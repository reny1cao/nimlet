import XCTest

/// The approval path is the one place in Nimlet where doing nothing has to mean
/// "no". Everything else here fails safe by accident; this has to fail safe on
/// purpose, and these are the cases that say whether it does.
final class ApprovalTests: XCTestCase {

    private let second: Int64 = 1000

    private func request(id: String = "r1",
                         at now: Int64 = 0,
                         timeout: TimeInterval = 60) -> ApprovalRequest {
        ApprovalRequest(id: id,
                        targetID: "t1",
                        targetName: "claude",
                        title: "Run a command",
                        detail: "rm -rf build/",
                        kind: .command,
                        createdAtEpochMillis: now,
                        timeout: timeout)
    }

    // MARK: - Nothing is approved by not answering

    func testAnUnansweredRequestExpiresIntoADenial() {
        var ledger = ApprovalLedger()
        XCTAssertEqual(ledger.add(request(timeout: 60), now: 0), .added)

        XCTAssertTrue(ledger.expire(now: 59 * second).isEmpty, "still inside its window")

        let resolutions = ledger.expire(now: 60 * second)
        XCTAssertEqual(resolutions.count, 1)
        XCTAssertEqual(resolutions.first?.decision, .deny)
        XCTAssertEqual(resolutions.first?.reason, .expired)
        XCTAssertTrue(ledger.pending.isEmpty)
    }

    func testAnApprovalThatArrivesAfterTheDeadlineLosesToTheDeadline() {
        var ledger = ApprovalLedger()
        _ = ledger.add(request(timeout: 60), now: 0)

        let resolution = ledger.resolve(id: "r1", decision: .approve, by: "iPhone", now: 61 * second)
        XCTAssertEqual(resolution?.decision, .deny,
                       "a yes after the agent was already told no must not become a second answer")
        XCTAssertEqual(resolution?.reason, .expired)
    }

    func testAnAlreadyExpiredRequestIsRefusedRatherThanShown() {
        var ledger = ApprovalLedger()
        // Sent from a hook on a Mac that was asleep: by the time it arrives its
        // window is gone.
        let outcome = ledger.add(request(timeout: 5), now: 30 * second)
        guard case .refused(let resolution) = outcome else {
            return XCTFail("expected a refusal, got \(outcome)")
        }
        XCTAssertEqual(resolution.decision, .deny)
        XCTAssertTrue(ledger.pending.isEmpty, "a card that appears and vanishes reads as a bug")
    }

    func testADecodedRequestWithNoExpiryPolicyDeniesRatherThanApproves() throws {
        // A field this end cannot read must never be read as consent.
        let json = Data(#"{"id":"r1","targetName":"claude","title":"x","detail":"y","onExpiry":"whatever"}"#.utf8)
        let decoded = try NimletCoder.decode(ApprovalRequest.self, from: json)
        XCTAssertEqual(decoded.onExpiry, .deny)
    }

    func testADecodedResolutionWithNoDecisionDeniesRatherThanApproves() throws {
        let json = Data(#"{"requestID":"r1"}"#.utf8)
        let decoded = try NimletCoder.decode(ApprovalResolution.self, from: json)
        XCTAssertEqual(decoded.decision, .deny)
    }

    // MARK: - The asker always gets an answer

    func testAnsweringProducesExactlyOneResolutionAndLeavesNothingPending() {
        var ledger = ApprovalLedger()
        _ = ledger.add(request(), now: 0)

        let first = ledger.resolve(id: "r1", decision: .approve, by: "iPhone", now: second)
        XCTAssertEqual(first?.decision, .approve)
        XCTAssertEqual(first?.byDeviceName, "iPhone")
        XCTAssertTrue(ledger.pending.isEmpty)

        XCTAssertNil(ledger.resolve(id: "r1", decision: .deny, by: "iPad", now: 2 * second),
                     "a second phone answering must not send the agent a contradicting answer")
    }

    func testAFloodIsDeniedRatherThanQueuedBehindAPhoneNobodyIsWatching() {
        var ledger = ApprovalLedger()
        for index in 0..<ApprovalLedger.maxPending {
            XCTAssertEqual(ledger.add(request(id: "r\(index)"), now: 0), .added)
        }
        let outcome = ledger.add(request(id: "one-too-many"), now: 0)
        guard case .refused(let resolution) = outcome else {
            return XCTFail("expected a refusal, got \(outcome)")
        }
        XCTAssertEqual(resolution.decision, .deny)
        XCTAssertEqual(resolution.reason, .refused)
        XCTAssertEqual(ledger.pending.count, ApprovalLedger.maxPending)
    }

    func testARetryingHookIsNotASecondQuestion() {
        var ledger = ApprovalLedger()
        _ = ledger.add(request(), now: 0)
        XCTAssertEqual(ledger.add(request(), now: second), .duplicate)
        XCTAssertEqual(ledger.pending.count, 1)
    }

    func testWhenTheAskerDiesItsRequestComesOffEveryPhone() {
        var ledger = ApprovalLedger()
        _ = ledger.add(request(id: "r1"), now: 0)
        _ = ledger.add(request(id: "r2"), now: 0)

        let gone = ledger.withdraw(ids: ["r1"], now: second)
        XCTAssertEqual(gone.count, 1)
        XCTAssertEqual(gone.first?.reason, .withdrawn)
        XCTAssertEqual(gone.first?.decision, .deny)
        XCTAssertEqual(ledger.pending.map(\.id), ["r2"])
    }

    // MARK: - What the phone is told

    func testTheDeadlineIsCarriedAsATimeRatherThanADuration() {
        // Both ends read the same wall clock, so a phone that connects halfway
        // through shows the time actually left rather than the whole window.
        let subject = request(at: 10 * second, timeout: 60)
        XCTAssertEqual(subject.expiresAtEpochMillis, 70 * second)
        XCTAssertEqual(subject.secondsRemaining(at: 40 * second), 30)
        XCTAssertEqual(subject.secondsRemaining(at: 999 * second), 0, "never negative")
    }

    func testAnEnormousDetailIsCutWithAVisibleMarkerRatherThanSilently() {
        let subject = ApprovalRequest(targetName: "claude",
                                      title: "Run a command",
                                      detail: String(repeating: "x", count: 50_000))
        XCTAssertTrue(subject.detail.hasSuffix("(truncated)"),
                      "nobody may approve a command whose tail was quietly removed")
        XCTAssertLessThan(subject.detail.count, ApprovalRequest.maxDetailCharacters + 32)
    }

    func testAnAbsurdTimeoutIsClampedRatherThanHonoured() {
        let forever = request(at: 0, timeout: 86_400)
        XCTAssertEqual(forever.expiresAtEpochMillis,
                       Int64(ApprovalRequest.maxTimeout * 1000),
                       "a request that outlives the session it belongs to is not a request")
    }

    func testTheNextDeadlineIsTheSoonestOne() {
        var ledger = ApprovalLedger()
        _ = ledger.add(request(id: "slow", at: 0, timeout: 300), now: 0)
        _ = ledger.add(request(id: "soon", at: 0, timeout: 30), now: 0)
        XCTAssertEqual(ledger.nextExpiry(), 30 * second)
    }

    func testADenialCarriesItsReasonToTheAgent() {
        var ledger = ApprovalLedger()
        _ = ledger.add(request(), now: 0)
        let resolution = ledger.resolve(id: "r1", decision: .deny,
                                        reason: "  wrong directory  ", by: "iPhone", now: second)
        XCTAssertEqual(resolution?.note, "wrong directory")
    }

    func testAnEmptyReasonIsNoReasonRatherThanAnEmptyOne() {
        var ledger = ApprovalLedger()
        _ = ledger.add(request(), now: 0)
        let resolution = ledger.resolve(id: "r1", decision: .deny,
                                        reason: "   ", by: "iPhone", now: second)
        XCTAssertNil(resolution?.note)
    }

    // MARK: - On the wire

    func testARequestAndItsResolutionSurviveTheWire() throws {
        let original = request()
        let line = try NimletCoder.line(ClientMessage.requestApproval(original))
        let decoded = try NimletCoder.decode(ClientMessage.self, from: line.dropLast())
        guard case .requestApproval(let round) = decoded else {
            return XCTFail("decoded as something else")
        }
        XCTAssertEqual(round, original)

        let resolution = ApprovalResolution(requestID: "r1", decision: .approve,
                                            reason: .answered, byDeviceName: "iPhone",
                                            atEpochMillis: second)
        let out = try NimletCoder.line(HostMessage.approvalResolved(resolution))
        let back = try NimletCoder.decode(HostMessage.self, from: out.dropLast())
        guard case .approvalResolved(let round2) = back else {
            return XCTFail("decoded as something else")
        }
        XCTAssertEqual(round2, resolution)
    }

    func testADecisionWithoutAReasonStillEncodes() throws {
        let line = try NimletCoder.line(ClientMessage.approvalDecision(id: "r1",
                                                                     decision: .deny,
                                                                     reason: nil))
        let decoded = try NimletCoder.decode(ClientMessage.self, from: line.dropLast())
        guard case .approvalDecision(let id, let decision, let reason, let answers, _, _) = decoded else {
            return XCTFail("decoded as something else")
        }
        XCTAssertEqual(id, "r1")
        XCTAssertEqual(decision, .deny)
        XCTAssertNil(reason)
        XCTAssertNil(answers)
    }

    func testAnAnswerFromANewerPhoneReadsAsThePlainDecisionToAnOlderMac() throws {
        // What 0.1.1 (47) decodes: the answers are extra keys it ignores.
        let line = try NimletCoder.line(ClientMessage.approvalDecision(id: "r1", decision: .approve, reason: nil,
                                                                     answers: ["Postgres"], alwaysAllow: true))
        let text = String(decoding: line, as: UTF8.self)
        XCTAssertTrue(text.contains(#""answers":["Postgres"]"#))
        // And what an older phone sends still decodes here, with nothing extra.
        let old = Data(#"{"approvalDecision":{"id":"r1","decision":"approve"}}"#.utf8)
        guard case .approvalDecision(_, let decision, _, let answers, let always, let handBack)
                = try NimletCoder.decode(ClientMessage.self, from: old) else {
            return XCTFail("decoded as something else")
        }
        XCTAssertEqual(decision, .approve)
        XCTAssertNil(answers)
        XCTAssertNil(always)
        XCTAssertNil(handBack)
    }

    func testAQuestionSurvivesTheWireAndAnOlderRequestIsNotOne() throws {
        let asked = ApprovalRequest(id: "q", targetName: "claude", title: "Has a question", detail: "Which?",
                                    questions: [ApprovalQuestion(question: "Which?", header: "Pick",
                                                                 options: [ApprovalOption(label: "A", detail: "first")],
                                                                 allowsMultiple: true)],
                                    alwaysAllowRule: nil, returnsToMac: true)
        let round = try NimletCoder.decode(ApprovalRequest.self, from: NimletCoder.encode(asked))
        XCTAssertEqual(round, asked)

        let old = try NimletCoder.decode(ApprovalRequest.self,
                                       from: Data(#"{"id":"r1","targetName":"claude","title":"x","detail":"y"}"#.utf8))
        XCTAssertFalse(old.isQuestion)
        XCTAssertFalse(old.returnsToMac, "an older request keeps its old meaning: unanswered is denied")
        XCTAssertNil(old.alwaysAllowRule)
    }

    // MARK: - Questions and answers

    private func question(id: String = "q1", at now: Int64 = 0, rule: String? = nil) -> ApprovalRequest {
        ApprovalRequest(id: id, targetName: "claude", title: "Has a question", detail: "Which?",
                        createdAtEpochMillis: now, timeout: 600,
                        questions: [ApprovalQuestion(question: "Which?", options: [ApprovalOption(label: "A")]),
                                    ApprovalQuestion(question: "And?", options: [])],
                        alwaysAllowRule: rule, returnsToMac: true)
    }

    func testAnAnsweredQuestionCarriesItsAnswersBack() {
        var ledger = ApprovalLedger()
        _ = ledger.add(question(), now: 0)
        let resolution = ledger.resolve(id: "q1", with: ApprovalAnswer(decision: .approve, answers: ["A", " typed "]),
                                        by: "iPhone", now: second)
        XCTAssertEqual(resolution?.decision, .approve)
        XCTAssertEqual(resolution?.reason, .answered)
        XCTAssertEqual(resolution?.answers, ["A", "typed"])
    }

    func testAYesToAQuestionWithoutEveryAnswerGoesBackToTheMac() {
        // An older phone only knows Approve. That is not an answer to "which?".
        for given in [nil, ["A"], ["A", "  "]] as [[String]?] {
            var ledger = ApprovalLedger()
            _ = ledger.add(question(), now: 0)
            let resolution = ledger.resolve(id: "q1", with: ApprovalAnswer(decision: .approve, answers: given),
                                            by: "iPhone", now: second)
            XCTAssertEqual(resolution?.decision, .deny)
            XCTAssertEqual(resolution?.reason, .handedBack)
            XCTAssertNil(resolution?.answers)
        }
    }

    func testDontAskAgainOnlyWhenTheAgentOfferedIt() {
        var ledger = ApprovalLedger()
        _ = ledger.add(request(id: "plain"), now: 0)
        _ = ledger.add(ApprovalRequest(id: "ruled", targetName: "claude", title: "Run a command", detail: "touch x",
                                       createdAtEpochMillis: 0, timeout: 60, alwaysAllowRule: "touch x"), now: 0)
        let always = ApprovalAnswer(decision: .approve, alwaysAllow: true)
        XCTAssertEqual(ledger.resolve(id: "plain", with: always, by: nil, now: second)?.alwaysAllow, false)
        XCTAssertEqual(ledger.resolve(id: "ruled", with: always, by: nil, now: second)?.alwaysAllow, true)
    }

    func testHandingBackIsNeverAYes() {
        var ledger = ApprovalLedger()
        _ = ledger.add(question(), now: 0)
        let resolution = ledger.resolve(id: "q1", with: ApprovalAnswer(decision: .approve, answers: ["A", "B"],
                                                                       handBack: true),
                                        by: nil, now: second)
        XCTAssertEqual(resolution?.decision, .deny)
        XCTAssertEqual(resolution?.reason, .handedBack)
    }

    func testTypedTextWinsOverPicksAndNothingIsNoAnswer() {
        XCTAssertEqual(ApprovalQuestion.answer(picking: ["A", "B"], typed: nil), "A, B")
        XCTAssertEqual(ApprovalQuestion.answer(picking: ["A"], typed: "  my own  "), "my own")
        XCTAssertNil(ApprovalQuestion.answer(picking: [], typed: "   "))
    }

    // MARK: - The wait

    func testTheWaitIsClampedAndSaidPlainly() {
        XCTAssertEqual(ApprovalWait.clamped(5), ApprovalWait.shortest)
        XCTAssertEqual(ApprovalWait.clamped(10 * 86_400), ApprovalRequest.maxTimeout)
        XCTAssertTrue(ApprovalWait.choices.contains(ApprovalWait.standard))
        XCTAssertTrue(ApprovalWait.choices.allSatisfy { $0 <= ApprovalRequest.maxTimeout })
        XCTAssertEqual(ApprovalWait.choices.map(ApprovalWait.describe),
                       ["2 minutes", "10 minutes", "30 minutes", "1 hour", "4 hours", "12 hours"])
        XCTAssertEqual(ApprovalWait.clock(45), "45s")
        XCTAssertEqual(ApprovalWait.clock(598), "9:58")
        XCTAssertEqual(ApprovalWait.clock(3 * 3600 + 12 * 60 + 5), "3h 12m")
    }

    func testALongWaitStillEndsWithoutAYes() {
        var ledger = ApprovalLedger()
        _ = ledger.add(question(), now: 0)
        XCTAssertTrue(ledger.expire(now: 599 * second).isEmpty)
        let expired = ledger.expire(now: 600 * second)
        XCTAssertEqual(expired.map(\.decision), [.deny])
        XCTAssertEqual(expired.map(\.reason), [.expired])
    }

    // MARK: - An asker cut off by the Mac

    func testAnAskerCutOffByTheMacGetsTimeToComeBack() {
        var ledger = ApprovalLedger()
        _ = ledger.add(question(), now: 0)
        ledger.orphan(ids: ["q1", "nobody"], now: second)
        XCTAssertEqual(ledger.nextExpiry(), second + ApprovalLedger.reconnectGrace)
        XCTAssertTrue(ledger.sweepOrphans(now: 20 * second).isEmpty, "still inside the grace")

        // The hook dials back in and asks again under the same id.
        XCTAssertEqual(ledger.add(question(), now: 25 * second), .duplicate)
        XCTAssertTrue(ledger.orphanedAt.isEmpty)
        XCTAssertTrue(ledger.sweepOrphans(now: 120 * second).isEmpty)
        XCTAssertEqual(ledger.pending.map(\.id), ["q1"])
    }

    func testAnAskerThatNeverComesBackIsWithdrawn() {
        var ledger = ApprovalLedger()
        _ = ledger.add(question(), now: 0)
        ledger.orphan(ids: ["q1"], now: second)
        let lost = ledger.sweepOrphans(now: second + ApprovalLedger.reconnectGrace)
        XCTAssertEqual(lost.map(\.reason), [.withdrawn])
        XCTAssertEqual(lost.map(\.decision), [.deny])
        XCTAssertTrue(ledger.pending.isEmpty)
        XCTAssertTrue(ledger.orphanedAt.isEmpty)
    }
}

/// Keys are addressed the way text is, and which keys exist at all depends on
/// what is listening at the other end.
final class ShortcutTests: XCTestCase {

    // MARK: - Translating a chord

    func testAChordBecomesWhatTmuxCallsIt() {
        XCTAssertEqual(KeyChord("escape").tmuxName, "Escape")
        XCTAssertEqual(KeyChord("enter").tmuxName, "Enter")
        XCTAssertEqual(KeyChord("c", control: true).tmuxName, "C-c")
        XCTAssertEqual(KeyChord("p", option: true).tmuxName, "M-p")
        XCTAssertEqual(KeyChord("space").tmuxName, "Space")
        XCTAssertEqual(KeyChord("up").tmuxName, "Up")
    }

    func testShiftedTabIsBackTabRatherThanAModifier() {
        // tmux has no S-Tab. Both agents cycle their permission mode with
        // Shift+Tab, so getting this wrong would break the single most useful
        // button on the phone for both of them.
        XCTAssertEqual(KeyChord("tab", shift: true).tmuxName, "BTab")
    }

    func testAShiftedLetterIsACapitalRatherThanAModifier() {
        XCTAssertEqual(KeyChord("k", shift: true).tmuxName, "K")
    }

    func testACommandChordCannotReachAPaneAtAll() {
        // ⌘C is the terminal application's own shortcut; it never becomes a
        // character in the input stream of the program running inside it.
        XCTAssertNil(KeyChord("c", command: true).tmuxName)
        XCTAssertNil(KeyChord("v", command: true).tmuxName)
    }

    func testAKeyTmuxHasNoNameForIsRefusedRatherThanGuessedAt() {
        XCTAssertNil(KeyChord("§").tmuxName)
        XCTAssertNil(KeyChord("f13").tmuxName)
    }

    func testARepeatIsClampedToSomethingAFingerCouldHaveMeant() {
        XCTAssertEqual(KeyChord("escape", repeatCount: 99).repeatCount, 4)
        XCTAssertEqual(KeyChord("escape", repeatCount: 0).repeatCount, 1)
    }

    func testAChordReadsTheWayAKeyboardIsWritten() {
        XCTAssertEqual(KeyChord("c", control: true).display, "⌃C")
        XCTAssertEqual(KeyChord("tab", shift: true).display, "⇧⇥")
        XCTAssertEqual(KeyChord("escape", repeatCount: 2).display, "esc ×2")
        XCTAssertEqual(KeyChord("escape", repeatCount: 2).spoken, "Escape, twice")
    }

    // MARK: - Choosing a set

    func testAPanesRunningProcessPicksTheSet() {
        XCTAssertEqual(ShortcutProfiles.guess(forCommand: "claude").id, "claude")
        XCTAssertEqual(ShortcutProfiles.guess(forCommand: "codex").id, "codex")
        XCTAssertEqual(ShortcutProfiles.guess(forCommand: "zsh").id, "shell")
        XCTAssertEqual(ShortcutProfiles.guess(forCommand: "CLAUDE").id, "claude", "case is not a decision")
    }

    func testAnUnrecognisedProcessFallsBackToTheShellRatherThanToAnAgent() {
        // Guessing an agent would put Escape-to-interrupt on a pane where
        // Escape does nothing, and hide Control-C where it is the only thing
        // that works.
        XCTAssertEqual(ShortcutProfiles.guess(forCommand: "vim").id, "shell")
        XCTAssertEqual(ShortcutProfiles.guess(forCommand: nil).id, "shell")
        XCTAssertEqual(ShortcutProfiles.guess(forCommand: "").id, "shell")
    }

    func testAChosenProfileWinsOverWhateverIsRunning() {
        var target = NimletTarget(name: "claude", kind: .tmux, tmuxTarget: "%3")
        target.profileID = "codex"
        XCTAssertEqual(ShortcutProfiles.resolved(for: target, paneCommand: "claude").id, "codex")
    }

    func testAnAppTargetNeverGetsAPanesSet() {
        let target = NimletTarget(name: "Zed", kind: .app, bundleID: "dev.zed.Zed")
        let resolved = ShortcutProfiles.resolved(for: target, paneCommand: "claude")
        XCTAssertFalse(ShortcutProfiles.paneProfiles.contains { $0.id == resolved.id },
                       "an app got \(resolved.name), which is a pane's set")
    }

    func testAnAppGetsTheSetForTheAppItActuallyIs() {
        // The whole of "Mac app" used to be esc · return · ⌘C · ⌘V, which is a
        // true description of every app on the machine and a useful
        // description of none of them.
        func profile(_ bundleID: String) -> String {
            ShortcutProfiles.resolved(for: NimletTarget(name: "x", kind: .app, bundleID: bundleID)).id
        }
        XCTAssertEqual(profile("com.apple.Safari"), "browser")
        XCTAssertEqual(profile("com.google.Chrome"), "browser")
        XCTAssertEqual(profile("com.microsoft.VSCode"), "editor")
        XCTAssertEqual(profile("dev.zed.Zed"), "editor")
        XCTAssertEqual(profile("com.apple.dt.Xcode"), "xcode")
        XCTAssertEqual(profile("com.anthropic.claudefordesktop"), "chat")
        XCTAssertEqual(profile("com.googlecode.iterm2"), "terminal")
    }

    func testAnAppNobodyHasDescribedKeepsThePlainSetRatherThanTheNearestOne() {
        // A browser's ⌘L in an app that uses it for something else is a button
        // that quietly does the wrong thing, which is worse than a plain one.
        XCTAssertEqual(ShortcutProfiles.guess(forBundleID: "com.apple.Notes").id, "app")
        XCTAssertEqual(ShortcutProfiles.guess(forBundleID: nil).id, "app")
        XCTAssertEqual(ShortcutProfiles.guess(forBundleID: "").id, "app")
    }

    func testABetaBuildIsTheSameAppWithASuffix() {
        // The build somebody actually runs is often the nightly, and it ships
        // the same keymap as the release it is a channel of.
        XCTAssertEqual(ShortcutProfiles.guess(forBundleID: "com.google.Chrome.canary").id, "browser")
        XCTAssertEqual(ShortcutProfiles.guess(forBundleID: "dev.zed.Zed-Preview").id, "editor")
        // Not a suffix, a different app: `com.apple.dt.Xcodes` must not become
        // Xcode by sharing a prefix with it.
        XCTAssertEqual(ShortcutProfiles.guess(forBundleID: "com.apple.dt.Xcodes").id, "app")
    }

    func testWhateverHasFocusGetsOnlyWhatIsTrueOfEveryWindow() {
        let target = NimletTarget(name: "Focused", kind: .frontmost)
        XCTAssertEqual(ShortcutProfiles.resolved(for: target).id, "app")
    }

    func testATargetIsOnlyOfferedSetsItCouldUse() {
        // Pinning a pane to the Mac app set is pinning it to a row of ⌘ keys
        // it cannot receive.
        let paneIDs = ShortcutProfiles.choices(for: .tmux).map(\.id)
        XCTAssertEqual(paneIDs, ["claude", "codex", "shell"])
        let appIDs = ShortcutProfiles.choices(for: .app).map(\.id)
        XCTAssertFalse(appIDs.contains("shell"))
        XCTAssertEqual(ShortcutProfiles.choices(for: .frontmost).map(\.id), appIDs)
    }

    // MARK: - What the sets contain

    func testEveryAgentSetCanInterruptAndCanTalk() {
        for profile in [ShortcutProfiles.claudeCode, ShortcutProfiles.codex] {
            XCTAssertTrue(profile.actions.contains { $0.chord?.key == "escape" },
                          "\(profile.name) must be able to interrupt")
            XCTAssertTrue(profile.actions.contains { $0.kind == .dictate },
                          "\(profile.name) must keep a visible way to dictate")
        }
    }

    func testEverySetKeepsAVisibleWayToDictate() {
        // Hold-to-talk on a tile is a custom gesture, and a custom gesture
        // cannot be the only way to reach a feature.
        for profile in ShortcutProfiles.all {
            XCTAssertTrue(profile.actions.contains { $0.kind == .dictate }, profile.name)
        }
    }

    func testTabAndDeleteReachAPaneAsTheKeysTheyAre() {
        // Both go two ways — `tmux send-keys` for a pane, a virtual key code
        // for a window — and neither spelling is guessable: tmux calls
        // backspace `BSpace`, and a shifted tab is `BTab` rather than a
        // modifier on `Tab`.
        XCTAssertEqual(KeyChord("tab").tmuxName, "Tab")
        XCTAssertEqual(KeyChord("delete").tmuxName, "BSpace")
        XCTAssertEqual(KeyChord("tab", shift: true).tmuxName, "BTab")
    }

    func testTabAndDeleteAreOfferedWhereTheyMeanSomething() {
        for profile in [ShortcutProfiles.claudeCode, ShortcutProfiles.shell, ShortcutProfiles.app] {
            XCTAssertTrue(profile.actions.contains { $0.chord == KeyChord("tab") },
                          "\(profile.name) should offer Tab")
        }
        // Delete is offered by the sets you type *into*. A browser or Xcode
        // row is for driving the app, not for editing a line in it, and a
        // button per key on a row that already scrolls is how a row becomes
        // unreadable.
        for profile in [ShortcutProfiles.claudeCode, ShortcutProfiles.shell, ShortcutProfiles.app,
                        ShortcutProfiles.chat, ShortcutProfiles.terminalApp] {
            XCTAssertTrue(profile.actions.contains { $0.chord == KeyChord("delete") },
                          "\(profile.name) should offer Delete")
        }
        // Codex is the exception, and deliberately: plain Tab is that profile's
        // `queue`, which is on the row already. Two buttons sending one chord
        // under two names would be a lie about one of them.
        let codexTabs = ShortcutProfiles.codex.actions.filter { $0.chord == KeyChord("tab") }
        XCTAssertEqual(codexTabs.map(\.id), ["queue"])
    }

    func testDeleteIsWrittenAndSaidAsAKeyRatherThanAWord() {
        // Without its own case both fall through to `key.uppercased()`, and a
        // settings row offers a button labelled DELETE.
        XCTAssertEqual(KeyChord("delete").display, "⌫")
        XCTAssertEqual(KeyChord("delete").spoken, "Delete")
        XCTAssertEqual(KeyChord("tab").display, "⇥")
    }

    func testNoPaneSetOffersAKeyAPaneCannotReceive() {
        for profile in [ShortcutProfiles.claudeCode, ShortcutProfiles.codex, ShortcutProfiles.shell] {
            for action in profile.actions where action.kind == .key {
                // An unbound action is a separate case, and is kept off the
                // grid rather than sent; see UnboundShortcutTests.
                guard let chord = action.chord else { continue }
                XCTAssertNotNil(chord.tmuxName,
                                "\(profile.name)/\(action.label) cannot reach a pane")
            }
        }
    }

    func testTheShellSetDoesNotPretendEscapeInterruptsAnything() {
        // Escape at a shell prompt does nothing. Offering it there would teach
        // the one gesture that matters in the place it does not work.
        let shell = ShortcutProfiles.shell
        XCTAssertFalse(shell.actions.contains { $0.chord == KeyChord("escape") })
        XCTAssertTrue(shell.actions.contains { $0.chord == KeyChord("c", control: true) })
    }

    func testProfileIdentifiersAreUniqueAndStable() {
        // They are persisted on a target, so a rename must not silently
        // repoint somebody's target at a different set.
        let ids = ShortcutProfiles.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertEqual(ids.sorted(),
                       ["app", "browser", "chat", "claude", "codex", "editor",
                        "shell", "terminal", "xcode"])
    }

    // MARK: - On the wire

    func testAChordSurvivesTheWireWithItsTargetAndItsRepeat() throws {
        let sent = ClientMessage.key(KeyPayload(chord: KeyChord("escape", repeatCount: 2),
                                                targetID: "t-3"))
        let line = try NimletCoder.line(sent)
        guard case .key(let payload) = try NimletCoder.decode(ClientMessage.self,
                                                            from: line.dropLast()) else {
            return XCTFail("decoded as something else")
        }
        XCTAssertEqual(payload.chord, KeyChord("escape", repeatCount: 2))
        XCTAssertEqual(payload.targetID, "t-3")
    }

    func testTwoOlderShapesOfAKeyStillDecodeToWhatTheyMeant() throws {
        func chord(_ json: String) throws -> KeyChord {
            try NimletCoder.decode(KeyPayload.self, from: Data(json.utf8)).chord
        }
        // v8 named five keys.
        XCTAssertEqual(try chord(#"{"key":"escape"}"#), KeyChord("escape"))
        XCTAssertEqual(try chord(#"{"key":"interrupt"}"#), KeyChord("c", control: true))
        XCTAssertEqual(try chord(#"{"key":"paste"}"#), KeyChord("v", command: true))
        // Before that, a macOS virtual key code and no target at all.
        XCTAssertEqual(try chord(#"{"keyCode":36}"#), KeyChord("enter"))
        XCTAssertEqual(try chord(#"{"keyCode":8,"command":true}"#), KeyChord("c", command: true))
        XCTAssertNil(try NimletCoder.decode(KeyPayload.self, from: Data(#"{"keyCode":53}"#.utf8)).targetID)
    }

    func testATargetWithNoProfileDecodesAsAutomaticRatherThanFailing() throws {
        let json = Data(#"{"id":"t1","name":"claude","kind":"tmux","tmuxTarget":"%3"}"#.utf8)
        let target = try NimletCoder.decode(NimletTarget.self, from: json)
        XCTAssertNil(target.profileID)
        XCTAssertEqual(ShortcutProfiles.resolved(for: target, paneCommand: "codex").id, "codex")
    }
}

/// An action the phone cannot actually perform must not become a button.
final class UnboundShortcutTests: XCTestCase {

    func testCodexsVoiceToggleIsCarriedButNotBound() {
        // The action exists in Codex's keymap; the build publishes no default
        // key for it. A guessed chord would be a button that silently does
        // nothing, which is worse than one that is not offered.
        let voice = ShortcutProfiles.codex.actions.first { $0.id == "voice" }
        XCTAssertNotNil(voice, "the action is kept so its settings row can explain itself")
        XCTAssertNil(voice?.chord)
        XCTAssertNotNil(voice?.note)
    }

    func testClaudeCodesVoiceKeyIsTheOneItsOwnDocumentationNames() {
        let voice = ShortcutProfiles.claudeCode.actions.first { $0.id == "voice" }
        XCTAssertEqual(voice?.chord, KeyChord("space"))
        // It records while held, and a phone cannot hold a key through
        // send-keys, so the note has to say what makes it work from here.
        XCTAssertEqual(voice?.note?.contains("/voice tap"), true)
    }

    func testEveryBoundActionInEveryProfileCanActuallyBeSent() {
        for profile in ShortcutProfiles.all {
            for action in profile.actions where action.kind == .key {
                guard let chord = action.chord else { continue }
                // A window is sent a `CGEvent`, so the chord has to have a key
                // code; this is the check that used to be impossible to write,
                // because the code table lived in the host and the profiles
                // live here. A profile naming a key the Mac had never heard of
                // became a button that reported success and pressed nothing.
                XCTAssertNotNil(chord.macVirtualKey,
                                "\(profile.name)/\(action.label) is not a key a Mac keyboard has")
            }
        }
        for profile in ShortcutProfiles.paneProfiles {
            for action in profile.actions where action.kind == .key {
                guard let chord = action.chord else { continue }
                XCTAssertNotNil(chord.tmuxName,
                                "\(profile.name)/\(action.label) cannot reach a pane")
            }
        }
    }

    func testAWindowSetIsAllowedTheKeysOnlyAWindowCanReceive() {
        // The point of splitting the sets: ⌘ chords are exactly what a pane
        // cannot be sent, and exactly what an app is driven by.
        for profile in ShortcutProfiles.appProfiles.filter({ $0.id != "app" }) {
            XCTAssertTrue(profile.actions.contains { $0.chord?.command == true },
                          "\(profile.name) is a window set with no ⌘ key in it")
        }
        XCTAssertNil(KeyChord("r", command: true).tmuxName)
    }

    func testTheKeysAnAppShortcutNeedsAreKeysNimletCanPress() {
        // ⌘. stops an Xcode run, ⌘[ goes back, ⌃` opens the editor's terminal.
        // None of them existed in the vocabulary before there were app sets.
        for key in [".", "[", "]", "`", ",", "/", ";", "'", "-", "=", "\\"] {
            XCTAssertNotNil(KeyChord(key).macVirtualKey, key)
        }
        for key in ["home", "end", "pageup", "pagedown", "forwarddelete", "f1", "f12"] {
            XCTAssertNotNil(KeyChord(key).macVirtualKey, key)
        }
        XCTAssertNil(KeyChord("f13").macVirtualKey, "no keyboard here has one")
        XCTAssertNil(KeyChord("£").macVirtualKey)
    }

    func testAnAppChordIsSpokenAsWordsRatherThanAsPunctuation() {
        // This is what a delivery receipt reads back, and "Command ." is not
        // something anybody says.
        XCTAssertEqual(KeyChord(".", command: true).spoken, "Command Period")
        XCTAssertEqual(KeyChord("[", command: true).display, "⌘[")
        XCTAssertEqual(KeyChord("`", control: true).spoken, "Control Backtick")
        XCTAssertEqual(KeyChord("f5").display, "F5")
    }

    func testPunctuationIsNotOfferedToAPaneEvenUnmodified() {
        // tmux reads a bare `;` argument as its own command separator, so the
        // one chord that would need escaping is the one nobody would test.
        // Every punctuation chord in the profiles carries ⌘ anyway.
        XCTAssertNil(KeyChord(";").tmuxName)
        XCTAssertNil(KeyChord("[").tmuxName)
        XCTAssertEqual(KeyChord("f5").tmuxName, "F5")
        XCTAssertEqual(KeyChord("pageup").tmuxName, "PPage")
        XCTAssertEqual(KeyChord("home").tmuxName, "Home")
    }
}

/// The dock's order is the target list's order, and the Mac owns the list.
final class TargetOrderTests: XCTestCase {

    func testAnOrderSurvivesTheWire() throws {
        let sent = ClientMessage.reorderTargets(ids: ["c", "a", "b"])
        let line = try NimletCoder.line(sent)
        guard case .reorderTargets(let ids) = try NimletCoder.decode(ClientMessage.self,
                                                                    from: line.dropLast()) else {
            return XCTFail("decoded as something else")
        }
        XCTAssertEqual(ids, ["c", "a", "b"])
    }
}

/// The three things the user named for Codex, which no fixed key row had.
final class CodexShortcutTests: XCTestCase {

    private func action(_ id: String) -> ShortcutAction? {
        ShortcutProfiles.codex.actions.first { $0.id == id }
    }

    func testSteerAndQueueAreTwoButtonsRatherThanOneWithAMode() {
        // A message sent while a turn is running either redirects that turn or
        // waits behind it. Which one you meant is a decision, and a decision
        // with no visible state is one you get wrong silently.
        XCTAssertEqual(action("steer")?.chord, KeyChord("enter"))
        XCTAssertEqual(action("queue")?.chord, KeyChord("tab"))
        XCTAssertNotEqual(action("steer")?.chord, action("queue")?.chord)
    }

    func testTypedTextCanBeThrownAwayWithoutSendingIt() {
        XCTAssertEqual(action("clear-input")?.chord, KeyChord("u", control: true))
    }

    func testStoppingTheRunIsStillTheFirstButton() {
        XCTAssertEqual(ShortcutProfiles.codex.actions.first?.chord, KeyChord("escape"))
    }

    func testEveryCodexButtonCanReachAPane() {
        for action in ShortcutProfiles.codex.actions where action.kind == .key {
            guard let chord = action.chord else { continue }
            XCTAssertNotNil(chord.tmuxName, action.label)
        }
    }

    func testTheShellKeepsItsTwoClearsApartBecauseTheyAreNotTheSameClear() {
        let shell = ShortcutProfiles.shell
        XCTAssertEqual(shell.actions.first { $0.id == "clear-input" }?.chord,
                       KeyChord("u", control: true))
        XCTAssertEqual(shell.actions.first { $0.id == "clear-screen" }?.chord,
                       KeyChord("l", control: true))
    }
}
