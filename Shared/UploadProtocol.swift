import Foundation

/// The attachment-upload wire format, shared by both apps.
///
/// Like the panel mirror, this rides a connection of its own rather than the
/// control channel, and for the same reason turned around: a 2 MB photo and a
/// stream of pointer deltas cannot share one socket, because TCP delivers in
/// order and every move behind the photo waits for it. The control channel also
/// frames by newline with a 1 MiB ceiling and encodes through one shared
/// `JSONEncoder`, so an image sent that way would have to be base64'd — a third
/// more bytes — inside the lock the 120 Hz pointer path is holding.
///
/// So: the phone opens a socket, says `uploadHello` with a manifest, waits to be
/// told to go ahead, and then writes one length-prefixed binary frame per
/// attachment. The framing is `ViewChannel`'s, the other way round.
///
/// The socket is deliberately short-lived — opened for a batch and closed after
/// the receipt. `HostServer` admits eight connections in total and a phone
/// can already hold three — control, panel and listen — so a permanent fourth
/// would let two phones fill the Mac between them.
public enum UploadChannel {
    /// Per attachment, after the phone has resized it. Far above what the phone
    /// actually sends (a 2576-px JPEG is 1–2 MB): the point of the ceiling is
    /// that a mistake is refused in writing rather than silently truncated,
    /// which is what the control channel's line cap did.
    public static let maxAttachmentBytes = 25 << 20
    /// Per batch. A phone is not the place to assemble a fifty-image prompt, and
    /// every one of them is a file written on somebody's Mac.
    public static let maxAttachments = 8
    /// What any image Claude will look at has to fit inside anyway.
    public static let maxPixelsPerSide = 8000
}

/// What the phone sends first, on its own, before any bytes of any image.
///
/// The caption travels here rather than as a separate `text` message so that the
/// whole thing — "look at this, here it is" — arrives at the target as one
/// delivery with one Return at the end of it, instead of a sentence that runs
/// before the paths it refers to have landed.
public struct AttachmentManifest: Codable, Sendable, Equatable {
    public var protocolVersion: Int
    public var deviceName: String
    /// The same stable id the control connection identifies with. An upload
    /// arrives on a socket that never said `hello`, so without this the Mac
    /// cannot tell which phone is asking — and writing a file to somebody's disk
    /// deserves at least the approval a keystroke needs.
    public var deviceID: String
    /// Every target this batch is for. The bytes are uploaded once and the files
    /// are written once, however many targets they are then delivered to.
    public var targetIDs: [String]
    /// What was typed alongside the images. May be empty.
    public var text: String
    /// Overrides each target's own `submitOnSend`, exactly as a text delivery's
    /// does. Never overrides `allowAutoSubmit`, which is policy.
    public var submit: Bool?
    /// How many frames follow. The host holds the batch until it has them all,
    /// so a connection that dies halfway delivers nothing rather than half a
    /// prompt.
    public var count: Int
    /// A key to press on each target once the batch has been delivered to it —
    /// the "steer it" or "queue it" decision the composer offers.
    ///
    /// It travels with the batch rather than being sent from the phone after
    /// Send is tapped, because at that moment the images have not left: a chord
    /// sent from there would steer a turn that has not been told about them yet.
    public var followChord: KeyChord?

    public init(protocolVersion: Int = NimletProtocol.version,
                deviceName: String,
                deviceID: String,
                targetIDs: [String],
                text: String,
                submit: Bool?,
                count: Int,
                followChord: KeyChord? = nil) {
        self.protocolVersion = protocolVersion
        self.deviceName = deviceName
        self.deviceID = deviceID
        self.targetIDs = targetIDs
        self.text = text
        self.submit = submit
        self.count = count
        self.followChord = followChord
    }

    /// Field by field with defaults, for the same reason `NimletTarget` is: a
    /// manifest that fails to decode is an upload that fails with "unreadable
    /// message" and no clue which field was at fault.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try c.decodeIfPresent(Int.self, forKey: .protocolVersion) ?? NimletProtocol.version
        deviceName = try c.decodeIfPresent(String.self, forKey: .deviceName) ?? "iPhone"
        deviceID = try c.decodeIfPresent(String.self, forKey: .deviceID) ?? ""
        targetIDs = try c.decodeIfPresent([String].self, forKey: .targetIDs) ?? []
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        submit = try c.decodeIfPresent(Bool.self, forKey: .submit)
        count = try c.decodeIfPresent(Int.self, forKey: .count) ?? 0
        followChord = try c.decodeIfPresent(KeyChord.self, forKey: .followChord)
    }
}

/// One attachment's header. The payload that follows it is the image itself.
public struct AttachmentFrame: Codable, Sendable, Equatable {
    /// Only the two lossless-and-lossy pair Claude reads well and the phone can
    /// produce without a detour: a screenshot or an annotation stays PNG so its
    /// text stays crisp, a photograph goes as JPEG.
    public enum Format: String, Codable, Sendable, CaseIterable {
        case png, jpeg

        public var fileExtension: String {
            switch self {
            case .png: return "png"
            case .jpeg: return "jpg"
            }
        }

        /// The uniform type the bytes must actually turn out to be. The header
        /// says what the phone believes it sent; this is what the Mac checks
        /// before it writes a file anybody's agent will open.
        public var uniformTypeIdentifier: String {
            switch self {
            case .png: return "public.png"
            case .jpeg: return "public.jpeg"
            }
        }
    }

    /// 0-based, and its own ordering: the files are named in this order, which
    /// is the order they are referred to in the prompt.
    public var index: Int
    public var format: Format
    /// Cross-checked against the payload the framing actually delivered. A
    /// disagreement means a desynced stream, not a short read.
    public var byteCount: Int
    /// Pixel size as the phone measured it, for the log and the refusal message.
    public var width: Int
    public var height: Int

    public init(index: Int, format: Format, byteCount: Int, width: Int, height: Int) {
        self.index = index
        self.format = format
        self.byteCount = byteCount
        self.width = width
        self.height = height
    }
}

public enum AttachmentFrameWriter {
    public static func encode(_ frame: AttachmentFrame, payload: Data) throws -> Data {
        try LengthPrefixed.encode(frame, payload: payload)
    }
}

/// Accumulates bytes and yields whole attachments.
public struct AttachmentFrameReader {
    private var framer: LengthPrefixedFramer<AttachmentFrame>

    public init(maxFrameBytes: Int = UploadChannel.maxAttachmentBytes) {
        framer = LengthPrefixedFramer(maxFrameBytes: maxFrameBytes)
    }

    public mutating func append(_ data: Data) -> [(frame: AttachmentFrame, payload: Data)] {
        framer.append(data).map { (frame: $0.header, payload: $0.payload) }
    }
}

// MARK: - Stills, for annotating

/// A picture of the Mac's own screen, fetched so it can be drawn on and sent
/// back.
///
/// This is the other half of sending an image: most of what a developer wants to
/// point at is already on the monitor in front of them, and "this button, here"
/// is a circle round it rather than a paragraph describing where it is.
///
/// It comes down on a short-lived connection of its own, framed like an upload
/// and for the same reasons. Deliberately *not* down the panel channel: the
/// panel is a live tile of one target that the user may never have opened, and a
/// still is wanted at full sharpness at a moment that has nothing to do with
/// whether a mirror happens to be running.
///
/// The phone flattens its drawing over the still and sends the result back as an
/// ordinary attachment. Sending the strokes instead and compositing on the Mac
/// would put fewer bytes on the wire, and buy nothing: the still is already
/// capped at the resolution Claude reads, so the Mac would be compositing over
/// the same pixels the phone has, in a second implementation of the same thing.
public enum StillChannel {
    public static let maxStillBytes = 25 << 20
    /// What the phone asks for if it has no opinion. The same ceiling attachments
    /// are resized to, because this becomes one.
    public static let defaultLongEdge = 2576
}

public struct StillRequest: Codable, Sendable, Equatable {
    public var protocolVersion: Int
    public var deviceName: String
    /// The same stable id everything else identifies with; a still of somebody's
    /// screen is not less sensitive than a keystroke on it.
    public var deviceID: String
    /// Whose screen: an app target's window, or the display a pane is on.
    public var targetID: String
    /// The phone's ceiling on the long edge, so the Mac scales once, at capture,
    /// rather than sending a 6K window for the phone to shrink.
    public var maxLongEdge: Int

    public init(protocolVersion: Int = NimletProtocol.version,
                deviceName: String,
                deviceID: String,
                targetID: String,
                maxLongEdge: Int = StillChannel.defaultLongEdge) {
        self.protocolVersion = protocolVersion
        self.deviceName = deviceName
        self.deviceID = deviceID
        self.targetID = targetID
        self.maxLongEdge = maxLongEdge
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try c.decodeIfPresent(Int.self, forKey: .protocolVersion) ?? NimletProtocol.version
        deviceName = try c.decodeIfPresent(String.self, forKey: .deviceName) ?? "iPhone"
        deviceID = try c.decodeIfPresent(String.self, forKey: .deviceID) ?? ""
        targetID = try c.decodeIfPresent(String.self, forKey: .targetID) ?? ""
        maxLongEdge = try c.decodeIfPresent(Int.self, forKey: .maxLongEdge) ?? StillChannel.defaultLongEdge
    }
}

/// The one frame that comes back. PNG, always: this is a screenshot of text and
/// interface, which is what JPEG is worst at.
public struct StillFrame: Codable, Sendable, Equatable {
    /// What was photographed — a window name, or the display. Shown above the
    /// canvas so it is obvious *what* is about to be drawn on.
    public var title: String
    public var width: Int
    public var height: Int
    public var byteCount: Int

    public init(title: String, width: Int, height: Int, byteCount: Int) {
        self.title = title
        self.width = width
        self.height = height
        self.byteCount = byteCount
    }
}

public enum StillFrameWriter {
    public static func encode(_ frame: StillFrame, payload: Data) throws -> Data {
        try LengthPrefixed.encode(frame, payload: payload)
    }
}

public struct StillFrameReader {
    private var framer: LengthPrefixedFramer<StillFrame>

    public init(maxFrameBytes: Int = StillChannel.maxStillBytes) {
        framer = LengthPrefixedFramer(maxFrameBytes: maxFrameBytes)
    }

    public mutating func append(_ data: Data) -> [(frame: StillFrame, payload: Data)] {
        framer.append(data).map { (frame: $0.header, payload: $0.payload) }
    }
}
