import Foundation
import os

/// `~/Library/Application Support/Nimlet`, and the one-time move from the
/// directory the app made when it was called Mice.
///
/// The folder is user-visible — the menu reveals it, and every image path
/// typed into an agent's prompt starts with it — so it carries the name on
/// the app. The old folder is renamed rather than left beside a new one,
/// because two folders is a question ("which one has my screenshots?") and
/// a rename answers it before it is asked.
enum SupportDirectory {
    static let name = "Nimlet"
    private static let legacyName = "Mice"

    static let url: URL? = {
        let manager = FileManager.default
        guard let base = try? manager.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                          appropriateFor: nil, create: true) else { return nil }
        let directory = base.appendingPathComponent(name, isDirectory: true)
        let legacy = base.appendingPathComponent(legacyName, isDirectory: true)
        if !manager.fileExists(atPath: directory.path), manager.fileExists(atPath: legacy.path) {
            do {
                try manager.moveItem(at: legacy, to: directory)
            } catch {
                // Leave both alone rather than half-move anything; the app
                // keeps working in the new folder either way.
                miceLog.error("support directory: could not rename \(legacy.path, privacy: .private): \(error.localizedDescription, privacy: .public)")
            }
        }
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                     attributes: [.posixPermissions: 0o700])
        // `attributes` only applies to a directory this call made. One that
        // was renamed from the old name, or created by an earlier build with
        // the default mode, keeps whatever it had — so the mode is set either
        // way. The inbox below it does the same.
        try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        return directory
    }()
}
