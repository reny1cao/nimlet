import AppKit
import Combine
import XCTest

// AppRegistry only needs this short queue crossing, not the host's input router.
func onMain<T>(_ work: () -> T) -> T {
    if Thread.isMainThread { return work() }
    return DispatchQueue.main.sync(execute: work)
}

private final class RegistryApp: NSRunningApplication {
    var pid: Int32 = 123
    var path = "/Applications/QA.app"
    var hasTerminated = false
    override var processIdentifier: pid_t { pid }
    override var bundleIdentifier: String? { "org.nimlet.QA" }
    override var bundleURL: URL? { URL(fileURLWithPath: path) }
    override var localizedName: String? { "QA" }
    override var activationPolicy: NSApplication.ActivationPolicy { .regular }
    override var isTerminated: Bool { hasTerminated }
    override var isActive: Bool { false }
    override var isHidden: Bool { false }
    override var launchDate: Date? { Date(timeIntervalSince1970: 100) }
}

@MainActor
final class AppRegistryTests: XCTestCase {
    func testAppsWithoutProcessesCannotChurnRuntimeIdentityOrTriggerRefreshFeedback() {
        let first = RegistryApp(); first.pid = -1
        let second = RegistryApp(); second.pid = -1; second.path = "/Applications/OtherCopy.app"
        let live = RegistryApp()
        let registry = AppRegistry(runningApplications: { [first, second, live] }, notificationCenter: NotificationCenter())
        let initial = registry.safeSnapshot
        var publications = 0
        let subscription = registry.$snapshot.dropFirst().sink { _ in publications += 1 }
        for _ in 0..<100 { registry.refresh() }
        XCTAssertEqual(registry.safeSnapshot.apps.count, 1, "LaunchServices can report multiple apps with PID -1")
        XCTAssertEqual(registry.safeSnapshot, initial, "Unchanged processes must keep their identity and revision")
        XCTAssertEqual(publications, 0, "A stable scan must not retrigger Dock work")
        subscription.cancel()
    }

    func testProcessReplacementInvalidatesOldIdentity() {
        var app = RegistryApp()
        let registry = AppRegistry(runningApplications: { [app] }, notificationCenter: NotificationCenter())
        let old = registry.safeSnapshot.apps[0].identity
        registry.refresh()
        XCTAssertEqual(registry.safeSnapshot.apps[0].identity, old)
        app.hasTerminated = true
        app = RegistryApp()
        registry.refresh()
        XCTAssertNotEqual(registry.safeSnapshot.apps[0].identity, old)
        XCTAssertNil(registry.resolve(old), "A reused PID cannot address the old app")
    }

    func testNotificationBurstRunsOneScanAndSubscribersCannotRecursivelyRefresh() async {
        let center = NotificationCenter()
        var apps: [NSRunningApplication] = []
        var scans = 0
        let registry = AppRegistry(runningApplications: { scans += 1; return apps }, notificationCenter: center)
        var publications = 0
        let subscription = registry.$snapshot.dropFirst().sink { snapshot in
            publications += 1
            XCTAssertEqual(registry.safeSnapshot, snapshot, "Readers must see the published state")
            registry.refresh()
        }
        apps = [RegistryApp()]
        let baseline = scans
        for _ in 0..<100 {
            center.post(name: NSWorkspace.didLaunchApplicationNotification, object: nil)
            center.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
        }
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        XCTAssertEqual(scans, baseline + 1)
        XCTAssertEqual(publications, 1)
        registry.refresh()
        XCTAssertEqual(publications, 1, "No refresh loop after a state change")
        subscription.cancel()
    }
}
