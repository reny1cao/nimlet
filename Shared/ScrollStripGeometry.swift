import CoreGraphics

/// Where the scroll strip is, and how big a piece of a surface it takes.
///
/// One definition, used by the view that draws the strip and by the two raw-touch
/// surfaces that route touches to it. Two would drift, and the failure would be a
/// strip that is drawn in one place and works in another — which is the least
/// debuggable kind of wrong, because the app looks right in a screenshot.
///
/// In `Shared` for the same reason `PointerLanding` is: it is geometry with a
/// feel attached, it is the subject of an actual complaint about aiming, and the
/// tests can reach it here.
enum ScrollStripGeometry {
    /// What the finger gets.
    ///
    /// 52, up from 40, and the 40 was the whole of one complaint. The pad stops
    /// one gutter short of the glass, so the strip was a 40-point target
    /// beginning 14 points inside a card whose edge is the thing you aim at —
    /// which is to say that aiming at the edge of the pad landed you outside the
    /// strip and moved the pointer instead. Wider, plus the bleed below, and the
    /// edge of the pad is in the middle of the target rather than past the end
    /// of it.
    ///
    /// Short of the 44 points Apple asks for a button in the sense that it is not
    /// a button: it runs the whole height of its surface, so the area is enormous
    /// even where the width is not.
    static let touchWidth: CGFloat = 52

    /// How far the ink stops short of the ends, so it reads as a hint down the
    /// side rather than as a border.
    static let inset: CGFloat = 12

    /// And how far it stops short of the trailing edge.
    ///
    /// Small, because the ink is there to say where the edge is. It used to be
    /// half the target width: the rail was centred in its 40 points and so drawn
    /// 20 points in from the card's edge, pointing at a place your thumb has no
    /// reason to go.
    static let edge: CGFloat = 7

    /// The strip inside a surface of this size.
    ///
    /// `bleed` is how far past the surface's own trailing edge the *target* is
    /// allowed to run. The pad hands it the screen's gutter, so the strip reaches
    /// the glass: a thumb resting on the edge of the phone is the cheapest aim
    /// there is, and it was landing in the margin between the card and the glass.
    /// Nothing is drawn out there — the ink stays on the card, where the card is.
    static func rect(in size: CGSize, bleed: CGFloat = 0) -> CGRect {
        guard size.width > touchWidth * 2, size.height > 0 else { return .zero }
        return CGRect(x: size.width - touchWidth, y: 0,
                      width: touchWidth + max(bleed, 0), height: size.height)
    }
}
