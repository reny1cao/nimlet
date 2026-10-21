import SwiftUI

/// What the strip is doing, for the view that draws it.
struct ScrollStripState: Equatable {
    /// Where the finger is down the strip, as a fraction of its height. Held at
    /// its last value through the coast, so the highlight fades out where the
    /// flick left it instead of jumping back to the middle.
    var position: CGFloat = 0.5
    /// 1 with a finger down, decaying to 0 as the coast runs out. Drives every
    /// visible difference, so the strip brightens the instant it is touched and
    /// dims at the rate the page is actually slowing down.
    var energy: CGFloat = 0
    /// A finger is on it now, as against the page still coasting.
    var isTouched = false

    static let idle = ScrollStripState()
}

/// Scrolling, on a surface of its own down the right-hand edge.
///
/// It used to be two fingers, which meant two fingers had to mean two things.
/// Telling a pinch from a scroll then cost fourteen points of movement before
/// either could begin, had to be latched for the rest of the gesture so it could
/// not change its mind, and was simply wrong for anyone who did a bit of both.
/// Giving scroll a place of its own leaves two fingers meaning exactly one
/// thing, on both surfaces that have them.
///
/// Narrow on purpose, and drawn narrower than it is touched: 52 points of target
/// against 4 of ink. The ink is a hint that there is something here, not a
/// control to aim at — the edge of the pad is the thing you aim at, and your
/// thumb is already resting on it.
///
/// It is deliberately not a scrollbar. There is no thumb, no proportional
/// length and no position, because Nimlet has no idea how long the thing at the
/// other end is; it is a place to drag, and dragging it does exactly what
/// dragging two fingers used to do, in the same direction, faster.
///
/// What it does have is a highlight that rides under the finger. Not decoration:
/// the one question this surface could not answer was "is it reading me at all",
/// because a scroll that lands on a page with nothing left to scroll looks
/// exactly like a strip that missed the touch. A patch of light that moves with
/// the thumb answers it without the Mac being involved, and it is the same patch
/// that fades out over the coast, which is how you can see that the flick took.
struct ScrollStrip: View {
    var state: ScrollStripState = .idle

    /// How long the travelling highlight is.
    private let highlightLength: CGFloat = 78

    private var energy: CGFloat { min(max(state.energy, 0), 1) }

    var body: some View {
        GeometryReader { geometry in
            let inset = ScrollStripGeometry.inset
            let track = max(geometry.size.height - inset * 2, 1)
            ZStack(alignment: .top) {
                rail
                // Inside the rail rather than over it: clipped to the same
                // capsule, so what moves with the thumb is a patch of light in
                // the rail and not a second object sliding along beside it.
                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(colors: [.white.opacity(0), .white, .white.opacity(0)],
                                       startPoint: .top, endPoint: .bottom)
                    )
                    .frame(height: highlightLength)
                    .offset(y: state.position * track - highlightLength / 2)
                    .opacity(0.95 * energy)
            }
            .frame(width: width, height: track)
            .clipShape(Capsule(style: .continuous))
            .shadow(color: .white.opacity(0.35 * energy), radius: 5)
            .padding(.trailing, ScrollStripGeometry.edge)
            .frame(width: geometry.size.width, height: geometry.size.height,
                   alignment: .trailing)
        }
        .frame(width: ScrollStripGeometry.touchWidth)
        .animation(.easeOut(duration: 0.14), value: state.isTouched)
        // The raw-touch surface underneath owns these touches, the same way
        // it owns the Air pill's. A SwiftUI view that took them would take
        // them with a gesture recognizer's delay, on the one path in this
        // app that is tuned hardest against exactly that.
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// The rail. Faded at both ends rather than cut off, so it reads as a hint
    /// down the side of the pad and not as a border on it.
    private var rail: some View {
        LinearGradient(colors: [.white.opacity(0), .white, .white, .white.opacity(0)],
                       startPoint: .top, endPoint: .bottom)
            .opacity(0.16 + 0.34 * energy)
    }

    /// Wider under a finger, and it stays wider while the page coasts: the rail
    /// is describing what the page is doing, not what the thumb is doing.
    private var width: CGFloat { 4 + 3 * energy }
}
