import Foundation
import StoreKit

/// The tip jar — a StoreKit 2 wrapper over three CONSUMABLE products (coffee /
/// lunch / dinner). Buying a tip unlocks nothing, so there's no entitlement to
/// track and every successful transaction is finished immediately. Modelled on the
/// owner's proven FitBridge `StoreManager`, trimmed to the consumable case.
///
/// Singleton, mirroring `PushCenter.shared`: Settings observes `TipStore.shared`.
/// The whole "Support" section stays invisible until `loadState == .loaded`, so
/// nothing shows before the App Store Connect products exist (or when offline).
@MainActor
final class TipStore: ObservableObject {
    static let shared = TipStore()

    // Match the app's bundle id (com.jerryfane.herdr) and the owner's own
    // `com.jerryfane.<app>.<tier>` convention (see FitBridge).
    static let coffeeID = "com.jerryfane.herdr.tip.coffee"
    static let lunchID  = "com.jerryfane.herdr.tip.lunch"
    static let dinnerID = "com.jerryfane.herdr.tip.dinner"
    static let productIDs = [coffeeID, lunchID, dinnerID]

    enum LoadState {
        case idle
        case loading
        case loaded([Product])
        /// Empty result, a thrown error (offline, or products not yet created in
        /// App Store Connect), or any other failure. The section HIDES on this —
        /// a tip jar degrading to invisible is fine; a broken-looking empty
        /// section is not.
        case unavailable
    }

    enum PurchaseState: Equatable {
        case idle
        case purchasing(Product.ID)
        case thankYou(Product.ID)
        case failed(String)
    }

    @Published private(set) var loadState: LoadState = .idle
    @Published private(set) var purchaseState: PurchaseState = .idle

    private var updatesListener: Task<Void, Never>?

    private init() {
        // Drain any transaction that completes OUTSIDE an explicit purchase() call
        // (e.g. an "Ask to Buy" approved later). A consumable grants nothing, so
        // this only finishes it — an unfinished consumable re-delivers here on every
        // launch, which is the classic StoreKit 2 leak.
        updatesListener = Task.detached {
            for await update in Transaction.updates {
                if case .verified(let transaction) = update {
                    await transaction.finish()
                }
            }
        }
    }

    deinit { updatesListener?.cancel() }

    /// Safe to call every time Settings opens: it re-fetches only from `.idle` or a
    /// prior `.unavailable`, so a product created in ASC after first launch appears
    /// the next time Settings opens — no app update required.
    func loadProducts() async {
        switch loadState {
        case .loaded, .loading: return
        case .idle, .unavailable: break
        }
        loadState = .loading
        do {
            let fetched = try await Product.products(for: Self.productIDs)
            guard !fetched.isEmpty else { loadState = .unavailable; return }
            let order = Self.productIDs
            loadState = .loaded(fetched.sorted {
                (order.firstIndex(of: $0.id) ?? 0) < (order.firstIndex(of: $1.id) ?? 0)
            })
        } catch {
            loadState = .unavailable
        }
    }

    func purchase(_ product: Product) async {
        purchaseState = .purchasing(product.id)
        do {
            switch try await product.purchase() {
            case .success(let verification):
                guard case .verified(let transaction) = verification else {
                    purchaseState = .failed("Couldn't verify that purchase.")
                    return
                }
                await transaction.finish()   // consumable: nothing to grant or track
                purchaseState = .thankYou(product.id)
                // Auto-dismiss the thank-you after a beat (only if it's still showing).
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    guard let self else { return }
                    if case .thankYou = self.purchaseState { self.purchaseState = .idle }
                }
            case .userCancelled, .pending:
                purchaseState = .idle
            @unknown default:
                purchaseState = .idle
            }
        } catch {
            purchaseState = .failed("Couldn't complete the purchase. Try again.")
        }
    }
}
