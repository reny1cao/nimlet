import Foundation
import CoreGraphics

/// The panel-mirror wire format, shared by both apps.
///
/// This rides a *second* TCP connection rather than the control channel. Pointer
/// deltas and a 60 KB keyframe cannot share one socket: TCP delivers in order, so
/// every move behind a keyframe waits for it. That is precisely the stutter the
/// pointer path was tuned to avoid, and no amount of care on the video side
/// undoes it.
///
/// Framing is binary — `[UInt32 headerLength][header JSON][UInt32 payloadLength][payload]`,
/// both lengths big-endian. JSON for the header keeps it readable and evolvable;
/// the payload stays raw because base64 would add a third to every frame.
/// A viewer announces itself with one newline-JSON `viewHello` line, after which
/// the socket carries nothing but these frames. Anything else on a fresh
/// connection means a control client.
public enum ViewChannel {
    /// Guards against a peer claiming a frame larger than any real one.
    public static let maxFrameBytes = 8 << 20
}

/// A rectangle in fractions of something else — here, the part of a panel a
/// viewer is looking at.
///
/// One type rather than four loose `Double?` on each payload, and one clamp
/// rather than one per payload. The clamps had already drifted to three
/// different minimum sizes, so the deepest zoom the viewer could express was
/// quietly widened tenfold on arrival.
/// A place inside something, as fractions of it, in the same spirit as
/// `UnitRect`: the sender and the receiver disagree about pixels — the encoder,
/// the phone's scale and the size of the panel it draws all rescale on the way —
/// and never about fractions.
public struct UnitSpot: Codable, Sendable, Equatable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    /// Nil for a point that is not inside at all, so "the pointer is somewhere
    /// else" is the absence of a field rather than a value to be interpreted.
    public init?(inside point: CGPoint) {
        guard (0...1).contains(point.x), (0...1).contains(point.y) else { return nil }
        self.init(x: point.x, y: point.y)
    }

    public var point: CGPoint {
        CGPoint(x: min(max(x, 0), 1), y: min(max(y, 0), 1))
    }
}

public struct UnitRect: Codable, Sendable, Equatable {
    /// Smaller than this and the region is a handful of pixels of the source.
    public static let minimumSide = 0.002
    public static let full = UnitRect(x: 0, y: 0, width: 1, height: 1)

    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// Nil for "all of it", so the full rectangle costs nothing on the wire.
    public init?(_ rect: CGRect) {
        guard rect != CGRect(x: 0, y: 0, width: 1, height: 1) else { return nil }
        self.init(x: rect.origin.x, y: rect.origin.y, width: rect.width, height: rect.height)
    }

    /// Always a sane rectangle inside the unit square, whatever arrived.
    public var rect: CGRect {
        guard width > 0, height > 0 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        let w = min(max(width, Self.minimumSide), 1)
        let h = min(max(height, Self.minimumSide), 1)
        return CGRect(x: min(max(x, 0), 1 - w), y: min(max(y, 0), 1 - h), width: w, height: h)
    }

    /// The same clamp, for callers holding a `CGRect` rather than the wire form.
    public static func clamped(_ rect: CGRect) -> CGRect {
        UnitRect(x: rect.origin.x, y: rect.origin.y, width: rect.width, height: rect.height).rect
    }
}

/// What the viewer tells the host when it attaches.
public struct ViewHelloPayload: Codable, Sendable {
    public var protocolVersion: Int
    public var deviceName: String
    /// The same stable id the control connection identifies with.
    ///
    /// A viewer arrives on its own socket and never says `hello`, so without
    /// this the Mac cannot tell which phone is asking — and a live picture of
    /// the screen deserves at least the approval a keystroke needs.
    public var deviceID: String
    /// The viewer's usable pixel box. The host fits the panel inside it rather
    /// than sending a Retina-sized window the phone would only scale down.
    public var maxWidth: Int
    public var maxHeight: Int
    /// The part of the panel the viewer is actually looking at, or nil for all
    /// of it.
    ///
    /// This is what makes zooming worth anything. Magnifying on the phone
    /// enlarges pixels that have already been through the encoder; sending the
    /// crop instead lets the Mac encode that region at the viewer's full size,
    /// so the text gets sharper rather than merely bigger.
    public var crop: UnitRect?
    /// The phone's available mirror area, width over height. Independent of
    /// encode resolution and zoom. Nil preserves the window's existing size.
    public var fitAspect: Double?

    public init(protocolVersion: Int = NimletProtocol.version,
                deviceName: String,
                deviceID: String = "",
                maxWidth: Int,
                maxHeight: Int,
                crop: CGRect? = nil,
                fitAspect: Double? = nil) {
        self.protocolVersion = protocolVersion
        self.deviceName = deviceName
        self.deviceID = deviceID
        self.maxWidth = maxWidth
        self.maxHeight = maxHeight
        self.crop = crop.flatMap(UnitRect.init)
        self.fitAspect = fitAspect
    }

    public var cropRect: CGRect { crop?.rect ?? CGRect(x: 0, y: 0, width: 1, height: 1) }
}

/// One frame's header. Optionals rather than an enum with associated values:
/// a viewer that meets a field it does not know simply ignores it.
public struct ViewFrame: Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// Compressed video of a window.
        case video
        /// A terminal pane, as text. Sharper than any codec and ~100x smaller.
        case text
        /// Nothing to show, and why.
        case state
    }

    public enum Codec: String, Codable, Sendable { case hevc, h264 }

    public var kind: Kind
    /// Shown above the panel: "Claude", "codex:0.1".
    public var title: String
    /// Host `DispatchTime` uptime nanoseconds at capture. With the clock offset
    /// the control channel's ping/pong already measures, this is what makes
    /// glass-to-glass latency a number instead of an impression.
    public var captureTime: UInt64

    // Video
    public var codec: Codec?
    public var isKeyframe: Bool?
    public var width: Int?
    public var height: Int?
    /// VPS/SPS/PPS, repeated on every keyframe so a viewer can join mid-stream.
    public var parameterSets: [Data]?
    /// Counts video frames for the whole stream. The viewer acknowledges the
    /// highest one it has read (`ClientMessage.viewAck`), which is how the Mac
    /// knows what is still on the way — see `VideoFlowWindow`. A viewer may see
    /// gaps: frames it had no room for were never sent to it.
    public var sequence: Int?
    /// How round the window's corners are, as a fraction of its width.
    ///
    /// The picture does not carry them: a window is masked into its rounded
    /// shape when the window server composites it, and what a stream hands over
    /// is the rectangular buffer behind that mask. Without this the phone shows
    /// four corners of the window that nobody at the Mac can see.
    ///
    /// A fraction rather than points, because the encoder, the phone's scale
    /// and the size of the panel it draws all rescale it on the way. Absent
    /// when the Mac could not measure it, which the phone reads as square.
    public var cornerRadius: Double?

    // Text
    public var columns: Int?
    public var rows: Int?

    /// Where the Mac's pointer is inside the window being mirrored, as
    /// fractions of it, or nil when it is somewhere else.
    ///
    /// Sent so that a mirror zoomed in past what it can show at once has
    /// something to follow. There is no gesture spare for panning a tile — the
    /// pad's two fingers are scroll and its one finger is the pointer — so the
    /// view follows the cursor the pad is already driving, which is where the
    /// person is looking anyway.
    ///
    /// Nil is the ordinary case and means "not in this window": the pointer is
    /// over something else, or on another display. The viewer holds its position
    /// rather than jumping somewhere when that happens, because the pointer
    /// leaving is not a statement about what you were reading.
    public var pointer: UnitSpot?

    /// Which window these pixels are of: the Mac bumps it whenever the mirror
    /// changes windows. The phone hands back the one on its glass with every
    /// touch (`pointAtPanel`), which is how a touch on a picture of the last
    /// window is told from one on this one. Optional for the same reason as
    /// `canOpen`: absent from an older Mac.
    public var generation: Int?

    /// The part of the panel this frame actually shows, or nil for all of it.
    ///
    /// The viewer needs this to know when the Mac has caught up with a zoom. Its
    /// own transform exists only to bridge the gap between what it asked to see
    /// and what is arriving; once a frame turns up that already *is* the region
    /// asked for, the transform becomes the identity and the picture simply gets
    /// sharper without moving.
    public var crop: UnitRect?

    // State
    public var reason: String?
    /// Whether this state is one the phone can clear by asking for the window
    /// to be opened — which today means exactly one thing: it is minimised.
    ///
    /// A flag rather than the phone matching on `reason`. The sentence is
    /// written for a person and gets reworded; a screen that offers "Open it"
    /// only when it recognises the wording would lose the button the next time
    /// somebody improved the copy, and lose it silently.
    ///
    /// Optional, and that is load-bearing rather than style. `ViewFrame` has no
    /// hand-written decoder the way `NimletTarget` does, so `Codable` is
    /// synthesised — and a synthesised decoder calls `decode` for a
    /// non-Optional property and throws when the key is missing. A plain
    /// `Bool` here would make every frame from a Mac on an older build
    /// undecodable, which is not a missing button: it is a mirror that never
    /// shows anything. Optional gets `decodeIfPresent`, and absent means no.
    public var canOpen: Bool?

    public init(kind: Kind, title: String, captureTime: UInt64) {
        self.kind = kind
        self.title = title
        self.captureTime = captureTime
    }

    public var cropRect: CGRect { crop?.rect ?? CGRect(x: 0, y: 0, width: 1, height: 1) }

    public mutating func setCrop(_ rect: CGRect) {
        crop = UnitRect(rect)
    }

    public static func state(_ reason: String, title: String = "", canOpen: Bool = false) -> ViewFrame {
        var frame = ViewFrame(kind: .state, title: title, captureTime: Instrumentation.now())
        frame.reason = reason
        frame.canOpen = canOpen ? true : nil
        return frame
    }
}

// MARK: - Framing

/// `[UInt32 headerLength][header JSON][UInt32 payloadLength][payload]`, both
/// lengths big-endian.
///
/// Generic over the header because two channels now frame this way: the panel
/// mirror sends video and text down to the phone, and an attachment upload sends
/// images the other way. Payloads in both cases are raw bytes full of newlines,
/// which is the whole reason neither can use `LineFramer`.
public enum LengthPrefixed {
    public static func encode<Header: Encodable>(_ header: Header, payload: Data) throws -> Data {
        let head = try NimletCoder.encode(header)
        var out = Data(capacity: head.count + payload.count + 8)
        out.append(bigEndian: UInt32(head.count))
        out.append(head)
        out.append(bigEndian: UInt32(payload.count))
        out.append(payload)
        return out
    }
}

/// Accumulates bytes and yields whole frames. Mirrors `LineFramer`, but
/// length-prefixed: a video frame or a PNG contains newlines by definition.
public struct LengthPrefixedFramer<Header: Decodable> {
    private var buffer = Data()
    private let maxFrameBytes: Int

    /// Set when a bogus length forced the buffer to be thrown away, and cleared
    /// by whoever reads it.
    ///
    /// Worth surfacing rather than swallowing, because of what the panel channel
    /// does with it: a desynced reader has dropped part of a video frame, so the
    /// decoder's reference picture is now something the Mac does not think it
    /// sent, and every delta frame after it decodes into nonsense. The only
    /// repair is a keyframe, and the only end that knows to ask for one is this
    /// one. Left silent, the picture stayed broken until the host's own safety
    /// keyframe came round — which is exactly the interval this change lengthens.
    private var desynced = false

    public init(maxFrameBytes: Int) {
        self.maxFrameBytes = maxFrameBytes
    }

    /// Whether the stream desynced since this was last asked. Reading clears it.
    public mutating func takeDesync() -> Bool {
        defer { desynced = false }
        return desynced
    }

    public mutating func append(_ data: Data) -> [(header: Header, payload: Data)] {
        buffer.append(data)
        var frames: [(Header, Data)] = []
        var offset = 0

        while true {
            guard buffer.count - offset >= 4 else { break }
            let headerLength = Int(buffer.readUInt32(at: offset))
            // A bogus length means a desynced stream; there is no recovering a
            // byte offset we have lost, so drop everything rather than emitting
            // garbage. On the panel channel the next keyframe restores the
            // picture; on an upload the batch is refused for being short.
            guard headerLength > 0, headerLength <= maxFrameBytes else {
                buffer.removeAll()
                desynced = true
                return frames
            }
            guard buffer.count - offset >= 8 + headerLength else { break }
            let payloadLength = Int(buffer.readUInt32(at: offset + 4 + headerLength))
            guard payloadLength <= maxFrameBytes else {
                buffer.removeAll()
                desynced = true
                return frames
            }
            let total = 8 + headerLength + payloadLength
            guard buffer.count - offset >= total else { break }

            let headerStart = offset + 4
            let payloadStart = offset + 8 + headerLength
            if let header = try? NimletCoder.decode(
                Header.self,
                from: buffer.subdata(in: headerStart..<(headerStart + headerLength))) {
                frames.append((header, buffer.subdata(in: payloadStart..<(payloadStart + payloadLength))))
            }
            offset += total
        }

        if offset > 0 { buffer.removeSubrange(0..<offset) }
        return frames
    }
}

public enum ViewFrameWriter {
    public static func encode(_ frame: ViewFrame, payload: Data) throws -> Data {
        try LengthPrefixed.encode(frame, payload: payload)
    }
}

/// The panel channel's reader. A named wrapper rather than a bare `typealias`,
/// so the tuple its callers destructure keeps saying `frame` rather than
/// `header`.
public struct ViewFrameReader {
    private var framer: LengthPrefixedFramer<ViewFrame>

    public init(maxFrameBytes: Int = ViewChannel.maxFrameBytes) {
        framer = LengthPrefixedFramer(maxFrameBytes: maxFrameBytes)
    }

    public mutating func append(_ data: Data) -> [(frame: ViewFrame, payload: Data)] {
        framer.append(data).map { (frame: $0.header, payload: $0.payload) }
    }

    /// Whether the stream desynced since this was last asked, which on this
    /// channel means the decoder's reference picture can no longer be trusted.
    public mutating func takeDesync() -> Bool { framer.takeDesync() }
}

private extension Data {
    mutating func append(bigEndian value: UInt32) {
        var be = value.bigEndian
        Swift.withUnsafeBytes(of: &be) { append(contentsOf: $0) }
    }

    /// `self` is always a whole `Data` here, never a slice, so plain Int offsets
    /// are safe — the trap `LineFramer` sidesteps by tracking `startIndex`.
    func readUInt32(at offset: Int) -> UInt32 {
        (UInt32(self[offset]) << 24)
            | (UInt32(self[offset + 1]) << 16)
            | (UInt32(self[offset + 2]) << 8)
            | UInt32(self[offset + 3])
    }
}
