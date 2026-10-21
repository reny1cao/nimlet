import Foundation
import Network
import Combine

/// The per-device push keys, and nothing else.
///
/// One key per approved phone, 256 bits, in the Keychain. They seal pushes
/// (`PushEnvelope`) and are issued only to a phone paired by key, over the LAN.
enum AwayKeys {

    /// The key for a device, made if it does not have one yet.
    ///
    /// Issued for approved devices only. The caller checks that, and it matters:
    /// a key handed to a device the user has not accepted would be a way in that
    /// the approval step was supposed to gate.
    static func issue(forDevice deviceID: String) -> Data? {
        if let existing = SecretStore.read(service: SecretStore.awayService, account: deviceID),
           existing.count == RemoteAccess.keyLength {
            return existing
        }
        let fresh = NimletTransport.newRemoteKey()
        guard SecretStore.write(fresh, service: SecretStore.awayService, account: deviceID) else {
            return nil
        }
        miceLog.info("away: issued a key for \(deviceID, privacy: .private)")
        return fresh
    }

    static func existing(forDevice deviceID: String) -> Data? {
        SecretStore.read(service: SecretStore.awayService, account: deviceID)
    }

    static func forget(deviceID: String) {
        guard SecretStore.delete(service: SecretStore.awayService, account: deviceID) else { return }
        miceLog.info("away: dropped the key for \(deviceID, privacy: .private)")
    }
}

/// Being reachable from somewhere that is not this network.
///
/// Off by default, and it stays off until the user says otherwise, because what
/// it does is put a port that injects keystrokes into this Mac on the public
/// internet. When it is on, the sequence is:
///
/// 1. Note every address this Mac has — the private ones for the LAN, and any
///    globally routable IPv6 address, which has no NAT in front of it.
/// 2. Ask the router to forward the away port, by PCP, then NAT-PMP, then UPnP.
/// 3. Learn the public IPv4 address: from the router, which knows it, or from a
///    STUN server when the router will not say.
/// 4. Hand the whole list to every connected phone, which remembers it and dials
///    the best one that answers.
/// 5. Renew the mapping at half its lifetime, and redo all of it whenever the
///    network changes underneath.
///
/// The one case this cannot solve is named rather than retried: if the address
/// the internet sees is inside `100.64.0.0/10`, the Mac is behind its ISP's own
/// NAT, the router has no public address to forward, and nothing here will ever
/// work. That needs the connect relay (`RelayService`), if one is configured.
/// The status says so.
@MainActor
final class RemoteReach: ObservableObject {
    static let shared = RemoteReach()

    enum Status: Equatable {
        /// The user has not turned this on.
        case off
        /// Asking the router.
        case working
        /// There is a way in.
        case reachable
        /// There is not, and this is why, in words for the user.
        case blocked(String)

        var isOn: Bool { self != .off }
    }

    @Published private(set) var status: Status = .off
    /// Every address worth trying, best first. The local ones are in here even
    /// when away access is off — they are what Bonjour would have found anyway —
    /// so a phone always has something to fall back on.
    @Published private(set) var candidates: [NimletCandidate] = []
    /// One line for the menu bar: "PCP · 203.0.113.9:61423".
    @Published private(set) var detail: String?

    private let mapper = PortMapper()
    private var monitor: NWPathMonitor?
    private var renewal: Timer?
    private var refreshTask: Task<Void, Never>?
    private var lastPathSignature: String?

    /// Whether away access is on, readable from the network queue.
    ///
    /// `nonisolated` and straight out of preferences: `HostServer` builds the
    /// away listener on its own queue and cannot hop to the main actor to ask,
    /// and this is one boolean that the main actor does not own any more of the
    /// truth about than the file does.
    nonisolated static var isEnabledForListener: Bool {
        LaunchNetworkPolicy.allowsAwayAccess && UserDefaults.standard.bool(forKey: "mice.away.enabled")
    }

    /// Where the away listener binds, and the port the router is asked to
    /// forward to it.
    nonisolated static var port: UInt16 {
        let override = UserDefaults.standard.integer(forKey: "mice.awayPort")
        guard override > 1024, override <= 65535 else { return RemoteAccess.defaultPort }
        return UInt16(override)
    }

    /// Two hours, which both protocols are happy with and neither treats as
    /// permanent. Renewed at half of it.
    nonisolated private static let lease: UInt32 = 7200

    private let enabledKey = "mice.away.enabled"

    var isEnabled: Bool {
        get { LaunchNetworkPolicy.allowsAwayAccess && UserDefaults.standard.bool(forKey: enabledKey) }
        set {
            guard LaunchNetworkPolicy.allowsAwayAccess, newValue != isEnabled else { return }
            UserDefaults.standard.set(newValue, forKey: enabledKey)
            if newValue { start() } else { stop() }
        }
    }

    private init() {}

    /// Called once at launch. Picks up where the last run left off, and always
    /// publishes the local addresses whether away access is on or not.
    func begin() {
        refreshLocal()
        watchPath()
        guard isEnabled else { return }
        start()
    }

    // MARK: - On and off

    private func start() {
        guard SecretStore.isUsable() else {
            status = .blocked("This Mac's Keychain would not store the away key")
            miceLog.error("away: the Keychain refused to store a key; away access cannot be switched on")
            return
        }
        status = .working
        watchPath()
        refresh()
    }

    private func stop() {
        refreshTask?.cancel()
        refreshTask = nil
        renewal?.invalidate()
        renewal = nil
        status = .off
        detail = nil
        let port = Self.port
        // Give the port back rather than leaving a hole in somebody's router
        // until the lease runs out.
        Task { await mapper.unmap(internalPort: port) }
        refreshLocal()
    }

    /// At quit, with the switch left on: the mapping is deleted now rather
    /// than left to expire. Bounded, because `applicationWillTerminate` does
    /// not wait for anything that does not make it wait.
    func releaseMappingForQuit() {
        guard isEnabled, status != .off else { return }
        let port = Self.port
        let done = DispatchSemaphore(value: 0)
        Task {
            await mapper.unmap(internalPort: port)
            done.signal()
        }
        _ = done.wait(timeout: .now() + 1.5)
    }

    /// How many phones are paired by key, which is who the away listener lets
    /// in. Zero means the port may be open and the address published, and
    /// nothing can use it yet.
    var pairedPhoneCount: Int { HostTrust.shared.trustedDeviceCount }

    /// What the router was asked for and would not give, published so a
    /// person who forwards the port by hand is used straight away. Not worth a
    /// phone's attempt once the relay is up.
    private static let unforwarded = "not forwarded yet"

    /// Redo the whole sequence. Safe to call at any time; the previous attempt is
    /// cancelled rather than raced.
    func refresh() {
        guard isEnabled else { refreshLocal(); return }
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            await self?.resolve()
        }
    }

    // MARK: - Resolving

    private func resolve() async {
        let port = Self.port
        var found: [NimletCandidate] = localCandidates()

        let outcome = await mapper.map(internalPort: port, lifetime: Self.lease)
        guard !Task.isCancelled else { return }

        switch outcome {
        case .success(let mapping):
            // The router's own answer first; STUN only when it would not say.
            var external = mapping.externalHost
            var reflexive: StunWire.Reflexive?
            if external == nil || UPnPGateway.isPrivate(external!) {
                reflexive = await PublicAddress.reflexive(over: await PortMapper.physicalInterface())
                external = reflexive?.isIPv6 == false ? reflexive?.host : nil
            }
            guard !Task.isCancelled else { return }

            if let external, !UPnPGateway.isPrivate(external) {
                found.append(NimletCandidate(host: external,
                                           port: mapping.externalPort,
                                           reach: .forwarded4,
                                           via: mapping.via))
                detail = "\(mapping.via) · \(external):\(mapping.externalPort)"
                status = .reachable
            } else if let reflexive, reflexive.isCarrierGradeNAT {
                blockOnCarrierNAT()
            } else {
                // A mapping with no address to put in front of it. The port is
                // forwarded and nobody can be told where to.
                detail = "\(mapping.via) · port \(mapping.externalPort)"
                status = .blocked("Your router forwarded the port but would not say what its public address is")
            }
            scheduleRenewal(after: mapping.lifetime)

        case .failure(.carrierGradeNAT(let why)):
            blockOnCarrierNAT(why)

        case .failure(.refused(let why)):
            status = .blocked("Your router refused to forward a port — \(why)")
            detail = nil

        case .failure(.noGateway), .failure(.silent):
            // Nothing answered, which is the ordinary outcome on a router with
            // UPnP switched off. Before calling it, find out whether there is
            // any point: a Mac with a public address of its own needs no
            // forwarding at all, and one behind a carrier's NAT can never have it.
            let reflexive = await PublicAddress.reflexive(over: await PortMapper.physicalInterface())
            guard !Task.isCancelled else { return }
            if let reflexive, reflexive.isCarrierGradeNAT {
                blockOnCarrierNAT()
            } else if let reflexive, !reflexive.isIPv6,
                      localCandidates().contains(where: { $0.host == reflexive.host }) {
                // No NAT in the way at all: the address the internet sees is one
                // of this Mac's own, so the listener is already reachable on it.
                found.append(NimletCandidate(host: reflexive.host, port: port,
                                           reach: .forwarded4, via: "no NAT"))
                detail = "direct · \(reflexive.host):\(port)"
                status = .reachable
            } else if let reflexive, !reflexive.isIPv6 {
                // The router would not open a port, but there is a public address
                // in front of it and it is a real one. Publish it anyway: if the
                // user forwards the port by hand — which is the advice below —
                // this is the address it will be forwarded on, and the phone
                // starts using it without anybody coming back here to say so.
                // Costs a phone one failed connection attempt until then.
                found.append(NimletCandidate(host: reflexive.host, port: port,
                                           reach: .forwarded4, via: Self.unforwarded))
                detail = "seen as \(reflexive.host):\(port)"
                status = .blocked("Your router would not open a port by itself. Turn on UPnP, NAT-PMP or PCP in its settings — or forward TCP \(port) to this Mac by hand, and Nimlet will start using it.")
            } else {
                detail = nil
                status = .blocked("Your router would not open a port, and nothing on the internet could say what this Mac's public address is.")
            }
        }

        // IPv6 is published whether or not any of the above worked, and it is
        // tried before the forwarded port: there is no NAT to traverse and
        // nothing to keep alive. A router that blocks unsolicited inbound IPv6 —
        // most do by default — simply makes this candidate fail, which costs the
        // phone one connection attempt.
        found.append(contentsOf: globalCandidates(port: port))
        candidates = CandidateOrder.sorted(found)
        miceLog.info("away: \(self.candidates.count, privacy: .public) candidates, \(String(describing: self.status), privacy: .public)")
    }

    private func blockOnCarrierNAT(_ why: String? = nil) {
        detail = nil
        status = .blocked(why ?? "Your internet connection is behind your ISP's own NAT, so there is no port to forward. Reaching this Mac from away needs the connect relay (mice.relay).")
    }

    /// The local addresses, and nothing that leaves the building. Published even
    /// with away access off: they are what a phone on this network uses, and the
    /// phone keeping a copy means it reconnects at the desk without waiting for
    /// Bonjour.
    private func refreshLocal() {
        var found = localCandidates()
        if isEnabled { found.append(contentsOf: globalCandidates(port: Self.port)) }
        candidates = CandidateOrder.sorted(found)
    }

    private func localCandidates() -> [NimletCandidate] {
        PublicAddress.interfaces().local.map {
            NimletCandidate(host: $0, port: HostServer.shared.trustPort, reach: .local, via: OverlayAddress.contains($0) ? "VPN" : "this network")
        }
    }

    private func globalCandidates(port: UInt16) -> [NimletCandidate] {
        PublicAddress.interfaces().global6.map {
            NimletCandidate(host: $0, port: port, reach: .internet6, via: "IPv6")
        }
    }

    // MARK: - Keeping it

    /// Renewed at half the lease. A mapping is a lease on purpose: a Mac that is
    /// switched off stops being reachable within the hour instead of leaving a
    /// forwarded port behind it forever.
    private func scheduleRenewal(after lifetime: UInt32) {
        renewal?.invalidate()
        let interval = max(TimeInterval(lifetime) / 2, 60)
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        renewal = timer
    }

    /// Joining a network, a cable going in, an ISP handing out a new address: all
    /// of them change the answer and none of them announce it.
    private func watchPath() {
        monitor?.cancel()
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            // A signature rather than the path itself: `pathUpdateHandler` fires
            // for changes that do not move any address Nimlet publishes, and each
            // one would otherwise re-ask the router and re-issue a mapping.
            let addresses = PublicAddress.interfaces()
            let signature = path.availableInterfaces.map(\.name).sorted().joined(separator: ",")
                + "|\(path.status)|" + (addresses.local + addresses.global6).sorted().joined(separator: ",")
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard signature != self.lastPathSignature else { return }
                self.lastPathSignature = signature
                // The router on a network we have just joined has never heard of
                // this Mac, so the next request is a new mapping rather than a
                // renewal of one it does not have.
                await self.mapper.forgetMapping()
                self.refresh()
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.renyicao.mice.host.away.path"))
        self.monitor = monitor
    }

    // MARK: - What the phone is told

    /// The message for one phone paired by key: the addresses, and its push
    /// key.
    ///
    /// - Parameter isLocalPeer: whether this connection came from this Mac's own
    ///   network. The key is only ever issued over one that did, never down the
    ///   internet-facing path.
    func payload(forDevice deviceID: String, isLocalPeer: Bool) -> RemoteAccessPayload {
        var payload = RemoteAccessPayload(isEnabled: isEnabled,
                                          candidates: candidates,
                                          unavailable: unavailableReason)
        // Last, because every byte crosses somebody else's server — and when it
        // is there, "there is no way in" is no longer true.
        if let relay = RelayService.shared.candidate {
            // An address the Mac already knows is not forwarded costs the phone
            // a whole attempt deadline before it reaches the relay.
            payload.candidates.removeAll { $0.via == Self.unforwarded }
            payload.candidates.append(relay)
            payload.unavailable = nil
        }
        guard isEnabled, isLocalPeer, DeviceRegistry.shared.isApproved(deviceID) else { return payload }
        guard let key = AwayKeys.issue(forDevice: deviceID) else {
            payload.unavailable = "This Mac's Keychain would not store the push key"
            return payload
        }
        payload.pushKey = key
        return payload
    }

    private var unavailableReason: String? {
        if case .blocked(let why) = status { return why }
        if !isEnabled {
            if candidates.contains(where: { OverlayAddress.contains($0.host) }) {
                return "Direct internet access is off. For another Wi-Fi or cellular, connect Tailscale on both devices; this phone has saved the Mac's VPN address."
            }
            return "Direct internet access is off on your Mac. Connect on the same network, or enable Reachable on cellular in the Mac menu while this phone is connected. A VPN is another option."
        }
        return nil
    }
}
