import XCTest
import CoreGraphics

/// The arithmetic behind the mirror's zoom.
///
/// Worth testing rather than eyeballing because every way it can be wrong looks
/// almost right: a picture a few points out of place, a touch that lands next to
/// what was tapped, a pinch that slides out from under the fingers. None of
/// those announce themselves, and all of them come from these six functions
/// disagreeing with each other by a factor nobody can see.
final class MirrorFocusTests: XCTestCase {

    /// An upright phone's mirror card, and a landscape Mac window.
    private let card = CGSize(width: 402, height: 780)
    private let window = CGSize(width: 1512, height: 982)
    /// A window the card's own shape, so that both axes crop and the anchoring
    /// can be checked without the clamp at an edge deciding the answer.
    private let upright = CGSize(width: 800, height: 1600)

    func testAtRestTheWholePictureIsOnTheCard() {
        let focus = MirrorFocus()
        let visible = focus.visible(card: card, picture: window)
        XCTAssertEqual(visible.width, 1, accuracy: 0.0001)
        XCTAssertEqual(visible.height, 1, accuracy: 0.0001,
                       "at rest both axes fit — the short one with a bar, not a crop")
    }

    func testAtRestTheDrawnPictureFitsInsideTheCard() {
        let drawn = MirrorFocus().drawn(card: card, picture: window)
        XCTAssertLessThanOrEqual(drawn.width, card.width + 0.5)
        XCTAssertLessThanOrEqual(drawn.height, card.height + 0.5)
        XCTAssertEqual(drawn.width / drawn.height, window.width / window.height, accuracy: 0.001,
                       "fitted, not filled: the window keeps its own shape")
    }

    /// The one property that lets `picture` be the frames' pixels one moment and
    /// a number derived by division the next: only its shape is ever used.
    func testTheDrawingDependsOnThePicturesShapeAndNotItsUnits() {
        var focus = MirrorFocus()
        focus.zoom = 2.7
        let inPixels = focus.drawn(card: card, picture: window)
        let inPoints = focus.drawn(card: card, picture: CGSize(width: window.width / 2,
                                                              height: window.height / 2))
        XCTAssertEqual(inPixels.width, inPoints.width, accuracy: 0.001)
        XCTAssertEqual(inPixels.height, inPoints.height, accuracy: 0.001)
    }

    func testZoomingShowsLessOfThePicture() {
        var focus = MirrorFocus()
        let before = focus.visible(card: card, picture: window)
        focus.magnify(by: 3, about: CGPoint(x: 0.5, y: 0.5), card: card, picture: window)
        let after = focus.visible(card: card, picture: window)
        XCTAssertLessThan(after.width, before.width)
        XCTAssertLessThan(after.height, before.height)
    }

    /// What a pinch is: whatever is between the fingers stays between them.
    func testZoomingHoldsTheAnchorStillOnTheCard() {
        var focus = MirrorFocus()
        focus.zoom = 2
        focus.centre = CGPoint(x: 0.5, y: 0.5)
        let anchor = CGPoint(x: 0.36, y: 0.62)
        let before = focus.pointOnCard(anchor, card: card, picture: upright)
        focus.magnify(by: 1.6, about: anchor, card: card, picture: upright)
        let after = focus.pointOnCard(anchor, card: card, picture: upright)
        XCTAssertEqual(before.x, after.x, accuracy: 0.5)
        XCTAssertEqual(before.y, after.y, accuracy: 0.5)
    }

    /// The bug this was written for. A landscape window on an upright phone is
    /// letterboxed, so its vertical axis is entirely visible and the region's
    /// coordinates are offset from the glass's by the height of the bar. Holding
    /// the anchor's place *within the region* therefore moved it on the glass,
    /// by that bar, on the first frame of every pinch.
    func testZoomingALetterboxedWindowDoesNotSlideItByTheBar() {
        var focus = MirrorFocus()
        let anchor = CGPoint(x: 0.5, y: 0.5)
        let before = focus.pointOnCard(anchor, card: card, picture: window)
        focus.magnify(by: 1.3, about: anchor, card: card, picture: window)
        let after = focus.pointOnCard(anchor, card: card, picture: window)
        XCTAssertEqual(before.x, after.x, accuracy: 0.5)
        XCTAssertEqual(before.y, after.y, accuracy: 0.5)
    }

    /// And where the two cannot both be had, the edge wins: a held point is
    /// worth less than never showing past the window into black.
    func testAtTheEdgeTheClampOverrulesTheAnchor() {
        var focus = MirrorFocus()
        focus.zoom = 2
        let corner = CGPoint(x: 0.99, y: 0.99)
        focus.magnify(by: 2, about: corner, card: card, picture: upright)
        let region = focus.region(card: card, picture: upright)
        XCTAssertLessThanOrEqual(region.maxX, 1.0001)
        XCTAssertLessThanOrEqual(region.maxY, 1.0001)
    }

    func testZoomNeverGoesBelowFittedOrPastTheCeiling() {
        var focus = MirrorFocus()
        focus.magnify(by: 0.01, about: CGPoint(x: 0.5, y: 0.5), card: card, picture: window)
        XCTAssertEqual(focus.zoom, 1, accuracy: 0.0001, "fitted is as far out as it goes")
        focus.magnify(by: 1000, about: CGPoint(x: 0.5, y: 0.5), card: card, picture: window)
        XCTAssertEqual(focus.zoom, MirrorFocus.maximumZoom, accuracy: 0.0001)
    }

    func testAnAbsurdPinchFactorIsIgnoredRatherThanTrapped() {
        var focus = MirrorFocus()
        focus.zoom = 2
        focus.magnify(by: .nan, about: CGPoint(x: 0.5, y: 0.5), card: card, picture: window)
        XCTAssertEqual(focus.zoom, 2, accuracy: 0.0001)
        focus.magnify(by: 0, about: CGPoint(x: 0.5, y: 0.5), card: card, picture: window)
        XCTAssertEqual(focus.zoom, 2, accuracy: 0.0001)
    }

    func testPanningCannotShowPastTheEdgeOfThePicture() {
        var focus = MirrorFocus()
        focus.zoom = 3
        focus.pan(by: CGSize(width: 5000, height: 5000), card: card, picture: window)
        var region = focus.region(card: card, picture: window)
        XCTAssertGreaterThanOrEqual(region.minX, -0.0001)
        XCTAssertGreaterThanOrEqual(region.minY, -0.0001)
        focus.pan(by: CGSize(width: -5000, height: -5000), card: card, picture: window)
        region = focus.region(card: card, picture: window)
        XCTAssertLessThanOrEqual(region.maxX, 1.0001)
        XCTAssertLessThanOrEqual(region.maxY, 1.0001)
    }

    func testPanningFollowsTheFingersRatherThanOpposingThem() {
        var focus = MirrorFocus()
        focus.zoom = 3
        focus.centre = CGPoint(x: 0.5, y: 0.5)
        focus.pan(by: CGSize(width: 40, height: 0), card: card, picture: window)
        XCTAssertLessThan(focus.centre.x, 0.5,
                          "dragging right brings what is to the left into view")
    }

    func testTheBarsBesideAFittedPictureAreNotThePicture() {
        let focus = MirrorFocus()
        let drawn = focus.drawn(card: card, picture: window)
        let origin = focus.origin(card: card, picture: window)
        XCTAssertTrue(focus.contains(CGPoint(x: card.width / 2, y: card.height / 2),
                                     card: card, picture: window))
        XCTAssertFalse(focus.contains(CGPoint(x: card.width / 2, y: origin.y - 8),
                                      card: card, picture: window),
                       "above a letterboxed window is black, and black is not the Mac")
        XCTAssertFalse(focus.contains(CGPoint(x: card.width / 2, y: origin.y + drawn.height + 8),
                                      card: card, picture: window))
    }

    /// A touch resolved to a fraction of the window and drawn back onto the card
    /// has to land where the finger was, or the pointer is next to what was
    /// tapped and nothing says so.
    func testATouchResolvesToWhereItWasOnTheWindow() {
        var focus = MirrorFocus()
        focus.zoom = 2.4
        focus.centre = CGPoint(x: 0.4, y: 0.3)
        let touch = CGPoint(x: 210, y: 430)
        let inWindow = focus.picturePoint(at: touch, card: card, picture: window)
        let back = focus.pointOnCard(inWindow, card: card, picture: window)
        XCTAssertEqual(back.x, touch.x, accuracy: 0.5)
        XCTAssertEqual(back.y, touch.y, accuracy: 0.5)
    }

    func testAPointDraggedOffTheWindowResolvesToItsEdge() {
        let focus = MirrorFocus()
        let inWindow = focus.picturePoint(at: CGPoint(x: -400, y: -400), card: card, picture: window)
        XCTAssertEqual(inWindow.x, 0, accuracy: 0.0001)
        XCTAssertEqual(inWindow.y, 0, accuracy: 0.0001)
    }

    func testTheMirrorOpensCloseEnoughToReadAndAtTheCorner() {
        let focus = MirrorFocus.opening(card: card, picture: window)
        XCTAssertGreaterThan(focus.zoom, 1, "a fitted Mac window on a phone is not a readable one")
        XCTAssertLessThanOrEqual(focus.zoom, MirrorFocus.readingZoom + 0.0001)
        let region = focus.region(card: card, picture: window)
        XCTAssertEqual(region.minX, 0, accuracy: 0.0001, "the corner a window puts its title in")
        XCTAssertEqual(region.minY, 0, accuracy: 0.0001)
    }

    func testOpeningAPictureThatIsNotThereYetIsFittedRatherThanUndefined() {
        let focus = MirrorFocus.opening(card: card, picture: .zero)
        XCTAssertEqual(focus.zoom, 1, accuracy: 0.0001)
        XCTAssertFalse(focus.isZoomed)
    }

    func testAZeroSizedCardIsNotDividedBy() {
        let focus = MirrorFocus()
        XCTAssertFalse(focus.contains(.zero, card: .zero, picture: window))
        let visible = focus.visible(card: .zero, picture: window)
        XCTAssertEqual(visible.width, 1)
        XCTAssertEqual(visible.height, 1)
    }

}

/// When the Mac is asked for the region instead of the window.
///
/// The thresholds here were measured, not chosen, and the three separate pieces
/// of hysteresis exist because each one alone still flapped: a pinch that hovers
/// on the line, a pan of two points, and the Mac rounding a crop to whole points
/// of the window each defeat a different one of them.
final class MirrorCropTests: XCTestCase {

    private let whole = MirrorCrop.whole

    /// Half of the window in each axis: a 2x zoom.
    private func region(_ side: CGFloat, at origin: CGPoint = CGPoint(x: 0.25, y: 0.25)) -> CGRect {
        CGRect(x: origin.x, y: origin.y, width: side, height: side)
    }

    func testAModestZoomAsksForNothingBecauseTheWholeWindowAlreadyServesIt() {
        XCTAssertNil(MirrorCrop.wanted(showing: region(0.5), streaming: whole),
                     "2x is sharp from the whole-window stream, and a crop costs a keyframe")
        XCTAssertNil(MirrorCrop.wanted(showing: region(1 / 3.0), streaming: whole),
                     "3x too — this is the measurement the thresholds came from")
    }

    func testPastTheThresholdTheRegionIsAskedFor() {
        let wanted = MirrorCrop.wanted(showing: region(0.25), streaming: whole)
        XCTAssertNotNil(wanted, "4x is past where the window has the pixels")
        XCTAssertNotEqual(wanted, whole)
    }

    func testTheCropAskedForSurroundsTheRegionWithRoomToPan() {
        let showing = region(0.2)
        let wanted = MirrorCrop.wanted(showing: showing, streaming: whole)!
        XCTAssertTrue(wanted.surrounds(showing, slack: 0),
                      "a crop that does not contain what is on screen shows black")
        XCTAssertGreaterThan(wanted.width, showing.width,
                             "the margin is what makes a small pan free")
        XCTAssertEqual(wanted.midX, showing.midX, accuracy: 0.0001)
        XCTAssertEqual(wanted.midY, showing.midY, accuracy: 0.0001)
    }

    func testPanningInsideWhatIsAlreadyArrivingAsksForNothing() {
        let showing = region(0.2, at: CGPoint(x: 0.4, y: 0.4))
        let stream = MirrorCrop.wanted(showing: showing, streaming: whole)!
        let nudged = showing.offsetBy(dx: 0.01, dy: -0.01)
        XCTAssertNil(MirrorCrop.wanted(showing: nudged, streaming: stream),
                     "the margin exists precisely so this costs the capture nothing")
    }

    func testPanningOutOfWhatIsArrivingAsksForMore() {
        let showing = region(0.2, at: CGPoint(x: 0.4, y: 0.4))
        let stream = MirrorCrop.wanted(showing: showing, streaming: whole)!
        let moved = showing.offsetBy(dx: 0.3, dy: 0)
        let wanted = MirrorCrop.wanted(showing: moved, streaming: stream)
        XCTAssertNotNil(wanted)
        XCTAssertTrue(wanted!.surrounds(moved, slack: 0))
    }

    /// The Mac clamps a crop to whole points of the window and to its edges, so
    /// what arrives is never quite what was asked for. Without the slack, the
    /// difference reads as "the region is outside the crop" every frame.
    func testTheMacsOwnRoundingDoesNotReadAsHavingPannedAway() {
        let showing = region(0.2, at: CGPoint(x: 0.4, y: 0.4))
        let asked = MirrorCrop.wanted(showing: showing, streaming: whole)!
        let arrived = asked.insetBy(dx: 0.004, dy: 0.004)
        XCTAssertNil(MirrorCrop.wanted(showing: showing, streaming: arrived))
    }

    func testZoomingBackOutDropsTheCrop() {
        let stream = MirrorCrop.wanted(showing: region(0.2), streaming: whole)!
        XCTAssertEqual(MirrorCrop.wanted(showing: region(0.8), streaming: stream), whole)
    }

    /// Zooming out through the band keeps cropping. It may re-fit to the larger
    /// region on the way — what it must not do is drop to the whole window,
    /// because then pinching back in past 3.2x would crop again, which is the
    /// flap the two thresholds exist to prevent.
    func testTheBandBetweenTheTwoThresholdsDoesNotDropTheCrop() {
        let stream = MirrorCrop.wanted(showing: region(0.2), streaming: whole)!
        // 1/0.35 is 2.86: past the keep line, short of the crop line.
        let wanted = MirrorCrop.wanted(showing: region(0.35, at: CGPoint(x: 0.35, y: 0.35)),
                                       streaming: stream)
        XCTAssertNotEqual(wanted, whole)
    }

    /// And re-fitting settles in one step rather than asking again on the next
    /// frame, which would be the same flap at a different rate.
    func testRefittingInTheBandSettlesImmediately() {
        let stream = MirrorCrop.wanted(showing: region(0.2), streaming: whole)!
        let showing = region(0.35, at: CGPoint(x: 0.35, y: 0.35))
        let refitted = MirrorCrop.wanted(showing: showing, streaming: stream)!
        XCTAssertNil(MirrorCrop.wanted(showing: showing, streaming: refitted))
    }

    func testASmallPinchInsideWhatIsArrivingAsksForNothing() {
        let showing = region(0.2, at: CGPoint(x: 0.4, y: 0.4))
        let stream = MirrorCrop.wanted(showing: showing, streaming: whole)!
        // Zoomed out a little: still cropped, still inside the margin.
        let looser = CGRect(x: 0.39, y: 0.39, width: 0.24, height: 0.24)
        XCTAssertNil(MirrorCrop.wanted(showing: looser, streaming: stream))
    }

    func testACropMuchLargerThanNeededIsTightened() {
        let loose = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
        let showing = region(0.12, at: CGPoint(x: 0.4, y: 0.4))
        let wanted = MirrorCrop.wanted(showing: showing, streaming: loose)
        XCTAssertNotNil(wanted, "the point of cropping is the resolution, and this is not giving it")
        XCTAssertLessThan(wanted!.width, loose.width)
    }

    func testACropNeverLeavesTheWindow() {
        for origin in [CGPoint(x: 0, y: 0), CGPoint(x: 0.85, y: 0.85), CGPoint(x: 0, y: 0.85)] {
            let showing = region(0.15, at: origin)
            let wanted = MirrorCrop.wanted(showing: showing, streaming: whole)!
            XCTAssertGreaterThanOrEqual(wanted.minX, -0.0001, "\(origin)")
            XCTAssertGreaterThanOrEqual(wanted.minY, -0.0001, "\(origin)")
            XCTAssertLessThanOrEqual(wanted.maxX, 1.0001, "\(origin)")
            XCTAssertLessThanOrEqual(wanted.maxY, 1.0001, "\(origin)")
            XCTAssertTrue(wanted.surrounds(showing, slack: 0.0001), "\(origin)")
        }
    }

    func testAnEmptyRegionAsksForNothingRatherThanDividingByIt() {
        XCTAssertNil(MirrorCrop.wanted(showing: .zero, streaming: whole))
    }

    /// A tall strip of a wide window: one axis is fully visible, the other is
    /// not. The tighter axis is what decides, because it is the one running out
    /// of pixels.
    func testTheTighterAxisDecides() {
        let strip = CGRect(x: 0.3, y: 0, width: 0.2, height: 1)
        XCTAssertNotNil(MirrorCrop.wanted(showing: strip, streaming: whole))
    }
}

/// The zoomed tile following the Mac's pointer.
///
/// This is what makes zoom usable without a full-screen view to pan in: there is
/// no second gesture for panning a tile, so the view follows the cursor the
/// trackpad is already driving. It has to follow the way a camera does, not the
/// way a crosshair does — a view that re-centres on every twitch is a view
/// nobody can read.
final class MirrorFollowTests: XCTestCase {

    private let card = CGSize(width: 374, height: 240)
    private let window = CGSize(width: 1512, height: 982)

    private func zoomed(_ zoom: CGFloat, at centre: CGPoint = CGPoint(x: 0.5, y: 0.5)) -> MirrorFocus {
        var focus = MirrorFocus()
        focus.zoom = zoom
        focus.centre = centre
        return focus
    }

    func testAPointerComfortablyInsideMovesNothing() {
        var focus = zoomed(3)
        let before = focus
        focus.keep(CGPoint(x: 0.5, y: 0.5), inViewWithin: 0.2, card: card, picture: window)
        XCTAssertEqual(focus, before, "a twitch in the middle must not slide the picture")
    }

    func testAPointerNearAnEdgePullsTheViewAfterIt() {
        var focus = zoomed(3)
        let before = focus.region(card: card, picture: window)
        focus.keep(CGPoint(x: before.maxX - 0.001, y: 0.5), inViewWithin: 0.2, card: card, picture: window)
        let after = focus.region(card: card, picture: window)
        XCTAssertGreaterThan(after.minX, before.minX, "the view follows to the right")
    }

    /// And only far enough to put the point back on the margin — a follow that
    /// re-centres jumps the picture by half a screen every time you reach an
    /// edge.
    func testTheViewMovesOnlyAsFarAsItMustAndNoFurther() {
        var focus = zoomed(3)
        let size = focus.visible(card: card, picture: window)
        let before = focus.region(card: card, picture: window)
        let target = before.maxX
        focus.keep(CGPoint(x: target, y: 0.5), inViewWithin: 0.2, card: card, picture: window)
        let after = focus.region(card: card, picture: window)
        XCTAssertEqual(after.maxX - target, size.width * 0.2, accuracy: 0.001,
                       "the point ends up exactly on the margin, not in the middle")
    }

    func testFollowingNeverShowsPastTheEdgeOfTheWindow() {
        var focus = zoomed(4, at: CGPoint(x: 0.9, y: 0.9))
        focus.keep(CGPoint(x: 1, y: 1), inViewWithin: 0.25, card: card, picture: window)
        let region = focus.region(card: card, picture: window)
        XCTAssertLessThanOrEqual(region.maxX, 1.0001)
        XCTAssertLessThanOrEqual(region.maxY, 1.0001)
        XCTAssertGreaterThanOrEqual(region.minX, -0.0001)
    }

    func testAPointerInACornerIsFollowedOnBothAxesAtOnce() {
        var focus = zoomed(3)
        focus.keep(CGPoint(x: 0.02, y: 0.02), inViewWithin: 0.2, card: card, picture: window)
        let region = focus.region(card: card, picture: window)
        XCTAssertEqual(region.minX, 0, accuracy: 0.0001)
        XCTAssertEqual(region.minY, 0, accuracy: 0.0001)
    }

    /// At rest the whole window is on screen, so there is nothing to follow and
    /// following would only move a picture that is already showing everything.
    func testNothingIsFollowedWhileTheWholeWindowIsVisible() {
        var focus = MirrorFocus()
        let before = focus
        focus.keep(CGPoint(x: 0.99, y: 0.99), inViewWithin: 0.2, card: card, picture: window)
        XCTAssertEqual(focus, before)
    }

    func testAnEmptyCardIsNotDividedBy() {
        var focus = zoomed(3)
        focus.keep(CGPoint(x: 0.5, y: 0.5), inViewWithin: 0.2, card: .zero, picture: window)
        XCTAssertEqual(focus.zoom, 3, accuracy: 0.0001)
    }
}

/// The one-button version of the zoom, now that the gesture it used to live on
/// means right click on both surfaces.
final class MirrorToggleTests: XCTestCase {

    private func ready() -> MirrorState {
        var state = MirrorState()
        state.card = CGSize(width: 402, height: 780)
        state.picture = CGSize(width: 1512, height: 982)
        return state
    }

    func testTheFirstToggleOpensItCloseEnoughToRead() {
        var state = ready()
        state.toggleZoom()
        XCTAssertTrue(state.focus.isZoomed)
        XCTAssertLessThanOrEqual(state.focus.zoom, MirrorFocus.readingZoom + 0.0001)
    }

    func testTheSecondToggleShowsTheWholeWindowAgain() {
        var state = ready()
        state.toggleZoom()
        state.toggleZoom()
        XCTAssertFalse(state.focus.isZoomed)
        XCTAssertEqual(state.focus.centre, CGPoint(x: 0.5, y: 0.5))
    }

    /// Whatever the toggle leaves on screen is what the next pinch zooms about,
    /// so the anchor has to come with it.
    func testTheAnchorFollowsTheToggle() {
        var state = ready()
        state.anchor = CGPoint(x: 0.9, y: 0.9)
        state.toggleZoom()
        XCTAssertEqual(state.anchor, state.focus.centre)
    }

    func testTogglingBeforeThereIsAPictureDoesNothing() {
        var state = MirrorState()
        state.toggleZoom()
        XCTAssertFalse(state.focus.isZoomed)
    }
}
