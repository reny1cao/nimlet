import Foundation

/// What the phone is allowed to interrupt you for, and when.
///
/// Everything here is a preference with a default, and the defaults are the
/// argument: **the two things worth a buzz are an agent blocked on you and an
/// agent that fell over.** A finished turn is not. A finished turn will still
/// be finished when you next look, and an app that buzzes on every completed
/// turn is an app whose notifications get switched off inside a week — at
/// which point the two that mattered are gone too.
///
/// So `done` ships off and can be turned on, rather than shipping on and
/// needing to be turned off. Same reasoning as the dock indicator: a target
/// with nothing to say says nothing.
public struct AlertSettings: Codable, Sendable, Equatable {

    /// The master switch. Off means nothing is posted and anything already on
    /// the lock screen is taken down — not "posted quietly".
    public var isEnabled: Bool
    /// An agent is blocked on a person. The one that costs real time.
    public var waiting: Bool
    /// A run stopped badly. Same argument: nothing more happens until you look.
    public var failed: Bool
    /// A run finished. Off by default; see above.
    public var done: Bool
    /// An agent is asking permission, and will be denied if nobody answers.
    public var approvals: Bool
    /// Whether the first alert of a burst makes a sound. Off still posts — a
    /// silent notification is a notification, and the lock screen still lights.
    public var playsSound: Bool
    /// How long after a sounded alert about one target the next alert about
    /// that same target stays silent.
    ///
    /// Not a drop: the banner is still updated, because the *newest* state of
    /// an agent is the true one and a stale banner is worse than a quiet one.
    /// This only governs the noise. A flapping hook that reports four times a
    /// minute should cost one buzz, not four.
    public var quietSeconds: TimeInterval
    /// Targets that never interrupt. The noisy pane you left running a test
    /// loop in, the one you already know about.
    ///
    /// Muting is about the buzz and the lock screen only. A muted target still
    /// gets its dot on the tile, because the dot is what you look at when you
    /// are looking, and muting is a statement about when you are not.
    public var mutedTargetIDs: Set<String>
    /// Whether an approval banner shows what the agent wants to run.
    ///
    /// Off, the banner says that an agent is asking and which one; on, it
    /// carries the first line or two of the command. The command is the
    /// most sensitive thing this app ever puts on a lock screen — paths,
    /// tokens, repository names — and a lock screen is read by whoever is
    /// looking at the phone, so showing it is a choice rather than a default.
    public var showsApprovalDetail: Bool

    public static let quietRange: ClosedRange<TimeInterval> = 0...300

    public init(isEnabled: Bool = true,
                waiting: Bool = true,
                failed: Bool = true,
                done: Bool = false,
                approvals: Bool = true,
                playsSound: Bool = true,
                quietSeconds: TimeInterval = 30,
                mutedTargetIDs: Set<String> = [],
                showsApprovalDetail: Bool = false) {
        self.isEnabled = isEnabled
        self.waiting = waiting
        self.failed = failed
        self.done = done
        self.approvals = approvals
        self.playsSound = playsSound
        self.quietSeconds = min(max(quietSeconds, AlertSettings.quietRange.lowerBound),
                                AlertSettings.quietRange.upperBound)
        self.mutedTargetIDs = mutedTargetIDs
        self.showsApprovalDetail = showsApprovalDetail
    }

    /// Every field defaulted, for the reason `NimletTarget`'s decoder gives: this
    /// is read back from preferences written by an older build, and a field
    /// that did not exist then must not cost the user every setting they have.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = AlertSettings()
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? fallback.isEnabled
        waiting = try c.decodeIfPresent(Bool.self, forKey: .waiting) ?? fallback.waiting
        failed = try c.decodeIfPresent(Bool.self, forKey: .failed) ?? fallback.failed
        done = try c.decodeIfPresent(Bool.self, forKey: .done) ?? fallback.done
        approvals = try c.decodeIfPresent(Bool.self, forKey: .approvals) ?? fallback.approvals
        playsSound = try c.decodeIfPresent(Bool.self, forKey: .playsSound) ?? fallback.playsSound
        let quiet = try c.decodeIfPresent(TimeInterval.self, forKey: .quietSeconds) ?? fallback.quietSeconds
        quietSeconds = min(max(quiet, AlertSettings.quietRange.lowerBound),
                           AlertSettings.quietRange.upperBound)
        mutedTargetIDs = try c.decodeIfPresent(Set<String>.self, forKey: .mutedTargetIDs) ?? []
        showsApprovalDetail = try c.decodeIfPresent(Bool.self, forKey: .showsApprovalDetail) ?? fallback.showsApprovalDetail
    }

    /// Whether this kind of agent report is one the user asked to hear about.
    public func allows(_ kind: AgentEvent.Kind) -> Bool {
        guard isEnabled else { return false }
        switch kind {
        case .waiting: return waiting
        case .failed: return failed
        case .done: return done
        }
    }

    public func isMuted(_ targetID: String?) -> Bool {
        guard let targetID else { return false }
        return mutedTargetIDs.contains(targetID)
    }
}

/// One thing to put in front of somebody, already decided.
///
/// Deliberately not a `UNNotificationRequest`: this type is the whole decision,
/// and it is made in `Shared` where it can be tested on a Mac with no
/// notification centre in the process. The phone's job is to translate it,
/// which is a dozen lines of assignment and no judgement at all.
///
/// `Codable` because it travels. When the phone is asleep the Mac decides the
/// alert — running this same policy, against the settings that phone sent it —
/// seals the result and pushes it; see `PushEnvelope`. One alert type, decided
/// by one set of rules, whichever end happens to be awake.
public struct AgentAlert: Codable, Sendable, Equatable, Identifiable {

    public enum Kind: String, Codable, Sendable, Equatable {
        case waiting, failed, done, approval
        /// An agent asked a question. Answered in the app, where its choices
        /// are, so its banner carries no buttons.
        case question

        /// The notification category each kind is posted under. Kept here so
        /// the app and the notification extension cannot disagree.
        public var category: String {
            switch self {
            case .approval: return "mice.agent.approval"
            case .question: return "mice.agent.question"
            case .waiting, .failed, .done: return "mice.agent.event"
            }
        }
    }

    /// Stable per subject, not per event. An agent that reports twice replaces
    /// its own notification instead of stacking a second one behind it — the
    /// lock screen should say what is true now, not keep a diary.
    public var id: String
    /// Groups a target's notifications under one heading in Notification
    /// Centre. One target, one stack.
    public var threadID: String
    public var title: String
    public var subtitle: String?
    public var body: String
    public var kind: Kind
    /// The target this is about, so a tap can take you to it and a mute can
    /// find it. Nil only for an approval that arrived without one.
    public var targetID: String?
    /// Set for an approval, so the banner can carry Approve and Deny and the
    /// answer can be matched back to the request.
    public var approvalID: String?
    /// Silent because something about this target buzzed a moment ago. The
    /// banner still appears and the screen still lights.
    public var isSilent: Bool
    /// Asks iOS to break through Focus and a locked screen. The system only
    /// honours this for an app the user has granted it to, and quietly treats
    /// it as an ordinary alert otherwise — so it is safe to ask.
    public var isTimeSensitive: Bool
    /// Where this sorts in a stack of several. Highest first.
    public var relevance: Double
    /// The number for the app icon at the moment this was decided.
    public var badge: Int

    public init(id: String,
                threadID: String,
                title: String,
                subtitle: String? = nil,
                body: String,
                kind: Kind,
                targetID: String?,
                approvalID: String? = nil,
                isSilent: Bool,
                isTimeSensitive: Bool,
                relevance: Double,
                badge: Int) {
        self.id = id
        self.threadID = threadID
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.kind = kind
        self.targetID = targetID
        self.approvalID = approvalID
        self.isSilent = isSilent
        self.isTimeSensitive = isTimeSensitive
        self.relevance = relevance
        self.badge = badge
    }

    /// Defaulted throughout, for the reason every other decoder here is: this
    /// arrives inside a push sealed by a Mac that may be a version ahead or
    /// behind, and a field it did not have is not a good enough reason to show
    /// nothing at all.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        threadID = try c.decodeIfPresent(String.self, forKey: .threadID) ?? "target.unknown"
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Nimlet"
        subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle)
        body = try c.decodeIfPresent(String.self, forKey: .body) ?? "Something needs you"
        kind = (try? c.decodeIfPresent(Kind.self, forKey: .kind)).flatMap { $0 } ?? .waiting
        targetID = try c.decodeIfPresent(String.self, forKey: .targetID)
        approvalID = try c.decodeIfPresent(String.self, forKey: .approvalID)
        isSilent = try c.decodeIfPresent(Bool.self, forKey: .isSilent) ?? false
        isTimeSensitive = try c.decodeIfPresent(Bool.self, forKey: .isTimeSensitive) ?? true
        relevance = try c.decodeIfPresent(Double.self, forKey: .relevance) ?? 0.9
        badge = try c.decodeIfPresent(Int.self, forKey: .badge) ?? 0
    }
}

/// What to do about one thing that happened.
///
/// Posting and withdrawing come back together because they are usually the
/// same event. An agent that says `done` after saying `waiting` posts nothing
/// — `done` is off by default — but it absolutely must take the "Waiting for
/// you" banner down, because that sentence is no longer true. A notification
/// system that only knows how to add is how a lock screen ends up lying.
public struct AlertOutcome: Sendable, Equatable {

    /// Why nothing was posted. Carried rather than dropped so the tests can
    /// name the rule they are checking, instead of asserting on a silence that
    /// could have come from anywhere.
    public enum Suppression: String, Sendable, Equatable {
        /// Already seen this exact report.
        case duplicate
        /// Older than `AlertPolicy.staleAfter`. A clock that disagrees, or a
        /// report that took the scenic route.
        case stale
        /// The user is holding the phone and looking at this app.
        case foreground
        /// Switched off, in general or for this kind.
        case disabled
        /// This target never interrupts.
        case muted
        /// The request had already timed out when it arrived.
        case expired
    }

    public var post: AgentAlert?
    /// Notification ids that are no longer true and should come down, whether
    /// or not they have already been shown.
    public var withdraw: [String]
    public var badge: Int
    public var suppression: Suppression?

    public init(post: AgentAlert? = nil,
                withdraw: [String] = [],
                badge: Int = 0,
                suppression: Suppression? = nil) {
        self.post = post
        self.withdraw = withdraw
        self.badge = badge
        self.suppression = suppression
    }
}

/// The rules, with no notification centre, no clock and no main thread in
/// them.
///
/// Pure and synchronous for the same reason `ApprovalLedger` is: this is the
/// part that must not be wrong, so it is the part with nothing in it that
/// cannot be run a thousand times in a test.
///
/// It also holds the small amount of memory the rules need — what is currently
/// on the lock screen, what each target last said, when each last made a
/// noise. Without that memory a notification system can only add, and most of
/// what makes one accurate is knowing what to take away.
public struct AlertPolicy: Sendable {

    /// Past this, a report is old news and gets no banner.
    ///
    /// Generous on purpose. The common case cannot produce a stale event at
    /// all — the host fans an event out to the phones connected at that moment
    /// and there is no replay — so this is a guard against two clocks
    /// disagreeing, not a filter anybody should ever hit. Set it tight and the
    /// first casualty is the phone whose clock is a minute slow.
    public static let staleAfter: TimeInterval = 300

    /// The shortest gap between two sounds, across every target.
    ///
    /// Four agents finishing a long build at the same second is one event to a
    /// person, and four buzzes in a row reads as a malfunction. The later ones
    /// still post, still light the screen and still stack — they just arrive
    /// quietly.
    public static let soundGap: TimeInterval = 3

    /// Notification ids should not collide across kinds, and should be
    /// derivable from the subject alone so the thing that posts and the thing
    /// that withdraws agree without passing ids around.
    public static func eventID(targetID: String) -> String { "agent.event." + targetID }
    public static func approvalID(requestID: String) -> String { "agent.approval." + requestID }
    public static func threadID(targetID: String?) -> String { "target." + (targetID ?? "unknown") }

    public var settings: AlertSettings

    /// What is on the lock screen right now, by notification id. The badge is
    /// this count, and "take down what is no longer true" is a filter over it.
    public private(set) var outstanding: [String: AgentAlert] = [:]

    /// The last report accepted from each target, so a repeat or an
    /// out-of-order straggler can be recognised without keeping every event
    /// ever seen.
    private var lastReport: [String: (millis: Int64, kind: AgentEvent.Kind)] = [:]
    /// When each target last made a noise, for the quiet window.
    private var lastSoundAt: [String: Int64] = [:]
    /// And when anything did, for the burst gate.
    private var lastAnySoundAt: Int64?

    public init(settings: AlertSettings = AlertSettings()) {
        self.settings = settings
    }

    public var badge: Int { outstanding.count }

    // MARK: - Agent reports

    /// An agent said something. Decide whether to interrupt, and take down
    /// whatever it just made untrue.
    ///
    /// - Parameters:
    ///   - isActive: whether the user is looking at this app right now. If they
    ///     are, the dot on the tile and the toast are the right weight for
    ///     this, and a banner over the app you are holding is noise.
    public mutating func receive(_ event: AgentEvent,
                                 targetName: String,
                                 isActive: Bool,
                                 now: Int64) -> AlertOutcome {
        // A report we have already acted on, or one that arrived behind a
        // newer one. Either way it says nothing new, and re-posting it would
        // resurrect a banner the newer report had taken down.
        if let last = lastReport[event.targetID],
           event.atEpochMillis < last.millis
            || (event.atEpochMillis == last.millis && event.kind == last.kind) {
            return AlertOutcome(badge: badge, suppression: .duplicate)
        }
        lastReport[event.targetID] = (event.atEpochMillis, event.kind)

        // Whatever this target had on the lock screen is now out of date —
        // including when the new report is one we do not post. This is the
        // `waiting` → `done` case, and it is the whole reason the policy keeps
        // state at all.
        var withdrawn = drop { $0.kind != .approval && $0.targetID == event.targetID }

        func give(_ reason: AlertOutcome.Suppression) -> AlertOutcome {
            AlertOutcome(withdraw: withdrawn, badge: badge, suppression: reason)
        }

        guard settings.allows(event.kind) else { return give(.disabled) }
        guard !settings.isMuted(event.targetID) else { return give(.muted) }
        guard now - event.atEpochMillis <= Int64(Self.staleAfter * 1000) else { return give(.stale) }
        guard !isActive else { return give(.foreground) }

        let thread = Self.threadID(targetID: event.targetID)
        let silent = !allowSound(thread: thread, now: now, respectingQuietWindow: true)
        let alert = AgentAlert(id: Self.eventID(targetID: event.targetID),
                               threadID: thread,
                               title: targetName,
                               body: Self.body(for: event),
                               kind: Self.kind(of: event.kind),
                               targetID: event.targetID,
                               isSilent: silent,
                               isTimeSensitive: event.kind != .done,
                               relevance: Self.relevance(of: event.kind),
                               badge: 0)
        // The sweep above took this target's own previous banner down, and
        // this one has the same id. Re-adding an id replaces it in place, so
        // leaving it in the withdraw list would remove and re-add the same
        // notification — a visible flicker, and a second buzz on some builds.
        withdrawn.removeAll { $0 == alert.id }
        return post(alert, alsoWithdrawing: withdrawn)
    }

    // MARK: - Approvals

    /// An agent is blocked on a decision and will be denied if nobody makes
    /// one. The most time-critical thing this app has to say.
    public mutating func receive(_ request: ApprovalRequest,
                                 isActive: Bool,
                                 now: Int64) -> AlertOutcome {
        let id = Self.approvalID(requestID: request.id)
        guard outstanding[id] == nil else {
            return AlertOutcome(badge: badge, suppression: .duplicate)
        }
        guard settings.isEnabled, settings.approvals else {
            return AlertOutcome(badge: badge, suppression: .disabled)
        }
        guard !settings.isMuted(request.targetID) else {
            return AlertOutcome(badge: badge, suppression: .muted)
        }
        guard !request.isExpired(at: now) else {
            return AlertOutcome(badge: badge, suppression: .expired)
        }
        guard !isActive else {
            return AlertOutcome(badge: badge, suppression: .foreground)
        }

        // The per-target quiet window does not apply: two approvals are two
        // separate decisions, and silencing the second because the first was
        // recent would be silencing a question nobody has answered. The burst
        // gate still does — four at once is still one noise.
        let silent = !allowSound(thread: Self.threadID(targetID: request.targetID),
                                 now: now,
                                 respectingQuietWindow: false)
        let alert = AgentAlert(id: id,
                               threadID: Self.threadID(targetID: request.targetID),
                               title: request.targetName,
                               subtitle: request.title,
                               body: settings.showsApprovalDetail
                                   ? Self.firstLines(of: request.detail)
                                   : (request.isQuestion ? Self.hiddenQuestionBody : Self.hiddenApprovalBody),
                               kind: request.isQuestion ? .question : .approval,
                               targetID: request.targetID,
                               approvalID: request.id,
                               isSilent: silent,
                               isTimeSensitive: true,
                               relevance: 1,
                               badge: 0)
        return post(alert, alsoWithdrawing: [])
    }

    /// The Mac's whole answer about what is still pending. Anything we are
    /// showing that is not in it has been answered, has expired, or was
    /// withdrawn by the asker — and a banner offering Approve and Deny for a
    /// decision that is already made is the worst thing on this list.
    public mutating func retainApprovals(_ ids: Set<String>) -> AlertOutcome {
        let gone = drop { alert in
            guard let approvalID = alert.approvalID else { return false }
            return !ids.contains(approvalID)
        }
        return AlertOutcome(withdraw: gone, badge: badge)
    }

    /// One request is done with, by whatever route.
    public mutating func resolved(approvalID: String) -> AlertOutcome {
        let gone = drop { $0.approvalID == approvalID }
        return AlertOutcome(withdraw: gone, badge: badge)
    }

    /// The deadlines the Mac has not told us about, because telling us needs a
    /// connection it may not have. A card that has run out is a denial already;
    /// leaving its banner up invites an answer that cannot land.
    public mutating func expireApprovals(pending: [ApprovalRequest], now: Int64) -> AlertOutcome {
        let live = Set(pending.filter { !$0.isExpired(at: now) }.map(\.id))
        return retainApprovals(live)
    }

    // MARK: - Looking at the app

    /// The user opened Nimlet. Everything here has been superseded by the thing
    /// itself: the dots are on the tiles, the cards are in the sheet, and the
    /// ages are live. A lock screen full of notifications about an app you are
    /// looking at is the most common way this feature goes wrong.
    public mutating func opened() -> AlertOutcome {
        AlertOutcome(withdraw: drop { _ in true }, badge: 0)
    }

    /// Settings changed. Anything that would no longer be posted comes down
    /// now rather than sitting there as a promise the new settings do not keep.
    public mutating func apply(_ settings: AlertSettings) -> AlertOutcome {
        self.settings = settings
        let gone = drop { alert in
            if !settings.isEnabled { return true }
            if settings.isMuted(alert.targetID) { return true }
            switch alert.kind {
            case .approval, .question: return !settings.approvals
            case .waiting: return !settings.waiting
            case .failed: return !settings.failed
            case .done: return !settings.done
            }
        }
        return AlertOutcome(withdraw: gone, badge: badge)
    }

    /// One alert is no longer on the screen, and nothing was decided by that.
    ///
    /// Two callers, and they are the reason `outstanding` has to be a record of
    /// what the lock screen actually holds rather than of what we asked it to:
    /// the notification centre refusing a post because permission has not been
    /// granted yet, and the user swiping one away. Both leave a phantom in the
    /// count otherwise, and a badge nobody can clear is the classic version of
    /// this bug.
    @discardableResult
    public mutating func undo(id: String) -> AlertOutcome {
        outstanding.removeValue(forKey: id)
        return AlertOutcome(badge: badge)
    }

    /// Everything down, memory included. For disconnecting or signing out of a
    /// Mac, where the ids on screen refer to targets this phone can no longer
    /// reach.
    public mutating func reset() -> AlertOutcome {
        let gone = drop { _ in true }
        lastReport.removeAll()
        lastSoundAt.removeAll()
        lastAnySoundAt = nil
        return AlertOutcome(withdraw: gone, badge: 0)
    }

    // MARK: - Plumbing

    /// Books the alert, then stamps it with the badge it produced. Two steps
    /// because the badge *is* the outstanding count, so it cannot be known
    /// until this one is in.
    private mutating func post(_ alert: AgentAlert, alsoWithdrawing withdrawn: [String]) -> AlertOutcome {
        var booked = alert
        outstanding[booked.id] = booked
        booked.badge = badge
        outstanding[booked.id] = booked
        return AlertOutcome(post: booked, withdraw: withdrawn, badge: badge)
    }

    /// Removes everything matching and returns what was removed, so a caller
    /// never has to ask twice or keep the two lists in step by hand.
    private mutating func drop(where matches: (AgentAlert) -> Bool) -> [String] {
        let gone = outstanding.filter { matches($0.value) }.map(\.key).sorted()
        for id in gone { outstanding.removeValue(forKey: id) }
        return gone
    }

    /// Whether this alert gets to make a noise, and books the noise if so.
    private mutating func allowSound(thread: String,
                                     now: Int64,
                                     respectingQuietWindow: Bool) -> Bool {
        guard settings.playsSound else { return false }
        if respectingQuietWindow, settings.quietSeconds > 0,
           let last = lastSoundAt[thread],
           now - last < Int64(settings.quietSeconds * 1000) {
            return false
        }
        if let last = lastAnySoundAt, now - last < Int64(Self.soundGap * 1000) {
            return false
        }
        lastSoundAt[thread] = now
        lastAnySoundAt = now
        return true
    }

    private static func kind(of kind: AgentEvent.Kind) -> AgentAlert.Kind {
        switch kind {
        case .waiting: return .waiting
        case .failed: return .failed
        case .done: return .done
        }
    }

    /// Where an alert sorts against the others in its stack. An unanswered
    /// question outranks a stopped run, which outranks a finished one.
    private static func relevance(of kind: AgentEvent.Kind) -> Double {
        switch kind {
        case .waiting: return 0.9
        case .failed: return 0.8
        case .done: return 0.3
        }
    }

    /// The hook's own words when it gave any, and a plain sentence when it did
    /// not. The note is what the person who wrote the hook wanted said, and it
    /// beats anything this file could invent.
    static func body(for event: AgentEvent) -> String {
        if let note = event.note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
            return firstLines(of: note)
        }
        switch event.kind {
        case .waiting: return "Waiting for you"
        case .failed: return "Something failed"
        case .done: return "Finished"
        }
    }

    /// What an approval banner says instead of the command when the user has
    /// not asked to see commands on the lock screen. The title already names
    /// the agent and the subtitle says what kind of thing it wants to do.
    public static let hiddenApprovalBody = "Open Nimlet to see what it wants to run"
    /// The same, for a question: the question itself can say as much about the
    /// work as a command does.
    public static let hiddenQuestionBody = "Open Nimlet to see the question and answer it"

    /// A banner is two or three lines and an approval detail can be four
    /// thousand characters of diff. Cut it here rather than hand the whole
    /// thing to the notification centre and hope.
    static func firstLines(of text: String, limit: Int = 200) -> String {
        let flattened = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: " · ")
        guard flattened.count > limit else { return flattened }
        return String(flattened.prefix(limit)) + "…"
    }
}
