import AppKit
import ApplicationServices

/// Reads an app's own menu bar, so its buttons can be the keys it actually
/// publishes rather than the keys somebody wrote down once.
///
/// The curated sets in `ShortcutProfiles` are right about the apps they name
/// and blind to everything else: an app whose keys have been rebound reports
/// one thing and gets sent another, and an app nobody listed gets esc · return
/// · ⌘C · ⌘V. A menu bar answers both cases, and Nimlet already holds the
/// Accessibility grant it takes to read one — the same grant it uses to press
/// the keys afterwards.
///
/// Nothing here is a guess: every chord comes from the app, and an item the
/// app publishes no key for is not offered.
enum MenuScanner {

    /// What came back, or why nothing did.
    enum Outcome {
        case read(appName: String, commands: [MenuCommand])
        case notRunning
        case unreadable(String)
    }

    /// AX attribute names, spelled out because the `kAX*` constants are C
    /// macros and are not imported into Swift.
    private enum Attribute {
        static let children = "AXChildren"
        static let title = "AXTitle"
        static let menuBar = "AXMenuBar"
        static let cmdChar = "AXMenuItemCmdChar"
        static let cmdVirtualKey = "AXMenuItemCmdVirtualKey"
        static let cmdModifiers = "AXMenuItemCmdModifiers"
    }

    /// A menu bar is a tree and some apps build a deep one. Three levels reach
    /// "Product ▸ Perform Action ▸ …" and stop well short of the Services menu,
    /// which is every app on the machine and none of this one.
    private static let maxDepth = 3
    /// Enough for an app with a large menu bar — Xcode's is about 700 items —
    /// and a hard stop for one whose menus are generated.
    private static let maxItems = 1_200
    /// Per-message, and then again for the whole walk. A wedged app must not be
    /// able to hold a queue.
    private static let messageTimeout: Float = 1.5
    private static let walkDeadline: TimeInterval = 6

    /// Walks the menu bar of the running app with this bundle id.
    ///
    /// Blocking, and deliberately not on main: every `AXUIElementCopyAttribute`
    /// is a round trip to another process, and an app that is busy will take
    /// its time answering.
    static func scan(bundleID: String) -> Outcome {
        guard AXIsProcessTrusted() else {
            return .unreadable("Nimlet needs Accessibility to read another app's menus")
        }
        let running = onMain {
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        }
        guard let running, let appName = onMain({ running.localizedName }) else {
            return .notRunning
        }
        let pid = running.processIdentifier

        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, messageTimeout)
        guard let bar = element(app, Attribute.menuBar) else {
            return .unreadable("\(appName) publishes no menu bar Nimlet can read")
        }

        var commands: [MenuCommand] = []
        var visited = 0
        let deadline = Date().addingTimeInterval(walkDeadline)
        // The first bar item is the Apple menu, which belongs to the system
        // rather than to the app and is the same everywhere.
        for barItem in children(bar).dropFirst() {
            guard let menuName = string(barItem, Attribute.title), !menuName.isEmpty else { continue }
            for menu in children(barItem) {
                walk(menu, menu: menuName, depth: 1,
                     into: &commands, visited: &visited, deadline: deadline)
            }
            if visited >= maxItems || Date() > deadline { break }
        }
        return .read(appName: appName, commands: commands)
    }

    /// Depth-first, in the order the menu is drawn, because that order is what
    /// breaks ties when a title appears twice.
    private static func walk(_ menu: AXUIElement,
                             menu menuName: String,
                             depth: Int,
                             into commands: inout [MenuCommand],
                             visited: inout Int,
                             deadline: Date) {
        guard depth <= maxDepth, visited < maxItems, Date() <= deadline else { return }
        for item in children(menu) {
            visited += 1
            guard visited < maxItems, Date() <= deadline else { return }
            if let title = string(item, Attribute.title), !title.isEmpty,
               let chord = chord(of: item) {
                commands.append(MenuCommand(menu: menuName, title: title, chord: chord))
            }
            // A submenu is one child of the item, and its own children are the
            // items. Depth counts menus rather than elements, so this is one
            // level down and not two.
            for submenu in children(item) {
                walk(submenu, menu: menuName, depth: depth + 1,
                     into: &commands, visited: &visited, deadline: deadline)
            }
        }
    }

    /// The chord a menu item publishes, or nil when it publishes none.
    private static func chord(of item: AXUIElement) -> KeyChord? {
        let character = string(item, Attribute.cmdChar)
        let virtualKey = number(item, Attribute.cmdVirtualKey)
        guard let key = keyToken(character: character, virtualKey: virtualKey) else { return nil }

        // Carbon's menu modifier mask, which is what AX reports: the bits say
        // what is *added* to Command, and the fourth one says Command itself is
        // absent. So zero means ⌘ alone — the common case — and a naive read of
        // this field as "no modifiers" produces a row of bare letters that type
        // into the document instead of driving it.
        // The mask is the whole truth about the modifiers, and the character's
        // case says nothing: a menu bar reports ⌘N as the character "N", so
        // reading an uppercase letter as a shift — which looks like exactly the
        // right thing to do — turns every ordinary shortcut in the app into a
        // shifted one. Finder's New Finder Window came out as ⇧⌘N.
        let mask = number(item, Attribute.cmdModifiers) ?? 0
        let shift = mask & 1 != 0
        let option = mask & 2 != 0
        let control = mask & 4 != 0
        let command = mask & 8 == 0
        return KeyChord(key, control: control, option: option, shift: shift, command: command)
    }

    /// The name Nimlet knows the key by.
    ///
    /// The character comes first because it is what most items carry; the
    /// virtual key is for the ones with nothing printable — F5, an arrow, Home.
    /// A control character means one of the keys a menu draws as a glyph.
    private static func keyToken(character: String?, virtualKey: Int?) -> String? {
        if let character, let scalar = character.unicodeScalars.first,
           character.unicodeScalars.count == 1 {
            switch scalar.value {
            case 0x1B: return "escape"
            case 0x0D, 0x03: return "enter"
            case 0x09: return "tab"
            case 0x08, 0x7F: return "delete"
            case 0x20: return "space"
            default:
                let lowered = character.lowercased()
                if KeyChord.keyCodes[lowered] != nil { return lowered }
            }
        }
        guard let virtualKey, let code = UInt16(exactly: virtualKey) else { return nil }
        return KeyChord.key(forVirtualKey: code)
    }

    // MARK: - AX plumbing

    private static func copy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var out: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &out) == .success else {
            return nil
        }
        return out
    }

    private static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let raw = copy(element, attribute),
              CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return (raw as! AXUIElement)
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        copy(element, Attribute.children) as? [AXUIElement] ?? []
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        copy(element, attribute) as? String
    }

    private static func number(_ element: AXUIElement, _ attribute: String) -> Int? {
        (copy(element, attribute) as? NSNumber)?.intValue
    }
}

/// What the Mac has already read, so the phone asking twice costs one round
/// trip rather than two menu walks.
///
/// Keyed by bundle id and pinned to the process it was read from: an app that
/// has been quit and relaunched may well have been updated, and an app whose
/// menus were read while a document was closed publishes different ones now.
final class MenuCatalog {
    static let shared = MenuCatalog()

    private struct Entry {
        var payload: MenuProfilePayload
        var pid: pid_t
        var readAt: Date
    }

    /// Long enough that focusing a target repeatedly costs nothing, short
    /// enough that rebinding a key and coming back works without a relaunch.
    private static let lifetime: TimeInterval = 300

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    /// Blocking: walks the menu bar unless a fresh answer is already held.
    /// Callers are on the host's own queues, never on main.
    func profile(forBundleID bundleID: String, refresh: Bool = false) -> MenuProfilePayload {
        let key = bundleID.lowercased()
        let pid = onMain {
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .first?.processIdentifier
        }

        if !refresh, let entry = held(key), entry.pid == (pid ?? -1),
           Date().timeIntervalSince(entry.readAt) < Self.lifetime {
            return entry.payload
        }

        let payload = Self.build(bundleID: bundleID)
        lock.withLock {
            entries[key] = Entry(payload: payload, pid: pid ?? -1, readAt: Date())
        }
        return payload
    }

    private func held(_ key: String) -> Entry? { lock.withLock { entries[key] } }

    private static func build(bundleID: String) -> MenuProfilePayload {
        switch MenuScanner.scan(bundleID: bundleID) {
        case .notRunning:
            return MenuProfilePayload(bundleID: bundleID, outcome: .notRunning,
                                      note: "Not running, so it has no menus to read yet.")
        case .unreadable(let why):
            return MenuProfilePayload(bundleID: bundleID, outcome: .unreadable, note: why)
        case .read(let appName, let commands):
            guard let profile = MenuVocabulary.profile(appNamed: appName,
                                                       bundleID: bundleID,
                                                       from: commands) else {
                return MenuProfilePayload(
                    bundleID: bundleID, outcome: .nothingUseful,
                    note: "\(appName) publishes \(commands.count) shortcut"
                        + "\(commands.count == 1 ? "" : "s"), and too few of them are things "
                        + "worth a button.")
            }
            miceLog.info("""
                read \(commands.count, privacy: .public) shortcuts from \
                \(bundleID, privacy: .public), kept \(profile.actions.count, privacy: .public)
                """)
            return MenuProfilePayload(
                bundleID: bundleID, outcome: .read, profile: profile,
                note: "Read from \(appName)'s own menu bar — \(commands.count) shortcuts, "
                    + "\(profile.actions.count - 1) of them worth a button.")
        }
    }
}
