import StoreKit
import SwiftUI

/// Nimlet Pro, three ways to own the same thing: a monthly or annual
/// auto-renewable subscription, each starting with Apple's two-week free trial,
/// or a one-time Lifetime purchase. All belong to the Apple Account that bought
/// them.
///
/// There is no Nimlet account and no server. Apple-signed transactions on this
/// phone authorize production purchases, read fresh from StoreKit — including
/// offline, where StoreKit answers from its own verified cache. Nothing is
/// written to preferences, so a defaults edit cannot unlock it. Every phone
/// signed in to the same Apple Account gets the same answer.
/// An opted-in TestFlight build grants temporary full beta access from the
/// sandbox receipt or verified app transaction, with no purchase requirement.
///
/// The trial is the App Store's introductory offer, not a clock of our own:
/// Apple decides eligibility (once per Apple Account per subscription group),
/// shows it on the purchase sheet, and starts billing when it ends. Promotions —
/// offer codes, win-back offers, sale prices on Lifetime — are configured in
/// App Store Connect and need nothing here beyond the store view and its
/// Redeem Code button.
@MainActor
final class ProStore: ObservableObject {
    static let shared = ProStore()
    /// Both live in one subscription group, so the trial is offered once
    /// across them and switching plans is a change rather than a second
    /// subscription. Prices and the trial are set in App Store Connect.
    static let subscriptionIDs = ["com.renyicao.nimlet.pro.annual", "com.renyicao.nimlet.pro.monthly"]
    /// Non-consumable. The ID is the one already created in App Store Connect.
    static let lifetimeID = "com.renyicao.nimlet.pro.lifetime"
    static let productIDs = subscriptionIDs + [lifetimeID]

    @Published private(set) var hasLifetime = false
    @Published private(set) var hasSubscription = false
    @Published private(set) var isPublicBeta = false
    @Published private(set) var isChecking = true
    @Published private(set) var message: String?
    private var updates: Task<Void, Never>?
    private var accessRefresh: Task<Void, Never>?

    var hasPro: Bool { isPublicBeta || hasLifetime || hasSubscription }

    private static var publicBetaBuild: Bool {
        Bundle.main.object(forInfoDictionaryKey: "NimletPublicBeta") as? Bool == true
    }

    private static var initialBetaAccess: Bool {
        #if targetEnvironment(simulator)
        let simulator = true
        #else
        let simulator = false
        #endif
        return PublicBetaAccessPolicy.allowsFullAccess(
            publicBetaBuild: publicBetaBuild,
            receiptName: Bundle.main.appStoreReceiptURL?.lastPathComponent,
            simulator: simulator)
    }

    /// Use Apple's regional prices; a fixed US discount can be wrong elsewhere.
    static func annualSavingPercent(monthlyPrice: Decimal, annualPrice: Decimal) -> Int? {
        let twelveMonths = monthlyPrice * 12
        guard twelveMonths > 0, annualPrice > 0, annualPrice < twelveMonths else { return nil }
        let saving = (twelveMonths - annualPrice) / twelveMonths * 100
        return Int(NSDecimalNumber(decimal: saving).doubleValue.rounded())
    }

    init(publicBetaAccess: Bool? = nil) {
        isPublicBeta = publicBetaAccess ?? Self.initialBetaAccess
        if isPublicBeta { isChecking = false }
        if publicBetaAccess == nil, Self.publicBetaBuild {
            Task { [weak self] in
                #if !targetEnvironment(simulator)
                if let result = try? await AppTransaction.shared,
                   case .verified(let app) = result {
                    self?.isPublicBeta = app.environment == .sandbox
                }
                #endif
                await self?.refresh()
            }
        }
        guard !isPublicBeta else { return }
        // Renewals, expiries, refunds, Ask to Buy approvals, redeemed offer
        // codes and purchases made on another phone with this account all
        // arrive here. Started before anything else so none of them is missed.
        updates = Task { [weak self] in
            for await result in Transaction.updates {
                guard case .verified(let transaction) = result,
                      Self.productIDs.contains(transaction.productID) else { continue }
                await self?.refresh()
                await transaction.finish()
            }
        }
        Task { await refresh() }
    }

    /// Current entitlements hold only what is owned right now: Lifetime unless
    /// refunded, and subscriptions in the trial, paid up, or in a billing grace
    /// period. So an expiry needs no date arithmetic here, only a fresh look.
    func refresh() async {
        if isPublicBeta {
            accessRefresh?.cancel()
            accessRefresh = nil
            isChecking = false
            return
        }
        var lifetime = false
        var subscription = false
        var expiration: Date?
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  transaction.revocationDate == nil else { continue }
            if transaction.productID == Self.lifetimeID {
                lifetime = true
            } else if Self.subscriptionIDs.contains(transaction.productID) {
                subscription = true
                if let end = transaction.expirationDate {
                    expiration = min(expiration ?? end, end)
                }
            }
        }
        hasLifetime = lifetime
        hasSubscription = subscription
        isChecking = false
        scheduleAccessRefresh(expiration: expiration)
    }

    private func scheduleAccessRefresh(expiration: Date?) {
        accessRefresh?.cancel()
        accessRefresh = nil
        guard hasPro else { return }
        // Receipt changes can arrive late. Check the verified cache again at
        // expiry and at most every 30 seconds while a Pro entitlement is held.
        let delay = max(1, min(30, expiration?.timeIntervalSinceNow ?? 30))
        accessRefresh = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    /// What the store view reported. It runs the purchase itself, so it can
    /// put Apple's confirmation on the right scene; this only decides what the
    /// outcome means.
    func complete(_ outcome: Result<Product.PurchaseResult, Error>) async {
        guard !isPublicBeta else { return }
        message = nil
        switch outcome {
        case .success(.success(.verified(let transaction))):
            guard Self.productIDs.contains(transaction.productID) else { return }
            await refresh()
            // The signed purchase result can arrive before currentEntitlements
            // contains it. Deliver that verified purchase immediately; future
            // refreshes still handle expiry, refunds and purchases elsewhere.
            let active = transaction.revocationDate == nil && !transaction.isUpgraded
                && (transaction.expirationDate.map { $0 > Date() } ?? true)
            if active {
                if transaction.productID == Self.lifetimeID {
                    hasLifetime = true
                } else {
                    hasSubscription = true
                }
            }
            scheduleAccessRefresh(expiration: transaction.expirationDate)
            await transaction.finish()
            if !hasPro { message = "The purchase could not be confirmed. Try Restore Purchases." }
        case .success(.success(.unverified)):
            message = "Apple could not verify this purchase. Pro remains locked. Try Restore Purchases."
        case .success(.pending):
            message = "Your purchase is awaiting approval. Pro will unlock when Apple confirms it."
        case .success(.userCancelled):
            break
        case .success:
            message = "The purchase is not complete. You can try again."
        case .failure:
            message = "The purchase could not be completed. Please try again."
        }
    }

    func restore() async {
        guard !isPublicBeta else { return }
        message = nil
        do {
            try await AppStore.sync()
            await refresh()
            if !hasPro { message = "No Nimlet Pro purchase was found for this Apple Account." }
        } catch {
            message = "Purchases could not be restored. Check your App Store account and connection, then try again."
        }
    }
}

struct ProSheet: View {
    @ObservedObject private var store = ProStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var annualSavingPercent: Int?
    @State private var managingSubscription = false
    @State private var dismissAfterManaging = false

    var body: some View {
        Group {
            if store.isPublicBeta {
                NavigationStack {
                    List {
                        Label("All features available", systemImage: "checkmark.seal.fill")
                        Text("Public beta access needs no purchase. Pricing and early-bird details will be announced later.")
                        features
                        Link("Beta feedback and setup", destination: URL(string: "https://nimlet.app/beta/")!)
                    }
                    .navigationTitle("Nimlet Beta")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
                }
            } else if store.hasLifetime {
                NavigationStack {
                    List {
                        Label("Lifetime unlocked", systemImage: "checkmark.seal.fill")
                        features
                        if store.hasSubscription {
                            Text("Cancel your old subscription to stop renewal.")
                            Button("Manage subscription") { managingSubscription = true }
                        }
                    }
                    .navigationTitle("Nimlet Pro")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
                }
            } else {
                storeView
            }
        }
        .onInAppPurchaseCompletion { _, outcome in
            await store.complete(outcome)
            guard case .success(.success(.verified(let transaction))) = outcome,
                  ProStore.productIDs.contains(transaction.productID), store.hasPro else { return }
            if transaction.productID == ProStore.lifetimeID && store.hasSubscription {
                // Apple owns cancellation. Take the owner straight to its UI.
                dismissAfterManaging = true
                managingSubscription = true
            } else {
                dismiss()
            }
        }
        .manageSubscriptionsSheet(isPresented: $managingSubscription)
        .onChange(of: managingSubscription) { _, open in
            if !open {
                Task {
                    await store.refresh()
                    if dismissAfterManaging { dismiss() }
                }
            }
        }
        .task {
            guard !store.isPublicBeta else { return }
            guard let plans = try? await Product.products(for: ProStore.subscriptionIDs),
                  let monthly = plans.first(where: { $0.id.hasSuffix(".monthly") }),
                  let annual = plans.first(where: { $0.id.hasSuffix(".annual") }) else { return }
            annualSavingPercent = ProStore.annualSavingPercent(monthlyPrice: monthly.price,
                                                              annualPrice: annual.price)
        }
    }

    /// Apple's own store view: it loads both plans, shows the trial or a
    /// win-back offer only to an account eligible for it, and marks the plan
    /// already subscribed to. Lifetime is a non-consumable, which this view
    /// does not list, so it rides in the header.
    private var storeView: some View {
        SubscriptionStoreView(productIDs: ProStore.subscriptionIDs) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Nimlet Pro").font(.largeTitle.bold())
                Text("Same Pro features. Choose how you pay.")
                    .foregroundStyle(.secondary)
                features
                if let annualSavingPercent {
                    Text("Save \(annualSavingPercent)% with yearly billing.")
                        .font(.subheadline.weight(.medium))
                }
                ProductView(id: ProStore.lifetimeID)
                    .productViewStyle(.compact)
                if store.hasSubscription {
                    Text("Switching to Lifetime? Cancel your subscription to stop renewal.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("Manage subscription") { managingSubscription = true }
                }
                Text("Local trackpad and app switching stay free. Remote access and the work console require Pro. Pro uses your Apple Account. No AI service included.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if let message = store.message {
                    Text(message).font(.callout)
                }
            }
            .padding(.horizontal)
        }
        .subscriptionStoreControlStyle(.picker)
        .storeButton(.visible, for: .restorePurchases, .redeemCode, .policies, .cancellation)
        .subscriptionStorePolicyDestination(url: URL(string: "https://nimlet.app/privacy/")!,
                                            for: .privacyPolicy)
        .subscriptionStorePolicyDestination(url: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!,
                                            for: .termsOfService)
        // The Restore and Redeem Code buttons talk to the App Store but tell
        // nobody; looking again on the way out picks up what they found.
        .onDisappear { Task { await store.refresh() } }
    }

    private var features: some View {
        Group {
            Label("Remote access: VPN, direct and relay", systemImage: "network")
            Label("Live windows and text or voice input", systemImage: "macwindow")
            Label("Agent workflows and Mac audio", systemImage: "waveform")
            Label("Messages, images and screenshot markup", systemImage: "person.2")
        }
    }
}
