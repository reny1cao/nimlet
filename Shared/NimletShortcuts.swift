import Foundation

/// One keystroke, named rather than numbered.
///
/// A macOS virtual key code can be posted as a `CGEvent` and nothing else. It
/// cannot be handed to `tmux send-keys`, which wants `Escape`, `C-c`, `BTab` —
/// and a pane is where an agent actually is. So a chord is stored in neither
/// form and translated into both.
public struct KeyChord: Codable, Sendable, Hashable {
    /// Lowercase token: a letter, a digit, or a named key such as `escape`,
    /// `enter`, `tab`, `space`, `up`.
    public var key: String
    public var control: Bool
    public var option: Bool
    public var shift: Bool
    public var command: Bool
    /// Sent this many times in a row. Two agents use a double Escape as a
    /// distinct command — Claude Code to rewind, Codex to edit the previous
    /// message — and it is one action to the person pressing it.
    public var repeatCount: Int

    public init(_ key: String,
                control: Bool = false,
                option: Bool = false,
                shift: Bool = false,
                command: Bool = false,
                repeatCount: Int = 1) {
        self.key = key
        self.control = control
        self.option = option
        self.shift = shift
        self.command = command
        self.repeatCount = max(1, min(repeatCount, 4))
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decodeIfPresent(String.self, forKey: .key) ?? "escape"
        control = try c.decodeIfPresent(Bool.self, forKey: .control) ?? false
        option = try c.decodeIfPresent(Bool.self, forKey: .option) ?? false
        shift = try c.decodeIfPresent(Bool.self, forKey: .shift) ?? false
        command = try c.decodeIfPresent(Bool.self, forKey: .command) ?? false
        repeatCount = max(1, min(try c.decodeIfPresent(Int.self, forKey: .repeatCount) ?? 1, 4))
    }

    /// What `tmux send-keys` calls it, or nil when a pane cannot receive it.
    ///
    /// Command is the one modifier with no meaning inside a pane: ⌘C is the
    /// terminal application's own shortcut and never reaches the program
    /// running in it.
    public var tmuxName: String? {
        guard !command else { return nil }
        // tmux spells shifted Tab as back-tab rather than as a modifier.
        if key == "tab", shift, !control, !option { return "BTab" }
        guard let base = KeyChord.tmuxBase(of: key) else { return nil }
        var name = ""
        if control { name += "C-" }
        if option { name += "M-" }
        if shift, base.count > 1 { name += "S-" }
        // A shifted letter is the capital, not a modifier tmux understands.
        let body = (shift && base.count == 1) ? base.uppercased() : base
        return name + body
    }

    private static func tmuxBase(of key: String) -> String? {
        switch key {
        case "escape": return "Escape"
        case "enter": return "Enter"
        case "tab": return "Tab"
        case "space": return "Space"
        case "up": return "Up"
        case "down": return "Down"
        case "left": return "Left"
        case "right": return "Right"
        case "delete": return "BSpace"
        case "forwarddelete": return "DC"
        case "home": return "Home"
        case "end": return "End"
        case "pageup": return "PPage"
        case "pagedown": return "NPage"
        default:
            if let number = functionKeyNumber(key) { return "F\(number)" }
            // Punctuation is deliberately absent, though tmux would take most
            // of it: `send-keys ;` is read by tmux's own parser as a command
            // separator rather than as a key, so the one chord that needs
            // special handling is the one nobody would think to test. Every
            // punctuation chord in the profiles below carries ⌘, which already
            // means "not for a pane".
            guard key.count == 1, let scalar = key.unicodeScalars.first,
                  CharacterSet.alphanumerics.contains(scalar) else { return nil }
            return key
        }
    }

    /// `f1`...`f12` and nothing else: `f13` is a key no keyboard here has, and
    /// `f0` is not a key at all.
    static func functionKeyNumber(_ key: String) -> Int? {
        guard key.count > 1, key.hasPrefix("f"), let number = Int(key.dropFirst()),
              (1...12).contains(number) else { return nil }
        return number
    }

    /// Every key Nimlet can name, and the `kVK_*` code it is posted as.
    ///
    /// This lived in the host, beside the code that posts the event, which
    /// meant the vocabulary a profile could name and the vocabulary the Mac
    /// could press were two lists maintained in two targets — and a profile
    /// naming a key the host had never heard of became a button that reported
    /// success and pressed nothing. They are one list now, and the tests check
    /// every bound chord against it.
    ///
    /// It reads both ways: a chord names a key code to post, and a key code
    /// read out of an app's own menu bar names a chord to store.
    public static let keyCodes: [String: UInt16] = [
        "a": 0x00, "b": 0x0B, "c": 0x08, "d": 0x02, "e": 0x0E, "f": 0x03, "g": 0x05,
        "h": 0x04, "i": 0x22, "j": 0x26, "k": 0x28, "l": 0x25, "m": 0x2E, "n": 0x2D,
        "o": 0x1F, "p": 0x23, "q": 0x0C, "r": 0x0F, "s": 0x01, "t": 0x11, "u": 0x20,
        "v": 0x09, "w": 0x0D, "x": 0x07, "y": 0x10, "z": 0x06,
        "0": 0x1D, "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15,
        "5": 0x17, "6": 0x16, "7": 0x1A, "8": 0x1C, "9": 0x19,
        "escape": 0x35, "enter": 0x24, "tab": 0x30, "space": 0x31, "delete": 0x33,
        "forwarddelete": 0x75, "home": 0x73, "end": 0x77, "pageup": 0x74,
        "pagedown": 0x79,
        "left": 0x7B, "right": 0x7C, "down": 0x7D, "up": 0x7E,
        // The punctuation an app shortcut actually reaches for: ⌘. stops a
        // build, ⌘[ goes back, ⌃` opens a terminal, ⌘, opens settings.
        ",": 0x2B, ".": 0x2F, "/": 0x2C, ";": 0x29, "'": 0x27, "[": 0x21,
        "]": 0x1E, "\\": 0x2A, "-": 0x1B, "=": 0x18, "`": 0x32,
        "f1": 0x7A, "f2": 0x78, "f3": 0x63, "f4": 0x76, "f5": 0x60, "f6": 0x61,
        "f7": 0x62, "f8": 0x64, "f9": 0x65, "f10": 0x6D, "f11": 0x67, "f12": 0x6F,
    ]

    private static let keysByCode: [UInt16: String] =
        Dictionary(uniqueKeysWithValues: keyCodes.map { ($0.value, $0.key) })

    /// The `kVK_*` code to post as a `CGEvent`, or nil when this is not a key
    /// a Mac keyboard has.
    public var macVirtualKey: UInt16? { KeyChord.keyCodes[key] }

    /// The name for a key code, which is what a menu bar reports for a
    /// shortcut with no printable character — F5, an arrow, Home.
    public static func key(forVirtualKey code: UInt16) -> String? { keysByCode[code] }

    /// How it reads on a phone button: ⌃C, ⇧⇥, esc ×2.
    public var display: String {
        var text = ""
        if control { text += "⌃" }
        if option { text += "⌥" }
        if shift { text += "⇧" }
        if command { text += "⌘" }
        switch key {
        case "escape": text += "esc"
        case "enter": text += "↵"
        case "tab": text += "⇥"
        case "delete": text += "⌫"
        case "forwarddelete": text += "⌦"
        case "space": text += "space"
        case "up": text += "↑"
        case "down": text += "↓"
        case "left": text += "←"
        case "right": text += "→"
        case "home": text += "↖"
        case "end": text += "↘"
        case "pageup": text += "⇞"
        case "pagedown": text += "⇟"
        // Punctuation is already the character it sends, and a function key is
        // already written the way it is printed on the key.
        default: text += key.uppercased()
        }
        return repeatCount > 1 ? "\(text) ×\(repeatCount)" : text
    }

    /// Said aloud, because "⌃C" is not a word.
    public var spoken: String {
        var parts: [String] = []
        if control { parts.append("Control") }
        if option { parts.append("Option") }
        if shift { parts.append("Shift") }
        if command { parts.append("Command") }
        switch key {
        case "escape": parts.append("Escape")
        case "enter": parts.append("Return")
        case "tab": parts.append("Tab")
        case "delete": parts.append("Delete")
        case "forwarddelete": parts.append("Forward delete")
        case "space": parts.append("Space")
        case "home": parts.append("Home")
        case "end": parts.append("End")
        case "pageup": parts.append("Page up")
        case "pagedown": parts.append("Page down")
        // "Command ," is not something anybody says, and this is what a
        // delivery receipt reads back.
        case ",": parts.append("Comma")
        case ".": parts.append("Period")
        case "/": parts.append("Slash")
        case ";": parts.append("Semicolon")
        case "'": parts.append("Quote")
        case "[": parts.append("Left bracket")
        case "]": parts.append("Right bracket")
        case "\\": parts.append("Backslash")
        case "-": parts.append("Minus")
        case "=": parts.append("Equals")
        case "`": parts.append("Backtick")
        default: parts.append(key.uppercased())
        }
        let name = parts.joined(separator: " ")
        return repeatCount > 1 ? "\(name), twice" : name
    }
}

/// One button on the phone, and what it does.
public struct ShortcutAction: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        /// Send a chord to the target.
        case key
        /// Start this phone's own dictation for the target. Not a keystroke —
        /// the microphone is here, and the text crosses the LAN already
        /// transcribed.
        case dictate
    }

    public var id: String
    /// Two or three words at most: this is a 44pt button.
    public var label: String
    public var symbol: String
    public var kind: Kind
    public var chord: KeyChord?
    /// Shown under the button in the target's settings, where there is room to
    /// say what it does and what it needs.
    public var note: String?
    /// The glyph says it on its own, so the button is drawn without the word.
    ///
    /// A row of these is read by shape long before it is read by text, and
    /// "reload" written beside a clockwise arrow is a word occupying the room
    /// the next button wanted. Set only where the symbol is one nobody has to
    /// learn, and never where it would leave two buttons in the same set
    /// looking alike — which is why `find` loses its word in a browser and
    /// keeps it in an editor, where three different searches sit side by side.
    ///
    /// The label is still what the button is called: the target's settings list
    /// it, and VoiceOver reads it.
    public var glyphOnly: Bool

    public init(id: String, label: String, symbol: String,
                kind: Kind = .key, chord: KeyChord? = nil, note: String? = nil,
                glyphOnly: Bool = false) {
        self.id = id
        self.label = label
        self.symbol = symbol
        self.kind = kind
        self.chord = chord
        self.note = note
        self.glyphOnly = glyphOnly
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? "key"
        symbol = try c.decodeIfPresent(String.self, forKey: .symbol) ?? "keyboard"
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .key
        chord = try c.decodeIfPresent(KeyChord.self, forKey: .chord)
        note = try c.decodeIfPresent(String.self, forKey: .note)
        // A Mac on an older build sends no such field, and a button that keeps
        // its word is the safe way to be wrong about this.
        glyphOnly = try c.decodeIfPresent(Bool.self, forKey: .glyphOnly) ?? false
    }
}

/// The set of buttons for one kind of thing on the other end.
///
/// A row of four fixed keys cannot serve a coding agent, a shell and a GUI app
/// at once: Escape interrupts an agent but does nothing at a shell prompt,
/// Control-C kills a command but quits an agent outright, ⌘C is the terminal's
/// own shortcut and never reaches a pane at all. What belongs on the phone
/// depends entirely on what is listening.
public struct ShortcutProfile: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    /// What the pane's foreground process is called when this profile is the
    /// right guess. Empty for profiles that are only ever chosen by hand.
    public var commands: [String]
    /// The bundle identifiers of the Mac apps this profile is the right guess
    /// for. The app equivalent of `commands`: a pane is recognised by what is
    /// running in it, an app by what it is.
    public var bundleIDs: [String]
    public var actions: [ShortcutAction]

    public init(id: String, name: String, commands: [String] = [],
                bundleIDs: [String] = [], actions: [ShortcutAction]) {
        self.id = id
        self.name = name
        self.commands = commands
        self.bundleIDs = bundleIDs
        self.actions = actions
    }

    /// Decoded field by field, like everything else that crosses the wire: a
    /// discovered profile is sent from the Mac to the phone, and the two ends
    /// are not always the same build.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? "app"
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Mac app"
        commands = try c.decodeIfPresent([String].self, forKey: .commands) ?? []
        bundleIDs = try c.decodeIfPresent([String].self, forKey: .bundleIDs) ?? []
        actions = try c.decodeIfPresent([ShortcutAction].self, forKey: .actions) ?? []
    }
}

// MARK: - The built-in profiles

/// Drawn from each agent's own documentation and, where a version ships one,
/// from its own keymap. They are defaults rather than truths: these tools
/// rebind their own keys between releases, and both of the ones below let the
/// user rebind them too — so every one of these is editable per target.
public enum ShortcutProfiles {
    // Every row below is ordered by how often the button is pressed from a
    // phone, not by how the tool documents its keys. The row scrolls, and what
    // scrolls off the end is what you reach for once a week — so `stop` leads
    // an agent's set, `reload` leads a browser's, and `run` leads a shell's.
    //
    // `tab` and `delete` are the exception. Both are in these sets, and neither
    // appears on the row: they are typing keys, so the phone puts them on
    // either side of the composer where the typing is.
    public static let claudeCode = ShortcutProfile(
        id: "claude",
        name: "Claude Code",
        commands: ["claude"],
        actions: [
            ShortcutAction(id: "interrupt", label: "stop", symbol: "escape",
                           chord: KeyChord("escape"),
                           note: "Interrupts Claude, or closes a dialog."),
            ShortcutAction(id: "mode", label: "mode", symbol: "lock.rotation",
                           chord: KeyChord("tab", shift: true),
                           note: "Cycles permission modes — accept edits, plan, and back."),
            ShortcutAction(id: "rewind", label: "rewind", symbol: "arrow.uturn.backward",
                           chord: KeyChord("escape", repeatCount: 2),
                           note: "Escape twice: clears the input draft, or rewinds."),
            ShortcutAction(id: "tasks", label: "tasks", symbol: "checklist",
                           chord: KeyChord("t", control: true),
                           note: "Toggles Claude's task checklist.",
                           glyphOnly: true),
            ShortcutAction(id: "transcript", label: "log", symbol: "text.alignleft",
                           chord: KeyChord("o", control: true),
                           note: "Toggles the transcript viewer.",
                           glyphOnly: true),
            ShortcutAction(id: "clear-input", label: "clear", symbol: "delete.left",
                           chord: KeyChord("u", control: true),
                           note: "Throws away what is typed in the prompt without sending it.",
                           glyphOnly: true),
            ShortcutAction(id: "tab", label: "tab", symbol: "arrow.right.to.line",
                           chord: KeyChord("tab"),
                           note: "Completes what is being typed — a file path, a slash command."),
            ShortcutAction(id: "delete", label: "delete", symbol: "delete.backward",
                           chord: KeyChord("delete"),
                           note: "Backspace: rubs out the character before the cursor. "
                               + "Hold-to-repeat is a held key, which a pane cannot be sent — "
                               + "this is one character per tap."),
            ShortcutAction(id: "voice", label: "its mic", symbol: "waveform.badge.mic",
                           chord: KeyChord("space"),
                           note: "Claude Code's own dictation, through the Mac's microphone. "
                               + "It records while the key is held, so from a phone it needs "
                               + "`/voice tap` first, which makes one press start and stop it."),
            dictate,
        ])

    public static let codex = ShortcutProfile(
        id: "codex",
        name: "Codex",
        commands: ["codex"],
        actions: [
            ShortcutAction(id: "interrupt", label: "stop", symbol: "escape",
                           chord: KeyChord("escape"),
                           note: "Interrupts the current turn."),
            // The distinction Codex makes and nothing else does: a message
            // sent while a turn is running either redirects that turn or waits
            // behind it. Which one you meant is a decision, so it is two
            // buttons rather than one with a mode.
            ShortcutAction(id: "steer", label: "steer", symbol: "arrow.triangle.branch",
                           chord: KeyChord("enter"),
                           note: "Sends what is in the composer into the turn that is already "
                               + "running, redirecting it now."),
            ShortcutAction(id: "queue", label: "queue", symbol: "text.line.first.and.arrowtriangle.forward",
                           chord: KeyChord("tab"),
                           note: "Holds what is in the composer until the current turn finishes."),
            ShortcutAction(id: "mode", label: "mode", symbol: "lock.rotation",
                           chord: KeyChord("tab", shift: true),
                           note: "Cycles the permission mode."),
            ShortcutAction(id: "edit-previous", label: "edit last", symbol: "arrow.uturn.backward",
                           chord: KeyChord("escape", repeatCount: 2),
                           note: "Escape twice on an empty composer steps back to your last message."),
            ShortcutAction(id: "clear-input", label: "clear", symbol: "delete.left",
                           chord: KeyChord("u", control: true),
                           note: "Throws away what is typed in the composer without sending it.",
                           glyphOnly: true),
            // No plain `tab` button here, alone among the profiles: in Codex
            // that key is `queue`, which is on this row already. A second
            // button sending the same chord under a different name would be
            // two ways to do one thing, and a lie about one of them — which is
            // also why the composer offers no tab key for a Codex target.
            ShortcutAction(id: "delete", label: "delete", symbol: "delete.backward",
                           chord: KeyChord("delete"),
                           note: "Backspace: rubs out the character before the cursor."),
            // Left unbound on purpose. Codex 0.153 carries a `toggle_voice_mute`
            // action in its keymap, but the feature is behind a flag and the
            // build publishes no default key for it — and a guessed chord would
            // be a button that silently does nothing, which is worse than a
            // button that is not there. Unbound actions are listed in the
            // target's settings and kept off the phone's row.
            ShortcutAction(id: "voice", label: "its mic", symbol: "waveform.badge.mic",
                           chord: nil,
                           note: "Codex has a voice toggle in its keymap (toggle_voice_mute), "
                               + "but this version ships no default key for it. Bind one with "
                               + "/keymap on the Mac and it can be added here."),
            dictate,
        ])

    public static let shell = ShortcutProfile(
        id: "shell",
        name: "Shell",
        commands: ["zsh", "bash", "fish", "sh", "tmux", "nu"],
        actions: [
            ShortcutAction(id: "enter", label: "run", symbol: "return",
                           chord: KeyChord("enter"),
                           note: "Runs whatever is sitting at the prompt.",
                           glyphOnly: true),
            ShortcutAction(id: "interrupt", label: "^C", symbol: "stop.circle",
                           chord: KeyChord("c", control: true),
                           note: "Kills what is running."),
            ShortcutAction(id: "clear-input", label: "clear", symbol: "delete.left",
                           chord: KeyChord("u", control: true),
                           note: "Throws away what is typed at the prompt without running it.",
                           glyphOnly: true),
            ShortcutAction(id: "clear-screen", label: "wipe", symbol: "rectangle.dashed",
                           chord: KeyChord("l", control: true),
                           note: "Clears the screen. The scrollback is untouched."),
            ShortcutAction(id: "eof", label: "^D", symbol: "escape",
                           chord: KeyChord("d", control: true),
                           note: "End of input. At an empty prompt this closes the shell."),
            ShortcutAction(id: "tab", label: "tab", symbol: "arrow.right.to.line",
                           chord: KeyChord("tab"),
                           note: "Completes the path or command at the prompt."),
            ShortcutAction(id: "delete", label: "delete", symbol: "delete.backward",
                           chord: KeyChord("delete"),
                           note: "Backspace: rubs out the character before the cursor."),
            dictate,
        ])

    // MARK: - Windows rather than panes

    // Everything below is for a target that is an app: a window, where ⌘ keys
    // are the whole vocabulary and `tmux send-keys` has nothing to say. They
    // are picked by bundle identifier the way a pane's set is picked by its
    // foreground process — because "Mac app" was one set for every app on the
    // machine, and esc · return · ⌘C · ⌘V is a true description of all of them
    // and a useful description of none.
    //
    // Only shortcuts each of these apps ships by default are here. An app that
    // has been rebound, or one nobody listed, keeps the generic set rather than
    // getting a guessed chord that quietly does something else.

    /// The three every window understands. Written once because they are the
    /// same button whatever the window is — and drawn without their words,
    /// because they are also the three most-drawn icons on a computer.
    private static let escape = ShortcutAction(id: "escape", label: "esc", symbol: "escape",
                                               chord: KeyChord("escape"), glyphOnly: true)
    private static let copy = ShortcutAction(id: "copy", label: "copy", symbol: "doc.on.doc",
                                             chord: KeyChord("c", command: true), glyphOnly: true)
    private static let paste = ShortcutAction(id: "paste", label: "paste", symbol: "doc.on.clipboard",
                                              chord: KeyChord("v", command: true), glyphOnly: true)
    /// Close what is in front: a tab in a browser, a document in an editor, a
    /// window everywhere else.
    ///
    /// The curated fallback for an app whose menu bar Nimlet has not read. It
    /// keeps its word rather than standing on the glyph alone: an unlabelled
    /// ✕ in a row of keys reads as "dismiss this row", and what it actually
    /// does is close something on the Mac.
    ///
    /// ⌘Q is deliberately not here, and not in the menu table either. Closing
    /// leaves the app running and anything unsaved raises a dialog you can see
    /// in the mirror; quitting from a phone is a larger and less visible act,
    /// and it does not belong on a row a thumb can brush.
    private static let close = ShortcutAction(id: "close", label: "close", symbol: "xmark",
                                              chord: KeyChord("w", command: true),
                                              note: "Closes the front tab, document or window. "
                                                  + "The app keeps running.")
    /// The microphone is on the phone, so this button is the same one in every
    /// set and says the same thing about where the audio goes.
    private static let dictate = ShortcutAction(
        id: "dictate", label: "talk", symbol: "mic.fill", kind: .dictate,
        note: "This phone's microphone. Transcribed here; only text is sent.")

    /// For an app or frontmost target whose app nobody has described: a
    /// window, not a pane. ⌘ keys work here and only here.
    public static let app = ShortcutProfile(
        id: "app",
        name: "Mac app",
        actions: [
            ShortcutAction(id: "enter", label: "return", symbol: "return",
                           chord: KeyChord("enter"), glyphOnly: true),
            escape,
            copy,
            paste,
            ShortcutAction(id: "tab", label: "tab", symbol: "arrow.right.to.line",
                           chord: KeyChord("tab")),
            ShortcutAction(id: "delete", label: "delete", symbol: "delete.backward",
                           chord: KeyChord("delete")),
            close,
            dictate,
        ])

    /// The one every browser agrees on. Back, forward, reload and tab-switching
    /// are the same chords in Safari, Chrome, Firefox, Edge and the Chromium
    /// forks, which is why this is one set rather than five.
    public static let browser = ShortcutProfile(
        id: "browser",
        name: "Browser",
        bundleIDs: [
            "com.apple.safari",
            "com.apple.safaritechnologypreview",
            "com.google.chrome",
            "com.brave.browser",
            "com.microsoft.edgemac",
            "org.mozilla.firefox",
            "com.vivaldi.vivaldi",
            "com.operasoftware.opera",
            "com.kagi.kagimacos",
            "company.thebrowser.browser",
            "company.thebrowser.dia",
        ],
        actions: [
            // Reload first: it is what you press from the phone while looking
            // at a dev build on the monitor, over and over. The first four are
            // the browser toolbar's own icons, so they are drawn and not
            // written — which is what lets all four fit on the screen at once.
            ShortcutAction(id: "reload", label: "reload", symbol: "arrow.clockwise",
                           chord: KeyChord("r", command: true),
                           note: "Reloads the page.",
                           glyphOnly: true),
            ShortcutAction(id: "back", label: "back", symbol: "chevron.backward",
                           chord: KeyChord("[", command: true),
                           note: "Back one page.",
                           glyphOnly: true),
            ShortcutAction(id: "forward", label: "forward", symbol: "chevron.forward",
                           chord: KeyChord("]", command: true),
                           note: "Forward one page.",
                           glyphOnly: true),
            ShortcutAction(id: "find", label: "find", symbol: "magnifyingglass",
                           chord: KeyChord("f", command: true),
                           note: "Opens the find bar. Type into it from the composer.",
                           glyphOnly: true),
            ShortcutAction(id: "address", label: "address", symbol: "character.cursor.ibeam",
                           chord: KeyChord("l", command: true),
                           note: "Selects the address bar, so the next thing sent is a URL "
                               + "or a search."),
            // These two keep their words: one arrow pointing at a line is not
            // "the tab to the right" until somebody tells you, and there are
            // two of them side by side.
            ShortcutAction(id: "next-tab", label: "next tab", symbol: "arrow.right.to.line",
                           chord: KeyChord("tab", control: true),
                           note: "The tab to the right."),
            ShortcutAction(id: "previous-tab", label: "prev tab", symbol: "arrow.left.to.line",
                           chord: KeyChord("tab", control: true, shift: true),
                           note: "The tab to the left."),
            copy,
            paste,
            escape,
            close,
            dictate,
        ])

    /// VS Code and the editors that kept its keymap, plus Zed, which chose the
    /// same chords for all of these.
    public static let editor = ShortcutProfile(
        id: "editor",
        name: "Code editor",
        bundleIDs: [
            "com.microsoft.vscode",
            "com.microsoft.vscodeinsiders",
            "com.visualstudio.code.oss",
            "com.todesktop.230313mzl4w4u92",  // Cursor
            "com.exafunction.windsurf",
            "dev.zed.zed",
        ],
        actions: [
            ShortcutAction(id: "save", label: "save", symbol: "square.and.arrow.down",
                           chord: KeyChord("s", command: true),
                           note: "Saves the file in front.",
                           glyphOnly: true),
            ShortcutAction(id: "palette", label: "palette", symbol: "command",
                           chord: KeyChord("p", shift: true, command: true),
                           note: "The command palette. Everything else the editor can do is "
                               + "in here, typed."),
            // Three searches in one set: open-by-name, find here, find
            // everywhere. All three are magnifiers, so all three keep a word.
            ShortcutAction(id: "open-file", label: "open", symbol: "magnifyingglass",
                           chord: KeyChord("p", command: true),
                           note: "Go to file by name."),
            ShortcutAction(id: "find", label: "find", symbol: "text.magnifyingglass",
                           chord: KeyChord("f", command: true),
                           note: "Find in this file."),
            ShortcutAction(id: "find-in-files", label: "find all", symbol: "doc.text.magnifyingglass",
                           chord: KeyChord("f", shift: true, command: true),
                           note: "Find across the project."),
            ShortcutAction(id: "terminal", label: "terminal", symbol: "terminal",
                           chord: KeyChord("`", control: true),
                           note: "Shows or hides the built-in terminal.",
                           glyphOnly: true),
            ShortcutAction(id: "sidebar", label: "sidebar", symbol: "sidebar.left",
                           chord: KeyChord("b", command: true),
                           note: "Shows or hides the file tree, which is the width you want "
                               + "back when you are reading.",
                           glyphOnly: true),
            copy,
            paste,
            escape,
            close,
            dictate,
        ])

    /// Xcode, whose four most-pressed keys are all ⌘ and none of them reach a
    /// pane.
    public static let xcode = ShortcutProfile(
        id: "xcode",
        name: "Xcode",
        bundleIDs: ["com.apple.dt.xcode"],
        actions: [
            ShortcutAction(id: "run", label: "run", symbol: "play.fill",
                           chord: KeyChord("r", command: true),
                           note: "Build and run.",
                           glyphOnly: true),
            ShortcutAction(id: "stop", label: "stop", symbol: "stop.fill",
                           chord: KeyChord(".", command: true),
                           note: "Stops the running scheme.",
                           glyphOnly: true),
            ShortcutAction(id: "build", label: "build", symbol: "hammer",
                           chord: KeyChord("b", command: true),
                           note: "Builds without running.",
                           glyphOnly: true),
            ShortcutAction(id: "test", label: "test", symbol: "checkmark.diamond",
                           chord: KeyChord("u", command: true),
                           note: "Runs the test suite."),
            ShortcutAction(id: "open-quickly", label: "open", symbol: "magnifyingglass",
                           chord: KeyChord("o", shift: true, command: true),
                           note: "Open Quickly: a file or a symbol by name."),
            // A trash can is "throw this away", and what it throws away here is
            // the build folder rather than anything you wrote. Worth a word.
            ShortcutAction(id: "clean", label: "clean", symbol: "trash",
                           chord: KeyChord("k", shift: true, command: true),
                           note: "Cleans the build folder."),
            copy,
            paste,
            escape,
            close,
            dictate,
        ])

    /// A desktop app with a composer — Claude, ChatGPT — where the thing being
    /// sent is a sentence and the keys around it are about the conversation.
    public static let chat = ShortcutProfile(
        id: "chat",
        name: "Chat app",
        bundleIDs: ["com.anthropic.claudefordesktop", "com.openai.chat"],
        actions: [
            ShortcutAction(id: "enter", label: "send", symbol: "paperplane",
                           chord: KeyChord("enter"),
                           note: "Sends what is in the composer. Useful when this target is "
                               + "set not to press Return for you.",
                           glyphOnly: true),
            ShortcutAction(id: "new-chat", label: "new chat", symbol: "square.and.pencil",
                           chord: KeyChord("n", command: true),
                           note: "Starts a fresh conversation."),
            ShortcutAction(id: "newline", label: "newline", symbol: "arrow.turn.down.left",
                           chord: KeyChord("enter", shift: true),
                           note: "A line break inside the composer instead of a send.",
                           glyphOnly: true),
            copy,
            paste,
            escape,
            ShortcutAction(id: "delete", label: "delete", symbol: "delete.backward",
                           chord: KeyChord("delete"),
                           note: "Backspace: one character per tap."),
            close,
            dictate,
        ])

    /// A terminal emulator addressed as a window rather than through tmux.
    ///
    /// The keys are the shell's, because that is what is reading them — this is
    /// the same row as a pane's, posted at a window instead. It is the worse
    /// half of the deal and it is here for the terminal that is not running
    /// tmux: the window has to be in front, and the keystroke goes wherever the
    /// focus went. A tmux target needs neither.
    public static let terminalApp = ShortcutProfile(
        id: "terminal",
        name: "Terminal app",
        bundleIDs: [
            "com.apple.terminal",
            "com.googlecode.iterm2",
            "com.mitchellh.ghostty",
            "com.github.wez.wezterm",
            "net.kovidgoyal.kitty",
            "org.alacritty",
            "dev.warp.warp-stable",
            "co.zeit.hyper",
        ],
        actions: [
            ShortcutAction(id: "enter", label: "run", symbol: "return",
                           chord: KeyChord("enter"),
                           note: "Runs whatever is sitting at the prompt.",
                           glyphOnly: true),
            ShortcutAction(id: "interrupt", label: "^C", symbol: "stop.circle",
                           chord: KeyChord("c", control: true),
                           note: "Kills what is running in the front window."),
            ShortcutAction(id: "clear-input", label: "clear", symbol: "delete.left",
                           chord: KeyChord("u", control: true),
                           note: "Throws away what is typed at the prompt without running it.",
                           glyphOnly: true),
            ShortcutAction(id: "clear-screen", label: "wipe", symbol: "rectangle.dashed",
                           chord: KeyChord("l", control: true),
                           note: "Clears the screen. The scrollback is untouched."),
            ShortcutAction(id: "find", label: "find", symbol: "magnifyingglass",
                           chord: KeyChord("f", command: true),
                           note: "The terminal's own search over the scrollback.",
                           glyphOnly: true),
            ShortcutAction(id: "eof", label: "^D", symbol: "escape",
                           chord: KeyChord("d", control: true),
                           note: "End of input. At an empty prompt this closes the shell."),
            ShortcutAction(id: "tab", label: "tab", symbol: "arrow.right.to.line",
                           chord: KeyChord("tab"),
                           note: "Completes the path or command at the prompt."),
            ShortcutAction(id: "delete", label: "delete", symbol: "delete.backward",
                           chord: KeyChord("delete"),
                           note: "Backspace: rubs out the character before the cursor."),
            copy,
            paste,
            close,
            dictate,
        ])

    /// The sets for something running in a pane.
    public static let paneProfiles: [ShortcutProfile] = [claudeCode, codex, shell]

    /// The sets for something in a window. The generic one is first because it
    /// is the one that is always right, if never interesting.
    public static let appProfiles: [ShortcutProfile] = [app, browser, editor, xcode, chat, terminalApp]

    public static let all: [ShortcutProfile] = paneProfiles + appProfiles

    /// What a target of this kind may be pinned to.
    ///
    /// A pane cannot receive a ⌘ key and a window cannot receive `tmux
    /// send-keys`, so offering every set for every target was offering a way to
    /// pick a row of buttons that does nothing.
    public static func choices(for kind: NimletTarget.Kind) -> [ShortcutProfile] {
        kind == .tmux ? paneProfiles : appProfiles
    }

    public static func profile(id: String?) -> ShortcutProfile? {
        guard let id else { return nil }
        return all.first { $0.id == id }
    }

    /// The best guess from a pane's foreground process.
    ///
    /// A guess, and named as one: a pane running an agent through a wrapper
    /// reports the wrapper, and every one of these tools can be started under a
    /// different name. Whatever it returns can be overridden per target.
    public static func guess(forCommand command: String?) -> ShortcutProfile {
        guard let command, !command.isEmpty else { return shell }
        let name = command.lowercased()
        for candidate in paneProfiles where candidate.commands.contains(name) {
            return candidate
        }
        return shell
    }

    /// The best guess from an app's bundle identifier.
    ///
    /// Falls back to the generic set rather than to the nearest-looking one: a
    /// browser's ⌘L in an app that uses it for something else is a button that
    /// does the wrong thing silently, which is worse than a plain one.
    public static func guess(forBundleID bundleID: String?) -> ShortcutProfile {
        guard let bundleID, !bundleID.isEmpty else { return app }
        let id = bundleID.lowercased()
        for candidate in appProfiles where candidate.bundleIDs.contains(id) {
            return candidate
        }
        // A nightly, a beta or a channel build is the same app with a suffix on
        // its identifier — `com.google.chrome.canary`, `dev.zed.zed-preview` —
        // and the keymap is the same too. Without this, the build somebody
        // actually runs is the one that gets the plainest possible row.
        for candidate in appProfiles {
            let matches = candidate.bundleIDs.contains {
                id.hasPrefix($0 + ".") || id.hasPrefix($0 + "-")
            }
            if matches { return candidate }
        }
        return app
    }

    /// The profile a target uses: what it was given, or what its kind implies.
    public static func resolved(for target: NimletTarget, paneCommand: String? = nil) -> ShortcutProfile {
        if let chosen = profile(id: target.profileID) { return chosen }
        switch target.kind {
        case .tmux: return guess(forCommand: paneCommand)
        case .app: return guess(forBundleID: target.bundleID)
        // Whatever has focus could be anything at all, so it gets the set that
        // is true of every window and nothing more.
        case .frontmost: return app
        }
    }
}
