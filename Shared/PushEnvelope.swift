import Foundation
import CryptoKit

/// Reaching a phone that is asleep in a pocket.
///
/// Everything in `AgentAlerts` only fires while the app is alive — in front,
/// for the twenty-five seconds of grace `NimletClient` buys, or for as long as
/// listening keeps the process running. Past that iOS freezes the process, the
/// socket goes, and an agent that blocks at that moment blocks in silence until
/// somebody happens to pick the phone up. That is the hole this closes, and the
/// only thing that closes it is APNs: a push is delivered by the system, to a
/// device, whether or not the app it belongs to has run this week.
///
/// ## The problem with APNs, and the way out
///
/// A push has to be signed with the APNs key, which belongs to the *team* that
/// owns the bundle id — not to the user, and not to their Mac. Shipping that
/// key inside a downloadable Mac app would hand every copy the ability to push
/// to every other user's phone. So something the developer controls has to hold
/// it, and that something sees every push that passes through.
///
/// Which would be the end of it, except that a push does not have to be
/// readable to be deliverable. Nimlet already gives every approved device a
/// 256-bit key at pairing — `RemoteAccess`, `AwayKeys`, one per device, in the
/// Keychain at both ends, issued over the LAN and never sent anywhere else. So
/// the Mac seals the notification with the key it already shares with that
/// phone, and what travels is ciphertext. The relay signs it, Apple carries it,
/// and a notification service extension on the phone opens it a moment before
/// it is shown.
///
/// What the relay can see: an opaque device token, a length, and a timestamp.
/// What it cannot see: which target, which agent, what it said, what command it
/// wanted to run. That is not a promise about the relay's good behaviour — it
/// is a statement about what it is given.
///
/// ## Why there is no key identifier in here
///
/// The obvious design carries "which key sealed this" so the phone knows which
/// to open it with. That would mean putting a host identifier in the clear, and
/// a host identifier in this app is a Bonjour name — "Renyi's MacBook Air".
/// Handing the relay the user's name, every time an agent finishes a turn, to
/// save the phone trying two keys, is a bad trade. So the phone tries the keys
/// it has; AEAD makes a wrong one fail cleanly rather than ambiguously, and
/// nobody has more than a couple of Macs.
public enum PushEnvelope {

    /// What the phone will actually show, once it can read it.
    ///
    /// Deliberately the alert itself rather than a nudge to go and fetch one.
    /// The tempting design is a content-available push that wakes the app so it
    /// can connect to the Mac and ask what happened — no payload, nothing to
    /// encrypt, nothing to leak. It does not work: iOS budgets background
    /// pushes at a handful a day, throttles them, delays them, and drops them
    /// entirely for an app the user has force-quit. Every one of those is fatal
    /// to the one thing this feature is for. An alert push has none of those
    /// limits, so the alert has to travel, so it has to be sealed.
    public struct Sealed: Codable, Sendable, Equatable {
        /// The sealed `AgentAlert`, base64 for a JSON payload.
        public var box: String
        /// Which version of this format, so a phone can refuse politely rather
        /// than decrypt something it does not understand.
        public var version: Int

        public static let currentVersion = 1

        public init(box: String, version: Int = Sealed.currentVersion) {
            self.box = box
            self.version = version
        }
    }

    public enum Failure: Error, Equatable {
        /// No key opened it. Usually a phone that has been re-paired since,
        /// occasionally one being pushed to by a Mac it no longer knows.
        case noKeyFits
        /// The sealed box is malformed, or from a future version.
        case unreadable
        /// The key is not the right length to be one of ours.
        case badKey
    }

    /// Seals one alert for one device.
    ///
    /// AES-GCM rather than anything more interesting: it is authenticated, it
    /// is what `CryptoKit` gives you on both platforms without a dependency,
    /// and the combined representation puts the nonce, the ciphertext and the
    /// tag in one blob so there is no framing of our own to get wrong.
    public static func seal(_ alert: AgentAlert, with key: Data) throws -> Sealed {
        guard key.count == RemoteAccess.keyLength else { throw Failure.badKey }
        let plaintext = try NimletCoder.encode(alert)
        let box = try AES.GCM.seal(plaintext, using: SymmetricKey(data: key))
        guard let combined = box.combined else { throw Failure.unreadable }
        return Sealed(box: combined.base64EncodedString())
    }

    /// Opens one, trying each key the phone holds.
    ///
    /// Takes the keys rather than reaching for the Keychain itself, because the
    /// one caller that matters is a notification service extension — a separate
    /// process, with its own entitlements, whose whole job is thirty
    /// milliseconds long. Anything it cannot do is better discovered by the app
    /// than by the extension.
    public static func open(_ sealed: Sealed, tryingKeys keys: [Data]) throws -> AgentAlert {
        guard sealed.version == Sealed.currentVersion else { throw Failure.unreadable }
        guard let combined = Data(base64Encoded: sealed.box) else { throw Failure.unreadable }
        for key in keys where key.count == RemoteAccess.keyLength {
            guard let box = try? AES.GCM.SealedBox(combined: combined),
                  let plaintext = try? AES.GCM.open(box, using: SymmetricKey(data: key)),
                  let alert = try? NimletCoder.decode(AgentAlert.self, from: plaintext) else { continue }
            return alert
        }
        throw Failure.noKeyFits
    }

    // MARK: - The APNs payload

    /// The key the sealed alert travels under, inside the push payload.
    public static let payloadKey = "m"

    /// What somebody sees if the extension never runs, or runs and cannot open
    /// the box.
    ///
    /// It has to say something, because iOS shows the payload's own alert text
    /// in that case and an empty string is a blank banner. It must not say
    /// anything specific, because this is the one string in the whole design
    /// that the relay and Apple can both read. "Something needs you" is true of
    /// every alert this sends and tells a bystander nothing.
    public static let placeholderTitle = "Nimlet"
    public static let placeholderBody = "Something needs you"

    /// The whole APNs payload, built here so the Mac and the tests agree on it
    /// and the relay stays a pipe that does not know what it is carrying.
    ///
    /// `mutable-content` is what gets the extension run at all. The category is
    /// carried in the clear and is the one piece of metadata this leaks — it
    /// says "this one has Approve and Deny on it" — because a category that
    /// arrives only from the extension is a category iOS may have already
    /// resolved the buttons from.
    public static func payload(for sealed: Sealed,
                               category: String,
                               isTimeSensitive: Bool,
                               isSilent: Bool,
                               threadID: String,
                               relevance: Double) -> [String: Any] {
        var aps: [String: Any] = [
            "alert": ["title": placeholderTitle, "body": placeholderBody],
            "mutable-content": 1,
            "category": category,
            // A thread id is a grouping hint and would otherwise carry the
            // target's id in the clear. Hashed, so two alerts about one target
            // still group and nothing about which target it is travels.
            "thread-id": opaqueThread(threadID),
            "relevance-score": relevance,
            "interruption-level": isTimeSensitive ? "time-sensitive" : "passive",
        ]
        if !isSilent { aps["sound"] = "default" }
        return ["aps": aps, payloadKey: ["box": sealed.box, "version": sealed.version]]
    }

    /// A stable, meaningless name for a thread. Truncated because a grouping
    /// key only has to not collide, and 64 hex characters in every payload is
    /// bytes spent on nothing.
    static func opaqueThread(_ threadID: String) -> String {
        let digest = SHA256.hash(data: Data(threadID.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
