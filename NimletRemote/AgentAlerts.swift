import Foundation
import UIKit
@preconcurrency import UserNotifications

/// Telling you an agent needs you, when you are not looking at the phone.
///
/// The dock grew an activity dot and no way to deliver it. That is the wrong
/// shape for this product: the whole premise is that the agent keeps working
/// while you do something else, and "something else" means the phone is face
/// down beside the keyboard or in a pocket. A six-point dot on a dark tile is
/// an ambient signal on a screen nobody is looking at.
///
/// The macOS Dock gets away with a badge because the Mac's screen is in front
/// of you. It also bounces, which is the part worth copying — an app that needs
/// a decision is allowed to interrupt. On iOS that is a notification.
///
/// ## What this is, exactly
///
/// Local notifications, posted by the app when an event arrives. That is worth
/// stating plainly because it is *not* the same as a push: iOS suspends a
/// backgrounded app, and a suspended app is not reading its socket, so nothing
/// arrives to notify about. This fires while Nimlet is running — foregrounded,
/// or in the grace period after you leave it, or while it is kept alive beside
/// another app because you left listening on. Reaching a phone that has been
/// asleep in a pocket for an hour needs APNs and a server to push from, which
/// is a different piece of work and an account-level decision, not a view
/// change.
///
/// So: better than a dot, honestly short of the Dock's bounce.
///
/// ## Getting through a Focus
///
/// `waiting`, `failed` and every approval ask for the time-sensitive
/// interruption level, which is what lets a notification through a Focus and
/// onto a locked screen — the exact situation this whole file exists for. iOS
/// grants that only to an app carrying the Time Sensitive Notifications
/// capability; without it the request is quietly demoted to an ordinary alert,
/// which is the difference between this feature working and this feature
/// appearing to work. It is declared in `Signing/NimletRemote.entitlements` and
/// needs the matching capability on the App ID.
///
/// ## What is here and what is next door
///
/// This file is the plumbing and nothing else — permission, categories, the
/// delegate, translating a decision into a `UNNotificationRequest`. Every
/// judgement about *whether* to interrupt lives in `AlertPolicy`, in `Shared`,
/// where it is pure and has three hundred lines of tests on it. That split is
/// deliberate: a notification bug is invisible by construction — a banner that
/// should have appeared and did not looks exactly like an agent with nothing
/// to say — so the rules had to go somewhere they could be run a thousand
/// times without a phone.
@MainActor
final class AgentAlerts: NSObject, ObservableObject {

    static let shared = AgentAlerts()

    /// What iOS will let us do, as far as we last looked.
    enum Authorisation: Equatable {
        /// Before `prime()` has answered.
        case unknown
        /// Never asked. The interesting one: an ask not yet spent.
        case notAsked
        case allowed
        case denied
    }

    @Published private(set) var settings: AlertSettings
    @Published private(set) var authorisation: Authorisation = .unknown
    /// The APNs token, once iOS has issued one. Hex, as `PushRegistration`
    /// wants it.
    ///
    /// Nil until the user has allowed notifications and the device has
    /// registered, which is a round trip to Apple and takes a moment. Also nil
    /// with no network, and re-issued — sometimes changed — on every launch,
    /// which is why the app asks for it every time rather than remembering one.
    @Published private(set) var pushToken: String?
    /// Why there is no token, when there should be one. For the settings
    /// screen, which is otherwise a switch that is on beside a feature that
    /// does nothing.
    @Published private(set) var pushFailure: String?

    /// What a tap on a notification wants the app to do. Handed over rather
    /// than acted on here, because this object knows nothing about connections
    /// or screens.
    enum Intent: Equatable {
        /// Open the app on this target.
        case openTarget(String)
        /// Open the approvals sheet, on this request when it is still there.
        case openApprovals(requestID: String?)
        /// Answer without opening anything.
        case decide(requestID: String, decision: ApprovalDecision)
    }

    /// Called when the Mac needs to be told something new — a token arrived,
    /// or the user changed what they want to be woken for. Set by whoever owns
    /// the client, for the same reason `onIntent` is.
    var onRegistrationChanged: (() -> Void)?

    /// Set once, by whoever owns the client. Anything that arrives before then
    /// is queued rather than dropped: a notification tap can and does land
    /// before the first view has appeared, because tapping one is how the app
    /// was launched.
    var onIntent: ((Intent) -> Void)? {
        didSet {
            guard onIntent != nil, !queued.isEmpty else { return }
            let pending = queued
            queued = []
            for intent in pending { onIntent?(intent) }
        }
    }

    private var policy: AlertPolicy
    private var queued: [Intent] = []
    /// Something happened that would have been worth a notification, and we
    /// have never asked for permission to post one. Spent at the next moment
    /// the user is actually looking at the app — see `becameActive`.
    private var owesAsk = false
    private let centre = UNUserNotificationCenter.current()
    private let defaults: UserDefaults

    private static let settingsKey = "mice.alerts.settings"
    private static let eventCategory = AgentAlert.Kind.waiting.category
    private static let approvalCategory = AgentAlert.Kind.approval.category
    private static let questionCategory = AgentAlert.Kind.question.category
    private static let approveAction = "mice.approve"
    private static let denyAction = "mice.deny"
    private static let muteAction = "mice.mute"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.data(forKey: Self.settingsKey)
            .flatMap { try? NimletCoder.decode(AlertSettings.self, from: $0) }
        settings = stored ?? AlertSettings()
        policy = AlertPolicy(settings: stored ?? AlertSettings())
        super.init()
    }

    // MARK: - Setting up

    /// Called once at launch, before anything can arrive.
    ///
    /// Reads the permission state rather than asking for it. The two are very
    /// different: reading is silent, and asking on first launch — before the
    /// user has any idea what this app would tell them — is the ask most
    /// reliably denied, and a denial is permanent in a way a deferred ask is
    /// not.
    func prime() {
        centre.delegate = self
        centre.setNotificationCategories([eventCategory(), approvalCategory(), questionCategory()])
        Task {
            await refreshAuthorisation()
            // Every launch, not just the first. Apple issues the token afresh
            // each time and occasionally issues a different one; a phone that
            // registered once and stopped asking is a phone the Mac eventually
            // cannot reach, with nothing anywhere saying so.
            if authorisation == .allowed { UIApplication.shared.registerForRemoteNotifications() }
        }
    }

    // MARK: - Being reachable while asleep

    /// iOS issued a token. Hex, because that is what APNs wants and what every
    /// relay in the world expects to be handed.
    func absorb(deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        guard hex != pushToken else { return }
        pushToken = hex
        pushFailure = nil
        onRegistrationChanged?()
    }

    /// No token, and a reason. Usually no network at launch, occasionally a
    /// build whose provisioning has no push capability at all — which is worth
    /// telling somebody, because it looks exactly like the feature being off.
    func pushRegistrationFailed(_ error: Error) {
        pushToken = nil
        pushFailure = "Apple hasn't issued this phone a push token yet"
            + " — usually no internet at launch. It is asked again on the next launch."
        remoteLog.error("push registration failed: \(error.localizedDescription, privacy: .public)")
        onRegistrationChanged?()
    }

    /// What the Mac needs in order to reach this phone when it is asleep: where
    /// to send, and what this phone considers worth being woken for.
    ///
    /// The settings travel because the Mac is the end that is awake, so it is
    /// the end that has to apply them. A phone that kept its rules to itself
    /// would be woken for everything and then quietly discard most of it,
    /// having already lit the screen.
    private static let usesPushSandbox: Bool = {
        #if DEBUG
        let fallback = true
        #else
        let fallback = false
        #endif
        // Xcode can sign a Release device build for development. Reading its
        // embedded profile avoids sending that token to production APNs.
        let profile = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision")
            .flatMap { try? Data(contentsOf: $0) }
        return PushEnvironment.usesSandbox(provisioningProfile: profile, fallback: fallback)
    }()

    var registration: PushRegistration {
        // Notifications off, or iOS says no: the Mac is told to stop rather
        // than left pushing into a phone that will not show any of it.
        let token = (settings.isEnabled && authorisation == .allowed) ? pushToken : nil
        return PushRegistration(token: token, usesSandbox: Self.usesPushSandbox, settings: settings)
    }

    private func refreshAuthorisation() async {
        let status = await centre.notificationSettings().authorizationStatus
        switch status {
        case .notDetermined: authorisation = .notAsked
        case .denied: authorisation = .denied
        default: authorisation = .allowed
        }
    }

    /// The Approve and Deny buttons on an approval banner, and the asymmetry
    /// between them, which is the considered part.
    ///
    /// **Deny is answered from the banner.** It runs without opening the app,
    /// and it is allowed to fail: a denial that never reaches the Mac ends in
    /// the request expiring, and a request that expires is denied — or goes
    /// back to the agent's own prompt, which approves nothing either. The
    /// failure mode of this button is never a yes. That is the only reason it
    /// is safe to offer at arm's length from a locked screen.
    ///
    /// **Approve opens the app**, and asks for a face or a passcode first.
    /// A failed approval is invisible — the agent just sits there — so it must
    /// not be fire-and-forget; and approving `rm -rf` from a lock screen
    /// somebody else is holding is not a thing this app should make easy. The
    /// detail on the card is what the decision is about, and you should be
    /// looking at it.
    private func approvalCategory() -> UNNotificationCategory {
        let approve = UNNotificationAction(identifier: Self.approveAction,
                                           title: "Approve",
                                           options: [.foreground, .authenticationRequired])
        let deny = UNNotificationAction(identifier: Self.denyAction,
                                        title: "Deny",
                                        options: [.destructive])
        return UNNotificationCategory(identifier: Self.approvalCategory,
                                      actions: [approve, deny],
                                      intentIdentifiers: [],
                                      hiddenPreviewsBodyPlaceholder: "is asking permission",
                                      categorySummaryFormat: "%u requests waiting",
                                      options: [])
    }

    /// A question has no buttons on the lock screen. Its choices are the
    /// agent's, there can be several of them and several questions, and the
    /// right answer is often one you type — so a tap opens the card, where all
    /// of that is.
    private func questionCategory() -> UNNotificationCategory {
        UNNotificationCategory(identifier: Self.questionCategory,
                               actions: [],
                               intentIdentifiers: [],
                               hiddenPreviewsBodyPlaceholder: "has a question",
                               categorySummaryFormat: "%u questions waiting",
                               options: [])
    }

    /// The one place a mute is genuinely wanted is the moment you find out you
    /// need one, which is standing over a banner from the pane that will not
    /// stop reporting. Making the user remember the target's name, open the
    /// app, find Settings and scroll to it is how a switch nobody uses gets
    /// built.
    ///
    /// Not offered on an approval, and that is not an oversight: muting an
    /// agent that is asking permission does not quieten it, it denies it —
    /// unanswered requests expire into a no — and a button that looks like
    /// "stop telling me" but means "say no to everything from now on" is a
    /// trap.
    private func eventCategory() -> UNNotificationCategory {
        let mute = UNNotificationAction(identifier: Self.muteAction,
                                        title: "Mute this target",
                                        options: [])
        return UNNotificationCategory(identifier: Self.eventCategory,
                                      actions: [mute],
                                      intentIdentifiers: [],
                                      hiddenPreviewsBodyPlaceholder: "has something to report",
                                      categorySummaryFormat: "%u more updates",
                                      options: [])
    }

    // MARK: - Things that happen

    /// An agent reported something.
    func report(_ event: AgentEvent, targetName: String) {
        // Asking is worth an ask only once something has happened that would
        // have used it. Noted here even when the app is in front, because that
        // is the *best* time to ask: the sheet appears while somebody is
        // looking at the screen it belongs to, and the permission is then in
        // place before they walk away.
        if authorisation == .notAsked, settings.allows(event.kind), !settings.isMuted(event.targetID) {
            owesAsk = true
            askIfOwedAndVisible()
        }
        apply(policy.receive(event,
                             targetName: targetName,
                             isActive: isActive,
                             now: ApprovalClock.now()))
    }

    /// An agent is blocked on a decision.
    func report(_ request: ApprovalRequest) {
        if authorisation == .notAsked, settings.approvals, !settings.isMuted(request.targetID) {
            owesAsk = true
            askIfOwedAndVisible()
        }
        apply(policy.receive(request, isActive: isActive, now: ApprovalClock.now()))
    }

    /// The Mac's whole answer about what is still pending — or this phone's,
    /// after it answered one itself. Anything we are showing that is not in it
    /// is already decided.
    func approvalsChanged(to pending: [ApprovalRequest]) {
        apply(policy.expireApprovals(pending: pending, now: ApprovalClock.now()))
    }

    func resolved(approvalID: String) {
        apply(policy.resolved(approvalID: approvalID))
    }

    /// The user is looking at Nimlet. Everything on the lock screen has been
    /// superseded by the thing itself.
    func becameActive() {
        apply(policy.opened())
        askIfOwedAndVisible()
        Task { await refreshAuthorisation() }
    }

    /// The connection to a Mac is gone for good — disconnected by hand, or the
    /// device was revoked. The banners name targets this phone can no longer
    /// reach, and their buttons have nowhere to send an answer.
    func forgetEverything() {
        apply(policy.reset())
    }

    // MARK: - Permission

    /// Asks, from the Settings screen, where the user went looking for this.
    /// Returns once the answer is known so the switch can settle on the truth
    /// rather than on what was tapped.
    @discardableResult
    func requestAuthorisation() async -> Bool {
        owesAsk = false
        let granted = (try? await centre.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        await refreshAuthorisation()
        if granted {
            // Only now. Asking for a token before permission is granted gets
            // one, and it is useless: APNs accepts the push and iOS drops it.
            UIApplication.shared.registerForRemoteNotifications()
        }
        onRegistrationChanged?()
        return granted
    }

    /// Spends an owed ask, but only with somebody in front of the screen.
    ///
    /// iOS cannot present a permission sheet over another app, so asking from
    /// the background does not ask: it leaves a continuation hanging until the
    /// app is next opened, and the notification that prompted it is long gone
    /// by then. This was the sharp edge in the first version of this file —
    /// the first alert the app ever had to deliver was the one guaranteed to
    /// be swallowed.
    private func askIfOwedAndVisible() {
        guard owesAsk, authorisation == .notAsked, isActive else { return }
        owesAsk = false
        Task { await requestAuthorisation() }
    }

    // MARK: - Settings

    func update(_ settings: AlertSettings) {
        self.settings = settings
        if let data = try? NimletCoder.encode(settings) {
            defaults.set(data, forKey: Self.settingsKey)
        }
        // The Mac applies these too, for the pushes this phone is asleep for.
        // Sent on every change rather than on connect only: muting a target and
        // then locking the phone should not still cost a buzz.
        onRegistrationChanged?()
        // Acts on what is already up, rather than only on what comes next.
        // Muting a target and watching its banner sit there is the complaint
        // this answers.
        apply(policy.apply(settings))
    }

    func setMuted(_ muted: Bool, targetID: String) {
        var next = settings
        if muted { next.mutedTargetIDs.insert(targetID) } else { next.mutedTargetIDs.remove(targetID) }
        update(next)
    }

    func isMuted(_ targetID: String) -> Bool { settings.mutedTargetIDs.contains(targetID) }

    // MARK: - Posting

    private var isActive: Bool { UIApplication.shared.applicationState == .active }

    private func apply(_ outcome: AlertOutcome) {
        // One line per report: posted, or why not. Without it a banner that
        // never appeared could not be told apart from an event that never
        // arrived (QA 2026-10-03, N03/N04).
        if let suppression = outcome.suppression {
            remoteLog.info("alert: not posted, \(suppression.rawValue, privacy: .public)")
        }
        if !outcome.withdraw.isEmpty {
            // Both lists: one that has been shown, one that has not. A request
            // can sit in the pending list for a moment after `add`, and
            // removing from only one of them leaves the banner that was about
            // to appear to appear anyway.
            centre.removeDeliveredNotifications(withIdentifiers: outcome.withdraw)
            centre.removePendingNotificationRequests(withIdentifiers: outcome.withdraw)
        }
        if let alert = outcome.post {
            guard authorisation == .allowed else {
                // Nothing reached the screen, so the policy must not go on
                // believing something did — otherwise the badge counts a
                // notification nobody can clear.
                remoteLog.info("alert: not posted, notifications not allowed")
                policy.undo(id: alert.id)
                setBadge(policy.badge)
                return
            }
            deliver(alert)
        }
        setBadge(outcome.badge)
    }

    private func deliver(_ alert: AgentAlert) {
        let content = UNMutableNotificationContent()
        content.title = alert.title
        if let subtitle = alert.subtitle { content.subtitle = subtitle }
        content.body = alert.body
        content.sound = alert.isSilent ? nil : .default
        // One target, one stack. Two agents having a bad afternoon should read
        // as two conversations rather than as one pile.
        content.threadIdentifier = alert.threadID
        content.categoryIdentifier = alert.kind.category
        content.relevanceScore = alert.relevance
        // Asks to break through Focus and a locked screen. iOS honours this
        // only for an app granted the Time Sensitive capability and treats it
        // as an ordinary alert otherwise, so asking costs nothing.
        content.interruptionLevel = alert.isTimeSensitive ? .timeSensitive : .passive
        content.badge = NSNumber(value: alert.badge)
        content.userInfo = Self.payload(for: alert)

        // No trigger: now, not on a schedule. Re-using the id replaces the
        // notification in place rather than stacking a second one behind it,
        // which is the whole reason ids are derived from the subject.
        let kind = alert.kind.rawValue
        let level = alert.isTimeSensitive ? "time-sensitive" : "passive"
        centre.add(UNNotificationRequest(identifier: alert.id, content: content, trigger: nil)) { error in
            if let error {
                remoteLog.error("alert: \(kind, privacy: .public) not posted: \(error.localizedDescription, privacy: .public)")
            } else {
                remoteLog.info("alert: \(kind, privacy: .public) posted, \(level, privacy: .public)")
            }
        }
    }

    private static func payload(for alert: AgentAlert) -> [String: Any] {
        var info: [String: Any] = ["kind": alert.kind.rawValue]
        if let targetID = alert.targetID { info["targetID"] = targetID }
        if let approvalID = alert.approvalID { info["approvalID"] = approvalID }
        return info
    }

    private func setBadge(_ count: Int) {
        guard authorisation == .allowed else { return }
        centre.setBadgeCount(count)
    }

    // MARK: - Taps

    fileprivate func handle(_ response: UNNotificationResponse) {
        let info = response.notification.request.content.userInfo
        let targetID = info["targetID"] as? String
        let approvalID = info["approvalID"] as? String
        // Whatever was done to it, it is off the screen now.
        policy.undo(id: response.notification.request.identifier)
        setBadge(policy.badge)

        switch response.actionIdentifier {
        case Self.denyAction:
            guard let approvalID else { break }
            deliver(.decide(requestID: approvalID, decision: .deny))
        case Self.approveAction:
            // `.foreground`, so the app is coming up anyway. Land on the card
            // rather than on whatever screen it was left on: the detail is
            // what the decision is about.
            deliver(.openApprovals(requestID: approvalID))
        case Self.muteAction:
            guard let targetID else { break }
            // Takes down this target's other banners on its way, because
            // `update` acts on what is already up.
            setMuted(true, targetID: targetID)
        case UNNotificationDismissActionIdentifier:
            break
        default:
            if let approvalID {
                deliver(.openApprovals(requestID: approvalID))
            } else if let targetID {
                deliver(.openTarget(targetID))
            }
        }
    }

    private func deliver(_ intent: Intent) {
        guard let onIntent else { queued.append(intent); return }
        onIntent(intent)
    }
}

// MARK: - The delegate

/// The completion-handler forms, each handler called on the main thread.
///
/// Not the `async` forms. A `nonisolated async` delegate method runs on the
/// global executor, and the bridge Swift generates calls UIKit's completion
/// handler from wherever the body finished. For a tap, that handler updates
/// the app's snapshot, which asserts it is on the main thread: tapping a
/// notification while the app was in the background aborted it with "Call
/// must be made on main thread" (build 25, QA 2026-10-03).
extension AgentAlerts: UNUserNotificationCenterDelegate {

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // The app is in front. `AlertPolicy` already declines to post in that
        // case, so arriving here means the app came forward between the
        // decision and the delivery — a race of milliseconds.
        //
        // Nothing, not even quietly into Notification Centre. The dot is on
        // the tile with its age beside it and the card is in the sheet, so no
        // information is lost by dropping this; what would be lost by keeping
        // it is the badge, which counts what `AlertPolicy` believes is on
        // screen and has already forgotten this one.
        DispatchQueue.main.async { completionHandler([]) }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.handle(response) }
            completionHandler()
        }
    }
}
