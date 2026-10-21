import AppKit
import ApplicationServices
import CoreGraphics

/// Posts synthetic HID events. Everything here silently does nothing unless the
/// app holds Accessibility permission, which is why `isTrusted` is surfaced all
/// the way to the phone's UI rather than being checked once at launch.
final class EventInjector {
    static let shared = EventInjector()

    /// Virtual keycodes we need by name.
    enum Key {
        static let v: UInt16 = 0x09
        static let ret: UInt16 = 0x24
        static let escape: UInt16 = 0x35
    }

    /// When paused, every injection call becomes a no-op but the connection
    /// stays up — useful for demoing or when you don't want the cursor stolen.
    ///
    /// Written from the menu bar on main and read on the network and injection
    /// queues, so it goes through the same lock as the held buttons below.
    var isPaused: Bool {
        get { stateLock.withLock { pausedStorage } }
        set { stateLock.withLock { pausedStorage = newValue } }
    }

    private let source = CGEventSource(stateID: .hidSystemState)
    /// Guards the state that both the network queue and main touch.
    ///
    /// `heldButtons` in particular was a bare `Set` read on every pointer move
    /// on the network queue and cleared on main whenever the user paused
    /// injection, the Mac slept, or the app quit. Mutating a Swift Set while
    /// another thread hashes it reallocates the storage underneath that thread,
    /// which is a use-after-free — and the milder outcome, a torn set, leaves a
    /// `leftMouseDown` with no matching up, which is the exact thing
    /// `releaseAllButtons` exists to prevent.
    private let stateLock = NSLock()
    private var pausedStorage = false
    private var heldButtons: Set<MouseButton> = []
    private let pasteboardRestoreDelay: TimeInterval = 0.35

    /// Restores are serialised here so two deliveries close together cannot
    /// race each other back onto the pasteboard.
    private let pasteboardQueue = DispatchQueue(label: "com.renyicao.mice.host.pasteboard")
    private let pasteboardLock = NSLock()
    private var pasteGeneration = 0
    private var savedItems: [NSPasteboardItem]?

    private let displayLock = NSLock()
    private var cachedDisplayRects: [CGRect]?

    private init() {
        // Hot-plugging a screen, changing resolution or rearranging displays
        // all move the rects the cursor is clamped to.
        CGDisplayRegisterReconfigurationCallback({ _, _, _ in
            EventInjector.shared.invalidateDisplayCache()
        }, nil)
    }

    /// `AXIsProcessTrusted` is not the whole story. After an OS update or a long
    /// sleep, TCC can start returning `kAXErrorAPIDisabled` to a process it
    /// still lists as trusted: every injected event then goes nowhere while the
    /// UI cheerfully reports that permission was granted. Only a real AX call
    /// tells the two apart, and that is what `revalidateTrust()` makes — on the
    /// permission poll and after every wake, never on the pointer path.
    /// Written by the trust probe, read from the network and injection queues
    /// on every delivery.
    private var apiDisabled = false
    private let trustQueue = DispatchQueue(label: "com.renyicao.mice.host.trust", qos: .utility)

    var isTrusted: Bool { AXIsProcessTrusted() && !stateLock.withLock { apiDisabled } }

    /// Answers through `isTrusted`, never inline. The system-wide element hands
    /// the question to whichever app is in front, and an app pegged on its own
    /// main thread holds it for the full six-second default timeout. Codex,
    /// answering another program's accessibility queries for twelve minutes,
    /// did exactly that, and on main it froze the menu and every phone request
    /// that hops through main, once every 15 seconds.
    func revalidateTrust() {
        trustQueue.async { [self] in
            var value: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(),
                                                       kAXFocusedUIElementAttribute as CFString,
                                                       &value)
            stateLock.withLock { apiDisabled = (status == .apiDisabled) }
        }
    }

    /// Shows the system prompt once; subsequent calls are cheap no-ops if granted.
    @discardableResult
    func requestAccessibility() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Pointer

    var cursorLocation: CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    func move(dx: Double, dy: Double) {
        guard !isPaused else { return }
        let moveStart = Instrumentation.now()

        let readStart = Instrumentation.now()
        let current = cursorLocation
        Instrumentation.shared.record("1_cursor_read", since: readStart)

        let clampStart = Instrumentation.now()
        let target = clampToDisplays(CGPoint(x: current.x + dx, y: current.y + dy))
        Instrumentation.shared.record("2_clamp", since: clampStart)
        // While a button is held this has to be a drag event, or the app being
        // dragged in never sees the motion.
        let type: CGEventType
        let button: CGMouseButton
        let held = stateLock.withLock { heldButtons }
        if held.contains(.left) {
            type = .leftMouseDragged; button = .left
        } else if held.contains(.right) {
            type = .rightMouseDragged; button = .right
        } else if held.contains(.middle) {
            type = .otherMouseDragged; button = .center
        } else {
            type = .mouseMoved; button = .left
        }

        let buildStart = Instrumentation.now()
        guard let event = CGEvent(mouseEventSource: source, mouseType: type,
                                  mouseCursorPosition: target, mouseButton: button) else { return }
        // Handing macOS the delta (rather than only the absolute point) keeps the
        // system's own pointer acceleration and relative-motion consumers happy.
        event.setIntegerValueField(.mouseEventDeltaX, value: Int64(dx.rounded()))
        event.setIntegerValueField(.mouseEventDeltaY, value: Int64(dy.rounded()))
        Instrumentation.shared.record("3_build", since: buildStart)

        let postStart = Instrumentation.now()
        event.post(tap: .cghidEventTap)
        Instrumentation.shared.record("4_post", since: postStart)
        Instrumentation.shared.record("5_move_total", since: moveStart)
    }

    /// Put the pointer somewhere, rather than nudge it from where it is.
    ///
    /// For a finger on the mirror. A tap there is not a movement at all — it is
    /// a place, already chosen, and the pointer's previous position has nothing
    /// to do with where it should end up. Sending it as a delta would mean
    /// subtracting one from the other and hoping the two ends agree about where
    /// the pointer was, which they do not: the phone last heard about the
    /// pointer's position never.
    ///
    /// The delta is still filled in, because a window being dragged reads it.
    func point(to location: CGPoint) {
        guard !isPaused else { return }
        let current = cursorLocation
        let target = clampToDisplays(location)

        // A held button makes this a drag, exactly as it does for a nudge: the
        // app being dragged in sees no motion otherwise.
        let type: CGEventType
        let button: CGMouseButton
        let held = stateLock.withLock { heldButtons }
        if held.contains(.left) {
            type = .leftMouseDragged; button = .left
        } else if held.contains(.right) {
            type = .rightMouseDragged; button = .right
        } else if held.contains(.middle) {
            type = .otherMouseDragged; button = .center
        } else {
            type = .mouseMoved; button = .left
        }

        guard let event = CGEvent(mouseEventSource: source, mouseType: type,
                                  mouseCursorPosition: target, mouseButton: button) else { return }
        event.setIntegerValueField(.mouseEventDeltaX, value: Int64((target.x - current.x).rounded()))
        event.setIntegerValueField(.mouseEventDeltaY, value: Int64((target.y - current.y).rounded()))
        event.post(tap: .cghidEventTap)
    }

    /// Takes the pointer with the window the phone has just brought forward.
    ///
    /// Raising a window moves keyboard focus and nothing else, which left the
    /// pointer over the window you had just left: the cursor had to be found by
    /// waving the trackpad about, and scroll — which macOS delivers to whatever
    /// the pointer is over rather than to what is focused — kept scrolling the
    /// old window. Switching to a window from the phone is a statement about
    /// where you are working, so the pointer goes there too.
    ///
    /// Does nothing when the pointer is already in that window, so tapping the
    /// tile for the app you are already in never moves anything.
    func follow(window frame: CGRect) {
        guard !isPaused, Self.followsWindows else { return }
        // Mid-drag is the one moment the pointer is already carrying something,
        // and `point(to:)` would turn the jump into a drag across the screen.
        guard stateLock.withLock({ heldButtons.isEmpty }) else { return }
        guard let landing = PointerLanding.landing(in: frame,
                                                  pointer: cursorLocation,
                                                  screens: displayRects()) else { return }
        point(to: landing)
    }

    /// Read once: somebody who turns this off is turning off a behaviour, not
    /// asking to have the question reconsidered on every window switch.
    ///
    /// `defaults write com.renyicao.mice.host mice.followPointer -bool NO`
    private static let followsWindows: Bool = {
        UserDefaults.standard.object(forKey: "mice.followPointer") as? Bool ?? true
    }()

    // MARK: - Scroll

    /// Where the scroll the phone is sending is in its life, and what has to be
    /// stamped on the next event because of it.
    ///
    /// macOS tells a trackpad from a mouse wheel by these two fields and nothing
    /// else. Without them every pixel delta is an unrelated notch of a wheel: no
    /// rubber band at the end of a document, no momentum an app can distinguish
    /// from a finger, and — in the apps that coalesce wheel ticks — a flick
    /// arriving as a lurch. They are cheap and they are the whole difference.
    private struct ScrollPhaseState {
        var gesture: CGScrollPhase?
        var momentum: CGMomentumScrollPhase?
        /// The first event of a phase carries `began`; the ones after it carry
        /// `changed`, and likewise for the coast.
        var hasSentFirst = false
        var lastEventAt = Date.distantPast
    }

    private var scrollPhase = ScrollPhaseState()
    /// Whether a check for an abandoned gesture is already scheduled. Read and
    /// written under `stateLock`.
    private var scrollWatchArmed = false
    private let scrollWatchQueue = DispatchQueue(label: "com.renyicao.mice.host.scroll-watch")

    /// How long a gesture may go quiet before the host closes it out itself.
    ///
    /// The phone always sends its `ended`, but "always" here means "unless the
    /// phone is backgrounded, loses Wi-Fi or is killed mid-flick", and the cost
    /// of a `began` with no `ended` is every scroll view on the Mac believing a
    /// finger is still resting on the glass — stuck mid-rubber-band, refusing to
    /// settle. So the host will not hold one open indefinitely on the phone's
    /// word.
    private let scrollPhaseTimeout: TimeInterval = 0.4

    func scroll(dx: Double, dy: Double) {
        guard !isPaused else { return }
        let phase: (gesture: CGScrollPhase?, momentum: CGMomentumScrollPhase?) =
            stateLock.withLock { stampForScroll() }
        post(scrollDX: dx, dy: dy, gesture: phase.gesture, momentum: phase.momentum)
    }

    func scroll(phase: ScrollGesturePhase) {
        guard !isPaused else { return }
        // Two of the four are only ever a marker: nothing moved, and the point
        // of the event is the field on it. The other two arm the next delta,
        // because a `began` with no movement on it is a gesture with no
        // direction and some apps read the first event's delta to pick an axis.
        switch phase {
        case .began:
            stateLock.withLock {
                scrollPhase = ScrollPhaseState(gesture: .began, momentum: nil,
                                               hasSentFirst: false, lastEventAt: Date())
                armScrollWatch()
            }
        case .momentumBegan:
            stateLock.withLock {
                scrollPhase = ScrollPhaseState(gesture: nil, momentum: .begin,
                                               hasSentFirst: false, lastEventAt: Date())
                armScrollWatch()
            }
        case .ended:
            let live = stateLock.withLock { () -> Bool in
                guard scrollPhase.gesture != nil else { return false }
                scrollPhase = ScrollPhaseState()
                return true
            }
            if live { post(scrollDX: 0, dy: 0, gesture: .ended, momentum: nil) }
        case .momentumEnded:
            let live = stateLock.withLock { () -> Bool in
                guard scrollPhase.momentum != nil else { return false }
                scrollPhase = ScrollPhaseState()
                return true
            }
            if live { post(scrollDX: 0, dy: 0, gesture: nil, momentum: .end) }
        }
    }

    /// What the next delta carries, advancing the state as it goes. Called with
    /// `stateLock` held.
    private func stampForScroll() -> (CGScrollPhase?, CGMomentumScrollPhase?) {
        let now = Date()
        // Gone quiet for too long: whatever was open is over, and this delta is
        // the start of something new rather than the middle of something stale.
        if scrollPhase.gesture != nil || scrollPhase.momentum != nil,
           now.timeIntervalSince(scrollPhase.lastEventAt) > scrollPhaseTimeout {
            scrollPhase = ScrollPhaseState()
        }
        scrollPhase.lastEventAt = now
        armScrollWatch()

        if scrollPhase.momentum != nil {
            let phase: CGMomentumScrollPhase = scrollPhase.hasSentFirst ? .continuous : .begin
            scrollPhase.hasSentFirst = true
            scrollPhase.momentum = .continuous
            return (nil, phase)
        }
        // A delta arriving with no phase at all is either an older phone or one
        // whose `began` was lost. Either way it is the start of a gesture, and
        // opening one here is better than posting an unphased event: the timeout
        // above closes it whatever happens next.
        let phase: CGScrollPhase = scrollPhase.hasSentFirst ? .changed : .began
        scrollPhase.hasSentFirst = true
        scrollPhase.gesture = .changed
        return (phase, nil)
    }

    /// Schedules a look at the gesture once it could have gone quiet. Called
    /// with `stateLock` held.
    ///
    /// The timeout in `stampForScroll` only closes a stale gesture when the
    /// next delta arrives, and a phone that has dropped off the network sends
    /// no next delta — so the `began` it left open stayed open, every scroll
    /// view on the Mac holding its rubber band against a finger that was not
    /// there, until somebody scrolled again. This posts the `ended` itself.
    private func armScrollWatch(after delay: TimeInterval? = nil) {
        guard !scrollWatchArmed else { return }
        scrollWatchArmed = true
        let wait = delay ?? scrollPhaseTimeout + 0.05
        scrollWatchQueue.asyncAfter(deadline: .now() + wait) { [weak self] in
            self?.closeQuietScroll()
        }
    }

    private func closeQuietScroll() {
        enum Close { case gesture, momentum }
        let close = stateLock.withLock { () -> Close? in
            scrollWatchArmed = false
            guard scrollPhase.gesture != nil || scrollPhase.momentum != nil else { return nil }
            let quiet = Date().timeIntervalSince(scrollPhase.lastEventAt)
            guard quiet >= scrollPhaseTimeout else {
                armScrollWatch(after: scrollPhaseTimeout - quiet + 0.05)
                return nil
            }
            let open: Close = scrollPhase.momentum != nil ? .momentum : .gesture
            scrollPhase = ScrollPhaseState()
            return pausedStorage ? nil : open
        }
        switch close {
        case .gesture: post(scrollDX: 0, dy: 0, gesture: .ended, momentum: nil)
        case .momentum: post(scrollDX: 0, dy: 0, gesture: nil, momentum: .end)
        case nil: break
        }
    }

    private func post(scrollDX dx: Double, dy: Double,
                      gesture: CGScrollPhase?, momentum: CGMomentumScrollPhase?) {
        guard let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel,
                                  wheelCount: 2,
                                  wheel1: Int32(dy.rounded()),
                                  wheel2: Int32(dx.rounded()),
                                  wheel3: 0) else { return }
        // Pixel units already imply this, but an app reading the field rather
        // than the units gets the same answer this way.
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        if let gesture {
            event.setIntegerValueField(.scrollWheelEventScrollPhase,
                                       value: Int64(gesture.rawValue))
        }
        if let momentum {
            event.setIntegerValueField(.scrollWheelEventMomentumPhase,
                                       value: Int64(momentum.rawValue))
        }
        event.post(tap: .cghidEventTap)
    }

    /// Drops any open scroll phase without telling anyone, for pausing and
    /// quitting — where the connection is going away and there is no gesture
    /// left to close.
    func forgetScrollPhase() {
        stateLock.withLock { scrollPhase = ScrollPhaseState() }
    }

    func click(button: MouseButton, phase: ClickPhase, clickCount: Int = 1, at position: CGPoint? = nil) {
        guard !isPaused else { return }
        switch phase {
        case .down: postMouse(button: button, down: true, clickCount: clickCount, at: position)
        case .up:   postMouse(button: button, down: false, clickCount: clickCount, at: position)
        case .click:
            postMouse(button: button, down: true, clickCount: clickCount, at: position)
            postMouse(button: button, down: false, clickCount: clickCount, at: position)
        }
    }

    /// Releases anything still held. For quitting and for pausing, where every
    /// held button really is ours to drop.
    func releaseAllButtons() {
        // Taken and cleared in one step, then posted outside the lock: posting a
        // CGEvent is not something to do while holding a lock the pointer hot
        // path needs.
        let held = stateLock.withLock { () -> Set<MouseButton> in
            let snapshot = heldButtons
            heldButtons.removeAll()
            return snapshot
        }
        for button in held { post(button: button, down: false, clickCount: 1) }
    }

    /// Releases only what one phone was holding, for when that phone vanishes
    /// mid-drag. Dropping everything instead meant a stranger connecting and
    /// disconnecting cancelled the drag the real user was in the middle of.
    func release(buttons: Set<MouseButton>) {
        let mine = stateLock.withLock { () -> Set<MouseButton> in
            let owned = heldButtons.intersection(buttons)
            heldButtons.subtract(owned)
            return owned
        }
        for button in mine { post(button: button, down: false, clickCount: 1) }
    }

    private func postMouse(button: MouseButton, down: Bool, clickCount: Int, at position: CGPoint? = nil) {
        post(button: button, down: down, clickCount: clickCount, at: position)
        stateLock.withLock {
            if down { heldButtons.insert(button) } else { heldButtons.remove(button) }
        }
    }

    /// Posts the event and nothing else, for the release paths that have
    /// already updated `heldButtons` under the lock.
    private func post(button: MouseButton, down: Bool, clickCount: Int, at point: CGPoint? = nil) {
        let position = point.map(clampToDisplays) ?? cursorLocation
        let type: CGEventType
        let cgButton: CGMouseButton
        switch button {
        case .left:   type = down ? .leftMouseDown : .leftMouseUp;   cgButton = .left
        case .right:  type = down ? .rightMouseDown : .rightMouseUp; cgButton = .right
        case .middle: type = down ? .otherMouseDown : .otherMouseUp; cgButton = .center
        }
        guard let event = CGEvent(mouseEventSource: source, mouseType: type,
                                  mouseCursorPosition: position, mouseButton: cgButton) else { return }
        event.setIntegerValueField(.mouseEventClickState, value: Int64(max(1, clickCount)))
        event.post(tap: .cghidEventTap)
    }

    // MARK: - Keyboard

    func pressKey(_ keyCode: UInt16, flags: CGEventFlags = []) {
        guard !isPaused else { return }
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else { return }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    /// Pasteboard + Cmd-V, then put the user's clipboard back. This is the
    /// reliable path for a paragraph of dictated text.
    ///
    /// What goes back matters as much as that something does. Saving only
    /// `.string` destroyed a copied image or file outright, and a fixed delay
    /// with no reentrancy guard meant two deliveries inside the same window
    /// left the *second* one's transcript sitting on the clipboard for good.
    func paste(_ string: String) {
        pasteWriting { pasteboard in
            let item = NSPasteboardItem()
            item.setString(string, forType: .string)
            EventInjector.markTransient(item)
            pasteboard.writeObjects([item])
        }
    }

    /// The nspasteboard.org convention, honoured by the clipboard managers
    /// people actually run: this item is in transit and should not be kept.
    /// Without it every dictated sentence ended up in Paste, Maccy and Raycast's
    /// history — and, through Universal Clipboard, on the user's other devices
    /// — for the 0.35 s it sat on the pasteboard.
    private static let transientTypes = [
        NSPasteboard.PasteboardType("org.nspasteboard.TransientType"),
        NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"),
    ]

    static func markTransient(_ item: NSPasteboardItem) {
        for type in transientTypes { item.setData(Data(), forType: type) }
    }

    /// The same, for a file on disk that happens to be an image.
    ///
    /// One pasteboard item carrying both representations: an app whose composer
    /// takes pixels reads `public.png`, one that takes files reads the file URL,
    /// and neither has to be guessed at from here. Writing two separate items
    /// instead would leave an app that reads only the first one attaching
    /// whichever we happened to put there.
    func paste(imageAt url: URL, format: AttachmentFrame.Format) {
        guard let data = try? Data(contentsOf: url) else { return }
        pasteWriting { pasteboard in
            let item = NSPasteboardItem()
            item.setData(data, forType: NSPasteboard.PasteboardType(rawValue: format.uniformTypeIdentifier))
            item.setString(url.absoluteString, forType: .fileURL)
            EventInjector.markTransient(item)
            pasteboard.writeObjects([item])
        }
    }

    /// Pasteboard + Cmd-V, then put the user's clipboard back.
    private func pasteWriting(_ write: (NSPasteboard) -> Void) {
        guard !isPaused else { return }
        let pasteboard = NSPasteboard.general

        pasteboardLock.lock()
        pasteGeneration += 1
        let generation = pasteGeneration
        // Only the first paste of a burst sees the user's own clipboard; a
        // later one would snapshot the transcript we just wrote.
        if savedItems == nil { savedItems = EventInjector.snapshot(pasteboard) }
        pasteboardLock.unlock()

        pasteboard.clearContents()
        write(pasteboard)
        let writtenChangeCount = pasteboard.changeCount

        // The frontmost app needs a beat to notice it was raised before it will
        // accept the keystroke.
        Thread.sleep(forTimeInterval: 0.04)
        pressKey(Key.v, flags: .maskCommand)

        pasteboardQueue.asyncAfter(deadline: .now() + pasteboardRestoreDelay) { [self] in
            // The lock is held across the restore. Releasing it first left a gap
            // in which `savedItems` was already nil while the transcript was
            // still on the pasteboard, so a paste starting in that gap saved the
            // transcript as though it were the user's own clipboard and handed
            // it back to them afterwards. `pasteboardQueue` is serial and does
            // nothing else, so holding the lock here blocks nothing that matters.
            pasteboardLock.lock()
            defer { pasteboardLock.unlock() }
            let isLatest = generation == pasteGeneration
            let items = isLatest ? savedItems : nil
            if isLatest { savedItems = nil }

            guard let items else { return }
            // Someone copied something of their own while we were waiting;
            // their clipboard is now more current than the one we saved.
            guard pasteboard.changeCount == writtenChangeCount else { return }
            pasteboard.clearContents()
            // An empty snapshot means the user had nothing on the clipboard
            // before this delivery, and bailing out on it left the dictated
            // text sitting there for the rest of the session — the opposite of
            // what restoring is for. Clearing is the restore in that case.
            if !items.isEmpty { pasteboard.writeObjects(items) }
        }
    }

    /// Copies every representation of every item, not just the plain text one.
    private static func snapshot(_ pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                guard let data = item.data(forType: type) else { continue }
                copy.setData(data, forType: type)
            }
            return copy
        }
    }

    func pressReturn() {
        // A short gap after a paste; otherwise the Return can land before the
        // pasted text is committed to the field.
        Thread.sleep(forTimeInterval: 0.06)
        pressKey(Key.ret)
    }

    // MARK: - Geometry

    func invalidateDisplayCache() {
        displayLock.withLock { cachedDisplayRects = nil }
    }

    /// Keeps the cursor on a display that can actually draw it.
    ///
    /// Clamping to the union of the displays looks equivalent and is not: on an
    /// L-shaped arrangement the union covers a rectangle no screen occupies, so
    /// the cursor could be pushed into the gap and parked somewhere invisible.
    private func clampToDisplays(_ point: CGPoint) -> CGPoint {
        let rects = displayRects()
        guard !rects.isEmpty else { return point }
        if rects.contains(where: { $0.contains(point) }) { return point }

        var best = point
        var bestDistance = Double.infinity
        for rect in rects {
            let clamped = CGPoint(x: min(max(point.x, rect.minX), rect.maxX - 1),
                                  y: min(max(point.y, rect.minY), rect.maxY - 1))
            let distance = hypot(clamped.x - point.x, clamped.y - point.y)
            if distance < bestDistance {
                bestDistance = distance
                best = clamped
            }
        }
        return best
    }

    /// Cached because this is read on every pointer move, and the display list
    /// only changes when the reconfiguration callback says it did.
    private func displayRects() -> [CGRect] {
        if let cached = displayLock.withLock({ cachedDisplayRects }) { return cached }

        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        let rects = ids.prefix(Int(count)).map { CGDisplayBounds($0) }

        displayLock.withLock { cachedDisplayRects = rects }
        return rects
    }
}
