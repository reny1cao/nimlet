import Foundation

/// One item read out of an app's own menu bar: what it is called, which menu it
/// hangs under, and the key it publishes for itself.
///
/// The Mac reads these with the Accessibility API it already holds a grant for.
/// This type is the seam between that walk and the ranking below, which is why
/// it is here rather than in the host: the ranking is the part with opinions in
/// it, and opinions are worth testing.
public struct MenuCommand: Codable, Sendable, Hashable {
    /// The top-level menu it was found under — "File", "Product", "History".
    public var menu: String
    /// The item's own title, exactly as the menu bar spells it.
    public var title: String
    public var chord: KeyChord

    public init(menu: String, title: String, chord: KeyChord) {
        self.menu = menu
        self.title = title
        self.chord = chord
    }

    /// Lowercased, with the trailing ellipsis a menu puts on anything that
    /// opens a dialog, and with the runs of whitespace flattened.
    public var normalisedTitle: String {
        var text = title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        for suffix in ["…", "..."] where text.hasSuffix(suffix) {
            text = String(text.dropLast(suffix.count))
        }
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

/// Turns a menu bar into a row of buttons.
///
/// A menu bar holds two hundred shortcuts and the row holds about ten, so the
/// question is not how to read them — it is which ten. Ranking them by how
/// common or how deep they are produces a plausible row of the wrong things:
/// Print, Hide, Minimise and Select All all rank well and none of them is why
/// somebody picked up their phone.
///
/// So the *what* is curated and the *which key* is discovered. The list below
/// is the things worth a button on a phone, in the order they are worth it;
/// each one names the titles that mean it, and the chord comes from the app
/// itself. That is what a hardcoded table cannot do: an app with rebound keys
/// reports its own, and an app nobody ever listed still yields save, find, new
/// and undo.
public enum MenuVocabulary {

    /// One thing worth a button, and the menu titles that mean it.
    public struct Want: Sendable {
        public var id: String
        public var label: String
        public var symbol: String
        /// Normalised titles, best spelling first.
        public var titles: [String]
        /// The lowercased top-level menus to look in *first*. Empty means no
        /// preference.
        ///
        /// Not decoration: Xcode has an item called "Find" in its View menu and
        /// it is the find *navigator*, ⌘4, while the one that opens the find
        /// bar lives under Find. Without a preference the phone's find button
        /// opened a sidebar.
        ///
        /// A preference rather than a filter, because a menu bar is localised
        /// and this list is in English. On a Mac running in Chinese the Edit
        /// menu is called 编辑, every want that named "edit" matched nothing,
        /// and the whole feature quietly did nothing for anyone not working in
        /// English.
        public var menus: [String]
        /// Whether the button is drawn as its symbol alone. Same rule as the
        /// curated sets: only where nobody has to learn the glyph, and never
        /// where this list can put a near-twin beside it — which is why the
        /// three magnifiers and the two tab arrows all keep their words.
        public var glyphOnly: Bool
        /// Whether a longer title may match — "Undo Typing" for undo, "New
        /// Session" for new.
        ///
        /// Off by default, and that default is the important half: with it on
        /// for everything, Chrome's save became "Save Page As…" and Xcode's
        /// reload became "Reload Organizer". A want opts in only where the app
        /// genuinely appends to the word.
        public var matchesLongerTitles: Bool

        public init(id: String, label: String, symbol: String, titles: [String],
                    menus: [String] = [], matchesLongerTitles: Bool = false,
                    glyphOnly: Bool = false) {
            self.id = id
            self.label = label
            self.symbol = symbol
            self.titles = titles
            self.menus = menus
            self.matchesLongerTitles = matchesLongerTitles
            self.glyphOnly = glyphOnly
        }
    }

    /// Order is priority: the row is filled from the top and stops at `limit`.
    public static let wants: [Want] = [
        // What you press while looking at the monitor rather than the phone.
        Want(id: "run", label: "run", symbol: "play.fill",
             titles: ["run", "build and run", "build & run", "start debugging",
                      "run without debugging", "run project", "run app"],
             menus: ["product", "run", "build", "debug", "terminal", "tasks", "go"], glyphOnly: true),
        Want(id: "stop", label: "stop", symbol: "stop.fill",
             titles: ["stop", "stop debugging", "cancel build", "stop build", "stop task"],
             menus: ["product", "run", "build", "debug", "terminal", "tasks", "view"], glyphOnly: true),
        Want(id: "build", label: "build", symbol: "hammer",
             titles: ["build", "build project", "build for running", "compile"],
             menus: ["product", "run", "build", "terminal", "tasks"], glyphOnly: true),
        Want(id: "test", label: "test", symbol: "checkmark.diamond",
             titles: ["test", "run tests", "run all tests", "test project"],
             menus: ["product", "run", "build", "debug", "terminal", "tasks"]),
        Want(id: "reload", label: "reload", symbol: "arrow.clockwise",
             titles: ["reload page", "reload this page", "reload", "refresh",
                      "reload page from origin"],
             menus: ["view", "history", "go", "file"], glyphOnly: true),
        Want(id: "back", label: "back", symbol: "chevron.backward",
             titles: ["back", "go back", "show previous page"],
             menus: ["history", "go", "navigate", "view"], glyphOnly: true),
        Want(id: "forward", label: "forward", symbol: "chevron.forward",
             titles: ["forward", "go forward", "show next page"],
             menus: ["history", "go", "navigate", "view"], glyphOnly: true),
        Want(id: "save", label: "save", symbol: "square.and.arrow.down",
             titles: ["save", "save file"], menus: ["file"], glyphOnly: true),
        Want(id: "find", label: "find", symbol: "magnifyingglass",
             titles: ["find", "find in page", "search"],
             menus: ["edit", "find", "search"]),
        Want(id: "find-all", label: "find all", symbol: "doc.text.magnifyingglass",
             titles: ["find in files", "find in project", "find in folder",
                      "find in workspace", "search in files", "find in all projects"],
             menus: ["edit", "find", "search", "navigate", "go"]),
        Want(id: "open-quickly", label: "open", symbol: "doc.text.magnifyingglass",
             titles: ["open quickly", "go to file", "quick open", "open file quickly",
                      "go to anything"],
             menus: ["file", "go", "navigate", "edit"]),
        Want(id: "palette", label: "palette", symbol: "command",
             titles: ["command palette", "show command palette", "show all commands"]),
        Want(id: "terminal", label: "terminal", symbol: "terminal",
             titles: ["toggle terminal", "terminal", "show terminal", "new terminal"],
             menus: ["view", "terminal", "window", "shell", "tools"], glyphOnly: true),
        Want(id: "sidebar", label: "sidebar", symbol: "sidebar.left",
             titles: ["toggle sidebar", "show sidebar", "hide sidebar",
                      "toggle primary side bar", "toggle left dock", "show navigator",
                      "hide navigator"],
             menus: ["view", "window", "appearance"], glyphOnly: true),
        Want(id: "new", label: "new", symbol: "square.and.pencil",
             titles: ["new tab", "new chat", "new conversation", "new", "new file",
                      "new document", "new window"],
             menus: ["file", "shell", "chat", "session"], matchesLongerTitles: true),
        Want(id: "next-tab", label: "next tab", symbol: "arrow.right.to.line",
             titles: ["show next tab", "select next tab", "next tab", "go to next tab"],
             menus: ["window", "tab", "view", "shell", "go"]),
        Want(id: "previous-tab", label: "prev tab", symbol: "arrow.left.to.line",
             titles: ["show previous tab", "select previous tab", "previous tab",
                      "go to previous tab"],
             menus: ["window", "tab", "view", "shell", "go"]),
        Want(id: "address", label: "address", symbol: "character.cursor.ibeam",
             titles: ["open location", "address bar", "focus address bar"],
             menus: ["file", "view", "go", "edit"]),
        Want(id: "undo", label: "undo", symbol: "arrow.uturn.backward",
             titles: ["undo"], menus: ["edit"], matchesLongerTitles: true),
        Want(id: "redo", label: "redo", symbol: "arrow.uturn.forward",
             titles: ["redo"], menus: ["edit"], matchesLongerTitles: true),
        // Last, so they fill what is left rather than crowding out the verbs.
        Want(id: "copy", label: "copy", symbol: "doc.on.doc",
             titles: ["copy"], menus: ["edit"], glyphOnly: true),
        Want(id: "paste", label: "paste", symbol: "doc.on.clipboard",
             titles: ["paste"], menus: ["edit"], glyphOnly: true),
        // Closing what is in front — a tab, a document, a window.
        //
        // Discovered rather than assumed, which is the whole reason this table
        // exists: ⌘W is the answer in most apps and it is not the answer in
        // all of them, and an app that rebound it reports its own chord here.
        // The titles are only the ones that mean *this window or document* —
        // "Close All", "Close Others" and "Close Window Group" are different
        // and larger acts, and `matchesLongerTitles` stays off so none of them
        // can match.
        //
        // Kept away from `quit`, which is not in this table at all. Closing is
        // reversible in the way that matters — the app is still there, the
        // document reopens, and anything unsaved raises a dialog you can see in
        // the mirror. Quitting from a phone is a different decision and does
        // not belong on a row you can brush with a thumb.
        Want(id: "close", label: "close", symbol: "xmark",
             titles: ["close", "close tab", "close window", "close editor"],
             menus: ["file", "window"], glyphOnly: true),
    ]

    /// How many keys a discovered row may hold. The row scrolls, but a row you
    /// have to scroll to read is one you stop reading.
    public static let limit = 12

    /// Below this, what was read is not worth showing: an app whose menu bar
    /// yielded two recognisable things is better served by the curated set,
    /// which at least knows what ⌘C does.
    public static let minimumUseful = 3

    /// The row for one app, or nil when its menus had too little in them.
    ///
    /// `commands` arrives in menu-bar order — File, Edit, View and so on, left
    /// to right — and that order breaks ties: a title that appears twice is
    /// taken from the menu it appears in first.
    public static func profile(appNamed name: String,
                               bundleID: String,
                               from commands: [MenuCommand]) -> ShortcutProfile? {
        let usable = commands.filter { isPressable($0.chord) }
        var actions: [ShortcutAction] = []
        var usedChords: Set<KeyChord> = []

        for want in wants {
            guard actions.count < limit else { break }
            guard let command = match(want, in: usable) else { continue }
            // Two buttons sending one chord under two names is a lie about one
            // of them — and a menu bar offers plenty of chances: "Find" and
            // "Search" are one key in an app that has both.
            guard usedChords.insert(command.chord).inserted else { continue }
            actions.append(ShortcutAction(id: want.id,
                                          label: want.label,
                                          symbol: want.symbol,
                                          chord: command.chord,
                                          note: "\(possessive(name)) own key for "
                                              + "\(command.menu) ▸ \(command.title).",
                                          glyphOnly: want.glyphOnly))
        }

        guard actions.count >= minimumUseful else { return nil }
        // The two keys that flank the composer rather than joining the row.
        // No menu bar publishes them — they carry no modifier, and a bare key
        // read out of a menu is a misread — but every window that takes typing
        // takes these, and a discovered set is for an app you are typing at.
        // They are counted against nothing: the row leaves them out, so they
        // cannot crowd a verb off the end of it.
        actions.append(ShortcutAction(id: "tab", label: "tab", symbol: "arrow.right.to.line",
                                      chord: KeyChord("tab"),
                                      note: "Tab: the next field, or a completion."))
        actions.append(ShortcutAction(id: "delete", label: "delete", symbol: "delete.backward",
                                      chord: KeyChord("delete"),
                                      note: "Backspace: one character per tap."))
        actions.append(ShortcutAction(id: "dictate", label: "talk", symbol: "mic.fill",
                                      kind: .dictate,
                                      note: "This phone's microphone. Transcribed here; "
                                          + "only text is sent."))
        return ShortcutProfile(id: profileID(forBundleID: bundleID),
                               name: "\(name) menus",
                               actions: actions)
    }

    /// "Xcode's", "Notes'". Every note on every button carries it, so the one
    /// app whose name ends in an s should not read like a typo.
    private static func possessive(_ name: String) -> String {
        name.lowercased().hasSuffix("s") ? name + "'" : name + "'s"
    }

    /// Namespaced so it can never collide with a curated set's id, and so a
    /// glance at a stored profile says where it came from.
    public static func profileID(forBundleID bundleID: String) -> String {
        "menu:" + bundleID.lowercased()
    }

    public static func isDiscovered(profileID: String?) -> Bool {
        profileID?.hasPrefix("menu:") ?? false
    }

    /// Exact titles first, across the menus the want allows, and only then —
    /// and only for a want that asked for it — the longer ones.
    ///
    /// The order between the two passes matters: "Save" must not be allowed to
    /// find "Save As…" in an app that has both, and it never will, because the
    /// exact pass runs first over every menu before the longer one runs at all.
    private static func match(_ want: Want, in commands: [MenuCommand]) -> MenuCommand? {
        let preferred = commands.filter { want.menus.contains($0.menu.lowercased()) }
        // Four passes, narrowest first. The preferred menus are exhausted
        // before the rest of the bar is looked at, which is what keeps Xcode's
        // find on ⌘F — and the rest of the bar is looked at at all, which is
        // what makes a menu bar in another language work.
        for candidates in [preferred, commands] {
            for title in want.titles {
                if let hit = candidates.first(where: { $0.normalisedTitle == title }) { return hit }
            }
        }
        guard want.matchesLongerTitles else { return nil }
        for candidates in [preferred, commands] {
            for title in want.titles {
                if let hit = candidates.first(where: { $0.normalisedTitle.hasPrefix(title + " ") }) {
                    return hit
                }
            }
        }
        return nil
    }

    /// Whether a chord read from a menu is one worth pressing.
    ///
    /// A menu shortcut carries a modifier. One that arrives without any is a
    /// misread — some apps publish an accelerator the Accessibility API cannot
    /// describe, and it comes back as a bare letter — and a bare letter posted
    /// at a window does not run a command, it types. A function key is the one
    /// real exception: F5 is a whole shortcut by itself.
    static func isPressable(_ chord: KeyChord) -> Bool {
        if chord.command || chord.control || chord.option { return true }
        return KeyChord.functionKeyNumber(chord.key) != nil
    }
}
