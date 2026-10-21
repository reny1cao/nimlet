import StoreKit
import StoreKitTest
import XCTest

@MainActor
final class ProPurchaseTests: XCTestCase {
    func testAnnualSavingUsesRegionalPrices() {
        XCTAssertEqual(ProStore.annualSavingPercent(monthlyPrice: Decimal(string: "4.99")!,
                                                    annualPrice: Decimal(string: "29.99")!), 50)
        XCTAssertEqual(ProStore.annualSavingPercent(monthlyPrice: 38, annualPrice: 198), 57)
        XCTAssertNil(ProStore.annualSavingPercent(monthlyPrice: 0, annualPrice: 30))
        XCTAssertNil(ProStore.annualSavingPercent(monthlyPrice: 5, annualPrice: 60))
    }

    func testCancelledPendingAndFailedPurchaseDoNotGrantPro() async throws {
        let session = try SKTestSession(configurationFileNamed: "Nimlet")
        session.resetToDefaultState()
        session.disableDialogs = true
        session.clearTransactions()
        defer { session.clearTransactions() }
        let store = ProStore.shared
        await store.refresh()

        await store.complete(.success(.userCancelled))
        XCTAssertFalse(store.hasPro)
        XCTAssertNil(store.message, "Cancellation should return to the free workflow quietly")

        await store.complete(.success(.pending))
        XCTAssertFalse(store.hasPro, "Pending approval must not grant access")
        XCTAssertNotNil(store.message)

        await store.complete(.failure(NSError(domain: "NimletPurchaseTest", code: 1)))
        XCTAssertFalse(store.hasPro, "A failed purchase must keep access locked")
        XCTAssertNotNil(store.message)
    }

    func testTrialSubscriptionLifetimeAndRefundChangeAccess() async throws {
        executionTimeAllowance = 120
        // Printed so a run that hangs inside StoreKit Test says where.
        print("StoreKit checkpoint: configure local test session")
        let session = try SKTestSession(configurationFileNamed: "Nimlet")
        session.resetToDefaultState()
        session.disableDialogs = true
        session.clearTransactions()
        defer { session.clearTransactions() }
        let store = ProStore.shared

        print("StoreKit checkpoint: refresh empty entitlements")
        await store.refresh()
        XCTAssertFalse(store.hasPro, "A clean install must not grant Pro")

        print("StoreKit checkpoint: load products")
        let products = try await Product.products(for: ProStore.productIDs)
        XCTAssertEqual(Set(products.map(\.id)), Set(ProStore.productIDs), "All three options must load")
        let annual = try XCTUnwrap(products.first { $0.id == "com.renyicao.nimlet.pro.annual" })
        let monthly = try XCTUnwrap(products.first { $0.id == "com.renyicao.nimlet.pro.monthly" })
        let lifetime = try XCTUnwrap(products.first { $0.id == ProStore.lifetimeID })
        XCTAssertEqual(monthly.price, Decimal(string: "4.99"))
        XCTAssertEqual(annual.price, Decimal(string: "29.99"))
        XCTAssertEqual(lifetime.price, Decimal(string: "99.99"))
        XCTAssertEqual(lifetime.type, .nonConsumable)
        for plan in [annual, monthly] {
            let offer = try XCTUnwrap(plan.subscription?.introductoryOffer, "\(plan.id) has no trial")
            XCTAssertEqual(offer.paymentMode, .freeTrial)
            XCTAssertEqual(offer.period.unit, .week)
            XCTAssertEqual(offer.period.value, 2, "The trial is fourteen days")
        }
        let eligibleBefore = await annual.subscription!.isEligibleForIntroOffer
        XCTAssertTrue(eligibleBefore, "A new account gets the trial")

        print("StoreKit checkpoint: start trial")
        // Use StoreKit Test's transaction API so this entitlement test does
        // not depend on a purchase sheet's foreground presentation scene.
        let subscription = try await session.buyProduct(identifier: annual.id)
        await store.complete(.success(.success(.verified(subscription))))
        XCTAssertTrue(store.hasSubscription, "Starting the trial must unlock Pro")
        // Sandbox updates group eligibility asynchronously after purchase.
        let eligibilityDeadline = Date().addingTimeInterval(8)
        var eligibleAfter = await monthly.subscription!.isEligibleForIntroOffer
        while eligibleAfter && Date() < eligibilityDeadline {
            try await Task.sleep(for: .milliseconds(100))
            eligibleAfter = await monthly.subscription!.isEligibleForIntroOffer
        }
        XCTAssertFalse(eligibleAfter, "The trial is once per group, not once per plan")

        print("StoreKit checkpoint: restore")
        await store.restore()
        XCTAssertTrue(store.hasPro, "Restore must preserve the subscription")

        print("StoreKit checkpoint: expire subscription")
        try session.expireSubscription(productIdentifier: annual.id)
        // StoreKit Test takes about fifteen seconds to drop an expired
        // subscription from current entitlements (iOS 27.1 simulator).
        try await waitFor(store, hasPro: false, within: 60, "An expired subscription must lock Pro again")

        print("StoreKit checkpoint: buy lifetime")
        let ownership = try await session.buyProduct(identifier: lifetime.id)
        await store.complete(.success(.success(.verified(ownership))))
        XCTAssertTrue(store.hasLifetime, "Lifetime must unlock Pro with no subscription")

        print("StoreKit checkpoint: refund lifetime")
        let bought = try XCTUnwrap(session.allTransactions().last { $0.productIdentifier == lifetime.id })
        try session.refundTransaction(identifier: bought.identifier)
        try await waitFor(store, hasPro: false, "A refund must remove access")

        let client = NimletClient()
        XCTAssertFalse(client.requirePro())
        XCTAssertTrue(client.showingPro, "Denied access must offer Pro")
        print("StoreKit checkpoint: done")
    }

    /// StoreKit delivers expiries and refunds asynchronously, so wait for the
    /// visible state rather than race the delivery.
    private func waitFor(_ store: ProStore, hasPro expected: Bool, within seconds: TimeInterval = 8,
                         _ message: String) async throws {
        let start = Date()
        repeat {
            await store.refresh()
            if store.hasPro == expected { break }
            try await Task.sleep(for: .milliseconds(100))
        } while Date().timeIntervalSince(start) < seconds
        print("StoreKit checkpoint: settled after \(Date().timeIntervalSince(start))s")
        XCTAssertEqual(store.hasPro, expected, message)
    }
}
