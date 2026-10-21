import XCTest

final class ProAccessPolicyTests: XCTestCase {
    func testFreeAllowsLANButRejectsEveryRemoteTransport() {
        XCTAssertTrue(ProAccessPolicy.allows(route: .lan, hasPro: false))
        for route in [RoutePolicy.RouteClass.direct, .relayDatagram, .relay] {
            XCTAssertFalse(ProAccessPolicy.allows(route: route, hasPro: false))
            XCTAssertTrue(ProAccessPolicy.allows(route: route, hasPro: true))
        }
    }

    func testVPNCannotMasqueradeAsLocalReach() {
        let lan = NimletCandidate(host: "192.168.1.20", port: 61413, reach: .local, via: "this network")
        let tailscale = NimletCandidate(host: "100.64.12.34", port: 61413, reach: .local, via: "VPN")
        let privateVPN = NimletCandidate(host: "10.1.2.3", port: 61413, reach: .local, via: "VPN")
        let publicLocal = NimletCandidate(host: "203.0.113.1", port: 61413, reach: .local, via: "manual")
        XCTAssertTrue(ProAccessPolicy.allows(candidate: lan, offLAN: false, hasPro: false))
        XCTAssertFalse(ProAccessPolicy.allows(candidate: lan, offLAN: true, hasPro: false))
        for candidate in [tailscale, privateVPN, publicLocal] {
            XCTAssertFalse(ProAccessPolicy.allows(candidate: candidate, offLAN: false, hasPro: false))
            XCTAssertTrue(ProAccessPolicy.allows(candidate: candidate, offLAN: true, hasPro: true))
        }
    }

    func testSingleTargetInputIsProAndPointerRemainsFree() {
        XCTAssertTrue(ProAccessPolicy.requiresPro(.text(TextPayload(text: "one target", targetID: "app")), targets: []))
        XCTAssertTrue(ProAccessPolicy.requiresPro(.requestWindows(targetID: "app"), targets: []))
        XCTAssertFalse(ProAccessPolicy.requiresPro(.move(dx: 4, dy: 1), targets: []))
        XCTAssertFalse(ProAccessPolicy.requiresPro(.scroll(dx: 0, dy: 3), targets: []))
        XCTAssertFalse(ProAccessPolicy.requiresPro(.click(button: .left, phase: .click, clickCount: 1), targets: []))
    }

    func testOnlyAppSwitchingIsFreeAndUnknownTargetsFailClosed() {
        let app = NimletTarget(id: "app", name: "Editor", kind: .app)
        let terminal = NimletTarget(id: "pane", name: "Agent", kind: .tmux)
        XCTAssertFalse(ProAccessPolicy.requiresPro(.focus(targetID: "app"), targets: [app, terminal]))
        XCTAssertTrue(ProAccessPolicy.requiresPro(.focus(targetID: "pane"), targets: [app, terminal]))
        XCTAssertTrue(ProAccessPolicy.requiresPro(.focus(targetID: "missing"), targets: [app, terminal]))
    }

    func testDenyAndSettingsRemainAvailableWithoutUpgrade() {
        XCTAssertFalse(ProAccessPolicy.requiresPro(.approvalDecision(id: "r", decision: .deny, reason: nil), targets: []))
        XCTAssertTrue(ProAccessPolicy.requiresPro(.approvalDecision(id: "r", decision: .approve, reason: nil), targets: []))
        XCTAssertFalse(ProAccessPolicy.requiresPro(.removeTarget(id: "a"), targets: []))
        XCTAssertFalse(ProAccessPolicy.requiresPro(.reorderTargets(ids: ["a"]), targets: []))
        XCTAssertFalse(ProAccessPolicy.offersUpgrade(for: .requestWindows(targetID: "a")))
    }
}
