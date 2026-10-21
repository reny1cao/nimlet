import Foundation
import Network
import AVFoundation
import Combine
import UIKit

/// A third connection to the same Mac, carrying its audio this way.
///
/// Separate from the control channel for the reason the mirror is, and separate
/// from the mirror for a stronger version of it: TCP delivers in order, so a
/// packet queued behind a 60 KB keyframe waits for the keyframe. A late pointer
/// delta is a stutter; late audio is a hole. Three sockets, one job each.
///
/// This is also the one part of Nimlet that keeps working with the app in the
/// background. Everything else is a foreground input device — the premise of the
/// app is that the phone is beside the keyboard — and this is the opposite
/// premise: you have walked off and want to hear what the Mac is doing. So it
/// holds `NimletClient` awake while it runs, and iOS lets it, because an app
/// playing audio is an app with a reason to exist off screen.
@MainActor
final class ListenClient: ObservableObject {

    /// Switched on by the user, and the only thing that starts any of this.
    @Published private(set) var isOn = false
    /// The socket is up and the Mac has been told who is asking.
    @Published private(set) var isConnected = false
    /// Samples are reaching the speaker. Published at a human rate, from a timer,
    /// because the render thread changes its mind about this in milliseconds.
    @Published private(set) var isPlaying = false
    /// Why there is nothing to hear, when the Mac has said.
    @Published private(set) var message: String?
    /// Capture on the Mac to arrival here, in milliseconds.
    @Published private(set) var latencyMillis: Double?

    /// Capture on the Mac to actually being *heard*, in milliseconds, or nil
    /// while nothing is playing.
    ///
    /// Three parts, and the second is the one that makes this different from
    /// `latencyMillis`: the trip over the network, the cushion the samples are
    /// still sitting in, and whatever the route adds on the way out — which for
    /// AirPods is more than the other two together.
    ///
    /// Published so the mirror can hold the picture to meet it. Without it the
    /// two channels are treated oppositely by design — video the instant it
    /// lands, audio out of a jitter buffer — and the gap between them is the
    /// cushion's whole width, which on a video of somebody talking is exactly
    /// the fault everybody can see and nobody can name.
    @Published private(set) var playbackDelayMillis: Double?

    /// Held while the user is dictating: the microphone is a few inches from the
    /// speaker, and the Mac's audio has no business being transcribed into
    /// somebody's prompt.
    @Published private(set) var isHeld = false

    /// `nonisolated`, because the frames arrive on the network queue and that is
    /// where they are handed over. The player is internally synchronised and says
    /// so; only building and tearing its graph down is main-actor work, and those
    /// two methods are marked.
    private nonisolated let player = AudioPlayer()
    private let queue = DispatchQueue(label: "com.renyicao.mice.remote.listen")
    private var connection: NWConnection?
    private var stream: ListeningStream?
    private weak var control: NimletClient?
    private var proObservation: AnyCancellable?
    private var hostID: String?
    private var controlObservation: AnyCancellable?
    private let backoff = Backoff()
    private var meter: Timer?
    private var latencySample: Double?

    var statusDescription: String {
        guard isOn else { return "Off" }
        if isHeld { return "Paused while dictating" }
        if let message { return message }
        if isPlaying { return "Playing your Mac's system audio" }
        return isConnected ? "Waiting for sound from your Mac" : "Reconnecting audio"
    }

    // MARK: - Switching on

    func toggle(control: NimletClient) {
        if isOn { turnOff() } else { turnOn(control: control) }
    }

    func turnOn(control: NimletClient) {
        guard control.requirePro() else { return }
        guard !isOn, control.state.isConnected,
              control.status?.deviceApproved == true,
              let hostID = control.listeningHostID else { return }
        remoteLog.info("listen: on")
        isOn = true
        self.control = control
        proObservation = Publishers.CombineLatest3(ProStore.shared.$hasLifetime, ProStore.shared.$hasSubscription,
                                                   ProStore.shared.$isPublicBeta)
            .map { $0 || $1 || $2 }.removeDuplicates().receive(on: DispatchQueue.main)
            .sink { [weak self] hasPro in
                guard !hasPro, self?.control?.hasProAccess != true else { return }
                self?.turnOff()
            }
        self.hostID = hostID
        controlObservation = Publishers.CombineLatest3(control.$listeningHostID,
                                                        control.$session,
                                                        control.$status)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reconcileControl() }
        message = nil
        // Held awake from here rather than from the first frame: the socket has
        // to survive the walk to the other room, which is exactly the interval
        // in which the app is backgrounded and has nothing playing yet.
        control.holdForListening(true)
        NowPlaying.begin(hostName: control.currentHostName ?? "Your Mac") { [weak self] in
            self?.turnOff()
        }
        connectIfNeeded()
        startMeter()
    }

    func turnOff() {
        proObservation = nil
        guard isOn else { return }
        remoteLog.info("listen: off")
        isOn = false
        backoff.cancel()
        meter?.invalidate()
        meter = nil
        stream?.invalidate()
        stream = nil
        connection?.cancel()
        connection = nil
        isConnected = false
        isPlaying = false
        latencyMillis = nil
        playbackDelayMillis = nil
        latencySample = nil
        message = nil
        player.stop()
        NowPlaying.end()
        controlObservation = nil
        hostID = nil
        control?.holdForListening(false)
        control = nil
    }

    /// Dictation is starting, or has finished.
    ///
    /// Muted locally first, then paused on the Mac so cellular traffic stops too. The socket stays up either
    /// way: stopping the capture on the Mac costs about a second to start again,
    /// and letting go of a button should not cost a second of silence.
    func hold(_ held: Bool) {
        guard isHeld != held else { return }
        isHeld = held
        stream?.hold(held)
        guard isOn else { return }
        if held {
            player.flush()
            isPlaying = false
        }
        sendHello()
    }

    // MARK: - The socket

    private func connectIfNeeded() {
        guard control?.hasProAccess == true else { turnOff(); return }
        guard isOn, connection == nil, let control else { return }
        guard control.state.isConnected, control.status?.deviceApproved == true,
              let session = control.session, let parameters = session.parameters else {
            message = "Connect to your Mac first"
            scheduleRetry()
            return
        }
        let stream = ListeningStream(held: isHeld)
        self.stream = stream

        // The same route and key the control connection settled on: anything
        // else fails the handshake, and the only symptom is silence.
        let connection = NWConnection(to: session.endpoint, using: parameters)
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self, self.connection === connection else { return }
                switch state {
                case .ready:
                    remoteLog.info("listen: ready")
                    self.isConnected = true
                    self.backoff.reset()
                    self.sendHello()
                case .failed(let error):
                    remoteLog.error("listen: failed \(error.localizedDescription, privacy: .public)")
                    self.dropConnection()
                case .cancelled:
                    self.dropConnection()
                default:
                    break
                }
            }
        }
        connection.start(queue: queue)
        self.connection = connection
        receiveLoop(on: connection, stream: stream)
    }

    /// A link that comes back is the normal case here, not the exception: this
    /// runs while the phone moves between an access point and cellular, with
    /// nobody watching for a reconnect button.
    private func dropConnection() {
        stream?.invalidate()
        stream = nil
        connection?.cancel()
        connection = nil
        isConnected = false
        isPlaying = false
        // Keep the live audio session through a transient network gap. Stopping
        // it here lets iOS suspend us before a cellular reconnect can complete.
        // Invalidating the stream above prevents old packets filling this graph.
        player.flush()
        scheduleRetry()
    }

    private func scheduleRetry() {
        guard isOn else { return }
        backoff.schedule { [weak self] in self?.connectIfNeeded() }
    }

    private func sendHello() {
        guard let connection, isConnected, let control else { return }
        let hello = ListenHelloPayload(deviceName: UIDevice.current.name,
                                       deviceID: control.deviceID,
                                       paused: isHeld)
        guard let data = try? NimletCoder.line(ClientMessage.listenHello(hello)) else { return }
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    /// A listen socket belongs to one explicitly selected Mac. A user switch,
    /// disconnect or refusal ends that choice; a transient reconnect to the
    /// same Mac waits for an approved control session and adopts its new key.
    private func reconcileControl() {
        guard isOn, let control else { return }
        guard control.listeningHostID == hostID else { turnOff(); return }
        if control.status?.deviceApproved == false { turnOff(); return }
        guard let session = control.session, control.state.isConnected else {
            if connection != nil { dropConnection() }
            return
        }
        if let connection, connection.endpoint != session.endpoint {
            dropConnection()
        }
        connectIfNeeded()
    }

    // MARK: - Receiving

    private nonisolated func receiveLoop(on connection: NWConnection, stream: ListeningStream) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty { self.absorb(data, stream: stream) }
            if isComplete || error != nil {
                connection.cancel()
                return
            }
            guard stream.isActive else { return }
            self.receiveLoop(on: connection, stream: stream)
        }
    }

    /// Every socket owns its framer and decoder. Invalidate synchronously before
    /// flushing or stopping, so an old callback cannot enqueue into a new graph.
    private nonisolated func absorb(_ data: Data, stream: ListeningStream) {
        stream.lock.withLock {
            guard stream.active else { return }
            for (frame, payload) in stream.reader.append(data) {
                let epoch = stream.epoch
                switch frame.kind {
                case .state:
                    Task { @MainActor in
                        guard self.stream === stream, stream.accepts(epoch) else { return }
                        self.noteState(frame.reason)
                        if frame.reason != nil { self.player.flush() }
                    }
                case .audio:
                    guard !stream.held else { continue }
                    play(frame, payload: payload, stream: stream, epoch: epoch)
                    Task { @MainActor in
                        guard self.stream === stream, stream.accepts(epoch) else { return }
                        self.noteArrival(capturedAt: frame.captureTime)
                    }
                }
            }
        }
    }

    /// Called with the stream's lock held; decoding and local mute are atomic.
    private nonisolated func play(_ frame: AudioFrame, payload: Data,
                                  stream: ListeningStream, epoch: UInt64) {
        guard stream.decoder.adopt(frame), let ranges = frame.packetRanges(in: payload) else { return }
        if let sequence = frame.sequence, let last = stream.lastSequence, sequence != last &+ 1 {
            remoteLog.info("listen: frame gap \(last) → \(sequence)")
        }
        stream.lastSequence = frame.sequence
        if let format = stream.decoder.outputFormat, format != stream.startedFormat {
            stream.startedFormat = format
            Task { @MainActor in
                guard self.stream === stream, stream.accepts(epoch) else { return }
                do {
                    try self.player.start(format: format)
                } catch {
                    self.message = "This iPhone would not start playing audio"
                    self.dropConnection()
                }
            }
        }
        for range in ranges {
            guard let pcm = stream.decoder.decode(payload.subdata(in: range)) else { continue }
            player.enqueue(pcm)
        }
    }

    private func noteState(_ reason: String?) {
        guard message != reason else { return }
        message = reason
        if reason != nil { isPlaying = false }
    }

    /// Needs the clock offset the control channel's ping/pong measures; without
    /// it the two uptimes are unrelated numbers.
    private func noteArrival(capturedAt captured: UInt64) {
        if message != nil { message = nil }
        guard let offset = control?.hostClockOffset else { return }
        let hostNow = Int64(bitPattern: Instrumentation.now()) + offset
        let elapsed = Double(hostNow - Int64(bitPattern: captured)) / 1_000_000
        guard elapsed >= 0, elapsed < 10_000 else { return }
        latencySample = latencySample.map { $0 + (elapsed - $0) * 0.15 } ?? elapsed
    }

    /// Publishes what the render thread has been doing, twice a second.
    ///
    /// Assigning a `@Published` fires `objectWillChange` whether or not the
    /// value changed, and the whole screen observes this object — so the two
    /// things a person can see are published at the rate a person can read them,
    /// not at the rate audio arrives. The same trap `PanelClient` keeps its frame
    /// counter out of.
    private func startMeter() {
        meter?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.flushMeter() }
        }
        RunLoop.main.add(timer, forMode: .common)
        meter = timer
    }

    private func flushMeter() {
        let playing = player.isPlaying
        if playing != isPlaying {
            isPlaying = playing
            NowPlaying.note(playing: playing)
        }
        if let latencySample, latencyMillis.map({ abs($0 - latencySample) > 5 }) ?? true {
            latencyMillis = latencySample
        }
        notePlaybackDelay(playing: playing)
        guard Instrumentation.isEnabled else { return }
        remoteLog.info("listen: \(self.player.buffered)ms buffered, \(self.player.cushion)ms cushion, \(self.player.dropoutCount) dropouts")
    }

    /// Republished at the rate a person reads, not the rate a render thread
    /// changes its mind, and only when it has moved far enough to be worth a
    /// re-render — the same discipline the two readouts above keep.
    private func notePlaybackDelay(playing: Bool) {
        guard playing, !isHeld, let latencySample else {
            if playbackDelayMillis != nil { playbackDelayMillis = nil }
            return
        }
        let total = latencySample
            + Double(player.buffered)
            + AudioSession.outputLatency * 1000
        guard playbackDelayMillis.map({ abs($0 - total) > 10 }) ?? true else { return }
        playbackDelayMillis = total
    }
}

/// Mutable codec state for exactly one socket. Epochs also retire main-actor
/// jobs queued before a dictation hold, even if hold/resume happened quickly.
final class ListeningStream: @unchecked Sendable {
    let lock = NSLock()
    var active = true
    var held: Bool
    var epoch: UInt64 = 0
    var reader = AudioFrameReader()
    var decoder = AudioDecoder()
    var lastSequence: UInt32?
    var startedFormat: AVAudioFormat?

    init(held: Bool) { self.held = held }
    var isActive: Bool { lock.withLock { active } }
    func accepts(_ epoch: UInt64) -> Bool {
        lock.withLock { active && !held && self.epoch == epoch }
    }
    func invalidate() {
        lock.withLock { active = false; epoch &+= 1 }
    }
    func hold(_ held: Bool) {
        lock.withLock {
            self.held = held
            epoch &+= 1
            startedFormat = nil
            lastSequence = nil
        }
    }
}
