import Foundation

/// The Mac's half of reaching a phone that is asleep.
///
/// Everything the phone can do for itself, it already does: `AgentAlerts` posts
/// a local notification the moment an event arrives over the socket. That stops
/// working about twenty-five seconds after the app leaves the screen, because
/// iOS freezes the process and a frozen process is not reading anything. From
/// then on the only end awake is this one.
///
/// So this is the same notification, decided here instead. The phone sent its
/// rules — `PushRegistration` carries the very `AlertSettings` the user set —
/// and `PushRouter` runs `AlertPolicy` against them, per device, which is why
/// that type lives in `Shared` with no UIKit in it. What comes out is an
/// `AgentAlert` identical to the one the phone would have made for itself.
///
/// Then it is sealed with that device's away key and handed to the relay. See
/// `PushEnvelope` for why it is sealed and what that buys; see Relay/worker.js
/// for what the relay is allowed to be.
///
/// ## Inert until it is pointed somewhere
///
/// There is no relay address compiled in. Without one this whole file does
/// nothing at all, which is the right default for a program whose entire
/// premise is that it talks to your Mac and nowhere else: turning on the one
/// path that leaves the building should be a thing somebody did on purpose.
///
///     defaults write com.renyicao.mice.host mice.push.relay https://…workers.dev
///
/// The secret, if the relay has one, is typed into Settings → Notifications
/// and kept in the Keychain; a `mice.push.secret` preference written by an
/// older build is moved there the first time it is read.
final class PushSender {

    static let shared = PushSender()

    /// Serial, and everything here hops onto it. `HostServer` calls in from its
    /// network queue, the menu bar reads the summary from main, and the router
    /// is a value with mutating methods — one queue is cheaper to be sure about
    /// than a lock per field.
    private let queue = DispatchQueue(label: "com.renyicao.mice.push")
    private var router = PushRouter()
    private let session: URLSession
    private var lastFailure: String?

    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        // A push is worth about as long as it takes to notice it failed. The
        // agent on the other end is blocked; a socket held open for a minute
        // against a relay that is down helps nobody.
        configuration.timeoutIntervalForRequest = 10
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    static let relayKey = "mice.push.relay"
    static let secretKey = "mice.push.secret"

    /// The relay the app was built with, from `MICE_PUSH_RELAY_URL` in
    /// project.yml. Empty in a plain checkout, which keeps the "talks to your
    /// Mac and nowhere else" default; set once for a build that testers get,
    /// so none of them has to type a URL into Terminal.
    static var builtInRelay: URL? {
        guard let text = Bundle.main.infoDictionary?["MicePushRelayURL"] as? String,
              !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return URL(string: text)
    }

    private static var builtInSecret: String? {
        guard let text = Bundle.main.infoDictionary?["MicePushRelaySecret"] as? String,
              !text.isEmpty else { return nil }
        return text
    }

    /// What the user typed into Settings → Notifications, if anything.
    var customRelay: String {
        UserDefaults.standard.string(forKey: Self.relayKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// In the Keychain, like every other credential for a path that leaves
    /// the Mac. It used to sit in preferences beside the relay URL; a value
    /// found there is moved across the first time it is read.
    var customSecret: String {
        if let data = SecretStore.read(service: Self.secretService, account: Self.secretAccount) {
            return String(decoding: data, as: UTF8.self)
        }
        let defaults = UserDefaults.standard
        guard let legacy = defaults.string(forKey: Self.secretKey), !legacy.isEmpty else { return "" }
        if SecretStore.write(Data(legacy.utf8), service: Self.secretService, account: Self.secretAccount) {
            defaults.removeObject(forKey: Self.secretKey)
        }
        return legacy
    }

    private static let secretService = "com.renyicao.mice.push.v1"
    private static let secretAccount = "relay"

    /// Where pushes go, or nil if nobody has said: the user's own setting
    /// first, the built-in one otherwise.
    var relay: URL? {
        if !customRelay.isEmpty { return URL(string: customRelay) }
        return Self.builtInRelay
    }

    private var relaySecret: String? {
        if !customRelay.isEmpty { return customSecret.isEmpty ? nil : customSecret }
        return Self.builtInSecret
    }

    var isConfigured: Bool { relay != nil }
    var usesBuiltInRelay: Bool { customRelay.isEmpty && Self.builtInRelay != nil }

    /// From Settings. Empty strings clear the preference, which falls back to
    /// the built-in relay or to nothing.
    @discardableResult
    func setRelay(_ urlString: String, secret: String) -> Bool {
        let defaults = UserDefaults.standard
        // Save the replacement before removing a legacy credential or changing
        // its relay. A refused Keychain write must leave the working settings.
        if secret.isEmpty {
            SecretStore.delete(service: Self.secretService, account: Self.secretAccount)
        } else if !SecretStore.write(Data(secret.utf8), service: Self.secretService, account: Self.secretAccount) {
            return false
        }
        defaults.removeObject(forKey: Self.secretKey)
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { defaults.removeObject(forKey: Self.relayKey) }
        else { defaults.set(trimmed, forKey: Self.relayKey) }
        queue.async { self.lastFailure = nil }
        return true
    }

    /// Whether `relay` answers at all. The worker refuses anything that is not
    /// a push, so any HTTP answer — including its 400 for "not json" — proves
    /// the address is right; only no answer, or a 401 from a wrong secret, is
    /// a problem. Nothing is pushed to any phone by this.
    func probe(completion: @escaping (String) -> Void) {
        guard let relay else { completion("No relay set"); return }
        var request = URLRequest(url: relay)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let relaySecret { request.setValue("Bearer " + relaySecret, forHTTPHeaderField: "Authorization") }
        session.dataTask(with: request) { _, response, error in
            let text: String
            if let error {
                text = "Not reachable: \(error.localizedDescription)"
            } else if let http = response as? HTTPURLResponse {
                switch http.statusCode {
                case 401: text = "The relay refused the secret"
                case 400: text = "Relay reachable"
                case 405: text = "Relay reachable"
                default: text = "Relay answered \(http.statusCode)"
                }
            } else {
                text = "No answer"
            }
            DispatchQueue.main.async { completion(text) }
        }.resume()
    }

    // MARK: - Devices

    func register(_ registration: PushRegistration, forDevice deviceID: String) {
        queue.async {
            self.router.register(registration, forDevice: deviceID)
            miceLog.info("push: \(registration.token == nil ? "stopped" : "registered", privacy: .public) for \(deviceID, privacy: .private)")
        }
    }

    /// A phone connected. It cleared its own lock screen on the way in, so the
    /// Mac's idea of what is on it has to go as well — otherwise the next push
    /// carries a badge counting notifications the user has already dealt with.
    func deviceArrived(_ deviceID: String) {
        queue.async { self.router.deviceArrived(deviceID) }
    }

    /// Revoked or unpaired. The key is dropped elsewhere; this is the half that
    /// stops the pushes.
    func forget(deviceID: String) {
        queue.async { self.router.forget(deviceID: deviceID) }
    }

    func resolved(approvalID: String) {
        queue.async { self.router.resolved(approvalID: approvalID) }
    }

    // MARK: - Sending

    func send(_ event: AgentEvent, targetName: String, connected: Set<String>) {
        queue.async {
            let deliveries = self.router.route(event, targetName: targetName,
                                               connected: connected,
                                               now: ApprovalClock.now())
            // Whether a push was even attempted. A connected phone is left to
            // post its own notification, so "0 pushes, 1 connected" is the
            // answer to "why did only the phone's own banner matter here".
            miceLog.info("push: \(event.kind.rawValue, privacy: .public) → \(deliveries.count, privacy: .public) push(es), \(connected.count, privacy: .public) connected")
            self.deliver(deliveries, category: Self.eventCategory)
        }
    }

    func send(_ request: ApprovalRequest, connected: Set<String>) {
        queue.async {
            let deliveries = self.router.route(request, connected: connected,
                                               now: ApprovalClock.now())
            miceLog.info("push: approval → \(deliveries.count, privacy: .public) push(es), \(connected.count, privacy: .public) connected")
            self.deliver(deliveries, category: (request.isQuestion ? AgentAlert.Kind.question : .approval).category)
        }
    }

    /// What the menu bar shows. A feature that silently does nothing is worse
    /// than one that is off, so there has to be somewhere that says which.
    func summary(completion: @escaping (String) -> Void) {
        queue.async {
            let devices = self.router.subscribedDeviceIDs.count
            let text: String
            if self.relay == nil {
                text = "Not set up"
            } else if devices == 0 {
                text = "None allow notifications yet"
            } else if let failure = self.lastFailure {
                text = failure
            } else {
                text = devices == 1 ? "1 phone" : "\(devices) phones"
            }
            DispatchQueue.main.async { completion(text) }
        }
    }

    // MARK: - Plumbing

    private static let eventCategory = AgentAlert.Kind.waiting.category

    private func deliver(_ deliveries: [PushDelivery], category: String) {
        guard !deliveries.isEmpty else { return }
        guard let relay else {
            // Not an error: no relay is the default, and a Mac at a desk with
            // the phone in front of it never needs one.
            miceLog.info("push: no relay set — not sending")
            return
        }
        for delivery in deliveries {
            guard let key = AwayKeys.existing(forDevice: delivery.deviceID),
                  key.count == RemoteAccess.keyLength else {
                // No key means this device was never approved, or was revoked
                // and had its key dropped. Either way there is nothing to seal
                // with, and sending it in the clear is not the fallback.
                miceLog.error("push: no key for \(delivery.deviceID, privacy: .private) — not sending")
                continue
            }
            guard let sealed = try? PushEnvelope.seal(delivery.alert, with: key) else { continue }
            let payload = PushEnvelope.payload(for: sealed,
                                               category: category,
                                               isTimeSensitive: delivery.alert.isTimeSensitive,
                                               isSilent: delivery.alert.isSilent,
                                               threadID: delivery.alert.threadID,
                                               relevance: delivery.alert.relevance)
            post(delivery, payload: payload, to: relay)
        }
    }

    private func post(_ delivery: PushDelivery, payload: [String: Any], to relay: URL) {
        let body: [String: Any] = [
            "token": delivery.token,
            "sandbox": delivery.usesSandbox,
            "collapseId": delivery.collapseID,
            // APNs wants seconds, and the rest of this protocol is in
            // milliseconds; converted once, here, rather than at both ends.
            "expiration": delivery.expiresAtEpochMillis / 1000,
            "payload": payload,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }

        var request = URLRequest(url: relay)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let relaySecret { request.setValue("Bearer " + relaySecret, forHTTPHeaderField: "Authorization") }
        request.httpBody = data

        let deviceID = delivery.deviceID
        session.dataTask(with: request) { [weak self] data, response, error in
            self?.queue.async { self?.absorb(data, response, error, forDevice: deviceID) }
        }.resume()
    }

    /// The one answer worth acting on rather than logging.
    ///
    /// `BadDeviceToken` means that phone is gone — reinstalled, restored onto
    /// new hardware, or the app deleted — and its token will never work again.
    /// Pushing to it for ever afterwards is how a relay's rate limit gets spent
    /// on nothing, so the registration is dropped and the phone re-registers
    /// the next time it connects, which it does on every connection.
    private func absorb(_ data: Data?, _ response: URLResponse?, _ error: Error?, forDevice deviceID: String) {
        if let error {
            lastFailure = "Relay unreachable"
            miceLog.error("push: \(error.localizedDescription, privacy: .public)")
            return
        }
        let reason = data
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            .flatMap { $0["reason"] as? String }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            if let reason, reason.contains("BadDeviceToken") || reason.contains("Unregistered") {
                router.forget(deviceID: deviceID)
                lastFailure = nil
                miceLog.info("push: \(deviceID, privacy: .private) is gone — stopped")
            } else {
                lastFailure = "Relay said \(status)"
                miceLog.error("push: relay \(status) \(reason ?? "", privacy: .public)")
            }
            return
        }
        lastFailure = nil
        // The relay's 200 is APNs accepting the push, not the phone showing
        // it — but without it the two could not even be told apart.
        miceLog.info("push: relay 200 for \(deviceID, privacy: .private)")
    }
}
