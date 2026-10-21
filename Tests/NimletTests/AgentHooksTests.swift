import XCTest

/// "Something needs you" from Claude Code and Codex, in a terminal or a desktop app.
final class AgentHooksTests: XCTestCase {
    private let cli = "\"/Applications/Nimlet.app/Contents/Helpers/nimlet\""

    private func json(_ text: String) -> Data { Data(text.utf8) }

    // MARK: - The payload

    func testAPermissionRequestForACommandNamesTheCommand() {
        // Codex 0.153's PermissionRequest, as it arrived in a live session.
        let payload = HookPayload(json("""
        {"hook_event_name":"PermissionRequest","tool_name":"Bash",
         "tool_input":{"command":"npm test","description":"Run the tests?"}}
        """))
        XCTAssertEqual(payload.eventName, "PermissionRequest")
        XCTAssertEqual(payload.kind, .command)
        XCTAssertEqual(payload.waitingNote, "Wants to run: npm test")
    }

    func testAQuestionIsQuotedFromEitherAgent() {
        let claude = HookPayload(json("""
        {"hook_event_name":"PreToolUse","tool_name":"AskUserQuestion",
         "tool_input":{"questions":[{"question":"Which database?","options":[]}]}}
        """))
        XCTAssertEqual(claude.waitingNote, "Asks: Which database?")

        let codex = HookPayload(json("""
        {"hook_event_name":"PreToolUse","tool_name":"request_user_input",
         "tool_input":{"questions":[{"prompt":"Ship it?"}]}}
        """))
        XCTAssertEqual(codex.waitingNote, "Asks: Ship it?")
    }

    func testAQuestionWithAShapeNobodyExpectedStillSaysItIsAQuestion() {
        let payload = HookPayload(json("""
        {"tool_name":"request_user_input","tool_input":{"items":[1,2]}}
        """))
        XCTAssertEqual(payload.waitingNote, "Has a question for you")
    }

    func testAPayloadThatIsNotJSONLeavesThePhonesOwnSentence() {
        XCTAssertNil(HookPayload(json("not json")).waitingNote)
        XCTAssertNil(HookPayload(Data()).waitingNote)
    }

    // MARK: - The settings file

    func testInstallingAddsOursAndKeepsEverythingElse() {
        let theirs: [String: Any] = [
            "model": "opus",
            "hooks": ["PermissionRequest": [["hooks": [["type": "command", "command": "/x/cc-status"]]]]],
        ]
        let entries = HookPlan.waiting(.claudeCode, cli: cli)
        let root = HookFile.adding(entries, to: theirs)

        XCTAssertEqual(root["model"] as? String, "opus")
        XCTAssertTrue(HookFile.containsAll(entries, in: root))
        let hooks = root["hooks"] as? [String: Any]
        let permission = hooks?["PermissionRequest"] as? [[String: Any]]
        XCTAssertEqual(permission?.count, 2, "the user's own hook stays, ours is a group of its own")
        XCTAssertNil(hooks?["PreToolUse"],
                     "Claude Code raises PermissionRequest for its questions too; a second hook would ask twice")
    }

    func testInstallingTwiceWritesOnce() {
        let entries = HookPlan.waiting(.codex, cli: cli)
        let once = HookFile.adding(entries, to: [:])
        let twice = HookFile.adding(entries, to: once)
        let hooks = twice["hooks"] as? [String: Any]
        XCTAssertEqual((hooks?["PermissionRequest"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual((hooks?["PreToolUse"] as? [[String: Any]])?.count, 1)
    }

    func testCodexAsksThroughItsOwnTool() {
        let entries = HookPlan.waiting(.codex, cli: cli)
        XCTAssertEqual(entries.map(\.event), ["PermissionRequest", "PreToolUse"])
        XCTAssertEqual(entries.last?.matcher, "request_user_input")
        XCTAssertTrue(entries.allSatisfy { $0.command.contains("--agent \"Codex\"") })
    }

    func testRemovingWaitingLeavesTheGateAndTheUsersHooks() {
        var root: [String: Any] = [
            "hooks": ["PreToolUse": [["hooks": [["type": "command", "command": "/x/cc-status"]]]]],
        ]
        root = HookFile.adding(HookPlan.approval(cli: cli), to: root)
        root = HookFile.adding(HookPlan.waiting(.claudeCode, cli: cli), to: root)
        root = HookFile.removing(HookPlan.waiting(.claudeCode, cli: cli), from: root)

        XCTAssertFalse(HookFile.contains(HookPlan.waiting(.claudeCode, cli: cli)[0], in: root))
        XCTAssertTrue(HookFile.containsAll(HookPlan.approval(cli: cli), in: root))
        let hooks = root["hooks"] as? [String: Any]
        XCTAssertNil(hooks?["PermissionRequest"], "an event left empty is taken out")
        XCTAssertEqual((hooks?["PreToolUse"] as? [[String: Any]])?.count, 2)
    }

    func testAStopHookFromAnOlderBuildNeedsAnUpdateAndCanStillBeRemoved() {
        // `event done || true`, before `--hook` and `--agent` existed.
        let root: [String: Any] = ["hooks": ["Stop": [["hooks": [["type": "command",
                                                                    "command": "\(cli) event done || true"]]]]]]
        XCTAssertFalse(HookFile.containsAll(HookPlan.stop(.claudeCode, cli: cli), in: root))
        XCTAssertNil(HookFile.removing(HookPlan.stop(.claudeCode, cli: cli), from: root)["hooks"])
    }

    func testInstallingUpgradesAnOldStopHookWithoutLosingOtherHooksOrOptions() throws {
        let root: [String: Any] = [
            "model": "opus",
            "hooks": ["Stop": [[
                "matcher": "*",
                "customGroupOption": true,
                "hooks": [
                    ["type": "command", "command": "\(cli) event done || true", "timeout": 7],
                    ["type": "command", "command": "/x/user-stop"],
                ],
            ]]],
        ]
        let entries = HookPlan.stop(.claudeCode, cli: cli)
        let updated = HookFile.adding(entries, to: root)
        XCTAssertTrue(HookFile.containsAll(entries, in: updated))
        XCTAssertEqual(updated["model"] as? String, "opus")
        let hooks = try XCTUnwrap(updated["hooks"] as? [String: Any])
        let groups = try XCTUnwrap(hooks["Stop"] as? [[String: Any]])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?["customGroupOption"] as? Bool, true)
        let commands = try XCTUnwrap(groups.first?["hooks"] as? [[String: Any]])
        XCTAssertEqual(commands.count, 2)
        XCTAssertEqual(commands[0]["command"] as? String, entries[0].command)
        XCTAssertEqual(commands[0]["timeout"] as? Int, 7)
        XCTAssertEqual(commands[1]["command"] as? String, "/x/user-stop")
        let once = try JSONSerialization.data(withJSONObject: updated, options: .sortedKeys)
        let twice = try JSONSerialization.data(withJSONObject: HookFile.adding(entries, to: updated), options: .sortedKeys)
        XCTAssertEqual(once, twice)
    }

    func testInstallingCollapsesDuplicateOldStopHooks() throws {
        let root: [String: Any] = ["hooks": ["Stop": [
            ["hooks": [["type": "command", "command": "nimlet event done || true"]]],
            ["hooks": [
                ["type": "command", "command": "\(cli) event done || true"],
                ["type": "command", "command": "/x/user-stop"],
            ]],
        ]]]
        let entries = HookPlan.stop(.claudeCode, cli: cli)
        let updated = HookFile.adding(entries, to: root)
        let hooks = try XCTUnwrap(updated["hooks"] as? [String: Any])
        let groups = try XCTUnwrap(hooks["Stop"] as? [[String: Any]])
        let commands = groups.flatMap { $0["hooks"] as? [[String: Any]] ?? [] }
        XCTAssertEqual(commands.compactMap { $0["command"] as? String }, [entries[0].command, "/x/user-stop"])
    }

    func testAnInterruptedCodexTurnAlsoTakesTheNoticeDown() {
        XCTAssertEqual(HookPlan.stop(.codex, cli: cli).map(\.event), ["Stop", "Interrupt"])
        XCTAssertEqual(HookPlan.stop(.claudeCode, cli: cli).map(\.event), ["Stop"])
    }

    // MARK: - Answering from the phone

    func testClaudeCodesPromptsAndQuestionsGoThroughOneAnsweringHook() {
        let entries = HookPlan.waiting(.claudeCode, cli: cli)
        XCTAssertEqual(entries.map(\.event), ["PermissionRequest"])
        XCTAssertEqual(entries.first?.verb, "answer")
        XCTAssertEqual(entries.first?.command, "\(cli) answer --hook --agent \"Claude Code\" || true")
        XCTAssertEqual(entries.first?.timeout, ApprovalWait.hookTimeoutSeconds,
                       "Claude Code ends a hook at ten minutes unless told otherwise")
        XCTAssertGreaterThan(ApprovalWait.hookTimeoutSeconds, Int(ApprovalWait.choices.max() ?? 0))
    }

    func testCodexQuestionsStillOnlyTellThePhone() {
        let entries = HookPlan.waiting(.codex, cli: cli)
        XCTAssertEqual(entries.first?.verb, "answer")
        XCTAssertEqual(entries.last?.verb, "event", "a Codex question cannot be answered from a hook")
        XCTAssertNil(entries.last?.timeout)
    }

    func testInstallingReplacesTheOldNotifyOnlyHooks() throws {
        // What 0.1.1 (45–47) wrote, beside somebody's own status hook.
        let old = "\(cli) event waiting --hook --agent \"Claude Code\" || true"
        let root: [String: Any] = ["hooks": [
            "PermissionRequest": [["hooks": [["type": "command", "command": "/x/cc-status"]]],
                                  ["hooks": [["type": "command", "command": old]]]],
            "PreToolUse": [["matcher": "AskUserQuestion", "hooks": [["type": "command", "command": old]]]],
        ]]
        let legacy = HookPlan.legacyWaiting(.claudeCode)
        XCTAssertTrue(legacy.contains { HookFile.contains($0, in: root) }, "the old hook is recognised")

        let entries = HookPlan.waiting(.claudeCode, cli: cli)
        let updated = HookFile.adding(entries, to: HookFile.removing(legacy, from: root))
        XCTAssertTrue(HookFile.containsAll(entries, in: updated))
        XCTAssertFalse(legacy.contains { HookFile.contains($0, in: updated) })
        let hooks = try XCTUnwrap(updated["hooks"] as? [String: Any])
        XCTAssertNil(hooks["PreToolUse"])
        let commands = (hooks["PermissionRequest"] as? [[String: Any]] ?? [])
            .flatMap { $0["hooks"] as? [[String: Any]] ?? [] }
            .compactMap { $0["command"] as? String }
        XCTAssertEqual(commands, ["/x/cc-status", entries[0].command])
    }

    func testAHookWithoutItsTimeoutIsOutOfDate() {
        let entries = HookPlan.approval(cli: cli)
        var bare = entries
        bare[0].timeout = nil
        let root = HookFile.adding(bare, to: [:])
        XCTAssertFalse(HookFile.containsAll(entries, in: root), "it would be cut off at ten minutes")
        XCTAssertTrue(HookFile.containsAll(entries, in: HookFile.adding(entries, to: root)))
    }

    func testTheGateNoLongerFixesItsOwnWindow() {
        XCTAssertFalse(HookPlan.approval(cli: cli)[0].command.contains("--for"))
    }

    private let askUserQuestion = """
    {"hook_event_name":"PermissionRequest","tool_name":"AskUserQuestion","permission_mode":"default",
     "tool_input":{"questions":[
       {"question":"Which database?","header":"Database","multiSelect":false,
        "options":[{"label":"Postgres","description":"The one in prod"},{"label":"SQLite","description":"Local only"}]},
       {"question":"Which checks?","header":"Checks","multiSelect":true,
        "options":[{"label":"Lint"},{"label":"Tests"}]}]}}
    """

    func testAQuestionArrivesWithItsChoices() {
        let prompt = HookAnswer.prompt(from: json(askUserQuestion), agent: .claudeCode)
        let request = HookAnswer.request(for: prompt, targetID: "t1", targetName: "claude", timeout: 600, now: 0)
        XCTAssertTrue(request.isQuestion)
        XCTAssertTrue(request.returnsToMac, "unanswered, it waits at the Mac rather than being denied")
        XCTAssertEqual(request.questions.map(\.question), ["Which database?", "Which checks?"])
        XCTAssertEqual(request.questions[0].options,
                       [ApprovalOption(label: "Postgres", detail: "The one in prod"),
                        ApprovalOption(label: "SQLite", detail: "Local only")])
        XCTAssertTrue(request.questions[1].allowsMultiple)
        XCTAssertEqual(request.expiresAtEpochMillis, 600_000)
    }

    func testAnAnswerGoesBackAsTheToolsOwnInputWithAnswers() throws {
        let prompt = HookAnswer.prompt(from: json(askUserQuestion), agent: .claudeCode)
        let resolution = ApprovalResolution(requestID: "r", decision: .approve, reason: .answered,
                                            byDeviceName: "iPhone", answers: ["SQLite", "Lint, Tests"])
        let data = try XCTUnwrap(HookAnswer.output(for: resolution, prompt: prompt))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let specific = try XCTUnwrap(object["hookSpecificOutput"] as? [String: Any])
        XCTAssertEqual(specific["hookEventName"] as? String, "PermissionRequest")
        let decision = try XCTUnwrap(specific["decision"] as? [String: Any])
        XCTAssertEqual(decision["behavior"] as? String, "allow")
        let input = try XCTUnwrap(decision["updatedInput"] as? [String: Any])
        XCTAssertEqual(input["answers"] as? [String: String],
                       ["Which database?": "SQLite", "Which checks?": "Lint, Tests"])
        XCTAssertEqual((input["questions"] as? [Any])?.count, 2, "the tool's own input survives the trip")
    }

    func testNothingIsPrintedUnlessSomebodyAnswered() {
        let prompt = HookAnswer.prompt(from: json(askUserQuestion), agent: .claudeCode)
        for reason in [ApprovalResolution.Reason.expired, .withdrawn, .refused, .handedBack] {
            let resolution = ApprovalResolution(requestID: "r", decision: .deny, reason: reason)
            XCTAssertNil(HookAnswer.output(for: resolution, prompt: prompt),
                         "\(reason) must leave the agent's own prompt, never decide")
        }
        // A yes with no answers in it — a phone a release behind.
        let blank = ApprovalResolution(requestID: "r", decision: .approve, reason: .answered)
        XCTAssertNil(HookAnswer.output(for: blank, prompt: prompt))
    }

    private let bashPrompt = """
    {"hook_event_name":"PermissionRequest","tool_name":"Bash",
     "tool_input":{"command":"mkdir -p build-out && touch build-out/x.txt"},
     "permission_suggestions":[{"type":"addRules","behavior":"allow","destination":"localSettings",
       "rules":[{"toolName":"Bash","ruleContent":"mkdir -p build-out"},{"toolName":"Bash","ruleContent":"touch build-out/x.txt"}]}]}
    """

    func testAPermissionPromptOffersTheAgentsOwnStandingRule() throws {
        let prompt = HookAnswer.prompt(from: json(bashPrompt), agent: .claudeCode)
        XCTAssertEqual(prompt.alwaysAllowRule, "mkdir -p build-out, touch build-out/x.txt")
        let request = HookAnswer.request(for: prompt, targetID: nil, targetName: "Claude Code", timeout: 120)
        XCTAssertFalse(request.isQuestion)
        XCTAssertEqual(request.kind, .command)
        XCTAssertEqual(request.alwaysAllowRule, prompt.alwaysAllowRule)

        let always = ApprovalResolution(requestID: "r", decision: .approve, reason: .answered, alwaysAllow: true)
        let data = try XCTUnwrap(HookAnswer.output(for: always, prompt: prompt))
        let decision = try XCTUnwrap(((JSONSerialization.jsonObject(with: data) as? [String: Any])?["hookSpecificOutput"]
            as? [String: Any])?["decision"] as? [String: Any])
        XCTAssertEqual(decision["behavior"] as? String, "allow")
        let rules = try XCTUnwrap(decision["updatedPermissions"] as? [[String: Any]])
        XCTAssertEqual(rules.first?["destination"] as? String, "localSettings", "passed back untouched")
        XCTAssertNil(decision["updatedInput"])
    }

    func testADenialTellsTheAgentWhoAndWhy() throws {
        let prompt = HookAnswer.prompt(from: json(bashPrompt), agent: .claudeCode)
        let denial = ApprovalResolution(requestID: "r", decision: .deny, reason: .answered,
                                        byDeviceName: "Renyi's iPhone", note: "Wrong directory")
        let data = try XCTUnwrap(HookAnswer.output(for: denial, prompt: prompt))
        let decision = try XCTUnwrap(((JSONSerialization.jsonObject(with: data) as? [String: Any])?["hookSpecificOutput"]
            as? [String: Any])?["decision"] as? [String: Any])
        XCTAssertEqual(decision["behavior"] as? String, "deny")
        XCTAssertEqual(decision["message"] as? String,
                       "The user denied this from Renyi's iPhone through Nimlet. They said: Wrong directory")
    }

    func testARuleThatCannotBePutInWordsIsNotOffered() {
        let odd = """
        {"tool_name":"Bash","tool_input":{"command":"x"},
         "permission_suggestions":[{"type":"setMode","mode":"bypassPermissions","destination":"session"}]}
        """
        XCTAssertNil(HookAnswer.prompt(from: json(odd), agent: .claudeCode).alwaysAllowRule)
        let edits = """
        {"tool_name":"Edit","tool_input":{"file_path":"/x"},
         "permission_suggestions":[{"type":"setMode","mode":"acceptEdits","destination":"session"}]}
        """
        XCTAssertEqual(HookAnswer.prompt(from: json(edits), agent: .claudeCode).alwaysAllowRule,
                       "edits for the rest of this session")
    }

    func testCodexIsOnlyEverToldAllowOrDeny() throws {
        // Codex rejects any other field in a PermissionRequest decision.
        let codex = """
        {"hook_event_name":"PermissionRequest","tool_name":"Bash","turn_id":"t",
         "tool_input":{"command":"touch x"},
         "permission_suggestions":[{"type":"addRules","behavior":"allow","rules":[{"toolName":"Bash","ruleContent":"touch x"}]}]}
        """
        let prompt = HookAnswer.prompt(from: json(codex), agent: .codex)
        XCTAssertNil(prompt.alwaysAllowRule)
        let approve = ApprovalResolution(requestID: "r", decision: .approve, reason: .answered, alwaysAllow: true)
        let data = try XCTUnwrap(HookAnswer.output(for: approve, prompt: prompt))
        let decision = try XCTUnwrap(((JSONSerialization.jsonObject(with: data) as? [String: Any])?["hookSpecificOutput"]
            as? [String: Any])?["decision"] as? [String: Any])
        XCTAssertEqual(decision.keys.sorted(), ["behavior"])
    }

    func testAQuestionsNoteNamesItsChoices() {
        let payload = HookPayload(json(askUserQuestion))
        XCTAssertEqual(payload.waitingNote, "Asks: Which database? — Postgres · SQLite")
    }

    func testTheWaitingHookIsNotMistakenForTheGate() {
        let waiting = HookPlan.waiting(.claudeCode, cli: cli)
        let root = HookFile.adding(waiting, to: [:])
        XCTAssertFalse(HookFile.containsAll(HookPlan.approval(cli: cli), in: root))
    }

    // MARK: - Which app

    func testTheClaudeDesktopAppIsFoundAboveClaudeCodesOwnBundle() {
        // As this very session's ancestry read on the Mac it was written on.
        let ancestors = [
            "/bin/zsh",
            "/Users/me/Library/Application Support/Claude/claude-code/2.1.293/x/claude.app/Contents/MacOS/claude",
            "/Applications/Claude.app/Contents/Helpers/disclaimer",
            "/Applications/Claude.app/Contents/MacOS/Claude",
        ]
        XCTAssertEqual(HookAncestry.appBundle(ancestors: ancestors), "/Applications/Claude.app")
    }

    func testChatGPTsCodexIsChatGPTNotItsNestedCLI() {
        let ancestors = [
            "/bin/sh",
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT",
        ]
        XCTAssertEqual(HookAncestry.appBundle(ancestors: ancestors), "/Applications/ChatGPT.app")
    }

    func testTmuxHasNoApp() {
        XCTAssertNil(HookAncestry.appBundle(ancestors: ["/bin/zsh", "/opt/homebrew/bin/tmux"]))
    }

    // MARK: - The wire

    func testAnEventFromNobodysTargetCarriesItsName() throws {
        let event = AgentEvent(targetID: "agent.codex", kind: .waiting, atEpochMillis: 1,
                               note: "Wants to run: npm test", sourceName: "Codex")
        let data = try JSONEncoder().encode(event)
        XCTAssertEqual(try JSONDecoder().decode(AgentEvent.self, from: data), event)

        let withoutName = try JSONDecoder().decode(AgentEvent.self, from: Data("""
        {"targetID":"t","kind":"done","atEpochMillis":0}
        """.utf8))
        XCTAssertNil(withoutName.sourceName)
    }
}
