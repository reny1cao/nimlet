import SwiftUI

/// The settings that belong on the phone rather than on the Mac.
///
/// The Mac owns targets, pairing and the Return policy — it is where those can
/// be checked against what is actually running. What is left here is what only
/// this phone can know: what it is called, how much you dictate at once, and
/// how its own sensors behave.
///
/// Three of these used to exist only as `defaults write` keys, which on an
/// iPhone means they did not exist at all. The axis signs in particular were
/// documented as the fix for steering going the wrong way, on a device with no
/// way to write a default.
struct SettingsSheet: View {
    @Binding var reviewThreshold: Int
    var onManageTargets: () -> Void = {}
    @EnvironmentObject private var client: NimletClient
    @EnvironmentObject private var listen: ListenClient
    @EnvironmentObject private var panel: PanelClient
    @ObservedObject private var alerts = AgentAlerts.shared
    @Environment(\.dismiss) private var dismiss
    @AppStorage("mice.air.slideGain") private var slideGain = 2.6
    @AppStorage("mice.air.gain") private var steerGain = 2200.0
    @AppStorage("mice.air.invertX") private var invertX = false
    @AppStorage("mice.air.invertY") private var invertY = false
    @AppStorage("mice.air.shown") private var showsAirPill = false
    @AppStorage("mice.fanOut.shown") private var showsFanOut = false
    @AppStorage("mice.panel.shown") private var showsMirror = true
    @AppStorage("mice.dock.showNames") private var showsDockNames = true
    @AppStorage(DictationLanguage.key) private var dictationLanguage = ""
    @State private var copiedDiagnostics = false
    @State private var showingPro = false
    @State private var managingSubscription = false
    @ObservedObject private var pro = ProStore.shared

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if pro.isPublicBeta {
                        LabeledContent("Nimlet Beta", value: "All features available")
                        Text("No purchase needed during public testing. Pricing and early-bird details will be announced later.")
                            .font(.footnote).foregroundStyle(.secondary)
                        Link("Public beta & feedback", destination: URL(string: "https://nimlet.app/beta/")!)
                    } else {
                        if pro.hasPro {
                            LabeledContent("Nimlet Pro", value: pro.hasLifetime ? "Lifetime" : "Subscribed")
                        }
                        // Shown to a Lifetime owner too: buying Lifetime does not
                        // stop a subscription, and this is the way out of it.
                        if pro.hasSubscription {
                            Button("Manage Subscription…") { managingSubscription = true }
                        }
                        if !pro.hasLifetime {
                            Button(pro.hasSubscription ? "Switch to Lifetime…" : "Nimlet Pro…") { showingPro = true }
                        }
                    }
                }
                Section {
                    LabeledContent("Mac", value: client.currentHostName ?? "not connected")
                    // Labelled like the row above it, or an editable field in
                    // a list of values reads as another value.
                    HStack {
                        Text("This phone")
                        Spacer(minLength: 12)
                        TextField(client.defaultDeviceName, text: $client.deviceName)
                            .textInputAutocapitalization(.words)
                            .autocorrectionDisabled()
                            .multilineTextAlignment(.trailing)
                            .accessibilityLabel("This phone's name")
                    }
                    Button("Targets…", action: onManageTargets)
                        .disabled(!client.state.isConnected)
                } header: {
                    Text("Connection")
                } footer: {
                    Text("The name is what your Mac shows when it asks you to approve this "
                         + "phone. A new one reaches it the next time this phone connects.")
                }

                Section("Network") {
                    LabeledContent("Current route", value: client.connectionRouteDescription)
                    // Measured, and named for what it is: the control socket's
                    // ping, not the time from a touch to the picture changing.
                    if client.state.isConnected, let summary = client.linkStats.roundTripSummary {
                        LabeledContent("Control round trip", value: summary)
                    }
                    if client.state.isConnected, panel.isVideo, let delay = panel.latencyMillis {
                        LabeledContent("Mirror delay", value: "\(Int(delay.rounded())) ms capture to arrival")
                    }
                    if let session = client.session {
                        LabeledContent("Security", value: "Paired by key · \(session.pin.shortCode)")
                    }
                    Text(client.cellularReadiness).font(.callout)
                    Text("Away from your Mac's Wi-Fi, either run Tailscale on both devices, or switch on Reachable on cellular in the Mac's menu.")
                        .font(.caption)
                }

                if client.status != nil || listen.isOn {
                    Section {
                        Toggle("Listen to this Mac", isOn: Binding(
                            get: { listen.isOn },
                            set: { $0 ? listen.turnOn(control: client) : listen.turnOff() }))
                            .disabled(!listen.isOn && (!client.state.isConnected || client.status?.deviceApproved != true))
                        Text(listen.statusDescription)
                            .font(.callout)
                    } header: {
                        Text("Mac audio")
                    } footer: {
                        Text("Streams the Mac's system sound, including other apps and calls. Pauses while you dictate. Requires Screen Recording permission and Let phones listen in the Mac menu.")
                    }
                }

                Section {
                    Picker("Language", selection: $dictationLanguage) {
                        ForEach(DictationLanguage.options) { option in
                            Text(option.name).tag(option.id)
                        }
                    }
                    Stepper(value: $reviewThreshold, in: 40...600, step: 20) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Review over \(reviewThreshold) characters")
                            Text("Shorter than this, letting go sends it.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityLabel("Review transcripts longer than \(reviewThreshold) characters")
                } header: {
                    Text("Dictation")
                } footer: {
                    Text("The language can also be changed while dictating, from the globe beside "
                         + "Send. A long transcript opens for editing before it is sent, because "
                         + "Send otherwise pastes it straight into a prompt with no undo.")
                }

                Section {
                    NavigationLink {
                        AlertSettingsView(alerts: alerts, targets: client.targets, client: client)
                    } label: {
                        LabeledContent("Notifications", value: notificationSummary)
                    }
                } footer: {
                    Text("What the phone is allowed to interrupt you for while you are "
                         + "looking at something else.")
                }

                // Three things that used to be on the screen whether or not
                // anybody wanted them: the mirror, the air pill parked on the
                // pad, and the fan-out button sitting first in the composer's
                // row. Each is a real feature and none of them is the common
                // case, so each is a switch now rather than a default.
                Section("Dock") {
                    Toggle("Show app names", isOn: $showsDockNames)
                }

                Section {
                    Toggle("Mirror the focused pane", isOn: $showsMirror)
                    Toggle("Send to several targets", isOn: $showsFanOut)
                } header: {
                    Text("On screen")
                } footer: {
                    Text("The mirror is the picture of your Mac at the top of the screen; "
                         + "turning it off stops that video stream. Mac audio has its own switch. Fan-out puts a "
                         + "button beside the composer that turns the dock into a list you "
                         + "pick several targets from.")
                }

                Section {
                    Toggle("Show the air pill", isOn: $showsAirPill)
                    if showsAirPill {
                        slider("Tilt sensitivity", value: $steerGain, in: 800...4000, step: 100,
                               display: sensitivityLabel(steerGain, in: 800...4000))
                        slider("Slide speed", value: $slideGain, in: 1...5, step: 0.2,
                               display: String(format: "%.1f×", slideGain))
                        Toggle("Invert sideways", isOn: $invertX)
                        Toggle("Invert up and down", isOn: $invertY)
                    }
                } header: {
                    Text("Air pill")
                } footer: {
                    Text("A circle on the trackpad that steers the pointer by tilting the "
                         + "phone; sliding it with your thumb moves the pointer too. If the "
                         + "pointer goes the wrong way, invert that axis.")
                }

                Section {
                    LabeledContent("Version", value: Self.version)
                    LabeledContent("Nimlet on your Mac", value: client.status == nil ? "not connected" : "up to date")
                    Button("Report a problem…") { reportProblem() }
                    Button(copiedDiagnostics ? "Copied" : "Copy diagnostics") {
                        UIPasteboard.general.string = diagnostics
                        copiedDiagnostics = true
                    }
                    Button("Disconnect", role: .destructive) {
                        client.disconnect()
                        dismiss()
                    }
                } header: {
                    Text("About")
                } footer: {
                    Text("Report a problem opens an email to support@nimlet.app with the versions "
                         + "and connection state filled in — nothing you typed or dictated is included. "
                         + "If the Mac companion is older than this app, update it at nimlet.app/download.")
                }
            }
            .sheet(isPresented: $showingPro) { ProSheet() }
            .manageSubscriptionsSheet(isPresented: $managingSubscription)
            .onChange(of: managingSubscription) { _, open in
                if !open { Task { await pro.refresh() } }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func slider(_ title: String,
                        value: Binding<Double>,
                        in range: ClosedRange<Double>,
                        step: Double,
                        display: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(display)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: step)
                .accessibilityLabel(title)
                .accessibilityValue(display)
        }
    }

    /// The row's own answer to "what will this do", so the common case never
    /// needs opening. Named states rather than a count: "3 of 4" says nothing
    /// about which three.
    private var notificationSummary: String {
        let settings = alerts.settings
        guard settings.isEnabled else { return "Off" }
        if alerts.authorisation == .denied { return "Off in iOS" }
        var kinds: [String] = []
        if settings.waiting { kinds.append("waiting") }
        if settings.approvals { kinds.append("asking") }
        if settings.failed { kinds.append("failed") }
        if settings.done { kinds.append("finished") }
        guard !kinds.isEmpty else { return "Nothing" }
        let muted = settings.mutedTargetIDs.intersection(client.targets.map(\.id)).count
        return kinds.joined(separator: ", ") + (muted > 0 ? " · \(muted) muted" : "")
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let marketing = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(marketing) (\(build))"
    }

    /// A word instead of a raw gain, because 2200 means nothing to anybody.
    private func sensitivityLabel(_ value: Double, in range: ClosedRange<Double>) -> String {
        let fraction = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
        switch fraction {
        case ..<0.25: return "gentle"
        case ..<0.5: return "normal"
        case ..<0.75: return "quick"
        default: return "very quick"
        }
    }

    /// What a bug report needs and nothing it should not: versions, the state
    /// of the link, which end is which. No text, no transcript, no addresses.
    private var diagnostics: String {
        let device = UIDevice.current
        var lines = [
            "Nimlet iPhone \(Self.version), protocol \(NimletProtocol.version)",
            "\(device.systemName) \(device.systemVersion), \(device.model)",
            "Mac: \(client.currentHostName ?? "not connected")",
            "Mac Nimlet: \(client.status.map { "protocol \($0.protocolVersion)" } ?? "not connected")",
            "Approved: \(client.status.map { $0.deviceApproved ? "yes" : "no" } ?? "unknown (not connected)")",
            "Route: \(client.connectionRouteDescription)",
            "Connect: TLS \(client.linkStats.tlsMillis.map { "\($0) ms" } ?? "-"), welcome \(client.linkStats.welcomeMillis.map { "\($0) ms" } ?? "-"), \(client.linkStats.raced.map { "\($0) routes raced" } ?? "-")",
            "Control round trip: \(client.linkStats.roundTripSummary ?? "not measured")",
            "Last route move: \(client.linkStats.lastMove ?? "none")",
            "Last drop: \(client.linkStats.lastDrop ?? "none")",
            "Direct IPv6 probe: \(client.linkStats.direct ?? "not run")",
            "Relay UDP: \(client.linkStats.relayUDP ?? "not asked for")",
            "Mirror route: \(panel.mirrorEndpoint.map { $0 == client.session?.endpoint ? "same as control" : "different from control" } ?? "-")",
            "Mirror: first frame \(panel.firstFrameMillis.map { "\($0) ms after dialing" } ?? "-"), delay \(panel.latencyMillis.map { "\(Int($0)) ms capture to arrival" } ?? "-"), \(String(format: "%.0f", panel.framesPerSecond)) fps",
            "Security: \(client.session.map { "key \($0.pin.shortCode)" } ?? "not connected")",
            "State: \(String(describing: client.state))",
            "Local network denied: \(client.localNetworkDenied ? "yes" : "no")",
            "Notifications: \(notificationSummary)",
        ]
        if let failure = client.failure { lines.append("Last failure: \(failure.message)") }
        return lines.joined(separator: "\n")
    }

    private func reportProblem() {
        let subject = "Nimlet feedback (iPhone \(Self.version))"
        let body = "What I tried:\n\nWhat happened:\n\nWhat I expected:\n\n---\n" + diagnostics
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = "support@nimlet.app"
        components.queryItems = [URLQueryItem(name: "subject", value: subject),
                                 URLQueryItem(name: "body", value: body)]
        guard let url = components.url else { return }
        UIApplication.shared.open(url) { opened in
            // No mail app configured: the text is still on the clipboard, which
            // is the next best place for it.
            if !opened { UIPasteboard.general.string = body }
        }
    }
}
