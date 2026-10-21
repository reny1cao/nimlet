import Foundation

/// Which way to a Mac is better, and when it is safe to move a live session to
/// it. Pure, so the rules the phone lives by can be tested without a network.
///
/// The race that opens a session takes whichever route finishes TLS first.
/// That is the right way to *start* — the person is waiting — and the wrong way
/// to *stay*: a phone that connected over the relay on 5G and then walked into
/// the house kept the relay for as long as the cellular socket survived, and a
/// direct address that was slow to answer the first time was never asked again.
/// So after a session is up the phone keeps looking for a better route and moves
/// the session onto it, make-before-break, when doing so cannot reorder input.
public enum RoutePolicy {

    /// How far a route travels, best first. Ordering by class rather than by
    /// raw round trip alone, because a class says something a few pings cannot:
    /// the relay costs somebody bandwidth and crosses an ocean, and the LAN
    /// does not depend on anybody's router.
    public enum RouteClass: Int, Comparable, Sendable, CustomStringConvertible {
        /// This network: Bonjour, a LAN address, AWDL.
        case lan = 0
        /// Not this network, but nobody in the middle: public IPv6, a
        /// forwarded port, a VPN overlay address.
        case direct = 1
        /// The connect relay, over UDP with KCP (`DirectTunnel`): still the
        /// relay's route, but a lost packet costs a resend of that packet, not
        /// a stall of everything behind it.
        case relayDatagram = 2
        /// The connect relay, over TCP.
        case relay = 3

        public static func < (lhs: RouteClass, rhs: RouteClass) -> Bool { lhs.rawValue < rhs.rawValue }

        public var description: String {
            switch self {
            case .lan: return "local network"
            case .direct: return "direct"
            case .relayDatagram: return "relay (UDP)"
            case .relay: return "relay"
            }
        }
    }

    public static func routeClass(reach: NimletCandidate.Reach, isOverlay: Bool) -> RouteClass {
        switch reach {
        case .local: return isOverlay ? .direct : .lan
        case .internet6, .forwarded4: return .direct
        case .relay: return .relay
        }
    }

    /// Whether the route that worked last time may jump the queue.
    ///
    /// Never the relay while the phone is on a network that could have the Mac
    /// on it: the relay takes seconds to splice and the LAN milliseconds, and
    /// letting it start first is how a relay success the evening before became
    /// the route used at the desk the next morning.
    public static func mayPromote(_ proven: RouteClass, offLAN: Bool) -> Bool {
        offLAN || proven != .relay
    }

    /// Whether a session on `current` should move to `candidate`, given the
    /// quickest round trips each has shown (seconds).
    ///
    /// A better class wins unless it is clearly slower — a VPN relaying through
    /// its own servers can be. The same class has to be a lot quicker, so two
    /// routes a few milliseconds apart never trade places back and forth.
    public static func shouldMigrate(from current: RouteClass, roundTrip currentRTT: Double?,
                                     to candidate: RouteClass, roundTrip candidateRTT: Double) -> Bool {
        guard candidate <= current else { return false }
        guard let currentRTT else { return candidate < current }
        if candidate < current { return candidateRTT <= currentRTT * 1.2 + 0.01 }
        return candidateRTT < currentRTT * 0.7 && currentRTT - candidateRTT > 0.03
    }

    /// Whether the session can change sockets now without input arriving out of
    /// order.
    ///
    /// Moves are relative and add up the same in any order, so a finger still
    /// moving does not hold a switch up. What must not straddle two sockets is
    /// anything ordered: a button held down (its release would race its press),
    /// and a click, scroll, key or point sent less than a round trip ago on the
    /// old socket, which the new, quicker one could overtake.
    ///
    /// - Parameters:
    ///   - sinceOrderedInput: seconds since the last input that is not a move.
    ///   - roundTrip: the old route's round trip, seconds.
    public static func isQuietForSwitch(buttonsHeld: Bool, sinceOrderedInput: Double, roundTrip: Double?) -> Bool {
        guard !buttonsHeld else { return false }
        return sinceOrderedInput >= max(0.3, (roundTrip ?? 0.5) * 1.5)
    }

    /// How long an active session waits for a pong before calling its socket
    /// dead, and how long a one-off health check waits.
    ///
    /// On the LAN a round trip is milliseconds, and three seconds of silence
    /// is a dead socket. Through the relay from 5G it is not: measured on
    /// 2026-10-05, base round trips were 230–410 ms and a queue on the shared
    /// downlink stretched single round trips past four seconds. A three-second
    /// limit there tore down a working session, and the redial cost more than
    /// the wait it was avoiding.
    public static func pongTimeout(for routeClass: RouteClass) -> Double {
        routeClass == .lan ? 3 : 8
    }

    public static func healthCheckTimeout(for routeClass: RouteClass) -> Double {
        routeClass == .lan ? 2 : 6
    }

    /// How long to wait before looking again, after `attempt` looks that found
    /// nothing better: soon at first, then rarely. A direct address that does
    /// not answer costs one unanswered SYN per look.
    public static func upgradeDelay(attempt: Int) -> Double {
        min(15 * pow(2, Double(attempt)), 120)
    }
}
