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

    /// Round-robin: toma una de cada pool por vuelta hasta agotarlas.
    private static func interleave<T>(_ pools: [[T]]) -> [T] {
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

// MARK: - Caché de artwork de Apple Music
//
// Memoiza la URL oficial por artista para que el cúmulo, el detalle y demás
// vistas la pidan una sola vez. No es ObservableObject a propósito: cada vista
// la consume desde su `.task` y guarda el resultado en estado local, evitando
// re-render global del cúmulo entero.

@MainActor
enum ArtworkCache {
    private static var cache: [String: URL] = [:]
    private static var tasks: [String: Task<URL?, Never>] = [:]

    /// URL de la foto oficial de Apple Music, resuelta una vez y cacheada.
    /// Devuelve `nil` si no hay autorización o no se encontró: en ese caso el
    /// llamador usa `artist.imageURL` (horneada en el feed) como fallback.
    static func appleMusicArtworkURL(for artist: LineupArtist,
                                     width: Int = 600, height: Int = 600) async -> URL? {
        if let hit = cache[artist.id] { return hit }
        if let running = tasks[artist.id] { return await running.value }
        guard MusicAuthorization.currentStatus == .authorized else { return nil }

        let task = Task<URL?, Never> {
            try? await ArtistCatalog.artworkURL(for: artist, width: width, height: height)
        }
        tasks[artist.id] = task
        let url = await task.value
        tasks[artist.id] = nil
        if let url { cache[artist.id] = url }
        return url
    }
}

// MARK: - Imagen de artista (feed al instante → foto oficial en vivo)

/// Muestra la foto del artista usando la URL del feed de inmediato y, en cuanto
/// se resuelve la oficial de Apple Music (si hay autorización), la mejora.
/// Reusa el mismo `content` de `AsyncImage`, así cada vista mantiene su estilo.
struct ArtistImage<Content: View>: View {
    let artist: LineupArtist
    var width: Int = 600
    var height: Int = 600
    @ViewBuilder var content: (AsyncImagePhase) -> Content

    @State private var liveURL: URL?

    var body: some View {
        AsyncImage(url: liveURL ?? artist.imageURL, content: content)
            .task(id: artist.id) {
                liveURL = await ArtworkCache.appleMusicArtworkURL(
                    for: artist, width: width, height: height)
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

// MARK: - Zoom de artista (seamless desde el círculo)
//
// Se presenta como overlay encima del cúmulo expandido. El héroe usa
// `matchedGeometryEffect` con el mismo id que la burbuja, de modo que la vista
// hace zoom *hacia* el círculo tocado mientras el resto se atenúa por detrás.
// La primera pantalla es el círculo enfocado sobre el cúmulo atenuado; el resto
// del detalle continúa hacia abajo (scroll), insinuado con un indicador sutil.

struct ArtistZoomView: View {
    let artist: LineupArtist
    let festivalAccent: Color
    @ObservedObject var player: FestivalPlayer
    let namespace: Namespace.ID
    let onClose: () -> Void

    @StateObject private var model = ArtistDetailViewModel()
    @State private var scrolled = false
    @State private var hintBounce = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var accent: Color { artist.accentColor ?? festivalAccent }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                // Scrim: deja ver el cúmulo atenuado arriba; opaco abajo para el detalle.
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.0),
                        .init(color: accent.opacity(0.55), location: 0.40),
                        .init(color: .black, location: 0.80)
                    ],
                    startPoint: .top, endPoint: .bottom
                )
                .ignoresSafeArea()
                .allowsHitTesting(false)

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        heroSection(height: geo.size.height,
                                    topInset: geo.safeAreaInsets.top)
                        detailSection
                    }
                }
                .scrollIndicators(.hidden)
                .onScrollGeometryChange(for: Bool.self) { scrollGeo in
                    scrollGeo.contentOffset.y > 24
                } action: { _, isScrolled in
                    withAnimation(.easeInOut(duration: 0.25)) { scrolled = isScrolled }
                }

                closeButton.padding(.horizontal)
            }
            .foregroundStyle(.white)
            .task { await model.load(artist) }
        }
    }

    // MARK: Héroe (primera pantalla)

    private func heroSection(height: CGFloat, topInset: CGFloat) -> some View {
        let heroSize = min(240, height * 0.32)
        return VStack(spacing: 16) {
            Spacer(minLength: topInset + 56)

            ZStack {
                Circle().fill(accent.gradient)
                if artist.imageURL != nil {
                    ArtistImage(artist: artist) { phase in
                        if let image = phase.image {
                            image.resizable().scaledToFill()
                        } else {
                            Text(initials).font(.system(size: 52, weight: .bold))
                        }
                    }
                    .clipShape(Circle())
                } else {
                    Text(initials).font(.system(size: 52, weight: .bold))
                }
            }
            .frame(width: heroSize, height: heroSize)
            .overlay(Circle().stroke(.white.opacity(0.3), lineWidth: 1))
            .shadow(color: .black.opacity(0.4), radius: 16, y: 8)
            .matchedGeometryEffect(id: artist.id, in: namespace, isSource: true)

            Text(artist.name)
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Tag(text: artist.tier.displayName, filled: true, accent: accent)

            Spacer()
            scrollHint
        }
        .frame(height: height * 0.86)
        .frame(maxWidth: .infinity)
    }

    // Insinúa que la vista continúa hacia abajo.
    private var scrollHint: some View {
        VStack(spacing: 4) {
            Text("Desliza para ver más")
                .font(.caption.weight(.medium))
                .foregroundStyle(.white.opacity(0.7))
            Image(systemName: "chevron.down")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.8))
                .offset(y: hintBounce ? 4 : -2)
        }
        .opacity(scrolled ? 0 : 1)
        .padding(.bottom, 18)
        .onAppear {
            // Respeta "Reducir movimiento": sin el rebote infinito (que además
            // mantendría un timer corriendo). El chevron queda estático.
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true)) {
                hintBounce = true
            }
        }
    }

    // MARK: Detalle (continúa hacia abajo)

    private var detailSection: some View {
        VStack(spacing: 20) {
            metadata
            playButton
            topSongsSection
        }
        .padding()
        .padding(.bottom, 48)
        .frame(maxWidth: .infinity)
        .background(.black)
    }

    private var metadata: some View {
        FlowChips {
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
            Task { await player.playMix(for: [artist]) }
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

    private var closeButton: some View {
        HStack {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(12)
                    .background(.black.opacity(0.3), in: Circle())
            }
            .accessibilityLabel("Cerrar")
            Spacer()
        }
    }

    private var initials: String {
        artist.name
            .split(separator: " ").prefix(2)
            .compactMap { $0.first }
            .map(String.init).joined().uppercased()
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
