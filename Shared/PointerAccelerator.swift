import CoreGraphics
import Foundation

/// Maps finger movement on a ~360pt-wide glass surface onto a multi-thousand
/// pixel desktop. Without a curve you must choose between "can't cross the
/// screen" and "can't hit a button"; with one you get both.
///
/// The curve is deliberately steeper than a straight line, and it took a
/// complaint to get there. The first version was linear in speed with a ceiling
/// of 6.2, which reads as plenty until you notice where the ceiling sat: it
/// needed 3900 points per second, and no thumb on a pad this size produces
/// that. What a real flick manages is 1000 to 1600, and at 1000 the linear
/// curve gave 2.4 — so a 200-point swipe moved the pointer 480 points and
/// getting from the left of a 1512-point display to the bottom right took five
/// of them.
///
/// So the knee moved down to where fingers actually live, and the shape became
/// superlinear: slow movement earns almost nothing, because that is where
/// precision comes from, and everything above a brisk drag earns most of the
/// range. The same flick now carries about 1200 points, which is one swipe
/// across a display and a bit, while a 20-point nudge still lands on a
/// 12-point close button.
///
/// Lives in `Shared` rather than beside the pad because it is arithmetic with a
/// feel attached — exactly the kind of thing that is easy to get subtly wrong
/// and impossible to argue about from memory — so it is compiled into the tests.
struct PointerAccelerator {
    /// Multiplier for slow, deliberate movement. Keep near 1 for precision.
    var baseGain: Double = 1.05
    /// How much extra gain movement at `speedThreshold` earns.
    var accelerationStrength: Double = 5.0
    /// Speed (points/second) at which acceleration reaches full strength.
    ///
    /// Measured off real gestures rather than picked: resting a thumb and
    /// pushing is 150–400, a deliberate drag across the pad is 500–800, a flick
    /// is 1000–1600. The knee belongs at the top of "deliberate", so that
    /// anything meant as a flick is already past it.
    var speedThreshold: Double = 1050
    /// Ceiling on the speed ratio so a flick can't fling the cursor off-screen.
    var maxSpeedRatio: Double = 1.7
    /// How the speed ratio is bent before it is applied. Above 1 the curve is
    /// flat at the bottom and steep at the top, which is the whole point of it:
    /// it buys reach out of the fast half of the range without spending any
    /// precision out of the slow half.
    var curve: Double = 1.6
    /// Smoothing applied to the *speed estimate*, not the delta. Smoothing the
    /// delta would add visible pointer lag; smoothing the gain just removes
    /// jitter in how fast the cursor feels.
    ///
    /// Asymmetric, because rising and falling are not the same question. A
    /// flick has to earn its gain within a frame or two, or the pointer is
    /// still accelerating after the finger has stopped and overshoots; so
    /// rising is barely smoothed at all. Falling is smoothed harder, so one
    /// slow frame in the middle of a fast drag — a finger rolling, a dropped
    /// touch event — does not drop the gain out from under the gesture.
    var risingSmoothing: Double = 0.8
    var fallingSmoothing: Double = 0.3

    private var smoothedSpeed: Double = 0

    mutating func reset() { smoothedSpeed = 0 }

    /// The gain a sustained speed of `speed` points per second earns. Exposed
    /// so the curve can be argued with in a test rather than in a hand.
    func gain(atSpeed speed: Double) -> Double {
        let ratio = min(max(speed, 0) / speedThreshold, maxSpeedRatio)
        return baseGain * (1 + accelerationStrength * pow(ratio, curve))
    }

    mutating func accelerate(delta: CGPoint, dt: TimeInterval) -> CGPoint {
        let distance = hypot(delta.x, delta.y)
        guard distance > 0 else { return .zero }

        // A stale or absurd timestamp would produce a nonsense speed.
        let safeDt = min(max(dt, 1.0 / 240.0), 1.0 / 30.0)
        let instantaneousSpeed = Double(distance) / safeDt
        let smoothing = instantaneousSpeed > smoothedSpeed ? risingSmoothing : fallingSmoothing
        smoothedSpeed += (instantaneousSpeed - smoothedSpeed) * smoothing

        let gain = gain(atSpeed: smoothedSpeed)
        return CGPoint(x: delta.x * gain, y: delta.y * gain)
    }
}
