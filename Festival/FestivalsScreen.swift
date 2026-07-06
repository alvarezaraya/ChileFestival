import SwiftUI

// MARK: - Pantalla raíz

/// Paginado horizontal de festivales. Cada página muestra un **póster** (silueta
/// rectangular tipo Apple Invites) que encierra el cúmulo con física. Un único
/// botón de reproducir, compartido por todos los eventos, vive fuera de la
/// silueta y cambia de color / selección musical según el festival visible.
struct FestivalsScreen: View {
    let feed: FestivalFeed
    /// Abre la pantalla de selección de festivales seguidos (sheet del RootView).
    var onEditFollows: (() -> Void)? = nil

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

    init(feed: FestivalFeed, onEditFollows: (() -> Void)? = nil) {
        self.feed = feed
        self.onEditFollows = onEditFollows
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

            // Botón flotante para cambiar los festivales seguidos. Solo en la
            // vista de carrusel: al expandir el cartel o abrir un artista estorba.
            if let onEditFollows, !isExpanded, zoomArtist == nil {
                VStack {
                    HStack {
                        Spacer()
                        Button(action: onEditFollows) {
                            Image(systemName: "slider.horizontal.3")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white.opacity(0.85))
                                .padding(10)
                                .background(.white.opacity(0.12), in: Circle())
                        }
                        .accessibilityLabel("Elegir festivales a seguir")
                    }
                    .padding(.horizontal)
                    Spacer()
                }
                .transition(.opacity)
            }

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
                    selectedDay: Binding(
                        get: { selectedDays[festival.id] },
                        set: { selectedDays[festival.id] = $0 }
                    ),
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

            // Página de artista: el círculo lo lleva al centro la cámara del
            // cúmulo (zoom nativo); este overlay solo aporta el contenido.
            if let artist = zoomArtist {
                ArtistZoomView(
                    artist: artist,
                    festivalAccent: current.accentColor,
                    player: player,
                    onClose: closeZoom
                )
                .zIndex(2)
                // La tarjeta entra deslizándose desde abajo, sin fundidos: la
                // parte superior del overlay es transparente, así que lo único
                // que se ve moverse es el contenido subiendo bajo el círculo.
                .transition(.move(edge: .bottom))

                // Cerrar va como hermano del overlay (las transiciones de los
                // hijos no corren al insertarse el padre): se funde aparte y no
                // viaja con la tarjeta.
                closeZoomButton
                    .zIndex(3)
                    .transition(.opacity)
            }
        }
        .background(.black)
        // Confirmación táctil al expandir/colapsar el cartel y al entrar/salir
        // del zoom de artista.
        .sensoryFeedback(.impact(weight: .light), trigger: isExpanded)
        .sensoryFeedback(.selection, trigger: zoomArtist?.id)
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

    private func closeZoom() {
        withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) {
            zoomArtist = nil
        }
    }

    private var closeZoomButton: some View {
        VStack {
            HStack {
                CloseCircleButton(label: "Cerrar", action: closeZoom)
                Spacer()
            }
            .padding(.horizontal)
            Spacer()
        }
    }

    private var background: some View {
        LinearGradient(colors: [current.accentColor.opacity(0.35), .black],
                       startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
            .animation(.easeInOut(duration: 0.6), value: current.accentColorHex)
    }

    private var pageDots: some View {
        let dotSize: CGFloat = 7
        let gap: CGFloat = 7
        let step = dotSize + gap          // 14 pts por slot
        let n = feed.festivals.count
        let sideRadius = 2                // dots visibles a cada lado

        let maxVisible = 2 * sideRadius + 1
        let showAll = n <= maxVisible
        let containerW = showAll
            ? CGFloat(n) * step - gap
            : CGFloat(maxVisible) * step - gap

        // En un ZStack centrado el HStack ya queda centrado; el offset
        // mueve el strip para que dot[safeIndex] quede en el centro del contenedor.
        let hstackW = CGFloat(n) * step - gap
        let xOffset: CGFloat = showAll ? 0
            : hstackW / 2 - CGFloat(safeIndex) * step - dotSize / 2

        return ZStack {
            HStack(spacing: gap) {
                ForEach(feed.festivals.indices, id: \.self) { i in
                    let d = abs(i - safeIndex)
                    Circle()
                        .fill(.white.opacity(
                            showAll
                                ? (i == safeIndex ? 0.95 : 0.35)
                                : (d == 0 ? 0.95 : d == 1 ? 0.60 : d == 2 ? 0.30 : 0.0)
                        ))
                        .frame(width: dotSize, height: dotSize)
                }
            }
            .offset(x: xOffset)
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: safeIndex)
        }
        .frame(width: containerW, height: dotSize)
        // Decorativo: VoiceOver ya pagina el carrusel deslizando en el TabView.
        .accessibilityHidden(true)
        .mask(
            LinearGradient(stops: [
                .init(color: showAll ? .black : .clear, location: 0),
                .init(color: .black,                    location: showAll ? 0 : 0.15),
                .init(color: .black,                    location: showAll ? 1 : 0.85),
                .init(color: showAll ? .black : .clear, location: 1)
            ], startPoint: .leading, endPoint: .trailing)
        )
    }
}

// MARK: - Página de póster (silueta colapsada)

struct FestivalPosterPage: View {
    let festival: Festival
    /// Sin `@ObservedObject`: solo se pasa hacia abajo; observarlo re-renderizaría
    /// la página completa con cada publicación del motor (30/60 Hz).
    let physics: ClusterPhysics
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
                // Despeja el botón flotante de "elegir festivales" (top-trailing).
                .padding(.horizontal, 44)
            // Solo si el cartel ya tiene artistas repartidos por jornada. Si el
            // lineup está vacío o aún sin desglose por día, el selector no aporta
            // (serían chips deshabilitados) y se omite.
            if festival.hasDayBreakdown {
                DaySelector(festival: festival, selectedDay: $selectedDay)
            }
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
                    // paredes encierran los (hasta) 10 destacados dentro de la silueta.
                    // (Con 1.7 el mundo era mayor y los círculos de orden exterior
                    // quedaban fuera, difuminados, y se veían menos.)
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
                .multilineTextAlignment(.center)
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
        } else {
            Text("En \(festival.daysUntilStart) día\(festival.daysUntilStart == 1 ? "" : "s")")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(festival.accentColor)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(festival.accentColor.opacity(0.18), in: Capsule())
        }
    }

}

// MARK: - Overlay a pantalla completa

struct FullscreenClusterOverlay: View {
    let festival: Festival
    /// Sin `@ObservedObject`: solo se pasa hacia abajo; observarlo re-renderizaría
    /// el overlay completo con cada publicación del motor (60 Hz).
    let physics: ClusterPhysics
    let namespace: Namespace.ID
    var zoomedArtistID: String?
    /// Binding al MISMO estado que la portada: al expandir, la simulación es la
    /// que ya venía corriendo y los círculos conservan su posición (solo se
    /// revelan los no-destacados). Cambiar el día aquí reconstruye el cúmulo y
    /// deja a la portada en sync, así el colapso tampoco salta.
    @Binding var selectedDay: Int?
    let onClose: () -> Void
    let onSelect: (LineupArtist) -> Void

    @State private var searchText = ""
    @FocusState private var searchFieldFocused: Bool

    /// Cartel completo del día seleccionado, mismo orden por peso que la portada.
    private var artists: [LineupArtist] {
        festival.artists(onDay: selectedDay)
            .sorted { $0.billingWeight > $1.billingWeight }
    }

    /// Coincidencias dentro del cartel visible (respeta el día seleccionado),
    /// insensible a mayúsculas y tildes.
    private var searchResults: [LineupArtist] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        return artists.filter { $0.name.localizedStandardContains(query) }
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
                worldScale: 1.6,
                zoomedArtistID: zoomedArtistID,
                onSelect: onSelect
            )
            // Marco de pantalla COMPLETA (sin safe areas): así el centro de la
            // ventana del cúmulo es el centro real de la pantalla y el zoom a un
            // artista deja su círculo exactamente centrado.
            .ignoresSafeArea()

            if zoomedArtistID == nil {
                VStack {
                    HStack {
                        CloseCircleButton(label: "Cerrar cartel", action: onClose)
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
                    // Mismos filtros por día que la portada, arriba del cartel
                    // expandido. Comparten estado, así ambas vistas quedan en sync.
                    if festival.hasDayBreakdown {
                        DaySelector(festival: festival, selectedDay: $selectedDay)
                            .padding(.horizontal)
                            .padding(.top, 10)
                    }
                    Spacer()
                    bottomSearchBar
                }
                .transition(.opacity)
            }
        }
    }

    // MARK: Buscador de artistas (borde inferior)

    /// Pista + campo de búsqueda anclados abajo. Al escribir, las coincidencias
    /// aparecen sobre el campo; tocar una abre al artista con el mismo zoom que
    /// tocar su burbuja. El bloque vive dentro de las safe areas, así que el
    /// teclado lo empuja hacia arriba sin tapar los resultados.
    private var bottomSearchBar: some View {
        VStack(spacing: 10) {
            if !searchResults.isEmpty {
                searchResultsList
            } else if !searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                Text("Sin coincidencias en este cartel")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.black.opacity(0.25), in: Capsule())
            } else if !searchFieldFocused {
                Text("Toca un artista")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.black.opacity(0.25), in: Capsule())
            }
            searchField
        }
        .padding(.horizontal)
        .padding(.bottom, 12)
        .animation(.easeInOut(duration: 0.2), value: searchResults)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.white.opacity(0.55))
            TextField("", text: $searchText,
                      prompt: Text("Buscar artista").foregroundStyle(.white.opacity(0.45)))
                .focused($searchFieldFocused)
                .foregroundStyle(.white)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .onSubmit {
                    // Enter abre la primera coincidencia (si la hay).
                    if let first = searchResults.first { select(first) }
                }
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.white.opacity(0.55))
                }
                .accessibilityLabel("Borrar búsqueda")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .background(.black.opacity(0.35), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.15), lineWidth: 1))
    }

    /// Hasta 5 coincidencias en un panel compacto; con más, se invita a seguir
    /// escribiendo (evita un ScrollView que acapararía altura fija).
    private var searchResultsList: some View {
        VStack(spacing: 0) {
            ForEach(searchResults.prefix(5)) { artist in
                Button { select(artist) } label: {
                    HStack {
                        Text(artist.name)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.45))
                    }
                    .padding(.horizontal, 16).padding(.vertical, 11)
                    .contentShape(Rectangle())
                }
                if artist.id != searchResults.prefix(5).last?.id {
                    Divider().overlay(.white.opacity(0.12))
                }
            }
            if searchResults.count > 5 {
                Text("y \(searchResults.count - 5) más — sigue escribiendo")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.vertical, 7)
            }
        }
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        )
    }

    private func select(_ artist: LineupArtist) {
        searchFieldFocused = false
        searchText = ""
        onSelect(artist)
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

// MARK: - Botón circular de cerrar (compartido)

/// Xmark sobre un círculo translúcido: lo usan el zoom de artista y el header
/// del cartel expandido.
private struct CloseCircleButton: View {
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.headline)
                .foregroundStyle(.white)
                .padding(12)
                .background(.black.opacity(0.3), in: Circle())
        }
        .accessibilityLabel(label)
    }
}

// MARK: - Selector de día (compartido)

/// Fila de chips "Todos / Día N". La usan la portada y el cartel expandido,
/// enlazados al mismo día seleccionado por festival.
private struct DaySelector: View {
    let festival: Festival
    @Binding var selectedDay: Int?

    var body: some View {
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
