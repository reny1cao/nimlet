import Foundation

/// Sharpening a window that has stopped moving.
///
/// The mirror only encodes a frame when the window changes, which is what keeps
/// a still terminal at zero cost — and also what kept it blurry. Whatever the
/// last frame was given is what stays on the glass: a keyframe sent as a phone
/// attaches is held to half a second of link by the rate limits, and on a still
/// window nothing ever follows it. Measured on 2026-10-15 with the hardware HEVC
/// encoder, a 1768x1104 terminal attached at 2.5 Mbps arrived at 28.7 dB and
/// would have stayed there; even on the LAN at 12 Mbps it was 37 dB.
///
/// So the last picture is encoded again, a few times, a quarter of a second
/// apart. The encoder only spends bits where the picture on the phone still
/// differs from the window, so each pass is a refinement of the last and a
/// window that is already sharp costs a few hundred bytes a pass. Measured the
/// same way: 28.7 dB to 39.7 at 2.5 Mbps, 22.4 to 30.9 at 1 Mbps, and 37 to 49
/// on the LAN, within a second and a half.
///
/// The encoder is told the passes' own frame rate while they run. It turns a
/// bitrate into a per-frame budget by dividing by the frame rate it expects, so
/// told sixty it would give each pass a sixtieth of a second of link and the
/// picture would barely move; told four, a pass may use the quarter-second it
/// actually has, which keeps the average at the rate the link was measured to
/// carry. The first live frame after a refinement puts the real rate back
/// before it is encoded.
public struct StillRefinement: Sendable, Equatable {

    /// How long the window has to be still before the first pass, and the
    /// spacing of the rest.
    public static let interval = 0.25
    /// The frame rate the encoder is told while passes run.
    public static let framesPerSecond = 1 / interval
    /// Passes per still spell. Past this a picture has stopped improving.
    public static let passes = 6
    /// Offers per still spell, including ones the link had no room for, so a
    /// full link cannot keep a refinement alive forever.
    public static let attempts = 12

    public private(set) var passesTaken = 0
    public private(set) var attemptsMade = 0

    public init() {}

    /// The window changed: a fresh picture, and a fresh set of passes for it.
    public mutating func pictureChanged() {
        passesTaken = 0
        attemptsMade = 0
    }

    /// A pass was offered to the encoder. Returns whether another should be.
    public mutating func offered(taken: Bool) -> Bool {
        attemptsMade += 1
        if taken { passesTaken += 1 }
        return wantsAnother
    }

    public var wantsAnother: Bool {
        passesTaken < Self.passes && attemptsMade < Self.attempts
    }
}
