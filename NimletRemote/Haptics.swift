import UIKit

/// On a blind trackpad the phone gives no visual feedback, so touch has to do
/// the job the pointer normally does. Skipping this makes the app feel broken
/// even when every event is landing correctly.
enum Haptics {
    private static let light = UIImpactFeedbackGenerator(style: .light)
    private static let rigid = UIImpactFeedbackGenerator(style: .rigid)
    private static let soft = UIImpactFeedbackGenerator(style: .soft)
    private static let notice = UINotificationFeedbackGenerator()

    static func prepare() {
        light.prepare(); rigid.prepare(); soft.prepare(); notice.prepare()
    }

    static func click() { rigid.impactOccurred(intensity: 0.9) }
    static func secondaryClick() { light.impactOccurred(intensity: 0.7) }
    static func dragStart() { soft.impactOccurred(intensity: 1.0) }
    static func dragEnd() { light.impactOccurred(intensity: 0.5) }
    static func recordStart() { rigid.impactOccurred(intensity: 1.0) }
    static func recordEnd() { soft.impactOccurred(intensity: 0.8) }
    static func success() { notice.notificationOccurred(.success) }
    /// Something needs a decision. A warning rather than a success or an error:
    /// nothing has gone wrong, but nothing will proceed either.
    static func attention() { notice.notificationOccurred(.warning) }
    static func failure() { notice.notificationOccurred(.error) }

    /// The Mac confirmed a delivery. Two rising taps rather than the system
    /// success notification: the phone is face down beside the keyboard while
    /// this arrives, so "it landed" has to be tellable from "you let go of the
    /// button" without looking, and those two happen a fraction apart.
    static func delivered() {
        rigid.impactOccurred(intensity: 0.55)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.09) {
            rigid.impactOccurred(intensity: 1.0)
            rigid.prepare()
        }
    }

    /// The Mac could not deliver. Three heavy taps, deliberately unlike
    /// anything else here: a failure that feels like a success is worse than no
    /// feedback at all, because the text is gone and nobody goes to check.
    static func deliveryFailed() {
        notice.notificationOccurred(.error)
        for step in 1...2 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.13 * Double(step)) {
                rigid.impactOccurred(intensity: 1.0)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            rigid.prepare(); notice.prepare()
        }
    }
}
