import XCTest

final class PublicBetaAccessPolicyTests: XCTestCase {
    func testProductionReceiptCannotUnlockPublicBeta() {
        XCTAssertFalse(PublicBetaAccessPolicy.allowsFullAccess(publicBetaBuild: true, receiptName: "receipt"))
        XCTAssertFalse(PublicBetaAccessPolicy.allowsFullAccess(publicBetaBuild: true, receiptName: nil))
    }

    func testOnlyOptedInReleaseGetsSandboxAndSimulatorAccess() {
        XCTAssertTrue(PublicBetaAccessPolicy.allowsFullAccess(publicBetaBuild: true, receiptName: "sandboxReceipt"))
        XCTAssertTrue(PublicBetaAccessPolicy.allowsFullAccess(publicBetaBuild: true, receiptName: nil, verifiedSandbox: true))
        XCTAssertTrue(PublicBetaAccessPolicy.allowsFullAccess(publicBetaBuild: true, receiptName: nil, simulator: true))
        XCTAssertFalse(PublicBetaAccessPolicy.allowsFullAccess(publicBetaBuild: false, receiptName: "sandboxReceipt", verifiedSandbox: true, simulator: true))
    }
}
