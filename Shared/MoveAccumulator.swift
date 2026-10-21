import Foundation

/// Pointer moves read in one batch, summed into one.
///
/// The phone sends a move per touch frame. When a TCP segment is lost on a
/// long path, every move behind it waits for the retransmission and then they
/// all arrive in one read — a quarter of a second of finger, sixty events. The
/// Mac used to replay each: sixty cursor reads and sixty posted events to land
/// exactly where one would have. Summing them keeps the displacement exact and
/// spends one event on it.
///
/// Only *consecutive* moves are summed. Anything else — a click, a scroll, a
/// key, a point on the mirror — flushes what has been summed first, so the
/// cursor is where it should be when the button goes down and the order of
/// everything that is not a move is the order the phone sent it in.
public struct MoveAccumulator: Sendable, Equatable {
    public private(set) var dx: Double = 0
    public private(set) var dy: Double = 0
    /// How many moves are in the sum.
    public private(set) var count = 0

    public init() {}

    public mutating func add(dx: Double, dy: Double) {
        self.dx += dx
        self.dy += dy
        count += 1
    }

    /// The summed move, if there is one, and an empty accumulator.
    public mutating func take() -> (dx: Double, dy: Double, count: Int)? {
        guard count > 0 else { return nil }
        defer { self = MoveAccumulator() }
        return (dx, dy, count)
    }
}
