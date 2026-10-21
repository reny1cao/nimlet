import Foundation

/// Free is a local trackpad and app switcher. Pro is the work console.
enum ProAccessPolicy {
    static func allows(route: RoutePolicy.RouteClass, hasPro: Bool) -> Bool {
        hasPro || route == .lan
    }

    static func allows(candidate: NimletCandidate, offLAN: Bool, hasPro: Bool) -> Bool {
        if hasPro { return true }
        return !offLAN && candidate.reach == .local
            && !OverlayAddress.contains(candidate.host)
            && !candidate.via.lowercased().contains("vpn")
            && LaunchNetworkPolicy.allows(host: candidate.host)
    }

    static func requiresPro(_ message: ClientMessage, targets: [NimletTarget]) -> Bool {
        switch message {
        case .hello, .pair, .ping, .move, .scroll, .scrollPhase, .click,
             .requestApps, .requestAppDirectory, .requestAppState, .requestAppIcons,
             .addTarget, .addTargets, .updateTarget, .removeTarget, .reorderTargets,
             .registerPush, .requestRemoteAccess:
            return false
        case .focus(let id):
            return targets.first(where: { $0.id == id })?.kind != .app
        case .appCommand(let command):
            return ![.activate, .reopen, .keep, .unkeep].contains(command.action)
        case .approvalDecision(_, let decision, _, _, _, let handBack):
            // Refusing a pending command, or leaving it to the agent's own
            // prompt, must remain available without Pro.
            return decision != .deny && handBack != true
        default:
            return true
        }
    }

    static func offersUpgrade(for message: ClientMessage) -> Bool {
        switch message {
        case .text, .key, .focus, .appCommand, .approvalDecision,
             .focusWindow, .openWindow, .pointAtPanel, .reshapePanel:
            return true
        default:
            return false
        }
    }
}
