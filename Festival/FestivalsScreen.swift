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
    @State private var selectedIndex: Int
    @State private var expandedIndex: Int? = nil
    @State private var zoomArtist: LineupArtist? = nil
    @State private var showNowPlaying = false
    /// ID del festival cuyo botón inició la reproducción actual.
    @State private var activePlayerFestivalID: String? = nil
    /// Día elegido por festival (nil/ausente = todos). Es el parámetro con el que
    /// se arma la fila de reproducción al tocar play.
    @State private var selectedDays: [String: Int] = [:]
    @Namespace private var ns

    init(feed: FestivalFeed) {
        self.feed = feed
        // Arrancar en el festival más próximo a realizarse (o el último si todos pasaron).
        let today = Date()
        let idx = feed.festivals.firstIndex { $0.endDate.addingTimeInterval(86_400) > today }
            ?? max(0, feed.festivals.count - 1)
        _selectedIndex = State(initialValue: idx)
    }

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
                        // Solo la página visible mantiene la física en marcha; los
                        // vecinos del TabView se quedan vivos pero pausados para
                        // no saturar el main thread con dos simulaciones.
                        isVisible: i == safeIndex,
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
                    SharedPlayButton(festival: current, player: player,
                                     activeFestivalID: activePlayerFestivalID,
                                     play: { festival in
                                         activePlayerFestivalID = festival.id
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
                    selectedDay: selectedDays[festival.id],
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
        .onChange(of: player.isActive) { _, active in
            if !active { activePlayerFestivalID = nil }
        }
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
    var isVisible: Bool = true
    @Binding var selectedDay: Int?
    let onExpand: () -> Void

    /// Artistas que la portada simula y dibuja: solo cabezas de cartel y estelares.
    /// Al simular únicamente estos, llenan la silueta sea cual sea el tamaño del
    /// cartel (no quedan dispersos en festivales con pocos destacados). Los demás
    /// se agregan a la misma simulación al expandir, conservando estas posiciones.
    private var posterArtists: [LineupArtist] {
        festival.headlineArtists(onDay: selectedDay)
    }

    /// Cartel completo del día (solo para saber si aún no hay lineup que mostrar).
    private var dayArtists: [LineupArtist] {
        festival.artists(onDay: selectedDay)
    }

    var body: some View {
        VStack(spacing: 12) {
            header
            // Solo si el cartel ya tiene artistas repartidos por jornada. Si el
            // lineup está vacío o aún sin desglose por día, el selector no aporta
            // (serían chips deshabilitados) y se omite.
            if festival.hasDayBreakdown { daySelector }
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
                    artists: posterArtists,
                    physics: physics,
                    accent: festival.accentColor,
                    interactive: false,
                    isActive: !isExpanded && isVisible,
                    // worldScale 1.0: el "mundo" físico = la ventana visible, así las
                    // paredes encierran TODOS los destacados dentro de la silueta y se
                    // ven los ≥10. (Con 1.7 el mundo era mayor y los círculos de orden
                    // exterior quedaban fuera, difuminados, y se veían menos de 10.)
                    worldScale: 1.0,
                    fadesAtEdges: true,
                    onTapBackground: onExpand
                )
                .padding(.horizontal, 28)
                .clipShape(RoundedRectangle(cornerRadius: 34, style: .continuous))

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
        VStack(spacing: 3) {
            Text(festival.name)
                .font(.title2.bold())
                .opacity(festival.isPast ? 0.55 : 1)
            HStack(spacing: 6) {
                Text(festival.dateRangeLabel)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(festival.isPast ? 0.40 : 0.85))
                statusBadge
            }
            Text("\(festival.venue) · \(festival.city)")
                .font(.caption2)
                .foregroundStyle(.white.opacity(festival.isPast ? 0.35 : 0.55))
        }
    }

    @ViewBuilder private var statusBadge: some View {
        if festival.isPast {
            Text("Pasado")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.50))
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(.white.opacity(0.10), in: Capsule())
        } else if festival.isOngoing {
            Text("En curso")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(.green.opacity(0.75), in: Capsule())
        } else if festival.daysUntilStart <= 90 {
            Text("En \(festival.daysUntilStart) día\(festival.daysUntilStart == 1 ? "" : "s")")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(festival.accentColor)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(festival.accentColor.opacity(0.18), in: Capsule())
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
    /// Mismo día que la portada: así la simulación es exactamente la misma que ya
    /// venía corriendo y, al expandir, los círculos conservan su posición (solo se
    /// revelan los no-destacados). Si difiriera, la física se reconstruiría y los
    /// círculos saltarían.
    var selectedDay: Int?
    let onClose: () -> Void
    let onSelect: (LineupArtist) -> Void

    /// Cartel completo del día seleccionado, mismo orden por peso que la portada.
    private var artists: [LineupArtist] {
        festival.artists(onDay: selectedDay)
            .sorted { $0.billingWeight > $1.billingWeight }
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
                        .accessibilityLabel("Cerrar cartel")
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
    var activeFestivalID: String?
    var play: (Festival) -> Void
    var onOpenPlayer: () -> Void = {}

    private var isThisActive: Bool {
        player.isActive && festival.id == activeFestivalID
    }

    var body: some View {
        Group {
            if isThisActive {
                MiniPlayerView(player: player, accent: festival.accentColor,
                               onTap: onOpenPlayer)
            } else if festival.lineup.isEmpty {
                // Sin lineup anunciado: no hay nada que reproducir. Botón apagado y
                // no tappable (es un contenedor estático, no un Button).
                HStack {
                    Image(systemName: "play.slash.fill")
                    Text("No disponible").fontWeight(.semibold).lineLimit(1)
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(.white.opacity(0.12), in: Capsule())
                .foregroundStyle(.white.opacity(0.45))
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Reproducción no disponible")
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
