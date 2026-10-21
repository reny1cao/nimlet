import Foundation
import Network

/// Names the link a connection is actually on, from either end of it.
///
/// Before any path can be made better, which one a session is on has to be
/// something you can read rather than infer from the Wi-Fi icon: a phone and a
/// Mac on the same Wi-Fi may well be talking over AWDL, and a phone on
/// cellular may be in a VPN. Logged at both ends and put in both diagnostics.
enum LinkRoute {
    static func name(of path: NWPath?) -> String {
        guard let path else { return "?" }
        let interface = path.availableInterfaces.first
        if let name = interface?.name, name.hasPrefix("awdl") || name.hasPrefix("llw") {
            return "AWDL"
        }
        if case .hostPort(let host, _) = path.remoteEndpoint,
           OverlayAddress.contains(String("\(host)".split(separator: "%").first ?? "")) {
            return "VPN"
        }
        switch interface?.type {
        case .wifi: return "Wi-Fi"
        case .wiredEthernet: return "Ethernet"
        case .cellular: return "cellular"
        case .loopback: return "loopback"
        case .other: return interface?.name.hasPrefix("utun") == true ? "VPN" : "other"
        default: return "?"
        }
    }
}
