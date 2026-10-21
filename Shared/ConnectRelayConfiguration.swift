import Foundation

/// Keep an address and its pin from the same source. A custom relay must
/// never inherit the built-in server's pin when its own pin is missing.
struct ConnectRelayConfiguration {
    let address: String
    let fingerprint: TrustFingerprint?

    static func resolve(preferences: [String: Any], bundle: [String: Any]) -> Self? {
        if let address = nonempty(preferences["mice.relay"]) {
            return Self(address: address,
                        fingerprint: nonempty(preferences["mice.relayFingerprint"]).flatMap(TrustFingerprint.init))
        }
        guard let address = nonempty(bundle["MiceConnectRelay"]) else { return nil }
        return Self(address: address,
                    fingerprint: nonempty(bundle["MiceConnectRelayFingerprint"]).flatMap(TrustFingerprint.init))
    }

    private static func nonempty(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
