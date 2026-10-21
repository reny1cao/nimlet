import CoreGraphics
import Foundation
import ScreenCaptureKit

/// How round the corners of a window are, for a phone that is drawing it.
///
/// The stream cannot say. A window is composited onto the screen through a mask
/// the window server owns, and what `SCStream` hands over is the window's own
/// rectangular buffer — the pixels *behind* that mask included. Measured on a
/// live mirror: the top-left pixel of an arriving frame is window content, not
/// the black of a masked corner. So a phone drawing the buffer as it arrives
/// shows four corners of a window that nobody at the Mac can see.
///
/// This was a guess — 9pt, with a note admitting two failed attempts to
/// measure it — and the guess was out by nearly half, which on the glass is a
/// bright wedge of window in every corner that the Mac hides. It is measured
/// now, by a route the earlier attempts missed:
///
///     screencapture -x -o -l <windowID> out.png
///
/// `-o` drops the shadow, which is what defeated reading it off a screen
/// capture, and what comes back is the window **through its mask**: the four
/// corners are alpha 0. Scanning the first fully opaque column of each row
/// from each corner gives the curve directly.
///
/// Measured on this Mac, five windows of five sizes across four applications
/// (TextEdit 656×422, System Settings 740×625, Terminal 860×499, Xcode
/// 1400×900, ChatGPT 2013×1026), all four corners of each:
///
///     35, 25, 21, 18, 16, 15, 13, 12, 11, 10, 9, 8, 7, 6, 6   (pixels at 2x)
///
/// The same sixteen numbers every time — the corner is a constant of the
/// window server, not a proportion of the window. Fitted against a
/// `CALayer` with `cornerCurve = .continuous` rendered at the same scale, the
/// radius that reproduces it is 16.8pt, r.m.s. 0.47pt over those rows; the
/// phone clips with `RoundedRectangle(style: .continuous)`, so it is the same
/// curve and not an approximation of one.
///
/// Still a constant rather than a per-window reading, and that is the
/// remaining limitation: it is one Mac, one macOS version, at 2x. A machine
/// that draws its windows differently would need it changed, so it still is:
///
///   defaults write com.renyicao.mice.host mice.windowCornerRadius -float 10
enum WindowCorner {

    /// Points, at the window's own scale. Measured; see above.
    static var measuredRadius: Double {
        let override = UserDefaults.standard.double(forKey: "mice.windowCornerRadius")
        return override > 0 && override < 40 ? override : 16.8
    }

    /// As a fraction of the window's width, which is the form that survives the
    /// encoder, the phone's scale factor and the size of the panel it draws.
    ///
    /// Nil for a window too small to have a meaningful corner, which is also
    /// the shape of "do not clip this".
    static func radiusFraction(of window: SCWindow) -> Double? {
        let width = Double(window.frame.width)
        let height = Double(window.frame.height)
        let radius = measuredRadius
        guard width > radius * 4, height > radius * 4 else { return nil }
        return radius / width
    }
}
