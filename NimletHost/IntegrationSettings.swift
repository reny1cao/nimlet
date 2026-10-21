import SwiftUI
import AppKit

/// Settings → Agents: the bundled command-line tool and the hooks that let an
/// agent report to the phone. One click each, where it used to be a compiler,
/// a `pair` command, an approval and a JSON file edited by hand.
struct AgentsSettingsPane: View {
    @EnvironmentObject private var server: HostServer
    @EnvironmentObject private var state: HostState
    @ObservedObject private var registry = DeviceRegistry.shared
    @State private var status = HookInstaller.status()
    @State private var problem: String?
    @State private var done: String?
    @State private var wait = AgentWait.seconds

    var body: some View {
        Form {
            Section {
                if status.cliAvailable {
                    LabeledContent("Command-line tool") {
                        Text(HookInstaller.cliURL?.path ?? "")
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Status") {
                        if status.cliPaired && status.cliApproved {
                            Label("Paired with this Mac and approved", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        } else if status.cliPaired {
                            Label("Paired, not approved", systemImage: "exclamationmark.circle")
                                .foregroundStyle(.orange)
                        } else {
                            Text("Not paired yet").foregroundStyle(.secondary)
                        }
                    }
                    LabeledContent("Pairing code") {
                        HStack {
                            Text(state.pairingCode)
                                .font(.body.monospaced()).tracking(2)
                                .textSelection(.enabled)
                            Button {
                                run {
                                    state.rotatePairingCode()
                                    // The tool holds the old code; keep it working.
                                    if status.cliPaired {
                                        try HookInstaller.pairCLI(pairingCode: state.pairingCode,
                                                                  hostName: server.hostDisplayName)
                                    }
                                    done = "New pairing code. Copies of the tool paired by hand elsewhere need `nimlet pair` again."
                                }
                            } label: {
                                Image(systemName: "arrow.triangle.2.circlepath")
                            }
                            .buttonStyle(.borderless)
                            .help("Rotate the code; the tool on this Mac is re-paired for you")
                        }
                    }
                    Button(status.cliPaired && status.cliApproved ? "Pair again" : "Pair with this Mac") {
                        run {
                            try HookInstaller.pairCLI(pairingCode: state.pairingCode,
                                                      hostName: server.hostDisplayName)
                            done = "The tool is paired with this Mac and approved."
                        }
                    }
                } else {
                    Label("This copy of Nimlet has no command-line tool inside it.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Reinstall from nimlet.app/download, or build with `make install-host`.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("The tool agents talk through")
            } footer: {
                Text("Hooks call this tool to tell your phone an agent finished, is waiting, or wants to run a command. Pairing writes ~/.config/nimlet/config.json with this Mac's pairing code and approves the tool like a phone. Phones never use this code; they pair by key.")
            }

            Section {
                hookRow(.waiting,
                        title: "Answer agents from your phone",
                        detail: "When an agent asks permission or asks you a question, the phone shows what it wants and the choices it offered, and your answer goes back to that session. The agent\u{2019}s own prompt stays on the Mac too; whichever you answer first counts. Unanswered, it stays on the Mac and nothing is approved. Claude Code: permission prompts and questions, in a terminal or the Claude app. Codex: permission prompts while you are away from the Mac (screen locked, or a minute without typing); its questions are only shown.",
                        installed: status.waitingHook)
                hookRow(.stop,
                        title: "Tell the phone when a run finishes",
                        detail: "A Stop hook. It also takes down a \u{201C}waiting for you\u{201D} that was answered at the Mac. A phone that is asleep is pushed if notifications are set up.",
                        installed: status.stopHook)
                hookRow(.approval,
                        title: "Ask the phone before every Bash command",
                        detail: "Claude Code only. A PreToolUse hook on Bash, even for commands Claude would run without asking. Each waits for Approve or Deny on the phone or in the menu bar; unanswered, it is denied.",
                        installed: status.approvalHook)
                Picker(selection: $wait) {
                    ForEach(ApprovalWait.choices, id: \.self) { seconds in
                        Text(ApprovalWait.describe(seconds)).tag(seconds)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Wait for an answer")
                        Text("How long a question or permission prompt stays answerable from the phone. When it runs out nothing is approved: the agent\u{2019}s own prompt is still on the Mac, and the Bash gate denies the command. Longer suits a run you only check now and then.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .onChange(of: wait) { _, seconds in AgentWait.seconds = seconds }
                HStack {
                    Button("Reveal settings.json") { HookInstaller.revealSettings() }
                    Spacer()
                    Text(status.codexPresent ? "~/.claude/settings.json · ~/.codex/hooks.json" : "~/.claude/settings.json")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text(status.codexPresent ? "Claude Code and Codex hooks" : "Claude Code hooks")
            } footer: {
                Text("In a tmux pane that is a Nimlet target, the hooks report as that pane. Anywhere else they report as an app target for the app they run in — the Claude app, ChatGPT, your terminal — and failing that as \u{201C}Claude Code\u{201D} or \u{201C}Codex\u{201D}. A copy of each file is kept beside it before every change. Codex runs a hook only after you trust it: type /hooks in a Codex session once after installing.")
            }

            if let done {
                Section { Label(done, systemImage: "checkmark.circle").foregroundStyle(.green) }
            }
            if let problem {
                Section { Label(problem, systemImage: "xmark.octagon").foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear(perform: refresh)
        .onReceive(registry.$approved) { _ in refresh() }
    }

    private func hookRow(_ which: HookInstaller.Switch, title: String, detail: String,
                         installed: Bool) -> some View {
        let files = which.agents.map { "~/" + $0.settingsPath }.joined(separator: " and ")
        return HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if installed {
                Button("Remove") { run { try HookInstaller.remove(which); done = "Removed from \(files)." } }
            } else {
                Button("Install") {
                    run {
                        if !(status.cliPaired && status.cliApproved) {
                            try HookInstaller.pairCLI(pairingCode: state.pairingCode,
                                                      hostName: server.hostDisplayName)
                        }
                        try HookInstaller.install(which)
                        done = "Written to \(files). Agents pick it up when a session next starts."
                            + (which.agents.contains(.codex) ? " In Codex, trust it once with /hooks." : "")
                    }
                }
                .disabled(!status.cliAvailable)
            }
        }
    }

    private func run(_ work: () throws -> Void) {
        problem = nil
        done = nil
        do { try work() } catch { problem = error.localizedDescription }
        refresh()
    }

    private func refresh() { status = HookInstaller.status() }
}

/// Settings → Notifications: where a push to a sleeping phone goes.
struct NotificationsSettingsPane: View {
    @State private var relay = PushSender.shared.customRelay
    @State private var secret = PushSender.shared.customSecret
    @State private var summary = ""
    @State private var probe: String?

    private var builtIn: URL? { PushSender.builtInRelay }

    var body: some View {
        Form {
            Section {
                if let builtIn {
                    LabeledContent("Built in", value: builtIn.absoluteString)
                }
                TextField(builtIn == nil ? "https://…workers.dev" : "Leave empty to use the built-in relay",
                          text: $relay)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                SecureField("Relay secret, if it has one", text: $secret)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("Save") {
                        guard PushSender.shared.setRelay(relay, secret: secret) else {
                            probe = "Could not save the secret to Keychain"
                            return
                        }
                        probe = nil
                        refresh()
                    }
                    Button("Test") {
                        guard PushSender.shared.setRelay(relay, secret: secret) else {
                            probe = "Could not save the secret to Keychain"
                            return
                        }
                        probe = "Asking…"
                        PushSender.shared.probe { probe = $0 }
                    }
                    Spacer()
                    if let probe { Text(probe).font(.caption).foregroundStyle(.secondary) }
                }
                LabeledContent("Phones", value: summary)
            } header: {
                Text("Reaching a phone that is asleep")
            } footer: {
                Text("iOS freezes Nimlet about half a minute after it leaves the screen, so an agent that needs you after that is reached through Apple's push service instead. The push is sealed on this Mac with the phone's own key; the relay forwards ciphertext and sees which phone, when, and nothing else. With no relay set, nothing leaves this Mac and a sleeping phone is simply not told. Relay/README.md in the source tree is the four-step deployment.")
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear(perform: refresh)
    }

    private func refresh() {
        PushSender.shared.summary { summary = $0 }
    }
}
