import Foundation

/// What the mirror is allowed to spend on the link, measured rather than assumed.
///
/// The host used to pick a bitrate from the *name* of the interface — 12 Mbps on
/// Wi-Fi, 2.5 over AWDL — and then never look again. A link that could not carry
/// the number was never told to send less; it simply stopped accepting frames,
/// and because the sender waited for each frame to be taken before capturing the
/// next, "the link is full" and "the mirror has stopped" were the same thing.
///
/// There is a measurement available and it costs nothing to take. `NWConnection`
/// says when it has accepted a frame, and the interval from handing a frame over
/// to that acknowledgement is the only honest throughput signal a TCP sender
/// gets: while the socket buffer has room the write returns at once and says
/// nothing, and once it is full the write is paced by the link itself. So a frame
/// that took a while to be taken is both the congestion signal *and* the
/// bandwidth sample — bytes over seconds, of a transfer the link metered.
///
/// The loop that follows is deliberately plain: probe upward in small steps
/// while nothing is going wrong, and cut hard the moment something does. That
/// asymmetry is the whole point. Growing slowly costs a little sharpness for a
/// second or two; shrinking slowly costs a frozen picture, because every frame
/// sent into a full link is another frame of backlog for the ones behind it.
public struct VideoPacer: Sendable, Equatable {

    /// Below this the picture is not worth looking at, and the problem is not one
    /// bitrate control can solve.
    public static let floor = 700_000

    /// The floor for a viewer that is away — through the relay or across the
    /// internet. Measured on 2026-10-05 from 5G through the Singapore relay, the
    /// phone's acknowledgements still showed a queue at 700 kbps: the path
    /// carried less than that, and a floor above the link's capacity is a floor
    /// that keeps a queue, which is the pointer arriving late on screen. A
    /// softer picture of where the pointer is now beats a sharp one of where it
    /// was.
    public static let farFloor = 300_000
    /// A frame the transport took longer than this to accept was paced by the
    /// link rather than by memcpy. Roughly two frame intervals at 60 Hz: long
    /// enough that an ordinary write into a socket with room never trips it,
    /// short enough to react before a backlog is something you can see.
    public static let stallSeconds = 0.035

    /// Under this a frame's accept time is mostly fixed cost — TLS, the syscall,
    /// the queue hop — and dividing by it would claim a throughput the link
    /// cannot deliver. Only frames the link actually metered are sampled.
    private static let sampleFloorSeconds = 0.006
    private static let sampleFloorBytes = 6_000

    /// How much of the measured capacity to aim at. The remainder is what keeps
    /// the audio socket — and the pointer socket, and everything else sharing
    /// this Wi-Fi — out of a queue behind the mirror.
    private static let safety = 0.82

    /// One step down, and it is a step rather than a slide for the reason above.
    private static let backoff = 0.72

    /// How long a step down is given to take effect before another is allowed.
    ///
    /// The part that cannot be left out, and the reason is arithmetic rather than
    /// taste. Every frame sent into a link that is already full comes back slow,
    /// so a controller that cuts on each one cuts eight or nine times before the
    /// first cut has reached the encoder — measured against a 6 Mbps link, that
    /// took the rate from 12 Mbps to the floor inside a second and left 78% of
    /// the link unused for the rest of the run. One cut per episode, then wait
    /// and look again. TCP has worked this way since 1988 for the same reason.
    private static let cutCooldownSeconds = 0.35

    /// And one step up, taken after this long with nothing going wrong.
    ///
    /// Seconds rather than a frame count, which is what it used to be: a link bad
    /// enough to be worth recovering from is also a link running at ten frames a
    /// second, so a count meant the recovery slowed down exactly when it was
    /// needed most.
    private static let probe = 1.1
    private static let probeSeconds = 1.0

    /// How much may be in the transport at once, as a fraction of a second at
    /// the current rate. Enough to keep the encoder busy while the last frame
    /// drains; not enough to be a queue.
    private static let inFlightSeconds = 0.05

    /// How quickly the delivered frame rate is believed.
    ///
    /// Asymmetric, and for the same reason the bitrate is: measured against a
    /// hardware HEVC encoder, telling it 60 fps while a fraction of that is
    /// actually going out makes it overshoot the rate it was asked for by three
    /// times — 1.5 Mbps requested, 4.5 delivered — because it spends a second's
    /// budget across sixty frames and then sends twenty of them. Overshooting
    /// during congestion is the one thing that must not happen, so a frame rate
    /// that has fallen is believed at once and one that has risen is not.
    private static let rateFallAlpha = 0.3
    private static let rateRiseAlpha = 0.08

    /// What the encoder is being asked for right now.
    public private(set) var bitrate: Int
    /// The frame rate actually reaching the phone, which is what the encoder's
    /// rate allocator has to be told about.
    ///
    /// It turns a bitrate into a per-frame size by dividing by this. Told 60
    /// while twenty are going out, it asks itself for frames a third the size it
    /// can actually make — measured against the hardware HEVC encoder, a
    /// 1920x1200 window in motion does not come out below about 10 KB a frame
    /// whatever rate it is given — so it abandons the target and emits sixty of
    /// them anyway: 1.5 Mbps asked for, 4.5 delivered, on exactly the link that
    /// provoked the back-off. Told twenty, the per-frame budget is something it
    /// can meet, and it meets it to within a fifth.
    public private(set) var framesPerSecond: Double
    /// Bytes per second, as metered by the link. Nil until the link has made us
    /// wait for something, which on a quiet gigabit LAN is never — and on a
    /// quiet gigabit LAN there is nothing to adapt to.
    public private(set) var goodput: Double?

    /// What the encoder was last told, which is not always `bitrate`: a change
    /// too small to be worth a retune moves `bitrate` and leaves this alone.
    ///
    /// Retunes are judged against this rather than against the step just
    /// taken, and that is the difference between a mirror that recovers and
    /// one that does not. Every probe is a 10% step and the retune threshold is
    /// an eighth, so judged step by step no probe was ever worth telling the
    /// encoder about: the pacer climbed back to the ceiling on its own while the
    /// encoder stayed at whatever the last cut had left it — measured on
    /// 2026-10-15, a phone on a direct path sat at the 300 kbps floor for four
    /// minutes. Judged against this, two probes add up to a retune.
    public private(set) var told: Int
    /// The interface-derived ceiling. Measurement can only ask for less.
    private var ceiling: Int
    /// The least this stream is ever asked for: `floor`, or `farFloor` for a
    /// viewer that is away.
    public private(set) var minimum: Int
    /// Seconds of delivery since the last step down, and since the last one that
    /// went cleanly. Accumulated from the intervals the caller reports rather
    /// than read off a clock, so this type stays a pure function of what it is
    /// told — which is what makes the loop testable at all.
    private var sinceCut = Double.infinity
    private var cleanSeconds: Double = 0

    public init(ceiling: Int, minimum: Int = VideoPacer.floor) {
        self.minimum = minimum
        self.ceiling = max(ceiling, minimum)
        self.bitrate = self.ceiling
        self.told = self.ceiling
        self.framesPerSecond = 60
    }

    /// A new ceiling — the viewer set changed, and with it the interface. Keeps
    /// whatever has been learned about the link when the ceiling has not moved.
    public mutating func setCeiling(_ value: Int, minimum: Int = VideoPacer.floor) {
        self.minimum = minimum
        bitrate = max(bitrate, minimum)
        let clamped = max(value, minimum)
        guard clamped != ceiling else { return }
        ceiling = clamped
        bitrate = min(bitrate, clamped)
        // A ceiling that went up is an invitation to find out, not a licence to
        // jump: the probe below gets there a step at a time.
        cleanSeconds = 0
    }

    /// The caller has just told the encoder `bitrate` outside the `note…`
    /// methods — a new ceiling, a conservative start, a new session.
    public mutating func noteTold() {
        told = bitrate
    }

    /// One frame reached the transport. `seconds` is how long that took.
    ///
    /// Returns true when the encoder should be retuned, so the caller is not
    /// setting VideoToolbox properties sixty times a second to move a number by
    /// a kilobit.
    @discardableResult
    public mutating func noteDelivered(bytes: Int, seconds: Double,
                                       interval: Double) -> Bool {
        noteInterval(interval)
        let step = interval > 0 && interval < 2 ? interval : 0
        sinceCut += step

        if seconds >= Self.sampleFloorSeconds, bytes >= Self.sampleFloorBytes {
            let sample = Double(bytes) / seconds
            goodput = goodput.map { $0 + (sample - $0) * 0.25 } ?? sample
        }

        if seconds > Self.stallSeconds {
            cleanSeconds = 0
            cut()
        } else {
            cleanSeconds += step
            if cleanSeconds >= Self.probeSeconds {
                cleanSeconds = 0
                bitrate = min(ceiling, Int(Double(bitrate) * Self.probe))
            }
        }
        return retuneIfWorthIt()
    }

    /// End-to-end queueing delay this far above the link's quickest round trip
    /// is a queue building somewhere between here and the glass — in the relay,
    /// in a cellular base station — and is cut on.
    public static let queueCutSeconds = 0.08
    /// Above this, a queue is forming: not worth cutting on yet, but not a time
    /// to probe upward either.
    public static let queueHoldSeconds = 0.03

    /// The phone acknowledged a frame, and this is how long it sat in queues on
    /// the way (`VideoFlowWindow`). The local-socket signal above cannot see
    /// those queues; this is the one that can.
    ///
    /// - Parameter deliveryRate: bytes per second the phone has actually been
    ///   acknowledging. While a queue is building the link is full, so this is
    ///   its capacity, and a cut lands there rather than walking down to it.
    @discardableResult
    public mutating func noteQueueDelay(_ seconds: Double, deliveryRate: Double?) -> Bool {
        guard seconds > Self.queueHoldSeconds else { return false }
        cleanSeconds = 0
        guard seconds > Self.queueCutSeconds else { return false }
        if let deliveryRate { goodput = deliveryRate }
        cut()
        return retuneIfWorthIt()
    }

    /// A frame had to be thrown away because the transport was still busy with
    /// the last one. The strongest congestion signal there is: it is not that a
    /// frame was slow, it is that there was no room for one at all.
    @discardableResult
    public mutating func noteDropped() -> Bool {
        cleanSeconds = 0
        cut()
        return retuneIfWorthIt()
    }

    /// One step down, at most once per `cutCooldownSeconds` of delivery.
    ///
    /// Two bounds on where it lands, and the lower one wins: a step down from
    /// where we are, and — once the link has been measured — a rate it has
    /// actually shown it can carry. The second is what makes a single cut land
    /// close to the answer instead of walking towards it.
    private mutating func cut() {
        guard sinceCut >= Self.cutCooldownSeconds else { return }
        sinceCut = 0
        var wanted = Int(Double(bitrate) * Self.backoff)
        if let goodput { wanted = min(wanted, Int(goodput * 8 * Self.safety)) }
        bitrate = max(minimum, min(ceiling, wanted))
    }

    /// Where a viewer from away starts, before anything is measured. The far
    /// ceiling is 2.5 Mbps; starting there on a path that carries one built a
    /// second of queue in the first second of every session (2026-10-05). The
    /// probe finds its way up from here in a few seconds if the path allows.
    public static let farStart = 1_000_000

    /// Starts lower when nothing has been learned yet. Does nothing once the
    /// link has been measured, so a reattaching viewer keeps what was learned.
    public mutating func startConservatively(at rate: Int) {
        guard goodput == nil else { return }
        bitrate = min(bitrate, max(minimum, rate))
        cleanSeconds = 0
    }

    /// The link is gone, or the mirror has moved to another window. Whatever was
    /// learned was learned about something else.
    public mutating func reset() {
        bitrate = ceiling
        told = ceiling
        goodput = nil
        framesPerSecond = 60
        cleanSeconds = 0
        sinceCut = .infinity
    }

    /// How many bytes of this stream may be inside the transport at once.
    ///
    /// A slice of a second at the current rate: enough that frame N+1 is encoded
    /// while frame N drains, which is the bubble this replaces, and far too
    /// little to accumulate into latency. At 12 Mbps that is 75 KB, which two
    /// delta frames fit inside and a keyframe does not; at the floor it is a few
    /// kilobytes, which is one frame and no more.
    ///
    /// It does not need to leave room for a first frame, and deliberately does
    /// not try: an empty transport always takes one whatever this says, which is
    /// where that guarantee belongs. A floor generous enough to hold a frame
    /// here would quietly allow two of them at low rates — a tenth of a second
    /// of link, on exactly the link that can least afford it.
    public var inFlightByteBudget: Int {
        max(4096, Int(Double(bitrate) / 8 * Self.inFlightSeconds))
    }

    /// Frames of this stream that may be in the transport at once.
    ///
    /// Two, and the second one is the whole gain: the old rule was one, which
    /// meant the encoder sat idle for the entire time a frame took to be
    /// accepted — and for a keyframe on a busy link that is most of a tenth of a
    /// second, every time.
    public static let maxFramesInFlight = 2

    private mutating func noteInterval(_ interval: Double) {
        guard interval > 0, interval < 2 else { return }
        let sample = min(1 / interval, 120)
        let alpha = sample < framesPerSecond ? Self.rateFallAlpha : Self.rateRiseAlpha
        framesPerSecond += (sample - framesPerSecond) * alpha
    }

    /// Retuning a live compression session is cheap but not free, and a rate
    /// that jitters by a percent teaches the encoder nothing. Measured from
    /// what the encoder was last told, so small steps in one direction add up.
    private mutating func retuneIfWorthIt() -> Bool {
        guard bitrate != told, abs(bitrate - told) * 8 >= told else { return false }
        told = bitrate
        return true
    }
}

// MARK: - Keeping the picture with the sound

/// How long the phone holds a video frame so that what you see and what you hear
/// are of the same moment.
///
/// The two streams arrive on their own sockets and are treated oppositely on
/// purpose: a video frame is put on the glass the instant it lands, because the
/// mirror is something you point at, while audio goes through a cushion that
/// `JitterWindow` sizes to the link. So the sound is always the cushion's worth
/// of milliseconds behind the picture — which nobody notices while the Mac is
/// showing a terminal, and everybody notices the moment it is showing a face.
///
/// Both channels already stamp every frame with the same host clock, and the
/// control channel already measures the offset between that clock and this
/// phone's. So the correction needs no new field on the wire: hold the picture by
/// the difference between the two paths' delays.
public enum VideoHold {

    /// Past this the mirror is no longer a thing you can drive, and a lip-sync
    /// error is the better of the two faults.
    public static let maximum = 0.28

    /// Below this it is not worth holding a frame, and chasing the last few
    /// milliseconds of a measurement that moves would be visible as judder.
    public static let deadband = 0.025

    /// Seconds to hold each video frame, given how far behind the Mac each path
    /// is running. Nil arguments — no measurement yet, or nothing playing — mean
    /// no hold, which is the mirror's own preference.
    public static func seconds(audioDelay: Double?, videoDelay: Double?) -> Double {
        guard let audioDelay, let videoDelay else { return 0 }
        let difference = audioDelay - videoDelay
        guard difference > deadband else { return 0 }
        return min(difference, maximum)
    }
}
