import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - Compartir el cartel como imagen
//
// Genera un póster (1080×1350, 4:5 — el formato de feed de Instagram) con el
// cúmulo de burbujas del festival y lo ofrece vía ShareLink. El póster NO es
// una captura del cúmulo en vivo: la física corre en una cola asíncrona y las
// fotos llegan por .task, cosas que ImageRenderer no espera. En su lugar se
// resuelve todo por adelantado (layout estático determinista + fotos
// descargadas) y se renderiza una vista síncrona.

// MARK: Transferable (render perezoso: solo si el usuario comparte)

struct FestivalPoster: Transferable {
    let festival: Festival
    /// Día concreto (1-indexed) o nil = cartel completo.
    var day: Int? = nil

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .jpeg) { poster in
            guard let image = await FestivalShareRenderer.poster(for: poster.festival,
                                                                 day: poster.day),
                  let data = image.jpegData(compressionQuality: 0.92) else {
                throw CocoaError(.fileWriteUnknown)
            }
            return data
        }
        .suggestedFileName { "\($0.festival.id).jpg" }
    }
}

/// Botón de compartir listo para colocar en el chrome del cúmulo expandido
/// (o donde haga falta): entrega el póster del festival/día visible.
struct ShareCartelLink: View {
    let festival: Festival
    var day: Int? = nil

    var body: some View {
        ShareLink(
            item: FestivalPoster(festival: festival, day: day),
            preview: SharePreview("Cartel de \(festival.name)")
        ) {
            Image(systemName: "square.and.arrow.up")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(.white.opacity(0.12), in: Circle())
        }
        .accessibilityLabel("Compartir cartel")
    }
}

// MARK: - Renderer

@MainActor
enum FestivalShareRenderer {

    /// Máximo de burbujas en el póster: más allá los círculos quedan ilegibles
    /// a 1080 px de ancho. Se eligen por peso (cabezas de cartel primero).
    private static let maxBubbles = 24

    static func poster(for festival: Festival, day: Int? = nil) async -> UIImage? {
        let artists = Array(
            festival.artists(onDay: day)
                .sorted { $0.billingWeight > $1.billingWeight }
                .prefix(maxBubbles))

        let layout = SharePosterLayout.pack(artists, in: FestivalShareCard.clusterRegion)
        let images = await fetchImages(for: layout)

        let card = FestivalShareCard(
            festival: festival, day: day,
            bubbles: layout.map { placed in
                FestivalShareCard.Bubble(artist: placed.artist,
                                         center: placed.center,
                                         radius: placed.radius,
                                         image: images[placed.artist.id])
            })
        let renderer = ImageRenderer(content: card)
        renderer.scale = 3   // 360×450 pt → 1080×1350 px
        return renderer.uiImage
    }

    /// Fotos por artista, resueltas ANTES de renderizar: primero el catálogo
    /// en vivo (si hay autorización; las peticiones del mismo lote se agrupan
    /// en una consulta) y de respaldo la imageURL del feed.
    private static func fetchImages(for layout: [SharePosterLayout.PlacedArtist])
        async -> [String: UIImage] {
        var urls: [(id: String, url: URL, pixel: CGFloat)] = []
        for placed in layout {
            let live = await LiveArtistArtwork.url(for: placed.artist)
            guard let url = live ?? placed.artist.imageURL else { continue }
            urls.append((placed.artist.id, url, placed.radius * 2 * 3))
        }
        var images: [String: UIImage] = [:]
        await withTaskGroup(of: (String, UIImage?).self) { group in
            for entry in urls {
                group.addTask {
                    (entry.id, await ArtworkImageCache.shared.image(for: entry.url,
                                                                    maxPixel: entry.pixel))
                }
            }
            for await (id, image) in group {
                if let image { images[id] = image }
            }
        }
        return images
    }
}

// MARK: - Packing estático (determinista, síncrono)

enum SharePosterLayout {

    struct PlacedArtist {
        let artist: LineupArtist
        var center: CGPoint
        let radius: CGFloat
    }

    /// Mismo espíritu que ClusterPhysics (anillos por peso + colisiones) pero
    /// síncrono y sin azar: siembra en espiral de ángulo áureo y relaja un
    /// número fijo de iteraciones. El mismo cartel produce siempre el mismo
    /// póster.
    static func pack(_ artists: [LineupArtist], in region: CGRect) -> [PlacedArtist] {
        guard !artists.isEmpty else { return [] }

        // Radios por tier, escalados para que ocupen ~52 % del área de la zona.
        var radii = artists.map { 18 + (44 - 18) * $0.circleSizeFactor }
        let circlesArea = radii.reduce(0) { $0 + .pi * $1 * $1 }
        let scale = min(sqrt(0.52 * region.width * region.height / circlesArea), 1.6)
        radii = radii.map { $0 * scale }

        // Alcance del cúmulo: disco que empaca justo los círculos (Σr²/packing).
        let reach = min(sqrt(radii.reduce(0) { $0 + $1 * $1 } / 0.68),
                        min(region.width, region.height) / 2)

        let center = CGPoint(x: region.midX, y: region.midY)
        let count = artists.count
        var placed = artists.enumerated().map { i, artist in
            let t = count <= 1 ? 0 : CGFloat(i) / CGFloat(count - 1)
            let angle = CGFloat(i) * 2.399963   // ángulo áureo
            let seed = sqrt(t) * reach * 0.8
            return PlacedArtist(
                artist: artist,
                center: CGPoint(x: center.x + cos(angle) * seed,
                                y: center.y + sin(angle) * seed),
                radius: radii[i])
        }

        // Relajación: resorte radial al anillo objetivo + separación de pares.
        for _ in 0..<220 {
            for i in placed.indices {
                let t = count <= 1 ? 0 : CGFloat(i) / CGFloat(count - 1)
                let target = sqrt(t) * max(0, reach - placed[i].radius - 4)
                let dx = placed[i].center.x - center.x
                let dy = placed[i].center.y - center.y
                let d = max(sqrt(dx * dx + dy * dy), 0.01)
                let pull = (d - target) * 0.12
                placed[i].center.x -= dx / d * pull
                placed[i].center.y -= dy / d * pull
            }
            separate(&placed, clampTo: region)
        }
        // Asentamiento final SIN el resorte: el empuje radial de cada iteración
        // reintroduce solapes leves que una sola pasada de colisiones no
        // alcanza a deshacer; estas iteraciones puras convergen a separación
        // limpia (el test de solapes del póster lo verifica).
        for _ in 0..<40 {
            separate(&placed, clampTo: region)
        }
        return placed
    }

    /// Una pasada de separación de pares + recorte a la zona.
    private static func separate(_ placed: inout [PlacedArtist], clampTo region: CGRect) {
        for i in 0..<placed.count {
            for j in (i + 1)..<placed.count {
                let dx = placed[j].center.x - placed[i].center.x
                let dy = placed[j].center.y - placed[i].center.y
                var d = sqrt(dx * dx + dy * dy)
                let minD = placed[i].radius + placed[j].radius + 2
                guard d < minD else { continue }
                if d < 0.01 { d = 0.01 }
                let push = (minD - d) / 2
                let nx = dx / d, ny = dy / d
                placed[i].center.x -= nx * push
                placed[i].center.y -= ny * push
                placed[j].center.x += nx * push
                placed[j].center.y += ny * push
            }
        }
        for i in placed.indices {
            let r = placed[i].radius
            placed[i].center.x = min(max(placed[i].center.x, region.minX + r),
                                     region.maxX - r)
            placed[i].center.y = min(max(placed[i].center.y, region.minY + r),
                                     region.maxY - r)
        }
    }
}

// MARK: - La tarjeta (vista síncrona que renderiza ImageRenderer)

struct FestivalShareCard: View {
    struct Bubble: Identifiable {
        let artist: LineupArtist
        let center: CGPoint
        let radius: CGFloat
        let image: UIImage?
        var id: String { artist.id }
    }

    let festival: Festival
    let day: Int?
    let bubbles: [Bubble]

    /// 4:5 en puntos; el renderer lo escala a 3× (1080×1350 px).
    static let size = CGSize(width: 360, height: 450)
    /// Zona del cúmulo, entre el encabezado y el pie.
    static let clusterRegion = CGRect(x: 8, y: 96, width: 344, height: 306)

    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(
                stops: [.init(color: festival.accentColor.opacity(0.70), location: 0),
                        .init(color: .black, location: 0.62)],
                startPoint: .top, endPoint: .bottom)

            ForEach(bubbles) { bubble in
                ShareBubbleView(bubble: bubble, accent: festival.accentColor)
                    .position(bubble.center)
            }

            VStack(spacing: 3) {
                Text(festival.name)
                    .font(.system(size: 30, weight: .heavy))
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.75))
            }
            .padding(.top, 22)
            .padding(.horizontal, 16)

            VStack {
                Spacer()
                Text("\(festival.venue) · \(festival.city)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(.bottom, 14)
            }
        }
        .foregroundStyle(.white)
        .frame(width: Self.size.width, height: Self.size.height)
    }

    private var subtitle: String {
        if let day { return "Día \(day) · \(festival.dateRangeLabel)" }
        return festival.dateRangeLabel
    }
}

/// Burbuja del póster: mismo lenguaje visual que ArtistBubble (foto, degradado
/// de legibilidad, nombre curvado) pero 100 % síncrona: la imagen ya viene
/// descargada y decodificada.
private struct ShareBubbleView: View {
    let bubble: FestivalShareCard.Bubble
    let accent: Color

    private var diameter: CGFloat { bubble.radius * 2 }

    var body: some View {
        ZStack {
            Circle().fill((bubble.artist.accentColor ?? accent).gradient)

            if let image = bubble.image {
                Image(uiImage: image)
                    .resizable().scaledToFill()
                    .frame(width: diameter, height: diameter)
                    .clipShape(Circle())
                Circle().fill(
                    LinearGradient(colors: [.clear, .clear, .black.opacity(0.6)],
                                   startPoint: .top, endPoint: .bottom))
                CurvedBottomText(text: bubble.artist.name, radius: bubble.radius)
                    .frame(width: diameter, height: diameter)
            } else {
                Text(initials)
                    .font(.system(size: max(9, bubble.radius * 0.5), weight: .bold))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
        .frame(width: diameter, height: diameter)
        .overlay(Circle().stroke(.white.opacity(0.25), lineWidth: 1))
    }

    private var initials: String {
        bubble.artist.name
            .split(separator: " ").prefix(2)
            .compactMap { $0.first }
            .map(String.init).joined().uppercased()
    }
}
