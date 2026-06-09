import SwiftUI

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
            ZStack {
                // Capa de fondo: en modo silueta capta el toque para expandir.
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { if !interactive { onTapBackground() } }

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

                // Motor: avanza la simulación en cada frame. Pausa si está inactiva.
                TimelineView(.animation(paused: !isActive)) { tl in
                    Color.clear
                        .onChange(of: tl.date) { _, date in
                            let dt = lastTick.map { CGFloat(date.timeIntervalSince($0)) } ?? 0
                            lastTick = date
                            if isActive { physics.step(dt) }
                        }
                }
                .allowsHitTesting(false)
            }
            .coordinateSpace(.named("cluster"))
            .onAppear {
                boundsSize = geo.size
                if isActive { physics.configure(artists: artists, size: geo.size) }
            }
            .onChange(of: geo.size) { _, size in
                boundsSize = size
                if isActive { physics.configure(artists: artists, size: size) }
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
    }

    @ViewBuilder private var bubble: some View {
        if let ns = matchNamespace {
            ArtistBubble(artist: physicsBody.artist, radius: physicsBody.radius, accent: accent)
                .matchedGeometryEffect(id: physicsBody.id, in: ns, isSource: !isZoomSource)
        } else {
            ArtistBubble(artist: physicsBody.artist, radius: physicsBody.radius, accent: accent)
        }
    }

    /// Un único gesto distingue arrastre (física) de toque (expandir/seleccionar)
    /// según la distancia recorrida, evitando conflictos de gestos.
    private var drag: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("cluster"))
            .onChanged { v in
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

struct ArtistBubble: View {
    let artist: LineupArtist
    let radius: CGFloat
    let accent: Color

    private var diameter: CGFloat { radius * 2 }

    var body: some View {
        ZStack {
            Circle().fill((artist.accentColor ?? accent).gradient)

            if artist.imageURL != nil {
                // La foto del artista es el contenido: llena el círculo.
                ArtistImage(artist: artist, width: 300, height: 300) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        initialsLabel   // placeholder mientras carga / si falla
                    }
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
        .shadow(color: .black.opacity(0.25), radius: 3, y: 2)
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
