import SwiftUI

/// The one horizontal inset the screen is built on.
///
/// Named because two rows now have to step back out of it: a row that scrolls
/// sideways is cut off wherever its scroll view ends, and ending it 14 points
/// short of the glass put a hard vertical edge in the middle of the screen with
/// nothing on the far side of it. They bleed to the edge and hand the inset
/// back as a content margin, so what is at rest still lines up with the
/// trackpad and the headers above it, and what is moving leaves the screen
/// instead of stopping inside it.
///
/// Named `Metric` rather than `Layout`, which is a SwiftUI protocol: a type of
/// that name in this module would shadow it for every file in the app.
enum Metric {
    static let gutter: CGFloat = 14

    /// How far the dock floats from the screen's sides and its bottom edge.
    ///
    /// One number for all three. The tray used to sit 8 points from the sides
    /// and over 40 from the bottom, with 26-point corners under a screen whose
    /// own corners are twice that: three distances and two curves that had
    /// nothing to do with each other, so it read as a card dropped near the
    /// bottom rather than as part of the screen. A capsule the same distance
    /// from every edge it is near is a shape of its own and does not have to
    /// match the glass.
    static let dockInset: CGFloat = 20

    /// The gap the main stack leaves under its last band.
    static let stackBottom: CGFloat = 8

    /// How tall the stage may stand, as a share of the screen it is on.
    ///
    /// A share rather than a number of points, which is what this was. 244pt is
    /// 28% of an iPhone 17 Pro and 37% of the smallest phone the app runs on —
    /// the same constant meaning two different layouts. The stage is the
    /// picture of the Mac and it is the reason the app is open, so it gets the
    /// largest share the other two bands can spare, on every phone.
    ///
    /// It is still a ceiling and not a height: the band takes the shape of the
    /// window it is mirroring, so a wide window uses less than this and a tall
    /// one is held to it rather than pushing the pad off the screen.
    static let stageShare: CGFloat = 0.45
    /// And the share while the keyboard is up, where the pad has stood down and
    /// left its room behind. Of a much shorter screen: the keyboard has taken
    /// half of it, so the same share is a smaller picture.
    static let stageTypingShare: CGFloat = 0.5

    /// What everything below the stage needs between them, so the stage's share
    /// is taken out of what is actually spare.
    ///
    /// Measured rather than guessed. The first guess was 320 and it did not bite
    /// where it was meant to: 45% of the smallest phone left the pad 89 points,
    /// which is enough to drag a pointer across and not enough to put two
    /// fingers on.
    ///
    /// 20 for the status line, 90 for the console, 85 for the dock, 36 for the
    /// three gaps between the bands — and 127 for the pad itself, which is the
    /// number this exists to protect and is exactly what the smallest phone had
    /// when the stage was a flat 244. So no phone comes out of this with a
    /// smaller stage than it went in with, and every phone that can afford the
    /// full share gets it: 45% on anything from an iPhone 16 up, against the 28
    /// to 32% that 244 points was there.
    ///
    /// The dock's 85 is its 73-point capsule plus the 12 it lifts by on a phone
    /// with no home indicator, the smallest case; on every other phone it
    /// floats down into the home indicator's band and costs less than that.
    private static let bandsBelowStage: CGFloat = 20 + 90 + 85 + 36 + 127

    /// How far the handle between the stage and the pad may move the share.
    /// Below the floor the picture is a strip nobody can read; above the
    /// ceiling the pad is clamped by `bandsBelowStage` anyway.
    static let stageShareRange: ClosedRange<CGFloat> = 0.15...0.8

    /// The ceiling for a screen of this height, at the share the person has
    /// dragged the handle to (the default when they never have).
    static func stage(in height: CGFloat, composing: Bool,
                      share chosen: CGFloat = stageShare) -> CGFloat {
        guard height > 0 else { return 244 }
        let clamped = min(max(chosen, stageShareRange.lowerBound), stageShareRange.upperBound)
        let share = height * (composing ? stageTypingShare : clamped)
        // Composing has no pad to protect: the keyboard is where the room went,
        // and the console is what has to stay against it.
        guard !composing else { return max(share, 120) }
        // The 160 floor protects the picture from the pad's needs, not from
        // the person: dragged smaller than that, smaller is what they asked for.
        return max(min(share, height - bandsBelowStage), min(160, share))
    }

    /// And the height when there is no picture at all — a window minimised, a
    /// target with nothing focused, the Mac not answering yet.
    ///
    /// A fixed number rather than a share, because it is sized to its sentence
    /// rather than to the picture it stands in for. A stopped mirror used to
    /// take the stage's whole ceiling and draw nothing in it, which put two
    /// dark rectangles of nearly the same size one above the other: the empty
    /// stage and the trackpad. Neither said which one you could touch.
    static let stagePlaceholder: CGFloat = 148
}

/// Which edges of a sideways row have more row behind them.
struct ScrollEdges: Equatable {
    var leading = false
    var trailing = false

    init(leading: Bool = false, trailing: Bool = false) {
        self.leading = leading
        self.trailing = trailing
    }

    /// A scroll view rests at `-contentInsets.leading` at the start and at
    /// `contentSize - containerSize + contentInsets.trailing` at the end. That
    /// holds whether the margins were put on the content or on the view, so
    /// this arithmetic does not care which.
    init(_ geometry: ScrollGeometry) {
        let offset = geometry.contentOffset.x
        // Half a point of slack. A scroll view at rest sits a hair off its own
        // limit, and a fade that blinks on at the end of every flick is worse
        // than no fade at all.
        leading = offset > -geometry.contentInsets.leading + 0.5
        trailing = offset + geometry.containerSize.width
            < geometry.contentSize.width + geometry.contentInsets.trailing - 0.5
    }
}

extension View {
    /// Fades a horizontal scroll view at whichever edge its content runs past.
    ///
    /// Both rows along the bottom of the screen scroll — the things you can
    /// send, and the targets you can send them to — and both were sliced flat:
    /// half a capsule, half a tile, then black. A cut like that reads as a
    /// drawing fault rather than as an invitation, and at the trailing edge,
    /// where the next thing along is the one you have not found yet, it is the
    /// difference between a row that looks finished and one that is longer than
    /// the screen.
    ///
    /// Only where there is something to fade: a row scrolled to its end is not
    /// dimmed for having arrived, and a row short enough to fit is not dimmed at
    /// all.
    func fadedScrollEdges(_ width: CGFloat = 20) -> some View {
        modifier(FadedScrollEdges(width: width))
    }
}

private struct FadedScrollEdges: ViewModifier {
    let width: CGFloat
    @State private var edges = ScrollEdges()

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: ScrollEdges.self) { geometry in
                ScrollEdges(geometry)
            } action: { _, new in
                edges = new
            }
            // Sized to the scroll view, so this has to be applied before the row
            // bleeds out of the gutter — masking the padded frame instead would
            // cut off exactly the part the bleed just bought.
            .mask {
                HStack(spacing: 0) {
                    LinearGradient(colors: [.black.opacity(0), .black],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(width: edges.leading ? width : 0)
                    Rectangle().fill(.black)
                    LinearGradient(colors: [.black, .black.opacity(0)],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(width: edges.trailing ? width : 0)
                }
            }
            .animation(.easeOut(duration: 0.16), value: edges)
    }
}
