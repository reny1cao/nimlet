import SwiftUI

/// What the phone is allowed to interrupt you for.
///
/// Shaped around the fact that the defaults are already the right answer for
/// almost everybody: the screen opens on a permission state and four switches,
/// and the two knobs that need explaining are below them with the sentence
/// that explains them. Nobody should have to come here to make notifications
/// work — this is for the afternoon one pane will not stop reporting.
struct AlertSettingsView: View {

    @ObservedObject var alerts: AgentAlerts
    let targets: [NimletTarget]
    /// Only for what the Mac says about itself. Passed rather than taken from
    /// the environment so this screen can be looked at without one.
    var client: NimletClient?
    @State private var asking = false

    var body: some View {
        Form {
            permission

            Section {
                Toggle("Notifications", isOn: bind(\.isEnabled))
            } footer: {
                Text("Nimlet can tell you about an agent while it is running — in front, "
                     + "for a short while after you leave it, or for as long as it is playing "
                     + "your Mac's sound. Past that, iOS freezes the app; whether a phone "
                     + "asleep in a pocket still hears anything depends on the push setup "
                     + "on the Mac, shown below.")
            }

            if alerts.settings.isEnabled {
                interruptions
                whileAsleep
                manner
                perTarget
            }
        }
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Permission

    @ViewBuilder private var permission: some View {
        switch alerts.authorisation {
        case .notAsked, .unknown:
            Section {
                Button {
                    asking = true
                    Task {
                        await alerts.requestAuthorisation()
                        asking = false
                    }
                } label: {
                    HStack {
                        Text("Allow notifications")
                        Spacer()
                        if asking { ProgressView() }
                    }
                }
                .disabled(asking)
            } footer: {
                Text("Nimlet has not asked yet. It asks on its own the first time an agent "
                     + "has something worth telling you, so the question arrives with an "
                     + "answer to \u{201C}about what?\u{201D} attached.")
            }
        case .denied:
            Section {
                Button("Open iOS Settings") {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    UIApplication.shared.open(url)
                }
            } header: {
                Text("Turned off in iOS")
            } footer: {
                Text("Notifications are switched off for Nimlet in iOS Settings, so nothing "
                     + "below can reach you until they are switched back on there.")
            }
        case .allowed:
            EmptyView()
        }
    }

    // MARK: - What

    private var interruptions: some View {
        Section {
            Toggle("Waiting for you", isOn: bind(\.waiting))
            Toggle("Something failed", isOn: bind(\.failed))
            Toggle("Asking permission", isOn: bind(\.approvals))
            if alerts.settings.approvals {
                Toggle("Show the command in the banner", isOn: bind(\.showsApprovalDetail))
            }
            Toggle("Finished a turn", isOn: bind(\.done))
        } header: {
            Text("Interrupt me when")
        } footer: {
            Text("A finished turn is off because it will still be finished when you next "
                 + "look, and an app that buzzes every time an agent stops is an app whose "
                 + "notifications get switched off — taking the other three with them. "
                 + "Turned on, it arrives quietly and does not light a locked screen. "
                 + "An approval banner names the agent and what kind of thing it wants; "
                 + "the command itself — paths, tokens and all — appears on the lock screen "
                 + "only if you ask for it.")
        }
    }

    // MARK: - Past the grace period

    /// The honest status of the one part of this that is not obvious.
    ///
    /// Everything above works while the app is alive, which is about
    /// twenty-five seconds after you leave it. Past that the phone has to be
    /// reached by APNs, and that needs three things to be true at once — this
    /// phone allowed notifications, Apple issued it a token, and the Mac has
    /// somewhere to send one. Any of the three missing looks identical from the
    /// outside: nothing happens. So each is named.
    @ViewBuilder private var whileAsleep: some View {
        Section {
            LabeledContent("This phone", value: reachability)
            if let mac = macReachability {
                LabeledContent("Your Mac", value: mac)
            }
            if let failure = alerts.pushFailure {
                Text(failure)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("While the phone is asleep")
        } footer: {
            Text("Past a short while in your pocket, iOS freezes Nimlet and nothing sent "
                 + "over the connection arrives. If the Mac has a push relay set up — "
                 + "Settings → Notifications in Nimlet on the Mac — it reaches this phone "
                 + "through Apple instead. The notification is sealed with the key this "
                 + "phone and that Mac already share, so what passes through in between "
                 + "cannot be read.")
        }
    }

    private var reachability: String {
        guard alerts.settings.isEnabled else { return "Off" }
        switch alerts.authorisation {
        case .denied: return "Off in iOS"
        case .notAsked, .unknown: return "Not allowed yet"
        case .allowed: return alerts.pushToken == nil ? "Waiting for Apple" : "Reachable"
        }
    }

    /// Nil for a Mac too old to have an opinion. Saying "not set up" about a
    /// Mac that has simply never been asked would be inventing a fault.
    private var macReachability: String? {
        guard let configured = client?.status?.pushRelayConfigured else { return nil }
        return configured ? "Can reach this phone" : "Not set up — Settings → Notifications on the Mac"
    }

    // MARK: - How

    private var manner: some View {
        Section {
            Toggle("Play a sound", isOn: bind(\.playsSound))
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Then stay quiet for")
                    Spacer()
                    Text(Self.duration(alerts.settings.quietSeconds))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(value: bind(\.quietSeconds),
                       in: AlertSettings.quietRange,
                       step: 5)
                    .accessibilityLabel("Quiet period after a sound")
                    .accessibilityValue(Self.duration(alerts.settings.quietSeconds))
            }
            .disabled(!alerts.settings.playsSound)
        } header: {
            Text("Sound")
        } footer: {
            Text("After one target makes a sound, anything else it reports for this long "
                 + "arrives silently. The notification still appears and still says the "
                 + "newest thing — a hook that reports four times a minute should cost one "
                 + "buzz, not four.")
        }
    }

    // MARK: - Which

    @ViewBuilder private var perTarget: some View {
        Section {
            if targets.isEmpty {
                Text("No targets yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(targets) { target in
                    Toggle(isOn: Binding(
                        get: { !alerts.isMuted(target.id) },
                        set: { alerts.setMuted(!$0, targetID: target.id) })) {
                            Text(target.name)
                        }
                }
            }
        } header: {
            Text("Targets")
        } footer: {
            Text("A muted target never interrupts and never appears on the lock screen. It "
                 + "keeps its dot in the dock, because the dot is what you look at when you "
                 + "are looking, and muting is a statement about when you are not.")
        }
    }

    // MARK: - Plumbing

    /// One writable field of the settings, saved through `AgentAlerts` so that
    /// every change goes through the one path that also acts on what is
    /// already on the lock screen.
    private func bind<Value>(_ field: WritableKeyPath<AlertSettings, Value>) -> Binding<Value> {
        Binding(get: { alerts.settings[keyPath: field] },
                set: { newValue in
                    var next = alerts.settings
                    next[keyPath: field] = newValue
                    alerts.update(next)
                })
    }

    private static func duration(_ seconds: TimeInterval) -> String {
        let whole = Int(seconds.rounded())
        if whole == 0 { return "no time" }
        if whole < 60 { return "\(whole)s" }
        let minutes = whole / 60
        let rest = whole % 60
        return rest == 0 ? "\(minutes)m" : "\(minutes)m \(rest)s"
    }
}
