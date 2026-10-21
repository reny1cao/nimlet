import XCTest
import CryptoKit
import Network

/// The connect relay end to end: the real `Relay/connect/relay.mjs` in a child
/// process, `RelayLink` registering with this Mac's key and pumping into a
/// trust listener, and a phone handshaking through it by server name. Every
/// claim the relay design makes — routing without decrypting, mutual pinning
/// end to end, a refused key refused through the relay too — is one of these.
///
/// Needs `node`; skipped without it.
final class RelayLinkTests: XCTestCase {

    private let mac = try! TrustIdentity(privateKey: P256.Signing.PrivateKey())
    private let phone = try! TrustIdentity(privateKey: P256.Signing.PrivateKey())
    private let stranger = try! TrustIdentity(privateKey: P256.Signing.PrivateKey())

    private var relay: Process?
    private var relayPort: UInt16 = 0
    private var relayFingerprint: TrustFingerprint!
    private var keyFile: URL?
    private let logLock = NSLock()
    private var relayLog = ""
    private var log: String { logLock.withLock { relayLog } }

    override func setUpWithError() throws {
        let script = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Relay/connect/relay.mjs")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        // A fresh key per run: the relay makes it, and prints the fingerprint
        // the Mac has to pin, which is what the next lines read back.
        let keyFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("nimlet-relay-test-\(UUID().uuidString).pem")
        self.keyFile = keyFile
        process.arguments = ["node", script.path, "--port", "0", "--key", keyFile.path]
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (environment["PATH"] ?? "/usr/bin:/bin")
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        // What the relay says about each phone, for the tests that care which
        // way it was carried.
        let errors = Pipe()
        process.standardError = errors
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let text = String(decoding: handle.availableData, as: UTF8.self)
            guard let self else { return }
            self.logLock.withLock { self.relayLog += text }
        }
        do { try process.run() } catch { throw XCTSkip("node is not available: \(error)") }
        relay = process
        let line = String(decoding: output.fileHandleForReading.availableData, as: UTF8.self)
        // `listening <port> <fingerprint>`
        let words = line.split(separator: " ").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard words.count == 3, words[0] == "listening", let port = UInt16(words[1]),
              let fingerprint = TrustFingerprint(words[2]) else {
            process.terminate()
            throw XCTSkip("the relay did not start: \(line)")
        }
        relayPort = port
        relayFingerprint = fingerprint
    }

    override func tearDown() {
        (relay?.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        relay?.terminate()
        relay?.waitUntilExit()
        if let keyFile { try? FileManager.default.removeItem(at: keyFile) }
    }

    private func link(for identity: TrustIdentity, to server: EchoMac,
                      pinning: TrustFingerprint? = nil) throws -> RelayLink {
        try XCTUnwrap(RelayLink(relay: "127.0.0.1:\(relayPort)", relayFingerprint: pinning ?? relayFingerprint,
                                identity: identity, localPort: server.port))
    }

    /// The Mac pins the relay's key: a relay presenting any other is never
    /// registered with, however it answers.
    func testTheMacRefusesARelayWhoseKeyItDoesNotPin() throws {
        let server = try EchoMac(identity: mac, accepts: [phone.fingerprint])
        let other = try TrustIdentity(privateKey: P256.Signing.PrivateKey()).fingerprint
        let link = try link(for: mac, to: server, pinning: other)
        defer { link.stop(); server.stop() }
        let failed = expectation(description: "refused")
        failed.assertForOverFulfill = false
        link.onStateChange = { state in
            if case .failed(let why) = state, why.contains("mice.relayFingerprint") { failed.fulfill() }
        }
        link.start()
        wait(for: [failed], timeout: 5)
        if case .registered = link.state { XCTFail("registered with a relay whose key was not the pinned one") }
    }

    func testTheRouteIsTheOneTheRelayDerivesFromTheKey() {
        let route = RelayRoute.route(for: mac.fingerprint)
        XCTAssertEqual(route.count, 40)
        XCTAssertEqual(RelayRoute.serverName(for: mac.fingerprint), route + ".nimlet")
    }

    func testAPhoneReachesTheMacThroughTheRelayWithBothKeysPinned() throws {
        let server = try EchoMac(identity: mac, accepts: [phone.fingerprint])
        let link = try link(for: mac, to: server)
        defer { link.stop(); server.stop() }
        try waitForRegistration(link)

        let reply = try dial(as: phone, payload: "through the relay")
        XCTAssertEqual(reply, "through the relay")
        XCTAssertEqual(server.peers, [phone.fingerprint], "the Mac must see the phone's own key, end to end")
    }

    func testALPNRoutesWithoutASyntheticDNSNameAndKeepsBothKeysPinned() throws {
        let server = try EchoMac(identity: mac, accepts: [phone.fingerprint])
        let link = try link(for: mac, to: server)
        defer { link.stop(); server.stop() }
        try waitForRegistration(link)
        XCTAssertEqual(try dial(as: phone, payload: "ALPN relay", useALPN: true), "ALPN relay")
        XCTAssertEqual(server.peers, [phone.fingerprint])
        XCTAssertNil(try dial(as: stranger, payload: "refuse me", useALPN: true))
        XCTAssertNil(try dial(as: phone, payload: "wrong Mac", pin: stranger.fingerprint, useALPN: true))
    }

    func testQuickSuccessfulSessionsDoNotLockOutThePairedPhone() throws {
        let server = try EchoMac(identity: mac, accepts: [phone.fingerprint])
        let link = try link(for: mac, to: server)
        defer { link.stop(); server.stop() }
        try waitForRegistration(link)
        for attempt in 0..<6 {
            XCTAssertEqual(try dial(as: phone, payload: "quick-\(attempt)", useALPN: true), "quick-\(attempt)")
        }
        XCTAssertEqual(server.peers.count, 6)
    }

    /// A Mac registered with a relay that offers spares keeps two ready, and
    /// the next phone is spliced to one at once: no OPEN, and no TCP and TLS
    /// handshake between the Mac and the relay while the phone waits. The TLS
    /// inside is still the phone's, end to end, and the spare is replaced.
    func testAPhoneIsCarriedByASpareTheMacOpenedInAdvance() throws {
        let server = try EchoMac(identity: mac, accepts: [phone.fingerprint])
        let link = try link(for: mac, to: server)
        defer { link.stop(); server.stop() }
        try waitForRegistration(link)
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(try dial(as: phone, payload: "via a spare", useALPN: true), "via a spare")
        XCTAssertEqual(server.peers, [phone.fingerprint])
        XCTAssertTrue(log.contains("phone: spliced to a spare"), log)
        // Its replacement is ready for the next one.
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(try dial(as: phone, payload: "and another", useALPN: true), "and another")
        XCTAssertEqual(log.components(separatedBy: "spliced to a spare").count - 1, 2, log)
        XCTAssertFalse(log.contains("phone: spliced\n"), "neither went through OPEN: \(log)")
    }

    /// The relay's UDP, end to end through the real relay: the Mac asks for a
    /// pair over its own TLS, both ends run the KCP tunnel through it with the
    /// token in front, and a session's bytes come back intact. Then the same
    /// with a quarter of the phone's datagrams lost — the 5G uplink measured on
    /// 2026-10-05 — with and without sending each twice.
    func testATunnelRunsThroughTheRelaysUDPAndRidesOutTheUplinkLoss() throws {
        let server = try EchoMac(identity: mac, accepts: [phone.fingerprint])
        let link = try link(for: mac, to: server)
        defer { link.stop(); server.stop() }
        try waitForRegistration(link)
        let echo = try LineEcho()
        defer { echo.stop() }

        func run(phoneLoss: Double, copies: Int) throws -> (p50: Double, p95: Double) {
            let token = RelayDatagramGrant.newToken()
            let granted = expectation(description: "UDP pair")
            var port: UInt16?
            link.requestDatagramPair(token: token) { port = $0; granted.fulfill() }
            wait(for: [granted], timeout: 5)
            let grant = RelayDatagramGrant(host: "127.0.0.1", port: try XCTUnwrap(port, "the relay offered no UDP"), token: token)
            let secret = Data(repeating: 5, count: 32)
            let macSide = DirectTunnel(socket: try XCTUnwrap(DirectSocket.connected(to: grant.host, port: grant.port)),
                                       secret: secret, side: .acceptor(port: echo.port),
                                       framing: try XCTUnwrap(grant.framing(asMac: true)),
                                       redundancy: copies > 1 ? .small(copies: copies, maxBytes: 300) : .none)
            let phoneSide = DirectTunnel(socket: try XCTUnwrap(DirectSocket.connected(to: grant.host, port: grant.port)),
                                         secret: secret, side: .dialer,
                                         framing: try XCTUnwrap(grant.framing(asMac: false)),
                                         redundancy: copies > 1 ? .all(copies: copies) : .none)
            phoneSide.dropRate = phoneLoss
            let ready = expectation(description: "listening and heard")
            ready.expectedFulfillmentCount = 2
            var loopback: UInt16 = 0
            phoneSide.onReady = { loopback = $0; ready.fulfill() }
            phoneSide.onFirstContact = { ready.fulfill() }
            macSide.start()
            phoneSide.start()
            wait(for: [ready], timeout: 10)
            defer { phoneSide.close(); macSide.close() }
            let times = try echo.pingPong(port: loopback, count: 80)
            let sorted = times.sorted()
            return (sorted[sorted.count / 2] * 1000, sorted[Int(Double(sorted.count) * 0.95)] * 1000)
        }

        let clean = try run(phoneLoss: 0, copies: 1)
        let lossy = try run(phoneLoss: 0.24, copies: 1)
        let doubled = try run(phoneLoss: 0.24, copies: 2)
        print(String(format: "relay UDP, small messages: clean p50 %.0f p95 %.0f ms; 24%% phone loss p50 %.0f p95 %.0f ms; same, sent twice p50 %.0f p95 %.0f ms",
                     clean.p50, clean.p95, lossy.p50, lossy.p95, doubled.p50, doubled.p95))
        XCTAssertLessThan(clean.p95, 50)
        XCTAssertLessThan(doubled.p95, lossy.p95, "sending twice must beat recovering")
        XCTAssertTrue(log.contains("opened a UDP pair"), log)
    }

    /// The relay passes ciphertext and nothing else: a key the Mac does not
    /// accept is refused by the Mac, through the relay, exactly as it would be
    /// on the LAN.
    func testAKeyTheMacDoesNotAcceptIsRefusedThroughTheRelay() throws {
        let server = try EchoMac(identity: mac, accepts: [phone.fingerprint])
        let link = try link(for: mac, to: server)
        defer { link.stop(); server.stop() }
        try waitForRegistration(link)

        XCTAssertNil(try dial(as: stranger, payload: "let me in"))
        XCTAssertTrue(server.peers.isEmpty)
    }

    /// And the phone pins the Mac: a relay that routed it somewhere else gets
    /// nothing from it.
    func testThePhoneRefusesAnythingButThePinnedMacThroughTheRelay() throws {
        let impostor = try TrustIdentity(privateKey: P256.Signing.PrivateKey())
        let server = try EchoMac(identity: impostor, accepts: [phone.fingerprint])
        let link = try link(for: impostor, to: server)
        defer { link.stop(); server.stop() }
        try waitForRegistration(link, as: impostor)

        // Routed to the impostor's route, pinning the real Mac.
        XCTAssertNil(try dial(as: phone, payload: "secret", route: impostor.fingerprint, pin: mac.fingerprint))
        XCTAssertTrue(server.peers.isEmpty)
    }

    // MARK: - Helpers

    private func waitForRegistration(_ link: RelayLink, as identity: TrustIdentity? = nil,
                                     timeout: TimeInterval = 5) throws {
        let expected = RelayRoute.route(for: (identity ?? mac).fingerprint)
        let registered = expectation(description: "registered")
        link.onStateChange = { state in
            if case .registered(let route) = state, route == expected { registered.fulfill() }
        }
        link.start()
        wait(for: [registered], timeout: timeout)
    }

    /// Dials the relay as `identity`, sends `payload`, returns what came back,
    /// or nil if the link never carried anything.
    private func dial(as identity: TrustIdentity, payload: String,
                      route: TrustFingerprint? = nil, pin: TrustFingerprint? = nil,
                      useALPN: Bool = false) throws -> String? {
        let target = route ?? mac.fingerprint
        let pinned = pin ?? target
        let params = try TrustTransport.parameters(identity: identity, accepts: { $0 == pinned },
                                                   peerToPeer: false,
                                                   serverName: useALPN ? nil : RelayRoute.serverName(for: target),
                                                   applicationProtocol: useALPN ? RelayRoute.applicationProtocol(for: target) : nil)
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: relayPort)!, using: params)
        let queue = DispatchQueue(label: "phone")
        let done = DispatchSemaphore(value: 0)
        var reply: String?
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                connection.send(content: Data(payload.utf8), completion: .contentProcessed { _ in })
                connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { data, _, _, error in
                    if error == nil, let data { reply = String(decoding: data, as: UTF8.self) }
                    done.signal()
                }
            case .failed, .waiting, .cancelled:
                done.signal()
            default: break
            }
        }
        connection.start(queue: queue)
        _ = done.wait(timeout: .now() + 8)
        connection.cancel()
        return reply
    }
}

/// A trust listener that echoes, and records which keys it let in.
private final class EchoMac: @unchecked Sendable {
    let listener: NWListener
    private let queue = DispatchQueue(label: "echo-mac")
    private let lock = NSLock()
    private var seen: [TrustFingerprint] = []
    var peers: [TrustFingerprint] { lock.withLock { seen } }
    var port: UInt16 { listener.port!.rawValue }

    init(identity: TrustIdentity, accepts: Set<TrustFingerprint>) throws {
        listener = try NWListener(using: TrustTransport.parameters(identity: identity, accepts: { accepts.contains($0) },
                                                                   peerToPeer: false), on: .any)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.newConnectionHandler = { [unowned self] connection in
            connection.stateUpdateHandler = { [unowned self] state in
                guard case .ready = state else { return }
                if let peer = TrustTransport.peerFingerprint(of: connection) {
                    lock.withLock { seen.append(peer) }
                    if case .hostPort(_, let port) = connection.endpoint {
                        RelayLink.phoneAuthenticated(atLocalPort: port.rawValue)
                    }
                }
                connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { data, _, _, _ in
                    if let data { connection.send(content: data, completion: .contentProcessed { _ in }) }
                }
            }
            connection.start(queue: queue)
        }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
    }

    func stop() { listener.cancel() }
}

/// Echoes each line it is sent — a stand-in for the away listener behind a
/// tunnel — and times line round trips through a loopback port.
private final class LineEcho: @unchecked Sendable {
    let listener: NWListener
    var port: UInt16 { listener.port!.rawValue }

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            func pump() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, done, error in
                    if let data { connection.send(content: data, completion: .contentProcessed { _ in }) }
                    if done || error != nil { connection.cancel(); return }
                    pump()
                }
            }
            pump()
        }
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.start(queue: .global())
        _ = ready.wait(timeout: .now() + 5)
    }

    func stop() { listener.cancel() }

    /// Sends `count` 80-byte lines one at a time and returns each round trip.
    func pingPong(port: UInt16, count: Int) throws -> [Double] {
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        connection.start(queue: .global())
        defer { connection.cancel() }
        var times: [Double] = []
        for index in 0..<count {
            let line = Data(String(format: "move %04d", index).utf8 + [UInt8](repeating: 32, count: 70) + [10])
            let back = DispatchSemaphore(value: 0)
            let lock = NSLock()
            var got = 0
            func read() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, error in
                    let done = lock.withLock { () -> Bool in got += data?.count ?? 0; return got >= line.count }
                    if done { back.signal() } else if error == nil { read() }
                }
            }
            let started = Date()
            connection.send(content: line, completion: .contentProcessed { _ in })
            read()
            guard back.wait(timeout: .now() + 10) == .success else { throw NSError(domain: "LineEcho", code: 1) }
            times.append(Date().timeIntervalSince(started))
        }
        return times
    }
}
