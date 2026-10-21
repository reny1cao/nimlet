import XCTest
import CryptoKit

/// Reaching a phone that is asleep, without telling the relay anything.
///
/// Two halves, tested separately because they fail differently. The envelope is
/// cryptography: it is either exactly right or it is a privacy claim the README
/// makes and the code does not keep. The router is judgement: it decides who
/// gets woken, and the expensive bug there is a phone buzzing in a cinema about
/// something the user is already reading on the Mac.
final class PushTests: XCTestCase {

    private func profile(environment: String) throws -> Data {
        let plist = try PropertyListSerialization.data(fromPropertyList: [
            "Entitlements": ["aps-environment": environment],
        ], format: .xml, options: 0)
        // A profile is a CMS envelope; the surrounding bytes need not be UTF-8.
        return Data([0x30, 0x82, 0xff]) + plist + Data([0xff, 0x00])
    }

    func testDevelopmentSigningOverridesReleasePushDefault() throws {
        XCTAssertTrue(PushEnvironment.usesSandbox(provisioningProfile: try profile(environment: "development"),
                                                  fallback: false))
    }

    func testProductionSigningOverridesDebugPushDefault() throws {
        XCTAssertFalse(PushEnvironment.usesSandbox(provisioningProfile: try profile(environment: "production"),
                                                   fallback: true))
    }

    func testMissingOrUnreadableProfileKeepsPushDefault() throws {
        for profile in [nil, Data("invalid".utf8), Data("<?xml broken </plist>".utf8),
                        try self.profile(environment: "unknown")] {
            XCTAssertTrue(PushEnvironment.usesSandbox(provisioningProfile: profile, fallback: true))
            XCTAssertFalse(PushEnvironment.usesSandbox(provisioningProfile: profile, fallback: false))
        }
    }

    private let t0: Int64 = 1_700_000_000_000

    private func key(_ byte: UInt8 = 7) -> Data {
        Data(repeating: byte, count: RemoteAccess.keyLength)
    }

    private func alert(id: String = "agent.event.t-1",
                       kind: AgentAlert.Kind = .waiting,
                       target: String? = "t-1",
                       approval: String? = nil) -> AgentAlert {
        AgentAlert(id: id,
                   threadID: AlertPolicy.threadID(targetID: target),
                   title: "claude (work)",
                   subtitle: nil,
                   body: "Waiting for you",
                   kind: kind,
                   targetID: target,
                   approvalID: approval,
                   isSilent: false,
                   isTimeSensitive: true,
                   relevance: 0.9,
                   badge: 1)
    }

    private func event(_ kind: AgentEvent.Kind, _ target: String = "t-1", at millis: Int64? = nil) -> AgentEvent {
        AgentEvent(targetID: target, kind: kind, atEpochMillis: millis ?? t0)
    }

    private func approval(_ id: String = "a-1",
                          target: String? = "t-1",
                          timeout: TimeInterval = 120) -> ApprovalRequest {
        ApprovalRequest(id: id, targetID: target, targetName: "claude",
                        title: "Run a command", detail: "rm -rf build",
                        kind: .command, createdAtEpochMillis: t0, timeout: timeout)
    }

    private func registration(token: String? = "abc123",
                              sandbox: Bool = false,
                              settings: AlertSettings = AlertSettings()) -> PushRegistration {
        PushRegistration(token: token, usesSandbox: sandbox, settings: settings)
    }

    // MARK: - The envelope

    func testAnAlertSurvivesBeingSealedAndOpened() throws {
        let original = alert()
        let sealed = try PushEnvelope.seal(original, with: key())
        XCTAssertEqual(try PushEnvelope.open(sealed, tryingKeys: [key()]), original)
    }

    /// The whole privacy claim in one assertion: what travels must not contain
    /// the target's name, the agent's words, or the id of anything.
    func testNothingReadableTravels() throws {
        let sealed = try PushEnvelope.seal(alert(), with: key())
        let payload = PushEnvelope.payload(for: sealed,
                                           category: "mice.agent.event",
                                           isTimeSensitive: true,
                                           isSilent: false,
                                           threadID: "target.t-1",
                                           relevance: 0.9)
        let json = String(data: try JSONSerialization.data(withJSONObject: payload), encoding: .utf8) ?? ""
        for secret in ["claude", "work", "Waiting for you", "t-1"] {
            XCTAssertFalse(json.contains(secret), "\(secret) reached the relay in the clear")
        }
        XCTAssertTrue(json.contains(PushEnvelope.placeholderBody),
                      "something has to show if the extension never runs")
    }

    func testTheWrongKeyOpensNothing() throws {
        let sealed = try PushEnvelope.seal(alert(), with: key(7))
        XCTAssertThrowsError(try PushEnvelope.open(sealed, tryingKeys: [key(9)])) { error in
            XCTAssertEqual(error as? PushEnvelope.Failure, .noKeyFits)
        }
    }

    /// A phone paired with two Macs holds two keys and is told nothing about
    /// which sealed this — on purpose, because saying so would put a host name
    /// in the clear. So it tries them.
    func testTheRightKeyIsFoundAmongSeveral() throws {
        let sealed = try PushEnvelope.seal(alert(), with: key(3))
        let opened = try PushEnvelope.open(sealed, tryingKeys: [key(9), key(3), key(1)])
        XCTAssertEqual(opened.title, "claude (work)")
    }

    func testAKeyOfTheWrongLengthIsRefusedRatherThanUsed() {
        XCTAssertThrowsError(try PushEnvelope.seal(alert(), with: Data(repeating: 1, count: 16))) {
            XCTAssertEqual($0 as? PushEnvelope.Failure, .badKey)
        }
    }

    func testAShortKeyIsSkippedWhenOpening() throws {
        let sealed = try PushEnvelope.seal(alert(), with: key())
        // A truncated Keychain item must not crash `SymmetricKey`, just fail.
        XCTAssertThrowsError(try PushEnvelope.open(sealed, tryingKeys: [Data(repeating: 7, count: 8)]))
        XCTAssertEqual(try PushEnvelope.open(sealed, tryingKeys: [Data(repeating: 7, count: 8), key()]),
                       alert())
    }

    func testGarbageIsRejectedRatherThanDecoded() {
        XCTAssertThrowsError(try PushEnvelope.open(.init(box: "not base64 %%%"), tryingKeys: [key()])) {
            XCTAssertEqual($0 as? PushEnvelope.Failure, .unreadable)
        }
    }

    func testAFutureFormatIsRefusedPolitely() throws {
        let sealed = try PushEnvelope.seal(alert(), with: key())
        let ahead = PushEnvelope.Sealed(box: sealed.box, version: PushEnvelope.Sealed.currentVersion + 1)
        XCTAssertThrowsError(try PushEnvelope.open(ahead, tryingKeys: [key()])) {
            XCTAssertEqual($0 as? PushEnvelope.Failure, .unreadable)
        }
    }

    /// Two seals of the same alert must differ, or the relay learns that the
    /// same thing happened twice by comparing bytes.
    func testSealingTwiceProducesDifferentBytes() throws {
        let first = try PushEnvelope.seal(alert(), with: key())
        let second = try PushEnvelope.seal(alert(), with: key())
        XCTAssertNotEqual(first.box, second.box)
    }

    func testGroupingSurvivesWithoutNamingTheTarget() {
        let thread = PushEnvelope.opaqueThread("target.t-1")
        XCTAssertEqual(thread, PushEnvelope.opaqueThread("target.t-1"), "same target, same group")
        XCTAssertNotEqual(thread, PushEnvelope.opaqueThread("target.t-2"))
        XCTAssertFalse(thread.contains("t-1"))
    }

    func testTheQuietFlagReachesThePayload() throws {
        let sealed = try PushEnvelope.seal(alert(), with: key())
        func aps(silent: Bool, timeSensitive: Bool) -> [String: Any] {
            PushEnvelope.payload(for: sealed, category: "c", isTimeSensitive: timeSensitive,
                                 isSilent: silent, threadID: "t", relevance: 0.5)["aps"] as? [String: Any] ?? [:]
        }
        XCTAssertNil(aps(silent: true, timeSensitive: true)["sound"])
        XCTAssertNotNil(aps(silent: false, timeSensitive: true)["sound"])
        XCTAssertEqual(aps(silent: false, timeSensitive: true)["interruption-level"] as? String,
                       "time-sensitive")
        XCTAssertEqual(aps(silent: false, timeSensitive: false)["interruption-level"] as? String,
                       "passive")
        XCTAssertEqual(aps(silent: false, timeSensitive: true)["mutable-content"] as? Int, 1,
                       "without this the extension never runs and nothing is ever decrypted")
    }

    func testThePayloadFitsInsideWhatAPNsAccepts() throws {
        // 4 KiB is the limit, and an approval detail can be four thousand
        // characters on its own. `AlertPolicy` cuts the body to 200; this is
        // the assertion that the cut is enough once sealed and base64'd.
        let fat = AgentAlert(id: "agent.approval.a-1",
                             threadID: "target.t-1",
                             title: String(repeating: "n", count: 120),
                             subtitle: String(repeating: "s", count: 120),
                             body: String(repeating: "b", count: 200),
                             kind: .approval, targetID: "t-1", approvalID: "a-1",
                             isSilent: false, isTimeSensitive: true, relevance: 1, badge: 3)
        let sealed = try PushEnvelope.seal(fat, with: key())
        let payload = PushEnvelope.payload(for: sealed, category: "mice.agent.approval",
                                           isTimeSensitive: true, isSilent: false,
                                           threadID: "target.t-1", relevance: 1)
        let bytes = try JSONSerialization.data(withJSONObject: payload).count
        XCTAssertLessThan(bytes, 4096, "APNs would reject this outright")
    }

    // MARK: - Who gets woken

    func testAPhoneThatIsAlreadyConnectedIsNotPushedTo() {
        var router = PushRouter()
        router.register(registration(), forDevice: "d-1")
        XCTAssertTrue(router.route(event(.waiting), targetName: "claude",
                                   connected: ["d-1"], now: t0).isEmpty,
                      "it is getting the notification the better way")
    }

    func testAPhoneThatIsAwayIsPushedTo() {
        var router = PushRouter()
        router.register(registration(token: "tok"), forDevice: "d-1")
        let sent = router.route(event(.waiting), targetName: "claude", connected: [], now: t0)
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?.token, "tok")
        XCTAssertEqual(sent.first?.alert.kind, .waiting)
        XCTAssertEqual(sent.first?.alert.title, "claude")
    }

    func testOnePhoneAwayAndOneAtTheDeskGetOneEach() {
        var router = PushRouter()
        router.register(registration(token: "here"), forDevice: "d-here")
        router.register(registration(token: "away"), forDevice: "d-away")
        let sent = router.route(event(.failed), targetName: "codex",
                                connected: ["d-here"], now: t0)
        XCTAssertEqual(sent.map(\.deviceID), ["d-away"])
    }

    func testAPhoneThatNeverRegisteredIsNotPushedTo() {
        var router = PushRouter()
        XCTAssertTrue(router.route(event(.waiting), targetName: "claude", connected: [], now: t0).isEmpty)
    }

    func testRegisteringWithoutATokenStopsThePushes() {
        var router = PushRouter()
        router.register(registration(token: "tok"), forDevice: "d-1")
        XCTAssertTrue(router.isSubscribed("d-1"))
        router.register(registration(token: nil), forDevice: "d-1")
        XCTAssertFalse(router.isSubscribed("d-1"))
        XCTAssertTrue(router.route(event(.waiting), targetName: "claude", connected: [], now: t0).isEmpty)
    }

    func testForgettingADeviceStopsThePushes() {
        var router = PushRouter()
        router.register(registration(), forDevice: "d-1")
        router.forget(deviceID: "d-1")
        XCTAssertTrue(router.route(event(.waiting), targetName: "claude", connected: [], now: t0).isEmpty)
    }

    // MARK: - The phone's rules, applied on the Mac

    func testTheMacHonoursWhatThePhoneAskedToBeWokenFor() {
        var router = PushRouter()
        router.register(registration(settings: AlertSettings(waiting: false)), forDevice: "d-1")
        XCTAssertTrue(router.route(event(.waiting), targetName: "claude", connected: [], now: t0).isEmpty)
        XCTAssertEqual(router.route(event(.failed, at: t0 + 1_000), targetName: "claude",
                                    connected: [], now: t0 + 1_000).count, 1)
    }

    func testAMutedTargetIsNeverPushedAbout() {
        var router = PushRouter()
        router.register(registration(settings: AlertSettings(mutedTargetIDs: ["t-noisy"])),
                        forDevice: "d-1")
        XCTAssertTrue(router.route(event(.waiting, "t-noisy"), targetName: "noisy",
                                   connected: [], now: t0).isEmpty,
                      "a mute has to stop the push, not the banner it already caused")
    }

    func testAFinishedTurnIsNotWorthWakingSomebodyFor() {
        var router = PushRouter()
        router.register(registration(), forDevice: "d-1")
        XCTAssertTrue(router.route(event(.done), targetName: "claude", connected: [], now: t0).isEmpty)
    }

    func testTwoPhonesWithDifferentRulesGetDifferentAnswers() {
        var router = PushRouter()
        router.register(registration(token: "a", settings: AlertSettings(done: true)), forDevice: "d-a")
        router.register(registration(token: "b"), forDevice: "d-b")
        XCTAssertEqual(router.route(event(.done), targetName: "claude", connected: [], now: t0)
                        .map(\.deviceID), ["d-a"])
    }

    func testTheQuietWindowAppliesToPushesToo() {
        var router = PushRouter()
        router.register(registration(), forDevice: "d-1")
        XCTAssertEqual(router.route(event(.waiting), targetName: "claude", connected: [], now: t0)
                        .first?.alert.isSilent, false)
        let soon = t0 + 5_000
        XCTAssertEqual(router.route(event(.failed, at: soon), targetName: "claude",
                                    connected: [], now: soon).first?.alert.isSilent, true)
    }

    // MARK: - Replacing rather than stacking

    func testATargetsSecondPushReplacesItsFirst() {
        var router = PushRouter()
        router.register(registration(), forDevice: "d-1")
        let first = router.route(event(.waiting), targetName: "claude", connected: [], now: t0)
        let later = t0 + 60_000
        let second = router.route(event(.failed, at: later), targetName: "claude",
                                  connected: [], now: later)
        XCTAssertEqual(first.first?.collapseID, second.first?.collapseID)
        XCTAssertEqual(second.first?.alert.badge, 1, "one target, one banner")
    }

    // MARK: - Deadlines

    /// The nicest thing APNs does for free: a question the clock has already
    /// answered is never delivered at all.
    func testAnApprovalPushDiesWithTheRequest() {
        var router = PushRouter()
        router.register(registration(), forDevice: "d-1")
        let request = approval(timeout: 90)
        let sent = router.route(request, connected: [], now: t0)
        XCTAssertEqual(sent.first?.expiresAtEpochMillis, request.expiresAtEpochMillis)
        XCTAssertEqual(sent.first?.expiresAtEpochMillis, t0 + 90_000)
    }

    func testAStatusPushStopsBeingWorthDelivering() {
        var router = PushRouter()
        router.register(registration(), forDevice: "d-1")
        let sent = router.route(event(.waiting), targetName: "claude", connected: [], now: t0)
        XCTAssertEqual(sent.first?.expiresAtEpochMillis,
                       t0 + Int64(PushRouter.reportLifetime * 1000))
    }

    // MARK: - Keeping the count honest

    func testConnectingClearsWhatTheMacThinksIsOnTheLockScreen() {
        var router = PushRouter()
        router.register(registration(), forDevice: "d-1")
        _ = router.route(event(.waiting), targetName: "claude", connected: [], now: t0)
        XCTAssertEqual(router.outstanding(forDevice: "d-1"), 1)
        router.deviceArrived("d-1")
        XCTAssertEqual(router.outstanding(forDevice: "d-1"), 0)
    }

    func testReRegisteringClearsItToo() {
        var router = PushRouter()
        router.register(registration(), forDevice: "d-1")
        _ = router.route(event(.waiting), targetName: "claude", connected: [], now: t0)
        router.register(registration(), forDevice: "d-1")
        XCTAssertEqual(router.outstanding(forDevice: "d-1"), 0)
    }

    func testAnAnsweredApprovalStopsBeingCounted() {
        var router = PushRouter()
        router.register(registration(), forDevice: "d-1")
        _ = router.route(approval("a-1"), connected: [], now: t0)
        XCTAssertEqual(router.outstanding(forDevice: "d-1"), 1)
        router.resolved(approvalID: "a-1")
        XCTAssertEqual(router.outstanding(forDevice: "d-1"), 0)
    }

    /// The badge on a push is the Mac's belief about that phone's lock screen.
    /// If it drifts, the user gets a red dot they cannot clear.
    func testTheBadgeCountsUpAcrossSeveralPushes() {
        var router = PushRouter()
        router.register(registration(), forDevice: "d-1")
        var now = t0
        var badges: [Int] = []
        for index in 0..<3 {
            now += 60_000
            let sent = router.route(event(.waiting, "t-\(index)", at: now),
                                    targetName: "t\(index)", connected: [], now: now)
            badges.append(sent.first?.alert.badge ?? -1)
        }
        XCTAssertEqual(badges, [1, 2, 3])
        XCTAssertEqual(router.outstanding(forDevice: "d-1"), 3)
    }

    // MARK: - Registration on the wire

    func testARegistrationSurvivesAFieldThatDidNotExistYet() throws {
        let decoded = try JSONDecoder().decode(PushRegistration.self,
                                               from: Data(#"{"token":"abc"}"#.utf8))
        XCTAssertEqual(decoded.token, "abc")
        XCTAssertFalse(decoded.usesSandbox, "a release build's token must not be sent to the sandbox")
        XCTAssertEqual(decoded.settings, AlertSettings())
    }

    func testARegistrationRoundTrips() throws {
        let original = registration(token: "deadbeef", sandbox: true,
                                    settings: AlertSettings(done: true, mutedTargetIDs: ["t-1"]))
        let decoded = try JSONDecoder().decode(PushRegistration.self,
                                               from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original)
    }

    func testTheSandboxFlagReachesTheDelivery() {
        var router = PushRouter()
        router.register(registration(token: "tok", sandbox: true), forDevice: "d-1")
        XCTAssertEqual(router.route(event(.waiting), targetName: "claude", connected: [], now: t0)
                        .first?.usesSandbox, true)
    }
}
