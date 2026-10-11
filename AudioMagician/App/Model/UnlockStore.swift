import Foundation
import Observation
import StoreKit

/// The one-time "Audio Magician Unlock". Everything is free except the exact
/// receiver settings in the fix plan.
@MainActor
@Observable
final class UnlockStore {
    /// Must match the non-consumable created in App Store Connect.
    static let productID = "com.audiomagician.app.unlock"

    private(set) var product: Product?
    private(set) var isPurchased = false
    private(set) var isWorking = false
    var lastError: String?

    /// Developer override for testing locked/unlocked states (always false in release builds).
    private var debugFlag = false

    var isUnlocked: Bool { isPurchased || debugFlag }

    #if DEBUG
    var debugUnlocked: Bool {
        get { debugFlag }
        set {
            debugFlag = newValue
            UserDefaults.standard.set(newValue, forKey: "debugUnlocked")
        }
    }
    #endif

    @ObservationIgnored private var updates: Task<Void, Never>?

    func start() {
        guard updates == nil else { return }
        #if DEBUG
        debugFlag = UserDefaults.standard.bool(forKey: "debugUnlocked")
        #endif
        updates = Task { [weak self] in
            for await result in Transaction.updates {
                if case .verified(let t) = result {
                    await t.finish()
                    await self?.refresh()
                }
            }
        }
        Task {
            await loadProduct()
            await refresh()
        }
    }

    func loadProduct() async {
        do {
            product = try await Product.products(for: [Self.productID]).first
        } catch {
            lastError = error.localizedDescription
        }
    }

    func refresh() async {
        var owned = false
        for await result in Transaction.currentEntitlements {
            if case .verified(let t) = result, t.productID == Self.productID, t.revocationDate == nil {
                owned = true
            }
        }
        isPurchased = owned
    }

    func purchase() async {
        guard let product else {
            lastError = "The store isn't available right now. Please try again in a moment."
            return
        }
        isWorking = true
        defer { isWorking = false }
        do {
            switch try await product.purchase() {
            case .success(let verification):
                if case .verified(let t) = verification {
                    await t.finish()
                    isPurchased = true
                }
            case .pending, .userCancelled:
                break
            @unknown default:
                break
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func restore() async {
        isWorking = true
        defer { isWorking = false }
        try? await AppStore.sync()
        await refresh()
    }
}
