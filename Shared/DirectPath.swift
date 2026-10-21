import Foundation
import CryptoKit
import Security
import Darwin

// MARK: - A direct IPv6 path, measured
//
// Measured on 2026-10-05: the phone on China Mobile 5G lost ~24% of its packets
// on the way to the overseas relay, and every loss held the whole TCP stream —
// the pointer — for 0.4–0.9 s. Both ends are on China Mobile in Shanghai with
// global IPv6, and domestic China Mobile paths measured 0% loss. A direct path
// would never cross the lossy international link.
//
// Inbound IPv6 to the Mac is blocked by its home router — but only unsolicited
// inbound: a reply from the exact address and port the Mac has sent to gets
// through (measured the same day). So both ends send to each other at once, and
// each one's firewall sees its own side open the conversation. This is the IPv6
// half of the hole punching RustDesk does (`punch_udp`/`start_ipv6` in its
// client); the design is followed here, the code is not — RustDesk is AGPL.
//
// Phase 0 only measures: punch, then ping for a while, and report round trips
// and loss. Nothing in the session depends on it yet.

/// One end's address for the direct path: a global IPv6 address and a UDP port.
public struct DirectCandidate: Codable, Sendable, Equatable {
    public var host: String
    public var port: UInt16

    public init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }

    public var display: String { "[\(host)]:\(port)" }
}

/// What a probe found.
public struct DirectProbeReport: Codable, Sendable, Equatable {
    public var punched: Bool
    /// Start of punching to the first packet from the other end.
    public var punchMillis: Int?
    public var sent: Int
    public var received: Int
    public var rttP50: Double?
    public var rttP95: Double?
    public var note: String?

    public init(punched: Bool, punchMillis: Int? = nil, sent: Int = 0, received: Int = 0,
                rttP50: Double? = nil, rttP95: Double? = nil, note: String? = nil) {
        self.punched = punched
        self.punchMillis = punchMillis
        self.sent = sent
        self.received = received
        self.rttP50 = rttP50
        self.rttP95 = rttP95
        self.note = note
    }

    public var lossPercent: Double {
        sent > 0 ? Double(sent - received) / Double(sent) * 100 : 0
    }

    public var summary: String {
        guard punched else { return "not reachable directly" + (note.map { " (\($0))" } ?? "") }
        // Punched and handed to the tunnel, nothing measured: say only that.
        if sent == 0 { return "punched in \(punchMillis ?? -1) ms; tunnel open" }
        let rtt = rttP50.map { String(format: "%.0f ms median", $0) } ?? "no replies"
        let p95 = rttP95.map { String(format: ", %.0f ms p95", $0) } ?? ""
        return String(format: "direct IPv6 in %d ms: %@%@, %.1f%% loss (%d/%d)",
                      punchMillis ?? -1, rtt, p95, lossPercent, received, sent)
    }
}

/// The datagrams on the direct path.
///
/// `NDP1 | kind | seq (u32) | stamp (u64) | tag (8)`, 25 bytes. The tag is the
/// first eight bytes of HMAC-SHA256 under a key exported from the control
/// session's TLS (`exporterLabel`), so only the two ends of that session can
/// make packets the other will answer: a stranger who learns the address and
/// port gets nothing back.
public enum DirectPacket {
    public enum Kind: UInt8, Sendable {
        case probe = 1, ack = 2, ping = 3, pong = 4
        /// The tunnel's: conversation `seq` has ended (`DirectTunnel`).
        case close = 5
    }

    public static let exporterLabel = "EXPORTER-nimlet-direct-v1"
    static let magic: [UInt8] = Array("NDP1".utf8)
    public static let size = 25

    public static func encode(_ kind: Kind, seq: UInt32, stamp: UInt64, key: SymmetricKey) -> Data {
        var out = Data(magic)
        out.append(kind.rawValue)
        withUnsafeBytes(of: seq.bigEndian) { out.append(contentsOf: $0) }
        withUnsafeBytes(of: stamp.bigEndian) { out.append(contentsOf: $0) }
        let tag = HMAC<SHA256>.authenticationCode(for: out, using: key)
        out.append(contentsOf: Data(tag).prefix(8))
        return out
    }

    public static func decode(_ data: Data, key: SymmetricKey) -> (kind: Kind, seq: UInt32, stamp: UInt64)? {
        let bytes = [UInt8](data)
        guard bytes.count == size, Array(bytes[0..<4]) == magic, let kind = Kind(rawValue: bytes[4]) else { return nil }
        let body = Data(bytes[0..<17])
        let tag = HMAC<SHA256>.authenticationCode(for: body, using: key)
        guard Data(tag).prefix(8) == Data(bytes[17..<25]) else { return nil }
        let seq = bytes[5..<9].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        let stamp = bytes[9..<17].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        return (kind, seq, stamp)
    }
}

/// When to send punch probes: at once, then 20 ms apart growing by half each
/// time up to 200 ms apart — RustDesk's schedule — for `limit` seconds.
public enum DirectPunchSchedule {
    public static func delays(limit: Double = 6) -> [Double] {
        var out: [Double] = [0]
        var gap = 0.02
        var at = 0.0
        while at + gap <= limit {
            at += gap
            out.append(at)
            gap = min(gap * 1.5, 0.2)
        }
        return out
    }
}

/// One UDP socket, punched towards the other end and then pinged through.
///
/// BSD sockets rather than Network.framework: the address and port have to be
/// chosen, bound and told to the other end before anything is sent, and on the
/// Mac the socket has to be held to the physical interface — its default IPv6
/// route can be a VPN's (a Tailscale exit node, on the machine this was built
/// on), and a reply leaving through the tunnel is a reply the router never sees.
public final class DirectProbe: @unchecked Sendable {
    public enum Role: Sendable {
        /// Pings once punched, and reports what came back.
        case pinger
        /// Answers pings until the time is up.
        case echo
    }

    public let local: DirectCandidate
    private let fd: Int32
    private let key: SymmetricKey
    private let queue = DispatchQueue(label: "com.renyicao.mice.direct")
    private var source: DispatchSourceRead?
    private var punchedAt: UInt64?
    private var startedAt: UInt64 = 0
    private var sentPings = 0
    private var pingSentAt: [UInt32: UInt64] = [:]
    private var roundTrips: [Double] = []
    private var finished = false
    private var completion: ((DirectProbeReport) -> Void)?
    private var role: Role = .pinger
    private var measureSeconds: Double = 0
    /// Set when the socket is to be handed over once punched, rather than
    /// measured: see `punch(peer:limit:completion:)`.
    private var handOver: ((Int32, Int) -> Void)?

    /// - Parameters:
    ///   - secret: the TLS exporter value both ends of the control session derive.
    ///   - address: the local IPv6 address to bind, or nil to pick one: the
    ///     physical interface's global address on a Mac, the default route's
    ///     on a phone.
    /// Tests only: the address to bind when none is given, in place of the
    /// default route's — loopback, where both ends of a test live.
    nonisolated(unsafe) public static var addressOverride: String?

    public init?(secret: Data, address: String? = nil, interface: String? = nil) {
        let address = address ?? Self.addressOverride
        guard let chosen = address.map({ (text: $0, index: interface.map { if_nametoindex($0) } ?? 0) })
                ?? Self.localIPv6(interface: interface) else { return nil }
        let fd = socket(AF_INET6, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return nil }
        var on: Int32 = 1
        setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &on, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        if chosen.index != 0 {
            var index = chosen.index
            setsockopt(fd, IPPROTO_IPV6, IPV6_BOUND_IF, &index, socklen_t(MemoryLayout<UInt32>.size))
        }
        var bindAddress = sockaddr_in6()
        bindAddress.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        bindAddress.sin6_family = sa_family_t(AF_INET6)
        guard inet_pton(AF_INET6, chosen.text, &bindAddress.sin6_addr) == 1,
              withUnsafePointer(to: &bindAddress, {
                  $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                      bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                  }
              }) == 0 else { close(fd); return nil }
        var bound = sockaddr_in6()
        var length = socklen_t(MemoryLayout<sockaddr_in6>.size)
        _ = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        self.fd = fd
        self.key = SymmetricKey(data: secret)
        self.local = DirectCandidate(host: chosen.text, port: UInt16(bigEndian: bound.sin6_port))
    }

    deinit { if !finished { close(fd) } }

    /// Punches towards `peer`, then measures for `seconds`, then reports once.
    public func start(peer: DirectCandidate, role: Role, measureFor seconds: Double,
                      punchLimit: Double = 6, completion: @escaping (DirectProbeReport) -> Void) {
        queue.async { [self] in
            self.role = role
            self.measureSeconds = seconds
            self.completion = completion
            var remote = sockaddr_in6()
            remote.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            remote.sin6_family = sa_family_t(AF_INET6)
            remote.sin6_port = peer.port.bigEndian
            guard inet_pton(AF_INET6, peer.host, &remote.sin6_addr) == 1,
                  withUnsafePointer(to: &remote, {
                      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                          connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                      }
                  }) == 0 else {
                return finish(DirectProbeReport(punched: false, note: "could not address \(peer.display): errno \(errno)"))
            }
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.readAll() }
            source.resume()
            self.source = source
            startedAt = Self.now()
            for delay in DirectPunchSchedule.delays(limit: punchLimit) {
                queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self, self.punchedAt == nil, !self.finished else { return }
                    self.send(.probe, seq: 0, stamp: 0)
                }
            }
            queue.asyncAfter(deadline: .now() + punchLimit + 0.5) { [weak self] in
                guard let self, self.punchedAt == nil else { return }
                self.finish(DirectProbeReport(punched: false, note: "no answer in \(Int(punchLimit)) s"))
            }
            // The echo end answers until it is safely past the pinger's last
            // ping; the pinger ends itself once its pings have come back.
            if role == .echo {
                queue.asyncAfter(deadline: .now() + punchLimit + seconds + 3) { [weak self] in self?.finish(nil) }
            }
        }
    }

    /// Punches towards `peer` and, the moment anything comes back, hands the
    /// connected socket over — to `DirectTunnel` — instead of measuring.
    /// `completion` gets the socket and how long punching took, or nil and why
    /// not; the caller owns the socket from then on.
    public func punch(peer: DirectCandidate, limit: Double = 6,
                      completion: @escaping (Int32?, Int?, String?) -> Void) {
        queue.async { [self] in
            handOver = { fd, millis in completion(fd, millis, nil) }
        }
        start(peer: peer, role: .echo, measureFor: 0, punchLimit: limit) { report in
            completion(nil, nil, report.note ?? "no answer")
        }
    }

    public func cancel() {
        queue.async { [weak self] in self?.finish(DirectProbeReport(punched: false, note: "cancelled")) }
    }

    // MARK: - Internals (on `queue`)

    private func punched() {
        guard punchedAt == nil else { return }
        punchedAt = Self.now()
        if let handOver {
            // Stop reading and hand the socket over without closing it. Any
            // probe still on its way is the tunnel's to answer.
            self.handOver = nil
            finished = true
            source?.cancel()
            source = nil
            completion = nil
            handOver(fd, Int((punchedAt! &- startedAt) / 1_000_000))
            return
        }
        guard role == .pinger else { return }
        // 20 Hz, about a pointer's worth of packets without its volume.
        let interval = 0.05
        let count = Int(measureSeconds / interval)
        for index in 0..<count {
            queue.asyncAfter(deadline: .now() + Double(index) * interval) { [weak self] in
                guard let self, !self.finished else { return }
                self.sentPings += 1
                let seq = UInt32(self.sentPings)
                let stamp = Self.now()
                self.pingSentAt[seq] = stamp
                self.send(.ping, seq: seq, stamp: stamp)
            }
        }
        // A second for the last pongs to come back.
        queue.asyncAfter(deadline: .now() + measureSeconds + 1) { [weak self] in self?.finish(nil) }
    }

    private func readAll() {
        var buffer = [UInt8](repeating: 0, count: 64)
        while true {
            let count = recv(fd, &buffer, buffer.count, MSG_DONTWAIT)
            // ICMP unreachable comes back as an error on a connected socket:
            // that is loss on the way, not the end of the path.
            if count < 0 { return }
            guard let packet = DirectPacket.decode(Data(buffer[0..<count]), key: key) else { continue }
            switch packet.kind {
            case .probe:
                send(.ack, seq: packet.seq, stamp: packet.stamp)
                punched()
            case .ack:
                punched()
            case .ping:
                punched()
                send(.pong, seq: packet.seq, stamp: packet.stamp)
            case .pong:
                guard let sentAt = pingSentAt.removeValue(forKey: packet.seq) else { continue }
                roundTrips.append(Double(Self.now() &- sentAt) / 1_000_000)
            case .close:
                continue
            }
        }
    }

    private func send(_ kind: DirectPacket.Kind, seq: UInt32, stamp: UInt64) {
        let data = DirectPacket.encode(kind, seq: seq, stamp: stamp, key: key)
        _ = data.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, data.count, 0) }
    }

    private func finish(_ given: DirectProbeReport?) {
        guard !finished else { return }
        finished = true
        source?.cancel()
        source = nil
        close(fd)
        let sorted = roundTrips.sorted()
        let pick = { (p: Double) -> Double? in sorted.isEmpty ? nil : sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))] }
        let report = given ?? DirectProbeReport(
            punched: punchedAt != nil,
            punchMillis: punchedAt.map { Int(($0 &- startedAt) / 1_000_000) },
            sent: sentPings, received: roundTrips.count,
            rttP50: pick(0.5), rttP95: pick(0.95))
        let completion = self.completion
        self.completion = nil
        completion?(report)
    }

    private static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    // MARK: - Choosing the local address

    /// A global IPv6 address to punch from.
    ///
    /// With an interface name, that interface's — what the Mac uses, naming its
    /// physical interface so a VPN's default route is not involved. Without
    /// one, the address the default route would use, found by "connecting" a
    /// UDP socket to a public resolver without sending anything (RustDesk's
    /// trick), which is what a phone uses: cellular or Wi-Fi, whichever it is on.
    public static func localIPv6(interface: String?) -> (text: String, index: UInt32)? {
        if let interface {
            return globalAddresses().first { $0.interface == interface }
                .map { ($0.text, if_nametoindex(interface)) }
        }
        let fd = socket(AF_INET6, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var resolver = sockaddr_in6()
        resolver.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        resolver.sin6_family = sa_family_t(AF_INET6)
        resolver.sin6_port = UInt16(53).bigEndian
        inet_pton(AF_INET6, "2400:3200::1", &resolver.sin6_addr)
        guard withUnsafePointer(to: &resolver, {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
        }) == 0 else { return nil }
        var mine = sockaddr_in6()
        var length = socklen_t(MemoryLayout<sockaddr_in6>.size)
        _ = withUnsafeMutablePointer(to: &mine) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard let text = text(of: mine.sin6_addr), isGlobal(text) else { return nil }
        return (text, 0)
    }

    /// The physical interface a Mac should punch from: the first with a global
    /// IPv6 address that is not a tunnel, a peer-to-peer link or a bridge.
    public static func physicalInterface() -> String? {
        globalAddresses().first.map(\.interface)
    }

    static func globalAddresses() -> [(interface: String, text: String)] {
        var out: [(String, String)] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let name = String(cString: entry.pointee.ifa_name)
            guard let address = entry.pointee.ifa_addr, Int32(address.pointee.sa_family) == AF_INET6,
                  Int32(entry.pointee.ifa_flags) & IFF_UP != 0,
                  !["utun", "awdl", "llw", "bridge", "ipsec", "gif", "stf", "lo"].contains(where: name.hasPrefix) else { continue }
            let text = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { Self.text(of: $0.pointee.sin6_addr) }
            if let text, isGlobal(text) { out.append((name, text)) }
        }
        return out
    }

    static func text(of address: in6_addr) -> String? {
        var address = address
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &address, &buffer, socklen_t(buffer.count)) != nil else { return nil }
        return String(cString: buffer)
    }

    /// 2000::/3, as `PublicAddress.isGloballyRoutableIPv6` decides it on the Mac.
    static func isGlobal(_ text: String) -> Bool {
        var address = in6_addr()
        guard inet_pton(AF_INET6, text, &address) == 1 else { return false }
        let first = withUnsafeBytes(of: address) { $0[0] }
        return first & 0xE0 == 0x20
    }
}

// MARK: - The relay's UDP

/// What the Mac tells the phone after asking the relay for a UDP pair: where
/// to send, and the token both ends put in front of every datagram so the
/// relay knows which pair it belongs to (`Relay/connect/relay.mjs`).
public struct RelayDatagramGrant: Codable, Sendable, Equatable {
    public var host: String
    public var port: UInt16
    /// 16 random bytes, base64url: only this Mac, its phone and the relay
    /// ever see it, and only inside TLS.
    public var token: String

    public init(host: String, port: UInt16, token: String) {
        self.host = host
        self.port = port
        self.token = token
    }

    public static func newToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// `NU1 | role | token`: what goes in front of each datagram from `role`.
    public func framing(asMac: Bool) -> Data? {
        var base64 = token.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let raw = Data(base64Encoded: base64), raw.count == 16 else { return nil }
        return Data("NU1".utf8) + Data([asMac ? 0x4D : 0x50]) + raw
    }

    /// The key a relay tunnel's datagrams are tagged with is exported from the
    /// session under its own label, so nothing from one tunnel means anything
    /// in another.
    public static let exporterLabel = "EXPORTER-nimlet-relay-udp-v1"
}

/// A UDP socket connected to `host:port` — an IP literal, as the relay's
/// address is configured. Follows the default route: the relay is reached the
/// way the Mac's TCP to it is.
public enum DirectSocket {
    public static func connected(to host: String, port: UInt16) -> Int32? {
        var hints = addrinfo()
        hints.ai_flags = AI_NUMERICHOST
        hints.ai_socktype = SOCK_DGRAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &result) == 0, let info = result else { return nil }
        defer { freeaddrinfo(result) }
        let fd = socket(info.pointee.ai_family, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return nil }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        guard connect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen) == 0 else {
            close(fd)
            return nil
        }
        return fd
    }
}
