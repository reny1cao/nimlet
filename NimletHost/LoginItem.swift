import Foundation
import ServiceManagement

/// "Launch at login", via SMAppService.
///
/// Registration only sticks for an app in a stable location — macOS will not
/// keep launching something out of a build directory — so the UI offers this
/// only once Nimlet is installed in /Applications.
enum LoginItem {

    static var status: SMAppService.Status { SMAppService.mainApp.status }

    static var isEnabled: Bool { status == .enabled }

    /// The user can revoke this in System Settings without telling the app, and
    /// `requiresApproval` is how that shows up.
    static var needsApproval: Bool { status == .requiresApproval }

    static var isInstalledInApplications: Bool {
        Bundle.main.bundleURL.path.hasPrefix("/Applications/")
    }

    @discardableResult
    static func setEnabled(_ enabled: Bool) -> String? {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    static func openSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
