import CoreGraphics
import AppKit

/// Screen Recording is a second TCC grant, completely separate from
/// Accessibility, and window mirroring is silently empty without it — the same
/// failure shape that made `accessibilityGranted` worth sending to the phone.
enum ScreenAccess {

    /// Checks without prompting. Safe to call on a timer.
    static var isGranted: Bool { CGPreflightScreenCaptureAccess() }

    /// Shows the system prompt the first time. Afterwards macOS only takes the
    /// user to System Settings; the grant does not apply to an already-running
    /// process, so the app has to be relaunched before capture works.
    @discardableResult
    static func request() -> Bool { CGRequestScreenCaptureAccess() }

    private static let requestedOnce = NSLock()
    private nonisolated(unsafe) static var hasRequested = false

    /// Asks the first time a viewer actually needs it, rather than at launch:
    /// most of Nimlet never captures anything, and a Screen Recording prompt on
    /// first run would be asking for something the user may never use. Until
    /// this runs, Nimlet does not even appear in the Screen Recording list, so
    /// "grant it in System Settings" would be advice with nothing to click.
    static func requestOnceIfNeeded() {
        guard !isGranted else { return }
        let shouldAsk = requestedOnce.withLock { () -> Bool in
            guard !hasRequested else { return false }
            hasRequested = true
            return true
        }
        guard shouldAsk else { return }
        miceLog.info("view: asking for Screen Recording")
        request()
    }

    static func openSettings() {
        request()
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }
}
