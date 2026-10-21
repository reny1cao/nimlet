import Foundation
import Network
import AVFoundation

/// Owns the listen channel: who is listening, and pushing the Mac's own output
/// mix to each of them.
///
/// The shape is `PanelStreamer`'s, deliberately — capture starts when the first
/// listener attaches and stops when the last one leaves, so a Mac nobody is
/// listening to is a Mac that is not capturing anything and does not have the
/// recording indicator lit all day.
///
/// What is *not* `PanelStreamer`'s shape is what happens under pressure. The
/// mirror drops frames freely: a frame nobody can receive yet is superseded by
/// the next one, and the picture catches up by itself. Audio has no such thing
/// as a superseding sample — every packet dropped is a hole you can hear — so
/// this queues rather than drops, and only drops when the queue has grown past
/// the point where what is in it is no longer worth hearing.
///
/// That was the intent and it was not what the code did. There was no queue: a
/// listener with four frames outstanding was filtered out of the send and the
/// frame built for it was thrown away — the *newest* audio, the part that was
/// still worth hearing, while the socket held the oldest. So a half-second of
/// Wi-Fi contention punched a hole in the stream, the phone's cushion underran,
/// and `JitterWindow` answered by moving every listener further behind the Mac
/// for the rest of the afternoon. There is a real queue now, it is bounded in
/// seconds rather than frames, and when it has to give something up it gives up
/// the front — which is the audio the phone would have discarded on arrival.
final class AudioStreamer {
    static let shared = AudioStreamer()

    private final class Listener {
        let connection: NWConnection
        var name: String
        /// The phone is dictating and has asked for silence. Its socket stays.
        var isPaused: Bool
        /// Encoded frames waiting for the socket, oldest first, with how much
        /// sound each one is — the bound below is a duration, not a count, and a
        /// count cannot be converted into one after the fact because AAC frames
        /// are not all the same size.
        var queue: [(data: Data, seconds: Double)] = []
        var queuedSeconds: Double = 0
        /// True between handing a frame to the transport and it being taken. One
        /// at a time on purpose: what the socket holds cannot be trimmed, and
        /// what this queue holds can, so the backlog belongs here.
        var isWriting = false

        init(connection: NWConnection, hello: ListenHelloPayload) {
            self.connection = connection
            self.name = hello.deviceName
            self.isPaused = hello.isPaused
        }
    }

    /// About 170 ms, which is four frames at the current packing.
    ///
    /// Past this the link is not keeping up and the audio at the front is as old
    /// as the cushion the phone keeps — it would throw it away on arrival, so
    /// sending it is work done to make the delay worse. Under it, a burst of
    /// contention is absorbed rather than heard, which is the whole difference
    /// between a queue and the filter this replaces.
    private static let maxQueuedSeconds = 0.17

    /// How much sound one frame carries, from the frame rather than from the
    /// constant. `build` takes everything pending, which is usually
    /// `packetsPerFrame` and is occasionally one more — the converter can
    /// complete two packets in a call that had one waiting — and a bound in
    /// seconds that assumed the constant would be quietly wrong whenever it did.
    private static func seconds(of frame: AudioFrame) -> Double {
        Double(frame.packets?.count ?? AudioChannel.packetsPerFrame) * AudioChannel.packetSeconds
    }

    private let lock = NSLock()
    private var listeners: [ObjectIdentifier: Listener] = [:]
    /// Start and stop arrive from the network queue (a phone attaching) and from
    /// main (the switch in the menu); one serial queue for both, so they cannot
    /// interleave halfway through.
    private let control = DispatchQueue(label: "com.renyicao.mice.host.listen")

    private var capture: SystemAudio!
    private let encoder = AudioEncoder()
    /// Guards the codec and the half-built frame.
    ///
    /// Both are written on ScreenCaptureKit's delivery queue, which is where an
    /// encode has to happen — the samples are a view into a block buffer that is
    /// alive for the length of that callback and no longer. And both are *reset*
    /// on `control`, when the last listener leaves. Stopping an `SCStream` is
    /// asynchronous, so a buffer is often still in flight while that reset runs:
    /// without this, the teardown clears the packet list from under an encode
    /// that is halfway through appending to it.
    private let encodeLock = NSLock()
    /// Packets waiting to fill a frame.
    private var pending: [Data] = []
    private var pendingAt: UInt64 = 0
    private var sequence: UInt32 = 0
    /// Frames until the format is repeated. Touched only on the capture queue.
    private var untilDescribe = 0
    /// Set by an attach, so a phone that has just arrived is told what it is
    /// about to hear on the very next frame rather than up to two seconds later.
    /// Under the lock because an attach arrives on the network queue and this is
    /// read where the frames are built.
    private var wantsDescribe = false
    private var lastState: String?

    private init() {
        capture = SystemAudio(
            onBuffer: { [weak self] buffer, arrived in self?.encodeAndSend(buffer, at: arrived) },
            onState: { [weak self] reason in self?.sendState(reason) })
    }

    /// Whether anybody is listening. The menu names them from the device list,
    /// which is published; this is what decides whether to capture at all.
    var listenerCount: Int { lock.withLock { listeners.count } }

    /// The switch in the menu. Off refuses the channel outright and tells the
    /// phones why, rather than handing them a silence they cannot interpret.
    ///
    /// Stored rather than held in memory: a Mac that has been told not to send
    /// its audio has not changed its mind because it was restarted.
    private static let allowedKey = "mice.listen.allowed"
    var isAllowed: Bool {
        get {
            // Absent means yes. A phone the user has approved can already be
            // shown the screen, and refusing sound by default would be a
            // setting nobody finds for a feature they asked for.
            UserDefaults.standard.object(forKey: Self.allowedKey) as? Bool ?? true
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.allowedKey)
            guard !newValue else { restart(); return }
            let stranded = lock.withLock { Array(listeners.values) }
            for listener in stranded {
                send(.state("This Mac is set not to send its audio"), payload: Data(), to: [listener])
            }
            control.async { self.stopNow() }
        }
    }

    // MARK: - Listeners

    /// Also the pause and the resume: a phone re-sends its hello rather than
    /// dropping a socket it will want back in three seconds.
    func attach(_ connection: NWConnection, hello: ListenHelloPayload) {
        let key = ObjectIdentifier(connection)
        let isNew = lock.withLock { () -> Bool in
            if let existing = listeners[key] {
                existing.name = hello.deviceName
                // Going quiet throws away what is queued rather than holding it
                // for the resume. The phone flushes its own buffer when it takes
                // the microphone, and a Mac that answered the release of a
                // dictation button with a fifth of a second of audio from before
                // it would be replaying the moment the user just spoke over.
                if hello.isPaused, !existing.isPaused {
                    existing.queue.removeAll()
                    existing.queuedSeconds = 0
                }
                existing.isPaused = hello.isPaused
                return false
            }
            listeners[key] = Listener(connection: connection, hello: hello)
            return true
        }
        // Whoever has just arrived, or just come back, has no idea what format
        // the next frame is in.
        lock.withLock { wantsDescribe = true }
        guard isAllowed else {
            send(.state("This Mac is set not to send its audio"), payload: Data(),
                 to: lock.withLock { listeners[key].map { [$0] } ?? [] })
            return
        }
        if isNew {
            miceLog.info("listen: \(hello.deviceName, privacy: .private) attached")
        }
        restart()
    }

    func detach(_ connection: NWConnection) {
        let removed = lock.withLock { listeners.removeValue(forKey: ObjectIdentifier(connection)) }
        guard let removed else { return }
        guard listenerCount > 0 else {
            control.async { self.stopNow() }
            // "nobody listening" rather than "capture stopped", because the
            // capture may never have started — the switch in the menu can be off,
            // in which case this line is the only one in the log and it should
            // not send whoever is reading it looking for a capture that failed.
            miceLog.info("listen: \(removed.name, privacy: .private) left, nobody listening")
            return
        }
        restart()
    }

    // MARK: - Capture

    private func restart() {
        control.async {
            guard self.isAllowed, self.listenerCount > 0 else { self.stopNow(); return }
            self.lock.withLock { self.lastState = nil }
            self.capture.start()
        }
    }

    private func stopNow() {
        capture.stop()
        encodeLock.withLock {
            encoder.invalidate()
            pending.removeAll()
        }
        lock.withLock {
            lastState = nil
            // Whatever is queued is of a moment that has passed, and the next
            // listener to arrive would hear it before anything live.
            for listener in listeners.values {
                listener.queue.removeAll()
                listener.queuedSeconds = 0
            }
        }
    }

    /// Whether any listener wants to hear the next packet.
    ///
    /// Asked before encoding rather than before sending: a phone that has asked
    /// for silence while it dictates should cost this Mac nothing at all, and
    /// the capture is the part that cannot be stopped for three seconds without
    /// costing a second to come back.
    private var isWanted: Bool {
        lock.withLock { listeners.values.contains { !$0.isPaused } }
    }

    private func encodeAndSend(_ buffer: AVAudioPCMBuffer, at arrived: UInt64) {
        guard isAllowed, isWanted else {
            // Nothing to send, and the codec's accumulated half-packet is about
            // to be a splice across a silence. Better to start the next packet
            // cleanly than to join two sides of a gap.
            encodeLock.withLock { pending.removeAll() }
            return
        }
        let frame: (AudioFrame, Data)? = encodeLock.withLock {
            guard let output = encoder.encode(buffer) else { return nil }
            if pending.isEmpty { pendingAt = arrived }
            var offset = 0
            for length in output.packets {
                pending.append(output.data.subdata(in: offset..<(offset + length)))
                offset += length
            }
            guard pending.count >= AudioChannel.packetsPerFrame else { return nil }
            return build()
        }
        guard let frame else { return }
        lock.withLock { lastState = nil }
        // Everybody who is listening, with no room test: the room test is the
        // queue's, and its answer is which end to give up rather than whether to
        // take the frame at all.
        let ready: [Listener] = lock.withLock { listeners.values.filter { !$0.isPaused } }
        enqueue(frame.0, payload: frame.1, to: ready)
    }

    /// Takes whatever is pending and makes a frame of it. Called with
    /// `encodeLock` held; sending happens outside it, because a socket write is
    /// not something to hold a codec's lock across.
    private func build() -> (AudioFrame, Data)? {
        guard !pending.isEmpty else { return nil }
        let packets = pending
        pending.removeAll(keepingCapacity: true)

        sequence &+= 1
        var frame = AudioFrame(kind: .audio, captureTime: pendingAt)
        frame.packets = packets.map(\.count)
        frame.sequence = sequence
        let asked = lock.withLock { () -> Bool in
            guard wantsDescribe else { return false }
            wantsDescribe = false
            return true
        }
        if untilDescribe <= 0 || asked, let described = encoder.describedFormat {
            // Repeated rather than sent once, for the same reason the mirror
            // repeats its parameter sets on every keyframe: a listener can join
            // at any moment, and a stream you cannot start playing is not a
            // stream. Every fiftieth frame is about two seconds and costs 1% of
            // the bandwidth to say.
            frame.codec = .aac
            frame.sampleRate = described.sampleRate
            frame.channels = described.channels
            frame.framesPerPacket = described.framesPerPacket
            untilDescribe = 50
        } else {
            untilDescribe -= 1
        }

        var payload = Data(capacity: packets.reduce(0) { $0 + $1.count })
        for packet in packets { payload.append(packet) }
        return (frame, payload)
    }

    // MARK: - Sending

    private func sendState(_ reason: String) {
        let changed = lock.withLock { () -> Bool in
            guard reason != lastState else { return false }
            lastState = reason
            return true
        }
        guard changed else { return }
        send(.state(reason), payload: Data(), to: lock.withLock { Array(listeners.values) })
    }

    /// Audio into each listener's queue, then a nudge at the socket.
    ///
    /// The trim is the point of the whole structure: when the queue is over its
    /// bound the *oldest* frame goes, not the newest. Those two choices sound
    /// nothing alike. Dropping the newest leaves a hole in the middle of what the
    /// phone is about to play; dropping the oldest shortens the delay and is
    /// inaudible, because what came off the front is audio the phone's own
    /// cushion would have skipped past on arrival.
    private func enqueue(_ frame: AudioFrame, payload: Data, to listeners: [Listener]) {
        guard !listeners.isEmpty,
              let data = try? AudioFrameWriter.encode(frame, payload: payload) else { return }
        let seconds = Self.seconds(of: frame)
        var dropped = 0
        let waiting: [Listener] = lock.withLock {
            var claimed: [Listener] = []
            for listener in listeners {
                // Recheck membership and pause under the same lock as the
                // append: a snapshot made before a revoke or a hold must not
                // queue anything afterward.
                guard self.listeners[ObjectIdentifier(listener.connection)] === listener else { continue }
                guard isAllowed, !listener.isPaused else { continue }
                listener.queue.append((data, seconds))
                listener.queuedSeconds += seconds
                while listener.queuedSeconds > Self.maxQueuedSeconds, listener.queue.count > 1 {
                    listener.queuedSeconds -= listener.queue.removeFirst().seconds
                    dropped += 1
                }
                claimed.append(listener)
            }
            return claimed
        }
        if dropped > 0, Instrumentation.isEnabled {
            miceLog.info("listen: \(dropped) frame(s) too old to send")
        }
        waiting.forEach(pump)
    }

    /// One frame from the head of a listener's queue into its socket, and the
    /// next one when that is taken.
    private func pump(_ listener: Listener) {
        let next: Data? = lock.withLock {
            guard listeners[ObjectIdentifier(listener.connection)] === listener else { return nil }
            guard !listener.isWriting, !listener.queue.isEmpty else { return nil }
            let head = listener.queue.removeFirst()
            listener.queuedSeconds = max(0, listener.queuedSeconds - head.seconds)
            listener.isWriting = true
            return head.data
        }
        guard let next else { return }
        listener.connection.send(content: next, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.lock.withLock { listener.isWriting = false }
            if error != nil { self.detach(listener.connection); return }
            self.pump(listener)
        })
    }

    /// A status line, straight past the queue.
    ///
    /// It has to overtake whatever audio is waiting rather than queue behind it:
    /// the sentence explains why there is nothing to hear, and a phone shown it
    /// half a second late has already decided the link is broken. Nothing
    /// supersedes it either, so unlike audio it is never dropped.
    private func send(_ frame: AudioFrame, payload: Data, to listeners: [Listener]) {
        guard !listeners.isEmpty, let data = try? AudioFrameWriter.encode(frame, payload: payload) else { return }
        let ready: [Listener] = lock.withLock {
            listeners.filter { self.listeners[ObjectIdentifier($0.connection)] === $0 }
        }
        for listener in ready {
            listener.connection.send(content: data, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                if error != nil { self.detach(listener.connection) }
            })
        }
    }
}
