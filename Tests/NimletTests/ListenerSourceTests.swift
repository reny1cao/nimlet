import XCTest

/// Who the two LAN listeners answer at all. See `PortMapWire.isLocalSource`,
/// `HostServer.accept` and the "Three listeners" section of SECURITY.md.
final class ListenerSourceTests: XCTestCase {

    private let mine = ["2001:db8:1:2::10"]

    func testTheLANListenersTakeThisNetworkAndRefuseTheInternet() {
        for local in ["127.0.0.1", "::1", "192.168.0.7", "10.1.2.3", "172.16.5.5", "169.254.1.1",
                      "fe80::1", "fd00::5", "::ffff:192.168.0.7", "2001:db8:1:2:aaaa:bbbb:cccc:dddd"] {
            XCTAssertTrue(PortMapWire.isLocalSource(local, allowingOverlay: false, mine: mine), local)
            XCTAssertTrue(PortMapWire.isLocalSource(local, allowingOverlay: true, mine: mine), local)
        }
        // A global address that is not on one of this Mac's own prefixes: the
        // trust and code ports are not where the internet comes in.
        for remote in ["8.8.8.8", "203.0.113.9", "2001:4860:4860::8888", "2001:db8:1:3::10",
                       "::ffff:8.8.8.8", "", "not an address"] {
            XCTAssertFalse(PortMapWire.isLocalSource(remote, allowingOverlay: true, mine: mine), remote)
            XCTAssertFalse(PortMapWire.isLocalSource(remote, allowingOverlay: false, mine: mine), remote)
        }
    }

    /// A tailnet peer reaches the trust listener, which pins keys, and not
    /// the pairing-code listener, which is thirty bits behind a throttle.
    func testAnOverlayPeerReachesTheTrustListenerAndNotTheCodeListener() {
        for overlay in ["100.101.102.103", "100.127.0.1", "fd7a:115c:a1e0::1234:5678"] {
            XCTAssertTrue(PortMapWire.isLocalSource(overlay, allowingOverlay: true, mine: mine), overlay)
            XCTAssertFalse(PortMapWire.isLocalSource(overlay, allowingOverlay: false, mine: mine), overlay)
        }
    }

    /// The relay's pump arrives from loopback, and loopback is nobody to
    /// throttle: the phone behind it is what the bridge records.
    func testARelayedSocketIsKnownByThePhoneBehindItOrNotAtAll() {
        XCTAssertNil(RelayLink.phoneAddress(forLocalPort: 1), "nothing recorded for a port no bridge has dialled from")
    }
}
