import AppKit

/// Application operations are asynchronous; waiting for save prompts never stalls pointer input.
enum AppController {
    private static var busy: Set<String> = [] // main thread only

    static func perform(_ request: AppCommand) async -> AppCommandResult {
        func result(_ phase: AppCommandResult.Phase, _ message: String, targetID: String? = nil) -> AppCommandResult {
            AppCommandResult(requestID: request.id, phase: phase, message: message, targetID: targetID ?? request.targetID)
        }
        guard request.hostSessionID == AppRegistry.shared.safeSnapshot.hostSessionID else {
            return result(.failed, "Your Mac restarted — refresh before trying again")
        }
        if request.action.changesRunningContent && EventInjector.shared.isPaused {
            return result(.failed, "Input is paused on your Mac")
        }
        let acquired = onMainActor { busy.insert(request.app.key).inserted }
        guard acquired else { return result(.failed, "Finish the previous action for this app first") }
        defer { _ = onMainActor { busy.remove(request.app.key) } }

        if request.action == .unkeep {
            guard let id = request.targetID,
                  let target = TargetStore.shared.safeTargets.first(where: { $0.id == id }),
                  target.appReference?.matches(request.app) == true else {
                return result(.failed, "That favorite no longer exists — refresh the list")
            }
            onMainActor { TargetStore.shared.remove(ids: [id]) }
            return result(.succeeded, "Removed from favorites; the app keeps running")
        }

        if request.action == .keep {
            let outcome: TargetStore.AddOutcome = onMainActor {
                if let existing = TargetStore.shared.targets.first(where: { $0.appReference == request.app }) { return .added(existing) }
                if let id = request.targetID, let known = TargetStore.shared.target(id: id),
                   known.appReference?.matches(request.app) == true,
                   let target = TargetStore.shared.promote(id) { return .added(target) }
                guard let url = AppRegistry.installedURL(request.app) else { return .refused("That app is no longer installed") }
                let baseName = AppCatalog.displayNameForApp(url: url, bundleID: request.app.bundleID)
                var name = baseName
                var suffix = 2
                while TargetStore.shared.targets.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                    name = "\(baseName) (\(suffix))"; suffix += 1
                }
                let target = NimletTarget(id: TargetStore.provisionalID(app: request.app.bundleID, path: request.app.applicationPath),
                    name: name, kind: .app, bundleID: request.app.bundleID, applicationPath: request.app.applicationPath,
                    symbol: AppRanking.symbol(bundleID: request.app.bundleID))
                return TargetStore.shared.add(target)
            }
            switch outcome {
            case .added(let target): return result(.succeeded, "Kept \(target.name) in favorites", targetID: target.id)
            case .refused(let message): return result(.failed, message)
            }
        }

        let app: NSRunningApplication
        // The pinned window exists, but its app is not answering Accessibility.
        var unresponsive = false
        if request.action == .activate || request.action == .reopen {
            onMainActor { AppRegistry.shared.refresh() }
            let matches = AppRegistry.shared.safeSnapshot.apps.filter { request.app.matches($0.identity.app) }
            if matches.count > 1 { return result(.failed, "More than one copy is running — choose a copy in All apps") }
            // A deliberate app tap may recover a dead window choice. Text delivery still uses
            // TargetRouter's exact-window check and cannot perform this recovery implicitly.
            let selected = onMainActor {
                request.targetID.flatMap { TargetStore.shared.target(id: $0) }
                    .flatMap { $0.appReference?.matches(request.app) == true ? $0 : nil }
            }
            if request.action == .activate, let selected, let windowID = selected.pinnedWindowID,
               let bundleID = selected.bundleID {
                switch WindowRoster.presence(of: windowID, bundleID: bundleID,
                                             applicationPath: selected.applicationPath, appIdentity: selected.pinnedAppIdentity) {
                case .present: break
                case .unresponsive: unresponsive = true
                case .gone:
                    onMainActor {
                        guard let current = TargetStore.shared.target(id: selected.id),
                              current.pinnedWindowID == windowID,
                              current.pinnedAppIdentity == selected.pinnedAppIdentity else { return }
                        TargetStore.shared.setPinnedWindow(nil, title: nil, for: selected.id)
                    }
                    miceLog.info("apps: released unavailable window \(windowID, privacy: .public) for \(selected.name, privacy: .public)")
                case .unknown:
                    return result(.failed, "Grant Accessibility to Nimlet on your Mac to check \(selected.name)'s window", targetID: selected.id)
                }
            }
            let hasWindowPin = onMainActor {
                selected.flatMap { TargetStore.shared.target(id: $0.id)?.pinnedWindowID } != nil
            }
            let running = AppRegistry.running(request.app)
            // A running app with a window open is only brought forward. Reopening it as well is what
            // turned taps on a tile into extra windows: an app may answer reopen with a new window.
            let hasWindow = running.flatMap { WindowRoster.hasOpenWindow(processID: $0.processIdentifier) } == true
            if request.action == .activate, let running, hasWindowPin || hasWindow {
                app = running
            } else {
                // Opening an app from the Dock sends its reopen event even if its process already exists.
                // Activation alone leaves Calendar and other apps with no window after their last one closes.
                guard let url = AppRegistry.installedURL(request.app) else { return result(.failed, "That app is no longer installed") }
                let opened: Result<NSRunningApplication, Error> = await withCheckedContinuation { continuation in
                    let waiter = AppLaunchWaiter(continuation)
                    DispatchQueue.global().asyncAfter(deadline: .now() + 12) {
                        waiter.complete(.failure(NSError(domain: "NimletLaunch", code: 2,
                            userInfo: [NSLocalizedDescriptionKey: "Launch result unconfirmed. Refresh to check whether the app opened."])))
                    }
                    onMainActor {
                        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { app, error in
                            if let app { waiter.complete(.success(app)) }
                            else { waiter.complete(.failure(error ?? NSError(domain: "Nimlet", code: 1,
                                userInfo: [NSLocalizedDescriptionKey: "The Mac couldn't start that app"]))) }
                        }
                    }
                }
                switch opened {
                case .success(let running): app = running
                case .failure(let error): return result((error as NSError).domain == "NimletLaunch" ? .unconfirmed : .failed, error.localizedDescription)
                }
            }
        } else {
            guard let identity = request.identity, identity.app.matches(request.app),
                  let running = AppRegistry.shared.resolve(identity) else {
                return result(.failed, "That app instance has ended — refresh before trying again")
            }
            app = running
        }

        let ref = AppReference(bundleID: app.bundleIdentifier ?? request.app.bundleID,
                               applicationPath: onMainActor { app.bundleURL?.standardizedFileURL.path })
        let target: NimletTarget = onMainActor {
            AppRegistry.shared.refresh()
            let copies = AppRegistry.shared.safeSnapshot.apps.filter { $0.identity.app.bundleID.caseInsensitiveCompare(ref.bundleID) == .orderedSame }.count
            if let id = request.targetID, let known = TargetStore.shared.target(id: id),
               known.appReference?.matches(ref) == true, (known.applicationPath != nil || copies <= 1) {
                if request.action == .reopen { TargetStore.shared.setPinnedWindow(nil, title: nil, for: known.id) }
                return TargetStore.shared.target(id: known.id) ?? known
            }
            return TargetStore.shared.offerApp(ref, name: app.localizedName ?? request.app.bundleID)
        }

        if request.action == .activate, unresponsive, target.pinnedWindowID != nil {
            // Raising one window is an Accessibility request, and that is what the app is not
            // answering. Bring the app forward and point the mirror at the pinned window — capture
            // asks the window server, not the app. Delivery still checks the window before typing,
            // so nothing is typed while the app cannot confirm where it would land.
            onMainActor {
                if app.isHidden { _ = app.unhide() }
                _ = app.activate(options: [.activateAllWindows])
                TargetStore.shared.setActive(target.id)
            }
            miceLog.info("apps: \(target.name, privacy: .public) is not answering Accessibility; showing its pinned window")
            return result(.needsAttention, "\(target.name) isn't responding on your Mac. Showing its window — typing into it waits until it responds.",
                          targetID: target.id)
        }

        if request.action == .activate || request.action == .reopen {
            // An app tap restores a valid minimized selection; a gone selection was released above.
            // Explicit window actions and text delivery continue to address exactly their chosen window.
            if let windowID = target.pinnedWindowID {
                let restored = WindowRoster.open(windowID: windowID, bundleID: ref.bundleID,
                    name: target.name, applicationPath: ref.applicationPath, appIdentity: target.pinnedAppIdentity)
                if case .refused(let why) = restored { return result(.failed, why, targetID: target.id) }
            }
            // Reopening unhid the app; activating on its own does not.
            onMainActor { if app.isHidden { _ = app.unhide() } }
            let outcome = TargetRouter.focus(target, movingPointer: true)
            guard outcome.ok else { return result(.failed, outcome.message, targetID: target.id) }
            var activated = false
            for _ in 0..<40 {
                activated = onMainActor { NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier }
                if activated { break }
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard activated else { return result(.needsAttention, "The app is running but did not come forward — try again", targetID: target.id) }
            onMainActor { TargetStore.shared.setActive(target.id); AppRegistry.shared.refresh() }
            var roster = await WindowRoster.windows(ofBundleID: ref.bundleID, pinned: target.pinnedWindowID,
                                                    withPreviews: false, applicationPath: ref.applicationPath)
            // Workspace completion confirms the process, while its first window may still be opening.
            let windowDeadline = Date().addingTimeInterval(3)
            while target.pinnedWindowID == nil, roster.windows.isEmpty, !app.isTerminated,
                  Date() < windowDeadline {
                try? await Task.sleep(for: .milliseconds(150))
                roster = await WindowRoster.windows(ofBundleID: ref.bundleID, pinned: nil,
                                                    withPreviews: false, applicationPath: ref.applicationPath)
            }
            return result(.succeeded, roster.windows.isEmpty ? "\(target.name) is running; no windows are open" : "Opened \(target.name)", targetID: target.id)
        }

        guard let identity = request.identity else { return result(.failed, "Refresh this app's state first") }
        if request.action == .quit {
            onMainActor {
                // Quit addresses the whole app; follow its front window so any save dialog is controllable.
                TargetStore.shared.setPinnedWindow(nil, title: nil, for: target.id)
                _ = app.activate(options: [.activateAllWindows])
                TargetStore.shared.setActive(target.id)
            }
            guard onMainActor({ app.terminate() }) else {
                return result(.needsAttention, "Quit needs attention. Check the app's save dialog, then refresh its state.", targetID: target.id)
            }
            for _ in 0..<60 {
                if app.isTerminated {
                    onMainActor { AppRegistry.shared.refresh(); TargetStore.shared.refreshProvisional() }
                    return result(.succeeded, "Quit \(target.name)", targetID: target.id)
                }
                try? await Task.sleep(for: .milliseconds(150))
            }
            return result(.needsAttention, "Quit was not confirmed. Check the save dialog, then refresh the app's state.", targetID: target.id)
        }

        guard let windowID = request.windowID else { return result(.failed, "Choose a window first") }
        let raised: WindowRoster.Raise = request.action == .restoreWindow
            ? WindowRoster.open(windowID: windowID, bundleID: ref.bundleID, name: target.name, applicationPath: ref.applicationPath, appIdentity: identity)
            : WindowRoster.raise(windowID: windowID, bundleID: ref.bundleID, name: target.name,
                                 movingPointer: true, applicationPath: ref.applicationPath, appIdentity: identity)
        guard case .raised(let title) = raised else {
            if case .refused(let why) = raised { return result(.failed, why) }
            return result(.failed, "Couldn't select that window")
        }
        onMainActor {
            TargetStore.shared.setPinnedWindow(windowID, title: title, for: target.id)
            TargetStore.shared.setActive(target.id)
        }
        if request.action != .closeWindow {
            return result(.succeeded, "Showing \(title.isEmpty ? target.name : title)", targetID: target.id)
        }
        switch WindowRoster.requestClose(windowID: windowID, identity: identity) {
        case .refused(let why): return result(.failed, why, targetID: target.id)
        case .raised:
            let deadline = Date().addingTimeInterval(6)
            while Date() < deadline {
                if WindowRoster.contains(windowID: windowID, identity: identity) == false {
                    onMainActor {
                        if TargetStore.shared.target(id: target.id)?.pinnedWindowID == windowID {
                            TargetStore.shared.setPinnedWindow(nil, title: nil, for: target.id)
                        }
                    }
                    return result(.succeeded, "Closed \(title.isEmpty ? "window" : title)", targetID: target.id)
                }
                try? await Task.sleep(for: .milliseconds(150))
            }
            return result(.needsAttention, "Close was not confirmed. Check the save dialog, then refresh the windows. Cancel keeps the window open.", targetID: target.id)
        }
    }
}

/// Both the Workspace callback and deadline can finish; exactly one resumes the request.
private final class AppLaunchWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Result<NSRunningApplication, Error>, Never>?
    init(_ continuation: CheckedContinuation<Result<NSRunningApplication, Error>, Never>) { self.continuation = continuation }
    func complete(_ result: Result<NSRunningApplication, Error>) {
        let held = lock.withLock { let held = continuation; continuation = nil; return held }
        held?.resume(returning: result)
    }
}
