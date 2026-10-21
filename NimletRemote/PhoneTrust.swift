import Foundation
import CryptoKit

/// This phone's key, and everything it remembers about each Mac it paired with.
///
/// The phone's private key is in the Keychain (`ThisDeviceOnly`, so iCloud
/// does not carry it to a second device the Mac never approved), and so is
/// each Mac's push key, which the notification extension reads. What it
/// remembers about each Mac otherwise — the fingerprint it pinned off the QR
/// code, that Mac's trust-listener addresses, how it was last reached and why
/// it cannot be reached from away — is not secret and lives in preferences,
/// keyed by the remembered host's id.
enum PhoneTrust {
    private static let pinsKey = "mice.trust.pins.v1"
    /// The fingerprint of the key the pins were made with.
    private static let ownerKey = "mice.trust.owner.v1"
    private static func candidatesKey(_ hostID: String) -> String { "mice.trust.candidates." + hostID }
    private static func lastReachKey(_ hostID: String) -> String { "mice.trust.lastReach." + hostID }
    private static func unavailableKey(_ hostID: String) -> String { "mice.trust.unavailable." + hostID }
    private static func awayEnabledKey(_ hostID: String) -> String { "mice.trust.awayEnabled." + hostID }

    /// Made on first use. Nil only if the Keychain refused it, which leaves the
    /// phone unable to pair.
    @MainActor static let identity: TrustIdentity? = {
        keyIsNew = SecretStore.read(service: SecretStore.trustService, account: "phone") == nil
        let identity = TrustIdentity.loadOrCreate(account: "phone", commonName: "Nimlet iPhone")
        if identity == nil { remoteLog.error("trust: the Keychain would not store this phone's key") }
        return identity
    }()

    /// Whether `identity` was made by this launch rather than read back.
    @MainActor private static var keyIsNew = false

    /// Drops pins this phone's key never earned, and says whether there were any.
    ///
    /// The key is `ThisDeviceOnly` and preferences are not, so a new iPhone set
    /// up from the old one's backup, or by Quick Start, arrives with every Mac
    /// the old phone paired with and a key none of them has ever seen. Left
    /// alone it dials each of them, is refused, and offers the same refusal
    /// again on every tap — the Mac is listed as paired and nothing gets in.
    /// So the pins are kept with the key that made them, and any made by
    /// another are dropped here, before anything dials: the Macs stay listed,
    /// as ones to pair with again.
    ///
    /// Before the owner was recorded, a key made just now is the only sign.
    /// A reinstall is not one: the Keychain outlives the app and preferences
    /// do not, so it brings back the key and no pins.
    @MainActor
    static func dropPinsMadeByAnotherKey(keyIsNew: Bool? = nil) -> Bool {
        guard let me = identity?.fingerprint.description else { return false }
        let defaults = UserDefaults.standard
        let owner = defaults.string(forKey: ownerKey)
        let inherited = owner.map { $0 != me } ?? (keyIsNew ?? Self.keyIsNew)
        defaults.set(me, forKey: ownerKey)
        let pins = defaults.dictionary(forKey: pinsKey) as? [String: String] ?? [:]
        guard inherited, !pins.isEmpty else { return false }
        remoteLog.notice("trust: \(pins.count, privacy: .public) pin(s) came from another phone's key; pairing again")
        for hostID in pins.keys { forget(hostID: hostID) }
        return true
    }

    /// The key this phone pinned for a Mac, or nil for one it has not paired with.
    static func pin(forHost hostID: String) -> TrustFingerprint? {
        let pins = UserDefaults.standard.dictionary(forKey: pinsKey) as? [String: String] ?? [:]
        return pins[hostID].flatMap(TrustFingerprint.init)
    }

    static func remember(pin: TrustFingerprint, forHost hostID: String) {
        var pins = UserDefaults.standard.dictionary(forKey: pinsKey) as? [String: String] ?? [:]
        pins[hostID] = pin.description
        UserDefaults.standard.set(pins, forKey: pinsKey)
    }

    /// Forgetting a Mac forgets everything about reaching it, the push key
    /// included: a key that outlives the pairing is a key nobody knows they
    /// still have.
    static func forget(hostID: String) {
        var pins = UserDefaults.standard.dictionary(forKey: pinsKey) as? [String: String] ?? [:]
        pins[hostID] = nil
        UserDefaults.standard.set(pins, forKey: pinsKey)
        for key in [candidatesKey(hostID), lastReachKey(hostID), unavailableKey(hostID), awayEnabledKey(hostID)] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        SecretStore.delete(service: SecretStore.awayService, account: hostID)
    }

    /// Addresses of a Mac's trust listeners, best first.
    static func candidates(forHost hostID: String) -> [NimletCandidate] {
        guard let data = UserDefaults.standard.data(forKey: candidatesKey(hostID)),
              let stored = try? JSONDecoder().decode([NimletCandidate].self, from: data) else { return [] }
        return CandidateOrder.sorted(stored)
    }

    /// Replaces the list rather than merging into it: the Mac is the only end
    /// that knows which of its addresses still exist.
    static func remember(_ candidates: [NimletCandidate], forHost hostID: String) {
        guard let data = try? JSONEncoder().encode(candidates) else { return }
        UserDefaults.standard.set(data, forKey: candidatesKey(hostID))
    }

    /// How this phone last reached a Mac. On cellular, a Mac last reached
    /// through the relay has the relay started first.
    static func lastReach(forHost hostID: String) -> NimletCandidate.Reach? {
        UserDefaults.standard.string(forKey: lastReachKey(hostID)).flatMap(NimletCandidate.Reach.init(rawValue:))
    }

    static func remember(lastReach reach: NimletCandidate.Reach, forHost hostID: String) {
        UserDefaults.standard.set(reach.rawValue, forKey: lastReachKey(hostID))
    }

    /// Why the Mac says it cannot be reached from away, if it says so — worth
    /// showing when the phone is off the Mac's network: "your ISP is using
    /// carrier-grade NAT" explains a failure that would otherwise look like a
    /// bug here.
    static func unavailable(forHost hostID: String) -> String? {
        UserDefaults.standard.string(forKey: unavailableKey(hostID))
    }

    static func remember(unavailable: String?, forHost hostID: String) {
        UserDefaults.standard.set(unavailable, forKey: unavailableKey(hostID))
    }

    /// Whether the Mac last said its away access was on. Nil until it has
    /// said anything: a phone that has not reached its Mac since launch does
    /// not know, and "off" was what it used to claim.
    static func awayEnabled(forHost hostID: String) -> Bool? {
        UserDefaults.standard.object(forKey: awayEnabledKey(hostID)) as? Bool
    }

    static func remember(awayEnabled: Bool, forHost hostID: String) {
        UserDefaults.standard.set(awayEnabled, forKey: awayEnabledKey(hostID))
    }

    /// Stores the key that opens this Mac's pushes, where the notification
    /// extension can read it.
    @discardableResult
    static func remember(pushKey: Data, forHost hostID: String) -> Bool {
        SecretStore.write(pushKey, service: SecretStore.awayService, account: hostID)
    }
}
