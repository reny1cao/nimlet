import XCTest

/// Switching window or app from the phone takes the Mac's pointer with it.
///
/// What is being tested is where the pointer is allowed to end up. The rest of
/// that path — Accessibility raising a window, a `CGEvent` moving the cursor —
/// needs a Mac with windows on it; this is the part that decides, and it is the
/// part that can be wrong on somebody's second monitor.
final class PointerLandingTests: XCTestCase {

    private let screen = CGRect(x: 0, y: 0, width: 1728, height: 1117)

    // MARK: - Moving, and not moving

    func testThePointerGoesToTheMiddleOfTheWindowItWasNotIn() {
        let window = CGRect(x: 200, y: 100, width: 800, height: 600)
        let landing = PointerLanding.landing(in: window,
                                             pointer: CGPoint(x: 1700, y: 1100),
                                             screens: [screen])
        XCTAssertEqual(landing, CGPoint(x: 600, y: 400))
    }

    func testAPointerAlreadyInThatWindowIsLeftAlone() {
        let window = CGRect(x: 200, y: 100, width: 800, height: 600)
        // Tapping the tile for the app you are already working in must not yank
        // the cursor out from under the hand about to use it.
        XCTAssertNil(PointerLanding.landing(in: window,
                                            pointer: CGPoint(x: 210, y: 590),
                                            screens: [screen]))
    }

    func testAWindowWithNoAreaIsNotSomewhereToPutACursor() {
        XCTAssertNil(PointerLanding.landing(in: CGRect(x: 40, y: 40, width: 0, height: 0),
                                            pointer: CGPoint(x: 900, y: 900),
                                            screens: [screen]))
    }

    // MARK: - Windows that hang off a screen

    func testTheLandingIsInsideTheScreenWhenTheWindowIsNot() {
        // Half off the left edge: the window's own middle is at x = -100, which
        // is nowhere a cursor can be.
        let window = CGRect(x: -500, y: 200, width: 800, height: 400)
        guard let landing = PointerLanding.landing(in: window,
                                                  pointer: CGPoint(x: 1700, y: 1100),
                                                  screens: [screen]) else {
            return XCTFail("a window that is 300 points on screen can be pointed into")
        }
        XCTAssertEqual(landing, CGPoint(x: 150, y: 400))
        XCTAssertTrue(screen.contains(landing), "the pointer cannot go off the display")
        XCTAssertTrue(window.contains(landing), "and it has to land in the window")
    }

    func testAWindowOnANeighbouringDisplayIsReachedThere() {
        // A second display to the left of the built-in one, which is where a
        // negative origin comes from.
        let secondary = CGRect(x: -1920, y: -200, width: 1920, height: 1080)
        let window = CGRect(x: -1400, y: 0, width: 600, height: 400)
        let landing = PointerLanding.landing(in: window,
                                             pointer: CGPoint(x: 800, y: 500),
                                             screens: [screen, secondary])
        XCTAssertEqual(landing, CGPoint(x: -1100, y: 200))
    }

    func testAWindowSpanningTwoDisplaysLandsOnTheDisplayShowingMostOfIt() {
        let secondary = CGRect(x: 1728, y: 0, width: 1920, height: 1080)
        // 200 points on the built-in display, 600 on the second one.
        let window = CGRect(x: 1528, y: 300, width: 800, height: 400)
        guard let landing = PointerLanding.landing(in: window,
                                                  pointer: CGPoint(x: 10, y: 10),
                                                  screens: [screen, secondary]) else {
            return XCTFail("a window across two displays can still be pointed into")
        }
        XCTAssertEqual(landing, CGPoint(x: 2028, y: 500))
        XCTAssertTrue(secondary.contains(landing))
    }

    func testAWindowNoDisplayIsShowingIsLeftAlone() {
        // Entirely off the arrangement — a window dragged to a display that has
        // since been unplugged. Moving the pointer to it would park the cursor
        // somewhere it cannot be seen, which is the complaint this exists to fix.
        XCTAssertNil(PointerLanding.landing(in: CGRect(x: 4000, y: 4000, width: 600, height: 400),
                                            pointer: CGPoint(x: 800, y: 500),
                                            screens: [screen]))
    }

    func testWithNoDisplayListTheWindowsOwnMiddleIsUsed() {
        // `CGGetActiveDisplayList` failing says something is wrong with the
        // display query, not with the window, and refusing to move the pointer
        // would be the wrong thing to conclude from it.
        let landing = PointerLanding.landing(in: CGRect(x: 100, y: 100, width: 400, height: 200),
                                             pointer: CGPoint(x: 900, y: 900),
                                             screens: [])
        XCTAssertEqual(landing, CGPoint(x: 300, y: 200))
    }
}
