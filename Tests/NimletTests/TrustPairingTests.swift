import XCTest
import CryptoKit
import Network

/// The pieces of pairing by key that are logic rather than handshake.
final class TrustPairingTests: XCTestCase {

    private let phone = try! TrustIdentity(privateKey: P256.Signing.PrivateKey())
    private let stranger = try! TrustIdentity(privateKey: P256.Signing.PrivateKey())
    private let exporter = Data(repeating: 3, count: 32)
    private let t0 = Date(timeIntervalSinceReferenceDate: 5_000)

    // MARK: - The invitation window

    func testNothingIsRedeemableUntilAWindowIsOpened() {
        var window = PairingWindow()
        XCTAssertFalse(window.isOpen(at: t0))
        let proof = PairingProof.make(secret: PairingProof.newSecret(), exporter: exporter, device: phone.fingerprint)
        XCTAssertFalse(window.redeem(proof, exporter: exporter, device: phone.fingerprint, at: t0))
    }

    /// A QR code on a screen can be photographed; the second scan must fail.
    func testAnInvitationWorksOnce() {
        var window = PairingWindow()
        let secret = window.open(at: t0)
        let proof = PairingProof.make(secret: secret, exporter: exporter, device: phone.fingerprint)
        XCTAssertTrue(window.redeem(proof, exporter: exporter, device: phone.fingerprint, at: t0))
        XCTAssertFalse(window.isOpen(at: t0))
        let second = PairingProof.make(secret: secret, exporter: exporter, device: stranger.fingerprint)
        XCTAssertFalse(window.redeem(second, exporter: exporter, device: stranger.fingerprint, at: t0))
    }

    func testAnInvitationExpires() {
        var window = PairingWindow()
        let secret = window.open(at: t0)
        let proof = PairingProof.make(secret: secret, exporter: exporter, device: phone.fingerprint)
        let late = t0.addingTimeInterval(PairingWindow.lifetime + 1)
        XCTAssertFalse(window.redeem(proof, exporter: exporter, device: phone.fingerprint, at: late))
    }

    /// A stranger guessing must not be able to shut the real phone out.
    func testABadProofLeavesTheWindowOpenForTheRightOne() {
        var window = PairingWindow()
        let secret = window.open(at: t0)
        let guess = PairingProof.make(secret: PairingProof.newSecret(), exporter: exporter, device: stranger.fingerprint)
        XCTAssertFalse(window.redeem(guess, exporter: exporter, device: stranger.fingerprint, at: t0))
        let proof = PairingProof.make(secret: secret, exporter: exporter, device: phone.fingerprint)
        XCTAssertTrue(window.redeem(proof, exporter: exporter, device: phone.fingerprint, at: t0))
    }

    /// Showing a new code makes the old one worthless.
    func testReopeningReplacesTheSecret() {
        var window = PairingWindow()
        let old = window.open(at: t0)
        _ = window.open(at: t0)
        let proof = PairingProof.make(secret: old, exporter: exporter, device: phone.fingerprint)
        XCTAssertFalse(window.redeem(proof, exporter: exporter, device: phone.fingerprint, at: t0))
    }

    // MARK: - Who a trust socket is

    func testEveryHelloIsRewrittenToTheProvenKey() {
        let proven = phone.fingerprint.description
        let messages: [ClientMessage] = [
            .hello(HelloPayload(deviceName: "p", deviceID: "claimed")),
            .viewHello(ViewHelloPayload(deviceName: "p", deviceID: "claimed", maxWidth: 100, maxHeight: 100)),
            .listenHello(ListenHelloPayload(deviceName: "p", deviceID: "claimed")),
            .uploadHello(AttachmentManifest(deviceName: "p", deviceID: "claimed", targetIDs: ["t"],
                                            text: "", submit: false, count: 1)),
            .stillHello(StillRequest(deviceName: "p", deviceID: "claimed", targetID: "t")),
        ]
        for message in messages {
            let data = try! NimletCoder.line(message.claiming(deviceID: proven))
            let text = String(decoding: data, as: UTF8.self)
            XCTAssertFalse(text.contains("claimed"), "\(text) still names the claimed id")
            XCTAssertTrue(text.contains(proven), "\(text) does not name the proven key")
        }
    }

    func testOtherMessagesAreUntouched() {
        guard case .move(let dx, let dy) = ClientMessage.move(dx: 1, dy: 2).claiming(deviceID: "x") else {
            return XCTFail("a move stopped being a move")
        }
        XCTAssertEqual(dx, 1)
        XCTAssertEqual(dy, 2)
    }

    // MARK: - The wire

    func testPairingMessagesRoundTrip() throws {
        let request = ClientMessage.pair(PairRequest(proof: Data([1, 2, 3]), deviceName: "Phone"))
        guard case .pair(let decoded) = try NimletCoder.decode(ClientMessage.self, from: NimletCoder.line(request)) else {
            return XCTFail("not a pair")
        }
        XCTAssertEqual(decoded.proof, Data([1, 2, 3]))
        let result = HostMessage.pairResult(PairResult(ok: false, message: "expired"))
        guard case .pairResult(let answer) = try NimletCoder.decode(HostMessage.self, from: NimletCoder.line(result)) else {
            return XCTFail("not a pair result")
        }
        XCTAssertEqual(answer, PairResult(ok: false, message: "expired"))
    }
}

/// What the pairing-code listener refuses: a device id only a key can prove.
final class ClaimedDeviceIDTests: XCTestCase {
    func testTheFiveHellosNameTheirDeviceAndNothingElseDoes() {
        XCTAssertEqual(ClientMessage.hello(HelloPayload(deviceName: "p", deviceID: "a")).claimedDeviceID, "a")
        XCTAssertEqual(ClientMessage.stillHello(StillRequest(deviceName: "p", deviceID: "b", targetID: "t")).claimedDeviceID, "b")
        XCTAssertNil(ClientMessage.move(dx: 1, dy: 1).claimedDeviceID)
    }

    /// The test the listener applies: a phone's UUID never looks like a key,
    /// and a key's fingerprint always does.
    func testAUUIDIsNeverMistakenForAKeyAndAFingerprintAlwaysIs() throws {
        XCTAssertNil(TrustFingerprint(UUID().uuidString))
        XCTAssertNil(TrustFingerprint("legacy:iPhone"))
        let key = try TrustIdentity(privateKey: P256.Signing.PrivateKey())
        XCTAssertNotNil(TrustFingerprint(key.fingerprint.description))
    }
}
