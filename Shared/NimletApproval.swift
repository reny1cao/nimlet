import Foundation

/// An agent asking permission before it does something, and the answer.
///
/// The phone is already the surface you reach for when a run needs a word from
/// you. This is the same reach for the moment a run needs a *decision* — the
/// one thing that, unanswered, stops the work entirely.
///
/// Two properties are load-bearing and everything else follows from them:
///
/// 1. **Nothing is approved by not answering.** A request that nobody answers
///    expires into its `onExpiry` decision, which is `deny`. A phone in a
///    pocket, a dropped connection and a closed app all have to end in the
///    agent being told no, never in it proceeding because the answer was slow.
/// 2. **The asker always gets an answer.** Every path out of a pending
///    request — answered, expired, withdrawn, refused for want of room —
///    produces an `ApprovalResolution`. An agent blocked on a pipe that never
///    writes is worse than an agent denied.
///
/// A question is the same thing with more than two answers. "May I run
/// `npm test`?" and "Which database should I use?" both stop the agent until
/// somebody picks, both reach the same card on the phone, and both come back
/// over the same path to the process that asked — which is the agent's own
/// session, because it is that session's hook that is waiting.

/// One choice the agent offered. The label is what goes back to it.
public struct ApprovalOption: Codable, Sendable, Equatable, Hashable {
    public var label: String
    public var detail: String?

    public init(label: String, detail: String? = nil) {
        self.label = label
        self.detail = detail
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        detail = try c.decodeIfPresent(String.self, forKey: .detail)
    }
}

/// Something the agent asked, with the choices it offered. The person can
/// also write their own answer instead: every agent that asks this way takes
/// free text, and the right answer is often not on the list.
public struct ApprovalQuestion: Codable, Sendable, Equatable {
    public var question: String
    /// A word or two the agent gave the question, such as "Database".
    public var header: String?
    public var options: [ApprovalOption]
    public var allowsMultiple: Bool

    public init(question: String, header: String? = nil, options: [ApprovalOption], allowsMultiple: Bool = false) {
        self.question = question
        self.header = header
        self.options = options
        self.allowsMultiple = allowsMultiple
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        question = try c.decodeIfPresent(String.self, forKey: .question) ?? ""
        header = try c.decodeIfPresent(String.self, forKey: .header)
        options = try c.decodeIfPresent([ApprovalOption].self, forKey: .options) ?? []
        allowsMultiple = try c.decodeIfPresent(Bool.self, forKey: .allowsMultiple) ?? false
    }

    /// What goes back to the agent for these picks: one label, or several
    /// joined the way the agents join them. Typed text wins over the picks.
    public static func answer(picking labels: [String], typed: String?) -> String? {
        let text = typed?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !text.isEmpty { return text }
        let picked = labels.filter { !$0.isEmpty }
        return picked.isEmpty ? nil : picked.joined(separator: ", ")
    }
}

/// How long an agent waits for an answer, as the person set it on the Mac.
///
/// It was a fixed two minutes. That suits somebody at the desk with the phone
/// beside the keyboard, and nobody else: a long run checked now and then asks
/// its question while the phone is in a pocket, and two minutes later the
/// question is gone. Whatever this is set to, the end of it never approves
/// anything.
public enum ApprovalWait {
    /// What Settings → Agents offers.
    public static let choices: [TimeInterval] = [120, 600, 1800, 3600, 4 * 3600, 12 * 3600]
    /// Long enough to notice a buzz, finish a sentence and pick up the phone.
    public static let standard: TimeInterval = 600
    public static let shortest: TimeInterval = 60

    /// The preference key on the Mac, in the host's own defaults.
    public static let defaultsKey = "mice.agents.waitSeconds"

    public static func clamped(_ seconds: TimeInterval) -> TimeInterval {
        min(max(seconds, shortest), ApprovalRequest.maxTimeout)
    }

    /// What an agent is told to allow its hook, in seconds: the longest wait
    /// there is, and a margin for finding the Mac. The hook ends itself at the
    /// wait the person chose; this only stops the agent from ending it sooner.
    /// Claude Code's own default is ten minutes, which would quietly cut every
    /// longer wait short.
    public static let hookTimeoutSeconds = Int(ApprovalRequest.maxTimeout) + 120

    /// "2 minutes", "1 hour", "12 hours".
    public static func describe(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return minutes == 1 ? "1 minute" : "\(minutes) minutes" }
        let hours = Double(minutes) / 60
        if hours == hours.rounded() {
            let whole = Int(hours)
            return whole == 1 ? "1 hour" : "\(whole) hours"
        }
        return String(format: "%.1f hours", hours)
    }

    /// A countdown that stays short at any length: "45s", "9:58", "3h 12m".
    public static func clock(_ seconds: Int) -> String {
        if seconds >= 3600 { return "\(seconds / 3600)h \(seconds % 3600 / 60)m" }
        if seconds >= 60 { return String(format: "%d:%02d", seconds / 60, seconds % 60) }
        return "\(seconds)s"
    }
}

public struct ApprovalRequest: Codable, Sendable, Equatable, Identifiable {
    /// Only for the icon and the one-word summary on the phone. The `detail` is
    /// what is actually being decided; this must never be the only thing shown.
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case command, edit, network, other
    }

    public var id: String
    /// Which target the asking agent is running in, when it knows. Lets the
    /// phone name the pane rather than say "an agent".
    public var targetID: String?
    public var targetName: String
    /// A short imperative: "Run a command", "Write to a file".
    public var title: String
    /// The thing itself — the command line, the path, the URL. Shown verbatim
    /// and monospaced, because this is the text the decision is about.
    public var detail: String
    public var kind: Kind
    public var createdAtEpochMillis: Int64
    public var expiresAtEpochMillis: Int64
    /// What happens if nobody answers. Carried on the wire rather than assumed,
    /// so the phone can state the outcome instead of implying one.
    public var onExpiry: ApprovalDecision
    /// Set when the agent asked a question rather than for permission. The
    /// answers come back in the resolution, in this order.
    public var questions: [ApprovalQuestion]
    /// The agent's own "yes, and don't ask again for …", described, when it
    /// offered one. Approving with it is the same as choosing that line in the
    /// agent's prompt on the Mac.
    public var alwaysAllowRule: String?
    /// Unanswered, this goes back to the agent's own prompt on the Mac rather
    /// than being denied: nothing is approved and nothing is refused, and the
    /// person answers it there when they are back. `onExpiry` stays `.deny`,
    /// because to the phone an expired card is still not a yes.
    public var returnsToMac: Bool

    public var isQuestion: Bool { !questions.isEmpty }

    /// Used where nobody said: a request decoded without a deadline, and
    /// `nimlet ask` run against a Mac too old to say what it was set to.
    public static let defaultTimeout: TimeInterval = ApprovalWait.standard
    /// Twelve hours: a run started before leaving for the day is still able to
    /// ask, and a forgotten request still ends.
    public static let maxTimeout: TimeInterval = 12 * 3600
    /// `LineFramer` caps a line at 1 MiB, and a phone screen shows a fraction
    /// of this anyway. A diff pasted whole would otherwise be dropped in
    /// transit at exactly the moment a decision was wanted.
    public static let maxDetailCharacters = 4000

    public init(id: String = UUID().uuidString,
                targetID: String? = nil,
                targetName: String,
                title: String,
                detail: String,
                kind: Kind = .other,
                createdAtEpochMillis: Int64 = ApprovalClock.now(),
                timeout: TimeInterval = ApprovalRequest.defaultTimeout,
                onExpiry: ApprovalDecision = .deny,
                questions: [ApprovalQuestion] = [],
                alwaysAllowRule: String? = nil,
                returnsToMac: Bool = false) {
        self.id = id
        self.targetID = targetID
        self.targetName = targetName
        self.title = title
        self.detail = ApprovalRequest.truncated(detail)
        self.kind = kind
        self.createdAtEpochMillis = createdAtEpochMillis
        let seconds = min(max(timeout, 1), ApprovalRequest.maxTimeout)
        self.expiresAtEpochMillis = createdAtEpochMillis + Int64(seconds * 1000)
        self.onExpiry = onExpiry
        self.questions = questions
        self.alwaysAllowRule = alwaysAllowRule
        self.returnsToMac = returnsToMac
    }

    /// Every field defaulted, for the same reason `NimletTarget`'s is: a request
    /// that fails to decode is a run left hanging, and a missing field is not a
    /// good enough reason for that.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        targetID = try c.decodeIfPresent(String.self, forKey: .targetID)
        targetName = try c.decodeIfPresent(String.self, forKey: .targetName) ?? "an agent"
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Asking permission"
        detail = ApprovalRequest.truncated(try c.decodeIfPresent(String.self, forKey: .detail) ?? "")
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .other
        let created = try c.decodeIfPresent(Int64.self, forKey: .createdAtEpochMillis) ?? ApprovalClock.now()
        createdAtEpochMillis = created
        expiresAtEpochMillis = try c.decodeIfPresent(Int64.self, forKey: .expiresAtEpochMillis)
            ?? created + Int64(ApprovalRequest.defaultTimeout * 1000)
        // An unreadable expiry policy is read as the safe one, never as approve.
        onExpiry = (try? c.decodeIfPresent(ApprovalDecision.self, forKey: .onExpiry)) .flatMap { $0 } ?? .deny
        questions = (try? c.decodeIfPresent([ApprovalQuestion].self, forKey: .questions)).flatMap { $0 } ?? []
        alwaysAllowRule = try c.decodeIfPresent(String.self, forKey: .alwaysAllowRule)
        returnsToMac = try c.decodeIfPresent(Bool.self, forKey: .returnsToMac) ?? false
    }

    public func isExpired(at nowMillis: Int64) -> Bool {
        nowMillis >= expiresAtEpochMillis
    }

    public func secondsRemaining(at nowMillis: Int64) -> Int {
        Int(max(0, expiresAtEpochMillis - nowMillis) / 1000)
    }

    /// Kept whole where it fits and cut with a visible marker where it does
    /// not, so nobody approves a command whose tail was silently removed.
    static func truncated(_ text: String) -> String {
        guard text.count > maxDetailCharacters else { return text }
        return String(text.prefix(maxDetailCharacters)) + "\n… (truncated)"
    }
}

public enum ApprovalDecision: String, Codable, Sendable, Equatable {
    case approve, deny
}

/// How a pending request ended. Sent to the asker, and fanned out so a second
/// phone takes the card off its screen instead of answering it twice.
public struct ApprovalResolution: Codable, Sendable, Equatable {
    public enum Reason: String, Codable, Sendable {
        /// Somebody decided.
        case answered
        /// Nobody decided in time.
        case expired
        /// The asking process went away.
        case withdrawn
        /// Too many requests were already pending, or the Mac could not accept
        /// this one. Denied rather than queued: a queue behind a phone is a
        /// queue nobody is watching.
        case refused
        /// Somebody chose to answer it in the agent itself, on the Mac. Nothing
        /// was decided here; the agent's own prompt takes it from there.
        case handedBack
    }

    public var requestID: String
    public var decision: ApprovalDecision
    public var reason: Reason
    /// Which phone answered, for the Mac's log and the CLI's output.
    public var byDeviceName: String?
    public var atEpochMillis: Int64
    public var note: String?
    /// One answer per question, in the request's order. Only on an approved
    /// question; nil for everything else.
    public var answers: [String]?
    /// The agent's own standing rule was chosen along with the approval.
    public var alwaysAllow: Bool

    public init(requestID: String,
                decision: ApprovalDecision,
                reason: Reason,
                byDeviceName: String? = nil,
                atEpochMillis: Int64 = ApprovalClock.now(),
                note: String? = nil,
                answers: [String]? = nil,
                alwaysAllow: Bool = false) {
        self.requestID = requestID
        self.decision = decision
        self.reason = reason
        self.byDeviceName = byDeviceName
        self.atEpochMillis = atEpochMillis
        self.note = note
        self.answers = answers
        self.alwaysAllow = alwaysAllow
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        requestID = try c.decodeIfPresent(String.self, forKey: .requestID) ?? ""
        // Same rule as `onExpiry`: anything we cannot read is a denial.
        decision = (try? c.decodeIfPresent(ApprovalDecision.self, forKey: .decision)).flatMap { $0 } ?? .deny
        reason = (try? c.decodeIfPresent(Reason.self, forKey: .reason)).flatMap { $0 } ?? .refused
        byDeviceName = try c.decodeIfPresent(String.self, forKey: .byDeviceName)
        atEpochMillis = try c.decodeIfPresent(Int64.self, forKey: .atEpochMillis) ?? ApprovalClock.now()
        note = try c.decodeIfPresent(String.self, forKey: .note)
        // Only ever honoured alongside an approval, which is checked where it
        // is used; a malformed list reads as no answers.
        answers = (try? c.decodeIfPresent([String].self, forKey: .answers)).flatMap { $0 }
        alwaysAllow = (try? c.decodeIfPresent(Bool.self, forKey: .alwaysAllow)).flatMap { $0 } ?? false
    }
}

/// What a person picked, on its way from a phone or the menu bar to the ledger.
public struct ApprovalAnswer: Equatable, Sendable {
    public var decision: ApprovalDecision
    /// Why not, or anything else to tell the agent along with a denial.
    public var reason: String?
    public var answers: [String]?
    public var alwaysAllow: Bool
    /// "Answer it in the agent instead": leave the agent's own prompt to it.
    public var handBack: Bool

    public init(decision: ApprovalDecision, reason: String? = nil, answers: [String]? = nil,
                alwaysAllow: Bool = false, handBack: Bool = false) {
        self.decision = decision
        self.reason = reason
        self.answers = answers
        self.alwaysAllow = alwaysAllow
        self.handBack = handBack
    }

    public static let approve = ApprovalAnswer(decision: .approve)
    public static let deny = ApprovalAnswer(decision: .deny)
}

/// One clock, so the two ends and the tests all read epoch milliseconds the
/// same way.
public enum ApprovalClock {
    public static func now() -> Int64 { millis(at: Date()) }

    /// Takes a `Date` for the callers that already have one — a `TimelineView`
    /// tick, a hook's event stamp — so none of them open-codes the conversion.
    public static func millis(at date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }
}

/// The pending set and the rules for leaving it.
///
/// Pure and synchronous on purpose: this is the part that must not be wrong, so
/// it is the part with no network, no timers and no main thread in it. The host
/// wraps it with all three.
public struct ApprovalLedger {
    /// Past this, the phone is being used as a queue rather than as a decision
    /// surface, and the honest answer to the next asker is no.
    public static let maxPending = 8

    /// How long a request waits for its asker to dial back in after the Mac
    /// itself cut the connection — a wake from sleep, a new network. The hook
    /// is still running and still waiting; it just has to find the Mac again.
    public static let reconnectGrace: Int64 = 30_000

    public private(set) var pending: [ApprovalRequest] = []
    /// Requests whose asker's connection went with a restart of the Mac's
    /// listeners, and when. Withdrawn if nobody comes back for them.
    public private(set) var orphanedAt: [String: Int64] = [:]

    public init() {}

    public enum AddOutcome: Equatable {
        case added
        /// Same id already pending: a retrying asker, not a second question.
        case duplicate
        /// Refused, with the denial to send back.
        case refused(ApprovalResolution)
    }

    public mutating func add(_ request: ApprovalRequest, now: Int64 = ApprovalClock.now()) -> AddOutcome {
        if pending.contains(where: { $0.id == request.id }) {
            // The asker is back, on a new connection: the same question, still
            // open, so it is the same card and not a second one.
            orphanedAt[request.id] = nil
            return .duplicate
        }
        // An expired request is refused rather than added: it would be swept a
        // moment later anyway, and a card that appears and vanishes reads as a
        // bug rather than as a timeout.
        if request.isExpired(at: now) {
            return .refused(ApprovalResolution(requestID: request.id,
                                               decision: request.onExpiry,
                                               reason: .expired,
                                               atEpochMillis: now,
                                               note: "Expired before it reached the Mac"))
        }
        guard pending.count < ApprovalLedger.maxPending else {
            return .refused(ApprovalResolution(requestID: request.id,
                                               decision: .deny,
                                               reason: .refused,
                                               atEpochMillis: now,
                                               note: "\(ApprovalLedger.maxPending) requests are already waiting"))
        }
        pending.append(request)
        return .added
    }

    /// Answering an id that is not pending returns nil rather than inventing a
    /// resolution — the request was already expired or answered elsewhere, and
    /// the asker has been told once already.
    public mutating func resolve(id: String,
                                 decision: ApprovalDecision,
                                 reason: String? = nil,
                                 by deviceName: String?,
                                 now: Int64 = ApprovalClock.now()) -> ApprovalResolution? {
        resolve(id: id, with: ApprovalAnswer(decision: decision, reason: reason), by: deviceName, now: now)
    }

    public mutating func resolve(id: String,
                                 with answer: ApprovalAnswer,
                                 by deviceName: String?,
                                 now: Int64 = ApprovalClock.now()) -> ApprovalResolution? {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return nil }
        let request = pending.remove(at: index)
        orphanedAt[id] = nil
        // A decision that lands after the deadline loses to the deadline. The
        // agent has already been told no, and telling it yes now would be a
        // second, contradictory answer.
        if request.isExpired(at: now) {
            return ApprovalResolution(requestID: id,
                                      decision: request.onExpiry,
                                      reason: .expired,
                                      byDeviceName: deviceName,
                                      atEpochMillis: now,
                                      note: "The answer arrived after it expired")
        }
        if answer.handBack {
            return ApprovalResolution(requestID: id, decision: .deny, reason: .handedBack,
                                      byDeviceName: deviceName, atEpochMillis: now,
                                      note: "Left for the agent's own prompt")
        }
        let note = answer.reason?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard answer.decision == .approve else {
            return ApprovalResolution(requestID: id,
                                      decision: .deny,
                                      reason: .answered,
                                      byDeviceName: deviceName,
                                      atEpochMillis: now,
                                      note: (note?.isEmpty ?? true) ? nil : note)
        }
        var answers: [String]?
        if request.isQuestion {
            // A yes to a question is its answers. Without one for every
            // question — a phone a release behind, which only knows Approve —
            // there is nothing to tell the agent, so it goes back to the
            // agent's own prompt rather than on with a blank.
            let given = (answer.answers ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard given.count == request.questions.count, !given.contains(where: \.isEmpty) else {
                return ApprovalResolution(requestID: id, decision: .deny, reason: .handedBack,
                                          byDeviceName: deviceName, atEpochMillis: now,
                                          note: "No answer came with it")
            }
            answers = given
        }
        return ApprovalResolution(requestID: id,
                                  decision: .approve,
                                  reason: .answered,
                                  byDeviceName: deviceName,
                                  atEpochMillis: now,
                                  note: (note?.isEmpty ?? true) ? nil : note,
                                  answers: answers,
                                  // Only a rule the agent itself offered.
                                  alwaysAllow: answer.alwaysAllow && request.alwaysAllowRule != nil)
    }

    public mutating func expire(now: Int64 = ApprovalClock.now()) -> [ApprovalResolution] {
        let due = pending.filter { $0.isExpired(at: now) }
        guard !due.isEmpty else { return [] }
        pending.removeAll { $0.isExpired(at: now) }
        for request in due { orphanedAt[request.id] = nil }
        return due.map {
            ApprovalResolution(requestID: $0.id,
                               decision: $0.onExpiry,
                               reason: .expired,
                               atEpochMillis: now,
                               note: "Nobody answered in time")
        }
    }

    /// Drops the requests matching `ids` — used when the process that asked
    /// them goes away, which is the only case where nobody is left to tell.
    public mutating func withdraw(ids: Set<String>, now: Int64 = ApprovalClock.now()) -> [ApprovalResolution] {
        let gone = pending.filter { ids.contains($0.id) }
        guard !gone.isEmpty else { return [] }
        pending.removeAll { ids.contains($0.id) }
        for request in gone { orphanedAt[request.id] = nil }
        return gone.map {
            ApprovalResolution(requestID: $0.id,
                               decision: $0.onExpiry,
                               reason: .withdrawn,
                               atEpochMillis: now,
                               note: "The agent that asked is gone")
        }
    }

    public func request(id: String) -> ApprovalRequest? {
        pending.first { $0.id == id }
    }

    /// When the next expiry is due, so a timer can sleep until then instead of
    /// waking every second for nothing.
    public func nextExpiry() -> Int64? {
        let orphans = orphanedAt.values.map { $0 + ApprovalLedger.reconnectGrace }
        return (pending.map(\.expiresAtEpochMillis) + orphans).min()
    }

    /// The Mac cut these askers off itself, so they are not gone: give them
    /// `reconnectGrace` to ask again before the cards come down.
    public mutating func orphan(ids: Set<String>, now: Int64 = ApprovalClock.now()) {
        for id in ids where pending.contains(where: { $0.id == id }) && orphanedAt[id] == nil {
            orphanedAt[id] = now
        }
    }

    /// The orphans nobody came back for, withdrawn.
    public mutating func sweepOrphans(now: Int64 = ApprovalClock.now()) -> [ApprovalResolution] {
        let lost = Set(orphanedAt.filter { now - $0.value >= ApprovalLedger.reconnectGrace }.keys)
        return withdraw(ids: lost, now: now)
    }
}
