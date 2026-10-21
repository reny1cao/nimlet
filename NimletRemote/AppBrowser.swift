import SwiftUI

/// The row opens an app; its pin edits the Dock and its info button shows details.
struct AppBrowser: View {
    @EnvironmentObject private var client: NimletClient
    @Environment(\.dismiss) private var dismiss
    var onManage: () -> Void
    @State private var section = SectionKind.running
    @State private var query = ""
    @State private var selectedApp: AppReference?
    @State private var selectedName = ""
    @State private var showsDetails = false
    private enum SectionKind: String, CaseIterable {
        case favorites = "Dock", running = "Running", installed = "All apps"
    }
    private func matches(_ text: String) -> Bool { query.isEmpty || text.localizedCaseInsensitiveContains(query) }
    private var favorites: [NimletTarget] {
        client.dockTargets.filter { !$0.isProvisional && $0.kind == .app && matches($0.name + " " + ($0.bundleID ?? "")) }
    }
    private var runningApps: [RunningMacApp] {
        (client.appRuntime?.apps ?? []).filter { matches($0.name + " " + $0.identity.app.key) }
    }
    private var installedApps: [MacApp] {
        client.appSuggestions.filter { matches($0.name + " " + $0.appReference.key) }
    }
    private var count: Int {
        switch section {
        case .favorites: favorites.count
        case .running: runningApps.count
        case .installed: installedApps.count
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Show", selection: $section) {
                        ForEach(SectionKind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented)
                    HStack {
                        Text("\(count) \(count == 1 ? "app" : "apps")")
                        Spacer()
                        Image(systemName: "pin.fill")
                        Text("Keep in Dock")
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 10)
                List {
                    if client.appOperationNotice != nil { AppOperationNotice() }
                    if !client.state.isConnected {
                        Text("Reconnect to use app controls.").foregroundStyle(.secondary)
                    } else if !client.supportsAppManagement {
                        Text("Update Nimlet on your Mac to use app controls.").foregroundStyle(.secondary)
                    }
                    switch section {
                    case .favorites:
                        ForEach(favorites) { target in
                            if let ref = target.appReference { appRow(ref, name: target.name) }
                        }
                        if favorites.isEmpty { Text(query.isEmpty ? "Pin apps from Running or All apps to keep them here." : "No matching apps.").foregroundStyle(.secondary) }
                    case .running:
                        ForEach(runningApps) { app in appRow(app.identity.app, name: app.name) }
                        if client.appRuntime == nil && client.state.isConnected {
                            HStack { ProgressView(); Text("Reading running apps…") }
                        } else if runningApps.isEmpty { Text("No matching running apps.").foregroundStyle(.secondary) }
                    case .installed:
                        if client.isFetchingApps { HStack { ProgressView(); Text("Reading apps…") } }
                        ForEach(installedApps) { app in appRow(app.appReference, name: app.name) }
                        if !client.isFetchingApps && installedApps.isEmpty { Text("No matching apps. Refresh to check your Mac.").foregroundStyle(.secondary) }
                    }
                }
                .listStyle(.plain)
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle("Apps")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "Search apps")
            .navigationDestination(isPresented: $showsDetails) {
                if let selectedApp { AppDetails(app: selectedApp, name: selectedName, onShowMirror: { dismiss() }) }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button("Manage targets", action: { dismiss(); onManage() })
                    } label: { Image(systemName: "ellipsis") }
                }
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
                ToolbarItemGroup(placement: .bottomBar) {
                    if let previous = client.previousTarget {
                        Button { client.focus(previous.id); dismiss() } label: { Label("Back to \(previous.name)", systemImage: "arrow.uturn.backward") }
                    }
                    Spacer()
                    Button { client.requestAppState(); client.requestApps(refresh: true) } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                        .disabled(!client.state.isConnected)
                }
            }
            .task { client.requestAppState(); client.requestApps() }
            .onDisappear { client.forgetApps() }
        }
        .overlay(alignment: .top) { ToastView() }
    }

    private func appRow(_ ref: AppReference, name: String) -> some View {
        let running = client.runningApp(for: ref)
        let runningState = client.appRunningState(for: ref)
        let pinned = client.isDockFavorite(ref)
        let copyCount = client.appSuggestions.filter { $0.bundleID.caseInsensitiveCompare(ref.bundleID) == .orderedSame }.count
        return HStack(spacing: 0) {
            Button {
                if client.supportsAppManagement {
                    if client.performAppAction(.activate, app: ref, targetID: client.appTarget(for: ref)?.id) { dismiss() }
                } else if let target = client.appTarget(for: ref) { client.focus(target.id); dismiss() }
            } label: {
                HStack(spacing: 12) {
                    AppManagementIcon(ref: ref)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(name).font(.body.weight(.medium)).foregroundStyle(.primary).lineLimit(1)
                        if copyCount > 1, let path = ref.applicationPath {
                            Text(path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        } else if section != .running || running?.isHidden == true {
                            Text(runningState == .unknown ? "State unavailable" :
                                (runningState == .notRunning ? "Not running" : (running?.isHidden == true ? "Hidden" : "Running")))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 4)
                }
                .frame(minHeight: 48).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(client.supportsAppManagement ? !client.canManageApps : !client.state.isConnected)
            .accessibilityLabel("\(runningState == .running ? "Show" : "Open") \(name)")
            Button { client.toggleDockFavorite(ref) } label: {
                Image(systemName: pinned ? "pin.fill" : "pin")
                    .font(.system(size: 16)).foregroundStyle(pinned ? Color.accentColor : .secondary)
                    .frame(width: 44, height: 48).contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(!client.canManageApps)
            .accessibilityLabel("\(pinned ? "Remove from Dock" : "Keep in Dock"): \(name)")
            .accessibilityValue(pinned ? "Pinned" : "Not pinned")
            Button {
                selectedApp = ref; selectedName = name; showsDetails = true
            } label: {
                Image(systemName: "info.circle").font(.system(size: 17)).foregroundStyle(.secondary)
                    .frame(width: 44, height: 48).contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityLabel("Details for \(name)")
        }
        .listRowInsets(EdgeInsets(top: 7, leading: 20, bottom: 7, trailing: 8))
        .onAppear { client.requestIcons(bundleIDs: [ref.bundleID]) }
    }
}

private struct AppManagementIcon: View {
    let ref: AppReference
    @EnvironmentObject private var client: NimletClient
    var body: some View {
        Group {
            if let icon = client.appIcons[ref.bundleID.lowercased()] { Image(uiImage: icon).resizable().scaledToFit() }
            else { Image(systemName: "app").resizable().scaledToFit().foregroundStyle(.secondary).padding(5) }
        }.frame(width: 40, height: 40).accessibilityHidden(true)
    }
}

private struct AppDetails: View {
    let app: AppReference
    let name: String
    let onShowMirror: () -> Void
    @EnvironmentObject private var client: NimletClient
    @State private var closingWindow: MacWindow?
    @State private var closingIdentity: AppInstanceIdentity?
    @State private var confirmingClose = false
    @State private var quittingIdentity: AppInstanceIdentity?
    @State private var confirmingQuit = false
    private var running: RunningMacApp? { client.runningApp(for: app) }
    private var runningState: NimletClient.AppRunningState { client.appRunningState(for: app) }
    private var target: NimletTarget? { client.appTarget(for: app) }
    private var roster: NimletClient.WindowRoster? { target.flatMap { client.windowRoster(for: $0.id) } }
    private var usableRoster: Bool { running?.identity == roster?.appIdentity && running != nil }

    var body: some View {
        List {
            if client.appOperationNotice != nil { AppOperationNotice() }
            Section {
                Button(runningState == .running ? "Show app" : "Launch app") { perform(.activate, showMirror: true) }
                Button(client.isDockFavorite(app) ? "Remove from Dock" : "Keep in Dock") {
                    client.toggleDockFavorite(app)
                }
                if running != nil {
                    Button("Quit \(name)…", role: .destructive) { quittingIdentity = running?.identity; confirmingQuit = true }
                }
            }.disabled(!client.canManageApps)
            Section("Windows") {
                if running == nil {
                    Text(runningState == .unknown ? "App state is unconfirmed. Refresh first." :
                        (runningState == .running ? "The app is running more than once. Window controls need a single instance." :
                            "The app is not running. Launch it to see its windows.")).foregroundStyle(.secondary)
                } else if let roster {
                    if let note = roster.note {
                        Text(note.hasPrefix("is ") || note.hasPrefix("isn't ") ? "\(name) \(note)" : note)
                            .foregroundStyle(.secondary)
                    }
                    if roster.windows.isEmpty {
                        if roster.note == nil { Text("The app is running; no windows are open.").foregroundStyle(.secondary) }
                        Button("Ask app to reopen a window") { perform(.reopen, showMirror: true) }
                            .disabled(!client.canManageApps)
                        Text("The app decides whether it supports reopening. You can also use its New shortcut on the control screen.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(roster.windows) { window in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(window.title.isEmpty ? "Untitled window" : window.title)
                            Text(window.isMinimized ? "Minimized" : "Open").font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Button(window.isMinimized ? "Restore" : "Show") {
                                    perform(window.isMinimized ? .restoreWindow : .focusWindow, window: window, showMirror: true)
                                }.buttonStyle(.bordered).disabled(!window.canRaise && !window.isMinimized)
                                Button("Close window…", role: .destructive) { closingWindow = window; closingIdentity = roster.appIdentity; confirmingClose = true }
                                    .buttonStyle(.bordered).disabled(!window.canClose || window.isMinimized)
                            }.disabled(!client.canManageApps || !usableRoster)
                        }.padding(.vertical, 4)
                    }
                    if !usableRoster { Text("The app state changed. Refresh windows before using them.").foregroundStyle(.orange) }
                } else { HStack { ProgressView(); Text("Reading windows…") } }
            }
            Section {
                Button("Refresh app and windows") { refresh() }.disabled(!client.canManageApps)
                if target?.pinnedWindowID != nil {
                    Button("Follow app's front window") {
                        if let target { client.focusWindow(nil, for: target.id); onShowMirror() }
                    }.disabled(!client.canManageApps)
                }
            } footer: {
                Text("Close window affects one Mac window. Quit closes the entire app. Save dialogs appear on the mirror; Cancel leaves the app or window open.")
            }
            if let path = app.applicationPath { Section("App copy") { Text(path).font(.caption).textSelection(.enabled) } }
        }
        .navigationTitle(name).navigationBarTitleDisplayMode(.inline)
        .task(id: running?.identity) { refresh() }
        .confirmationDialog("Quit \(name)?", isPresented: $confirmingQuit, titleVisibility: .visible) {
            Button("Quit app", role: .destructive) { perform(.quit, identity: quittingIdentity, showMirror: true) }
        } message: { Text("This affects all windows in this app. The Mac may ask you to save changes.") }
        .confirmationDialog("Close this window?", isPresented: $confirmingClose, titleVisibility: .visible) {
            if let window = closingWindow {
                Button("Close window", role: .destructive) { perform(.closeWindow, window: window, identity: closingIdentity, showMirror: true) }
            }
        } message: { Text(closingWindow?.title ?? "") }
    }

    private func refresh() {
        client.requestAppState()
        if let identity = running?.identity { client.requestAppWindows(identity) }
    }
    private func perform(_ action: AppCommand.Action, targetID: String? = nil, window: MacWindow? = nil, identity suppliedIdentity: AppInstanceIdentity? = nil, showMirror: Bool = false) {
        let identity = suppliedIdentity ?? (window == nil ? running?.identity : roster?.appIdentity)
        if client.performAppAction(action, app: app, identity: identity,
            targetID: targetID ?? target?.id, windowID: window?.id), showMirror { onShowMirror() }
    }
}

struct AppOperationNotice: View {
    @EnvironmentObject private var client: NimletClient
    var body: some View {
        if let operation = client.appOperationNotice {
            HStack(spacing: 8) {
                ProgressView().tint(.white)
                Text(operation.message).font(.caption).fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12).padding(.vertical, 4)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            .accessibilityElement(children: .contain)
        }
    }
}
