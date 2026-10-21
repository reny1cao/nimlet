import CoreGraphics
import Foundation

/// How far a finger on the scroll strip moves the page.
///
/// The strip is about 600 points tall and a page is not, so a fixed ratio was
/// always going to be wrong at one end: 1.6 pixels per point meant a full-height
/// thumb drag moved a document by less than one screen, and reading anything
/// long was a rowing motion.
///
/// Geared like the pointer, and for the same reason: a slow drag stays near
/// one-to-one, which is what you want when you are lining a line of code up with
/// your eye, and a flick is worth several screens. Same shape as
/// `PointerAccelerator`, deliberately — the two surfaces are one hand doing two
/// things and they should not disagree about what "fast" means — but gentler,
/// because scrolling past what you were looking for is more annoying than
/// arriving slightly short of it.
struct ScrollGearing {
    /// What a slow, deliberate drag is worth, in scrolled pixels per point of
    /// finger travel.
    var baseScale: Double = 1.5
    var accelerationStrength: Double = 2.2
    var speedThreshold: Double = 1200
    var maxSpeedRatio: Double = 1.6
    var curve: Double = 1.4
    var risingSmoothing: Double = 0.7
    var fallingSmoothing: Double = 0.3

    private var smoothedSpeed: Double = 0

    mutating func reset() { smoothedSpeed = 0 }

    func scale(atSpeed speed: Double) -> Double {
        let ratio = min(max(speed, 0) / speedThreshold, maxSpeedRatio)
        return baseScale * (1 + accelerationStrength * pow(ratio, curve))
    }

    /// Finger travel in, scroll delta out, in the sign convention the Mac wants:
    /// positive `y` scrolls the content down, which is what a finger moving down
    /// the strip means.
    mutating func geared(delta: CGPoint, dt: TimeInterval) -> CGPoint {
        let distance = hypot(delta.x, delta.y)
        guard distance > 0 else { return .zero }
        let safeDt = min(max(dt, 1.0 / 240.0), 1.0 / 30.0)
        let instantaneous = Double(distance) / safeDt
        let smoothing = instantaneous > smoothedSpeed ? risingSmoothing : fallingSmoothing
        smoothedSpeed += (instantaneous - smoothedSpeed) * smoothing

        let scale = scale(atSpeed: smoothedSpeed)
        return CGPoint(x: -delta.x * scale, y: delta.y * scale)
    }
}

/// The coast after a flick: what the page keeps doing once the thumb has gone.
///
/// Lifting a finger used to stop the page dead, which is the single thing that
/// made the strip feel like a machine part rather than like scrolling. Every
/// scrolling surface anyone has touched since 2007 keeps going, and macOS will
/// not do it for us — an injected pixel scroll is a report of movement that has
/// already happened, so the frames of a coast have to be sent like any others.
///
/// Exponential decay rather than a fixed friction, because that is what UIKit
/// and AppKit both do and the difference is legible: constant friction stops
/// abruptly at the end, exponential glides in.
struct ScrollCoast {
    /// Fraction of the speed that survives one second. 0.06 is a coast of
    /// roughly 1.4 seconds and about 1100 pixels from a brisk flick — long
    /// enough to be worth doing, short enough that a second flick is never
    /// waiting for the first one to finish.
    var retentionPerSecond: Double = 0.06
    /// Below this, in pixels per second, a lift was a stop and not a flick.
    /// A thumb settling on the glass before it leaves always has a little
    /// residual speed, and coasting on it is a page that will not sit still.
    var launchSpeed: Double = 300
    /// And below this the coast is over. High enough not to dribble out in
    /// single pixels for another half second.
    var restSpeed: Double = 60
    /// Nothing leaves the strip faster than this, however hard it is flicked.
    var maximumSpeed: Double = 9000

    /// Whether a lift at this speed, in pixels per second, is a flick.
    func launches(atSpeed speed: Double) -> Bool { speed >= launchSpeed }

    /// The speed the coast starts at, clamped.
    func launchVelocity(_ velocity: CGPoint) -> CGPoint {
        let speed = hypot(Double(velocity.x), Double(velocity.y))
        guard speed > maximumSpeed else { return velocity }
        let scale = maximumSpeed / speed
        return CGPoint(x: velocity.x * CGFloat(scale), y: velocity.y * CGFloat(scale))
    }

    /// What is left of `velocity` after `dt` seconds.
    func decayed(_ velocity: CGPoint, over dt: TimeInterval) -> CGPoint {
        let factor = CGFloat(pow(retentionPerSecond, max(dt, 0)))
        return CGPoint(x: velocity.x * factor, y: velocity.y * factor)
    }

    func hasStopped(_ velocity: CGPoint) -> Bool {
        hypot(Double(velocity.x), Double(velocity.y)) < restSpeed
    }
}
