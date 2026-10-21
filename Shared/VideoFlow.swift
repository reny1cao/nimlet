import Foundation

/// How much of the mirror is between the Mac and the phone's glass, measured by
/// the phone saying what it has received.
///
/// `VideoPacer` used to learn about the link only from `NWConnection` taking a
/// frame, which is the Mac's own kernel accepting it. On the LAN that is close
/// enough to the truth. Through the connect relay it is not: the first hop is a
/// loopback socket into the relay pump, then the Mac's socket to the relay, the
/// relay's own buffers, the relay's socket to the phone and the cellular
/// downlink. Every one of them will take a frame long before the phone has it,
/// so the pacer saw a link with room in it while seconds of picture queued up —
/// and the pointer's replies queued behind that picture on the shared downlink.
///
/// So the phone acknowledges every batch of video it reads (`viewAck`), with the
/// highest sequence number in it, and this counts what has been sent and not yet
/// acknowledged. TCP delivers in order, which is what lets one number
/// acknowledge everything before it.
///
/// Two things come out of it:
///
/// - **Room**: a bound on the bytes in flight end to end, a little more than one
///   round trip's worth at the current rate. Enough to keep the link busy; too
///   little to become a queue. The encoder is not even asked for a frame there is
///   no room for, so congestion costs frame rate rather than latency.
/// - **Queueing delay**: how much longer a frame took to be acknowledged than the
///   quickest the link has managed lately, less the time the frame itself takes
///   to cross at the rate it is being sent. That is the delay-based congestion
///   signal `VideoPacer.noteQueueDelay` cuts the bitrate on.
public struct VideoFlowWindow: Sendable, Equatable {

    /// What one acknowledgement says about the link.
    public struct Sample: Sendable, Equatable {
        /// Sent to acknowledged, for the newest frame the acknowledgement covers.
        public let roundTrip: Double
        /// `roundTrip` less the quickest recent one and the frame's own airtime.
        public let queueDelay: Double
        /// The least `queueDelay` of the last `standingSeconds` — at least the
        /// last `standingSamples` acknowledgements. What the pacer acts on.
        public let standingDelay: Double
        /// Bytes per second acknowledged over the last measuring window, once
        /// one has completed.
        public let deliveryRate: Double?
    }

    private struct Outstanding: Sendable, Equatable {
        let sequence: Int
        let bytes: Int
        let sentAt: UInt64
    }

    private struct Delay: Sendable, Equatable {
        let at: UInt64
        let delay: Double
    }

    /// The round trip assumed before one has been measured. Generous on purpose:
    /// too small and the first second of a relayed mirror is one frame at a time.
    public static let bootstrapRoundTrip = 0.25
    /// Room beyond one base round trip: what keeps the encoder from idling while
    /// the acknowledgement for the last frame is on its way back.
    public static let headroomSeconds = 0.06
    /// The least room there is, so a low bitrate still allows a delta frame
    /// behind the one in flight.
    public static let minimumBudget = 16 * 1024
    /// How long the quickest round trip is believed. A route that has become
    /// slower — a handover, the relay instead of Wi-Fi — must not be judged
    /// forever against the one before it.
    public static let baseLifetimeSeconds = 10.0
    /// An acknowledgement this far behind the base means the oldest frame is
    /// stuck in a queue, whatever the byte count says.
    public static let stuckSeconds = 0.3

    /// How long a queue has to last before it is one.
    ///
    /// A single late acknowledgement is not a queue on a cellular path, it is
    /// the path: measured on 2026-10-05, 5G to this Mac had a 77 ms median
    /// round trip and a 140 ms p95, so one acknowledgement in twenty sat 60 ms
    /// or more above the quickest. Judged one sample at a time, that was a cut
    /// every third of a second and a probe never — and on 2026-10-15 a phone on
    /// the direct path went from 1 Mbps to the 300 kbps floor in three seconds
    /// and stayed there. A queue the sender built is in *every* acknowledgement
    /// until it drains, so the least delay over a short interval separates the
    /// two (CoDel's insight): jitter shows up in some samples, a queue in all.
    public static let standingSeconds = 0.2
    /// And at least this many acknowledgements, so a mirror running at a few
    /// frames a second is not judged on one.
    public static let standingSamples = 3
    /// But nothing older than this: a quiet window's last few samples can be
    /// seconds old, and a queue that has formed since must not hide behind them.
    public static let standingLimitSeconds = 1.0

    private var outstanding: [Outstanding] = []
    public private(set) var unackedBytes = 0
    public var unackedFrames: Int { outstanding.count }

    /// The quickest recent round trip, less airtime: propagation plus the fixed
    /// costs. Nil until the first acknowledgement.
    public private(set) var baseRoundTrip: Double?
    private var baseMeasuredAt: UInt64 = 0
    /// Smoothed raw round trip, for diagnostics.
    public private(set) var smoothedRoundTrip: Double?
    /// The latest queueing-delay sample.
    public private(set) var queueDelay: Double = 0
    /// Recent samples of it, oldest first, for `standingDelay`.
    private var recentDelays: [Delay] = []
    /// How far acknowledgements wander above what is standing: the path's
    /// jitter, smoothed. Room is left for it, or a frame whose acknowledgement
    /// is merely late holds the next one back — measured in simulation, 5G
    /// jitter alone took a mirror with megabits to spare to 24 frames a second.
    public private(set) var jitter: Double = 0
    /// The most room jitter is given, so a path that is mostly spikes cannot
    /// turn the window into a queue.
    public static let jitterAllowanceLimit = 0.1

    private var rateWindowStart: UInt64?
    private var rateWindowBytes = 0
    public private(set) var deliveryRate: Double?
    private static let rateWindowSeconds = 0.25

    public init() {}

    /// A frame of `bytes` went to this viewer as `sequence` at `now`
    /// (`Instrumentation.now()` nanoseconds).
    public mutating func sent(sequence: Int, bytes: Int, at now: UInt64) {
        outstanding.append(Outstanding(sequence: sequence, bytes: bytes, sentAt: now))
        unackedBytes += bytes
    }

    /// The phone has every frame up to and including `sequence`.
    ///
    /// - Parameter bitrate: what the encoder is being asked for, in bits per
    ///   second, for the frame's airtime when nothing has been measured yet.
    @discardableResult
    public mutating func acknowledged(through sequence: Int, at now: UInt64, bitrate: Int) -> Sample? {
        var newest: Outstanding?
        var cleared = 0
        var ackedBytes = 0
        while cleared < outstanding.count, outstanding[cleared].sequence <= sequence {
            newest = outstanding[cleared]
            ackedBytes += outstanding[cleared].bytes
            cleared += 1
        }
        guard let newest, now >= newest.sentAt else { return nil }
        outstanding.removeFirst(cleared)
        unackedBytes = max(0, unackedBytes - ackedBytes)

        noteDelivered(bytes: ackedBytes, at: now)
        let roundTrip = Double(now - newest.sentAt) / 1_000_000_000
        // At the rate it is being sent, not the delivery rate: a still window
        // delivers a few hundred bytes a second, and dividing a frame by that
        // would call a whole round trip "airtime" and hide a real queue.
        let airtime = Double(newest.bytes) * 8 / Double(max(bitrate, 1))
        let base = max(roundTrip - airtime, 0.001)
        // Only a frame that is small next to the round trip says anything about
        // the path itself. A keyframe at a low rate can take longer to cross
        // than the whole round trip — measured on 2026-10-05 through the relay,
        // that set the base to 1 ms, every later frame read as a second of
        // queue, and the stream sat at its floor with one frame in flight.
        let measuresThePath = airtime < roundTrip * 0.5
        let age = Double(now &- baseMeasuredAt) / 1_000_000_000
        if measuresThePath, baseRoundTrip == nil || base < baseRoundTrip! || age > Self.baseLifetimeSeconds {
            baseRoundTrip = base
            baseMeasuredAt = now
        }
        smoothedRoundTrip = smoothedRoundTrip.map { $0 + (roundTrip - $0) * 0.125 } ?? roundTrip
        queueDelay = baseRoundTrip.map { max(0, base - $0) } ?? 0
        let standing = noteStanding(queueDelay, at: now)
        jitter += (queueDelay - standing - jitter) / 16
        return Sample(roundTrip: roundTrip, queueDelay: queueDelay,
                      standingDelay: standing, deliveryRate: deliveryRate)
    }

    private mutating func noteStanding(_ delay: Double, at now: UInt64) -> Double {
        recentDelays.append(Delay(at: now, delay: delay))
        func age(_ at: UInt64) -> Double { Double(now &- at) / 1_000_000_000 }
        while let oldest = recentDelays.first, recentDelays.count > 1,
              age(oldest.at) > Self.standingLimitSeconds
                || (recentDelays.count > Self.standingSamples && age(oldest.at) > Self.standingSeconds) {
            recentDelays.removeFirst()
        }
        return recentDelays.lazy.map(\.delay).min() ?? delay
    }

    /// Whether another frame may be sent to this viewer now.
    ///
    /// An empty window always takes one: a rule that could refuse the only
    /// frame there is would be a mirror that never starts.
    public func hasRoom(bitrate: Int, now: UInt64) -> Bool {
        guard let oldest = outstanding.first else { return true }
        let base = baseRoundTrip ?? Self.bootstrapRoundTrip
        let age = Double(now &- oldest.sentAt) / 1_000_000_000
        let airtime = Double(unackedBytes) * 8 / Double(max(bitrate, 1))
        if age > base + airtime + Self.stuckSeconds { return false }
        return unackedBytes < budget(bitrate: bitrate)
    }

    /// Bytes allowed in flight: a base round trip plus headroom at `bitrate`,
    /// and twice the path's jitter.
    public func budget(bitrate: Int) -> Int {
        let base = baseRoundTrip ?? Self.bootstrapRoundTrip
        let allowance = min(2 * jitter, Self.jitterAllowanceLimit)
        return max(Self.minimumBudget, Int(Double(bitrate) / 8 * (base + Self.headroomSeconds + allowance)))
    }

    /// The link changed under this viewer; what was learned was about another.
    public mutating func reset() {
        self = VideoFlowWindow()
    }

    private mutating func noteDelivered(bytes: Int, at now: UInt64) {
        guard let start = rateWindowStart else {
            rateWindowStart = now
            rateWindowBytes = 0
            return
        }
        rateWindowBytes += bytes
        let elapsed = Double(now &- start) / 1_000_000_000
        guard elapsed >= Self.rateWindowSeconds else { return }
        let sample = Double(rateWindowBytes) / elapsed
        deliveryRate = deliveryRate.map { $0 + (sample - $0) * 0.3 } ?? sample
        rateWindowStart = now
        rateWindowBytes = 0
    }
}
