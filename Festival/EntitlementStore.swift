import Combine
import Foundation
import StoreKit

// MARK: - EntitlementStore
//
// Compra única (no consumible) que desbloquea seguir festivales sin límite.
// El producto debe existir en App Store Connect con este mismo Product ID;
// mientras no exista (o sin red), `product` queda nil y el paywall muestra un
// estado de "no disponible" con reintento en vez de romperse.

@MainActor
final class EntitlementStore: ObservableObject {
    static let unlimitedFollowsID = "cl.alvarezaraya.Festival.follows.unlimited"

    @Published private(set) var hasUnlimitedFollows = false
    @Published private(set) var product: Product?
    @Published private(set) var isPurchasing = false
    @Published var purchaseError: String?

    init() {
        // Transacciones que llegan fuera del flujo de compra directo: Ask to
        // Buy aprobado más tarde, restauración desde otro dispositivo, refunds.
        Task { [weak self] in
            for await update in Transaction.updates {
                guard let self else { break }
                if case .verified(let transaction) = update {
                    await transaction.finish()
                }
                await self.refreshEntitlement()
            }
        }
        Task { [weak self] in
            await self?.loadProduct()
            await self?.refreshEntitlement()
        }
    }

    func loadProduct() async {
        guard product == nil else { return }
        product = try? await Product.products(for: [Self.unlimitedFollowsID]).first
    }

    func refreshEntitlement() async {
        var owns = false
        for await entitlement in Transaction.currentEntitlements {
            if case .verified(let transaction) = entitlement,
               transaction.productID == Self.unlimitedFollowsID,
               transaction.revocationDate == nil {
                owns = true
            }
        }
        hasUnlimitedFollows = owns
    }

    func purchase() async {
        purchaseError = nil
        if product == nil { await loadProduct() }
        guard let product else {
            purchaseError = "La compra no está disponible por ahora. Intenta más tarde."
            return
        }
        isPurchasing = true
        defer { isPurchasing = false }
        do {
            switch try await product.purchase() {
            case .success(let verification):
                if case .verified(let transaction) = verification {
                    await transaction.finish()
                    hasUnlimitedFollows = true
                } else {
                    purchaseError = "No se pudo verificar la compra."
                }
            case .userCancelled:
                break
            case .pending:
                purchaseError = "Compra pendiente de aprobación."
            @unknown default:
                break
            }
        } catch {
            purchaseError = error.localizedDescription
        }
    }

    func restore() async {
        purchaseError = nil
        try? await AppStore.sync()
        await refreshEntitlement()
        if !hasUnlimitedFollows {
            purchaseError = "No encontramos compras anteriores para restaurar."
        }
    }
}
