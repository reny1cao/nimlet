import Foundation

/// APNs follows the signing profile, even when a Release build is installed
/// directly from Xcode. App Store installations may omit the profile, so the
/// build's default is used only when no recognised environment can be read.
public enum PushEnvironment {
    public static func usesSandbox(provisioningProfile: Data?, fallback: Bool) -> Bool {
        guard let data = provisioningProfile,
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
              let root = (try? PropertyListSerialization.propertyList(
                from: data[start.lowerBound..<end.upperBound], format: nil)) as? [String: Any],
              let entitlements = root["Entitlements"] as? [String: Any],
              let environment = entitlements["aps-environment"] as? String else { return fallback }
        switch environment {
        case "development": return true
        case "production": return false
        default: return fallback
        }
    }
}

/// What a phone told the Mac about being pushed to.
///
/// Sent on connecting and whenever the user changes a notification setting,
/// because the Mac cannot decide what is worth waking somebody for without
/// knowing what they asked to be woken for. The settings travel rather than
/// being guessed at: the same `AlertPolicy` then runs on the Mac, against the
/// same rules, and a target muted on the phone is a target the Mac never pushes
/// about — rather than one whose push arrives and is politely ignored, having
/// already lit the screen.
public struct PushRegistration: Codable, Sendable, Equatable {

    /// The APNs device token, hex, as iOS hands it over. Nil means *stop*:
    /// notifications were switched off, or permission was withdrawn, and the
    /// Mac should forget the token rather than keep pushing into the dark.
    public var token: String?
    /// Which APNs environment this build's token belongs to. A token minted
    /// against the sandbox is rejected by the production endpoint and the other
    /// way round, and the failure is a 400 with `BadDeviceToken` — indis-
    /// tinguishable, from the Mac, from a phone that has been wiped. The build
    /// knows which it is; nothing else does.
    public var usesSandbox: Bool
    /// What this phone wants to be interrupted for.
    public var settings: AlertSettings

    public init(token: String?, usesSandbox: Bool, settings: AlertSettings) {
        self.token = token
        self.usesSandbox = usesSandbox
        self.settings = settings
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        token = try c.decodeIfPresent(String.self, forKey: .token)
        // Production if unsaid. A debug build always says so explicitly, and
        // guessing sandbox for a release build would break every real phone.
        usesSandbox = try c.decodeIfPresent(Bool.self, forKey: .usesSandbox) ?? false
        settings = try c.decodeIfPresent(AlertSettings.self, forKey: .settings) ?? AlertSettings()
    }
}

/// One push to make. The alert is not yet sealed: sealing needs that device's
/// key, which lives in the Keychain, and this type is decided in `Shared` where
/// there is no Keychain to reach for.
public struct PushDelivery: Sendable, Equatable {
    public var deviceID: String
    public var token: String
    public var usesSandbox: Bool
    public var alert: AgentAlert
    /// APNs replaces a notification already on the phone that carries the same
    /// id. The alert's own id is derived from its subject, so a target that
    /// reports twice replaces its own banner instead of stacking a second one —
    /// the same rule the on-phone path follows, enforced by Apple instead.
    public var collapseID: String
    /// After this, APNs throws the push away rather than delivering it.
    public var expiresAtEpochMillis: Int64

    public init(deviceID: String,
                token: String,
                usesSandbox: Bool,
                alert: AgentAlert,
                collapseID: String,
                expiresAtEpochMillis: Int64) {
        self.deviceID = deviceID
        self.token = token
        self.usesSandbox = usesSandbox
        self.alert = alert
        self.collapseID = collapseID
        self.expiresAtEpochMillis = expiresAtEpochMillis
    }
}

/// Who gets woken up, and — much more of the work — who does not.
///
/// Pure and synchronous, like `AlertPolicy` and `ApprovalLedger`, and for the
/// same reason: the expensive failures here are the ones you cannot see. A
/// push that should not have been sent is a phone buzzing in a cinema about an
/// agent whose notification the user is already looking at on the Mac; a push
/// that should have been sent and was not is the entire feature quietly not
/// working. Neither shows up in a screenshot, so both are tested instead.
public struct PushRouter: Sendable {

    /// How long a status report is worth delivering for.
    ///
    /// A phone that has been off for two hours does not want a banner about an
    /// agent that stopped ninety minutes ago; it wants the dock, which will
    /// tell it the same thing with an age attached the moment the app opens.
    /// An hour is the line: long enough to cover lunch, short enough that
    /// nothing arrives claiming to be news when it is history.
    public static let reportLifetime: TimeInterval = 3600

    private struct Subscriber {
        var token: String
        var usesSandbox: Bool
        var policy: AlertPolicy
    }

    private var subscribers: [String: Subscriber] = [:]

    public init() {}

    public var subscribedDeviceIDs: Set<String> { Set(subscribers.keys) }

    public func isSubscribed(_ deviceID: String) -> Bool { subscribers[deviceID] != nil }

    /// A phone registered, re-registered, or changed a setting.
    ///
    /// Registering resets that device's policy, and that is deliberate rather
    /// than incidental: a phone sends this when it connects, and a phone that
    /// has just connected has just cleared its own lock screen. Keeping the
    /// Mac's idea of what is showing there would mean pushing a badge count
    /// that includes notifications the user has already dealt with.
    public mutating func register(_ registration: PushRegistration, forDevice deviceID: String) {
        guard let token = registration.token, !token.isEmpty else {
            subscribers.removeValue(forKey: deviceID)
            return
        }
        subscribers[deviceID] = Subscriber(token: token,
                                           usesSandbox: registration.usesSandbox,
                                           policy: AlertPolicy(settings: registration.settings))
    }

    /// Revoked, unpaired, or simply gone. The key goes with it elsewhere; this
    /// is the half that stops the pushes.
    public mutating func forget(deviceID: String) {
        subscribers.removeValue(forKey: deviceID)
    }

    // MARK: - Routing

    /// An agent reported something. Who, if anyone, should be woken.
    public mutating func route(_ event: AgentEvent,
                               targetName: String,
                               connected: Set<String>,
                               now: Int64) -> [PushDelivery] {
        deliveries(connected: connected) { policy, _ in
            policy.receive(event, targetName: targetName, isActive: false, now: now)
        } expiring: { _ in
            now + Int64(Self.reportLifetime * 1000)
        }
    }

    /// An agent is blocked on a decision.
    public mutating func route(_ request: ApprovalRequest,
                               connected: Set<String>,
                               now: Int64) -> [PushDelivery] {
        deliveries(connected: connected) { policy, _ in
            policy.receive(request, isActive: false, now: now)
        } expiring: { _ in
            // Exactly the request's own deadline, which buys something nothing
            // else here can: a question that the clock has already answered is
            // never delivered at all. APNs drops it, so a phone coming out of a
            // pocket does not light up with Approve and Deny for a run that
            // gave up on it twenty minutes ago.
            request.expiresAtEpochMillis
        }
    }

    /// Runs one decision against every subscriber that is not already being
    /// spoken to directly.
    ///
    /// The `connected` check is the first and most important rule. A phone with
    /// a live socket gets the notification the ordinary way — decided on the
    /// phone, sent over a connection that exists, with nothing passing through
    /// anybody's relay. Pushing to it as well would be a second buzz about the
    /// same thing, routed the worse of the two ways.
    private mutating func deliveries(connected: Set<String>,
                                     decide: (inout AlertPolicy, String) -> AlertOutcome,
                                     expiring: (String) -> Int64) -> [PushDelivery] {
        var made: [PushDelivery] = []
        for deviceID in subscribers.keys.sorted() where !connected.contains(deviceID) {
            guard var subscriber = subscribers[deviceID] else { continue }
            let outcome = decide(&subscriber.policy, deviceID)
            subscribers[deviceID] = subscriber
            guard let alert = outcome.post else { continue }
            made.append(PushDelivery(deviceID: deviceID,
                                     token: subscriber.token,
                                     usesSandbox: subscriber.usesSandbox,
                                     alert: alert,
                                     // Hashed for the same reason `thread-id` is: the
                                     // alert id names the target or the request, and the
                                     // relay and Apple both read this header. The phone
                                     // never sees it, so nothing has to match at that end.
                                     collapseID: PushEnvelope.opaqueThread(alert.id),
                                     expiresAtEpochMillis: expiring(deviceID)))
        }
        return made
    }

    // MARK: - Keeping the far end honest

    /// A phone connected. Whatever the Mac believed was on its lock screen, the
    /// phone has just cleared — `AgentAlerts.becameActive` does it on the way
    /// in — so the Mac's copy of that belief has to go too, or the next push
    /// carries a badge counting notifications nobody can see.
    public mutating func deviceArrived(_ deviceID: String) {
        guard var subscriber = subscribers[deviceID] else { return }
        _ = subscriber.policy.opened()
        subscribers[deviceID] = subscriber
    }

    /// An approval was answered, expired or withdrawn.
    ///
    /// Worth doing even though it cannot reach a notification already on a
    /// sleeping phone — APNs has no way to retract one, and that limit is real
    /// and stated in the README. What it does fix is the count: without this
    /// the Mac would go on believing that question is still up, and every later
    /// push would carry a badge one too high, for ever.
    public mutating func resolved(approvalID: String) {
        for (deviceID, var subscriber) in subscribers {
            _ = subscriber.policy.resolved(approvalID: approvalID)
            subscribers[deviceID] = subscriber
        }
    }

    /// What the Mac still believes is on one phone's lock screen. For tests and
    /// for the menu bar, which is the only place a user can see that this is
    /// working at all.
    public func outstanding(forDevice deviceID: String) -> Int {
        subscribers[deviceID]?.policy.badge ?? 0
    }
}
