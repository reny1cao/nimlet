import AppKit
import ApplicationServices
import ScreenCaptureKit

/// The windows an application has open, and how to raise exactly one of them.
///
/// Two frameworks, because neither answers the whole question. ScreenCaptureKit
/// knows what the window server is drawing — ids, titles, sizes, and it is the
/// only thing that can photograph a window. The Accessibility API knows what the
/// *app* thinks it has — which window is minimised, and it is the only way to
/// bring one forward. This joins them on the window id.
///
/// What this is not: a list of an app's documents. Claude's conversations and a
/// browser's tabs are not windows, Nimlet cannot see them, and offering a list
/// that looked like them would be promising something it cannot keep. Every
/// entry here is a window you could click on the Mac.
enum WindowRoster {

    /// Enough to find the window you meant, and a hard stop for an app that
    /// keeps forty. Previews are screenshots, and they are what this costs.
    static let limit = 12

    /// Windows smaller than this are palettes, tool strips and the little
    /// floating things apps hang off their real windows. Same threshold the
    /// mirror and the screenshot path already use, so the three cannot disagree
    /// about what counts as a window.
    private static let minimumSide: CGFloat = 120

    struct Roster {
        var windows: [MacWindow]
        /// Why it is empty or thin, when there is a reason worth reading.
        var note: String?
        var appIdentity: AppInstanceIdentity? = nil
    }

    // MARK: - Listing

    static func windows(ofBundleID bundleID: String,
                        pinned: UInt32?,
                        withPreviews: Bool = true,
                        applicationPath: String? = nil) async -> Roster {
        let running = onMain {
            AppRegistry.running(AppReference(bundleID: bundleID, applicationPath: applicationPath))
        }
        guard let running else {
            return Roster(windows: [], note: "isn't running, so it has no windows open yet.")
        }
        let identity = AppRegistry.shared.identity(for: AppReference(bundleID: bundleID, applicationPath: applicationPath))
        let pid = running.processIdentifier
        let appName = onMain { running.localizedName } ?? bundleID

        // Accessibility first, and on its own terms. It is what knows the
        // titles, which window is minimised, and which ones can be brought
        // forward — and Nimlet already holds that grant, because it is the same
        // one it injects keystrokes with. Building the list out of
        // ScreenCaptureKit instead meant a Mac without Screen Recording had no
        // window list at all, when what it actually lacks is the pictures.
        let answered = answeredWindows(pid: pid)
        let axWindows = answered ?? []
        let content = ScreenAccess.isGranted ? await shareableContent() : nil
        // Which window is in front is the window server's answer, the same
        // one the mirror follows, so the card marked as showing is the window
        // that is. `AXMain` is only the fallback: an app that is not frontmost
        // may publish no main window at all.
        let stacking = stackingOrder(processID: pid)
        let stacked = axWindows.compactMap { ax -> WindowOrdering.Candidate? in
            guard !ax.isMinimized, let id = ax.windowID, stacking.contains(id) else { return nil }
            let size = ax.size ?? .zero
            return WindowOrdering.Candidate(id: id, isOnScreen: true, area: Double(size.width * size.height))
        }
        let front = WindowOrdering.front(of: stacked, stacking: stacking)
        // Every window the window server has for this app, whatever its size.
        //
        // Kept unfiltered on purpose: it is what says how big an Accessibility
        // window is, and the size is what decides whether the window belongs in
        // the shelf at all. Filtering first meant a small window found no match
        // here, so the guard below had nothing to measure and let it through —
        // which is how two 8-point transient windows called "Window" ended up
        // on the shelf with thumbnails, since the preview pass looks in the
        // unfiltered list.
        let allWindows = (content?.windows ?? []).filter { window in
            window.owningApplication?.processID == pid && window.windowLayer == 0
        }
        var capturedByID: [UInt32: SCWindow] = [:]
        for window in allWindows { capturedByID[window.windowID] = window }
        let captured = allWindows.filter {
            $0.frame.width > minimumSide && $0.frame.height > minimumSide
        }

        var windows: [MacWindow] = []
        var seen = Set<UInt32>()
        for ax in axWindows {
            // A window the Accessibility API will not put an id to cannot be
            // pinned to safely — that is the whole identity of the thing — so
            // it is picked up from the window server's side below instead, and
            // marked as one that cannot be raised.
            guard let id = ax.windowID, seen.insert(id).inserted else { continue }
            let capture = capturedByID[id]
            // The window server's frame where there is one, and the app's own
            // answer where there is not — a Mac without Screen Recording still
            // has to keep palettes and transient overlays off the shelf.
            let size = capture?.frame.size ?? ax.size
            if let size, size.width <= minimumSide || size.height <= minimumSide { continue }
            windows.append(MacWindow(id: id,
                                     title: ax.title,
                                     appName: appName,
                                     isMinimized: ax.isMinimized,
                                     isOnScreen: !ax.isMinimized && (capture?.isOnScreen ?? true),
                                     isFrontmost: !ax.isMinimized && (front.map { $0 == id } ?? ax.isMain),
                                     isPinned: pinned == id,
                                     width: Int(capture?.frame.width ?? 0),
                                     height: Int(capture?.frame.height ?? 0),
                                     canRaise: true,
                                     canClose: closeButton(of: ax.element) != nil))
        }
        // Anything the window server has that Accessibility did not account
        // for. Finder's desktop window is the usual one. Listed, because it is
        // a window and it can be mirrored; not raisable, and it says so.
        //
        // On screen only, and that qualifier is the whole point of the shelf:
        // every entry here is meant to be a window you could click on the Mac.
        // A window the server holds, Accessibility cannot name, and nobody can
        // see is none of those things — it cannot be raised, it cannot be
        // photographed (the preview pass skips anything off screen), and it
        // usually has no title either, so it arrived on the shelf as the app's
        // own name over an empty rectangle with a warning badge. Chrome keeps
        // one permanently. That card could not be chosen, explained or
        // dismissed; it could only be wondered about.
        for window in captured where !seen.contains(window.windowID) && window.isOnScreen {
            seen.insert(window.windowID)
            windows.append(MacWindow(id: window.windowID,
                                     title: window.title ?? "",
                                     appName: appName,
                                     isMinimized: false,
                                     isOnScreen: window.isOnScreen,
                                     isFrontmost: false,
                                     isPinned: pinned == window.windowID,
                                     width: Int(window.frame.width),
                                     height: Int(window.frame.height),
                                     canRaise: false))
        }

        // Opened order, so a card stays where it was after the window it
        // stands for is brought forward. See `WindowOrdering`.
        windows = WindowOrdering.shelf(windows)

        var note: String?
        if answered == nil {
            note = "isn't responding right now, so its windows can be shown but not brought forward."
        } else if windows.isEmpty {
            note = AXIsProcessTrusted()
                ? "is running but has no windows open."
                : "Grant Nimlet Accessibility on your Mac to see and pick its windows."
        } else if content == nil {
            // Worth saying once: the cards are titles rather than pictures, and
            // that is a switch the user can throw.
            note = "Grant Nimlet Screen Recording to see a picture of each window."
        } else if windows.contains(where: { $0.isMinimized }) {
            note = "A dimmed card is minimised. Tap it and Nimlet will bring it back."
        } else if windows.contains(where: { !$0.canRaise }) {
            note = "A dimmed card is one Nimlet can mirror but can't bring forward."
        }

        guard withPreviews, let content else { return Roster(windows: windows, note: note, appIdentity: identity) }

        // The pictures are the expensive part, so an app with more windows
        // than the limit gets them for the one being shown and the one in
        // front first — not for whichever happened to be opened earliest.
        let pictured = windows.filter { $0.isPinned || $0.isFrontmost }
            + windows.filter { !$0.isPinned && !$0.isFrontmost }
        let previews = await self.previews(for: Array(pictured.prefix(limit)), in: content)
        for index in windows.indices {
            windows[index].preview = previews[windows[index].id]
        }
        return Roster(windows: windows, note: note, appIdentity: identity)
    }

    /// How long ScreenCaptureKit gets to answer before the shelf goes ahead
    /// without it.
    ///
    /// It normally answers in milliseconds, and there is no documented bound on
    /// what it does when the capture service is wedged or the grant is being
    /// renegotiated. A phone left on a spinner is a worse outcome than a shelf
    /// of titles without pictures — and by this point the titles are already in
    /// hand, because they came from Accessibility.
    private static let captureTimeout = Duration.seconds(2)

    private static func shareableContent() async -> SCShareableContent? {
        await withTimeout(captureTimeout) {
            try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        } ?? nil
    }

    /// Runs `work`, or gives up on it. The abandoned task is left to finish on
    /// its own: there is nothing to cancel inside ScreenCaptureKit, and the
    /// result is simply dropped.
    private static func withTimeout<T: Sendable>(_ limit: Duration,
                                                 _ work: @escaping @Sendable () async -> T) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await work() }
            group.addTask {
                try? await Task.sleep(for: limit)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// One screenshot per window, small, and all of them at once.
    ///
    /// Serially this was most of a second for an app with six windows open,
    /// which is a second of the shelf sitting empty. A minimised window is not
    /// photographed at all: there is nothing on the screen to photograph, and
    /// asking anyway is how you get a black rectangle instead of a card that
    /// says "minimised".
    private static func previews(for windows: [MacWindow],
                                 in content: SCShareableContent) async -> [UInt32: Data] {
        let byID = Dictionary(uniqueKeysWithValues: content.windows.map { ($0.windowID, $0) })
        return await withTaskGroup(of: (UInt32, Data?).self) { group in
            for window in windows where !window.isMinimized && window.isOnScreen {
                guard let source = byID[window.id] else { continue }
                group.addTask { (window.id, await preview(of: source)) }
            }
            var found: [UInt32: Data] = [:]
            for await (id, data) in group {
                if let data { found[id] = data }
            }
            return found
        }
    }

    /// The long edge of a preview, in pixels. The card is about 150 points
    /// wide on a phone, so this is a 2x picture of it and nothing more: a
    /// window's worth of text is unreadable at any size that fits on a card,
    /// and the title above it is what actually identifies the window.
    private static let previewLongEdge = 320.0

    private static func preview(of window: SCWindow) async -> Data? {
        let config = SCStreamConfiguration()
        let factor = min(1, previewLongEdge / max(window.frame.width, window.frame.height, 1))
        config.width = max(Int(window.frame.width * factor), 8)
        config.height = max(Int(window.frame.height * factor), 8)
        config.captureResolution = .nominal
        config.showsCursor = false
        // Bounded for the same reason the listing is: a card without its
        // picture still names its window, and the shelf has to open.
        let shot = await withTimeout(captureTimeout) {
            try? await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(desktopIndependentWindow: window),
                configuration: config)
        }
        guard let image = shot ?? nil else { return nil }
        let rep = NSBitmapImageRep(cgImage: image)
        // JPEG rather than PNG: a screenshot is a photograph, and a window's
        // worth of PNG is five times the bytes for detail a 150-point card
        // cannot show.
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.5])
    }

    // MARK: - Raising one

    enum Raise {
        case raised(title: String)
        /// The window is gone, or minimised, or cannot be addressed. The
        /// message is written to be shown to the person who tapped.
        case refused(String)
    }

    /// Brings exactly that window forward, or refuses.
    ///
    /// The refusal is the point. Every other outcome here — raising the app and
    /// hoping, falling back to the frontmost window, picking the one with the
    /// same title — ends with text typed into a window nobody chose.
    ///
    /// `movingPointer` is for the switches a person made on purpose — a tap on a
    /// tile, a tap on a card in the window shelf — and not for the raise that
    /// happens on the way to delivering a sentence. Sending text somewhere is
    /// not a statement about where you are working, and a pointer that jumped
    /// away every time dictation landed would be worse than one that never
    /// moves.
    static func raise(windowID: UInt32, bundleID: String, name: String,
                      movingPointer: Bool = false, applicationPath: String? = nil,
                      appIdentity: AppInstanceIdentity? = nil) -> Raise {
        guard AXIsProcessTrusted() else {
            return .refused("Grant Accessibility to Nimlet first")
        }
        let running = appIdentity.flatMap { AppRegistry.shared.resolvePinned($0) }
            ?? (appIdentity == nil ? AppRegistry.running(AppReference(bundleID: bundleID, applicationPath: applicationPath)) : nil)
        guard let running else { return .refused("\(name) isn't running") }

        guard let windows = answeredWindows(pid: running.processIdentifier) else {
            return .refused(notResponding(name))
        }
        guard let match = windows.first(where: { $0.windowID == windowID }) else {
            return .refused("\(name)'s selected window is no longer available — refresh its windows")
        }
        if match.isMinimized {
            return .refused("\(match.title.isEmpty ? "That window" : match.title) is minimised — "
                            + "open it on your Mac, or pick another")
        }
        // Order matters: raising the window puts it in front of its siblings,
        // activating the app puts the app in front of everything else. The
        // other way round leaves the app's previous front window on top for a
        // frame, and whatever is typed next can land in it.
        AXUIElementPerformAction(match.element, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(match.element, kAXMainAttribute as CFString, kCFBooleanTrue)
        onMain { _ = running.activate(options: [.activateAllWindows]) }
        if movingPointer, let frame = frame(of: match.element) {
            EventInjector.shared.follow(window: frame)
        }
        return .raised(title: match.title)
    }

    /// Un-minimises a window, then raises it.
    ///
    /// The deliberate counterpart to `raise`'s refusal. Focusing will not touch
    /// a minimised window, because a tap that lands on the wrong card should
    /// never undo something the user put away — but "open it" is a different
    /// sentence, and it is one the phone has no other way to say. The Dock has
    /// had exactly this since 1999: a minimised window sits in it and comes
    /// back when you click it.
    ///
    /// Un-minimising first and raising second, because the two are not
    /// interchangeable: `AXRaise` on a minimised window does nothing at all,
    /// and the app would be activated in front of a window still in the Dock.
    static func open(windowID: UInt32, bundleID: String, name: String,
                     applicationPath: String? = nil, appIdentity: AppInstanceIdentity? = nil) -> Raise {
        guard AXIsProcessTrusted() else {
            return .refused("Grant Accessibility to Nimlet first")
        }
        let running = appIdentity.flatMap { AppRegistry.shared.resolvePinned($0) }
            ?? (appIdentity == nil ? AppRegistry.running(AppReference(bundleID: bundleID, applicationPath: applicationPath)) : nil)
        guard let running else { return .refused("\(name) isn't running") }

        guard let windows = answeredWindows(pid: running.processIdentifier) else {
            return .refused(notResponding(name))
        }
        guard let match = windows.first(where: { $0.windowID == windowID }) else {
            return .refused("\(name)'s selected window is no longer available — refresh its windows")
        }
        if match.isMinimized {
            let result = AXUIElementSetAttributeValue(match.element,
                                                      kAXMinimizedAttribute as CFString,
                                                      kCFBooleanFalse)
            guard result == .success else {
                return .refused("\(name) wouldn't bring that window back — open it on your Mac")
            }
        }
        // Same order as `raise`, and for the same reason: the window in front
        // of its siblings, then the app in front of everything else.
        AXUIElementPerformAction(match.element, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(match.element, kAXMainAttribute as CFString, kCFBooleanTrue)
        onMain { _ = running.activate(options: [.activateAllWindows]) }
        return .raised(title: match.title)
    }

    /// Where the window that app would bring forward on its own is.
    ///
    /// For the tiles that name an app rather than one of its windows: activating
    /// an app says nothing about where its window is, and the pointer has to be
    /// told somewhere to go. The app's own `AXMain` window is that somewhere,
    /// with the largest window as the fallback for the apps that publish no main
    /// one — a small floating palette is never the answer.
    static func frontWindowFrame(ofBundleID bundleID: String, applicationPath: String? = nil) -> CGRect? {
        guard AXIsProcessTrusted() else { return nil }
        let running = onMain {
            AppRegistry.running(AppReference(bundleID: bundleID, applicationPath: applicationPath))
        }
        guard let running else { return nil }
        let windows = accessibleWindows(pid: running.processIdentifier)
            .filter { !$0.isMinimized }
        guard !windows.isEmpty else { return nil }
        let main = windows.first { $0.isMain } ?? windows.max {
            ($0.size?.width ?? 0) * ($0.size?.height ?? 0)
                < ($1.size?.width ?? 0) * ($1.size?.height ?? 0)
        }
        return main.flatMap { frame(of: $0.element) }
    }

    /// That app's windows on screen, in the order the window server stacks
    /// them: front first. Ordinary windows only — no menus, no overlays.
    ///
    /// The window server's own list, which needs neither Accessibility nor
    /// Screen Recording for ids and layers, and which is the one thing that
    /// knows which of an app's windows was clicked last.
    static func stackingOrder(processID: pid_t) -> [UInt32] {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return [] }
        return info.compactMap { entry in
            guard (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == processID,
                  (entry[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let number = entry[kCGWindowNumber as String] as? NSNumber else { return nil }
            return number.uint32Value
        }
    }

    /// Whether the app already has a window open that is not minimised.
    ///
    /// Asked before a tile tap reopens the app. Reopening is what clicking an
    /// app in the Dock does, and it is only needed for an app with nothing to
    /// show; sent to one that already has windows, plenty of apps answer by
    /// opening another — so every tap on a tile was a chance of one more
    /// window. Nil when Accessibility cannot say, which keeps the Dock's
    /// behaviour. Minimised windows do not count: bringing one of those back
    /// is exactly what the reopen is for.
    static func hasOpenWindow(processID: pid_t) -> Bool? {
        guard AXIsProcessTrusted() else { return nil }
        // An app too busy to answer gets no reopen either: it would only be
        // queued behind whatever it is busy with. The window server says
        // whether it has a window up.
        guard let windows = answeredWindows(pid: processID) else {
            return !serverWindows(processID: processID, onScreenOnly: true).isEmpty
        }
        return windows.contains { window in
            guard !window.isMinimized else { return false }
            guard let size = window.size else { return true }
            return size.width > minimumSide && size.height > minimumSide
        }
    }

    /// What a tile tap needs to know about the window its target is pinned to.
    enum Presence: Equatable {
        case present
        case gone
        /// The window is there — the window server still lists it — but the app
        /// is not answering Accessibility, so it cannot be raised or typed into.
        case unresponsive
        /// Accessibility is not granted, so nothing can be said either way.
        case unknown
    }

    /// Whether a pinned window still exists, without mistaking a busy app for a
    /// closed window.
    ///
    /// Accessibility first, because it is what raising and delivering use. When
    /// the app does not answer, or answers with windows it cannot put an id to,
    /// the window server decides: it lists every window that exists, on any
    /// Space and minimised or not, and a closed one is gone from it.
    static func presence(of windowID: UInt32, bundleID: String, applicationPath: String? = nil,
                         appIdentity: AppInstanceIdentity? = nil) -> Presence {
        let app = appIdentity.flatMap { AppRegistry.shared.resolvePinned($0) }
            ?? (appIdentity == nil ? AppRegistry.running(AppReference(bundleID: bundleID, applicationPath: applicationPath)) : nil)
        guard let app else { return .gone }
        guard AXIsProcessTrusted() else { return .unknown }
        let listed = { serverWindows(processID: app.processIdentifier, onScreenOnly: false).contains(windowID) }
        guard let windows = answeredWindows(pid: app.processIdentifier) else {
            return listed() ? .unresponsive : .gone
        }
        if windows.contains(where: { $0.windowID == windowID }) { return .present }
        // Every window accounted for by id, and this one is not among them.
        if windows.allSatisfy({ $0.windowID != nil }) { return .gone }
        return listed() ? .present : .gone
    }

    /// The ids of that app's ordinary windows, as the window server lists them —
    /// ones too small to be a real window left out.
    private static func serverWindows(processID: pid_t, onScreenOnly: Bool) -> Set<UInt32> {
        let options: CGWindowListOption = onScreenOnly ? [.optionOnScreenOnly, .excludeDesktopElements] : [.optionAll]
        guard let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        return Set(info.compactMap { entry in
            guard (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == processID,
                  (entry[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let bounds = (entry[kCGWindowBounds as String] as? NSDictionary)
                      .flatMap({ CGRect(dictionaryRepresentation: $0 as CFDictionary) }),
                  bounds.width > minimumSide, bounds.height > minimumSide,
                  let number = entry[kCGWindowNumber as String] as? NSNumber else { return nil }
            return number.uint32Value
        })
    }

    /// Said to the person who tapped, in place of "that window is gone".
    static func notResponding(_ name: String) -> String {
        "\(name) isn't responding on your Mac right now — try again once it is"
    }

    /// Whether that window still exists and could receive something now.
    ///
    /// Asked before every delivery to a pinned target, which is the check that
    /// makes the pin a promise rather than a preference.
    static func state(of windowID: UInt32, bundleID: String, applicationPath: String? = nil) -> (exists: Bool, minimised: Bool, title: String) {
        let running = onMain {
            AppRegistry.running(AppReference(bundleID: bundleID, applicationPath: applicationPath))
        }
        guard let running else { return (false, false, "") }
        guard let match = accessibleWindows(pid: running.processIdentifier)
            .first(where: { $0.windowID == windowID }) else { return (false, false, "") }
        return (true, match.isMinimized, match.title)
    }

    // MARK: - Reshaping

    /// Resize a window to `aspect` (width over height), keeping its top-left
    /// corner and its width, and keeping it on the screen it is on.
    ///
    /// Width is what stays because width is what the phone does not change:
    /// the band is always the phone's width, and a seam dragged down asks for
    /// a taller picture. When a taller window will not fit the screen, the
    /// height is held to the screen and the width gives way instead.
    ///
    /// The app has the last word. A window with a minimum or a fixed size
    /// takes the nearest size it allows, and the phone keeps a bar for the
    /// difference; that is the app's rule, not something to fight.
    static func reshape(windowID: UInt32, aspect: CGFloat) -> Bool {
        guard AXIsProcessTrusted(), aspect.isFinite, aspect > 0.1, aspect < 10 else { return false }
        guard let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]],
              let pid = info.first?[kCGWindowOwnerPID as String] as? pid_t else { return false }
        guard let match = accessibleWindows(pid: pid).first(where: { $0.windowID == windowID }),
              !match.isMinimized,
              let current = frame(of: match.element) else { return false }

        let visible = onMain { visibleFrame(containing: current) } ?? current
        let minimum: CGFloat = 240
        var width = current.width
        var height = width / aspect
        if height > visible.height {
            height = visible.height
            width = height * aspect
        }
        if width > visible.width {
            width = visible.width
            height = width / aspect
        }
        width = max(width, minimum)
        height = max(height, minimum)
        let wanted = CGSize(width: width.rounded(), height: height.rounded())
        guard abs(wanted.width - current.width) >= 2 || abs(wanted.height - current.height) >= 2 else {
            return false
        }
        // Moved back on screen before growing, so a window near the bottom
        // grows upward rather than under the Dock — and so the app is never
        // asked for a frame it would clamp against the screen edge itself.
        let origin = CGPoint(x: min(max(current.minX, visible.minX), max(visible.maxX - wanted.width, visible.minX)),
                             y: min(max(current.minY, visible.minY), max(visible.maxY - wanted.height, visible.minY)))
        if origin != current.origin {
            var point = origin
            if let value = AXValueCreate(.cgPoint, &point) {
                AXUIElementSetAttributeValue(match.element, kAXPositionAttribute as CFString, value)
            }
        }
        var size = wanted
        guard let value = AXValueCreate(.cgSize, &size) else { return false }
        return AXUIElementSetAttributeValue(match.element, kAXSizeAttribute as CFString, value) == .success
    }

    /// The usable part of the screen a window is mostly on — menu bar and Dock
    /// taken off — in the same top-left-origin space `AXPosition` uses.
    ///
    /// `NSScreen` answers bottom-left from the primary display's bottom edge,
    /// so the flip is against the primary display's height, not this one's.
    private static func visibleFrame(containing window: CGRect) -> CGRect? {
        guard let primary = NSScreen.screens.first else { return nil }
        let flipped = NSScreen.screens.map { screen -> CGRect in
            let v = screen.visibleFrame
            return CGRect(x: v.minX, y: primary.frame.maxY - v.maxY, width: v.width, height: v.height)
        }
        return flipped.max { lhs, rhs in
            let a = lhs.intersection(window), b = rhs.intersection(window)
            return (a.isNull ? 0 : a.width * a.height) < (b.isNull ? 0 : b.width * b.height)
        }
    }

    // MARK: - The Accessibility side

    struct AXWindow {
        var element: AXUIElement
        var title: String
        var isMinimized: Bool
        /// The app's own idea of how big the window is. Nil when it publishes
        /// none, which is treated as "no reason to exclude it".
        var size: CGSize?
        /// The app's main window — the one it would bring forward on its own.
        ///
        /// This is the app's own answer, and it is the only one worth having:
        /// `SCWindow.isActive` is true for *every* window of the active
        /// application, so a shelf built on it showed four Claude windows all
        /// claiming to be the front one.
        var isMain: Bool
        /// Nil when this build could not put a window server id to an AX
        /// element, which is the one case where a window is listed but not
        /// raisable.
        var windowID: UInt32?
    }

    private static func accessibleWindows(pid: pid_t) -> [AXWindow] {
        answeredWindows(pid: pid) ?? []
    }

    /// The app's windows as Accessibility reports them, or nil when the app
    /// did not answer at all.
    ///
    /// The two used to be the same empty list, and they mean opposite things.
    /// An app whose main thread is busy — Codex, pegged answering somebody
    /// else's accessibility query, would not reply in ten seconds — looked
    /// exactly like an app whose window had closed, and the phone was told to
    /// refresh a list that refreshing could not fix.
    private static func answeredWindows(pid: pid_t) -> [AXWindow]? {
        guard AXIsProcessTrusted() else { return [] }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
        if error == .cannotComplete { return nil }
        guard error == .success, let elements = value as? [AXUIElement] else { return [] }

        let deadline = Date().addingTimeInterval(4)
        return elements.compactMap { element -> AXWindow? in
            guard Date() < deadline else { return nil }
            AXUIElementSetMessagingTimeout(element, 0.5)
            var titleValue: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleValue)
            var minimisedValue: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXMinimizedAttribute as CFString, &minimisedValue)
            var mainValue: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXMainAttribute as CFString, &mainValue)
            return AXWindow(element: element,
                            title: titleValue as? String ?? "",
                            isMinimized: (minimisedValue as? Bool) ?? false,
                            size: size(of: element),
                            isMain: (mainValue as? Bool) ?? false,
                            windowID: windowID(of: element))
        }
    }

    /// The window server id behind an Accessibility element.
    ///
    /// `_AXUIElementGetWindow` is the only thing that answers this, and it is
    /// private — so it is looked up at run time rather than linked against. If a
    /// future macOS drops it, every window still lists, still previews and still
    /// mirrors; what stops working is raising one, and `canRaise` already says
    /// so on the card. Matching on titles instead was the alternative, and two
    /// windows called "Untitled" is not a hypothetical.
    private static func closeButton(of window: AXUIElement) -> AXUIElement? {
        AXUIElementSetMessagingTimeout(window, 0.5)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXCloseButtonAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return value as! AXUIElement
    }

    static func requestClose(windowID: UInt32, identity: AppInstanceIdentity) -> Raise {
        guard AXIsProcessTrusted() else { return .refused("Grant Accessibility to Nimlet first") }
        guard let app = AppRegistry.shared.resolve(identity) else { return .refused("That app instance has ended — refresh its windows") }
        guard let window = accessibleWindows(pid: app.processIdentifier).first(where: { $0.windowID == windowID }),
              let button = closeButton(of: window.element) else { return .refused("That window has closed or does not support closing") }
        AXUIElementSetMessagingTimeout(button, 0.5)
        var enabled: CFTypeRef?
        if AXUIElementCopyAttributeValue(button, kAXEnabledAttribute as CFString, &enabled) == .success,
           (enabled as? Bool) == false { return .refused("Finish the app's current dialog first") }
        guard AXUIElementPerformAction(button, kAXPressAction as CFString) == .success else {
            return .refused("The app did not accept closing that window")
        }
        return .raised(title: window.title)
    }

    /// nil means unconfirmed, never a successful close.
    static func contains(windowID: UInt32, identity: AppInstanceIdentity) -> Bool? {
        guard AXIsProcessTrusted() else { return nil }
        guard let app = AppRegistry.shared.resolve(identity) else { return false }
        return contains(windowID: windowID, processID: app.processIdentifier)
    }

    /// A saved choice survives a host restart, but never the selected app's process ending.
    /// A failed Accessibility read is unknown, not evidence that a window closed.
    static func contains(windowID: UInt32, bundleID: String, applicationPath: String? = nil,
                         appIdentity: AppInstanceIdentity? = nil) -> Bool? {
        let app = appIdentity.flatMap { AppRegistry.shared.resolvePinned($0) }
            ?? (appIdentity == nil ? AppRegistry.running(AppReference(bundleID: bundleID, applicationPath: applicationPath)) : nil)
        guard let app else { return false }
        guard AXIsProcessTrusted() else { return nil }
        return contains(windowID: windowID, processID: app.processIdentifier)
    }

    private static func contains(windowID: UInt32, processID: pid_t) -> Bool? {
        let element = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(element, 1)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return nil }
        let ids = windows.compactMap { self.windowID(of: $0) }
        if ids.contains(windowID) { return true }
        return ids.count == windows.count ? false : nil
    }

    private typealias GetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    private static let getWindow: GetWindow? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow") else {
            miceLog.error("windows: _AXUIElementGetWindow is unavailable; windows cannot be raised")
            return nil
        }
        return unsafeBitCast(symbol, to: GetWindow.self)
    }()

    /// Where the window sits on the Mac's screens, in the top-left-origin space
    /// `CGEvent` uses for the pointer.
    ///
    /// That space is the reason this reads `AXPosition` rather than anything
    /// from AppKit: Accessibility answers in the same coordinates the pointer is
    /// moved in, while `NSWindow` and `NSScreen` answer in a bottom-left-origin
    /// one, and converting between them across several displays is a bug
    /// waiting for somebody's second monitor.
    private static func frame(of element: AXUIElement) -> CGRect? {
        guard let origin = position(of: element), let size = size(of: element) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    private static func position(of element: AXUIElement) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(value as! AXValue, .cgPoint, &point) else { return nil }
        return point
    }

    /// `AXSize` comes back as an `AXValue` box rather than as anything Swift
    /// can bridge, hence the unwrapping.
    private static func size(of element: AXUIElement) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(value as! AXValue, .cgSize, &size) else { return nil }
        return size
    }

    private static func windowID(of element: AXUIElement) -> UInt32? {
        guard let getWindow else { return nil }
        var id: CGWindowID = 0
        guard getWindow(element, &id) == .success, id != 0 else { return nil }
        return UInt32(id)
    }
}
