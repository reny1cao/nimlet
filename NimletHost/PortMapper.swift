import Foundation
import Network

/// One question-and-answer over UDP.
///
/// Every protocol in the away path is one datagram out and one back — PCP,
/// NAT-PMP, STUN — and all three are talking to something that may not be there
/// at all. So the shape is the same every time: send, wait a short while, give up
/// quietly. Giving up is the normal outcome, not an error: most routers do not
/// speak most of these.
enum UDPExchange {

    /// Sends `request` and returns the first datagram that comes back, or nil.
    ///
    /// Also hands back the local address the datagram went out from, which PCP
    /// needs to put in its own payload — the router compares the two and refuses
    /// a mapping asked for through the wrong interface.
    static func ask(_ request: Data,
                    of endpoint: NWEndpoint,
                    over interface: NWInterface? = nil,
                    timeout: TimeInterval = 0.9) async -> (reply: Data, localAddress: String?)? {
        let parameters = NWParameters.udp
        parameters.preferNoProxies = true
        // Pinned to the interface the router is on, when one is known. Not
        // optional politeness: with a VPN up, the default route belongs to the
        // tunnel, and a datagram for 192.168.0.1 sent down it reaches a router
        // that has never heard of this Mac — or nothing at all. Measured on this
        // machine with Tailscale running, where the only gateway the default path
        // reports is Tailscale's own.
        parameters.requiredInterface = interface
        let connection = NWConnection(to: endpoint, using: parameters)
        let queue = DispatchQueue(label: "com.renyicao.mice.host.udp")

        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<(Data, String?)?, Never>) in
                // Exactly one resume, from whichever of the three paths gets
                // there first: the reply, the timeout, or a connection that
                // could not be made at all.
                let once = OnceBox(continuation: continuation, connection: connection)

                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        let local = Self.address(of: connection.currentPath?.localEndpoint)
                        connection.send(content: request, completion: .contentProcessed { error in
                            guard error == nil else { return once.finish(nil) }
                        })
                        connection.receiveMessage { data, _, _, _ in
                            guard let data, !data.isEmpty else { return once.finish(nil) }
                            once.finish((data, local))
                        }
                    case .failed, .cancelled:
                        once.finish(nil)
                    default:
                        break
                    }
                }
                connection.start(queue: queue)
                queue.asyncAfter(deadline: .now() + timeout) { once.finish(nil) }
            }
        } onCancel: {
            connection.cancel()
        }
    }

    /// The host part of an endpoint, without the `%en0` scope that an IPv6 one
    /// arrives with attached.
    static func address(of endpoint: NWEndpoint?) -> String? {
        guard case .hostPort(let host, _) = endpoint else { return nil }
        switch host {
        case .ipv4(let address): return "\(address)"
        case .ipv6(let address): return String("\(address)".split(separator: "%").first ?? "")
        case .name(let name, _): return name
        @unknown default: return nil
        }
    }

    /// Resumes a continuation once and only once, and closes the socket with it.
    private final class OnceBox: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<(Data, String?)?, Never>?
        private let connection: NWConnection

        init(continuation: CheckedContinuation<(Data, String?)?, Never>, connection: NWConnection) {
            self.continuation = continuation
            self.connection = connection
        }

        func finish(_ value: (Data, String?)?) {
            let pending: CheckedContinuation<(Data, String?)?, Never>? = lock.withLock {
                defer { continuation = nil }
                return continuation
            }
            guard let pending else { return }
            connection.cancel()
            pending.resume(returning: value)
        }
    }
}

/// Asking the router for a way in, and keeping it.
///
/// Three protocols are tried in the order they deserve, and between them they
/// cover most of what is on the market:
///
/// 1. **PCP** (RFC 6887), the current one. Apple's own routers, OpenWrt,
///    pfSense, OPNsense and AVM speak it, and it is the only one of the three
///    that can say *why* it refused — including the answer that matters most,
///    which is "there is no public address here to forward".
/// 2. **NAT-PMP** (RFC 6886), its predecessor, which some gateways speak alone.
/// 3. **UPnP-IGD**, which most cheap consumer routers speak instead of either —
///    and which many routers ship with switched off, because it has a long
///    history of being abused from inside the network. See `UPnPGateway`.
///
/// A mapping is a lease, not a setting: it has a lifetime and it dies if it is
/// not renewed, which is deliberate — a Mac that goes away stops being reachable
/// rather than leaving a hole in somebody's router forever. `RemoteReach` renews
/// at half the lifetime and deletes the mapping when away access is switched off.
actor PortMapper {

    struct Mapping: Equatable {
        /// What the world sees. Nil for a mapping made by a protocol that
        /// declines to say, in which case STUN is asked instead.
        var externalHost: String?
        var externalPort: UInt16
        /// Seconds. Renewal is due at half of this.
        var lifetime: UInt32
        /// "PCP", "NAT-PMP" or "UPnP", for the menu bar.
        var via: String
    }

    enum Failure: Error, Equatable {
        /// Nothing answered. The overwhelmingly common case, and not an error.
        case noGateway
        case silent
        /// The router answered, and said no. The message is the router's reason
        /// in words, which is worth showing: "set to refuse port forwarding" is
        /// a switch somebody can go and find.
        case refused(String)
        /// The router has no public address of its own to forward. Nothing here
        /// can fix that; only a relay can.
        case carrierGradeNAT(String)
    }

    /// Kept for the life of the mapping. PCP identifies a mapping by its nonce,
    /// so renewing with a fresh one asks for a *second* mapping — which is how a
    /// program slowly fills a router's table and then gets refused.
    private var nonce = PortMapWire.newNonce()
    private let upnp = UPnPGateway()

    /// Asks for `internalPort` to be forwarded, by whichever protocol answers.
    func map(internalPort: UInt16, lifetime: UInt32) async -> Result<Mapping, Failure> {
        guard let gateway = await Self.gateway() else {
            // No IPv4 gateway on any physical interface. UPnP is worth a try
            // anyway: it finds the router by multicast rather than by address.
            if let mapping = await upnp.map(internalPort: internalPort, lifetime: lifetime, over: nil) {
                return .success(mapping)
            }
            return .failure(.noGateway)
        }

        switch await pcp(gateway: gateway, internalPort: internalPort, lifetime: lifetime) {
        case .success(let mapping):
            return .success(mapping)
        case .failure(.carrierGradeNAT(let why)):
            // The one failure that is worth stopping on. Trying two more
            // protocols cannot conjure a public address, and a later "silent"
            // would replace a precise explanation with a vague one.
            return .failure(.carrierGradeNAT(why))
        case .failure(let pcpFailure):
            if case .success(let mapping) = await natPMP(gateway: gateway,
                                                         internalPort: internalPort,
                                                         lifetime: lifetime) {
                return .success(mapping)
            }
            if let mapping = await upnp.map(internalPort: internalPort,
                                            lifetime: lifetime,
                                            over: gateway.interface) {
                return .success(mapping)
            }
            return .failure(pcpFailure)
        }
    }

    /// Gives the port back. Best effort by design: the lease expires on its own
    /// within the hour, so a router that has already forgotten this Mac — or one
    /// that is no longer on the other end of the cable — costs nothing here.
    func unmap(internalPort: UInt16) async {
        guard let gateway = await Self.gateway() else {
            await upnp.unmap(internalPort: internalPort, over: nil)
            return
        }
        _ = await pcp(gateway: gateway, internalPort: internalPort, lifetime: 0)
        _ = await natPMP(gateway: gateway, internalPort: internalPort, lifetime: 0)
        await upnp.unmap(internalPort: internalPort, over: gateway.interface)
    }

    /// A new mapping rather than a renewal of the last one — after the network
    /// changed, or the router rebooted and forgot everything.
    func forgetMapping() {
        nonce = PortMapWire.newNonce()
    }

    // MARK: - PCP

    private func pcp(gateway: Gateway,
                     internalPort: UInt16,
                     lifetime: UInt32) async -> Result<Mapping, Failure> {
        // Sent twice before giving up. A single lost datagram is otherwise
        // indistinguishable from a router that does not speak PCP, and the
        // difference decides whether the user is told to check a setting.
        for attempt in 0..<2 {
            // The client address has to be this Mac's address on the link to the
            // gateway, and the only way to know which interface that is is to
            // open the socket and look. So the first pass sends a request with a
            // placeholder, learns the address from the path, and the second
            // sends the real one — which is cheap, because a router that
            // answers `addressMismatch` has already told us it speaks PCP.
            guard let probe = PortMapWire.PCP.mapRequest(
                clientAddress: Data(repeating: 0, count: 16),
                nonce: nonce,
                internalPort: internalPort,
                suggestedExternalPort: internalPort,
                suggestedExternalAddress: Data(repeating: 0, count: 16),
                lifetime: lifetime) else { return .failure(.silent) }

            guard let first = await UDPExchange.ask(probe, of: gateway.endpoint, over: gateway.interface) else {
                if attempt == 1 { return .failure(.silent) }
                continue
            }
            if PortMapWire.PCP.saysUseNATPMP(first.reply) { return .failure(.silent) }

            var reply = first.reply
            if let local = first.localAddress,
               let client = PortMapWire.mappedIPv6(fromIPv4: local) ?? PortMapWire.ipv6Bytes(from: local),
               let addressed = PortMapWire.PCP.mapRequest(clientAddress: client,
                                                          nonce: nonce,
                                                          internalPort: internalPort,
                                                          suggestedExternalPort: internalPort,
                                                          suggestedExternalAddress: Data(repeating: 0, count: 16),
                                                          lifetime: lifetime),
               let second = await UDPExchange.ask(addressed, of: gateway.endpoint, over: gateway.interface) {
                reply = second.reply
            }

            guard let parsed = PortMapWire.PCP.parseMapResponse(reply) else {
                if attempt == 1 { return .failure(.silent) }
                continue
            }
            let result = PortMapWire.PCP.Result(rawValue: parsed.result)
            switch result {
            case .success:
                miceLog.info("away: PCP mapped \(internalPort, privacy: .public) → \(parsed.externalPort, privacy: .public) for \(parsed.lifetime, privacy: .public)s")
                return .success(Mapping(externalHost: PortMapWire.ipv4(fromMappedIPv6: parsed.externalAddress),
                                        externalPort: parsed.externalPort,
                                        lifetime: parsed.lifetime,
                                        via: "PCP"))
            case .cannotProvideExternal:
                return .failure(.carrierGradeNAT(result!.message))
            case .some(let known):
                miceLog.info("away: PCP refused — \(known.message, privacy: .public)")
                return .failure(.refused(known.message))
            case nil:
                return .failure(.refused("the router refused with code \(parsed.result)"))
            }
        }
        return .failure(.silent)
    }

    // MARK: - NAT-PMP

    private func natPMP(gateway: Gateway,
                        internalPort: UInt16,
                        lifetime: UInt32) async -> Result<Mapping, Failure> {
        let request = PortMapWire.NATPMP.mapRequest(internalPort: internalPort,
                                                    suggestedExternalPort: internalPort,
                                                    lifetime: lifetime)
        guard let exchange = await UDPExchange.ask(request, of: gateway.endpoint, over: gateway.interface),
              let parsed = PortMapWire.NATPMP.parseMapResponse(exchange.reply) else {
            return .failure(.silent)
        }
        guard parsed.result == 0 else {
            let known = PortMapWire.NATPMP.Result(rawValue: parsed.result)
            return .failure(.refused(known?.message ?? "the router refused with code \(parsed.result)"))
        }
        // NAT-PMP reports the external address under a separate opcode, and it
        // is the router's own answer — better than asking a stranger for it.
        var external: String?
        if let address = await UDPExchange.ask(PortMapWire.NATPMP.externalAddressRequest(), of: gateway.endpoint, over: gateway.interface),
           let parsedAddress = PortMapWire.NATPMP.parseExternalAddressResponse(address.reply),
           parsedAddress.result == 0 {
            external = parsedAddress.address
        }
        miceLog.info("away: NAT-PMP mapped \(internalPort, privacy: .public) → \(parsed.externalPort, privacy: .public) for \(parsed.lifetime, privacy: .public)s")
        return .success(Mapping(externalHost: external,
                                externalPort: parsed.externalPort,
                                lifetime: parsed.lifetime,
                                via: "NAT-PMP"))
    }

    // MARK: - The gateway

    /// The home router, and the interface it is on.
    struct Gateway {
        var endpoint: NWEndpoint
        var interface: NWInterface?
    }

    /// The router on the physical network, which is not the same question as
    /// "where does traffic go by default".
    ///
    /// Two things were wrong with the obvious version of this, and both were found
    /// by running it rather than by reading it:
    ///
    /// - **`currentPath` on a monitor that has not been started is
    ///   `unsatisfied`, with no gateways at all.** The monitor has to be started
    ///   and its first update waited for. The comment here used to claim
    ///   otherwise.
    /// - **The default path's gateway is the VPN's.** With Tailscale up, the only
    ///   gateway reported is `fd7a:115c:a1e0::` on `utun0`, and there is no IPv4
    ///   gateway in the list — so a Mac behind any VPN reported "no router" and
    ///   away access could never be switched on. Asking a monitor scoped to Wi-Fi
    ///   or Ethernet gives `192.168.0.1` on `en0`, which is the router this is
    ///   about.
    /// The interface the home router is on, for anything that has to ask
    /// the internet a question about this network rather than about
    /// wherever the default route leads.
    static func physicalInterface() async -> NWInterface? {
        await gateway()?.interface
    }

    private static func gateway() async -> Gateway? {
        for type in [NWInterface.InterfaceType.wifi, .wiredEthernet] {
            guard let path = await firstPath(requiring: type), path.status == .satisfied else {
                continue
            }
            for candidate in path.gateways {
                guard case .hostPort(let host, _) = candidate, case .ipv4 = host else { continue }
                return Gateway(endpoint: .hostPort(host: host,
                                                   port: NWEndpoint.Port(rawValue: PortMapWire.gatewayPort)!),
                               interface: path.availableInterfaces.first { $0.type == type })
            }
        }
        return nil
    }

    private static func firstPath(requiring type: NWInterface.InterfaceType) async -> NWPath? {
        let monitor = NWPathMonitor(requiredInterfaceType: type)
        let queue = DispatchQueue(label: "com.renyicao.mice.host.gateway")
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<NWPath?, Never>) in
                let box = PathBox(continuation: continuation, monitor: monitor)
                monitor.pathUpdateHandler = { path in box.finish(path) }
                monitor.start(queue: queue)
                // A monitor for an interface type this Mac does not have never
                // calls back at all.
                queue.asyncAfter(deadline: .now() + 1.5) { box.finish(nil) }
            }
        } onCancel: {
            monitor.cancel()
        }
    }

    private final class PathBox: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<NWPath?, Never>?
        private let monitor: NWPathMonitor

        init(continuation: CheckedContinuation<NWPath?, Never>, monitor: NWPathMonitor) {
            self.continuation = continuation
            self.monitor = monitor
        }

        func finish(_ path: NWPath?) {
            let pending: CheckedContinuation<NWPath?, Never>? = lock.withLock {
                defer { continuation = nil }
                return continuation
            }
            guard let pending else { return }
            monitor.cancel()
            pending.resume(returning: path)
        }
    }
}
