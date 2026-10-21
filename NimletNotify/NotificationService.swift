import UserNotifications

/// Opens a sealed push a moment before it is shown.
///
/// This is the whole reason a Nimlet notification can say "claude (work) —
/// waiting for you" while the relay that carried it knows only that some
/// device got 300 bytes. The Mac sealed the alert with the 256-bit key it was
/// given at pairing; this runs on the phone, in a process of its own, with a
/// Keychain access group shared with the app, and opens it. See `PushEnvelope`.
///
/// ## What it must do when it cannot
///
/// Deliver something, every time, on every path. An extension that returns
/// nothing does not suppress the notification — iOS shows the payload as it
/// arrived, which is the placeholder, and then kills the process. An extension
/// that is slow gets `serviceExtensionTimeWillExpire` and then the same. So
/// every branch here ends in the content handler being called, and the thing
/// held in reserve is the unmodified push rather than an empty one.
///
/// The placeholder is honest rather than apologetic: "Nimlet — Something needs
/// you". If the key does not fit — a phone re-paired since, a Mac it no longer
/// knows — the user still learns that something wants them, which is more than
/// they had before, and opening the app tells them the rest.
final class NotificationService: UNNotificationServiceExtension {

    private var handler: ((UNNotificationContent) -> Void)?
    private var pending: UNMutableNotificationContent?

    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        handler = contentHandler
        guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else {
            contentHandler(request.content)
            return
        }
        pending = content

        guard let sealed = Self.sealed(in: request.content.userInfo) else {
            // Not one of ours, or a push from a Mac speaking a format this
            // build has never heard of. Shown as the placeholder — not as
            // whatever the payload said, which nothing has vouched for.
            contentHandler(Self.placeholder(content))
            return
        }

        // Anything the app wrote before the shared access group existed lives
        // somewhere this process cannot see. The app moves them on launch; an
        // extension that runs first would find nothing, so it looks too —
        // reading is all it is entitled to do, which is all this needs.
        let keys = SecretStore.readAll(service: SecretStore.awayService)
        guard let alert = try? PushEnvelope.open(sealed, tryingKeys: keys) else {
            contentHandler(Self.placeholder(content))
            return
        }

        content.title = alert.title
        content.subtitle = alert.subtitle ?? ""
        content.body = alert.body
        // Regrouped under the real target now that there is one to name. The
        // payload carried a hash of it so that two alerts about one agent would
        // group even if this never ran.
        content.threadIdentifier = alert.threadID
        content.categoryIdentifier = alert.kind.category
        content.badge = NSNumber(value: alert.badge)
        content.userInfo = Self.userInfo(for: alert)
        contentHandler(content)
    }

    /// Thirty seconds, and this does a base64 decode and one AES-GCM open. If
    /// it ever gets here something is very wrong, and the answer is still to
    /// show the placeholder rather than to show nothing.
    override func serviceExtensionTimeWillExpire() {
        guard let handler, let pending else { return }
        handler(Self.placeholder(pending))
        self.handler = nil
    }

    /// What is shown when the box could not be opened, or there was none.
    ///
    /// The payload's own text, category and user info are overwritten rather
    /// than passed through. The push relay forwards what it is given, and a
    /// push nobody sealed is a push nobody has vouched for: letting it put
    /// its own words — or Approve and Deny buttons — on the lock screen would
    /// make the relay's bearer secret, which ships inside the Mac app, into a
    /// way of writing convincing notifications. The only thing a sealed box
    /// proves is that the Mac this phone paired with sent it, and only then
    /// does the banner say anything specific.
    private static func placeholder(_ content: UNMutableNotificationContent) -> UNNotificationContent {
        content.title = PushEnvelope.placeholderTitle
        content.subtitle = ""
        content.body = PushEnvelope.placeholderBody
        content.categoryIdentifier = ""
        content.threadIdentifier = ""
        content.badge = nil
        content.userInfo = [:]
        return content
    }

    // MARK: - Shapes


    private static func sealed(in userInfo: [AnyHashable: Any]) -> PushEnvelope.Sealed? {
        guard let raw = userInfo[PushEnvelope.payloadKey] as? [String: Any],
              let box = raw["box"] as? String else { return nil }
        let version = raw["version"] as? Int ?? PushEnvelope.Sealed.currentVersion
        return PushEnvelope.Sealed(box: box, version: version)
    }

    /// What a tap has to be able to act on. The same keys `AgentAlerts` puts on
    /// a local notification, so the delegate that handles a tap cannot tell —
    /// and does not have to care — which of the two routes brought it here.
    private static func userInfo(for alert: AgentAlert) -> [String: Any] {
        var info: [String: Any] = ["kind": alert.kind.rawValue]
        if let targetID = alert.targetID { info["targetID"] = targetID }
        if let approvalID = alert.approvalID { info["approvalID"] = approvalID }
        return info
    }
}
