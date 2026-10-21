import SwiftUI
import AppKit
import Combine

@main
struct NimletHostApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var server = HostServer.shared
    @StateObject private var store = TargetStore.shared
    @StateObject private var state = HostState.shared

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environmentObject(server)
                .environmentObject(store)
                .environmentObject(state)
        } label: {
            // The icon is the only thing a menu bar app shows without being
            // clicked, so it has to say the two things that matter: something
            // needs you (a phone waiting, a grant missing, not listening), or a
            // phone is attached. It used to look identical in all three states.
            Image(systemName: menuBarSymbol)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(server)
                .environmentObject(store)
                .environmentObject(state)
        }
    }

    private var menuBarSymbol: String {
        if server.connectedDevices.contains(where: { !$0.approved }) {
            return "iphone.badge.exclamationmark"
        }
        if !state.accessibilityGranted || !server.isListening {
            return "cursorarrow.click.badge.clock"
        }
        return server.connectedDevices.isEmpty ? "cursorarrow.click" : "cursorarrow.click.2"
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Instrumentation.logger = miceLog
        // Ask once at launch. Without this grant every CGEvent below is a no-op,
        // and the failure mode is silence rather than an error.
        if !EventInjector.shared.isTrusted {
            EventInjector.shared.requestAccessibility()
        }
        HostServer.shared.beginApprovals()
        HostServer.shared.start(pairingCode: HostState.shared.pairingCode)
        HostServer.shared.beginSystemWatch()
        // Publishes this Mac's own addresses whether or not away access is on,
        // and, if it is, asks the router for a way in.
        RemoteReach.shared.begin()
        HostServer.shared.beginRemoteAccessWatch()
        RelayService.shared.begin()
        HostState.shared.beginWatchingAccessibility()
        UpdateCheck.shared.begin()
        ApprovalPrompt.shared.begin()
        HookInstaller.upgradeInstalledHooks()
        // The path contains the user name; the diagnostics line says whether
        // it is translocated, which is the only thing anyone needs from it.
        miceLog.info("launched from \(Bundle.main.bundleURL.path, privacy: .private), login item: \(String(describing: LoginItem.status), privacy: .public)")
        // After the listener is up, so the window can show the code and say
        // whether anything is listening for it.
        SetupWindow.showOnFirstLaunch()

        // Used by Scripts/install-host.sh so installing finishes the job rather
        // than leaving a toggle to go find. Off again from the menu any time.
        if CommandLine.arguments.contains("--enable-login-item") {
            HostState.shared.setLaunchAtLogin(true)
            miceLog.info("login item after register: \(String(describing: LoginItem.status), privacy: .public) error=\(HostState.shared.loginItemError ?? "none", privacy: .public)")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        EventInjector.shared.releaseAllButtons()
        HostServer.shared.stop()
        // The router mapping was a lease on a hole in somebody's firewall; a
        // quit should not leave it open for the rest of the lease.
        RemoteReach.shared.releaseMappingForQuit()
    }
}

/// Small bag of host-side UI state that isn't the server or the target list.
final class HostState: ObservableObject {
    static let shared = HostState()

    private let codeKey = "mice.pairingCode.v1"

    @Published var pairingCode: String {
        didSet { UserDefaults.standard.set(pairingCode, forKey: codeKey) }
    }
    @Published var injectionPaused = false {
        didSet {
            EventInjector.shared.isPaused = injectionPaused
            if injectionPaused {
                EventInjector.shared.releaseAllButtons()
                EventInjector.shared.forgetScrollPhase()
            }
            HostServer.shared.broadcastStatus()
        }
    }
    /// Whether an approved phone may ask to hear this Mac.
    ///
    /// On by default, and that is deliberate rather than lazy: a phone the user
    /// has approved can already be shown a live picture of the screen, which is
    /// strictly more than it can hear. The switch exists because audio is the one
    /// stream that carries other people — a call, somebody in the room — and
    /// there are rooms where the answer is no regardless of whose phone it is.
    @Published var audioAllowed = AudioStreamer.shared.isAllowed {
        didSet { AudioStreamer.shared.isAllowed = audioAllowed }
    }
    @Published private(set) var accessibilityGranted = EventInjector.shared.isTrusted
    /// Separate grant, separate failure: without it the phone's panel view is
    /// blank while pointer and text keep working perfectly.
    @Published private(set) var screenRecordingGranted = ScreenAccess.isGranted
    @Published private(set) var launchAtLogin = LoginItem.isEnabled
    @Published var loginItemError: String?

    private var timer: Timer?
    private var connectionWatch: AnyCancellable?
    private var lastTrustProbe = Date.distantPast
    private var lastPaneScan = Date.distantPast

    private init() {
        if let saved = UserDefaults.standard.string(forKey: codeKey), PairingCode.isValid(saved) {
            pairingCode = saved
        } else {
            let generated = NimletTransport.newPairingCode()
            pairingCode = generated
            UserDefaults.standard.set(generated, forKey: codeKey)
        }
    }

    /// There is no notification for the Accessibility grant, so poll. The user
    /// flips it in System Settings and expects the UI to catch up on its own.
    func beginWatchingAccessibility() {
        connectionWatch = HostServer.shared.$connectedDevices
            .map { !$0.isEmpty }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshPermissions()
                self?.schedulePermissionCheck()
            }
    }

    private func schedulePermissionCheck() {
        timer?.invalidate()
        let interval: TimeInterval = HostServer.shared.connectedDevices.isEmpty ? 30 : 1.5
        let next = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            self?.refreshPermissions()
            self?.schedulePermissionCheck()
        }
        next.tolerance = interval * 0.2
        RunLoop.main.add(next, forMode: .common)
        timer = next
    }

    /// Refresh immediately when the menu opens; idle checks can then be sparse.
    func refreshPermissions() {
        let hasPhone = !HostServer.shared.connectedDevices.isEmpty
        let now = Date()
        // The probe answers in the background; the next check, 1.5 seconds on
        // while a phone is connected, reads what it found.
        if hasPhone, now.timeIntervalSince(lastTrustProbe) >= 15 {
            lastTrustProbe = now
            EventInjector.shared.revalidateTrust()
        }
        let granted = EventInjector.shared.isTrusted
        if granted != accessibilityGranted {
            accessibilityGranted = granted
            HostServer.shared.broadcastStatus()
        }
        let screen = ScreenAccess.isGranted
        if screen != screenRecordingGranted {
            screenRecordingGranted = screen
            HostServer.shared.broadcastStatus()
        }
        let enabled = LoginItem.isEnabled
        if enabled != launchAtLogin { launchAtLogin = enabled }
        if hasPhone, now.timeIntervalSince(lastPaneScan) >= 15 {
            lastPaneScan = now
            TargetStore.shared.refreshProvisional()
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        loginItemError = LoginItem.setEnabled(enabled)
        launchAtLogin = LoginItem.isEnabled
        // Approval was revoked or never given; System Settings is the only place
        // the user can grant it.
        if enabled, LoginItem.needsApproval {
            loginItemError = "Approve Nimlet in Login Items"
            LoginItem.openSettings()
        }
    }

    func rotatePairingCode() {
        pairingCode = NimletTransport.newPairingCode()
        HostServer.shared.restart(pairingCode: pairingCode)
    }

    func openScreenRecordingSettings() {
        ScreenAccess.openSettings()
    }

    func openAccessibilitySettings() {
        EventInjector.shared.requestAccessibility()
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}
