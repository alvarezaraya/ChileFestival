import SwiftUI

// MARK: - Packer (relajación: empujar solapados + atraer al centro)

struct PackedCircle: Identifiable, Sendable {
    let artist: LineupArtist
    var center: CGPoint
    let radius: CGFloat
    var id: String { artist.id }
}

enum CirclePacker {

    nonisolated static func pack(_ artists: [LineupArtist],
                     in size: CGSize,
                     minRadius: CGFloat = 28,
                     maxRadius: CGFloat = 64,
                     padding: CGFloat = 3,
                     iterations: Int = 320) -> [PackedCircle] {

        guard !artists.isEmpty, size.width > 1, size.height > 1 else { return [] }

        // Radio por peso (área ~ peso → sqrt para percepción visual correcta).
        let radii = artists.map { a -> CGFloat in
            minRadius + (maxRadius - minRadius) * sqrt(CGFloat(a.billingWeight))
        }

        let center = CGPoint(x: size.width / 2, y: size.height / 2)

        // Posiciones iniciales en espiral determinista (mayores hacia el centro).
        var pos = (0..<artists.count).map { i -> CGPoint in
            let t = CGFloat(i)
            let angle = t * 2.399963        // golden angle → reparto uniforme
            let r = 6 * sqrt(t)
            return CGPoint(x: center.x + cos(angle) * r,
                           y: center.y + sin(angle) * r)
        }

        let centeringStrength: CGFloat = 0.012

        for _ in 0..<iterations {
            // Atracción al centro.
            for i in pos.indices {
                pos[i].x += (center.x - pos[i].x) * centeringStrength
                pos[i].y += (center.y - pos[i].y) * centeringStrength
            }
            // Resolución de colisiones (par a par).
            for i in 0..<pos.count {
                for j in (i + 1)..<pos.count {
                    let dx = pos[j].x - pos[i].x
                    let dy = pos[j].y - pos[i].y
                    var dist = (dx * dx + dy * dy).squareRoot()
                    let minDist = radii[i] + radii[j] + padding
                    if dist < minDist {
                        if dist == 0 { dist = 0.01 }
                        let overlap = (minDist - dist) / 2
                        let nx = dx / dist, ny = dy / dist
                        pos[i].x -= nx * overlap; pos[i].y -= ny * overlap
                        pos[j].x += nx * overlap; pos[j].y += ny * overlap
                    }
                }
            }
        }

        // Encajar (escalar + centrar) en el frame disponible.
        var minX = CGFloat.greatestFiniteMagnitude, minY = minX
        var maxX = -minX, maxY = -minX
        for i in pos.indices {
            minX = min(minX, pos[i].x - radii[i]); maxX = max(maxX, pos[i].x + radii[i])
            minY = min(minY, pos[i].y - radii[i]); maxY = max(maxY, pos[i].y + radii[i])
        }
        let bboxW = max(maxX - minX, 1), bboxH = max(maxY - minY, 1)
        let inset: CGFloat = 8
        let scale = min((size.width - inset * 2) / bboxW,
                        (size.height - inset * 2) / bboxH, 1)
        let bcx = (minX + maxX) / 2, bcy = (minY + maxY) / 2

        return artists.enumerated().map { idx, artist in
            let p = pos[idx]
            return PackedCircle(
                artist: artist,
                center: CGPoint(x: center.x + (p.x - bcx) * scale,
                                y: center.y + (p.y - bcy) * scale),
                radius: radii[idx] * scale)
        }
    }
}

// MARK: - Vista del cúmulo

struct FestivalClusterView: View {
    let artists: [LineupArtist]
    let accent: Color
    var onTapArtist: (LineupArtist) -> Void = { _ in }

    @State private var circles: [PackedCircle] = []
    @State private var selected: String?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ForEach(circles) { circle in
                    ArtistBubble(circle: circle,
                                 accent: accent,
                                 isSelected: selected == circle.id)
                        .position(circle.center)
                        .onTapGesture {
                            selected = circle.id
                            onTapArtist(circle.artist)
                        }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            // Recalcula cuando cambia el tamaño o el lineup. El cómputo va a
            // un hilo de fondo para no bloquear la UI con carteles grandes.
            .task(id: ClusterKey(size: geo.size, ids: artists.map(\.id))) {
                let result = await Task.detached(priority: .userInitiated) {
                    CirclePacker.pack(artists, in: geo.size)
                }.value
                withAnimation(.spring(duration: 0.45)) { circles = result }
            }
        }
    }
}

private struct ClusterKey: Equatable {
    let size: CGSize
    let ids: [String]
}

// MARK: - Burbuja de artista

struct ArtistBubble: View {
    let circle: PackedCircle
    let accent: Color
    let isSelected: Bool

    private var diameter: CGFloat { circle.radius * 2 }
    private var showsFullName: Bool { circle.radius >= 40 }

    var body: some View {
        ZStack {
            Circle().fill((circle.artist.accentColor ?? accent).gradient)

            if let url = circle.artist.imageURL {
                // La foto del artista es el contenido: llena el círculo.
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        initialsLabel   // placeholder mientras carga / si falla
                    }
                }
                .clipShape(Circle())

                // Degradado inferior para que el nombre quede legible sobre la foto.
                Circle().fill(
                    LinearGradient(colors: [.clear, .clear, .black.opacity(0.6)],
                                   startPoint: .top, endPoint: .bottom))

                // Nombre curvado siguiendo la curvatura inferior del círculo.
                CurvedBottomText(text: circle.artist.name, radius: circle.radius)
                    .frame(width: diameter, height: diameter)
            } else {
                // Sin foto: gradiente de acento + texto centrado.
                centeredLabel
            }
        }
        .frame(width: diameter, height: diameter)
        .overlay(
            Circle().stroke(.white.opacity(isSelected ? 0.95 : 0.25),
                            lineWidth: isSelected ? 3 : 1))
        .shadow(color: .black.opacity(0.25), radius: isSelected ? 8 : 3, y: 2)
        .scaleEffect(isSelected ? 1.06 : 1)
        .animation(.spring(duration: 0.3), value: isSelected)
    }

    private var label: String { showsFullName ? circle.artist.name : initials }

    /// Texto centrado cuando no hay foto.
    private var centeredLabel: some View {
        Text(label)
            .font(.system(size: max(9, circle.radius * 0.28), weight: .semibold))
            .multilineTextAlignment(.center)
            .minimumScaleFactor(0.6)
            .lineLimit(2)
            .foregroundStyle(.white)
            .padding(4)
    }

    /// Iniciales como placeholder mientras carga la foto.
    private var initialsLabel: some View {
        Text(initials)
            .font(.system(size: max(10, circle.radius * 0.5), weight: .bold))
            .foregroundStyle(.white.opacity(0.9))
    }

    private var initials: String {
        circle.artist.name
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
                glyph.rotate(by: .radians(Double(theta)))
                glyph.draw(resolve(ch, fontSize), at: .zero, anchor: .center)
                angle += ws[i] / arcRadius
            }
        }
    }
}
