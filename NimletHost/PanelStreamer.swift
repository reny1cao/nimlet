import Foundation
import Network
import Combine
import CoreMedia
import AppKit

/// Owns the panel mirror: which target is being watched, how it is captured, and
/// pushing frames to every attached viewer.
///
/// The medium follows the target kind, because "the focused panel" is two
/// different things. A tmux pane is text and should stay text — it renders sharp
/// at any size on a phone and costs a few KB. An app window is pixels, and needs
/// the whole capture-encode-decode pipeline to be worth looking at.
final class PanelStreamer {
    static let shared = PanelStreamer()

    private final class ViewClient {
        let connection: NWConnection
        /// Arrived from away — directly or through the relay — so cellular, or
        /// a network that is not the Mac's. Its path on this end looks like
        /// Wi-Fi or loopback, so it has to be told.
        let isFar: Bool
        var name: String
        var maxWidth: Int
        var maxHeight: Int
        var crop: CGRect
        var fitAspect: Double?
        var fitUpdatedAt: UInt64
        /// Frames, and bytes, handed to the transport and not yet taken.
        ///
        /// Counts rather than the boolean this used to be. One frame at a time
        /// reads as the tightest possible backpressure and is in fact the
        /// loosest thing here: nothing is encoded while a frame is draining, so
        /// the encoder idles for exactly as long as the socket takes — and for a
        /// keyframe on a busy link that is most of a tenth of a second, during
        /// which the mirror is a still picture. Two frames, bounded by bytes,
        /// lets frame N+1 be ready the moment frame N is taken.
        var inFlightFrames = 0
        var inFlightBytes = 0
        /// A video frame went out that this viewer did not get.
        ///
        /// Which means its decoder is now building deltas against a picture the
        /// encoder has moved past, and the only repair is a keyframe. Per viewer
        /// rather than one flag for the stream, and cleared when a keyframe
        /// actually reaches it — so a slow second phone costs one keyframe per
        /// episode of congestion instead of one per frame.
        var missedFrame = false
        /// What the phone has acknowledged, as opposed to what this Mac's own
        /// socket has taken. See `VideoFlowWindow`.
        var flow = VideoFlowWindow()

        init(connection: NWConnection, hello: ViewHelloPayload, far: Bool) {
            self.connection = connection
            self.isFar = far
            self.name = hello.deviceName
            self.maxWidth = ViewClient.clamp(hello.maxWidth)
            self.maxHeight = ViewClient.clamp(hello.maxHeight)
            self.crop = hello.cropRect
            self.fitAspect = WindowAutoFit.validAspect(hello.fitAspect)
            self.fitUpdatedAt = Instrumentation.now()
        }

        /// Returns true when the viewer actually wants a different size, so a
        /// plain keyframe request does not tear a running capture down.
        func adopt(_ hello: ViewHelloPayload) -> Bool {
            name = hello.deviceName
            let width = ViewClient.clamp(hello.maxWidth)
            let height = ViewClient.clamp(hello.maxHeight)
            let region = hello.cropRect
            let aspect = WindowAutoFit.validAspect(hello.fitAspect)
            let fitChanged = aspect != fitAspect
            if fitChanged { fitUpdatedAt = Instrumentation.now() }
            defer { maxWidth = width; maxHeight = height; crop = region; fitAspect = aspect }
            return width != maxWidth || height != maxHeight || region != crop || fitChanged
        }

        /// Small enough for a picture-in-picture tile, bounded so a bad number
        /// cannot ask the encoder for something absurd.
        private static func clamp(_ value: Int) -> Int { min(max(value, 160), 4096) }

        /// Whether another frame may be handed over.
        ///
        /// An empty transport always takes one, whatever the budget says: a rule
        /// that can refuse the only frame there is would be a mirror that never
        /// starts on a slow link.
        func hasRoom(budget: Int) -> Bool {
            if inFlightFrames == 0 { return true }
            return inFlightFrames < VideoPacer.maxFramesInFlight && inFlightBytes < budget
        }

        /// Room for a video frame: in this Mac's socket, *and* end to end. The
        /// first alone is blind to every queue past this Mac's kernel.
        func hasVideoRoom(budget: Int, bitrate: Int, now: UInt64) -> Bool {
            hasRoom(budget: budget) && flow.hasRoom(bitrate: bitrate, now: now)
        }

        func took(_ bytes: Int) {
            inFlightFrames += 1
            inFlightBytes += bytes
        }

        func released(_ bytes: Int) {
            inFlightFrames = max(0, inFlightFrames - 1)
            inFlightBytes = max(0, inFlightBytes - bytes)
        }
    }

    /// What a frame is being sent for, which decides whether it may be dropped
    /// and whether its delivery says anything about the link.
    private enum SendPolicy {
        /// A video frame. Admitted against the pacer's budget, and timed: this
        /// is where the bitrate for the next one comes from.
        case video
        /// A tmux pane as text. Small, arrives ten times a second, and superseded
        /// by the next one — so the old one-at-a-time rule is exactly right.
        case text
        /// A status line. Never dropped: it is the only thing that explains an
        /// empty mirror, and there is no next one to supersede it.
        case status
    }

    private let lock = NSLock()
    private var clients: [ObjectIdentifier: ViewClient] = [:]
    private var cancellables = Set<AnyCancellable>()
    /// Source changes arrive from the network queue (a viewer attaching) and
    /// from main (the target changing). One serial queue for both, so a start
    /// and a stop can never interleave halfway through.
    private let control = DispatchQueue(label: "com.renyicao.mice.host.panel")
    /// Frames in the encoder right now. One at a time: an encode takes a few
    /// milliseconds against a 17 ms frame interval, so nothing is gained by
    /// letting them pile up and a queue is latency by another name.
    private var encodesInFlight = 0
    /// Stop and frame submission must not interleave between prepare and encode.
    private let videoLifecycle = NSLock()
    /// Delivery can arrive after a stop. It must not release a new stream's slot.
    private var encodeEpoch = 0
    /// Measured bitrate control, replacing the number this used to guess from
    /// the name of the interface. Read once per frame, written from the
    /// transport's completions, so it lives under the same lock as the clients.
    private var pacer = VideoPacer(ceiling: PanelStreamer.wifiCeiling)
    /// When a frame was last handed to the transport, for the delivered frame
    /// rate the encoder's rate allocator is told about.
    private var lastHandOver: UInt64 = 0
    /// Numbers every video frame, for the viewers' acknowledgements.
    private var frameSequence = 0
    /// A capture was skipped because no viewer had room for it. Whatever it
    /// showed may be the last change the window makes, so the next room that
    /// opens asks for a fresh capture rather than leaving the phone a frame
    /// behind until something else moves.
    private var skippedForRoom = false

    private let encoder = VideoEncoder()
    private var paneMirror: PaneMirror!
    private var windowCapture: WindowCapture!
    private var currentTitle = ""
    private var lastState: String?

    private init() {
        paneMirror = PaneMirror { [weak self] frame, payload in
            self?.send(frame, payload: payload, policy: .text,
                       onBackpressureDrop: { self?.paneMirror.invalidate() })
        }
        windowCapture = WindowCapture(
            onFrame: { [weak self] pixelBuffer, time, crop, generation, refinement in
                self?.encodeAndSend(pixelBuffer, at: time, crop: crop, generation: generation,
                                    refinement: refinement) ?? false
            },
            onState: { [weak self] reason, canOpen in self?.sendState(reason, canOpen: canOpen) })

        // Tapping a target button on the phone is also "show me that one".
        TargetStore.shared.$activeTargetID
            .removeDuplicates()
            .dropFirst()
            .debounce(for: .milliseconds(120), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.restartSource() }
            .store(in: &cancellables)

        // And picking a window off the shelf is "show me *that* one". The
        // active target has not changed — what changed is which of its windows
        // it points at, so watching the id alone would leave the mirror on the
        // previous window until something unrelated restarted it.
        TargetStore.shared.$targets
            .combineLatest(TargetStore.shared.$provisionalTargets)
            .map { curated, offered in
                (curated + offered).first { $0.id == TargetStore.shared.activeTargetID }
            }
            .removeDuplicates()
            .dropFirst()
            .debounce(for: .milliseconds(120), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.restartSource() }
            .store(in: &cancellables)
    }

    var viewerCount: Int { lock.withLock { clients.count } }

    /// Where the window now being mirrored is, for a phone that wants to point
    /// into the picture it was sent.
    ///
    /// Nil when the panel is a tmux pane: those pixels are characters this Mac
    /// drew from a pane's contents, not a window anybody can click in. A touch
    /// on that mirror has nowhere to land, and putting the pointer over the
    /// terminal *showing* the pane would be a guess about a window the phone
    /// never asked about.
    var mirroredWindowFrame: CGRect? { windowCapture.windowFrame }

    /// Give the window being mirrored this width-over-height, and capture it
    /// at its new shape straight away.
    ///
    /// Nothing for a tmux pane — there is no window, only characters drawn to
    /// whatever shape the phone asked for — and nothing when no window is
    /// resolved yet.
    func reshapeMirroredWindow(aspect: CGFloat) {
        guard let windowID = windowCapture.resolvedWindowID else { return }
        guard WindowRoster.reshape(windowID: windowID, aspect: aspect) else { return }
        windowCapture.refresh()
    }

    /// A click from the phone, which may have brought another window forward.
    ///
    /// A target that follows its app, or the focused-app target, mirrors
    /// whatever window is in front, so look again now rather than at the next
    /// watchdog tick a second and a half away — a click on another window
    /// should move the picture while the finger is still near the glass. A
    /// target pinned to one window shows that window whatever was clicked.
    func noteClick() {
        guard viewerCount > 0 else { return }
        if let target = TargetStore.shared.safeActiveTarget,
           target.kind == .tmux || target.pinnedWindowID != nil { return }
        windowCapture.refresh()
    }

    /// The same frame, but only once a touch about it can be believed.
    ///
    /// Whenever the mirror changes windows there is an interval in which the
    /// phone is still drawing the window before this one — the new one has to
    /// be captured, encoded, sent, decoded and put on the glass — and a finger
    /// put down during it arrives here to be resolved against a window that is
    /// somewhere else. Measured, with two same-sized TextEdit windows 29 points
    /// apart: a touch aimed at the top-left corner of the window on the glass
    /// landed on the top-left corner of the other one, to half a point. Exact
    /// arithmetic, wrong window — and silent, because both are real windows of
    /// the same application.
    ///
    /// Two conditions, and it is worth being exact about what each one buys:
    ///
    /// - A keyframe of *this* window has been handed to the transport. This
    ///   part is a fact, not an estimate: frames carry the generation they were
    ///   captured under, so "the phone has not been sent a picture of this
    ///   window yet" is answered rather than guessed. It covers the capture,
    ///   the encode and the backpressure queue, which is most of the interval
    ///   and all of the variable part of it.
    /// - And `viewerAllowance` has passed since. This part *is* an estimate,
    ///   and it is the limit of this fix: the phone never says which frame it
    ///   has drawn, so the leg from this machine's socket to the glass is
    ///   covered by an interval rather than by an acknowledgement. On a link
    ///   slower than the allowance — a congested network, a phone whose decoder
    ///   is behind — a touch in that gap still lands in the window before this
    ///   one. Closing it properly needed the phone to name the frame it is
    ///   showing, and it now does: `windowFrame(shownGeneration:)` is the
    ///   exact answer, and this estimate is only the fallback for a phone
    ///   that predates it.
    ///
    ///   defaults write com.renyicao.mice.host mice.viewerAllowance -float 0.25
    ///
    /// One more simplification worth naming: "sent" means sent to at least one
    /// viewer. There is normally one phone, and the host does not pair a
    /// control connection with a view connection, so with two viewers attached
    /// the second one's touches are governed by the first one's frames.
    var pointableWindowFrame: CGRect? {
        guard let frame = windowCapture.windowFrame else { return nil }
        let shown = lock.withLock { sentWindow }
        guard shown.generation == windowCapture.windowGeneration,
              Date().timeIntervalSince(shown.at) >= Self.viewerAllowance else { return nil }
        return frame
    }

    /// The mirrored window's frame, if the phone's touch was aimed at a picture
    /// of it — and nil if the picture was of a window the mirror has since
    /// left. Exact, unlike `pointableWindowFrame`: the phone says which
    /// generation was on its glass, so there is no interval to estimate, and
    /// each phone is judged by its own picture rather than the first one's.
    func windowFrame(shownGeneration: Int) -> CGRect? {
        guard shownGeneration == windowCapture.windowGeneration else { return nil }
        return windowCapture.windowFrame
    }

    private static let viewerAllowance: TimeInterval = {
        let override = UserDefaults.standard.double(forKey: "mice.viewerAllowance")
        return override > 0 && override < 2 ? override : 0.12
    }()

    /// The newest window whose picture has left this machine, and when the
    /// first frame of it did. Held under the same lock as the client list,
    /// because it is written on the encoder's queue and read on the network's.
    private var sentWindow: (generation: Int, at: Date) = (-1, .distantFuture)

    /// Touched only on the capture queue, where `encodeAndSend` runs.
    private var lastEncodedGeneration = -1
    /// The encoder was last told `StillRefinement.framesPerSecond` rather
    /// than the live rate. Capture queue only, like the above.
    private var encoderRefining = false

    private func noteSent(generation: Int, keyframe: Bool) {
        lock.withLock {
            guard sentWindow.generation != generation else { return }
            // A delta frame of a window the phone has never seen decodes into
            // the window before it, so the clock starts at the keyframe.
            guard keyframe else { return }
            sentWindow = (generation, Date())
        }
    }

    // MARK: - Viewers

    /// Also the viewport update and the keyframe request: a viewer re-sends its
    /// hello when it resizes — popping out to full screen, shrinking back to the
    /// tile — or when its decoder has been flushed and needs a fresh start.
    func attach(_ connection: NWConnection, hello: ViewHelloPayload, far: Bool = false) {
        let key = ObjectIdentifier(connection)
        let needsRestart = lock.withLock { () -> Bool in
            if let existing = clients[key] { return existing.adopt(hello) }
            clients[key] = ViewClient(connection: connection, hello: hello, far: far)
            return true
        }
        // A viewer that just arrived, or just resized, has nothing on screen it
        // can build the next delta frame on.
        lastState = nil
        encoder.requestKeyframe()
        // And something to make a keyframe out of: a still window produces
        // nothing to encode, so the request alone would leave the viewer
        // looking at black until the Mac's user moved something.
        windowCapture.requestFrame()
        paneMirror.invalidate()
        refreshBitrate()
        guard needsRestart else { return }
        miceLog.info("view: \(hello.deviceName, privacy: .private) at \(hello.maxWidth)x\(hello.maxHeight)")
        restartSource()
    }

    func detach(_ connection: NWConnection) {
        let removed = lock.withLock { clients.removeValue(forKey: ObjectIdentifier(connection)) }
        guard removed != nil else { return }
        guard viewerCount > 0 else {
            // Nobody is looking: stop capturing. This also puts out the screen
            // recording indicator rather than leaving it lit all day.
            stopSource()
            miceLog.info("view: last viewer left, capture stopped")
            return
        }
        // The box and the crop are the aggregate of whoever is still here, so a
        // viewer leaving has to re-derive them too. Without this the stream stays
        // clamped to a departed phone's smaller screen and narrower crop until
        // something unrelated happens to restart it.
        refreshBitrate()
        restartSource()
    }

    // MARK: - Source selection

    private func restartSource() {
        control.async { self.applySource() }
    }

    private func applySource() {
        guard viewerCount > 0 else { stopSourceNow(); return }
        let target = TargetStore.shared.safeActiveTarget
            ?? NimletTarget(name: "Focused", kind: .frontmost)
        // Named after the window when there is one, because "Claude" above a
        // mirror of one of four Claude windows does not say which.
        currentTitle = target.pinnedWindowTitle.map { title in
            title.isEmpty ? target.name : "\(target.name) · \(title)"
        } ?? target.name
        encoder.requestKeyframe()

        switch target.kind {
        case .tmux:
            windowCapture.stop()
            guard let pane = target.tmuxTarget, !pane.isEmpty else {
                sendState("\(target.name) has no tmux pane"); return
            }
            guard Tmux.isAvailable else { sendState("tmux not found on this Mac"); return }
            paneMirror.start(pane: pane, title: "\(target.name) · \(pane)")

        case .app, .frontmost:
            paneMirror.stop()
            let demand = viewerDemand()
            windowCapture.start(bundleID: target.kind == .app ? target.bundleID : nil,
                                windowID: target.kind == .app ? target.pinnedWindowID : nil,
                                applicationPath: target.applicationPath, appIdentity: target.pinnedAppIdentity,
                                maxWidth: demand.width, maxHeight: demand.height,
                                crop: demand.crop, fitAspect: demand.fitAspect)
        }
    }

    private func stopSource() {
        control.async { self.stopSourceNow() }
    }

    private func stopSourceNow() {
        paneMirror.stop()
        videoLifecycle.withLock {
            windowCapture.stop()
            lock.withLock {
                encodeEpoch += 1
                encodesInFlight = 0
            }
            encoder.invalidate()
        }
        lock.withLock {
            // Whatever the link taught us was about a stream that has ended. The
            // next one starts at the ceiling and finds its own level, rather than
            // inheriting a rate learned while a video was playing.
            pacer.reset()
            lastHandOver = 0
            skippedForRoom = false
        }
        lastState = nil
    }

    /// What the capture has to satisfy: the smallest box every viewer can show,
    /// and everything any of them is looking at. With one phone attached the
    /// crop is just its own; with two, neither gets shown less than it asked for.
    private func viewerDemand() -> (width: Int, height: Int, crop: CGRect, fitAspect: Double?) {
        lock.withLock {
            let width = clients.values.map(\.maxWidth).min() ?? 1179
            let height = clients.values.map(\.maxHeight).min() ?? 2556
            let union = clients.values.reduce(CGRect.null) { $0.union($1.crop) }
            // A single native window has one shape. The latest layout change
            // owns it; a keyframe request or zoom cannot take it back.
            let fit = clients.values.filter { $0.fitAspect != nil }
                .max { $0.fitUpdatedAt < $1.fitUpdatedAt }?.fitAspect
            return (width, height, union.isNull ? CGRect(x: 0, y: 0, width: 1, height: 1) : union, fit)
        }
    }

    // MARK: - Video

    /// `generation` says which window these pixels are of. It travels with
    /// them from the capture callback rather than being read here, because by
    /// the time a frame reaches this method the mirror may have moved on and
    /// reading it now would label the old window's pixels as the new one's.
    ///
    /// `refinement` is a pass over a picture already sent, because the window
    /// has stopped moving (`StillRefinement`). It is admitted like any other
    /// frame, but it is not a sign of the window's frame rate, and a pass the
    /// link has no room for is simply offered again later. Returns whether the
    /// frame went to the encoder.
    @discardableResult
    private func encodeAndSend(_ pixelBuffer: CVPixelBuffer, at time: CMTime, crop: CGRect,
                               generation: Int, refinement: Bool = false) -> Bool {
        videoLifecycle.lock()
        defer { videoLifecycle.unlock() }
        guard generation == windowCapture.windowGeneration else { return false }
        if generation != lastEncodedGeneration {
            lastEncodedGeneration = generation
            // A delta frame of a new window is decoded against the old one, so
            // the first frame after a change has to be a keyframe whether or
            // not the encoder thinks it needs one — the two windows can be the
            // same size, in which case nothing else would tell it.
            encoder.requestKeyframe()
        }
        // And a viewer that missed one needs the same thing for the same reason.
        if lock.withLock({ clients.values.contains(where: \.missedFrame) }) {
            encoder.requestKeyframe()
        }
        // Both checks happen *before* encoding, not after. If there is no room
        // for the frame in the transport, or one is still inside the encoder,
        // there is no sense spending a hardware encode on a frame nobody can
        // receive yet — and queueing it is how a mirror ends up seconds behind
        // and never catches up. What "no room" means is now a byte budget rather
        // than a single outstanding frame; see `ViewClient.hasRoom`.
        // Bytes, and not a frame interval derived from the delivered rate. That
        // was tried and measured: gating on 1.5x the rate the link was taking
        // halved the frame rate on a 6 Mbps link and on AWDL — 59 fps to 30 —
        // for no gain in bitrate at all, because the rate it gates on is the
        // rate it caused. Backpressure from the socket has no such loop in it:
        // it says how much room there is now, and lets the link decide the rest.
        let admitted = lock.withLock { () -> (bitrate: Int, fps: Double, epoch: Int)? in
            guard encodesInFlight == 0 else { return nil }
            let budget = pacer.inFlightByteBudget
            let now = Instrumentation.now()
            guard clients.values.contains(where: { $0.hasVideoRoom(budget: budget, bitrate: pacer.bitrate, now: now) }) else {
                // A pass is offered again on its own schedule; asking the
                // window for a fresh frame would end the refinement instead.
                if !refinement { skippedForRoom = true }
                return nil
            }
            encodesInFlight += 1
            return (pacer.bitrate, refinement ? StillRefinement.framesPerSecond : pacer.framesPerSecond, encodeEpoch)
        }
        guard let admitted else { return false }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let captured = Instrumentation.now()
        guard encoder.prepare(width: width, height: height,
                              bitrate: admitted.bitrate, fps: admitted.fps) else {
            lock.withLock { encodesInFlight -= 1 }
            return false
        }
        // Into a refinement, and out of one, the encoder's frame rate changes:
        // a pass may spend the quarter-second it has, and the first live frame
        // after must not be given a quarter-second of budget. A new session
        // was prepared with the right one, and retuning it again is harmless.
        if refinement != encoderRefining {
            encoderRefining = refinement
            encoder.retune(bitrate: admitted.bitrate, fps: admitted.fps)
        }

        let submitted = encoder.encode(pixelBuffer, at: time) { [weak self] output in
            guard let self else { return }
            let current = self.lock.withLock { () -> Bool in
                guard self.encodeEpoch == admitted.epoch else { return false }
                self.encodesInFlight -= 1
                return true
            }
            guard current, generation == self.windowCapture.windowGeneration else { return }
            // Nil means the encoder held the rate by dropping this frame. The
            // slot above is given back either way, which is the point: it used
            // to be given back only on success, and one dropped frame left the
            // count at one for good.
            guard let output else { return }

            var frame = ViewFrame(kind: .video, title: self.currentTitle, captureTime: captured)
            frame.codec = output.codec
            frame.isKeyframe = output.isKeyframe
            frame.width = width
            frame.height = height
            frame.parameterSets = output.parameterSets.isEmpty ? nil : output.parameterSets
            // What the window server masks off when it draws this window, so
            // the phone can mask the same thing rather than showing four
            // corners of a buffer nobody at the Mac can see.
            frame.cornerRadius = self.windowCapture.cornerFraction
            // What a zoomed-in mirror follows, since it has no gesture to pan
            // with. Nil while the pointer is over something else, which the
            // viewer reads as "stay where you are".
            frame.pointer = self.windowCapture.pointerInWindow
            frame.generation = generation
            frame.sequence = self.lock.withLock { () -> Int in
                self.frameSequence &+= 1
                return self.frameSequence
            }
            frame.setCrop(crop)
            self.lastState = nil
            let delivered = self.send(frame, payload: output.data, policy: .video, refinement: refinement,
                                      onBackpressureDrop: {
                // Any frame dropped *after* encoding strands the decoder, not
                // just a keyframe. The encoder has already folded this frame
                // into its reference picture, so every delta frame after it is
                // built against something the phone was never sent: the picture
                // does not go black, it goes wrong, and it stays wrong until a
                // keyframe arrives. This used to ask for one only when the
                // dropped frame happened to be a keyframe itself, which left
                // the ordinary case to be repaired by the safety net — two
                // seconds of smeared window, and now ten.
                self.lock.withLock { self.clients.values.forEach { $0.missedFrame = true } }
                // And the link just refused a frame outright, which is the
                // loudest thing it can say about the rate it is being sent.
                self.noteCongestion()
            })
            // Only once it has actually gone out. A frame that failed to
            // serialise, or that arrived while every viewer was still busy with
            // the last one, was never sent — and counting it would unlock
            // pointing at a window the phone has not been shown.
            if delivered { self.noteSent(generation: generation, keyframe: output.isKeyframe) }
        }
        if !submitted { lock.withLock { encodesInFlight -= 1 } }
        return submitted
    }

    /// An AWDL peer-to-peer link carries a fraction of what infrastructure Wi-Fi
    /// does. Sending 8 Mbps into it does not fail, it just buffers — which shows
    /// up as a mirror running behind rather than as an error.
    ///
    /// Recomputed when the viewer set changes, not per frame: it used to copy
    /// each connection's `NWPath` and build a string per interface sixty times a
    /// second, on the capture thread, holding the lock the encoder callback
    /// wants — all to answer a question whose answer changes approximately never.
    ///
    /// A *ceiling* now, and only that. It used to be the bitrate itself, which
    /// is a guess made from the name of an interface and then never revisited:
    /// 12 Mbps was optimistic for a phone two rooms away on a shared access
    /// point, and the pipeline had no way to find out — a link that could not
    /// carry it simply stopped taking frames. What the rate actually is comes
    /// from `VideoPacer`, which measures it.
    private static let wifiCeiling = 12_000_000
    private static let awdlCeiling = 2_500_000

    private func refreshBitrate() {
        // AWDL for its radio; anything from away — the relay included — for
        // the cellular link at the far end and, through the relay, a server
        // somebody pays for by the byte.
        let (constrained, far) = lock.withLock { () -> (Bool, Bool) in
            let far = clients.values.contains(where: \.isFar)
            let awdl = clients.values.contains { client in
                (client.connection.currentPath?.availableInterfaces ?? []).contains { $0.name.hasPrefix("awdl") }
            }
            return (far || awdl, far)
        }
        let ceiling = constrained ? Self.awdlCeiling : Self.wifiCeiling
        let minimum = far ? VideoPacer.farFloor : VideoPacer.floor
        let retune = lock.withLock { () -> (Int, Double)? in
            let before = pacer.bitrate
            pacer.setCeiling(ceiling, minimum: minimum)
            if far { pacer.startConservatively(at: VideoPacer.farStart) }
            guard pacer.bitrate != before else { return nil }
            pacer.noteTold()
            return (pacer.bitrate, pacer.framesPerSecond)
        }
        if let retune { encoder.retune(bitrate: retune.0, fps: retune.1) }
    }

    // MARK: - Rate control

    /// A frame reached the transport. `seconds` is how long that took, which for
    /// a TCP sender is the only honest throughput measurement available.
    private func noteDelivery(bytes: Int, seconds: Double, interval: Double) {
        let retune = lock.withLock { () -> (Int, Double)? in
            guard pacer.noteDelivered(bytes: bytes, seconds: seconds, interval: interval) else { return nil }
            return (pacer.bitrate, pacer.framesPerSecond)
        }
        reportRate()
        guard let retune else { return }
        encoder.retune(bitrate: retune.0, fps: retune.1)
        miceLog.info("view: \(retune.0 / 1000) kbps at \(retune.1, format: .fixed(precision: 0)) fps")
    }

    /// The transport had no room for a frame at all.
    private func noteCongestion() {
        let retune = lock.withLock { () -> (Int, Double)? in
            guard pacer.noteDropped() else { return nil }
            return (pacer.bitrate, pacer.framesPerSecond)
        }
        guard let retune else { return }
        encoder.retune(bitrate: retune.0, fps: retune.1)
    }

    /// Off unless somebody asked for numbers, like every other counter here.
    private func reportRate() {
        guard Instrumentation.isEnabled else { return }
        let due = lock.withLock { () -> (Int, Double, Double?)? in
            let now = Instrumentation.now()
            guard now &- lastReportAt >= 1_000_000_000 else { return nil }
            lastReportAt = now
            return (pacer.bitrate, pacer.framesPerSecond, pacer.goodput)
        }
        guard let due else { return }
        let measured = due.2.map { "\(Int($0 * 8 / 1000)) kbps measured" } ?? "not measured"
        miceLog.info("view: sending \(due.0 / 1000) kbps at \(due.1, format: .fixed(precision: 0)) fps, link \(measured, privacy: .public)")
    }

    private var lastReportAt: UInt64 = 0

    // MARK: - Acknowledgements

    /// A viewer has read every video frame up to `sequence`.
    func acknowledge(_ connection: NWConnection, sequence: Int) {
        let key = ObjectIdentifier(connection)
        let now = Instrumentation.now()
        let retune = lock.withLock { () -> (Int, Double)? in
            guard let client = clients[key],
                  let sample = client.flow.acknowledged(through: sequence, at: now, bitrate: pacer.bitrate)
            else { return nil }
            noteFlow(sample, of: client, at: now)
            guard pacer.noteQueueDelay(sample.standingDelay, deliveryRate: sample.deliveryRate) else { return nil }
            return (pacer.bitrate, pacer.framesPerSecond)
        }
        recaptureIfSkipped()
        guard let retune else { return }
        encoder.retune(bitrate: retune.0, fps: retune.1)
        miceLog.info("view: queueing on the way to the phone, \(retune.0 / 1000) kbps at \(retune.1, format: .fixed(precision: 0)) fps")
    }

    /// Room may have opened: if a capture was skipped for want of it, ask for
    /// another so the phone is not left on a stale picture.
    private func recaptureIfSkipped() {
        let wanted = lock.withLock { () -> Bool in
            guard skippedForRoom else { return false }
            let budget = pacer.inFlightByteBudget
            let now = Instrumentation.now()
            guard clients.values.contains(where: { $0.hasVideoRoom(budget: budget, bitrate: pacer.bitrate, now: now) }) else { return false }
            skippedForRoom = false
            return true
        }
        if wanted { windowCapture.requestFrame() }
    }

    /// Once a second, when instrumentation is on: what the phone's
    /// acknowledgements say, which is the measured half of "the mirror is behind".
    /// Called under `lock`.
    private func noteFlow(_ sample: VideoFlowWindow.Sample, of client: ViewClient, at now: UInt64) {
        guard Instrumentation.isEnabled, now &- lastFlowReportAt >= 1_000_000_000 else { return }
        lastFlowReportAt = now
        let base = client.flow.baseRoundTrip.map { Int($0 * 1000) } ?? -1
        let rate = sample.deliveryRate.map { Int($0 * 8 / 1000) } ?? -1
        miceLog.info("view: acked rtt \(Int(sample.roundTrip * 1000)) ms, base \(base) ms, queue \(Int(sample.queueDelay * 1000)) ms (standing \(Int(sample.standingDelay * 1000))), in flight \(client.flow.unackedFrames) frames / \(client.flow.unackedBytes / 1024) KB, delivered \(rate) kbps")
    }

    private var lastFlowReportAt: UInt64 = 0

    // MARK: - Sending

    private func sendState(_ reason: String, canOpen: Bool = false) {
        guard reason != lastState else { return }
        lastState = reason
        send(ViewFrame.state(reason, title: currentTitle, canOpen: canOpen),
             payload: Data(), policy: .status, onBackpressureDrop: {})
    }

    /// Whether the frame reached at least one viewer's socket.
    ///
    /// A `refinement` is timed for the bitrate like any video frame, but its
    /// interval says nothing about how fast the window is changing, so it is
    /// kept out of the frame rate the encoder is told.
    @discardableResult
    private func send(_ frame: ViewFrame, payload: Data, policy: SendPolicy, refinement: Bool = false,
                      onBackpressureDrop: () -> Void) -> Bool {
        guard let data = try? ViewFrameWriter.encode(frame, payload: payload) else {
            // The encoder has already folded this frame into its reference
            // picture, so a frame that cannot be serialised strands the decoder
            // exactly as a dropped one does.
            onBackpressureDrop()
            return false
        }
        let bytes = data.count
        let handedOver = Instrumentation.now()

        let (ready, interval): ([ViewClient], Double) = lock.withLock {
            let budget = pacer.inFlightByteBudget
            let taking = clients.values.filter { client in
                switch policy {
                case .video: return client.hasVideoRoom(budget: budget, bitrate: pacer.bitrate, now: handedOver)
                // Superseded by the next one, so one at a time is right.
                case .text: return client.inFlightFrames == 0
                // Nothing supersedes a status line, and it costs a few hundred
                // bytes: it goes out whatever the mirror is doing.
                case .status: return true
                }
            }
            if policy == .video {
                let keyframe = frame.isKeyframe == true
                for client in clients.values where !taking.contains(where: { $0 === client }) {
                    // Skipped while others were sent to: this viewer's reference
                    // picture is now behind the encoder's.
                    client.missedFrame = true
                }
                // A keyframe stands on its own, so whoever gets one is repaired.
                if keyframe { taking.forEach { $0.missedFrame = false } }
            }
            taking.forEach { $0.took(bytes) }
            if policy == .video, let sequence = frame.sequence {
                taking.forEach { $0.flow.sent(sequence: sequence, bytes: bytes, at: handedOver) }
            }
            let gap = lastHandOver == 0 || refinement ? 0 : Double(handedOver &- lastHandOver) / 1_000_000_000
            if policy == .video, !refinement, !taking.isEmpty { lastHandOver = handedOver }
            return (Array(taking), gap)
        }
        guard !ready.isEmpty else {
            if policy == .video { lock.withLock { skippedForRoom = true } }
            onBackpressureDrop()
            return false
        }

        for client in ready {
            client.connection.send(content: data, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                self.lock.withLock { client.released(bytes) }
                self.recaptureIfSkipped()
                if error != nil { self.detach(client.connection); return }
                guard policy == .video else { return }
                let took = Double(Instrumentation.now() &- handedOver) / 1_000_000_000
                self.noteDelivery(bytes: bytes, seconds: took, interval: interval)
            })
        }
        return true
    }
}
