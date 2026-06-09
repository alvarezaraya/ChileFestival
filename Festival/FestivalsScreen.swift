import SwiftUI

// MARK: - Pantalla raíz

/// Paginado horizontal de festivales. Cada página muestra un **póster** (silueta
/// rectangular tipo Apple Invites) que encierra el cúmulo con física. Un único
/// botón de reproducir, compartido por todos los eventos, vive fuera de la
/// silueta y cambia de color / selección musical según el festival visible.
struct FestivalsScreen: View {
    let feed: FestivalFeed

    @StateObject private var player = FestivalPlayer()
    @StateObject private var physicsStore = PhysicsStore()
    @State private var selectedIndex = 0
    @State private var expandedIndex: Int? = nil
    @State private var zoomArtist: LineupArtist? = nil
    @State private var showNowPlaying = false
    /// Día elegido por festival (nil/ausente = todos). Es el parámetro con el que
    /// se arma la fila de reproducción al tocar play.
    @State private var selectedDays: [String: Int] = [:]
    @Namespace private var ns

    private var safeIndex: Int { min(max(selectedIndex, 0), feed.festivals.count - 1) }
    private var current: Festival { feed.festivals[safeIndex] }
    private var isExpanded: Bool { expandedIndex != nil }

    /// Artistas con los que se genera el mix, según el día seleccionado del
    /// festival visible (ordenados por peso de cartel).
    private func mixArtists(for festival: Festival) -> [LineupArtist] {
        festival.artists(onDay: selectedDays[festival.id])
            .sorted { $0.billingWeight > $1.billingWeight }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            background

            // Carrusel de pósters (silueta colapsada).
            TabView(selection: $selectedIndex) {
                ForEach(Array(feed.festivals.enumerated()), id: \.element.id) { i, festival in
                    FestivalPosterPage(
                        festival: festival,
                        physics: physicsStore.model(for: festival.id),
                        namespace: ns,
                        isExpanded: expandedIndex == i,
                        selectedDay: Binding(
                            get: { selectedDays[festival.id] },
                            set: { selectedDays[festival.id] = $0 }
                        ),
                        onExpand: { withAnimation(.spring(response: 0.5, dampingFraction: 0.82)) {
                            expandedIndex = i
                        } }
                    )
                    .tag(i)
                    .opacity(expandedIndex == i ? 0 : 1)   // se oculta al expandir (matchedGeometry)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .disabled(isExpanded)

            // Botón dinámico compartido + indicador de página (fuera de la silueta).
            if zoomArtist == nil {
                VStack(spacing: 10) {
                    SharedPlayButton(festival: current, player: player, play: { festival in
                        Task { await player.playMix(for: mixArtists(for: festival)) }
                    }, onOpenPlayer: { showNowPlaying = true })
                    if feed.festivals.count > 1, !isExpanded { pageDots }
                }
                .padding(.horizontal)
                .padding(.bottom, 28)   // sube el bloque para alejar los dots del
                                        // home indicator y evitar falsos toques
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // Overlay a pantalla completa (silueta expandida, círculos tappables).
            if let i = expandedIndex {
                let festival = feed.festivals[i]
                FullscreenClusterOverlay(
                    festival: festival,
                    physics: physicsStore.model(for: festival.id),
                    namespace: ns,
                    zoomedArtistID: zoomArtist?.id,
                    onClose: { withAnimation(.spring(response: 0.5, dampingFraction: 0.82)) {
                        expandedIndex = nil
                    } },
                    onSelect: { artist in
                        withAnimation(.spring(response: 0.55, dampingFraction: 0.85)) {
                            zoomArtist = artist
                        }
                    }
                )
                .transition(.opacity)
            }

            // Zoom seamless hacia el artista seleccionado.
            if let artist = zoomArtist {
                ArtistZoomView(
                    artist: artist,
                    festivalAccent: current.accentColor,
                    player: player,
                    namespace: ns,
                    onClose: { withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) {
                        zoomArtist = nil
                    } }
                )
                .zIndex(2)
            }
        }
        .background(.black)
        .onDisappear { player.stop() }
        .sheet(isPresented: $showNowPlaying) {
            NowPlayingView(player: player, accent: current.accentColor) {
                showNowPlaying = false
            }
            .presentationDragIndicator(.hidden)
        }
    }

    private var background: some View {
        LinearGradient(colors: [current.accentColor.opacity(0.35), .black],
                       startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
            .animation(.easeInOut(duration: 0.6), value: current.accentColorHex)
    }

    private var pageDots: some View {
        HStack(spacing: 7) {
            ForEach(feed.festivals.indices, id: \.self) { i in
                Circle()
                    .fill(.white.opacity(i == safeIndex ? 0.95 : 0.35))
                    .frame(width: 7, height: 7)
            }
        }
    }
}

// MARK: - Página de póster (silueta colapsada)

struct FestivalPosterPage: View {
    let festival: Festival
    @ObservedObject var physics: ClusterPhysics
    let namespace: Namespace.ID
    let isExpanded: Bool
    @Binding var selectedDay: Int?
    let onExpand: () -> Void

    private var dayArtists: [LineupArtist] {
        festival.artists(onDay: selectedDay)
            .sorted { $0.billingWeight > $1.billingWeight }
    }

    var body: some View {
        VStack(spacing: 12) {
            header
            daySelector
            silhouette
            Spacer(minLength: 96)   // deja sitio al botón compartido flotante
        }
        .padding()
        .foregroundStyle(.white)
    }

    // La silueta rectangular que encierra los círculos (póster Apple Invites):
    // fondo transparente y solo el borde conserva el color del festival.
    private var silhouette: some View {
        ZStack {
            // Marco transparente con borde de color (matchedGeometry de la silueta).
            RoundedRectangle(cornerRadius: 34, style: .continuous)
                .fill(.clear)
                .matchedGeometryEffect(id: "silhouette-\(festival.id)",
                                       in: namespace, isSource: !isExpanded)

            if dayArtists.isEmpty {
                // El lineup aún no fue anunciado: aviso dentro del recuadro.
                VStack(spacing: 12) {
                    Image(systemName: "music.note.list")
                        .font(.system(size: 34))
                        .foregroundStyle(festival.accentColor.opacity(0.8))
                    Text("Lineup próximamente")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text("Los artistas de este festival aún no han sido anunciados.")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.55))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // El cúmulo se inseta en horizontal para dejar pasillos laterales por
                // donde se puede deslizar entre festivales (paginado del TabView).
                PhysicsClusterView(
                    artists: dayArtists,
                    physics: physics,
                    accent: festival.accentColor,
                    interactive: false,
                    isActive: !isExpanded,
                    onTapBackground: onExpand
                )
                .padding(.horizontal, 28)
                .mask {
                    // Degrada hacia todos los bordes para indicar que hay más contenido.
                    ZStack {
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0),
                                .init(color: .white, location: 0.15),
                                .init(color: .white, location: 0.85),
                                .init(color: .clear, location: 1)
                            ],
                            startPoint: .leading, endPoint: .trailing
                        )
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0),
                                .init(color: .white, location: 0.10),
                                .init(color: .white, location: 0.90),
                                .init(color: .clear, location: 1)
                            ],
                            startPoint: .top, endPoint: .bottom
                        )
                        .blendMode(.multiply)
                    }
                    .compositingGroup()
                    .clipShape(RoundedRectangle(cornerRadius: 34, style: .continuous))
                }

                // Pista de que es tocable / expandible.
                VStack {
                    Spacer()
                    Label("Toca para explorar", systemImage: "arrow.up.left.and.arrow.down.right")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(.black.opacity(0.25), in: Capsule())
                        .padding(.bottom, 12)
                }
                .allowsHitTesting(false)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 34, style: .continuous)
                .strokeBorder(festival.accentColor.gradient, lineWidth: 2.5)
        )
        .shadow(color: festival.accentColor.opacity(0.35), radius: 14, y: 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        VStack(spacing: 2) {
            Text(festival.name).font(.title2.bold())
            Text("\(festival.venue) · \(festival.city)")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.7))
        }
    }

    private var daySelector: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Chip(title: "Todos", selected: selectedDay == nil) { selectedDay = nil }
                ForEach(1...max(festival.dayCount, 1), id: \.self) { day in
                    let hasData = festival.lineup.contains { $0.day == day }
                    Chip(title: "Día \(day)", selected: selectedDay == day, disabled: !hasData) {
                        selectedDay = day
                    }
                }
            }
            .padding(.horizontal, 2)
        }
    }
}

// MARK: - Overlay a pantalla completa

struct FullscreenClusterOverlay: View {
    let festival: Festival
    @ObservedObject var physics: ClusterPhysics
    let namespace: Namespace.ID
    var zoomedArtistID: String?
    let onClose: () -> Void
    let onSelect: (LineupArtist) -> Void

    private var artists: [LineupArtist] {
        festival.clusterOrdered
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 0, style: .continuous)
                .fill(LinearGradient(colors: [festival.accentColor.opacity(0.30), .black],
                                     startPoint: .top, endPoint: .bottom))
                .matchedGeometryEffect(id: "silhouette-\(festival.id)",
                                       in: namespace, isSource: true)
                .ignoresSafeArea()

            PhysicsClusterView(
                artists: artists,
                physics: physics,
                accent: festival.accentColor,
                interactive: true,
                isActive: true,
                zoomedArtistID: zoomedArtistID,
                matchNamespace: namespace,
                onSelect: onSelect
            )
            .ignoresSafeArea(edges: .bottom)

            if zoomedArtistID == nil {
                VStack {
                    HStack {
                        Button(action: onClose) {
                            Image(systemName: "xmark")
                                .font(.headline)
                                .foregroundStyle(.white)
                                .padding(12)
                                .background(.black.opacity(0.3), in: Circle())
                        }
                        Spacer()
                        Text(festival.name)
                            .font(.headline)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(.black.opacity(0.25), in: Capsule())
                        Spacer()
                        Color.clear.frame(width: 44, height: 44)
                    }
                    .padding(.horizontal)
                    Spacer()
                    Text("Toca un artista")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white.opacity(0.8))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(.black.opacity(0.25), in: Capsule())
                        .padding(.bottom, 24)
                }
                .transition(.opacity)
            }
        }
    }
}

// MARK: - Botón de reproducir dinámico (único, compartido)

struct SharedPlayButton: View {
    let festival: Festival
    @ObservedObject var player: FestivalPlayer
    var play: (Festival) -> Void
    var onOpenPlayer: () -> Void = {}

    var body: some View {
        Group {
            if player.isActive {
                MiniPlayerView(player: player, accent: festival.accentColor,
                               onTap: onOpenPlayer)
            } else {
                Button { play(festival) } label: {
                    HStack {
                        Image(systemName: "play.fill")
                        Text(idleLabel).fontWeight(.semibold).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(festival.accentColor.gradient, in: Capsule())
                    .foregroundStyle(.white)
                }
            }
        }
        // Cambio de color sutil al pasar de un evento a otro.
        .animation(.easeInOut(duration: 0.5), value: festival.accentColorHex)
        .foregroundStyle(.white)
    }

    private var idleLabel: String {
        switch player.mode {
        case .needsAuthorization: "Autoriza Apple Music"
        case .error(let msg):     msg
        default:                  "Reproducir \(festival.name)"
        }
    }
}

// MARK: - Chip de día

private struct Chip: View {
    let title: String
    let selected: Bool
    var disabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(selected ? .white.opacity(0.9) : .white.opacity(0.15), in: Capsule())
                .foregroundStyle(selected ? .black : .white)
        }
        .opacity(disabled ? 0.30 : 1)
        .disabled(disabled)
    }
}
