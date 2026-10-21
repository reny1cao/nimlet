import XCTest

/// The rule that decides whether the dock is a dock.
///
/// A fixed tile size plus a scroll view is a list: no tile has a settled
/// position, and whatever is past the edge cannot be reached without looking
/// for it. Shrinking to fit is what the macOS Dock does instead, and it is the
/// whole reason that one can be used without being looked at.
///
/// The width used throughout is the room a 402-point phone actually leaves the
/// row: the capsule is the screen less 20 points a side, and the row keeps 14
/// points clear at each end of it. 334.
final class DockMetricsTests: XCTestCase {

    private let phone: CGFloat = 334

    // MARK: - Shrinking

    func testAShortRowKeepsTheRestingSize() {
        // Three tiles and a `+`. There is room to spare, so nothing shrinks —
        // a dock whose icons got smaller before it had to would be shrinking
        // for no reason — and the gaps stay open too.
        let row = DockMetrics.layout(tiles: 4, in: phone)
        XCTAssertEqual(row.side, DockMetrics.ceiling)
        XCTAssertEqual(row.spacing, DockMetrics.spacing)
        XCTAssertFalse(row.overflows)
    }

    func testTheRowShrinksRatherThanScrolling() {
        // Seven slots do not fit at the resting size: 7 × 48 + 6 × 8 = 384.
        // In 380 points they fit once the tiles give, and that is enough on its
        // own — the gaps never have to close.
        let row = DockMetrics.layout(tiles: 7, in: 380)
        XCTAssertGreaterThanOrEqual(row.side, DockMetrics.floor)
        XCTAssertLessThan(row.side, DockMetrics.ceiling)
        XCTAssertEqual(row.spacing, DockMetrics.spacing)
        XCTAssertFalse(row.overflows, "seven slots should be made to fit, not scrolled")
    }

    func testTheGapsCloseBeforeARowIsGivenUpOn() {
        // A narrower phone, where the tiles alone cannot do it: seven slots in
        // 344 points need the gaps to close as well. A tile is what you aim
        // at and the space between them is not, so the gaps are the cheaper
        // thing to spend — but they are only spent when spending them is what
        // saves the row.
        let narrow = DockMetrics.layout(tiles: 7, in: 344)
        XCTAssertEqual(narrow.spacing, DockMetrics.tightSpacing)
        XCTAssertGreaterThanOrEqual(narrow.side, DockMetrics.floor)
        XCTAssertFalse(narrow.overflows)

        // And at a large type size, where the floor rises under the tiles.
        let large = DockMetrics.layout(tiles: 5, in: 300, ceiling: 80, floor: 56)
        XCTAssertEqual(large.spacing, DockMetrics.tightSpacing)
        XCTAssertFalse(large.overflows)
    }

    /// Whatever it returns, it has to be true.
    func testARowThatClaimsToFitActuallyFits() {
        for width in stride(from: CGFloat(280), through: 440, by: 13) {
            for tiles in 1...16 {
                for hasDivider in [false, true] {
                    let row = DockMetrics.layout(tiles: tiles, hasDivider: hasDivider, in: width)
                    guard !row.overflows else { continue }
                    let gaps = CGFloat(tiles - 1) + (hasDivider ? 1 : 0)
                    let used = row.side * CGFloat(tiles)
                        + (hasDivider ? DockMetrics.dividerWidth : 0)
                        + row.spacing * gaps
                    XCTAssertLessThanOrEqual(used, width + 0.5,
                                             "\(tiles) tiles in \(width) claimed to fit and did not")
                    XCTAssertGreaterThanOrEqual(row.side, DockMetrics.floor,
                                                "a fitting row must still be tappable")
                }
            }
        }
    }

    func testShrinkingBuysRealCapacityOverTheFixedSizeItReplaced() {
        // A fixed tile that scrolled the rest would hold six slots here — five
        // targets and the `+`. Anything better than that is the point of
        // shrinking.
        let fixedFit = Int((phone + DockMetrics.spacing)
                           / (DockMetrics.ceiling + DockMetrics.spacing))
        XCTAssertEqual(fixedFit, 6)

        var shrunkFit = 0
        for tiles in 1...20 where !DockMetrics.layout(tiles: tiles, in: phone).overflows {
            shrunkFit = tiles
        }
        XCTAssertGreaterThan(shrunkFit, fixedFit)
    }

    // MARK: - The section rule

    func testTheDividerIsNotChargedAsAWholeTile() {
        // It is a hairline and the air around it. Counting it as a tile's worth
        // of width shrank every tile in the row to pay for seven points.
        let without = DockMetrics.layout(tiles: 6, hasDivider: false, in: phone)
        let with = DockMetrics.layout(tiles: 6, hasDivider: true, in: phone)
        XCTAssertGreaterThan(with.side, DockMetrics.floor)
        // Narrower, because the divider does cost something — but nothing like
        // a tile, which is what an extra slot would have cost.
        let asAnExtraTile = DockMetrics.layout(tiles: 7, hasDivider: false, in: phone)
        XCTAssertGreaterThan(with.side, asAnExtraTile.side)
        XCTAssertLessThanOrEqual(with.side, without.side)
    }

    // MARK: - The floor

    func testATileIsNeverSqueezedBelowATapTarget() {
        // Forty panes is not a realistic dock, but the arithmetic has to stay
        // honest at the end of it: a 9-point tile is not something a thumb can
        // hit, and the Dock's freedom to shrink to 16 comes from having a
        // pointer.
        XCTAssertEqual(DockMetrics.layout(tiles: 40, in: phone).side, DockMetrics.floor)
        XCTAssertGreaterThanOrEqual(DockMetrics.floor, 44,
                                    "the floor is a tap target, and 44 is the smallest iOS allows")
    }

    func testItScrollsOnceShrinkingHasRunOut() {
        XCTAssertTrue(DockMetrics.layout(tiles: 40, in: phone).overflows)
    }

    // MARK: - Degenerate cases

    func testAnUnmeasuredRowRestsAtTheCeilingRatherThanFlashingAtItsMinimum() {
        // The width arrives a frame after the view does. Answering the
        // minimum in the meantime would show every tile at its smallest for
        // one frame on every appearance.
        XCTAssertEqual(DockMetrics.layout(tiles: 6, in: 0).side, DockMetrics.ceiling)
        XCTAssertEqual(DockMetrics.layout(tiles: 6, in: -100).side, DockMetrics.ceiling)
        XCTAssertFalse(DockMetrics.layout(tiles: 6, in: 0).overflows)
    }

    func testAnEmptyRowAsksForNothing() {
        XCTAssertEqual(DockMetrics.layout(tiles: 0, in: phone).side, DockMetrics.ceiling)
        XCTAssertFalse(DockMetrics.layout(tiles: 0, in: phone).overflows)
    }

    func testOneTileDoesNotPayForAGapThatIsNotThere() {
        // `tiles - 1` gaps, so a single tile has none. Getting this wrong makes
        // a lone tile 8 points narrower than a resting one for no visible
        // reason.
        XCTAssertEqual(DockMetrics.layout(tiles: 1, in: DockMetrics.ceiling).side,
                       DockMetrics.ceiling)
    }

    // MARK: - Type size

    func testTheFloorAndCeilingScaleTogether() {
        // Both are `@ScaledMetric` in the view, so the caller can hand in a
        // larger pair. The rule must clamp to what it was given rather than to
        // its own defaults, or Larger Text would silently stop working.
        XCTAssertEqual(DockMetrics.layout(tiles: 40, in: phone, ceiling: 80, floor: 60).side, 60)
        XCTAssertEqual(DockMetrics.layout(tiles: 2, in: phone, ceiling: 80, floor: 60).side, 80)
    }
}
