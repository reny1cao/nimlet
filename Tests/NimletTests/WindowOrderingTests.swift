import XCTest

/// Which of an app's windows the mirror follows, and the order the shelf
/// shows them in.
final class WindowOrderingTests: XCTestCase {

    private func window(_ id: UInt32, front: Bool = false, minimised: Bool = false,
                        width: Int = 800, canRaise: Bool = true) -> MacWindow {
        MacWindow(id: id, title: "ChatGPT", appName: "Codex", isMinimized: minimised,
                  isOnScreen: !minimised, isFrontmost: front, width: width, height: 600,
                  canRaise: canRaise)
    }

    // MARK: - The shelf

    func testTheShelfIsInTheOrderTheWindowsWereOpened() {
        let shelf = WindowOrdering.shelf([window(40, front: true, width: 400),
                                          window(12, width: 1600),
                                          window(31, minimised: true)])
        XCTAssertEqual(shelf.map(\.id), [12, 31, 40])
    }

    func testBringingAWindowForwardDoesNotMoveItsCard() {
        // The window in front, and the biggest, used to lead. Switching to a
        // window must not change where any card is.
        let before = WindowOrdering.shelf([window(12, front: true), window(31), window(40, width: 1600)])
        let after = WindowOrdering.shelf([window(12), window(31, front: true), window(40, width: 1600)])
        XCTAssertEqual(before.map(\.id), after.map(\.id))
    }

    func testAWindowThatCannotBeRaisedGoesLast() {
        let shelf = WindowOrdering.shelf([window(5, canRaise: false), window(12), window(31)])
        XCTAssertEqual(shelf.map(\.id), [12, 31, 5])
    }

    // MARK: - Following the app

    private func candidate(_ id: UInt32, onScreen: Bool = true, area: Double = 480_000) -> WindowOrdering.Candidate {
        WindowOrdering.Candidate(id: id, isOnScreen: onScreen, area: area)
    }

    func testTheWindowStackedInFrontIsFollowedEvenWhenAnotherIsBigger() {
        // Clicking a smaller window on the Mac brings it to the front; the
        // mirror used to stay on the biggest one.
        let front = WindowOrdering.front(of: [candidate(12, area: 2_000_000), candidate(31, area: 300_000)],
                                         stacking: [31, 12])
        XCTAssertEqual(front, 31)
    }

    func testWindowsOfTheSameSizeAlwaysGiveTheSameAnswer() {
        // Nothing stacked — all minimised or on another Space. The answer must
        // not depend on the order ScreenCaptureKit happened to list them in.
        let one = WindowOrdering.front(of: [candidate(31, onScreen: false), candidate(12, onScreen: false)], stacking: [])
        let two = WindowOrdering.front(of: [candidate(12, onScreen: false), candidate(31, onScreen: false)], stacking: [])
        XCTAssertEqual(one, 12)
        XCTAssertEqual(two, 12)
    }

    func testAStackedWindowBeatsOneThatIsNot() {
        let front = WindowOrdering.front(of: [candidate(12, area: 2_000_000), candidate(31)], stacking: [31])
        XCTAssertEqual(front, 31)
    }

    func testNoCandidatesIsNoWindow() {
        XCTAssertNil(WindowOrdering.front(of: [], stacking: [12]))
    }
}
