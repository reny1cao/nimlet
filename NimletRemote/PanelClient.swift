import Foundation
import Network
import Combine
import SwiftUI
import UIKit

/// A partial frame belongs to one socket, including callbacks delivered after
/// that socket was replaced. Never append old bytes to a new session's reader.
private final class PanelConnectionReader: @unchecked Sendable {
    private var reader = ViewFrameReader()
    private let lock = NSLock()

    func append(_ data: Data) -> [(frame: ViewFrame, payload: Data)] {
        lock.withLock { reader.append(data) }
    }

    /// Whether the framer had to throw its buffer away since this was last
    /// asked. It means part of a video frame is gone, so the decoder's reference
    /// picture no longer matches the one the Mac is encoding against and every
    /// delta frame from here decodes into smear. Only a keyframe repairs it, and
    /// only this end knows to ask.
    func takeDesync() -> Bool {
        lock.withLock { reader.takeDesync() }
    }
}

/// A second connection to the same Mac, carrying the focused panel one way.
///
/// Separate on purpose. Pointer deltas and panel frames cannot share a TCP
/// socket: everything behind a 60 KB keyframe waits for it to arrive, which
/// would put the stutter straight back into the pointer. Two sockets, one job
/// each, and the trackpad never notices the mirror exists.
@MainActor
final class PanelClient: ObservableObject {

    struct TextScreen: Equatable {
        var lines: [AttributedString]
        var columns: Int
        var rows: Int
    }

    @Published private(set) var title = ""
    @Published private(set) var screen: TextScreen?
    @Published private(set) var message: String?
    /// Whether `message` describes something the phone can undo by asking for
    /// the window to be opened — today, a minimised one.
    @Published private(set) var messageCanOpen = false
    @Published private(set) var isConnected = false
    @Published private(set) var isVideo = false
    @Published private(set) var videoSize: CGSize?
    /// The region of the panel the arriving frames actually show. The viewer
    /// transforms between this and what it wants to show, so that when the Mac
    /// catches up the transform falls to the identity and nothing moves.
    @Published private(set) var streamCrop = CGRect(x: 0, y: 0, width: 1, height: 1)
    /// Where the Mac's pointer is in the window being mirrored, as fractions of
    /// it. Nil while it is somewhere else, which a zoomed mirror reads as "stay
    /// where you are" rather than as a position to jump to.
    ///
    /// Deliberately **not** `@Published`, and reported through `onPointerMoved`
    /// instead. This arrives on every frame — sixty times a second while the
    /// cursor is moving, which is exactly when it is moving — and a `@Published`
    /// property republishes on equal values too, so observing it would re-render
    /// the whole screen at video rate to move a magnifier that mostly does not
    /// need to move. The same trap `latencyMillis` and `framesPerSecond` are
    /// kept out of, for the same reason.
    private(set) var pointerInWindow: CGPoint?

    /// Called when the pointer has moved far enough inside the window to be
    /// worth acting on. The stage uses it to follow the cursor while zoomed in,
    /// and takes care to write nothing when the view does not actually move.
    var onPointerMoved: ((CGPoint) -> Void)?

    /// How far behind the Mac the *sound* is running, in seconds, or nil when
    /// this phone is not playing the Mac at all.
    ///
    /// Pushed in rather than read: the listen channel is a sibling of this one,
    /// owned beside it, and a mirror that reached into the audio player would
    /// couple two features that are useful separately. What it is used for is one
    /// subtraction — see `VideoHold` — and the whole point is that it costs
    /// nothing when nobody is listening, which is most of the time.
    private var audioDelay: TimeInterval?

    func setAudioDelay(millis: Double?) {
        audioDelay = millis.map { $0 / 1000 }
    }

    /// Below this the pointer has not really gone anywhere: a third of a percent
    /// of the window, which on a 1512-point window is five points.
    private static let pointerStep: CGFloat = 0.003
    /// How round the mirrored window's corners are, as a fraction of its
    /// width — what the window server masks off and the stream cannot carry.
    /// Nil when the Mac could not measure it, or is too old to send it, which
    /// the panel reads as square.
    @Published private(set) var cornerFraction: Double?
    /// Glass-to-glass, in milliseconds: capture on the Mac to arrival here.
    @Published private(set) var latencyMillis: Double?
    /// Ticks once per arriving frame so a view can show that the link is alive
    /// even while the picture is still. Published at a human rate, not a video one.
    @Published private(set) var framesPerSecond: Double = 0

    /// The whole window the arriving frames are of, in the frames' own pixels.
    ///
    /// The same number as `videoSize` while the Mac is sending all of it, and
    /// larger than the frames once it is sending a crop — which it does when a
    /// viewer has zoomed far enough that the whole window no longer carries the
    /// pixels for the part being read.
    ///
    /// Only its shape is ever used, which is why dividing is honest here: a
    /// crop is enlarged before it is encoded, so this overstates how many pixels
    /// the window has while getting its proportions exactly right.
    var windowSize: CGSize? {
        guard isVideo, let size = videoSize, size.width > 0, size.height > 0 else { return nil }
        guard streamCrop.width > 0, streamCrop.height > 0 else { return size }
        return CGSize(width: size.width / streamCrop.width, height: size.height / streamCrop.height)
    }

    /// The shape of the window being mirrored, width over height.
    ///
    /// Nil until there is a picture, and for a pane sent as characters rather
    /// than pixels — text reflows to whatever box it is given, so it has no
    /// shape to honour. The stage uses this to fit the arriving picture while
    /// the Mac resizes, and when an app cannot adopt the requested shape.
    ///
    /// Of the window and not of the frames, so that a viewer zooming in far
    /// enough to crop the stream does not change the shape of the tile it left
    /// behind — nor, for the frames still in flight when a crop is dropped, the
    /// shape of the tile it came back to.
    var pictureAspect: CGFloat? {
        guard let size = windowSize else { return nil }
        return size.width / size.height
    }

    let decoder = VideoDecoder()
    /// Which window's picture is on the glass right now, as the Mac numbered
    /// it. Sent back with every touch on the mirror, so the Mac can refuse one
    /// aimed at a window it has already left. Not published: nothing draws it.
    private(set) var shownGeneration: Int?

    private var connection: NWConnection?
    /// The same mirror on the route the session has just moved to, dialled
    /// while the old socket keeps the picture up. It takes over with its first
    /// frame, so a move to a better route never shows a black mirror.
    private var replacement: NWConnection?
    private var sessionObservation: AnyCancellable?
    /// When the current socket was dialled, for "dial → ready → first frame".
    private var dialedAt: UInt64?
    private var awaitingFirstFrame = false
    /// Dial to first frame on the last connection, milliseconds. Measured.
    @Published private(set) var firstFrameMillis: Int?
    private let queue = DispatchQueue(label: "com.renyicao.mice.remote.view")
    private weak var control: NimletClient?
    private var proObservation: AnyCancellable?

    private var viewport = CGSize(width: 1179, height: 2556)
    private var fitAspect: Double?
    private var windowFitSuspended = false
    private var crop = CGRect(x: 0, y: 0, width: 1, height: 1)
    private var wantsConnection = false
    private let backoff = Backoff()
    private var connectionDeadline: Task<Void, Never>?
    private static let handshakeTimeout: TimeInterval = 8

    /// Frame arrivals are counted here and published on a slow timer. Assigning
    /// a `@Published` fires `objectWillChange` whether or not the value changed,
    /// so publishing per frame would re-render the whole screen 60 times a
    /// second to move a latency readout by a millisecond.
    private var latencySample: Double?
    private var frameCount = 0
    private var meterStart = Instrumentation.now()
    private var meter: Timer?

    // MARK: - Lifecycle

    func start(control: NimletClient) {
        guard control.hasProAccess else { stop(); return }
        remoteLog.info("panel start")
        // Whoever is drawing the mirror now needs something to draw.
        decoder.onLayerAttached = { [weak self] in self?.requestKeyframe() }
        decoder.onShown = { [weak self] generation in self?.shownGeneration = generation }
        self.control = control
        proObservation = Publishers.CombineLatest3(ProStore.shared.$hasLifetime, ProStore.shared.$hasSubscription,
                                                   ProStore.shared.$isPublicBeta)
            .map { $0 || $1 || $2 }.removeDuplicates().receive(on: DispatchQueue.main)
            .sink { [weak self] hasPro in
                guard !hasPro, self?.control?.hasProAccess != true else { return }
                self?.stop()
            }
        wantsConnection = true
        sessionObservation = control.$session
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] session in self?.follow(session) }
        connectIfNeeded()
    }

    func stop() {
        proObservation = nil
        remoteLog.info("panel stop")
        wantsConnection = false
        sessionObservation = nil
        replacement?.cancel()
        replacement = nil
        connectionDeadline?.cancel()
        connectionDeadline = nil
        backoff.cancel()
        meter?.invalidate()
        meter = nil
        connection?.cancel()
        connection = nil
        isConnected = false
        isVideo = false
        screen = nil
        videoSize = nil
        streamCrop = CGRect(x: 0, y: 0, width: 1, height: 1)
        pointerInWindow = nil
        cornerFraction = nil
        latencyMillis = nil
        framesPerSecond = 0
        message = nil
        messageCanOpen = false
        audioDelay = nil
        decoder.reset()
    }

    /// The size the viewer can actually show, in points. Sending this keeps the
    /// Mac from encoding a 1920-wide stream into a 150-point tile — and, when the
    /// tile is popped out to full screen, from leaving it at tile resolution.
    ///
    /// The conversion to pixels lives here rather than at each call site: it is
    /// what decides the encode resolution on the Mac, and having two copies of
    /// it meant fixing the scale in one place and leaving the other quietly
    /// asking for the wrong box.
    func setViewport(points size: CGSize) {
        let scale = UITraitCollection.current.displayScale
        let rounded = CGSize(width: (size.width * scale / 8).rounded() * 8,
                             height: (size.height * scale / 8).rounded() * 8)
        guard rounded != viewport else { return }
        viewport = rounded
        sendHello()
    }

    /// Use the available area rather than the fitted picture: the latter still
    /// has the old Mac window's shape and would ask it to keep that shape.
    func setWindowFit(points size: CGSize) {
        guard !windowFitSuspended, size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0,
              let aspect = WindowAutoFit.validAspect(Double(size.width / size.height)),
              aspect != fitAspect else { return }
        fitAspect = aspect
        sendHello()
    }

    /// Keyboard animation may change the encode viewport, but never the Mac window's shape.
    /// Ignore temporary fit requests; the settled normal layout publishes again after input ends.
    func setWindowFitSuspended(_ suspended: Bool) { windowFitSuspended = suspended }

    /// The region of the panel now on screen, as fractions of the whole.
    ///
    /// Sent when a zoom or pan settles, never while it is moving: each one
    /// re-fits the capture on the Mac, and doing that per frame of a pinch would
    /// spend the whole gesture tearing the stream down and building it again.
    func setCrop(_ rect: CGRect) {
        let rounded = CGRect(x: (rect.origin.x * 200).rounded() / 200,
                             y: (rect.origin.y * 200).rounded() / 200,
                             width: (rect.width * 200).rounded() / 200,
                             height: (rect.height * 200).rounded() / 200)
        guard rounded != crop else { return }
        crop = rounded
        sendHello()
    }

    /// Asks for a fresh keyframe. The decoder needs one whenever its renderer has
    /// been flushed or its layer replaced, and without it the picture stays black
    /// until the host's own two-second safety keyframe comes round.
    func requestKeyframe() {
        sendHello()
    }

    private func connectIfNeeded() {
        guard control?.hasProAccess == true else { stop(); return }
        guard wantsConnection, connection == nil, let control else { return }
        guard let session = control.session, let parameters = session.parameters else {
            message = "Connect to your Mac first"
            messageCanOpen = false
            scheduleRetry()
            return
        }
        message = nil
        messageCanOpen = false
        decoder.reset()
        remoteLog.info("panel dialing: route=\(session.reach.rawValue, privacy: .public)")

        // The same route and key the control connection settled on: anything
        // else fails the handshake, and the only symptom is a mirror that
        // stays black.
        let connection = NWConnection(to: session.endpoint, using: parameters)
        dialedAt = Instrumentation.now()
        awaitingFirstFrame = true
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self, self.connection === connection else { return }
                switch state {
                case .ready:
                    remoteLog.info("panel ready after \(self.millisSinceDial(), privacy: .public) ms")
                    self.connectionDeadline?.cancel()
                    self.connectionDeadline = nil
                    self.isConnected = true
                    self.backoff.reset()
                    self.sendHello()
                    self.startMeter()
                    // The session may have moved while this was dialling.
                    if let session = self.control?.session, session.endpoint != connection.endpoint {
                        self.follow(session)
                    }
                case .failed(let error):
                    remoteLog.error("panel failed: \(error.localizedDescription, privacy: .public)")
                    self.message = error.localizedDescription
                    self.messageCanOpen = false
                    self.dropConnection()
                case .waiting(let error):
                    remoteLog.error("panel waiting: \(String(describing: error), privacy: .public), path=\(String(describing: connection.currentPath?.unsatisfiedReason), privacy: .public)")
                    self.dropConnection()
                case .cancelled:
                    remoteLog.info("panel cancelled")
                    self.dropConnection()
                default:
                    break
                }
            }
        }
        connection.start(queue: queue)
        self.connection = connection
        // TCP can already be connected to a VPN proxy while the pinned TLS
        // handshake is still silent. Bound that wait independently of TCP's
        // timeout; a fresh panel socket can recover without dropping control.
        connectionDeadline = Task { [weak self, weak connection] in
            try? await Task.sleep(for: .seconds(Self.handshakeTimeout))
            guard !Task.isCancelled, let self, let connection,
                  self.connection === connection, !self.isConnected else { return }
            remoteLog.error("panel TLS handshake timed out after 8s; retrying")
            self.dropConnection()
        }
        receiveLoop(on: connection, reader: PanelConnectionReader())
    }

    /// A mirror that gives up on the first Wi-Fi hiccup is worse than no mirror:
    /// the phone is usually face-up on the desk, and nobody is watching to press
    /// a reconnect button.
    private func dropConnection() {
        connectionDeadline?.cancel()
        connectionDeadline = nil
        connection?.cancel()
        connection = nil
        isConnected = false
        meter?.invalidate()
        meter = nil
        framesPerSecond = 0
        decoder.reset()
        scheduleRetry()
    }

    private func scheduleRetry() {
        guard wantsConnection else { return }
        backoff.schedule { [weak self] in self?.connectIfNeeded() }
    }

    /// The session moved to another route. Dial the mirror there too, and let
    /// the new socket take over once it has something to show.
    /// Where the mirror's socket goes, for diagnostics and for checking that it
    /// is on the session's route.
    var mirrorEndpoint: NWEndpoint? { isConnected ? connection?.endpoint : nil }

    private func follow(_ session: NimletClient.Session?) {
        guard wantsConnection, let session else { return }
        // Still dialling the route the session has just left: nothing is on
        // the glass yet, so start again on the new one. On 5G (2026-10-05) the
        // session moved to the direct path while the mirror's relay handshake
        // was in flight, the move was ignored, and the mirror stayed on the
        // relay for a minute.
        if let connection, !isConnected, connection.endpoint != session.endpoint {
            remoteLog.info("panel: session moved to \(session.reach.rawValue, privacy: .public) while dialing; redialing there")
            connectionDeadline?.cancel()
            connectionDeadline = nil
            self.connection = nil
            connection.cancel()
            connectIfNeeded()
            return
        }
        guard let connection, isConnected,
              connection.endpoint != session.endpoint,
              replacement?.endpoint != session.endpoint,
              let parameters = session.parameters else { return }
        replacement?.cancel()
        remoteLog.info("panel: session moved to \(session.reach.rawValue, privacy: .public); dialing the mirror there")
        let fresh = NWConnection(to: session.endpoint, using: parameters)
        let dialed = Instrumentation.now()
        fresh.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self, self.replacement === fresh else { return }
                switch state {
                case .ready:
                    remoteLog.info("panel: replacement ready after \(Int((Instrumentation.now() &- dialed) / 1_000_000), privacy: .public) ms")
                    self.sendHello(on: fresh)
                case .failed, .waiting, .cancelled:
                    // The old socket is still up; if it goes too, the ordinary
                    // retry dials the session's new route anyway.
                    remoteLog.error("panel: replacement did not come up: \(String(describing: state), privacy: .public)")
                    self.replacement = nil
                    fresh.cancel()
                default:
                    break
                }
            }
        }
        replacement = fresh
        fresh.start(queue: queue)
        receiveLoop(on: fresh, reader: PanelConnectionReader())
    }

    /// The replacement's first frame: it is the mirror now.
    private func promoteReplacement() {
        guard let fresh = replacement else { return }
        let old = connection
        replacement = nil
        connection = fresh
        // Its own handler from here: a later failure is the mirror's.
        fresh.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self, self.connection === fresh else { return }
                switch state {
                case .failed(let error):
                    remoteLog.error("panel failed: \(error.localizedDescription, privacy: .public)")
                    self.dropConnection()
                case .waiting, .cancelled:
                    self.dropConnection()
                default:
                    break
                }
            }
        }
        old?.cancel()
        remoteLog.info("panel: moved to the session's new route")
    }

    private func millisSinceDial() -> Int {
        dialedAt.map { Int((Instrumentation.now() &- $0) / 1_000_000) } ?? -1
    }

    private func sendHello() {
        guard let connection, isConnected else { return }
        sendHello(on: connection)
    }

    private func sendHello(on connection: NWConnection) {
        let hello = ViewHelloPayload(deviceName: UIDevice.current.name,
                                     deviceID: control?.deviceID ?? "",
                                     maxWidth: Int(viewport.width),
                                     maxHeight: Int(viewport.height),
                                     crop: crop,
                                     fitAspect: fitAspect)
        guard let data = try? NimletCoder.line(ClientMessage.viewHello(hello)) else { return }
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    // MARK: - Receive

    private nonisolated func receiveLoop(on connection: NWConnection, reader: PanelConnectionReader) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                let frames = reader.append(data)
                // Acknowledged here, on the network queue, the moment the bytes
                // are read: the Mac sizes what it keeps in flight from how long
                // this takes, and a hop through the main actor would add
                // whatever the UI happens to be doing to every measurement.
                if let newest = frames.lazy.filter({ $0.frame.kind == .video }).compactMap({ $0.frame.sequence }).max(),
                   let ack = try? NimletCoder.line(ClientMessage.viewAck(sequence: newest)) {
                    connection.send(content: ack, completion: .contentProcessed { _ in })
                }
                if reader.takeDesync() {
                    Task { @MainActor in
                        guard self.connection === connection else { return }
                        remoteLog.error("panel: reader desynced, asking for a keyframe")
                        self.requestKeyframe()
                    }
                }
                if !frames.isEmpty {
                    // Text is parsed here, on the network queue, rather than on
                    // the main actor: building forty AttributedStrings ten times
                    // a second shares a thread with touch delivery, which is the
                    // path this app tunes hardest.
                    let prepared = frames.map { (frame: $0.frame, payload: $0.payload, screen: Self.parse($0.frame, payload: $0.payload)) }
                    Task { @MainActor in
                        if self.replacement === connection { self.promoteReplacement() }
                        guard self.connection === connection else { return }
                        if self.awaitingFirstFrame {
                            self.awaitingFirstFrame = false
                            let millis = self.millisSinceDial()
                            self.firstFrameMillis = millis
                            remoteLog.info("panel first frame \(millis, privacy: .public) ms after dialing")
                        }
                        for item in prepared {
                            self.handle(item.frame, payload: item.payload, screen: item.screen)
                        }
                    }
                }
            }
            if isComplete || error != nil {
                remoteLog.error("panel read ended: complete=\(isComplete, privacy: .public) error=\(error?.localizedDescription ?? "none", privacy: .public)")
                connection.cancel()
                return
            }
            self.receiveLoop(on: connection, reader: reader)
        }
    }

    /// The expensive part of a text frame, done off the main actor.
    private nonisolated static func parse(_ frame: ViewFrame, payload: Data) -> TextScreen? {
        guard frame.kind == .text else { return nil }
        let source = String(data: payload, encoding: .utf8) ?? ""
        let lines = ANSIText.attributed(source, defaultForeground: .white)
        return TextScreen(lines: lines,
                          columns: frame.columns ?? lines.map(\.characters.count).max() ?? 80,
                          rows: frame.rows ?? lines.count)
    }

    private func handle(_ frame: ViewFrame, payload: Data, screen parsed: TextScreen?) {
        // Every assignment below is guarded, because `@Published` republishes on
        // equal values too and this runs up to 60 times a second.
        if title != frame.title {
            title = frame.title
            // A different panel: whatever was being zoomed into is gone, and so
            // is the pointer's place in a window this no longer is.
            crop = CGRect(x: 0, y: 0, width: 1, height: 1)
            streamCrop = CGRect(x: 0, y: 0, width: 1, height: 1)
            pointerInWindow = nil
        }
        let age = noteArrival(of: frame)

        switch frame.kind {
        case .state:
            if message != frame.reason { message = frame.reason }
            let canOpen = frame.canOpen ?? false
            if messageCanOpen != canOpen { messageCanOpen = canOpen }
            if screen != nil { screen = nil }
            if isVideo { isVideo = false }
            if videoSize != nil { videoSize = nil }

        case .text:
            if message != nil { message = nil }
            if messageCanOpen { messageCanOpen = false }
            if isVideo { isVideo = false }
            // Characters have no corners: a pane is drawn by this app, not
            // masked by the window server.
            if cornerFraction != nil { cornerFraction = nil }
            if let parsed, screen != parsed { screen = parsed }

        case .video:
            if message != nil { message = nil }
            if messageCanOpen { messageCanOpen = false }
            if !isVideo { isVideo = true }
            if let width = frame.width, let height = frame.height {
                let size = CGSize(width: width, height: height)
                if size != videoSize { videoSize = size }
            }
            if frame.cropRect != streamCrop { streamCrop = frame.cropRect }
            // Held when the pointer leaves: a magnifier that snapped back to
            // the middle every time the cursor crossed onto another window
            // would spend most of its time somewhere nobody asked for.
            if let spot = frame.pointer { notePointer(spot.point) }
            if frame.cornerRadius != cornerFraction { cornerFraction = frame.cornerRadius }
            // The renderer can only recover from a failure by being flushed, and
            // a flushed renderer shows nothing until the next keyframe.
            //
            // `hold` is how the picture is kept with the sound. Per frame rather
            // than a constant, and that is what makes it a correction rather
            // than a delay: a frame that arrived late is held less, one that
            // arrived early is held more, and both go on the glass at the moment
            // their own audio reaches the speaker. Zero unless this phone is
            // playing the Mac, in which case nothing below changes at all.
            let hold = VideoHold.seconds(audioDelay: audioDelay, videoDelay: age)
            if decoder.decode(frame, payload: payload, hold: hold) == .needsKeyframe {
                requestKeyframe()
            }
        }
    }

    private func notePointer(_ place: CGPoint) {
        if let last = pointerInWindow,
           abs(last.x - place.x) < Self.pointerStep,
           abs(last.y - place.y) < Self.pointerStep { return }
        pointerInWindow = place
        onPointerMoved?(place)
    }

    /// Needs the clock offset the control channel measures; without it the two
    /// uptimes are unrelated numbers and the subtraction is meaningless.
    ///
    /// Returns this frame's own age in seconds — not the smoothed average, which
    /// is what the readout wants — because aligning a frame with its audio is
    /// about that frame and not about the ones around it.
    @discardableResult
    private func noteArrival(of frame: ViewFrame) -> TimeInterval? {
        frameCount += 1
        guard let offset = control?.hostClockOffset else { return nil }
        let hostNow = Int64(bitPattern: Instrumentation.now()) + offset
        let elapsed = Double(hostNow - Int64(bitPattern: frame.captureTime)) / 1_000_000
        guard elapsed >= 0, elapsed < 5_000 else { return nil }
        latencySample = latencySample.map { $0 + (elapsed - $0) * 0.2 } ?? elapsed
        return elapsed / 1000
    }

    private func startMeter() {
        meter?.invalidate()
        frameCount = 0
        meterStart = Instrumentation.now()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.flushMeter() }
        }
        RunLoop.main.add(timer, forMode: .common)
        meter = timer
    }

    private func flushMeter() {
        let now = Instrumentation.now()
        let seconds = Double(now &- meterStart) / 1_000_000_000
        meterStart = now
        let rate = seconds > 0 ? Double(frameCount) / seconds : 0
        frameCount = 0
        if abs(rate - framesPerSecond) > 0.4 { framesPerSecond = rate }
        if let latencySample, latencyMillis.map({ abs($0 - latencySample) > 1 }) ?? true {
            latencyMillis = latencySample
        }
    }
}
