import XCTest
@testable import NimletTests

/// Turning a menu bar into a row of buttons.
///
/// Every menu bar below is a real one, trimmed: they were read off the running
/// apps with the Accessibility walk in `MenuScanner`, and each test named after
/// a mistake is a row this code actually produced before it was fixed.
final class MenuVocabularyTests: XCTestCase {

    private func command(_ menu: String, _ title: String, _ chord: KeyChord) -> MenuCommand {
        MenuCommand(menu: menu, title: title, chord: chord)
    }

    /// Xcode, in menu-bar order and cut to what matters here.
    private var xcode: [MenuCommand] {
        [
            command("File", "Save", KeyChord("s", command: true)),
            command("File", "Save As…", KeyChord("s", shift: true, command: true)),
            command("File", "Open Quickly…", KeyChord("o", shift: true, command: true)),
            command("Edit", "Undo Typing", KeyChord("z", command: true)),
            command("Edit", "Redo", KeyChord("z", shift: true, command: true)),
            command("Edit", "Copy", KeyChord("c", command: true)),
            command("Find", "Find…", KeyChord("f", command: true)),
            command("Find", "Find in Workspace", KeyChord("f", shift: true, command: true)),
            command("View", "Find", KeyChord("4", command: true)),
            command("View", "Reload Organizer", KeyChord("r", control: true)),
            command("Product", "Run", KeyChord("r", command: true)),
            command("Product", "Stop", KeyChord(".", command: true)),
            command("Product", "Build", KeyChord("b", command: true)),
            command("Product", "Test", KeyChord("u", command: true)),
        ]
    }

    private func profile(_ commands: [MenuCommand], app: String = "Xcode") -> ShortcutProfile? {
        MenuVocabulary.profile(appNamed: app, bundleID: "com.example.\(app)", from: commands)
    }

    private func chord(_ profile: ShortcutProfile?, _ id: String) -> KeyChord? {
        profile?.actions.first { $0.id == id }?.chord
    }

    func testTheKeysComeFromTheAppRatherThanFromAList() {
        let built = profile(xcode)
        XCTAssertEqual(chord(built, "run"), KeyChord("r", command: true))
        XCTAssertEqual(chord(built, "stop"), KeyChord(".", command: true))
        XCTAssertEqual(chord(built, "build"), KeyChord("b", command: true))
        XCTAssertEqual(chord(built, "test"), KeyChord("u", command: true))
    }

    func testARebindingIsFollowedRatherThanOverruled() {
        // The whole reason for reading a menu bar: somebody who moved Run to
        // ⌃⌥R gets a run button that presses ⌃⌥R.
        var rebound = xcode
        rebound[10] = command("Product", "Run", KeyChord("r", control: true, option: true))
        XCTAssertEqual(chord(profile(rebound), "run"), KeyChord("r", control: true, option: true))
    }

    func testFindIsTheEditorsFindAndNotXcodesFindNavigator() {
        // Xcode's View menu has an item called "Find" and it is ⌘4, which opens
        // a sidebar. The find button on the phone opened that sidebar until a
        // want could say which menus it may be taken from.
        XCTAssertEqual(chord(profile(xcode), "find"), KeyChord("f", command: true))
        XCTAssertEqual(chord(profile(xcode), "find-all"), KeyChord("f", shift: true, command: true))
    }

    func testALongerTitleIsOnlyMatchedWhereAnAppReallyAppendsToTheWord() {
        // "Undo Typing" is undo. "Save Page As…" is not save, and "Reload
        // Organizer" is not reload — both were on the row when every want
        // matched longer titles.
        XCTAssertEqual(chord(profile(xcode), "undo"), KeyChord("z", command: true))
        XCTAssertNil(chord(profile(xcode), "reload"))

        let chrome = [
            command("File", "Save Page As…", KeyChord("s", command: true)),
            command("Edit", "Undo", KeyChord("z", command: true)),
            command("Edit", "Copy", KeyChord("c", command: true)),
            command("Edit", "Paste", KeyChord("v", command: true)),
        ]
        XCTAssertNil(chord(profile(chrome, app: "Chrome"), "save"))
    }

    func testAnExactTitleWinsOverALongerOneWhereverItIsInTheMenuBar() {
        // Save As… comes first here on purpose: the exact pass has to finish
        // over the whole menu bar before the longer pass starts, or an app that
        // has both loses the one you meant.
        let commands = [
            command("File", "New Window", KeyChord("n", shift: true, command: true)),
            command("File", "New Tab", KeyChord("t", command: true)),
            command("Edit", "Undo", KeyChord("z", command: true)),
            command("Edit", "Copy", KeyChord("c", command: true)),
        ]
        XCTAssertEqual(chord(profile(commands, app: "Safari"), "new"), KeyChord("t", command: true))
    }

    func testTwoButtonsAreNeverTheSameKeyUnderTwoNames() {
        // An app with both "Find" and "Search" on one key would otherwise get
        // two chips that do one thing, and a lie about one of them.
        let commands = [
            command("Edit", "Find", KeyChord("f", command: true)),
            command("Edit", "Search", KeyChord("f", command: true)),
            command("Edit", "Undo", KeyChord("z", command: true)),
            command("Edit", "Copy", KeyChord("c", command: true)),
        ]
        let built = profile(commands, app: "Thing")
        let chords = built?.actions.compactMap(\.chord) ?? []
        XCTAssertEqual(Set(chords).count, chords.count)
    }

    func testARowIsCappedAndKeepsTheVerbsRatherThanTheEdits() {
        // Copy and paste match in every app on the machine, so if they could
        // crowd out run, build and test the row would be the same everywhere.
        //
        // The cap is on what came out of the menu bar. Tab, Backspace and the
        // microphone are added afterwards and are not on the row at all — the
        // first two flank the composer, the third is the composer's own button
        // — so they are counted out of it here.
        let built = profile(xcode)
        let discovered = built?.actions.filter { !["tab", "delete", "dictate"].contains($0.id) } ?? []
        XCTAssertLessThanOrEqual(discovered.count, MenuVocabulary.limit)
        let ids = built?.actions.map(\.id) ?? []
        XCTAssertLessThan(ids.firstIndex(of: "run") ?? .max, ids.firstIndex(of: "copy") ?? .max)
    }

    func testEveryDiscoveredRowCanBeTypedAt() {
        // No menu publishes Tab or Backspace — they carry no modifier, and the
        // reader throws away bare keys as misreads — but a window you are
        // sending sentences to is one you also need to correct a character in.
        let ids = profile(xcode)?.actions.map(\.id) ?? []
        XCTAssertTrue(ids.contains("tab"))
        XCTAssertTrue(ids.contains("delete"))
    }

    func testAMenuBarWithNothingInItIsRefusedRatherThanShown() {
        // Two recognisable items is not a set. Falling back to the curated one
        // beats a row with a single Paste on it.
        XCTAssertNil(profile([command("Edit", "Paste", KeyChord("v", command: true))],
                             app: "Quiet"))
        XCTAssertNil(profile([], app: "Silent"))
    }

    func testEveryDiscoveredRowCanStillBeTalkedTo() {
        let built = profile(xcode)
        XCTAssertEqual(built?.actions.last?.kind, .dictate)
    }

    func testEveryDiscoveredKeyIsOneTheMacCanActuallyPress() {
        for action in profile(xcode)?.actions ?? [] where action.kind == .key {
            XCTAssertNotNil(action.chord?.macVirtualKey, action.label)
        }
    }

    func testAButtonSaysWhichMenuItemItCameFrom() {
        // "Why is this ⌘." is answered on the button's own settings row rather
        // than by the user going to look in the app.
        let note = profile(xcode)?.actions.first { $0.id == "stop" }?.note
        XCTAssertEqual(note, "Xcode's own key for Product ▸ Stop.")
        // And an app whose name ends in an s does not read like a typo.
        let notes = [command("Edit", "Undo", KeyChord("z", command: true)),
                     command("Edit", "Copy", KeyChord("c", command: true)),
                     command("Edit", "Paste", KeyChord("v", command: true))]
        XCTAssertEqual(profile(notes, app: "Notes")?.actions.first?.note,
                       "Notes' own key for Edit ▸ Undo.")
    }

    func testATitleIsMatchedThroughTheEllipsisAndTheCase() {
        // A menu spells anything that opens a dialog with a trailing ellipsis,
        // and it is a single character rather than three dots about half the
        // time.
        XCTAssertEqual(command("Edit", "Find…", KeyChord("f")).normalisedTitle, "find")
        XCTAssertEqual(command("Edit", "Find...", KeyChord("f")).normalisedTitle, "find")
        XCTAssertEqual(command("Edit", "  Find  in   Page ", KeyChord("f")).normalisedTitle,
                       "find in page")
    }

    func testAMenuBarInAnotherLanguageStillYieldsARow() {
        // Read off a real app on a Mac running in Chinese: the menus are 编辑
        // and 视图, and the want list is in English. Scoping a want to the Edit
        // menu by name matched nothing, so the whole feature did nothing for
        // anyone not working in English — the menus are a preference now, and
        // the rest of the bar is searched after them.
        let localised = [
            command("Sysbuilder.AI", "Reload", KeyChord("r", command: true)),
            command("编辑", "Undo", KeyChord("z", command: true)),
            command("编辑", "Redo", KeyChord("z", shift: true, command: true)),
            command("编辑", "Copy", KeyChord("c", command: true)),
            command("编辑", "Paste", KeyChord("v", command: true)),
        ]
        let built = profile(localised, app: "Sysbuilder.AI")
        XCTAssertEqual(chord(built, "undo"), KeyChord("z", command: true))
        XCTAssertEqual(chord(built, "copy"), KeyChord("c", command: true))
        XCTAssertEqual(chord(built, "reload"), KeyChord("r", command: true))
    }

    func testThePreferredMenuIsStillExhaustedFirst() {
        // The other half of that change: searching the whole bar must not be
        // allowed to happen before the menus a want asked for. Xcode has a
        // "Find" in both Find and View, and only one of them is ⌘F.
        XCTAssertEqual(chord(profile(xcode), "find"), KeyChord("f", command: true))
    }

    func testAChordWithNoModifierAtAllIsNotAButton() {
        // Some apps publish an accelerator the Accessibility API cannot
        // describe and it arrives as a bare letter — Electron's Toggle Full
        // Screen came back as "F". Posted at a window, a bare letter does not
        // run a command: it types one into whatever is in front.
        XCTAssertFalse(MenuVocabulary.isPressable(KeyChord("f")))
        XCTAssertFalse(MenuVocabulary.isPressable(KeyChord("e", shift: true)))
        XCTAssertTrue(MenuVocabulary.isPressable(KeyChord("f", command: true)))
        // A function key is a whole shortcut on its own, and is the exception.
        XCTAssertTrue(MenuVocabulary.isPressable(KeyChord("f5")))

        let odd = [
            command("View", "Toggle Full Screen", KeyChord("f")),
            command("Edit", "Undo", KeyChord("z", command: true)),
            command("Edit", "Copy", KeyChord("c", command: true)),
            command("Edit", "Paste", KeyChord("v", command: true)),
        ]
        let built = profile(odd, app: "Electron")
        for action in built?.actions ?? [] where action.kind == .key {
            XCTAssertNotEqual(action.chord, KeyChord("f"), action.label)
        }
    }

    func testADiscoveredSetCannotBeMistakenForACuratedOne() {
        // The id is stored on a target and read back by both ends, so the two
        // namespaces must not be able to collide.
        let built = profile(xcode)
        XCTAssertTrue(MenuVocabulary.isDiscovered(profileID: built?.id))
        XCTAssertNil(ShortcutProfiles.profile(id: built?.id))
        for curated in ShortcutProfiles.all {
            XCTAssertFalse(MenuVocabulary.isDiscovered(profileID: curated.id), curated.name)
        }
    }

    func testADiscoveredSetSurvivesTheWire() throws {
        let payload = MenuProfilePayload(bundleID: "com.apple.dt.Xcode", outcome: .read,
                                         profile: profile(xcode), note: "Read from Xcode.")
        let line = try NimletCoder.line(HostMessage.menu(payload))
        guard case .menu(let decoded) = try NimletCoder.decode(HostMessage.self,
                                                             from: line.dropLast()) else {
            return XCTFail("decoded as something else")
        }
        XCTAssertEqual(decoded, payload)
        XCTAssertEqual(decoded.profile?.actions.first { $0.id == "run" }?.chord,
                       KeyChord("r", command: true))
    }

    func testARefusalSaysWhichRefusalItIs() throws {
        // "Not running" and "Nimlet cannot see its menus" want different things
        // from the user, and a phone told only that nothing arrived cannot tell
        // them apart.
        let json = Data(#"{"bundleID":"x","outcome":"notRunning","note":"Not running."}"#.utf8)
        let decoded = try NimletCoder.decode(MenuProfilePayload.self, from: json)
        XCTAssertEqual(decoded.outcome, .notRunning)
        XCTAssertNil(decoded.profile)
        // An outcome this build has never heard of is a failure to read, not a
        // crash and not a silent success.
        let odd = Data(#"{"bundleID":"x","outcome":"telepathy","note":"?"}"#.utf8)
        XCTAssertEqual(try NimletCoder.decode(MenuProfilePayload.self, from: odd).outcome, .unreadable)
    }

    // MARK: - Closing

    func testCloseComesFromTheAppsOwnKey() {
        let built = profile(xcode + [command("File", "Close", KeyChord("w", command: true))])
        XCTAssertEqual(chord(built, "close"), KeyChord("w", command: true))
    }

    func testABrowsersCloseTabIsTheCloseButton() {
        // Chrome calls it "Close Tab" and means the same thing a document app
        // means by "Close": get rid of what is in front.
        let built = profile([
            command("File", "New Tab", KeyChord("t", command: true)),
            command("File", "Close Tab", KeyChord("w", command: true)),
            command("Edit", "Copy", KeyChord("c", command: true)),
            command("Edit", "Paste", KeyChord("v", command: true)),
        ], app: "Chrome")
        XCTAssertEqual(chord(built, "close"), KeyChord("w", command: true))
    }

    func testCloseAllIsNotMistakenForClose() {
        // The dangerous near-miss. "Close All" throws away every window the app
        // has, and it sits directly under "Close" in most File menus — so if
        // longer titles were allowed to match, the close button would be an
        // app-wide one and would look identical.
        let built = profile([
            command("File", "Close All", KeyChord("w", option: true, command: true)),
            command("File", "Close Others", KeyChord("w", option: true, shift: true, command: true)),
            command("Edit", "Copy", KeyChord("c", command: true)),
            command("Edit", "Paste", KeyChord("v", command: true)),
            command("Product", "Run", KeyChord("r", command: true)),
        ])
        XCTAssertNil(chord(built, "close"),
                     "only an exact close title may become the close button")
    }

    func testAnAppThatPublishesNoCloseKeyGetsNoCloseButton() {
        // Nothing here is a guess: a menu item with no key published for it is
        // not offered, and ⌘W is not assumed on its behalf.
        let built = profile(xcode)
        XCTAssertNil(chord(built, "close"))
    }

    func testQuitIsNeverOffered() {
        // Not in the vocabulary at all, and this is the test that says so out
        // loud: closing leaves the app running and raises a visible dialog for
        // unsaved work, quitting does neither, and a row a thumb can brush is
        // the wrong place for it.
        let built = profile(xcode + [
            command("Xcode", "Quit Xcode", KeyChord("q", command: true)),
            command("File", "Close", KeyChord("w", command: true)),
        ])
        XCTAssertNil(chord(built, "quit"))
        XCTAssertFalse(built?.actions.contains { $0.chord == KeyChord("q", command: true) } ?? false,
                       "no button may send Command-Q, whatever it is called")
    }
}
