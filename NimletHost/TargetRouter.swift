import AppKit

/// Turns "send this text to Claude" into the right sequence of focus + injection.
enum TargetRouter {

    struct Outcome {
        var ok: Bool
        var message: String
        /// The app was not running and has only just been asked to start, so
        /// it will take seconds rather than a frame to come forward.
        var launched = false
    }

    /// Focus, and then proof of it.
    ///
    /// `focus` reports that an app was *asked* to come forward; this waits
    /// until it actually has. The difference used to be a fixed 0.18 s sleep,
    /// which is shorter than any app launch and shorter than some activations,
    /// and whatever was pasted after it went into whichever window was still
    /// in front — with Return pressed — for a sentence aimed at an app that
    /// had not opened yet. Nothing is sent until the app the sentence was
    /// addressed to is the one in front, and if it never comes, nothing is.
    private static func bringForward(_ target: NimletTarget) -> Outcome {
        let focused = focus(target)
        guard focused.ok, let bundleID = target.bundleID else { return focused }
        let timeout: TimeInterval = focused.launched ? 12 : 4
        guard waitUntilFrontmost(app: target.appReference ?? AppReference(bundleID: bundleID), timeout: timeout) else {
            return Outcome(ok: false,
                           message: focused.launched
                               ? "\(target.name) is still starting — nothing was sent. Try again in a moment."
                               : "\(target.name) didn't come to the front, so nothing was sent")
        }
        // In front, now let its window settle keyboard focus in its text field.
        Thread.sleep(forTimeInterval: 0.18)
        return focused
    }

    private static func waitUntilFrontmost(app: AppReference, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let ready = onMain {
                guard let front = NSWorkspace.shared.frontmostApplication, let bundleID = front.bundleIdentifier else { return false }
                return app.matches(AppReference(bundleID: bundleID, applicationPath: front.bundleURL?.standardizedFileURL.path))
            }
            if ready { return true }
            guard Date() < deadline else { return false }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    // MARK: - Focus

    /// `movingPointer` takes the Mac's pointer with the window, for the switches
    /// somebody made on purpose. Off by default because this function is also on
    /// the way to every delivery: raising a window to type into it is not a
    /// statement about where the pointer should be.
    @discardableResult
    static func focus(_ target: NimletTarget, movingPointer: Bool = false) -> Outcome {
        guard !EventInjector.shared.isPaused else {
            return Outcome(ok: false, message: "Injection is paused")
        }

        switch target.kind {
        case .frontmost:
            return Outcome(ok: true, message: "Using the focused app")

        case .app:
            guard let bundleID = target.bundleID, !bundleID.isEmpty else {
                return Outcome(ok: false, message: "\(target.name) has no bundle ID")
            }
            // A target pointed at one window goes to that window or nowhere.
            //
            // This is the whole safety property of the window shelf, and it
            // lives here rather than in the two callers because both of them —
            // tapping a tile and delivering text — come through this function.
            // Falling back to "activate the app" when the window is gone would
            // mean a dictated sentence typed into whichever window that app
            // happened to have in front, which is the failure the pin exists to
            // prevent.
            if let windowID = target.pinnedWindowID {
                switch WindowRoster.raise(windowID: windowID, bundleID: bundleID,
                                          name: target.name, movingPointer: movingPointer,
                                          applicationPath: target.applicationPath, appIdentity: target.pinnedAppIdentity) {
                case .raised(let title):
                    return Outcome(ok: true, message: "Focused \(title.isEmpty ? target.name : title)")
                case .refused(let why):
                    return Outcome(ok: false, message: why)
                }
            }
            // Callers run on a background queue; AppKit activation belongs on main.
            let activated: Bool = onMain {
                if let app = AppRegistry.running(target.appReference!) {
                    app.activate(options: [.activateAllWindows])
                    return true
                }
                return false
            }
            if activated {
                // Which window that app brought forward is its own decision, so
                // it is asked rather than assumed — and asked from here rather
                // than from inside the block above, because reading it is an
                // Accessibility round trip into another process and the main
                // thread is where this app's menu bar lives.
                if movingPointer, let frame = WindowRoster.frontWindowFrame(ofBundleID: bundleID, applicationPath: target.applicationPath) {
                    EventInjector.shared.follow(window: frame)
                }
                return Outcome(ok: true, message: "Focused \(target.name)")
            }
            if AppRegistry.shared.safeSnapshot.apps.filter({ target.appReference!.matches($0.identity.app) }).count > 1 {
                return Outcome(ok: false, message: "More than one copy of \(target.name) is running — choose one in All apps")
            }
            // Not running yet — launching is friendlier than failing. Nothing to
            // take the pointer to: an app that has not opened a window yet has
            // nowhere for it to land.
            return onMain {
                guard let url = AppRegistry.installedURL(target.appReference!) else {
                    return Outcome(ok: false, message: "\(target.name) isn't installed")
                }
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                return Outcome(ok: true, message: "Launching \(target.name)", launched: true)
            }

        case .tmux:
            switch resolvePane(of: target) {
            case .refused(let message):
                return Outcome(ok: false, message: message)
            case .ready(let pane):
                let result = Tmux.run(["select-pane", "-t", pane])
                return result.ok
                    ? Outcome(ok: true, message: "Selected \(target.name)")
                    : Outcome(ok: false, message: "tmux: \(result.output)")
            }
        }
    }

    // MARK: - Text delivery

    static func deliver(text: String, to target: NimletTarget, submit: Bool?) -> DeliveryReceipt {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return record(target, characters: 0, submitted: false, ok: false, message: "Nothing to send")
        }
        // Pausing injection is the only safety control the user has, and it
        // covered every path except the tmux one — the path that types straight
        // into a shell without so much as raising a window.
        guard !EventInjector.shared.isPaused else {
            return record(target, characters: trimmed.count, submitted: false, ok: false,
                          message: "Injection is paused — turn it back on in the menu bar")
        }
        // `allowAutoSubmit` is policy rather than preference, so neither the
        // target's own `submitOnSend` nor a per-message override can talk Nimlet
        // into pressing Return on a target that said never.
        let shouldSubmit = target.allowAutoSubmit && (submit ?? target.submitOnSend)

        switch target.kind {
        case .tmux:
            let pane: String
            switch resolvePane(of: target) {
            case .refused(let message):
                return record(target, characters: trimmed.count, submitted: false, ok: false, message: message)
            case .ready(let resolved):
                pane = resolved
            }

            // tmux's own buffer, pasted with `-p`, is what makes a paragraph
            // deliverable: the whole text arrives in one piece wrapped in
            // bracketed-paste markers whenever the application asked for them,
            // so a TUI doing its own line editing inserts the newlines instead
            // of running each line as it lands, and a leading slash is text
            // rather than a command. This used to replace every newline with a
            // space, which made a multi-line prompt — the thing this product
            // exists to send — impossible to send at all.
            let loaded = Tmux.run(["load-buffer", "-b", Tmux.bufferName, "-"], input: Data(trimmed.utf8))
            guard loaded.ok else {
                return record(target, characters: trimmed.count, submitted: false, ok: false,
                              message: "tmux: \(loaded.output)")
            }
            let pasted = Tmux.run(["paste-buffer", "-d", "-p", "-b", Tmux.bufferName, "-t", pane])
            guard pasted.ok else {
                // `-d` only deletes the buffer on success. A paste that failed
                // — the pane is gone, say — would otherwise leave the whole
                // dictated text readable with `tmux show-buffer -b nimlet`
                // until the next delivery overwrote it.
                _ = Tmux.run(["delete-buffer", "-b", Tmux.bufferName])
                return record(target, characters: trimmed.count, submitted: false, ok: false,
                              message: "tmux: \(pasted.output)")
            }
            var submitted = false
            if shouldSubmit {
                submitted = Tmux.run(["send-keys", "-t", pane, "Enter"]).ok
            }
            return record(target, characters: trimmed.count, submitted: submitted, ok: true,
                          message: sentMessage(trimmed, to: target))

        case .app, .frontmost:
            guard EventInjector.shared.isTrusted else {
                return record(target, characters: trimmed.count, submitted: false, ok: false,
                              message: "Grant Accessibility to Nimlet first")
            }
            if target.kind == .app {
                let focused = bringForward(target)
                guard focused.ok else {
                    return record(target, characters: trimmed.count, submitted: false, ok: false,
                                  message: focused.message)
                }
            }
            EventInjector.shared.paste(trimmed)
            if shouldSubmit { EventInjector.shared.pressReturn() }
            return record(target, characters: trimmed.count, submitted: shouldSubmit, ok: true,
                          message: sentMessage(trimmed, to: target))
        }
    }

    // MARK: - Attachment delivery

    /// One image, already validated and written to the inbox.
    struct Attachment {
        var url: URL
        var format: AttachmentFrame.Format
    }

    /// Delivers images that are already on disk.
    ///
    /// The route differs by what is listening, because "send an image" does. A
    /// pane cannot be handed bytes at all, so it is handed paths: every agent
    /// that runs in one opens a file it is given the name of, the delivery is the
    /// text path this app already trusts, and the pasteboard is never touched —
    /// which is the promise `tmux` targets make. An app with a composer is handed
    /// the pictures themselves, one paste each, because a file name typed into a
    /// message box is just some words.
    ///
    /// Either way the files stay in the inbox. They are the message, not a
    /// transport detail: the agent may not read the prompt for a minute, and the
    /// user may want the screenshot again tomorrow.
    static func deliver(attachments: [Attachment],
                        caption: String,
                        to target: NimletTarget,
                        submit: Bool?) -> DeliveryReceipt {
        guard !attachments.isEmpty else {
            return record(target, characters: 0, submitted: false, ok: false, message: "Nothing to send")
        }
        guard !EventInjector.shared.isPaused else {
            return record(target, characters: 0, submitted: false, ok: false,
                          message: "Injection is paused — turn it back on in the menu bar")
        }

        switch target.kind {
        case .tmux:
            // The caption first, then one path per line. A path on its own line
            // survives being pasted into a prompt that does its own line
            // editing, and reads as a file name rather than as prose.
            let body = ([caption.trimmingCharacters(in: .whitespacesAndNewlines)]
                .filter { !$0.isEmpty } + attachments.map { quoted($0.url.path) })
                .joined(separator: "\n")
            var receipt = deliver(text: body, to: target, submit: submit)
            if receipt.ok { receipt.message = sentMessage(attachments.count, to: target) }
            return receipt

        case .app, .frontmost:
            guard EventInjector.shared.isTrusted else {
                return record(target, characters: caption.count, submitted: false, ok: false,
                              message: "Grant Accessibility to Nimlet first")
            }
            if target.kind == .app {
                let focused = bringForward(target)
                guard focused.ok else {
                    return record(target, characters: caption.count, submitted: false, ok: false,
                                  message: focused.message)
                }
            }
            for attachment in attachments {
                EventInjector.shared.paste(imageAt: attachment.url, format: attachment.format)
                // A composer needs a moment to turn a pasted image into an
                // attachment before the next one lands on the pasteboard.
                Thread.sleep(forTimeInterval: 0.25)
            }
            let trimmed = caption.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { EventInjector.shared.paste(trimmed) }
            let shouldSubmit = target.allowAutoSubmit && (submit ?? target.submitOnSend)
            if shouldSubmit { EventInjector.shared.pressReturn() }
            return record(target, characters: trimmed.count, submitted: shouldSubmit, ok: true,
                          message: sentMessage(attachments.count, to: target))
        }
    }

    /// Sends one key to one target.
    ///
    /// The key row used to bypass all of this and post a `CGEvent` at whatever
    /// had keyboard focus. For an app target that is roughly right; for a tmux
    /// target it is wrong in the way that matters most — text reaches the pane
    /// without raising a window, so the window is usually *not* in front, and
    /// Escape went to whatever was. Tapping it to stop an agent stopped
    /// something else.
    static func press(_ chord: KeyChord, on target: NimletTarget?) -> Outcome {
        guard !EventInjector.shared.isPaused else {
            return Outcome(ok: false, message: "Injection is paused — turn it back on in the menu bar")
        }
        guard let target else { return postKey(chord, to: "the front window") }

        switch target.kind {
        case .tmux:
            guard let name = chord.tmuxName else {
                return Outcome(ok: false,
                               message: "\(chord.spoken) is the terminal's own shortcut, not something a pane can receive")
            }
            let pane: String
            switch resolvePane(of: target) {
            case .refused(let message): return Outcome(ok: false, message: message)
            case .ready(let resolved): pane = resolved
            }
            // A repeat is the same key again, not a held key: Escape Escape is
            // two presses to the program reading them.
            for _ in 0..<chord.repeatCount {
                let sent = Tmux.run(["send-keys", "-t", pane, name])
                guard sent.ok else { return Outcome(ok: false, message: "tmux: \(sent.output)") }
            }
            return Outcome(ok: true, message: "\(chord.spoken) → \(target.name)")

        case .app:
            // The same proof the paste path waits for: a keystroke posted
            // before the window is in front goes to whatever still is.
            let focused = bringForward(target)
            guard focused.ok else { return Outcome(ok: false, message: focused.message) }
            return postKey(chord, to: target.name)

        case .frontmost:
            return postKey(chord, to: target.name)
        }
    }

    private static func postKey(_ chord: KeyChord, to name: String) -> Outcome {
        guard EventInjector.shared.isTrusted else {
            return Outcome(ok: false, message: "Grant Accessibility to Nimlet first")
        }
        guard let code = chord.macVirtualKey else {
            return Outcome(ok: false, message: "\(chord.spoken) isn't a key Nimlet knows how to press")
        }
        var flags: CGEventFlags = []
        if chord.control { flags.insert(.maskControl) }
        if chord.option { flags.insert(.maskAlternate) }
        if chord.shift { flags.insert(.maskShift) }
        if chord.command { flags.insert(.maskCommand) }
        for index in 0..<chord.repeatCount {
            // A double Escape is two presses with a gap, not a key repeat: an
            // application distinguishing them looks at the interval.
            if index > 0 { Thread.sleep(forTimeInterval: 0.04) }
            EventInjector.shared.pressKey(code, flags: flags)
        }
        return Outcome(ok: true, message: "\(chord.spoken) → \(name)")
    }

    /// A path a shell — or an agent reading one — will take whole.
    ///
    /// The inbox is under `~/Library/Application Support/`, which has a space in
    /// it, so an unquoted path is two arguments. This is not a theoretical
    /// problem: the first image ever delivered to a pane came out as
    /// `no such file or directory: /Users/you/Library/Application`.
    ///
    /// POSIX single quotes: everything inside is literal, and the one character
    /// that cannot appear is produced by closing, escaping and reopening.
    private static func quoted(_ path: String) -> String {
        let safe = path.allSatisfy { $0.isLetter || $0.isNumber || "/._-".contains($0) }
        guard !safe else { return path }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func sentMessage(_ images: Int, to target: NimletTarget) -> String {
        "Sent \(images) image\(images == 1 ? "" : "s") to \(target.name)"
    }

    private static func sentMessage(_ text: String, to target: NimletTarget) -> String {
        let words = text.split(whereSeparator: \.isWhitespace).count
        return "Sent \(words) word\(words == 1 ? "" : "s") to \(target.name)"
    }

    private enum PaneLookup {
        case ready(String)
        case refused(String)
    }

    /// The pane id to send to, or why this target cannot be sent to right now.
    private static func resolvePane(of target: NimletTarget) -> PaneLookup {
        guard let pane = target.tmuxTarget, !pane.isEmpty else {
            return .refused("\(target.name) has no tmux pane")
        }
        // A positional spec names a slot, not a pane: indices renumber as soon
        // as a pane closes, so honouring one would paste into whatever moved
        // into the slot and press Return on it.
        guard target.hasStableTmuxID else {
            return .refused("\(target.name) still points at \(pane); pick the pane again in Settings so Nimlet can store its stable id")
        }
        guard Tmux.paneExists(pane) else {
            return .refused("tmux pane \(pane) is gone — pick the pane again in Settings")
        }
        return .ready(pane)
    }

    private static func record(_ target: NimletTarget,
                               characters: Int,
                               submitted: Bool,
                               ok: Bool,
                               message: String) -> DeliveryReceipt {
        let receipt = DeliveryReceipt(ok: ok,
                                      targetID: target.id,
                                      targetName: target.name,
                                      characters: characters,
                                      submitted: submitted,
                                      message: message)
        DeliveryLog.record(receipt)
        return receipt
    }
}


/// Runs an AppKit call on the main thread from one of the host's own queues.
func onMain<T>(_ work: () -> T) -> T {
    if Thread.isMainThread { return work() }
    return DispatchQueue.main.sync(execute: work)
}

/// Thin wrapper over the tmux binary. tmux is worth special-casing: `send-keys`
/// lands in the right pane whether or not the terminal window is visible, which
/// is far more reliable than raising a window and hoping focus follows.
enum Tmux {
    /// Named rather than anonymous so a delivery cannot push the user's own
    /// copied text down the buffer stack; `paste-buffer -d` then deletes it.
    static let bufferName = "nimlet"

    /// One live pane. The id is what gets stored; the spec is what gets shown.
    struct Pane: Identifiable, Hashable {
        /// Stable pane id, e.g. `%3`.
        var id: String
        /// `session:window.pane`, the form a person recognises.
        var spec: String
        var command: String
        var path: String

        var label: String { "\(spec)  \(command)" }
    }

    /// Where tmux might be. Homebrew first, then the places MacPorts and Nix
    /// put it, then whatever is on this process's PATH — which from a login
    /// item is almost nothing, so the list matters. `mice.tmuxPath` in
    /// preferences wins outright, for a tmux built somewhere nobody guessed.
    static var searchPaths: [String] {
        var paths = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/opt/local/bin/tmux",
                     "/run/current-system/sw/bin/tmux", "/nix/var/nix/profiles/default/bin/tmux",
                     NSString(string: "~/.nix-profile/bin/tmux").expandingTildeInPath,
                     "/usr/bin/tmux"]
        let env = ProcessInfo.processInfo.environment["PATH"] ?? ""
        paths += env.split(separator: ":").map { "\($0)/tmux" }
        return paths
    }

    static var executableURL: URL? {
        if let override = UserDefaults.standard.string(forKey: "mice.tmuxPath"),
           FileManager.default.isExecutableFile(atPath: override) {
            return URL(fileURLWithPath: override)
        }
        for path in searchPaths where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    static var isAvailable: Bool { executableURL != nil }

    @discardableResult
    static func run(_ arguments: [String], input: Data? = nil) -> (ok: Bool, output: String) {
        guard let executableURL else { return (false, "tmux not found") }
        let result = Subprocess.run(executableURL, arguments, input: input)
        return (result.ok, result.output)
    }

    static func listPanes() -> [Pane] {
        let format = "#{pane_id}|#{session_name}:#{window_index}.#{pane_index}|#{pane_current_command}|#{pane_current_path}"
        let result = run(["list-panes", "-a", "-F", format])
        guard result.ok else { return [] }
        return result.output.split(separator: "\n").compactMap { line in
            // tmux forbids `.` and `:` in a session name but allows `|`, so the
            // separator can appear inside a field. A shifted parse is not a
            // cosmetic problem: `command` decides whether a pane is seeded as a
            // shell, and a shell seeded by mistake is one Nimlet will press Return
            // in. Anything that does not parse to exactly the expected shape is
            // dropped rather than guessed at. The path is allowed to contain a
            // separator because it is last and absorbs the remainder.
            let fields = line.split(separator: "|", maxSplits: 3,
                                    omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 4,
                  isPaneID(fields[0]),
                  isPaneSpec(fields[1]),
                  !fields[2].isEmpty
            else {
                // Private: the line carries session names and working
                // directories, which is to say project names and paths.
                miceLog.error("skipping unparseable tmux pane line: \(String(line), privacy: .private)")
                return nil
            }
            return Pane(id: fields[0], spec: fields[1], command: fields[2], path: fields[3])
        }
    }

    /// `%` followed by digits, which is the whole of tmux's pane id syntax.
    static func isPaneID(_ text: String) -> Bool {
        guard text.hasPrefix("%") else { return false }
        let digits = text.dropFirst()
        return !digits.isEmpty && digits.allSatisfy(\.isNumber)
    }

    /// `session:window.pane`, where the two indices are numeric. A session name
    /// carrying a separator shifts the fields and fails this.
    private static func isPaneSpec(_ text: String) -> Bool {
        guard let colon = text.lastIndex(of: ":") else { return false }
        let indices = text[text.index(after: colon)...].split(separator: ".", omittingEmptySubsequences: false)
        guard indices.count == 2, !text[..<colon].isEmpty else { return false }
        return indices.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }

    /// Whether the id still names a live pane. Asking is cheap and the
    /// alternative is guessing with someone else's keyboard.
    static func paneExists(_ paneID: String) -> Bool {
        let result = run(["display-message", "-p", "-t", paneID, "#{pane_id}"])
        return result.ok && result.output == paneID
    }

    /// Turns a positional `session:window.pane` spec into the pane's stable id.
    static func resolve(spec: String) -> String? {
        if spec.hasPrefix("%") { return paneExists(spec) ? spec : nil }
        let result = run(["display-message", "-p", "-t", spec, "#{pane_id}"])
        guard result.ok, result.output.hasPrefix("%") else { return nil }
        return result.output
    }

    static func currentPath(ofPane paneID: String) -> String? {
        let result = run(["display-message", "-p", "-t", paneID, "#{pane_current_path}"])
        guard result.ok, !result.output.isEmpty else { return nil }
        return result.output
    }
}

/// Append-only record of what was delivered where.
///
/// The text itself is deliberately absent. The question this has to answer is
/// "did Nimlet press Return in that pane at 14:02?", and keeping a copy of
/// everything ever dictated in order to answer it would cost more than the
/// answer is worth.
enum DeliveryLog {
    static let fileURL: URL? = {
        SupportDirectory.url?.appendingPathComponent("deliveries.log")
    }()

    private static let lock = NSLock()
    private static let timestamps: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func record(_ receipt: DeliveryReceipt) {
        guard let fileURL else { return }
        let line = [
            timestamps.string(from: Date()),
            receipt.ok ? "delivered" : "refused",
            receipt.targetName,
            "\(receipt.characters) chars",
            "submitted=\(receipt.submitted ? "yes" : "no")",
        ].joined(separator: "\t") + "\n"

        lock.lock()
        defer { lock.unlock() }
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            create(at: fileURL, with: data)
        }
    }

    /// Created owner-only. The text never goes in here, but the target names
    /// and the timing do, and between them they describe what someone was
    /// working on and when.
    private static func create(at url: URL, with data: Data) {
        FileManager.default.createFile(atPath: url.path, contents: data,
                                       attributes: [.posixPermissions: 0o600])
    }

    static func reveal() {
        guard let fileURL else { return }
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            create(at: fileURL, with: Data())
        }
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }
}

/// Synchronous queue crossing for short published-state changes, never AX or disk work.
func onMainActor<T>(_ work: @MainActor () -> T) -> T {
    onMain { MainActor.assumeIsolated { work() } }
}
