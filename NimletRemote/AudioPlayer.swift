import Foundation
import AVFoundation
import Synchronization

/// Plays the Mac, out of a buffer that is always a little behind it.
///
/// The hard part of a live stream is not the codec, it is the gap between two
/// clocks. The Mac captures on its own crystal and this phone plays on another;
/// they are tens of parts per million apart, which is tens of milliseconds an
/// hour of drift in whichever direction. On top of that, TCP does not lose
/// audio, it *delays* it — a hesitating link delivers nothing for 300 ms and
/// then 300 ms all at once. Both of those are absorbed in the same place: a ring
/// buffer the network fills and the speaker drains, with a cushion in between
/// that `JitterWindow` grows and shrinks on its own.
///
/// `AVAudioSourceNode` rather than `AVAudioPlayerNode.scheduleBuffer`, and the
/// difference is what happens when the buffer runs dry. A player node that runs
/// out of scheduled buffers *stops*, and has to be started again — a click, and
/// a race about what to do with whatever arrives during the restart. A source
/// node is asked for samples on every render cycle whatever happens, so an
/// empty buffer is silence for 5 ms and then the stream carries on. Nothing to
/// restart, and nothing to click.
///
/// `@unchecked Sendable` because it genuinely is, and the checker cannot see why:
/// three threads use this and each has its own share. The main actor builds and
/// tears down the graph, the network queue calls `enqueue`, and the render thread
/// runs the callback — and the two things they have in common, the ring reference
/// and the published counters, are a lock and four atomics respectively.
final class AudioPlayer: @unchecked Sendable {

    /// Three seconds, which is far more than the cushion will ever ask for — it
    /// exists so that a burst arriving after a stall has somewhere to land while
    /// the render thread decides how much of it to throw away.
    private static let ringSeconds: Double = 3

    private let engine = AVAudioEngine()
    private var source: AVAudioSourceNode?
    private var format: AVAudioFormat?

    /// The ring, and a lock for the *reference* to it — not for its contents.
    ///
    /// The ring itself needs no lock: it is written by one thread and read by
    /// one, and its two indices carry the ordering. What does need one is this
    /// property, which the main actor replaces when the graph is built and the
    /// network queue reads on every frame. The render thread never touches it —
    /// the callback closes over the ring it was built with, which is what keeps
    /// a lock off the real-time path.
    private let ringLock = NSLock()
    private var ring: PCMRing?

    /// Touched only by the render callback. Not published, not locked: the
    /// render thread is the only thread that may look at this, which is the one
    /// discipline that makes a real-time callback safe.
    private var window = JitterWindow()
    private var isRendering = false

    /// What the rest of the app is allowed to know, and the only two things it
    /// asks. Atomics rather than a lock, because the writer is a real-time
    /// thread: a render callback that blocks on a lock held by the main thread
    /// is a dropout with a priority inversion behind it.
    private let playingFlag = Atomic<Bool>(false)
    private let bufferedMillis = Atomic<UInt64>(0)
    private let cushionMillis = Atomic<UInt64>(0)
    private let dropouts = Atomic<UInt64>(0)
    /// Set by `flush`, cleared by the next render cycle that finds the buffer
    /// empty.
    ///
    /// Every caller of `flush` has just created a gap on purpose — the user
    /// started dictating, the socket dropped, a phone call took the speaker —
    /// and the silence that follows is not the link failing to keep up. Without
    /// this, each of those grows the cushion a step: dictate five times in a
    /// minute and the stream is a fifth of a second further behind for the rest
    /// of the afternoon, for no reason anybody could hear.
    private let deliberateGap = Atomic<Bool>(false)

    /// Whether samples are actually reaching the speaker, as opposed to the
    /// socket being up.
    var isPlaying: Bool { playingFlag.load(ordering: .relaxed) }
    /// How much audio is waiting, and how much the cushion currently wants.
    /// Both in milliseconds, both for the status line and the log.
    var buffered: Int { Int(bufferedMillis.load(ordering: .relaxed)) }
    var cushion: Int { Int(cushionMillis.load(ordering: .relaxed)) }
    var dropoutCount: Int { Int(dropouts.load(ordering: .relaxed)) }

    private var observers: [NSObjectProtocol] = []
    /// Reported by the engine when the route changes under it. Stored so a
    /// rebuild triggered by AirPods arriving does not fight one triggered by the
    /// interruption that came with them.
    private var isRebuilding = false

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    // MARK: - Lifecycle

    /// Builds the graph for a format, or adopts a new one.
    ///
    /// Called when the first frame arrives rather than when the socket opens,
    /// because until a frame has arrived nobody knows what is coming.
    @MainActor
    func start(format wanted: AVAudioFormat) throws {
        if let format, format == wanted, engine.isRunning { return }
        teardown()
        try AudioSession.beginListening()
        observeOnce()

        let ring = PCMRing(channels: Int(wanted.channelCount),
                           capacity: Int(wanted.sampleRate * Self.ringSeconds))
        let rate = wanted.sampleRate
        let node = AVAudioSourceNode(format: wanted) { [weak self] silence, _, frameCount, buffers in
            guard let self else {
                silence.pointee = true
                PCMRing.fill(UnsafeMutableAudioBufferListPointer(buffers), from: 0, frames: Int(frameCount))
                return noErr
            }
            return self.render(Int(frameCount),
                               into: UnsafeMutableAudioBufferListPointer(buffers),
                               silence: silence,
                               ring: ring,
                               sampleRate: rate)
        }

        // Initialise render-owned state before the engine can call render.
        window = JitterWindow()
        isRendering = false
        deliberateGap.store(false, ordering: .relaxed)
        self.source = node
        self.format = wanted
        ringLock.withLock { self.ring = ring }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: wanted)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            teardown()
            AudioSession.endListening()
            throw error
        }
        remoteLog.info("listen: playing \(Int(wanted.sampleRate))Hz \(wanted.channelCount)ch")
    }

    @MainActor
    func stop() {
        teardown()
        AudioSession.endListening()
    }

    private func teardown() {
        if engine.isRunning { engine.stop() }
        if let source {
            engine.disconnectNodeOutput(source)
            engine.detach(source)
        }
        source = nil
        ringLock.withLock { ring = nil }
        format = nil
        playingFlag.store(false, ordering: .relaxed)
        bufferedMillis.store(0, ordering: .relaxed)
    }

    /// Throws away what is buffered without stopping.
    ///
    /// For a resume: the audio that arrived while the phone was dictating — or
    /// while a phone call had the speaker — is of a moment that has passed, and
    /// playing it would mean starting the live stream several seconds late and
    /// staying there.
    func flush() {
        deliberateGap.store(true, ordering: .relaxed)
        ringLock.withLock { ring?.clear() }
        playingFlag.store(false, ordering: .relaxed)
        bufferedMillis.store(0, ordering: .relaxed)
    }

    /// Samples in. Called on the network queue, one frame at a time.
    ///
    /// Returns false when there was no room, which means the render thread has
    /// stopped draining — the engine is stopped, or the session is interrupted.
    /// Silently dropping in that case is right: the alternative is a buffer full
    /// of audio from a minute ago waiting for a speaker that is busy.
    @discardableResult
    func enqueue(_ buffer: AVAudioPCMBuffer) -> Bool {
        guard let ring = ringLock.withLock({ ring }) else { return false }
        return ring.write(buffer)
    }

    // MARK: - The render callback

    /// Runs on a real-time thread. Nothing here allocates, locks, or touches
    /// anything another thread may be writing — which is why the ring and the
    /// sample rate are handed in rather than read off `self`.
    private func render(_ frames: Int,
                        into buffers: UnsafeMutableAudioBufferListPointer,
                        silence: UnsafeMutablePointer<ObjCBool>,
                        ring: PCMRing,
                        sampleRate: Double) -> OSStatus {
        let depth = Double(ring.available) / sampleRate
        bufferedMillis.store(UInt64(depth * 1000), ordering: .relaxed)
        cushionMillis.store(UInt64(window.target * 1000), ordering: .relaxed)

        switch window.verdict(depth: depth, isPlaying: isRendering) {
        case .fill:
            if isRendering {
                // It was playing and now there is nothing. That is a dropout and
                // the cushion should be bigger next time — unless somebody asked
                // for this silence, in which case it says nothing about the link.
                isRendering = false
                if deliberateGap.exchange(false, ordering: .relaxed) == false {
                    window.noteUnderrun()
                    dropouts.wrappingAdd(1, ordering: .relaxed)
                }
                playingFlag.store(false, ordering: .relaxed)
            }
            silence.pointee = true
            PCMRing.fill(buffers, from: 0, frames: frames)
            return noErr

        case .skip(let seconds):
            // Ahead of the stream — a burst arrived, or the two clocks have
            // drifted this far apart over the last hour. Dropping the oldest
            // samples is the only correction that does not change the pitch.
            ring.skip(frames: Int(seconds * sampleRate))

        case .play:
            break
        }

        let taken = ring.read(into: buffers, frames: frames)
        silence.pointee = false
        if taken < frames {
            // Ran out partway through. The rest of this cycle is silence, and
            // the next one starts from an empty buffer, which `verdict` reads as
            // "fill" and handles above.
            PCMRing.fill(buffers, from: taken, frames: frames - taken)
            if isRendering {
                isRendering = false
                if deliberateGap.exchange(false, ordering: .relaxed) == false {
                    window.noteUnderrun()
                    dropouts.wrappingAdd(1, ordering: .relaxed)
                }
                playingFlag.store(false, ordering: .relaxed)
            }
            return noErr
        }

        if !isRendering {
            isRendering = true
            playingFlag.store(true, ordering: .relaxed)
            // Playing again: whatever the last gap was, it is over, and a stale
            // pardon must not excuse the next real dropout.
            deliberateGap.store(false, ordering: .relaxed)
        }
        window.noteClean(seconds: Double(frames) / sampleRate)
        return noErr
    }

    // MARK: - Everything iOS does to a playing app

    /// A phone call, Siri, another app taking the speaker, AirPods arriving or
    /// leaving, the media server being reset.
    ///
    /// None of these are unusual and every one of them ends the audio for good
    /// if it is not handled: iOS stops the engine and does not start it again,
    /// and the app is left holding a socket full of samples and a silent
    /// speaker. Which is precisely the failure this whole feature cannot have —
    /// the phone is in a pocket and nobody is watching for it.
    @MainActor
    private func observeOnce() {
        guard observers.isEmpty else { return }
        let centre = NotificationCenter.default

        observers.append(centre.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(), queue: .main) { [weak self] note in
                guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
                Task { @MainActor in
                    guard let self else { return }
                    switch type {
                    case .began:
                        // iOS has already stopped the engine. Nothing to do but
                        // note it and let the buffer go stale.
                        self.playingFlag.store(false, ordering: .relaxed)
                    case .ended:
                        self.resume(discardingBuffer: true, why: "interruption ended")
                    @unknown default:
                        break
                    }
                }
            })

        observers.append(centre.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(), queue: .main) { [weak self] _ in
                Task { @MainActor in
                    // Not discarded: a route change is a couple of hundred
                    // milliseconds, and what is buffered is still current.
                    self?.resume(discardingBuffer: false, why: "route changed")
                }
            })

        observers.append(centre.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: AVAudioSession.sharedInstance(), queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let format = self.format else { return }
                    // The only notification that means the graph is gone rather
                    // than stopped. Everything has to be built again.
                    remoteLog.error("listen: media services reset")
                    self.teardown()
                    try? self.start(format: format)
                }
            })

        observers.append(centre.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.reconnect() }
            })
    }

    /// Asks for the session back and starts the engine again.
    @MainActor
    private func resume(discardingBuffer discard: Bool, why: String) {
        guard format != nil else { return }
        if discard { flush() }
        do {
            try AudioSession.reactivate()
            if !engine.isRunning { try engine.start() }
        } catch {
            remoteLog.error("listen: could not resume after \(why, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The engine tore its own graph down because the hardware format changed —
    /// which is what plugging in AirPods is, from here.
    ///
    /// Reconnecting rather than rebuilding: the source node and the ring are
    /// still good, and rebuilding them would throw away the buffer and the
    /// cushion the link has spent the last minute learning.
    @MainActor
    private func reconnect() {
        guard !isRebuilding, let source, let format else { return }
        isRebuilding = true
        defer { isRebuilding = false }
        engine.connect(source, to: engine.mainMixerNode, format: format)
        do {
            if !engine.isRunning { try engine.start() }
        } catch {
            remoteLog.error("listen: could not restart after a route change: \(error.localizedDescription, privacy: .public)")
        }
    }
}

// MARK: - The ring

/// A single-producer, single-consumer ring of deinterleaved Float32.
///
/// One writer (the network queue) and one reader (the render thread), and the
/// two never touch the same counter — so the only synchronisation needed is that
/// each side sees the other's index in order, which is what the acquire/release
/// pairs below are. No lock, because the reader is a real-time thread and a lock
/// there is a dropout waiting for the main thread to be busy.
///
/// Monotonic counters rather than wrapped ones: `written - read` is the fill
/// level with no special case for "full looks like empty", and both only wrap at
/// 2^64 frames, which at 48 kHz is twelve million years.
///
/// `@unchecked Sendable` is the claim this whole type exists to make: it is safe
/// to hand to two threads, provided each of them only ever plays one of the two
/// roles. Nothing enforces that but the three methods below being named for
/// which side they belong to.
final class PCMRing: @unchecked Sendable {
    private let capacity: Int
    private let channels: Int
    private let storage: [UnsafeMutablePointer<Float>]
    private let written = Atomic<UInt64>(0)
    private let read = Atomic<UInt64>(0)
    private let clearThrough = Atomic<UInt64>(0)

    init(channels: Int, capacity: Int) {
        let lanes = max(channels, 1)
        let frames = max(capacity, 1024)
        self.channels = lanes
        self.capacity = frames
        // Zeroed on the way in. A ring read before anything has been written to
        // it would otherwise hand whatever was in that memory to the speaker,
        // which is a burst of noise at full volume.
        storage = (0..<lanes).map { _ in
            let pointer = UnsafeMutablePointer<Float>.allocate(capacity: frames)
            pointer.initialize(repeating: 0, count: frames)
            return pointer
        }
    }

    deinit { storage.forEach { $0.deallocate() } }

    /// Frames waiting to be played.
    var available: Int {
        applyClear()
        let w = written.load(ordering: .acquiring)
        let r = read.load(ordering: .relaxed)
        return Int(w &- r)
    }

    func clear() {
        // Request a discard without publishing free storage while a render
        // callback may still be copying from it. Only the consumer owns `read`.
        clearThrough.store(written.load(ordering: .acquiring), ordering: .releasing)
    }

    /// Consumer only, before observing depth or copying any samples.
    private func applyClear() {
        let discard = clearThrough.load(ordering: .acquiring)
        if discard > read.load(ordering: .relaxed) {
            read.store(discard, ordering: .releasing)
        }
    }

    /// Producer side.
    @discardableResult
    func write(_ buffer: AVAudioPCMBuffer) -> Bool {
        let frames = Int(buffer.frameLength)
        guard frames > 0, let channelData = buffer.floatChannelData else { return false }
        let w = written.load(ordering: .relaxed)
        let r = read.load(ordering: .acquiring)
        guard capacity - Int(w &- r) >= frames else { return false }

        let start = Int(w % UInt64(capacity))
        let firstRun = min(frames, capacity - start)
        let sources = Int(buffer.format.channelCount)
        for channel in 0..<channels {
            // A mono stream into a stereo ring, or the other way, is not
            // something the Mac should ever send — but a wrong answer here is a
            // buffer overrun, so the source channel is clamped rather than
            // trusted.
            let from = channelData[min(channel, sources - 1)]
            storage[channel].advanced(by: start).update(from: from, count: firstRun)
            if firstRun < frames {
                storage[channel].update(from: from.advanced(by: firstRun), count: frames - firstRun)
            }
        }
        written.store(w &+ UInt64(frames), ordering: .releasing)
        return true
    }

    /// Consumer side: as many frames as asked for, or as many as there are.
    func read(into buffers: UnsafeMutableAudioBufferListPointer, frames: Int) -> Int {
        applyClear()
        let r = read.load(ordering: .relaxed)
        let w = written.load(ordering: .acquiring)
        let taken = min(frames, Int(w &- r))
        guard taken > 0 else { return 0 }

        let start = Int(r % UInt64(capacity))
        let firstRun = min(taken, capacity - start)
        for index in 0..<buffers.count {
            guard let destination = buffers[index].mData?.assumingMemoryBound(to: Float.self) else { continue }
            let source = storage[min(index, channels - 1)]
            destination.update(from: source.advanced(by: start), count: firstRun)
            if firstRun < taken {
                destination.advanced(by: firstRun).update(from: source, count: taken - firstRun)
            }
        }
        read.store(r &+ UInt64(taken), ordering: .releasing)
        return taken
    }

    /// Consumer side: throw the oldest frames away.
    func skip(frames: Int) {
        guard frames > 0 else { return }
        applyClear()
        let r = read.load(ordering: .relaxed)
        let w = written.load(ordering: .acquiring)
        read.store(r &+ UInt64(min(frames, Int(w &- r))), ordering: .releasing)
    }

    /// Silence into part of a render cycle's buffers.
    ///
    /// Static, because it is also what the render block does when there is no
    /// player left to ask — and an audio callback that returns without writing
    /// its buffers plays whatever was in that memory last, which is a burst of
    /// noise at full volume.
    static func fill(_ buffers: UnsafeMutableAudioBufferListPointer, from offset: Int, frames: Int) {
        guard frames > 0 else { return }
        for index in 0..<buffers.count {
            guard let base = buffers[index].mData?.assumingMemoryBound(to: Float.self) else { continue }
            base.advanced(by: offset).update(repeating: 0, count: frames)
        }
    }
}
