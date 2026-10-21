import SwiftUI
import UIKit

/// The fingers on the mirror.
///
/// One finger is the Mac's pointer: where you touch is where it goes, and what
/// you do there is what it does. Two fingers are the phone's own — they move
/// the picture around when it is zoomed in, and never reach the Mac at all.
///
/// Raw touches rather than gesture recognizers, for the reason the trackpad
/// gives: a recognizer's delay-and-see is the whole latency budget of a surface
/// whose point is that the Mac reacts while your finger is still down.
final class MirrorSurface: UIView {

    /// Move the pointer there. Sent for every touch, including the ones that
    /// turn out to be nothing: a pointer that follows your finger is what makes
    /// the mirror feel connected, and moving it is harmless.
    var onPoint: ((CGPoint) -> Void)?
    /// Press, and release, with the count the Mac needs to read two of them as
    /// a double click. Only ever sent for a touch that has committed to being a
    /// click or a drag.
    var onPress: ((Bool, Int) -> Void)?
    /// Two fingers, in points of the card.
    var onPan: ((CGSize) -> Void)?
    /// Two fingers moving apart or together, as a factor: 1.05 is "five
    /// percent bigger". Sent alongside the pan, because a real pinch does both
    /// at once and a picture that only did one of them would slide out from
    /// under the fingers.
    var onZoom: ((CGFloat) -> Void)?
    /// Every touch that lands, so the zoom knows what you were looking at.
    var onAnchor: ((CGPoint) -> Void)?
    /// Whether a point on the card is on the window at all.
    ///
    /// The card is the whole screen and the window is a picture somewhere in
    /// it, so most of what this surface covers is black. A finger there is not
    /// a finger on the Mac: it used to be carried to the nearest edge of the
    /// window and clicked, which is a click nobody asked for, on a title bar or
    /// a scroller, from a tap that landed on nothing.
    var accepts: ((CGPoint) -> Bool)?
    /// Two fingers down and up again without going anywhere: a right click,
    /// where they were.
    ///
    /// It used to toggle between the whole window and the part you were
    /// reading. That is a useful thing and it is now a button in the header,
    /// because the same gesture already meant right click on the trackpad, and
    /// a gesture that means two things depending on which half of the app you
    /// are in is a gesture nobody trusts. The mirror had no right click at all
    /// before this, which was the more obvious gap of the two.
    var onSecondaryTap: ((CGPoint) -> Void)?
    /// A drag down the strip at the right-hand edge. The mirror could not
    /// scroll the Mac at all before: one finger pointed and two moved the
    /// picture, and there was nothing left to scroll with.
    var onScroll: ((CGPoint) -> Void)?
    var onScrollStripChanged: ((ScrollStripState) -> Void)?
    var onScrollPhase: ((ScrollGesturePhase) -> Void)?
    /// Where that strip is. Empty when there is no room for one.
    var scrollStripRect: CGRect = .zero

    /// A press is committed on lift, on movement, or on a finger that has
    /// stayed put long enough to mean it — never on touch-down.
    ///
    /// Two fingers never land at the same instant, so anything that acted on
    /// touch-down would fire a click on the Mac at the start of every pan. The
    /// two delays below are how much lateness a second finger is allowed:
    /// under `settleDelay` a moving finger is still assumed to be half of a
    /// pan, and under `holdDelay` a still one is.
    ///
    /// Both are generous, because the failure they prevent is a click landing
    /// in somebody's application by accident and the cost of preventing it is
    /// a third of a second before a deliberate press-and-hold registers.
    ///
    /// Past those, the first finger has committed — and a second finger
    /// arriving *then* is ignored rather than being allowed to cancel the
    /// press, which is the one thing that would turn this into the very click
    /// it is avoiding: a press already sent cannot be taken back, so releasing
    /// it early converts it into one.
    private let holdDelay: TimeInterval = 0.35
    private let settleDelay: TimeInterval = 0.08
    private let dragThreshold: CGFloat = 8
    private let tapMaxDuration: TimeInterval = 0.4

    private var touch: UITouch?
    private var startPoint: CGPoint = .zero
    private var lastPoint: CGPoint = .zero
    private var began = Date()
    private var isPressing = false
    private var pressCount = 1
    /// A second tap in the same place, soon enough, is a double click — the
    /// Mac reads that from the count on the event rather than from the timing,
    /// so two clicks of one arrive as two separate clicks however fast they
    /// were, and a file never opens.
    private var lastTapEnded: Date = .distantPast
    private var lastTapPoint: CGPoint = .zero
    private let secondTapWindow: TimeInterval = 0.32
    private let secondTapMaxDistance: CGFloat = 30
    /// Latched for the life of the gesture: a second finger cancels the first
    /// one's claim on the Mac rather than adding to it.
    private var isPanning = false
    /// How far apart the fingers were last frame, for the pinch.
    private var lastSpread: CGFloat = 0
    /// When the two fingers landed, and how far they have been between them
    /// since — enough to tell a tap of two fingers from a pan that happened to
    /// end near where it started.
    private var panBegan = Date()
    private var panDrift: CGFloat = 0
    private let twoFingerTapDuration: TimeInterval = 0.35
    private let twoFingerTapDrift: CGFloat = 14
    /// Below this the two touches are close enough that the gap between them
    /// is mostly jitter, and dividing by it magnifies the jitter.
    private let minimumSpread: CGFloat = 40
    private var holdWork: DispatchWorkItem?
    /// The finger on the scroll strip. Where a touch *starts* decides what it
    /// is for as long as it lasts, the same rule the trackpad follows.
    private var scrollTouch: UITouch?
    /// The mirror's scroll matches the pad's, down to the gearing curve and the
    /// length of the coast, because they are the same gesture in two places and
    /// the same object now drives both. It used to be the same three lines copied
    /// twice with a matching constant and a comment promising they would be kept
    /// in step.
    private let scroll = ScrollDriver()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = .clear
        scroll.onScroll = { [weak self] delta in self?.onScroll?(delta) }
        scroll.onPhase = { [weak self] phase in self?.onScrollPhase?(phase) }
        scroll.onState = { [weak self] state in self?.onScrollStripChanged?(state) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) unused") }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        let all = live(event, touches)
        // The strip first, and only for a lone finger arriving on an idle
        // surface: a thumb landing there mid-pinch is part of the pinch.
        if scrollTouch == nil, touch == nil, !isPanning, !isPressing,
           !scrollStripRect.isEmpty, all.count == 1,
           let found = touches.first(where: { scrollStripRect.contains($0.location(in: self)) }) {
            scrollTouch = found
            scroll.began(at: found.location(in: self), in: bounds.height)
            return
        }
        // And while a scroll is running nothing else starts, so a hand resting
        // on the glass cannot turn it into a pinch.
        if scrollTouch != nil { return }
        if all.count >= 2 {
            // A press that has already gone out stays out: releasing it here
            // would hand the Mac a complete click it never asked for. The
            // second finger is ignored instead, and what the first one started
            // finishes as a one-finger press.
            guard !isPressing else { return }
            // Otherwise, whatever the first finger was about to do, it is a pan.
            cancelHold()
            if !isPanning {
                isPanning = true
                panBegan = Date()
                panDrift = 0
            }
            touch = nil
            lastPoint = centroid(of: all)
            lastSpread = spread(of: all)
            onAnchor?(lastPoint)
            return
        }
        guard !isPanning, let first = touches.first else { return }
        let landed = first.location(in: self)
        // Only where it starts. A drag that began on the window and has since
        // been pulled off the edge of it is still that drag, and the Mac wants
        // the rest of it.
        guard accepts?(landed) ?? true else { return }
        touch = first
        startPoint = landed
        lastPoint = startPoint
        began = Date()
        onAnchor?(startPoint)
        onPoint?(startPoint)
        scheduleHold()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let scrollTouch, touches.contains(scrollTouch) {
            // Natural scrolling, and both axes — the same mapping the pad uses,
            // because it is literally the same object doing it.
            scroll.moved(to: scrollTouch.location(in: self))
            return
        }
        let all = live(event, touches)
        if isPanning {
            guard all.count >= 2 else { return }
            let point = centroid(of: all)
            let width = spread(of: all)
            let previous = max(lastSpread, minimumSpread)
            panDrift += hypot(point.x - lastPoint.x, point.y - lastPoint.y)
                + abs(width - lastSpread)
            // Re-anchored every frame, on the point between the fingers, and
            // *before* the zoom rather than after it. A pinch anchored where
            // the last single finger happened to land — which is what this did
            // — enlarges about a point somewhere else on the glass, so the
            // picture slides out from under the fingers as it grows. Anchored
            // here, whatever is between the fingers stays between them, which
            // is the whole of what makes a pinch feel attached to the picture.
            onAnchor?(point)
            if lastSpread > 0, width > 0 {
                let factor = width / previous
                if abs(factor - 1) > 0.001 { onZoom?(factor) }
            }
            // And the fingers' own movement afterwards, so a pinch that drifts
            // across the glass carries the picture with it.
            onPan?(CGSize(width: point.x - lastPoint.x, height: point.y - lastPoint.y))
            lastPoint = point
            lastSpread = width
            return
        }
        guard let touch, touches.contains(touch) else { return }
        let point = touch.location(in: self)
        lastPoint = point
        onPoint?(point)
        // Moved far enough to be a drag rather than a tap, so the button has to
        // be down before the rest of the movement arrives.
        if !isPressing,
           Date().timeIntervalSince(began) >= settleDelay,
           hypot(point.x - startPoint.x, point.y - startPoint.y) > dragThreshold {
            cancelHold()
            press(true)
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let active = scrollTouch, touches.contains(active) {
            releaseScrollStrip()
            return
        }
        let remaining = live(event, touches).count
        if isPanning {
            if remaining == 0 {
                isPanning = false
                if Date().timeIntervalSince(panBegan) < twoFingerTapDuration,
                   panDrift < twoFingerTapDrift {
                    onSecondaryTap?(lastPoint)
                    Haptics.click()
                }
            }
            lastPoint = .zero
            lastSpread = 0
            return
        }
        guard let touch, touches.contains(touch) else { return }
        cancelHold()
        let point = touch.location(in: self)
        let quick = Date().timeIntervalSince(began) < tapMaxDuration
        let still = hypot(point.x - startPoint.x, point.y - startPoint.y) <= dragThreshold

        if isPressing {
            onPoint?(point)
            press(false)
        } else if quick && still {
            // A tap: the whole click happens here, at the place the finger was,
            // rather than being spread across the touch.
            let sinceTap = Date().timeIntervalSince(lastTapEnded)
            let nearTap = hypot(point.x - lastTapPoint.x, point.y - lastTapPoint.y)
            pressCount = sinceTap < secondTapWindow && nearTap < secondTapMaxDistance ? 2 : 1
            onPoint?(point)
            press(true)
            press(false)
            Haptics.click()
            // A third tap starts again rather than becoming a triple click.
            lastTapEnded = pressCount == 2 ? .distantPast : Date()
            lastTapPoint = point
        }
        self.touch = nil
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let active = scrollTouch, touches.contains(active) || active.phase == .cancelled {
            releaseScrollStrip(flung: false)
        }
        cancelHold()
        releaseIfPressing()
        touch = nil
        isPanning = live(event, touches).count >= 2
    }

    // MARK: - Pressing

    private func scheduleHold() {
        cancelHold()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.touch != nil, !self.isPanning, !self.isPressing else { return }
            self.pressCount = 1
            self.press(true)
            Haptics.dragStart()
        }
        holdWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + holdDelay, execute: work)
    }

    private func releaseScrollStrip(flung: Bool = true) {
        guard scrollTouch != nil else { return }
        scrollTouch = nil
        if flung { scroll.ended() } else { scroll.cancelled() }
    }

    private func cancelHold() {
        holdWork?.cancel()
        holdWork = nil
    }

    private func press(_ down: Bool) {
        guard isPressing != down else { return }
        isPressing = down
        onPress?(down, pressCount)
        if !down { pressCount = 1 }
    }

    private func releaseIfPressing() {
        guard isPressing else { return }
        press(false)
    }

    private func live(_ event: UIEvent?, _ touches: Set<UITouch>) -> Set<UITouch> {
        (event?.allTouches ?? touches).filter { $0.phase != .ended && $0.phase != .cancelled }
    }

    /// How far apart the fingers are: the mean distance from their centre,
    /// doubled, so for the usual two touches it is the gap between them.
    private func spread(of touches: Set<UITouch>) -> CGFloat {
        guard touches.count >= 2 else { return 0 }
        let middle = centroid(of: touches)
        let total = touches.reduce(CGFloat.zero) { partial, touch in
            let point = touch.location(in: self)
            return partial + hypot(point.x - middle.x, point.y - middle.y)
        }
        return total / CGFloat(touches.count) * 2
    }

    private func centroid(of touches: Set<UITouch>) -> CGPoint {
        guard !touches.isEmpty else { return .zero }
        let sum = touches.reduce(CGPoint.zero) { partial, touch in
            let point = touch.location(in: self)
            return CGPoint(x: partial.x + point.x, y: partial.y + point.y)
        }
        return CGPoint(x: sum.x / CGFloat(touches.count), y: sum.y / CGFloat(touches.count))
    }
}

struct MirrorTouchLayer: UIViewRepresentable {
    var onPoint: (CGPoint) -> Void
    var onPress: (Bool, Int) -> Void
    var onPan: (CGSize) -> Void
    var onZoom: (CGFloat) -> Void = { _ in }
    var onAnchor: (CGPoint) -> Void
    var onSecondaryTap: (CGPoint) -> Void = { _ in }
    var onScroll: (CGPoint) -> Void = { _ in }
    var onScrollStripChanged: (ScrollStripState) -> Void = { _ in }
    var onScrollPhase: (ScrollGesturePhase) -> Void = { _ in }
    var scrollStripRect: CGRect = .zero
    var accepts: (CGPoint) -> Bool = { _ in true }

    func makeUIView(context: Context) -> MirrorSurface {
        let view = MirrorSurface()
        apply(to: view)
        // The same bargain the trackpad strikes: VoiceOver would otherwise
        // swallow the touches and leave the mirror inert.
        view.isAccessibilityElement = true
        view.accessibilityTraits = .allowsDirectInteraction
        view.accessibilityLabel = "Mirror of your Mac"
        view.accessibilityHint = "Touch to click there, drag to drag there, drag or flick the strip on the right to scroll, two fingers to pinch and move the picture, two-finger tap to right click"
        return view
    }

    func updateUIView(_ uiView: MirrorSurface, context: Context) {
        apply(to: uiView)
    }

    private func apply(to view: MirrorSurface) {
        view.onPoint = onPoint
        view.onPress = onPress
        view.onPan = onPan
        view.onZoom = onZoom
        view.onAnchor = onAnchor
        view.onSecondaryTap = onSecondaryTap
        view.onScroll = onScroll
        view.onScrollStripChanged = onScrollStripChanged
        view.onScrollPhase = onScrollPhase
        view.scrollStripRect = scrollStripRect
        view.accepts = accepts
    }
}
