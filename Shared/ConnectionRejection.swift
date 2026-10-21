import Foundation

/// Terminal handshake replies, recognised by their wire strings so a phone can
/// tell a refusal from a dropped socket.
enum ConnectionRejection: Equatable {
    case revoked
    case versionMismatch

    /// Still says Mice: phones already in use compare this string exactly, so
    /// rewording it would turn a revocation into an unexplained disconnect on
    /// every phone older than the Mac.
    static let revokedMessage = "This Mac has revoked this device. Approve it again in the Mice menu."

    init?(message: String) {
        if message == Self.revokedMessage {
            self = .revoked
        } else if message.hasPrefix("Nimlet on this phone speaks protocol ") {
            // `NimletProtocol.versionRefusal`.
            self = .versionMismatch
        } else {
            return nil
        }
    }
}
