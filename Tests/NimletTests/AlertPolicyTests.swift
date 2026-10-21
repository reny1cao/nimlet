import XCTest

/// The rules that decide what the phone interrupts you for.
///
/// Worth this much testing for one reason: every bug in a notification system
/// is a bug you cannot see. A banner that should have appeared and did not
/// looks exactly like an agent that had nothing to say, and a banner that
/// should have come down and did not is a lock screen telling you something
/// untrue about your own machine. Neither shows up in a screenshot.
///
/// Times are epoch milliseconds throughout, same as the wire.
final class AlertPolicyTests: XCTestCase {

    private let t0: Int64 = 1_700_000_000_000

    private func event(_ kind: AgentEvent.Kind,
                       _ target: String = "t-1",
                       at millis: Int64? = nil,
                       note: String? = nil) -> AgentEvent {
        AgentEvent(targetID: target, kind: kind, atEpochMillis: millis ?? t0, note: note)
    }

    private func approval(_ id: String = "a-1",
                          target: String? = "t-1",
                          at millis: Int64? = nil,
                          timeout: TimeInterval = 120) -> ApprovalRequest {
        ApprovalRequest(id: id,
                        targetID: target,
                        targetName: "claude",
                        title: "Run a command",
                        detail: "rm -rf build",
                        kind: .command,
                        createdAtEpochMillis: millis ?? t0,
                        timeout: timeout)
    }

    /// The common case: away from the phone, notifications on, nothing recent.
    private func receive(_ policy: inout AlertPolicy,
                         _ event: AgentEvent,
                         name: String = "claude",
                         active: Bool = false,
                         at millis: Int64? = nil) -> AlertOutcome {
        policy.receive(event, targetName: name, isActive: active, now: millis ?? event.atEpochMillis)
    }

    // MARK: - What is worth interrupting for

    func testAnAgentBlockedOnYouInterrupts() {
        var policy = AlertPolicy()
        let outcome = receive(&policy, event(.waiting))
        XCTAssertEqual(outcome.post?.kind, .waiting)
        XCTAssertEqual(outcome.post?.title, "claude")
        XCTAssertEqual(outcome.post?.body, "Waiting for you")
        XCTAssertEqual(outcome.badge, 1)
        // Focus and a locked screen are exactly the situation this exists for.
        XCTAssertEqual(outcome.post?.isTimeSensitive, true)
    }

    func testAFailedRunInterrupts() {
        var policy = AlertPolicy()
        XCTAssertEqual(receive(&policy, event(.failed)).post?.kind, .failed)
    }

    /// The default that keeps the other two alive. An app that buzzes on every
    /// finished turn gets its notifications switched off, and then `waiting`
    /// is gone too.
    func testAFinishedTurnDoesNotInterruptUnlessAsked() {
        var policy = AlertPolicy()
        let quiet = receive(&policy, event(.done))
        XCTAssertNil(quiet.post)
        XCTAssertEqual(quiet.suppression, .disabled)

        var asked = AlertPolicy(settings: AlertSettings(done: true))
        let outcome = receive(&asked, event(.done))
        XCTAssertEqual(outcome.post?.kind, .done)
        // Still the quietest thing here: it lands in Notification Centre
        // without lighting a locked screen.
        XCTAssertEqual(outcome.post?.isTimeSensitive, false)
    }

    func testTheHooksOwnWordsBeatOurs() {
        var policy = AlertPolicy()
        let outcome = receive(&policy, event(.waiting, note: "Needs a merge decision"))
        XCTAssertEqual(outcome.post?.body, "Needs a merge decision")
    }

    func testAnEmptyNoteFallsBackToTheSentence() {
        var policy = AlertPolicy()
        XCTAssertEqual(receive(&policy, event(.failed, note: "   \n ")).post?.body,
                       "Something failed")
    }

    // MARK: - Accuracy: taking down what stopped being true

    /// The case the whole design turns on. `done` posts nothing, and must
    /// still remove "Waiting for you" — that sentence is now false, and a lock
    /// screen that keeps saying it is worse than one that said nothing.
    func testFinishingTakesDownTheWaitingBanner() {
        var policy = AlertPolicy()
        let waiting = receive(&policy, event(.waiting))
        let waitingID = try? XCTUnwrap(waiting.post?.id)

        let done = receive(&policy, event(.done, at: t0 + 5_000))
        XCTAssertNil(done.post, "done is off by default")
        XCTAssertEqual(done.withdraw, [waitingID].compactMap { $0 })
        XCTAssertEqual(done.badge, 0)
        XCTAssertTrue(policy.outstanding.isEmpty)
    }

    /// And when the new report *does* post, the replacement happens in place
    /// rather than as a removal followed by an add — which flickers, and on
    /// some builds buzzes twice.
    func testANewReportReplacesTheOldOneInPlace() {
        var policy = AlertPolicy()
        let first = receive(&policy, event(.waiting))
        let second = receive(&policy, event(.failed, at: t0 + 60_000), at: t0 + 60_000)
        XCTAssertEqual(second.post?.id, first.post?.id)
        XCTAssertEqual(second.withdraw, [], "same id: re-adding replaces it")
        XCTAssertEqual(second.badge, 1, "one target, one banner")
    }

    func testOneTargetsReportDoesNotDisturbAnother() {
        var policy = AlertPolicy()
        _ = receive(&policy, event(.waiting, "t-1"))
        let other = receive(&policy, event(.waiting, "t-2", at: t0 + 10_000), at: t0 + 10_000)
        XCTAssertEqual(other.withdraw, [])
        XCTAssertEqual(other.badge, 2)
    }

    func testTheSameReportTwiceIsOnlyOneBanner() {
        var policy = AlertPolicy()
        _ = receive(&policy, event(.waiting))
        let again = receive(&policy, event(.waiting))
        XCTAssertNil(again.post)
        XCTAssertEqual(again.suppression, .duplicate)
        XCTAssertEqual(again.withdraw, [], "a duplicate must not take down the banner it duplicates")
    }

    /// A straggler that arrives after a newer report must not resurrect a
    /// banner the newer one retired.
    func testAnOutOfOrderReportIsIgnored() {
        var policy = AlertPolicy()
        _ = receive(&policy, event(.waiting, at: t0))
        _ = receive(&policy, event(.done, at: t0 + 30_000), at: t0 + 30_000)
        let straggler = receive(&policy, event(.waiting, at: t0 + 1_000), at: t0 + 31_000)
        XCTAssertNil(straggler.post)
        XCTAssertEqual(straggler.suppression, .duplicate)
        XCTAssertTrue(policy.outstanding.isEmpty)
    }

    func testAReportFromLongAgoGetsNoBanner() {
        var policy = AlertPolicy()
        let late = receive(&policy, event(.waiting, at: t0),
                           at: t0 + Int64(AlertPolicy.staleAfter * 1000) + 1)
        XCTAssertNil(late.post)
        XCTAssertEqual(late.suppression, .stale)
    }

    func testAReportInsideTheWindowStillCounts() {
        var policy = AlertPolicy()
        let outcome = receive(&policy, event(.waiting, at: t0),
                              at: t0 + Int64(AlertPolicy.staleAfter * 1000))
        XCTAssertNotNil(outcome.post)
    }

    /// A phone whose clock is behind the Mac's sees an event stamped in the
    /// future. That is skew, not staleness, and must not be silently dropped.
    func testAReportFromTheFutureIsNotTreatedAsStale() {
        var policy = AlertPolicy()
        XCTAssertNotNil(receive(&policy, event(.waiting, at: t0 + 90_000), at: t0).post)
    }

    // MARK: - Looking at the phone

    func testNothingInterruptsTheAppYouAreLookingAt() {
        var policy = AlertPolicy()
        let outcome = receive(&policy, event(.waiting), active: true)
        XCTAssertNil(outcome.post)
        XCTAssertEqual(outcome.suppression, .foreground)
        XCTAssertEqual(outcome.badge, 0)
    }

    /// Opening the app is the user seeing all of it. The dots are on the tiles
    /// and the cards are in the sheet, so the lock screen has nothing left to
    /// add.
    func testOpeningTheAppClearsEverything() {
        var policy = AlertPolicy()
        _ = receive(&policy, event(.waiting, "t-1"))
        _ = receive(&policy, event(.failed, "t-2", at: t0 + 10_000), at: t0 + 10_000)
        _ = policy.receive(approval(), isActive: false, now: t0 + 20_000)

        let opened = policy.opened()
        XCTAssertEqual(opened.withdraw.count, 3)
        XCTAssertEqual(opened.badge, 0)
        XCTAssertTrue(policy.outstanding.isEmpty)
    }

    // MARK: - Smoothness: how often it is allowed to buzz

    func testASecondReportFromTheSameTargetArrivesQuietly() {
        var policy = AlertPolicy()
        XCTAssertEqual(receive(&policy, event(.waiting)).post?.isSilent, false)
        // Inside the quiet window: still posted, still current, no second buzz.
        let soon = receive(&policy, event(.failed, at: t0 + 10_000), at: t0 + 10_000)
        XCTAssertEqual(soon.post?.isSilent, true)
        XCTAssertNotNil(soon.post, "quiet means quiet, not dropped")
    }

    func testTheQuietWindowExpires() {
        var policy = AlertPolicy()
        _ = receive(&policy, event(.waiting))
        let later = t0 + Int64(policy.settings.quietSeconds * 1000) + 1
        XCTAssertEqual(receive(&policy, event(.failed, at: later), at: later).post?.isSilent, false)
    }

    /// Four agents finishing the same long build is one event to a person.
    func testABurstAcrossTargetsMakesOneNoise() {
        var policy = AlertPolicy()
        var sounded = 0
        for index in 0..<4 {
            let at = t0 + Int64(index) * 200
            if receive(&policy, event(.waiting, "t-\(index)", at: at), at: at).post?.isSilent == false {
                sounded += 1
            }
        }
        XCTAssertEqual(sounded, 1)
        XCTAssertEqual(policy.badge, 4, "quiet, but all four are there")
    }

    func testTheBurstGateOpensAgain() {
        var policy = AlertPolicy()
        _ = receive(&policy, event(.waiting, "t-1"))
        let after = t0 + Int64(AlertPolicy.soundGap * 1000) + 1
        XCTAssertEqual(receive(&policy, event(.waiting, "t-2", at: after), at: after).post?.isSilent,
                       false)
    }

    func testSoundCanBeTurnedOffWithoutTurningOffTheBanner() {
        var policy = AlertPolicy(settings: AlertSettings(playsSound: false))
        let outcome = receive(&policy, event(.waiting))
        XCTAssertNotNil(outcome.post)
        XCTAssertEqual(outcome.post?.isSilent, true)
    }

    func testAZeroQuietWindowLetsEveryReportSound() {
        var policy = AlertPolicy(settings: AlertSettings(quietSeconds: 0))
        _ = receive(&policy, event(.waiting))
        // Past the burst gate, which is not the same rule and still applies.
        let at = t0 + Int64(AlertPolicy.soundGap * 1000) + 1
        XCTAssertEqual(receive(&policy, event(.failed, at: at), at: at).post?.isSilent, false)
    }

    // MARK: - Configurable

    func testTheMasterSwitchStopsEverything() {
        var policy = AlertPolicy(settings: AlertSettings(isEnabled: false))
        XCTAssertEqual(receive(&policy, event(.waiting)).suppression, .disabled)
        XCTAssertEqual(policy.receive(approval(), isActive: false, now: t0).suppression, .disabled)
    }

    func testAKindCanBeTurnedOffOnItsOwn() {
        var policy = AlertPolicy(settings: AlertSettings(waiting: false))
        XCTAssertEqual(receive(&policy, event(.waiting)).suppression, .disabled)
        XCTAssertNotNil(receive(&policy, event(.failed, at: t0 + 1_000), at: t0 + 1_000).post)
    }

    func testAMutedTargetNeverInterrupts() {
        var policy = AlertPolicy(settings: AlertSettings(mutedTargetIDs: ["t-noisy"]))
        XCTAssertEqual(receive(&policy, event(.waiting, "t-noisy")).suppression, .muted)
        XCTAssertEqual(policy.receive(approval(target: "t-noisy"), isActive: false, now: t0).suppression,
                       .muted)
        // And says nothing about any other target.
        XCTAssertNotNil(receive(&policy, event(.waiting, "t-1", at: t0 + 1_000), at: t0 + 1_000).post)
    }

    /// Changing a setting has to act on what is already on the lock screen.
    /// Muting a target and watching its banner sit there is the complaint.
    func testTurningSomethingOffTakesDownWhatItWouldNoLongerPost() {
        var policy = AlertPolicy()
        _ = receive(&policy, event(.waiting, "t-1"))
        _ = receive(&policy, event(.failed, "t-2", at: t0 + 10_000), at: t0 + 10_000)

        let muted = policy.apply(AlertSettings(mutedTargetIDs: ["t-1"]))
        XCTAssertEqual(muted.withdraw, [AlertPolicy.eventID(targetID: "t-1")])
        XCTAssertEqual(muted.badge, 1)

        let off = policy.apply(AlertSettings(isEnabled: false))
        XCTAssertEqual(off.withdraw, [AlertPolicy.eventID(targetID: "t-2")])
        XCTAssertEqual(off.badge, 0)
    }

    func testSettingsSurviveAFieldThatDidNotExistYet() throws {
        // Written by a build that had never heard of `quietSeconds` or mutes.
        let json = Data(#"{"isEnabled":true,"waiting":false}"#.utf8)
        let settings = try JSONDecoder().decode(AlertSettings.self, from: json)
        XCTAssertFalse(settings.waiting)
        XCTAssertTrue(settings.failed, "a missing field must not cost the user the rest")
        XCTAssertEqual(settings.quietSeconds, AlertSettings().quietSeconds)
        XCTAssertTrue(settings.mutedTargetIDs.isEmpty)
    }

    func testAnAbsurdQuietWindowIsClamped() throws {
        XCTAssertEqual(AlertSettings(quietSeconds: -30).quietSeconds, 0)
        XCTAssertEqual(AlertSettings(quietSeconds: 99_999).quietSeconds,
                       AlertSettings.quietRange.upperBound)
        let decoded = try JSONDecoder().decode(AlertSettings.self,
                                               from: Data(#"{"quietSeconds":99999}"#.utf8))
        XCTAssertEqual(decoded.quietSeconds, AlertSettings.quietRange.upperBound)
    }

    func testSettingsRoundTrip() throws {
        let settings = AlertSettings(done: true, playsSound: false,
                                     quietSeconds: 45, mutedTargetIDs: ["a", "b"])
        let decoded = try JSONDecoder().decode(AlertSettings.self,
                                               from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded, settings)
    }

    // MARK: - Approvals

    func testAnApprovalInterrupts() {
        var policy = AlertPolicy(settings: AlertSettings(showsApprovalDetail: true))
        let outcome = policy.receive(approval(), isActive: false, now: t0)
        XCTAssertEqual(outcome.post?.kind, .approval)
        XCTAssertEqual(outcome.post?.approvalID, "a-1")
        XCTAssertEqual(outcome.post?.title, "claude")
        XCTAssertEqual(outcome.post?.subtitle, "Run a command")
        XCTAssertEqual(outcome.post?.body, "rm -rf build")
        XCTAssertEqual(outcome.post?.isTimeSensitive, true)
        XCTAssertEqual(outcome.post?.relevance, 1)
    }

    /// Two questions are two questions. Silencing the second because the first
    /// was recent silences one nobody has answered.
    func testASecondApprovalIgnoresTheQuietWindow() {
        var policy = AlertPolicy()
        _ = policy.receive(approval("a-1"), isActive: false, now: t0)
        let at = t0 + Int64(AlertPolicy.soundGap * 1000) + 1
        let second = policy.receive(approval("a-2"), isActive: false, now: at)
        XCTAssertEqual(second.post?.isSilent, false)
        XCTAssertEqual(second.badge, 2)
    }

    func testAnApprovalAndAnEventCoexist() {
        var policy = AlertPolicy()
        _ = receive(&policy, event(.waiting))
        let asked = policy.receive(approval(), isActive: false, now: t0 + 1_000)
        XCTAssertEqual(asked.withdraw, [], "a question does not retract a status")
        XCTAssertEqual(asked.badge, 2)
    }

    /// And the other way round: a report about the target must not silently
    /// cancel the question it is still blocked on.
    func testAReportDoesNotTakeDownAnApproval() {
        var policy = AlertPolicy()
        _ = policy.receive(approval(), isActive: false, now: t0)
        let reported = receive(&policy, event(.waiting, at: t0 + 1_000), at: t0 + 1_000)
        XCTAssertEqual(reported.withdraw, [])
        XCTAssertEqual(policy.outstanding.count, 2)
    }

    func testTheSameApprovalTwiceIsOneBanner() {
        var policy = AlertPolicy()
        _ = policy.receive(approval(), isActive: false, now: t0)
        let again = policy.receive(approval(), isActive: false, now: t0 + 500)
        XCTAssertNil(again.post)
        XCTAssertEqual(again.suppression, .duplicate)
        XCTAssertEqual(again.badge, 1)
    }

    /// The worst thing on this list: a banner offering Approve and Deny for a
    /// decision that has already been made.
    func testAnAnsweredApprovalComesDown() {
        var policy = AlertPolicy()
        let posted = policy.receive(approval("a-1"), isActive: false, now: t0)
        let resolved = policy.resolved(approvalID: "a-1")
        XCTAssertEqual(resolved.withdraw, [posted.post?.id].compactMap { $0 })
        XCTAssertEqual(resolved.badge, 0)
    }

    func testTheMacsListIsTheTruthAboutWhatIsStillPending() {
        var policy = AlertPolicy()
        _ = policy.receive(approval("a-1"), isActive: false, now: t0)
        _ = policy.receive(approval("a-2"), isActive: false, now: t0 + 4_000)
        _ = receive(&policy, event(.waiting), at: t0 + 8_000)

        let outcome = policy.retainApprovals(["a-2"])
        XCTAssertEqual(outcome.withdraw, [AlertPolicy.approvalID(requestID: "a-1")])
        XCTAssertEqual(outcome.badge, 2, "a-2 and the report are both still true")
    }

    /// The Mac tells us about an expiry over a connection it may not have.
    /// A card that has run out is already a denial.
    func testAnExpiredApprovalComesDownWithoutBeingTold() {
        var policy = AlertPolicy()
        let request = approval("a-1", timeout: 60)
        _ = policy.receive(request, isActive: false, now: t0)
        let outcome = policy.expireApprovals(pending: [request], now: t0 + 61_000)
        XCTAssertEqual(outcome.withdraw, [AlertPolicy.approvalID(requestID: "a-1")])
        XCTAssertEqual(outcome.badge, 0)
    }

    func testAnApprovalThatArrivedTooLateIsNotShown() {
        var policy = AlertPolicy()
        let outcome = policy.receive(approval(timeout: 60), isActive: false, now: t0 + 61_000)
        XCTAssertNil(outcome.post)
        XCTAssertEqual(outcome.suppression, .expired)
    }

    /// The default: the command stays off the lock screen. The title and
    /// subtitle still say who is asking and what kind of thing it is.
    func testAnApprovalHidesTheCommandUnlessAsked() {
        var policy = AlertPolicy()
        let outcome = policy.receive(approval(), isActive: false, now: t0)
        XCTAssertEqual(outcome.post?.title, "claude")
        XCTAssertEqual(outcome.post?.subtitle, "Run a command")
        XCTAssertEqual(outcome.post?.body, AlertPolicy.hiddenApprovalBody)
        XCTAssertFalse(outcome.post?.body.contains("rm -rf") ?? true)
    }

    /// A question is posted as one: no Approve or Deny on the lock screen, and
    /// the question itself kept off it unless asked, like a command.
    func testAQuestionIsItsOwnKindOfBanner() {
        var policy = AlertPolicy()
        let asked = ApprovalRequest(id: "q-1", targetID: "t-1", targetName: "claude", title: "Has a question",
                                    detail: "Which database?", createdAtEpochMillis: t0,
                                    questions: [ApprovalQuestion(question: "Which database?", options: [])],
                                    returnsToMac: true)
        let outcome = policy.receive(asked, isActive: false, now: t0)
        XCTAssertEqual(outcome.post?.kind, .question)
        XCTAssertEqual(outcome.post?.approvalID, "q-1", "a tap has to find the card")
        XCTAssertEqual(outcome.post?.body, AlertPolicy.hiddenQuestionBody)
        XCTAssertEqual(AgentAlert.Kind.question.category, "mice.agent.question")
        XCTAssertEqual(AgentAlert.Kind.approval.category, "mice.agent.approval")
        XCTAssertEqual(AgentAlert.Kind.waiting.category, "mice.agent.event")

        var off = AlertSettings()
        off.approvals = false
        XCTAssertEqual(policy.apply(off).withdraw, [AlertPolicy.approvalID(requestID: "q-1")])
    }

    func testALongDetailIsCutToBannerLength() {
        var policy = AlertPolicy(settings: AlertSettings(showsApprovalDetail: true))
        let detail = String(repeating: "x", count: 4_000)
        let request = ApprovalRequest(id: "a-1", targetName: "claude",
                                      title: "Write a file", detail: detail,
                                      createdAtEpochMillis: t0)
        let body = try? XCTUnwrap(policy.receive(request, isActive: false, now: t0).post?.body)
        XCTAssertLessThanOrEqual(body?.count ?? .max, 201)
        XCTAssertEqual(body?.hasSuffix("…"), true)
    }

    func testAMultilineDetailBecomesOneLine() {
        var policy = AlertPolicy(settings: AlertSettings(showsApprovalDetail: true))
        let request = ApprovalRequest(id: "a-1", targetName: "claude", title: "Run",
                                      detail: "cd /tmp\nrm -rf build", createdAtEpochMillis: t0)
        XCTAssertEqual(policy.receive(request, isActive: false, now: t0).post?.body,
                       "cd /tmp · rm -rf build")
    }

    // MARK: - Grouping and identity

    func testATargetsAlertsShareAThread() {
        var policy = AlertPolicy()
        let reported = receive(&policy, event(.waiting, "t-7"))
        let asked = policy.receive(approval(target: "t-7"), isActive: false, now: t0 + 1_000)
        XCTAssertEqual(reported.post?.threadID, asked.post?.threadID)
    }

    func testAnEventAndAnApprovalNeverShareAnID() {
        XCTAssertNotEqual(AlertPolicy.eventID(targetID: "x"), AlertPolicy.approvalID(requestID: "x"))
    }

    // MARK: - What never reached the screen

    /// The phone posts nothing before permission is granted, and the user can
    /// swipe a banner away. Either way the policy has to stop counting it, or
    /// the badge becomes a red dot nobody can clear.
    func testAnAlertThatNeverReachedTheScreenStopsCounting() {
        var policy = AlertPolicy()
        let posted = receive(&policy, event(.waiting))
        XCTAssertEqual(policy.badge, 1)

        let id = posted.post?.id ?? ""
        XCTAssertEqual(policy.undo(id: id).badge, 0)
        XCTAssertTrue(policy.outstanding.isEmpty)

        // And it is not remembered as having been shown, so the same target's
        // next report posts normally rather than only replacing a ghost.
        let next = receive(&policy, event(.failed, at: t0 + 60_000), at: t0 + 60_000)
        XCTAssertNotNil(next.post)
        XCTAssertEqual(next.withdraw, [])
    }

    func testUndoingSomethingUnknownChangesNothing() {
        var policy = AlertPolicy()
        _ = receive(&policy, event(.waiting))
        XCTAssertEqual(policy.undo(id: "nonsense").badge, 1)
    }

    // MARK: - Starting over

    func testResettingForgetsTheBanners() {
        var policy = AlertPolicy()
        _ = receive(&policy, event(.waiting))
        let outcome = policy.reset()
        XCTAssertEqual(outcome.withdraw.count, 1)
        XCTAssertEqual(outcome.badge, 0)
        // And forgets what it had seen, so the same report after a reconnect
        // is news again rather than a duplicate of something now gone.
        XCTAssertNotNil(receive(&policy, event(.waiting)).post)
    }

    // MARK: - The invariant

    /// Whatever route it took, the badge is the number of things actually on
    /// the lock screen. A badge that drifts from that is a red dot nobody can
    /// clear.
    func testTheBadgeAlwaysMatchesWhatIsOutstanding() {
        var policy = AlertPolicy(settings: AlertSettings(done: true, quietSeconds: 5))
        var now = t0
        let kinds: [AgentEvent.Kind] = [.waiting, .done, .failed]
        for step in 0..<60 {
            now += 1_500
            let outcome: AlertOutcome
            switch step % 5 {
            case 0, 1:
                outcome = receive(&policy,
                                  event(kinds[step % 3], "t-\(step % 4)", at: now),
                                  active: step % 11 == 0,
                                  at: now)
            case 2:
                outcome = policy.receive(approval("a-\(step)", target: "t-\(step % 4)", at: now),
                                         isActive: false, now: now)
            case 3:
                outcome = policy.resolved(approvalID: "a-\(step - 1)")
            default:
                outcome = policy.retainApprovals([])
            }
            XCTAssertEqual(outcome.badge, policy.outstanding.count, "step \(step)")
            XCTAssertEqual(policy.badge, policy.outstanding.count, "step \(step)")
            if let post = outcome.post {
                XCTAssertEqual(post.badge, policy.badge, "step \(step)")
                XCTAssertNotNil(policy.outstanding[post.id], "step \(step)")
                XCTAssertFalse(outcome.withdraw.contains(post.id),
                               "step \(step): never withdraw what you just posted")
            }
            for id in outcome.withdraw {
                XCTAssertNil(policy.outstanding[id], "step \(step): \(id) should be gone")
            }
        }
    }
}
