import SwiftUI
import UIKit
import ImageIO

// MARK: - Layout compartido del zoom

/// Diámetro del círculo del artista en zoom para una altura de ventana dada.
/// Lo usan la cámara del cúmulo (`zoomTransform`), la resolución de imagen de
/// la burbuja y el hueco del overlay del detalle (`ArtistZoomView`): los tres
/// deben coincidir o el círculo zoomeado no calza con el hueco.
func heroCircleDiameter(forHeight height: CGFloat) -> CGFloat {
    min(240, height * 0.32)
}

// MARK: - Vista del cúmulo con física

/// Renderiza los círculos sobre una simulación de gravedad. Sirve en dos modos:
///
/// - `interactive == false` (silueta colapsada): un toque en cualquier parte
///   expande la vista; los círculos son inertes al tacto.
/// - `interactive == true` (pantalla completa): cada círculo es tappable de forma
///   individual (abre el artista).
///
/// El estepeo lo dispara un `TimelineView(.animation)`. La instancia de
/// `ClusterPhysics` se comparte con la silueta para mantener continuidad.
struct PhysicsClusterView: View {
    let artists: [LineupArtist]
    /// Sin `@ObservedObject` a propósito: este body no lee `bodies` de forma
    /// reactiva (solo lo consulta `zoomTransform` cuando cambia el parámetro de
    /// zoom, con la física pausada). Observa únicamente `ClusterWorld`, así las
    /// publicaciones del motor no re-evalúan el GeometryReader ni los gestos.
    let physics: ClusterPhysics
    let accent: Color
    let interactive: Bool

    /// Solo la vista activa estepea la simulación. Como la silueta y el overlay a
    /// pantalla completa comparten el mismo `ClusterPhysics` (con marcos distintos),
    /// pausar la inactiva evita que ambas reescalen los cuerpos en cada frame.
    var isActive: Bool = true

    /// Factor del "mundo" físico respecto a la ventana visible. Con `> 1` los
    /// círculos se reparten en un espacio mayor que el marco recortado por la
    /// silueta; el contenido se centra y desborda, así solo se ve la parte central.
    var worldScale: CGFloat = 1

    /// Cuando es `true`, los círculos se difuminan (opacidad + desenfoque) de forma
    /// gradual a medida que se acercan al límite de la ventana visible.
    var fadesAtEdges: Bool = false

    /// Cuando se hace zoom a un artista: el mundo entero se acerca hacia su
    /// círculo (zoom proximal, ver `zoomTransform`) hasta dejarlo centrado al
    /// tamaño del detalle, y el resto se atenúa. Es un zoom NATIVO: el propio
    /// círculo del cúmulo es el círculo de la página de artista — no hay una
    /// segunda vista ni fundidos. El overlay del detalle solo aporta contenido.
    var zoomedArtistID: String? = nil

    var onTapBackground: () -> Void = {}
    var onSelect: (LineupArtist) -> Void = { _ in }

    @State private var boundsSize: CGSize = .zero

    /// Desplazamiento acumulado del mundo respecto al centro (pan). Solo se usa en
    /// modo interactivo: arrastrando se recorre el mundo, que es mayor que la
    /// ventana visible (`worldScale > 1`). La traslación del arrastre EN CURSO no
    /// vive aquí sino en `PanLayer`: así cada tick del gesto solo re-evalúa ese
    /// wrapper mínimo (un `.offset`) y no este GeometryReader completo.
    @State private var panOffset: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            // El "mundo" físico puede ser mayor que la ventana visible: el contenido
            // se centra y desborda, de modo que la silueta (clip del padre) solo deja
            // ver la parte central.
            let world = CGSize(width: geo.size.width * worldScale,
                               height: geo.size.height * worldScale)
            // Margen máximo de pan en cada eje: la mitad del desborde del mundo.
            let panLimit = CGSize(width: max(0, (world.width - geo.size.width) / 2),
                                  height: max(0, (world.height - geo.size.height) / 2))
            // Pan acumulado, recortado al límite. No incluye el arrastre en curso
            // (eso es un delta visual dentro de PanLayer); al tocar un artista no
            // puede haber arrastre activo, así que el zoom siempre lo ve completo.
            let offset = panOffset.clamped(to: panLimit)
            let zoom = zoomTransform(world: world, visible: geo.size, pan: offset)
            ZStack {
                // Capa de fondo para expandir: mide SOLO la ventana visible
                // (`geo.size`), no el mundo desbordado. Si viviera dentro del marco
                // del mundo (1.7×, posicionado), su zona de toque se saldría de la
                // silueta —el clip del padre recorta el dibujo pero no el
                // hit-testing— y robaría los toques del selector de día vecino.
                // En la silueta las burbujas son inertes, así que el toque cae aquí.
                if !interactive {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { onTapBackground() }
                        .accessibilityElement()
                        .accessibilityAddTraits(.isButton)
                        .accessibilityLabel("Explorar cartel")
                }

                // Mundo físico: desborda la ventana y el padre lo recorta. Sus
                // burbujas y el motor no captan toques en la silueta, por lo que
                // este subárbol no intercepta nada fuera de la ventana visible.
                // Va en una subvista Equatable: durante el pan (que re-evalúa
                // este body en cada frame del gesto) SwiftUI se salta el subárbol
                // entero —solo se mueve el contenedor— y las burbujas únicamente
                // se re-evalúan cuando la física publica posiciones nuevas.
                // Pan: en la vista expandida, arrastrar recorre el mundo (mayor
                // que la ventana). PanLayer aísla el gesto: durante el arrastre
                // solo se actualiza su `.offset` (el subárbol es un valor estable
                // que SwiftUI no reconstruye), como mover la capa de un scroll.
                PanLayer(
                    enabled: interactive && worldScale > 1,
                    basePan: panOffset,
                    limit: panLimit,
                    onEnd: { translation in
                        panOffset = CGSize(width: panOffset.width + translation.width,
                                           height: panOffset.height + translation.height)
                            .clamped(to: panLimit)
                    }
                ) {
                    ClusterWorld(
                        physics: physics,
                        accent: accent,
                        interactive: interactive,
                        isActive: isActive,
                        zoomedArtistID: zoomedArtistID,
                        visible: geo.size,
                        fadesAtEdges: fadesAtEdges,
                        onTapBackground: onTapBackground,
                        onSelect: onSelect
                    )
                    .equatable()
                    // Marco del mundo, centrado sobre la ventana visible (desborda
                    // y se recorta).
                    .frame(width: world.width, height: world.height)
                    .position(x: geo.size.width / 2 + offset.width,
                              y: geo.size.height / 2 + offset.height)
                }
                // Zoom proximal: acerca el mundo entero hacia el círculo tocado
                // y lo deja centrado, en la misma transacción que el héroe.
                .scaleEffect(zoom?.scale ?? 1, anchor: zoom?.anchor ?? .center)
                .offset(zoom?.offset ?? .zero)
            }
            .onAppear {
                boundsSize = world
                if isActive { physics.configure(artists: artists, size: world) }
            }
            .onChange(of: geo.size) { _, _ in
                boundsSize = world
                if isActive { physics.configure(artists: artists, size: world) }
            }
            // Cambiar el día (u otro filtro) reconstruye el cúmulo.
            .onChange(of: artists.map(\.id)) { _, _ in
                if isActive { physics.configure(artists: artists, size: boundsSize) }
            }
            // Al reactivarse (p. ej. al colapsar), readapta los cuerpos a su marco.
            .onChange(of: isActive) { _, active in
                if active {
                    physics.configure(artists: artists, size: boundsSize)
                }
            }
        }
    }

    /// Zoom proximal hacia el círculo seleccionado: UNA transformación —escala
    /// anclada en el círculo + traslación que lo lleva al centro de la ventana—
    /// que acerca todo el mundo hacia él. La escala deja la burbuja exactamente
    /// al tamaño del círculo de la página de artista; el overlay del detalle
    /// (transparente arriba) la deja ver centrada detrás.
    private func zoomTransform(world: CGSize, visible: CGSize, pan: CGSize)
        -> (scale: CGFloat, anchor: UnitPoint, offset: CGSize)? {
        guard interactive, let id = zoomedArtistID,
              let body = physics.bodies.first(where: { $0.id == id }),
              world.width > 0, world.height > 0 else { return nil }
        // Posición del círculo en la ventana visible (mundo centrado + pan).
        let screen = CGPoint(
            x: body.position.x - (world.width - visible.width) / 2 + pan.width,
            y: body.position.y - (world.height - visible.height) / 2 + pan.height)
        // Mismo tamaño que el círculo de ArtistZoomView.
        let heroSize = heroCircleDiameter(forHeight: visible.height)
        // OJO con el ancla: `.position` envuelve el mundo en un marco del tamaño
        // de la VENTANA visible, y `scaleEffect` (aplicado después) ancla sobre
        // ese marco. Por eso el UnitPoint es la posición del círculo EN PANTALLA
        // dividida por la ventana, no su posición dentro del mundo: la escala
        // deja el círculo quieto y el offset lo lleva exacto al centro, esté
        // donde esté (incluidos bordes y esquinas, incluso con pan).
        return (scale: heroSize / max(body.radius * 2, 1),
                anchor: UnitPoint(x: screen.x / visible.width,
                                  y: screen.y / visible.height),
                offset: CGSize(width: visible.width / 2 - screen.x,
                               height: visible.height / 2 - screen.y))
    }

}

// MARK: - Capa de pan (gesto aislado)

/// Aísla el gesto de pan del resto de la jerarquía: durante el arrastre solo
/// este wrapper se re-evalúa —su `content` es un valor estable que SwiftUI no
/// reconstruye— y el único cambio por frame es un `.offset`, equivalente a
/// mover la capa de un scroll view. Sin esto, cada tick del gesto re-evaluaba
/// el GeometryReader completo del cúmulo (transformaciones, onChange, etc.),
/// lo que en carteles grandes tiraba frames del arrastre.
private extension CGSize {
    /// Recorta el offset al rectángulo `[-limit, limit]` en cada eje.
    func clamped(to limit: CGSize) -> CGSize {
        CGSize(width: min(max(width, -limit.width), limit.width),
               height: min(max(height, -limit.height), limit.height))
    }
}

private struct PanLayer<Content: View>: View {
    let enabled: Bool
    /// Pan ya acumulado, aplicado por el padre vía `.position`. Aquí solo se usa
    /// para que el recorte a los límites también rija durante el arrastre.
    let basePan: CGSize
    let limit: CGSize
    /// Al soltar: el padre fusiona la traslación en su `panOffset` (única
    /// re-evaluación del árbol completo por gesto).
    let onEnd: (CGSize) -> Void
    @ViewBuilder let content: Content

    /// Traslación del arrastre en curso (se limpia sola al soltar).
    @GestureState private var liveDrag: CGSize = .zero

    var body: some View {
        // Delta visual en vivo: el total recortado menos lo que el padre ya
        // aplicó. En reposo es .zero y el wrapper es transparente.
        let base = basePan.clamped(to: limit)
        let clamped = CGSize(width: basePan.width + liveDrag.width,
                             height: basePan.height + liveDrag.height)
            .clamped(to: limit)
        content
            .offset(x: clamped.width - base.width, y: clamped.height - base.height)
            // `minimumDistance: 10` deja pasar los toques a las burbujas
            // (seleccionar artista): un tap simple no inicia el pan.
            .gesture(enabled ? panGesture : nil)
    }

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 10)
            .updating($liveDrag) { value, state, _ in
                state = value.translation
            }
            .onEnded { value in
                onEnd(value.translation)
            }
    }
}

// MARK: - Mundo del cúmulo (burbujas + motor)

/// Subárbol de burbujas + motor de la simulación. Es `Equatable` a propósito:
/// el pan del padre re-evalúa su body en cada frame del gesto, y esta igualdad
/// permite a SwiftUI saltarse las burbujas por completo (solo se mueve el
/// contenedor). El subárbol se re-evalúa únicamente cuando la física publica
/// (`@Published bodies` invalida esta vista directamente) o cambia un parámetro.
private struct ClusterWorld: View, Equatable {
    @ObservedObject var physics: ClusterPhysics
    let accent: Color
    let interactive: Bool
    let isActive: Bool
    let zoomedArtistID: String?
    let visible: CGSize
    let fadesAtEdges: Bool
    let onTapBackground: () -> Void
    let onSelect: (LineupArtist) -> Void

    @State private var lastTick: Date?

    // Igualdad sin los closures (estables en la práctica): compara la identidad
    // del motor y los parámetros visuales que afectan al render.
    static func == (lhs: ClusterWorld, rhs: ClusterWorld) -> Bool {
        lhs.physics === rhs.physics
            && lhs.accent == rhs.accent
            && lhs.interactive == rhs.interactive
            && lhs.isActive == rhs.isActive
            && lhs.zoomedArtistID == rhs.zoomedArtistID
            && lhs.visible == rhs.visible
            && lhs.fadesAtEdges == rhs.fadesAtEdges
    }

    var body: some View {
        ZStack {
            bubbles
                // Con un artista en zoom las burbujas no captan toques:
                // los gestos son del overlay del detalle (scroll/cerrar).
                .allowsHitTesting(zoomedArtistID == nil)
                .modifier(EdgeFadeMask(visible: visible, enabled: fadesAtEdges))
                .modifier(FlattenCluster(enabled: !interactive))

            // Motor: avanza la simulación a ~60 Hz. La silueta iba a 30 Hz de
            // cuando las páginas vecinas del TabView estepeaban a la vez; hoy
            // solo la página visible está activa (`isVisible` en
            // FestivalsScreen), así que puede ir a tasa completa — a 30 Hz las
            // burbujas se movían a saltos visibles. Publicar a 120 Hz no aporta
            // (la deriva de las burbujas es lenta) y duplica el trabajo del
            // main thread; los gestos y springs de SwiftUI sí corren a la tasa
            // del display (60/120 con ProMotion). Si un paso no alcanza, se
            // descarta (`stepInFlight`). Durante el zoom a un artista se pausa:
            // el fondo queda congelado y el ancla del zoom no se mueve bajo la
            // animación.
            TimelineView(.animation(minimumInterval: 1.0 / 60.0,
                                    paused: !isActive || zoomedArtistID != nil)) { tl in
                Color.clear
                    .onChange(of: tl.date) { _, date in
                        let dt = lastTick.map { CGFloat(date.timeIntervalSince($0)) } ?? 0
                        lastTick = date
                        if isActive && zoomedArtistID == nil { physics.step(dt) }
                    }
            }
            .allowsHitTesting(false)
        }
        // Al reanudarse (reactivarse o cerrar el zoom) descarta el tick previo
        // para no dar un paso gigante con el tiempo en pausa acumulado.
        .onChange(of: isActive) { _, active in
            if active { lastTick = nil }
        }
        .onChange(of: zoomedArtistID) { _, id in
            if id == nil { lastTick = nil }
        }
    }

    /// Renderiza las burbujas como un solo subárbol para poder aplicarles una
    /// máscara y aplanado únicos (más barato que modificadores por burbuja).
    @ViewBuilder private var bubbles: some View {
        ZStack {
            ForEach(physics.bodies) { body in
                TappableBubble(
                    physicsBody: body,
                    accent: accent,
                    interactive: interactive,
                    isZoomSource: zoomedArtistID == body.id,
                    dimmed: zoomedArtistID != nil && zoomedArtistID != body.id,
                    // Tamaño final del círculo en zoom: pide la imagen a esa
                    // resolución para que no se vea borrosa al agrandarse.
                    zoomDiameter: zoomedArtistID == body.id
                        ? heroCircleDiameter(forHeight: visible.height) : nil,
                    onTapBackground: onTapBackground,
                    onSelect: onSelect
                )
                // El círculo en zoom viaja por encima de sus vecinos.
                .zIndex(zoomedArtistID == body.id ? 1 : 0)
                .transition(.scale.combined(with: .opacity))
            }
        }
        // Cambiar el filtro (búsqueda o día) inserta y quita burbujas: animar
        // sobre los ids hace que se fundan/escalen en vez de saltar de golpe,
        // y como el value son los ids —no las posiciones— los ticks de la
        // física a 60 Hz no disparan animación alguna.
        .animation(.spring(response: 0.35, dampingFraction: 0.85),
                   value: physics.bodies.map(\.id))
    }
}

/// Una sola máscara para todo el cúmulo: un rectángulo redondeado desenfocado
/// centrado en la ventana visible. Sustituye al `.blur` dinámico por burbuja,
/// que recalculaba un pase offscreen por burbuja en cada frame (causaba stutter).
private struct EdgeFadeMask: ViewModifier {
    let visible: CGSize
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.mask(
                RoundedRectangle(cornerRadius: 60, style: .continuous)
                    .frame(width: visible.width * 0.92,
                           height: visible.height * 0.92)
                    .blur(radius: 22)
            )
        } else {
            content
        }
    }
}

/// Aplana el cúmulo en una sola textura Metal (`drawingGroup`) para que las
/// sombras y demás composición offscreen de cada burbuja se resuelvan una sola
/// vez por frame, en lugar de N veces. Solo se aplica a la silueta: el overlay
/// interactivo hace el zoom de cámara (scaleEffect grande) y aplanarlo lo
/// rasterizaría a 1× — el círculo agrandado se vería borroso.
private struct FlattenCluster: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.drawingGroup(opaque: false)
        } else {
            content
        }
    }
}

// MARK: - Burbuja (solo tap, sin arrastre)

private struct TappableBubble: View {
    let physicsBody: PhysicsBody
    let accent: Color
    let interactive: Bool
    let isZoomSource: Bool
    let dimmed: Bool
    /// Diámetro final (en puntos) cuando este artista está en zoom: la burbuja
    /// pide su imagen a esa resolución y oculta nombre/degradado.
    let zoomDiameter: CGFloat?
    let onTapBackground: () -> Void
    let onSelect: (LineupArtist) -> Void

    var body: some View {
        // La burbuja es el ÚNICO círculo del artista: durante el zoom no se
        // sustituye ni se duplica; la cámara del cúmulo la lleva al centro.
        ArtistBubble(artist: physicsBody.artist, radius: physicsBody.radius,
                     accent: accent, plain: isZoomSource, imagePoints: zoomDiameter)
            .equatable()
            .frame(width: physicsBody.radius * 2, height: physicsBody.radius * 2)
            // Sin .animation propia: la atenuación viaja en la misma transacción
            // (spring de onSelect) que el zoom proximal, como una sola animación.
            .opacity(dimmed ? 0.22 : 1)
            .position(physicsBody.position)
            .onTapGesture { onSelect(physicsBody.artist) }
            // En la portada (silueta) las burbujas son inertes al tacto: así
            // cualquier toque/deslizamiento atraviesa hasta el TabView (deslizar
            // entre festivales) o hasta la capa de fondo (expandir). Solo en la
            // vista expandida capturan toques (seleccionar artista).
            .allowsHitTesting(interactive)
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(physicsBody.artist.name)
            .accessibilityHint(interactive ? "Ver artista" : "Explorar cartel")
            .accessibilityAction {
                if interactive { onSelect(physicsBody.artist) } else { onTapBackground() }
            }
    }
}

// MARK: - Burbuja de artista (contenido visual)

struct ArtistBubble: View, Equatable {
    let artist: LineupArtist
    let radius: CGFloat
    let accent: Color
    /// En zoom: oculta nombre/degradado (la página muestra el título aparte) en
    /// la misma transacción de animación que el resto del zoom.
    var plain: Bool = false
    /// Tamaño en puntos al que pedir la imagen cuando supera al diámetro (el
    /// círculo en zoom se agranda; sin esto la foto se vería borrosa).
    var imagePoints: CGFloat? = nil

    /// Foto oficial del catálogo de Apple Music, resuelta en vivo (nil mientras
    /// llega, si no hay autorización o si el artista no tiene id de catálogo).
    @State private var liveArtworkURL: URL?

    private var diameter: CGFloat { radius * 2 }

    /// La foto en vivo manda; la del feed es el respaldo (offline, sin
    /// autorización de Apple Music o artista sin id resuelto).
    private var imageURL: URL? { liveArtworkURL ?? artist.imageURL }

    // Igualdad por contenido visual: permite a SwiftUI saltarse el re-render
    // (incluido el Canvas del nombre) mientras la física solo cambia la posición.
    static func == (lhs: ArtistBubble, rhs: ArtistBubble) -> Bool {
        lhs.artist.id == rhs.artist.id && lhs.radius == rhs.radius && lhs.accent == rhs.accent
            && lhs.plain == rhs.plain && lhs.imagePoints == rhs.imagePoints
    }

    var body: some View {
        ZStack {
            Circle().fill((artist.accentColor ?? accent).gradient)

            if let url = imageURL {
                // La foto del artista es el contenido: llena el círculo. Se decodifica
                // a tamaño y se cachea, así no satura el hilo principal con 56 PNG.
                CachedArtworkImage(url: url, pointSize: max(diameter, imagePoints ?? 0)) {
                    initialsLabel   // placeholder mientras carga / si falla
                }
                .clipShape(Circle())

                // Degradado inferior para legibilidad del nombre sobre la foto.
                Circle().fill(
                    LinearGradient(colors: [.clear, .clear, .black.opacity(0.6)],
                                   startPoint: .top, endPoint: .bottom))
                    .opacity(plain ? 0 : 1)

                // Nombre curvado siguiendo la curvatura inferior del círculo.
                CurvedBottomText(text: artist.name, radius: radius)
                    .frame(width: diameter, height: diameter)
                    .opacity(plain ? 0 : 1)
            } else {
                centeredLabel
            }
        }
        .frame(width: diameter, height: diameter)
        .overlay(Circle().stroke(.white.opacity(0.25), lineWidth: 1))
        // Resuelve la foto del catálogo al aparecer. Las burbujas del mismo
        // render se agrupan en una sola consulta (ver LiveArtistArtwork).
        // Mientras tanto (o si devuelve nil) se ve la del feed: el cambio, si
        // lo hay, suele ser imperceptible porque ambas vienen de Apple.
        .task(id: artist.id) { liveArtworkURL = await LiveArtistArtwork.url(for: artist) }
    }

    private var showsFullName: Bool { radius >= 40 }
    private var label: String { showsFullName ? artist.name : initials }

    private var centeredLabel: some View {
        Text(label)
            .font(.system(size: max(9, radius * 0.28), weight: .semibold))
            .multilineTextAlignment(.center)
            .minimumScaleFactor(0.6)
            .lineLimit(2)
            .foregroundStyle(.white)
            .padding(4)
    }

    private var initialsLabel: some View {
        Text(initials)
            .font(.system(size: max(10, radius * 0.5), weight: .bold))
            .foregroundStyle(.white.opacity(0.9))
    }

    private var initials: String {
        artist.name
            .split(separator: " ").prefix(2)
            .compactMap { $0.first }
            .map(String.init).joined().uppercased()
    }
}

// MARK: - Imagen cacheada y reducida (para el cúmulo)

/// Carga una foto remota una sola vez, la decodifica **fuera del hilo principal**
/// y al tamaño en píxeles del círculo, y la cachea en memoria. Sustituye a
/// `AsyncImage` en el cúmulo: con decenas de círculos, decodificar PNG de 600px
/// en el hilo principal saturaba la UI (la app "se pegaba" y la foto no aparecía).
struct CachedArtworkImage<Placeholder: View>: View {
    let url: URL
    /// Tamaño en puntos del círculo; se multiplica por la escala de pantalla
    /// (`displayScale`) para decodificar a la resolución física exacta.
    let pointSize: CGFloat
    @ViewBuilder var placeholder: () -> Placeholder

    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                placeholder()
            }
        }
        // El id incluye el tamaño: si el círculo crece (zoom), vuelve a pedir la
        // imagen a la nueva resolución. Mientras tanto sigue mostrando la actual.
        .task(id: "\(url.absoluteString)#\(Int(pointSize.rounded()))") {
            if let loaded = await ArtworkImageCache.shared.image(
                for: url, maxPixel: pointSize * displayScale) {
                image = loaded
            }
        }
    }
}

/// Caché compartida de imágenes decodificadas + deduplicación de descargas.
actor ArtworkImageCache {
    static let shared = ArtworkImageCache()

    private let cache = NSCache<NSURL, UIImage>()
    private var inFlight: [String: Task<UIImage?, Never>] = [:]
    /// Resolución nativa conocida por URL: cuando una descarga devuelve menos
    /// píxeles de los pedidos es que la fuente no da para más. Sin esto, cada
    /// petición mayor que la fuente fallaría el check de resolución y volvería
    /// a descargar + decodificar la misma imagen para siempre.
    private var nativePixel: [URL: CGFloat] = [:]

    func image(for url: URL, maxPixel: CGFloat) async -> UIImage? {
        let px = max(64, maxPixel)
        // Sirve la cacheada si su resolución alcanza para este tamaño —si se
        // pide más grande (el círculo en zoom), re-decodifica; la descarga suele
        // venir de URLCache, así que el upgrade es casi instantáneo— o si ya es
        // todo lo que la fuente puede dar.
        if let hit = cache.object(forKey: url as NSURL) {
            let hitPx = pixelSize(of: hit)
            if hitPx >= px - 1 { return hit }
            if let native = nativePixel[url], hitPx >= native - 1 { return hit }
        }
        let key = "\(url.absoluteString)#\(Int(px.rounded()))"
        if let running = inFlight[key] { return await running.value }

        // Si la URL trae menos píxeles de los necesarios (las del feed vienen a
        // 600×600), se descarga una versión más grande del mismo CDN. La caché
        // sigue indexada por la URL original del feed.
        let fetchURL = Self.upsized(url, toAtLeast: px)
        let task = Task<UIImage?, Never>.detached(priority: .utility) {
            guard let (data, _) = try? await URLSession.shared.data(from: fetchURL) else { return nil }
            return ArtworkImageCache.downsample(data, maxPixel: px)
        }
        inFlight[key] = task
        let img = await task.value
        inFlight[key] = nil
        if let img {
            // Si vino más chica de lo pedido, esa es la resolución nativa de la
            // fuente: se anota para servirla de caché en pedidas mayores.
            let imgPx = pixelSize(of: img)
            if imgPx < px - 1 { nativePixel[url] = imgPx }
            // Nunca reemplaza una versión cacheada por otra más chica.
            let current = cache.object(forKey: url as NSURL)
            if current == nil || imgPx > pixelSize(of: current!) {
                cache.setObject(img, forKey: url as NSURL)
            }
        }
        return img
    }

    private func pixelSize(of image: UIImage) -> CGFloat {
        max(image.size.width, image.size.height) * image.scale
    }

    /// Las fotos del feed vienen de mzstatic con el tamaño codificado en el
    /// último componente de la URL ("…/600x600cc.png") y el CDN sirve cualquier
    /// dimensión que se le pida. Si se necesitan más píxeles de los que la URL
    /// trae (el círculo en zoom a 3× pide ~720), se reescribe a ese tamaño.
    /// URLs sin el patrón (og:image de otros dominios) quedan intactas.
    private static func upsized(_ url: URL, toAtLeast minPixel: CGFloat) -> URL {
        guard url.host?.hasSuffix("mzstatic.com") == true else { return url }
        let name = url.lastPathComponent
        guard let match = name.firstMatch(of: /^(\d+)x(\d+)/),
              let w = Int(match.1), let h = Int(match.2),
              CGFloat(max(w, h)) < minPixel else { return url }
        let side = Int(minPixel.rounded(.up))
        let resized = name.replacingCharacters(in: match.range, with: "\(side)x\(side)")
        return url.deletingLastPathComponent().appendingPathComponent(resized)
    }

    /// Decodifica `data` directamente a un thumbnail de `maxPixel` px (ImageIO),
    /// evitando cargar el bitmap completo en memoria.
    private static func downsample(_ data: Data, maxPixel: CGFloat) -> UIImage? {
        let srcOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithData(data as CFData, srcOptions) else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ] as CFDictionary
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, options) else { return nil }
        return UIImage(cgImage: cg)
    }
}

// MARK: - Texto curvado sobre el borde inferior del círculo

/// Dibuja `text` letra por letra a lo largo de un arco interior, centrado en la
/// parte inferior del círculo (las letras siguen la curvatura). Usa `Canvas`
/// para medir cada glifo y rotarlo según su posición angular.
struct CurvedBottomText: View {
    let text: String
    let radius: CGFloat
    var weight: Font.Weight = .semibold

    var body: some View {
        Canvas { context, size in
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, radius > 12 else { return }
            let chars = trimmed.map(String.init)
            let center = CGPoint(x: size.width / 2, y: size.height / 2)

            let baseSize = max(7, radius * 0.24)
            // Radio del arco: hacia adentro desde el borde, dejando margen.
            let arcRadius = radius - baseSize * 0.5 - radius * 0.10
            guard arcRadius > 4 else { return }

            let probe = CGSize(width: 1000, height: 1000)
            func resolve(_ s: String, _ fs: CGFloat) -> GraphicsContext.ResolvedText {
                context.resolve(Text(s)
                    .font(.system(size: fs, weight: weight))
                    .foregroundColor(.white))
            }
            func widths(_ fs: CGFloat) -> [CGFloat] {
                chars.map { resolve($0, fs).measure(in: probe).width }
            }

            // Achica la fuente si el nombre no cabe en ~150° de arco.
            let maxArc: CGFloat = 2.6
            var fontSize = baseSize
            var ws = widths(fontSize)
            var total = ws.reduce(0, +)
            if total / arcRadius > maxArc {
                fontSize *= maxArc * arcRadius / total
                ws = widths(fontSize)
                total = ws.reduce(0, +)
            }

            var shadowed = context
            shadowed.addFilter(.shadow(color: .black.opacity(0.6), radius: 2, y: 1))

            // θ se mide desde el fondo (0 = punto más bajo), creciendo a la derecha.
            let totalAngle = total / arcRadius
            var angle = -totalAngle / 2
            for (i, ch) in chars.enumerated() {
                let theta = angle + ws[i] / (2 * arcRadius)
                let pos = CGPoint(x: center.x + arcRadius * sin(theta),
                                  y: center.y + arcRadius * cos(theta))
                var glyph = shadowed
                glyph.translateBy(x: pos.x, y: pos.y)
                glyph.rotate(by: .radians(-Double(theta)))
                glyph.draw(resolve(ch, fontSize), at: .zero, anchor: .center)
                angle += ws[i] / arcRadius
            }
        }
    }
}
