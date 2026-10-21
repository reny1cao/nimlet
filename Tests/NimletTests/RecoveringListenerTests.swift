import XCTest
import Network
import CryptoKit

final class RecoveringListenerTests: XCTestCase {
    private let queue = DispatchQueue(label: "mice.listener.recovery.tests")
    private let mac = try! TrustIdentity(privateKey: P256.Signing.PrivateKey())
    private let phone = try! TrustIdentity(privateKey: P256.Signing.PrivateKey())

    private func blocker() throws -> NWListener {
        let listener = try NWListener(using: .tcp, on: .any)
        let ready = expectation(description: "port occupied")
        listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        listener.newConnectionHandler = { $0.cancel() }
        listener.start(queue: queue)
        wait(for: [ready], timeout: 2)
        return listener
    }

    private func recovering(on port: NWEndpoint.Port) -> RecoveringListener {
        RecoveringListener(queue: queue) {
            try NWListener(using: TrustTransport.parameters(identity: self.mac,
                                                            accepts: { $0 == self.phone.fingerprint },
                                                            peerToPeer: false), on: port)
        }
    }

    func testAnOccupiedPortRecoversAfterReleaseWithoutRestartingTheApp() throws {
        let occupied = try blocker()
        let port = try XCTUnwrap(occupied.port)
        let listener = recovering(on: port)
        let failed = expectation(description: "occupied port refused")
        let ready = expectation(description: "listener recovered")
        var reportedFailure = false
        queue.sync {
            listener.stateUpdateHandler = { state in
                switch state {
                case .failed(let error) where !reportedFailure:
                    XCTAssertEqual(error, .posix(.EADDRINUSE))
                    reportedFailure = true
                    failed.fulfill()
                case .ready: ready.fulfill()
                default: break
                }
            }
            listener.start()
        }
        wait(for: [failed], timeout: 2)
        // It must not share a port with another live app instance.
        queue.sync { if case .ready = listener.state { XCTFail("Port ownership must stay exclusive") } }
        let start = Date()
        occupied.cancel()
        wait(for: [ready], timeout: 1.5)
        print("listener recovered after release: \(Int(Date().timeIntervalSince(start) * 1000)) ms")
        try checkPinnedConnection(on: listener, port: port)
        queue.sync { listener.cancel() }
    }

    func testCancelDuringRetryCannotReopenThePort() throws {
        let occupied = try blocker()
        let port = try XCTUnwrap(occupied.port)
        let listener = recovering(on: port)
        let failed = expectation(description: "initial bind failed")
        let reopened = expectation(description: "cancelled listener must stay closed")
        reopened.isInverted = true
        queue.sync {
            listener.stateUpdateHandler = { state in
                if case .failed = state { failed.fulfill() }
                if case .ready = state { reopened.fulfill() }
            }
            listener.start()
        }
        wait(for: [failed], timeout: 2)
        queue.sync { listener.cancel() }
        occupied.cancel()
        wait(for: [reopened], timeout: 0.8)
        queue.sync { if case .cancelled = listener.state {} else { XCTFail("Must stay cancelled") } }
    }

    func testRepeatedFixedPortRestartsStillAcceptPinnedTLSClients() throws {
        let reservation = try blocker()
        let port = try XCTUnwrap(reservation.port)
        reservation.cancel()
        for iteration in 0..<12 {
            let listener = recovering(on: port)
            let ready = expectation(description: "restart \(iteration)")
            queue.sync {
                listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
                listener.start()
            }
            wait(for: [ready], timeout: 1.5)
            try checkPinnedConnection(on: listener, port: port)
            queue.sync { listener.cancel() }
        }
    }

    private func checkPinnedConnection(on listener: RecoveringListener, port: NWEndpoint.Port) throws {
        let read = expectation(description: "pinned TLS hello delivered")
        queue.sync {
            listener.newConnectionHandler = { connection in
                connection.start(queue: self.queue)
                connection.send(content: Data("ready".utf8), completion: .contentProcessed { _ in })
                connection.receive(minimumIncompleteLength: 1, maximumLength: 16) { _, _, _, _ in
                    connection.cancel()
                }
            }
        }
        let client = NWConnection(host: "127.0.0.1", port: port,
                                  using: try TrustTransport.parameters(identity: phone,
                                                                       accepts: { $0 == self.mac.fingerprint },
                                                                       peerToPeer: false))
        client.start(queue: queue)
        client.receive(minimumIncompleteLength: 1, maximumLength: 16) { data, _, _, error in
            XCTAssertNil(error)
            XCTAssertEqual(data, Data("ready".utf8))
            read.fulfill()
        }
        wait(for: [read], timeout: 2)
        client.cancel()
    }
}
