import Foundation

/// A STUN binding request and the one answer worth reading out of it: what
/// address the rest of the internet sees this Mac as.
///
/// Used for two things, and neither is hole punching. There is no hole punching
/// in Nimlet: only the Mac has to accept a connection and a phone on a carrier
/// network can dial out perfectly well, so the port the router forwards is the
/// whole of the mechanism. (It could not do hole punching anyway.
/// `NWParameters.requiredLocalEndpoint` and `allowLocalEndpointReuse` do not
/// work for UDP — two connections cannot share a local port — which Apple's own
/// DTS confirms against FB13678278 and which was still true in macOS 26. Doing
/// it would mean BSD sockets and hand-rolling a transport on top.)
///
/// What it *is* for:
///
/// - **A public address when the router will not say.** PCP and NAT-PMP both
///   report the external address themselves, so this is only reached for when
///   neither answered and the mapping came from UPnP, or when the Mac has a
///   public address with no NAT in front of it at all.
///
/// - **Telling the user the truth about carrier-grade NAT.** If the address the
///   internet sees is in `100.64.0.0/10`, the Mac is behind its ISP's own NAT:
///   the router's public address is not public, forwarding a port on it
///   achieves nothing, and no amount of retrying will change that. Being able
///   to say so is worth the round trip, because the alternative is a switch that
///   looks broken.
///
/// Sending one packet to a public STUN server means telling that server this
/// Mac's IP address, which it would learn by receiving the packet whichever
/// server it was. Nothing else is in it: no name, no hostname, no identifier.
/// It happens only while away access is on. See PRIVACY.md.
///
/// Building and parsing only; the socket is in `PublicAddress`.
enum StunWire {
    static let bindingRequest: UInt16 = 0x0001
    static let bindingSuccess: UInt16 = 0x0101
    static let magicCookie: UInt32 = 0x2112_A442
    static let headerLength = 20

    enum Attribute: UInt16 {
        case mappedAddress = 0x0001
        case xorMappedAddress = 0x0020
        case errorCode = 0x0009
    }

    /// A binding request is a header and nothing else: twenty bytes, of which
    /// twelve are the transaction id that matches the answer to the question.
    static func request(transaction: Data) -> Data? {
        guard transaction.count == 12 else { return nil }
        var data = Data()
        data.appendBigEndian(bindingRequest)
        data.appendBigEndian(UInt16(0))
        data.appendBigEndian(magicCookie)
        data.append(transaction)
        return data
    }

    static func newTransaction() -> Data {
        var bytes = [UInt8](repeating: 0, count: 12)
        for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
        return Data(bytes)
    }

    struct Reflexive: Equatable {
        var host: String
        var port: UInt16
        var isIPv6: Bool

        /// `100.64.0.0/10`: the range RFC 6598 set aside for a carrier's own NAT.
        /// An address in it means the ISP is translating, the router's "public"
        /// address is not, and a forwarded port on it is unreachable from
        /// outside — which is the one failure worth naming to the user, because
        /// nothing they do to the router will fix it.
        var isCarrierGradeNAT: Bool {
            guard !isIPv6 else { return false }
            let parts = host.split(separator: ".").compactMap { Int($0) }
            guard parts.count == 4, parts[0] == 100 else { return false }
            return parts[1] >= 64 && parts[1] <= 127
        }
    }

    /// The address the server saw, or nil for anything that is not a success
    /// response to this transaction.
    ///
    /// The transaction id is checked rather than assumed: UDP delivers whatever
    /// arrives, including a late answer to a request that was already given up
    /// on, and publishing the address from one of those would publish an address
    /// measured through an interface that has since gone away.
    static func reflexiveAddress(in data: Data, transaction: Data) -> Reflexive? {
        guard data.count >= headerLength, transaction.count == 12 else { return nil }
        let type: UInt16 = data.bigEndian(at: 0)
        guard type == bindingSuccess else { return nil }
        let cookie: UInt32 = data.bigEndian(at: 4)
        guard cookie == magicCookie else { return nil }
        guard [UInt8](data.subdata(in: 8..<20)) == [UInt8](transaction) else { return nil }

        let declared = Int(data.bigEndian(at: 2) as UInt16)
        let end = min(headerLength + declared, data.count)
        var cursor = headerLength
        // Preferred if present, but a server old enough to send only the
        // unXORed form is still telling the truth.
        var fallback: Reflexive?
        while cursor + 4 <= end {
            let attribute: UInt16 = data.bigEndian(at: cursor)
            let length = Int(data.bigEndian(at: cursor + 2) as UInt16)
            let valueStart = cursor + 4
            guard valueStart + length <= data.count else { break }
            let value = data.subdata(in: valueStart..<(valueStart + length))
            switch Attribute(rawValue: attribute) {
            case .xorMappedAddress:
                if let found = parseAddress(value, xored: true, transaction: transaction) {
                    return found
                }
            case .mappedAddress:
                fallback = fallback ?? parseAddress(value, xored: false, transaction: transaction)
            default:
                break
            }
            // Every attribute is padded to a multiple of four, and the padding
            // is not in the declared length.
            cursor = valueStart + length + ((4 - length % 4) % 4)
        }
        return fallback
    }

    /// Whether a reply is the server saying no. Worth distinguishing from a lost
    /// packet: one is worth retrying and the other is worth trying elsewhere.
    static func errorCode(in data: Data) -> Int? {
        guard data.count >= headerLength else { return nil }
        let type: UInt16 = data.bigEndian(at: 0)
        guard type == 0x0111 else { return nil }
        var cursor = headerLength
        while cursor + 8 <= data.count {
            let attribute: UInt16 = data.bigEndian(at: cursor)
            let length = Int(data.bigEndian(at: cursor + 2) as UInt16)
            if Attribute(rawValue: attribute) == .errorCode {
                let bytes = [UInt8](data)
                guard cursor + 8 <= bytes.count else { return nil }
                return Int(bytes[cursor + 6]) * 100 + Int(bytes[cursor + 7])
            }
            cursor += 4 + length + ((4 - length % 4) % 4)
        }
        return nil
    }

    // MARK: - Private

    /// The address attribute: a reserved byte, a family, a port and an address.
    /// In the XORed form — which is the one every current server sends, and the
    /// reason it exists is that the un-XORed form was being rewritten in flight
    /// by NATs that recognised their own address in a payload — the port is
    /// XORed with the top half of the cookie and the address with the cookie,
    /// extended by the transaction id for IPv6.
    private static func parseAddress(_ value: Data, xored: Bool, transaction: Data) -> Reflexive? {
        let bytes = [UInt8](value)
        guard bytes.count >= 8 else { return nil }
        let family = bytes[1]
        let rawPort: UInt16 = value.bigEndian(at: 2)
        let port = xored ? rawPort ^ UInt16(magicCookie >> 16) : rawPort

        switch family {
        case 0x01:
            guard bytes.count >= 8 else { return nil }
            var address = [UInt8](bytes[4..<8])
            if xored {
                let cookie: [UInt8] = [UInt8(magicCookie >> 24 & 0xFF), UInt8(magicCookie >> 16 & 0xFF),
                                       UInt8(magicCookie >> 8 & 0xFF), UInt8(magicCookie & 0xFF)]
                for index in 0..<4 { address[index] ^= cookie[index] }
            }
            return Reflexive(host: address.map(String.init).joined(separator: "."),
                             port: port, isIPv6: false)
        case 0x02:
            guard bytes.count >= 20 else { return nil }
            var address = [UInt8](bytes[4..<20])
            if xored {
                let mask: [UInt8] = [UInt8(magicCookie >> 24 & 0xFF), UInt8(magicCookie >> 16 & 0xFF),
                                     UInt8(magicCookie >> 8 & 0xFF), UInt8(magicCookie & 0xFF)]
                    + [UInt8](transaction)
                for index in 0..<16 { address[index] ^= mask[index] }
            }
            return Reflexive(host: Self.text(ipv6: address), port: port, isIPv6: true)
        default:
            return nil
        }
    }

    private static func text(ipv6 bytes: [UInt8]) -> String {
        var address = in6_addr()
        withUnsafeMutableBytes(of: &address) { raw in
            for index in 0..<16 { raw[index] = bytes[index] }
        }
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &address, &buffer, socklen_t(INET6_ADDRSTRLEN)) != nil else {
            return ""
        }
        return String(cString: buffer)
    }
}
