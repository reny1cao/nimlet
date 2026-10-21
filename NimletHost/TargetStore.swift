import AppKit
import Combine

/// Persists the user's target list. Seeded with sensible guesses on first run so
/// the phone has something to show before anyone opens Settings.
final class TargetStore: ObservableObject {
    static let shared = TargetStore()

    private let defaultsKey = "mice.targets.v1"
    private let activeKey = "mice.activeTarget.v1"

    /// And enough apps to cover an agent, the terminal it runs in and the
    /// editor beside it, with room for the browser. The picker on the phone is
    /// where the rest are chosen, one tap each.
    private static let seededAppLimit = 5

    @Published private(set) var targets: [NimletTarget] = []
    @Published var activeTargetID: String?
    /// tmux targets whose pane could not be found. Kept rather than deleted:
    /// the pane is usually one `tmux new-session` away, and quietly removing a
    /// target the user configured is worse than showing a broken one.
    @Published private(set) var unresolvedTargetIDs: Set<String> = []

    /// A copy of the published state that any queue may read.
    ///
    /// `targets` and `activeTargetID` are `@Published`, so they are written on
    /// main — but `HostServer` reads them on its network queue for every
    /// inbound message, which is a data race against a Settings edit or the
    /// tmux reconcile. Readers off main take the snapshot instead.
    private let snapshotLock = NSLock()
    private var targetsSnapshot: [NimletTarget] = []
    private var unresolvedSnapshot: Set<String> = []
    private var activeSnapshot: String?
    private var provisionalSnapshot: [NimletTarget] = []

    /// Anything tmux is a subprocess, and a subprocess has no business on the
    /// launch path where it would delay the first click on the menu bar icon.
    private let tmuxQueue = DispatchQueue(label: "com.renyicao.mice.host.tmux", qos: .utility)
    private let provisionalRefreshLock = NSLock()
    private var provisionalRefreshPending = false
    private var provisionalPanes: [Tmux.Pane] = []

    private init() {
        let saved = UserDefaults.standard.data(forKey: defaultsKey)
        if let saved {
            do {
                targets = try NimletCoder.decode([NimletTarget].self, from: saved)
            } catch {
                // Reseeding on a decode failure deletes every target the user
                // configured, and doing that silently is how a person loses
                // their setup without ever learning why.
                let backup = TargetStore.backUp(saved)
                miceLog.error("""
                    saved targets did not decode (\(error.localizedDescription, privacy: .public)); \
                    raw JSON copied to \(backup?.path ?? "nowhere", privacy: .public) before reseeding
                    """)
            }
        }

        let isFirstRun = targets.isEmpty
        activeTargetID = UserDefaults.standard.string(forKey: activeKey) ?? targets.first?.id
        persist()

        // Only apps are seeded. Panes used to be too, a target per live pane
        // with the first one made active, which left a first run pointing at
        // whatever happened to be open in tmux that minute — a stray `cat`, a
        // QA session — under a name the user never chose, and broken the day
        // that pane closed. The panes are still offered: the provisional half
        // of the dock lists every live one, and explicit Keep saves one as a favorite.
        //
        // Seeding the apps is a metadata lookup per candidate, and asking tmux
        // is a subprocess. Neither belongs on the launch path, where they would
        // delay the first click on the menu bar icon — so the first run's whole
        // list is built here and applied in one hop.
        tmuxQueue.async { [weak self] in
            let apps = isFirstRun ? AppCatalog.seeds(limit: TargetStore.seededAppLimit) : []
            let tmux = Tmux.isAvailable
            let panes = tmux ? Tmux.listPanes() : []
            DispatchQueue.main.async {
                self?.seed(apps: apps)
                guard tmux else { return }
                self?.reconcile(panes: panes)
            }
        }
    }

    /// The apps a first run opens pointing at, plus the one target that needs
    /// nothing installed at all.
    ///
    /// Only the apps that are installed, so nobody opens Nimlet to a row of
    /// buttons that cannot work, and only the few that are actually used: the
    /// previous version seeded every match in the table, which on a machine
    /// with four terminals on it meant eleven tiles before the user had chosen
    /// a single one.
    private func seed(apps: [NimletTarget]) {
        guard targets.isEmpty else { return }
        targets = apps
        targets.append(NimletTarget(name: "Focused", kind: .frontmost,
                                  submitOnSend: false, symbol: "cursorarrow.rays"))
        if activeTargetID == nil { setActive(targets.first?.id) }
        persist()
    }

    /// Migrates positional tmux targets to stable ids and flags the ones whose
    /// pane is gone.
    private func reconcile(panes: [Tmux.Pane]) {
        var idsBySpec: [String: String] = [:]
        for pane in panes { idsBySpec[pane.spec] = pane.id }
        let live = Set(panes.map(\.id))

        var unresolved: Set<String> = []
        for index in targets.indices where targets[index].kind == .tmux {
            guard let spec = targets[index].tmuxTarget, !spec.isEmpty else {
                unresolved.insert(targets[index].id)
                continue
            }
            if targets[index].hasStableTmuxID {
                if !live.contains(spec) { unresolved.insert(targets[index].id) }
            } else if let resolved = idsBySpec[spec] {
                targets[index].tmuxTarget = resolved
            } else {
                unresolved.insert(targets[index].id)
            }
        }
        unresolvedTargetIDs = unresolved
        persist()
    }

    /// A pane running one of these is sitting at a prompt, so text may be typed
    /// into it but Return must never be pressed for it: submitting there runs
    /// whatever was dictated as a shell command.
    static func isShellPrompt(_ command: String) -> Bool {
        ShortcutProfiles.guess(forCommand: command).id == ShortcutProfiles.shell.id
    }

    private static func shortLabel(_ pane: Tmux.Pane) -> String {
        let session = pane.spec.split(separator: ":").first.map(String.init) ?? pane.spec
        return "\(pane.command) (\(session))"
    }

    /// A glyph per kind of pane, rather than one glyph for every pane there is.
    ///
    /// Every pane target used to be `terminal`. A tmux target carries no bundle
    /// id, so it has no artwork to fall back on — which meant a first run on a
    /// machine with a dozen panes produced a dozen identical grey squares, and
    /// the dock draws no name under a tile. They were not merely hard to tell
    /// apart; they were not distinguishable at all.
    ///
    /// The profile table already answers "what is running in this pane" for the
    /// shortcut strip. Asked once more here, it answers "what should this look
    /// like" for free, and the two can never disagree about what a pane is.
    static func paneSymbol(for command: String) -> String {
        switch ShortcutProfiles.guess(forCommand: command).id {
        case ShortcutProfiles.claudeCode.id: return "sparkle"
        case ShortcutProfiles.codex.id: return "chevron.left.forwardslash.chevron.right"
        default: return "terminal"
        }
    }

    // MARK: - What is running but not in the dock

    /// The macOS Dock's temporary section, for this dock.
    ///
    /// The Dock keeps two lists in one strip: the apps you put there, and —
    /// past a divider — the ones that merely happen to be running. That second
    /// list is what makes the first safe to curate, because it guarantees the
    /// Dock is never *wrong* about what is reachable. Whatever you did not think
    /// to add is still one click away.
    ///
    /// This store had only the curated half. It was seeded once on a first run,
    /// behind a `seededPanes.v1` flag, and `reconcile` never adds anything —
    /// so a tmux session started five minutes after that first launch was
    /// invisible until somebody opened Settings and built a target for it by
    /// hand. The list diverged from reality monotonically, and it did it
    /// silently: there is no empty slot to notice.
    ///
    /// Recomputed, never persisted. Only an explicit Keep action promotes a target.
    @Published private(set) var provisionalTargets: [NimletTarget] = []

    /// Enough to find the pane you meant: a phone is not the place to
    /// enumerate forty shells.
    private static let provisionalPaneLimit = 12
    /// All running GUI apps are reachable; the phone handles overflow.
    private static let provisionalAppLimit = Int.max

    /// A pane's provisional id, and an app's. Deterministic, so that promoting
    /// one keeps every reference to it — `activeTargetID` most of all — valid
    /// across the moment it stops being provisional.
    static func provisionalID(pane id: String) -> String { "pane:\(id)" }
    static func provisionalID(app bundleID: String, path: String? = nil) -> String {
        "app:" + AppReference(bundleID: bundleID, applicationPath: path).key
    }

    /// Re-reads what is live and rebuilds the provisional half of the dock.
    ///
    /// Pane scans are bounded to one outstanding request. App state comes from
    /// workspace notifications; reading it must not start another registry scan.
    func refreshProvisional() {
        let admitted = provisionalRefreshLock.withLock {
            guard !provisionalRefreshPending else { return false }
            provisionalRefreshPending = true
            return true
        }
        guard admitted else { return }
        tmuxQueue.async { [weak self] in
            let panes = Tmux.isAvailable ? Tmux.listPanes() : []
            DispatchQueue.main.async {
                guard let self else { return }
                self.provisionalRefreshLock.withLock { self.provisionalRefreshPending = false }
                self.provisionalPanes = panes
                self.applyProvisional(panes: panes, apps: AppRegistry.shared.safeSnapshot.apps)
            }
        }
    }

    /// An app activation changes no tmux panes and needs no subprocess.
    @MainActor
    func refreshProvisionalApps(_ snapshot: AppRuntimeSnapshot) {
        applyProvisional(panes: provisionalPanes, apps: snapshot.apps)
    }

    @MainActor
    private func applyProvisional(panes: [Tmux.Pane], apps: [RunningMacApp]) {
        let claimedPanes = Set(targets.compactMap { $0.kind == .tmux ? $0.tmuxTarget : nil })
        let claimedApps = targets.compactMap(\.appReference)

        let freePanes = panes.filter { !claimedPanes.contains($0.id) }
        // A pane running an agent is what you were looking for, and a bare
        // shell is what you were not.
        let orderedPanes = freePanes.filter { !TargetStore.isShellPrompt($0.command) }
            + freePanes.filter { TargetStore.isShellPrompt($0.command) }

        var offered: [NimletTarget] = orderedPanes.prefix(TargetStore.provisionalPaneLimit).map { pane in
            let isShell = TargetStore.isShellPrompt(pane.command)
            return NimletTarget(id: TargetStore.provisionalID(pane: pane.id),
                              name: TargetStore.shortLabel(pane),
                              kind: .tmux,
                              tmuxTarget: pane.id,
                              submitOnSend: !isShell,
                              allowAutoSubmit: !isShell,
                              symbol: TargetStore.paneSymbol(for: pane.command),
                              isProvisional: true)
        }

        // What Nimlet is for, first. The curated table is the same ranking
        // signal seeding uses: an editor or a browser is a plausible delivery
        // address, and Preview is running on every Mac in the world.
        let freeApps = apps.filter { app in !claimedApps.contains { ref in
            guard ref.matches(app.identity.app) else { return false }
            // A legacy bundle-only favorite cannot claim both installed copies.
            return ref.applicationPath != nil || apps.filter {
                $0.identity.app.bundleID.caseInsensitiveCompare(ref.bundleID) == .orderedSame
            }.count == 1
        } }
        offered += (freeApps.filter { AppRanking.known(bundleID: $0.identity.app.bundleID) != nil }
                    + freeApps.filter { AppRanking.known(bundleID: $0.identity.app.bundleID) == nil })
            .prefix(TargetStore.provisionalAppLimit)
            .map { app in
                let known = AppRanking.known(bundleID: app.identity.app.bundleID)
                let previous = provisionalTargets.first { old in
                    old.appReference?.matches(app.identity.app) == true
                        && (old.applicationPath == app.identity.app.applicationPath
                            || apps.filter { $0.identity.app.bundleID == app.identity.app.bundleID }.count == 1)
                }
                var target = NimletTarget(id: previous?.id ?? TargetStore.provisionalID(app: app.identity.app.bundleID, path: app.identity.app.applicationPath),
                                        name: previous?.name ?? known?.name ?? app.name,
                                        kind: .app,
                                        bundleID: app.identity.app.bundleID,
                                        applicationPath: app.identity.app.applicationPath,
                                        symbol: known?.symbol ?? "macwindow",
                                        isProvisional: true)
                target.applyDefaultSubmitPolicy()
                return target
            }

        for index in offered.indices {
            if let old = provisionalTargets.first(where: { $0.id == offered[index].id }) {
                offered[index].pinnedWindowID = old.pinnedWindowID
                offered[index].pinnedWindowTitle = old.pinnedWindowTitle
                offered[index].pinnedAppIdentity = old.pinnedAppIdentity
            }
        }
        guard offered != provisionalTargets else { return }
        provisionalTargets = offered
        snapshotLock.withLock { provisionalSnapshot = offered }
    }

    /// Explicitly keeps a provisional target, retaining its id and window choice.
    @MainActor
    @discardableResult
    func promote(_ id: String) -> NimletTarget? {
        if let existing = targets.first(where: { $0.id == id }) { return existing }
        guard var offered = provisionalTargets.first(where: { $0.id == id }) else { return nil }
        offered.isProvisional = false
        targets.append(offered)
        provisionalTargets.removeAll { $0.id == id }
        snapshotLock.withLock { provisionalSnapshot = provisionalTargets }
        persist()
        return offered
    }

    /// Re-reads the live panes. Cheap enough to do whenever Settings is opened,
    /// and it is the only way a target fixes itself after a session restarts.
    func refreshTmux() {
        tmuxQueue.async { [weak self] in
            guard Tmux.isAvailable else { return }
            let panes = Tmux.listPanes()
            DispatchQueue.main.async { self?.reconcile(panes: panes) }
        }
    }

    /// For callers that have just listed the panes themselves. Asking the store
    /// to refresh made it shell out for the same answer a second time.
    @MainActor
    func refreshTmux(with panes: [Tmux.Pane]) {
        reconcile(panes: panes)
    }

    func target(id: String?) -> NimletTarget? {
        guard let id else { return nil }
        return (targets + provisionalTargets).first { $0.id == id }
    }

    var activeTarget: NimletTarget? { target(id: activeTargetID) }

    func isUnresolved(_ id: String) -> Bool { unresolvedTargetIDs.contains(id) }

    func setActive(_ id: String?) {
        activeTargetID = id
        snapshotLock.withLock { activeSnapshot = id }
        UserDefaults.standard.set(id, forKey: activeKey)
    }

    enum AddOutcome {
        case added(NimletTarget)
        case refused(String)
    }

    /// Adds a target on behalf of a client, validating what the client asked
    /// for. A client may be a script, so the store rather than the caller
    /// decides what is a legal target.
    ///
    /// Runs on main because it publishes, so a tmux pane must already have been
    /// resolved to its stable id by the caller — listing panes is a subprocess
    /// and has no business on the main thread.
    @MainActor
    func add(_ requested: NimletTarget) -> AddOutcome {
        var target = requested
        if targets.contains(where: { $0.id == target.id }) { return .refused("That favorite already exists") }
        target.name = target.name.trimmingCharacters(in: .whitespacesAndNewlines)
        // The phone's picker sends the default policy for every app it adds;
        // the store knows which apps the default is dangerous for. Editing it
        // back on afterwards is the user's call and goes through `update`.
        target.applyDefaultSubmitPolicy()
        if let refusal = validate(target) { return .refused(refusal) }
        target.isProvisional = false
        provisionalTargets.removeAll { $0.id == target.id }
        snapshotLock.withLock { provisionalSnapshot = provisionalTargets }
        targets.append(target)
        unresolvedTargetIDs.remove(target.id)
        persist()
        return .added(target)
    }

    /// Changes one that already exists, under the same rules it was created
    /// under.
    ///
    /// This used to be `upsert` called straight from the server after two of
    /// the eight checks below were re-implemented at the call site — so an edit
    /// could put a target into a state it could never have been added in: a
    /// pane id that resolves to nothing, a second target on a pane that already
    /// has one, a name that already belongs to another.
    @MainActor
    func update(_ requested: NimletTarget) -> AddOutcome {
        var target = requested
        target.name = target.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let existing = self.target(id: target.id) else {
            return .refused("That target no longer exists")
        }
        // Whatever has focus, with Return pressed, is the one target a remote
        // caller could aim at anything at all — so a client may not turn an
        // existing target into one, and may not edit one into something else.
        guard target.kind == existing.kind else {
            return .refused("Change the kind on the Mac")
        }
        if let refusal = validate(target, excluding: target.id) { return .refused(refusal) }
        upsert(target)
        return .added(target)
    }

    /// The rules a target has to satisfy, wherever it came from.
    ///
    /// `excluding` is the target being edited, which must not be compared
    /// against itself for the duplicate name and duplicate pane checks.
    @MainActor
    private func validate(_ target: NimletTarget, excluding id: String? = nil) -> String? {
        guard !target.name.isEmpty else { return "A target needs a name" }
        let others = targets.filter { $0.id != id }

        switch target.kind {
        case .tmux:
            guard let pane = target.tmuxTarget, !pane.isEmpty else {
                return "A tmux target needs a pane"
            }
            // Only the stable id is ever stored: a positional spec names a slot
            // whose contents change as soon as a pane closes.
            guard target.hasStableTmuxID else {
                return "No tmux pane matches \(pane)"
            }
            if let existing = others.first(where: { $0.kind == .tmux && $0.tmuxTarget == pane }) {
                return "\(existing.name) already points at \(pane)"
            }
        case .app:
            guard let bundleID = target.bundleID, !bundleID.isEmpty else {
                return "An app target needs a bundle identifier"
            }
            guard AppRegistry.installedURL(target.appReference!) != nil else {
                return "\(bundleID) is not installed"
            }
        case .frontmost:
            // The user can still make one in Settings; a client may not make
            // one for them.
            if id == nil { return "A frontmost target has to be added on the Mac" }
        }

        if others.contains(where: { $0.name.caseInsensitiveCompare(target.name) == .orderedSame }) {
            return "There is already a target called \(target.name)"
        }
        return nil
    }

    /// Points a target at one window of its app, or lets it go back to
    /// following whichever window that app puts in front.
    ///
    /// Stored on the target rather than kept beside it, so the pin survives the
    /// app being quit, the phone disconnecting and Nimlet being relaunched — and
    /// so everything that reads a target (delivery, focus, the mirror) sees it
    /// without having to know this feature exists.
    @MainActor
    func setPinnedWindow(_ windowID: UInt32?, title: String?, for targetID: String) {
        let identity = windowID == nil ? nil : target(id: targetID)?.appReference.flatMap { AppRegistry.shared.identity(for: $0) }
        if let index = targets.firstIndex(where: { $0.id == targetID }) {
            targets[index].pinnedWindowID = windowID
            targets[index].pinnedWindowTitle = windowID == nil ? nil : title
            targets[index].pinnedAppIdentity = identity
            persist()
        } else if let index = provisionalTargets.firstIndex(where: { $0.id == targetID }) {
            provisionalTargets[index].pinnedWindowID = windowID
            provisionalTargets[index].pinnedWindowTitle = windowID == nil ? nil : title
            provisionalTargets[index].pinnedAppIdentity = identity
            snapshotLock.withLock { provisionalSnapshot = provisionalTargets }
        }
    }

    /// Supply a control target for an app, including a cold launch, without adding a favorite.
    @MainActor
    func offerApp(_ ref: AppReference, name: String) -> NimletTarget {
        let ambiguous = AppRegistry.shared.safeSnapshot.apps.filter { $0.identity.app.bundleID.lowercased() == ref.bundleID.lowercased() }.count > 1
        if let existing = targets.first(where: {
            $0.appReference?.matches(ref) == true && (!ambiguous || $0.applicationPath == ref.applicationPath)
        }) { return existing }
        let id = Self.provisionalID(app: ref.bundleID, path: ref.applicationPath)
        if let existing = provisionalTargets.first(where: { $0.id == id }) { return existing }
        var target = NimletTarget(id: id, name: name, kind: .app, bundleID: ref.bundleID,
                               applicationPath: ref.applicationPath,
                               symbol: AppRanking.symbol(bundleID: ref.bundleID), isProvisional: true)
        target.applyDefaultSubmitPolicy()
        provisionalTargets.append(target)
        snapshotLock.withLock { provisionalSnapshot = provisionalTargets }
        return target
    }

    func upsert(_ target: NimletTarget) {
        if let index = targets.firstIndex(where: { $0.id == target.id }) {
            targets[index] = target
        } else {
            targets.append(target)
        }
        unresolvedTargetIDs.remove(target.id)
        persist()
    }

    func remove(ids: Set<String>) {
        let removed = targets.filter { ids.contains($0.id) }
        for var old in removed where old.kind == .app {
            guard let ref = old.appReference, AppRegistry.shared.identity(for: ref) != nil else { continue }
            old.isProvisional = true
            provisionalTargets.removeAll { $0.id == old.id }
            provisionalTargets.append(old)
        }
        targets.removeAll { ids.contains($0.id) }
        snapshotLock.withLock { provisionalSnapshot = provisionalTargets }
        unresolvedTargetIDs.subtract(ids)
        if let active = activeTargetID, ids.contains(active), !provisionalTargets.contains(where: { $0.id == active }) {
            setActive(targets.first?.id)
        }
        persist()
    }

    /// Applies an order sent by a phone.
    ///
    /// Anything the phone did not mention keeps its place at the end rather
    /// than being dropped: the two lists can disagree — a target added on the
    /// Mac a moment ago is not in the order the phone dragged — and losing a
    /// target to a race is much worse than it appearing in the wrong place.
    func setOrder(_ ids: [String]) {
        var byID: [String: NimletTarget] = [:]
        for target in targets { byID[target.id] = target }
        var reordered = ids.compactMap { byID[$0] }
        let placed = Set(reordered.map(\.id))
        reordered.append(contentsOf: targets.filter { !placed.contains($0.id) })
        guard reordered.count == targets.count else { return }
        targets = reordered
        persist()
    }

    func move(from offsets: IndexSet, to destination: Int) {
        targets.move(fromOffsets: offsets, toOffset: destination)
        persist()
    }

    private func persist() {
        snapshotLock.withLock {
            targetsSnapshot = targets
            activeSnapshot = activeTargetID
            unresolvedSnapshot = unresolvedTargetIDs
        }
        guard let data = try? NimletCoder.line(targets) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    /// The reads `HostServer` makes from its network queue.
    var safeTargets: [NimletTarget] { snapshotLock.withLock { targetsSnapshot } }

    var safeActiveTargetID: String? { snapshotLock.withLock { activeSnapshot } }

    var safeUnresolvedTargetIDs: Set<String> { snapshotLock.withLock { unresolvedSnapshot } }

    var safeProvisionalTargets: [NimletTarget] { snapshotLock.withLock { provisionalSnapshot } }

    /// What the phone is shown: the dock's curated half and its live half, in
    /// that order. The divider between them is the phone's business.
    var safeDockTargets: [NimletTarget] {
        snapshotLock.withLock { targetsSnapshot + provisionalSnapshot }
    }

    /// Pure lookup: reading or controlling a provisional target does not keep it.
    func safeTarget(id: String?) -> NimletTarget? {
        guard let id else { return nil }
        return snapshotLock.withLock { (targetsSnapshot + provisionalSnapshot).first { $0.id == id } }
    }

    var safeActiveTarget: NimletTarget? {
        snapshotLock.withLock {
            guard let activeSnapshot else { return nil }
            return (targetsSnapshot + provisionalSnapshot).first { $0.id == activeSnapshot }
        }
    }

    /// Keeps a dated copy of JSON we could not read, next to the delivery log.
    private static func backUp(_ data: Data) -> URL? {
        guard let directory = DeliveryLog.fileURL?.deletingLastPathComponent() else { return nil }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = directory.appendingPathComponent("targets-\(stamp).json")
        // Owner-only, like the delivery log beside it: this is the target list
        // — names, bundle ids, pane ids, pinned window titles — and the fact
        // that it could not be parsed does not make it less descriptive.
        guard FileManager.default.createFile(atPath: url.path, contents: data,
                                             attributes: [.posixPermissions: 0o600]) else { return nil }
        return url
    }
}
