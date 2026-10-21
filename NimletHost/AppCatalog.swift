import AppKit
import CoreServices

/// What this Mac has installed, ranked by how much it is actually used, with
/// each app's own icon.
///
/// The phone could never answer this. It cannot see the Mac's disk, so adding
/// an app target meant typing a bundle identifier from memory into a phone
/// keyboard — `com.todesktop.230313mzl4w4u92` being a real example of one — and
/// the screen that asked for it had to admit in its own footer that it could
/// not offer anything better. This is the better thing: the Mac knows what is
/// installed, Spotlight knows how often each one has been opened, and an icon
/// is fifteen kilobytes.
///
/// Everything here blocks — directory scans, a metadata lookup per app, and an
/// icon render each — so it is called from the host's queues and never from
/// main.
final class AppCatalog {
    static let shared = AppCatalog()

    /// How many apps the phone is offered. A picker is a thing you glance at
    /// and tap; past a couple of screenfuls it is a file browser, and the tail
    /// of it is apps nobody would put in a dock.
    static let suggestionLimit = 30

    /// Long enough that opening the picker, closing it and opening it again
    /// costs one scan, short enough that an app installed while the phone is
    /// connected turns up without a relaunch. `refresh` skips it outright.
    private static let lifetime: TimeInterval = 120

    /// A rendered icon is the expensive part and the part that never changes,
    /// so it outlives the ranking it was gathered for.
    private let lock = NSLock()
    private var icons: [String: Data] = [:]
    private var scanned: [Installed] = []
    private var scannedAt = Date.distantPast

    /// One app on disk, before anything is known about how much it is used.
    private struct Installed {
        var url: URL
        var bundleID: String
        var name: String
    }

    // MARK: - What the phone asks for

    /// The apps worth offering, best first.
    ///
    /// `excluding` is the set already in the dock — they come back marked
    /// rather than dropped, because an app missing from the picker reads as an
    /// app Nimlet cannot see.
    func suggestions(refresh: Bool = false,
                     alreadyTargeted: Set<String> = [],
                     limit: Int = AppCatalog.suggestionLimit,
                     includeIcons: Bool = true) -> [MacApp] {
        let installed = scan(refresh: refresh)
        let running = runningBundleIDs()
        let docked = dockedBundleIDs()
        let added = Set(alreadyTargeted.map { $0.lowercased() })
        let now = Date()

        let ranked = installed.map { app -> (app: Installed, score: Double, count: Int, lastUsed: Date?) in
            let (count, lastUsed) = Self.usage(of: app.url)
            let key = app.bundleID.lowercased()
            let score = AppRanking.score(useCount: count,
                                         lastUsed: lastUsed,
                                         isRunning: running.contains(key),
                                         isDocked: docked.contains(key),
                                         isCurated: AppRanking.known(bundleID: key) != nil,
                                         now: now)
            return (app, score, count, lastUsed)
        }
        // Sorted by name within a tie so the order is stable between two scans
        // of a machine where nothing has changed — a picker whose tiles swap
        // places while you are looking at them is a picker you mistap.
        .sorted(by: Self.bestFirst)
        .prefix(limit)

        return ranked.map { app, _, count, lastUsed in
            let key = app.bundleID.lowercased()
            return MacApp(bundleID: app.bundleID,
                          name: app.name,
                          icon: includeIcons ? icon(for: app.url, bundleID: app.bundleID) : nil,
                          symbol: AppRanking.symbol(bundleID: app.bundleID),
                          isRunning: running.contains(key),
                          isAdded: added.contains(key),
                          useCount: count,
                          lastUsedEpochMillis: lastUsed.map { Int64($0.timeIntervalSince1970 * 1000) },
                          applicationPath: app.url.standardizedFileURL.path)
        }
    }

    /// Icons for apps the phone already has targets for, and nothing else: no
    /// ranking, no usage, and nothing for an app that is no longer installed.
    func icons(forBundleIDs bundleIDs: [String]) -> [MacApp] {
        bundleIDs.compactMap { bundleID in
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
                  let icon = icon(for: url, bundleID: bundleID)
            else { return nil }
            return MacApp(bundleID: bundleID,
                          name: Self.displayName(url: url, bundleID: bundleID),
                          icon: icon,
                          symbol: AppRanking.symbol(bundleID: bundleID))
        }
    }

    /// The apps a fresh install should open pointing at.
    ///
    /// The curated table filtered down to what is installed, ranked the same
    /// way everything else is, and capped — because seeding every match put
    /// eleven tiles in a dock before the user had chosen a single one, and the
    /// ones at the end were terminals they do not use.
    ///
    /// Blocking, like the rest of this: `TargetStore` calls it off its own
    /// queue rather than on the launch path.
    static func seeds(limit: Int) -> [NimletTarget] {
        let running = AppCatalog.shared.runningBundleIDs()
        let docked = AppCatalog.shared.dockedBundleIDs()
        let now = Date()
        return AppRanking.curated.compactMap { known -> (NimletTarget, Double)? in
            guard let url = NSWorkspace.shared
                .urlForApplication(withBundleIdentifier: known.bundleID) else { return nil }
            let (count, lastUsed) = usage(of: url)
            let key = known.bundleID.lowercased()
            let score = AppRanking.score(useCount: count,
                                         lastUsed: lastUsed,
                                         isRunning: running.contains(key),
                                         isDocked: docked.contains(key),
                                         isCurated: true,
                                         now: now)
            var target = NimletTarget(name: known.name, kind: .app,
                                    bundleID: known.bundleID, symbol: known.symbol)
            // A seeded terminal must not run what is dictated into it.
            target.applyDefaultSubmitPolicy()
            return (target, score)
        }
        .sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            return lhs.0.name.localizedCaseInsensitiveCompare(rhs.0.name) == .orderedAscending
        }
        .prefix(limit)
        .map(\.0)
    }

    static func displayNameForApp(url: URL, bundleID: String) -> String { displayName(url: url, bundleID: bundleID) }

    /// Highest score first, and alphabetical where two apps tie.
    private static func bestFirst(_ lhs: (app: Installed, score: Double, count: Int, lastUsed: Date?),
                                  _ rhs: (app: Installed, score: Double, count: Int, lastUsed: Date?)) -> Bool {
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        return lhs.app.name.localizedCaseInsensitiveCompare(rhs.app.name) == .orderedAscending
    }

    // MARK: - The disk

    private func scan(refresh: Bool) -> [Installed] {
        if !refresh {
            let held = lock.withLock { (scanned, scannedAt) }
            if !held.0.isEmpty, Date().timeIntervalSince(held.1) < Self.lifetime { return held.0 }
        }
        let found = Self.installedApps()
        lock.withLock {
            scanned = found
            scannedAt = Date()
        }
        return found
    }

    /// Where a Mac keeps applications, one level in and one level past that.
    ///
    /// The second level is what finds `/Applications/Utilities` and the folder
    /// a vendor installs four apps into; going deeper than that reaches the
    /// helpers bundled *inside* applications, which are not things anybody
    /// docks.
    private static func installedApps() -> [Installed] {
        var roots = FileManager.default.urls(for: .applicationDirectory,
                                             in: [.localDomainMask, .systemDomainMask, .userDomainMask])
        roots.append(URL(fileURLWithPath: "/System/Applications/Utilities"))

        var seen = Set<String>()
        var found: [Installed] = []
        for root in roots {
            for url in contents(of: root) {
                if url.pathExtension == "app" {
                    if let app = describe(url), seen.insert(app.url.standardizedFileURL.path).inserted {
                        found.append(app)
                    }
                } else if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    for inner in contents(of: url) where inner.pathExtension == "app" {
                        if let app = describe(inner), seen.insert(app.url.standardizedFileURL.path).inserted {
                            found.append(app)
                        }
                    }
                }
            }
        }
        return found
    }

    private static func contents(of directory: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: directory,
                                                      includingPropertiesForKeys: [.isDirectoryKey],
                                                      options: [.skipsHiddenFiles])) ?? []
    }

    /// Reads the bundle, and refuses the ones that could never be a target.
    ///
    /// An app target raises a window and pastes into it. A background-only app
    /// has no window to raise, so offering one is offering a button that
    /// silently does nothing — and Nimlet itself is not somewhere to dictate to.
    private static func describe(_ url: URL) -> Installed? {
        guard let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier,
              !bundleID.isEmpty else { return nil }
        guard bundleID != Bundle.main.bundleIdentifier else { return nil }
        let info = bundle.infoDictionary ?? [:]
        let background = (info["LSUIElement"] as? Bool ?? false)
            || (info["LSUIElement"] as? String == "1")
            || (info["LSBackgroundOnly"] as? Bool ?? false)
            || (info["LSBackgroundOnly"] as? String == "1")
        guard !background else { return nil }
        return Installed(url: url, bundleID: bundleID,
                         name: displayName(url: url, bundleID: bundleID, info: info))
    }

    /// What to call it on a tile 62 points wide.
    ///
    /// The curated name wins where there is one: an app is called "Google
    /// Chrome" on disk and "Chrome" by everyone who uses it, and the tile has
    /// room for one of those.
    private static func displayName(url: URL,
                                    bundleID: String,
                                    info: [String: Any]? = nil) -> String {
        if let known = AppRanking.known(bundleID: bundleID) { return known.name }
        let info = info ?? Bundle(url: url)?.infoDictionary ?? [:]
        for key in ["CFBundleDisplayName", "CFBundleName"] {
            if let name = info[key] as? String, !name.isEmpty { return name }
        }
        return url.deletingPathExtension().lastPathComponent
    }

    // MARK: - How much it is used

    /// Spotlight's own counters. `kMDItemUseCount` and `kMDItemLastUsedDate`
    /// are not exported to Swift as constants, hence the strings.
    ///
    /// Both can be missing — a machine whose index was rebuilt has forgotten
    /// every launch that came before it — which `AppRanking` treats as stale
    /// rather than as unused.
    static func usage(of url: URL) -> (count: Int, lastUsed: Date?) {
        guard let item = MDItemCreate(nil, url.path as CFString) else { return (0, nil) }
        let count = MDItemCopyAttribute(item, "kMDItemUseCount" as CFString) as? Int ?? 0
        let lastUsed = MDItemCopyAttribute(item, "kMDItemLastUsedDate" as CFString) as? Date
        return (count, lastUsed)
    }

    private func runningBundleIDs() -> Set<String> {
        let ids = onMain { NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier) }
        return Set(ids.map { $0.lowercased() })
    }

    /// What the user put in their Dock, which is the one ranking signal that is
    /// a statement of intent rather than a count of accidents.
    private func dockedBundleIDs() -> Set<String> {
        guard let defaults = UserDefaults(suiteName: "com.apple.dock"),
              let tiles = defaults.array(forKey: "persistent-apps") as? [[String: Any]]
        else { return [] }
        var ids = Set<String>()
        for tile in tiles {
            guard let data = tile["tile-data"] as? [String: Any] else { continue }
            if let bundleID = data["bundle-identifier"] as? String {
                ids.insert(bundleID.lowercased())
                continue
            }
            // Older Docks store only the path. Reading the bundle for it is a
            // disk hit per tile, but there are a dozen tiles and this runs
            // twice a minute at most.
            if let file = data["file-data"] as? [String: Any],
               let path = file["_CFURLString"] as? String,
               let url = URL(string: path) ?? URL(string: "file://" + path),
               let bundleID = Bundle(url: url)?.bundleIdentifier {
                ids.insert(bundleID.lowercased())
            }
        }
        return ids
    }

    // MARK: - Icons

    /// The app's icon as a 128px PNG, cached forever.
    ///
    /// Rendered from the app on this disk, and never fetched from anywhere.
    /// Third-party icon sets exist — a tested-apps list with a WebP per app was
    /// evaluated for this — and none of them can be right here: their pictures
    /// are the vendors' own trademarked artwork, which whoever collected them
    /// has no standing to relicense, and matching an entry to an installed app
    /// means a fuzzy comparison of display names. There is also nothing to
    /// gain. A target has to be an app that is installed, `NSWorkspace` has an
    /// icon for every one of those, and it is the icon that app is actually
    /// wearing on this Mac rather than the one it shipped with two versions
    /// ago.
    ///
    ///
    /// 128 because the phone draws it at about 30 points and a phone is at 3x;
    /// rendering into an explicit bitmap rather than by locking focus on an
    /// `NSImage`, which takes the screen's scale factor and quietly produced
    /// 256px images six times the size.
    private func icon(for url: URL, bundleID: String) -> Data? {
        let key = bundleID.lowercased()
        if let held = lock.withLock({ icons[key] }) { return held }
        guard let png = Self.render(iconAt: url) else { return nil }
        lock.withLock { icons[key] = png }
        return png
    }

    private static let iconPixels = 128

    private static func render(iconAt url: URL) -> Data? {
        // Drawn on main: an `NSImage` from the shared workspace is AppKit's,
        // and a few dozen 128px draws is a handful of milliseconds — far
        // cheaper than being wrong about which of them are thread-safe.
        onMain {
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                             pixelsWide: iconPixels, pixelsHigh: iconPixels,
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                             isPlanar: false, colorSpaceName: .deviceRGB,
                                             bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
            rep.size = NSSize(width: iconPixels, height: iconPixels)
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            icon.draw(in: NSRect(x: 0, y: 0, width: iconPixels, height: iconPixels),
                      from: .zero, operation: .copy, fraction: 1)
            return rep.representation(using: .png, properties: [:])
        }
    }
}
