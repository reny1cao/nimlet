import Foundation

/// The host's rules for when a phone's clicks must not reach the Mac, one per
/// connection.
///
/// Two failures this exists for, and both are about a click landing somewhere
/// the person did not aim it:
///
/// - **A mirror tap during a window switch.** A tap on the mirror is a
///   `pointAtPanel` followed by a click. The host refuses the point while the
///   picture on the phone is still the previous window's — but the click used
///   to go through regardless, so it landed wherever the cursor already was,
///   which is the other window. A refused point now takes the press that
///   follows it down with it. (Its release is dropped by the host, which
///   posts a release only for a button this phone actually holds.)
///
/// - **A phone that vanishes mid-drag.** A held button used to be let go only
///   when its socket closed, and a phone that walks out of Wi-Fi leaves a
///   socket that closes when TCP gives up on it — minutes, not seconds. The
///   host now lets go once the phone has been silent for `silenceLimit`, which
///   is safe because a phone holding a button pings every second.
public struct InputGuard: Sendable {

    /// How long a refused point keeps refusing the presses after it.
    ///
    /// A mirror tap sends its point and its press in the same touch callback,
    /// and a mirror hold presses 0.35 s after the point it started with, so a
    /// second covers both. It has to run out rather than last until the next
    /// move: a trackpad tap is a press with no point before it, and one made a
    /// while after a refused mirror tap is a click where the cursor is, which
    /// is exactly what it means.
    public static let refusedPointWindow: TimeInterval = 1

    /// How long a phone may say nothing while holding a button down.
    ///
    /// A phone holding a button pings every second (`NimletClient.tick`), so four
    /// seconds of silence is three lost pings — a link that is gone, not one
    /// that is slow. Older phones drop to a five-second ping after twenty idle
    /// seconds even mid-hold, and for them a hold that long and that still is
    /// released early; that is the cheaper mistake of the two.
    public static let silenceLimit: TimeInterval = 4

    private var refusedPointAt: Date?
    private var acceptedPoint: CGPoint?
    private var acceptedPointAt: Date?

    public init() {}

    /// The host answered a `pointAtPanel`.
    public mutating func pointed(accepted: Bool, position: CGPoint? = nil, at now: Date = Date()) {
        refusedPointAt = accepted ? nil : now
        acceptedPoint = accepted ? position : nil
        acceptedPointAt = accepted && position != nil ? now : nil
    }

    /// A relative move: the person is steering the cursor themselves, so
    /// wherever it is now is where they mean.
    public mutating func moved() {
        refusedPointAt = nil
        acceptedPoint = nil
        acceptedPointAt = nil
    }

    /// The click belongs to the point that preceded it on this socket. Posting
    /// a mouse move is asynchronous, so reading the system cursor immediately
    /// afterward can still return its previous position.
    public mutating func clickPosition(for phase: ClickPhase, at now: Date = Date()) -> CGPoint? {
        defer {
            if phase != .down { acceptedPoint = nil; acceptedPointAt = nil }
        }
        guard let acceptedPointAt,
              now.timeIntervalSince(acceptedPointAt) < Self.refusedPointWindow else { return nil }
        return acceptedPoint
    }

    /// Whether a click message may be posted.
    ///
    /// Releases always pass: a release is posted only for a button the phone
    /// holds, so the one matching a refused press finds nothing to release —
    /// and one matching an earlier, accepted press must never be eaten.
    public mutating func admits(_ button: MouseButton, _ phase: ClickPhase, at now: Date = Date()) -> Bool {
        guard phase != .up else { return true }
        guard let refused = refusedPointAt,
              now.timeIntervalSince(refused) < Self.refusedPointWindow else {
            refusedPointAt = nil
            return true
        }
        return false
    }

    /// Whether a connection that last said something at `lastHeard` has gone
    /// quiet for long enough that anything it holds should be let go.
    public static func isSilent(since lastHeard: Date, now: Date = Date()) -> Bool {
        now.timeIntervalSince(lastHeard) > silenceLimit
    }
}
