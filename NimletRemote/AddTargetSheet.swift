import SwiftUI

/// What the dock's `+` opens: the Mac's own applications, ranked by how much
/// they are used, and the tmux panes running on it — tap what you want, tap
/// Add.
///
/// It replaced a form that asked for a bundle identifier, typed, on a phone,
/// with a footer explaining that the phone could not list the Mac's apps. It
/// can now: the Mac scans its applications folders, ranks them by Spotlight's
/// own launch counts weighted toward what was used recently, renders each icon
/// and sends the lot over. So this is a grid of app icons, which is the shape
/// this question has on a phone.
///
/// Selecting rather than adding one at a time, for the same reason a photo
/// picker does: the apps a person wants in their dock are decided together, and
/// four round trips to the Mac with a sheet dismissing between each is four
/// chances to lose track of which ones were done.
struct AddTargetSheet: View {
    @EnvironmentObject private var client: NimletClient
    @Environment(\.dismiss) private var dismiss
    /// Where "manage targets" goes, when there is somewhere for it to go. Nil
    /// when this sheet was opened *from* that screen, which is the one place
    /// the row would be a loop.
    var onManage: (() -> Void)?

    @State private var chosenApps: Set<String> = []
    @State private var chosenPanes: Set<String> = []
    @State private var typing = false

    /// Wide enough for an icon and a name under it, and narrow enough that four
    /// fit across the narrowest phone.
    private let columns = [GridItem(.adaptive(minimum: 78), spacing: 12)]

    private var total: Int { chosenApps.count + chosenPanes.count }

    var body: some View {
        NavigationStack {
            List {
                appSection
                paneSection
                Section {
                    // The escape hatch, kept: the grid above offers what is in
                    // the Mac's applications folders, and an app built into a
                    // checkout is in none of them.
                    Button("Add by bundle identifier…") { typing = true }
                    if let onManage {
                        Button("Manage targets…") {
                            dismiss()
                            onManage()
                        }
                    }
                } footer: {
                    Text(onManage == nil
                         ? "For an app that lives somewhere other than the Mac's Applications folders."
                         : "Renaming a target, pointing it at another pane, or stopping Nimlet "
                           + "pressing Return on it all live under Manage.")
                }
            }
            .navigationTitle("Add to the dock")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(total > 0 ? "Add \(total)" : "Add") { add() }
                        .disabled(total == 0)
                }
            }
            .task {
                // Both are snapshots of a machine this phone cannot see, so
                // both are asked for when the sheet opens and neither is kept
                // after it closes.
                client.requestApps()
                client.requestPanes()
            }
            .onDisappear { client.forgetApps() }
            .sheet(isPresented: $typing) { TargetAdder() }
        }
    }

    // MARK: - Apps

    @ViewBuilder private var appSection: some View {
        Section {
            if client.appSuggestions.isEmpty {
                if client.isFetchingApps {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Looking at that Mac…").foregroundStyle(.secondary)
                    }
                    StalledHint(after: 10,
                                message: "Taking longer than usual. The Mac may be busy, or the link may have dropped.",
                                actionTitle: "Ask again") { client.requestApps(refresh: true) }
                } else {
                    // The two silences are not the same silence: a Mac that
                    // answered with nothing is a strange thing worth saying out
                    // loud, and a link that dropped while this was open is an
                    // ordinary thing that fixes itself.
                    Text(client.state.isConnected
                         ? "No applications came back from that Mac."
                         : "Not connected, so there is nothing to ask.")
                        .foregroundStyle(.secondary)
                }
            } else {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(client.appSuggestions) { app in
                        AppTile(app: app,
                                icon: client.icon(for: app),
                                isChosen: chosenApps.contains(app.id)) {
                            toggle(app)
                        }
                        .onAppear { client.requestIcons(bundleIDs: [app.bundleID]) }
                    }
                }
                .padding(.vertical, 6)
            }
        } header: {
            HStack {
                Text("Apps on that Mac")
                Spacer()
                Button("Rescan") { client.requestApps(refresh: true) }
                    .font(.caption)
                    .textCase(nil)
                    .disabled(client.isFetchingApps)
            }
        } footer: {
            // Said plainly, because an order nobody can account for looks
            // arbitrary — and because "most used" is a claim, and the user is
            // the only one who can tell whether it came out right.
            Text("Ordered by how much each one is used on that Mac, with whatever is open "
                 + "right now brought forward. Tap one to raise it and paste into it from here.")
        }
    }

    private func toggle(_ app: MacApp) {
        guard !app.isAdded else { return }
        Haptics.secondaryClick()
        if chosenApps.contains(app.id) {
            chosenApps.remove(app.id)
        } else {
            chosenApps.insert(app.id)
        }
    }

    // MARK: - Panes

    @ViewBuilder private var paneSection: some View {
        Section {
            if client.panes.isEmpty {
                if client.isFetchingPanes {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Asking the Mac…").foregroundStyle(.secondary)
                    }
                    StalledHint(after: 10,
                                message: "Taking longer than usual. The Mac may be busy, or the link may have dropped.",
                                actionTitle: "Ask again") { client.requestPanes() }
                } else {
                    Text(client.status?.tmuxAvailable == false
                         ? "tmux isn't installed on that Mac, so there are no panes to offer."
                         : "tmux is installed, but no panes are running.")
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(client.panes) { pane in
                Button { toggle(pane) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: chosenPanes.contains(pane.id)
                              ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(chosenPanes.contains(pane.id) ? Color.accentColor
                                                                           : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(pane.command)  \(pane.spec)").font(.callout)
                            Text(pane.shortPath).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(chosenPanes.contains(pane.id) ? [.isButton, .isSelected]
                                                                      : .isButton)
            }
        } header: {
            Text("tmux panes")
        } footer: {
            Text("A pane arrives whether or not its window is visible, and Nimlet will not press "
                 + "Return on one running a shell.")
        }
    }

    private func toggle(_ pane: TmuxPane) {
        Haptics.secondaryClick()
        if chosenPanes.contains(pane.id) {
            chosenPanes.remove(pane.id)
        } else {
            chosenPanes.insert(pane.id)
        }
    }

    // MARK: - Adding

    private func add() {
        var made: [NimletTarget] = []
        // In the order they are shown rather than the order they were tapped:
        // a set has no order, and the dock is a row whose order is the whole
        // point of it.
        for app in client.appSuggestions where chosenApps.contains(app.id) {
            made.append(app.asTarget())
        }
        for pane in client.panes where chosenPanes.contains(pane.id) {
            made.append(Self.target(for: pane, avoiding: made))
        }
        client.addTargets(made)
        Haptics.click()
        dismiss()
    }

    /// A pane's target, named after what is running in it.
    ///
    /// `submitOnSend` follows the same rule the Mac seeds by: a shell prompt is
    /// the one place a dictated sentence must not be submitted on this phone's
    /// say-so, and the Mac refuses a duplicate name — so two `zsh` panes chosen
    /// together are told apart here rather than half-refused there.
    private static func target(for pane: TmuxPane, avoiding taken: [NimletTarget]) -> NimletTarget {
        let isShell = ShortcutProfiles.guess(forCommand: pane.command).id == ShortcutProfiles.shell.id
        var name = pane.command
        if taken.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            name = "\(pane.command) (\(pane.spec))"
        }
        return NimletTarget(name: name,
                          kind: .tmux,
                          tmuxTarget: pane.id,
                          submitOnSend: !isShell,
                          allowAutoSubmit: !isShell,
                          symbol: "terminal")
    }
}

// MARK: - One app

/// An app, drawn as itself.
///
/// The icon is the Mac's own, at 128px, so this reads like a Home screen rather
/// than like a settings row — which is the whole difference between choosing an
/// app and configuring one.
private struct AppTile: View {
    let app: MacApp
    let icon: UIImage?
    let isChosen: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 5) {
                ZStack(alignment: .bottomTrailing) {
                    face
                    if app.isAdded {
                        badge("checkmark", .green)
                    } else if isChosen {
                        badge("plus", Color.accentColor)
                    }
                }
                Text(app.name)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .foregroundStyle(app.isAdded ? .secondary : .primary)
                Text(caption)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .opacity(app.isAdded ? 0.45 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(app.isAdded)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(app.name)
        .accessibilityValue(app.isAdded ? "already in the dock"
                                        : (isChosen ? "selected, \(caption)" : caption))
        .accessibilityHint(app.isAdded ? "" : "Double tap to add it when you tap Add")
        .accessibilityAddTraits(isChosen || app.isAdded ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder private var face: some View {
        Group {
            if let icon {
                Image(uiImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                // The half second before its picture lands, and for good on a
                // Mac that could not render one.
                Image(systemName: app.symbol)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.secondary.opacity(0.12),
                                in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            }
        }
        .frame(width: 54, height: 54)
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(Color.accentColor, lineWidth: isChosen ? 2 : 0)
                .padding(-3)
        )
    }

    private func badge(_ symbol: String, _ tint: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.white)
            .padding(3)
            .background(tint, in: Circle())
            .overlay(Circle().strokeBorder(Color(.systemBackground), lineWidth: 1.5))
            .offset(x: 4, y: 4)
    }

    /// Why this one is where it is in the list. Running beats an age, because
    /// it is the more useful fact and the one the ranking weighted most.
    private var caption: String {
        if app.isAdded { return "in the dock" }
        if app.isRunning { return "open now" }
        guard let millis = app.lastUsedEpochMillis else { return "not used lately" }
        let seconds = max(0, Date().timeIntervalSince1970 - Double(millis) / 1000)
        if seconds < 3600 { return "used today" }
        if seconds < 86_400 { return "\(Int(seconds / 3600))h ago" }
        let days = Int(seconds / 86_400)
        if days < 30 { return "\(days)d ago" }
        return "\(days / 30)mo ago"
    }
}
