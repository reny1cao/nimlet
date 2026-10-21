import Foundation
import Network
import AppKit
import Combine
import OSLog

/// `log stream --predicate 'subsystem == "com.renyicao.mice"'` to watch events
/// land. Worth having: when nothing happens on screen, the question is always
/// "is it the network or the Accessibility grant?", and this answers it.
let miceLog = Logger(subsystem: "com.renyicao.mice", category: "host")

/// Bonjour listener + message pump. One instance owns every connected phone.
final class HostServer: ObservableObject {
    static let shared = HostServer()

    /// A phone that has said hello, as the menu bar shows it.
    struct ConnectedDevice: Identifiable, Hashable {
        var id: String
        var name: String
        var approved: Bool
        /// Whether this phone has a listen socket open, so the menu can say that
        /// this Mac is being heard. The recording indicator in the menu bar says
        /// something *is* capturing; this says who is getting it.
        var isHearing = false
        /// The link its control socket arrived over, for diagnostics.
        var route = ""
    }

    @Published private(set) var isListening = false
    @Published private(set) var connectedDevices: [ConnectedDevice] = []
    /// Who has knocked with the pairing code and not been answered, kept after
    /// the socket closes. The nimlet tool connects for a moment per command, so
    /// in `connectedDevices` it was there and gone before anyone could click
    /// Approve. Phones never land here: an unknown key fails the handshake.
    @Published private(set) var awaitingApproval: [ConnectedDevice] = []
    @Published private(set) var lastError: String?
    @Published private(set) var lastActivity: String?

    /// A phone that was refused for speaking a newer protocol than this Mac.
    ///
    /// The phone updates itself through TestFlight while the Mac companion is
    /// updated by hand, so this Mac is usually the end that is behind. Shown in
    /// the menu with where to get the update, because nothing else on the Mac
    /// would ever say so.
    struct NewerPhone: Equatable {
        var name: String
        var protocolVersion: Int
    }
    @Published private(set) var newerPhone: NewerPhone?

    /// Each phone holds a control socket and a panel socket, and a listen,
    /// upload or screenshot socket while it is using one. Leave room for a
    /// second phone or simulator beside a phone that is away.
    private static let maxConnections = 12
    /// How many of those may have arrived over the away listener — directly
    /// or through the relay — at once. Its own budget, so that somebody who
    /// can reach the away port, or the relay, cannot fill every slot and queue
    /// the phone at the desk behind them. One away phone needs at most five.
    private static let maxAwayConnections = 6
    /// Two wrong codes are a typo; the third starts costing time.
    private static let failuresBeforeLockout = 3
    private static let maxLockout: TimeInterval = 300
    /// A real client says hello immediately after the handshake.
    private static let helloDeadline: TimeInterval = 10

    /// Only ever touched on `queue`. It used to be assigned on main by `start`
    /// and cleared on main by `stop` — outside that method's own `queue.sync`
    /// block — while `refreshConnectionLimit` dereferenced it on the network
    /// queue for every accept, disconnect and hello.
    private var listener: NWListener?
    /// The internet-facing one. Its own listener on its own port, holding one
    /// 256-bit key per approved device and no pairing code at all — so nothing
    /// that reaches it can be let in by knowing the six characters in the menu
    /// bar, and a device whose key has been dropped is refused by the handshake
    /// rather than after it. Nil unless the user has switched away access on.
    private var awayListener: RecoveringListener?
    private var awayListenerPort: UInt16?
    /// The LAN listener for phones paired by key: TLS 1.3, both ends pin the
    /// other's key, and an unknown key gets in only while a pairing invitation
    /// is open, to say `pair` and nothing else. Beside the pairing-code
    /// listener rather than instead of it, until every phone has paired again.
    private var trustListener: RecoveringListener?
    private var pairingCode = ""
    /// Accepted but not yet identified, kept apart from `clients`. Registering
    /// every connection the moment it arrived meant anything that opened a
    /// socket and stopped there accumulated without bound.
    private var pending: [ObjectIdentifier: Client] = [:]
    private var clients: [ObjectIdentifier: Client] = [:]
    private var throttles: [String: Throttle] = [:]
    private let queue = DispatchQueue(label: "com.renyicao.mice.host.net")
    /// Text delivery sleeps between steps; it must never do that on the network
    /// queue (it would stall pointer events) or on main (it would freeze the UI).
    private let injectionQueue = DispatchQueue(label: "com.renyicao.mice.host.inject")
    /// The newest shape a phone has asked the mirrored window to take. Held
    /// rather than queued, so a drag that outruns Accessibility applies its
    /// last shape and skips the ones in between.
    private let reshapeLock = NSLock()
    private var pendingReshape: CGFloat?
    /// Reading another app's menu bar is hundreds of round trips into a process
    /// that may be busy, so it gets a queue of its own: not the network one,
    /// which carries pointer moves, and not the injection one, which is what
    /// the keystroke after it is waiting on.
    private let menuQueue = DispatchQueue(label: "com.renyicao.mice.host.menu", qos: .utility)
    /// Scanning the applications folders and rendering their icons, for the
    /// same reason: it is hundreds of milliseconds of disk on a first run, and
    /// a phone asking for the app list must not delay the pointer of the phone
    /// beside it.
    private let catalogQueue = DispatchQueue(label: "com.renyicao.mice.host.apps", qos: .utility)
    private var cancellables = Set<AnyCancellable>()
    private var appCommands = AppCommandLedger()
    private var pathMonitor: NWPathMonitor?
    private var knownInterfaces: Set<String>?

    private final class Client {
        let connection: NWConnection
        /// Peer address without the port, for throttling.
        let source: String
        var framer = LineFramer()
        var name = "iPhone"
        var deviceID: String?
        var didHello = false
        var appManagementRequested = false
        /// What this phone in particular is holding down.
        var heldButtons: Set<MouseButton> = []
        /// Which of its clicks may reach the Mac. See `InputGuard`.
        var input = InputGuard()
        /// Moves read in this batch and not yet injected. See `MoveAccumulator`.
        var pendingMove = MoveAccumulator()
        /// The direct-path probe this phone asked for, while it runs.
        var directProbe: DirectProbe?
        /// When anything last arrived on this socket, for letting go of what a
        /// phone that has gone quiet was holding.
        var lastHeardAt = Date()
        /// Which link this socket arrived over — "Wi-Fi", "AWDL", "VPN" — for
        /// diagnostics. Which one is in use is otherwise invisible.
        var route = "?"
        var lastRefusal = Date.distantPast
        var lastSwitchingNote = Date.distantPast
        /// Approval requests this connection is blocked on. When it goes away,
        /// so do they: an answer with nobody left to hear it is worse than
        /// nothing, because it stays on every phone's screen.
        var approvalIDs: Set<String> = []
        /// A viewer connection stops being a control client the moment it says
        /// so: from then on the socket carries binary frames the other way.
        var isViewChannel = false
        /// And a listener carries the Mac's own audio the same way. Its own flag
        /// rather than a shared "not a control channel" one, because the two are
        /// torn down by different owners.
        var isListenChannel = false
        /// And an upload connection carries them *this* way. Set from the moment
        /// the manifest is accepted, which is also when this socket's framing
        /// changes from newline-delimited to length-prefixed.
        var upload: UploadSession?
        /// A socket that asked for one screenshot and will be closed once it has
        /// it. Reads nothing after its request.
        var isStillChannel = false
        /// Whether this arrived on the away listener — the internet-facing one —
        /// rather than on a listener on this Mac's network.
        ///
        /// Carried rather than derived from the peer's address, because the
        /// address cannot answer it: a home network's IPv6 addresses are globally
        /// routable and look exactly like an address from the other side of the
        /// world. Which listener accepted the socket is the fact.
        let isAway: Bool

        /// Only a control connection is a device in its own right, or a place to
        /// broadcast to: the others are second and third sockets from a phone
        /// that is already listed, each carrying one job.
        var isControlChannel: Bool {
            !isViewChannel && !isListenChannel && !isStillChannel && upload == nil
        }

        var isApproved: Bool {
            guard let deviceID else { return false }
            return DeviceRegistry.shared.isApproved(deviceID)
        }

        /// Whether this socket came in on a listener that pins keys.
        let isTrust: Bool
        /// The key this phone proved it holds in the handshake. On a trust
        /// socket this, and not anything the phone says, is its device id.
        var trustID: TrustFingerprint? {
            didSet { trustDeviceID = trustID?.description }
        }
        /// `trustID` as the device id it stands for, made once rather than for
        /// every pointer move.
        private(set) var trustDeviceID: String?

        init(connection: NWConnection, source: String, isAway: Bool, isTrust: Bool = false) {
            self.connection = connection
            self.source = source
            self.isAway = isAway
            self.isTrust = isTrust
        }

        /// Whether this connection may be handed its push key: a phone paired
        /// by key, on the trust listener, from this Mac's own network — never
        /// over the internet-facing path. A VPN overlay address counts as this
        /// Mac's own network, deliberately: the overlay authenticates its
        /// peers, and the trust listener is what a tailnet peer reaches. See
        /// `isLocalSource` and SECURITY.md.
        var mayBeIssuedPushKey: Bool {
            guard !isAway, trustID != nil else { return false }
            return PublicAddress.isOnThisMacsNetwork(source)
        }

        var isRelayed: Bool { HostServer.isRelayed(source: source, away: isAway) }

        /// The peer's port. For a relayed socket that is the loopback port the
        /// pump dialled from, which is how the phone behind it is looked up.
        var peerPort: UInt16 {
            guard case .hostPort(_, let port) = connection.endpoint else { return 0 }
            return port.rawValue
        }

        /// Who to count a failed handshake against: the peer, or for a socket
        /// that came through the relay, the phone the relay said it was
        /// carrying. Nil for a relayed socket whose bridge has not reported
        /// its address — a failure then counts against nobody rather than
        /// against every relayed phone at once.
        var throttleSource: String? {
            isRelayed ? RelayLink.phoneAddress(forLocalPort: peerPort) : source
        }

        /// A socket that proved an approved key in its handshake has guessed
        /// nothing, so closing before `hello` is not a failed attempt: a phone
        /// races its Mac's addresses and cancels the ones that lose.
        var provedApprovedKey: Bool { trustDeviceID.map(DeviceRegistry.shared.isApproved) ?? false }
    }

    /// Came through the connect relay: the pump delivers into the away listener
    /// from loopback, so every relayed phone has the same source address, and
    /// throttling it would let anybody who can reach the relay lock every
    /// relayed phone out. Not needed either: the away listener never pairs, so
    /// there is no secret to guess — the TLS pin is the gate.
    static func isRelayed(source: String, away: Bool) -> Bool {
        away && (source == "127.0.0.1" || source == "::1")
    }

    /// Whether a peer may use one of the two LAN listeners at all.
    ///
    /// A listener bound to a port is bound on every interface, and this Mac
    /// may well have an address the whole internet can route to — a global
    /// IPv6 address on the house's own prefix is the usual case — so "the LAN
    /// listener" is only the LAN listener if something says so. This does:
    /// the pairing-code listener and the trust listener take connections
    /// from this Mac's own networks and refuse the rest before a handshake,
    /// which is where the away listener, the one built to face the
    /// internet, is the right place to go.
    ///
    /// A VPN overlay address is "this network" for the trust listener and
    /// not for the pairing-code one. Phones are documented to reach the Mac
    /// over Tailscale, and the trust listener pins keys, so a tailnet peer
    /// gets exactly what a Wi-Fi peer gets. The pairing-code listener is
    /// thirty bits of shared secret behind a throttle, used only by the
    /// `nimlet` tool on this Mac, and a tailnet of unknown size is not a
    /// place to offer that.
    static func isLocalSource(_ source: String, allowingOverlay: Bool) -> Bool {
        PortMapWire.isLocalSource(source, allowingOverlay: allowingOverlay,
                                  mine: PublicAddress.interfaces().global6)
    }

    private struct Throttle {
        var failures = 0
        var lastFailure = Date.distantPast
        var blockedUntil: Date?
    }

    private init() {
        AppRegistry.shared.$snapshot
            .dropFirst()
            .sink { [weak self] snapshot in
                onMainActor { TargetStore.shared.refreshProvisionalApps(snapshot) }
                self?.broadcastAppState(snapshot)
            }
            .store(in: &cancellables)

        // Any change the user makes in Settings is pushed to the phone live.
        TargetStore.shared.$targets
            .dropFirst()
            .debounce(for: .milliseconds(120), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.broadcastTargets() }
            .store(in: &cancellables)

        // And the live half of the dock — the panes and apps that are running
        // with no target pointing at them. The phone draws them past a divider
        // the way the Dock does, so what is reachable and what is curated stop
        // being the same question.
        TargetStore.shared.$provisionalTargets
            .dropFirst()
            .removeDuplicates()
            .debounce(for: .milliseconds(200), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.broadcastTargets() }
            .store(in: &cancellables)

        // Selecting a different target in the menu bar has to reach the phone:
        // the phone's quick replies and its dictation all address "the active
        // target", so without this they kept addressing the previous one until
        // something else happened to push a status.
        TargetStore.shared.$activeTargetID
            .dropFirst()
            .debounce(for: .milliseconds(120), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.broadcastStatus() }
            .store(in: &cancellables)

        // A pane that closed changes nothing in the target list, so the phone
        // would keep drawing a target that now swallows everything sent to it.
        TargetStore.shared.$unresolvedTargetIDs
            .dropFirst()
            .removeDuplicates()
            .debounce(for: .milliseconds(120), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.broadcastStatus() }
            .store(in: &cancellables)

        // Approving a device is the moment it stops being refused, so the phone
        // needs to hear about it without asking.
        // Which ids, not the list: every phone that connects bumps its own
        // last-seen time in it, and that is not an approval changing.
        DeviceRegistry.shared.$approved
            .map { Set($0.map(\.id)) }
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] ids in
                self?.awaitingApproval.removeAll { ids.contains($0.id) }
                self?.broadcastStatus()
                self?.broadcastTargets()
                self?.publishDevices()
                // A newly approved device can be issued an away key, and the
                // first device paired by key is what brings the away listener up.
                self?.broadcastRemoteAccess()
                self?.startAway()
            }
            .store(in: &cancellables)

    }

    /// The Mac's name, unless told otherwise. Two Macs called the same thing —
    /// or two builds of Nimlet on one Mac while you are working on it — are
    /// indistinguishable on the phone otherwise, and Bonjour's own "(2)" suffix
    /// moves around as instances come and go.
    ///
    ///   open -n Mice.app --args -mice.serviceName "Nimlet Dev" -mice.port 61414
    var hostDisplayName: String {
        if let override = UserDefaults.standard.string(forKey: "mice.serviceName"),
           !override.trimmingCharacters(in: .whitespaces).isEmpty {
            return override
        }
        return Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    }

    /// The port to listen on. Fixed at 61413, because a phone that was given a
    /// `host:port` by hand remembers it and a moving port would strand that
    /// entry on every restart.
    ///
    /// Overridable for one case only: a second copy of Nimlet running beside the
    /// one you use, which is how this app is tested against a real Mac. Without
    /// it the test build either fails to bind or takes the port from the copy
    /// the person is working with — and the second of those is worse, because
    /// it looks like it worked.
    ///
    ///   open -n Mice.app --args -mice.serviceName "Nimlet QA" -mice.port 61414
    var listenPort: UInt16 {
        let override = UserDefaults.standard.integer(forKey: "mice.port")
        guard override > 1024, override <= 65535 else { return Self.defaultPort }
        return UInt16(override)
    }

    static let defaultPort: UInt16 = 61413

    /// Where the trust listener binds. Fixed for the same reason as
    /// `listenPort`: a phone remembers addresses with their ports.
    ///
    ///   open -n Mice.app --args -mice.trustPort 61434
    var trustPort: UInt16 {
        let override = UserDefaults.standard.integer(forKey: "mice.trustPort")
        guard override > 1024, override <= 65535 else { return Self.defaultTrustPort }
        return UInt16(override)
    }

    static let defaultTrustPort: UInt16 = 61433

    /// The two listener failures a person can do something about, in the words
    /// of what to do; the rest as the system said it.
    static func explainListenerProblem(_ error: NWError, port: UInt16) -> String {
        switch error {
        case .posix(.EADDRINUSE):
            return "Port \(port) is already in use — is another copy of Nimlet (or Mice) still running? Quit it, then choose Quit here and open Nimlet again."
        case .dns(let code) where code == -65570:
            // kDNSServiceErr_PolicyDenied: Local Network was refused.
            return "macOS is not letting Nimlet use the local network, so phones cannot find it. Allow Nimlet under System Settings → Privacy & Security → Local Network, then relaunch."
        default:
            return "Listener: \(error.localizedDescription)"
        }
    }

    // MARK: - Lifecycle

    func start(pairingCode: String) {
        stop()
        self.pairingCode = pairingCode
        do {
            let params = NimletTransport.parameters(pairingCode: pairingCode)
            // Only the `nimlet` tool dials this one; phones pair by key. The
            // port stays fixed so the tool's saved config survives a restart.
            let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: listenPort)!)
            // Both versions go in the TXT record so a phone can tell a version
            // mismatch from a wrong code before the handshake, where the two
            // are indistinguishable.
            let txt = NWTXTRecord([
                NimletProtocol.txtVersionKey: String(NimletProtocol.version),
                NimletProtocol.txtHostKey: hostDisplayName,
            ])
            listener.service = NWListener.Service(name: hostDisplayName,
                                                  type: NimletProtocol.bonjourType,
                                                  txtRecord: txt)
            listener.newConnectionLimit = HostServer.maxConnections

            let port = listenPort
            listener.stateUpdateHandler = { [weak self] state in
                DispatchQueue.main.async {
                    switch state {
                    case .ready:
                        self?.isListening = true
                        self?.lastError = nil
                    case .waiting(let error):
                        // Not failed, but not working either, and the menu
                        // used to show a green dot throughout: a listener
                        // macOS has refused the local network sits here for
                        // ever looking healthy.
                        self?.lastError = HostServer.explainListenerProblem(error, port: port)
                    case .failed(let error):
                        self?.isListening = false
                        self?.lastError = HostServer.explainListenerProblem(error, port: port)
                    case .cancelled:
                        self?.isListening = false
                    default:
                        break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
            listener.start(queue: queue)
            let trustListener = makeTrustListener()
            startAway()
            // A fresh listener is a fresh start: the lockouts belong to the
            // listener that collected them, not to the address forever.
            queue.async {
                self.listener = listener
                self.trustListener = trustListener
                self.throttles.removeAll()
            }
        } catch {
            DispatchQueue.main.async { self.lastError = error.localizedDescription }
        }
    }

    func stop() {
        // Hooks still waiting on an answer lose their connection here, through
        // no fault of their own. They dial back in; their cards wait for them.
        // Marked before anything can dial back in and ask again, which is why
        // it is not deferred when this already runs on main (it always does:
        // restarts, sleep and quitting all start there).
        let cutOff = queue.sync { Set(clients.values.flatMap(\.approvalIDs)) }
        if !cutOff.isEmpty {
            if Thread.isMainThread {
                MainActor.assumeIsolated { ApprovalBroker.shared.orphan(ids: cutOff) }
            } else {
                DispatchQueue.main.async { ApprovalBroker.shared.orphan(ids: cutOff) }
            }
        }
        queue.sync {
            listener?.cancel()
            listener = nil
            trustListener?.cancel()
            trustListener = nil
            awayListener?.cancel()
            awayListener = nil
            pending.values.forEach { $0.connection.cancel() }
            clients.values.forEach { $0.connection.cancel() }
            pending.removeAll()
            clients.removeAll()
        }
        EventInjector.shared.releaseAllButtons()
        EventInjector.shared.forgetScrollPhase()
        DispatchQueue.main.async {
            self.isListening = false
            self.connectedDevices = []
        }
    }

    /// Keep retrying a failed bind: wake and interface notifications can arrive
    /// together while the previous listener is still releasing the same port.
    private func makeTrustListener() -> RecoveringListener? {
        guard let identity = HostTrust.shared.identity else { return nil }
        let port = trustPort
        let listener = RecoveringListener(queue: queue) { [weak self] in
            let params = try TrustTransport.parameters(identity: identity,
                                                       accepts: { HostTrust.shared.accepts($0, onLAN: true) },
                                                       peerToPeer: true)
            let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
            var txt = NWTXTRecord([
                NimletProtocol.txtVersionKey: String(NimletProtocol.version),
                NimletProtocol.txtHostKey: self?.hostDisplayName ?? "Mac",
            ])
            txt[NimletProtocol.txtFingerprintKey] = identity.fingerprint.description
            listener.service = NWListener.Service(name: self?.hostDisplayName ?? "Mac",
                                                  type: NimletProtocol.trustBonjourType,
                                                  txtRecord: txt)
            return listener
        }
        listener.newConnectionLimit = HostServer.maxConnections
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                miceLog.info("trust: listening on \(port, privacy: .public)")
            case .failed(let error):
                miceLog.error("trust: listener failed \(error.localizedDescription, privacy: .public)")
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] conn in self?.accept(conn, trust: true) }
        listener.start()
        return listener
    }

    /// Rotating the code drops every paired phone on purpose.
    func restart(pairingCode: String) { start(pairingCode: pairingCode) }

    // MARK: - The away listener

    /// Binds the internet-facing port, if the user has asked for it.
    ///
    /// Everything that makes this different from the LAN listener is here, and
    /// each of the three matters:
    ///
    /// - **Keys, not codes.** It is a trust listener: TLS 1.3, and the phone's
    ///   certificate must carry the key of a device the user has approved, so
    ///   anything else fails the handshake before it has sent a byte of Nimlet's
    ///   own protocol. The decision is made per handshake from the registry,
    ///   so revoking a device closes this door without a restart. It never
    ///   pairs: an unknown key is refused here even while the LAN listener has
    ///   an invitation open. (It used to hold one PSK per device, issued over
    ///   the pairing-code channel — which made each 256-bit key exactly as
    ///   strong as the 30-bit code it travelled under.)
    /// - **No Bonjour service.** There is nobody on the far side of a router to
    ///   advertise to, and advertising a port that is deliberately reachable
    ///   would be announcing it to the whole local network as well.
    /// - **No peer-to-peer.** A socket that arrives over the internet has no
    ///   business being offered a radio link.
    ///
    /// With no device paired by key it binds nothing at all. A listener that
    /// can accept nobody would take TCP connections and fail every handshake,
    /// which is a port answering to nothing — worse than a closed one, because
    /// it says something is here.
    func startAway() {
        queue.async { self.startAwayNow() }
    }

    private func startAwayNow() {
        let port = RemoteReach.port
        let wanted = RemoteReach.isEnabledForListener && HostTrust.shared.hasTrustedDevices
        if wanted, let listener = awayListener, awayListenerPort == port {
            switch listener.state {
            case .setup, .waiting, .ready: return
            default: break
            }
        }
        awayListener?.cancel()
        awayListener = nil
        awayListenerPort = nil
        guard RemoteReach.isEnabledForListener else { return }
        guard let identity = HostTrust.shared.identity else {
            miceLog.error("away: this Mac has no key, so nothing is listening")
            return
        }
        guard wanted else {
            miceLog.info("away: no device is paired by key yet, so nothing is listening")
            return
        }
        let listener = RecoveringListener(queue: queue) {
            let params = try TrustTransport.parameters(identity: identity,
                                                       accepts: { HostTrust.shared.accepts($0, onLAN: false) },
                                                       peerToPeer: false)
            let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
            return listener
        }
        listener.newConnectionLimit = HostServer.maxConnections
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                miceLog.info("away: listening on \(port, privacy: .public)")
            case .failed(let error):
                miceLog.error("away: listener failed \(error.localizedDescription, privacy: .public)")
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] conn in self?.accept(conn, away: true, trust: true) }
        listener.start()
        awayListener = listener
        awayListenerPort = port
    }

    func stopAway() {
        queue.async {
            self.awayListener?.cancel()
            self.awayListener = nil
            // Every socket that came in over it goes with it. Leaving them up
            // would mean switching away access off does not actually end the
            // sessions it was switched off to end.
            for (key, client) in self.clients where client.isAway {
                client.connection.cancel()
                self.clients[key] = nil
            }
            for (key, client) in self.pending where client.isAway {
                client.connection.cancel()
                self.pending[key] = nil
            }
            // A direct tunnel is a way in from away too.
            for deviceID in Array(self.directTunnels.keys) {
                self.closeDirectTunnel(for: deviceID, "away access was switched off")
            }
        }
    }

    /// Pushes the addresses to every phone that is allowed to hear them.
    func broadcastRemoteAccess() {
        queue.async {
            for client in self.clients.values where client.isApproved && client.isControlChannel {
                self.sendRemoteAccess(to: client)
            }
        }
    }

    /// The addresses, and this phone's push key when it may be issued one.
    /// Only for a phone paired by key: the `nimlet` tool on the pairing code
    /// has no use for either.
    private func sendRemoteAccess(to client: Client) {
        guard let deviceID = client.trustDeviceID else { return }
        let mayIssue = client.mayBeIssuedPushKey
        DispatchQueue.main.async {
            let payload = RemoteReach.shared.payload(forDevice: deviceID, isLocalPeer: mayIssue)
            self.queue.async { self.send(.remoteAccess(payload), to: client) }
        }
    }

    /// Follows where this Mac can be reached. Called once at launch, on main,
    /// because `RemoteReach` lives there.
    ///
    /// The router handing back a different port, the ISP moving the address, a
    /// cable going in: each changes the answer, and none of them announces itself
    /// to the phone.
    @MainActor
    func beginRemoteAccessWatch() {
        RemoteReach.shared.$candidates
            .dropFirst()
            .removeDuplicates()
            .debounce(for: .milliseconds(200), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.broadcastRemoteAccess() }
            .store(in: &cancellables)
        RemoteReach.shared.$status
            .dropFirst()
            .removeDuplicates()
            .debounce(for: .milliseconds(200), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.broadcastRemoteAccess() }
            .store(in: &cancellables)
    }

    /// Connects the approval broker to the sockets. Called once at launch, on
    /// main, because the broker lives there.
    @MainActor
    func beginApprovals() {
        let broker = ApprovalBroker.shared
        broker.onAdded = { [weak self] request in
            // Every approved phone, so whichever one is in reach can answer.
            self?.broadcast(.approvalRequest(request))
        }
        broker.onResolved = { [weak self] resolution in
            self?.deliverResolution(resolution)
        }
    }

    /// Back to whoever asked, so it stops blocking — and out to the phones, so
    /// a card answered on one screen comes down on the other.
    private func deliverResolution(_ resolution: ApprovalResolution) {
        // Cannot reach a notification already on a sleeping phone — APNs has no
        // way to retract one — but it does stop the Mac counting a question
        // that is answered, which would otherwise inflate every later badge.
        PushSender.shared.resolved(approvalID: resolution.requestID)
        guard let data = try? NimletCoder.line(HostMessage.approvalResolved(resolution)) else { return }
        queue.async {
            var asker: ObjectIdentifier?
            for (key, client) in self.clients where client.approvalIDs.contains(resolution.requestID) {
                client.approvalIDs.remove(resolution.requestID)
                asker = key
            }
            for (key, client) in self.clients where client.isApproved || key == asker {
                client.connection.send(content: data, completion: .contentProcessed { _ in })
            }
        }
    }

    /// Sleep, wake and a change of network all leave the listener looking fine
    /// and reaching nobody, which is the worst shape a bug can take here.
    func beginSystemWatch() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.stop()
        }
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            // TCC can come back from sleep, or from an OS update, refusing an
            // app it still lists as trusted; every event then goes nowhere
            // while the UI reports that permission was granted.
            EventInjector.shared.revalidateTrust()
            EventInjector.shared.invalidateDisplayCache()
            self.start(pairingCode: self.pairingCode)
            self.broadcastStatus()
        }

        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let interfaces = Set(path.availableInterfaces.map(\.name))
            guard let known = self.knownInterfaces else {
                self.knownInterfaces = interfaces
                return
            }
            guard known != interfaces else { return }
            self.knownInterfaces = interfaces
            // Joining a different Wi-Fi network leaves the listener bound to an
            // address nothing can reach any more, and it reports no error.
            DispatchQueue.main.async { self.start(pairingCode: self.pairingCode) }
        }
        monitor.start(queue: queue)
        pathMonitor = monitor
    }

    // MARK: - Connections

    /// Runs on `queue`: `NWListener` delivers connections on the queue it was
    /// started with, and every connection handler below is started on it too.
    private func accept(_ connection: NWConnection, away: Bool = false, trust: Bool = false) {
        let source = HostServer.sourceKey(of: connection.endpoint)
        if away { miceLog.info("away: connection from \(source, privacy: .private)") }
        // The LAN listeners are for the LAN. See `isLocalSource`.
        if !away, !HostServer.isLocalSource(source, allowingOverlay: trust) {
            miceLog.error("\(trust ? "trust" : "code", privacy: .public): refused a connection from off this network (\(source, privacy: .private))")
            connection.cancel()
            refreshConnectionLimit()
            return
        }
        // The away listener has a budget of its own, so filling it costs the
        // phones at the desk nothing.
        if away, (clients.values.filter(\.isAway).count + pending.values.filter(\.isAway).count) >= HostServer.maxAwayConnections {
            miceLog.error("away: refused a connection; \(HostServer.maxAwayConnections, privacy: .public) away sockets are already open")
            connection.cancel()
            refreshConnectionLimit()
            return
        }
        // A relayed socket is throttled by the phone behind it when the bridge
        // has already said which one that is; the relay itself backs off a
        // phone that keeps failing, which is the enforcement that does not
        // depend on this lookup winning its race with the bridge.
        let throttleKey = HostServer.isRelayed(source: source, away: away)
            ? RelayLink.phoneAddress(forLocalPort: {
                if case .hostPort(_, let port) = connection.endpoint { return port.rawValue }
                return 0
            }())
            : source
        if let throttleKey, let until = throttles[throttleKey]?.blockedUntil, until > Date() {
            let seconds = Int(until.timeIntervalSinceNow.rounded())
            miceLog.error("refused \(source, privacy: .private): locked out for another \(seconds)s")
            connection.cancel()
            // `newConnectionLimit` counts down as connections are delivered and
            // has to be re-armed. Returning without doing so meant each refusal
            // permanently consumed a slot, so four locked-out connections
            // wedged the listener against everybody, including the user.
            refreshConnectionLimit()
            return
        }

        let client = Client(connection: connection, source: source, isAway: away, isTrust: trust)
        let key = ObjectIdentifier(client)
        pending[key] = client
        refreshConnectionLimit()

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                // An AWDL peer-to-peer link behaves very differently from
                // infrastructure Wi-Fi; which one is in use is otherwise invisible.
                let path = connection.currentPath
                let interfaces = (path?.availableInterfaces ?? [])
                    .map { "\($0.name)(\($0.type))" }
                    .joined(separator: ",")
                client.route = DirectTunnel.carrier(ofLocalPort: client.peerPort)
                    ?? (client.isRelayed ? "relay" : LinkRoute.name(of: path) + (client.isAway ? ", away" : ""))
                if client.isTrust {
                    // The verify block has already accepted this key; this is
                    // reading back which one it was. A trust socket with no
                    // key to read is not one anything should be served on.
                    guard let peer = TrustTransport.peerFingerprint(of: connection) else {
                        miceLog.error("trust: a connection completed with no peer key; closing it")
                        connection.cancel()
                        return
                    }
                    client.trustID = peer
                    if client.isRelayed { RelayLink.phoneAuthenticated(atLocalPort: client.peerPort) }
                    client.route += ", key"
                }
                miceLog.notice("client ready: route=\(client.route, privacy: .public) remote=\(String(describing: path?.remoteEndpoint), privacy: .private) interfaces=\(interfaces, privacy: .public) expensive=\(path?.isExpensive ?? false, privacy: .public)")
                // Nothing is sent here. The welcome used to go out on `.ready`,
                // which was both too early and too loud: too early because the
                // host does not yet know which device this is, so its
                // `deviceApproved` was a placeholder the phone had to wait out
                // with a timer; too loud because a viewer connection carries
                // binary frames from its first byte and a JSON line at the head
                // of that stream desyncs its length-prefixed reader. `greet`
                // sends it once there is something true to say.
            case .failed(let error):
                // A trust handshake that fails says nothing anywhere else: the
                // phone was refused, or refused this Mac, before it was a client.
                if client.isTrust, client.trustID == nil {
                    miceLog.error("trust: handshake from \(source, privacy: .private) failed: \(error.localizedDescription, privacy: .public)\(client.isAway ? " (away)" : "", privacy: .public)")
                }
                PanelStreamer.shared.detach(connection)
                AudioStreamer.shared.detach(connection)
                self.finish(client, key: key, error: error.localizedDescription)
                // The list says which phones are being heard, and this socket
                // going away is how a phone stops being one of them.
                if client.isListenChannel { self.publishDevices() }
            case .cancelled:
                PanelStreamer.shared.detach(connection)
                AudioStreamer.shared.detach(connection)
                self.finish(client, key: key, error: nil)
                if client.isListenChannel { self.publishDevices() }
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive(on: client)

        // A connection that completes the handshake and then says nothing is
        // holding a slot for no reason; a lot of them is an attack.
        queue.asyncAfter(deadline: .now() + HostServer.helloDeadline) { [weak self] in
            guard let self, self.pending[key] != nil else { return }
            miceLog.error("dropping \(source, privacy: .private): connected but never said hello")
            client.connection.cancel()
        }
    }

    /// Moves a connection out of the pending set now that it has said who it is.
    ///
    /// Four handshakes reach this: `hello` for a control client, `viewHello` for
    /// a panel viewer, `listenHello` for the Mac's audio and `uploadHello` for a
    /// batch of attachments. Any connection still pending when the hello
    /// deadline comes round is cancelled, so a socket that identified itself in
    /// one of the other ways has to land here as well.
    private func register(_ client: Client) {
        let key = ObjectIdentifier(client)
        pending[key] = nil
        clients[key] = client
        refreshConnectionLimit()
    }

    // MARK: - Attachments

    /// Feeds bytes to an upload in progress and acts on what that completes.
    private func absorb(_ data: Data, into session: UploadSession, from client: Client) {
        guard !data.isEmpty else { return }
        switch session.append(data) {
        case .receiving:
            break
        case .refused(let message):
            client.upload = nil
            miceLog.error("upload \(session.batchID, privacy: .public) refused: \(message, privacy: .public)")
            note("Upload refused: \(message)")
            send(.error(message), to: client, thenClose: true)
        case .complete(let attachments):
            // The batch is over either way now; what is left is delivery, and a
            // stray byte after the last frame should not be read as one.
            client.upload = nil
            deliver(attachments, for: session, to: client)
        }
    }

    /// Delivers a complete batch to every target the manifest named.
    ///
    /// The files are written once and delivered many times: the same photograph
    /// going to two panes is two deliveries of one pair of paths, not two
    /// uploads. The receipts go back on the upload socket, which is then closed —
    /// it exists for this one batch.
    private func deliver(_ attachments: [TargetRouter.Attachment],
                         for session: UploadSession,
                         to client: Client) {
        let manifest = session.manifest
        let targets = manifest.targetIDs.compactMap { TargetStore.shared.safeTarget(id: $0) }
        guard !targets.isEmpty else {
            // The target list can change while megabytes are in flight.
            send(.error("No target with that id — it may have been removed"), to: client, thenClose: true)
            return
        }
        injectionQueue.async {
            for (index, target) in targets.enumerated() {
                DispatchQueue.main.async { TargetStore.shared.setActive(target.id) }
                let receipt = TargetRouter.deliver(attachments: attachments,
                                                  caption: manifest.text,
                                                  to: target,
                                                  submit: manifest.submit)
                self.note(receipt.message)
                // Steer or queue, once the images are actually in the composer.
                if receipt.ok, let chord = manifest.followChord {
                    let pressed = TargetRouter.press(chord, on: target)
                    if !pressed.ok { self.note(pressed.message) }
                }
                let isLast = index == targets.count - 1
                self.send(.delivered(receipt), to: client, thenClose: isLast)
                if !receipt.ok { miceLog.error("upload \(session.batchID, privacy: .public): \(receipt.message, privacy: .public)") }
            }
            // Deleting what is stale on the way out, rather than on a timer:
            // uploads are the only thing that puts files in there.
            AttachmentInbox.prune()
        }
    }

    private func finish(_ client: Client, key: ObjectIdentifier, error: String?) {
        let wasPending = pending[key] != nil
        let wasKnown = clients[key] != nil
        pending[key] = nil
        clients[key] = nil
        refreshConnectionLimit()
        // A probe answers only the phone that asked; it goes with its session.
        client.directProbe?.cancel()
        client.directProbe = nil

        // A batch that never completed delivers nothing, and should not leave
        // the attachments it did receive lying in the inbox either.
        if let session = client.upload {
            client.upload = nil
            session.abandon()
        }

        if wasKnown {
            // Only what this phone was holding. Releasing everything meant a
            // stranger connecting and dropping cancelled the drag the actual
            // user was in the middle of.
            if !client.heldButtons.isEmpty {
                EventInjector.shared.release(buttons: client.heldButtons)
                client.heldButtons.removeAll()
            }
            // An agent that died mid-question leaves a card nobody can answer
            // usefully. Take it down rather than let it sit there until it
            // times out against a process that is already gone.
            if !client.approvalIDs.isEmpty {
                let ids = client.approvalIDs
                client.approvalIDs.removeAll()
                DispatchQueue.main.async { ApprovalBroker.shared.withdraw(ids: ids) }
            }
        } else if wasPending, !client.provedApprovedKey, let source = client.throttleSource {
            noteHandshakeFailure(source, error: error)
        }
        if wasPending || wasKnown { publishDevices() }
    }

    /// A connection that dies before it identifies itself is a wrong pairing
    /// code, a wrong protocol version or someone trying codes. Backing off
    /// costs the first two nothing and the third everything.
    private func noteHandshakeFailure(_ source: String, error: String?) {
        let now = Date()
        throttles = throttles.filter { $0.value.lastFailure > now.addingTimeInterval(-3600) }

        var throttle = throttles[source] ?? Throttle()
        throttle.failures += 1
        throttle.lastFailure = now
        if throttle.failures >= HostServer.failuresBeforeLockout {
            let seconds = min(pow(2, Double(throttle.failures - HostServer.failuresBeforeLockout + 1)),
                              HostServer.maxLockout)
            throttle.blockedUntil = now.addingTimeInterval(seconds)
            miceLog.error("\(source, privacy: .private): \(throttle.failures) failed handshakes, locked out \(Int(seconds))s (\(error ?? "closed", privacy: .public))")
        }
        throttles[source] = throttle
    }

    /// `newConnectionLimit` counts down as connections are delivered and stops
    /// the listener at zero, so it has to be re-armed as slots free up. That is
    /// also what turns it into a concurrency cap rather than a lifetime one.
    private func refreshConnectionLimit() {
        let spare = max(0, HostServer.maxConnections - (clients.count + pending.count))
        listener?.newConnectionLimit = spare
        trustListener?.newConnectionLimit = spare
        awayListener?.newConnectionLimit = spare
    }

    /// The peer's address without the port, so reconnecting from a new
    /// ephemeral port doesn't read as a brand new stranger.
    private static func sourceKey(of endpoint: NWEndpoint) -> String {
        guard case .hostPort(let host, _) = endpoint else { return "\(endpoint)" }
        // A link-local address carries the interface it arrived on
        // (`fe80::1%en0`), which is not part of who the peer is.
        let text = "\(host)"
        return text.split(separator: "%").first.map(String.init) ?? text
    }

    private func receive(on client: Client) {
        client.connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                client.lastHeardAt = Date()
                // An upload socket is newline-framed for exactly one line — the
                // manifest — and length-prefixed for every byte after it. The
                // handshake is what makes the switch safe: the phone waits for
                // `uploadReady` before sending any image bytes, so there is
                // never a frame sitting behind the manifest in the same packet.
                if let session = client.upload {
                    self.absorb(data, into: session, from: client)
                } else {
                    for line in client.framer.append(data) {
                        self.handle(line: line, from: client)
                        // The manifest just turned this into an upload. Anything
                        // the line framer had left over belongs to the binary
                        // stream now, and a client that ignored the handshake
                        // would otherwise have its first frame stranded there.
                        if let session = client.upload {
                            self.absorb(client.framer.drain(), into: session, from: client)
                            break
                        }
                    }
                    // The batch is read: whatever moves ended it go now.
                    self.flushMove(for: client)
                }
            }
            if isComplete || error != nil {
                client.connection.cancel()
                return
            }
            self.receive(on: client)
        }
    }

    private func publishDevices() {
        queue.async {
            // Which device ids have a listen socket open. Collected first, since
            // a phone is listed by its control connection and is heard on
            // another one entirely.
            let hearing = Set(self.clients.values.compactMap { client in
                client.isListenChannel ? client.deviceID : nil
            })
            let devices = self.clients.values.compactMap { client -> ConnectedDevice? in
                // A viewer is a second socket from a phone already listed.
                guard client.isControlChannel, let deviceID = client.deviceID else { return nil }
                return ConnectedDevice(id: deviceID,
                                       name: client.name,
                                       approved: DeviceRegistry.shared.isApproved(deviceID),
                                       isHearing: hearing.contains(deviceID),
                                       route: client.route)
            }
            .sorted { $0.name < $1.name }
            DispatchQueue.main.async { self.connectedDevices = devices }
        }
    }

    // MARK: - Message handling

    /// Direct tunnels, by device: each outlives the control connection that
    /// asked for it, because the phone moves its session — that connection
    /// included — onto the tunnel and then lets the relayed one go.
    private var directTunnels: [String: DirectTunnel] = [:]

    /// The direct path: bind a UDP socket on the physical interface, tell the
    /// phone where, punch towards it while it punches back, and once a packet
    /// gets through carry its connections into the away listener over KCP
    /// (`DirectTunnel`). The key comes from this session's TLS, so only this
    /// phone gets answers — and what runs inside is that phone's own TLS again.
    private func answerDirectOffer(_ peer: DirectCandidate, from client: Client) {
        client.directProbe?.cancel()
        client.directProbe = nil
        guard let deviceID = client.deviceID else { return }
        guard RemoteReach.isEnabledForListener else {
            send(.directAnswer(nil, note: "away access is off on this Mac"), to: client)
            return
        }
        guard let secret = TrustTransport.exporter(of: client.connection, label: DirectPacket.exporterLabel) else {
            send(.directAnswer(nil, note: "this session has no key to sign the probe with"), to: client)
            return
        }
        guard let interface = DirectProbe.physicalInterface(),
              let probe = DirectProbe(secret: secret, interface: interface) else {
            send(.directAnswer(nil, note: "this Mac has no global IPv6 address on a physical interface"), to: client)
            return
        }
        client.directProbe = probe
        miceLog.notice("direct: punching from \(probe.local.display, privacy: .private) on \(interface, privacy: .public) towards \(peer.display, privacy: .private)")
        send(.directAnswer(probe.local, note: nil), to: client)
        let awayPort = RemoteReach.port
        probe.punch(peer: peer) { [weak self, weak client] fd, millis, note in
            guard let self else { return }
            self.queue.async {
                if client?.directProbe === probe { client?.directProbe = nil }
                guard let fd else {
                    miceLog.notice("direct: not punched (\(note ?? "?", privacy: .public))")
                    return
                }
                let tunnel = DirectTunnel(socket: fd, secret: secret, side: .acceptor(port: awayPort))
                tunnel.onClose = { [weak self, weak tunnel] reason in
                    miceLog.notice("direct: tunnel closed: \(reason, privacy: .public)")
                    self?.queue.async {
                        if let tunnel, self?.directTunnels[deviceID] === tunnel { self?.directTunnels[deviceID] = nil }
                    }
                }
                self.directTunnels.removeValue(forKey: deviceID)?.close("replaced by a new one")
                self.directTunnels[deviceID] = tunnel
                tunnel.start()
                miceLog.notice("direct: punched in \(millis ?? -1, privacy: .public) ms; tunnel open")
            }
        }
    }

    /// Ends a device's direct tunnel — revoked, or away access switched off.
    private func closeDirectTunnel(for deviceID: String, _ reason: String) {
        directTunnels.removeValue(forKey: deviceID)?.close(reason)
        relayTunnels.removeValue(forKey: deviceID)?.close(reason)
    }

    /// Tunnels through the relay's UDP, by device: the same KCP tunnel as the
    /// direct path, sent to the relay with a token in front, for a phone that
    /// cannot be reached directly.
    private var relayTunnels: [String: DirectTunnel] = [:]

    /// Asks the relay for a UDP pair for this phone and starts this end of the
    /// tunnel at once — its keepalives are what tell the relay where this Mac
    /// is — then tells the phone where to send. Small datagrams go twice: the
    /// relay's lossy leg is the phone's, and what this end sends it besides
    /// the mirror is acknowledgements and replies.
    private func openRelayTunnel(for client: Client) {
        guard let deviceID = client.deviceID else { return }
        guard RemoteReach.isEnabledForListener else {
            send(.relayTunnel(nil, note: "away access is off on this Mac"), to: client)
            return
        }
        guard let secret = TrustTransport.exporter(of: client.connection, label: RelayDatagramGrant.exporterLabel) else {
            send(.relayTunnel(nil, note: "this session has no key to tag datagrams with"), to: client)
            return
        }
        let awayPort = RemoteReach.port
        DispatchQueue.main.async {
            RelayService.shared.requestDatagramPair { [weak self, weak client] grant, note in
                guard let self else { return }
                self.queue.async {
                    guard let client else { return }
                    guard let grant, let framing = grant.framing(asMac: true),
                          let fd = DirectSocket.connected(to: grant.host, port: grant.port) else {
                        miceLog.notice("relay UDP: not available (\(note ?? "no socket", privacy: .public))")
                        self.send(.relayTunnel(nil, note: note ?? "could not open a UDP socket to the relay"), to: client)
                        return
                    }
                    let tunnel = DirectTunnel(socket: fd, secret: secret, side: .acceptor(port: awayPort),
                                              framing: framing, redundancy: .small(copies: 2, maxBytes: 300))
                    tunnel.onClose = { [weak self, weak tunnel] reason in
                        miceLog.notice("relay UDP: tunnel closed: \(reason, privacy: .public)")
                        self?.queue.async {
                            if let tunnel, self?.relayTunnels[deviceID] === tunnel { self?.relayTunnels[deviceID] = nil }
                        }
                    }
                    self.relayTunnels.removeValue(forKey: deviceID)?.close("replaced by a new one")
                    self.relayTunnels[deviceID] = tunnel
                    tunnel.start()
                    miceLog.notice("relay UDP: pair open at \(grant.host, privacy: .public):\(grant.port, privacy: .public)")
                    self.send(.relayTunnel(grant, note: nil), to: client)
                }
            }
        }
    }

    /// Injects the moves summed from this batch, as one. See `MoveAccumulator`.
    private func flushMove(for client: Client) {
        guard let move = client.pendingMove.take() else { return }
        EventInjector.shared.move(dx: move.dx, dy: move.dy)
    }

    private func handle(line: Data, from client: Client) {
        let decodeStart = Instrumentation.now()
        defer { Instrumentation.shared.record("0_decode_dispatch", since: decodeStart) }
        guard let decoded = try? NimletCoder.decode(ClientMessage.self, from: line) else {
            send(.error("Unreadable message"), to: client)
            return
        }
        // On a trust socket the device is the key it proved, whatever its
        // hello says. Read here as well as on `.ready`, so a line that
        // arrives first is not taken for one from nobody.
        if client.isTrust, client.trustID == nil {
            client.trustID = TrustTransport.peerFingerprint(of: client.connection)
        }
        let message = client.trustDeviceID.map { decoded.claiming(deviceID: $0) } ?? decoded
        if client.isTrust {
            guard let peer = client.trustID, let peerID = client.trustDeviceID else { return }
            if case .pair(let request) = message {
                pair(request, as: peer, from: client)
                return
            }
            // An unknown key was let through the handshake only because an
            // invitation is open, and on that socket `pair` is the only word.
            // Once a socket has said hello it was approved then, and
            // `isPermitted` re-checks approval for every message after it.
            guard client.didHello || DeviceRegistry.shared.isApproved(peerID) else {
                miceLog.error("trust: an unpaired key said something other than pair; closing")
                client.connection.cancel()
                return
            }
        } else if case .pair = message {
            return
        } else if let claimed = message.claimedDeviceID, TrustFingerprint(claimed) != nil {
            // A key's fingerprint is a device id only a key can prove. On the
            // pairing-code listener it is a claim, and approving a claim of
            // that shape would let a code holder mint a key identity — one the
            // internet-facing listener and the relay would then accept.
            note("refused a device id that only a key can prove",
                 shown: "refused a device id that only a key can prove, from \(client.source)")
            send(.error("This device id can only connect by key"), to: client, thenClose: true)
            return
        }
        guard isPermitted(message, from: client) else { return }
        // Anything that is not a move lands after the moves before it.
        if case .move = message {} else { flushMove(for: client) }

        switch message {
        case .hello(let hello):
            greet(hello, from: client)

        case .move(let dx, let dy):
            Instrumentation.shared.recordMoveArrival()
            client.input.moved()
            client.pendingMove.add(dx: dx, dy: dy)
            countMove()

        case .scroll(let dx, let dy):
            miceLog.debug("scroll dx=\(dx, format: .fixed(precision: 1)) dy=\(dy, format: .fixed(precision: 1))")
            EventInjector.shared.scroll(dx: dx, dy: dy)

        case .scrollPhase(let phase):
            EventInjector.shared.scroll(phase: phase)

        case .requestRemoteAccess:
            sendRemoteAccess(to: client)

        case .pointAtPanel(let x, let y, let generation):
            let target = generation.map { PanelStreamer.shared.windowFrame(shownGeneration: $0) }
                ?? PanelStreamer.shared.pointableWindowFrame
            guard let frame = target, frame.width > 0, frame.height > 0 else {
                // Nothing is being mirrored, what is being mirrored is a pane
                // rather than a window, or the mirror has just changed windows
                // and the picture on the phone is still the old one — in which
                // case this touch is about a window that is no longer there.
                // Refused in silence: a finger dragging across the picture is a
                // hundred of these, and the phone has already been told what
                // the panel is showing. The press that follows is refused too —
                // the cursor never moved, so it would land on the other window.
                client.input.pointed(accepted: false)
                return
            }
            let inside = CGPoint(x: min(max(x, 0), 1), y: min(max(y, 0), 1))
            let position = CGPoint(x: frame.minX + inside.x * frame.width,
                                   y: frame.minY + inside.y * frame.height)
            client.input.pointed(accepted: true, position: position)
            EventInjector.shared.point(to: position)

        case .reshapePanel(let aspect):
            // Talks to another process, so not on this queue — and coalesced:
            // a drag sends these several times a second, and only the latest
            // shape is worth applying.
            reshapeLock.withLock { pendingReshape = CGFloat(aspect) }
            injectionQueue.async {
                let aspect = self.reshapeLock.withLock { () -> CGFloat? in
                    defer { self.pendingReshape = nil }
                    return self.pendingReshape
                }
                guard let aspect else { return }
                PanelStreamer.shared.reshapeMirroredWindow(aspect: aspect)
            }

        case .click(let button, let phase, let clickCount):
            guard client.input.admits(button, phase) else {
                miceLog.info("click \(button.rawValue, privacy: .public) \(phase.rawValue, privacy: .public) refused: aimed at a mirror frame of a window no longer shown")
                if phase != .up { noteMirrorSwitching(to: client) }
                return
            }
            // Already let go of, because the phone went quiet holding it. The
            // release that finally arrives must not post a second mouse-up.
            if phase == .up, !client.heldButtons.contains(button) { return }
            miceLog.info("click \(button.rawValue, privacy: .public) \(phase.rawValue, privacy: .public) accessibility=\(EventInjector.shared.isTrusted, privacy: .public)")
            switch phase {
            case .down:
                client.heldButtons.insert(button)
                beginSilenceWatch()
            case .up, .click: client.heldButtons.remove(button)
            }
            EventInjector.shared.click(button: button, phase: phase, clickCount: clickCount,
                                       at: client.input.clickPosition(for: phase))
            if phase != .down { PanelStreamer.shared.noteClick() }

        case .key(let payload):
            // Addressed like text is. An unknown id is refused rather than
            // quietly delivered to the front window, for the same reason a
            // delivery to one is: the user believes they are talking to the
            // target named on their screen.
            var destination: NimletTarget?
            if let id = payload.targetID {
                guard let known = TargetStore.shared.safeTarget(id: id) else {
                    send(.error("Unknown target"), to: client)
                    return
                }
                destination = known
            }
            let target = destination
            injectionQueue.async {
                let outcome = TargetRouter.press(payload.chord, on: target)
                self.note(outcome.message)
                if !outcome.ok { self.send(.error(outcome.message), to: client) }
            }

        case .focus(let targetID):
            guard let target = TargetStore.shared.safeTarget(id: targetID) else {
                send(.error("Unknown target"), to: client); return
            }
            injectionQueue.async {
                // A tap on a tile is somebody saying where they are working, so
                // the pointer goes with it.
                let outcome = TargetRouter.focus(target, movingPointer: true)
                if outcome.ok { DispatchQueue.main.async { TargetStore.shared.setActive(targetID) } }
                self.note(outcome.message)
                self.send(outcome.ok ? .toast(outcome.message) : .error(outcome.message), to: client)
                self.broadcastStatus()
                // A tap on a tile pointed at one window can fail for exactly one
                // interesting reason: that window has closed or been minimised.
                // Saying so and stopping there leaves the user holding a target
                // that does nothing, so the windows that *do* exist are sent
                // with the refusal and the phone opens the shelf on them.
                guard !outcome.ok, target.pinnedWindowID != nil,
                      let bundleID = target.bundleID else { return }
                Task {
                    let roster = await WindowRoster.windows(ofBundleID: bundleID,
                                                            pinned: target.pinnedWindowID, applicationPath: target.applicationPath)
                    for chunk in WindowListPayload.chunked(roster.windows,
                                                           targetID: targetID,
                                                           note: roster.note, appIdentity: roster.appIdentity) {
                        self.send(.windows(chunk), to: client)
                    }
                }
            }

        case .text(let payload):
            // An id that names nothing used to fall through to the active
            // target and, failing that, to a synthesised frontmost target with
            // Return enabled — so a stale or mistyped id did not fail, it typed
            // a sentence into whatever window happened to be in front and
            // pressed Return on it. The same id was then handed to `setActive`
            // without a lookup, which left the host pointing at a target that
            // does not exist and sent every later delivery the same way.
            var target: NimletTarget
            if let id = payload.targetID {
                guard let known = TargetStore.shared.safeTarget(id: id) else {
                    send(.delivered(DeliveryReceipt(ok: false, targetID: id, targetName: id,
                                                    characters: payload.text.count, submitted: false,
                                                    message: "No target with that id — it may have been removed")),
                         to: client)
                    send(.error("Unknown target"), to: client)
                    return
                }
                target = known
                DispatchQueue.main.async { TargetStore.shared.setActive(id) }
            } else if let active = TargetStore.shared.safeActiveTarget {
                target = active
            } else {
                send(.delivered(DeliveryReceipt(ok: false, targetID: nil, targetName: "—",
                                                characters: payload.text.count, submitted: false,
                                                message: "No target is selected on the Mac")),
                     to: client)
                return
            }
            injectionQueue.async {
                let receipt = TargetRouter.deliver(text: payload.text, to: target, submit: payload.submit)
                self.note(receipt.message)
                self.send(.delivered(receipt), to: client)
                if !receipt.ok { self.send(.error(receipt.message), to: client) }
            }

        case .requestVocabulary(let targetID):
            guard let target = TargetStore.shared.safeTarget(id: targetID) else {
                send(.error("Unknown target"), to: client); return
            }
            sendVocabulary(for: target, to: client)

        case .addTarget(let requested):
            // Resolving a pane spec shells out to tmux, so it happens here
            // rather than in the store, which publishes and therefore runs on
            // main.
            injectionQueue.async {
                let resolved = Self.resolvingPane(requested)
                DispatchQueue.main.async {
                    let outcome = TargetStore.shared.add(resolved)
                    switch outcome {
                    case .added(let added):
                        self.note("Added \(added.name)")
                        self.send(.toast("Added \(added.name)"), to: client)
                    case .refused(let reason):
                        self.send(.error(reason), to: client)
                    }
                }
            }

        case .updateTarget(let requested):
            // Resolving a pane spec shells out to tmux, so it happens off main
            // for the same reason `addTarget` does.
            injectionQueue.async {
                let resolved = Self.resolvingPane(requested)
                DispatchQueue.main.async {
                    switch TargetStore.shared.update(resolved) {
                    case .added(let saved):
                        self.note("Edited \(saved.name)")
                        self.send(.toast("Saved \(saved.name)"), to: client)
                    case .refused(let reason):
                        self.send(.error(reason), to: client)
                    }
                }
            }

        case .addTargets(let requested):
            // Resolving panes shells out, so the whole batch is prepared off
            // main and applied in one hop — not one hop per target, which would
            // let a target list change underneath the batch halfway through.
            injectionQueue.async {
                let resolved = requested.map(Self.resolvingPane)
                DispatchQueue.main.async {
                    var added: [String] = []
                    var refusals: [String] = []
                    for target in resolved {
                        switch TargetStore.shared.add(target) {
                        case .added(let target): added.append(target.name)
                        case .refused(let reason): refusals.append(reason)
                        }
                    }
                    // One toast for what worked and one error for what did not:
                    // four apps ticked in a picker should not answer with four
                    // of each, and a refusal buried in a stream of successes is
                    // a refusal nobody reads.
                    if !added.isEmpty {
                        let names = added.joined(separator: ", ")
                        self.note("Added \(names)")
                        self.send(.toast(added.count == 1 ? "Added \(names)"
                                                          : "Added \(added.count): \(names)"),
                                  to: client)
                    }
                    if let first = refusals.first {
                        self.send(.error(refusals.count == 1 ? first
                                                             : "\(first) (+\(refusals.count - 1) more)"),
                                  to: client)
                    }
                }
            }

        case .removeTarget(let id):
            DispatchQueue.main.async {
                guard let existing = TargetStore.shared.target(id: id) else {
                    self.send(.error("That target no longer exists"), to: client)
                    return
                }
                TargetStore.shared.remove(ids: [id])
                self.note("Removed \(existing.name)")
                self.send(.toast("Removed \(existing.name)"), to: client)
            }

        case .reorderTargets(let ids):
            DispatchQueue.main.async { TargetStore.shared.setOrder(ids) }

        case .requestMenu(let bundleID, let refresh):
            // A menu walk is a few hundred round trips into another process,
            // so it goes on a queue of its own rather than the injection one:
            // an app that is slow to answer must not be able to hold up the
            // keystroke behind it.
            menuQueue.async {
                self.send(.menu(MenuCatalog.shared.profile(forBundleID: bundleID,
                                                           refresh: refresh)),
                          to: client)
            }

        case .requestPanes:
            injectionQueue.async {
                guard Tmux.isAvailable else {
                    self.send(.panes([]), to: client)
                    return
                }
                let live = Tmux.listPanes()
                self.send(.panes(live.map {
                    TmuxPane(id: $0.id, spec: $0.spec, command: $0.command, path: $0.path)
                }), to: client)
                // The store's own view of which targets still resolve is
                // refreshed from the same trip — handing it these panes rather
                // than asking it to refresh, which shelled out for the same
                // answer a second time.
                DispatchQueue.main.async { TargetStore.shared.refreshTmux(with: live) }
            }

        case .requestWindows(let targetID):
            guard let target = TargetStore.shared.safeTarget(id: targetID) else {
                send(.error("Unknown target"), to: client); return
            }
            guard target.kind == .app, let bundleID = target.bundleID, !bundleID.isEmpty else {
                // A pane has no windows to show. Answered rather than ignored,
                // so the phone takes its spinner down.
                send(.windows(WindowListPayload(targetID: targetID, windows: [],
                                                note: "Only a Mac app has windows to pick from.")),
                     to: client)
                return
            }
            // Screenshots and an Accessibility walk, on the queue that is for
            // exactly that kind of work.
            catalogQueue.async {
                Task {
                    let roster = await WindowRoster.windows(ofBundleID: bundleID,
                                                            pinned: target.pinnedWindowID, applicationPath: target.applicationPath)
                    // The app's name, so the phone can write "Claude isn't
                    // running" without knowing what the target is called.
                    let note = roster.note.map { note in
                        note.hasPrefix("is") ? "\(target.name) \(note)" : note
                    }
                    for chunk in WindowListPayload.chunked(roster.windows,
                                                           targetID: targetID,
                                                           note: note, appIdentity: roster.appIdentity) {
                        self.send(.windows(chunk), to: client)
                    }
                }
            }

        case .openWindow(let targetID, let windowID):
            guard let target = TargetStore.shared.safeTarget(id: targetID) else {
                send(.error("Unknown target"), to: client); return
            }
            guard target.kind == .app, let bundleID = target.bundleID, !bundleID.isEmpty else {
                send(.error("Only a Mac app has windows to open"), to: client); return
            }
            // Nil means the window this target is already pointed at, which is
            // the case the mirror hits: the window you were watching got
            // minimised and the only thing wanted is it back.
            guard let wanted = windowID ?? target.pinnedWindowID else {
                send(.error("\(target.name) isn't pointed at a window"), to: client); return
            }
            injectionQueue.async {
                switch WindowRoster.open(windowID: wanted, bundleID: bundleID, name: target.name,
                                        applicationPath: target.applicationPath, appIdentity: target.pinnedAppIdentity) {
                case .raised(let title):
                    DispatchQueue.main.async {
                        TargetStore.shared.setPinnedWindow(wanted, title: title, for: targetID)
                        TargetStore.shared.setActive(targetID)
                        self.note("\(target.name): opened a window",
                                  shown: "\(target.name): opened \(title.isEmpty ? "window \(wanted)" : title)")
                        self.send(.toast("Opened \(title.isEmpty ? target.name : title)"), to: client)
                    }
                case .refused(let why):
                    self.send(.error(why), to: client)
                }
            }

        case .focusWindow(let targetID, let windowID):
            guard let target = TargetStore.shared.safeTarget(id: targetID) else {
                send(.error("Unknown target"), to: client); return
            }
            guard target.kind == .app, let bundleID = target.bundleID, !bundleID.isEmpty else {
                send(.error("Only a Mac app can be pointed at a window"), to: client); return
            }
            // Raising talks to another process, so it is not done on main.
            injectionQueue.async {
                guard let windowID else {
                    DispatchQueue.main.async {
                        TargetStore.shared.setPinnedWindow(nil, title: nil, for: targetID)
                        TargetStore.shared.setActive(targetID)
                        self.send(.toast("\(target.name) follows its front window again"), to: client)
                    }
                    return
                }
                switch WindowRoster.raise(windowID: windowID, bundleID: bundleID,
                                          name: target.name, movingPointer: true, applicationPath: target.applicationPath) {
                case .raised(let title):
                    DispatchQueue.main.async {
                        // Pinned only once the window actually came forward. A
                        // pin written first and refused after is a target
                        // pointing at a window the user never got to.
                        TargetStore.shared.setPinnedWindow(windowID, title: title, for: targetID)
                        TargetStore.shared.setActive(targetID)
                        self.note("\(target.name): showing a window",
                                  shown: "\(target.name): \(title.isEmpty ? "window \(windowID)" : title)")
                        self.send(.toast("Showing \(title.isEmpty ? target.name : title)"), to: client)
                    }
                case .refused(let why):
                    self.send(.error(why), to: client)
                    // The list the phone is holding is out of date — that is
                    // why it asked for a window that could not be raised.
                    Task {
                        let roster = await WindowRoster.windows(ofBundleID: bundleID,
                                                                pinned: target.pinnedWindowID, applicationPath: target.applicationPath)
                        for chunk in WindowListPayload.chunked(roster.windows,
                                                               targetID: targetID,
                                                               note: roster.note, appIdentity: roster.appIdentity) {
                            self.send(.windows(chunk), to: client)
                        }
                    }
                }
            }

        case .requestAppWindows(let identity):
            guard client.appManagementRequested else { break }
            guard let app = AppRegistry.shared.resolve(identity) else {
                send(.toast("That app instance has ended — refresh the list"), to: client)
                break
            }
            let target = onMainActor { TargetStore.shared.offerApp(identity.app, name: app.localizedName ?? identity.app.bundleID) }
            send(.targets(TargetStore.shared.safeDockTargets), to: client)
            Task { [weak self, weak client] in
                let roster = await WindowRoster.windows(ofBundleID: identity.app.bundleID, pinned: target.pinnedWindowID,
                    applicationPath: identity.app.applicationPath)
                guard let self, let client else { return }
                self.queue.async {
                    for payload in WindowListPayload.chunked(roster.windows, targetID: target.id,
                        note: roster.note, appIdentity: roster.appIdentity) { self.send(.windows(payload), to: client) }
                }
            }
        case .requestAppState:
            client.appManagementRequested = true
            onMain { AppRegistry.shared.refresh() }
            send(.appState(AppRegistry.shared.safeSnapshot), to: client)
            TargetStore.shared.refreshProvisional()

        case .requestAppDirectory(let refresh):
            catalogQueue.async {
                let taken = Set(TargetStore.shared.safeTargets.filter { $0.kind == .app }.compactMap(\.bundleID))
                let apps = AppCatalog.shared.suggestions(refresh: refresh, alreadyTargeted: taken,
                                                        limit: Int.max, includeIcons: false)
                for chunk in AppCatalogPayload.chunked(apps, purpose: .suggestions) { self.send(.apps(chunk), to: client) }
            }

        case .appCommand(let request):
            guard client.appManagementRequested, let deviceID = client.deviceID else {
                send(.error("Refresh application state before sending an app action"), to: client); return
            }
            switch appCommands.begin(request, deviceID: deviceID) {
            case .existing(let result): send(.appCommandResult(result), to: client)
            case .conflict:
                send(.appCommandResult(AppCommandResult(requestID: request.id, phase: .failed,
                    message: "That request ID was already used for another action")), to: client)
            case .busy:
                send(.appCommandResult(AppCommandResult(requestID: request.id, phase: .failed,
                    message: "Too many pending app actions — wait for the previous actions")), to: client)
            case .start:
                send(.appCommandResult(AppCommandResult(requestID: request.id, phase: .working,
                    message: "Your Mac is handling the app action", targetID: request.targetID)), to: client)
                Task {
                    let result = await AppController.perform(request)
                    self.queue.async {
                        self.appCommands.finish(result, deviceID: deviceID)
                        self.note(result.message)
                        self.send(.appCommandResult(result), to: client)
                        self.send(.targets(TargetStore.shared.safeDockTargets), to: client)
                        self.send(.status(self.status(forDevice: deviceID)), to: client)
                        self.send(.appState(AppRegistry.shared.safeSnapshot), to: client)
                    }
                    if let id = result.targetID, let target = TargetStore.shared.safeTarget(id: id),
                       let ref = target.appReference {
                        let roster = await WindowRoster.windows(ofBundleID: ref.bundleID, pinned: target.pinnedWindowID,
                                                               applicationPath: ref.applicationPath)
                        for chunk in WindowListPayload.chunked(roster.windows, targetID: id, note: roster.note,
                                                               appIdentity: roster.appIdentity) {
                            self.send(.windows(chunk), to: client)
                        }
                    }
                }
            }

        case .requestApps(let refresh):
            catalogQueue.async {
                // Which apps are already targets is decided here rather than on
                // the phone: the phone's copy of the list can be a moment old,
                // and the picker offering a duplicate is how two tiles for one
                // app get made.
                let taken = Set(TargetStore.shared.safeTargets
                    .filter { $0.kind == .app }
                    .compactMap(\.bundleID))
                let apps = AppCatalog.shared.suggestions(refresh: refresh, alreadyTargeted: taken)
                for chunk in AppCatalogPayload.chunked(apps, purpose: .suggestions) {
                    self.send(.apps(chunk), to: client)
                }
            }

        case .requestAppIcons(let bundleIDs):
            catalogQueue.async {
                let apps = AppCatalog.shared.icons(forBundleIDs: bundleIDs)
                for chunk in AppCatalogPayload.chunked(apps, purpose: .icons) {
                    self.send(.apps(chunk), to: client)
                }
            }

        case .agentEvent(let event):
            let name = TargetStore.shared.safeTarget(id: event.targetID)?.name
                ?? event.sourceName ?? event.targetID
            note("\(name): \(event.kind.rawValue)")
            // Fanned out to every phone: whoever is watching should feel it,
            // and the reporter is usually the CLI rather than a phone.
            broadcast(.agentEvent(event))
            // And to the ones that are not here to be fanned out to. A phone
            // iOS has frozen is not reading the socket that just carried this,
            // so for that phone the line above went nowhere.
            PushSender.shared.send(event, targetName: name, connected: connectedDeviceIDs())

        case .pair:
            // Handled before the switch, on trust sockets only.
            break

        case .registerPush(let registration):
            // Approved devices only, and the same reason as everything else
            // behind that check: a device the user has not accepted is told
            // nothing about this Mac, and being pushed to is being told when
            // its owner is working.
            guard let deviceID = client.deviceID, client.isApproved else {
                send(.error("Approve this device on the Mac first"), to: client)
                break
            }
            PushSender.shared.register(registration, forDevice: deviceID)

        case .requestApproval(let request):
            // Named rather than trusted: the asker supplies a target name, and
            // if it names a target this Mac knows, the phone should see the
            // pane's own name instead of whatever the hook was configured with.
            var resolved = request
            if let id = request.targetID, let known = TargetStore.shared.safeTarget(id: id) {
                resolved.targetName = known.name
            }
            // The same id again is the same hook, back on a new connection
            // after the Mac restarted its listeners: it now answers to this
            // one, and the phones already have its card.
            for other in clients.values where other !== client { other.approvalIDs.remove(resolved.id) }
            client.approvalIDs.insert(resolved.id)
            let asking = resolved
            let connected = connectedDeviceIDs()
            DispatchQueue.main.async {
                // Pushed once, when it first goes up: a duplicate is a card the
                // phones already have, and a refusal is a card they never get.
                guard case .added = ApprovalBroker.shared.submit(asking) else { return }
                PushSender.shared.send(asking, connected: connected)
                self.note("\(asking.targetName) is asking: \(asking.title)")
            }

        case .approvalDecision(let id, let decision, let reason, let answers, let alwaysAllow, let handBack):
            let name = client.name
            let answer = ApprovalAnswer(decision: decision, reason: reason, answers: answers,
                                        alwaysAllow: alwaysAllow ?? false, handBack: handBack ?? false)
            DispatchQueue.main.async {
                ApprovalBroker.shared.decide(id: id, with: answer, by: name)
            }

        case .requestPendingApprovals:
            DispatchQueue.main.async {
                let pending = ApprovalBroker.shared.pending
                self.send(.pendingApprovals(pending), to: client)
            }

        case .directOffer(let peer):
            answerDirectOffer(peer, from: client)

        case .relayTunnelRequest:
            openRelayTunnel(for: client)

        case .directReport(let report):
            miceLog.notice("direct: \(client.name, privacy: .private) measured \(report.summary, privacy: .public)")

        case .viewAck(let sequence):
            // Only a socket that is already a viewer has frames to acknowledge;
            // a viewer becomes one only after `viewHello` passed approval.
            guard client.isViewChannel else { return }
            PanelStreamer.shared.acknowledge(client.connection, sequence: sequence)

        case .viewHello(let hello):
            // A viewer never says `hello`, so it carries the same device id on
            // its own handshake — and is refused on the same terms. A live
            // picture of the screen is not less sensitive than a keystroke.
            guard DeviceRegistry.shared.isApproved(hello.deviceID) else {
                note("refused a panel viewer from \(hello.deviceName): not approved")
                send(.error("Waiting for approval on \(hostDisplayName) — open the Nimlet menu bar item"),
                     to: client, thenClose: true)
                return
            }
            client.isViewChannel = true
            client.name = hello.deviceName
            client.deviceID = hello.deviceID
            // A viewer identifies itself here rather than with `hello`, so this
            // is where it stops being a pending connection. Without it the
            // hello deadline cancelled the mirror ten seconds after it
            // connected, and the phone reconnected, forever.
            register(client)
            publishDevices()
            PanelStreamer.shared.attach(client.connection, hello: hello, far: client.isAway)

        case .listenHello(let hello):
            // Same terms as a viewer, and it is the same argument: this socket
            // says who it is on its own handshake, and a live feed of the room
            // the Mac is sitting in is not less sensitive than a picture of its
            // screen.
            guard DeviceRegistry.shared.isApproved(hello.deviceID) else {
                note("refused a listener from \(hello.deviceName): not approved")
                send(.error("Waiting for approval on \(hostDisplayName) — open the Nimlet menu bar item"),
                     to: client, thenClose: true)
                return
            }
            client.isListenChannel = true
            client.name = hello.deviceName
            client.deviceID = hello.deviceID
            // Like a viewer: this socket identifies itself here rather than with
            // `hello`, so this is where it stops being pending. Without it the
            // hello deadline cancels the audio ten seconds in and the phone
            // reconnects, forever.
            register(client)
            publishDevices()
            AudioStreamer.shared.attach(client.connection, hello: hello)

        case .uploadHello(let manifest):
            // Same terms as a viewer, for the same reason: this socket says who
            // it is on its own handshake, and writing a file to somebody's disk
            // is not less than a keystroke.
            guard DeviceRegistry.shared.isApproved(manifest.deviceID) else {
                note("refused an upload from \(manifest.deviceName): not approved")
                send(.error("Waiting for approval on \(hostDisplayName) — open the Nimlet menu bar item"),
                     to: client, thenClose: true)
                return
            }
            if let refusal = UploadSession.refusal(for: manifest) {
                note("refused an upload from \(manifest.deviceName): \(refusal)")
                send(.error(refusal), to: client, thenClose: true)
                return
            }
            // Every target has to exist before a byte is accepted. The
            // alternative is writing a photograph to disk and then discovering
            // there is nowhere to send it.
            let missing = manifest.targetIDs.filter { TargetStore.shared.safeTarget(id: $0) == nil }
            guard missing.isEmpty else {
                send(.error("No target with that id — it may have been removed"), to: client, thenClose: true)
                return
            }
            client.name = manifest.deviceName
            client.deviceID = manifest.deviceID
            let session = UploadSession(manifest: manifest)
            client.upload = session
            register(client)
            miceLog.info("upload \(session.batchID, privacy: .public): \(manifest.count) attachment(s) from \(manifest.deviceName, privacy: .private)")
            send(.uploadReady(batchID: session.batchID), to: client)

        case .stillHello(let request):
            guard DeviceRegistry.shared.isApproved(request.deviceID) else {
                note("refused a screenshot request from \(request.deviceName): not approved")
                send(.error("Waiting for approval on \(hostDisplayName) — open the Nimlet menu bar item"),
                     to: client, thenClose: true)
                return
            }
            guard NimletProtocol.supports(clientVersion: request.protocolVersion) else {
                send(.error(NimletProtocol.versionRefusal(clientVersion: request.protocolVersion)),
                     to: client, thenClose: true)
                return
            }
            guard let target = TargetStore.shared.safeTarget(id: request.targetID) else {
                send(.error("No target with that id — it may have been removed"), to: client, thenClose: true)
                return
            }
            client.isStillChannel = true
            client.name = request.deviceName
            client.deviceID = request.deviceID
            register(client)
            Task { [weak self] in
                guard let self else { return }
                switch await StillCapture.capture(target, maxLongEdge: request.maxLongEdge) {
                case .failure(let refusal):
                    self.queue.async {
                        self.note("Screenshot refused: \(refusal.message)")
                        self.send(.error(refusal.message), to: client, thenClose: true)
                    }
                case .success(let still):
                    let frame = StillFrame(title: still.title,
                                           width: Int(still.pixelSize.width),
                                           height: Int(still.pixelSize.height),
                                           byteCount: still.png.count)
                    guard let data = try? StillFrameWriter.encode(frame, payload: still.png) else {
                        self.queue.async {
                            self.send(.error("Couldn't encode the screenshot"), to: client, thenClose: true)
                        }
                        return
                    }
                    miceLog.info("still: \(frame.width, privacy: .public)×\(frame.height, privacy: .public), \(still.png.count, privacy: .public) bytes to \(request.deviceName, privacy: .private)")
                    self.queue.async { self.sendRaw(data, to: client, thenClose: true) }
                }
            }

        case .ping(let nonce):
            send(.pong(nonce: nonce, hostTime: Instrumentation.now()), to: client)
        }
    }

    /// A pane spec names a slot that renumbers; only its stable id is stored.
    /// Shared by the add and edit paths, which both have to do it before the
    /// store sees the target.
    private static func resolvingPane(_ requested: NimletTarget) -> NimletTarget {
        guard requested.kind == .tmux, let spec = requested.tmuxTarget, !spec.isEmpty else {
            return requested
        }
        var target = requested
        target.tmuxTarget = Tmux.resolve(spec: spec) ?? spec
        return target
    }

    /// `hello` and `ping` are all a device may do before the user has said yes
    /// to it. Everything else reaches the keyboard one way or another.
    private func isPermitted(_ message: ClientMessage, from client: Client) -> Bool {
        switch message {
        // A viewer's handshake, like the control one, has to arrive before the
        // host knows who is asking; the case above checks approval itself.
        case .hello, .ping, .viewHello, .listenHello, .uploadHello, .stillHello:
            return true
        // A viewer never says `hello`; the handler checks it is one.
        case .viewAck:
            return true
        default:
            break
        }
        guard client.didHello, let deviceID = client.deviceID else {
            send(.error("Send hello first"), to: client, thenClose: true)
            return false
        }
        guard DeviceRegistry.shared.isApproved(deviceID) else {
            // Pointer deltas arrive 120 times a second, and refusing each one
            // in writing would bury the phone in identical errors.
            let now = Date()
            if now.timeIntervalSince(client.lastRefusal) > 1 {
                client.lastRefusal = now
                send(.error("Waiting for approval on \(hostDisplayName) — open the Nimlet menu bar item"), to: client)
            }
            return false
        }
        return true
    }

    /// A phone that scanned this Mac's QR code, proving it.
    ///
    /// The proof is bound to this TLS session's exporter and to the key the
    /// phone authenticated with, so it can be neither replayed on another
    /// connection nor lifted onto another device. A good one approves the
    /// device outright: reading the code off this screen is the physical
    /// presence the approval prompt exists to stand for.
    private func pair(_ request: PairRequest, as peer: TrustFingerprint, from client: Client) {
        guard !client.isAway,
              let exporter = TrustTransport.exporter(of: client.connection, label: PairingProof.exporterLabel),
              HostTrust.shared.redeem(request.proof, exporter: exporter, device: peer, name: request.deviceName) else {
            note("refused a pairing attempt from \(request.deviceName)")
            noteHandshakeFailure(client.source, error: "bad pairing proof")
            send(.pairResult(PairResult(ok: false,
                                        message: "That pairing code has expired or was already used. Show a new one on your Mac and scan it again.")),
                 to: client, thenClose: true)
            return
        }
        DeviceRegistry.shared.approveFromNetwork(deviceID: peer.description, name: request.deviceName)
        client.name = request.deviceName
        note("Paired \(request.deviceName) by key")
        send(.pairResult(PairResult(ok: true)), to: client)
    }

    private func greet(_ hello: HelloPayload, from client: Client) {
        guard NimletProtocol.supports(clientVersion: hello.protocolVersion) else {
            // A deliberate refusal, so it must not count towards the lockout
            // the way a guessed code does.
            throttles[client.source] = nil
            if hello.protocolVersion > NimletProtocol.version {
                note("\(hello.deviceName) runs a newer Nimlet (protocol \(hello.protocolVersion)); this Mac speaks \(NimletProtocol.version)")
                let seen = NewerPhone(name: hello.deviceName, protocolVersion: hello.protocolVersion)
                DispatchQueue.main.async { self.newerPhone = seen }
            }
            send(.error(NimletProtocol.versionRefusal(clientVersion: hello.protocolVersion)),
                 to: client, thenClose: true)
            return
        }

        client.name = hello.deviceName
        client.deviceID = hello.deviceID
        client.didHello = true
        // Which build is on the other end is the first question when a phone
        // "cannot pair": a phone on protocol 23 cannot open a QR code at all.
        miceLog.notice("hello: \(hello.deviceName, privacy: .private) speaks protocol \(hello.protocolVersion, privacy: .public) via \(client.route, privacy: .public)")
        register(client)
        throttles[client.source] = nil

        // The revoked list was being written and never read, so a device the
        // user had explicitly turned away came back a minute later looking like
        // a stranger they had never ruled on, with an Approve button beside it.
        if DeviceRegistry.shared.isRevoked(hello.deviceID) {
            note("\(hello.deviceName) was revoked; refusing it")
            send(.error(ConnectionRejection.revokedMessage),
                 to: client, thenClose: true)
            return
        }

        let approved = DeviceRegistry.shared.seen(deviceID: hello.deviceID, name: hello.deviceName)
        if !approved {
            note("\(hello.deviceName) is waiting to be approved")
            let waiting = ConnectedDevice(id: hello.deviceID, name: hello.deviceName, approved: false,
                                          isHearing: false, route: client.route)
            DispatchQueue.main.async {
                if !self.awaitingApproval.contains(where: { $0.id == waiting.id }) {
                    self.awaitingApproval.append(waiting)
                }
            }
        }
        // This phone is here, and the first thing it did on arriving was clear
        // its own lock screen. Whatever the Mac believed was on it is now a
        // belief about notifications the user has already dealt with, and the
        // badge on the next push would count them.
        PushSender.shared.deviceArrived(hello.deviceID)
        publishDevices()
        // `welcome` went out when the connection became ready, before anyone
        // knew who this was, so it carried no targets. Now that the device has
        // a name and an answer, send both.
        send(.welcome(status: status(forDevice: hello.deviceID),
                      targets: approved ? TargetStore.shared.safeTargets : []),
             to: client)
        if approved {
            send(.targets(TargetStore.shared.safeDockTargets), to: client)
            // Unasked, and on every connection: the addresses may have moved
            // while this phone was away, and the phone that needs the new ones
            // is by definition not the one that could have asked for them.
            sendRemoteAccess(to: client)
            // A phone that was asleep, backgrounded or on the wrong network
            // reconnects into a Mac that may already have a blocked agent on
            // it. Sent unasked, because the one thing worse than a late answer
            // is a phone that looks idle while a run waits.
            DispatchQueue.main.async {
                let pending = ApprovalBroker.shared.pending
                guard !pending.isEmpty else { return }
                self.send(.pendingApprovals(pending), to: client)
            }
        }
    }

    private func sendVocabulary(for target: NimletTarget, to client: Client) {
        Vocabulary.shared.queue.async {
            let terms = Vocabulary.shared.terms(for: target)
            // An empty set still ends in a final chunk, so the phone stops
            // waiting instead of holding an old vocabulary it can't refresh.
            let bounds = stride(from: 0, to: max(terms.count, 1), by: Vocabulary.chunkSize)
            let chunks = bounds.map { start in
                Array(terms[start..<min(start + Vocabulary.chunkSize, terms.count)])
            }
            for (index, chunk) in chunks.enumerated() {
                self.send(.vocabulary(VocabularyPayload(targetID: target.id,
                                                        terms: chunk,
                                                        sequence: index,
                                                        isFinal: index == chunks.count - 1)),
                          to: client)
            }
            miceLog.info("vocabulary for \(target.name, privacy: .public): \(terms.count) terms in \(chunks.count) chunk(s)")
        }
    }

    /// One line for the log and the menu. `shown` is the menu's version when
    /// it differs: the menu is on the user's own screen and may name a window
    /// or an address, while the log ends up pasted into bug reports and
    /// may not.
    private func note(_ message: String, shown: String? = nil) {
        miceLog.info("\(message, privacy: .public)")
        let shown = shown ?? message
        DispatchQueue.main.async { self.lastActivity = shown }
    }

    /// A tap that was refused has to say so, or it is a tap that did nothing.
    /// Once per couple of seconds: a double tap is two refusals.
    private func noteMirrorSwitching(to client: Client) {
        let now = Date()
        guard now.timeIntervalSince(client.lastSwitchingNote) > 2 else { return }
        client.lastSwitchingNote = now
        send(.toast("The mirror was still switching windows — tap again"), to: client)
    }

    // MARK: - Letting go

    /// Checks for phones that have gone quiet holding a button.
    private var silenceWatch: DispatchSourceTimer?

    /// Runs on `queue` while some phone holds a button, and only then: a
    /// menu-bar app that woke once a second for ever would do so for nothing
    /// nearly all of the time.
    private func beginSilenceWatch() {
        guard silenceWatch == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in self?.releaseSilentHolds() }
        timer.resume()
        silenceWatch = timer
    }

    /// Lets go of what a silent phone was holding, without closing its socket.
    ///
    /// The socket may yet come back — a lift ride, a tunnel — and closing it
    /// is TCP's decision. What cannot wait for TCP is a button held down on the
    /// Mac by a phone that is no longer there: every click the person makes at
    /// the keyboard meanwhile becomes part of a drag.
    private func releaseSilentHolds() {
        let now = Date()
        for client in clients.values where !client.heldButtons.isEmpty {
            guard InputGuard.isSilent(since: client.lastHeardAt, now: now) else { continue }
            let silence = now.timeIntervalSince(client.lastHeardAt)
            miceLog.error("\(client.name, privacy: .private) silent for \(silence, format: .fixed(precision: 1))s holding \(client.heldButtons.map(\.rawValue).sorted().joined(separator: ","), privacy: .public); releasing")
            EventInjector.shared.release(buttons: client.heldButtons)
            client.heldButtons.removeAll()
        }
        if clients.values.allSatisfy({ $0.heldButtons.isEmpty }) {
            silenceWatch?.cancel()
            silenceWatch = nil
        }
    }

    /// Pointer deltas arrive ~120x/second, so log a rate rather than each one.
    private var moveCount = 0
    private var moveWindowStart = Date()

    private func countMove() {
        moveCount += 1
        let elapsed = Date().timeIntervalSince(moveWindowStart)
        guard elapsed >= 1 else { return }
        let rate = Double(moveCount) / elapsed
        let trusted = EventInjector.shared.isTrusted
        miceLog.info("pointer: \(rate, format: .fixed(precision: 0)) moves/s, accessibility=\(trusted, privacy: .public)")
        moveCount = 0
        moveWindowStart = Date()
    }

    // MARK: - Outbound

    /// Approval is per device, so the status is too.
    func status(forDevice deviceID: String?) -> HostStatus {
        HostStatus(hostName: hostDisplayName,
                   accessibilityGranted: EventInjector.shared.isTrusted,
                   injectionPaused: EventInjector.shared.isPaused,
                   activeTargetID: TargetStore.shared.safeActiveTargetID,
                   deviceApproved: deviceID.map { DeviceRegistry.shared.isApproved($0) } ?? false,
                   tmuxAvailable: Tmux.isAvailable,
                   screenRecordingGranted: ScreenAccess.isGranted,
                   unresolvedTargetIDs: Array(TargetStore.shared.safeUnresolvedTargetIDs),
                   pushRelayConfigured: PushSender.shared.isConfigured, appManagementVersion: 1,
                   agentWaitSeconds: Int(AgentWait.seconds))
    }

    private func send(_ message: HostMessage, to client: Client, thenClose: Bool = false) {
        guard let data = try? NimletCoder.line(message) else {
            if thenClose { client.connection.cancel() }
            return
        }
        client.connection.send(content: data, completion: .contentProcessed { _ in
            if thenClose { client.connection.cancel() }
        })
    }

    /// Writes bytes that are not a message: the one length-prefixed frame a
    /// still request is answered with.
    private func sendRaw(_ data: Data, to client: Client, thenClose: Bool = false) {
        client.connection.send(content: data, completion: .contentProcessed { _ in
            if thenClose { client.connection.cancel() }
        })
    }

    /// The phones with a live control socket right now.
    ///
    /// The one input `PushRouter` cannot work out for itself, and the rule that
    /// keeps this feature from being annoying: a phone that is connected is
    /// already being told the ordinary way, over a socket that exists, with
    /// nothing passing through anybody's relay. Pushing to it as well would be
    /// a second buzz about the same thing, routed the worse of the two ways.
    ///
    /// Read synchronously because every caller is already on `queue`.
    private func connectedDeviceIDs() -> Set<String> {
        Set(clients.values.compactMap { client in
            client.isControlChannel ? client.deviceID : nil
        })
    }

    /// Fans out to approved devices only. `.targets` and `.agentEvent` both
    /// describe what the user is working on, and an unapproved peer has been
    /// told nothing else about this Mac.
    func broadcast(_ message: HostMessage) {
        guard let data = try? NimletCoder.line(message) else { return }
        queue.async {
            for client in self.clients.values where client.isApproved && client.isControlChannel {
                client.connection.send(content: data, completion: .contentProcessed { _ in })
            }
        }
    }

    private func broadcastAppState(_ snapshot: AppRuntimeSnapshot) {
        queue.async {
            for client in self.clients.values where client.appManagementRequested {
                self.send(.appState(snapshot), to: client)
            }
        }
    }

    func broadcastStatus() {
        queue.async {
            for client in self.clients.values {
                self.send(.status(self.status(forDevice: client.deviceID)), to: client)
            }
        }
    }

    /// The dock, both halves of it: the targets the user curated, then the
    /// panes and apps that are live with nothing pointing at them.
    ///
    /// One message rather than two. A phone that splits them draws a divider; a
    /// phone on an older build that knows nothing about `isProvisional` simply
    /// shows a longer dock in which every tile works, which is the right way to
    /// be wrong about this.
    func broadcastTargets() {
        let dock = TargetStore.shared.safeDockTargets
        queue.async { self.broadcast(.targets(dock)) }
    }

    // MARK: - Devices

    func approve(_ device: ConnectedDevice) {
        DeviceRegistry.shared.approve(deviceID: device.id, name: device.name)
        note("Approved \(device.name)")
    }

    /// Answered "not now": off the list until it knocks again.
    func dismissWaiting(deviceID: String) {
        awaitingApproval.removeAll { $0.id == deviceID }
    }

    /// Revoked and then off the list, for a phone that has been replaced: it
    /// is not coming back to be approved again, and a revoked row for it would
    /// sit under the new phone's name forever.
    func remove(deviceID: String) {
        revoke(deviceID: deviceID)
        DeviceRegistry.shared.forget(deviceID: deviceID)
    }

    func revoke(deviceID: String) {
        awaitingApproval.removeAll { $0.id == deviceID }
        DeviceRegistry.shared.revoke(deviceID: deviceID)
        // The away key goes with the approval. Without this a revoked phone still
        // holds a key the internet-facing listener accepts — it would be refused
        // at the application layer, which is a socket it should never have got.
        AwayKeys.forget(deviceID: deviceID)
        // And the push registration, for the same reason: a revoked phone must
        // not go on being told when its owner's agents need attention. Without
        // the key there is nothing to seal for it anyway, so this is belt and
        // braces — but the belt is what stops a relay being asked to deliver.
        PushSender.shared.forget(deviceID: deviceID)
        // Outgoing streams do not receive another command on which to check
        // approval. Revoke every socket, including a local audio connection.
        queue.async {
            for client in self.clients.values where client.deviceID == deviceID {
                AudioStreamer.shared.detach(client.connection)
                client.connection.cancel()
            }
            self.closeDirectTunnel(for: deviceID, "the device was revoked")
        }
        startAway()
        broadcastStatus()
        publishDevices()
    }
}
