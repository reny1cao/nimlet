import AppKit
import Foundation

// MARK: - pair

private struct PairOutput: Encodable {
    let ok = true
    let configPath: String
    let host: String?
}

func commandPair(_ arguments: inout Arguments) throws {
    guard let code = try arguments.option("--code") else {
        throw CLIError(.usage, "nimlet pair needs --code (the six characters in Nimlet Settings → Agents)")
    }
    let host = try arguments.option("--host")
    try arguments.finish()

    if let problem = PairingCode.validate(code) {
        throw CLIError(.usage, problem.message)
    }

    // Re-pairing keeps the device id, so rotating the code on the Mac does not
    // also make this machine a stranger that has to be approved again.
    var config = (try? Config.load()) ?? Config.fresh()
    config.pairingCode = PairingCode.normalize(code)
    if let host {
        config.hostName = host.isEmpty ? nil : host
    }
    try config.save()

    Output.say("Saved \(Config.url.path)")
    if let name = config.hostName {
        Output.say("Will look for \(name). Run `nimlet list` to check.")
    } else {
        Output.say("Run `nimlet list` to check.")
    }
    Output.emit(PairOutput(configPath: Config.url.path, host: config.hostName))
}

// MARK: - list

private struct TargetLine: Encodable {
    let id: String
    let name: String
    let kind: String
    let detail: String?
    let stableTmuxID: Bool
    let active: Bool
}

private struct ListOutput: Encodable {
    let host: String
    let protocolVersion: Int
    let accessibilityGranted: Bool
    let injectionPaused: Bool
    let deviceApproved: Bool
    let tmuxAvailable: Bool
    let targets: [TargetLine]
}

func commandList(_ arguments: inout Arguments, timeout: Double?) throws {
    try arguments.finish()
    let (session, status, targets) = try openSession(timeout: timeout ?? 15)
    defer { session.close() }

    let lines = targets.map { target in
        TargetLine(id: target.id,
                   name: target.name,
                   kind: target.kind.rawValue,
                   detail: target.bundleID ?? target.tmuxTarget,
                   stableTmuxID: target.hasStableTmuxID,
                   active: target.id == status.activeTargetID)
    }
    Output.emit(ListOutput(host: status.hostName,
                           protocolVersion: status.protocolVersion,
                           accessibilityGranted: status.accessibilityGranted,
                           injectionPaused: status.injectionPaused,
                           deviceApproved: status.deviceApproved,
                           tmuxAvailable: status.tmuxAvailable,
                           targets: lines))

    Output.say("host: \(status.hostName) (protocol \(status.protocolVersion))")
    Output.say("accessibility: \(status.accessibilityGranted ? "granted" : "NOT GRANTED — clicks and typing are swallowed")")
    Output.say("injection: \(status.injectionPaused ? "paused" : "active")")
    Output.say("device: \(status.deviceApproved ? "approved" : "NOT APPROVED — approve \(Config.deviceName) in the Nimlet menu")")
    Output.say("tmux: \(status.tmuxAvailable ? "available" : "not installed")")

    guard !targets.isEmpty else {
        Output.say("")
        Output.say("no targets — add one with `nimlet target add --tmux %3`, or in Nimlet's Settings")
        return
    }

    let idWidth = max(2, targets.map(\.id.count).max() ?? 2)
    let nameWidth = max(4, targets.map(\.name.count).max() ?? 4)
    func pad(_ text: String, _ width: Int) -> String {
        text.padding(toLength: max(width, text.count), withPad: " ", startingAt: 0)
    }

    Output.say("")
    Output.say("  \(pad("ID", idWidth))  \(pad("NAME", nameWidth))  KIND       DETAIL")
    for target in targets {
        var detail = target.bundleID ?? target.tmuxTarget ?? "—"
        if target.kind == .tmux, !target.hasStableTmuxID {
            detail += "  (positional — renumbers when a pane closes)"
        }
        let marker = target.id == status.activeTargetID ? "* " : "  "
        Output.say("\(marker)\(pad(target.id, idWidth))  \(pad(target.name, nameWidth))  \(pad(target.kind.rawValue, 9))  \(detail)")
    }
}

// MARK: - target add

private struct TargetAddOutput: Encodable {
    let ok = true
    let target: NimletTarget
    let message: String
}

func commandTarget(_ arguments: inout Arguments, timeout: Double?) throws {
    guard let verb = arguments.takePositional() else {
        throw CLIError(.usage, "nimlet target needs a verb: add or remove")
    }
    switch verb {
    case "add": break
    case "remove":
        try commandTargetRemove(&arguments, timeout: timeout)
        return
    default:
        throw CLIError(.usage, "unknown target verb: \(verb)")
    }
    guard let spec = try arguments.option("--tmux") else {
        throw CLIError(.usage, "nimlet target add needs --tmux (a pane id such as %3, or a spec such as codex:0.1)")
    }
    let name = try arguments.option("--name")
    let blockAutoSubmit = arguments.flag("--no-auto-submit")
    try arguments.finish()

    let pane = try resolvePane(spec)
    let target = NimletTarget(name: name ?? pane.label,
                            kind: .tmux,
                            tmuxTarget: pane.id,
                            allowAutoSubmit: !blockAutoSubmit,
                            symbol: "terminal")

    // The host owns the target list and rewrites the whole of it whenever
    // anything changes, so writing the saved copy from here would be invisible
    // to the running app and then lost the next time it saved. Ask it instead.
    let (session, status, _) = try openSession(timeout: timeout ?? 15)
    defer { session.close() }
    warnAbout(status)

    session.send(.addTarget(target))
    let reply = try session.receive { message in
        switch message {
        case .toast, .error: return true
        default: return false
        }
    }

    switch reply {
    case .toast(let message):
        Output.say(message + (blockAutoSubmit ? " (Nimlet will never press Return on it)" : ""))
        Output.emit(TargetAddOutput(target: target, message: message))
    case .error(let reason):
        throw CLIError(.refused, reason)
    default:
        throw CLIError(.refused, "unexpected reply from the host")
    }
}

private struct TargetRemoveOutput: Encodable {
    let ok = true
    let id: String
    let name: String
}

/// The other half of `target add`. Added because removing one meant editing
/// the Mac's saved list behind the running app, which it would have silently
/// overwritten.
func commandTargetRemove(_ arguments: inout Arguments, timeout: Double?) throws {
    let selector = try arguments.option("--name") ?? arguments.takePositional()
    guard let selector else {
        throw CLIError(.usage, "nimlet target remove needs a name or id from `nimlet list`")
    }
    try arguments.finish()

    let (session, _, targets) = try openSession(timeout: timeout ?? 15)
    defer { session.close() }
    guard let target = try resolveTarget(selector, in: targets) else {
        throw CLIError(.usage, "nimlet target remove needs a name or id")
    }

    session.send(.removeTarget(id: target.id))
    let reply = try session.receive { message in
        switch message {
        case .toast, .error: return true
        default: return false
        }
    }
    switch reply {
    case .toast(let message):
        Output.say(message)
        Output.emit(TargetRemoveOutput(id: target.id, name: target.name))
    case .error(let reason):
        throw CLIError(.refused, reason)
    default:
        throw CLIError(.refused, "unexpected reply from the host")
    }
}

// MARK: - send

private struct SendOutput: Encodable {
    let ok: Bool
    let targetID: String?
    let targetName: String
    let characters: Int
    /// Absent when the host is old enough not to report it.
    let submitted: Bool?
    let message: String
}

func commandSend(_ arguments: inout Arguments, timeout: Double?) throws {
    let selector = try arguments.option("--target")
    var submit: Bool?
    if arguments.flag("--submit") { submit = true }
    if arguments.flag("--no-submit") { submit = false }
    let argumentText = arguments.takePositional()
    try arguments.finish()
    let text = try readText(argumentText)

    let (session, status, targets) = try openSession(timeout: timeout ?? 15)
    defer { session.close() }
    let target = try resolveTarget(selector, in: targets)
    warnAbout(status)

    session.send(.text(TextPayload(text: text, targetID: target?.id, submit: submit)))
    let reply = try session.receive { message in
        switch message {
        case .delivered, .toast: return true
        default: return false
        }
    }

    let result: SendOutput
    switch reply {
    case .delivered(let receipt):
        result = SendOutput(ok: receipt.ok,
                            targetID: receipt.targetID,
                            targetName: receipt.targetName,
                            characters: receipt.characters,
                            submitted: receipt.submitted,
                            message: receipt.message)
    case .toast(let message):
        // A host one protocol version behind has no delivery receipt; its toast
        // is the whole confirmation. It does not say whether Return was pressed,
        // so report that as unknown rather than guessing.
        result = SendOutput(ok: true,
                            targetID: target?.id,
                            targetName: target?.name ?? "the active target",
                            characters: text.count,
                            submitted: nil,
                            message: message)
    default:
        throw CLIError(.refused, "unexpected reply from the host")
    }

    Output.emit(result)
    guard result.ok else {
        throw CLIError(.refused, result.message)
    }
    Output.say(result.message)
}

// MARK: - event

private struct EventOutput: Encodable {
    let ok = true
    let targetID: String
    let targetName: String
    let kind: String
    let atEpochMillis: Int64
    let note: String?
}

func commandEvent(_ arguments: inout Arguments, timeout: Double?) throws {
    guard let word = arguments.takePositional() else {
        throw CLIError(.usage, "nimlet event needs done, waiting or failed")
    }
    guard let kind = AgentEvent.Kind(rawValue: word) else {
        let known = AgentEvent.Kind.allCases.map(\.rawValue).joined(separator: ", ")
        throw CLIError(.usage, "unknown event \(word) — one of: \(known)")
    }
    let selector = try arguments.option("--target")
    let pane = try arguments.option("--pane")
    var note = try arguments.option("--note")
    let agent = try arguments.option("--agent")
    let fromHook = arguments.flag("--hook")
    try arguments.finish()

    // A hook's payload, when this is one. Read only off a pipe: run by hand
    // at a terminal, waiting on stdin would look like a hang.
    if fromHook, note == nil, isatty(STDIN_FILENO) == 0 {
        let payload = HookPayload(FileHandle.standardInput.readDataToEndOfFile())
        if kind == .waiting { note = payload.waitingNote }
    }

    // This runs from the user's agent hook on every stop — and, for
    // `waiting`, in front of a permission prompt the agent will not show
    // until this returns. A Mac that is asleep, or a Nimlet that is not
    // running, must cost the agent seconds at most.
    let (session, _, targets) = try openSession(timeout: timeout ?? (fromHook ? 3 : 5))
    defer { session.close() }
    let source = try resolveHookSource(selector: selector, pane: pane, agent: agent, in: targets)
    // By hand, an event that names nobody is more likely a typo than a wish
    // to report as "iTerm". From a hook, anonymity is fine: it is still
    // somebody waiting.
    if !fromHook, agent == nil, source.target == nil {
        throw CLIError(.usage, selector == nil && pane == nil && tmuxPaneFromEnvironment() == nil
            ? "nimlet event needs --target, --pane or --agent, or to run inside a tmux pane"
            : "no Nimlet target is pointed at this pane — add one from the phone, or pass --target or --agent")
    }

    let millis = ApprovalClock.now()
    try session.sendAndFlush(.agentEvent(AgentEvent(targetID: source.id,
                                                    kind: kind,
                                                    atEpochMillis: millis,
                                                    note: note,
                                                    sourceName: source.target == nil ? source.name : nil)))
    // The host fans the event out to the phones and does not acknowledge it, so
    // silence is success; wait only long enough to catch a refusal.
    try session.drain(seconds: 0.3)

    // A hook's stdout belongs to the agent, which may read it as an answer.
    // Say nothing there.
    guard !fromHook else { return }
    Output.say("\(kind.rawValue) → \(source.name)")
    Output.emit(EventOutput(targetID: source.id,
                            targetName: source.name,
                            kind: kind.rawValue,
                            atEpochMillis: millis,
                            note: note))
}

// MARK: - ask, pending, decide

private struct AskOutput: Encodable {
    let ok: Bool
    let id: String
    let decision: String
    let reason: String
    let by: String?
    let note: String?
}

/// Blocks until somebody answers, or until the request expires into a denial.
///
/// The contract a hook can rely on: **exit 0 means approved, and every other
/// exit code means not approved.** A denial, a timeout, a Mac that is asleep, a
/// rotated pairing code and a bad argument all land on non-zero, so a hook
/// written as `nimlet ask ... || exit 2` fails closed no matter which of them
/// happens.
func commandAsk(_ arguments: inout Arguments, timeout: Double?) throws {
    let selector = try arguments.option("--target")
    let pane = try arguments.option("--pane")
    let title = try arguments.option("--title") ?? "Asking permission"
    let kindWord = try arguments.option("--kind") ?? "other"
    guard let kind = ApprovalRequest.Kind(rawValue: kindWord) else {
        let known = ApprovalRequest.Kind.allCases.map(\.rawValue).joined(separator: ", ")
        throw CLIError(.usage, "unknown --kind \(kindWord) — one of: \(known)")
    }
    let chosenWindow = try waitOption(&arguments)
    let detailArgument = try arguments.option("--detail") ?? arguments.takePositional()
    try arguments.finish()

    // stdin when nothing was passed, so a hook can pipe the command it is about
    // to run straight in.
    let detail = try readText(detailArgument)
    guard !detail.isEmpty else {
        throw CLIError(.usage, "nimlet ask needs something to decide about — --detail, an argument, or stdin")
    }

    let (session, status, targets) = try openSession(timeout: timeout ?? 15)
    defer { session.close() }
    let target = try resolveHookTarget(selector: selector, pane: pane, in: targets)
    let window = chosenWindow ?? hostWait(status)

    let request = ApprovalRequest(targetID: target?.id,
                                  targetName: target?.name ?? "an agent",
                                  title: title,
                                  detail: detail,
                                  kind: kind,
                                  timeout: window)
    try session.sendAndFlush(.requestApproval(request))
    Output.warn("waiting up to \(ApprovalWait.describe(window)) for an answer on your phone…")

    let resolution = try awaitResolution(of: request.id, on: session, within: window + 5)
    let approved = resolution.decision == .approve
    Output.say(summary(of: resolution))
    Output.emit(AskOutput(ok: approved,
                          id: request.id,
                          decision: resolution.decision.rawValue,
                          reason: resolution.reason.rawValue,
                          by: resolution.byDeviceName,
                          note: resolution.note))
    guard approved else {
        // Silent on stdout: the caller already has the decision, and `--json`
        // has printed it. This only sets the exit code.
        throw CLIError(resolution.reason == .expired ? .timedOut : .refused,
                       summary(of: resolution))
    }
}

/// `--for SECONDS`, or nil to use what the Mac is set to.
private func waitOption(_ arguments: inout Arguments) throws -> Double? {
    try arguments.option("--for").map { raw -> Double in
        guard let seconds = Double(raw), seconds > 0 else {
            throw CLIError(.usage, "--for wants a number of seconds")
        }
        return min(seconds, ApprovalRequest.maxTimeout)
    }
}

/// The wait from Settings → Agents, which the Mac reports when we connect.
private func hostWait(_ status: HostStatus) -> Double {
    status.agentWaitSeconds.map { ApprovalWait.clamped(Double($0)) } ?? ApprovalRequest.defaultTimeout
}

private func awaitResolution(of id: String,
                             on session: Session,
                             within seconds: Double) throws -> ApprovalResolution {
    let message = try session.receive(within: seconds) { message in
        if case .approvalResolved(let resolution) = message { return resolution.requestID == id }
        return false
    }
    guard case .approvalResolved(let resolution) = message else {
        throw CLIError(.refused, "the host answered something else")
    }
    return resolution
}

private func summary(of resolution: ApprovalResolution) -> String {
    let verb = resolution.decision == .approve ? "approved" : "denied"
    switch resolution.reason {
    case .answered:
        let who = "\(verb) by \(resolution.byDeviceName ?? "the Mac")"
        // The reason is the part the agent needs; the attribution is for the
        // person reading the terminal.
        guard let note = resolution.note else { return who }
        return "\(who): \(note)"
    case .expired:
        return "\(verb): nobody answered in time"
    case .withdrawn:
        return "\(verb): the request was withdrawn"
    case .refused:
        return "\(verb): \(resolution.note ?? "the Mac would not take the question")"
    case .handedBack:
        return "not answered here: \(resolution.note ?? "left for the agent's own prompt")"
    }
}

private struct PendingLine: Encodable {
    let id: String
    let targetName: String
    let title: String
    let detail: String
    let kind: String
    let secondsRemaining: Int
}

func commandPending(_ arguments: inout Arguments, timeout: Double?) throws {
    try arguments.finish()
    let (session, _, _) = try openSession(timeout: timeout ?? 15)
    defer { session.close() }

    try session.sendAndFlush(.requestPendingApprovals)
    let message = try session.receive(within: 5) { message in
        if case .pendingApprovals = message { return true }
        return false
    }
    guard case .pendingApprovals(let pending) = message else {
        throw CLIError(.refused, "the host answered something else")
    }

    let now = ApprovalClock.now()
    if pending.isEmpty { Output.say("Nothing is waiting.") }
    for request in pending {
        Output.say("\(request.id)  \(request.targetName)  \(request.title)  "
                   + "(\(request.secondsRemaining(at: now))s left)")
        Output.say("    " + request.detail.split(separator: "\n").first.map(String.init).orEmpty)
    }
    Output.emit(pending.map {
        PendingLine(id: $0.id,
                    targetName: $0.targetName,
                    title: $0.title,
                    detail: $0.detail,
                    kind: $0.kind.rawValue,
                    secondsRemaining: $0.secondsRemaining(at: now))
    })
}

// MARK: - menu

private struct MenuOutput: Encodable {
    let bundleID: String
    let outcome: String
    let note: String
    let buttons: [Button]

    struct Button: Encodable {
        let id: String
        let label: String
        let chord: String?
        let from: String?
    }
}

/// What Nimlet sees in an app's menu bar.
///
/// The row of buttons a phone gets for a Mac app is built from the app's own
/// menus, which makes "why is that the row?" a question with an answer nobody
/// can see — the menus are read on the Mac, the row is drawn on the phone, and
/// the only way to compare them was to hold both. This prints what the host
/// read and what it kept.
func commandMenu(_ arguments: inout Arguments, timeout: Double?) throws {
    let refresh = arguments.flag("--refresh")
    guard let bundleID = arguments.takePositional() else {
        throw CLIError(.usage, "nimlet menu needs a bundle identifier, e.g. com.apple.dt.Xcode")
    }
    try arguments.finish()

    let (session, _, _) = try openSession(timeout: timeout ?? 15)
    defer { session.close() }

    try session.sendAndFlush(.requestMenu(bundleID: bundleID, refresh: refresh))
    // A menu walk is hundreds of round trips into another process, and an app
    // that is busy takes its time answering.
    let message = try session.receive(within: 10) { message in
        if case .menu = message { return true }
        return false
    }
    guard case .menu(let payload) = message else {
        throw CLIError(.refused, "the host answered something else")
    }

    Output.say(payload.note)
    for action in payload.profile?.actions ?? [] {
        let key = action.chord?.display ?? (action.kind == .dictate ? "the phone" : "not set")
        Output.say("  \(action.label.padded(to: 10))\(key.padded(to: 6))  \(action.note ?? "")")
    }
    Output.emit(MenuOutput(
        bundleID: payload.bundleID,
        outcome: payload.outcome.rawValue,
        note: payload.note,
        buttons: (payload.profile?.actions ?? []).map {
            MenuOutput.Button(id: $0.id, label: $0.label,
                              chord: $0.chord?.display, from: $0.note)
        }))
    guard payload.outcome == .read else {
        throw CLIError(.refused, "no menus were read")
    }
}

private extension String {
    /// Left-aligned in a fixed column. The rows are read down the labels.
    func padded(to width: Int) -> String {
        count >= width ? self + " " : self + String(repeating: " ", count: width - count)
    }
}

private struct DecideOutput: Encodable {
    let ok = true
    let id: String
    let decision: String
}

/// Answering from the Mac itself. No new privilege: this tool already holds the
/// pairing code, which is the thing that stands between the local network and
/// keystroke injection here.
func commandDecide(_ arguments: inout Arguments, timeout: Double?) throws {
    guard let id = arguments.takePositional() else {
        throw CLIError(.usage, "nimlet decide needs a request id from `nimlet pending`")
    }
    guard let word = arguments.takePositional(), let decision = ApprovalDecision(rawValue: word) else {
        throw CLIError(.usage, "nimlet decide needs approve or deny")
    }
    let reason = try arguments.option("--reason")
    var answers: [String] = []
    while let answer = try arguments.option("--answer") { answers.append(answer) }
    let always = arguments.flag("--always")
    let handBack = arguments.flag("--hand-back")
    try arguments.finish()

    let (session, _, _) = try openSession(timeout: timeout ?? 15)
    defer { session.close() }
    try session.sendAndFlush(.approvalDecision(id: id, decision: decision, reason: reason,
                                               answers: answers.isEmpty ? nil : answers,
                                               alwaysAllow: always ? true : nil,
                                               handBack: handBack ? true : nil))
    // The resolution is fanned out to every client, so this one sees its own
    // answer come back and can say whether it landed.
    do {
        let resolution = try awaitResolution(of: id, on: session, within: 3)
        Output.say(summary(of: resolution))
    } catch let error as CLIError where error.code == .timedOut {
        throw CLIError(.usage, "nothing is waiting under that id — it may have expired")
    }
    Output.emit(DecideOutput(id: id, decision: decision.rawValue))
}

// MARK: - gate

/// A `PreToolUse` hook in one command: reads the hook's JSON from stdin, asks,
/// and exits 0 to allow or 2 to block.
///
/// Written as its own command rather than as a shell one-liner because the
/// alternative needs `jq`, needs quoting that survives a command containing
/// quotes, and gets the fail-closed direction wrong the first time everybody
/// writes it.
func commandGate(_ arguments: inout Arguments, timeout: Double?) throws {
    let selector = try arguments.option("--target")
    let pane = try arguments.option("--pane")
    let only = (try arguments.option("--tools"))
        .map { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
    let chosenWindow = try waitOption(&arguments)
    try arguments.finish()

    let raw = FileHandle.standardInput.readDataToEndOfFile()
    let event = HookPayload(raw)

    if let only, !only.isEmpty {
        // A tool nobody asked to gate is allowed without a question. Anything
        // else would put a card on the phone for every file read.
        guard let name = event.toolName, only.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else {
            return
        }
    }

    let (session, status, targets) = try openSession(timeout: timeout ?? 10)
    defer { session.close() }
    let source = try resolveHookSource(selector: selector, pane: pane, agent: nil, in: targets)
    let target = source.target
    let window = chosenWindow ?? hostWait(status)

    let request = ApprovalRequest(targetID: target?.id,
                                  targetName: target?.name ?? source.appName ?? "an agent",
                                  title: event.title,
                                  detail: event.detail,
                                  kind: event.kind,
                                  timeout: window)
    try session.sendAndFlush(.requestApproval(request))
    let resolution = try awaitResolution(of: request.id, on: session, within: window + 5)
    guard resolution.decision == .approve else {
        // Exit 2 with the reason on stderr: that is what a PreToolUse hook uses
        // to block a call and tell the agent why. Exited here rather than
        // thrown, because 2 is already `usage` in `CLIError` — and that overlap
        // is in the safe direction anyway: a hook this tool cannot understand
        // blocks the call rather than waving it through.
        session.close()
        FileHandle.standardError.write(Data(("nimlet: " + summary(of: resolution) + "\n").utf8))
        exit(2)
    }
}

// MARK: - answer

/// A `PermissionRequest` hook through which the phone answers: a permission
/// prompt — approve, deny with a reason, or the agent's own "don't ask again"
/// — or one of Claude Code's questions, with its choices.
///
/// The answer reaches the right session by construction: this process *is*
/// that session's hook, blocked until it has something to print. It prints
/// the agent's decision, or nothing. Nothing is "no decision", which both
/// agents answer with their own prompt on the Mac — so that is what happens
/// when nobody answers in time, when the Mac cannot be found, and when
/// anything here goes wrong. Never a yes by default.
///
/// Claude Code shows its prompt alongside this hook and ends the hook when
/// somebody answers there first. Codex shows its prompt only after the hook
/// returns, so holding it would hide the prompt from somebody sitting at the
/// Mac; for Codex the question is held for the phone only while nobody is —
/// the screen is locked, or nothing has been typed or clicked for a minute.
func commandAnswer(_ arguments: inout Arguments, timeout: Double?) throws {
    let agentName = try arguments.option("--agent")
    let selector = try arguments.option("--target")
    let pane = try arguments.option("--pane")
    _ = arguments.flag("--hook")
    try arguments.finish()

    guard isatty(STDIN_FILENO) == 0 else {
        throw CLIError(.usage, "nimlet answer is a hook: it reads a PermissionRequest payload on stdin")
    }
    let raw = FileHandle.standardInput.readDataToEndOfFile()
    let agent = HookAgent.allCases.first { $0.displayName == agentName } ?? .claudeCode
    let prompt = HookAnswer.prompt(from: raw, agent: agent)

    // Finding the Mac costs a hook a second or so; one that is not there must
    // not cost the agent more than a few.
    let (session, status, targets) = try openSession(timeout: timeout ?? 4)
    let source = try resolveHookSource(selector: selector, pane: pane, agent: agentName, in: targets)

    if agent == .codex, MacPresence.someoneIsHere() {
        // Somebody is at the Mac: let Codex show its prompt now, and tell the
        // phone the way the plain "waiting" hook always has.
        defer { session.close() }
        try session.sendAndFlush(.agentEvent(AgentEvent(targetID: source.id, kind: .waiting,
                                                        atEpochMillis: ApprovalClock.now(),
                                                        note: prompt.payload.waitingNote,
                                                        sourceName: source.target == nil ? source.name : nil)))
        try session.drain(seconds: 0.3)
        return
    }

    let request = HookAnswer.request(for: prompt,
                                     targetID: source.target?.id,
                                     targetName: source.target?.name ?? source.appName ?? source.name,
                                     timeout: hostWait(status))
    guard let resolution = holdOpen(request, on: session),
          let output = HookAnswer.output(for: resolution, prompt: prompt) else { return }
    // The only thing this command ever writes to stdout: the agent reads it.
    FileHandle.standardOutput.write(output)
}

/// Keeps a question open until it is answered or its deadline passes.
///
/// The Mac restarts its listeners on wake and when the network changes, and
/// every connection goes with them, this one included. The question has not
/// gone anywhere — the Mac keeps its card up for a while — so this dials in
/// again and asks it again under the same id, which the Mac takes as the same
/// question. Nil when the deadline passes with no word, or the Mac refuses.
private func holdOpen(_ request: ApprovalRequest, on first: Session) -> ApprovalResolution? {
    var session: Session? = first
    defer { session?.close() }
    while true {
        let remaining = Double(request.expiresAtEpochMillis - ApprovalClock.now()) / 1000
        guard remaining > 0 else { return nil }
        do {
            if session == nil {
                session = try openSession(timeout: min(10, remaining)).0
            }
            guard let current = session else { return nil }
            try current.sendAndFlush(.requestApproval(request))
            // A few seconds past the deadline: the Mac sends the expiry itself.
            return try awaitResolution(of: request.id, on: current, within: remaining + 5)
        } catch let error as CLIError where error.code == .unreachable {
            session?.close()
            session = nil
            Thread.sleep(forTimeInterval: 2)
        } catch {
            return nil
        }
    }
}

/// Whether somebody is using this Mac: the screen is unlocked and there was
/// input in the last minute. Input from a phone driving the Mac counts, and
/// that is right — that phone is looking at the Mac's screen.
enum MacPresence {
    static let recent: TimeInterval = 60

    static func someoneIsHere() -> Bool {
        if let session = CGSessionCopyCurrentDictionary() as? [String: Any],
           session["CGSSessionScreenIsLocked"] as? Bool == true {
            return false
        }
        let anyInput = CGEventType(rawValue: ~0) ?? .null
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput) < recent
    }
}

private extension Optional where Wrapped == String {
    var orEmpty: String { self ?? "" }
}

// MARK: - bench

private struct BenchOutput: Encodable {
    let moves: Int
    let hz: Double
    let seconds: Double
    let sendCall: Stat?
    let wakeError: Stat?
}

func commandBench(_ arguments: inout Arguments, timeout: Double?) throws {
    guard let raw = try arguments.option("--hz"), let hz = Double(raw), hz > 0 else {
        throw CLIError(.usage, "nimlet bench needs --hz (try 120)")
    }
    let seconds = Double(try arguments.option("--seconds") ?? "5") ?? 5
    try arguments.finish()

    let (session, _, _) = try openSession(timeout: timeout ?? 15)
    defer { session.close() }

    let interval = 1.0 / hz
    let total = Int(seconds * hz)
    var sendDurations: [Double] = []
    var wakeErrors: [Double] = []
    let start = DispatchTime.now().uptimeNanoseconds
    var sign = 1.0

    for index in 0..<total {
        let due = start &+ UInt64(Double(index) * interval * 1_000_000_000)
        var now = DispatchTime.now().uptimeNanoseconds
        if due > now {
            Thread.sleep(forTimeInterval: Double(due &- now) / 1_000_000_000)
            now = DispatchTime.now().uptimeNanoseconds
        }
        wakeErrors.append(Double(now &- due) / 1_000_000)

        let sendStart = DispatchTime.now().uptimeNanoseconds
        // Alternating sign keeps the cursor from walking off the screen.
        session.send(.move(dx: sign, dy: 0))
        sign = -sign
        sendDurations.append(Double(DispatchTime.now().uptimeNanoseconds &- sendStart) / 1000)
    }

    let sendCall = Stat(sendDurations)
    let wakeError = Stat(wakeErrors)
    Output.say("bench: \(total) moves at \(Int(hz)) Hz over \(seconds)s")
    if let sendCall { Output.say(sendCall.line(label: "send_call", unit: "us")) }
    if let wakeError { Output.say(wakeError.line(label: "wake_error", unit: "ms")) }
    Output.emit(BenchOutput(moves: total, hz: hz, seconds: seconds, sendCall: sendCall, wakeError: wakeError))

    // Let the last packets drain before the connection is torn down.
    Thread.sleep(forTimeInterval: 0.3)
}

// MARK: - hook

/// Prints a settings.json fragment, with the same preamble whichever hook it is.
///
/// Both `nimlet hook` and `nimlet hook --approve` printed this block verbatim —
/// the encoder setup, the failure, and the three lines telling you where to
/// paste it and that nothing here writes to your settings. Reworded in one
/// place they would have started saying different things about the same act.
private func printSnippet<T: Encodable>(_ snippet: T, trailing: [String]) throws {
    if Output.json {
        Output.emit(snippet)
        return
    }

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(snippet), let text = String(data: data, encoding: .utf8) else {
        throw CLIError(.refused, "could not render the snippet")
    }

    Output.say("Paste into ~/.claude/settings.json, or .claude/settings.json in a project.")
    Output.say("nimlet only prints this; nothing here writes to your settings.")
    Output.say("")
    Output.say(text)
    Output.say("")
    trailing.forEach(Output.say)
}

private struct ApprovalHookSnippet: Encodable {
    struct Entry: Encodable {
        let type = "command"
        let command: String
        /// Past the longest wait, so the agent does not end the hook first.
        let timeout = ApprovalWait.hookTimeoutSeconds
    }

    struct Group: Encodable {
        let matcher: String
        let hooks: [Entry]
    }

    struct Hooks: Encodable {
        let preToolUse: [Group]
        enum CodingKeys: String, CodingKey { case preToolUse = "PreToolUse" }
    }

    let hooks: Hooks
}

/// Prints the `PreToolUse` entry that routes a tool call to the phone.
///
/// Deliberately narrow by default: `Bash` only. Gating every tool would put a
/// card on the phone for each file the agent reads, and a surface that asks
/// about everything is one nobody reads before tapping.
private func printApprovalHook(target: String?) throws {
    let snippet = ApprovalHookSnippet(hooks: .init(preToolUse: [
        .init(matcher: "Bash",
              hooks: [.init(command: HookCommands.gate(target: target))]),
    ]))
    try printSnippet(snippet, trailing: [
        target == nil ? "The agent is matched to its target by the tmux pane it runs in ($TMUX_PANE)." : nil,
        target == nil ? "Pass --target NAME to pin it to one target instead." : nil,
        "Every command the agent runs then waits for a tap on your phone.",
        "Nothing is approved by not answering: once the wait set in Settings → Agents",
        "runs out, it denies itself.",
        "Try it once on something harmless before trusting it with anything else.",
    ].compactMap { $0 })
}

/// The two commands a hook calls, built once so `nimlet hook` and the installer
/// in the Mac app cannot drift apart.
enum HookCommands {
    /// This very binary, by absolute path and quoted. The copy inside
    /// Nimlet.app is on nobody's PATH, and a hook that said `nimlet` would run
    /// nothing at all there.
    static var invocation: String {
        let url = Bundle.main.executableURL?.resolvingSymlinksInPath()
            ?? URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let escaped = url.path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "$", with: "\\$")
        return "\"\(escaped)\""
    }

    static func event(target: String?) -> String {
        // `|| true` so a Mac that is asleep, or a pairing that has been
        // rotated, fails the notification rather than the agent run it is
        // reporting on.
        "\(invocation) event done --hook\(targetOption(target)) || true"
    }

    static func gate(target: String?) -> String {
        "\(invocation) gate\(targetOption(target)) --tools Bash"
    }

    private static func targetOption(_ target: String?) -> String {
        guard let target, !target.isEmpty else { return "" }
        let escaped = target.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "$", with: "\\$")
        return " --target \"\(escaped)\""
    }
}

private struct HookSnippet: Encodable {
    struct Entry: Encodable {
        let type = "command"
        let command: String
    }

    struct Group: Encodable {
        let hooks: [Entry]
    }

    struct Hooks: Encodable {
        let stop: [Group]
        enum CodingKeys: String, CodingKey { case stop = "Stop" }
    }

    let hooks: Hooks
}

func commandHook(_ arguments: inout Arguments) throws {
    let selector = try arguments.option("--target")
    let approve = arguments.flag("--approve")
    try arguments.finish()

    if approve {
        try printApprovalHook(target: selector)
        return
    }
    let snippet = HookSnippet(hooks: .init(stop: [.init(hooks: [
        .init(command: HookCommands.event(target: selector)),
    ])]))

    try printSnippet(snippet, trailing: [
        selector == nil ? "The agent is matched to its target by the tmux pane it runs in ($TMUX_PANE)." : nil,
        selector == nil ? "Pass --target NAME to pin it to one target instead." : nil,
        "Every phone connected to the Mac gets the event.",
        "Nimlet's Settings → Agents on the Mac installs the same hooks for you.",
    ].compactMap { $0 })
}

// MARK: - Shared helpers

private func openSession(timeout: Double) throws -> (Session, HostStatus, [NimletTarget]) {
    let session = Session(config: try Config.load(), timeout: timeout)
    do {
        let introduction = try session.connect()
        return (session, introduction.status, introduction.targets)
    } catch {
        session.close()
        throw error
    }
}

/// The pane this process is running in, if tmux started it. An agent's hook
/// runs as a child of the agent, which runs in the pane, so this is the pane
/// the event is about — without anybody having to write a target name into a
/// settings file per pane.
func tmuxPaneFromEnvironment() -> String? {
    guard let pane = ProcessInfo.processInfo.environment["TMUX_PANE"], !pane.isEmpty else { return nil }
    return pane
}

/// `--target` wins; otherwise `--pane`, otherwise `$TMUX_PANE`; nil when the
/// tool is not in a pane and nobody said. A pane that no target points at is
/// also nil.
private func resolveHookTarget(selector: String?, pane: String?, in targets: [NimletTarget]) throws -> NimletTarget? {
    if let selector { return try resolveTarget(selector, in: targets) }
    guard let paneID = pane ?? tmuxPaneFromEnvironment() else { return nil }
    return targets.first { $0.kind == .tmux && $0.tmuxTarget == paneID }
}

/// Who a hook is speaking for.
///
/// A target when one owns the place the hook runs: the one named, the tmux
/// pane, or — for an agent in a desktop app, or in a terminal outside tmux —
/// an `app` target pointed at the app the hook descends from. Otherwise a
/// stable stand-in id and a name, because "something needs you" has to reach
/// the phone whether or not anybody made a tile for where it came from.
private struct HookSource {
    var target: NimletTarget?
    var id: String
    var name: String
    /// The app the hook runs inside, when it runs inside one.
    var appName: String?
}

private func resolveHookSource(selector: String?, pane: String?, agent: String?,
                               in targets: [NimletTarget]) throws -> HookSource {
    if let target = try resolveHookTarget(selector: selector, pane: pane, in: targets) {
        return HookSource(target: target, id: target.id, name: target.name, appName: nil)
    }
    let app = HookAncestry.appBundle(ancestors: ancestorExecutables()).flatMap { Bundle(path: $0) }
    let appName = app.map { bundle in
        (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? bundle.bundleURL.deletingPathExtension().lastPathComponent
    }
    if let bundleID = app?.bundleIdentifier,
       let target = targets.first(where: { $0.kind == .app && $0.bundleID == bundleID && $0.pinnedWindowID == nil })
        ?? targets.first(where: { $0.kind == .app && $0.bundleID == bundleID }) {
        return HookSource(target: target, id: target.id, name: target.name, appName: appName)
    }
    let name = agent ?? appName ?? "An agent"
    // Per agent, not per app: the phone's mute switch and its "the second
    // report inside half a minute updates the banner" both key on this, and
    // what the person thinks of as one thing is "Codex", wherever it runs.
    let slug = name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
    return HookSource(target: nil, id: "agent." + String(slug), name: name, appName: appName)
}

/// The executables above this process, parent first, up to launchd.
private func ancestorExecutables() -> [String] {
    var paths: [String] = []
    var pid = getppid()
    var seen = Set<pid_t>()
    while pid > 1, seen.insert(pid).inserted, paths.count < 64 {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        if proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 {
            paths.append(String(cString: buffer))
        }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { break }
        pid = pid_t(info.pbi_ppid)
    }
    return paths
}

/// nil means "whatever target the Mac currently has selected".
private func resolveTarget(_ selector: String?, in targets: [NimletTarget]) throws -> NimletTarget? {
    guard let selector else { return nil }
    if let match = targets.first(where: { $0.id == selector }) { return match }

    let named = targets.filter { $0.name.caseInsensitiveCompare(selector) == .orderedSame }
    if named.count == 1 { return named[0] }
    if named.count > 1 {
        throw CLIError(.usage, "\(named.count) targets are called \(selector) — use the id from `nimlet list`")
    }
    guard !targets.isEmpty else {
        throw CLIError(.usage, "the host has no targets yet")
    }
    let known = targets.map(\.name).joined(separator: ", ")
    throw CLIError(.usage, "no target called \(selector) — the host offers: \(known)")
}

private func readText(_ argument: String?) throws -> String {
    var raw: String
    if let argument {
        raw = argument
    } else {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard let decoded = String(data: data, encoding: .utf8) else {
            throw CLIError(.usage, "stdin was not UTF-8")
        }
        raw = decoded
    }
    // Only the trailing whitespace goes. Leading whitespace is indentation when
    // what is being piped in is code, and the agent on the other end reads it.
    let text = String(raw.reversed().drop { $0.isWhitespace }.reversed())
    guard !text.isEmpty else {
        throw CLIError(.usage, "nothing to send — pass the text as an argument or pipe it in")
    }
    return text
}

/// The three ways a delivery can be swallowed without the host calling it a
/// failure. Warnings rather than errors: the host's receipt is still the verdict.
private func warnAbout(_ status: HostStatus) {
    if !status.accessibilityGranted {
        Output.warn("\(status.hostName) has not granted Accessibility — keystrokes will be swallowed")
    }
    if status.injectionPaused {
        Output.warn("injection is paused on \(status.hostName)")
    }
    if !status.deviceApproved {
        Output.warn("\(status.hostName) has not approved \(Config.deviceName) — approve it in the Nimlet menu")
    }
}

/// The menu bar app's own preferences.
///
/// Resolves a pane spec to its stable `%id`.
///
/// A positional spec such as `codex:0.1` renumbers whenever a pane closes, and a
/// stale one pastes into whatever now occupies the slot and presses Return on
/// it, so resolve it once here and store only the `%id`.
private func resolvePane(_ spec: String) throws -> (id: String, label: String) {
    // Separated by a pipe rather than a tab: `display-message` rewrites control
    // characters in what it prints, so a tab came back as an underscore, the
    // line never split, and the whole thing was stored as the pane id. A pane id
    // cannot contain a pipe, so splitting on the first one is safe even when a
    // window name contains one.
    let output = try tmux(["display-message", "-p", "-t", spec, "#{pane_id}|#{session_name}:#{window_name}"])
    let line = output.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let separator = line.firstIndex(of: "|") else {
        throw CLIError(.usage, "tmux did not recognise \(spec) as a pane")
    }
    let id = String(line[..<separator])
    guard id.hasPrefix("%") else {
        throw CLIError(.usage, "tmux did not recognise \(spec) as a pane")
    }
    let label = String(line[line.index(after: separator)...])
    return (id, label.isEmpty ? id : label)
}

private func tmux(_ arguments: [String]) throws -> String {
    let process = Process()
    // Through env, because tmux lives in /opt/homebrew/bin on Apple silicon and
    // /usr/local/bin on Intel, and neither is on a launchd-inherited PATH.
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["tmux"] + arguments
    let output = Pipe()
    let errors = Pipe()
    process.standardOutput = output
    process.standardError = errors
    do {
        try process.run()
    } catch {
        throw CLIError(.usage, "could not run tmux: \(error.localizedDescription)")
    }
    let produced = output.fileHandleForReading.readDataToEndOfFile()
    let complained = errors.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()

    guard process.terminationStatus == 0 else {
        let detail = String(data: complained, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        throw CLIError(.usage, detail.isEmpty ? "tmux exited \(process.terminationStatus)" : detail)
    }
    return String(data: produced, encoding: .utf8) ?? ""
}
