import Foundation
import ScreenCaptureKit
import CoreMedia
import AppKit

/// Streams one window with ScreenCaptureKit.
///
/// The filter is `desktopIndependentWindow`, which keeps producing frames while
/// the window sits behind your editor. That is the normal case here — you are
/// looking at the phone precisely because the agent's window is buried — and a
/// display-based filter would hand back whatever is on top instead.
final class WindowCapture: NSObject, SCStreamOutput, SCStreamDelegate {

    private let queue = DispatchQueue(label: "com.renyicao.mice.host.capture")
    /// The pixels, when they were captured, what fraction of the window they
    /// are — and which window, by generation, so that a frame from a stream
    /// that has since been replaced cannot be mistaken for one of the new one.
    /// The last argument says the frame is a refinement pass over a picture
    /// already sent (`StillRefinement`); the result, whether it was taken.
    private let onFrame: (CVPixelBuffer, CMTime, CGRect, Int, Bool) -> Bool
    private let onState: (String, Bool) -> Void

    private var stream: SCStream?
    private var windowID: CGWindowID?
    /// The one window this capture is allowed to show, when the target names
    /// one. Set, nothing else is ever resolved to: a mirror that quietly moved
    /// to another window would be showing one thing while the keystrokes went
    /// to another.
    private var pinnedWindowID: CGWindowID?
    private var configuredSize: CGSize = .zero
    private var configuredRect: CGRect = .zero
    private var bundleID: String?
    private var applicationPath: String?
    private var appIdentity: AppInstanceIdentity?
    private var maxWidth = 1179
    private var maxHeight = 2556
    /// The fraction of the window the viewer is looking at.
    private var crop = CGRect(x: 0, y: 0, width: 1, height: 1)
    private let fitLock = NSLock()
    private var fitAspect: Double?
    private var autoFit = WindowAutoFit()
    private var watchdog: DispatchSourceTimer?
    /// The watchdog and an explicit start can both land here; resolving twice at
    /// once would leave two streams running with one of them unreachable.
    private let resolveLock = NSLock()
    private var isResolving = false
    /// Delivered vs used, once a second. The two ways a mirror goes still look
    /// identical from the phone — the window is not being redrawn, or we are
    /// discarding what arrives — and this is what tells them apart.
    private var statusCounts: [Int: Int] = [:]
    private var isLocked = false
    /// What the stream is actually showing, as fractions of the window. Not the
    /// same as what was asked for: a crop gets clamped to a minimum size and to
    /// the window's edges.
    private var appliedCrop = CGRect(x: 0, y: 0, width: 1, height: 1)
    private var windowStart = Date()

    /// Where the window being captured sits on the Mac's screens, in the
    /// top-left-origin space `CGEvent` uses for the pointer.
    ///
    /// Published because a phone can point into the picture — a touch on the
    /// mirror is a place in this window — and this is the only end that knows
    /// where the window is. Written on the resolve pass, which runs every 1.5
    /// seconds and after every window change, and read on the network queue.
    var windowFrame: CGRect? { frameLock.withLock { resolvedFrame } }
    /// Which window that is, for the same readers. Nil exactly when
    /// `windowFrame` is.
    var resolvedWindowID: CGWindowID? { frameLock.withLock { resolvedFrame == nil ? nil : resolvedID } }
    private let frameLock = NSLock()
    private var resolvedFrame: CGRect?
    private var resolvedID: CGWindowID?

    /// Where the pointer is inside the window being captured, as fractions of
    /// it, or nil when it is somewhere else entirely.
    ///
    /// `CGEvent(source: nil)?.location` rather than `NSEvent.mouseLocation`, and
    /// the difference is not cosmetic: the two use opposite vertical origins, and
    /// `windowFrame` is in the top-left space `CGEvent` uses because that is the
    /// space the pointer is *injected* in. Mixing them would put the phone's
    /// magnifier at the reflection of the cursor rather than on it.
    ///
    /// Read once per frame, which sounds expensive and is not: it is a struct
    /// read out of the window server, and frames are only produced when
    /// something changed — which, for a pointer moving over a captured window,
    /// is exactly when this answer has moved too.
    var pointerInWindow: UnitSpot? {
        guard let frame = frameLock.withLock({ resolvedFrame }),
              frame.width > 0, frame.height > 0 else { return nil }
        guard let location = CGEvent(source: nil)?.location else { return nil }
        return UnitSpot(inside: CGPoint(x: (location.x - frame.minX) / frame.width,
                                        y: (location.y - frame.minY) / frame.height))
    }

    /// Which window this is, counted rather than named.
    ///
    /// It steps every time the mirror changes windows, and nothing else moves
    /// it — a window being dragged or resized keeps its number. The streamer
    /// stamps the frames it sends with the number they were captured under, so
    /// that "has the phone been sent a picture of *this* window yet" is a
    /// question with an answer rather than an interval.
    var windowGeneration: Int { frameLock.withLock { generation } }
    private var generation = 0

    /// How round this window's corners are, as a fraction of its width — the
    /// part of it the stream cannot carry. Measured once per window, because
    /// it is a property of the window and not of the frame.
    var cornerFraction: Double? { frameLock.withLock { resolvedCorner } }
    private var resolvedCorner: Double?
    private var wantsFrame = false

    /// The last picture handed on, held so a window that stops moving can be
    /// sent again until it is sharp. One surface out of the stream's five.
    private struct Picture {
        let buffer: CVPixelBuffer
        let crop: CGRect
        let generation: Int
    }
    private var lastPicture: Picture?
    private var refinement = StillRefinement()
    /// Bumped whenever the pending pass is superseded, so a pass already on
    /// the queue knows it is stale. Guarded by `frameLock`.
    private var refinementTicket = 0
    /// The pass waiting to run. A moving window replaces it with every frame,
    /// so it is cancelled rather than left to find out it is stale. `queue` only.
    private var pendingRefinement: DispatchWorkItem?

    init(onFrame: @escaping (CVPixelBuffer, CMTime, CGRect, Int, Bool) -> Bool,
         onState: @escaping (String, Bool) -> Void) {
        self.onFrame = onFrame
        self.onState = onState
    }

    // MARK: - Lifecycle

    func start(bundleID: String?, windowID: CGWindowID? = nil,
               applicationPath: String? = nil, appIdentity: AppInstanceIdentity? = nil,
               maxWidth: Int, maxHeight: Int, crop: CGRect, fitAspect: Double? = nil) {
        self.bundleID = bundleID
        self.applicationPath = applicationPath
        self.appIdentity = appIdentity
        self.pinnedWindowID = windowID
        self.maxWidth = maxWidth
        self.maxHeight = maxHeight
        self.crop = crop
        fitLock.withLock { self.fitAspect = WindowAutoFit.validAspect(fitAspect) }
        guard ScreenAccess.isGranted else {
            // Puts Nimlet in the Screen Recording list and shows the prompt, so
            // there is something to switch on.
            ScreenAccess.requestOnceIfNeeded()
            onState("Grant Screen Recording to Nimlet on your Mac, then relaunch it", false)
            return
        }
        Task { await resolveAndApply(restartIfNeeded: true) }
        startWatchdog()
    }

    func stop() {
        fitLock.withLock { fitAspect = nil; autoFit.reset() }
        watchdog?.cancel()
        watchdog = nil
        stopStreamOnly()
    }

    /// A window can be moved to another display, resized, closed or replaced by
    /// a newer one of the same app. None of that produces a notification, so
    /// re-resolve on a slow timer rather than trusting the first answer forever.
    private func startWatchdog() {
        watchdog?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1.5, repeating: 1.5, leeway: .milliseconds(250))
        timer.setEventHandler { [weak self] in
            Task { await self?.resolveAndApply(restartIfNeeded: false) }
        }
        timer.resume()
        watchdog = timer
    }

    // MARK: - Window resolution

    private func resolveAndApply(restartIfNeeded: Bool) async {
        let claimed = resolveLock.withLock { () -> Bool in
            guard !isResolving else { return false }
            isResolving = true
            return true
        }
        guard claimed else { return }
        defer { resolveLock.withLock { isResolving = false } }

        let selectedBundle = bundleID
        let selectedPath = applicationPath
        let selectedIdentity = appIdentity
        let selectedWindow = pinnedWindowID
        guard let window = await resolveWindow() else {
            if restartIfNeeded || stream != nil {
                stopStreamOnly()
                // `resolveWindow` may already have said something more useful.
                if !isLocked, pinnedWindowID == nil {
                    // The app's name, not its bundle identifier: nobody
                    // recognises com.todesktop.230313mzl4w4u92 as Cursor.
                    let name = bundleID.map { id in
                        NSRunningApplication.runningApplications(withBundleIdentifier: id).first?.localizedName
                            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
                                .map { FileManager.default.displayName(atPath: $0.path) }
                            ?? id
                    }
                    onState(name.map { "\($0) has no window open to mirror" } ?? "Nothing focused to mirror", false)
                }
            }
            return
        }
        // Resolution awaits the window server. Do not resize a window from a
        // selection that has already been replaced in the meantime.
        guard selectedBundle == bundleID, selectedWindow == pinnedWindowID,
              selectedPath == applicationPath, selectedIdentity == appIdentity else { return }
        guard window.isOnScreen else {
            stopStreamOnly()
            // Off-screen is not proof of minimization: a closed AX window may remain in SCK.
            if let selectedBundle, AXIsProcessTrusted() {
                let state = WindowRoster.state(of: window.windowID, bundleID: selectedBundle, applicationPath: selectedPath)
                if !state.exists {
                    let name = AppRegistry.running(AppReference(bundleID: selectedBundle, applicationPath: selectedPath))?.localizedName ?? "This app"
                    onState(selectedWindow == nil ? "\(name) has no window open to mirror"
                        : "The window you picked has closed — pick another on your phone", false)
                } else if state.minimised {
                    onState("\(state.title.isEmpty ? "That window" : state.title) is minimised", true)
                } else if AppRegistry.running(AppReference(bundleID: selectedBundle, applicationPath: selectedPath))?.isHidden == true {
                    onState("That app is hidden — show it from All apps", false)
                } else { onState("That window is not visible on this desktop — choose it from All apps", false) }
            } else { onState("That window is not visible on this desktop", false) }
            return
        }

        let aspectToFit = fitLock.withLock { () -> Double? in
            autoFit.shouldFit(windowID: window.windowID, size: window.frame.size,
                              aspect: fitAspect) ? fitAspect : nil
        }
        if let aspectToFit,
           WindowRoster.reshape(windowID: window.windowID, aspect: CGFloat(aspectToFit)) {
            miceLog.info("view: auto-fit window \(window.windowID) to aspect \(aspectToFit)")
            if let windowID, windowID != window.windowID { stopStreamOnly() }
            // AX returns before the window server publishes the new frame.
            // Resolve it again before updating capture and touch coordinates.
            refresh()
            return
        }

        frameLock.withLock {
            if windowID != window.windowID { generation += 1 }
            resolvedFrame = window.frame
            resolvedID = window.windowID
        }
        noteCorner(of: window)

        let region = sourceRect(for: window)
        let size = outputSize(for: window, region: region)
        let normalised = normalise(region, in: window)
        if let stream, windowID == window.windowID {
            guard size != configuredSize || region != configuredRect else { return }
            configuredSize = size
            configuredRect = region
            try? await stream.updateConfiguration(configuration(size: size, sourceRect: region))
            // Only once the new configuration is in force. Labelling frames with
            // the region they are *about* to show means the ones still in flight
            // claim to be a crop while they are still the whole window, and the
            // viewer briefly draws them at the wrong scale.
            appliedCrop = normalised
            return
        }

        stopStreamOnly()
        windowID = window.windowID
        configuredSize = size
        configuredRect = region
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let stream = SCStream(filter: filter,
                              configuration: configuration(size: size, sourceRect: region),
                              delegate: self)
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            try await stream.startCapture()
            appliedCrop = normalised
            self.stream = stream
            // The frames this stream delivered while it was starting were
            // dropped, because it was not yet the current one — including the
            // first full frame `SCStream` always sends. A window that is not
            // being redrawn produces nothing else, so ask for one.
            requestFrame()
            let cropNote = region == .zero ? "" : " crop \(Int(region.width))x\(Int(region.height))@\(Int(region.origin.x)),\(Int(region.origin.y))"
            // The title is private: it is a document name, a mail subject or
            // a URL as often as not, and the log goes into bug reports.
            miceLog.info("view: capturing \(window.title ?? "window", privacy: .private) at \(Int(size.width))x\(Int(size.height))\(cropNote, privacy: .public)")
        } catch {
            self.stream = nil
            onState("Capture failed: \(error.localizedDescription)", false)
        }
    }

    /// Look at the window again now rather than at the next watchdog tick.
    ///
    /// For a resize this end caused: the watchdog would notice it within 1.5
    /// seconds, and that is 1.5 seconds of the old shape squeezed into the new
    /// one on the phone while somebody's thumb is still on the handle.
    ///
    /// Three times, because the window server is not done when Accessibility
    /// returns: the first look often still sees the old frame, and a single
    /// look would leave the capture at the old shape until the watchdog.
    func refresh() {
        for delay in [0, 0.15, 0.45] {
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                Task { await self?.resolveAndApply(restartIfNeeded: false) }
            }
        }
    }

    private func stopStreamOnly() {
        let stream = self.stream
        self.stream = nil
        windowID = nil
        // Nothing is being mirrored, so there is nowhere for a touch on the
        // phone's picture to land. Stale coordinates would put the pointer
        // wherever that window used to be.
        frameLock.withLock {
            resolvedFrame = nil
            resolvedCorner = nil
            generation += 1
            lastPicture = nil
            refinementTicket += 1
        }
        configuredSize = .zero
        configuredRect = .zero
        Task { try? await stream?.stopCapture() }
    }

    /// One frame, please, even if nothing has changed.
    ///
    /// A viewer that has just attached — or that has handed its decoder a new
    /// layer, which is what going in and out of the full-screen mirror does —
    /// has nothing to draw until a keyframe arrives, and a keyframe is only
    /// produced when something is encoded. On a Mac whose screen is not moving,
    /// nothing is: every frame comes back `.idle` and is dropped, which is what
    /// keeps a still window at zero cost. So the drop is suspended for exactly
    /// one frame.
    func requestFrame() {
        frameLock.withLock { wantsFrame = true }
    }

    /// The corner the window server will mask this window into, as a fraction
    /// of its width. Cheap enough to do on every resolve — it is arithmetic,
    /// not a capture. See `WindowCorner` for what it is and is not.
    private func noteCorner(of window: SCWindow) {
        let fraction = WindowCorner.radiusFraction(of: window)
        frameLock.withLock { resolvedCorner = fraction }
    }

    /// Nothing renders behind the lock screen, so every frame comes back idle
    /// and the mirror is a still picture with no explanation. Say it instead.
    private static let lockScreenBundleID = "com.apple.loginwindow"

    private func resolveWindow() async -> SCWindow? {
        // onScreenWindowsOnly: false so a window that is merely covered still
        // counts; `isOnScreen` is checked separately to catch minimised ones.
        // Desktop windows are filtered out below anyway, so there is no reason
        // to have WindowServer marshal them across every 1.5 seconds.
        guard let content = try? await SCShareableContent.excludingDesktopWindows(
            true, onScreenWindowsOnly: false) else { return nil }

        let wanted = bundleID ?? NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let app = appIdentity.flatMap { AppRegistry.shared.resolvePinned($0) }
            ?? (appIdentity == nil ? wanted.flatMap { AppRegistry.running(AppReference(bundleID: $0, applicationPath: applicationPath)) } : nil)
        guard let app else { onState("That app is not running or its instance changed — choose it in All apps", false); return nil }
        let wantedPID = app.processIdentifier
        guard let wanted else { return nil }
        guard wanted != Self.lockScreenBundleID else {
            isLocked = true
            onState("Your Mac is locked", false)
            return nil
        }
        isLocked = false

        // Pinned: that window or nothing. Not "that window, or the best one
        // like it" — the mirror is what tells the user which window they are
        // talking to, so it has to be wrong loudly rather than plausibly.
        if let pinnedWindowID {
            guard let window = content.windows.first(where: { $0.windowID == pinnedWindowID && $0.owningApplication?.processID == wantedPID }) else {
                onState("The window you picked has closed — pick another on your phone", false)
                return nil
            }
            return window
        }

        let candidates = content.windows.filter { window in
            window.owningApplication?.processID == wantedPID
                && window.windowLayer == 0
                && window.frame.width > 120
                && window.frame.height > 120
                // SCK can retain closed windows. Only an explicit window pin should report a lost window.
                && (window.isOnScreen || !AXIsProcessTrusted()
                    || WindowRoster.state(of: window.windowID, bundleID: wanted, applicationPath: applicationPath).exists)
        }
        // The window the app has in front, by the window server's stacking
        // order. Not `isActive`: that is true for every window of the active
        // app, so the biggest one always won and a click on another window
        // never moved the mirror. See `WindowOrdering.front`.
        let front = WindowOrdering.front(
            of: candidates.map { WindowOrdering.Candidate(id: $0.windowID, isOnScreen: $0.isOnScreen,
                                                          area: Double($0.frame.width * $0.frame.height)) },
            stacking: WindowRoster.stackingOrder(processID: wantedPID))
        return candidates.first { $0.windowID == front }
    }

    /// The ceiling on either side of the encoded frame.
    ///
    /// It used to be 1920, which quietly halved a window on a 4K display and
    /// sent a phone 24% fewer pixels than its own screen can show. 2560 covers
    /// the long edge of any current iPhone with room to pinch into, and a
    /// hardware HEVC encoder does not notice the difference.
    /// Overridable for tuning:
    ///   defaults write com.renyicao.mice.host mice.maxEncodedSide -int 3840
    private static let maxEncodedSide: Double = {
        let override = UserDefaults.standard.double(forKey: "mice.maxEncodedSide")
        return override >= 640 ? override : 2560
    }()

    /// How far a small crop may be enlarged before encoding.
    private static let maxUpscale = 2.5

    /// The captured region as fractions of the window, which is what the viewer
    /// needs to tell whether a frame is the region it asked for.
    private func normalise(_ region: CGRect, in window: SCWindow) -> CGRect {
        guard region != .zero, window.frame.width > 0, window.frame.height > 0 else {
            return CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        return CGRect(x: region.origin.x / window.frame.width,
                      y: region.origin.y / window.frame.height,
                      width: region.width / window.frame.width,
                      height: region.height / window.frame.height)
    }

    /// The part of the window to capture, in the window's own points.
    ///
    /// An empty rect means all of it; ScreenCaptureKit treats `.zero` as "no
    /// crop", which is exactly the right default.
    private func sourceRect(for window: SCWindow) -> CGRect {
        guard crop != CGRect(x: 0, y: 0, width: 1, height: 1) else { return .zero }
        // Never so small that the encoder is handed a handful of pixels.
        let width = max(crop.width * window.frame.width, 32)
        let height = max(crop.height * window.frame.height, 32)
        let x = min(max(crop.origin.x * window.frame.width, 0), window.frame.width - width)
        let y = min(max(crop.origin.y * window.frame.height, 0), window.frame.height - height)
        return CGRect(x: x.rounded(), y: y.rounded(), width: width.rounded(), height: height.rounded())
    }

    /// Fits the captured region into the viewer's pixel box with 1.5x headroom so
    /// pinching in shows detail rather than blur, capped so the encoder stays
    /// cheap. Zoomed in, the region is smaller, so it arrives at a far higher
    /// effective resolution for the same number of encoded pixels — that is the
    /// whole point of sending the crop rather than the window.
    private func outputSize(for window: SCWindow, region: CGRect) -> CGSize {
        let backingScale = NSScreen.main?.backingScaleFactor ?? 2
        let captured = region == .zero ? window.frame.size : region.size
        let source = CGSize(width: captured.width * backingScale,
                            height: captured.height * backingScale)
        let boxLong = min(Self.maxEncodedSide, Double(max(maxWidth, maxHeight)) * 1.5)
        let boxShort = min(Self.maxEncodedSide, Double(min(maxWidth, maxHeight)) * 1.5)
        let sourceLong = max(source.width, source.height)
        let sourceShort = min(source.width, source.height)
        // Upscaling adds no information, but it does decide *who* resamples.
        // Left at native the phone stretches the picture across its screen with
        // the GPU's bilinear filter, which is the mushiest option available;
        // scaling here hands the job to a better one and then encodes the
        // result. Only ever kicks in for a crop small enough to need it.
        let scale = min(boxLong / sourceLong, boxShort / sourceShort, Self.maxUpscale)
        // H.264/HEVC want even dimensions; odd ones are quietly rounded and the
        // aspect drifts.
        return CGSize(width: (source.width * scale).evenRounded,
                      height: (source.height * scale).evenRounded)
    }

    private static let fill = CGColor(gray: 0, alpha: 1)

    private func configuration(size: CGSize, sourceRect region: CGRect) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.width = Int(size.width)
        config.height = Int(size.height)
        config.sourceRect = region
        config.scalesToFit = true
        config.preservesAspectRatio = true
        config.showsCursor = true
        config.capturesAudio = false
        config.shouldBeOpaque = true
        // Whatever the window does not cover is drawn in this. It does not
        // cover all of the frame for a moment whenever it changes shape — the
        // configuration is for the old shape until the next resolve — and the
        // default fill showed as a white strip down the side of the mirror.
        // Black is the phone's own background, so the moment passes unseen.
        //
        // The property is `assign`: the configuration does not retain the
        // colour. A temporary is freed as soon as this line ends, and SCStream
        // copying the configuration then retains a dead object and traps. The
        // colour has to outlive every configuration, so it is a static.
        config.backgroundColor = Self.fill
        config.ignoreShadowsSingleWindow = true
        config.queueDepth = 5
        // Straight into the encoder's native format — no colour conversion pass.
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        config.colorSpaceName = CGColorSpace.sRGB
        // A ceiling, not a target: idle frames are dropped below, so a still
        // terminal costs nothing while a scrolling one can use all of it.
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        return config
    }

    // MARK: - Frames

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        // Stopping an `SCStream` is asynchronous, so the stream that was
        // replaced a moment ago goes on delivering for a while. Those frames
        // are of the window before this one: encoded, they decode into the old
        // window's pixels, and stamped with the generation read at encode time
        // they would say the phone has been shown the new one. Identity is the
        // only thing that separates them.
        guard stream === self.stream else { return }
        // Bridged once. This deep-converts a CFArray of CFDictionaries — dirty
        // rects, content rect, display time — so doing it twice a frame at 60 Hz
        // was dozens of allocations per frame for a single integer.
        let rawStatus = (CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[SCStreamFrameInfo: Any]])?.first?[.status] as? Int
        statusCounts[rawStatus ?? -1, default: 0] += 1
        reportRate()

        // `.idle` means "nothing changed since the last frame". Dropping these is
        // what keeps a static agent pane at zero CPU and zero bandwidth while
        // still allowing 60 fps the moment it scrolls — except for the one
        // frame somebody has explicitly asked for, which is how a viewer with
        // an empty layer gets something to draw without waiting for the Mac's
        // user to move something.
        let asked = frameLock.withLock { () -> Bool in
            guard wantsFrame else { return false }
            wantsFrame = false
            return true
        }
        guard SCFrameStatus(rawValue: rawStatus ?? -1) == .complete || asked,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let current = frameLock.withLock { generation }
        _ = onFrame(pixelBuffer, CMSampleBufferGetPresentationTimeStamp(sampleBuffer), appliedCrop, current, false)
        // Whatever happens to the passes over the last picture, they are over
        // a picture the window has moved on from.
        let ticket = frameLock.withLock { () -> Int in
            lastPicture = Picture(buffer: pixelBuffer, crop: appliedCrop, generation: current)
            refinement.pictureChanged()
            refinementTicket += 1
            return refinementTicket
        }
        scheduleRefinement(ticket)
    }

    // MARK: - Refinement

    /// The next pass over the last picture, if the window is still by then.
    /// Called on `queue`.
    private func scheduleRefinement(_ ticket: Int) {
        pendingRefinement?.cancel()
        let pass = DispatchWorkItem { [weak self] in self?.refine(ticket) }
        pendingRefinement = pass
        queue.asyncAfter(deadline: .now() + StillRefinement.interval, execute: pass)
    }

    /// Runs on `queue`, where live frames arrive, so a pass and a live frame
    /// are never handed to the streamer at once.
    private func refine(_ ticket: Int) {
        let picture = frameLock.withLock { () -> Picture? in
            guard ticket == refinementTicket, let lastPicture, lastPicture.generation == generation else { return nil }
            return lastPicture
        }
        guard let picture, stream != nil else { return }
        let taken = onFrame(picture.buffer, CMClockGetTime(CMClockGetHostTimeClock()),
                            picture.crop, picture.generation, true)
        let again = frameLock.withLock { () -> Bool in
            guard ticket == refinementTicket else { return false }
            guard refinement.offered(taken: taken) else {
                // Done: give the surface back to the stream.
                lastPicture = nil
                return false
            }
            return true
        }
        if again { scheduleRefinement(ticket) }
    }

    /// Off unless someone asked for numbers, like every other perf counter here:
    /// a log line every second for as long as anyone is mirroring is exactly
    /// what `Instrumentation` exists to avoid.
    private func reportRate() {
        guard Instrumentation.isEnabled else { return }
        let elapsed = Date().timeIntervalSince(windowStart)
        guard elapsed >= 1 else { return }
        let total = statusCounts.values.reduce(0, +)
        let changed = statusCounts[SCFrameStatus.complete.rawValue] ?? 0
        let histogram = statusCounts.sorted { $0.key < $1.key }
            .map { "\(Self.statusName($0.key))=\($0.value)" }
            .joined(separator: " ")
        miceLog.info("capture: \(Double(total) / elapsed, format: .fixed(precision: 0))/s delivered, \(Double(changed) / elapsed, format: .fixed(precision: 0))/s changed, status \(histogram, privacy: .public)")
        statusCounts.removeAll(keepingCapacity: true)
        windowStart = Date()
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        miceLog.error("view: stream stopped \(error.localizedDescription, privacy: .public)")
        self.stream = nil
        windowID = nil
        onState("Capture stopped: \(error.localizedDescription)", false)
    }
}

extension WindowCapture {
    /// `SCFrameStatus` raw values, so the log reads as words. A run of nothing
    /// but `idle` means the window is not being redrawn — occluded, or behind
    /// the lock screen — not that Nimlet is dropping anything.
    static func statusName(_ raw: Int) -> String {
        switch raw {
        case 0: return "complete"
        case 1: return "idle"
        case 2: return "blank"
        case 3: return "suspended"
        case 4: return "started"
        case 5: return "stopped"
        default: return "status\(raw)"
        }
    }
}

private extension Double {
    var evenRounded: Double { (self / 2).rounded() * 2 }
}

private extension CGFloat {
    var evenRounded: CGFloat { CGFloat(Double(self).evenRounded) }
}
