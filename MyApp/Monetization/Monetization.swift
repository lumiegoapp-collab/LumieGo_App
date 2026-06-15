import SwiftUI
import Combine
import StoreKit

// MARK: - Trial Manager

/// Drives the "3 days free, paywall on day 4" model.
/// Records the first-launch date locally and locks premium access once the
/// 3-day window elapses, unless the user has unlocked Pro.
final class TrialManager: ObservableObject {

    @Published private(set) var isPro: Bool = false
    @Published private(set) var daysRemaining: Int = 3
    @Published private(set) var isLocked: Bool = false   // trial expired AND not Pro

    private let trialDays: TimeInterval = 3
    private let defaults = UserDefaults.standard
    private let firstLaunchKey = "lumiego.firstLaunchDate"
    private let proKey          = "lumiego.isPro"

    init() {
        if defaults.object(forKey: firstLaunchKey) == nil {
            defaults.set(Date(), forKey: firstLaunchKey)
        }
        refresh()
    }

    /// Recompute trial state. Call on launch and when returning to foreground.
    func refresh() {
        isPro = defaults.bool(forKey: proKey)
        let start = defaults.object(forKey: firstLaunchKey) as? Date ?? Date()
        let deadline = start.addingTimeInterval(trialDays * 86_400)
        let secondsLeft = deadline.timeIntervalSinceNow

        daysRemaining = max(0, Int(ceil(secondsLeft / 86_400)))
        isLocked = !isPro && secondsLeft <= 0
    }

    /// Call after a successful purchase/restore.
    func markPro() {
        updateSubscription(true)
    }

    /// Sync the live subscription entitlement from StoreKit. Passing `false` re-locks
    /// the app (after the trial) when a subscription has lapsed or been refunded.
    func updateSubscription(_ active: Bool) {
        defaults.set(active, forKey: proKey)
        refresh()
    }

    var trialLabel: String {
        if isPro { return "Pro" }
        if isLocked { return "Trial ended" }
        return daysRemaining == 1 ? "1 day left" : "\(daysRemaining) days left"
    }

    #if DEBUG
    /// Test helpers - only compiled into debug builds.
    func debugResetTrial() {
        defaults.set(Date(), forKey: firstLaunchKey)
        defaults.set(false, forKey: proKey)
        refresh()
    }
    func debugExpireTrial() {
        defaults.set(Date().addingTimeInterval(-4 * 86_400), forKey: firstLaunchKey)
        defaults.set(false, forKey: proKey)
        refresh()
    }
    #endif
}

// MARK: - Store Manager (StoreKit 2)

/// Real StoreKit 2 flow for the "LumieGo Pro" subscription group.
/// Create two AUTO-RENEWABLE subscriptions in App Store Connect (one group) with
/// these exact Product IDs: monthly ($4.99) and 6-month ($19.99).
@MainActor
final class StoreManager: ObservableObject {
    @Published var monthly: Product?
    @Published var sixMonth: Product?
    @Published var isPurchasing = false
    @Published var isPro = false
    @Published var message: String?

    let monthlyID  = "app.lumiego.ios.pro.monthly"
    let sixMonthID = "app.lumiego.ios.pro.6mo"
    private var productIDs: [String] { [monthlyID, sixMonthID] }

    private var updatesTask: Task<Void, Never>?

    init() {
        updatesTask = listenForTransactions()
        Task {
            await loadProducts()
            await refreshEntitlements()
        }
    }

    deinit { updatesTask?.cancel() }

    var monthlyPrice:  String { monthly?.displayPrice  ?? "$4.99" }
    var sixMonthPrice: String { sixMonth?.displayPrice ?? "$19.99" }
    /// True once at least one real StoreKit product has loaded.
    var productsAvailable: Bool { monthly != nil || sixMonth != nil }

    func loadProducts() async {
        do {
            let products = try await Product.products(for: productIDs)
            monthly  = products.first { $0.id == monthlyID }
            sixMonth = products.first { $0.id == sixMonthID }
            if monthly == nil && sixMonth == nil {
                message = "Store products not available yet. Add the subscriptions in App Store Connect."
            }
        } catch {
            message = "Couldn't reach the App Store. Check your connection and try again."
        }
    }

    /// Returns true on a verified, completed purchase of the given product.
    func purchase(_ product: Product?) async -> Bool {
        guard let product else { await loadProducts(); return false }
        isPurchasing = true
        defer { isPurchasing = false }
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                guard case .verified(let transaction) = verification else {
                    message = "Purchase could not be verified."
                    return false
                }
                await transaction.finish()
                isPro = true
                return true
            case .userCancelled:
                return false
            case .pending:
                message = "Your purchase is pending approval."
                return false
            @unknown default:
                return false
            }
        } catch {
            message = "Purchase failed: \(error.localizedDescription)"
            return false
        }
    }

    /// Returns true if a prior purchase was found and restored.
    func restore() async -> Bool {
        do { try await AppStore.sync() } catch { /* user may cancel; fall through */ }
        await refreshEntitlements()
        if !isPro { message = "No previous purchase found to restore." }
        return isPro
    }

    /// Check current entitlements (used on launch and after restore).
    func refreshEntitlements() async {
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result,
               productIDs.contains(transaction.productID),
               transaction.revocationDate == nil {
                isPro = true
                return
            }
        }
        isPro = false
    }

    /// Listen for transactions made outside the app (Ask to Buy, other devices).
    private func listenForTransactions() -> Task<Void, Never> {
        Task.detached { [productIDs] in
            for await update in Transaction.updates {
                guard case .verified(let transaction) = update else { continue }
                await transaction.finish()
                if productIDs.contains(transaction.productID), transaction.revocationDate == nil {
                    await MainActor.run { self.isPro = true }
                }
            }
        }
    }
}

// MARK: - Paywall

struct PaywallView: View {
    @ObservedObject var trial: TrialManager
    @StateObject private var store = StoreManager()
    var hideDebugControls = false   // true for clean App Store screenshots

    private let termsURL   = URL(string: "https://lumiegoapp-collab.github.io/LumieGo/terms.html")!
    private let privacyURL = URL(string: "https://lumiegoapp-collab.github.io/LumieGo/privacy.html")!

    @State private var pickSixMonth = true   // 6-month is the default "best value" plan

    private let features: [(String, String)] = [
        ("camera.on.rectangle",  "Dual camera, front + back at once"),
        ("text.alignleft",       "Teleprompter while you record"),
        ("4k.tv",                "4K recording + custom frame rates"),
        ("sparkles",             "No watermark, unlimited length")
    ]

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color.black, Color(red: 0.10, green: 0.07, blue: 0.02)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer(minLength: 24)

                VStack(spacing: 8) {
                    Image(systemName: "camera.aperture")
                        .font(.system(size: 46))
                        .foregroundStyle(.orange)
                    Text("LumieGo Pro")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                    Text("Your 3-day free trial has ended.\nSubscribe to keep creating.")
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                }
                .padding(.bottom, 26)

                VStack(alignment: .leading, spacing: 14) {
                    ForEach(features, id: \.1) { icon, label in
                        HStack(spacing: 14) {
                            Image(systemName: icon)
                                .font(.system(size: 17))
                                .foregroundColor(.orange)
                                .frame(width: 26)
                            Text(label)
                                .font(.system(size: 15))
                                .foregroundColor(.white)
                            Spacer()
                        }
                    }
                }
                .padding(20)
                .background(Color.white.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .padding(.horizontal, 24)

                Spacer()

                VStack(spacing: 10) {
                    // Plan selection
                    planCard(title: "6 Months", price: store.sixMonthPrice,
                             sublabel: "Billed every 6 months", badge: "SAVE 33%",
                             selected: pickSixMonth) { pickSixMonth = true }
                    planCard(title: "Monthly", price: store.monthlyPrice,
                             sublabel: "Billed every month", badge: nil,
                             selected: !pickSixMonth) { pickSixMonth = false }

                    Button {
                        let product = pickSixMonth ? store.sixMonth : store.monthly
                        if let product {
                            Task { if await store.purchase(product) { trial.markPro() } }
                        } else {
                            Task { await store.loadProducts() }   // retry loading
                        }
                    } label: {
                        Group {
                            if store.isPurchasing { ProgressView().tint(.black) }
                            else if !store.productsAvailable { Text("Try Again") }
                            else { Text("Subscribe") }
                        }
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Color.orange)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .disabled(store.isPurchasing)
                    .padding(.top, 4)

                    Button("Restore Purchase") {
                        Task { if await store.restore() { trial.markPro() } }
                    }
                    .font(.system(size: 14))
                    .foregroundColor(.white.opacity(0.7))

                    Text("Auto-renewable subscription. Your plan renews automatically unless canceled at least 24 hours before the end of the period. Manage or cancel anytime in your Apple ID settings.")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.4))
                        .multilineTextAlignment(.center)

                    // Legal links (required on any purchase screen)
                    HStack(spacing: 6) {
                        Link("Terms of Use", destination: termsURL)
                        Text("·").foregroundColor(.white.opacity(0.4))
                        Link("Privacy Policy", destination: privacyURL)
                    }
                    .font(.system(size: 12, weight: .medium))
                    .tint(.orange)

                    if let msg = store.message {
                        Text(msg)
                            .font(.system(size: 12))
                            .foregroundColor(.orange.opacity(0.9))
                            .multilineTextAlignment(.center)
                            .padding(.top, 4)
                    }

                    #if DEBUG
                    if !hideDebugControls {
                        HStack(spacing: 16) {
                            Button("DEBUG: Unlock") { trial.markPro() }
                            Button("DEBUG: Reset trial") { trial.debugResetTrial() }
                        }
                        .font(.system(size: 11))
                        .foregroundColor(.cyan.opacity(0.7))
                        .padding(.top, 8)
                    }
                    #endif
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 30)
            }
        }
        .interactiveDismissDisabled(true)   // can't swipe past the paywall on day 4
        .task { await store.refreshEntitlements() }
        .onChange(of: store.isPro) { _, pro in
            if pro { trial.markPro() }   // already-purchased users unlock automatically
        }
    }

    /// A selectable subscription plan row.
    private func planCard(title: String, price: String, sublabel: String,
                          badge: String?, selected: Bool,
                          action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().strokeBorder(selected ? Color.orange : Color.white.opacity(0.3), lineWidth: 2)
                        .frame(width: 22, height: 22)
                    if selected { Circle().fill(Color.orange).frame(width: 11, height: 11) }
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(title).font(.system(size: 16, weight: .semibold)).foregroundColor(.white)
                        if let badge {
                            Text(badge)
                                .font(.system(size: 10, weight: .bold)).foregroundColor(.black)
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(Color.orange).clipShape(Capsule())
                        }
                    }
                    Text(sublabel).font(.system(size: 12)).foregroundColor(.white.opacity(0.6))
                }
                Spacer()
                Text(price).font(.system(size: 16, weight: .bold)).foregroundColor(.white)
            }
            .padding(14)
            .background(Color.white.opacity(selected ? 0.10 : 0.04))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(selected ? Color.orange : Color.white.opacity(0.12), lineWidth: selected ? 2 : 1))
        }
        .buttonStyle(.plain)
    }
}

#Preview("Paywall") {
    PaywallView(trial: TrialManager(), hideDebugControls: true)
}
