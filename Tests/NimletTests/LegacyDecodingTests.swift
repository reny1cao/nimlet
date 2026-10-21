import XCTest

/// Decoding of JSON written by a v4 build.
///
/// These are not hypothetical inputs. `TargetStore` reseeds from scratch when
/// its saved file fails to decode, and the host keeps talking to clients one
/// release behind, so a field added without a default does not produce an error
/// anybody sees — it quietly erases the user's configured targets, or makes an
/// older phone unable to connect at all.
final class LegacyDecodingTests: XCTestCase {

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try NimletCoder.decode(type, from: Data(json.utf8))
    }

    // MARK: NimletTarget

    func testAV4TargetWithNoAllowAutoSubmitDecodesWithAutoSubmitAllowed() throws {
        let target = try decode(NimletTarget.self, """
        {"id":"t-1","name":"Claude","kind":"app",
         "bundleID":"com.anthropic.claudefordesktop",
         "submitOnSend":true,"symbol":"sparkles"}
        """)
        XCTAssertEqual(target.id, "t-1")
        XCTAssertEqual(target.name, "Claude")
        XCTAssertEqual(target.kind, .app)
        XCTAssertEqual(target.bundleID, "com.anthropic.claudefordesktop")
        XCTAssertTrue(target.submitOnSend)
        XCTAssertTrue(target.allowAutoSubmit)
        XCTAssertEqual(target.symbol, "sparkles")
    }

    func testAWholeV4TargetFileDecodesRatherThanFailingAndReseeding() throws {
        let targets = try decode([NimletTarget].self, """
        [{"id":"a","name":"Claude","kind":"app","bundleID":"com.x","submitOnSend":true,"symbol":"s"},
         {"id":"b","name":"codex","kind":"tmux","tmuxTarget":"%7","submitOnSend":false,"symbol":"t"},
         {"id":"c","name":"Frontmost","kind":"frontmost","submitOnSend":true,"symbol":"u"}]
        """)
        XCTAssertEqual(targets.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(targets.map(\.kind), [.app, .tmux, .frontmost])
        XCTAssertTrue(targets.allSatisfy(\.allowAutoSubmit))
    }

    func testATargetWithNoFieldsAtAllDecodesToUsableDefaults() throws {
        let target = try decode(NimletTarget.self, "{}")
        XCTAssertFalse(target.id.isEmpty, "a target with no id must still get one")
        XCTAssertEqual(target.name, "Target")
        XCTAssertEqual(target.kind, .frontmost)
        XCTAssertNil(target.bundleID)
        XCTAssertNil(target.tmuxTarget)
        XCTAssertTrue(target.submitOnSend)
        XCTAssertTrue(target.allowAutoSubmit)
        XCTAssertEqual(target.symbol, "square.dashed")
    }

    func testATargetCarryingAnUnknownFutureFieldStillDecodes() throws {
        let target = try decode(NimletTarget.self, """
        {"name":"Claude","kind":"app","somethingAddedInV6":{"nested":[1,2,3]}}
        """)
        XCTAssertEqual(target.name, "Claude")
        XCTAssertEqual(target.kind, .app)
    }

    func testATargetFromAnOlderMacIsTreatedAsOneTheUserChose() throws {
        // `isProvisional` splits the dock in two: curated targets, then the
        // panes and apps that merely happen to be running. A Mac that predates
        // the field sends neither, and the safe way to be wrong is "the user
        // chose this" — a target defaulting the other way would be drawn as a
        // passing suggestion and would vanish from the dock on the next report.
        let target = try decode(NimletTarget.self, """
        {"id":"t-1","name":"Claude","kind":"tmux","tmuxTarget":"%2","symbol":"terminal"}
        """)
        XCTAssertFalse(target.isProvisional)
    }

    func testProvisionalSurvivesTheWire() throws {
        let offered = NimletTarget(id: "pane:%9", name: "claude (work)", kind: .tmux,
                                 tmuxTarget: "%9", symbol: "sparkle", isProvisional: true)
        let line = try NimletCoder.line(offered)
        let back = try NimletCoder.decode(NimletTarget.self, from: line)
        XCTAssertEqual(back, offered)
        XCTAssertTrue(back.isProvisional)
    }

    func testAPromotedTargetKeepsTheIDItWasOfferedUnder() throws {
        // Promotion is "the same thing, now kept", not a new target: the id is
        // what `activeTargetID`, the agent event log and any pinned window all
        // refer to, and re-keying it on promotion would strand every one of
        // them at the moment the user first used the tile.
        let id = "pane:%9"
        var offered = NimletTarget(id: id, name: "claude (work)", kind: .tmux,
                                 tmuxTarget: "%9", symbol: "sparkle", isProvisional: true)
        offered.isProvisional = false
        XCTAssertEqual(offered.id, id)
        XCTAssertEqual(offered.tmuxTarget, "%9")
    }

    // MARK: ViewFrame

    func testAStateFrameFromAnOlderMacStillDecodes() throws {
        // `ViewFrame` has no hand-written decoder — `Codable` is synthesised —
        // so a non-Optional field added here throws on every frame from a Mac
        // that does not send it. That is not a missing button: the mirror
        // decodes nothing and shows nothing, for the whole session.
        let frame = try decode(ViewFrame.self, """
        {"kind":"state","title":"Chrome","captureTime":12345,"reason":"Chrome is minimised"}
        """)
        XCTAssertEqual(frame.reason, "Chrome is minimised")
        XCTAssertNil(frame.canOpen)
    }

    func testAVideoFrameFromAnOlderMacStillDecodes() throws {
        let frame = try decode(ViewFrame.self, """
        {"kind":"video","title":"Chrome","captureTime":12345,"width":800,"height":600}
        """)
        XCTAssertEqual(frame.kind, .video)
        XCTAssertNil(frame.canOpen)
    }

    func testAnOpenableStateSaysSo() throws {
        let frame = ViewFrame.state("Chrome is minimised", title: "Chrome", canOpen: true)
        let back = try NimletCoder.decode(ViewFrame.self, from: try NimletCoder.line(frame))
        XCTAssertEqual(back.canOpen, true)
    }

    func testAStateNobodyCanClearCarriesNoOpenFlag() throws {
        // "Your Mac is locked" is not something the phone can fix by asking for
        // a window, and offering a button that cannot work is worse than none.
        let frame = ViewFrame.state("Your Mac is locked")
        let back = try NimletCoder.decode(ViewFrame.self, from: try NimletCoder.line(frame))
        XCTAssertNil(back.canOpen)
    }

    func testAnExplicitAllowAutoSubmitFalseSurvivesDecodingRatherThanDefaultingToTrue() throws {
        let target = try decode(NimletTarget.self, """
        {"name":"prod shell","kind":"tmux","tmuxTarget":"%2",
         "submitOnSend":true,"allowAutoSubmit":false,"symbol":"terminal"}
        """)
        XCTAssertFalse(target.allowAutoSubmit)
        XCTAssertTrue(target.submitOnSend, "the two switches are independent")
    }

    func testAPositionalTmuxSpecIsNotTreatedAsAStablePaneID() throws {
        let positional = try decode(NimletTarget.self, """
        {"name":"codex","kind":"tmux","tmuxTarget":"codex:0.1"}
        """)
        XCTAssertFalse(positional.hasStableTmuxID)

        let stable = try decode(NimletTarget.self, """
        {"name":"codex","kind":"tmux","tmuxTarget":"%11"}
        """)
        XCTAssertTrue(stable.hasStableTmuxID)
    }

    func testATargetWithNoTmuxSpecHasNoStablePaneID() {
        XCTAssertFalse(NimletTarget(name: "Claude", kind: .app).hasStableTmuxID)
    }

    func testAnUnknownTargetKindIsRejectedRatherThanGuessedAt() {
        // Distinct from a missing field: a kind Nimlet does not implement cannot
        // be routed, so it must not decode into one that can be.
        XCTAssertThrowsError(try decode(NimletTarget.self, """
        {"name":"X","kind":"bluetooth"}
        """))
    }
}
