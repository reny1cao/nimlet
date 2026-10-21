import XCTest

/// The two curves that decide how far a finger goes.
///
/// Both of them are a feel expressed as arithmetic, which is the kind of thing
/// that gets retuned by whoever is annoyed that week and quietly stops being
/// what it was. What is pinned here is not the constants — those are meant to be
/// adjusted — but the claims the constants exist to make: that slow is precise,
/// that fast crosses a display, that the curve never inverts, and that a flick
/// coasts about as far as the comment above it says.
final class ScrollAndPointerFeelTests: XCTestCase {

    // MARK: - The pointer

    /// The complaint this was written for: five swipes from the left of the pad
    /// to the bottom right of the Mac.
    ///
    /// A 1512×982 display is 1800 points corner to corner. A brisk flick — 200
    /// points of pad at about 1100 points per second, which is what a thumb
    /// actually does — has to be worth most of that, or the pad is a rowing
    /// machine.
    func testAFlickCrossesMostOfADisplay() {
        var accelerator = PointerAccelerator()
        let travel = 200.0
        let speed = 1100.0
        var moved = 0.0
        // Sixty frames' worth, which is about what 200 points at that speed take.
        let frames = Int((travel / speed) * 120)
        let perFrame = travel / Double(frames)
        for _ in 0..<frames {
            let delta = accelerator.accelerate(delta: CGPoint(x: perFrame, y: 0),
                                              dt: perFrame / speed)
            moved += Double(delta.x)
        }
        XCTAssertGreaterThan(moved, 1000, "one flick has to be worth most of a display")
        XCTAssertLessThan(moved, 2600, "and not so much that it lands off the far edge")
    }

    /// The other half of the bargain: a deliberate nudge still lands on a small
    /// target. 20 points of pad, moved slowly, must not become 60 points of
    /// screen — a close button is 12 across.
    func testASlowNudgeStaysNearlyOneToOne() {
        var accelerator = PointerAccelerator()
        var moved = 0.0
        for _ in 0..<20 {
            let delta = accelerator.accelerate(delta: CGPoint(x: 1, y: 0), dt: 1.0 / 120.0)
            moved += Double(delta.x)
        }
        XCTAssertLessThan(moved, 34, "slow movement is where precision comes from")
        XCTAssertGreaterThan(moved, 20, "and it should not be slower than the finger")
    }

    func testTheCurveNeverTurnsBackOnItself() {
        let accelerator = PointerAccelerator()
        var previous = 0.0
        for speed in stride(from: 0.0, through: 4000.0, by: 50.0) {
            let gain = accelerator.gain(atSpeed: speed)
            XCTAssertGreaterThanOrEqual(gain, previous, "gain fell going from under \(speed)")
            previous = gain
        }
    }

    func testGainIsCappedSoAFlickCannotFlingThePointerAnywhere() {
        let accelerator = PointerAccelerator()
        let ceiling = accelerator.gain(atSpeed: 100_000)
        XCTAssertEqual(accelerator.gain(atSpeed: 8000), ceiling, accuracy: 0.0001)
        XCTAssertLessThan(ceiling, 16)
    }

    /// The knee has to sit where fingers are, which was the whole bug: the old
    /// curve reached full strength at 3900 points per second and no thumb on a
    /// phone produces that, so its ceiling was decoration.
    func testMostOfTheRangeIsEarnedAtSpeedsAThumbReaches() {
        let accelerator = PointerAccelerator()
        let ceiling = accelerator.gain(atSpeed: 100_000)
        XCTAssertGreaterThan(accelerator.gain(atSpeed: 1200) / ceiling, 0.4,
                             "a real flick should be well into the range, not at the bottom of it")
    }

    // MARK: - The strip

    func testASlowDragIsNearOneToOneAndAFlickIsWorthScreens() {
        var gearing = ScrollGearing()
        XCTAssertLessThan(gearing.scale(atSpeed: 150), 2.0)
        XCTAssertGreaterThan(gearing.scale(atSpeed: 1400), 5.0)

        // 120 points of thumb, dragged slowly: a few lines, not a page.
        var slow = 0.0
        for _ in 0..<120 {
            slow += Double(gearing.geared(delta: CGPoint(x: 0, y: 1), dt: 1.0 / 120.0).y)
        }
        XCTAssertLessThan(slow, 320)
        XCTAssertGreaterThan(slow, 120)
    }

    func testAFingerMovingDownScrollsTheContentDown() {
        var gearing = ScrollGearing()
        let down = gearing.geared(delta: CGPoint(x: 0, y: 8), dt: 1.0 / 120.0)
        XCTAssertGreaterThan(down.y, 0, "natural scrolling: the content follows the finger")
        gearing.reset()
        let right = gearing.geared(delta: CGPoint(x: 8, y: 0), dt: 1.0 / 120.0)
        XCTAssertLessThan(right.x, 0, "and sideways keeps the sign the Mac was always sent")
    }

    // MARK: - The coast

    func testAThumbSettlingOnTheGlassDoesNotLaunchAFlick() {
        let coast = ScrollCoast()
        XCTAssertFalse(coast.launches(atSpeed: 40))
        XCTAssertFalse(coast.launches(atSpeed: 280))
        XCTAssertTrue(coast.launches(atSpeed: 1800))
    }

    /// Simulated at 120Hz, the way the display link drives it: the coast has to
    /// end, has to end soon, and has to be worth about what the comment on
    /// `retentionPerSecond` promises.
    func testAFlickCoastsAboutOnceAndThenStops() {
        let coast = ScrollCoast()
        var velocity = coast.launchVelocity(CGPoint(x: 0, y: 3000))
        var travelled = 0.0
        var elapsed = 0.0
        let dt = 1.0 / 120.0
        while !coast.hasStopped(velocity), elapsed < 10 {
            travelled += Double(velocity.y) * dt
            velocity = coast.decayed(velocity, over: dt)
            elapsed += dt
        }
        XCTAssertLessThan(elapsed, 2.0, "a coast nobody can interrupt is a coast nobody wants")
        XCTAssertGreaterThan(elapsed, 0.6, "and stopping dead is what this exists to fix")
        XCTAssertGreaterThan(travelled, 600)
        XCTAssertLessThan(travelled, 2000)
    }

    func testNothingLeavesTheStripFasterThanTheCeiling() {
        let coast = ScrollCoast()
        let launched = coast.launchVelocity(CGPoint(x: 0, y: 90_000))
        XCTAssertEqual(Double(launched.y), coast.maximumSpeed, accuracy: 0.001)
        // And a velocity inside the ceiling is left exactly as it was, diagonal
        // included: clamping the magnitude must not bend the direction.
        let gentle = CGPoint(x: 300, y: -400)
        XCTAssertEqual(coast.launchVelocity(gentle), gentle)
    }

    func testDecayIsIndependentOfTheFrameRate() {
        let coast = ScrollCoast()
        let start = CGPoint(x: 0, y: 4000)
        var at60 = start
        for _ in 0..<60 { at60 = coast.decayed(at60, over: 1.0 / 60.0) }
        var at120 = start
        for _ in 0..<120 { at120 = coast.decayed(at120, over: 1.0 / 120.0) }
        XCTAssertEqual(Double(at60.y), Double(at120.y), accuracy: 1,
                       "a ProMotion phone must not coast further than a 60Hz one")
    }

    // MARK: - The strip's geometry

    /// Drawn in one place and touched in another is the failure mode the shared
    /// definition exists to prevent, so the numbers get pinned.
    func testTheStripReachesTheTrailingEdgeAndThePadBleedsPastIt() {
        let card = CGSize(width: 360, height: 600)
        let plain = ScrollStripGeometry.rect(in: card)
        XCTAssertEqual(plain.maxX, card.width)
        XCTAssertEqual(plain.width, ScrollStripGeometry.touchWidth)
        XCTAssertEqual(plain.height, card.height)

        let bled = ScrollStripGeometry.rect(in: card, bleed: 14)
        XCTAssertEqual(bled.minX, plain.minX, "the bleed adds reach, it does not move the strip")
        XCTAssertEqual(bled.maxX, card.width + 14)
    }

    func testASurfaceTooNarrowToSpareAStripDoesNotGetOne() {
        XCTAssertEqual(ScrollStripGeometry.rect(in: CGSize(width: 80, height: 600)), .zero)
        XCTAssertEqual(ScrollStripGeometry.rect(in: CGSize(width: 360, height: 0)), .zero)
    }

    /// The ink has to mark the edge it is telling you about. Centred in its own
    /// target — which is what it was — it pointed 20 points inside the card.
    func testTheInkSitsAtTheEdgeRatherThanInTheMiddleOfItsTarget() {
        XCTAssertLessThan(ScrollStripGeometry.edge, ScrollStripGeometry.touchWidth / 4)
    }
}
