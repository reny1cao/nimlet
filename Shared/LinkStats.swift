import Foundation

/// What the phone has measured about the link it is on, for the diagnostics
/// report and the one line in Settings that is worth a person's attention.
///
/// Measured numbers only. The control round trip is ping to pong on the control
/// socket; it is *not* the time from a finger moving to the picture changing,
/// which also includes the Mac's capture and encode and this phone's decode, and
/// is reported separately as the mirror's own delay.
public struct LinkStats: Sendable, Equatable {
    /// Control round trips, milliseconds, newest last.
    public private(set) var roundTrips: [Double] = []
    public static let window = 120

    /// How the last session came up, milliseconds from the start of the race.
    public var tlsMillis: Int?
    public var welcomeMillis: Int?
    /// How many routes were raced, and which one answered first.
    public var raced: Int?
    /// The last time the session moved to a better route, in words.
    public var lastMove: String?
    /// Why the session last dropped and redialled, in words, with the route it
    /// was on — the question every "it froze for a few seconds" comes down to.
    public var lastDrop: String?
    /// What the direct-path probe found this session, if it ran.
    public var direct: String?
    /// The relay's UDP tunnel this session, if one was asked for.
    public var relayUDP: String?

    public init() {}

    public mutating func add(roundTripMillis value: Double) {
        roundTrips.append(value)
        if roundTrips.count > Self.window { roundTrips.removeFirst(roundTrips.count - Self.window) }
    }

    public mutating func clearRoundTrips() { roundTrips.removeAll() }

    public func percentile(_ p: Double) -> Double? {
        guard !roundTrips.isEmpty else { return nil }
        let sorted = roundTrips.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p + 0.5))]
    }

    public var median: Double? { percentile(0.5) }
    public var p95: Double? { percentile(0.95) }

    /// "38 ms median · 61 ms p95 (40 pings)", or nil before the first.
    public var roundTripSummary: String? {
        guard let median, let p95 else { return nil }
        return "\(Int(median.rounded())) ms median · \(Int(p95.rounded())) ms p95 (\(roundTrips.count) pings)"
    }
}
