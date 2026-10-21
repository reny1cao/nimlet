import Foundation
import Network
import Combine
import UIKit
import OSLog

let remoteLog = Logger(subsystem: "com.renyicao.mice", category: "remote")

/// The framing buffer for exactly one connection.
///
/// It used to be a single buffer reused for the life of the client, reset on the
/// main actor by `dial()` while the previous connection's receive handler could
/// still be running on the network queue. That raced both ways: a dead
/// connection's trailing bytes could be prepended to the new connection's first
/// message, and the reset could equally throw away a partial frame that was
/// still being filled. Tying the buffer to the connection removes the shared
/// state instead of trying to time the reset.
private final class ConnectionFramer: @unchecked Sendable {
    private var framer = LineFramer()
    private let lock = NSLock()

    /// Framing and decoding happen together under the lock, so a burst of
    /// packets cannot be reordered by hopping each one to the main actor
    /// separately.
    func messages(from data: Data) -> [HostMessage] {
        lock.lock()
        defer { lock.unlock() }
        return framer.append(data).compactMap { try? NimletCoder.decode(HostMessage.self, from: $0) }
    }
}

/// Finds the Mac, reaches it by key, holds the connection, and pumps messages.
@MainActor
final class NimletClient: ObservableObject {

    enum State: Equatable {
        case idle
        case browsing
        case connecting(String)
        case connected(String)
        case failed(String)

        var isConnected: Bool { if case .connected = self { return true }; return false }
    }

    /// What went wrong, in the terms the recovery screens are written in.
    struct Failure: Equatable {
        enum Kind: Equatable {
            case revoked
            /// The two ends do not speak the same protocol version.
            case versionMismatch
            /// The Mac refused this phone's key, or answered with a key that
            /// is not the one this phone pinned. Pairing again is the way out.
            case notPaired
            /// Never got that far.
            case unreachable
        }
        var kind: Kind
        var message: String
        var hostName: String
    }

    struct DiscoveredHost: Identifiable, Hashable {
        let id: String
        let name: String
        /// How to reach this Mac again once it is no longer in the browse results.
        let remembered: RememberedHost
        /// Read from the Bonjour TXT record, so a version mismatch can be named
        /// *before* the handshake turns it into a refused key.
        let version: Int?
    }

    /// A Mac this phone has paired with. Kept so returning from the
    /// background, a network change or a relaunch can redial without the
    /// picker. Its key is in `PhoneTrust`, under `id`.
    struct RememberedHost: Codable, Hashable, Identifiable {
        enum Locator: Codable, Hashable {
            case bonjour(service: String, domain: String)
        }

        var name: String
        var locator: Locator

        var id: String {
            switch locator {
            case .bonjour(let service, let domain): return "bonjour:\(service).\(domain)"
            }
        }

        /// The Mac's trust listener, by Bonjour. Resolved again on use, which
        /// is what makes it survive a change of address.
        var trustEndpoint: NWEndpoint {
            switch locator {
            case .bonjour(let service, let domain):
                return .service(name: service, type: NimletProtocol.trustBonjourType, domain: domain, interface: nil)
            }
        }
    }

    /// The Mac being reached, and the key it has to prove it holds.
    private struct Target {
        let host: RememberedHost
        let pin: TrustFingerprint
        /// The QR code being redeemed. Cleared once the Mac has said yes, so a
        /// reconnect never tries to pair again.
        var invitation: PairingInvitation?
    }

    /// One address of a Mac's trust listener.
    private struct Route {
        let endpoint: NWEndpoint
        let reach: NimletCandidate.Reach
        /// For a tunnel's loopback address, the class of the path underneath,
        /// which its address cannot say.
        var tunnelClass: RoutePolicy.RouteClass? = nil
    }

    /// The link a session is on. What the panel, listen, upload and
    /// screenshot sockets dial, and the key they pin: a second socket that
    /// disagreed with the first would fail its handshake.
    struct Session: Equatable {
        let endpoint: NWEndpoint
        let pin: TrustFingerprint
        let reach: NimletCandidate.Reach

        /// Nil only if the Keychain would not hold this phone's key.
        @MainActor var parameters: NWParameters? { NimletClient.trustParameters(pin: pin, reach: reach) }
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var hosts: [DiscoveredHost] = []
    @Published private(set) var rememberedHosts: [RememberedHost] = []
    @Published private(set) var targets: [NimletTarget] = []
    @Published private var dockArrangements: [String: PhoneDockArrangement] = NimletClient.loadDockArrangements()
    @Published private(set) var status: HostStatus?
    @Published private(set) var toast: String?
    /// Last reported state per target, shown with its age. Kept across
    /// reconnections: an event from four minutes ago is still true.
    @Published private(set) var agentEvents: [String: AgentEvent] = [:]
    @Published private(set) var lastReceipt: DeliveryReceipt?
    /// Agents blocked on a decision, soonest deadline first.
    ///
    /// Cleared on every teardown on purpose: a card you can tap but whose
    /// answer has nowhere to go is worse than no card, and an approval that
    /// cannot be delivered has already denied itself on the Mac.
    @Published private(set) var approvals: [ApprovalRequest] = []
    /// The live tmux panes, in answer to `requestPanes`. Only ever fetched on
    /// demand: a list of every shell you have open goes stale in seconds and is
    /// wanted for about ten of them, while a target is being pointed at one.
    @Published private(set) var panes: [TmuxPane] = []
    @Published private(set) var isFetchingPanes = false
    /// Uploads in flight, keyed by their own id. See `upload(_:caption:to:submit:)`.
    private var uploads: [UUID: AttachmentUploader] = [:]
    /// And screenshot requests, for the same reason: the sheet that asked for one
    /// must not be what keeps it alive.
    private var stills: [UUID: StillFetcher] = [:]
    private var panesFetchedAt = Date.distantPast
    /// Why the last attempt failed, in the one distinction that changes what
    /// the user should do: a Mac that answered and refused this phone's key is
    /// not a network problem, and telling someone to check their Wi-Fi then
    /// wastes the next ten minutes.
    @Published private(set) var failure: Failure?
    /// When the link was last up, and when it started trying to come back.
    /// Both are shown rather than described: "reconnecting" with no numbers on
    /// it is indistinguishable from hung.
    @Published private(set) var lastConnectedAt: Date?
    @Published private(set) var retryingSince: Date?
    /// The link is down, but it is the *same session* coming back: the same Mac,
    /// dialled again, with everything the phone knows about it still on screen.
    ///
    /// The screen reads this rather than `isConnected` alone. Leaving an app and
    /// coming back to it used to take the whole operating surface away and put
    /// the "choose your Mac" screen in its place for as long as the redial took,
    /// which is how a two-second glance at a message read as the app having
    /// started from nothing. Held rather than computed from a timestamp, because
    /// what ends it is the reconnect ladder running out of patience — a number of
    /// attempts — and not a clock the screen would have to poll.
    @Published private(set) var isResuming = false
    /// Set once the surface has gone untouched long enough that the phone
    /// should stop behaving as though it is being driven.
    @Published private(set) var isIdle = false
    /// What the Mac calls this phone in the approval list and in the README's
    /// "approve it by name" instruction. Editable here because iOS will not
    /// tell us the name the user gave the device — see `defaultDeviceName`.
    @Published var deviceName: String {
        didSet {
            let trimmed = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                // Mid-edit, the field is briefly empty. Forgetting the override
                // rather than storing "" means the default comes back instead of
                // a nameless device reaching the Mac.
                UserDefaults.standard.removeObject(forKey: Self.deviceNameKey)
            } else {
                UserDefaults.standard.set(trimmed, forKey: Self.deviceNameKey)
            }
        }
    }
    /// Surfaced in the UI: link latency is the thing most likely to make the
    /// pointer feel bad, and it is invisible unless measured.
    @Published private(set) var roundTripMillis: Double?
    /// The host's monotonic clock minus this phone's, in nanoseconds. Two
    /// machines' uptimes are unrelated numbers; this is what makes a frame's
    /// capture stamp comparable to `now` here.
    @Published private(set) var hostClockOffset: Int64?
    /// The link the session is on, so the second sockets dial the same Mac
    /// the same way. Set when the Mac says `welcome`, cleared on teardown.
    @Published private(set) var session: Session?
    /// Stable across reconnects, cleared on explicit disconnect or refusal.
    @Published private(set) var listeningHostID: String?
    /// A scanned pairing link waiting for the person to say yes.
    ///
    /// Never redeemed on its own: a `nimlet://pair` link can come from
    /// anywhere — a web page, a message — and one that named a Mac the
    /// attacker holds the key to would otherwise pair this phone with it
    /// without a word, and could take the place of a Mac it already knows.
    struct PendingPairing: Equatable {
        let invitation: PairingInvitation
        /// The Mac this phone already pinned under that name, if it is a
        /// different key — said out loud, because confirming replaces it.
        let replacesPin: Bool
    }
    @Published private(set) var pendingPairing: PendingPairing?
    /// Whether the race was won: a link that got through TLS and then closed
    /// before `welcome` is a Mac refusing this phone's key — TLS 1.3 lets the
    /// client finish before the server has judged its certificate — and is not
    /// worth redialling.
    private var winner: Route?
    /// Only routes that completed welcome may jump ahead on the next attempt.
    private var lastSuccessfulRoutes: [String: Route] = [:]

    var connectionRouteDescription: String {
        guard state.isConnected else { return "Not connected" }
        let route: String
        if let directRoute, session?.endpoint == directRoute.endpoint {
            return "Direct IPv6"
        } else if let relayDatagramRoute, session?.endpoint == relayDatagramRoute.endpoint {
            return "Relay (UDP)"
        } else if case .hostPort(let host, _) = session?.endpoint,
           OverlayAddress.contains(String(describing: host)) {
            route = "VPN"
        } else {
            switch session?.reach ?? .local {
            case .local: route = "Local network"
            case .relay: route = "Relay"
            case .internet6, .forwarded4: route = "Direct internet"
            }
        }
        // The link underneath, when it says something the route does not:
        // "Local network" over AWDL is not the same thing as over Wi-Fi.
        guard let link = connectedLink, link != "?", link != route else { return route }
        return "\(route) · \(link)"
    }

    /// Whether the Mac can be reached away from its network, and why not.
    ///
    /// Read from what the Mac last said, which is kept, so that "not heard
    /// from it yet", "switched off" and "on, but blocked" are three different
    /// sentences. All three used to be "Off on your Mac" until the phone next
    /// reached it, which is exactly when the sentence is not needed.
    var cellularReadiness: String {
        guard hasProAccess else { return "Remote access requires Nimlet Pro. Local-network controls stay free." }
        guard LaunchNetworkPolicy.allowsAwayAccess else { return "This build supports local networks only." }
        guard let host = target?.host ?? rememberedHosts.first else {
            return "Pair with your Mac first."
        }
        guard let enabled = PhoneTrust.awayEnabled(forHost: host.id) else {
            return "Not known yet. This phone learns it the next time it reaches \(host.name)."
        }
        let candidates = PhoneTrust.candidates(forHost: host.id)
        // The relay does not care about the Mac's router, so a reason that is
        // about the router is not the answer while there is a relay.
        if enabled, candidates.contains(where: { $0.reach == .relay }) {
            return "On. Away from your Mac's network this phone goes through the relay."
        }
        // The Mac's own words beat this phone's guess: it knows whether it is
        // switched off, behind carrier-grade NAT, or only reachable by VPN.
        if let reason = PhoneTrust.unavailable(forHost: host.id) { return reason }
        guard enabled else {
            return "Off on your Mac. Enable Reachable on cellular in the Nimlet menu while this phone is connected locally."
        }
        guard candidates.contains(where: \.isRemote) else {
            return "Your Mac has no remote address yet. Check cellular access in its Nimlet menu."
        }
        return "On. Reaching it depends on your Mac's network allowing incoming connections."
    }

    /// The one way this phone dials a Mac — the control socket and every
    /// second socket alike, because a second socket that disagreed with the
    /// first would fail its handshake and leave the mirror black.
    fileprivate static func trustParameters(pin: TrustFingerprint, reach: NimletCandidate.Reach) -> NWParameters? {
        guard let identity = PhoneTrust.identity else { return nil }
        return try? TrustTransport.parameters(identity: identity,
                                              accepts: { $0 == pin },
                                              peerToPeer: reach == .local,
                                              applicationProtocol: reach == .relay ? RelayRoute.applicationProtocol(for: pin) : nil)
    }

    /// Whether this phone can dial `host` at all without asking for anything.
    func hasCredential(for host: RememberedHost) -> Bool {
        PhoneTrust.pin(forHost: host.id) != nil
    }

    /// The dock as the Mac last described it, so the app has something to draw
    /// the instant it opens. See `adopt(_:)`.
    private static let cachedTargetsKey = "mice.targets.cached.v1"
    private static let deviceIDKey = "mice.deviceID"
    private static let deviceNameKey = "mice.deviceName"
    private static let rememberedKey = "mice.rememberedHosts"
    private static let rememberedLimit = 6

    /// Backoff for silent drops. Fast enough that a Wi-Fi hiccup is invisible,
    /// slow enough that a sleeping Mac is not dialled all night.
    private static let reconnectBaseDelay: TimeInterval = 0.4
    private static let maxReconnectDelay: TimeInterval = 15
    private static let activePingInterval: TimeInterval = 1
    private static let idlePingInterval: TimeInterval = 5
    /// Must outlast the idle ping interval, or an untouched phone would declare
    /// its own connection dead.
    private static let pongTimeout: TimeInterval = 12
    // While active, and for one-off health checks, the limit depends on the
    // route: `RoutePolicy.pongTimeout` / `healthCheckTimeout`.
    private static let idleAfter: TimeInterval = 20
    /// How long the session is held open after the app leaves the screen.
    ///
    /// iOS suspends the process, and with it the socket, the moment nothing is
    /// keeping it awake — so the app asks for a task assertion and spends it on
    /// keeping the connection rather than on any work. About 30 seconds is what
    /// the system grants; this stays under it, and the assertion's own expiry
    /// handler is what closes the session cleanly if the estimate is ever wrong.
    ///
    /// This is the whole fix for "it starts from fresh every time I switch
    /// apps": checking a message, copying a token out of 1Password and coming
    /// back now costs nothing at all, because there was never a moment when the
    /// phone was not connected.
    private static let backgroundGrace: TimeInterval = 25
    /// How long the screen you left stays up while the link comes back.
    ///
    /// Past it the link is a problem rather than a pause, and the recovery
    /// screen — which names what went wrong and has a way out of it — is more
    /// use than a dimmed trackpad. It has to be bounded by something: a dial
    /// that nothing answers takes ten seconds to be declared failed, and a Mac
    /// that has gone to sleep is never declared anything at all.
    private static let surfaceHold: TimeInterval = 6
    /// How long a target's dictation vocabulary stays good for. A repository's
    /// identifiers move — a branch switch, an afternoon's work — and the host
    /// has no way to push a refresh, so the cache has to go stale by itself or
    /// a phone left open all day keeps biasing dictation toward yesterday's
    /// symbols.
    private static let vocabularyLifetime: TimeInterval = 10 * 60

    private var browser: NWBrowser?
    private var connection: NWConnection?
    private let pathMonitor = NWPathMonitor()
    private var networkPathSignature: String?
    private var cellularOnlyPath: Bool?
    private let queue = DispatchQueue(label: "com.renyicao.mice.remote.net")
    private var toastTask: Task<Void, Never>?
    /// The addresses of the Mac being dialled, raced.
    ///
    /// Staggered rather than all at once: the best address starts first and
    /// usually answers before the next is due, so at the desk only one socket
    /// is ever opened. One that is slow — a firewall swallowing the SYN, a
    /// cellular round trip — no longer holds up the rest, and the first
    /// handshake to finish wins; the others are cancelled.
    private var racers: [(route: Route, connection: NWConnection)] = []
    /// Addresses not started yet, best first.
    private var unstarted: [Route] = []
    /// Which kinds of route the current attempt tried, so a failure can say
    /// which ways in did not work rather than always blaming the network.
    private var triedReaches: Set<NimletCandidate.Reach> = []
    /// Starts the next address if the ones running have not answered.
    private var staggerTask: Task<Void, Never>?
    /// Set when an address refused this phone's key, or answered with the
    /// wrong one. Only a verdict once every address has had its say: a stale
    /// address may belong to another Mac now.
    private var refusedByKey = false
    /// How long an address gets before the next one starts alongside it.
    private static let stagger: TimeInterval = 0.3
    /// Ends a race, or a won link, that is neither succeeding nor failing.
    private var attemptDeadline: Task<Void, Never>?
    private var pingTimer: Timer?
    private var pendingPings: [UInt64: UInt64] = [:]
    private var pingNonce: UInt64 = 0
    private var lastPongAt: Date?
    private var resumeProbeNonce: UInt64?
    private var resumeProbeTask: Task<Void, Never>?
    private var lastActivityAt = Date()

    /// Readable so the panel's own socket can identify itself as the same
    /// phone; the Mac approves devices, not connections.
    let deviceID: String
    /// The Mac this phone is on, or is trying to be on.
    private var target: Target?
    /// Bumped whenever a connection is abandoned, so callbacks still in flight
    /// on the old one cannot write over the new one's state.
    private var dialGeneration = 0
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempt = 0
    private var isSuspended = false
    /// Non-nil while the app is off screen and the session is being held open.
    private var suspendTask: Task<Void, Never>?
    private var backgroundAssertion: UIBackgroundTaskIdentifier = .invalid
    /// Ends the held surface if the link does not come back. See `holdSurface`.
    private var surfaceHoldTask: Task<Void, Never>?
    /// Set when the Mac refused this phone. Without it, every Bonjour update
    /// would redial into the same refusal for as long as the app is open.
    private var handshakeRejected = false
    /// Set when the user disconnects on purpose, so nothing drags them back.
    private var autoConnectSuppressed = false

    private var vocabularies: [String: [String]] = [:]
    private var vocabularyFetchedAt: [String: Date] = [:]
    private var vocabularyChunks: [String: [String]] = [:]
    /// Targets whose vocabulary has been asked for on *this* connection and not
    /// yet fully arrived. Cleared once the final chunk lands, so the expiry
    /// below is what decides when to ask again.
    private var requestedVocabulary: Set<String> = []

    /// What each app's own menu bar says its keys are, keyed by lowercased
    /// bundle id, and whatever the Mac said when it could not read one.
    ///
    /// Published because a row of buttons changes the moment one arrives: a
    /// target focused before the answer came back is showing the curated set
    /// and should stop.
    @Published private(set) var menuProfiles: [String: ShortcutProfile] = [:]
    @Published private(set) var menuNotes: [String: MenuProfilePayload] = [:]
    /// Bundle ids asked about on *this* connection. A menu walk costs the Mac
    /// real time, so focusing the same target ten times asks once.
    private var requestedMenus: Set<String> = []

    /// The Mac's applications, ranked, in answer to `requestApps`. Held only
    /// while the picker is open: it is a photograph of a disk, and the phone
    /// has no business keeping one.
    @Published private(set) var appSuggestions: [MacApp] = []
    @Published private(set) var isFetchingApps = false
    /// Every app icon this phone has ever been sent, by lowercased bundle id.
    ///
    /// Published rather than read through the store so a dock tile redraws the
    /// moment its app's picture arrives. See `AppIconStore` for why they are
    /// kept across launches.
    @Published private(set) var appIcons: [String: UIImage] = [:]
    private let iconStore = AppIconStore()
    /// Chunks of a suggestion set, held aside until the final one lands: a
    /// picker that fills in three bursts is a picker whose tiles move under
    /// the finger.
    private var appChunks: [MacApp] = []
    /// Icons asked for on *this* connection, so a burst of `targets` messages
    /// asks the Mac to render the same pictures once.
    private var requestedIcons: Set<String> = []

    /// One app's open windows, by target id, as the Mac last described them.
    ///
    /// A photograph of something that changes while you look at it — windows
    /// open, close and get minimised — so it is asked for when the shelf opens
    /// and never treated as still true later. What *is* durable is the pin, and
    /// that lives on the target, on the Mac.
    struct WindowRoster: Equatable {
        var windows: [MacWindow] = []
        var note: String?
        var appIdentity: AppInstanceIdentity?
        var fetchedAt = Date()
    }
    @Published private(set) var windowRosters: [String: WindowRoster] = [:]
    /// Decoded previews, by window id. Never written to disk: a picture of
    /// somebody's screen is not something to leave lying around, and it is
    /// stale within seconds anyway.
    @Published private(set) var windowPreviews: [UInt32: UIImage] = [:]
    @Published private(set) var fetchingWindowsFor: String?
    /// A target whose shelf should be opened without being asked for.
    ///
    /// Set when the Mac sends a window list nobody requested, which it does
    /// when a tap lands on a target whose window has closed. The alternative
    /// was a toast saying the window is gone and a tile that keeps not working
    /// — "show a clear state and let the user choose another" has to include
    /// the choosing.
    @Published var shelfRequestID: String?
    /// Set when a notification was tapped and the answer to it is a card on
    /// the approvals sheet. Cleared by whoever presents the sheet, the same
    /// way `shelfRequestID` is — a request to show something, not a piece of
    /// state about what is shown.
    @Published var approvalRequestID: String?
    /// And the bare form of it: open the sheet, no particular card.
    @Published var wantsApprovals = false
    private var windowChunks: [String: [MacWindow]] = [:]

    /// Pointer deltas are sent straight from touch delivery.
    ///
    /// They used to be accumulated and flushed by a 120 Hz Timer. UIKit already
    /// delivers touches once per display frame, so that timer was a second,
    /// independent 120 Hz clock beating against the first: some ticks flushed
    /// nothing and the next flushed a double-sized delta. Average throughput
    /// looked right while the per-packet deltas alternated — which is what the
    /// eye reads as stutter. It also cost up to a frame of latency.
    private var lastSendAt: UInt64 = 0

    /// Whether `hello` has gone out on this connection. A socket is non-nil
    /// from the moment it is dialled, but hello waits for `.ready`, and
    /// Network.framework queues anything sent before then — so a focus or a
    /// key sent while connecting reached the Mac ahead of hello, and the Mac
    /// answered "Send hello first" and closed the connection it was on.
    private var helloSent = false
    /// What this phone has told the Mac to hold down. While anything is held
    /// the phone keeps its one-second ping, because the Mac lets go of a held
    /// button after a few seconds of silence (`InputGuard.silenceLimit`) and a
    /// long, still drag is not an idle phone.
    private var pressedButtons: Set<MouseButton> = []
    /// When the current run of dials started, for logging how long a
    /// connection took to come up.
    private var raceStartedAt: Date?
    /// The link the session is on — "Wi-Fi", "AWDL", "cellular", "VPN" — for
    /// the route line in Settings and for diagnostics.
    @Published private(set) var connectedLink: String?
    /// Round trips and connection timings, measured. See `LinkStats`.
    @Published private(set) var linkStats = LinkStats()
    /// When the won route finished TLS, for the timings above.
    private var tlsReadyAt: Date?

    // MARK: Moving to a better route

    /// A better way to the Mac being tried while the session carries on over
    /// the one it has. See `RoutePolicy` for why there is one at all.
    private final class Probe {
        let route: Route
        let connection: NWConnection
        var welcomed = false
        var pings: [UInt64: UInt64] = [:]
        /// Round trips on this socket, seconds.
        var samples: [Double] = []
        /// The newest of what the Mac broadcast on this socket while it was
        /// being measured, applied if it becomes the session: anything sent
        /// in the moment before the switch may reach the old, slower socket
        /// only after the switch, where it is not read.
        var status: HostStatus?
        var targets: [NimletTarget]?
        init(route: Route, connection: NWConnection) {
            self.route = route
            self.connection = connection
        }
    }
    private var probes: [Probe] = []
    private var upgradeTask: Task<Void, Never>?
    private var upgradeDeadline: Task<Void, Never>?
    private var switchTask: Task<Void, Never>?
    /// Looks that found nothing better since the session came up, for the
    /// backoff between them.
    private var upgradeAttempt = 0
    /// Sockets a session has just left, kept open long enough for anything
    /// still on its way back on them — the answer to a request sent before
    /// the switch — to arrive.
    private var retiring: [NWConnection] = []
    /// When anything other than a pointer move or a ping was last sent: the
    /// input whose order a switch must not disturb.
    private var lastOrderedInputAt = Date.distantPast
    /// Round trips on the session's socket, seconds, newest last.
    private var recentRoundTrips: [Double] = []
    private static let probeDeadline: TimeInterval = 6
    /// Phase 0 of a direct path (`DirectProbe`): punched once per session away
    /// from the LAN, measured, and reported. Nothing depends on it yet.
    private var directProbe: DirectProbe?
    /// The punched path, carrying connections over KCP (`DirectTunnel`), and
    /// the loopback address it listens on — a route like any other, offered to
    /// `lookForBetterRoute` and moved to when it is quicker.
    private var directTunnel: DirectTunnel?
    private var directRoute: Route?
    /// The same, through the relay's UDP (`RelayDatagramGrant`): for when no
    /// direct path can be punched, so the relay's lossy leg costs a resend
    /// instead of a stall.
    private var relayTunnel: DirectTunnel?
    private var relayDatagramRoute: Route?
    private var relayTunnelPort: UInt16?
    private var relayTunnelHeard = false
    private static let switchPatience: TimeInterval = 15

    private let proAccessProvider: (() -> Bool)?
    private var proObservation: AnyCancellable?
    var hasProAccess: Bool { proAccessProvider?() ?? ProStore.shared.hasPro }

    init(proAccess: (() -> Bool)? = nil) {
        self.proAccessProvider = proAccess
        // A phone restored from another one's backup. Its id goes too: the
        // default name is made from it, and the Mac would otherwise list the
        // new phone under the old one's name, beside the old one.
        if PhoneTrust.dropPinsMadeByAnotherKey() {
            UserDefaults.standard.removeObject(forKey: Self.deviceIDKey)
        }
        let deviceID = Self.loadDeviceID()
        self.deviceID = deviceID
        deviceName = Self.loadDeviceName(deviceID: deviceID)
        rememberedHosts = Self.loadRememberedHosts()
        // From disk, before anything is connected: the dock draws itself the
        // moment the app opens, and it should draw apps rather than glyphs.
        appIcons = iconStore.images
        targets = Self.loadCachedTargets()
        // iOS terminates a backgrounded app whenever it wants the memory, and
        // what the user sees after that is a launch. Launching straight into the
        // picker while the app silently redialled a Mac it has known for weeks is
        // what "it starts from fresh" describes, so a launch that has a Mac to go
        // back to and a dock to draw holds that dock up and fills it in.
        holdSurface(!targets.isEmpty && rememberedHosts.first.map(hasCredential) == true)

        pathMonitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            // The phone's own view of its network, including why it has none:
            // `cellularDenied` is this app being refused cellular data, which
            // looks from inside exactly like a Mac that will not answer.
            let links = [NWInterface.InterfaceType.wifi, .cellular, .wiredEthernet, .other]
                .filter { path.usesInterfaceType($0) }.map { "\($0)" }.joined(separator: "+")
            let signature = "\(path.status)|\(links)|\(path.availableInterfaces.map(\.name).sorted().joined(separator: ","))"
            remoteLog.info("path: \(String(describing: path.status), privacy: .public) via \(links, privacy: .public), reason \(String(describing: path.unsatisfiedReason), privacy: .public)")
            let cellularOnly = satisfied && path.usesInterfaceType(.cellular)
                && !path.usesInterfaceType(.wifi) && !path.usesInterfaceType(.wiredEthernet)
            Task { @MainActor in
                self?.networkPathChanged(satisfied: satisfied, signature: signature, cellularOnly: cellularOnly)
            }
        }
        pathMonitor.start(queue: queue)
        if proAccess == nil {
            proObservation = Publishers.CombineLatest3(ProStore.shared.$hasLifetime,
                                                       ProStore.shared.$hasSubscription,
                                                       ProStore.shared.$isPublicBeta)
                .map { $0 || $1 || $2 }.removeDuplicates()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] hasPro in self?.proAccessChanged(hasPro) }
        }
    }

    private func proAccessChanged(_ hasPro: Bool) {
        objectWillChange.send()
        guard !hasPro else {
            if !isLinkBusy, let host = target?.host { reconnect(to: host) }
            return
        }
        // Cancel a pending remote race as well as a live remote session.
        let isRemote = winner.map { Self.routeClass($0) != .lan } == true
            || racers.contains { Self.routeClass($0.route) != .lan }
            || probes.contains { Self.routeClass($0.route) != .lan }
        if isRemote, let current = target {
            teardown(keepingSurface: true)
            showToast("Remote access needs Nimlet Pro. Local controls remain free.")
            race(current, routes(for: current.host))
        }
    }

    var activeTargetID: String? { status?.activeTargetID }

    // MARK: - Discovery

    /// Whether discovery may start on its own. Off during the welcome screen,
    /// because starting a Bonjour browse is what makes iOS ask for the local
    /// network, and that screen exists to say so first.
    var browsingAllowed = true

    /// iOS refused Nimlet the local network. There is no API that says so;
    /// what there is, is the browser parking itself in `.waiting` with a policy
    /// error, which is this. Cleared the moment a result arrives.
    @Published private(set) var localNetworkDenied = false

    func startBrowsing() {
        browsingAllowed = true
        guard browser == nil else { return }
        if !state.isConnected { state = .browsing }
        let params = NWParameters()
        params.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: NimletProtocol.trustBonjourType, domain: nil), using: params)

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                guard let self else { return }
                // Bonjour reports the same service once per interface (en0,
                // awdl0, utun...). Without collapsing them the list shows
                // duplicates and we may dial a dead interface.
                var seen = Set<String>()
                self.hosts = results.compactMap { result -> DiscoveredHost? in
                    guard case let .service(name, _, domain, _) = result.endpoint else { return nil }
                    guard seen.insert("\(name)|\(domain)").inserted else { return nil }
                    var version: Int?
                    if case let .bonjour(record) = result.metadata {
                        version = record[NimletProtocol.txtVersionKey].flatMap(Int.init)
                    }
                    let remembered = RememberedHost(name: name,
                                                    locator: .bonjour(service: name, domain: domain))
                    return DiscoveredHost(id: remembered.id, name: name,
                                          remembered: remembered, version: version)
                }
                .sorted { $0.name < $1.name }

                if !self.hosts.isEmpty { self.localNetworkDenied = false }
                self.attemptAutoConnect()
            }
        }
        browser.stateUpdateHandler = { [weak self] browserState in
            Task { @MainActor in
                guard let self else { return }
                switch browserState {
                case .waiting(let error):
                    // -65570 is kDNSServiceErr_PolicyDenied: the one `waiting`
                    // that no amount of waiting fixes, because the user said no.
                    if case .dns(let code) = error, code == -65570 {
                        self.localNetworkDenied = true
                        remoteLog.info("browse: local network access denied")
                    }
                case .ready:
                    self.localNetworkDenied = false
                case .failed(let error):
                    guard !self.isLinkBusy, self.failure == nil else { return }
                    self.state = .failed("Couldn't look for Macs: \(error.localizedDescription)")
                default:
                    break
                }
            }
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    func stopBrowsing() {
        browser?.cancel()
        browser = nil
    }

    /// The Mac last used, the moment Bonjour sees it.
    private func attemptAutoConnect() {
        guard !isLinkBusy, !isSuspended, !handshakeRejected, !autoConnectSuppressed else { return }
        guard let remembered = rememberedHosts.first,
              let match = hosts.first(where: { $0.remembered.id == remembered.id }) else { return }
        connect(to: match, explicitly: false)
    }

    // MARK: - Connection

    /// Whether a socket is up or being raced for.
    private var isLinkBusy: Bool { connection != nil || !racers.isEmpty }

    func connect(to host: DiscoveredHost) {
        connect(to: host, explicitly: true)
    }

    func connect(to host: RememberedHost) {
        handshakeRejected = false
        autoConnectSuppressed = false
        reconnect(to: host)
    }

    private func connect(to host: DiscoveredHost, explicitly: Bool) {
        if explicitly {
            handshakeRejected = false
            autoConnectSuppressed = false
        }
        if let mismatch = Self.versionMismatch(for: host) {
            target = PhoneTrust.pin(forHost: host.remembered.id).map { Target(host: host.remembered, pin: $0) }
            refuse(.versionMismatch, message: mismatch, hostName: host.name)
            return
        }
        reconnect(to: host.remembered)
    }

    /// Every entry point comes here: a tap, automatic retries, foreground
    /// resume and a cold launch all rebuild the same race.
    private func reconnect(to host: RememberedHost) {
        guard let pin = PhoneTrust.pin(forHost: host.id) else { return }
        race(Target(host: host, pin: pin), routes(for: host))
    }

    /// Every way into a Mac's trust listeners: its Bonjour service, then the
    /// addresses it has told this phone, local before internet.
    private func routes(for host: RememberedHost, extra: [NimletCandidate] = []) -> [Route] {
        var routes: [Route] = []
        // On cellular alone nothing on the Mac's LAN can answer, so none of it
        // is started.
        let path = pathMonitor.currentPath
        let offLAN = cellularOnlyPath ?? (path.status == .satisfied && path.usesInterfaceType(.cellular)
            && !path.usesInterfaceType(.wifi) && !path.usesInterfaceType(.wiredEthernet))
        if !offLAN, LaunchNetworkPolicy.allows(endpoint: host.trustEndpoint) {
            routes.append(Route(endpoint: host.trustEndpoint, reach: .local))
        }
        var candidates = PhoneTrust.candidates(forHost: host.id) + extra
        // Off the LAN the relay is the one way in that does not depend on the
        // Mac's router, so it starts first. Behind direct addresses that never
        // answer it waited out their stagger, and a cellular reconnect took
        // minutes (QA 2026-10-03).
        if offLAN {
            candidates = candidates.filter { $0.reach == .relay } + candidates.filter { $0.reach != .relay }
        }
        for candidate in candidates {
            guard !(offLAN && candidate.reach == .local) || OverlayAddress.contains(candidate.host),
                  LaunchNetworkPolicy.allowsAwayAccess || (!candidate.isRemote && LaunchNetworkPolicy.allows(host: candidate.host)),
                  ProAccessPolicy.allows(candidate: candidate, offLAN: offLAN, hasPro: hasProAccess),
                  let port = NWEndpoint.Port(rawValue: candidate.port) else { continue }
            let route = Route(endpoint: .hostPort(host: NWEndpoint.Host(candidate.host), port: port),
                              reach: candidate.reach)
            if !routes.contains(where: { $0.endpoint == route.endpoint && $0.reach == route.reach }) {
                routes.append(route)
            }
        }
        // Promote only an address still present in the current, filtered list.
        // A LAN success cannot sneak back into a cellular-only race.
        if let proven = lastSuccessfulRoutes[host.id],
           RoutePolicy.mayPromote(Self.routeClass(proven), offLAN: offLAN),
           let index = routes.firstIndex(where: { $0.endpoint == proven.endpoint && $0.reach == proven.reach }) {
            routes.insert(routes.remove(at: index), at: 0)
        }
        return routes
    }

    /// Starts racing a Mac's addresses.
    private func race(_ target: Target, _ routes: [Route]) {
        // Dialling the Mac we were already on is a reconnection and keeps the
        // screen; dialling a different one is a new session and must not show
        // the last one's dock.
        teardown(keepingSurface: self.target?.host.id == target.host.id)
        reconnectTask?.cancel()
        reconnectTask = nil
        self.target = target
        listeningHostID = target.host.id
        failure = nil
        refusedByKey = false
        if raceStartedAt == nil { raceStartedAt = Date() }
        state = .connecting(target.host.name)
        guard PhoneTrust.identity != nil else {
            refuse(.notPaired, message: "This phone's Keychain would not hold its key, so it cannot connect.",
                   hostName: target.host.name)
            return
        }
        guard !routes.isEmpty else {
            if !hasProAccess {
                showingPro = !ProStore.shared.isChecking || proAccessProvider != nil
                state = .failed("Free controls need the same local network. Remote access requires Nimlet Pro.")
                return
            }
            gaveUp(.posix(.EHOSTUNREACH))
            return
        }
        unstarted = routes
        linkStats.raced = routes.count
        triedReaches = Set(routes.map(\.reach))
        remoteLog.info("race: \(routes.map { $0.reach.rawValue }.joined(separator: ","), privacy: .public)")
        startNextRoute(generation: dialGeneration)
        armDeadline(generation: dialGeneration)
    }

    /// Starts the next address, and the clock on the one after it.
    private func startNextRoute(generation: Int) {
        staggerTask?.cancel()
        staggerTask = nil
        guard generation == dialGeneration, winner == nil, let target, !unstarted.isEmpty else { return }
        let route = unstarted.removeFirst()
        guard let parameters = Self.trustParameters(pin: target.pin, reach: route.reach) else { return }
        let connection = NWConnection(to: route.endpoint, using: parameters)
        connection.stateUpdateHandler = { [weak self, weak connection] connectionState in
            Task { @MainActor in
                guard let self, let connection, generation == self.dialGeneration else { return }
                switch connectionState {
                case .ready:
                    self.won(route, on: connection)
                case .waiting(let error):
                    // This socket cannot proceed on its current path. Retire
                    // it now so another address, or a fresh retry, can answer
                    // instead of spending the remaining ten-second deadline.
                    remoteLog.info("race: \(route.reach.rawValue, privacy: .public) waiting: \(String(describing: error), privacy: .public), path \(String(describing: connection.currentPath?.unsatisfiedReason), privacy: .public)")
                    if connection === self.connection {
                        self.connectionFailed(error)
                    } else {
                        self.lost(connection, error)
                    }
                case .failed(let error):
                    if connection === self.connection {
                        self.connectionFailed(error)
                    } else {
                        self.lost(connection, error)
                    }
                default:
                    break
                }
            }
        }
        racers.append((route, connection))
        connection.start(queue: queue)
        guard !unstarted.isEmpty else { return }
        staggerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.stagger))
            guard !Task.isCancelled else { return }
            self?.startNextRoute(generation: generation)
        }
    }

    /// The first address through TLS. The Mac it reached holds the pinned key,
    /// so the others have nothing left to offer.
    private func won(_ route: Route, on connection: NWConnection) {
        guard ProAccessPolicy.allows(route: Self.routeClass(route), hasPro: hasProAccess),
              hasProAccess || LinkRoute.name(of: connection.currentPath) != "VPN" else {
            showingPro = true
            lost(connection, .posix(.EACCES))
            return
        }
        guard winner == nil, racers.contains(where: { $0.connection === connection }) else { return }
        staggerTask?.cancel()
        staggerTask = nil
        unstarted = []
        for racer in racers where racer.connection !== connection { racer.connection.cancel() }
        racers = []
        winner = route
        tlsReadyAt = Date()
        self.connection = connection
        receiveLoop(on: connection, framer: ConnectionFramer(), generation: dialGeneration)
        // A slow pairing must not be cut off by what is left of the race's
        // clock.
        armDeadline(generation: dialGeneration)
        guard let target else { return }
        // Redeeming a QR code: prove it before saying anything else, because
        // on that socket `pair` is the only thing the Mac will hear.
        if let invitation = target.invitation {
            guard let exporter = TrustTransport.exporter(of: connection, label: PairingProof.exporterLabel),
                  let me = PhoneTrust.identity?.fingerprint else {
                connectionFailed(.tls(errSSLInternal))
                return
            }
            let proof = PairingProof.make(secret: invitation.secret, exporter: exporter, device: me)
            send(.pair(PairRequest(proof: proof, deviceName: helloName)))
            return
        }
        // TLS alone is not an accepted session. Keep the deadline and the
        // connecting screen until welcome arrives.
        send(.hello(HelloPayload(deviceName: helloName, deviceID: deviceID)))
        // Away from the LAN, ask for the direct path in the same flight as
        // hello: the Mac reads them in order, so its answer follows welcome by
        // nothing, rather than by a relay round trip and a few seconds' wait.
        if Self.routeClass(route) > .lan { startDirectProbe() }
        // On the TCP relay, also ask for its UDP: a fallback when no direct
        // path can be punched, and better than this one either way.
        if route.reach == .relay, route.tunnelClass == nil { send(.relayTunnelRequest) }
    }

    /// One address out of the race. Nothing is reported for it: off the LAN
    /// the local addresses always fail, and saying so would put "could not
    /// reach your Mac" on screen a second before reaching it.
    private func lost(_ connection: NWConnection, _ error: NWError) {
        guard let racer = racers.first(where: { $0.connection === connection }) else { return }
        // Logged, not shown: which way in failed and how is what a slow
        // reconnect is diagnosed from.
        remoteLog.info("race: \(racer.route.reach.rawValue, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        racers.removeAll { $0.connection === connection }
        connection.cancel()
        if Self.isCertificateRefusal(error) { refusedByKey = true }
        if !unstarted.isEmpty {
            startNextRoute(generation: dialGeneration)
        } else if racers.isEmpty {
            gaveUp(error)
        }
    }

    /// Ends a race, or a won link, that is neither succeeding nor failing.
    ///
    /// `connectionTimeout` is ten seconds per socket, and a firewall that drops
    /// a SYN rather than refusing it produces exactly that silence. This bounds
    /// the whole attempt the same way.
    private func armDeadline(generation: Int) {
        attemptDeadline?.cancel()
        attemptDeadline = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, let self, generation == self.dialGeneration else { return }
            self.connectionFailed(.posix(.ETIMEDOUT))
        }
    }

    /// The Mac's answer to a QR code.
    private func paired(_ result: PairResult) {
        guard var target, let invitation = target.invitation else { return }
        guard result.ok else {
            refuseByKey(message: result.message
                        ?? "Your Mac did not accept that pairing code. Show a new one and scan it again.")
            return
        }
        PhoneTrust.remember(pin: target.pin, forHost: target.host.id)
        if PhoneTrust.candidates(forHost: target.host.id).isEmpty {
            PhoneTrust.remember(Self.candidates(from: invitation), forHost: target.host.id)
        }
        remoteLog.info("trust: paired with \(target.host.name, privacy: .public) by key")
        target.invitation = nil
        self.target = target
        send(.hello(HelloPayload(deviceName: helloName, deviceID: deviceID)))
    }

    /// Takes a scanned QR code and pairs with the Mac it names.
    ///
    /// The system Camera opens the app with the URL; nothing about the code is
    /// typed. The Mac's key comes from the code, so the very first handshake is
    /// already pinned — there is no moment of trusting whatever answered.
    @discardableResult
    func acceptInvitation(_ url: URL) -> Bool {
        guard let invitation = PairingInvitation(url: url) else { return false }
        guard PhoneTrust.identity != nil else {
            showToast("⚠︎ This phone's Keychain would not hold a key, so it cannot pair by code")
            return true
        }
        pendingPairing = PendingPairing(invitation: invitation, replacesPin: replacesPin(invitation))
        return true
    }

    /// Whether pairing by `invitation` would replace a different key this
    /// phone already pinned under that Mac's name.
    func replacesPin(_ invitation: PairingInvitation) -> Bool {
        let existing = PhoneTrust.pin(forHost: Self.invitedHost(invitation).id)
        return existing != nil && existing != invitation.host
    }

    func cancelPairing() {
        pendingPairing = nil
    }

    /// The person said yes to the pairing on screen.
    func confirmPairing() {
        guard let invitation = pendingPairing?.invitation else { return }
        pendingPairing = nil
        pair(with: invitation)
    }

    /// Redeems a code the person has agreed to: from the alert for a link the
    /// Camera opened, or straight from the scanner inside the app.
    func pair(with invitation: PairingInvitation) {
        let host = Self.invitedHost(invitation)
        handshakeRejected = false
        autoConnectSuppressed = false
        failure = nil
        if retryingSince == nil { retryingSince = Date() }
        startBrowsing()
        // The link's addresses are dialled but not kept: only a Mac that has
        // proved it holds the key in the code gets to leave addresses behind.
        race(Target(host: host, pin: invitation.host, invitation: invitation),
             routes(for: host, extra: Self.candidates(from: invitation)))
    }

    private static func invitedHost(_ invitation: PairingInvitation) -> RememberedHost {
        RememberedHost(name: invitation.name, locator: .bonjour(service: invitation.name, domain: "local."))
    }

    private static func candidates(from invitation: PairingInvitation) -> [NimletCandidate] {
        invitation.addresses.compactMap { address -> NimletCandidate? in
            guard let (ip, port) = parseAddress(address) else { return nil }
            return NimletCandidate(host: ip, port: port, reach: .local, via: "QR code")
        }
    }

    /// A Mac that will not have this phone, or a Mac that is not the one this
    /// phone paired with. Terminal: redialling produces the same answer.
    private func refuseByKey(message: String) {
        refuse(.notPaired, message: message, hostName: target?.host.name ?? "your Mac")
    }

    /// A verdict rather than a link problem: stop, say so, and do not redial.
    private func refuse(_ kind: Failure.Kind, message: String, hostName: String) {
        handshakeRejected = true
        listeningHostID = nil
        retryingSince = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        holdSurface(false)
        teardown()
        failure = Failure(kind: kind, message: message, hostName: hostName)
        state = .failed(message)
    }

    private func sessionBecameReady() {
        guard let target, let winner, !state.isConnected else { return }
        attemptDeadline?.cancel()
        attemptDeadline = nil
        PhoneTrust.remember(lastReach: winner.reach, forHost: target.host.id)
        lastSuccessfulRoutes[target.host.id] = winner
        session = Session(endpoint: winner.endpoint, pin: target.pin, reach: winner.reach)
        state = .connected(target.host.name)
        holdSurface(false)
        failure = nil
        retryingSince = nil
        lastConnectedAt = Date()
        connectedLink = LinkRoute.name(of: connection?.currentPath)
        let took = raceStartedAt.map { Int(Date().timeIntervalSince($0) * 1000) } ?? -1
        var tls = -1
        if let raceStartedAt, let tlsReadyAt { tls = Int(tlsReadyAt.timeIntervalSince(raceStartedAt) * 1000) }
        raceStartedAt = nil
        tlsReadyAt = nil
        linkStats.tlsMillis = tls
        linkStats.welcomeMillis = took
        linkStats.clearRoundTrips()
        let routeClass = Self.routeClass(winner)
        remoteLog.notice("session ready: \(winner.reach.rawValue, privacy: .public) (\(routeClass.description, privacy: .public)) over \(self.connectedLink ?? "?", privacy: .public) — TLS at \(tls, privacy: .public) ms, welcome at \(took, privacy: .public) ms, first of \(self.linkStats.raced ?? 0, privacy: .public) routes")
        // First through TLS is how a session starts, not a promise it is the
        // best way there. Anything short of the LAN keeps looking.
        upgradeAttempt = 0
        if routeClass > .lan {
            // A tunnel that opened while welcome was on its way is looked at
            // now; otherwise the usual first look, and the probe if hello's
            // could not be sent (a pairing, say).
            scheduleUpgrade(after: directRoute != nil || relayDatagramRoute != nil ? 0.05 : 1.5, "connected over \(routeClass)")
            if directProbe == nil, directTunnel == nil { startDirectProbe() }
        }
        reconnectAttempt = 0
        reconnectTask?.cancel()
        reconnectTask = nil
        lastPongAt = Date()
        lastActivityAt = Date()
        remember(target.host)
        startPinging()
        sendPing()
    }

    // MARK: - Moving to a better route

    /// The class of the route the session is on; the LAN when there is none.
    private var currentRouteClass: RoutePolicy.RouteClass {
        winner.map(Self.routeClass) ?? .lan
    }

    private static func routeClass(_ route: Route) -> RoutePolicy.RouteClass {
        if let tunnelClass = route.tunnelClass { return tunnelClass }
        var overlay = false
        if case .hostPort(let host, _) = route.endpoint {
            overlay = OverlayAddress.contains(String("\(host)".split(separator: "%").first ?? ""))
        }
        return RoutePolicy.routeClass(reach: route.reach, isOverlay: overlay)
    }

    private static func describe(_ route: Route) -> String {
        "\(route.reach.rawValue)(\(routeClass(route)))"
    }

    /// Looks for a better route after `delay`, replacing any look already due.
    private func scheduleUpgrade(after delay: TimeInterval, _ reason: String) {
        upgradeTask?.cancel()
        let generation = dialGeneration
        upgradeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, generation == self.dialGeneration else { return }
            self.upgradeTask = nil
            self.lookForBetterRoute(reason)
        }
    }

    /// Dials every route of a better class than the session's, alongside it.
    /// Each that answers says hello like any session, is pinged, and is moved
    /// to only if it is actually quicker — see `RoutePolicy.shouldMigrate`.
    private func lookForBetterRoute(_ reason: String) {
        guard state.isConnected, !isSuspended, let target, let current = winner,
              probes.isEmpty, switchTask == nil else { return }
        let currentClass = Self.routeClass(current)
        guard currentClass > .lan else { return }
        let better = (routes(for: target.host) + [directRoute, relayDatagramRoute].compactMap { $0 }).filter {
            Self.routeClass($0) < currentClass && !($0.endpoint == current.endpoint && $0.reach == current.reach)
        }
        guard !better.isEmpty else {
            remoteLog.info("upgrade: \(reason, privacy: .public); nothing better than \(currentClass.description, privacy: .public) to try")
            scheduleNextLook()
            return
        }
        remoteLog.info("upgrade: \(reason, privacy: .public); on \(Self.describe(current), privacy: .public), trying \(better.map(Self.describe).joined(separator: ","), privacy: .public)")
        let generation = dialGeneration
        for route in better {
            guard let parameters = Self.trustParameters(pin: target.pin, reach: route.reach) else { continue }
            let connection = NWConnection(to: route.endpoint, using: parameters)
            let probe = Probe(route: route, connection: connection)
            probes.append(probe)
            connection.stateUpdateHandler = { [weak self, weak connection] state in
                Task { @MainActor in
                    guard let self, let connection, generation == self.dialGeneration else { return }
                    // Once moved to, this socket is the session, and its
                    // failure is the session's.
                    if connection === self.connection {
                        switch state {
                        case .waiting(let error), .failed(let error): self.connectionFailed(error)
                        default: break
                        }
                        return
                    }
                    guard let probe = self.probes.first(where: { $0.connection === connection }) else { return }
                    switch state {
                    case .ready:
                        self.send(.hello(HelloPayload(deviceName: self.helloName, deviceID: self.deviceID)), on: connection)
                    case .waiting(let error), .failed(let error):
                        self.dropProbe(probe, "\(error)")
                    default:
                        break
                    }
                }
            }
            connection.start(queue: queue)
            receiveLoop(on: connection, framer: ConnectionFramer(), generation: generation)
        }
        upgradeDeadline?.cancel()
        upgradeDeadline = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.probeDeadline))
            guard !Task.isCancelled, let self, generation == self.dialGeneration, self.switchTask == nil else { return }
            if !self.probes.isEmpty {
                remoteLog.info("upgrade: \(self.probes.count, privacy: .public) routes did not answer in time")
            }
            self.cancelProbes()
            self.scheduleNextLook()
        }
    }

    /// Messages from a socket that is not the session's: a route being tried,
    /// or one the session has just left.
    private func receivedAside(_ messages: [HostMessage], ended: Bool, on source: NWConnection) {
        if let probe = probes.first(where: { $0.connection === source }) {
            for message in messages { handleProbe(message, probe) }
            if ended, probes.contains(where: { $0 === probe }) { dropProbe(probe, "closed") }
            return
        }
        guard retiring.contains(where: { $0 === source }) else { return }
        // Only answers to something asked on that socket before the switch.
        // Everything the Mac broadcasts reaches the session's socket too, and a
        // pong would time the route that was left.
        for message in messages where Self.isReply(message) { handle(message) }
        if ended { retiring.removeAll { $0 === source } }
    }

    private static func isReply(_ message: HostMessage) -> Bool {
        switch message {
        case .appCommandResult, .delivered, .vocabulary, .pendingApprovals, .panes,
             .windows, .apps, .menu, .uploadReady:
            return true
        default:
            return false
        }
    }

    private func handleProbe(_ message: HostMessage, _ probe: Probe) {
        switch message {
        case .welcome(let status, let targets):
            guard status.deviceApproved else { return dropProbe(probe, "not approved on that route") }
            probe.welcomed = true
            probe.status = status
            probe.targets = targets
            // Three pings, a little apart, so one unlucky sample does not
            // decide — and close enough that measuring costs a round trip,
            // not half a second.
            for index in 0..<3 {
                Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(40 * index))
                    guard let self, self.probes.contains(where: { $0 === probe }) else { return }
                    self.pingNonce &+= 1
                    probe.pings[self.pingNonce] = Instrumentation.now()
                    self.send(.ping(nonce: self.pingNonce), on: probe.connection)
                }
            }
        case .status(let status):
            probe.status = status
        case .targets(let targets):
            probe.targets = targets
        case .pong(let nonce, _):
            guard let sentAt = probe.pings.removeValue(forKey: nonce) else { return }
            probe.samples.append(Double(Instrumentation.now() &- sentAt) / 1_000_000_000)
            if probe.samples.count >= 3 { evaluate(probe) }
        case .error(let text):
            dropProbe(probe, "the Mac said: \(text)")
        default:
            break
        }
    }

    private func evaluate(_ probe: Probe) {
        guard let current = winner, switchTask == nil, let candidateRTT = probe.samples.min() else { return }
        let currentRTT = recentRoundTrips.suffix(10).min()
        let from = Self.routeClass(current), to = Self.routeClass(probe.route)
        let numbers = "\(Int(candidateRTT * 1000)) ms vs \(currentRTT.map { "\(Int($0 * 1000)) ms" } ?? "unmeasured")"
        guard RoutePolicy.shouldMigrate(from: from, roundTrip: currentRTT, to: to, roundTrip: candidateRTT) else {
            remoteLog.info("upgrade: \(Self.describe(probe.route), privacy: .public) answered but is not better: \(numbers, privacy: .public)")
            dropProbe(probe, "not better")
            return
        }
        remoteLog.info("upgrade: \(Self.describe(probe.route), privacy: .public) is better: \(numbers, privacy: .public); switching when input is quiet")
        for other in probes where other !== probe { other.connection.cancel() }
        probes = [probe]
        upgradeDeadline?.cancel()
        upgradeDeadline = nil
        let generation = dialGeneration
        let started = Date()
        switchTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, generation == self.dialGeneration,
                      self.probes.contains(where: { $0 === probe }) else { return }
                let quiet = RoutePolicy.isQuietForSwitch(buttonsHeld: !self.pressedButtons.isEmpty,
                                                         sinceOrderedInput: Date().timeIntervalSince(self.lastOrderedInputAt),
                                                         roundTrip: currentRTT)
                if quiet {
                    self.switchTask = nil
                    self.switchSession(to: probe, roundTrip: candidateRTT, from: currentRTT)
                    return
                }
                if Date().timeIntervalSince(started) > Self.switchPatience {
                    remoteLog.info("upgrade: input never went quiet; staying on the current route for now")
                    self.switchTask = nil
                    self.dropProbe(probe, "input never went quiet")
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    /// Make-before-break: the new socket already said hello and was welcomed,
    /// so from here every message goes to it, and the old one is kept open
    /// just long enough for answers already on their way back.
    private func switchSession(to probe: Probe, roundTrip: Double, from previousRTT: Double?) {
        guard ProAccessPolicy.allows(route: Self.routeClass(probe.route), hasPro: hasProAccess),
              hasProAccess || LinkRoute.name(of: probe.connection.currentPath) != "VPN" else {
            probe.connection.cancel()
            return
        }
        guard let target, let old = connection, let previous = winner else { return }
        probes = []
        connection = probe.connection
        winner = probe.route
        session = Session(endpoint: probe.route.endpoint, pin: target.pin, reach: probe.route.reach)
        connectedLink = LinkRoute.name(of: probe.connection.currentPath)
        PhoneTrust.remember(lastReach: probe.route.reach, forHost: target.host.id)
        lastSuccessfulRoutes[target.host.id] = probe.route
        pendingPings.removeAll()
        recentRoundTrips = probe.samples
        linkStats.clearRoundTrips()
        probe.samples.forEach { linkStats.add(roundTripMillis: $0 * 1000) }
        roundTripMillis = roundTrip * 1000
        lastPongAt = Date()
        if let status = probe.status { apply(status) }
        if let targets = probe.targets { adopt(targets) }
        // Asked again on the new socket: anything the old one was subscribed
        // to, and the approvals, in case one arrived in the instant between.
        refreshApprovals()
        if appStateRequested { send(.requestAppState) }
        retire(old, roundTrip: previousRTT)
        let note = "\(Self.routeClass(previous)) → \(Self.routeClass(probe.route)): \(Int(roundTrip * 1000)) ms vs \(previousRTT.map { "\(Int($0 * 1000)) ms" } ?? "?")"
        // On a direct path the relay's UDP has nothing left to carry.
        if Self.routeClass(probe.route) <= .direct { closeRelayTunnel("the session moved to a direct path") }
        linkStats.lastMove = note
        upgradeAttempt = 0
        remoteLog.notice("upgrade: moved \(note, privacy: .public) over \(self.connectedLink ?? "?", privacy: .public)")
        if Self.routeClass(probe.route) > .lan { scheduleUpgrade(after: RoutePolicy.upgradeDelay(attempt: 0), "still not on the LAN") }
    }

    private func retire(_ old: NWConnection, roundTrip: Double?) {
        retiring.append(old)
        let linger = max(3, (roundTrip ?? 0.5) * 4)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(linger))
            guard let self else { return }
            old.cancel()
            self.retiring.removeAll { $0 === old }
        }
    }

    private func dropProbe(_ probe: Probe, _ why: String) {
        guard probes.contains(where: { $0 === probe }) else { return }
        remoteLog.notice("upgrade: \(Self.describe(probe.route), privacy: .public) dropped: \(why, privacy: .public)")
        probe.connection.cancel()
        probes.removeAll { $0 === probe }
        guard probes.isEmpty, switchTask == nil else { return }
        upgradeDeadline?.cancel()
        upgradeDeadline = nil
        scheduleNextLook()
    }

    private func cancelProbes() {
        switchTask?.cancel()
        switchTask = nil
        upgradeDeadline?.cancel()
        upgradeDeadline = nil
        probes.forEach { $0.connection.cancel() }
        probes = []
    }

    /// Looks again later, less often each time nothing better turned up.
    private func scheduleNextLook() {
        guard state.isConnected, let winner, Self.routeClass(winner) > .lan else { return }
        let delay = RoutePolicy.upgradeDelay(attempt: upgradeAttempt)
        upgradeAttempt += 1
        scheduleUpgrade(after: delay, "periodic look")
    }

    /// One message on a socket that is not (yet) the session's.
    private func send(_ message: ClientMessage, on connection: NWConnection) {
        guard let data = try? NimletCoder.line(message) else { return }
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    // MARK: - Direct path, phase 0

    private func startDirectProbe() {
        guard hasProAccess else { return }
        guard directProbe == nil, directTunnel == nil, let connection, helloSent else { return }
        guard let secret = TrustTransport.exporter(of: connection, label: DirectPacket.exporterLabel) else {
            linkStats.direct = "not tried: no session key"
            return
        }
        guard let probe = DirectProbe(secret: secret) else {
            linkStats.direct = "not tried: this phone has no global IPv6 right now"
            remoteLog.info("direct: no global IPv6 on this phone's default route")
            return
        }
        directProbe = probe
        linkStats.direct = "punching…"
        remoteLog.info("direct: offering \(probe.local.display, privacy: .private)")
        send(.directOffer(probe.local))
    }

    private func answerDirect(_ candidate: DirectCandidate?, note: String?) {
        guard let probe = directProbe else { return }
        guard let candidate else {
            linkStats.direct = "not tried: \(note ?? "the Mac has no IPv6 address to offer")"
            remoteLog.notice("direct: Mac declined: \(note ?? "?", privacy: .public)")
            directProbe = nil
            return
        }
        let generation = dialGeneration
        guard let connection, let secret = TrustTransport.exporter(of: connection, label: DirectPacket.exporterLabel) else { return }
        remoteLog.info("direct: punching towards \(candidate.display, privacy: .private)")
        probe.punch(peer: candidate) { [weak self] fd, millis, note in
            Task { @MainActor in
                guard let self, generation == self.dialGeneration, self.directProbe === probe else {
                    if let fd { Darwin.close(fd) }
                    return
                }
                self.directProbe = nil
                guard let fd else {
                    let report = DirectProbeReport(punched: false, note: note)
                    self.linkStats.direct = report.summary
                    remoteLog.info("direct: \(report.summary, privacy: .public)")
                    self.send(.directReport(report))
                    return
                }
                self.openDirectTunnel(fd, secret: secret, punchMillis: millis ?? -1, generation: generation)
            }
        }
    }

    // MARK: - The relay's UDP

    private func openRelayTunnel(_ grant: RelayDatagramGrant?, note: String?) {
        guard relayTunnel == nil else { return }
        guard let grant else {
            linkStats.relayUDP = "not available: \(note ?? "?")"
            remoteLog.notice("relay UDP: not available: \(note ?? "?", privacy: .public)")
            return
        }
        guard let connection,
              let secret = TrustTransport.exporter(of: connection, label: RelayDatagramGrant.exporterLabel),
              let framing = grant.framing(asMac: false),
              let fd = DirectSocket.connected(to: grant.host, port: grant.port) else {
            linkStats.relayUDP = "not available: could not open a UDP socket"
            return
        }
        let generation = dialGeneration
        // Everything twice: this end's datagrams cross the uplink that lost a
        // quarter of them, and they are input and acknowledgements — small.
        let tunnel = DirectTunnel(socket: fd, secret: secret, side: .dialer,
                                  framing: framing, redundancy: .all(copies: 2))
        tunnel.onReady = { [weak self] port in
            Task { @MainActor in
                guard let self, generation == self.dialGeneration, self.relayTunnel === tunnel else { return }
                self.relayTunnelPort = port
                self.offerRelayTunnelRoute()
            }
        }
        tunnel.onFirstContact = { [weak self] in
            Task { @MainActor in
                guard let self, generation == self.dialGeneration, self.relayTunnel === tunnel else { return }
                self.relayTunnelHeard = true
                self.offerRelayTunnelRoute()
            }
        }
        tunnel.onClose = { [weak self] reason in
            Task { @MainActor in
                guard let self, self.relayTunnel === tunnel else { return }
                remoteLog.notice("relay UDP: tunnel closed: \(reason, privacy: .public)")
                self.relayTunnel = nil
                self.relayDatagramRoute = nil
                self.relayTunnelPort = nil
                self.relayTunnelHeard = false
                self.linkStats.relayUDP = "closed: \(reason)"
            }
        }
        relayTunnel = tunnel
        linkStats.relayUDP = "opening…"
        tunnel.start()
    }

    /// Once the tunnel listens here and has heard the Mac through the relay,
    /// it is a route — offered to the upgrade at once, like a direct one.
    private func offerRelayTunnelRoute() {
        guard relayDatagramRoute == nil, relayTunnelHeard, let port = relayTunnelPort,
              let loopback = NWEndpoint.Port(rawValue: port) else { return }
        relayDatagramRoute = Route(endpoint: .hostPort(host: "127.0.0.1", port: loopback), reach: .relay,
                                   tunnelClass: .relayDatagram)
        linkStats.relayUDP = "open"
        remoteLog.notice("relay UDP: tunnel open on loopback \(port, privacy: .public)")
        guard state.isConnected else { return }
        if switchTask == nil { cancelProbes() }
        scheduleUpgrade(after: 0.02, "the relay's UDP is open")
    }

    private func closeRelayTunnel(_ reason: String) {
        relayTunnel?.close(reason)
        relayTunnel = nil
        relayDatagramRoute = nil
        relayTunnelPort = nil
        relayTunnelHeard = false
    }

    /// The punched socket becomes a tunnel; its loopback port becomes a route.
    private func openDirectTunnel(_ fd: Int32, secret: Data, punchMillis: Int, generation: Int) {
        let tunnel = DirectTunnel(socket: fd, secret: secret, side: .dialer)
        tunnel.onReady = { [weak self] port in
            Task { @MainActor in
                guard let self, generation == self.dialGeneration, self.directTunnel === tunnel,
                      let loopback = NWEndpoint.Port(rawValue: port) else { return }
                self.directRoute = Route(endpoint: .hostPort(host: "127.0.0.1", port: loopback), reach: .internet6,
                                         tunnelClass: .direct)
                self.linkStats.direct = "punched in \(punchMillis) ms; tunnel open"
                remoteLog.notice("direct: punched in \(punchMillis, privacy: .public) ms; tunnel on loopback \(port, privacy: .public)")
                self.send(.directReport(DirectProbeReport(punched: true, punchMillis: punchMillis)))
                self.upgradeAttempt = 0
                // Now, not after whatever look is already running: the first
                // test on 5G (2026-10-05) opened the tunnel while a look was
                // waiting out a blocked address, and that look's six seconds
                // plus the next one's fifteen kept the session on the relay
                // for the whole test. Only a switch already under way waits.
                // Before welcome there is no session to move yet; welcome looks.
                guard self.state.isConnected else { return }
                if self.switchTask == nil { self.cancelProbes() }
                self.scheduleUpgrade(after: 0.02, "a direct path is open")
            }
        }
        tunnel.onClose = { [weak self] reason in
            Task { @MainActor in
                guard let self, self.directTunnel === tunnel else { return }
                remoteLog.notice("direct: tunnel closed: \(reason, privacy: .public)")
                self.directTunnel = nil
                self.directRoute = nil
                self.linkStats.direct = "closed: \(reason)"
                // A session on the tunnel loses its sockets now and redials the
                // usual way; one still on the relay just stops looking here.
            }
        }
        directTunnel = tunnel
        tunnel.start()
    }

    /// The won link failed, or the race or the link ran out of time.
    private func connectionFailed(_ error: NWError) {
        remoteLog.error("connection failed: \(String(describing: error), privacy: .public)")
        // A session that was up and has now failed — Wi-Fi to cellular, the
        // relay restarting — is a link to bring back, not a verdict on whether
        // this phone is paired.
        if state.isConnected {
            dropAndReconnect("the connection failed: \(error.localizedDescription)")
            return
        }
        // Through TLS and then closed before `welcome` is the Mac judging this
        // phone's key. Running out of time is not.
        var timedOut = false
        if case .posix(.ETIMEDOUT) = error { timedOut = true }
        if winner != nil, !timedOut { refusedByKey = true }
        gaveUp(error)
    }

    /// Every address has failed, or the one that got through did.
    private func gaveUp(_ error: NWError) {
        attemptDeadline?.cancel()
        attemptDeadline = nil
        let name = target?.host.name ?? "your Mac"
        if refusedByKey {
            refuseByKey(message: target?.invitation != nil
                        ? "\(name) did not accept this phone. Show a new pairing code on your Mac and scan it again."
                        : "\(name) does not recognise this phone any more, or is not the Mac it paired with. On your Mac, open the Nimlet menu, choose Pair a Phone, and scan the code.")
            return
        }
        let mismatch = hosts.first { $0.name == name }.flatMap { Self.versionMismatch(for: $0) }
        let message = mismatch ?? explain(error, host: name)
        state = .failed(message)
        // A named failure is a screen of its own — it has something to say and
        // something to offer — so the held surface stands down for it.
        holdSurface(false)
        failure = Failure(kind: mismatch != nil ? .versionMismatch : .unreachable, message: message, hostName: name)
        teardown()
        if retryingSince == nil { retryingSince = Date() }
        scheduleReconnect()
    }

    /// "Try again", from the recovery screens. Deliberately clears the two
    /// latches that exist to stop the app redialling by itself — a refused code
    /// and a user-requested disconnect — because this is the user asking.
    func retry() {
        handshakeRejected = false
        autoConnectSuppressed = false
        reconnectAttempt = 0
        failure = nil
        // Mid-attempt is when somebody presses this: the attempt they are
        // watching is the one not working. Start a fresh one, with the routes
        // as they are now, rather than doing nothing.
        guard !state.isConnected else { return }
        startBrowsing()
        guard let pending = target ?? rememberedTarget() else { return }
        target = pending
        if retryingSince == nil { retryingSince = Date() }
        reconnect(to: pending.host)
    }

    /// The Mac this phone is on, or was last trying to be on.
    var currentHostName: String? {
        switch state {
        case .connected(let name), .connecting(let name): return name
        default: return target?.host.name ?? rememberedHosts.first?.name
        }
    }

    /// Whether the attempt under way is redeeming a pairing code, rather than
    /// coming back to a Mac this phone already holds a pin for.
    var isPairing: Bool { target?.invitation != nil }

    /// The Mac on the failure screen, for its "Forget" button: the one the
    /// last attempt was for.
    var failedHost: RememberedHost? { failure == nil ? nil : target?.host }

    func disconnect() {
        autoConnectSuppressed = true
        raceStartedAt = nil
        listeningHostID = nil
        failure = nil
        retryingSince = nil
        holdSurface(false)
        target = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        teardown()
        state = .browsing
    }

    /// Keeps the screen you left on display while the link comes back — or takes
    /// it down.
    ///
    /// Bounded, because every reason to hold it is a guess that the same Mac is
    /// about to answer, and a guess that turns out to be wrong must not sit there
    /// being wrong: a dimmed trackpad says "in a moment", and after six seconds
    /// that is no longer what is happening.
    /// `capped: false` is for a hold taken while the app is off screen. The
    /// countdown would be frozen along with the process and then fire the moment
    /// the app came back — ending the hold exactly when it is wanted — so the
    /// clock is started again by `enterForeground`, where there is a screen for
    /// it to mean anything on.
    private func holdSurface(_ hold: Bool, capped: Bool = true) {
        surfaceHoldTask?.cancel()
        surfaceHoldTask = nil
        isResuming = hold
        guard hold, capped else { return }
        surfaceHoldTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.surfaceHold))
            guard !Task.isCancelled, let self, !self.state.isConnected else { return }
            self.isResuming = false
        }
    }

    /// Ends a connection and forgets everything that described it.
    ///
    /// `keepingSurface` is for the teardowns that are on the way back to the
    /// same Mac — leaving the app for a moment, a Wi-Fi hiccup, the redial that
    /// follows either. The target list and the host's own status survive those,
    /// because they describe a Mac that has not changed and are what the screen
    /// is drawn from; clearing them meant every blip emptied the dock.
    private func teardown(keepingSurface keep: Bool = false) {
        // Anything still in flight on the old connection belongs to a session
        // that no longer exists.
        dialGeneration &+= 1
        resumeProbeTask?.cancel()
        resumeProbeTask = nil
        resumeProbeNonce = nil
        attemptDeadline?.cancel()
        attemptDeadline = nil
        staggerTask?.cancel()
        staggerTask = nil
        racers.forEach { $0.connection.cancel() }
        racers = []
        unstarted = []
        winner = nil
        connection?.cancel()
        connection = nil
        cancelProbes()
        upgradeTask?.cancel()
        upgradeTask = nil
        directProbe?.cancel()
        directProbe = nil
        directTunnel?.close("session ended")
        directTunnel = nil
        directRoute = nil
        closeRelayTunnel("session ended")
        retiring.forEach { $0.cancel() }
        retiring = []
        recentRoundTrips = []
        helloSent = false
        pressedButtons.removeAll()
        connectedLink = nil
        session = nil
        hostClockOffset = nil
        pingTimer?.invalidate()
        pingTimer = nil
        pendingPings.removeAll()
        lastPongAt = nil
        roundTripMillis = nil
        if !keep {
            targets = []
            status = nil
        }
        requestedVocabulary.removeAll()
        vocabularyChunks.removeAll()
        // Same rule as the vocabulary below: the sets that were read are kept,
        // because an app's own keys do not change while the phone is away — but
        // what the Mac said about the ones it could *not* read does go, since
        // "not running" is a statement about a moment that has passed.
        requestedMenus.removeAll()
        menuNotes.removeAll()
        // The terms themselves are kept — a stale set still beats none while the
        // fresh one is on its way — but their age is not, so the next connection
        // asks again. Time away from the Mac is exactly when the repository is
        // most likely to have moved.
        vocabularyFetchedAt.removeAll()
        approvals.removeAll()
        // The cards go because their answers have nowhere to be sent. The
        // banners are the same cards on the lock screen, with the same two
        // buttons and the same missing socket, so they go too. Agent reports
        // are left alone: "this failed twenty minutes ago" is a statement
        // about the past and is still true with the link down.
        AgentAlerts.shared.approvalsChanged(to: [])
        unresolvedTargetIDs.removeAll()
        // The icons themselves stay — an app's picture is the same one on the
        // next connection, and a dock that goes grey the moment the link drops
        // is a dock that looks broken every time the phone locks. What goes is
        // the record of having asked, and the catalogue, which describes a disk
        // this phone can no longer see.
        requestedIcons.removeAll()
        appSuggestions = []
        appChunks = []
        isFetchingApps = false
        appStateRequested = false
        appRuntime = nil
        appOperationsDisconnected()
        // A window list describes a Mac this phone can no longer see, and the
        // previews are pictures of a moment that has passed. The pins are not
        // here to lose: they live on the targets, on the Mac.
        windowRosters.removeAll()
        windowPreviews.removeAll()
        windowChunks.removeAll()
        fetchingWindowsFor = nil
        isIdle = false
    }

    /// Ends a connection that is no longer carrying anything and starts the
    /// race again. Distinct from `disconnect()`, which is the user's decision.
    private func dropAndReconnect(_ reason: String) {
        remoteLog.notice("dropping connection: \(reason, privacy: .public)")
        let clock = Date().formatted(date: .omitted, time: .standard)
        linkStats.lastDrop = "\(clock) on \(currentRouteClass): \(reason)"
        if retryingSince == nil { retryingSince = Date() }
        let name = target?.host.name
        holdSurface(!targets.isEmpty && target != nil)
        teardown(keepingSurface: true)
        state = name.map { State.connecting($0) } ?? .browsing
        scheduleReconnect()
    }

    /// Silent drops — a Mac going to sleep, a Wi-Fi hiccup, a VPN coming up —
    /// change nothing in Bonjour, so without this nothing at all brings the
    /// session back and the app simply stops working until it is force-quit.
    private func scheduleReconnect() {
        guard !isSuspended, !handshakeRejected, !autoConnectSuppressed else { return }
        guard reconnectTask == nil, !isLinkBusy, let pending = target else { return }

        let attempt = reconnectAttempt
        reconnectAttempt += 1
        let delay = min(Self.reconnectBaseDelay * pow(2, Double(attempt)), Self.maxReconnectDelay)
            * Double.random(in: 0.8...1.2)
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.reconnectTask = nil
            guard !self.isSuspended, !self.isLinkBusy else { return }
            self.reconnect(to: pending.host)
        }
    }

    /// iOS suspends the socket the moment the app leaves the screen and a
    /// suspended TLS connection never recovers. Every notification, every call
    /// and every glance at a message used to end the session permanently, with
    /// nothing on screen to say so — which is what "it randomly stopped
    /// working" means.
    func enterBackground() {
        resumeProbeTask?.cancel()
        resumeProbeTask = nil
        resumeProbeNonce = nil
        guard !isSuspended, suspendTask == nil else { return }
        // A network handoff may have no socket at the exact moment the phone
        // locks. Listening still needs its reconnect task in that case.
        if isListeningHeld {
            stopBrowsing()
            beginBackgroundAssertion()
            return
        }
        // Nothing to hold open. Spending a task assertion on a connection that
        // does not exist would keep the app awake to do nothing.
        guard isLinkBusy else { suspendNow(); return }
        // Bonjour is the one thing that is no use off screen: nobody is looking
        // at a list of Macs, and browsing keeps the radio busy.
        stopBrowsing()
        beginBackgroundAssertion()
        suspendTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.backgroundGrace))
            guard !Task.isCancelled else { return }
            self?.suspendNow()
        }
    }

    /// Gives the session up: the grace ran out, or iOS is about to freeze the
    /// process and said so.
    private func suspendNow() {
        suspendTask?.cancel()
        suspendTask = nil
        endBackgroundAssertion()
        guard !isSuspended else { return }
        isSuspended = true
        reconnectTask?.cancel()
        reconnectTask = nil
        stopBrowsing()
        // The dock, the targets and what the Mac said about itself are kept: it
        // is the same Mac, and coming back to a screen that still describes it
        // and then fills in is not the same experience as coming back to an
        // empty one.
        holdSurface(!targets.isEmpty && target != nil, capped: false)
        teardown(keepingSurface: true)
        state = target.map { State.connecting($0.host.name) } ?? .idle
    }

    /// Whether something in this app has a reason to be alive off screen.
    ///
    /// Exactly one thing does: the listen channel, which plays the Mac's audio.
    /// Everything else here is a foreground input device — the premise of the app
    /// is a phone lying beside the keyboard — and the ten-second grace below is
    /// sized for a glance at a notification, not for a walk to the kitchen.
    private var isListeningHeld = false

    /// Told by `ListenClient` when the user switches listening on and off.
    ///
    /// Switching it off in the background is the case worth being careful about:
    /// the process is awake only because audio was playing, and once it is not,
    /// the socket has to be given up deliberately rather than left to be frozen
    /// mid-handshake — which is the state nothing recovers from.
    func holdForListening(_ hold: Bool) {
        guard isListeningHeld != hold else { return }
        isListeningHeld = hold
        if hold {
            suspendTask?.cancel()
            suspendTask = nil
            return
        }
        guard UIApplication.shared.applicationState == .background else { return }
        suspendNow()
    }

    /// Asks iOS to keep the process running for a moment longer.
    ///
    /// The expiry handler is the important half: it runs *before* the process is
    /// frozen, which is the only chance to end the session deliberately rather
    /// than leave a socket that will never carry anything again and a UI that
    /// believes it is connected.
    private func beginBackgroundAssertion() {
        guard backgroundAssertion == .invalid else { return }
        backgroundAssertion = UIApplication.shared.beginBackgroundTask(withName: "mice.session") { [weak self] in
            // iOS calls this on the main thread and expects the task ended
            // before it returns. Hopping through a Task ended it afterwards,
            // if at all, which is the moment a socket the Mac still counts as
            // connected stops being read.
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.isListeningHeld { self.endBackgroundAssertion() }
                else { self.suspendNow() }
            }
        }
    }

    private func endBackgroundAssertion() {
        guard backgroundAssertion != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundAssertion)
        backgroundAssertion = .invalid
    }

    /// Redial the Mac we were on, silently. No code, no picker: back in under a
    /// second or it may as well not reconnect at all.
    ///
    /// Also runs at launch, where the remembered endpoint is dialled without
    /// waiting for Bonjour — which is the only way a Mac reached by address,
    /// over Tailscale or across a VLAN, ever comes back by itself.
    func enterForeground() {
        // Back inside the grace: the connection was never dropped, so there is
        // nothing to redial and nothing on screen to rebuild. Listening counts
        // as held too — it skips the grace entirely and keeps the socket for as
        // long as it is on, which means the same check applies on the way back:
        // a link that was frozen looks exactly like one that was kept.
        let held = suspendTask != nil || isListeningHeld
        suspendTask?.cancel()
        suspendTask = nil
        endBackgroundAssertion()
        isSuspended = false
        reconnectAttempt = 0
        lastActivityAt = Date()
        // A run can block while the app is in the background, and the card for
        // it was dropped with the connection. Ask again rather than come back
        // looking idle.
        refreshApprovals()
        if browsingAllowed { startBrowsing() }
        if held, isLinkBusy {
            if state.isConnected {
                probeHeldConnection()
                upgradeAttempt = 0
                scheduleUpgrade(after: 1, "back in the foreground")
            } else if let target, !handshakeRejected, !autoConnectSuppressed {
                // A handshake started before leaving may point at yesterday's
                // network. Resume should rebuild it, not wait out its deadline.
                reconnect(to: target.host)
            }
            return
        }
        guard !isLinkBusy, !autoConnectSuppressed, !handshakeRejected,
              let pending = target ?? rememberedTarget() else { return }
        // The screen the app was left on is held up for the redial — and its
        // clock starts here, now that there is somebody looking at it.
        if isResuming { holdSurface(true) }
        target = pending
        reconnect(to: pending.host)
    }

    /// The Mac last used, if this phone still holds its key.
    private func rememberedTarget() -> Target? {
        guard let host = rememberedHosts.first, let pin = PhoneTrust.pin(forHost: host.id) else { return nil }
        return Target(host: host, pin: pin)
    }

    /// Joining another network, a VPN coming up or Ethernet being plugged in
    /// leaves any existing connection pointing at an address that no longer
    /// resolves, and produces no Bonjour change to notice it by.
    func networkPathChanged(satisfied: Bool, signature: String, cellularOnly: Bool? = nil) {
        let changed = networkPathSignature.map { $0 != signature } ?? false
        networkPathSignature = signature
        if let cellularOnly { cellularOnlyPath = cellularOnly }
        guard satisfied, !isSuspended, !handshakeRejected, !autoConnectSuppressed,
              let target else { return }
        reconnectAttempt = 0
        if state.isConnected {
            if changed {
                probeHeldConnection()
                // A new network is the likeliest moment for a better route to
                // exist — home Wi-Fi after the relay on 5G — and the moment the
                // last look's answer stopped being true.
                if switchTask == nil { cancelProbes() }
                upgradeAttempt = 0
                scheduleUpgrade(after: 0.8, "the network changed")
            }
            return
        }
        // A new usable path invalidates a dial on the old path. Waiting for
        // its ten-second deadline adds no information about the new network.
        guard !isLinkBusy || changed else { return }
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnect(to: target.host)
    }

    private func remember(_ host: RememberedHost) {
        var hosts = rememberedHosts.filter { $0.id != host.id }
        hosts.insert(host, at: 0)
        rememberedHosts = Array(hosts.prefix(Self.rememberedLimit))
        persistRememberedHosts()
    }

    func forget(_ host: RememberedHost) {
        lastSuccessfulRoutes[host.id] = nil
        rememberedHosts.removeAll { $0.id == host.id }
        persistRememberedHosts()
        // And everything this phone knows about reaching it: the user's word
        // for what they just did is "remove".
        PhoneTrust.forget(hostID: host.id)
    }

    /// Takes the Mac's target list, and keeps a copy.
    ///
    /// The copy is only ever drawn — never acted on. Every tap goes to the Mac by
    /// target id, and the Mac holds the real list; this is what stops the dock
    /// being empty for the second between opening the app and hearing from it.
    private func adopt(_ incoming: [NimletTarget]) {
        targets = incoming
        // The curated half only. A provisional target is a live reading of
        // what was running on the Mac a moment ago — cached and restored on a
        // cold start it becomes a claim about panes that may have closed
        // overnight, drawn as confidently as the targets the user chose. The
        // dock's live half is empty until the Mac says otherwise, which is the
        // honest state for it to start in.
        guard let data = try? NimletCoder.encode(incoming.filter { !$0.isProvisional }) else { return }
        UserDefaults.standard.set(data, forKey: Self.cachedTargetsKey)
    }

    private static func loadCachedTargets() -> [NimletTarget] {
        guard let data = UserDefaults.standard.data(forKey: cachedTargetsKey) else { return [] }
        return (try? NimletCoder.decode([NimletTarget].self, from: data)) ?? []
    }

    private func persistRememberedHosts() {
        guard let data = try? JSONEncoder().encode(rememberedHosts) else { return }
        UserDefaults.standard.set(data, forKey: Self.rememberedKey)
    }

    private static func loadRememberedHosts() -> [RememberedHost] {
        guard let data = UserDefaults.standard.data(forKey: rememberedKey) else { return [] }
        return (try? JSONDecoder().decode([RememberedHost].self, from: data)) ?? []
    }

    /// Generated once and kept. The Mac approves and revokes *devices*, and it
    /// can do neither if every reconnection looks like a stranger.
    private static func loadDeviceID() -> String {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: deviceIDKey), !existing.isEmpty { return existing }
        let created = UUID().uuidString
        defaults.set(created, forKey: deviceIDKey)
        return created
    }

    /// The name that actually goes over the wire. Never empty: the Mac's
    /// approval sheet, its device list and its toasts are all built around
    /// naming the phone being approved, so a blank one there is unanswerable.
    private var helloName: String {
        let trimmed = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultDeviceName : trimmed
    }

    /// Shown as the rename field's placeholder: what the Mac is told if the
    /// user leaves the field empty.
    var defaultDeviceName: String { Self.defaultDeviceName(for: deviceID) }

    private static func loadDeviceName(deviceID: String) -> String {
        let stored = UserDefaults.standard.string(forKey: deviceNameKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let stored, !stored.isEmpty { return stored }
        return defaultDeviceName(for: deviceID)
    }

    /// The hello used to carry `UIDevice.current.name`. Since iOS 16 that is the
    /// *model* name — every phone says "iPhone" — unless the app holds the
    /// user-assigned-device-name entitlement, which needs a special grant from
    /// Apple and which this app does not have. So the Mac was asking the user to
    /// approve one of two identical "iPhone"s, and the README's instruction to
    /// approve by name had nothing to go on.
    ///
    /// Appending a few characters of the device id restores the distinction with
    /// no entitlement at all: the id is per-installation, stable, and already in
    /// the same payload, so the suffix the Mac shows is also the one that
    /// identifies the device it is approving. The user can replace the whole
    /// thing from the connect screen.
    private static func defaultDeviceName(for deviceID: String) -> String {
        let suffix = deviceID.filter(\.isHexDigit).prefix(4).uppercased()
        guard !suffix.isEmpty else { return UIDevice.current.model }
        return "\(UIDevice.current.model) \(suffix)"
    }

    /// `host:port`, with IPv6 in brackets, as a QR code lists them.
    private static func parseAddress(_ raw: String) -> (host: String, port: UInt16)? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        let hostPart: String
        let portPart: Substring
        // An IPv6 literal is full of colons, so it has to be bracketed before
        // the last one can mean "port".
        if text.hasPrefix("["), let close = text.firstIndex(of: "]") {
            hostPart = String(text[text.index(after: text.startIndex)..<close])
            let rest = text[text.index(after: close)...]
            guard rest.hasPrefix(":") else { return nil }
            portPart = rest.dropFirst()
        } else {
            guard let colon = text.lastIndex(of: ":") else { return nil }
            hostPart = String(text[text.startIndex..<colon])
            portPart = text[text.index(after: colon)...]
        }
        guard !hostPart.isEmpty, let port = UInt16(portPart), port > 0 else { return nil }
        return (hostPart, port)
    }

    /// What a link failure means, in words a person can act on.
    private func explain(_ error: NWError, host name: String) -> String {
        if case .posix(let code) = error {
            switch code {
            case .ECONNREFUSED:
                return "\(name) isn't accepting connections — is Nimlet running on it?"
            case .EHOSTUNREACH, .ENETUNREACH, .ENETDOWN, .ETIMEDOUT, .EHOSTDOWN:
                // Only a local-only attempt is about being on the same network.
                if triedReaches.contains(.relay) {
                    return "Can't reach \(name) through the relay — is Nimlet running on it, with Reachable on cellular on?"
                }
                if triedReaches.contains(where: { $0 != .local }) {
                    return "Can't reach \(name) at its internet addresses or on this network"
                }
                return "Can't reach \(name) — this phone and your Mac have to be on the same network"
            case .ECONNRESET, .ENOTCONN, .EPIPE:
                return "\(name) closed the connection"
            default:
                break
            }
        }
        if case .dns(_) = error {
            return "Couldn't find \(name) on this network"
        }
        return error.localizedDescription
    }

    /// A TLS failure about a certificate — the Mac refused this phone's key, or
    /// this phone refused the Mac's — as opposed to a link that broke.
    private static func isCertificateRefusal(_ error: NWError) -> Bool {
        guard case .tls(let status) = error else { return false }
        return [errSSLBadCert, errSSLXCertChainInvalid, errSSLPeerBadCert, errSSLPeerUnsupportedCert,
                errSSLPeerCertRevoked, errSSLPeerCertExpired, errSSLPeerCertUnknown, errSSLPeerUnknownCA,
                errSSLUnknownRootCert, errSSLNoRootCert].contains(status)
    }

    private static func isHandshakeFailure(_ error: NWError) -> Bool {
        if case .tls = error { return true }
        return error.localizedDescription.localizedCaseInsensitiveContains("handshake")
    }

    /// Answered from the TXT record before dialling. Afterwards it is one more
    /// refused handshake.
    private static func versionMismatch(for host: DiscoveredHost) -> String? {
        guard let version = host.version, version != NimletProtocol.version else { return nil }
        return version > NimletProtocol.version
            ? "\(host.name) needs a newer Nimlet on this phone — update it in TestFlight or the App Store"
            : "Nimlet on \(host.name) is too old to talk to this phone — update it on your Mac from nimlet.app/download"
    }

    /// Where the Mac companion is downloaded from. The one address this app
    /// knows besides the Mac's own, and it is only ever *shown*, never fetched.
    static let macDownloadURL = URL(string: "https://nimlet.app/download/")!

    /// The loop is re-armed per connection and carries that connection's own
    /// framer and dial generation. Anything arriving on a connection we have
    /// already abandoned is dropped at the fence rather than applied to whatever
    /// session happens to be current.
    private nonisolated func receiveLoop(on source: NWConnection,
                                         framer: ConnectionFramer,
                                         generation: Int) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            let messages = data.map { framer.messages(from: $0) } ?? []
            // Deliver the final error before EOF, in the same main-actor job.
            // Separate tasks could reconnect first and discard the refusal as
            // an old-generation reply.
            Task { @MainActor in
                guard generation == self.dialGeneration else { return }
                guard self.connection === source else {
                    self.receivedAside(messages, ended: isComplete || error != nil, on: source)
                    return
                }
                for message in messages {
                    guard generation == self.dialGeneration else { return }
                    self.handle(message)
                }
                if isComplete || error != nil {
                    guard generation == self.dialGeneration else { return }
                    if !self.state.isConnected {
                        self.connectionFailed(error ?? .posix(.ECONNRESET))
                    } else {
                        self.dropAndReconnect(error.map { "receive failed: \(String(describing: $0))" }
                                              ?? "the Mac closed the connection")
                    }
                }
            }
            if isComplete || error != nil { return }
            self.receiveLoop(on: source, framer: framer, generation: generation)
        }
    }

    /// What the Mac says about reaching it.
    ///
    /// The addresses replace whatever was held, because the Mac is the only end
    /// that knows which of its own addresses still exist. The reason it cannot
    /// be reached from away, if there is one, is kept for the connection
    /// screen. And the push key is stored only when one was sent: most of these
    /// carry none, and that absence is not a withdrawal.
    private func apply(_ payload: RemoteAccessPayload) {
        guard let host = target?.host ?? rememberedHosts.first else { return }
        if !payload.candidates.isEmpty {
            PhoneTrust.remember(payload.candidates, forHost: host.id)
        }
        PhoneTrust.remember(unavailable: payload.unavailable, forHost: host.id)
        PhoneTrust.remember(awayEnabled: payload.isEnabled, forHost: host.id)
        // What `cellularReadiness` reads is in the defaults, not published.
        objectWillChange.send()
        guard let key = payload.issuedPushKey else { return }
        guard PhoneTrust.remember(pushKey: key, forHost: host.id) else {
            remoteLog.error("push: this phone's Keychain would not store the key")
            showToast("⚠︎ Couldn't store the key for your Mac's notifications")
            return
        }
        remoteLog.info("push: stored a key and \(payload.candidates.count, privacy: .public) addresses")
    }

    private func handle(_ message: HostMessage) {
        switch message {
        case .welcome(let status, let targets):
            sessionBecameReady()
            adopt(targets)
            // After the targets, so the active one can be looked up: a welcome
            // carries both, and asking about the app before its target exists
            // asks about nothing.
            apply(status)
            requestMissingIcons()
            // Whatever is already waiting. A tap on a notification is often
            // what launched the app, and the card it was about was raised
            // while nothing here was listening; without this the sheet opened
            // for it said "Nothing is waiting".
            if status.deviceApproved { refreshApprovals() }
        case .status(let status):
            apply(status)
        case .targets(let targets):
            adopt(targets)
            requestMissingIcons()
            // The shortcut set a target gets depends on what is running in its
            // pane, so the pane list is no longer only for picking one.
            if targets.contains(where: { $0.kind == .tmux }) { requestPanes() }
            // And on what an app publishes, for the one whose buttons are on
            // screen right now.
            requestMenuIfNeeded(for: targets.first { $0.id == activeTargetID })
        case .directAnswer(let candidate, let note):
            answerDirect(candidate, note: note)
        case .relayTunnel(let grant, let note):
            openRelayTunnel(grant, note: note)
        case .remoteAccess(let payload):
            apply(payload)
        case .pairResult(let result):
            paired(result)
        case .toast(let text):
            showToast(text)
        case .error(let text):
            if let rejection = ConnectionRejection(message: text) {
                refuse(rejection == .revoked ? .revoked : .versionMismatch,
                       message: rejection == .revoked
                           ? "This Mac has revoked this device. Approve it again in the Nimlet menu."
                           : text,
                       hostName: target?.host.name ?? "your Mac")
            } else {
                showToast("⚠︎ " + text)
            }
        case .delivered(let receipt):
            lastReceipt = receipt
            // The phone is face down beside the keyboard, so a receipt nobody
            // looks at has to be felt — and a failure must not feel like a
            // success.
            if receipt.ok { Haptics.delivered() } else { Haptics.deliveryFailed() }
            showToast(receipt.message)
        case .agentEvent(let event):
            agentEvents[event.targetID] = event
            // The dot on the tile is for when you are looking. This is for when
            // you are not — which, for an agent that works while you do
            // something else, is most of the time.
            AgentAlerts.shared.report(event,
                                      targetName: targets.first { $0.id == event.targetID }?.name
                                          ?? event.sourceName ?? "Your Mac")
        case .vocabulary(let payload):
            absorb(payload)
        case .approvalRequest(let request):
            absorb(request)
        case .approvalResolved(let resolution):
            let known = approvals.first { $0.id == resolution.requestID }
            approvals.removeAll { $0.id == resolution.requestID }
            // Unconditional, and before the `known` guard: another phone
            // answering is exactly the case where this one is showing a banner
            // for a card it never had on screen.
            AgentAlerts.shared.resolved(approvalID: resolution.requestID)
            // Only when it was on this screen: every phone hears every
            // resolution, including the ones for cards it never showed.
            guard let known else { break }
            switch resolution.reason {
            case .expired:
                showToast(known.returnsToMac ? "Nobody answered — it\u{2019}s waiting on your Mac" : "Nobody answered — denied")
            case .handedBack:
                showToast("Left for \(known.targetName) on your Mac")
            case .answered:
                guard let by = resolution.byDeviceName else { break }
                let verb = known.isQuestion
                    ? (resolution.decision == .approve ? "Answered" : "Declined")
                    : (resolution.decision == .approve ? "Approved" : "Denied")
                showToast("\(verb) on \(by)")
            case .withdrawn, .refused:
                break
            }
        case .uploadReady:
            // Only ever meaningful on an upload socket, which reads its own
            // lines. Arriving here means the Mac answered a question this
            // connection never asked.
            break
        case .panes(let list):
            panes = list
            panesFetchedAt = Date()
            isFetchingPanes = false
        case .appState(let snapshot):
            acceptAppState(snapshot)
        case .appCommandResult(let result):
            acceptAppResult(result)
        case .apps(let payload):
            absorb(payload)
        case .windows(let payload):
            absorb(payload)
        case .menu(let payload):
            absorb(payload)
        case .pendingApprovals(let list):
            // Replaces rather than merges: this is the Mac's whole answer, and
            // anything held here that is not in it is already resolved.
            let wasEmpty = approvals.isEmpty
            approvals = list.sorted { $0.expiresAtEpochMillis < $1.expiresAtEpochMillis }
            if wasEmpty, !approvals.isEmpty { Haptics.attention() }
            // Whatever this phone was showing that is not in the Mac's answer
            // has been decided by somebody, somewhere. A banner still offering
            // Approve and Deny for it is the worst thing this feature can do.
            AgentAlerts.shared.approvalsChanged(to: approvals)
            for request in approvals { AgentAlerts.shared.report(request) }
        case .pong(let nonce, let hostTime):
            lastPongAt = Date()
            if nonce == resumeProbeNonce {
                resumeProbeTask?.cancel()
                resumeProbeTask = nil
                resumeProbeNonce = nil
            }
            guard let sentAt = pendingPings.removeValue(forKey: nonce) else { break }
            let now = Instrumentation.now()
            let millis = Double(now &- sentAt) / 1_000_000
            // Smoothed: a single sample says little about how the link feels.
            roundTripMillis = roundTripMillis.map { $0 + (millis - $0) * 0.3 } ?? millis
            linkStats.add(roundTripMillis: millis)
            recentRoundTrips.append(millis / 1000)
            if recentRoundTrips.count > 20 { recentRoundTrips.removeFirst() }
            // The host replied somewhere in the middle of the round trip; half
            // of it is the best estimate of when, and the usual one.
            let midpoint = sentAt &+ (now &- sentAt) / 2
            let offset = Int64(bitPattern: hostTime) - Int64(bitPattern: midpoint)
            hostClockOffset = hostClockOffset.map { $0 + (offset - $0) / 4 } ?? offset
            Instrumentation.shared.record("rtt", since: sentAt)
        }
    }

    private func absorb(_ request: ApprovalRequest) {
        guard !approvals.contains(where: { $0.id == request.id }) else { return }
        approvals.append(request)
        approvals.sort { $0.expiresAtEpochMillis < $1.expiresAtEpochMillis }
        // The phone is face down beside the keyboard. A card nobody feels
        // arrive is a card that expires into a denial.
        Haptics.attention()
        showToast(request.isQuestion
                  ? "\(request.targetName) has a question"
                  : "\(request.targetName) is asking: \(request.title)")
        // And in a pocket it is not felt either. This is the one event in the
        // app with a deadline attached to it.
        AgentAlerts.shared.report(request)
    }

    /// Sends the answer and takes the card down without waiting for the Mac.
    /// The resolution comes back a moment later and removes nothing, because
    /// this already did.
    func decide(_ id: String, _ decision: ApprovalDecision, reason: String? = nil) {
        decide(id, ApprovalAnswer(decision: decision, reason: reason))
    }

    func decide(_ id: String, _ answer: ApprovalAnswer) {
        guard answer.decision == .deny || answer.handBack || requirePro() else { return }
        let request = approvals.first { $0.id == id }
        guard state.isConnected else {
            // Nothing to send it over, and the Mac will end it on its own
            // clock. Say how, rather than leave a card that does nothing.
            showToast(request?.returnsToMac == true ? "Not connected — it stays on your Mac" : "Not connected — it will deny itself")
            approvals.removeAll { $0.id == id }
            AgentAlerts.shared.resolved(approvalID: id)
            return
        }
        approvals.removeAll { $0.id == id }
        AgentAlerts.shared.resolved(approvalID: id)
        send(.approvalDecision(id: id, decision: answer.decision, reason: answer.reason,
                               answers: answer.answers,
                               alwaysAllow: answer.alwaysAllow ? true : nil,
                               handBack: answer.handBack ? true : nil))
    }

    /// The question or permission prompt a target is waiting on, if any — so a
    /// tap on that target's "waiting for you" can open it.
    func pendingApproval(for targetID: String) -> ApprovalRequest? {
        approvals.first { $0.targetID == targetID }
    }

    /// Targets whose tmux pane the Mac can no longer find. Everything sent to
    /// one of these goes nowhere, so it must not be drawn like the others.
    ///
    /// Stored rather than derived on read: every tile asks, so building the set
    /// in the getter made it O(targets) allocations per target per render.
    @Published private(set) var unresolvedTargetIDs: Set<String> = []

    /// The target that was focused before the one that is focused now.
    ///
    /// Nil until something has actually changed, and it deliberately does not
    /// survive a reconnect: a "back" that goes somewhere you were looking at
    /// yesterday is not a back.
    @Published private(set) var previousTargetID: String?

    /// That target, if the Mac still has it.
    var previousTarget: NimletTarget? {
        guard let previousTargetID, previousTargetID != activeTargetID else { return nil }
        return targets.first { $0.id == previousTargetID }
    }

    /// The live pane behind a target, when the Mac has told us about it.
    /// Panes are only fetched on demand, so this is nil until something asks.
    func pane(for target: NimletTarget) -> TmuxPane? {
        guard target.kind == .tmux, let id = target.tmuxTarget else { return nil }
        return panes.first { $0.id == id }
    }

    /// Fetched only while a pane is being picked. The answer is a snapshot of
    /// something that changes constantly, so it is never held as state to be
    /// kept fresh.
    func requestPanes() {
        guard state.isConnected else { return }
        isFetchingPanes = true
        send(.requestPanes)
    }

    /// Asked for again when something suggests the pane may now be running
    /// something else — a delivery, a focus, a return from the background.
    private func refreshPanesIfStale() {
        guard state.isConnected, !isFetchingPanes else { return }
        guard Date().timeIntervalSince(panesFetchedAt) > 20 else { return }
        panesFetchedAt = Date()
        send(.requestPanes)
    }

    // MARK: - App management

    @Published private(set) var appRuntime: AppRuntimeSnapshot?
    @Published private(set) var appOperation: AppCommandResult?
    /// Only in-flight work needs a status row. Receipts remain internal; failures use a transient toast.
    var appOperationNotice: AppCommandResult? {
        guard let appOperation, appOperation.phase == .working else { return nil }
        return appOperation
    }
    private var appStateRequested = false
    private var appRequestIDs: Set<String> = []
    private var appOperationTimeout: Task<Void, Never>?
    private var appToastRequestID: String?
    var supportsAppManagement: Bool { (status?.appManagementVersion ?? 0) >= 1 }
    var canManageApps: Bool { state.isConnected && status?.deviceApproved == true && supportsAppManagement && appRuntime != nil }

    func requestAppState() {
        guard state.isConnected, supportsAppManagement else { return }
        send(.requestAppState)
    }

    private func acceptAppState(_ snapshot: AppRuntimeSnapshot) {
        if let old = appRuntime {
            if old.hostSessionID == snapshot.hostSessionID, old.revision > snapshot.revision { return }
            if old.hostSessionID != snapshot.hostSessionID {
                appOperationsDisconnected()
                windowRosters.removeAll(); windowPreviews.removeAll(); windowChunks.removeAll()
            }
        }
        remoteLog.info("apps: snapshot session=\(snapshot.hostSessionID, privacy: .public) revision=\(snapshot.revision, privacy: .public) count=\(snapshot.apps.count, privacy: .public)")
        appRuntime = snapshot
    }

    func runningApp(for ref: AppReference) -> RunningMacApp? {
        let matches = appRuntime?.apps.filter { ref.matches($0.identity.app) } ?? []
        return matches.count == 1 ? matches.first : nil
    }

    enum AppRunningState: Equatable { case unknown, notRunning, running }

    /// Process selection must be unique; the running indicator only needs one match.
    func appRunningState(for ref: AppReference) -> AppRunningState {
        guard state.isConnected, let snapshot = appRuntime else { return .unknown }
        return snapshot.apps.contains { ref.matches($0.identity.app) } ? .running : .notRunning
    }

    func appTarget(for ref: AppReference) -> NimletTarget? {
        let matches = targets.filter { $0.appReference?.matches(ref) == true }
        if let exact = matches.first(where: { $0.appReference == ref }) { return exact }
        let copies = appRuntime?.apps.filter { ref.bundleID.caseInsensitiveCompare($0.identity.app.bundleID) == .orderedSame } ?? []
        let copyMatches = copies.first.map { ref.applicationPath == nil || $0.identity.app.applicationPath == ref.applicationPath } ?? true
        return copies.count <= 1 && copyMatches ? matches.first : nil
    }

    func isFavorite(_ ref: AppReference) -> Bool {
        targets.contains { !$0.isProvisional && $0.appReference?.matches(ref) == true }
    }

    func requestAppWindows(_ identity: AppInstanceIdentity) {
        guard canManageApps else { return }
        if let target = appTarget(for: identity.app) { fetchingWindowsFor = target.id }
        send(.requestAppWindows(identity))
    }

    func requestIcons(bundleIDs: [String]) {
        guard state.isConnected else { return }
        let missing = iconStore.missing(from: bundleIDs).filter { requestedIcons.insert($0).inserted }
        if !missing.isEmpty { send(.requestAppIcons(bundleIDs: missing)) }
    }

    @discardableResult func performAppAction(_ action: AppCommand.Action, app: AppReference,
        identity: AppInstanceIdentity? = nil, targetID: String? = nil, windowID: UInt32? = nil) -> Bool {
        guard canManageApps, let snapshot = appRuntime else {
            showToast("Reconnect and refresh the Mac's app state first"); requestAppState(); return false
        }
        if appOperation?.phase == .working {
            showToast("Wait for the current app action to finish"); return false
        }
        clearAppFeedback()
        let command = AppCommand(hostSessionID: snapshot.hostSessionID, action: action, app: app,
            identity: identity, targetID: targetID, windowID: windowID)
        // Requests are never replayed after reconnect. A late receipt may confirm only this request.
        if appRequestIDs.count >= 256 { appRequestIDs.removeAll() }
        appRequestIDs.insert(command.id)
        appOperation = AppCommandResult(requestID: command.id, phase: .working,
            message: action == .activate ? "Opening app on your Mac…" : "Waiting for your Mac…", targetID: targetID)
        remoteLog.info("apps: send request=\(command.id, privacy: .public) action=\(action.rawValue, privacy: .public) session=\(snapshot.hostSessionID, privacy: .public)")
        send(.appCommand(command))
        appOperationTimeout?.cancel()
        appOperationTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled, let self, self.appOperation?.requestID == command.id,
                  self.appOperation?.phase == .working else { return }
            self.appOperation = AppCommandResult(requestID: command.id, phase: .unconfirmed,
                message: "No result received. Refresh and check the Mac before trying again.", targetID: targetID)
            if let result = self.appOperation { self.showAppFeedback(result) }
        }
        return true
    }

    private func acceptAppResult(_ result: AppCommandResult) {
        guard appRequestIDs.contains(result.requestID), appOperation?.requestID == result.requestID else { return }
        // A delayed working receipt cannot overwrite a terminal result.
        if result.phase == .working, appOperation?.phase != .working { return }
        if appOperation == result { return } // Repeated receipts must not revive a dismissed toast.
        remoteLog.info("apps: result request=\(result.requestID, privacy: .public) phase=\(result.phase.rawValue, privacy: .public)")
        appOperation = result
        if result.phase != .working {
            appOperationTimeout?.cancel()
            if result.phase == .succeeded { clearAppFeedback(); Haptics.delivered() }
            else { showAppFeedback(result); Haptics.deliveryFailed() }
        }
    }

    private func appOperationsDisconnected() {
        appOperationTimeout?.cancel()
        if let old = appOperation, old.phase == .working {
            appOperation = AppCommandResult(requestID: old.requestID, phase: .unconfirmed,
                message: "Connection lost. The action may have completed; refresh before trying again.", targetID: old.targetID)
            if let result = appOperation { showAppFeedback(result) }
        }
        appRequestIDs.removeAll()
    }

    private func showAppFeedback(_ result: AppCommandResult) {
        showToast(result.message, duration: .seconds(4))
        appToastRequestID = result.requestID
    }

    private func clearAppFeedback() {
        guard appToastRequestID != nil else { return }
        toastTask?.cancel(); toast = nil; appToastRequestID = nil
    }

    // MARK: - One app's windows

    /// Asked for when the shelf opens, and again when it is pulled to refresh.
    /// Every answer costs the Mac a screenshot per window, so it is never on a
    /// timer.
    func requestWindows(for targetID: String) {
        guard state.isConnected else { return }
        fetchingWindowsFor = targetID
        windowChunks[targetID] = []
        send(.requestWindows(targetID: targetID))
    }

    /// Point a target at one window — or, with nil, let it go back to whichever
    /// window its app puts in front.
    ///
    /// Nothing is applied here. The Mac raises the window first and only pins
    /// it if that worked, then sends the target list back; a phone that moved
    /// its own tile first would be showing a window it never reached.
    func focusWindow(_ windowID: UInt32?, for targetID: String) {
        guard state.isConnected else {
            showToast("Not connected")
            return
        }
        if let windowID, supportsAppManagement {
            guard let target = targets.first(where: { $0.id == targetID }), let ref = target.appReference,
                  let identity = windowRosters[targetID]?.appIdentity else {
                showToast("Refresh the window list first"); requestWindows(for: targetID); return
            }
            performAppAction(.focusWindow, app: ref, identity: identity, targetID: targetID, windowID: windowID)
        } else { send(.focusWindow(targetID: targetID, windowID: windowID)) }
    }

    /// Bring a minimised window back, then point this target at it.
    ///
    /// `windowID` nil means whichever window the target is already pinned to —
    /// the mirror's case, where the window being watched got minimised and
    /// there is nothing to pick from.
    func openWindow(_ windowID: UInt32?, for targetID: String) {
        guard state.isConnected else {
            showToast("Not connected")
            return
        }
        if supportsAppManagement {
            guard let target = targets.first(where: { $0.id == targetID }), let ref = target.appReference,
                  let id = windowID ?? target.pinnedWindowID,
                  let identity = windowRosters[targetID]?.appIdentity ?? runningApp(for: ref)?.identity else {
                showToast("Refresh the window list first"); requestWindows(for: targetID); return
            }
            performAppAction(.restoreWindow, app: ref, identity: identity, targetID: targetID, windowID: id)
        } else { send(.openWindow(targetID: targetID, windowID: windowID)) }
    }

    func windowRoster(for targetID: String) -> WindowRoster? { windowRosters[targetID] }

    func preview(of window: MacWindow) -> UIImage? { windowPreviews[window.id] }

    /// The window a target is pointed at, if any. Read off the target itself,
    /// which is the Mac's copy — so it cannot disagree with what the Mac will
    /// actually deliver to.
    func pinnedWindow(of target: NimletTarget) -> (id: UInt32, title: String)? {
        guard let id = target.pinnedWindowID else { return nil }
        return (id, target.pinnedWindowTitle ?? "")
    }

    private func absorb(_ payload: WindowListPayload) {
        let unsolicited = fetchingWindowsFor != payload.targetID
        for window in payload.windows {
            guard let data = window.preview, let image = UIImage(data: data) else { continue }
            windowPreviews[window.id] = image
        }
        if payload.sequence == 0 { windowChunks[payload.targetID] = [] }
        windowChunks[payload.targetID, default: []].append(contentsOf: payload.windows)
        // The note rides the first chunk, and the list is only usable whole.
        if payload.sequence == 0, let note = payload.note {
            windowRosters[payload.targetID, default: WindowRoster()].note = note
        }
        guard payload.isFinal else { return }
        let windows = windowChunks.removeValue(forKey: payload.targetID) ?? []
        let note = payload.sequence == 0 ? payload.note : windowRosters[payload.targetID]?.note
        windowRosters[payload.targetID] = WindowRoster(windows: windows, note: note, appIdentity: payload.appIdentity)
        if fetchingWindowsFor == payload.targetID { fetchingWindowsFor = nil }
        // Nobody asked for this list, which means the Mac is answering a tap
        // that could not be honoured. Open the shelf on what is actually there.
        if unsolicited, let target = targets.first(where: { $0.id == payload.targetID }),
           let pinned = target.pinnedWindowID,
           !windows.contains(where: { $0.id == pinned && !$0.isMinimized }) {
            shelfRequestID = payload.targetID
        }
        // Previews of windows that are no longer listed are pictures of
        // something that is gone.
        let live = Set(windows.map(\.id))
        let kept = Set(windowRosters.values.flatMap { $0.windows.map(\.id) }).union(live)
        windowPreviews = windowPreviews.filter { kept.contains($0.key) }
    }

    // MARK: - The Mac's applications

    /// Asked for while the picker is open. The Mac scans its applications
    /// folders and renders an icon each, which is disk work it should not be
    /// doing on a connection nobody is choosing an app on.
    func requestApps(refresh: Bool = false) {
        guard state.isConnected else { return }
        isFetchingApps = true
        if refresh { appSuggestions = [] }
        appChunks = []
        send(supportsAppManagement ? .requestAppDirectory(refresh: refresh) : .requestApps(refresh: refresh))
    }

    /// Dropped when the picker closes: a list of what is installed on a Mac
    /// goes out of date the moment somebody installs something, and holding it
    /// would mean opening the picker a day later shows yesterday's disk while
    /// it asks about today's.
    func forgetApps() {
        appSuggestions = []
        appChunks = []
        isFetchingApps = false
    }

    /// The icons of the app targets already in the dock, for the ones this
    /// phone cannot draw yet.
    private func requestMissingIcons() {
        guard state.isConnected else { return }
        let wanted = targets.filter { $0.kind == .app }.compactMap(\.bundleID)
        requestIcons(bundleIDs: wanted)
    }

    private func absorb(_ payload: AppCatalogPayload) {
        if iconStore.absorb(payload.apps) { appIcons = iconStore.images }
        // An icon set changes the pictures and nothing else. Letting it touch
        // the suggestion list would empty the picker every time a target was
        // added while it was open.
        guard payload.purpose == .suggestions else { return }
        if payload.sequence == 0 { appChunks = [] }
        appChunks.append(contentsOf: payload.apps)
        guard payload.isFinal else { return }
        appSuggestions = appChunks
        appChunks = []
        isFetchingApps = false
    }

    /// The icon the Mac sent for this app, if it ever did.
    func icon(for target: NimletTarget) -> UIImage? {
        guard target.kind == .app, let bundleID = target.bundleID else { return nil }
        return appIcons[bundleID.lowercased()]
    }

    func icon(for app: MacApp) -> UIImage? { appIcons[app.bundleID.lowercased()] }

    /// How much bigger than its canvas that icon has to be drawn to look the
    /// size of the glyph tile beside it. See `AppIconStore.contentScale`.
    func iconScale(for target: NimletTarget) -> CGFloat {
        guard target.kind == .app else { return 1 }
        return iconStore.contentScale(for: target.bundleID)
    }

    func updateTarget(_ target: NimletTarget) { send(.updateTarget(target)) }

    func removeTarget(_ id: String) { send(.removeTarget(id: id)) }

    private static let dockArrangementsKey = "mice.dock.arrangements"
    private var dockHostKey: String { target?.host.id ?? rememberedHosts.first?.id ?? "unpaired" }
    private var dockArrangement: PhoneDockArrangement { dockArrangements[dockHostKey] ?? PhoneDockArrangement() }
    var dockTargets: [NimletTarget] { dockArrangement.visibleTargets(in: targets) }

    func isDockFavorite(_ app: AppReference) -> Bool {
        isFavorite(app) && !dockArrangement.isHidden(app)
    }

    func removeFromDock(_ tile: NimletTarget) {
        guard let app = tile.appReference else { removeTarget(tile.id); return }
        if !tile.isProvisional {
            if supportsAppManagement {
                guard performAppAction(.unkeep, app: app, targetID: tile.id) else { return }
            } else { removeTarget(tile.id) }
        }
        editDock { $0.hide(app) }
    }

    func toggleDockFavorite(_ app: AppReference) {
        if isDockFavorite(app), let tile = appTarget(for: app) {
            removeFromDock(tile)
        } else if performAppAction(.keep, app: app, targetID: appTarget(for: app)?.id) {
            editDock { $0.show(app) }
        }
    }

    /// Includes live apps: layout is a phone preference, independent of Mac favorites.
    func reorderDockTargets(_ ids: [String]) {
        let visible = dockTargets
        guard ids.count == visible.count, Set(ids) == Set(visible.map(\.id)) else { return }
        let byID = Dictionary(visible.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        editDock { $0.order = ids.compactMap { byID[$0] }.map(PhoneDockArrangement.key(for:)) }
    }

    private func editDock(_ edit: (inout PhoneDockArrangement) -> Void) {
        var arrangement = dockArrangement
        edit(&arrangement)
        dockArrangements[dockHostKey] = arrangement
        if let data = try? JSONEncoder().encode(dockArrangements) {
            UserDefaults.standard.set(data, forKey: Self.dockArrangementsKey)
        }
    }

    private static func loadDockArrangements() -> [String: PhoneDockArrangement] {
        guard let data = UserDefaults.standard.data(forKey: dockArrangementsKey),
              let layouts = try? JSONDecoder().decode([String: PhoneDockArrangement].self, from: data) else { return [:] }
        return layouts
    }

    /// The dock's order, which is the target list's order.
    ///
    /// Applied here as well as sent, so the tile follows the finger rather than
    /// waiting out a round trip to the Mac and back.
    /// Rearranges the curated half of the dock, leaving the live half where it
    /// is.
    ///
    /// `ids` carries only the targets the Mac has stored, because those are the
    /// only ones an order can be persisted for. The count check is against that
    /// half for the same reason: comparing it to the whole list — curated plus
    /// whatever happens to be running — made every drag a no-op the moment one
    /// provisional tile appeared, silently, because the guard is the only thing
    /// that reports it.
    func reorderTargets(_ ids: [String]) {
        var byID: [String: NimletTarget] = [:]
        for target in targets { byID[target.id] = target }
        let reordered = ids.compactMap { byID[$0] }
        let offered = targets.filter(\.isProvisional)
        guard reordered.count == targets.count - offered.count else { return }
        adopt(reordered + offered)
        send(.reorderTargets(ids: ids))
    }

    func addTarget(_ target: NimletTarget) { send(.addTarget(target)) }

    /// Everything ticked in the picker, in one message. The Mac replies with
    /// one toast and one refusal rather than a stream of both.
    func addTargets(_ targets: [NimletTarget]) {
        guard !targets.isEmpty else { return }
        send(.addTargets(targets))
    }

    /// Asked for after a reconnect or a return from the background, so a run
    /// that blocked while the app was away is not waiting in silence.
    func refreshApprovals() {
        guard state.isConnected else { return }
        send(.requestPendingApprovals)
    }

    /// Drops what the Mac has already given up on. The host sends a resolution
    /// for every expiry, but only over a connection that is still up.
    private func pruneExpiredApprovals() {
        let now = ApprovalClock.now()
        let expired = approvals.filter { $0.isExpired(at: now) }
        guard !expired.isEmpty else { return }
        approvals.removeAll { $0.isExpired(at: now) }
        // The Mac sends a resolution for every expiry, but only over a
        // connection that is still up. This is the same sweep for the lock
        // screen: a card that has run out is a denial already, and its banner
        // must not sit there inviting an answer that cannot land.
        AgentAlerts.shared.approvalsChanged(to: approvals)
    }

    private func apply(_ status: HostStatus) {
        let wasApproved = self.status?.deviceApproved ?? false
        if self.status == nil || wasApproved != status.deviceApproved {
            remoteLog.info("host status: approved=\(status.deviceApproved, privacy: .public) inputPaused=\(status.injectionPaused, privacy: .public)")
        }
        // Whatever was focused before this report, kept so the dock can offer
        // the one switch macOS makes a reflex and this app had no answer for.
        //
        // The commonest move in any session is A → B → A: look at the other
        // thing, come back. On a Mac that is Command-Tab, which is ordered by
        // recency precisely so the toggle costs nothing. Nimlet had no recency
        // anywhere — no most-recent list, no back — so coming back meant
        // finding the tile again in a row that scrolls.
        if let incoming = status.activeTargetID,
           let current = self.status?.activeTargetID,
           incoming != current {
            previousTargetID = current
        }
        self.status = status
        unresolvedTargetIDs = Set(status.unresolvedTargetIDs)
        // The moment the user said yes on the Mac. The away addresses and this
        // phone's key went out with the welcome, before the answer existed, so
        // they were sent to a device that was not yet allowed to have them —
        // which is right, and means asking again now.
        if status.deviceApproved, !wasApproved {
            send(.requestRemoteAccess)
            refreshApprovals()
        }
        // On every status that says this phone is allowed, not only on the
        // transition. A reconnect produces one of these and no transition, and
        // a reconnect is exactly when the Mac's copy of the token and the rules
        // needs refreshing — it may have been restarted since, and it clears
        // what it knew about a phone the moment that phone arrives.
        if status.deviceApproved {
            sendPushRegistration()
            if supportsAppManagement, !appStateRequested {
                appStateRequested = true
                requestAppState()
            }
        }
        if let active = status.activeTargetID {
            requestVocabularyIfNeeded(for: active)
            requestMenuIfNeeded(for: targets.first { $0.id == active })
        }
    }

    /// Lets the voice layer report into the same toast strip the Mac uses, so a
    /// speech failure is readable rather than just a buzz.
    func note(_ text: String) { showToast(text) }

    /// Set when a Pro feature was asked for without Pro; the root view shows
    /// the purchase sheet off it.
    @Published var showingPro = false

    /// The one gate for Pro features. Says no by offering the purchase, never
    /// silently, so a tap that does nothing is never the answer.
    @discardableResult
    func requirePro() -> Bool {
        guard hasProAccess else {
            showingPro = true
            return false
        }
        return true
    }

    private func showToast(_ text: String, duration: Duration = .seconds(2.4)) {
        appToastRequestID = nil
        toast = text
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.toast = nil
            self?.appToastRequestID = nil
        }
    }

    /// Chunks only become usable as a set, so they are held aside until the
    /// final one lands rather than biasing dictation with half a repository.
    private func absorb(_ payload: VocabularyPayload) {
        if payload.sequence == 0 { vocabularyChunks[payload.targetID] = [] }
        vocabularyChunks[payload.targetID, default: []].append(contentsOf: payload.terms)
        guard payload.isFinal else { return }
        vocabularies[payload.targetID] = vocabularyChunks.removeValue(forKey: payload.targetID) ?? []
        vocabularyFetchedAt[payload.targetID] = Date()
        requestedVocabulary.remove(payload.targetID)
    }

    func vocabulary(for targetID: String) -> [String] { vocabularies[targetID] ?? [] }

    /// Asked for when the active target changes: the words dictation gets wrong
    /// are a project's own identifiers, and they differ per target.
    ///
    /// A set that has arrived is re-asked for once it is older than
    /// `vocabularyLifetime`, and unconditionally on a new connection, because
    /// the previous rule — ask once, keep forever — meant a phone that stayed
    /// open across a branch switch was biased toward identifiers the repository
    /// no longer contained, with nothing able to correct it short of a relaunch.
    func requestVocabularyIfNeeded(for targetID: String) {
        guard state.isConnected else { return }
        if let fetchedAt = vocabularyFetchedAt[targetID],
           Date().timeIntervalSince(fetchedAt) < Self.vocabularyLifetime { return }
        // Still in flight on this connection: asking twice would only duplicate
        // the chunks.
        guard requestedVocabulary.insert(targetID).inserted else { return }
        send(.requestVocabulary(targetID: targetID))
    }

    func focus(_ targetID: String) {
        clearAppFeedback()
        if supportsAppManagement, let target = targets.first(where: { $0.id == targetID }), let ref = target.appReference {
            performAppAction(.activate, app: ref, targetID: targetID)
        } else { send(.focus(targetID: targetID)) }
        requestVocabularyIfNeeded(for: targetID)
        requestMenuIfNeeded(for: targets.first { $0.id == targetID })
        // Looking at a target is the moment its buttons are about to be used,
        // and what is running in its pane decides which buttons those are.
        refreshPanesIfStale()
    }

    func lastEvent(for targetID: String) -> AgentEvent? { agentEvents[targetID] }

    /// Tells the Mac how to reach this phone while it is asleep, and what to
    /// bother it with when it does.
    ///
    /// Sent on connecting, on being approved, and whenever a notification
    /// setting changes — all three, because all three change the answer and
    /// none of them implies the others. Cheap enough to repeat: one short line
    /// on a socket that is already open.
    func sendPushRegistration() {
        guard state.isConnected, status?.deviceApproved == true else { return }
        send(.registerPush(AgentAlerts.shared.registration))
    }

    // MARK: - Sending

    private func startPinging() {
        pingTimer?.invalidate()
        let interval = isIdle ? Self.idlePingInterval : Self.activePingInterval
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pingTimer = timer
    }

    private func tick() {
        pruneExpiredApprovals()
        let wasIdle = isIdle
        isIdle = state.isConnected && pressedButtons.isEmpty
            && Date().timeIntervalSince(lastActivityAt) > Self.idleAfter
        if isIdle != wasIdle { startPinging() }

        // A Mac that has gone to sleep, or a Wi-Fi drop that never reaches TCP,
        // leaves a connection that looks fine and answers nothing. Unanswered
        // pings are the only evidence there is.
        let timeout = isIdle ? Self.pongTimeout : RoutePolicy.pongTimeout(for: currentRouteClass)
        if state.isConnected, resumeProbeNonce == nil, let lastPongAt,
           Date().timeIntervalSince(lastPongAt) > timeout {
            dropAndReconnect("no pong for \(Int(timeout))s")
            return
        }
        sendPing()
    }

    /// A single foreground check is cheaper than tearing down a healthy TLS
    /// session, and faster than waiting for the normal idle watchdog.
    private func probeHeldConnection() {
        resumeProbeTask?.cancel()
        let generation = dialGeneration
        resumeProbeNonce = sendPing()
        resumeProbeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(RoutePolicy.healthCheckTimeout(for: self?.currentRouteClass ?? .lan)))
            guard !Task.isCancelled, let self, generation == self.dialGeneration,
                  self.resumeProbeNonce != nil, self.state.isConnected else { return }
            self.dropAndReconnect("foreground health check did not answer")
        }
    }

    @discardableResult
    private func sendPing() -> UInt64 {
        pingNonce &+= 1
        let nonce = pingNonce
        pendingPings[nonce] = Instrumentation.now()
        // Don't let unanswered pings accumulate on a flaky link.
        if pendingPings.count > 10 {
            let oldest = pendingPings.keys.sorted().prefix(pendingPings.count - 10)
            oldest.forEach { pendingPings.removeValue(forKey: $0) }
        }
        send(.ping(nonce: nonce))
        return nonce
    }

    /// Anything the user originated counts as the surface being in use. A phone
    /// that runs hot and flat all afternoon is how testers quietly stop picking
    /// it up, so what costs power is scoped to a surface someone is touching.
    private func noteActivity() {
        lastActivityAt = Date()
        guard isIdle else { return }
        isIdle = false
        startPinging()
        // The last idle response may be up to five seconds old. Check now
        // rather than treating its age as evidence that this live link died.
        if state.isConnected { probeHeldConnection() }
    }

    func send(_ message: ClientMessage) {
        if ProAccessPolicy.requiresPro(message, targets: targets), !hasProAccess {
            if ProAccessPolicy.offersUpgrade(for: message) { showingPro = true }
            return
        }
        if case .ping = message {} else { noteActivity() }
        // What must not be reordered by a switch is input — a click must land
        // where the moves before it put the pointer. Requests and reports can
        // cross sockets freely; counting them held the first switch of every
        // session behind the burst of requests a session starts with.
        switch message {
        case .click, .scroll, .scrollPhase, .key, .text, .pointAtPanel, .focus, .reshapePanel:
            lastOrderedInputAt = Date()
        default:
            break
        }
        guard let connection else { return }
        switch message {
        case .hello: helloSent = true
        case .pair: break
        default: if !helloSent { return }
        }
        if case .click(let button, let phase, _) = message {
            if phase == .down { pressedButtons.insert(button) } else { pressedButtons.remove(button) }
        }
        guard let data = try? NimletCoder.line(message) else { return }
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    /// Called once per touch frame with that frame's accumulated delta.
    func sendMove(dx: Double, dy: Double) {
        lastPointerDriveAt = Date()
        guard abs(dx) >= 0.01 || abs(dy) >= 0.01 else { return }
        let now = Instrumentation.now()
        if lastSendAt != 0 { Instrumentation.shared.record("send_interval", since: lastSendAt) }
        lastSendAt = now

        let sendStart = Instrumentation.now()
        send(.move(dx: dx, dy: dy))
        Instrumentation.shared.record("send_call", since: sendStart)
    }

    func sendScroll(dx: Double, dy: Double) {
        guard abs(dx) >= 0.5 || abs(dy) >= 0.5 else { return }
        send(.scroll(dx: dx, dy: dy))
    }

    /// Marks the start and end of a scroll, and of the coast after a flick, so
    /// the Mac can stamp its events with a phase.
    func sendScroll(phase: ScrollGesturePhase) {
        send(.scrollPhase(phase))
    }

    /// Whether the pointer has been moved from this phone recently enough that
    /// it is still fair to call it "the one you are driving".
    ///
    /// The zoomed mirror follows the cursor, and should follow it only while the
    /// cursor is this phone's. A pointer moved at the Mac, or warped by an
    /// application, is news rather than intent.
    var isDrivingPointer: Bool {
        Date().timeIntervalSince(lastPointerDriveAt) < 1.5
    }

    private var lastPointerDriveAt = Date.distantPast

    /// Put the pointer at this spot in the window being mirrored.
    ///
    /// - Parameter shownGeneration: which window's picture the finger was on,
    ///   from the frame on the glass. Nil before a frame from a Mac that
    ///   numbers them; that Mac then judges by timing instead.
    func sendPanelPoint(_ point: CGPoint, shownGeneration: Int? = nil) {
        lastPointerDriveAt = Date()
        guard point.x.isFinite, point.y.isFinite else { return }
        send(.pointAtPanel(x: Double(min(max(point.x, 0), 1)),
                           y: Double(min(max(point.y, 0), 1)),
                           generation: shownGeneration))
    }

    /// Sends one key to each selected target.
    ///
    /// Addressed, like text. A key used to be posted at whatever had keyboard
    /// focus on the Mac, which for the pane targets this app is built around
    /// meant Escape reached whatever window happened to be in front instead of
    /// the agent whose name was lit up on this screen.
    func sendKey(_ chord: KeyChord, to targetIDs: [String]) {
        for targetID in targetIDs {
            send(.key(KeyPayload(chord: chord, targetID: targetID)))
        }
    }

    /// Which set of buttons a target gets.
    ///
    /// Resolved here rather than stored on the Mac so it follows what is
    /// actually there: a pane that was a shell this morning and is running an
    /// agent now should offer the agent's keys without anybody editing
    /// anything, and an app should offer the keys it publishes today.
    ///
    /// Three answers, in order. A set pinned by hand wins over everything —
    /// that is what pinning is for, and it is the way out of a bad read. Then
    /// the app's own menu bar, which is the only source that can be right about
    /// keys somebody has rebound, or about an app nobody ever wrote a set for.
    /// Then the curated guess, which is what is left when the app is not
    /// running or its menus say nothing useful.
    func shortcuts(for target: NimletTarget) -> ShortcutProfile {
        if let pinned = ShortcutProfiles.profile(id: target.profileID) { return pinned }
        if let discovered = discoveredShortcuts(for: target) { return discovered }
        return ShortcutProfiles.resolved(for: target, paneCommand: pane(for: target)?.command)
    }

    /// What the app itself published, if the Mac has read it.
    func discoveredShortcuts(for target: NimletTarget) -> ShortcutProfile? {
        guard target.kind == .app, let bundleID = target.bundleID else { return nil }
        return menuProfiles[bundleID.lowercased()]
    }

    /// The Mac's last word on that app's menus, whether or not it could read
    /// them. Shown in the target's settings, where "why is this row the plain
    /// one?" is the question being asked.
    func menuReading(for target: NimletTarget) -> MenuProfilePayload? {
        guard target.kind == .app, let bundleID = target.bundleID else { return nil }
        return menuNotes[bundleID.lowercased()]
    }

    private func absorb(_ payload: MenuProfilePayload) {
        let key = payload.bundleID.lowercased()
        menuNotes[key] = payload
        // A failed read does not erase a set read earlier: the app being quit
        // right now is not a reason to take its buttons away, and the keys it
        // published have not changed by being closed.
        if let profile = payload.profile { menuProfiles[key] = profile }
        requestedMenus.remove(key)
    }

    /// Asked for when a target is about to be used, and only for an app: it is
    /// the moment its buttons are about to be looked at, and the answer is
    /// cheap to keep once it arrives.
    func requestMenuIfNeeded(for target: NimletTarget?) {
        guard let target, target.kind == .app, let bundleID = target.bundleID,
              !bundleID.isEmpty, state.isConnected else { return }
        let key = bundleID.lowercased()
        // Already read, or already asked on this connection.
        guard menuProfiles[key] == nil, !requestedMenus.contains(key) else { return }
        // An app that was not running when we asked is worth asking about again
        // — it may be running now — but not on every single focus.
        if let note = menuNotes[key], note.outcome == .unreadable { return }
        requestedMenus.insert(key)
        send(.requestMenu(bundleID: bundleID, refresh: false))
    }

    /// Reads them again from scratch, for somebody who has just rebound a key
    /// and wants the row to catch up.
    func refreshMenu(for target: NimletTarget) {
        guard target.kind == .app, let bundleID = target.bundleID, !bundleID.isEmpty,
              state.isConnected else { return }
        requestedMenus.insert(bundleID.lowercased())
        send(.requestMenu(bundleID: bundleID, refresh: true))
    }

    /// Delivers one phrase to several targets at once.
    func sendText(_ text: String, to targetIDs: [String]) {
        guard requirePro() else { return }
        for targetID in targetIDs {
            send(.text(TextPayload(text: text, targetID: targetID)))
        }
    }

    // MARK: - Attachments

    /// Sends images to each target, with whatever was typed alongside them.
    ///
    /// The bytes go on a socket of their own and the caption travels with them,
    /// so the whole thing lands as one delivery rather than as a sentence that
    /// runs before the pictures it refers to have been written.
    func upload(_ attachments: [ImageAttachment],
                caption: String,
                to targetIDs: [String],
                submit: Bool?,
                follow: KeyChord? = nil) {
        guard !attachments.isEmpty, !targetIDs.isEmpty, requirePro() else { return }
        guard let session, let parameters = session.parameters else {
            showToast("⚠︎ Not connected to a Mac")
            return
        }
        let manifest = AttachmentManifest(deviceName: helloName,
                                          deviceID: deviceID,
                                          targetIDs: targetIDs,
                                          text: caption,
                                          submit: submit,
                                          count: attachments.count,
                                          followChord: follow)
        let uploader = AttachmentUploader(
            manifest: manifest,
            attachments: attachments,
            endpoint: session.endpoint,
            parameters: parameters,
            onMessage: { [weak self] message in self?.handle(message) },
            onFinish: { [weak self] id, outcome in
                guard let self else { return }
                self.uploads[id] = nil
                // A failure that produced no receipt has to say something: the
                // haptic the receipt would have fired is the only other signal,
                // and silence reads as a slow agent.
                if case .failed(let reason) = outcome, self.lastReceipt?.ok != true {
                    self.showToast("⚠︎ " + reason)
                    Haptics.deliveryFailed()
                }
            })
        // Held here rather than by the view: the compose sheet is dismissed the
        // moment Send is tapped, and an uploader owned by it would be released
        // mid-photograph.
        uploads[uploader.id] = uploader
        uploader.start()
        let count = attachments.count
        showToast("Sending \(count) image\(count == 1 ? "" : "s")…")
    }

    /// Asks the Mac for a picture of that target's screen, to be drawn on.
    ///
    /// A window for an app target, the display the pointer is on for a pane —
    /// panes live inside a terminal Nimlet has no handle on, and somebody circling
    /// something on their monitor means the monitor.
    func fetchStill(for targetID: String, completion: @escaping (Result<Still, StillProblem>) -> Void) {
        guard requirePro() else {
            completion(.failure(StillProblem(message: "Screen capture and annotation require Nimlet Pro.")))
            return
        }
        guard let session, let parameters = session.parameters else {
            completion(.failure(StillProblem(message: "Not connected to a Mac")))
            return
        }
        let fetcher = StillFetcher(
            request: StillRequest(deviceName: helloName, deviceID: deviceID, targetID: targetID),
            endpoint: session.endpoint,
            parameters: parameters,
            onResult: completion,
            onFinish: { [weak self] id in self?.stills[id] = nil })
        stills[fetcher.id] = fetcher
        fetcher.start()
    }
}
