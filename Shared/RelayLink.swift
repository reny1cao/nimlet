import Foundation
import Network
import CryptoKit

/// The hint a phone puts in its TLS ALPN (or legacy server name) to be routed to one Mac by the
/// connect relay, derived from the key it already pinned for that Mac — so
/// there is nothing new for the Mac to hand out, and nothing to keep in step.
public enum RelayRoute {
    /// The relay's route: the first 20 bytes of the key fingerprint, in hex.
    /// Forty characters, which is a DNS label (63 at most) and so a server
    /// name BoringSSL will send.
    public static func route(for host: TrustFingerprint) -> String {
        host.bytes.prefix(20).map { String(format: "%02x", $0) }.joined()
    }

    public static func serverName(for host: TrustFingerprint) -> String {
        route(for: host) + ".nimlet"
    }

    /// A routing hint, not a DNS name. iOS VPN proxies can try resolving a
    /// synthetic SNI hostname before sending the handshake to its IP address.
    public static func applicationProtocol(for host: TrustFingerprint) -> String {
        "nimlet-" + route(for: host)
    }
}

/// The Mac's end of the connect relay (`Relay/connect/relay.mjs`).
///
/// A Mac behind a NAT nobody can open still makes outbound connections, so it
/// holds one open to the relay and registers by proving it holds its key. When
/// a phone arrives the relay says `OPEN`, and this opens a second connection
/// that becomes the phone's byte stream — and pumps it, unread, into this
/// Mac's own away listener on loopback. The TLS inside is end to end: the
/// phone pinned this Mac's key, the away listener pins the phone's, and the
/// relay and this pump see ciphertext with forward secrecy.
///
/// Into the away listener in particular, because it is the one that never
/// pairs and never issues a key: whatever comes through the relay is treated
/// as what it is — something from the internet.
///
/// ## The Mac's own connections to the relay are TLS too
///
/// Not for secrecy — what they carry is the phone's ciphertext and a few
/// lines of control — but for *identity*. Without it, anybody on the path
/// between this Mac and the relay could answer as the relay: say `OPEN`
/// whenever they liked, or stand in the middle of the registration and hold
/// this Mac's route at the real relay. So the Mac dials the relay with TLS
/// 1.3, pins the relay's key (`relayFingerprint`, printed by the relay when it
/// starts), and refuses anything else before a line is exchanged. The relay
/// does not present a certificate for its name; it presents its key, and the
/// key is the whole of the trust decision — the same rule as between phone
/// and Mac.
public final class RelayLink: @unchecked Sendable {
    public enum State: Equatable, Sendable {
        case connecting
        case registered(route: String)
        case failed(String)
    }

    public let relayHost: String
    public let relayPort: UInt16
    public let relayFingerprint: TrustFingerprint
    private let identity: TrustIdentity
    private let localPort: UInt16
    private let queue = DispatchQueue(label: "com.renyicao.mice.relay")
    /// Called on the relay queue whenever `state` changes.
    public var onStateChange: (@Sendable (State) -> Void)?

    private var control: NWConnection?
    private var lines = LineFramer(maxLineBytes: 4096)
    private var running = false
    private var retryDelay: TimeInterval = 1
    private var bridges: [ObjectIdentifier: Bridge] = [:]
    /// Connections to the relay opened before any phone needed them, so the
    /// next phone is spliced at once instead of waiting for this Mac to dial
    /// the relay and finish a TLS handshake across the internet (measured
    /// from Shanghai to Singapore on 2026-10-05: 670 ms median, per socket).
    /// Only when the relay offered a token with its OK; an older relay never
    /// does, and this Mac then answers OPEN as it always did.
    private var spares: [ObjectIdentifier: NWConnection] = [:]
    private var spareToken: String?
    private var route: String?
    /// Spares that died young in a row, for the backoff on replacing them.
    private var spareFailures = 0
    /// Two: a phone's control socket and its mirror arrive together.
    public static let spareCount = 2
    /// UDP pairs asked for and not yet answered, by token.
    private var datagramWaiters: [String: @Sendable (UInt16?) -> Void] = [:]

    /// Asks the relay for a UDP pair under `token` (`RelayDatagramGrant`), over
    /// this Mac's own TLS to it. `completion` gets the relay's UDP port, or nil
    /// — not registered, or a relay too old to know the word, which says
    /// nothing and is given three seconds.
    public func requestDatagramPair(token: String, completion: @escaping @Sendable (UInt16?) -> Void) {
        queue.async {
            guard let control = self.control, case .registered = self._state else { return completion(nil) }
            self.datagramWaiters[token] = completion
            self.write("UDP \(token)\n", on: control)
            self.queue.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.datagramWaiters.removeValue(forKey: token)?(nil)
            }
        }
    }
    private var _state: State = .connecting {
        didSet { if _state != oldValue { onStateChange?(_state) } }
    }
    public var state: State { queue.sync { _state } }

    /// - Parameters:
    ///   - relay: `host:port`, as `mice.relay` holds it.
    ///   - relayFingerprint: the relay's key, as `mice.relayFingerprint` holds
    ///     it and the relay prints it at startup.
    public init?(relay: String, relayFingerprint: TrustFingerprint, identity: TrustIdentity, localPort: UInt16) {
        guard let colon = relay.lastIndex(of: ":"),
              let port = UInt16(relay[relay.index(after: colon)...]), port > 0 else { return nil }
        let host = String(relay[..<colon]).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard !host.isEmpty else { return nil }
        relayHost = host
        relayPort = port
        self.relayFingerprint = relayFingerprint
        self.identity = identity
        self.localPort = localPort
    }

    public func start() {
        queue.async {
            guard !self.running else { return }
            self.running = true
            self.connectControl()
        }
    }

    public func stop() {
        queue.sync {
            running = false
            control?.cancel()
            control = nil
            dropSpares()
            bridges.values.forEach { $0.cancel() }
            bridges.removeAll()
        }
    }

    // MARK: - Which phone is behind a relayed socket

    /// The phones behind the loopback sockets currently pumped into the away
    /// listener, by the loopback port each pump dialled from. `HostServer`
    /// reads it to count a failed handshake against the phone the relay said
    /// it was carrying rather than against `127.0.0.1`, which is every relayed
    /// phone at once.
    private static let phonesLock = NSLock()
    private struct RelayedPhone {
        let address: String
        let authenticated: @Sendable () -> Void
    }
    private static var phonesByLocalPort: [UInt16: RelayedPhone] = [:]

    public static func phoneAddress(forLocalPort port: UInt16) -> String? {
        phonesLock.withLock { phonesByLocalPort[port]?.address }
    }

    /// Called by the away listener only after mutual TLS accepts an approved
    /// phone. A quick successful connection must not count as an attack.
    public static func phoneAuthenticated(atLocalPort port: UInt16) {
        let notify = phonesLock.withLock { phonesByLocalPort[port]?.authenticated }
        notify?()
    }

    private static func record(phone: String, atLocalPort port: UInt16,
                               authenticated: @escaping @Sendable () -> Void) {
        phonesLock.withLock { phonesByLocalPort[port] = RelayedPhone(address: phone, authenticated: authenticated) }
    }

    private static func forget(localPort port: UInt16) {
        phonesLock.withLock { phonesByLocalPort[port] = nil }
    }

    // MARK: - The control connection

    private static func tcp() -> NWProtocolTCP.Options {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        // Above the relay's 20-second PING, which keeps the link busy and is
        // what finds a dead relay; keepalive is only the backstop.
        tcp.keepaliveIdle = 45
        tcp.keepaliveInterval = 5
        tcp.keepaliveCount = 3
        tcp.connectionTimeout = 10
        return tcp
    }

    /// TLS to the relay: 1.3 only, and the verify block accepts exactly the
    /// key the user configured. Nothing about names or chains is consulted.
    private func relayParameters() -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv13)
        // A Mac sends no phone ALPN routing hint. Its real hostname may be
        // SNI; an IP literal is left unnamed. Neither identifies a phone.
        if IPv4Address(relayHost) == nil, IPv6Address(relayHost) == nil {
            sec_protocol_options_set_tls_server_name(options, relayHost)
        }
        let pinned = relayFingerprint
        sec_protocol_options_set_verify_block(options, { _, trust, complete in
            let ref = sec_trust_copy_ref(trust).takeRetainedValue()
            guard let chain = SecTrustCopyCertificateChain(ref) as? [SecCertificate],
                  let leaf = chain.first,
                  let presented = TrustFingerprint(certificate: leaf) else { return complete(false) }
            complete(presented == pinned)
        }, queue)
        let params = NWParameters(tls: tls, tcp: Self.tcp())
        return params
    }

    private var relayEndpoint: NWEndpoint {
        .hostPort(host: NWEndpoint.Host(relayHost), port: NWEndpoint.Port(rawValue: relayPort)!)
    }

    private func connectControl() {
        guard running else { return }
        _state = .connecting
        lines = LineFramer(maxLineBytes: 4096)
        let connection = NWConnection(to: relayEndpoint, using: relayParameters())
        control = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, self.control === connection else { return }
            switch state {
            case .ready:
                let key = self.identity.privateKey.publicKey.x963Representation.base64URLEncoded
                // ` spares`: this Mac will keep connections ready if the relay
                // offers a token for them. An older relay ignores the word.
                self.write("NIMLET-HOST 1 \(key) spares\n", on: connection)
                self.readLines(on: connection)
            case .failed(let error):
                self.lost(connection, because: Self.describe(error))
            case .waiting(let error):
                self.lost(connection, because: Self.describe(error))
            case .cancelled:
                self.lost(connection, because: nil)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    /// A refused pin reads as a bare TLS error; say what it means instead.
    private static func describe(_ error: NWError) -> String {
        if case .tls(let status) = error, status == errSSLBadCert || status == errSSLXCertChainInvalid || status == errSSLPeerBadCert {
            return "the relay's key is not the one in mice.relayFingerprint"
        }
        return error.localizedDescription
    }

    private func lost(_ connection: NWConnection, because reason: String?) {
        guard control === connection else { return }
        connection.cancel()
        control = nil
        dropSpares()
        guard running else { return }
        _state = .failed(reason ?? "the relay closed the connection")
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, 30)
        queue.asyncAfter(deadline: .now() + delay * Double.random(in: 0.8...1.2)) { [weak self] in
            guard let self, self.running, self.control == nil else { return }
            self.connectControl()
        }
    }

    private func readLines(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, complete, error in
            guard let self, self.control === connection else { return }
            for line in data.map({ self.lines.append($0) }) ?? [] {
                self.handle(String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespaces), on: connection)
            }
            if self.lines.droppedLines > 0 { return self.lost(connection, because: "the relay sent a line too long") }
            if complete || error != nil { return self.lost(connection, because: error.map(Self.describe)) }
            self.readLines(on: connection)
        }
    }

    private func handle(_ line: String, on connection: NWConnection) {
        let parts = line.split(separator: " ", maxSplits: 2).map(String.init)
        switch parts.first {
        case "CHALLENGE":
            guard parts.count == 2, let nonce = Data(base64URLEncoded: parts[1]),
                  let signature = try? identity.privateKey.signature(for: Data("nimlet-relay-v1:".utf8) + nonce) else {
                return lost(connection, because: "the relay's challenge was unreadable")
            }
            write("PROOF \(signature.derRepresentation.base64URLEncoded)\n", on: connection)
        case "OK":
            retryDelay = 1
            route = parts.count >= 2 ? parts[1] : nil
            spareToken = parts.count >= 3 ? parts[2] : nil
            _state = .registered(route: parts.count >= 2 ? parts[1] : "")
            replenishSpares()
        case "OPEN":
            // `OPEN <id> <phone address>`. The address is what the relay saw,
            // for the away listener's throttle; absent from an older relay.
            guard parts.count >= 2 else { return }
            openBridge(id: parts[1], phone: parts.count >= 3 ? parts[2] : "?")
        case "PING":
            write("PONG\n", on: connection)
        case "UDP-OK":
            // `UDP-OK <token> <port>`
            guard parts.count == 3, let port = UInt16(parts[2]) else { return }
            datagramWaiters.removeValue(forKey: parts[1])?(port)
        case "UDP-NO":
            guard parts.count >= 2 else { return }
            datagramWaiters.removeValue(forKey: parts[1])?(nil)
        default:
            break
        }
    }

    private func write(_ text: String, on connection: NWConnection) {
        connection.send(content: Data(text.utf8), completion: .contentProcessed { _ in })
    }

    // MARK: - One phone

    /// The away listener's own budget (`HostServer.maxAwayConnections`): more
    /// than this would only be refused there, and a relay asking for more is
    /// misbehaving.
    private static let maxBridges = 6

    // MARK: - Spares

    private func replenishSpares() {
        while spares.count < Self.spareCount, openSpare() {}
    }

    /// Opens one spare, if the relay offered them. False when it did not.
    @discardableResult
    private func openSpare() -> Bool {
        guard running, control != nil, let token = spareToken, let route else { return false }
        let connection = NWConnection(to: relayEndpoint, using: relayParameters())
        let key = ObjectIdentifier(connection)
        spares[key] = connection
        let opened = Date()
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.write("NIMLET-SPARE 1 \(route) \(token)\n", on: connection)
                self.awaitPhone(on: connection, buffer: Data())
            case .waiting:
                connection.cancel()
            case .failed, .cancelled:
                self.spareEnded(key, opened: opened)
            default:
                break
            }
        }
        connection.start(queue: queue)
        return true
    }

    /// Reads a spare's one line, `PHONE <id> <address>`. What follows it is
    /// the phone's ClientHello, and goes to the away listener first.
    private func awaitPhone(on connection: NWConnection, buffer: Data) {
        let key = ObjectIdentifier(connection)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self, self.spares[key] != nil else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
                let parts = line.split(separator: " ").map(String.init)
                guard parts.first == "PHONE", parts.count >= 2 else { return connection.cancel() }
                self.spares[key] = nil
                self.spareFailures = 0
                self.adoptSpare(connection, id: parts[1], phone: parts.count >= 3 ? parts[2] : "?",
                                leftover: Data(buffer[buffer.index(after: newline)...]))
                // The next phone, or this one's next socket, gets one too.
                self.replenishSpares()
                return
            }
            if complete || error != nil || buffer.count > 4096 { return connection.cancel() }
            self.awaitPhone(on: connection, buffer: buffer)
        }
    }

    /// A spare closed before any phone used it: the relay restarted, dropped
    /// an idle one, or refused it. Replaced, but a run of quick deaths backs
    /// off rather than dialling the relay in a loop.
    private func spareEnded(_ key: ObjectIdentifier, opened: Date) {
        guard spares.removeValue(forKey: key) != nil else { return }
        if Date().timeIntervalSince(opened) < 10 { spareFailures += 1 } else { spareFailures = 0 }
        let delay = min(pow(2, Double(spareFailures)), 60)
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.replenishSpares() }
    }

    private func dropSpares() {
        let open = spares.values
        spares.removeAll()
        open.forEach { $0.cancel() }
        spareToken = nil
        route = nil
    }

    private func adoptSpare(_ connection: NWConnection, id: String, phone: String, leftover: Data) {
        guard bridges.count < Self.maxBridges else { return connection.cancel() }
        let bridge = Bridge(relay: connection,
                            local: NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: localPort)!,
                                                using: NWParameters(tls: nil, tcp: Self.tcp())),
                            phone: phone,
                            queue: queue)
        bridge.onAuthenticated = { [weak self] in
            guard let self, let control = self.control else { return }
            self.write("VERIFIED \(id)\n", on: control)
        }
        let key = ObjectIdentifier(bridge)
        bridges[key] = bridge
        bridge.onClose = { [weak self] in self?.bridges[key] = nil }
        bridge.adopt(leftover: leftover)
    }

    private func openBridge(id: String, phone: String) {
        guard bridges.count < Self.maxBridges else { return }
        let bridge = Bridge(relay: NWConnection(to: relayEndpoint, using: relayParameters()),
                            local: NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: localPort)!,
                                                using: NWParameters(tls: nil, tcp: Self.tcp())),
                            phone: phone,
                            queue: queue)
        bridge.onAuthenticated = { [weak self] in
            guard let self, let control = self.control else { return }
            self.write("VERIFIED \(id)\n", on: control)
        }
        let key = ObjectIdentifier(bridge)
        bridges[key] = bridge
        bridge.onClose = { [weak self] in self?.bridges[key] = nil }
        bridge.start(hello: Data("NIMLET-DATA 1 \(id)\n".utf8))
    }

    /// Two sockets, each read only as fast as the other drains.
    ///
    /// Read-after-write rather than read-ahead: the mirror's rate control
    /// measures how long a frame takes to leave the Mac, and over the relay
    /// the first hop is this loopback socket. A pump that read eagerly would
    /// make every frame look instant and blind the pacer to a cellular link
    /// that is drowning; one that waits for each write lets the backlog reach
    /// the socket the pacer is timing.
    private final class Bridge {
        let relay: NWConnection
        let local: NWConnection
        let phone: String
        let queue: DispatchQueue
        var onClose: (() -> Void)?
        var onAuthenticated: (() -> Void)?
        private var authenticated = false
        private var closed = false
        private var localPort: UInt16?
        private var heardFromRelay = false

        /// How long a bridge may sit with nothing from the relay side. A
        /// phone that was there sends its ClientHello the moment the splice
        /// is made; a bridge that has heard nothing in this long is holding
        /// one of the away listener's slots for a phone that is not there.
        private static let silence: TimeInterval = 5

        init(relay: NWConnection, local: NWConnection, phone: String, queue: DispatchQueue) {
            self.relay = relay
            self.local = local
            self.phone = phone
            self.queue = queue
        }

        func start(hello: Data) {
            relay.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.relay.send(content: hello, completion: .contentProcessed { _ in })
                    self.local.start(queue: self.queue)
                    self.queue.asyncAfter(deadline: .now() + Self.silence) { [weak self] in
                        guard let self, !self.heardFromRelay else { return }
                        self.cancel()
                    }
                case .failed, .cancelled: self.cancel()
                default: break
                }
            }
            prepareLocal(first: Data())
            relay.start(queue: queue)
            // Bounded: a relay that opens a socket and never fills it must not
            // hold a slot on the away listener for ever.
            queue.asyncAfter(deadline: .now() + 15) { [weak self] in
                guard let self, self.local.state != .ready else { return }
                self.cancel()
            }
        }

        /// A spare the relay has just given a phone: already connected, and
        /// `leftover` is the phone's first bytes, read along with the PHONE line.
        func adopt(leftover: Data) {
            heardFromRelay = true
            relay.stateUpdateHandler = { [weak self] state in
                switch state {
                case .failed, .cancelled: self?.cancel()
                default: break
                }
            }
            prepareLocal(first: leftover)
            local.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 15) { [weak self] in
                guard let self, self.local.state != .ready else { return }
                self.cancel()
            }
        }

        /// The loopback half. `first` is written to the away listener before
        /// anything is pumped, so the phone's bytes arrive in order.
        private func prepareLocal(first: Data) {
            local.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    if case .hostPort(_, let port) = self.local.currentPath?.localEndpoint {
                        self.localPort = port.rawValue
                        RelayLink.record(phone: self.phone, atLocalPort: port.rawValue) { [weak self] in
                            guard let self else { return }
                            self.queue.async { [weak self] in
                                guard let self, !self.authenticated else { return }
                                self.authenticated = true
                                self.onAuthenticated?()
                            }
                        }
                    }
                    let startPumping = { [weak self] in
                        guard let self, !self.closed else { return }
                        self.pump(from: self.relay, to: self.local)
                        self.pump(from: self.local, to: self.relay)
                    }
                    if first.isEmpty { startPumping() } else {
                        self.local.send(content: first, completion: .contentProcessed { [weak self] error in
                            if error != nil { self?.cancel() } else { startPumping() }
                        })
                    }
                case .failed, .cancelled: self.cancel()
                default: break
                }
            }
        }

        /// Numbers bridges for the timing series below, so a control socket's
        /// moves and a mirror's frames are not averaged into one number.
        private static var bridgeCount = 0
        private lazy var tag: Int = { Bridge.bridgeCount += 1; return Bridge.bridgeCount }()
        private var lastFromRelay: UInt64 = 0

        private func pump(from source: NWConnection, to sink: NWConnection) {
            source.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
                guard let self, !self.closed else { return }
                if let data, !data.isEmpty {
                    if source === self.relay { self.heardFromRelay = true }
                    // Measured only when asked for (`mice.instrument`): where in
                    // this Mac the time goes between the relay and the listener.
                    let inbound = source === self.relay
                    let received = Instrumentation.now()
                    if Instrumentation.isEnabled, inbound {
                        if self.lastFromRelay != 0 {
                            Instrumentation.shared.record("bridge\(self.tag)_relay_gap", since: self.lastFromRelay)
                        }
                        self.lastFromRelay = received
                        Instrumentation.shared.record(bytes: "bridge\(self.tag)_relay_chunk", data.count)
                    } else if Instrumentation.isEnabled {
                        Instrumentation.shared.record(bytes: "bridge\(self.tag)_local_chunk", data.count)
                    }
                    sink.send(content: data, completion: .contentProcessed { [weak self] sendError in
                        guard let self, !self.closed else { return }
                        if Instrumentation.isEnabled {
                            Instrumentation.shared.record(inbound ? "bridge\(self.tag)_to_local" : "bridge\(self.tag)_to_relay",
                                                          since: received)
                        }
                        if sendError != nil { return self.cancel() }
                        if complete || error != nil { return self.cancel() }
                        self.pump(from: source, to: sink)
                    })
                    return
                }
                if complete || error != nil { return self.cancel() }
                self.pump(from: source, to: sink)
            }
        }

        func cancel() {
            guard !closed else { return }
            closed = true
            relay.cancel()
            local.cancel()
            if let localPort { RelayLink.forget(localPort: localPort) }
            onClose?()
        }
    }
}
