import Foundation
import CryptoKit
import Combine

/// This Mac's key, and the decision about whose keys it accepts.
///
/// The key is made once and kept in the Keychain; everything a phone pins is
/// derived from it, so losing it means every phone pairs again — which is the
/// right outcome for a key that may have leaked, and the reason it is not in
/// preferences next to the pairing code. See `DeviceTrust.swift`.
final class HostTrust: ObservableObject, @unchecked Sendable {
    static let shared = HostTrust()


    /// Nil only if the Keychain refused the key, in which case the trust
    /// listener does not start and the menu says why.
    let identity: TrustIdentity?

    /// The invitation on screen, if any. Published for the menu; the secret
    /// inside it is read under `lock` by the network queue.
    @Published private(set) var invitation: PairingInvitation?
    @Published private(set) var invitationExpires: Date?
    /// Set when a phone redeems the invitation, so the QR window can say who
    /// just paired and close itself.
    @Published private(set) var lastPaired: String?
    /// And which key it was, so the window can offer to remove the phones it
    /// may have replaced without offering to remove it.
    @Published private(set) var lastPairedID: String?

    private let lock = NSLock()
    private var window = PairingWindow()

    private init() {
        identity = TrustIdentity.loadOrCreate(account: "host", commonName: "Nimlet Mac")
        if identity == nil {
            miceLog.error("trust: the Keychain would not store this Mac's key; pairing by QR is unavailable")
        }
    }

    var fingerprint: TrustFingerprint? { identity?.fingerprint }

    /// The verify block's question. Runs on the TLS verify queue.
    ///
    /// An approved key is let in anywhere. An unknown one only on the LAN and
    /// only while an invitation is open — and then all it gets is a socket on
    /// which `pair` is the one thing it may say. The away listener never pairs:
    /// the credential for a path is not handed out down that path.
    func accepts(_ peer: TrustFingerprint, onLAN: Bool) -> Bool {
        if DeviceRegistry.shared.isApproved(peer.description) { return true }
        return onLAN && lock.withLock { window.isOpen }
    }

    /// Puts a fresh invitation on screen, replacing any open one.
    @MainActor
    func openInvitation(name: String, addresses: [String]) {
        guard let fingerprint else { return }
        let secret = lock.withLock { window.open() }
        invitation = PairingInvitation(host: fingerprint, secret: secret, name: name, addresses: addresses)
        invitationExpires = Date().addingTimeInterval(PairingWindow.lifetime)
        lastPaired = nil
        lastPairedID = nil
        miceLog.info("trust: pairing code shown (\(addresses.count, privacy: .public) address(es))")
    }

    @MainActor
    func closeInvitation() {
        if invitation != nil { miceLog.info("trust: pairing code closed") }
        lock.withLock { window.close() }
        invitation = nil
        invitationExpires = nil
    }

    /// Checks a phone's proof. Runs on the network queue.
    func redeem(_ proof: Data, exporter: Data, device: TrustFingerprint, name: String) -> Bool {
        let ok = lock.withLock { window.redeem(proof, exporter: exporter, device: device) }
        if ok {
            DispatchQueue.main.async {
                self.invitation = nil
                self.invitationExpires = nil
                self.lastPaired = name
                self.lastPairedID = device.description
            }
        }
        return ok
    }

    /// How many approved devices are paired by key. One or more is the
    /// condition for the away listener, and the relay, to run at all.
    var trustedDeviceCount: Int {
        DeviceRegistry.shared.approvedIdentifiers().filter { TrustFingerprint($0) != nil }.count
    }

    var hasTrustedDevices: Bool { trustedDeviceCount > 0 }
}
