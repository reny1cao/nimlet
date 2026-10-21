import Foundation
import Combine

/// Keeps this Mac registered with the connect relay while it should be.
///
/// Three conditions, all of them: away access is on (the relay is one more way
/// in from away, and the switch is the user's word on whether there is any),
/// a relay is configured, and at least one phone is paired by key (the relay
/// pumps into the away listener, which accepts nothing else). A distribution
/// build can include a relay and its public key; plain checkouts leave both
/// empty. Neither starts a connection until the user enables away access.
///
///   defaults write com.renyicao.mice.host mice.relay relay.example.com:7443
///   defaults write com.renyicao.mice.host mice.relayFingerprint <what the relay printed>
///
/// Both, because the Mac pins the relay's key: a relay address without the
/// key to expect is not a relay this Mac will talk to. See
/// Relay/connect/README.md.
@MainActor
final class RelayService: ObservableObject {
    static let shared = RelayService()

    enum Status: Equatable {
        case off
        case connecting
        case registered
        case failed(String)
    }

    @Published private(set) var status: Status = .off
    private var link: RelayLink?
    /// What `mice.relay` said when `link` was made, to tell a changed setting
    /// from an unchanged one without re-parsing either.
    private var linkConfiguration: String?
    private var cancellables = Set<AnyCancellable>()

    private init() {}

    nonisolated static var configured: String? {
        configuration?.address
    }

    /// The relay's key, as the relay prints it at startup, or nil if it is
    /// missing or not a fingerprint.
    nonisolated static var configuredFingerprint: TrustFingerprint? {
        configuration?.fingerprint
    }

    nonisolated private static var configuration: ConnectRelayConfiguration? {
        ConnectRelayConfiguration.resolve(preferences: UserDefaults.standard.dictionaryRepresentation(),
                                          bundle: Bundle.main.infoDictionary ?? [:])
    }

    /// Called once at launch, after `RemoteReach.begin()`.
    func begin() {
        RemoteReach.shared.$status
            .removeDuplicates()
            .sink { [weak self] _ in Task { @MainActor in self?.reconcile() } }
            .store(in: &cancellables)
        DeviceRegistry.shared.$approved
            .map { Set($0.map(\.id)) }
            .removeDuplicates()
            .sink { [weak self] _ in Task { @MainActor in self?.reconcile() } }
            .store(in: &cancellables)
        reconcile()
    }

    func reconcile() {
        let relay = Self.configured
        let wanted = LaunchNetworkPolicy.allowsAwayAccess && RemoteReach.shared.isEnabled && relay != nil
            && HostTrust.shared.identity != nil && HostTrust.shared.hasTrustedDevices
        guard wanted, let relay, let identity = HostTrust.shared.identity else {
            if link != nil { stop() }
            return
        }
        guard let fingerprint = Self.configuredFingerprint else {
            stop()
            status = .failed("Set mice.relayFingerprint to the key the relay prints when it starts")
            return
        }
        // The settings and the port it pumps into: a change to any is a new link.
        let configuration = "\(relay)|\(fingerprint)|\(RemoteReach.port)"
        if link != nil, linkConfiguration == configuration { return }
        stop()
        guard let fresh = RelayLink(relay: relay, relayFingerprint: fingerprint,
                                    identity: identity, localPort: RemoteReach.port) else {
            status = .failed("mice.relay should be host:port")
            return
        }
        fresh.onStateChange = { [weak self] state in
            Task { @MainActor in self?.apply(state) }
        }
        link = fresh
        linkConfiguration = configuration
        status = .connecting
        fresh.start()
        miceLog.info("relay: connecting to \(relay, privacy: .public)")
    }

    private func stop() {
        link?.stop()
        link = nil
        linkConfiguration = nil
        if status != .off { status = .off; HostServer.shared.broadcastRemoteAccess() }
    }

    private func apply(_ state: RelayLink.State) {
        let was = status
        switch state {
        case .connecting: status = .connecting
        case .registered: status = .registered
        case .failed(let why): status = .failed(why)
        }
        if case .registered = state { miceLog.info("relay: registered") }
        // A phone learns the relay is there — or no longer is — the same way it
        // learns any other address: pushed, unasked.
        if (was == .registered) != (status == .registered) { HostServer.shared.broadcastRemoteAccess() }
    }

    /// A UDP pair at the relay for one phone's session (`RelayDatagramGrant`),
    /// or nil with why not.
    func requestDatagramPair(completion: @escaping @Sendable (RelayDatagramGrant?, String?) -> Void) {
        guard status == .registered, let link else {
            return completion(nil, "this Mac is not registered with the relay")
        }
        let token = RelayDatagramGrant.newToken()
        let host = link.relayHost
        link.requestDatagramPair(token: token) { port in
            guard let port else { return completion(nil, "the relay did not offer UDP") }
            completion(RelayDatagramGrant(host: host, port: port, token: token), nil)
        }
    }

    /// The relay as an address a phone paired by key can dial, while this Mac
    /// is registered with it.
    var candidate: NimletCandidate? {
        guard status == .registered, let link else { return nil }
        return NimletCandidate(host: link.relayHost, port: link.relayPort, reach: .relay, via: "relay")
    }
}
