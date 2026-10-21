import XCTest

/// A target can be pointed at one window of an app rather than at the app.
///
/// The promise being tested is narrow and absolute: what the phone picked is
/// what the Mac keeps, and a target that has lost its window must read as
/// *lost* rather than as an ordinary app target — because an ordinary app
/// target delivers to whatever window is in front, which is the one outcome the
/// pin exists to prevent.
final class WindowPinTests: XCTestCase {

    // MARK: - The pin survives everything it has to survive

    func testAPinnedWindowSurvivesTheWire() throws {
        let target = NimletTarget(id: "t1", name: "Claude", kind: .app,
                                bundleID: "com.anthropic.claudefordesktop",
                                symbol: "sparkle",
                                pinnedWindowID: 1191,
                                pinnedWindowTitle: "Dock bar auto-population UX")
        let line = try NimletCoder.line(ClientMessage.updateTarget(target))
        guard case .updateTarget(let round) = try NimletCoder.decode(ClientMessage.self,
                                                                    from: line.dropLast()) else {
            return XCTFail("decoded as something else")
        }
        XCTAssertEqual(round.pinnedWindowID, 1191)
        XCTAssertEqual(round.pinnedWindowTitle, "Dock bar auto-population UX")
        XCTAssertEqual(round, target)
    }

    func testATargetSavedBeforeWindowsExistedStillDecodes() throws {
        // The saved-target decoder is hand-written precisely so that adding a
        // field cannot delete somebody's target list on the next launch.
        let json = Data(#"{"id":"t1","name":"Claude","kind":"app","bundleID":"com.x","symbol":"app"}"#.utf8)
        let target = try NimletCoder.decode(NimletTarget.self, from: json)
        XCTAssertNil(target.pinnedWindowID, "an old target follows the app, as it always did")
        XCTAssertNil(target.pinnedWindowTitle)
    }

    func testTheWireCarriesBothAskingForAWindowAndGivingUpOnOne() throws {
        let pick = try NimletCoder.line(ClientMessage.focusWindow(targetID: "t1", windowID: 42))
        guard case .focusWindow(let targetID, let windowID) =
                try NimletCoder.decode(ClientMessage.self, from: pick.dropLast()) else {
            return XCTFail("decoded as something else")
        }
        XCTAssertEqual(targetID, "t1")
        XCTAssertEqual(windowID, 42)

        // nil is not the absence of an instruction here — it *is* the
        // instruction: stop pinning and follow the app again.
        let release = try NimletCoder.line(ClientMessage.focusWindow(targetID: "t1", windowID: nil))
        guard case .focusWindow(_, let none) =
                try NimletCoder.decode(ClientMessage.self, from: release.dropLast()) else {
            return XCTFail("decoded as something else")
        }
        XCTAssertNil(none)
    }

    func testTheWireCarriesTheShapeTheSeamWasDraggedTo() throws {
        let line = try NimletCoder.line(ClientMessage.reshapePanel(aspect: 0.75))
        guard case .reshapePanel(let aspect) =
                try NimletCoder.decode(ClientMessage.self, from: line.dropLast()) else {
            return XCTFail("decoded as something else")
        }
        XCTAssertEqual(aspect, 0.75)
    }

    // MARK: - What a window list says

    private func window(_ id: UInt32, _ title: String, previewBytes: Int = 0) -> MacWindow {
        MacWindow(id: id, title: title, appName: "Claude",
                  preview: previewBytes > 0 ? Data(repeating: 0xEE, count: previewBytes) : nil)
    }

    func testAWindowListSurvivesTheWireWithItsPictures() throws {
        let windows = [window(1191, "Dock bar auto-population UX", previewBytes: 16_000),
                       MacWindow(id: 48, title: "All iCloud", appName: "Notes",
                                 isMinimized: true, isOnScreen: false, canRaise: true)]
        let payload = WindowListPayload(targetID: "t1", windows: windows)
        let line = try NimletCoder.line(HostMessage.windows(payload))
        guard case .windows(let round) = try NimletCoder.decode(HostMessage.self,
                                                               from: line.dropLast()) else {
            return XCTFail("decoded as something else")
        }
        XCTAssertEqual(round, payload)
        XCTAssertTrue(round.windows[1].isMinimized,
                      "the state that stops a delivery must not be the one that gets lost")
    }

    func testAnUntitledWindowIsStillNamedAfterSomething() {
        XCTAssertEqual(MacWindow(id: 1, title: "", appName: "Ghostty").displayTitle, "Ghostty")
        XCTAssertEqual(MacWindow(id: 1, title: "   ", appName: "Ghostty").displayTitle, "Ghostty")
        XCTAssertEqual(MacWindow(id: 1, title: "notes.md", appName: "Zed").displayTitle, "notes.md")
    }

    func testAWindowFromAPartialMessageIsDrawableAndNotFalselyReassuring() throws {
        let json = Data(#"{"id":7,"title":"x"}"#.utf8)
        let window = try NimletCoder.decode(MacWindow.self, from: json)
        XCTAssertEqual(window.id, 7)
        XCTAssertFalse(window.isMinimized)
        XCTAssertFalse(window.isPinned, "nothing is pinned until the Mac says it is")
        XCTAssertNil(window.preview)
    }

    func testPreviewsAreChunkedUnderTheFramersLine() throws {
        // Twelve windows at twenty kilobytes of JPEG is past the one-megabyte
        // line, and an overlong line is dropped whole rather than truncated.
        let windows = (0..<WindowRoster.limitForTests).map {
            window(UInt32($0 + 1), "Window \($0)", previewBytes: 20_000)
        }
        let chunks = WindowListPayload.chunked(windows, targetID: "t1", note: "a note")
        for chunk in chunks {
            let line = try NimletCoder.line(HostMessage.windows(chunk))
            XCTAssertLessThan(line.count, 1 << 20)
        }
        XCTAssertEqual(chunks.flatMap(\.windows).map(\.id), windows.map(\.id),
                       "chunking loses no window and reorders none")
        XCTAssertEqual(chunks.compactMap(\.note), ["a note"],
                       "the note rides one chunk, so folding them shows it once")
        XCTAssertEqual(chunks.filter(\.isFinal).count, 1)
    }

    func testAnEmptyWindowListStillArrives() {
        // "No windows" has to be a message: the shelf spins until the final
        // chunk lands.
        let chunks = WindowListPayload.chunked([], targetID: "t1", note: "Claude isn't running")
        XCTAssertEqual(chunks.count, 1)
        XCTAssertTrue(chunks[0].isFinal)
        XCTAssertTrue(chunks[0].windows.isEmpty)
        XCTAssertEqual(chunks[0].note, "Claude isn't running")
    }

    func testAWindowWhosePictureIsTooBigKeepsItsPlaceAndItsTitle() {
        let chunks = WindowListPayload.chunked([window(1, "huge", previewBytes: 400_000),
                                                window(2, "small", previewBytes: 900)],
                                               targetID: "t1", budget: 64 << 10)
        let all = chunks.flatMap(\.windows)
        XCTAssertEqual(all.map(\.id), [1, 2])
        XCTAssertNil(all[0].preview, "a card without its picture still names its window")
        XCTAssertEqual(all[0].title, "huge")
        XCTAssertNotNil(all[1].preview)
    }
}

/// The host's own limit, mirrored here because the roster type itself is macOS
/// code and these tests compile on their own.
private enum WindowRoster {
    static let limitForTests = 12
}
