import Foundation

/// The agents Nimlet writes hooks for, and what it writes.
///
/// Claude Code and Codex share one hook format — a JSON file mapping an event
/// name to groups of `{matcher, hooks: [{type: "command", command}]}` — and,
/// as of Codex 0.153, the same event names and the same payload shape for the
/// two events that matter here. So one description serves both files, and the
/// differences are the file's path and the name of the tool that asks the user
/// a question.
public enum HookAgent: String, CaseIterable, Sendable {
    case claudeCode
    case codex

    /// What the phone calls it when no target owns the place it runs in.
    public var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        }
    }

    /// Relative to the home directory.
    public var settingsPath: String {
        switch self {
        case .claudeCode: return ".claude/settings.json"
        case .codex: return ".codex/hooks.json"
        }
    }

    /// The tool an agent calls to put a question to the user and wait. Asking
    /// is not a permission prompt, so `PermissionRequest` never sees it; it is
    /// caught on its way in instead.
    public var questionTool: String {
        switch self {
        case .claudeCode: return "AskUserQuestion"
        case .codex: return "request_user_input"
        }
    }
}

/// One hook entry Nimlet owns: which event, which tools, which `nimlet` verb.
public struct HookEntry: Equatable, Sendable {
    public var event: String
    public var matcher: String?
    /// The word after `nimlet` that marks the entry as ours: `event`, `answer`
    /// or `gate`.
    public var verb: String
    public var command: String
    /// Seconds the agent lets the hook run, for a hook that waits on a person.
    /// Both agents end a hook that runs past its timeout, and Claude Code's
    /// default is ten minutes — shorter than a wait the person may have chosen.
    public var timeout: Int?

    public init(event: String, matcher: String? = nil, verb: String, command: String, timeout: Int? = nil) {
        self.event = event
        self.matcher = matcher
        self.verb = verb
        self.command = command
        self.timeout = timeout
    }
}

/// The hook entries for each switch in Settings → Agents.
///
/// `cli` is the command that starts the tool, already quoted for a shell.
public enum HookPlan {
    /// "Something needs you": the agent is about to show a permission prompt
    /// or ask a question, and the phone can answer it.
    ///
    /// One `PermissionRequest` hook carries both, because both agents raise it
    /// for a permission prompt and Claude Code raises it for `AskUserQuestion`
    /// too (2.1.289: the hook's `updatedInput.answers` answers the question).
    /// The hook holds the prompt until the phone, the menu bar or the agent's
    /// own prompt answers it, and says nothing back if nobody does — which
    /// leaves the agent's prompt on the Mac, never approves.
    ///
    /// Claude Code shows its own prompt while the hook waits and kills the
    /// hook when somebody answers there, so the two race and the first answer
    /// wins. Codex shows its prompt only once the hook returns; see
    /// `nimlet answer` for how that is kept from hiding it at the desk.
    ///
    /// Codex's question tool cannot be answered from a hook — its
    /// `PermissionRequest` decision takes no input — so that one still only
    /// tells the phone.
    public static func waiting(_ agent: HookAgent, cli: String) -> [HookEntry] {
        var entries = [HookEntry(event: "PermissionRequest", verb: "answer",
                                 command: "\(cli) answer --hook --agent \"\(agent.displayName)\" || true",
                                 timeout: ApprovalWait.hookTimeoutSeconds)]
        if agent == .codex {
            entries.append(HookEntry(event: "PreToolUse", matcher: agent.questionTool, verb: "event",
                                     command: "\(cli) event waiting --hook --agent \"\(agent.displayName)\" || true"))
        }
        return entries
    }

    /// What earlier builds wrote for the same switch: `event waiting` on the
    /// permission prompt, and on Claude Code's question tool, which now
    /// reaches the `PermissionRequest` hook as well and would report twice.
    /// Taken out when the switch is installed or removed.
    public static func legacyWaiting(_ agent: HookAgent) -> [HookEntry] {
        var entries = [HookEntry(event: "PermissionRequest", verb: "event", command: "")]
        if agent == .claudeCode {
            entries.append(HookEntry(event: "PreToolUse", matcher: agent.questionTool, verb: "event", command: ""))
        }
        return entries
    }

    /// "Finished": takes down a "waiting" that was answered at the Mac.
    ///
    /// Codex also needs `Interrupt`: pressing Esc on its permission prompt
    /// ("No, and tell Codex what to do differently") aborts the turn, and an
    /// aborted turn never reaches `Stop` — so without it the phone would go on
    /// saying "waiting for you" about a prompt that is gone. Codex allows an
    /// `Interrupt` hook one second, and finding the Mac over Bonjour takes
    /// longer, so that one is sent off in the background and returns at once.
    public static func stop(_ agent: HookAgent, cli: String) -> [HookEntry] {
        let done = "\(cli) event done --hook --agent \"\(agent.displayName)\""
        var entries = [HookEntry(event: "Stop", verb: "event", command: done + " || true")]
        if agent == .codex {
            entries.append(HookEntry(event: "Interrupt", verb: "event",
                                     command: done + " </dev/null >/dev/null 2>&1 &"))
        }
        return entries
    }

    /// The gate is Claude Code's alone. Codex's `PreToolUse` cannot say
    /// "allow" without rewriting the input, so a gate there could only ever
    /// deny; its `PermissionRequest` is the place, and that is a different
    /// contract nobody has round-tripped yet.
    ///
    /// No `--for`: the gate waits as long as Settings → Agents says, and
    /// denies when that runs out.
    public static func approval(cli: String) -> [HookEntry] {
        [HookEntry(event: "PreToolUse", matcher: "Bash", verb: "gate",
                   command: "\(cli) gate --tools Bash",
                   timeout: ApprovalWait.hookTimeoutSeconds)]
    }
}

/// Reads and edits the `hooks` object of a settings file, leaving everything
/// that is not ours exactly as it was.
///
/// Ours means a command that runs `nimlet <verb>` — by the bundled path, by
/// the bare name, or by any path ending in `/nimlet` — so an entry somebody
/// wrote by hand from `nimlet hook` counts too. Installing updates our command
/// in place, so an older hook does not keep running without the current flags.
public enum HookFile {
    public static func contains(_ entry: HookEntry, in root: [String: Any]) -> Bool {
        let hooks = root["hooks"] as? [String: Any] ?? [:]
        return groups(hooks[entry.event]).contains { group in
            matcher(of: group) == entry.matcher
                && commands(of: group).contains { isOurs($0, verb: entry.verb) }
        }
    }

    public static func containsAll(_ entries: [HookEntry], in root: [String: Any]) -> Bool {
        let hooks = root["hooks"] as? [String: Any] ?? [:]
        return !entries.isEmpty && entries.allSatisfy { entry in
            groups(hooks[entry.event]).contains { group in
                matcher(of: group) == entry.matcher
                    && (group["hooks"] as? [[String: Any]] ?? []).contains { hook in
                        hook["command"] as? String == entry.command
                            && (entry.timeout == nil || (hook["timeout"] as? NSNumber)?.intValue == entry.timeout)
                    }
            }
        }
    }

    public static func adding(_ entries: [HookEntry], to root: [String: Any]) -> [String: Any] {
        var root = root
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for entry in entries {
            var installed = false
            var list = groups(hooks[entry.event]).compactMap { group -> [String: Any]? in
                guard matcher(of: group) == entry.matcher else { return group }
                guard let original = group["hooks"] as? [[String: Any]] else { return group }
                let updated = original.compactMap { hook -> [String: Any]? in
                    guard isOurs(hook["command"] as? String, verb: entry.verb) else { return hook }
                    // Keep one invocation and its options. A second copy would
                    // report the same event twice.
                    guard !installed else { return nil }
                    installed = true
                    var hook = hook
                    hook["command"] = entry.command
                    if let timeout = entry.timeout { hook["timeout"] = timeout }
                    return hook
                }
                guard !updated.isEmpty else { return nil }
                var group = group
                group["hooks"] = updated
                return group
            }
            if !installed {
                var hook: [String: Any] = ["type": "command", "command": entry.command]
                if let timeout = entry.timeout { hook["timeout"] = timeout }
                var group: [String: Any] = ["hooks": [hook]]
                if let matcher = entry.matcher { group["matcher"] = matcher }
                list.append(group)
            }
            hooks[entry.event] = list
        }
        root["hooks"] = hooks
        return root
    }

    /// Takes out our commands for these entries' events and verbs. Matched
    /// loosely on purpose — by event, matcher and verb, not by the exact
    /// command — so an entry written by an older build, or by hand, goes too.
    public static func removing(_ entries: [HookEntry], from root: [String: Any]) -> [String: Any] {
        guard var hooks = root["hooks"] as? [String: Any] else { return root }
        for entry in entries {
            let kept = groups(hooks[entry.event]).compactMap { group -> [String: Any]? in
                guard matcher(of: group) == entry.matcher else { return group }
                var group = group
                let left = (group["hooks"] as? [[String: Any]] ?? [])
                    .filter { !isOurs($0["command"] as? String, verb: entry.verb) }
                guard !left.isEmpty else { return nil }
                group["hooks"] = left
                return group
            }
            if kept.isEmpty { hooks.removeValue(forKey: entry.event) } else { hooks[entry.event] = kept }
        }
        var root = root
        if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
        return root
    }

    public static func isOurs(_ command: String?, verb: String) -> Bool {
        guard let command else { return false }
        // `nimlet event …`, `"/Applications/Nimlet.app/Contents/Helpers/nimlet" event …`,
        // `/usr/local/bin/nimlet event …` — the word before the verb is what
        // makes it ours.
        let pattern = "(^|[\\s\"'/])nimlet\"?\\s+\(verb)(\\s|$)"
        return command.range(of: pattern, options: .regularExpression) != nil
    }

    private static func groups(_ value: Any?) -> [[String: Any]] {
        value as? [[String: Any]] ?? []
    }

    /// An empty matcher matches every tool, the same as none at all.
    private static func matcher(of group: [String: Any]) -> String? {
        guard let matcher = group["matcher"] as? String, !matcher.isEmpty, matcher != "*" else { return nil }
        return matcher
    }

    private static func commands(of group: [String: Any]) -> [String?] {
        (group["hooks"] as? [[String: Any]] ?? []).map { $0["command"] as? String }
    }
}

/// What a hook payload carries, read defensively.
///
/// The shape is `{"hook_event_name": "...", "tool_name": "...", "tool_input":
/// {...}}` from Claude Code and Codex alike, but this runs wherever the user
/// puts it: an unrecognised payload is described rather than dropped, because
/// refusing to parse would mean refusing to ask, and refusing to ask would
/// mean the tool call goes through unseen.
public struct HookPayload {
    public var eventName: String?
    public var toolName: String?
    public var title: String
    public var detail: String
    public var kind: ApprovalRequest.Kind
    /// The question, when the tool is one that asks the user something.
    public var question: String?
    /// Its choices, when it offered any.
    public var options: [ApprovalOption] = []

    public init(_ data: Data) {
        let text = String(data: data, encoding: .utf8) ?? ""
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        eventName = object?["hook_event_name"] as? String
        toolName = object?["tool_name"] as? String
        let input = object?["tool_input"] as? [String: Any]

        switch toolName {
        case "Bash", "shell", "exec_command":
            kind = .command
            title = "Run a command"
            detail = (input?["command"] as? String) ?? (input?["cmd"] as? String) ?? text
        case "Write", "Edit", "NotebookEdit", "apply_patch":
            kind = .edit
            title = "Write to a file"
            detail = (input?["file_path"] as? String) ?? text
        case "WebFetch", "WebSearch":
            kind = .network
            title = "Reach the network"
            detail = (input?["url"] as? String) ?? (input?["query"] as? String) ?? text
        case .some(let name) where HookAgent.allCases.contains(where: { $0.questionTool == name }):
            kind = .other
            title = "Ask you something"
            question = Self.question(in: input)
            options = HookAnswer.questions(in: input).first?.options ?? []
            detail = question ?? Self.describe(input) ?? text
        case .some(let name):
            kind = .other
            title = "Use \(name)"
            detail = Self.describe(input) ?? text
        case nil:
            kind = .other
            title = "Asking permission"
            detail = text.isEmpty ? "(the hook sent nothing)" : text
        }
        if detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            detail = "(no detail in the hook payload)"
        }
    }

    /// What the phone's "waiting for you" says, when the payload says enough
    /// to say more than that. Nil leaves the phone's own sentence.
    public var waitingNote: String? {
        if let question {
            // The choices too, when there are a few: on a lock screen they are
            // most of what makes the question answerable at a glance.
            let labels = options.prefix(4).map(\.label).filter { !$0.isEmpty }
            return labels.isEmpty ? "Asks: " + question : "Asks: \(question) — " + labels.joined(separator: " · ")
        }
        switch kind {
        case .command: return "Wants to run: " + detail
        case .edit: return "Wants to edit: " + detail
        case .network: return "Wants to reach: " + detail
        case .other:
            guard let toolName else { return nil }
            return HookAgent.allCases.contains(where: { $0.questionTool == toolName })
                ? "Has a question for you"
                : "Wants to use " + toolName
        }
    }

    /// `AskUserQuestion` carries `questions: [{question, …}]`; Codex's
    /// `request_user_input` the same list. A bare `question` or `prompt` is
    /// accepted too, because these shapes are not anybody's stable API.
    private static func question(in input: [String: Any]?) -> String? {
        guard let input else { return nil }
        let candidates: [Any?] = [
            (input["questions"] as? [[String: Any]])?.first?["question"],
            (input["questions"] as? [[String: Any]])?.first?["prompt"],
            input["question"],
            input["prompt"],
        ]
        return candidates.lazy
            .compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    private static func describe(_ input: [String: Any]?) -> String? {
        guard let input, !input.isEmpty else { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: input,
                                                     options: [.prettyPrinted, .sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// A permission prompt or a question, from the hook holding it to the phone,
/// and the answer back in the shape the agent reads.
///
/// Pure, so the two halves the agents depend on — what a payload becomes and
/// what an answer prints — are tested without an agent, a Mac or a phone. The
/// shapes were checked against Claude Code 2.1.289 (terminal and SDK mode) and
/// Codex 0.153.4 on 2026-10-14.
public enum HookAnswer {

    /// What the hook read, kept whole: the answer to a question is the tool's
    /// own input with `answers` added, so the input has to survive the trip.
    public struct Prompt {
        public var agent: HookAgent
        public var payload: HookPayload
        public var toolInput: [String: Any]?
        public var questions: [ApprovalQuestion]
        /// Claude Code's `permission_suggestions`: what "yes, and don't ask
        /// again" would add. Passed back untouched when that is chosen.
        public var suggestions: [[String: Any]]?
        public var alwaysAllowRule: String?
    }

    public static func prompt(from data: Data, agent: HookAgent) -> Prompt {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let input = object?["tool_input"] as? [String: Any]
        let toolName = object?["tool_name"] as? String
        // Only Claude Code's question tool takes an answer through this hook.
        let questions = agent == .claudeCode && toolName == HookAgent.claudeCode.questionTool
            ? Self.questions(in: input) : []
        var suggestions: [[String: Any]]?
        var rule: String?
        if agent == .claudeCode, questions.isEmpty,
           let offered = object?["permission_suggestions"] as? [[String: Any]], !offered.isEmpty {
            rule = describe(offered, toolName: toolName)
            // Offered only when every part of it can be said in words. A rule
            // somebody approves has to be a rule they have read.
            suggestions = rule == nil ? nil : offered
        }
        return Prompt(agent: agent, payload: HookPayload(data), toolInput: input,
                      questions: questions, suggestions: suggestions, alwaysAllowRule: rule)
    }

    public static func request(for prompt: Prompt,
                               id: String = UUID().uuidString,
                               targetID: String?,
                               targetName: String,
                               timeout: TimeInterval,
                               now: Int64 = ApprovalClock.now()) -> ApprovalRequest {
        let asking = !prompt.questions.isEmpty
        return ApprovalRequest(id: id,
                               targetID: targetID,
                               targetName: targetName,
                               title: asking ? "Has a question" : prompt.payload.title,
                               detail: asking
                                   ? prompt.questions.map(\.question).joined(separator: "\n")
                                   : prompt.payload.detail,
                               kind: prompt.payload.kind,
                               createdAtEpochMillis: now,
                               timeout: timeout,
                               questions: prompt.questions,
                               alwaysAllowRule: prompt.alwaysAllowRule,
                               returnsToMac: true)
    }

    /// The hook's stdout for this resolution, or nil to print nothing — which
    /// both agents read as "no decision" and answer with their own prompt.
    /// Expired, withdrawn, refused and handed back all land there: nothing
    /// becomes a yes by not being answered.
    public static func output(for resolution: ApprovalResolution, prompt: Prompt) -> Data? {
        guard resolution.reason == .answered else { return nil }
        var decision: [String: Any]
        switch resolution.decision {
        case .deny:
            decision = ["behavior": "deny", "message": denial(resolution, isQuestion: !prompt.questions.isEmpty)]
        case .approve:
            decision = ["behavior": "allow"]
            if !prompt.questions.isEmpty {
                guard let answers = resolution.answers, answers.count == prompt.questions.count,
                      prompt.agent == .claudeCode else { return nil }
                var input = prompt.toolInput ?? [:]
                var byQuestion: [String: String] = [:]
                for (question, answer) in zip(prompt.questions, answers) { byQuestion[question.question] = answer }
                input["answers"] = byQuestion
                decision["updatedInput"] = input
            } else if resolution.alwaysAllow, let suggestions = prompt.suggestions {
                decision["updatedPermissions"] = suggestions
            }
        }
        let output: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PermissionRequest",
                                                            "decision": decision]]
        return try? JSONSerialization.data(withJSONObject: output, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    /// What the agent reads with a no. Who said it and why, so it can change
    /// course rather than ask again.
    static func denial(_ resolution: ApprovalResolution, isQuestion: Bool) -> String {
        let place = resolution.byDeviceName ?? "the Mac"
        let head = isQuestion
            ? "The user declined to answer, from \(place) through Nimlet."
            : "The user denied this from \(place) through Nimlet."
        guard let note = resolution.note, !note.isEmpty else { return head }
        return head + " They said: " + note
    }

    /// `AskUserQuestion`'s `questions: [{question, header, options: [{label,
    /// description}], multiSelect}]`. Questions with no text are dropped; the
    /// agent would have nothing to match an answer to.
    static func questions(in input: [String: Any]?) -> [ApprovalQuestion] {
        guard let list = input?["questions"] as? [[String: Any]] else { return [] }
        return list.compactMap { item in
            guard let text = (item["question"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { return nil }
            let options = (item["options"] as? [[String: Any]] ?? []).compactMap { option -> ApprovalOption? in
                guard let label = option["label"] as? String, !label.isEmpty else { return nil }
                return ApprovalOption(label: label, detail: option["description"] as? String)
            }
            return ApprovalQuestion(question: text,
                                    header: item["header"] as? String,
                                    options: options,
                                    allowsMultiple: item["multiSelect"] as? Bool ?? false)
        }
    }

    /// "touch build/x.txt", "WebFetch(domain:example.com)", "edits for the rest
    /// of this session". Nil when any part is a kind this cannot put in words.
    static func describe(_ suggestions: [[String: Any]], toolName: String?) -> String? {
        var parts: [String] = []
        for suggestion in suggestions {
            switch suggestion["type"] as? String {
            case "addRules":
                guard (suggestion["behavior"] as? String) == "allow",
                      let rules = suggestion["rules"] as? [[String: Any]], !rules.isEmpty else { return nil }
                for rule in rules {
                    guard let tool = rule["toolName"] as? String else { return nil }
                    if let content = rule["ruleContent"] as? String, !content.isEmpty {
                        parts.append(tool == toolName ? content : "\(tool)(\(content))")
                    } else {
                        parts.append(tool == toolName ? "every \(tool) call" : tool)
                    }
                }
            case "setMode":
                guard (suggestion["mode"] as? String) == "acceptEdits" else { return nil }
                parts.append("edits for the rest of this session")
            case "addDirectories":
                guard let directories = suggestion["directories"] as? [String], !directories.isEmpty else { return nil }
                parts.append("files in " + directories.joined(separator: ", "))
            default:
                return nil
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}

/// Which app a hook is running inside, from the executables of its ancestors.
///
/// A hook in a terminal outside tmux descends from the terminal; one in the
/// Claude desktop app from Claude.app; one in ChatGPT's Codex from
/// ChatGPT.app. Each has an app bundle somewhere above it, and that bundle's
/// identifier is what an `app` target is pointed at.
public enum HookAncestry {
    /// The app bundle the *topmost* of these executables lives in, taking the
    /// outermost `.app` in its path. Topmost, because the nearest is often an
    /// app of its own nested inside the real one: Claude Code ships as a small
    /// `claude.app` in Application Support, and ChatGPT runs Codex from a
    /// `CodexCLI.app` in its own Resources. Outermost, because a helper's path
    /// is `Claude.app/Contents/Helpers/…` or `ChatGPT.app/…/Codex (Service).app/…`.
    ///
    /// `ancestors` runs from the parent upward. The caller's own executable is
    /// left out: `nimlet` lives inside Nimlet.app, and every hook would
    /// otherwise belong to it.
    public static func appBundle(ancestors: [String]) -> String? {
        ancestors.compactMap(outermostApp(in:)).last
    }

    static func outermostApp(in path: String) -> String? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard let index = parts.firstIndex(where: { $0.hasSuffix(".app") }) else { return nil }
        return parts[...index].joined(separator: "/")
    }
}
