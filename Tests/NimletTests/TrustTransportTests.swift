import XCTest
import CryptoKit
import Network

/// The trust layer, tested against Apple's own TLS stack on loopback rather than
/// assumed: every claim `DeviceTrust.swift` makes about the handshake is one of
/// these.
final class TrustTransportTests: XCTestCase {

    private let mac = try! TrustIdentity(privateKey: P256.Signing.PrivateKey(), commonName: "mac")
    private let phone = try! TrustIdentity(privateKey: P256.Signing.PrivateKey(), commonName: "phone")
    private let stranger = try! TrustIdentity(privateKey: P256.Signing.PrivateKey(), commonName: "stranger")

    // MARK: - The certificate

    func testTheCertificateIsOneSecurityCanRead() throws {
        let certificate = try XCTUnwrap(SecCertificateCreateWithData(nil, mac.certificateDER as CFData))
        XCTAssertEqual(TrustFingerprint(certificate: certificate), mac.fingerprint)
    }

    func testTheIdentityIsOneNetworkFrameworkCanPresent() throws {
        // Built in init, which throws if Security would not make one.
        _ = try TrustIdentity(privateKey: P256.Signing.PrivateKey()).secIdentity
    }

    /// The certificate is rebuilt at every launch; only the key persists, so
    /// the fingerprint must not depend on anything but the key.
    func testTheFingerprintIsTheKeysNotTheCertificates() throws {
        let again = try TrustIdentity(privateKey: mac.privateKey, commonName: "renamed")
        XCTAssertNotEqual(again.certificateDER, mac.certificateDER)
        XCTAssertEqual(again.fingerprint, mac.fingerprint)
    }

    // MARK: - The handshake

    func testPinnedPeersCompleteATLS13Handshake() throws {
        let link = try Loopback(server: mac, serverAccepts: [phone.fingerprint],
                                client: phone, clientAccepts: [mac.fingerprint])
        let outcome = link.run()
        XCTAssertTrue(outcome.clientReady)
        XCTAssertTrue(outcome.serverReady)
        XCTAssertEqual(outcome.version, .TLSv13, "TLS 1.3 is what brings ECDHE, and with it forward secrecy")
    }

    /// The device id is now something the phone proved, not something it said.
    func testTheMacLearnsWhichKeyThePhoneHolds() throws {
        let link = try Loopback(server: mac, serverAccepts: [phone.fingerprint],
                                client: phone, clientAccepts: [mac.fingerprint])
        let outcome = link.run()
        XCTAssertEqual(outcome.serverSawPeer, phone.fingerprint)
        XCTAssertEqual(outcome.clientSawPeer, mac.fingerprint)
    }

    func testBothEndsDeriveTheSameExporterAndItIsPerSession() throws {
        let first = try Loopback(server: mac, serverAccepts: [phone.fingerprint],
                                 client: phone, clientAccepts: [mac.fingerprint]).run()
        let second = try Loopback(server: mac, serverAccepts: [phone.fingerprint],
                                  client: phone, clientAccepts: [mac.fingerprint]).run()
        XCTAssertNotNil(first.clientExporter)
        XCTAssertEqual(first.clientExporter, first.serverExporter)
        XCTAssertNotEqual(first.clientExporter, second.clientExporter,
                          "a proof bound to one session must be worthless on the next")
    }

    /// A phone that dialled the wrong Mac — or a relay pretending to be one —
    /// is refused by the phone itself.
    func testThePhoneRefusesAMacItDidNotPair() throws {
        let link = try Loopback(server: stranger, serverAccepts: [phone.fingerprint],
                                client: phone, clientAccepts: [mac.fingerprint])
        let outcome = link.run()
        XCTAssertFalse(outcome.clientReady)
        XCTAssertFalse(outcome.serverReady)
    }

    /// A revoked or never-approved phone never gets a session. In TLS 1.3 the
    /// client finishes before the server has judged its certificate, so the
    /// phone may briefly think it is in — what matters is that the Mac never
    /// is, and the phone's first read fails.
    func testTheMacRefusesAPhoneItDoesNotTrust() throws {
        let link = try Loopback(server: mac, serverAccepts: [phone.fingerprint],
                                client: stranger, clientAccepts: [mac.fingerprint])
        let outcome = link.run()
        XCTAssertFalse(outcome.serverReady)
        XCTAssertFalse(outcome.clientCouldRead)
    }

    /// Revocation has to hold against a phone that was in a moment ago, on the
    /// same listener. A resumed TLS 1.3 session would skip the certificate
    /// exchange and with it the verify block, which is why `TrustTransport`
    /// turns resumption off. Measured: this loopback does not resume even with
    /// it on, so the test pins the outcome rather than proving the setting.
    func testARevokedPhoneCannotComeBackOnItsLastSession() throws {
        let approved = ApprovedKeys([phone.fingerprint])
        let link = try Loopback(server: mac, serverAccepts: { approved.contains($0) },
                                client: phone, clientAccepts: [mac.fingerprint])
        let first = link.run(keepListening: true)
        XCTAssertTrue(first.serverReady)
        approved.revokeAll()
        let second = link.run()
        XCTAssertFalse(second.serverReady)
        XCTAssertFalse(second.clientCouldRead)
    }

    func testAPhoneWithNoCertificateIsRefused() throws {
        // A client that presents nothing: the PSK-era phone, or a port scanner.
        let link = try Loopback(server: mac, serverAccepts: [phone.fingerprint],
                                client: nil, clientAccepts: [mac.fingerprint])
        let outcome = link.run()
        XCTAssertFalse(outcome.serverReady)
    }

    // MARK: - Pairing

    func testAPairingProofVerifiesForTheSessionAndDeviceItWasMadeFor() {
        let secret = PairingProof.newSecret()
        let exporter = Data(repeating: 7, count: 32)
        let proof = PairingProof.make(secret: secret, exporter: exporter, device: phone.fingerprint)
        XCTAssertTrue(PairingProof.verify(proof, secret: secret, exporter: exporter, device: phone.fingerprint))
        XCTAssertFalse(PairingProof.verify(proof, secret: secret, exporter: Data(repeating: 8, count: 32),
                                           device: phone.fingerprint), "replayed onto another session")
        XCTAssertFalse(PairingProof.verify(proof, secret: secret, exporter: exporter,
                                           device: stranger.fingerprint), "lifted onto another device")
        XCTAssertFalse(PairingProof.verify(proof, secret: PairingProof.newSecret(), exporter: exporter,
                                           device: phone.fingerprint), "made without the secret")
    }

    func testTheSecretIs128Bits() {
        XCTAssertEqual(PairingProof.newSecret().count, 16)
        XCTAssertNotEqual(PairingProof.newSecret(), PairingProof.newSecret())
    }

    func testAnInvitationSurvivesTheTripThroughAQRCode() throws {
        let invitation = PairingInvitation(host: mac.fingerprint, secret: PairingProof.newSecret(),
                                           name: "Renyi's MacBook Air", addresses: ["192.168.0.2:61413", "[fd7a::1]:61413"])
        let decoded = try XCTUnwrap(PairingInvitation(url: invitation.url))
        XCTAssertEqual(decoded, invitation)
    }

    func testAnInvitationWithAShortSecretIsRejected() throws {
        var components = URLComponents(url: PairingInvitation(host: mac.fingerprint, secret: PairingProof.newSecret(),
                                                              name: "Mac").url,
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = components.queryItems!.map {
            $0.name == "s" ? URLQueryItem(name: "s", value: Data(repeating: 1, count: 4).base64URLEncoded) : $0
        }
        XCTAssertNil(PairingInvitation(url: components.url!))
    }

    func testTheShortCodeUsesThePairingAlphabet() {
        let code = mac.fingerprint.shortCode
        XCTAssertEqual(code.count, 8)
        XCTAssertTrue(code.allSatisfy { PairingCode.alphabet.contains($0) })
    }
}

/// One listener, one connection, on 127.0.0.1, and what each end saw.
private final class Loopback {
    struct Outcome {
        var clientReady = false
        var serverReady = false
        var clientCouldRead = false
        var version: tls_protocol_version_t?
        var clientSawPeer: TrustFingerprint?
        var serverSawPeer: TrustFingerprint?
        var clientExporter: Data?
        var serverExporter: Data?
    }

    private let listener: NWListener
    private let clientParams: NWParameters
    private let queue = DispatchQueue(label: "loopback")
    private var outcome = Outcome()
    private var serverConnection: NWConnection?

    convenience init(server: TrustIdentity, serverAccepts: Set<TrustFingerprint>,
                     client: TrustIdentity?, clientAccepts: Set<TrustFingerprint>) throws {
        try self.init(server: server, serverAccepts: { serverAccepts.contains($0) },
                      client: client, clientAccepts: clientAccepts)
    }

    init(server: TrustIdentity, serverAccepts: @escaping @Sendable (TrustFingerprint) -> Bool,
         client: TrustIdentity?, clientAccepts: Set<TrustFingerprint>) throws {
        let serverParams = try TrustTransport.parameters(identity: server,
                                                         accepts: serverAccepts,
                                                         peerToPeer: false)
        listener = try NWListener(using: serverParams, on: .any)
        if let client {
            clientParams = try TrustTransport.parameters(identity: client,
                                                         accepts: { clientAccepts.contains($0) },
                                                         peerToPeer: false)
        } else {
            // TLS 1.3 with the same pin, and no certificate to offer.
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv13)
            sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, _, complete in complete(true) },
                                                  DispatchQueue(label: "noclient"))
            clientParams = NWParameters(tls: tls)
        }
    }

    private var started = false

    /// One connection. With `keepListening` the listener stays up, so a
    /// second run dials the same port — which is what a resumed session needs.
    func run(timeout: TimeInterval = 5, keepListening: Bool = false) -> Outcome {
        outcome = Outcome()
        let listening = DispatchSemaphore(value: 0)
        let done = DispatchGroup()
        done.enter()   // server verdict
        done.enter()   // client verdict
        var serverDone = false
        let finishServer = { if !serverDone { serverDone = true; done.leave() } }

        listener.stateUpdateHandler = { if case .ready = $0 { listening.signal() } }
        listener.newConnectionHandler = { [unowned self] connection in
            serverConnection = connection
            connection.stateUpdateHandler = { [unowned self] state in
                switch state {
                case .ready:
                    outcome.serverReady = true
                    outcome.serverSawPeer = TrustTransport.peerFingerprint(of: connection)
                    outcome.serverExporter = TrustTransport.exporter(of: connection, label: PairingProof.exporterLabel)
                    connection.send(content: Data("hi".utf8), completion: .contentProcessed { _ in })
                    finishServer()
                case .failed, .cancelled:
                    finishServer()
                default: break
                }
            }
            connection.start(queue: queue)
        }
        if !started {
            listener.start(queue: queue)
            guard listening.wait(timeout: .now() + timeout) == .success else { return outcome }
            started = true
        }
        guard let port = listener.port else { return outcome }

        let client = NWConnection(host: "127.0.0.1", port: port, using: clientParams)
        var clientDone = false
        let finishClient = { if !clientDone { clientDone = true; done.leave() } }
        client.stateUpdateHandler = { [unowned self] state in
            switch state {
            case .ready:
                outcome.clientReady = true
                outcome.version = TrustTransport.negotiatedVersion(of: client)
                outcome.clientSawPeer = TrustTransport.peerFingerprint(of: client)
                outcome.clientExporter = TrustTransport.exporter(of: client, label: PairingProof.exporterLabel)
                client.receive(minimumIncompleteLength: 1, maximumLength: 16) { [unowned self] data, _, _, error in
                    outcome.clientCouldRead = error == nil && data == Data("hi".utf8)
                    finishClient()
                }
            case .failed, .cancelled:
                finishClient()
            case .waiting:
                // A refused handshake parks here rather than failing.
                finishClient()
            default: break
            }
        }
        client.start(queue: queue)
        // A server that refuses the client never reports anything for that
        // connection beyond failing it, and may not even do that before the
        // client gives up — so its verdict is bounded rather than awaited.
        _ = done.wait(timeout: .now() + timeout)
        let result = queue.sync { outcome }
        client.cancel()
        serverConnection?.cancel()
        if !keepListening { listener.cancel() }
        return result
    }
}

/// A set of approved keys the test can change between handshakes.
private final class ApprovedKeys: @unchecked Sendable {
    private let lock = NSLock()
    private var keys: Set<TrustFingerprint>
    init(_ keys: Set<TrustFingerprint>) { self.keys = keys }
    func contains(_ key: TrustFingerprint) -> Bool { lock.withLock { keys.contains(key) } }
    func revokeAll() { lock.withLock { keys.removeAll() } }
}
