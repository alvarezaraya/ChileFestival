import SwiftUI
import UIKit

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
    /// True mientras el carrusel muestra el archivo de ediciones pasadas en vez
    /// de los festivales vigentes. Se entra/sale con el pull de los extremos.
    @State private var showsArchive = false
    /// Arrastre acumulado del pull del archivo en curso (0 sin gesto activo).
    @State private var pullOffset: CGFloat = 0
    /// True cuando el pull cruzó el umbral: soltar cambia de modo.
    @State private var pullArmed = false
    /// Alto de la pantalla, para acotar la franja donde vale el pull.
    @State private var pageHeight: CGFloat = 0
    @Namespace private var ns

    init(feed: FestivalFeed, onEditFollows: (() -> Void)? = nil) {
        self.feed = feed
        self.onEditFollows = onEditFollows
        // Arrancar en el festival más próximo a realizarse (o el último
        // vigente si todos los del carrusel principal ya pasaron).
        let today = Date()
        let recent = feed.festivals.filter { !$0.isArchived }
        let visible = recent.isEmpty ? feed.festivals : recent
        let idx = visible.firstIndex { $0.endDate.addingTimeInterval(86_400) > today }
            ?? max(0, visible.count - 1)
        _selectedIndex = State(initialValue: idx)
    }

    // MARK: Archivo de ediciones pasadas

    /// Festivales vigentes: aún no ocurren o terminaron hace menos de una semana.
    private var recentFestivals: [Festival] { feed.festivals.filter { !$0.isArchived } }
    /// Ediciones pasadas (terminaron hace más de una semana), cronológicas.
    private var archivedFestivals: [Festival] { feed.festivals.filter(\.isArchived) }
    /// Solo hay archivo cuando existen ambos grupos: un archivo vacío no
    /// necesita entrada, y si no queda nada vigente el carrusel principal
    /// muestra todo (un archivo sin carrusel al que volver no tendría salida).
    private var hasArchive: Bool { !archivedFestivals.isEmpty && !recentFestivals.isEmpty }
    /// Festivales del modo activo.
    private var displayedFestivals: [Festival] {
        guard hasArchive else { return feed.festivals }
        return showsArchive ? archivedFestivals : recentFestivals
    }

    private var safeIndex: Int { min(max(selectedIndex, 0), displayedFestivals.count - 1) }
    private var current: Festival { displayedFestivals[safeIndex] }
    private var isExpanded: Bool { expandedIndex != nil }

    /// Artistas con los que se genera el mix, según el día seleccionado del
    /// festival visible (ordenados por peso de cartel).
    private func mixArtists(for festival: Festival) -> [LineupArtist] {
        festival.artists(onDay: selectedDays[festival.id])
            .sorted { $0.billingWeight > $1.billingWeight }
    }

    /// Pool del modo descubrimiento: solo intermedios y emergentes del día
    /// seleccionado. Vacío = el botón de descubrimiento se oculta.
    private func discoveryPool(for festival: Festival) -> [LineupArtist] {
        festival.discoveryArtists(onDay: selectedDays[festival.id])
            .sorted { $0.billingWeight > $1.billingWeight }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            background

            // Carrusel de pósters (silueta colapsada) del modo activo. Tirar
            // más allá del extremo (pull tipo pull-to-refresh horizontal)
            // cambia entre los vigentes y el archivo de ediciones pasadas.
            TabView(selection: $selectedIndex) {
                ForEach(Array(displayedFestivals.enumerated()), id: \.element.id) { i, festival in
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
            // El pull convive con el paginado: el rubber-band del extremo sigue
            // siendo el del sistema, aquí solo se mide el arrastre.
            .simultaneousGesture(archivePullGesture)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { pageHeight = $0 }
            // Salidas accesibles del gesto (VoiceOver no puede "tirar del borde").
            .accessibilityAction(named: "Ediciones pasadas") {
                if hasArchive, !showsArchive, !isExpanded { enterArchive() }
            }
            .accessibilityAction(named: "Próximos festivales") {
                if showsArchive, !isExpanded { exitArchive() }
            }
            // Al cambiar de modo el carrusel entero se reemplaza deslizándose:
            // el archivo entra/sale por la izquierda (el pasado vive "antes"
            // del primer festival vigente) y el principal por la derecha.
            .id(showsArchive)
            .transition(.asymmetric(
                insertion: .move(edge: showsArchive ? .leading : .trailing).combined(with: .opacity),
                removal: .move(edge: showsArchive ? .trailing : .leading).combined(with: .opacity)))

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
                                     },
                                     playDiscovery: discoveryPool(for: current).isEmpty ? nil : { festival in
                                         activePlayerFestivalID = festival.id
                                         Task { await player.playMix(for: discoveryPool(for: festival)) }
                                     },
                                     onOpenPlayer: { showNowPlaying = true })
                    if displayedFestivals.count > 1, !isExpanded {
                        PageDotsIndicator(labels: displayedFestivals.map(\.name),
                                          selectedIndex: $selectedIndex)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 28)   // sube el bloque para alejar los dots del
                                        // home indicator y evitar falsos toques
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // Indicador del pull del archivo: emerge del borde con el arrastre,
            // como un pull-to-refresh horizontal.
            if pullProgress > 0, !isExpanded, zoomArtist == nil {
                PullPortalIndicator(toPast: !showsArchive,
                                    progress: pullProgress,
                                    armed: pullArmed,
                                    accent: current.accentColor)
                    .offset(x: showsArchive ? 70 - 82 * pullProgress
                                            : -70 + 82 * pullProgress)
                    .frame(maxWidth: .infinity, maxHeight: .infinity,
                           alignment: showsArchive ? .trailing : .leading)
                    .allowsHitTesting(false)
            }

            // Overlay a pantalla completa (silueta expandida, círculos tappables).
            if let i = expandedIndex, displayedFestivals.indices.contains(i) {
                let festival = displayedFestivals[i]
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
        // Confirmación táctil al armar el pull (cruza el umbral) y al soltar
        // cruzando el portal (en ambos sentidos).
        .sensoryFeedback(.impact(weight: .light), trigger: pullArmed) { _, armed in armed }
        .sensoryFeedback(.impact(weight: .medium), trigger: showsArchive)
        .sheet(isPresented: $showNowPlaying) {
            NowPlayingView(player: player, accent: current.accentColor) {
                showNowPlaying = false
            }
            .presentationDragIndicator(.hidden)
        }
    }

    // MARK: Pull del archivo (tipo pull-to-refresh horizontal)

    /// Puntos de arrastre que arman el portal.
    private static let pullThreshold: CGFloat = 90

    /// Progreso 0…1 del pull en curso (1 = umbral alcanzado).
    private var pullProgress: CGFloat { min(abs(pullOffset) / Self.pullThreshold, 1) }

    /// Pull desde los extremos del carrusel: tirar hacia atrás del primer
    /// festival vigente (o hacia adelante de la última edición archivada) hace
    /// emerger el indicador con el arrastre; cruzado el umbral se arma y al
    /// soltar cambia de modo. No hay página intermedia: el gesto convive con
    /// el rubber-band del sistema como gesto simultáneo del TabView.
    private var archivePullGesture: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                guard hasArchive, !isExpanded, zoomArtist == nil else { return }
                // Fuera de la franja del póster el arrastre no cuenta: arriba
                // el selector de día y abajo los dots tienen scroll/scrub
                // horizontal propio y dispararían falsos pulls.
                let y = value.startLocation.y
                if pageHeight > 0, y < pageHeight * 0.25 || y > pageHeight * 0.85 { return }
                let dx = value.translation.width
                let pulling = showsArchive
                    ? (safeIndex == displayedFestivals.count - 1 && dx < 0)
                    : (safeIndex == 0 && dx > 0)
                pullOffset = pulling ? dx : 0
                pullArmed = abs(pullOffset) >= Self.pullThreshold
            }
            .onEnded { _ in
                let crossed = pullArmed
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    pullOffset = 0
                    pullArmed = false
                }
                guard crossed else { return }
                if showsArchive { exitArchive() } else { enterArchive() }
            }
    }

    /// Cambia al archivo dejando visible la edición pasada más reciente (la
    /// vecina natural del extremo por el que se tiró).
    private func enterArchive() {
        withAnimation(.spring(response: 0.55, dampingFraction: 0.85)) {
            showsArchive = true
            selectedIndex = archivedFestivals.count - 1
        }
    }

    /// Vuelve a los vigentes dejando visible el primero, el vecino natural
    /// del extremo del archivo desde el que se tiró.
    private func exitArchive() {
        withAnimation(.spring(response: 0.55, dampingFraction: 0.85)) {
            showsArchive = false
            selectedIndex = 0
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

}

// MARK: - Indicador del pull del archivo

/// Disco de material translúcido que emerge del borde durante el pull del
/// archivo, como el spinner de un pull-to-refresh pero horizontal: crece y se
/// asoma con el arrastre, el ícono rota con el progreso y, al cruzar el
/// umbral, se "arma" (tinte de acento + etiqueta). Soltar armado cambia de
/// modo; el disparo lo maneja el gesto, esta vista solo dibuja.
private struct PullPortalIndicator: View {
    /// True: emerge del borde izquierdo, hacia las ediciones pasadas.
    /// False: del derecho, de vuelta a los próximos.
    let toPast: Bool
    /// Progreso 0…1 del arrastre (1 = umbral).
    let progress: CGFloat
    /// True cuando soltar ya dispara el cambio de modo.
    let armed: Bool
    /// Color del festival visible, para teñir el estado armado.
    let accent: Color

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle().fill(.ultraThinMaterial)
                Circle().strokeBorder(.white.opacity(0.15), lineWidth: 1)
                Image(systemName: toPast ? "clock.arrow.circlepath" : "arrow.uturn.forward")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(armed ? AnyShapeStyle(accent) : AnyShapeStyle(.white.opacity(0.8)))
                    .rotationEffect(.degrees(Double(progress) * (toPast ? -180 : 180)))
            }
            .frame(width: 54, height: 54)
            .shadow(color: .black.opacity(0.25), radius: 8, y: 4)

            Text(toPast ? "Ediciones pasadas" : "Próximos festivales")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(.ultraThinMaterial, in: Capsule())
                .opacity(armed ? 1 : 0)
        }
        .scaleEffect(0.4 + 0.6 * progress)
        .opacity(Double(progress))
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: armed)
    }
}

// MARK: - Indicador de página

/// Dots de paginado interactivos bajo el botón de reproducir. Además de
/// indicar la posición, un toque salta al festival correspondiente y
/// arrastrar sobre el strip recorre las páginas (scrub). Con más de 5
/// festivales se muestra una ventana deslizante que se detiene en los
/// extremos (siempre llena); el dot de borde se encoge solo del lado donde
/// quedan festivales ocultos, como pista de que hay más.
private struct PageDotsIndicator: View {
    /// Nombres de los festivales, para el valor de VoiceOver.
    let labels: [String]
    @Binding var selectedIndex: Int

    private static let dotSize: CGFloat = 7
    private static let activeWidth: CGFloat = 20   // cápsula del dot actual
    private static let gap: CGFloat = 7
    private static let step = dotSize + gap        // 14 pts por slot
    private static let sideRadius = 2              // dots visibles a cada lado

    /// Índice donde arrancó el scrub en curso (nil sin gesto activo).
    @State private var scrubAnchor: Int? = nil

    private var n: Int { labels.count }
    private var safeIndex: Int { min(max(selectedIndex, 0), n - 1) }
    private var maxVisible: Int { 2 * Self.sideRadius + 1 }
    private var showAll: Bool { n <= maxVisible }

    /// Centro de la ventana visible: sigue al dot activo pero se detiene en
    /// los extremos, así la ventana nunca queda medio vacía.
    private var windowCenter: Int {
        showAll ? safeIndex
                : min(max(safeIndex, Self.sideRadius), n - 1 - Self.sideRadius)
    }

    private var stripWidth: CGFloat {
        CGFloat(n - 1) * Self.step + Self.activeWidth
    }
    private var containerWidth: CGFloat {
        CGFloat((showAll ? n : maxVisible) - 1) * Self.step + Self.activeWidth
    }
    /// Corrimiento que deja el punto medio de la ventana en el centro del
    /// contenedor (el HStack ya viene centrado por el frame).
    private var xOffset: CGFloat {
        guard !showAll else { return 0 }
        let windowMid = CGFloat(windowCenter) * Self.step
            + Self.dotSize / 2 + (Self.activeWidth - Self.dotSize) / 2
        return stripWidth / 2 - windowMid
    }

    var body: some View {
        HStack(spacing: Self.gap) {
            ForEach(0..<n, id: \.self) { i in
                Capsule()
                    .fill(.white.opacity(opacity(for: i)))
                    .frame(width: i == safeIndex ? Self.activeWidth : Self.dotSize,
                           height: Self.dotSize)
                    .scaleEffect(scale(for: i))
            }
        }
        .offset(x: xOffset)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: safeIndex)
        .frame(width: containerWidth, height: Self.dotSize)
        // Área táctil generosa sin mover el layout vecino: el padding entra en
        // el contentShape pero los dots siguen ocupando 7 pts visuales.
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .contentShape(Rectangle())
        .gesture(scrubGesture)
        // Confirmación táctil al cambiar de página (por gesto o por swipe del carrusel).
        .sensoryFeedback(.selection, trigger: safeIndex)
        .accessibilityElement()
        .accessibilityLabel("Festival visible")
        .accessibilityValue("\(labels[safeIndex]), \(safeIndex + 1) de \(n)")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: select(safeIndex + 1)
            case .decrement: select(safeIndex - 1)
            @unknown default: break
            }
        }
    }

    // MARK: Apariencia por dot

    private func opacity(for i: Int) -> Double {
        if i == safeIndex { return 0.95 }
        if showAll { return 0.35 }
        let d = abs(i - windowCenter)
        if d > Self.sideRadius { return 0 }                    // fuera de la ventana
        if d == Self.sideRadius, isTruncated(edgeOf: i) { return 0.30 }
        return 0.40
    }

    private func scale(for i: Int) -> CGFloat {
        guard !showAll else { return 1 }
        let d = abs(i - windowCenter)
        if d > Self.sideRadius { return 0.3 }                  // colapsa al salir
        if d == Self.sideRadius, isTruncated(edgeOf: i) { return 0.6 }
        return 1
    }

    /// True si más allá del dot de borde `i` quedan festivales ocultos.
    private func isTruncated(edgeOf i: Int) -> Bool {
        i < windowCenter ? i > 0 : i < n - 1
    }

    // MARK: Gestos

    /// Arrastrar recorre una página por slot; un toque (sin arrastre) salta al
    /// dot bajo el dedo. Mapeo uniforme por `step`: aproximación suficiente
    /// aunque la cápsula activa sea más ancha.
    private var scrubGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let anchor = scrubAnchor ?? safeIndex
                scrubAnchor = anchor
                let delta = Int((value.translation.width / Self.step).rounded())
                if delta != 0 { select(anchor + delta) }
            }
            .onEnded { value in
                defer { scrubAnchor = nil }
                guard abs(value.translation.width) < Self.step / 2 else { return }
                // location.x viene en el espacio del área táctil (con padding).
                let x = value.location.x - 12
                let delta = ((x - containerWidth / 2) / Self.step).rounded()
                select(windowCenter + Int(delta))
            }
    }

    private func select(_ i: Int) {
        let clamped = min(max(i, 0), n - 1)
        guard clamped != selectedIndex else { return }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            selectedIndex = clamped
        }
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

    /// Abre la página oficial en el navegador (Safari).
    @Environment(\.openURL) private var openURL

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
        VStack(spacing: 5) {
            Text(festival.name)
                .font(.title2.bold())
                .multilineTextAlignment(.center)
                .opacity(festival.isPast ? 0.55 : 1)
            // Metadatos en una sola fila: fecha y estado primero (lo que importa
            // para decidir), recinto · ciudad como dato secundario (es lo único
            // que puede truncarse si la fila no cabe) y el enlace a la página
            // oficial —se abre en Safari— como ícono compacto al final. Las
            // ediciones archivadas no llevan enlace: a esas alturas el sitio ya
            // suele apuntar a la edición siguiente.
            HStack(spacing: 6) {
                Text(festival.dateRangeLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(festival.isPast ? 0.45 : 0.90))
                    .fixedSize()
                statusBadge
                    .fixedSize()
                Text("\(festival.venue) · \(festival.city)")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(festival.isPast ? 0.35 : 0.55))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let website = festival.websiteURL, !festival.isArchived {
                    Button { openURL(website) } label: {
                        Image(systemName: "safari")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.white.opacity(festival.isPast ? 0.50 : 0.85))
                            .padding(5)
                            .background(.white.opacity(0.12), in: Circle())
                    }
                    .accessibilityLabel("Sitio oficial de \(festival.name)")
                    .accessibilityHint("Abre la página del festival en Safari")
                }
            }
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
    /// Borde superior del bloque del buscador en coordenadas globales (lo
    /// publica `bottomSearchBar`; el teclado lo empuja hacia arriba). Con
    /// búsqueda activa, la ventana útil del cúmulo termina ahí.
    @State private var searchBarTop: CGFloat? = nil

    /// Con el buscador enfocado o con texto, el cúmulo cede la franja del
    /// teclado y del campo para que las coincidencias queden a la vista.
    private var searchActive: Bool { searchFieldFocused || !query.isEmpty }

    /// Cartel completo del día seleccionado, mismo orden por peso que la portada.
    private var artists: [LineupArtist] {
        festival.artists(onDay: selectedDay)
            .sorted { $0.billingWeight > $1.billingWeight }
    }

    /// Consulta normalizada del buscador.
    private var query: String { searchText.trimmingCharacters(in: .whitespaces) }

    /// Artistas visibles en el cúmulo: con búsqueda activa quedan solo las
    /// coincidencias (insensible a mayúsculas y tildes); sin búsqueda, el
    /// cartel completo del día seleccionado.
    private var visibleArtists: [LineupArtist] {
        guard !query.isEmpty else { return artists }
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
                artists: visibleArtists,
                physics: physics,
                accent: festival.accentColor,
                interactive: true,
                isActive: true,
                worldScale: 1.6,
                zoomedArtistID: zoomedArtistID,
                // Buscando: las burbujas se repliegan a la franja sobre el
                // buscador (y el teclado, que lo empuja), así ninguna
                // coincidencia queda tapada.
                clearBelowGlobalY: searchActive ? searchBarTop : nil,
                onSelect: onSelect
            )
            // Marco de pantalla COMPLETA (sin safe areas): el zoom a un artista
            // deja su círculo centrado en el centro real de la pantalla (la
            // ventana útil recortada por la búsqueda se maneja adentro, con
            // `clearBelowGlobalY`; el marco no cambia).
            .ignoresSafeArea()

            if zoomedArtistID == nil {
                VStack {
                    VStack(spacing: 0) {
                        HStack {
                            CloseCircleButton(label: "Cerrar cartel", action: onClose)
                            Spacer()
                            Text(festival.name)
                                .font(.headline)
                                .foregroundStyle(.white)
                                .padding(.horizontal, 14).padding(.vertical, 8)
                                .background(.black.opacity(0.25), in: Capsule())
                            Spacer()
                            // Comparte el cartel visible (día filtrado incluido)
                            // como póster. Ocupa el hueco que balanceaba al botón
                            // de cerrar, así el título sigue centrado.
                            ShareCartelLink(festival: festival, day: selectedDay)
                        }
                        .padding(.horizontal)
                        // Mismos filtros por día que la portada, arriba del cartel
                        // expandido. Comparten estado, así ambas vistas quedan en sync.
                        if festival.hasDayBreakdown {
                            DaySelector(festival: festival, selectedDay: $selectedDay)
                                .padding(.horizontal)
                                .padding(.top, 10)
                        }
                    }
                    // Aire extra bajo los chips: el scrim cubre también esta zona,
                    // así el desenfoque muere en fade gradual y no en un corte.
                    .padding(.bottom, 36)
                    // Scrim tras el header (título + filtros de día): los chips
                    // flotan sobre las fotos de las burbujas y sin esto no
                    // contrastan. Sube hasta el borde físico de la pantalla.
                    .background(ProgressiveBlurScrim(edge: .top))
                    Spacer()
                    bottomSearchBar
                        // Zona de fundido sobre la barra: el Spacer la absorbe
                        // (la barra no se mueve, solo crece el área del scrim).
                        .padding(.top, 36)
                        .background(ProgressiveBlurScrim(edge: .bottom))
                }
                .transition(.opacity)
            }
        }
    }

    // MARK: Buscador de artistas (borde inferior)

    /// Pista + campo de búsqueda anclados abajo. Al escribir, el propio cúmulo
    /// se filtra en vivo: las burbujas que no coinciden desaparecen y quedan
    /// solo las coincidencias, tappables como siempre. Enter abre la primera.
    /// El bloque vive dentro de las safe areas, así que el teclado lo empuja
    /// hacia arriba sin tapar el campo.
    private var bottomSearchBar: some View {
        VStack(spacing: 10) {
            if !query.isEmpty {
                Text(matchCountLabel)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(visibleArtists.isEmpty ? 0.6 : 0.8))
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
        // Publica el borde superior del bloque (incluida la píldora de estado):
        // con búsqueda activa, el cúmulo comprime su ventana hasta aquí para
        // que ninguna burbuja quede bajo el buscador ni el teclado, que empuja
        // este bloque —y con él la ventana— hacia arriba.
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.frame(in: .global).minY
        } action: { searchBarTop = $0 }
        .animation(.easeInOut(duration: 0.2), value: visibleArtists)
        .animation(.easeInOut(duration: 0.2), value: searchFieldFocused)
    }

    private var matchCountLabel: String {
        switch visibleArtists.count {
        case 0:  "Sin coincidencias en este cartel"
        case 1:  "1 coincidencia — toca su burbuja o presiona buscar"
        default: "\(visibleArtists.count) coincidencias"
        }
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
                    // Enter abre la primera coincidencia (si hay búsqueda activa).
                    if !query.isEmpty, let first = visibleArtists.first { select(first) }
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

    private func select(_ artist: LineupArtist) {
        // La búsqueda se conserva: al cerrar el artista, el cartel sigue
        // filtrado con la misma consulta (el X del campo la limpia).
        searchFieldFocused = false
        onSelect(artist)
    }
}

// MARK: - Botón de reproducir dinámico (único, compartido)

struct SharedPlayButton: View {
    let festival: Festival
    @ObservedObject var player: FestivalPlayer
    var activeFestivalID: String?
    var play: (Festival) -> Void
    /// Modo descubrimiento: mix solo con los tiers chicos del cartel. `nil`
    /// cuando el cartel (o el día elegido) no tiene artistas por descubrir —
    /// el botón compañero se oculta.
    var playDiscovery: ((Festival) -> Void)? = nil
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
                HStack(spacing: 10) {
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
                    // Modo descubrimiento: mix solo con intermedios y
                    // emergentes (los nombres grandes ya se conocen).
                    if let playDiscovery {
                        Button { playDiscovery(festival) } label: {
                            Image(systemName: "sparkles")
                                .font(.headline)
                                .foregroundStyle(.white)
                                .frame(width: 52, height: 52)
                                .background(.white.opacity(0.14), in: Circle())
                                .overlay(Circle().strokeBorder(
                                    festival.accentColor.opacity(0.7), lineWidth: 1.5))
                        }
                        .accessibilityLabel("Modo descubrimiento")
                        .accessibilityHint("Reproduce solo artistas emergentes e intermedios del cartel")
                    }
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

// MARK: - Scrim de blur progresivo (bokeh)

/// Scrim "bokeh" para los controles que flotan sobre el cúmulo: el desenfoque
/// del fondo crece gradualmente hacia el borde de la pantalla, en vez de solo
/// fundirse en opacidad. No hay blur de radio variable público, así que se
/// apilan varias capas de blur puro con máscaras escalonadas: junto al borde
/// se superponen todas (desenfoque máximo, cada capa desenfoca lo ya
/// compuesto debajo, incluidas las anteriores) y hacia el interior van
/// muriendo una a una hasta ninguna. Un velo oscuro mínimo remata la
/// legibilidad del texto blanco sin apagar los colores.
private struct ProgressiveBlurScrim: View {
    /// Borde contra el que se apoya el scrim (ahí el desenfoque es máximo).
    let edge: VerticalEdge

    /// Fracción del alto (desde el borde) donde termina de desvanecerse cada
    /// capa de blur: la primera cubre todo, las siguientes mueren cada vez
    /// más cerca del borde — eso escalona la intensidad del desenfoque.
    private static let fadeEnds: [CGFloat] = [1.0, 0.65, 0.38]

    var body: some View {
        ZStack {
            ForEach(Self.fadeEnds, id: \.self) { end in
                PureBackdropBlur()
                    .mask(fadeMask(endingAt: end))
            }
            // Velo secundario, solo para asegurar el contraste del texto: el
            // protagonista es el bokeh y los colores deben traslucirse.
            LinearGradient(
                stops: [.init(color: .black.opacity(0.30), location: 0),
                        .init(color: .black.opacity(0.12), location: 0.6),
                        .init(color: .clear, location: 1)],
                startPoint: startPoint, endPoint: endPoint)
        }
        // Cubre hasta el borde físico de la pantalla (notch / home indicator).
        .ignoresSafeArea(edges: edge == .top ? .top : .bottom)
        .allowsHitTesting(false)
    }

    private var startPoint: UnitPoint { edge == .top ? .top : .bottom }
    private var endPoint: UnitPoint { edge == .top ? .bottom : .top }

    /// Máscara opaca junto al borde que se desvanece por completo en `end`
    /// (fracción del alto). El tramo plano inicial mantiene el blur a plena
    /// intensidad detrás de los controles antes de empezar a morir.
    private func fadeMask(endingAt end: CGFloat) -> LinearGradient {
        LinearGradient(
            stops: [.init(color: .black, location: 0),
                    .init(color: .black, location: end * 0.35),
                    .init(color: .clear, location: end)],
            startPoint: startPoint, endPoint: endPoint)
    }
}

/// Desenfoque gaussiano PURO del contenido de fondo. Los materiales del
/// sistema (`.ultraThinMaterial` y compañía) suman al blur un velo blanquecino
/// y desaturación —el look "vidrio esmerilado"— que apaga los colores. Aquí se
/// usa un `UIVisualEffectView` al que se le ocultan las subvistas de tinte y
/// se le dejan solo los filtros de desenfoque del backdrop: quedan los colores
/// del cúmulo desenfocados y traslúcidos, como un fondo fuera de foco (bokeh).
/// Si UIKit cambiara sus internals, degrada con gracia al material completo.
private struct PureBackdropBlur: UIViewRepresentable {
    func makeUIView(context: Context) -> PureBlurEffectView { PureBlurEffectView() }
    func updateUIView(_ uiView: PureBlurEffectView, context: Context) {}
}

private final class PureBlurEffectView: UIVisualEffectView {
    init() { super.init(effect: UIBlurEffect(style: .regular)) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) no implementado") }

    // El efecto arma sus capas al entrar en ventana y puede rearmarlas en
    // layout (p. ej. cambios de trait), así que se poda en ambos puntos.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        stripFrost()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        stripFrost()
    }

    /// Deja solo el desenfoque: oculta toda subvista que no sea el backdrop
    /// (los velos de tinte) y poda del backdrop los filtros que no sean el
    /// blur gaussiano (desaturación, etc.).
    private func stripFrost() {
        for sub in subviews {
            if String(describing: type(of: sub)).contains("BackdropView") {
                sub.layer.filters = sub.layer.filters?.filter {
                    String(describing: $0).lowercased().contains("blur")
                }
            } else {
                sub.alpha = 0
            }
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
