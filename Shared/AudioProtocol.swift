import Foundation

/// The listen channel: the Mac's own output mix, going to the phone.
///
/// A *third* socket, and the reason is the one written at the top of
/// `ViewProtocol`, only more so. TCP delivers in order, so anything queued
/// behind a 60 KB keyframe waits for it — and where a late pointer delta is a
/// stutter you can feel, late audio is a hole you can hear. Audio is the most
/// jitter-sensitive thing this app carries and the cheapest: 12 KB/s against
/// the mirror's 1.5 MB/s. It gets its own socket, with nothing ahead of it.
///
/// Framing is `LengthPrefixed`, the same as the panel channel and an upload —
/// `[UInt32 headerLength][header JSON][UInt32 payloadLength][payload]`, both
/// lengths big-endian. A listener announces itself with one newline-JSON
/// `listenHello` line and the socket carries nothing but these frames
/// afterwards.
public enum AudioChannel {
    /// Two AAC packets of 48 kHz stereo are a few hundred bytes. A frame
    /// claiming more than this is not a frame.
    public static let maxFrameBytes = 1 << 18

    /// 48 kHz, which is what ScreenCaptureKit hands over and what an iPhone's
    /// output runs at. Resampling either end would be work done to sound worse.
    public static let sampleRate = 48_000
    /// Stereo. The Mac is playing music and videos as often as it is playing an
    /// agent's notification chime, and a mono downmix of the first to save
    /// 6 KB/s is a bad trade.
    public static let channels = 2
    /// AAC-LC's block size. Fixed by the codec, and named here because it is
    /// what turns a packet count into a duration at both ends.
    public static let framesPerPacket = 1024

    /// How many packets ride in one frame.
    ///
    /// Each frame costs a ~70-byte JSON header and 8 bytes of length prefix
    /// against a ~250-byte packet, so one packet per frame spends a third of
    /// the bandwidth on headers. Two halves that for 21 ms of added latency,
    /// which is under the ear's threshold for anything that is not a
    /// conversation. Three would save little more and start to be audible when
    /// a frame is lost.
    public static let packetsPerFrame = 2

    /// The wall-clock length of one packet: 21.3 ms.
    public static let packetSeconds = Double(framesPerPacket) / Double(sampleRate)

    /// The largest an AAC packet can be: 768 bytes a channel, which the format
    /// fixes and Apple's own encoder reports as its maximum output packet size.
    ///
    /// Both ends need the same number for different reasons. The Mac's encoder is
    /// asked for it when it allocates. The phone allocates a decode buffer of
    /// this size once and then refuses any packet larger, because a length off
    /// the wire is about to be used as a byte count into that buffer.
    public static let maxPacketBytes = 768 * channels
}

/// What a listener tells the Mac when it attaches.
///
/// Re-sent rather than replaced when something changes, exactly as
/// `viewHello` is: one message describes what the phone wants, and sending it
/// again is how the phone changes its mind without tearing down a socket and
/// the capture behind it.
public struct ListenHelloPayload: Codable, Sendable {
    public var protocolVersion: Int
    public var deviceName: String
    /// The same stable id the control connection identifies with. This socket
    /// never says `hello`, so without it the Mac cannot tell which phone is
    /// asking to hear the room it is sitting in.
    public var deviceID: String
    /// True while the phone wants the stream held: it is dictating, and the
    /// microphone is a foot from the speaker.
    ///
    /// Asked of the Mac rather than handled locally by muting, because the
    /// phone may be on cellular — and paying for audio nobody is allowed to
    /// hear is the kind of waste that is invisible until the bill.
    ///
    /// Optional, and that is load-bearing: a synthesised decoder throws on a
    /// missing key for a non-Optional property, so a plain `Bool` would make
    /// every hello from an older phone undecodable.
    public var paused: Bool?

    public init(protocolVersion: Int = NimletProtocol.version,
                deviceName: String,
                deviceID: String,
                paused: Bool = false) {
        self.protocolVersion = protocolVersion
        self.deviceName = deviceName
        self.deviceID = deviceID
        self.paused = paused ? true : nil
    }

    public var isPaused: Bool { paused ?? false }
}

/// One frame of the listen channel.
///
/// Optionals rather than an enum with associated values, for the same reason
/// `ViewFrame` is shaped this way: a field a peer does not know is a field it
/// ignores, rather than a message it cannot read at all.
public struct AudioFrame: Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// Compressed audio. The payload is `packets` concatenated.
        case audio
        /// Nothing to send, and why. The phone shows it and keeps the socket.
        case state
    }

    /// AAC-LC. Named on the wire so that a phone meeting a codec it does not
    /// know says so, rather than handing the bytes to a decoder built for
    /// something else and playing the result.
    public enum Codec: String, Codable, Sendable { case aac }

    public var kind: Kind
    /// Host `DispatchTime` uptime nanoseconds at capture, the same clock the
    /// panel channel stamps its frames with. With the offset the control
    /// channel's ping/pong measures, this makes the delay a number.
    public var captureTime: UInt64

    // Audio
    public var codec: Codec?
    public var sampleRate: Int?
    public var channels: Int?
    /// Samples per packet — 1024 for AAC-LC. Sent rather than assumed, because
    /// it is what the phone builds its decoder's input format out of.
    public var framesPerPacket: Int?
    /// The byte length of each packet in the payload, in order.
    ///
    /// AAC is variable-rate: a silent passage encodes to a tenth of what a
    /// cymbal does, so the payload cannot be split by arithmetic. Lengths
    /// rather than offsets, because a length that overruns the payload is
    /// caught by one running total on arrival.
    public var packets: [Int]?
    /// Counts frames, so the phone can tell a gap from a pause.
    ///
    /// Not for reordering — TCP has already done that — but for the one thing
    /// order alone cannot say: whether the silence it just played was the Mac
    /// having nothing to send or the link having swallowed something.
    public var sequence: UInt32?

    // State
    public var reason: String?

    public init(kind: Kind, captureTime: UInt64) {
        self.kind = kind
        self.captureTime = captureTime
    }

    public static func state(_ reason: String) -> AudioFrame {
        var frame = AudioFrame(kind: .state, captureTime: Instrumentation.now())
        frame.reason = reason
        return frame
    }

    /// The packet lengths, but only if they describe this payload exactly.
    ///
    /// One check rather than one per call site, and it is the check that
    /// matters: the lengths come off the wire and are used to slice a buffer.
    public func packetRanges(in payload: Data) -> [Range<Int>]? {
        guard let packets, !packets.isEmpty else { return nil }
        var ranges: [Range<Int>] = []
        ranges.reserveCapacity(packets.count)
        var offset = 0
        for length in packets {
            guard length > 0, length <= payload.count - offset else { return nil }
            ranges.append(offset..<(offset + length))
            offset += length
        }
        // A payload with bytes left over is a frame this phone does not
        // understand the shape of, which is not the same as a frame it can use
        // most of.
        guard offset == payload.count else { return nil }
        return ranges
    }
}

// MARK: - Framing

public enum AudioFrameWriter {
    public static func encode(_ frame: AudioFrame, payload: Data) throws -> Data {
        try LengthPrefixed.encode(frame, payload: payload)
    }
}

/// The listen channel's reader. A named wrapper rather than a bare `typealias`
/// so its callers destructure a tuple that says `frame`, matching
/// `ViewFrameReader`.
public struct AudioFrameReader {
    private var framer: LengthPrefixedFramer<AudioFrame>

    public init(maxFrameBytes: Int = AudioChannel.maxFrameBytes) {
        framer = LengthPrefixedFramer(maxFrameBytes: maxFrameBytes)
    }

    public mutating func append(_ data: Data) -> [(frame: AudioFrame, payload: Data)] {
        framer.append(data).map { (frame: $0.header, payload: $0.payload) }
    }
}

// MARK: - The cushion

/// What to do with a jitter buffer, given how much is in it.
public enum AudioDrift: Equatable, Sendable {
    /// Play from the buffer.
    case play
    /// Too far behind to be live. Throw this many seconds away and carry on —
    /// audio that is late is not worth hearing, and playing a backlog is how a
    /// stream ends up minutes behind and never catches up.
    case skip(seconds: Double)
    /// Not enough to play yet. Output silence and let it fill.
    case fill
}

/// How much audio the phone keeps ahead of the speaker, and how it changes its
/// mind about that.
///
/// A live stream over TCP arrives in bursts whenever the link hesitates:
/// nothing for 300 ms, then 300 ms all at once. A fixed cushion is therefore
/// always wrong — small enough to be responsive on good Wi-Fi is small enough
/// to break up on cellular, and large enough for cellular is a fifth of a
/// second of delay nobody on the same desk asked for.
///
/// So it moves. It starts tight, grows every time the buffer runs dry, and
/// creeps back down while nothing goes wrong. Nothing to configure, which on a
/// phone is the only kind of setting that exists: there is no `defaults write`
/// on iOS, and a slider labelled "buffer" is a question no one should be asked.
///
/// The two clocks drift as well — the Mac's capture and the phone's output are
/// unrelated crystals, tens of parts per million apart, which is tens of
/// milliseconds an hour in one direction or the other. `skip` absorbs the
/// direction that fills the buffer and `fill` absorbs the one that empties it,
/// so drift never needs its own mechanism.
public struct JitterWindow: Equatable, Sendable {
    /// Four AAC packets. Below this a single late frame is a hole.
    public static let minimum = 0.09
    /// Past this the delay is worse than the dropout it prevents.
    public static let maximum = 0.45
    /// What one dropout is worth. Two packets: enough that a link which is
    /// genuinely bad reaches a usable cushion in a couple of seconds, small
    /// enough that one hiccup on a good link is not paid for all afternoon.
    public static let growth = 0.043
    /// And what it costs to forget one.
    public static let decay = 0.03
    /// How long everything has to go right before the cushion is trimmed.
    public static let calm: Double = 20

    /// How far ahead of the speaker the buffer is kept.
    public private(set) var target: Double
    /// Seconds of clean playback since the last dropout.
    private var quiet: Double = 0

    public init(target: Double = JitterWindow.minimum) {
        self.target = min(max(target, Self.minimum), Self.maximum)
    }

    /// Above this the buffer is not a cushion, it is a delay. Generous
    /// relative to the target, because a burst that arrives all at once is the
    /// normal shape of a good link on a busy network and not something to
    /// punish: only a buffer that stays full is drift.
    public var ceiling: Double { min(target * 3 + 0.06, Self.maximum * 3) }

    /// The buffer ran dry. Ask for more next time.
    public mutating func noteUnderrun() {
        quiet = 0
        target = min(target + Self.growth, Self.maximum)
    }

    /// Time played without trouble. Trims the cushion once there has been
    /// enough of it, one step at a time rather than all at once — a link that
    /// is quiet for twenty seconds and then bursts should not have just been
    /// returned to the minimum.
    public mutating func noteClean(seconds: Double) {
        guard seconds > 0, target > Self.minimum else { return }
        quiet += seconds
        guard quiet >= Self.calm else { return }
        quiet = 0
        target = max(target - Self.decay, Self.minimum)
    }

    /// What to do, given how many seconds are buffered and whether the stream
    /// is currently playing.
    ///
    /// `isPlaying` is the hysteresis, and without it the buffer chatters: a
    /// stream that starts the moment it has one packet underruns on the next
    /// callback, forever. Starting takes a full cushion; continuing takes a
    /// single sample.
    public func verdict(depth: Double, isPlaying: Bool) -> AudioDrift {
        if depth > ceiling { return .skip(seconds: depth - target) }
        if isPlaying { return depth > 0 ? .play : .fill }
        return depth >= target ? .play : .fill
    }
}
