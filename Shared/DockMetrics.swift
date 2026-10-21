import CoreGraphics

/// How big a dock tile is, given how many there are and how much room.
///
/// This is the rule that makes a dock a dock rather than a scrolling list, so
/// it is written down once, on its own, where it can be tested. The phone's
/// dock used a fixed tile size and scrolled whatever did not fit, which from
/// the fifth target onwards meant no tile had a settled position and anything
/// past the edge could not be reached without going to look for it.
///
/// The macOS Dock's answer is to shrink: icons get smaller as you add more, so
/// everything stays on screen and tile *n* is always in the same place. That is
/// what spatial memory is built on, and it is why the Dock can be used without
/// being looked at.
///
/// Two things give, in this order, which is the order that costs least:
///
/// 1. **The gaps.** Tiles move closer together before any of them gets smaller.
///    A tile is what you aim at; the space between them is not, so it is the
///    cheaper thing to spend.
/// 2. **The tiles.** Down to a floor, and the floor is a real one: the Dock
///    shrinks to about 16 points because a pointer can hit 16 points. A thumb
///    cannot, and 44 is the smallest target iOS will let you ask for.
///
/// Past that it scrolls — but the case that matters, which is everything
/// anyone actually talks to, now fits.
///
/// It lives in `Shared` rather than beside the view because the test target
/// compiles `Shared` and the app targets' own sources are not available to it.
public enum DockMetrics {
    /// The size a tile takes when there is room for it. Its icon is six points
    /// smaller, 42, so a resting tile sits only just above the floor: the dock
    /// is a capsule now, and a taller tile made it a fat one.
    public static let ceiling: CGFloat = 48
    /// And the smallest it may be squeezed to. A tap target, not a taste.
    public static let floor: CGFloat = 44
    /// The gap between tiles when there is room, and when there is not.
    public static let spacing: CGFloat = 8
    public static let tightSpacing: CGFloat = 4
    /// The rule between the curated half of the dock and the live half. A
    /// hairline and the air around it — it takes width, but nothing like a
    /// tile's worth, and counting it as one squeezed the row for nothing.
    public static let dividerWidth: CGFloat = 7

    public struct Layout: Equatable, Sendable {
        public let side: CGFloat
        public let spacing: CGFloat
        /// True when shrinking ran out and the row still has to scroll.
        public let overflows: Bool
    }

    /// What the row should look like.
    ///
    /// - Parameters:
    ///   - tiles: how many things of tile width the row holds — targets and
    ///     the trailing `+`, since that takes a slot like any other.
    ///   - hasDivider: whether the section rule is in the row too.
    ///   - width: the room available, already less whatever margin the row
    ///     hands back to its container.
    ///   - ceiling/floor: the resting and minimum sizes, which scale with the
    ///     type size, so they are passed in rather than read from here.
    ///
    /// Rests at the ceiling for an empty or unmeasured row, so a dock that has
    /// not been laid out yet does not flash at its minimum size for a frame.
    public static func layout(tiles: Int,
                              hasDivider: Bool = false,
                              in width: CGFloat,
                              ceiling: CGFloat = DockMetrics.ceiling,
                              floor: CGFloat = DockMetrics.floor) -> Layout {
        guard tiles > 0, width > 0 else {
            return Layout(side: ceiling, spacing: spacing, overflows: false)
        }
        for gap in [spacing, tightSpacing] {
            let side = fittedSide(tiles: tiles, hasDivider: hasDivider,
                                  in: width, spacing: gap)
            if side >= floor {
                return Layout(side: min(side, ceiling), spacing: gap, overflows: false)
            }
        }
        return Layout(side: floor, spacing: tightSpacing, overflows: true)
    }

    /// The side that would exactly fill the width at this spacing, before any
    /// clamping. May be less than the floor, or negative — that is the caller's
    /// signal to try again or give up.
    private static func fittedSide(tiles: Int,
                                   hasDivider: Bool,
                                   in width: CGFloat,
                                   spacing: CGFloat) -> CGFloat {
        // One gap between every pair of things in the row, and the divider is
        // one of those things.
        let gaps = CGFloat(tiles - 1) + (hasDivider ? 1 : 0)
        let fixed = hasDivider ? dividerWidth : 0
        return (width - fixed - spacing * gaps) / CGFloat(tiles)
    }
}
