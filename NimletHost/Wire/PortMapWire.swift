import Foundation

/// Asking a home router for a way in, on the wire.
///
/// Two protocols, and both are needed. PCP (RFC 6887) is the current one and is
/// what Apple's own routers, OpenWrt, pfSense, OPNsense and AVM speak; NAT-PMP
/// (RFC 6886) is its predecessor, which PCP servers are required to keep
/// answering and which some gateways speak alone. Between them they cover the
/// routers that deliberately do not implement UPnP — and UPnP, which most cheap
/// consumer routers speak instead, is a third thing entirely and lives in
/// `UPnPGateway`.
///
/// Both are UDP to the default gateway on port 5351, both are idempotent, and
/// both hand back a lifetime that has to be renewed. Neither is authenticated in
/// any way, which is worth saying plainly: anything on the local network can ask
/// the router to forward a port, and that has been true of every home network
/// for twenty years. It is why the port being forwarded here is the one guarded
/// by a per-device key rather than by the pairing code.
///
/// Parsing and building only. Nothing here touches the network, which is what
/// makes the byte layouts — the part that is easy to get subtly wrong and
/// impossible to debug from a router's silence — something a test can check.
enum PortMapWire {

    /// Where both protocols listen on the gateway.
    static let gatewayPort: UInt16 = 5351

    /// TCP, as both protocols number it.
    static let tcpProtocol: UInt8 = 6

    // MARK: - NAT-PMP, RFC 6886

    enum NATPMP {
        static let version: UInt8 = 0
        /// Opcode 2 is "map TCP"; the response echoes it with the high bit set.
        static let mapTCP: UInt8 = 2
        static let mapTCPResponse: UInt8 = 128 + 2
        static let externalAddress: UInt8 = 0
        static let externalAddressResponse: UInt8 = 128

        enum Result: UInt16 {
            case success = 0
            case unsupportedVersion = 1
            case refused = 2
            case networkFailure = 3
            case outOfResources = 4
            case unsupportedOpcode = 5

            var message: String {
                switch self {
                case .success: return "mapped"
                case .unsupportedVersion: return "the router does not speak NAT-PMP"
                case .refused: return "the router refused to forward a port"
                case .networkFailure: return "the router has no internet connection"
                case .outOfResources: return "the router has no port mappings left"
                case .unsupportedOpcode: return "the router does not forward TCP"
                }
            }
        }

        /// 12 bytes: version, opcode, two reserved, internal port, suggested
        /// external port, lifetime.
        ///
        /// A lifetime of zero is how a mapping is deleted, and the suggested
        /// external port is a suggestion: the router is free to hand back a
        /// different one, which is why the response's port is what gets
        /// published rather than the one that was asked for.
        static func mapRequest(internalPort: UInt16,
                               suggestedExternalPort: UInt16,
                               lifetime: UInt32) -> Data {
            var data = Data([version, mapTCP, 0, 0])
            data.appendBigEndian(internalPort)
            data.appendBigEndian(suggestedExternalPort)
            data.appendBigEndian(lifetime)
            return data
        }

        struct MapResponse: Equatable {
            var result: UInt16
            var epoch: UInt32
            var internalPort: UInt16
            var externalPort: UInt16
            var lifetime: UInt32
        }

        /// 16 bytes. Nil for anything that is not a well-formed response to the
        /// request above — including a response to a *different* opcode, which
        /// is what a gateway running both protocols sends when the two cross.
        static func parseMapResponse(_ data: Data) -> MapResponse? {
            guard data.count >= 16 else { return nil }
            let bytes = [UInt8](data)
            guard bytes[0] == version, bytes[1] == mapTCPResponse else { return nil }
            return MapResponse(result: data.bigEndian(at: 2),
                               epoch: data.bigEndian(at: 4),
                               internalPort: data.bigEndian(at: 8),
                               externalPort: data.bigEndian(at: 10),
                               lifetime: data.bigEndian(at: 12))
        }

        /// Two bytes, and the cheapest way to learn the public address: the
        /// router already knows it and no third party has to be asked.
        static func externalAddressRequest() -> Data {
            Data([version, externalAddress])
        }

        struct ExternalAddressResponse: Equatable {
            var result: UInt16
            var epoch: UInt32
            var address: String
        }

        static func parseExternalAddressResponse(_ data: Data) -> ExternalAddressResponse? {
            guard data.count >= 12 else { return nil }
            let bytes = [UInt8](data)
            guard bytes[0] == version, bytes[1] == externalAddressResponse else { return nil }
            let address = "\(bytes[8]).\(bytes[9]).\(bytes[10]).\(bytes[11])"
            return ExternalAddressResponse(result: data.bigEndian(at: 2),
                                           epoch: data.bigEndian(at: 4),
                                           address: address)
        }
    }

    // MARK: - PCP, RFC 6887

    enum PCP {
        static let version: UInt8 = 2
        static let mapOpcode: UInt8 = 1
        /// The response sets the top bit of the opcode byte.
        static let responseBit: UInt8 = 0x80
        /// 24-byte common header, then a 36-byte MAP body.
        static let requestLength = 60
        static let responseLength = 60

        enum Result: UInt8 {
            case success = 0
            case unsupportedVersion = 1
            case notAuthorized = 2
            case malformedRequest = 3
            case unsupportedOpcode = 4
            case unsupportedOption = 5
            case malformedOption = 6
            case networkFailure = 7
            case noResources = 8
            case unsupportedProtocol = 9
            case userExceededQuota = 10
            case cannotProvideExternal = 11
            case addressMismatch = 12
            case excessiveRemotePeers = 13

            /// In words, for the menu bar. `notAuthorized` is the one worth
            /// being specific about: it means the router speaks PCP and has been
            /// told not to hand out mappings, which is a switch the user can go
            /// and find rather than a dead end.
            var message: String {
                switch self {
                case .success: return "mapped"
                case .unsupportedVersion: return "the router does not speak PCP"
                case .notAuthorized: return "the router is set to refuse port forwarding"
                case .malformedRequest, .malformedOption, .unsupportedOption:
                    return "the router rejected the request"
                case .unsupportedOpcode: return "the router cannot forward ports"
                case .networkFailure: return "the router has no internet connection"
                case .noResources, .userExceededQuota:
                    return "the router has no port mappings left"
                case .unsupportedProtocol: return "the router cannot forward TCP"
                case .cannotProvideExternal:
                    return "the router has no public address to forward — this looks like carrier-grade NAT"
                case .addressMismatch: return "the router disagreed about this Mac's address"
                case .excessiveRemotePeers: return "the router refused: too many peers"
                }
            }
        }

        /// A MAP request. 60 bytes, and every field of it matters:
        ///
        /// - `clientAddress` is this Mac's own address on the link to the
        ///   gateway, as 16 bytes — an IPv6 address, or an IPv4 one in the
        ///   `::ffff:0:0/96` form. The router compares it with where the packet
        ///   came from and answers `addressMismatch` if they differ, which is
        ///   how a mapping requested through the wrong interface is caught.
        /// - `nonce` identifies *this* mapping for its whole life. A renewal has
        ///   to carry the same twelve bytes or the router treats it as a second,
        ///   different mapping — which is how a program that renews with a fresh
        ///   nonce slowly exhausts a router's table.
        static func mapRequest(clientAddress: Data,
                               nonce: Data,
                               protocolNumber: UInt8 = tcpProtocol,
                               internalPort: UInt16,
                               suggestedExternalPort: UInt16,
                               suggestedExternalAddress: Data,
                               lifetime: UInt32) -> Data? {
            guard clientAddress.count == 16, nonce.count == 12,
                  suggestedExternalAddress.count == 16 else { return nil }
            var data = Data([version, mapOpcode, 0, 0])
            data.appendBigEndian(lifetime)
            data.append(clientAddress)
            data.append(nonce)
            data.append(protocolNumber)
            data.append(contentsOf: [0, 0, 0])
            data.appendBigEndian(internalPort)
            data.appendBigEndian(suggestedExternalPort)
            data.append(suggestedExternalAddress)
            return data.count == requestLength ? data : nil
        }

        struct MapResponse: Equatable {
            var result: UInt8
            var lifetime: UInt32
            var epoch: UInt32
            var nonce: Data
            var protocolNumber: UInt8
            var internalPort: UInt16
            var externalPort: UInt16
            var externalAddress: Data
        }

        /// Nil unless this is a version-2 MAP response. A gateway that speaks
        /// only NAT-PMP answers a PCP request with a *NAT-PMP* unsupported-
        /// version error — two bytes of version 0 — and that is the signal to
        /// fall back rather than a packet to parse.
        static func parseMapResponse(_ data: Data) -> MapResponse? {
            guard data.count >= responseLength else { return nil }
            let bytes = [UInt8](data)
            guard bytes[0] == version, bytes[1] == (mapOpcode | responseBit) else { return nil }
            return MapResponse(result: bytes[3],
                               lifetime: data.bigEndian(at: 4),
                               epoch: data.bigEndian(at: 8),
                               nonce: data.subdata(in: 24..<36),
                               protocolNumber: bytes[36],
                               internalPort: data.bigEndian(at: 40),
                               externalPort: data.bigEndian(at: 42),
                               externalAddress: data.subdata(in: 44..<60))
        }

        /// Whether a reply is a gateway saying "I only speak the old one".
        ///
        /// It arrives as a NAT-PMP error rather than a PCP one — a router that
        /// predates PCP cannot answer in a protocol it does not have — so this
        /// is checked before parsing rather than as a result code afterwards.
        static func saysUseNATPMP(_ data: Data) -> Bool {
            guard data.count >= 2 else { return false }
            let bytes = [UInt8](data)
            if bytes[0] == NATPMP.version { return true }
            // And a PCP-shaped answer whose version is not 2 is the same news.
            return bytes[0] != version
        }
    }

    // MARK: - Addresses

    /// An IPv4 address as PCP wants it: sixteen bytes, `::ffff:a.b.c.d`.
    static func mappedIPv6(fromIPv4 text: String) -> Data? {
        let parts = text.split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4 else { return nil }
        var data = Data(repeating: 0, count: 10)
        data.append(contentsOf: [0xFF, 0xFF])
        data.append(contentsOf: parts)
        return data
    }

    /// And back again, for reading a PCP response's external address. Nil when
    /// the sixteen bytes are a real IPv6 address rather than a wrapped IPv4 one,
    /// which is what a PCP server answering for an IPv6 pinhole sends.
    static func ipv4(fromMappedIPv6 data: Data) -> String? {
        guard data.count == 16 else { return nil }
        let bytes = [UInt8](data)
        guard bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xFF, bytes[11] == 0xFF else {
            return nil
        }
        return "\(bytes[12]).\(bytes[13]).\(bytes[14]).\(bytes[15])"
    }

    /// Sixteen bytes of an IPv6 address, from its text form. Deliberately
    /// narrow: it handles what `getaddrinfo` hands back for a real interface
    /// address, including a `%en0` scope suffix, and refuses anything else
    /// rather than guessing.
    static func ipv6Bytes(from text: String) -> Data? {
        let bare = String(text.split(separator: "%").first ?? "")
        var address = in6_addr()
        guard bare.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else { return nil }
        return withUnsafeBytes(of: &address) { Data($0) }
    }

    /// Whether a peer is on a network these addresses are on.
    ///
    /// Here rather than beside the interface list because it decides one
    /// security question — whether a connection may be handed this device's away
    /// key — and a predicate that decides one of those should be a thing a test
    /// can pin down. The LAN is where the pairing code was typed in and the user
    /// was standing; it is the trust away access is bootstrapped from, so "is
    /// this the LAN" has to be answered rather than assumed.
    ///
    /// IPv4 is easy: a private address is a private address. IPv6 is not, and it
    /// is the reason this exists. A home network's IPv6 addresses are globally
    /// routable and look exactly like an address from the other side of the
    /// world; what separates them is the prefix. A peer sharing a /64 with one of
    /// this Mac's own addresses is on the same link, and one that does not, is
    /// not.
    ///
    /// - Parameter mine: this Mac's own globally routable IPv6 addresses.
    static func isOnSameNetwork(_ peer: String, asAnyOf mine: [String]) -> Bool {
        let bare = String(peer.split(separator: "%").first ?? "")
        guard !bare.isEmpty else { return false }
        if bare.contains("."), !bare.contains(":") { return isPrivateIPv4(bare) }
        guard let bytes = ipv6Bytes(from: bare).map({ [UInt8]($0) }) else { return false }
        // Link-local and unique-local reach no further than the house by
        // definition, so they need no comparison.
        if bytes[0] == 0xFE, bytes[1] & 0xC0 == 0x80 { return true }
        if bytes[0] & 0xFE == 0xFC { return true }
        // ::1, which is the command-line tool on this Mac.
        if bytes.dropLast().allSatisfy({ $0 == 0 }), bytes[15] == 1 { return true }
        return mine.contains { address in
            guard let ours = ipv6Bytes(from: address).map({ [UInt8]($0) }) else { return false }
            return Array(ours.prefix(8)) == Array(bytes.prefix(8))
        }
    }

    /// Whether a peer may use one of the Mac's two LAN listeners: on one of
    /// this Mac's own networks, by `isOnSameNetwork`, with a VPN overlay
    /// address (`OverlayAddress`) allowed or not as the listener says. Here,
    /// beside the predicate it is built on, so a test can pin it down.
    ///
    /// - Parameter mine: this Mac's own globally routable IPv6 addresses.
    static func isLocalSource(_ source: String, allowingOverlay: Bool, mine: [String]) -> Bool {
        var host = source
        // A dual-stack listener may present an IPv4 peer as `::ffff:a.b.c.d`.
        if host.lowercased().hasPrefix("::ffff:"), host.dropFirst(7).contains(".") {
            host = String(host.dropFirst(7))
        }
        if OverlayAddress.contains(host) { return allowingOverlay }
        return isOnSameNetwork(host, asAnyOf: mine)
    }

    /// The ranges that do not leave the building — and the carrier's own NAT
    /// range, which leaves it and arrives nowhere.
    static func isPrivateIPv4(_ address: String) -> Bool {
        let parts = address.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else { return false }
        switch (parts[0], parts[1]) {
        case (10, _), (127, _), (169, 254), (192, 168): return true
        case (172, 16...31): return true
        case (100, 64...127): return true
        default: return false
        }
    }

    /// Twelve fresh bytes, kept for the life of a mapping. See `mapRequest`.
    static func newNonce() -> Data {
        var bytes = [UInt8](repeating: 0, count: 12)
        for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
        return Data(bytes)
    }
}

// MARK: - Big-endian helpers

extension Data {
    mutating func appendBigEndian(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }

    mutating func appendBigEndian(_ value: UInt32) {
        append(UInt8(truncatingIfNeeded: value >> 24))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }

    /// Reads from `offset` counted from the start of this value, whatever its
    /// own indices happen to be: a `Data` produced by slicing another one keeps
    /// the parent's indices, and a parser written against `self[0]` reads the
    /// wrong byte or traps.
    func bigEndian(at offset: Int) -> UInt16 {
        let bytes = [UInt8](self)
        guard offset + 1 < bytes.count else { return 0 }
        return UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
    }

    func bigEndian(at offset: Int) -> UInt32 {
        let bytes = [UInt8](self)
        guard offset + 3 < bytes.count else { return 0 }
        return UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16
            | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
    }
}
