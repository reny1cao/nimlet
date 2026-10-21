import Foundation
import Network
import CryptoKit
import Darwin
import CKCP

/// TCP connections carried over the punched IPv6 UDP path, each as one KCP
/// conversation — the relay, with the ocean taken out.
///
/// Measured on 2026-10-05 between the phone on China Mobile 5G and the Mac on
/// China Mobile broadband, both in Shanghai: the direct path answered in 81 ms
/// with no loss (400/400), where the relay through Singapore took 924 ms and
/// lost a quarter of the phone's packets. So the session moves here.
///
/// What runs inside is exactly what runs through the relay: the phone's TLS
/// 1.3, pinned at both ends, from a loopback socket on the phone to the Mac's
/// away listener on loopback. Nothing about who is trusted changes, and nothing
/// above this type knows it is not a TCP connection to the Mac.
///
/// KCP is RustDesk's choice for its direct UDP paths, used here with its
/// "turbo" settings (`nodelay 1, interval 10, resend 2, nc 1`, windows of 1024,
/// stream mode): retransmission after two later acknowledgements or a 30 ms
/// floor, rather than TCP's hundreds of milliseconds. Congestion is left to the
/// mirror's own end-to-end window (`VideoFlowWindow`). The C is skywind3000's
/// (MIT, `Packages/CKCP`); the design is RustDesk's; the code is not (AGPL).
///
/// Datagrams on the socket:
/// - `DirectPacket` (25 bytes): probes still in flight, keepalive ping/pong,
///   and `close` for a conversation that has ended;
/// - `0xD7 | KCP segment | tag`, the tag being HMAC-SHA256 under the session's
///   exported key, truncated to 8 bytes, so a stranger who learns the address
///   cannot feed a conversation.
public final class DirectTunnel: @unchecked Sendable {

    /// Extra copies of what this end sends, for a path that loses packets.
    ///
    /// Through the relay the phone's uplink lost ~24% (5G, Shanghai →
    /// Singapore, 2026-10-05). KCP recovers a lost segment in about a round
    /// trip — half a second through the relay — so recovering is not enough;
    /// not losing it is. That direction carries the pointer, keys and
    /// acknowledgements, which are tiny, so sending each twice costs little and
    /// turns a 24% loss into ~6% if the two are lost independently.
    public enum Redundancy: Sendable, Equatable {
        case none
        /// Every datagram, `copies` times in all.
        case all(copies: Int)
        /// Datagrams up to `maxBytes`, `copies` times: acknowledgements and
        /// input, not the mirror's frames.
        case small(copies: Int, maxBytes: Int)

        func copies(for bytes: Int) -> Int {
            switch self {
            case .none: return 1
            case .all(let copies): return max(1, copies)
            case .small(let copies, let maxBytes): return bytes <= maxBytes ? max(1, copies) : 1
            }
        }
    }

    /// Gap between copies, so a burst of loss is less likely to take both.
    static let copySpacing: Double = 0.004

    public enum Side: Sendable {
        /// The phone: listens on loopback and carries each connection to the Mac.
        case dialer
        /// The Mac: opens a loopback connection to `port` — the away listener —
        /// for each conversation the phone starts.
        case acceptor(port: UInt16)
    }

    static let marker: UInt8 = 0xD7
    static let tagLength = 8
    /// A UDP payload this size crosses any IPv6 path without fragmenting.
    static let datagram = 1200
    /// How long the path may say nothing before it is given up for dead.
    public static let silenceLimit: Double = 8
    static let keepaliveInterval: Double = 1
    /// More than this many segments waiting and the local side stops being read
    /// until they drain — RustDesk's `2 × sndwnd`.
    static let backlog = 2048

    private let fd: Int32
    private let key: SymmetricKey
    private let side: Side
    /// Put in front of every datagram sent: the relay's `NU1 | role | token`
    /// when the path is the relay's UDP, nothing when it is direct.
    private let framing: Data
    private let redundancy: Redundancy
    private var heardAnything = false
    private let queue = DispatchQueue(label: "com.renyicao.mice.direct.tunnel")
    private var source: DispatchSourceRead?
    private var timer: DispatchSourceTimer?
    private var listener: NWListener?
    private var conversations: [UInt32: Conversation] = [:]
    /// Ended conversations, so their stragglers do not start new ones.
    private var ended: Set<UInt32> = []
    private var lastHeard: UInt64
    private var lastPing: UInt64 = 0
    private var pingSeq: UInt32 = 0
    private var pingsOut: [UInt32: UInt64] = [:]
    private var roundTrips: [Double] = []
    private var closed = false

    /// The loopback port to dial (dialer side), once listening.
    public var onReady: (@Sendable (UInt16) -> Void)?
    /// Once, when the tunnel ends, with why.
    public var onClose: (@Sendable (String) -> Void)?
    /// Once, when the first datagram from the other end arrives — proof the
    /// path works, which on the relay is not known until both ends are in.
    public var onFirstContact: (@Sendable () -> Void)?
    /// Tests: the fraction of outgoing datagrams to drop on purpose.
    var dropRate: Double = 0

    // MARK: - Which loopback sockets are the tunnel's

    private static let portsLock = NSLock()
    private static var acceptorPorts: [UInt16: String] = [:]

    /// What a connection reaching the away listener from `port` on loopback
    /// came through — "direct", or "relay UDP" — or nil for neither, so the
    /// Mac's log says which path a phone is really on.
    public static func carrier(ofLocalPort port: UInt16) -> String? {
        portsLock.withLock { acceptorPorts[port] }
    }

    private var label: String { framing.isEmpty ? "direct" : "relay UDP" }

    final class Conversation {
        let conv: UInt32
        let kcp: UnsafeMutablePointer<ikcpcb>
        let local: NWConnection
        /// Not reading the local side while too much waits to be sent.
        var paused = false
        /// The local side has ended; close once what it sent is acknowledged.
        var closingSince: UInt64?
        /// The loopback port this end dialled from, on the Mac.
        var localPort: UInt16?

        init(conv: UInt32, kcp: UnsafeMutablePointer<ikcpcb>, local: NWConnection) {
            self.conv = conv
            self.kcp = kcp
            self.local = local
        }
    }

    /// Takes over a socket `DirectProbe.punch` connected.
    public init(socket fd: Int32, secret: Data, side: Side, framing: Data = Data(), redundancy: Redundancy = .none) {
        self.fd = fd
        self.key = SymmetricKey(data: secret)
        self.side = side
        self.framing = framing
        self.redundancy = redundancy
        self.lastHeard = Self.now()
    }

    deinit {
        if !closed { Darwin.close(fd) }
    }

    public func start() {
        queue.async { [self] in
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.readAll() }
            source.resume()
            self.source = source
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(2))
            timer.setEventHandler { [weak self] in self?.tick() }
            timer.resume()
            self.timer = timer
            if case .dialer = side { listen() }
        }
    }

    public func close(_ reason: String = "closed") {
        queue.async { [weak self] in self?.shutDown(reason) }
    }

    /// The direct path's round trip, from the keepalive pings: median of the
    /// last few, in milliseconds.
    public func roundTripMillis() -> Double? {
        queue.sync {
            let recent = roundTrips.suffix(15).sorted()
            return recent.isEmpty ? nil : recent[recent.count / 2]
        }
    }

    // MARK: - Local side

    private func listen() {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        (parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options)?.noDelay = true
        guard let listener = try? NWListener(using: parameters) else {
            return shutDown("could not listen on loopback")
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self else { return }
            switch state {
            case .ready:
                if let port = listener?.port?.rawValue { self.onReady?(port) }
            case .failed(let error):
                self.shutDown("loopback listener failed: \(error)")
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return connection.cancel() }
            var conv = UInt32.random(in: 1...UInt32.max)
            while self.conversations[conv] != nil || self.ended.contains(conv) {
                conv = UInt32.random(in: 1...UInt32.max)
            }
            self.open(conv, local: connection)
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    /// A conversation, and the loopback connection it carries.
    private func open(_ conv: UInt32, local: NWConnection) {
        guard let kcp = ikcp_create(conv, Unmanaged.passUnretained(self).toOpaque()) else {
            return local.cancel()
        }
        ikcp_setoutput(kcp, kcpOutput)
        ikcp_nodelay(kcp, 1, 10, 2, 1)
        ikcp_wndsize(kcp, 1024, 1024)
        ikcp_setmtu(kcp, Int32(Self.datagram - 1 - Self.tagLength - framing.count))
        kcp.pointee.stream = 1
        let conversation = Conversation(conv: conv, kcp: kcp, local: local)
        conversations[conv] = conversation
        local.stateUpdateHandler = { [weak self, weak conversation] state in
            switch state {
            case .ready:
                if case .acceptor = self?.side,
                   case .hostPort(_, let port) = local.currentPath?.localEndpoint {
                    conversation?.localPort = port.rawValue
                    let label = self?.label ?? "direct"
                    Self.portsLock.withLock { Self.acceptorPorts[port.rawValue] = label }
                }
            case .failed, .cancelled: self?.localEnded(conv)
            default: break
            }
        }
        local.start(queue: queue)
        readLocal(conversation)
    }

    private func readLocal(_ conversation: Conversation) {
        conversation.local.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self, self.conversations[conversation.conv] === conversation else { return }
            if let data, !data.isEmpty {
                data.withUnsafeBytes { raw in
                    _ = ikcp_send(conversation.kcp, raw.bindMemory(to: CChar.self).baseAddress, Int32(raw.count))
                }
                ikcp_flush(conversation.kcp)
            }
            if complete || error != nil { return self.localEnded(conversation.conv) }
            if ikcp_waitsnd(conversation.kcp) > Int32(Self.backlog) {
                conversation.paused = true
            } else {
                self.readLocal(conversation)
            }
        }
    }

    private func localEnded(_ conv: UInt32) {
        guard let conversation = conversations[conv], conversation.closingSince == nil else { return }
        conversation.closingSince = Self.now()
    }

    // MARK: - The path

    private func readAll() {
        var buffer = [UInt8](repeating: 0, count: 2048)
        while !closed {
            let count = recv(fd, &buffer, buffer.count, MSG_DONTWAIT)
            if count < 0 { return }
            let packet = Data(buffer[0..<count])
            if count == DirectPacket.size, let control = DirectPacket.decode(packet, key: key) {
                lastHeard = Self.now()
                noteContact()
                handle(control.kind, seq: control.seq, stamp: control.stamp)
                continue
            }
            guard count > 1 + 24 + Self.tagLength, buffer[0] == Self.marker else { continue }
            let body = packet.prefix(count - Self.tagLength)
            let tag = HMAC<SHA256>.authenticationCode(for: body, using: key)
            guard Data(tag).prefix(Self.tagLength) == packet.suffix(Self.tagLength) else { continue }
            lastHeard = Self.now()
            noteContact()
            let segment = body.dropFirst()
            let conv = segment.withUnsafeBytes { ikcp_getconv($0.baseAddress) }
            if conversations[conv] == nil {
                guard case .acceptor(let port) = side, !ended.contains(conv) else { continue }
                let local = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!,
                                         using: Self.loopbackParameters())
                open(conv, local: local)
            }
            guard let conversation = conversations[conv] else { continue }
            segment.withUnsafeBytes { raw in
                _ = ikcp_input(conversation.kcp, raw.bindMemory(to: CChar.self).baseAddress, raw.count)
            }
            deliver(conversation)
        }
    }

    private func noteContact() {
        guard !heardAnything else { return }
        heardAnything = true
        let contact = onFirstContact
        onFirstContact = nil
        contact?()
    }

    private func handle(_ kind: DirectPacket.Kind, seq: UInt32, stamp: UInt64) {
        switch kind {
        case .probe:
            // The other end has not heard our ack yet; it still needs one.
            sendControl(.ack, seq: seq, stamp: stamp)
        case .ack:
            break
        case .ping:
            sendControl(.pong, seq: seq, stamp: stamp)
        case .pong:
            if let sent = pingsOut.removeValue(forKey: seq) {
                roundTrips.append(Double(Self.now() &- sent) / 1_000_000)
                if roundTrips.count > 60 { roundTrips.removeFirst() }
            }
        case .close:
            guard let conversation = conversations[seq] else { return }
            deliver(conversation)
            finish(conversation, tellPeer: false)
        }
    }

    /// Everything KCP has put back in order goes to the local side.
    private func deliver(_ conversation: Conversation) {
        while true {
            let size = ikcp_peeksize(conversation.kcp)
            guard size > 0 else { return }
            var bytes = [UInt8](repeating: 0, count: Int(size))
            let read = bytes.withUnsafeMutableBytes {
                ikcp_recv(conversation.kcp, $0.bindMemory(to: CChar.self).baseAddress, size)
            }
            guard read > 0 else { return }
            conversation.local.send(content: Data(bytes[0..<Int(read)]), completion: .contentProcessed { [weak self] error in
                guard error != nil, let self else { return }
                self.queue.async { self.localEnded(conversation.conv) }
            })
        }
    }

    private func tick() {
        guard !closed else { return }
        let now = Self.now()
        let clock = UInt32(truncatingIfNeeded: now / 1_000_000)
        for conversation in Array(conversations.values) {
            ikcp_update(conversation.kcp, clock)
            if conversation.paused, ikcp_waitsnd(conversation.kcp) <= Int32(Self.backlog / 2) {
                conversation.paused = false
                readLocal(conversation)
            }
            // Closed locally: once what it sent is acknowledged — or after a
            // few seconds of trying — tell the other end and let go.
            if let since = conversation.closingSince,
               ikcp_waitsnd(conversation.kcp) == 0 || Double(now &- since) / 1e9 > 3 {
                finish(conversation, tellPeer: true)
            }
        }
        if Double(now &- lastPing) / 1e9 >= Self.keepaliveInterval {
            lastPing = now
            pingSeq &+= 1
            pingsOut[pingSeq] = now
            if pingsOut.count > 20 { pingsOut.removeValue(forKey: pingsOut.keys.min()!) }
            sendControl(.ping, seq: pingSeq, stamp: now)
        }
        if Double(now &- lastHeard) / 1e9 > Self.silenceLimit {
            shutDown("the direct path went silent for \(Int(Self.silenceLimit)) s")
        }
    }

    private func finish(_ conversation: Conversation, tellPeer: Bool) {
        guard conversations.removeValue(forKey: conversation.conv) != nil else { return }
        ended.insert(conversation.conv)
        if tellPeer {
            // Three times, a little apart: a close lost on the way would leave
            // the other end holding a conversation nobody is in.
            for delay in [0.0, 0.05, 0.2] {
                queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.sendControl(.close, seq: conversation.conv, stamp: 0)
                }
            }
        }
        conversation.local.cancel()
        ikcp_release(conversation.kcp)
        if let port = conversation.localPort {
            Self.portsLock.withLock { _ = Self.acceptorPorts.removeValue(forKey: port) }
        }
    }

    private func shutDown(_ reason: String) {
        guard !closed else { return }
        for conversation in Array(conversations.values) { finish(conversation, tellPeer: true) }
        closed = true
        listener?.cancel()
        listener = nil
        timer?.cancel()
        timer = nil
        source?.cancel()
        source = nil
        Darwin.close(fd)
        let onClose = self.onClose
        self.onClose = nil
        onClose?(reason)
    }

    // MARK: - Sending

    fileprivate func sendSegment(_ bytes: UnsafeRawBufferPointer) {
        guard !closed else { return }
        var datagram = Data(capacity: bytes.count + 1 + Self.tagLength)
        datagram.append(Self.marker)
        datagram.append(contentsOf: bytes)
        let tag = HMAC<SHA256>.authenticationCode(for: datagram, using: key)
        datagram.append(contentsOf: Data(tag).prefix(Self.tagLength))
        transmit(datagram)
    }

    private func sendControl(_ kind: DirectPacket.Kind, seq: UInt32, stamp: UInt64) {
        guard !closed else { return }
        transmit(DirectPacket.encode(kind, seq: seq, stamp: stamp, key: key))
    }

    private func transmit(_ datagram: Data) {
        let framed = framing.isEmpty ? datagram : framing + datagram
        let copies = redundancy.copies(for: framed.count)
        put(framed)
        for copy in 1..<max(copies, 1) {
            queue.asyncAfter(deadline: .now() + Self.copySpacing * Double(copy)) { [weak self] in
                guard let self, !self.closed else { return }
                self.put(framed)
            }
        }
    }

    private func put(_ datagram: Data) {
        if dropRate > 0, Double.random(in: 0..<1) < dropRate { return }
        // A full socket buffer or an ICMP error is loss on the way, which KCP
        // and the keepalive are there to absorb.
        _ = datagram.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, datagram.count, 0) }
    }

    private static func loopbackParameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        return NWParameters(tls: nil, tcp: tcp)
    }

    private static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
}

/// KCP's output: one segment, to go out as one datagram.
private let kcpOutput: @convention(c) (UnsafePointer<CChar>?, Int32, UnsafeMutablePointer<ikcpcb>?, UnsafeMutableRawPointer?) -> Int32 = { buffer, length, _, user in
    guard let buffer, let user, length > 0 else { return 0 }
    let tunnel = Unmanaged<DirectTunnel>.fromOpaque(user).takeUnretainedValue()
    tunnel.sendSegment(UnsafeRawBufferPointer(start: buffer, count: Int(length)))
    return 0
}
