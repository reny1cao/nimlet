import Foundation

/// Beta access is part of this release, not a purchase or a preference.
enum PublicBetaAccessPolicy {
    static func allowsFullAccess(publicBetaBuild: Bool, receiptName: String?,
                                 verifiedSandbox: Bool = false, simulator: Bool = false) -> Bool {
        publicBetaBuild && (verifiedSandbox || receiptName == "sandboxReceipt" || simulator)
    }
}
