import XCTest

final class RoutePolicyTests: XCTestCase {

    func testRouteClasses() {
        XCTAssertEqual(RoutePolicy.routeClass(reach: .local, isOverlay: false), .lan)
        XCTAssertEqual(RoutePolicy.routeClass(reach: .local, isOverlay: true), .direct, "a VPN address is not this network")
        XCTAssertEqual(RoutePolicy.routeClass(reach: .internet6, isOverlay: false), .direct)
        XCTAssertEqual(RoutePolicy.routeClass(reach: .forwarded4, isOverlay: false), .direct)
        XCTAssertEqual(RoutePolicy.routeClass(reach: .relay, isOverlay: false), .relay)
    }

    /// The bug: a relay success the night before was dialled first at the desk.
    func testARelaySuccessIsPromotedOnlyOffTheLAN() {
        XCTAssertFalse(RoutePolicy.mayPromote(.relay, offLAN: false))
        XCTAssertTrue(RoutePolicy.mayPromote(.relay, offLAN: true))
        XCTAssertTrue(RoutePolicy.mayPromote(.direct, offLAN: false))
        XCTAssertTrue(RoutePolicy.mayPromote(.lan, offLAN: false))
    }

    func testABetterClassWinsUnlessItIsClearlySlower() {
        // Measured 2026-10-05: the relay from Shanghai is ~500 ms; a LAN is ~5.
        XCTAssertTrue(RoutePolicy.shouldMigrate(from: .relay, roundTrip: 0.5, to: .lan, roundTrip: 0.005))
        XCTAssertTrue(RoutePolicy.shouldMigrate(from: .relay, roundTrip: 0.5, to: .direct, roundTrip: 0.04))
        // A VPN relaying through its own servers can be worse than our relay.
        XCTAssertFalse(RoutePolicy.shouldMigrate(from: .relay, roundTrip: 0.2, to: .direct, roundTrip: 0.35))
        // Never to a worse class, however quick it looks.
        XCTAssertFalse(RoutePolicy.shouldMigrate(from: .lan, roundTrip: 0.05, to: .relay, roundTrip: 0.01))
        // Unmeasured: a better class is enough.
        XCTAssertTrue(RoutePolicy.shouldMigrate(from: .relay, roundTrip: nil, to: .direct, roundTrip: 0.3))
    }

    func testTheSameClassNeedsAClearWinSoRoutesDoNotFlap() {
        XCTAssertFalse(RoutePolicy.shouldMigrate(from: .direct, roundTrip: 0.050, to: .direct, roundTrip: 0.045))
        XCTAssertFalse(RoutePolicy.shouldMigrate(from: .direct, roundTrip: 0.050, to: .direct, roundTrip: 0.030))
        XCTAssertTrue(RoutePolicy.shouldMigrate(from: .direct, roundTrip: 0.200, to: .direct, roundTrip: 0.040))
    }

    func testASwitchWaitsForHeldButtonsAndOrderedInputButNotForMoves() {
        XCTAssertFalse(RoutePolicy.isQuietForSwitch(buttonsHeld: true, sinceOrderedInput: 60, roundTrip: 0.05))
        // A click 400 ms ago on a 500 ms relay may still be on its way.
        XCTAssertFalse(RoutePolicy.isQuietForSwitch(buttonsHeld: false, sinceOrderedInput: 0.4, roundTrip: 0.5))
        XCTAssertTrue(RoutePolicy.isQuietForSwitch(buttonsHeld: false, sinceOrderedInput: 0.8, roundTrip: 0.5))
        XCTAssertTrue(RoutePolicy.isQuietForSwitch(buttonsHeld: false, sinceOrderedInput: 0.31, roundTrip: 0.01))
    }

    /// Through the relay a queued pong is not a dead socket.
    func testAwayRoutesWaitLongerBeforeDeclaringASocketDead() {
        XCTAssertEqual(RoutePolicy.pongTimeout(for: .lan), 3)
        XCTAssertEqual(RoutePolicy.pongTimeout(for: .relay), 8)
        XCTAssertEqual(RoutePolicy.healthCheckTimeout(for: .lan), 2)
        XCTAssertEqual(RoutePolicy.healthCheckTimeout(for: .direct), 6)
        XCTAssertLessThan(RoutePolicy.pongTimeout(for: .relay), 12, "still inside the idle timeout")
    }

    /// The relay over UDP is better than the relay over TCP, and a direct
    /// path is better than either.
    func testTheUDPRelaySitsBetweenDirectAndTheTCPRelay() {
        XCTAssertLessThan(RoutePolicy.RouteClass.direct, .relayDatagram)
        XCTAssertLessThan(RoutePolicy.RouteClass.relayDatagram, .relay)
        // Same round trip, better class: worth moving to.
        XCTAssertTrue(RoutePolicy.shouldMigrate(from: .relay, roundTrip: 0.5, to: .relayDatagram, roundTrip: 0.5))
        XCTAssertTrue(RoutePolicy.shouldMigrate(from: .relayDatagram, roundTrip: 0.5, to: .direct, roundTrip: 0.08))
        XCTAssertFalse(RoutePolicy.shouldMigrate(from: .direct, roundTrip: 0.08, to: .relayDatagram, roundTrip: 0.01))
    }

    func testLooksBackOffButNeverStop() {
        XCTAssertEqual(RoutePolicy.upgradeDelay(attempt: 0), 15)
        XCTAssertEqual(RoutePolicy.upgradeDelay(attempt: 1), 30)
        XCTAssertEqual(RoutePolicy.upgradeDelay(attempt: 10), 120)
    }

    func testLinkStatsReportMedianAndP95OfMeasuredRoundTrips() {
        var stats = LinkStats()
        XCTAssertNil(stats.roundTripSummary)
        (1...100).forEach { stats.add(roundTripMillis: Double($0)) }
        XCTAssertEqual(stats.median ?? 0, 51, accuracy: 1)
        XCTAssertEqual(stats.p95 ?? 0, 95, accuracy: 1)
        (1...200).forEach { _ in stats.add(roundTripMillis: 7) }
        XCTAssertEqual(stats.roundTrips.count, LinkStats.window)
        XCTAssertEqual(stats.median, 7)
    }
}
