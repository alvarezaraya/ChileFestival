import SwiftUI
import UIKit
import ImageIO

// MARK: - Vista del cúmulo con física

/// Renderiza los círculos sobre una simulación de gravedad. Sirve en dos modos:
///
/// - `interactive == false` (silueta colapsada): un toque en cualquier parte
///   expande la vista; los círculos solo se pueden **arrastrar** (física).
/// - `interactive == true` (pantalla completa): cada círculo es tappable de forma
///   individual (abre el artista) además de arrastrable.
///
/// El estepeo lo dispara un `TimelineView(.animation)`. La instancia de
/// `ClusterPhysics` se comparte con la silueta para mantener continuidad.
struct PhysicsClusterView: View {
    let artists: [LineupArtist]
    @ObservedObject var physics: ClusterPhysics
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

    /// Cuando se hace zoom a un artista: el círculo origen se oculta (lo sustituye
    /// el héroe con matchedGeometry) y el resto se atenúa.
    var zoomedArtistID: String? = nil
    /// Solo la vista a pantalla completa participa del matchedGeometry hacia el
    /// héroe (evita ids duplicados entre silueta y overlay).
    var matchNamespace: Namespace.ID? = nil

    var onTapBackground: () -> Void = {}
    var onSelect: (LineupArtist) -> Void = { _ in }

    @State private var lastTick: Date?
    @State private var boundsSize: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            // El "mundo" físico puede ser mayor que la ventana visible: el contenido
            // se centra y desborda, de modo que la silueta (clip del padre) solo deja
            // ver la parte central.
            let world = CGSize(width: geo.size.width * worldScale,
                               height: geo.size.height * worldScale)
            ZStack {
                // Capa de fondo: en modo silueta capta el toque para expandir.
                // En la silueta el cúmulo va dentro de un `drawingGroup` que aplana
                // las burbujas y oculta su accesibilidad; esta capa ofrece a
                // VoiceOver un único botón para expandir el cartel.
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { if !interactive { onTapBackground() } }
                    .accessibilityElement()
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel("Explorar cartel")
                    // En el overlay interactivo cada burbuja ya es accesible; aquí
                    // ocultamos la capa de fondo para no duplicar elementos.
                    .accessibilityHidden(interactive)

                bubbles
                    .modifier(EdgeFadeMask(visible: geo.size, enabled: fadesAtEdges))
                    .modifier(FlattenCluster(enabled: !interactive))

                // Motor: avanza la simulación a ~30 Hz. A 60 Hz, dos festivales del
                // TabView corriendo en paralelo saturan el main thread y bloquean
                // gestos. 30 Hz es indistinguible visualmente para un cúmulo con
                // damping y deja holgura al run loop.
                TimelineView(.animation(minimumInterval: 1.0 / 30.0,
                                        paused: !isActive)) { tl in
                    Color.clear
                        .onChange(of: tl.date) { _, date in
                            let dt = lastTick.map { CGFloat(date.timeIntervalSince($0)) } ?? 0
                            lastTick = date
                            if isActive { physics.step(dt) }
                        }
                }
                .allowsHitTesting(false)
            }
            // Marco del mundo, centrado sobre la ventana visible (desborda y se recorta).
            // `coordinateSpace` se ancla al marco del mundo (antes de `position`) para
            // que el arrastre lea coordenadas del mundo, no de la ventana visible.
            .frame(width: world.width, height: world.height)
            .coordinateSpace(.named("cluster"))
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
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
                    lastTick = nil
                    physics.configure(artists: artists, size: boundsSize)
                }
            }
        }
    }

    /// Renderiza las burbujas como un solo subárbol para poder aplicarles una
    /// máscara y aplanado únicos (más barato que modificadores por burbuja).
    @ViewBuilder private var bubbles: some View {
        ZStack {
            ForEach(physics.bodies) { body in
                DraggableBubble(
                    physics: physics,
                    physicsBody: body,
                    accent: accent,
                    interactive: interactive,
                    isZoomSource: zoomedArtistID == body.id,
                    dimmed: zoomedArtistID != nil && zoomedArtistID != body.id,
                    matchNamespace: matchNamespace,
                    onTapBackground: onTapBackground,
                    onSelect: onSelect
                )
            }
        }
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
/// vez por frame, en lugar de N veces. Solo se aplica a la silueta (no al
/// overlay con `matchedGeometryEffect`, incompatible con `drawingGroup`).
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

// MARK: - Burbuja arrastrable

private struct DraggableBubble: View {
    @ObservedObject var physics: ClusterPhysics
    let physicsBody: PhysicsBody
    let accent: Color
    let interactive: Bool
    let isZoomSource: Bool
    let dimmed: Bool
    let matchNamespace: Namespace.ID?
    let onTapBackground: () -> Void
    let onSelect: (LineupArtist) -> Void

    @State private var didDrag = false

    var body: some View {
        bubble
            .frame(width: physicsBody.radius * 2, height: physicsBody.radius * 2)
            .opacity(isZoomSource ? 0 : (dimmed ? 0.22 : 1))
            .scaleEffect(dimmed ? 0.92 : 1)
            .position(physicsBody.position)
            .animation(.easeInOut(duration: 0.35), value: dimmed)
            .gesture(drag)
            // En la portada (silueta) las burbujas son inertes al tacto: así
            // cualquier toque/deslizamiento atraviesa hasta el TabView (deslizar
            // entre festivales) o hasta la capa de fondo (expandir). Solo en la
            // vista expandida capturan toques (seleccionar / arrastrar).
            .allowsHitTesting(interactive)
            // VoiceOver: cada burbuja es un elemento con el nombre del artista.
            // En modo cartel a pantalla completa (`interactive`) la acción abre
            // el artista; en la silueta colapsada expande la vista. En la silueta
            // el `drawingGroup` aplana el subárbol, así que estos elementos solo
            // se exponen de forma fiable en el overlay interactivo —que es donde
            // importa explorar el lineup.
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(physicsBody.artist.name)
            .accessibilityHint(interactive ? "Ver artista" : "Explorar cartel")
            .accessibilityAction {
                if interactive { onSelect(physicsBody.artist) } else { onTapBackground() }
            }
    }

    @ViewBuilder private var bubble: some View {
        if let ns = matchNamespace {
            ArtistBubble(artist: physicsBody.artist, radius: physicsBody.radius, accent: accent)
                .equatable()
                .matchedGeometryEffect(id: physicsBody.id, in: ns, isSource: !isZoomSource)
        } else {
            ArtistBubble(artist: physicsBody.artist, radius: physicsBody.radius, accent: accent)
                .equatable()
        }
    }

    /// Un único gesto distingue arrastre (física) de toque (expandir/seleccionar)
    /// según la distancia recorrida, evitando conflictos de gestos. En la silueta
    /// colapsada (`!interactive`) los círculos son inertes: no se arrastran ni se
    /// seleccionan, cualquier toque solo expande la vista.
    private var drag: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("cluster"))
            .onChanged { v in
                guard interactive else { return }   // silueta: sin arrastre
                let moved = abs(v.translation.width) + abs(v.translation.height)
                if moved > 8 {
                    if !didDrag { didDrag = true; physics.beginDrag(physicsBody.id) }
                    physics.drag(physicsBody.id, to: v.location)
                }
            }
            .onEnded { v in
                if didDrag {
                    physics.endDrag(physicsBody.id, velocity: v.velocity)
                    didDrag = false
                } else if interactive {
                    onSelect(physicsBody.artist) // pantalla completa → abre artista
                } else {
                    onTapBackground()            // silueta → expande
                }
            }
    }
}

// MARK: - Burbuja de artista (contenido visual)

struct ArtistBubble: View, Equatable {
    let artist: LineupArtist
    let radius: CGFloat
    let accent: Color

    private var diameter: CGFloat { radius * 2 }

    // Igualdad por contenido visual: permite a SwiftUI saltarse el re-render
    // (incluido el Canvas del nombre) mientras la física solo cambia la posición.
    static func == (lhs: ArtistBubble, rhs: ArtistBubble) -> Bool {
        lhs.artist.id == rhs.artist.id && lhs.radius == rhs.radius && lhs.accent == rhs.accent
    }

    var body: some View {
        ZStack {
            Circle().fill((artist.accentColor ?? accent).gradient)

            if let url = artist.imageURL {
                // La foto del artista es el contenido: llena el círculo. Se decodifica
                // a tamaño y se cachea, así no satura el hilo principal con 56 PNG.
                CachedArtworkImage(url: url, pointSize: diameter) {
                    initialsLabel   // placeholder mientras carga / si falla
                }
                .clipShape(Circle())

                // Degradado inferior para legibilidad del nombre sobre la foto.
                Circle().fill(
                    LinearGradient(colors: [.clear, .clear, .black.opacity(0.6)],
                                   startPoint: .top, endPoint: .bottom))

                // Nombre curvado siguiendo la curvatura inferior del círculo.
                CurvedBottomText(text: artist.name, radius: radius)
                    .frame(width: diameter, height: diameter)
            } else {
                centeredLabel
            }
        }
        .frame(width: diameter, height: diameter)
        .overlay(Circle().stroke(.white.opacity(0.25), lineWidth: 1))
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
        .task(id: url) {
            if image == nil {
                image = await ArtworkImageCache.shared.image(
                    for: url, maxPixel: pointSize * displayScale)
            }
        }
    }
}

/// Caché compartida de imágenes decodificadas + deduplicación de descargas.
actor ArtworkImageCache {
    static let shared = ArtworkImageCache()

    private let cache = NSCache<NSURL, UIImage>()
    private var inFlight: [URL: Task<UIImage?, Never>] = [:]

    func image(for url: URL, maxPixel: CGFloat) async -> UIImage? {
        if let hit = cache.object(forKey: url as NSURL) { return hit }
        if let running = inFlight[url] { return await running.value }

        let px = max(64, maxPixel)
        let task = Task<UIImage?, Never>.detached(priority: .utility) {
            guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
            return ArtworkImageCache.downsample(data, maxPixel: px)
        }
        inFlight[url] = task
        let img = await task.value
        inFlight[url] = nil
        if let img { cache.setObject(img, forKey: url as NSURL) }
        return img
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
