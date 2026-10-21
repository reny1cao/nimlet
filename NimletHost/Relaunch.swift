import AppKit

/// Quit and start again, from a button.
///
/// macOS applies a fresh Screen Recording grant only to a process started
/// after it was given, and the banner that says so used to offer Quit and
/// nothing else — the relaunch was the user's job, from Finder, after finding
/// the app again. A detached shell waits for this process to be gone and
/// opens the same bundle: starting the new copy first would have it fail to
/// bind the port the old one is still holding.
enum Relaunch {
    static func now() {
        let path = Bundle.main.bundleURL.path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "while kill -0 $1 2>/dev/null; do sleep 0.2; done; /usr/bin/open -n \"$2\"",
                             "relaunch", String(ProcessInfo.processInfo.processIdentifier), path]
        do {
            try process.run()
        } catch {
            miceLog.error("relaunch: could not start the helper shell: \(error.localizedDescription, privacy: .public)")
            return
        }
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }
}
