import SwiftUI

/// Hold to steer the pointer by moving the phone; drag to reposition.
///
/// A dedicated control rather than a trackpad gesture: every press-and-hold on
/// the trackpad is already taken (0.55s = drag, tap-and-a-half = drag) and so
/// is holding a target button (320ms = dictate). Binding steering to any of
/// those would have destroyed an existing gesture.
///
/// Reposition needs no mode switch, the way AssistiveTouch works: steering uses
/// phone motion, so your finger stays still on the pill. Sliding it past a
/// threshold can only mean "move me".
struct AirPill: View {
    let position: CGPoint
    let isSteering: Bool
    var isMoveMode: Bool = false

    private let size: CGFloat = 62

    var body: some View {
        ZStack {
            Circle()
                .fill(isSteering ? Color.accentColor : Color.white.opacity(0.10))
                .overlay(Circle().strokeBorder(isMoveMode ? Color.yellow : Color.white.opacity(0.18),
                                               lineWidth: isMoveMode ? 2 : 1))
            VStack(spacing: 1) {
                Image(systemName: isMoveMode ? "arrow.up.and.down.and.arrow.left.and.right"
                                  : isSteering ? "dot.radiowaves.left.and.right" : "move.3d")
                    .font(.system(size: 17, weight: .medium))
                Text("air")
                    .font(.system(size: 9, weight: .bold))
            }
            .foregroundStyle(isSteering ? Color.black : Color.white.opacity(0.65))
        }
        .frame(width: size, height: size)
        .scaleEffect(isSteering ? 1.08 : isMoveMode ? 1.12 : 1)
        .animation(.spring(duration: 0.18), value: isMoveMode)
        .animation(.spring(duration: 0.18), value: isSteering)
        .position(position)
        .allowsHitTesting(false)
        // Its touches belong to the trackpad surface underneath, which carries
        // the accessibility description for both.
        .accessibilityHidden(true)
    }
}
