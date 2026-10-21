import CoreGraphics
import QuartzCore
import UIKit

/// One finger on the scroll strip, from the moment it lands to the moment the
/// page it flung finally stops.
///
/// Both touch surfaces have a strip and both used to implement it the same three
/// lines twice: subtract the last point, multiply by 1.6, send. That was fine
/// while scrolling was three lines. It is not fine now that it has a gain curve,
/// a coast driven off a display link, four phase markers to keep paired and a
/// highlight to drive, and two copies of all of that would drift — and the way
/// they would drift is that one surface scrolls differently from the other,
/// which is the exact complaint this is here to answer.
///
/// Owns the frames of the coast as well as the frames of the drag, because a
/// coast is not something macOS will do on our behalf: an injected pixel scroll
/// is a report of movement that has already happened, so every frame of a fling
/// has to be sent like any other.
final class ScrollDriver {

    /// A scroll delta, in pixels, ready for the Mac.
    var onScroll: ((CGPoint) -> Void)?
    /// Where this scroll is in its life, so the Mac can stamp its events.
    var onPhase: ((ScrollGesturePhase) -> Void)?
    /// What the strip should look like now.
    var onState: ((ScrollStripState) -> Void)?

    private var gearing = ScrollGearing()
    private let coast = ScrollCoast()

    private var lastPoint: CGPoint = .zero
    private var lastTimestamp: TimeInterval = 0
    /// Smoothed output velocity in scrolled pixels per second — what the coast
    /// launches at. Taken from the geared output rather than from the finger, so
    /// a flick coasts at the speed it was actually scrolling and the curve is
    /// applied once instead of twice.
    private var velocity: CGPoint = .zero
    private var height: CGFloat = 1
    private var position: CGFloat = 0.5

    private var link: CADisplayLink?
    private var coasting: CGPoint = .zero
    private var lastFrame: TimeInterval = 0

    /// How quickly the velocity estimate follows the finger. Fast, because the
    /// number that matters is the speed over the last two or three frames before
    /// the lift and not the average of the whole gesture: a long slow drag that
    /// ends in a flick should coast, and one that ends in a stop should not.
    private let velocitySmoothing: CGFloat = 0.55

    // MARK: - The finger

    func began(at point: CGPoint, in height: CGFloat) {
        stopCoasting(sendingPhase: false)
        gearing.reset()
        lastPoint = point
        lastTimestamp = CACurrentMediaTime()
        velocity = .zero
        self.height = max(height, 1)
        position = min(max(point.y / self.height, 0), 1)
        onPhase?(.began)
        publish(isTouched: true, energy: 1)
    }

    func moved(to point: CGPoint) {
        let now = CACurrentMediaTime()
        let dt = now - lastTimestamp
        let raw = CGPoint(x: point.x - lastPoint.x, y: point.y - lastPoint.y)
        lastPoint = point
        lastTimestamp = now
        position = min(max(point.y / height, 0), 1)

        let geared = gearing.geared(delta: raw, dt: dt)
        guard geared != .zero else { return }

        let safeDt = CGFloat(min(max(dt, 1.0 / 240.0), 1.0 / 30.0))
        let instant = CGPoint(x: geared.x / safeDt, y: geared.y / safeDt)
        velocity.x += (instant.x - velocity.x) * velocitySmoothing
        velocity.y += (instant.y - velocity.y) * velocitySmoothing

        onScroll?(geared)
        publish(isTouched: true, energy: 1)
    }

    /// The finger has gone. Either the page keeps going or it stops here.
    func ended() {
        let launch = coast.launchVelocity(velocity)
        let speed = hypot(Double(launch.x), Double(launch.y))
        velocity = .zero
        guard coast.launches(atSpeed: speed) else {
            onPhase?(.ended)
            publish(isTouched: false, energy: 0)
            return
        }
        // Ended first, then momentum began: that is the order macOS itself sends
        // them in, and a scroll view that never sees the `ended` is one that
        // rubber-bands for the length of the coast.
        onPhase?(.ended)
        onPhase?(.momentumBegan)
        coasting = launch
        lastFrame = CACurrentMediaTime()
        publish(isTouched: false, energy: 1)
        startLink()
    }

    /// Cancelled, backgrounded, or the surface went away. No coast: a gesture
    /// that was interrupted was not a flick.
    func cancelled() {
        velocity = .zero
        if link != nil {
            stopCoasting(sendingPhase: true)
        } else {
            onPhase?(.ended)
        }
        publish(isTouched: false, energy: 0)
    }

    // MARK: - The coast

    private func startLink() {
        let link = CADisplayLink(target: self, selector: #selector(step))
        // Whatever the screen will give. A ProMotion phone coasts at 120 and the
        // Mac is happier with the smaller deltas that come with it.
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120,
                                                        preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func step(_ link: CADisplayLink) {
        let now = link.timestamp
        let dt = lastFrame > 0 ? now - lastFrame : link.duration
        lastFrame = now
        // A frame after the app was suspended arrives with a huge gap, and
        // decaying by it would teleport the page. Skip it and carry on.
        guard dt > 0, dt < 0.1 else { return }

        let delta = CGPoint(x: coasting.x * CGFloat(dt), y: coasting.y * CGFloat(dt))
        coasting = coast.decayed(coasting, over: dt)
        if delta != .zero { onScroll?(delta) }

        // Drawn as the share of the launch speed that is left, so the strip dims
        // out at the rate the page is slowing rather than blinking off.
        publish(isTouched: false, energy: energyOfCoast())

        if coast.hasStopped(coasting) { stopCoasting(sendingPhase: true) }
    }

    private func energyOfCoast() -> CGFloat {
        let speed = hypot(Double(coasting.x), Double(coasting.y))
        guard speed > coast.restSpeed else { return 0 }
        // Against a speed a flick comfortably clears rather than against the
        // launch speed, so two flicks of different strength fade the same way.
        return CGFloat(min(speed / 2400, 1))
    }

    private func stopCoasting(sendingPhase: Bool) {
        guard link != nil else { return }
        link?.invalidate()
        link = nil
        coasting = .zero
        lastFrame = 0
        if sendingPhase {
            onPhase?(.momentumEnded)
            publish(isTouched: false, energy: 0)
        }
    }

    private func publish(isTouched: Bool, energy: CGFloat) {
        onState?(ScrollStripState(position: position, energy: energy, isTouched: isTouched))
    }

    deinit { link?.invalidate() }
}
