import XCTest

/// The two ways a click from the phone used to land somewhere nobody aimed it.
final class InputGuardTests: XCTestCase {

    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000)

    // MARK: - A tap on a mirror that is still switching windows

    /// The measured failure: the host refused the point because the phone was
    /// still showing the previous window, and then posted the click anyway —
    /// at wherever the cursor already was, which is the other window.
    func testAPressAfterARefusedPointIsRefused() {
        var guardian = InputGuard()
        guardian.pointed(accepted: false, at: t0)
        XCTAssertFalse(guardian.admits(.left, .down, at: t0))
    }

    /// Releases always pass the guard; the host posts one only for a button
    /// the phone holds, which a refused press never became.
    func testAReleaseIsNeverRefused() {
        var guardian = InputGuard()
        guardian.pointed(accepted: false, at: t0)
        XCTAssertTrue(guardian.admits(.left, .up, at: t0))
    }

    func testAnAtomicClickAfterARefusedPointIsRefused() {
        var guardian = InputGuard()
        guardian.pointed(accepted: false, at: t0)
        XCTAssertFalse(guardian.admits(.right, .click, at: t0))
        // The next press is judged on its own point.
        guardian.pointed(accepted: true, at: t0)
        XCTAssertTrue(guardian.admits(.left, .down, at: t0))
        XCTAssertTrue(guardian.admits(.left, .up, at: t0))
    }

    /// A mirror hold presses a third of a second after the point it began
    /// with, and nothing new is pointed in between.
    func testAHoldThatBeganOnARefusedPointIsRefused() {
        var guardian = InputGuard()
        guardian.pointed(accepted: false, at: t0)
        XCTAssertFalse(guardian.admits(.left, .down, at: t0.addingTimeInterval(0.35)))
    }

    func testAnAcceptedPointClearsTheRefusal() {
        var guardian = InputGuard()
        guardian.pointed(accepted: false, at: t0)
        guardian.pointed(accepted: true, at: t0.addingTimeInterval(0.15))
        XCTAssertTrue(guardian.admits(.left, .down, at: t0.addingTimeInterval(0.16)))
        XCTAssertTrue(guardian.admits(.left, .up, at: t0.addingTimeInterval(0.2)))
    }

    /// The trackpad steers the cursor itself; a click after a move is a click
    /// where the person put it.
    func testARelativeMoveClearsTheRefusal() {
        var guardian = InputGuard()
        guardian.pointed(accepted: false, at: t0)
        guardian.moved()
        XCTAssertTrue(guardian.admits(.left, .click, at: t0))
    }

    /// A trackpad tap has no point in front of it. Long after a refused mirror
    /// tap it means "click where the cursor is", and must not be eaten.
    func testTheRefusalRunsOut() {
        var guardian = InputGuard()
        guardian.pointed(accepted: false, at: t0)
        let later = t0.addingTimeInterval(InputGuard.refusedPointWindow + 0.01)
        XCTAssertTrue(guardian.admits(.left, .click, at: later))
    }

    /// The case that used to strand a button: a press accepted, then another
    /// refused, then the release. Eating that release left the first press
    /// held down on the Mac.
    func testTheReleaseOfAnAcceptedPressSurvivesALaterRefusal() {
        var guardian = InputGuard()
        XCTAssertTrue(guardian.admits(.left, .down, at: t0))
        guardian.pointed(accepted: false, at: t0)
        XCTAssertFalse(guardian.admits(.left, .down, at: t0))
        XCTAssertTrue(guardian.admits(.left, .up, at: t0))
    }

    func testOrdinaryClicksAreUntouched() {
        var guardian = InputGuard()
        XCTAssertTrue(guardian.admits(.left, .down, at: t0))
        XCTAssertTrue(guardian.admits(.left, .up, at: t0))
        XCTAssertTrue(guardian.admits(.left, .click, at: t0))
    }

    // MARK: - A phone that goes quiet holding a button

    func testImmediatePressAndReleaseUseTheAcceptedPointRatherThanTheOldCursor() {
        var guardian = InputGuard()
        let target = CGPoint(x: 2100, y: 420)
        guardian.pointed(accepted: true, position: target, at: t0)
        XCTAssertEqual(guardian.clickPosition(for: .down, at: t0), target)
        XCTAssertEqual(guardian.clickPosition(for: .up, at: t0), target)
        XCTAssertNil(guardian.clickPosition(for: .click, at: t0), "A later trackpad tap must use the cursor")
    }

    func testDragReleaseUsesItsLatestPointAndEachPhoneKeepsItsOwnPoint() {
        var phone = InputGuard()
        var other = InputGuard()
        let start = CGPoint(x: 120, y: 300)
        let end = CGPoint(x: 750, y: 800)
        phone.pointed(accepted: true, position: start, at: t0)
        XCTAssertEqual(phone.clickPosition(for: .down, at: t0), start)
        other.pointed(accepted: true, position: .zero, at: t0)
        phone.pointed(accepted: true, position: end, at: t0.addingTimeInterval(3))
        XCTAssertEqual(phone.clickPosition(for: .up, at: t0.addingTimeInterval(3)), end)
        XCTAssertEqual(other.clickPosition(for: .click, at: t0), .zero)
    }

    func testRelativeMovementRefusalAndIdleTimeDiscardAnOldAbsolutePoint() {
        var guardian = InputGuard()
        guardian.pointed(accepted: true, position: .zero, at: t0)
        guardian.moved()
        XCTAssertNil(guardian.clickPosition(for: .down, at: t0))
        guardian.pointed(accepted: true, position: .zero, at: t0)
        guardian.pointed(accepted: false, at: t0)
        XCTAssertNil(guardian.clickPosition(for: .up, at: t0))
        guardian.pointed(accepted: true, position: .zero, at: t0)
        XCTAssertNil(guardian.clickPosition(for: .click, at: t0.addingTimeInterval(2)))
    }

    /// The limit has to outlast the one-second ping a phone sends while it is
    /// holding something, with room for a lost one or two.
    func testSilenceIsLongerThanSeveralHeldPings() {
        XCTAssertGreaterThanOrEqual(InputGuard.silenceLimit, 3)
        XCTAssertFalse(InputGuard.isSilent(since: t0, now: t0.addingTimeInterval(2.9)))
    }

    /// And short enough to be seconds rather than TCP's minutes.
    func testSilenceIsSeconds() {
        XCTAssertLessThanOrEqual(InputGuard.silenceLimit, 6)
        XCTAssertTrue(InputGuard.isSilent(since: t0, now: t0.addingTimeInterval(InputGuard.silenceLimit + 0.1)))
    }
}
