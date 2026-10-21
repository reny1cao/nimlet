import Foundation
import Network

/// Explicit distribution policy. Development/TestFlight supports remote access;
/// a deliberately LAN-only build can define MICE_LAN_ONLY.
enum LaunchNetworkPolicy {
    #if MICE_LAN_ONLY
    static let allowsAwayAccess = false
    #else
    static let allowsAwayAccess = true
    #endif

    static func allows(host: String) -> Bool {
        let name = host.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if name == "localhost" || name.hasSuffix(".local") || name.hasSuffix(".local.") { return true }
        if let address = IPv4Address(name) {
            let b = Array(address.rawValue)
            return b[0] == 10 || b[0] == 127
                || (b[0] == 172 && (16...31).contains(b[1]))
                || (b[0] == 192 && b[1] == 168)
                || (b[0] == 169 && b[1] == 254)
        }
        // A scope suffix identifies a local interface for link-local IPv6.
        let literal = String(name.split(separator: "%", maxSplits: 1).first ?? "")
        if let address = IPv6Address(literal) {
            let b = Array(address.rawValue)
            return (b[0] & 0xfe) == 0xfc || (b[0] == 0xfe && (b[1] & 0xc0) == 0x80)
                || (b.dropLast().allSatisfy { $0 == 0 } && b.last == 1)
        }
        return false
    }

    static func allows(endpoint: NWEndpoint) -> Bool {
        switch endpoint {
        case .service(_, _, let domain, _): return domain == "local." || domain == "local"
        case .hostPort(let host, _): return allows(host: String(describing: host))
        default: return false
        }
    }
}
