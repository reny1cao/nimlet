import SwiftUI
import AppKit

/// The window a fresh install opens on.
///
/// A menu bar app announces itself with an icon the size of a fingernail, and
/// the first thing macOS puts in front of a new user is a system alert about
/// Accessibility with no explanation of why. This is the explanation, and the
/// three steps after it, each one ticking itself off as the thing it asks for
/// happens — so the person can watch the phone arrive rather than wonder
/// whether anything is going on. Shown once by itself; reopened from the menu.
enum SetupWindow {
    private static var window: NSWindow?
    private static let shownKey = "mice.setup.shown"

    @MainActor
    static func showOnFirstLaunch() {
        guard !UserDefaults.standard.bool(forKey: shownKey) else { return }
        UserDefaults.standard.set(true, forKey: shownKey)
        show()
    }

    @MainActor
    static func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let root = SetupGuideView()
            .environmentObject(HostServer.shared)
            .environmentObject(HostState.shared)
        let controller = NSHostingController(rootView: root)
        let created = NSWindow(contentViewController: controller)
        created.title = "Set up Nimlet"
        created.styleMask = [.titled, .closable, .miniaturizable]
        created.setContentSize(NSSize(width: 480, height: 640))
        created.center()
        created.isReleasedWhenClosed = false
        // A menu bar app has no Dock icon to click to find this again, and an
        // ordinary window sinks behind whatever the user was doing the moment
        // they click it. Floating keeps it where they left it.
        created.level = .floating
        window = created
        created.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct SetupGuideView: View {
    @EnvironmentObject private var server: HostServer
    @EnvironmentObject private var state: HostState
    @ObservedObject private var registry = DeviceRegistry.shared

    private var connected: [HostServer.ConnectedDevice] { server.connectedDevices.filter(\.approved) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Nimlet is running in your menu bar")
                        .font(.title2.weight(.semibold))
                    Text("Look for the pointer icon at the top right of the screen. Three steps and your iPhone can type here.")
                        .foregroundStyle(.secondary)
                }

                step(1, "Allow Accessibility", done: state.accessibilityGranted) {
                    Text("This is how Nimlet moves the pointer and types for you. Without it, clicks and typing are silently ignored.")
                    if !state.accessibilityGranted {
                        Button("Open Privacy & Security…") { state.openAccessibilitySettings() }
                        Text("Switch on Nimlet in the Accessibility list. This page notices by itself.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                step(2, "Get Nimlet on your iPhone", done: !registry.approved.isEmpty || !server.connectedDevices.isEmpty) {
                    Text("Install it from your TestFlight invitation and open it. Keep the phone on the same Wi-Fi as this Mac; the app finds this Mac by itself.")
                }

                step(3, "Scan the pairing code with the phone", done: !server.connectedDevices.isEmpty) {
                    Button("Pair a Phone…") { PairWindow.show() }
                    Text("Point the iPhone's Camera at the code. Nimlet opens by itself, pairs by key, and can type here straight away.")
                        .font(.caption).foregroundStyle(.secondary)
                    if !server.isListening {
                        Label(server.lastError ?? "Nimlet is not listening for phones yet", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    ForEach(connected) { device in
                        Label("\(device.name) is connected and can type here", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }

                step(4, "Optional: Screen Recording", done: state.screenRecordingGranted) {
                    Text("For a live picture of a window on the phone, screenshots to draw on, and hearing this Mac's sound. Typing and the pointer need only step 1.")
                    if !state.screenRecordingGranted {
                        HStack {
                            Button("Open Privacy & Security…") { state.openScreenRecordingSettings() }
                            Button("Relaunch Nimlet") { Relaunch.now() }
                        }
                        Text("macOS applies this one only to a fresh launch, so relaunch Nimlet after allowing it.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text("Agents").font(.headline)
                    Text("To have an agent tell the phone when it finishes, or ask the phone before running a command, open Settings → Agents and install the Claude Code hooks. One click; nothing else to compile.")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("Open Settings") {
                        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                    }
                }

                Text("Reopen this any time from the menu bar: Setup guide…")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 480, minHeight: 500)
    }

    private func step<Content: View>(_ number: Int, _ title: String, done: Bool,
                                     @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(done ? Color.green : Color.secondary.opacity(0.25))
                    .frame(width: 26, height: 26)
                if done {
                    Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.white)
                } else {
                    Text("\(number)").font(.caption.bold())
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
