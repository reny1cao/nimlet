import Foundation
import AppKit

/// The command-line tool inside this app, and the two things a tester needs
/// done with it that used to need a compiler and a text editor.
///
/// Everything that tells the phone what an agent is doing — "finished",
/// "waiting for you", "may I run this?" — arrives through `nimlet`, a headless
/// client the agent's own hooks call. Shipping the app without it shipped the
/// app without that half. So the tool is copied into `Contents/Helpers` at build
/// time, and this is what pairs it with this Mac, approves it as a device, and
/// writes the hook entries into Claude Code's settings and Codex's hooks file —
/// with a backup of each file first, and a way to take them out again.
enum HookInstaller {

    /// Where the copy build phase puts it: Contents/Helpers, not Contents/MacOS,
    /// beside the app's own executable rather than on top of it: a
    /// case-insensitive disk would treat `Nimlet` and `nimlet` as one file. Nil in a build that was not made through
    /// Xcode's NimletHost target, which is how `make tool` users end up.
    static var cliURL: URL? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/nimlet")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    static let claudeSettingsURL = settingsURL(for: .claudeCode)

    static func settingsURL(for agent: HookAgent) -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(agent.settingsPath)
    }

    /// Codex counts as installed when it has a home: the CLI makes `~/.codex`
    /// on first run, and so does ChatGPT's Codex, which runs the same core
    /// and reads the same hooks file.
    static var codexPresent: Bool {
        var isDirectory: ObjCBool = false
        let home = settingsURL(for: .codex).deletingLastPathComponent().path
        return FileManager.default.fileExists(atPath: home, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// The same place `nimlet pair` writes, in the same shape: `Config` in
    /// Tools/nimlet/Config.swift. Kept byte-compatible on purpose so a tester who
    /// later runs `nimlet pair` by hand is editing the same file.
    static let cliConfigDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config", isDirectory: true)
        .appendingPathComponent("nimlet", isDirectory: true)
    static var cliConfigURL: URL { cliConfigDirectory.appendingPathComponent("config.json") }
    static let cliDeviceName = DeviceRegistry.toolName

    struct Status: Equatable {
        var cliAvailable: Bool
        var cliPaired: Bool
        var cliApproved: Bool
        var waitingHook: Bool
        var stopHook: Bool
        var approvalHook: Bool
        var settingsExists: Bool
        var codexPresent: Bool
    }

    /// The three switches in Settings → Agents.
    enum Switch {
        /// A permission prompt or a question: tell the phone, both agents.
        case waiting
        /// A finished run: tell the phone, both agents.
        case stop
        /// Claude Code's Bash commands wait for an answer from the phone.
        case approval

        /// Which agents' files this switch writes to.
        var agents: [HookAgent] {
            switch self {
            case .waiting, .stop: return HookInstaller.codexPresent ? [.claudeCode, .codex] : [.claudeCode]
            case .approval: return [.claudeCode]
            }
        }

        func entries(for agent: HookAgent, cli: String) -> [HookEntry] {
            switch self {
            case .waiting: return HookPlan.waiting(agent, cli: cli)
            case .stop: return HookPlan.stop(agent, cli: cli)
            case .approval: return agent == .claudeCode ? HookPlan.approval(cli: cli) : []
            }
        }

        /// What an earlier build wrote for this switch and the current one
        /// replaces. Taken out on install and on remove.
        func legacyEntries(for agent: HookAgent) -> [HookEntry] {
            self == .waiting ? HookPlan.legacyWaiting(agent) : []
        }

        static let all: [Switch] = [.waiting, .stop, .approval]
    }

    enum Failure: LocalizedError {
        case noCLI
        case unreadableSettings(String, path: String)
        case cannotWrite(String)

        var errorDescription: String? {
            switch self {
            case .noCLI:
                return "This copy of Nimlet has no command-line tool inside it. Reinstall from nimlet.app/download."
            case .unreadableSettings(let why, let path):
                return "~/\(path) could not be read as JSON (\(why)). Nothing was changed."
            case .cannotWrite(let why):
                return "Could not write the file: \(why)"
            }
        }
    }

    // MARK: - Status

    static func status() -> Status {
        let config = readCLIConfig()
        let deviceID = config?["deviceID"] as? String
        let paired = (config?["pairingCode"] as? String).map { !$0.isEmpty } ?? false
        let approved = deviceID.map { DeviceRegistry.shared.isApproved($0) } ?? false
        return Status(cliAvailable: cliURL != nil,
                      cliPaired: paired,
                      cliApproved: approved,
                      waitingHook: isInstalled(.waiting),
                      stopHook: isInstalled(.stop),
                      approvalHook: isInstalled(.approval),
                      settingsExists: FileManager.default.fileExists(atPath: claudeSettingsURL.path),
                      codexPresent: codexPresent)
    }

    /// Installed when every file the switch writes to has every entry. The
    /// command must be current too: an older hook needs Install to update its
    /// flags, even though Remove still recognises it as ours.
    private static func isInstalled(_ which: Switch) -> Bool {
        let cli = quoted(cliURL?.path ?? "nimlet")
        return which.agents.allSatisfy { agent in
            let root = ((try? readSettings(agent)) ?? nil) ?? [:]
            return HookFile.containsAll(which.entries(for: agent, cli: cli), in: root)
                && !which.legacyEntries(for: agent).contains { HookFile.contains($0, in: root) }
        }
    }

    /// Something of ours for this switch is in a file, current or not: the
    /// person turned it on at some point.
    private static func wasTurnedOn(_ which: Switch) -> Bool {
        let cli = quoted(cliURL?.path ?? "nimlet")
        return which.agents.contains { agent in
            let root = ((try? readSettings(agent)) ?? nil) ?? [:]
            return (which.entries(for: agent, cli: cli) + which.legacyEntries(for: agent))
                .contains { HookFile.contains($0, in: root) }
        }
    }

    /// Brings hooks a person already turned on up to this build, at launch.
    ///
    /// The hook command is part of what the app ships: an older one keeps
    /// running the older behaviour — "waiting for you" that cannot be
    /// answered, a gate that gives up after two minutes — until somebody
    /// opens Settings and presses Install again, which nobody knows to do.
    /// Only switches that are already on are touched, each file is backed up
    /// first as on any install, and everything that is not ours stays as it
    /// was. Codex asks for its hooks to be trusted again after the change.
    static func upgradeInstalledHooks() {
        // The installed app only. A build run from a worktree or DerivedData
        // would point every agent on this Mac at its own copy of the tool.
        guard cliURL != nil, Bundle.main.bundleURL.path.hasPrefix("/Applications/") else { return }
        for which in Switch.all where wasTurnedOn(which) && !isInstalled(which) {
            do {
                try install(which)
                miceLog.info("hooks: brought \(String(describing: which), privacy: .public) up to date")
            } catch {
                miceLog.error("hooks: could not update \(String(describing: which), privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Pairing the tool

    /// Writes the tool's config for *this* Mac and approves its device id.
    ///
    /// Re-pairing keeps an existing device id, exactly as `nimlet pair` does, so
    /// rotating the code never turns the tool into a stranger.
    @MainActor
    static func pairCLI(pairingCode: String, hostName: String) throws {
        guard cliURL != nil else { throw Failure.noCLI }
        let existing = readCLIConfig()
        let deviceID = (existing?["deviceID"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? UUID().uuidString
        let config: [String: Any] = ["pairingCode": pairingCode, "hostName": hostName, "deviceID": deviceID]
        do {
            try FileManager.default.createDirectory(at: cliConfigDirectory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            var data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
            data.append(0x0A)
            try data.write(to: cliConfigURL, options: .atomic)
            // The atomic write made a fresh file; the mode has to be set again.
            // This file holds the pairing code.
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cliConfigURL.path)
        } catch {
            throw Failure.cannotWrite(error.localizedDescription)
        }
        // Approved by name, like a phone — except the user clicked the button
        // that does both, on the Mac the tool runs on.
        DeviceRegistry.shared.approve(deviceID: deviceID, name: cliDeviceName)
        miceLog.info("paired and approved the bundled CLI as \(deviceID, privacy: .private)")
    }

    // MARK: - Hooks

    /// Adds or updates the switch's hooks in each agent's file. Idempotent:
    /// our command is updated in place, keeping the group's other hooks and
    /// options. Every file is read before any is
    /// written, so one that is not JSON stops the lot rather than half of it.
    static func install(_ which: Switch) throws {
        guard let cli = cliURL else { throw Failure.noCLI }
        let command = quoted(cli.path)
        let roots = try which.agents.map { ($0, try readSettings($0) ?? [:]) }
        for (agent, root) in roots {
            let current = HookFile.removing(which.legacyEntries(for: agent), from: root)
            try writeSettings(HookFile.adding(which.entries(for: agent, cli: command), to: current), for: agent)
        }
    }

    /// Takes out every entry of ours for this switch, whoever wrote it, and
    /// leaves everything else in each file exactly as it was.
    static func remove(_ which: Switch) throws {
        let command = quoted(cliURL?.path ?? "nimlet")
        for agent in which.agents {
            guard let root = try readSettings(agent) else { continue }
            let entries = which.entries(for: agent, cli: command) + which.legacyEntries(for: agent)
            guard entries.contains(where: { HookFile.contains($0, in: root) }) else { continue }
            try writeSettings(HookFile.removing(entries, from: root), for: agent)
        }
    }

    static func revealSettings() {
        if FileManager.default.fileExists(atPath: claudeSettingsURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([claudeSettingsURL])
        } else {
            NSWorkspace.shared.open(claudeSettingsURL.deletingLastPathComponent())
        }
    }

    static func quoted(_ path: String) -> String {
        let escaped = path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "$", with: "\\$")
        return "\"\(escaped)\""
    }

    // MARK: - Files

    private static func readCLIConfig() -> [String: Any]? {
        guard let data = try? Data(contentsOf: cliConfigURL) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func readSettings(_ agent: HookAgent) throws -> [String: Any]? {
        guard let data = try? Data(contentsOf: settingsURL(for: agent)) else { return nil }
        if data.isEmpty { return [:] }
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw Failure.unreadableSettings("the top level is not an object", path: agent.settingsPath)
            }
            return object
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.unreadableSettings(error.localizedDescription, path: agent.settingsPath)
        }
    }

    private static func writeSettings(_ root: [String: Any], for agent: HookAgent) throws {
        let manager = FileManager.default
        let url = settingsURL(for: agent)
        do {
            try manager.createDirectory(at: url.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
            // The first write keeps what was there. A settings file is the
            // kind of thing people hand-edit, and a backup beside it is cheaper
            // than an apology.
            if manager.fileExists(atPath: url.path) {
                let stamp = ISO8601DateFormatter().string(from: Date())
                    .replacingOccurrences(of: ":", with: "-")
                let backup = url.deletingLastPathComponent()
                    .appendingPathComponent("\(url.lastPathComponent).before-nimlet-\(stamp)")
                try? manager.copyItem(at: url, to: backup)
            }
            var data = try JSONSerialization.data(withJSONObject: root,
                                                  options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            data.append(0x0A)
            try data.write(to: url, options: .atomic)
        } catch {
            throw Failure.cannotWrite(error.localizedDescription)
        }
    }
}

/// How long an agent's question waits for an answer before it goes back to
/// the agent's own prompt — or, for the Bash gate, is denied. Settings →
/// Agents; read by `nimlet` from the host's status when a hook asks.
enum AgentWait {
    static var seconds: TimeInterval {
        get {
            let stored = UserDefaults.standard.double(forKey: ApprovalWait.defaultsKey)
            return stored > 0 ? ApprovalWait.clamped(stored) : ApprovalWait.standard
        }
        set {
            UserDefaults.standard.set(ApprovalWait.clamped(newValue), forKey: ApprovalWait.defaultsKey)
            HostServer.shared.broadcastStatus()
        }
    }
}
