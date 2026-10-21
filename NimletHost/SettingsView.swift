import SwiftUI
import AppKit

/// Where the menu wants Settings to open. The menu bar window and the
/// Settings window share no view hierarchy, so "fix this target" has to pass
/// through something both can see.
final class SettingsRoute: ObservableObject {
    static let shared = SettingsRoute()
    @Published var targetID: String?
}

struct SettingsView: View {
    enum Tab: String {
        case general, targets, agents, notifications
    }

    @ObservedObject private var route = SettingsRoute.shared
    @AppStorage("mice.settings.tab") private var tab: Tab = .targets

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettingsPane()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(Tab.general)
            TargetsSettingsPane()
                .tabItem { Label("Targets", systemImage: "square.grid.2x2") }
                .tag(Tab.targets)
            AgentsSettingsPane()
                .tabItem { Label("Agents", systemImage: "sparkle") }
                .tag(Tab.agents)
            NotificationsSettingsPane()
                .tabItem { Label("Notifications", systemImage: "bell.badge") }
                .tag(Tab.notifications)
        }
        .frame(width: 780, height: 600)
        .onAppear { if route.targetID != nil { tab = .targets } }
        .onChange(of: route.targetID) { _, id in if id != nil { tab = .targets } }
    }
}

/// The settings that are set once and left alone, moved out of the menu so
/// the menu holds only what changes from one day to the next.
private struct GeneralSettingsPane: View {
    @EnvironmentObject private var state: HostState

    var body: some View {
        Form {
            Section {
                if LoginItem.isInstalledInApplications {
                    Toggle("Launch at login", isOn: Binding(
                        get: { state.launchAtLogin },
                        set: { state.setLaunchAtLogin($0) }
                    ))
                    if let error = state.loginItemError {
                        Text(error)
                            .foregroundStyle(.orange)
                    }
                } else {
                    // Registering from anywhere but Applications doesn't
                    // survive; say so rather than offering a toggle that
                    // silently won't stick. Downloads is where a zip opens, so
                    // this is the common case for a tester, not an edge one.
                    LabeledContent("Launch at login") {
                        Text("Needs Nimlet in Applications")
                            .foregroundStyle(.secondary)
                    }
                    Text("Quit Nimlet, move it into your Applications folder, and open it from there.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                LabeledContent("Setup guide") {
                    Button("Open…") { SetupWindow.show() }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct TargetsSettingsPane: View {
    @EnvironmentObject private var store: TargetStore
    @ObservedObject private var route = SettingsRoute.shared
    @State private var selection: String?
    @State private var filter = ""

    var body: some View {
        HStack(spacing: 0) {
            targetList
                .frame(width: 250)
            Divider()
            Group {
                if let target = selectedTarget {
                    TargetEditor(target: binding(for: target))
                        .id(target.id)
                } else {
                    ContentUnavailableView("No targets",
                                           systemImage: "square.dashed",
                                           description: Text("Add one with the + button below the list."))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // The list used to float in the middle of the pane with a window's
        // worth of nothing above it.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            store.refreshTmux()
            takeRoute()
            // An empty editor asked a question nobody needed asked: there is
            // always a target worth showing first.
            if selectedTarget == nil {
                selection = store.activeTargetID ?? store.targets.first?.id
            }
        }
        .onChange(of: route.targetID) { _, _ in takeRoute() }
    }

    private func takeRoute() {
        guard let id = route.targetID else { return }
        filter = ""
        selection = id
        route.targetID = nil
    }

    private var selectedTarget: NimletTarget? {
        store.target(id: selection)
    }

    private func move(from offsets: IndexSet, to destination: Int) {
        store.move(from: offsets, to: destination)
    }

    private var visibleTargets: [NimletTarget] {
        let query = filter.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return store.targets }
        return store.targets.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    private func binding(for target: NimletTarget) -> Binding<NimletTarget> {
        Binding(
            get: { store.targets.first { $0.id == target.id } ?? target },
            set: { store.upsert($0) }
        )
    }

    private var targetList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Filter targets", text: $filter)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .padding([.horizontal, .top], 10)
            .padding(.bottom, 4)

            List(selection: $selection) {
                ForEach(visibleTargets) { target in
                    TargetRow(target: target,
                              unresolved: store.isUnresolved(target.id),
                              active: target.id == store.activeTargetID)
                        .tag(target.id)
                }
                // The order here is the order of the phone's strip, which a
                // filtered list cannot show.
                .onMove(perform: filter.isEmpty ? move : nil)
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            Divider()
            HStack(spacing: 4) {
                Button {
                    let new = NimletTarget(name: "New target", kind: .app, symbol: "app.dashed")
                    store.upsert(new)
                    filter = ""
                    selection = new.id
                } label: { Image(systemName: "plus").frame(width: 20, height: 18) }
                .help("Add a target")

                Button {
                    guard let id = selection else { return }
                    store.remove(ids: [id])
                    selection = store.targets.first?.id
                } label: { Image(systemName: "minus").frame(width: 20, height: 18) }
                .disabled(selection == nil)
                .help("Remove the selected target")

                Spacer()
                Text("Drag to reorder the phone's strip")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .background(Color.primary.opacity(0.03))
    }
}

private struct TargetRow: View {
    let target: NimletTarget
    let unresolved: Bool
    let active: Bool

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: target.symbol)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(target.name)
                    .lineLimit(1)
                Text(unresolved ? "Pane not running" : MenuView.deliveryDescription(target))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if unresolved {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help("This pane is no longer running. Pick another one.")
            } else if active {
                Text("ACTIVE")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.green.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
                    .help("The phone is sending here now")
            }
        }
        .padding(.vertical, 2)
    }
}

private struct TargetEditor: View {
    @EnvironmentObject private var store: TargetStore
    @Binding var target: NimletTarget
    @State private var runningApps: [(name: String, bundleID: String)] = []
    @State private var tmuxPanes: [Tmux.Pane] = []
    @State private var choosingSymbol = false

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 28)
                .padding(.top, 20)

            Form {
                Section("Delivery") {
                    Picker("Delivery", selection: $target.kind) {
                        Text("App").tag(NimletTarget.Kind.app)
                        Text("tmux Pane").tag(NimletTarget.Kind.tmux)
                        Text("Focused Window").tag(NimletTarget.Kind.frontmost)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Text(deliveryExplanation)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                switch target.kind {
                case .app:
                    Section("Application") {
                        TextField("Bundle identifier", text: Binding(
                            get: { target.bundleID ?? "" },
                            set: { target.bundleID = $0 }
                        ))
                        Picker("Pick a running app", selection: Binding(
                            get: { target.bundleID ?? "" },
                            set: { target.bundleID = $0 }
                        )) {
                            Text("—").tag("")
                            ForEach(runningApps, id: \.bundleID) { app in
                                Text("\(app.name)  (\(app.bundleID))").tag(app.bundleID)
                            }
                        }
                        // The list above is what is running *now*, and the app you
                        // want a button for is often the one you have not opened
                        // yet — which left typing a bundle identifier from memory
                        // as the only way to make a target for it.
                        Button("Choose an app…") { chooseApp() }
                        LabeledContent("Buttons", value: ShortcutProfiles
                            .resolved(for: target).name)
                            .help("Chosen from the app's bundle identifier, and pinnable per target "
                                  + "from the phone.")
                    }

                case .tmux:
                    tmuxSection

                case .frontmost:
                    EmptyView()
                }

                Section("Return Key") {
                    Toggle(isOn: $target.allowAutoSubmit) {
                        Text("Allow pressing Return")
                        Text("Turn off for a pane at a shell prompt: text still arrives, but nothing submits it.")
                    }
                    Toggle(isOn: $target.submitOnSend) {
                        Text("Press Return after sending")
                        Text("Submits each message as soon as it lands.")
                    }
                    .disabled(!target.allowAutoSubmit)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
        // One ground under the header and the form, which otherwise drew as
        // two bands of slightly different grey.
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear(perform: refresh)
        .onChange(of: target.kind) { _, _ in refresh() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Button { choosingSymbol = true } label: {
                    Image(systemName: target.symbol.isEmpty ? "questionmark" : target.symbol)
                        .font(.system(size: 22))
                        .frame(width: 48, height: 48)
                        .background(.background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Change the icon shown on the phone")
                .accessibilityLabel("Change icon")
                .popover(isPresented: $choosingSymbol, arrowEdge: .bottom) {
                    SymbolChooser(symbol: $target.symbol)
                }

                VStack(alignment: .leading, spacing: 2) {
                    TextField("Name", text: $target.name)
                        .textFieldStyle(.plain)
                        .font(.title2.weight(.semibold))
                    Text("Shown on the phone's target strip.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                if store.activeTargetID == target.id {
                    Label("Sending here", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.callout.weight(.medium))
                } else {
                    Button("Send Here") { store.setActive(target.id) }
                        .help("Make this the target the phone types into")
                }
            }

            if store.isUnresolved(target.id) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(target.kind == .tmux
                         ? "This pane isn't running anymore. Pick one of the running panes below, and the phone can type here again."
                         : "This target can't be reached right now.")
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.callout)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.13), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
        }
    }

    private var deliveryExplanation: String {
        switch target.kind {
        case .app:
            return "Brings the app to the front, then pastes."
        case .tmux:
            return "Types with tmux send-keys. The terminal doesn't need to be in front, so you can keep working on the Mac."
        case .frontmost:
            return "Text is pasted into whatever already has keyboard focus. Useful as a catch-all button."
        }
    }

    @ViewBuilder private var tmuxSection: some View {
        Section {
            if Tmux.isAvailable {
                // The pane id is what gets stored and the spec is what gets
                // shown: `codex:0.1` names a slot, and the slots renumber the
                // moment any pane closes.
                ForEach(tmuxPanes) { pane in
                    paneRow(selected: target.tmuxTarget == pane.id,
                            spec: pane.spec, detail: pane.command, missing: false) {
                        target.tmuxTarget = pane.id
                    }
                    .help("Pane id \(pane.id)")
                }
                if let current = target.tmuxTarget, !current.isEmpty,
                   !tmuxPanes.contains(where: { $0.id == current }) {
                    // Keep a pane that has since closed in the list, or opening
                    // Settings would quietly repoint the target at whatever
                    // happens to be first.
                    paneRow(selected: true, spec: current, detail: "Not running", missing: true) {}
                }
                if tmuxPanes.isEmpty {
                    Text("No tmux panes are running.")
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("tmux not found. Nimlet looks in Homebrew, MacPorts and Nix's usual places and on this app's PATH; for a tmux elsewhere, run `defaults write com.renyicao.mice.host mice.tmuxPath /path/to/tmux` and relaunch.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } header: {
            HStack {
                Text("Pane")
                Spacer()
                if Tmux.isAvailable {
                    Button {
                        refreshPanes()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
            }
        }
    }

    private func paneRow(selected: Bool, spec: String, detail: String, missing: Bool,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(missing ? AnyShapeStyle(Color.orange)
                                     : selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                Text(spec)
                    .font(.body.monospaced())
                    .foregroundStyle(missing ? Color.orange : Color.primary)
                    .frame(minWidth: 80, alignment: .leading)
                Text(detail)
                    .foregroundStyle(missing ? Color.orange : Color.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// Reads the bundle identifier out of an app the user points at, rather
    /// than asking them to know it. `/Applications` is where the panel opens
    /// because that is where the answer almost always is.
    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url,
              let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return }
        target.bundleID = id
        // An unnamed target is about to be called "Target"; the app's own name
        // is the one the button should carry.
        let appName = FileManager.default.displayName(atPath: url.path)
        if target.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            target.name = appName
        }
        refresh()
    }

    private func refresh() {
        runningApps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in
                guard let id = app.bundleIdentifier, let name = app.localizedName else { return nil }
                return (name, id)
            }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
        refreshPanes()
    }

    /// Listing panes shells out to tmux. Doing that on the main thread from
    /// `.onAppear` meant a slow or wedged tmux froze the Settings window with
    /// no way out of it.
    private func refreshPanes() {
        guard Tmux.isAvailable else {
            tmuxPanes = []
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let panes = Tmux.listPanes()
            DispatchQueue.main.async { self.tmuxPanes = panes }
        }
    }
}

/// The icon a target carries on the phone. A field for any SF Symbol name,
/// with the ones targets usually want a click away.
private struct SymbolChooser: View {
    @Binding var symbol: String

    private static let suggestions = [
        "terminal", "sparkle", "chevron.left.forwardslash.chevron.right", "globe",
        "brain", "text.bubble", "hammer", "doc.text",
        "app.dashed", "square.dashed", "bolt", "cpu",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("SF Symbol name", text: $symbol)
                .textFieldStyle(.roundedBorder)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(32), spacing: 6), count: 6), spacing: 6) {
                ForEach(Self.suggestions, id: \.self) { name in
                    Button { symbol = name } label: {
                        Image(systemName: name)
                            .frame(width: 32, height: 32)
                            .background(symbol == name ? AnyShapeStyle(.tint.opacity(0.2))
                                        : AnyShapeStyle(Color.primary.opacity(0.05)),
                                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(name)
                    .accessibilityLabel(name)
                }
            }
        }
        .padding(12)
        .frame(width: 236)
    }
}
