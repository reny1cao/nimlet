import XCTest
import Network

/// The direct tunnel end to end on loopback: two punched sockets, KCP between
/// them, a TCP connection in at the phone's end and out at the Mac's.
final class DirectTunnelTests: XCTestCase {

    private let secret = Data(repeating: 3, count: 32)

    /// A stand-in for the away listener: echoes whatever it is sent.
    private final class Echo: @unchecked Sendable {
        let listener: NWListener
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
        var port: UInt16 { listener.port!.rawValue }
    }

    /// Punches two ends on ::1 and returns both tunnels and the phone's port.
    private func tunnels(drop: Double) throws -> (DirectTunnel, DirectTunnel, UInt16, Echo) {
        let echo = try Echo()
        let phoneProbe = try XCTUnwrap(DirectProbe(secret: secret, address: "::1"))
        let macProbe = try XCTUnwrap(DirectProbe(secret: secret, address: "::1"))
        let punched = expectation(description: "punched")
        punched.expectedFulfillmentCount = 2
        var phoneFD: Int32?, macFD: Int32?
        macProbe.punch(peer: phoneProbe.local, limit: 2) { fd, _, _ in macFD = fd; punched.fulfill() }
        phoneProbe.punch(peer: macProbe.local, limit: 2) { fd, _, _ in phoneFD = fd; punched.fulfill() }
        wait(for: [punched], timeout: 5)
        let phone = DirectTunnel(socket: try XCTUnwrap(phoneFD), secret: secret, side: .dialer)
        let mac = DirectTunnel(socket: try XCTUnwrap(macFD), secret: secret, side: .acceptor(port: echo.port))
        phone.dropRate = drop
        mac.dropRate = drop
        let listening = expectation(description: "listening")
        var port: UInt16 = 0
        phone.onReady = { port = $0; listening.fulfill() }
        mac.start()
        phone.start()
        wait(for: [listening], timeout: 5)
        return (phone, mac, port, echo)
    }

    /// Sends `bytes` in through the phone's loopback port and reads the echo.
    private func roundTrip(_ bytes: Data, port: UInt16, timeout: TimeInterval) throws -> (Data, TimeInterval) {
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        let lock = NSLock()
        var received = Data()
        let done = expectation(description: "echoed")
        func read() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, finished, error in
                let complete = lock.withLock { () -> Bool in
                    if let data { received.append(data) }
                    return received.count >= bytes.count
                }
                if complete { done.fulfill(); return }
                if finished || error != nil { return }
                read()
            }
        }
        let started = Date()
        connection.start(queue: .global())
        connection.send(content: bytes, completion: .contentProcessed { _ in })
        read()
        wait(for: [done], timeout: timeout)
        connection.cancel()
        return (lock.withLock { received }, Date().timeIntervalSince(started))
    }

    func testAMegabyteCrossesTheTunnelIntact() throws {
        let (phone, mac, port, _) = try tunnels(drop: 0)
        defer { phone.close(); mac.close() }
        let payload = Data((0..<1_000_000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        let (echoed, took) = try roundTrip(payload, port: port, timeout: 20)
        XCTAssertEqual(echoed, payload)
        print("1 MB through the tunnel and back: \(Int(took * 1000)) ms")
    }

    /// What broke the relay: a fifth of the datagrams lost, both ways. KCP
    /// resends quickly and nothing arrives out of order or missing.
    func testAFifthOfThePacketsLostStillArrivesIntact() throws {
        let (phone, mac, port, _) = try tunnels(drop: 0.2)
        defer { phone.close(); mac.close() }
        let payload = Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0 &* 13 &+ 1) })
        let (echoed, took) = try roundTrip(payload, port: port, timeout: 30)
        XCTAssertEqual(echoed.count, payload.count)
        XCTAssertEqual(echoed, payload)
        print("200 KB through the tunnel with 20% loss each way: \(Int(took * 1000)) ms")
    }

    /// Small messages one after another on one connection, as the pointer
    /// sends them: with 20% loss each way every one still comes back quickly —
    /// KCP resends a lost segment after its 30 ms floor, not TCP's hundreds.
    func testSmallMessagesOnOneConnectionStayQuickUnderLoss() throws {
        let (phone, mac, port, _) = try tunnels(drop: 0.2)
        defer { phone.close(); mac.close() }
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        connection.start(queue: .global())
        var times: [TimeInterval] = []
        for index in 0..<60 {
            let message = Data("move \(index)".utf8 + [UInt8](repeating: 32, count: 70))
            let back = expectation(description: "echo \(index)")
            let lock = NSLock()
            var got = Data()
            func read() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, error in
                    let done = lock.withLock { () -> Bool in
                        if let data { got.append(data) }
                        return got.count >= message.count
                    }
                    if done { back.fulfill() } else if error == nil { read() }
                }
            }
            let started = Date()
            connection.send(content: message, completion: .contentProcessed { _ in })
            read()
            wait(for: [back], timeout: 5)
            XCTAssertEqual(lock.withLock { got }, message)
            times.append(Date().timeIntervalSince(started))
        }
        connection.cancel()
        let sorted = times.sorted()
        let p50 = sorted[sorted.count / 2], p95 = sorted[Int(Double(sorted.count) * 0.95)], worst = sorted.last!
        print(String(format: "small messages, one connection, 20%% loss each way: p50 %.0f ms, p95 %.0f ms, worst %.0f ms",
                     p50 * 1000, p95 * 1000, worst * 1000))
        XCTAssertLessThan(p95, 0.3)
    }

    /// The far end going away closes the conversation at this end too, so a
    /// session on the tunnel fails over instead of hanging.
    func testClosingOneEndEndsTheOther() throws {
        let (phone, mac, _, _) = try tunnels(drop: 0)
        let ended = expectation(description: "phone side ended")
        phone.onClose = { _ in ended.fulfill() }
        mac.close("test")
        // The phone hears nothing more and gives the path up after the
        // silence limit.
        wait(for: [ended], timeout: DirectTunnel.silenceLimit + 4)
    }
}
