import SwiftUI
import UIKit

/// Raw touch handling rather than gesture recognizers: recognizers add
/// delay-and-see latency, and the whole point of this surface is that the
/// cursor moves the instant your finger does.
final class TrackpadSurface: UIView {

    var onMove: ((CGPoint) -> Void)?
    var onScroll: ((CGPoint) -> Void)?
    /// Two fingers moving together, in points of the pad. Moves the picture
    /// above, never the Mac — the same thing two fingers do on the mirror
    /// itself, which is the point of them doing it here too.
    var onPan: ((CGSize) -> Void)?
    /// What the scroll strip is doing, for the view that draws it.
    var onScrollStripChanged: ((ScrollStripState) -> Void)?
    /// Where the scroll is in its life, so the Mac can stamp its events.
    var onScrollPhase: ((ScrollGesturePhase) -> Void)?
    /// A pinch, as a fraction of the current size per step: +0.05 means "five
    /// percent bigger".
    ///
    /// It never reaches the Mac, and that is the whole point of it. This used to
    /// inject ⌘-scroll under the pointer, which changes the real application's
    /// own zoom for whoever is sitting in front of it — the wrong end entirely.
    /// The thing that wants to be bigger is the picture on this phone, and the
    /// stream already carries more detail than the tile can draw.
    var onZoom: ((Double) -> Void)?
    var onClick: ((MouseButton, Int) -> Void)?
    var onDragChange: ((Bool) -> Void)?

    /// The Air pill is handled here rather than as a SwiftUI gesture: this view
    /// owns raw touches as a UIKit subview, and a SwiftUI DragGesture layered
    /// above it never received a single event.
    var pillRect: CGRect = .zero
    var onPillSteerBegan: (() -> Void)?
    var onPillSteerEnded: (() -> Void)?
    var onPillMoved: ((CGPoint) -> Void)?
    /// Finger travel while the pill is held: the fast second speed, summed on
    /// top of whatever the gyro is contributing rather than interrupting it.
    var onPillSlide: ((CGPoint) -> Void)?
    var onPillMoveModeChanged: ((Bool) -> Void)?

    /// Tuned by feel: a tap must be quick and nearly stationary.
    private let tapMaxDuration: TimeInterval = 0.26
    private let tapMaxDisplacement: CGFloat = 12
    /// Window after a tap in which a second touch is part of the same gesture:
    /// a double click if it lifts, a tap-and-a-half drag if it stays down.
    private let secondTapWindow: TimeInterval = 0.32
    /// How long that second press has to outlast a double click before it
    /// becomes a drag. The two gestures start identically, so the only thing
    /// that separates them is whether the finger comes back up — the old
    /// behaviour began the drag immediately, which is why no double click could
    /// ever be expressed on this surface.
    ///
    /// Derived from `tapMaxDuration` rather than tuned on its own, because the
    /// two describe the same boundary from either side: below it the press is
    /// still a tap, above it it is a drag. As independent numbers they drifted
    /// apart — 0.2 against a 0.26 tap — and a second press held for 200–260ms
    /// was armed as a drag while still short enough to count as a tap, so the
    /// double click that whole band should have produced could never fire.
    private var dragArmDelay: TimeInterval { tapMaxDuration }
    /// A double click has to land roughly where the first one did, as it does
    /// on the Mac itself.
    private let secondTapMaxDistance: CGFloat = 34
    private let longPressDuration: TimeInterval = 0.55
    /// Below this the two touches are close enough that the gap between them is
    /// mostly jitter, and dividing by it magnifies the jitter.
    private let minimumSpread: CGFloat = 40

    private var accelerator = PointerAccelerator()
    private var gestureStart = Date()
    private var startPoint: CGPoint = .zero
    private var lastPoint: CGPoint = .zero
    private var lastTimestamp: TimeInterval = 0
    private var displacement: CGFloat = 0
    private var peakTouchCount = 0
    private var lastTwoFingerPoint: CGPoint = .zero
    /// Set as soon as a second finger lands. Putting two fingers down and
    /// lifting them is never perfectly simultaneous, so there are frames where
    /// only one touch is live — without this latch those frames are read as
    /// pointer movement and the cursor drifts away during every scroll.
    private var gestureUsedMultitouch = false
    /// How far the two fingers have moved and splayed in total. Not used to
    /// decide anything any more — two fingers mean one thing — only to tell a
    /// two-finger *tap*, which is a right click, from a gesture that happened to
    /// end near where it started.
    private var twoFingerTravel: CGFloat = 0
    private var spreadDisplacement: CGFloat = 0
    /// How far apart the fingers were last frame.
    private var lastSpread: CGFloat = 0
    /// The finger that landed on the scroll strip, if there is one. It belongs
    /// to the strip for its whole life however far it subsequently travels,
    /// exactly like the Air pill's.

    private var lastTapEnded: Date = .distantPast
    private var lastTapPoint: CGPoint = .zero
    /// This press followed a tap closely enough to complete a double click.
    private var isSecondTap = false
    private var isDragging = false
    private var longPressWorkItem: DispatchWorkItem?
    /// Separate from the long press: movement cancels the long press, but a
    /// tap-and-a-half drag is *expected* to move.
    private var dragArmWorkItem: DispatchWorkItem?

    private var scrollTouch: UITouch?
    /// Gearing, coast and phase markers, shared verbatim with the mirror's own
    /// strip so the two surfaces cannot come to feel different.
    private let scroll = ScrollDriver()
    /// Where the strip is. Empty on a surface too narrow to give one up.
    ///
    /// Wider than this view where the pad is allowed to bleed into the screen's
    /// gutter, which is why `point(inside:)` below exists.
    var scrollStripRect: CGRect = .zero

    private var pillTouch: UITouch?
    private var pillSteering = false
    private var pillRepositioning = false
    private var pillStartCentre: CGPoint = .zero
    private var pillTouchStart: CGPoint = .zero
    private var pillLastPoint: CGPoint = .zero
    private var pillTouchBegan = Date()
    private var pillLastTapEnded: Date = .distantPast
    /// Repositioning is its own mode, entered by double-tapping the pill.
    /// It cannot share the press gesture any more: sliding the finger is now
    /// the second movement speed, so a slide can no longer mean "move me".
    private var pillMoveMode = false
    private let pillDoubleTapWindow: TimeInterval = 0.35

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        isUserInteractionEnabled = true
        backgroundColor = .clear
        // Forwarded rather than exposed: the driver keeps going after the finger
        // has gone, so the frames of a coast arrive here exactly like the frames
        // of a drag and nothing outside this view has to know the difference.
        scroll.onScroll = { [weak self] delta in self?.onScroll?(delta) }
        scroll.onPhase = { [weak self] phase in self?.onScrollPhase?(phase) }
        scroll.onState = { [weak self] state in self?.onScrollStripChanged?(state) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) unused") }

    /// Lets the strip run past this view's trailing edge.
    ///
    /// The pad is inset from the glass by the one gutter the screen is built on,
    /// so a strip that stopped at the card stopped 14 points short of the edge of
    /// the phone — and the edge of the phone is where a thumb goes without being
    /// asked to aim. Extended here rather than by widening the view in SwiftUI,
    /// because the card, its border and the pill are all laid out against this
    /// view's bounds and every one of them would have moved.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        if super.point(inside: point, with: event) { return true }
        guard scrollStripRect.maxX > bounds.maxX else { return false }
        return CGRect(x: bounds.maxX, y: bounds.minY,
                      width: scrollStripRect.maxX - bounds.maxX,
                      height: bounds.height).contains(point)
    }

    // MARK: - Touches

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        let all = (event?.allTouches ?? touches)
            .filter { $0.phase != .ended && $0.phase != .cancelled && $0 != pillTouch }

        // The strip comes before everything except the pill, and for the same
        // reason: where a touch *starts* decides what it is, for as long as it
        // lasts. A scroll that stopped being one because the thumb wandered off
        // the strip would be a scroll that stops halfway down a page.
        if scrollTouch == nil, pillTouch == nil, !gestureUsedMultitouch,
           !scrollStripRect.isEmpty, all.count == 1,
           let touch = touches.first(where: { scrollStripRect.contains($0.location(in: self)) }) {
            scrollTouch = touch
            cancelLongPress()
            cancelDragArm()
            scroll.began(at: touch.location(in: self), in: bounds.height)
            return
        }
        // And while one is running, nothing else starts: a second finger during
        // a scroll is a hand resting, not the beginning of a pinch.
        if scrollTouch != nil { return }

        // A touch that starts on the pill belongs to the pill for its lifetime,
        // however far the finger subsequently travels.
        if pillTouch == nil, !pillRect.isEmpty, let touch = touches.first,
           pillRect.contains(touch.location(in: self)) {
            pillTouch = touch
            pillTouchStart = touch.location(in: self)
            pillLastPoint = pillTouchStart
            pillStartCentre = CGPoint(x: pillRect.midX, y: pillRect.midY)
            pillTouchBegan = Date()
            cancelLongPress()

            if pillMoveMode {
                pillRepositioning = true
                pillSteering = false
            } else {
                pillSteering = true
                pillRepositioning = false
                Haptics.dragStart()
                onPillSteerBegan?()
            }
            return
        }

        peakTouchCount = max(peakTouchCount, all.count)

        if all.count == 1, let touch = all.first {
            gestureStart = Date()
            startPoint = touch.location(in: self)
            lastPoint = startPoint
            lastTimestamp = touch.timestamp
            displacement = 0
            accelerator.reset()

            let sinceTap = Date().timeIntervalSince(lastTapEnded)
            let nearTap = hypot(startPoint.x - lastTapPoint.x, startPoint.y - lastTapPoint.y)
            if sinceTap < secondTapWindow && nearTap < secondTapMaxDistance {
                isSecondTap = true
                scheduleDragArm()
            } else {
                isSecondTap = false
                scheduleLongPress()
            }
        } else if all.count >= 2 {
            cancelLongPress()
            cancelDragArm()
            gestureUsedMultitouch = true
            lastTwoFingerPoint = centroid(of: all)
            lastSpread = spread(of: all)
            spreadDisplacement = 0
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let pillTouch, touches.contains(pillTouch) {
            let point = pillTouch.location(in: self)
            if pillRepositioning {
                onPillMoved?(CGPoint(x: pillStartCentre.x + (point.x - pillTouchStart.x),
                                     y: pillStartCentre.y + (point.y - pillTouchStart.y)))
            } else {
                // Second speed: finger travel adds to the gyro rather than
                // interrupting it, so control is continuous until release.
                let delta = CGPoint(x: point.x - pillLastPoint.x, y: point.y - pillLastPoint.y)
                if delta != .zero { onPillSlide?(delta) }
            }
            pillLastPoint = point
            return
        }

        if let scrollTouch, touches.contains(scrollTouch) {
            // Both axes. The strip is vertical and the thumb mostly moves that
            // way, but a touch that began here owns the rest of its travel —
            // so a sideways drag out of the strip scrolls sideways, which is
            // otherwise a thing the phone could no longer do at all.
            scroll.moved(to: scrollTouch.location(in: self))
            return
        }

        let all = (event?.allTouches ?? touches)
            .filter { $0.phase != .ended && $0.phase != .cancelled && $0 != pillTouch }

        if all.count >= 2 {
            gestureUsedMultitouch = true
            let point = centroid(of: all)
            let width = spread(of: all)
            let widthDelta = lastSpread > 0 ? width - lastSpread : 0
            // The gap the fingers *came from*, not the one they arrived at.
            // Dividing by the new gap makes pinching out and pinching in
            // asymmetric — the same movement reads as a larger fraction on the
            // way in, because the denominator has shrunk.
            let previous = max(lastSpread, minimumSpread)
            let delta = CGPoint(x: point.x - lastTwoFingerPoint.x,
                                y: point.y - lastTwoFingerPoint.y)
            lastTwoFingerPoint = point
            lastSpread = width
            twoFingerTravel += hypot(delta.x, delta.y)
            spreadDisplacement += abs(widthDelta)

            // Both at once, with no decision between them, because a real pinch
            // does both and a picture that only did one of them would slide out
            // from under the fingers. This is exactly what two fingers do on
            // the mirror itself; the pad is the same gesture at a distance.
            //
            // As a fraction of the gap rather than in points: a centimetre of
            // spread means more when the fingers are close together, which is
            // how a pinch feels and what `NSEvent`'s own magnification does.
            if widthDelta != 0 { onZoom?(Double(widthDelta / previous)) }
            if delta != .zero { onPan?(CGSize(width: delta.x, height: delta.y)) }
            return
        }

        // Tail end of a two-finger gesture: one finger has lifted but the other
        // is still down. Moving the cursor here is never what was meant.
        guard !gestureUsedMultitouch, let touch = all.first else { return }
        let point = touch.location(in: self)
        let raw = CGPoint(x: point.x - lastPoint.x, y: point.y - lastPoint.y)
        let dt = touch.timestamp - lastTimestamp
        lastPoint = point
        lastTimestamp = touch.timestamp

        displacement += hypot(raw.x, raw.y)
        if displacement > tapMaxDisplacement { cancelLongPress() }

        let accelerated = accelerator.accelerate(delta: raw, dt: dt)
        if accelerated != .zero { onMove?(accelerated) }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let active = scrollTouch, touches.contains(active) {
            releaseScrollStrip()
            return
        }
        if let active = pillTouch, touches.contains(active) {
            let duration = Date().timeIntervalSince(pillTouchBegan)
            let travel = hypot(active.location(in: self).x - pillTouchStart.x,
                               active.location(in: self).y - pillTouchStart.y)
            let wasTap = duration < tapMaxDuration && travel < tapMaxDisplacement
            let wasRepositioning = pillRepositioning
            releasePill()

            // Placing the pill ends the mode, so it cannot be left armed.
            if wasRepositioning {
                setPillMoveMode(false)
            } else if wasTap {
                if Date().timeIntervalSince(pillLastTapEnded) < pillDoubleTapWindow {
                    setPillMoveMode(!pillMoveMode)
                    pillLastTapEnded = .distantPast
                } else {
                    pillLastTapEnded = Date()
                }
            }
            return
        }
        // Excludes the pill's touch, as every other filter in this file does.
        // It did not, so while the pill was held `remaining` never reached zero:
        // no click could fire during steering, and a long press that had already
        // sent leftMouseDown never got its matching up.
        let remaining = event?.allTouches?.filter {
            $0.phase != .ended && $0.phase != .cancelled && $0 != pillTouch
        }.count ?? 0
        cancelLongPress()
        cancelDragArm()

        if remaining == 0 {
            finishGesture()
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        cancelLongPress()
        cancelDragArm()
        if let active = scrollTouch, touches.contains(active) || active.phase == .cancelled {
            releaseScrollStrip(flung: false)
        }
        // An incoming call cancels every touch. The pill was not released here,
        // so the gyro went on steering after the finger was gone and the pill
        // could not be taken again until the app was restarted.
        if let active = pillTouch, touches.contains(active) || active.phase == .cancelled {
            releasePill()
        }
        if isDragging { endDrag() }
        peakTouchCount = 0
        displacement = 0
        twoFingerTravel = 0
        spreadDisplacement = 0
        lastSpread = 0
        gestureUsedMultitouch = false
        isSecondTap = false
    }

    private func releasePill() {
        if pillSteering {
            Haptics.dragEnd()
            onPillSteerEnded?()
        }
        pillTouch = nil
        pillSteering = false
        pillRepositioning = false
    }

    private func finishGesture() {
        let duration = Date().timeIntervalSince(gestureStart)
        let wasQuick = duration < tapMaxDuration
        // A fast two-finger flick-scroll must not be mistaken for a right-click.
        let wasStill = displacement < tapMaxDisplacement && twoFingerTravel < tapMaxDisplacement
            && spreadDisplacement < tapMaxDisplacement

        if isDragging {
            endDrag()
        } else if wasQuick && wasStill {
            // Make sure any queued motion lands before the click that aimed it.
            if peakTouchCount >= 2 {
                onClick?(.right, 1)
                Haptics.secondaryClick()
            } else if isSecondTap {
                // Sent as count 2 after the count 1 the first tap already sent,
                // which is the sequence the Mac reads as a double click.
                onClick?(.left, 2)
                Haptics.click()
                // A third tap starts a new gesture rather than a triple click.
                lastTapEnded = .distantPast
            } else {
                onClick?(.left, 1)
                Haptics.click()
                lastTapEnded = Date()
                lastTapPoint = startPoint
            }
        }
        peakTouchCount = 0
        displacement = 0
        twoFingerTravel = 0
        spreadDisplacement = 0
        lastSpread = 0
        gestureUsedMultitouch = false
        isSecondTap = false
    }

    // MARK: - Drag

    private func setPillMoveMode(_ enabled: Bool) {
        guard pillMoveMode != enabled else { return }
        pillMoveMode = enabled
        Haptics.secondaryClick()
        onPillMoveModeChanged?(enabled)
    }

    private func scheduleLongPress() {
        cancelLongPress()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isDragging, self.displacement < self.tapMaxDisplacement else { return }
            self.beginDrag()
        }
        longPressWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + longPressDuration, execute: work)
    }

    private func cancelLongPress() {
        longPressWorkItem?.cancel()
        longPressWorkItem = nil
    }

    private func scheduleDragArm() {
        cancelDragArm()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isDragging else { return }
            // Held past the double-click window, so this was the drag half of
            // tap-and-a-half after all.
            self.isSecondTap = false
            self.beginDrag()
        }
        dragArmWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + dragArmDelay, execute: work)
    }

    private func cancelDragArm() {
        dragArmWorkItem?.cancel()
        dragArmWorkItem = nil
    }

    private func beginDrag() {
        guard !isDragging else { return }
        isDragging = true
        onDragChange?(true)
        Haptics.dragStart()
    }

    private func endDrag() {
        guard isDragging else { return }
        isDragging = false
        onDragChange?(false)
        Haptics.dragEnd()
    }

    /// The finger has gone. `flung` is the ordinary lift, which may leave the
    /// page coasting; a cancellation stops it dead, because a gesture the system
    /// took away was not a flick.
    private func releaseScrollStrip(flung: Bool = true) {
        guard scrollTouch != nil else { return }
        scrollTouch = nil
        if flung { scroll.ended() } else { scroll.cancelled() }
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
            let location = touch.location(in: self)
            return CGPoint(x: partial.x + location.x, y: partial.y + location.y)
        }
        return CGPoint(x: sum.x / CGFloat(touches.count), y: sum.y / CGFloat(touches.count))
    }
}

struct TrackpadView: UIViewRepresentable {
    let client: NimletClient
    /// Where the scroll strip is, so the surface can route touches to it. The
    /// view that draws the strip computes this from the same function.
    var scrollStripRect: CGRect = .zero
    /// Two fingers moving together, for the picture above.
    var onPan: ((CGSize) -> Void)?
    var onScrollStripChanged: ((ScrollStripState) -> Void)?
    /// Pinching the pad enlarges the mirror above it. Held by the screen, not
    /// by this view and not by the band that draws the picture, because the
    /// gesture and the picture are several hundred points apart and have to be
    /// looking at the same numbers.
    var onZoom: ((Double) -> Void)?
    var pillRect: CGRect = .zero
    var onPillSteerBegan: (() -> Void)?
    var onPillSteerEnded: (() -> Void)?
    var onPillMoved: ((CGPoint) -> Void)?
    var onPillSlide: ((CGPoint) -> Void)?
    var onPillMoveModeChanged: ((Bool) -> Void)?

    func makeUIView(context: Context) -> TrackpadSurface {
        let view = TrackpadSurface()
        view.onMove = { delta in
            client.sendMove(dx: Double(delta.x), dy: Double(delta.y))
        }
        view.onScroll = { delta in
            client.sendScroll(dx: Double(delta.x), dy: Double(delta.y))
        }
        view.onScrollPhase = { phase in client.sendScroll(phase: phase) }
        view.onClick = { button, count in
            client.send(.click(button: button, phase: .click, clickCount: count))
        }
        view.onDragChange = { isDown in
            client.send(.click(button: .left, phase: isDown ? .down : .up, clickCount: 1))
        }
        view.onZoom = { magnification in onZoom?(magnification) }
        view.onPan = { translation in onPan?(translation) }
        view.onScrollStripChanged = { state in onScrollStripChanged?(state) }
        view.scrollStripRect = scrollStripRect
        // VoiceOver otherwise swallows raw touches and leaves the whole
        // pointer surface dead for the users this app is meant to suit best.
        view.isAccessibilityElement = true
        view.accessibilityTraits = .allowsDirectInteraction
        view.accessibilityLabel = "Trackpad"
        view.accessibilityHint = "Drag to move the pointer, tap to click, tap twice to double click, drag or flick the strip down the right edge to scroll, pinch to enlarge the mirror above, drag two fingers to move it, two-finger tap to right click"
        view.pillRect = pillRect
        view.onPillSteerBegan = onPillSteerBegan
        view.onPillSteerEnded = onPillSteerEnded
        view.onPillMoved = onPillMoved
        view.onPillSlide = onPillSlide
        view.onPillMoveModeChanged = onPillMoveModeChanged
        return view
    }

    func updateUIView(_ uiView: TrackpadSurface, context: Context) {
        uiView.onZoom = { [onZoom] magnification in onZoom?(magnification) }
        uiView.onPan = { [onPan] translation in onPan?(translation) }
        uiView.onScrollStripChanged = { [onScrollStripChanged] state in onScrollStripChanged?(state) }
        uiView.scrollStripRect = scrollStripRect
        uiView.pillRect = pillRect
        uiView.onPillSteerBegan = onPillSteerBegan
        uiView.onPillSteerEnded = onPillSteerEnded
        uiView.onPillMoved = onPillMoved
        uiView.onPillSlide = onPillSlide
        uiView.onPillMoveModeChanged = onPillMoveModeChanged
    }
}
