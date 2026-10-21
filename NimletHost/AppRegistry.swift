import AppKit
import Combine

/// Lightweight process state only. Window walks and icon rendering stay off the main thread.
final class AppRegistry: ObservableObject {
    static let shared = AppRegistry()
    private struct Process { var app: NSRunningApplication; var identity: AppInstanceIdentity }
    @Published private(set) var snapshot: AppRuntimeSnapshot
    private var processes: [Int32: Process] = [:]
    private var observers: [NSObjectProtocol] = []
    private let lock = NSLock()
    private var copy: AppRuntimeSnapshot
    private let runningApplications: () -> [NSRunningApplication]
    private let notificationCenter: NotificationCenter
    private var refreshScheduled = false
    private var refreshing = false

    init(runningApplications: @escaping () -> [NSRunningApplication] = { NSWorkspace.shared.runningApplications },
         notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter) {
        self.runningApplications = runningApplications
        self.notificationCenter = notificationCenter
        let first = AppRuntimeSnapshot(hostSessionID: UUID().uuidString, revision: 0, apps: [])
        snapshot = first
        copy = first
        onMain {
            let center = notificationCenter
            for name in [NSWorkspace.didLaunchApplicationNotification,
                         NSWorkspace.didTerminateApplicationNotification,
                         NSWorkspace.didActivateApplicationNotification,
                         NSWorkspace.didHideApplicationNotification,
                         NSWorkspace.didUnhideApplicationNotification] {
                observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    self?.scheduleRefresh()
                })
            }
            refresh()
        }
    }

    deinit { observers.forEach { notificationCenter.removeObserver($0) } }

    var safeSnapshot: AppRuntimeSnapshot { lock.withLock { copy } }

    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            self.refresh()
        }
    }

    func refresh() {
        guard Thread.isMainThread else { DispatchQueue.main.async { self.refresh() }; return }
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        let mine = Bundle.main.bundleIdentifier
        let running = runningApplications().filter {
            // LaunchServices includes automatically terminated apps with PID -1.
            // They are installed choices, not live processes. Two such entries
            // collide in `processes` and churn their identities on every scan.
            $0.processIdentifier > 0 && $0.activationPolicy == .regular
                && !$0.isTerminated && $0.bundleIdentifier != mine
        }
        var current: [Int32: Process] = [:]
        var apps: [RunningMacApp] = []
        for app in running {
            guard let bundleID = app.bundleIdentifier else { continue }
            let pid = app.processIdentifier
            guard current[pid] == nil else { continue }
            let ref = AppReference(bundleID: bundleID, applicationPath: app.bundleURL?.standardizedFileURL.path)
            // A retained NSRunningApplication is tied to its lifetime. PID reuse cannot revive it.
            let identity: AppInstanceIdentity
            if let old = processes[pid], !old.app.isTerminated, old.identity.app == ref {
                identity = old.identity
            } else {
                identity = AppInstanceIdentity(hostSessionID: snapshot.hostSessionID,
                    instanceID: UUID().uuidString, processID: pid, app: ref,
                    launchEpochMillis: app.launchDate.map { Int64($0.timeIntervalSince1970 * 1000) })
            }
            current[pid] = Process(app: app, identity: identity)
            apps.append(RunningMacApp(identity: identity, name: app.localizedName ?? bundleID,
                                      isActive: app.isActive, isHidden: app.isHidden))
        }
        apps.sort { ($0.name.localizedLowercase, $0.identity.app.key, $0.id)
            < ($1.name.localizedLowercase, $1.identity.app.key, $1.id) }
        processes = current
        guard apps != snapshot.apps else { return }
        let next = AppRuntimeSnapshot(hostSessionID: snapshot.hostSessionID,
                                      revision: snapshot.revision + 1, apps: apps)
        lock.withLock { copy = next }
        snapshot = next
    }

    func identity(for ref: AppReference) -> AppInstanceIdentity? {
        onMain {
            refresh()
            let matches = snapshot.apps.filter { ref.matches($0.identity.app) }
            return matches.count == 1 ? matches.first?.identity : nil
        }
    }

    func resolve(_ identity: AppInstanceIdentity) -> NSRunningApplication? {
        onMain {
            refresh()
            guard identity.hostSessionID == snapshot.hostSessionID,
                  let found = processes[identity.processID], found.identity == identity,
                  !found.app.isTerminated else { return nil }
            return found.app
        }
    }

    func resolvePinned(_ identity: AppInstanceIdentity) -> NSRunningApplication? {
        onMain {
            refresh()
            guard let live = snapshot.apps.first(where: { identity.identifiesSameProcess(as: $0.identity) }) else { return nil }
            return resolve(live.identity)
        }
    }

    static func running(_ ref: AppReference) -> NSRunningApplication? {
        guard let identity = shared.identity(for: ref) else { return nil }
        return shared.resolve(identity)
    }

    static func installedURL(_ ref: AppReference) -> URL? {
        onMain {
            if let path = ref.applicationPath {
                let url = URL(fileURLWithPath: path).standardizedFileURL
                guard url.pathExtension == "app", Bundle(url: url)?.bundleIdentifier?.lowercased() == ref.bundleID.lowercased(),
                      FileManager.default.fileExists(atPath: url.path) else { return nil }
                return url
            }
            return NSWorkspace.shared.urlForApplication(withBundleIdentifier: ref.bundleID)
        }
    }
}
