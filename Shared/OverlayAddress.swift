import Foundation
import Network

/// Tailscale's address ranges are useful only through its active VPN interface.
/// A carrier address on an ordinary interface is not an overlay route.
enum OverlayAddress {
    static func contains(_ host: String) -> Bool {
        if let address = IPv4Address(host) {
            let bytes = Array(address.rawValue)
            return bytes[0] == 100 && (64...127).contains(bytes[1])
        }
        if let address = IPv6Address(host) {
            return Array(address.rawValue.prefix(6)) == [0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0]
        }
        return false
    }

    static func isAdvertisable(host: String, interface: String) -> Bool {
        (interface.hasPrefix("utun") || interface.hasPrefix("tailscale")) && contains(host)
    }
}
