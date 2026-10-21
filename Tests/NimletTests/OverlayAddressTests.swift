import XCTest

final class OverlayAddressTests: XCTestCase {
    func testOnlyActiveTunnelCandidatesQualify() {
        XCTAssertTrue(OverlayAddress.isAdvertisable(host: "100.101.102.103", interface: "utun4"))
        XCTAssertTrue(OverlayAddress.isAdvertisable(host: "fd7a:115c:a1e0::1234", interface: "utun4"))
        XCTAssertFalse(OverlayAddress.isAdvertisable(host: "100.101.102.103", interface: "en0"))
        XCTAssertFalse(OverlayAddress.isAdvertisable(host: "10.1.2.3", interface: "utun4"))
        XCTAssertFalse(OverlayAddress.contains("100.63.255.255"))
        XCTAssertFalse(OverlayAddress.contains("100.128.0.1"))
        XCTAssertFalse(OverlayAddress.contains("fd7a:115c:a1e1::1"))
        XCTAssertFalse(OverlayAddress.contains("mac.local"))
    }

    func testLANBeforeVPNBeforePublicRoutesAndWireCompatibility() throws {
        let vpn = NimletCandidate(host: "100.101.102.103", port: 61413, reach: .local, via: "VPN")
        let lan = NimletCandidate(host: "192.168.1.2", port: 61413, reach: .local, via: "this network")
        let wan = NimletCandidate(host: "203.0.113.1", port: 61423, reach: .forwarded4, via: "PCP")
        XCTAssertEqual(CandidateOrder.sorted([wan, vpn, lan]), [lan, vpn, wan])
        XCTAssertFalse(vpn.isRemote, "a VPN address is dialled like the LAN: the trust listener, with peer-to-peer on")
        let data = try NimletCoder.line(vpn)
        XCTAssertEqual(try NimletCoder.decode(NimletCandidate.self, from: data), vpn)
    }
}
