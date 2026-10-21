import Foundation
import Network

/// What addresses this Mac actually has, and what the internet thinks it has.
enum PublicAddress {

    /// Every address on this Mac worth telling a phone about.
    ///
    /// Two kinds, and the distinction is the whole point of the list:
    ///
    /// - **Local**: the private IPv4 addresses. Useful only from this network,
    ///   and the fastest thing there is from it.
    /// - **Globally routable IPv6**: an address with no NAT in front of it. A
    ///   phone on a carrier that speaks IPv6 — which is most of them, and some
    ///   speak nothing else — can reach it directly, if the home router lets an
    ///   inbound connection through. Most block it by default, which is why this
    ///   is one candidate among several rather than the answer.
    ///
    /// What is deliberately left out: link-local (`fe80::`, `169.254.`), which
    /// means nothing off the wire; unique-local (`fc00::/7`), which is private
    /// IPv6 and reaches no further than the house; loopback; and IPv6 privacy
    /// addresses are *kept*, because a temporary address is still the address
    /// inbound traffic can arrive on and the phone re-learns the list whenever it
    /// changes.
    static func interfaces() -> (local: [String], global6: [String]) {
        var local: [String] = []
        var global6: [String] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return ([], []) }
        defer { freeifaddrs(head) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            guard let address = entry.pointee.ifa_addr else { continue }
            let name = String(cString: entry.pointee.ifa_name)
            // Publish known overlay addresses on active VPN interfaces. Bonjour
            // does not cross a VPN; paired phones must remember its unicast route.
            if name.hasPrefix("utun") || name.hasPrefix("tailscale") {
                let length = Int32(address.pointee.sa_family) == AF_INET
                    ? socklen_t(MemoryLayout<sockaddr_in>.size)
                    : socklen_t(MemoryLayout<sockaddr_in6>.size)
                if [AF_INET, AF_INET6].contains(Int32(address.pointee.sa_family)),
                   let host = text(of: address, length: length),
                   OverlayAddress.isAdvertisable(host: host, interface: name) {
                    local.append(host)
                }
                continue
            }
            // Skip the interfaces that are not a way onto a network: Apple's
            // peer-to-peer link, the bridges VMs and containers put up, and
            // tunnels, whose addresses belong to somebody else's overlay.
            guard !name.hasPrefix("awdl"), !name.hasPrefix("llw"),
                  !name.hasPrefix("bridge"), !name.hasPrefix("utun"),
                  !name.hasPrefix("ipsec"), !name.hasPrefix("gif"),
                  !name.hasPrefix("stf") else { continue }

            switch Int32(address.pointee.sa_family) {
            case AF_INET:
                guard let text = text(of: address, length: socklen_t(MemoryLayout<sockaddr_in>.size)) else { continue }
                guard !text.hasPrefix("169.254.") else { continue }
                local.append(text)
            case AF_INET6:
                guard let text = text(of: address, length: socklen_t(MemoryLayout<sockaddr_in6>.size)) else { continue }
                let bare = String(text.split(separator: "%").first ?? "")
                guard isGloballyRoutableIPv6(bare) else { continue }
                global6.append(bare)
            default:
                continue
            }
        }
        return (local, global6)
    }

    /// `2000::/3`, which is the whole of the address space IANA has handed out
    /// for global use, minus the ranges inside it that are not.
    static func isGloballyRoutableIPv6(_ address: String) -> Bool {
        guard let bytes = PortMapWire.ipv6Bytes(from: address).map({ [UInt8]($0) }),
              bytes.count == 16 else { return false }
        // Link-local fe80::/10, unique-local fc00::/7, multicast ff00::/8,
        // loopback ::1 and the unspecified address are all outside 2000::/3
        // except by accident, so the test is the range itself.
        guard bytes[0] & 0xE0 == 0x20 else { return false }
        // Documentation prefix 2001:db8::/32 is routable in form and not in fact.
        if bytes[0] == 0x20, bytes[1] == 0x01, bytes[2] == 0x0D, bytes[3] == 0xB8 { return false }
        // Teredo (2001::/32) and 6to4 (2002::/16) are tunnels through IPv4, and a
        // tunnel's address is only as reachable as the tunnel.
        if bytes[0] == 0x20, bytes[1] == 0x01, bytes[2] == 0, bytes[3] == 0 { return false }
        if bytes[0] == 0x20, bytes[1] == 0x02 { return false }
        return true
    }

    /// Whether a peer is on a network this Mac is also on. `PortMapWire` holds
    /// the predicate and the reasons for it; this supplies the addresses.
    static func isOnThisMacsNetwork(_ address: String) -> Bool {
        PortMapWire.isOnSameNetwork(address, asAnyOf: interfaces().global6)
    }

    /// What the internet sees, by asking something on it.
    ///
    /// Only reached for when the router would not say — PCP and NAT-PMP both
    /// report the external address themselves, and their answer is better, being
    /// the router's own. Two servers are tried in turn rather than at once: this
    /// is not urgent, and asking two strangers when one would do is one more
    /// party than necessary.
    ///
    /// The privacy cost is one UDP datagram containing nothing but a random
    /// transaction id, to a server that learns this Mac's address by receiving it
    /// — which is true of every packet that leaves the house. Only while away
    /// access is on. See PRIVACY.md.
    ///
    /// - Parameter interface: the physical interface the router is on, when
    ///   known. The question is "what does the internet see on *this*
    ///   network", and with a VPN exit node up the default route answers a
    ///   different one — the exit node's address, behind which nothing the
    ///   router forwards will ever arrive.
    static func reflexive(over interface: NWInterface? = nil) async -> StunWire.Reflexive? {
        for server in servers {
            guard let endpoint = Self.endpoint(for: server) else { continue }
            let transaction = StunWire.newTransaction()
            guard let request = StunWire.request(transaction: transaction) else { continue }
            guard let exchange = await UDPExchange.ask(request, of: endpoint, over: interface, timeout: 1.5) else { continue }
            if let found = StunWire.reflexiveAddress(in: exchange.reply, transaction: transaction) {
                // Private: the log ends up in diagnostics people paste into
                // bug reports, and the public address is what identifies
                // their house.
                miceLog.info("away: the internet sees \(found.host, privacy: .private)")
                return found
            }
            if let code = StunWire.errorCode(in: exchange.reply) {
                miceLog.info("away: STUN server \(server, privacy: .public) answered \(code, privacy: .public)")
            }
        }
        return nil
    }

    /// Overridable, because a user who would rather not ask Google can point this
    /// at their own:
    ///
    ///   defaults write com.renyicao.mice.host mice.stunServers \
    ///     -array "stun.example.com:3478"
    ///
    /// An empty array switches the STUN step off entirely. Away access still
    /// works: the routers that can forward a port almost all report the external
    /// address themselves, and this is the fallback for the ones that do not.
    private static var servers: [String] {
        if let override = UserDefaults.standard.array(forKey: "mice.stunServers") as? [String] {
            return override
        }
        return ["stun.cloudflare.com:3478", "stun.l.google.com:19302"]
    }

    private static func endpoint(for server: String) -> NWEndpoint? {
        let parts = server.split(separator: ":")
        guard parts.count == 2, let port = UInt16(parts[1]),
              let nwPort = NWEndpoint.Port(rawValue: port) else { return nil }
        return .hostPort(host: NWEndpoint.Host(String(parts[0])), port: nwPort)
    }

    private static func text(of address: UnsafeMutablePointer<sockaddr>, length: socklen_t) -> String? {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(address, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0
        else { return nil }
        return String(cString: host)
    }
}
