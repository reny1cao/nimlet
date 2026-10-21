import XCTest

/// Version negotiation happens in the Bonjour TXT record, before TLS, because
/// a mismatch discovered afterwards reads as a refused key.
final class ProtocolVersionTests: XCTestCase {

    func testTheVersionIsTheOneBothEndsWereBuiltAgainst() {
        XCTAssertEqual(NimletProtocol.version, 28)
    }

    /// Both ends are built from the same tree, so they must agree exactly.
    func testOnlyTheSameVersionIsServed() {
        XCTAssertTrue(NimletProtocol.supports(clientVersion: NimletProtocol.version))
        XCTAssertFalse(NimletProtocol.supports(clientVersion: NimletProtocol.version - 1))
        XCTAssertFalse(NimletProtocol.supports(clientVersion: NimletProtocol.version + 1))
    }

    func testTheTXTKeysBothEndsReadAreTheOnesTheHostPublishes() {
        XCTAssertEqual(NimletProtocol.txtVersionKey, "v")
        XCTAssertEqual(NimletProtocol.txtHostKey, "host")
        XCTAssertEqual(NimletProtocol.bonjourType, "_mice._tcp")
        XCTAssertEqual(NimletProtocol.trustBonjourType, "_nimlet._tcp")
    }
}
