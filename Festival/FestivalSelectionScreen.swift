import SwiftUI

// MARK: - Pantalla de selección de festivales
//
// Doble uso: onboarding (primer arranque, pantalla completa) y edición
// posterior (sheet desde el carrusel). Se eligen hasta `FollowStore.freeLimit`
// series gratis; el intento de agregar una más abre el paywall.

struct FestivalSelectionScreen: View {
    enum Mode { case onboarding, edit }

    let feed: FestivalFeed
    let mode: Mode
    @ObservedObject var followStore: FollowStore
    @ObservedObject var entitlements: EntitlementStore
    /// Se llama después de guardar la selección.
    var onFinished: () -> Void
    /// Solo en modo edición: cerrar sin guardar.
    var onCancel: (() -> Void)? = nil

    @State private var selectedKeys: [String] = []
    @State private var showPaywall = false
    @State private var searchText = ""

    private var series: [FestivalSeries] { feed.series }

    /// Series visibles en la lista. Sin búsqueda: las 5 más multitudinarias,
    /// más las que el usuario ya sigue (para poder quitarlas sin buscarlas).
    /// Con búsqueda: el catálogo completo filtrado por nombre (ignora
    /// mayúsculas y acentos, cortesía de localizedStandardContains).
    private var visibleSeries: [FestivalSeries] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            let featured = feed.featuredSeries
            let extras = series.filter { serie in
                selectedKeys.contains(serie.key) && !featured.contains { $0.key == serie.key }
            }
            return featured + extras
        }
        return series.filter { $0.name.localizedStandardContains(query) }
    }
    private var atFreeLimit: Bool {
        !entitlements.hasUnlimitedFollows && selectedKeys.count >= FollowStore.freeLimit
    }

    var body: some View {
        ZStack {
            background

            ScrollView {
                VStack(spacing: 24) {
                    header
                    VStack(spacing: 12) {
                        searchField
                        ForEach(visibleSeries) { serie in
                            SeriesCard(
                                series: serie,
                                isSelected: selectedKeys.contains(serie.key),
                                isLocked: atFreeLimit && !selectedKeys.contains(serie.key),
                                action: { toggle(serie) }
                            )
                        }
                        if visibleSeries.isEmpty {
                            noResults
                        } else if searchText.isEmpty {
                            searchHint
                        }
                    }
                    .padding(.horizontal)
                }
                .padding(.top, mode == .onboarding ? 32 : 24)
                .padding(.bottom, 12)
            }
        }
        .safeAreaInset(edge: .bottom) { confirmButton }
        .overlay(alignment: .topTrailing) {
            if mode == .edit, let onCancel {
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(10)
                        .background(.white.opacity(0.12), in: Circle())
                }
                .accessibilityLabel("Cerrar sin guardar")
                .padding()
            }
        }
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .sensoryFeedback(.selection, trigger: selectedKeys.count)
        .onAppear { selectedKeys = followStore.followedKeys }
        .sheet(isPresented: $showPaywall) {
            PaywallView(entitlements: entitlements)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    private func toggle(_ serie: FestivalSeries) {
        if let idx = selectedKeys.firstIndex(of: serie.key) {
            selectedKeys.remove(at: idx)
        } else if entitlements.hasUnlimitedFollows || selectedKeys.count < FollowStore.freeLimit {
            selectedKeys.append(serie.key)
        } else {
            // Cuarto festival sin la compra: se ofrece el pase sin límite.
            showPaywall = true
        }
    }

    // MARK: Piezas

    private var background: some View {
        LinearGradient(colors: [Color(hex: "#5A2CA0").opacity(0.35), .black],
                       startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
    }

    private var header: some View {
        VStack(spacing: 10) {
            if mode == .onboarding {
                Image(systemName: "music.mic.circle.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(.white, .white.opacity(0.15))
            }
            Text(mode == .onboarding ? "Sigue tus festivales" : "Tus festivales")
                .font(.largeTitle.bold())
            Text("Estos son los 5 más multitudinarios de Chile; con el buscador llegas al catálogo completo. Elige hasta \(FollowStore.freeLimit) gratis y cámbialos cuando quieras.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.65))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
            slotIndicator
        }
    }

    /// Cuadro de búsqueda sobre el catálogo completo de series (no solo las
    /// 5 destacadas). Al escribir, la lista pasa a mostrar los resultados.
    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.white.opacity(0.45))
            TextField("", text: $searchText,
                      prompt: Text("Busca entre todos los festivales")
                          .foregroundStyle(.white.opacity(0.45)))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .foregroundStyle(.white)
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.white.opacity(0.45))
                }
                .accessibilityLabel("Borrar búsqueda")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(.white.opacity(0.08), in: Capsule())
    }

    private var noResults: some View {
        VStack(spacing: 6) {
            Text("Sin resultados para “\(searchText.trimmingCharacters(in: .whitespaces))”")
                .font(.subheadline.weight(.medium))
            Text("Prueba con otro nombre: el buscador recorre todos los festivales de la app.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.55))
        }
        .frame(maxWidth: .infinity)
        .multilineTextAlignment(.center)
        .padding(.vertical, 28)
    }

    /// Recordatorio, bajo las 5 destacadas, de que el catálogo es más grande.
    private var searchHint: some View {
        Text("¿No aparece el tuyo? Hay \(series.count) festivales en la app: usa el buscador.")
            .font(.caption)
            .foregroundStyle(.white.opacity(0.45))
            .frame(maxWidth: .infinity)
            .multilineTextAlignment(.center)
            .padding(.top, 4)
    }

    /// Tres cupos gratis dibujados como puntos; con la compra pasa a "Sin límite".
    private var slotIndicator: some View {
        HStack(spacing: 8) {
            if entitlements.hasUnlimitedFollows {
                Label("Sin límite", systemImage: "infinity")
                    .font(.caption.weight(.semibold))
            } else {
                ForEach(0..<FollowStore.freeLimit, id: \.self) { i in
                    Circle()
                        .fill(i < selectedKeys.count ? Color.white : .white.opacity(0.22))
                        .frame(width: 9, height: 9)
                }
                Text("\(selectedKeys.count) de \(FollowStore.freeLimit)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.75))
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.white.opacity(0.10), in: Capsule())
        .animation(.snappy, value: selectedKeys.count)
    }

    private var confirmButton: some View {
        VStack(spacing: 8) {
            if atFreeLimit {
                Button { showPaywall = true } label: {
                    Label("¿Quieres seguir más de \(FollowStore.freeLimit)?", systemImage: "sparkles")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
            Button {
                followStore.setFollowed(selectedKeys)
                onFinished()
            } label: {
                Text(mode == .onboarding ? "Comenzar" : "Guardar")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(
                        selectedKeys.isEmpty
                            ? AnyShapeStyle(.white.opacity(0.15))
                            : AnyShapeStyle(Color(hex: "#5A2CA0").gradient),
                        in: Capsule()
                    )
                    .foregroundStyle(selectedKeys.isEmpty ? .white.opacity(0.4) : .white)
            }
            .disabled(selectedKeys.isEmpty)
        }
        .padding(.horizontal)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .background(.black.opacity(0.35).gradient, ignoresSafeAreaEdges: .bottom)
    }
}

// MARK: - Tarjeta de serie

private struct SeriesCard: View {
    let series: FestivalSeries
    let isSelected: Bool
    /// True cuando ya se llenaron los cupos gratis y esta tarjeta no está
    /// seleccionada: sigue tocable (abre el paywall) pero se marca con candado.
    let isLocked: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(series.accentColor.gradient)
                    Image(systemName: "music.mic")
                        .font(.headline)
                        .foregroundStyle(.white)
                }
                .frame(width: 46, height: 46)
                .opacity(isLocked ? 0.45 : 1)

                VStack(alignment: .leading, spacing: 3) {
                    Text(series.name)
                        .font(.headline)
                        .multilineTextAlignment(.leading)
                    Text(series.statusLabel)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.65))
                    Text("\(series.editions.count) \(series.editions.count == 1 ? "edición" : "ediciones") en la app")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.40))
                }
                .opacity(isLocked ? 0.55 : 1)

                Spacer()

                if isLocked {
                    Image(systemName: "lock.fill")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.45))
                } else {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(isSelected ? series.accentColor : .white.opacity(0.30))
                }
            }
            .padding(14)
            .background(.white.opacity(isSelected ? 0.10 : 0.05),
                        in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(isSelected ? AnyShapeStyle(series.accentColor.gradient)
                                             : AnyShapeStyle(.white.opacity(0.10)),
                                  lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
        .animation(.snappy(duration: 0.25), value: isSelected)
        .accessibilityLabel("\(series.name), \(series.statusLabel)")
        .accessibilityValue(isSelected ? "Siguiendo" : isLocked ? "Requiere pase sin límite" : "No seguido")
    }
}
