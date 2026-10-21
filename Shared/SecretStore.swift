import Foundation
import Security

/// The Keychain, for the one secret that has to be in it.
///
/// Everything Nimlet has kept until now — the pairing code, the approved devices —
/// lives in preferences, and SECURITY.md says so plainly: `defaults read
/// com.renyicao.mice.host mice.pairingCode.v1` is the whole exploit. That is a
/// defensible trade for a LAN program whose threat model starts and ends at the
/// front door, because code already running as the user can post its own
/// CGEvents and does not need Nimlet at all.
///
/// An away key is different in kind. It is the credential for a port that is
/// deliberately reachable from the internet, it is 256 bits precisely so that it
/// cannot be guessed, and it is worthless if it can be read out of a plist by
/// anything that can read a plist. So it goes here, at both ends, and nowhere
/// else.
///
/// The two platforms want different things and asking for the wrong one fails at
/// runtime rather than at compile time:
///
/// - **iOS** has only the data-protection keychain. `ThisDeviceOnly` so the key
///   is not carried to the user's other devices by iCloud Keychain — the Mac
///   issues one key per device and a copy on a second phone would be a device the
///   user never approved — and `AfterFirstUnlock` so a reconnect on a locked
///   phone in a pocket still works.
/// - **macOS** uses the file-based keychain, which is what an unsandboxed
///   Developer ID app can reach without a keychain-access-group entitlement. The
///   item's ACL follows the code signature, so the app gets at its own key and
///   another program asks the user first.
public enum SecretStore {

    /// Where push keys live (`PushEnvelope`). One service, one account per
    /// device id on the Mac and per Mac on the phone.
    public static let awayService = "com.renyicao.mice.away.v1"
    /// Where each end keeps its own long-lived key (`TrustIdentity`).
    public static let trustService = "com.renyicao.mice.trust.v1"

    #if os(iOS)
    /// The group the app shares with its notification service extension.
    ///
    /// The extension is a separate process with its own bundle id, and the key
    /// it needs to open a sealed push is one this app was given at pairing.
    /// A shared access group is the only route between them that does not
    /// involve writing the key somewhere less careful than the Keychain.
    ///
    /// The team prefix has to be resolved: `kSecAttrAccessGroup` takes the full
    /// string, while the entitlement holds `$(AppIdentifierPrefix)…` and nothing
    /// resolves that at runtime. So the build writes the resolved group into
    /// Info.plist from the same two settings the entitlement uses
    /// (`Signing/Base.xcconfig`), and a fork signing with its own team gets its
    /// own group. The literal is the official group, for a bundle built without
    /// the key, such as the connection-test host.
    public static let sharedGroup: String = {
        if let group = Bundle.main.object(forInfoDictionaryKey: "NimletKeychainGroup") as? String,
           !group.isEmpty, !group.hasPrefix("."), !group.contains("$(") {
            return group
        }
        return "HG29U745Q5.com.renyicao.mice.shared"
    }()

    /// Every secret under one service.
    ///
    /// For the extension, which is deliberately told nothing about which Mac
    /// sealed the push it is holding — saying so would mean putting a host
    /// name in the clear, and a host name here is "Renyi's MacBook Air". So it
    /// tries the keys it has, which is a list of one for almost everybody.
    public static func readAll(service: String) -> [Data] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitAll]
        applyPlatform(&query)
        var items: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &items) == errSecSuccess else { return [] }
        return (items as? [Data]) ?? []
    }

    #endif

    public static func read(service: String, account: String) -> Data? {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        applyPlatform(&query)
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            if status != errSecItemNotFound {
                miceSecretLog("read \(account) failed with \(status)")
            }
            return nil
        }
        return item as? Data
    }

    /// Writes, replacing whatever was there. Returns false rather than throwing:
    /// every caller's answer to a Keychain that will not cooperate is the same —
    /// away access is unavailable and the user is told why — and there is nothing
    /// to distinguish between the ways it can refuse.
    @discardableResult
    public static func write(_ data: Data, service: String, account: String) -> Bool {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        applyPlatform(&query)

        var attributes: [String: Any] = [kSecValueData as String: data]
        #if os(iOS)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        // Named rather than left to the default. The default is the first group
        // in the entitlement, which is this one today and would silently stop
        // being it the moment somebody reorders that array.
        query[kSecAttrAccessGroup as String] = sharedGroup
        #endif

        let update = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if update == errSecSuccess { return true }
        guard update == errSecItemNotFound else {
            miceSecretLog("update \(account) failed with \(update)")
            return false
        }
        var insert = query
        insert.merge(attributes) { _, new in new }
        let status = SecItemAdd(insert as CFDictionary, nil)
        if status != errSecSuccess { miceSecretLog("add \(account) failed with \(status)") }
        return status == errSecSuccess
    }

    @discardableResult
    public static func delete(service: String, account: String) -> Bool {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        applyPlatform(&query)
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// Whether this Keychain can be written to at all, answered by doing it.
    ///
    /// Worth having as a question: a Keychain that refuses is the difference
    /// between "away access is off" and "away access looks on and no phone can
    /// ever connect", and the user should be told which.
    public static func isUsable() -> Bool {
        let probe = "mice.probe"
        guard write(Data([0x01]), service: awayService, account: probe) else { return false }
        let readBack = read(service: awayService, account: probe)
        delete(service: awayService, account: probe)
        return readBack == Data([0x01])
    }

    private static func applyPlatform(_ query: inout [String: Any]) {
        #if os(iOS)
        // The only keychain there is, and the default — named anyway, because
        // the same code compiles for the Mac where the default is the other one.
        query[kSecUseDataProtectionKeychain as String] = true
        #else
        // Deliberately the file-based keychain. The data-protection one on macOS
        // needs an entitlement this app does not have and should not ask for.
        query[kSecUseDataProtectionKeychain as String] = false
        #endif
    }
}

/// A print rather than a logger, because this file is compiled into both apps
/// and each has its own `Logger` with its own subsystem. A Keychain failure is
/// rare, actionable and worth seeing in the console either way — including in
/// the Release build a tester is running, which is where it will happen.
private func miceSecretLog(_ message: String) {
    print("keychain: \(message)")
}
