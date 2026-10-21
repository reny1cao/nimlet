import AppKit

/// Everything a bug report needs from the Mac, in one paste.
///
/// Versions, permissions, what is listening, who is connected, and the last
/// few minutes of this app's own log. Not the pairing code, not any text
/// that was delivered, not any address — public or local — and not a window
/// title: those are the things a person would have to remember to redact, so
/// they are not in it. The log lines that carry them are logged `.private`,
/// which `log show` renders as `<private>`.
enum Diagnostics {

    @MainActor
    static func copyToPasteboard(completion: @escaping () -> Void) {
        compose { text in
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            // Marked transient the way a delivery is: a bug report is for the
            // mail it is about to be pasted into, not for a clipboard
            // manager's history or every device on the user's Apple account.
            let item = NSPasteboardItem()
            item.setString(text, forType: .string)
            EventInjector.markTransient(item)
            pasteboard.writeObjects([item])
            completion()
        }
    }

    @MainActor
    static func compose(completion: @escaping (String) -> Void) {
        let summary = snapshot()
        DispatchQueue.global(qos: .userInitiated).async {
            let log = recentLog()
            DispatchQueue.main.async {
                completion(summary + "\n\n--- Nimlet log, last 10 minutes ---\n" + log)
            }
        }
    }

    @MainActor
    private static func snapshot() -> String {
        let server = HostServer.shared
        let state = HostState.shared
        let registry = DeviceRegistry.shared
        let reach = RemoteReach.shared
        let updates = UpdateCheck.shared
        let hooks = HookInstaller.status()
        let bundle = Bundle.main.bundleURL.path
        var lines: [String] = []
        lines.append("Nimlet for Mac \(UpdateCheck.currentVersion), protocol \(NimletProtocol.version)")
        lines.append("macOS \(ProcessInfo.processInfo.operatingSystemVersionString), \(architecture)")
        lines.append("Running from: \(bundle)\(bundle.contains("/AppTranslocation/") ? " (translocated — not yet moved out of the download)" : "")")
        lines.append("Launch at login: \(String(describing: LoginItem.status))")
        lines.append("Accessibility: \(state.accessibilityGranted ? "granted" : "NOT granted")")
        lines.append("Screen Recording: \(state.screenRecordingGranted ? "granted" : "not granted")")
        lines.append("Listening: \(server.isListening ? "yes" : "NO") as \(server.hostDisplayName) on port \(server.listenPort)")
        if let error = server.lastError { lines.append("Listener problem: \(error)") }
        lines.append("Injection paused: \(state.injectionPaused ? "yes" : "no"); phones may listen: \(state.audioAllowed ? "yes" : "no")")
        let connected = server.connectedDevices.map { "\($0.name) (\($0.approved ? "approved" : "waiting"), via \($0.route.isEmpty ? "?" : $0.route))" }
        lines.append("Connected: \(connected.isEmpty ? "nobody" : connected.joined(separator: ", "))")
        lines.append("Approved devices: \(registry.approved.count); revoked: \(registry.revoked.count)")
        if let newer = server.newerPhone {
            lines.append("A newer phone connected: \(newer.name) speaks protocol \(newer.protocolVersion)")
        }
        let store = TargetStore.shared
        let active = store.activeTargetID.flatMap { id in store.targets.first { $0.id == id } }
        lines.append("Targets: \(store.targets.count); active: \(active.map { "\($0.name) [\($0.kind.rawValue)]" } ?? "none")")
        lines.append("tmux: \(Tmux.executableURL?.path ?? "not found")")
        lines.append("Away access: \(reach.isEnabled ? "on" : "off"); status: \(String(describing: reach.status))")
        // How many ways in, by kind, and not what they are: an address is
        // something to redact, and a count answers "did it find the VPN".
        let kinds = Dictionary(grouping: reach.candidates, by: { $0.reach == .local ? ($0.via == "VPN" ? "VPN" : "local") : $0.reach.rawValue })
        lines.append("Addresses: " + (kinds.isEmpty ? "none" : kinds.keys.sorted().map { "\(kinds[$0]!.count) \($0)" }.joined(separator: ", ")))
        lines.append("Push relay: \(PushSender.shared.isConfigured ? (PushSender.shared.usesBuiltInRelay ? "built in" : "set in Settings") : "not set")")
        lines.append("CLI: \(hooks.cliAvailable ? "bundled" : "MISSING"), paired \(hooks.cliPaired ? "yes" : "no"), approved \(hooks.cliApproved ? "yes" : "no"); hooks: stop \(hooks.stopHook ? "yes" : "no"), approval \(hooks.approvalHook ? "yes" : "no")")
        lines.append("Update check: \(updates.lastChecked.map { "last \($0)" } ?? "not yet")"
                     + (updates.available.map { "; \($0.version) (\($0.build)) available" } ?? "")
                     + (updates.lastProblem.map { "; problem: \($0)" } ?? ""))
        return lines.joined(separator: "\n")
    }

    private static var architecture: String {
        #if arch(arm64)
        return "Apple silicon"
        #else
        return "Intel"
        #endif
    }

    /// `log show` for this app's subsystem. Slow-ish — a second or two — which
    /// is why `compose` runs it off the main thread.
    private static func recentLog() -> String {
        let result = Subprocess.run(URL(fileURLWithPath: "/usr/bin/log"),
                                    ["show", "--predicate", "subsystem == \"com.renyicao.mice\"",
                                     "--last", "10m", "--style", "compact"])
        guard result.ok else { return "(log show failed: \(result.output))" }
        let lines = result.output.split(separator: "\n", omittingEmptySubsequences: false)
        let tail = lines.suffix(300)
        return (lines.count > tail.count ? "(\(lines.count - tail.count) earlier lines omitted)\n" : "")
            + tail.joined(separator: "\n")
    }
}
