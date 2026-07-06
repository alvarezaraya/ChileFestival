import SwiftUI
import MusicKit
import Combine

// MARK: - Catálogo: resolución de artista + top songs (fuente única)
//
// No pide autorización: el llamador debe asegurarla antes (FestivalPlayer la
// pide una vez por mix; ArtistDetailViewModel la pide al abrir el detalle).

enum ArtistCatalog {

    /// Resuelve los `Artist` del catálogo de Apple Music: por id(s) si los
    /// tenemos cacheados en el feed, si no por búsqueda de texto. Suele ser uno
    /// solo; son varios cuando la entrada agrupa a más de un artista.
    static func catalogArtists(for artist: LineupArtist) async throws -> [MusicKit.Artist] {
        let ids = artist.appleMusicArtistIDs
        guard !ids.isEmpty else {
            var search = MusicCatalogSearchRequest(term: artist.name,
                                                   types: [MusicKit.Artist.self])
            search.limit = 1
            return try await search.response().artists.first.map { [$0] } ?? []
        }
        let request = MusicCatalogResourceRequest<MusicKit.Artist>(
            matching: \.id, memberOf: ids.map { MusicItemID($0) })
        // El catálogo no garantiza el orden; lo reordenamos según el feed.
        let items = try await request.response().items
        return ids.compactMap { id in items.first { $0.id.rawValue == id } }
    }

    /// El artista principal (para artwork, nombre, etc.).
    static func catalogArtist(for artist: LineupArtist) async throws -> MusicKit.Artist? {
        try await catalogArtists(for: artist).first
    }

    static func topSongs(for artist: LineupArtist, limit: Int) async throws -> [Song] {
        let artists = try await catalogArtists(for: artist)
        guard !artists.isEmpty else { return [] }

        // Caso común (un artista): sus top songs tal cual.
        if artists.count == 1 {
            let detailed = try await artists[0].with([.topSongs])
            return Array((detailed.topSongs ?? []).prefix(limit))
        }

        // Varios artistas en la entrada: combinamos sus top songs intercaladas
        // para que todos queden representados.
        var pools: [[Song]] = []
        for catalogArtist in artists {
            let detailed = try await catalogArtist.with([.topSongs])
            let songs = Array(detailed.topSongs ?? [])
            if !songs.isEmpty { pools.append(songs) }
        }
        return Array(interleave(pools).prefix(limit))
    }

    /// Top songs de TODO el cartel para el mix, en tandas de ~25 ids por
    /// consulta (el mismo batching que `LiveArtistArtwork` usa para las fotos).
    /// Consultar artista por artista —dos requests cada uno, en ráfaga— gatillaba
    /// el rate-limiting del catálogo con carteles grandes y los rechazados se
    /// omitían en silencio: el mix quedaba con un puñado de artistas.
    /// Cada pool viene junto a su artista (el mix necesita el tier para elegir
    /// con quién abrir); las entradas sin id resuelto caen a la búsqueda por
    /// texto individual. Devuelve el primer error por si TODOS fallaron
    /// (p. ej. sin red).
    static func topSongPools(for artists: [LineupArtist], limit: Int)
        async -> (pools: [(artist: LineupArtist, songs: [Song])], firstError: Error?) {
        var firstError: Error?

        // Top songs de cada id de catálogo, en tandas.
        var seen = Set<String>()
        let ids = artists.flatMap(\.appleMusicArtistIDs)
            .filter { seen.insert($0).inserted }
        var songsByID: [String: [Song]] = [:]
        for start in stride(from: 0, to: ids.count, by: 25) {
            let chunk = Array(ids[start..<min(start + 25, ids.count)])
            var request = MusicCatalogResourceRequest<MusicKit.Artist>(
                matching: \.id, memberOf: chunk.map { MusicItemID($0) })
            request.properties = [.topSongs]
            do {
                for item in try await request.response().items {
                    songsByID[item.id.rawValue] = Array(item.topSongs ?? [])
                }
            } catch {
                if firstError == nil { firstError = error }
            }
        }

        // Pool por entrada del cartel: sus ids combinados (intercalados si la
        // entrada agrupa a varios artistas), recortados al límite del mix.
        var pools: [(artist: LineupArtist, songs: [Song])] = []
        for artist in artists {
            let songs: [Song]
            if artist.appleMusicArtistIDs.isEmpty {
                do { songs = try await topSongs(for: artist, limit: limit) }
                catch { if firstError == nil { firstError = error }; continue }
            } else {
                let subPools = artist.appleMusicArtistIDs
                    .compactMap { songsByID[$0] }
                    .filter { !$0.isEmpty }
                songs = Array(interleave(subPools).prefix(limit))
            }
            if !songs.isEmpty { pools.append((artist, songs)) }
        }
        return (pools, firstError)
    }

    /// Round-robin: toma una de cada pool por vuelta hasta agotarlas.
    static func interleave<T>(_ pools: [[T]]) -> [T] {
        var pools = pools
        var result: [T] = []
        var keepGoing = true
        while keepGoing {
            keepGoing = false
            for i in pools.indices where !pools[i].isEmpty {
                result.append(pools[i].removeFirst()); keepGoing = true
            }
        }
        return result
    }

    /// Foto oficial del artista en Apple Music (artwork de MusicKit), resuelta
    /// en vivo. Requiere autorización; el llamador debería caer a la URL del
    /// feed si esto devuelve `nil`.
    static func artworkURL(for artist: LineupArtist,
                           width: Int, height: Int) async throws -> URL? {
        try await catalogArtist(for: artist)?.artwork?.url(width: width, height: height)
    }
}

// MARK: - Fotos en vivo desde Apple Music (con el feed de respaldo)
//
// Las burbujas del cúmulo piden aquí la foto oficial del catálogo y solo caen
// a la `imageURL` del feed si esto devuelve nil. NUNCA pide autorización (una
// alerta de permisos solo por mostrar fotos sería invasiva): mientras el
// usuario no la haya dado —la pide el primer play o el detalle de artista—,
// se usa el feed. Requiere `appleMusicArtistID` en el feed: la búsqueda por
// texto puede traer un homónimo y preferimos la foto curada antes que una
// equivocada.

@MainActor
enum LiveArtistArtwork {

    /// URL resuelta por id de LINEUP (no de catálogo). `.some(nil)` significa
    /// "el catálogo no tiene artwork": también se cachea para no re-consultar.
    private static var resolved: [String: URL?] = [:]
    /// Tanda en curso: las burbujas que aparecen en el mismo frame se agrupan
    /// en UNA consulta al catálogo en vez de una request por círculo.
    private static var pending: [String: LineupArtist] = [:]
    private static var flushTask: Task<Void, Never>?

    static func url(for artist: LineupArtist) async -> URL? {
        guard artist.appleMusicArtistID != nil,
              MusicAuthorization.currentStatus == .authorized else { return nil }
        if let hit = resolved[artist.id] { return hit }

        pending[artist.id] = artist
        if flushTask == nil {
            flushTask = Task {
                // Ventana corta para juntar todas las burbujas del mismo render.
                try? await Task.sleep(for: .milliseconds(80))
                let batch = Array(pending.values)
                pending = [:]
                flushTask = nil
                await resolveBatch(batch)
            }
        }
        await flushTask?.value
        // Los errores de red no se cachean: si la tanda falló, esto devuelve
        // nil (se usa el feed) y la próxima aparición de la burbuja reintenta.
        return resolved[artist.id] ?? nil
    }

    private static func resolveBatch(_ batch: [LineupArtist]) async {
        let byCatalogID = Dictionary(
            batch.compactMap { a in a.appleMusicArtistID.map { ($0, a) } },
            uniquingKeysWith: { a, _ in a })
        let ids = Array(byCatalogID.keys)
        // El endpoint de artistas múltiples acepta hasta ~25 ids por request.
        for start in stride(from: 0, to: ids.count, by: 25) {
            let chunk = Array(ids[start..<min(start + 25, ids.count)])
            let request = MusicCatalogResourceRequest<MusicKit.Artist>(
                matching: \.id, memberOf: chunk.map { MusicItemID($0) })
            guard let items = try? await request.response().items else { continue }
            for id in chunk {
                guard let lineupArtist = byCatalogID[id] else { continue }
                let artwork = items.first { $0.id.rawValue == id }?.artwork
                // `updateValue` y no subscript: hay que GUARDAR el nil (sin
                // artwork en el catálogo), no borrar la entrada.
                resolved.updateValue(artwork?.url(width: 600, height: 600),
                                     forKey: lineupArtist.id)
            }
        }
    }
}

// MARK: - ViewModel del detalle

@MainActor
final class ArtistDetailViewModel: ObservableObject {
    enum State {
        case idle, loading
        case loaded([Song])
        case needsAuthorization
        case empty
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    func load(_ artist: LineupArtist) async {
        state = .loading
        guard await MusicAuthorization.request() == .authorized else {
            state = .needsAuthorization; return
        }
        do {
            let songs = try await ArtistCatalog.topSongs(for: artist, limit: 12)
            state = songs.isEmpty ? .empty : .loaded(songs)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}

// MARK: - Página de artista (zoom nativo del propio círculo)
//
// Se presenta como overlay encima del cúmulo expandido. El zoom es NATIVO: no
// existe una segunda vista del artista ni fundidos. El propio círculo del
// cúmulo viaja hasta el centro llevado por la cámara (`zoomTransform` en
// PhysicsClusterView) y ahí se queda, visible DEBAJO de este overlay, que es
// transparente arriba. Aquí solo vive el contenido de la página: una tarjeta
// que entra deslizándose desde abajo (transición .move en FestivalsScreen) y
// que al deslizar hacia arriba revela las top songs pasando sobre el círculo.

struct ArtistZoomView: View {
    let artist: LineupArtist
    let festivalAccent: Color
    @ObservedObject var player: FestivalPlayer
    let onClose: () -> Void

    @StateObject private var model = ArtistDetailViewModel()

    private var accent: Color { artist.accentColor ?? festivalAccent }

    var body: some View {
        GeometryReader { geo in
            // Mismas medidas que usa la cámara del cúmulo (zoomTransform), para
            // que el hueco transparente calce con el círculo centrado detrás.
            let heroSize = heroCircleDiameter(forHeight: geo.size.height)
            let circleBottom = geo.size.height / 2 + heroSize / 2

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    // Hueco: deja ver el círculo (y el cúmulo atenuado) detrás.
                    // Tocar el espacio negativo —fuera del círculo— cierra la
                    // vista, igual que el botón de la esquina.
                    Color.clear
                        .frame(height: circleBottom + 24)
                        .contentShape(Rectangle())
                        .onTapGesture(coordinateSpace: .global) { location in
                            // El círculo vive centrado en la pantalla (marco
                            // completo, igual que esta vista): un toque dentro
                            // de su radio no cierra.
                            let center = CGPoint(x: geo.size.width / 2,
                                                 y: geo.size.height / 2)
                            let distance = hypot(location.x - center.x,
                                                 location.y - center.y)
                            if distance > heroSize / 2 { onClose() }
                        }
                    card
                }
            }
            .foregroundStyle(.white)
        }
        // Mismo marco que el cúmulo de fondo (pantalla completa): así el centro
        // de esta vista y el del zoom de cámara coinciden —el círculo queda en
        // el centro real de la pantalla— y el hueco calza con él.
        .ignoresSafeArea()
        .task(id: artist.id) { await model.load(artist) }
    }

    // MARK: Tarjeta de contenido (bajo el círculo)

    private var card: some View {
        VStack(spacing: 20) {
            Text(artist.name)
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            metadata
            playButton
            topSongsSection
        }
        .padding()
        .padding(.top, 8)
        .padding(.bottom, 140)
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(
                stops: [
                    .init(color: accent.opacity(0.55), location: 0),
                    .init(color: .black, location: 0.45)
                ],
                startPoint: .top, endPoint: .bottom))
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 28, topTrailingRadius: 28))
    }

    private var metadata: some View {
        FlowChips {
            Tag(text: artist.tier.displayName, filled: true, accent: accent)
            if let day = artist.day {
                Tag(text: "Día \(day)", filled: false, accent: accent)
            }
            ForEach(artist.genres, id: \.self) { genre in
                Tag(text: genre, filled: false, accent: accent)
            }
        }
    }

    private var playButton: some View {
        Button {
            // Si la lista de abajo ya cargó, se reproduce ESA (las mismas top
            // songs visibles); si aún no, cae al mix por catálogo del artista.
            if case .loaded(let songs) = model.state {
                Task { await player.playSongs(songs) }
            } else {
                Task { await player.playMix(for: [artist]) }
            }
            onClose()
        } label: {
            HStack {
                Image(systemName: "play.fill")
                Text("Reproducir top songs").fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(accent.gradient, in: Capsule())
            .foregroundStyle(.white)
        }
    }

    @ViewBuilder private var topSongsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Más escuchadas")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)

            switch model.state {
            case .idle, .loading:
                HStack { Spacer(); ProgressView().tint(.white); Spacer() }
                    .padding(.vertical, 24)
            case .loaded(let songs):
                ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                    SongRow(index: index + 1, song: song)
                }
            case .needsAuthorization:
                hint("Autoriza Apple Music para ver las canciones.")
            case .empty:
                hint("No encontré canciones para \(artist.name).")
            case .failed(let message):
                hint(message)
            }
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.white.opacity(0.65))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 12)
    }
}

// MARK: - Fila de canción

private struct SongRow: View {
    let index: Int
    let song: Song

    var body: some View {
        HStack(spacing: 12) {
            Text("\(index)")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.white.opacity(0.5))
                .frame(width: 22, alignment: .trailing)

            artwork

            VStack(alignment: .leading, spacing: 2) {
                Text(song.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                if let album = song.albumTitle {
                    Text(album)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)

            if let duration = song.duration {
                Text(format(duration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .padding(.vertical, 4)
    }

    private var artwork: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.1))
            if let url = song.artwork?.url(width: 80, height: 80) {
                AsyncImage(url: url) { $0.resizable().scaledToFill() }
                    placeholder: { Color.clear }
            } else {
                Image(systemName: "music.note").foregroundStyle(.white.opacity(0.5))
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func format(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - Tag y layout de chips con wrap

private struct Tag: View {
    let text: String
    let filled: Bool
    let accent: Color

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(filled ? AnyShapeStyle(accent) : AnyShapeStyle(.white.opacity(0.15)),
                        in: Capsule())
            .foregroundStyle(.white)
    }
}

/// Layout sencillo que reparte los chips en varias filas (wrap).
private struct FlowChips: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX; y += rowHeight + spacing; rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
