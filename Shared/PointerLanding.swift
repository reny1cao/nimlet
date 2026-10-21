import CoreGraphics

/// Where the Mac's pointer belongs after the phone has pointed the Mac at a
/// different window.
///
/// Switching window or app from the phone moved what was *focused* and left the
/// pointer exactly where it was — frequently on another display, over a window
/// you had just left. Two things went wrong at once: the cursor had to be found
/// by waving the trackpad around until something moved, and scroll went to the
/// window under the pointer, which is to say the old one.
///
/// The geometry lives here, away from `AXUIElement` and `CGEvent`, because the
/// interesting part is not how to move a cursor but where it should end up: in
/// the part of that window a person can actually see, and only when it is not
/// already there.
enum PointerLanding {

    /// The point to move the pointer to, or nil to leave it alone.
    ///
    /// - Parameters:
    ///   - window: the window's frame, in the top-left-origin global space
    ///     `CGEvent` uses for the pointer — the same space Accessibility and
    ///     ScreenCaptureKit report window positions in.
    ///   - pointer: where the pointer is now.
    ///   - screens: the active displays, in that same space. A window can hang
    ///     off the edge of one, and the middle of *that* window is not
    ///     somewhere a cursor can go.
    static func landing(in window: CGRect, pointer: CGPoint, screens: [CGRect]) -> CGPoint? {
        // A window with no area is either being created or being destroyed;
        // either way there is nowhere in it to put a cursor.
        guard window.width >= 1, window.height >= 1 else { return nil }

        // No display list at all means something is wrong with the display
        // query rather than with the window, and the window's own middle is a
        // better answer than refusing to move. A display list that simply does
        // not contain this window is the opposite: the window is on a screen
        // that is no longer there, and moving the cursor into it would park it
        // somewhere nobody can see — which is the complaint, not the fix.
        let visible: CGRect
        if screens.isEmpty {
            visible = window
        } else if let piece = visiblePart(of: window, on: screens) {
            visible = piece
        } else {
            return nil
        }

        // Already in that window: the point of this is to stop somebody hunting
        // for the cursor, and a cursor that is where it should be does not need
        // to be moved. Moving it anyway would yank the pointer out from under a
        // hand that was about to use it.
        if visible.contains(pointer) { return nil }

        return CGPoint(x: visible.midX, y: visible.midY)
    }

    /// The largest single-display piece of the window.
    ///
    /// Largest rather than union: a window spanning two screens has a middle
    /// that may sit in the gap between them, and the point of this is to name a
    /// place the cursor can be.
    private static func visiblePart(of window: CGRect, on screens: [CGRect]) -> CGRect? {
        var best: CGRect?
        var bestArea: CGFloat = 0
        for screen in screens {
            let piece = window.intersection(screen)
            guard !piece.isNull, piece.width >= 1, piece.height >= 1 else { continue }
            let area = piece.width * piece.height
            if area > bestArea {
                bestArea = area
                best = piece
            }
        }
        return best
    }
}
