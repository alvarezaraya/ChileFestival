import StoreKit
import SwiftUI

// MARK: - Paywall
//
// Aparece al intentar seguir un cuarto festival. Ofrece la compra única que
// desbloquea seguir sin límite (EntitlementStore). Al completarse la compra el
// sheet se cierra solo y la selección continúa donde estaba.

struct PaywallView: View {
    @ObservedObject var entitlements: EntitlementStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: "#5A2CA0").opacity(0.45), .black],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            VStack(spacing: 22) {
                Image(systemName: "infinity.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.white, .white.opacity(0.15))
                    .padding(.top, 26)

                VStack(spacing: 6) {
                    Text("Festivales sin límite")
                        .font(.title.bold())
                    Text("Ya sigues \(FollowStore.freeLimit) festivales gratis. Desbloquea el resto con una compra única.")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.65))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 30)
                }

                VStack(alignment: .leading, spacing: 12) {
                    bullet("music.note.list", "Sigue todos los festivales que quieras")
                    bullet("calendar.badge.plus", "Nuevas ediciones apenas se anuncien")
                    bullet("heart.fill", "Apoyas el desarrollo de la app")
                }
                .padding(.horizontal, 34)

                Spacer(minLength: 0)

                if let error = entitlements.purchaseError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 30)
                }

                VStack(spacing: 10) {
                    Button {
                        Task { await entitlements.purchase() }
                    } label: {
                        Group {
                            if entitlements.isPurchasing {
                                ProgressView().tint(.white)
                            } else if let product = entitlements.product {
                                Text("Desbloquear por \(product.displayPrice)")
                            } else {
                                Text("Desbloquear")
                            }
                        }
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color(hex: "#5A2CA0").gradient, in: Capsule())
                        .foregroundStyle(.white)
                    }
                    .disabled(entitlements.isPurchasing)

                    Button("Restaurar compras") {
                        Task { await entitlements.restore() }
                    }
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.white.opacity(0.65))
                }
                .padding(.horizontal)
                .padding(.bottom, 14)
            }
            .foregroundStyle(.white)
        }
        .preferredColorScheme(.dark)
        .task {
            // Reintenta cargar el producto si el primer intento (al abrir la
            // app) falló, p. ej. por falta de red.
            await entitlements.loadProduct()
        }
        .onChange(of: entitlements.hasUnlimitedFollows) { _, unlocked in
            if unlocked { dismiss() }
        }
    }

    private func bullet(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.subheadline)
                .foregroundStyle(Color(hex: "#B78CFF"))
                .frame(width: 24)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.85))
        }
    }
}
