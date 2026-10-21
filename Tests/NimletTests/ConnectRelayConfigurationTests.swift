import XCTest

final class ConnectRelayConfigurationTests: XCTestCase {
    private let pin = "izGBsllCGvtxspZCF_dziNghI46QQbox29eknNGN83w"
    private var builtIn: [String: Any] {
        ["MiceConnectRelay": "relay.example:7443", "MiceConnectRelayFingerprint": pin]
    }

    func testFreshInstallUsesReleaseAddressAndPin() {
        let value = ConnectRelayConfiguration.resolve(preferences: [:], bundle: builtIn)
        XCTAssertEqual(value?.address, "relay.example:7443")
        XCTAssertEqual(value?.fingerprint, TrustFingerprint(pin))
    }

    func testPlainCheckoutDoesNotConfigureRemoteService() {
        XCTAssertNil(ConnectRelayConfiguration.resolve(preferences: [:], bundle: [:]))
        XCTAssertNil(ConnectRelayConfiguration.resolve(preferences: [:], bundle: ["MiceConnectRelay": " \n"]))
    }

    func testCustomRelayCannotInheritReleasePin() {
        let value = ConnectRelayConfiguration.resolve(preferences: ["mice.relay": "other.example:7443"], bundle: builtIn)
        XCTAssertEqual(value?.address, "other.example:7443")
        XCTAssertNil(value?.fingerprint)
    }

    func testInvalidCustomPinFailsClosed() {
        let value = ConnectRelayConfiguration.resolve(preferences: ["mice.relay": "other.example:7443", "mice.relayFingerprint": "bad"], bundle: builtIn)
        XCTAssertNil(value?.fingerprint)
    }

    func testOrphanedPreferencePinCannotReplaceReleasePin() {
        let value = ConnectRelayConfiguration.resolve(preferences: ["mice.relayFingerprint": "bad"], bundle: builtIn)
        XCTAssertEqual(value?.fingerprint, TrustFingerprint(pin))
    }
}
