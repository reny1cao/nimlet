import Foundation

/// Reaching the Mac from somewhere that is not its network.
///
/// Only one end has to accept a connection, and it is always the Mac: a phone
/// behind a carrier's NAT can dial out perfectly well, but it cannot be dialled.
/// So there is no hole punching here and no rendezvous. The Mac asks its own
/// router for a way in, finds out what address that way in has, and hands the
/// answer to the phone over the connection they already trust. `RemoteReach` on
/// the host does that part.
///
/// The away listener is a trust listener (`TrustTransport`): it lets in only
/// the keys of phones the user paired, and it never pairs a new one. If the
/// Mac's own internet connection will not accept an inbound connection at all,
/// which is what a carrier-grade NAT gives you, the only way in is the connect
/// relay (`RelayLink`). See SECURITY.md.
public enum RemoteAccess {
    /// The port the away listener binds, and the one it asks the router to
    /// forward to it. Its own port rather than the trust listener's, because
    /// it is the only one ever exposed to the internet, and it never pairs.
    ///
    ///   defaults write com.renyicao.mice.host mice.awayPort -int 61424
    public static let defaultPort: UInt16 = 61423

    /// The length of the key that seals pushes for one phone (`PushEnvelope`).
    public static let keyLength = 32
}

/// One place the Mac believes it can be reached.
///
/// Sent as a list rather than a single address because which one works is not
/// something either end can know in advance — the phone may be on the Mac's own
/// Wi-Fi, on a different network in the same building, or on a carrier that
/// only speaks IPv6 — and trying them is cheaper and more reliable than
/// reasoning about them.
public struct NimletCandidate: Codable, Sendable, Hashable, Identifiable {

    /// How far this address reaches. Ordering is deliberate: the phone tries
    /// them in this order, and `local` first means being at your own desk never
    /// pays for a round trip through the internet.
    public enum Reach: String, Codable, Sendable, CaseIterable, Comparable {
        /// An address on the Mac's own network. The fastest path there is and
        /// worthless from anywhere else.
        case local
        /// A globally routable IPv6 address belonging to the Mac itself. No NAT
        /// in the way, which is why it is tried before the forwarded port —
        /// there is nothing to translate and nothing to keep alive. A home
        /// router that blocks unsolicited inbound IPv6, which most do by
        /// default, simply makes this one fail.
        case internet6
        /// A public IPv4 address and a port the router has agreed to forward to
        /// this Mac.
        case forwarded4
        /// The connect relay (`RelayLink`): the way in when there is no other,
        /// tried last because every byte crosses somebody else's server.
        case relay

        public static func < (lhs: Reach, rhs: Reach) -> Bool {
            let order = Reach.allCases
            return order.firstIndex(of: lhs)! < order.firstIndex(of: rhs)!
        }
    }

    public var host: String
    public var port: UInt16
    public var reach: Reach
    /// What produced this candidate — "PCP", "NAT-PMP", "UPnP", "en0" — for the
    /// menu bar and the log. Never parsed, and never trusted for anything.
    public var via: String

    public var id: String { "\(reach.rawValue)|\(host)|\(port)" }

    /// Whether this address leaves the Mac's own network.
    public var isRemote: Bool { reach != .local }

    public init(host: String, port: UInt16, reach: Reach, via: String) {
        self.host = host
        self.port = port
        self.reach = reach
        self.via = via
    }

    /// `host:port`, with IPv6 in the brackets that make it unambiguous.
    public var display: String {
        host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
    }
}

/// What the Mac tells a phone paired by key about reaching it.
///
/// Pushed rather than asked for, whenever it changes: a home IP address moves
/// when the ISP decides it should, and the moment it does, every phone that is
/// not currently on this network has a stale address and no way to learn the new
/// one. Pushing means any phone that is on the network — which is where phones
/// spend most of their time — is corrected without anybody doing anything.
public struct RemoteAccessPayload: Codable, Sendable, Equatable {
    /// Whether the user has turned away access on at all. Off is the default
    /// and the honest one: this opens a port on the internet.
    public var isEnabled: Bool
    /// The Mac's trust listeners, best first: the local addresses on the trust
    /// port, the internet ones on the away port, and the relay last.
    public var candidates: [NimletCandidate]
    /// Why there is no way in, in words for the user, when there is none.
    ///
    /// The case worth naming is a carrier-grade NAT at the Mac's end, where the
    /// router has no public address to forward and the only remaining answer is
    /// a relay. Silence there would look like a bug for as long as the user
    /// believed it was one.
    public var unavailable: String?
    /// The key this phone opens its pushes with (`PushEnvelope`).
    ///
    /// Sent only over a connection from the Mac's own network. Absent on most
    /// pushes, so a phone keeps the key it has rather than reading the absence
    /// as a withdrawal.
    public var pushKey: Data?

    public init(isEnabled: Bool,
                candidates: [NimletCandidate] = [],
                unavailable: String? = nil,
                pushKey: Data? = nil) {
        self.isEnabled = isEnabled
        self.candidates = candidates
        self.unavailable = unavailable
        self.pushKey = pushKey
    }

    /// The push key, if it is one that could actually be used, so a truncated
    /// or empty one is discarded rather than stored.
    public var issuedPushKey: Data? {
        guard let pushKey, pushKey.count == RemoteAccess.keyLength else { return nil }
        return pushKey
    }
}

/// The order a phone should try what it has been given.
///
/// Its own function, and tested, because "best first" is the whole of what makes
/// switching between Wi-Fi and cellular invisible: at the desk the first
/// candidate answers in a millisecond, and away from it the local ones fail
/// fast — nothing on the LAN answers at an address that is not on this LAN — so
/// the remote one is reached in the time a TCP connection takes to give up on a
/// host that is not there.
public enum CandidateOrder {
    public static func sorted(_ candidates: [NimletCandidate]) -> [NimletCandidate] {
        candidates.sorted { lhs, rhs in
            if lhs.reach != rhs.reach { return lhs.reach < rhs.reach }
            let lhsVPN = OverlayAddress.contains(lhs.host)
            let rhsVPN = OverlayAddress.contains(rhs.host)
            if lhsVPN != rhsVPN { return !lhsVPN }
            return lhs.id < rhs.id
        }
    }
}
