import SwiftUI
import MusicKit
import Combine

// MARK: - Catálogo: resolución de artista + top songs (fuente única)
//
// No pide autorización: el llamador debe asegurarla antes (FestivalPlayer la
// pide una vez por mix; ArtistDetailViewModel la pide al abrir el detalle).

enum ArtistCatalog {

    static func topSongs(for artist: LineupArtist, limit: Int) async throws -> [Song] {
        let catalogArtist: MusicKit.Artist
        if let id = artist.appleMusicArtistID {
            let request = MusicCatalogResourceRequest<MusicKit.Artist>(
                matching: \.id, equalTo: MusicItemID(id))
            guard let found = try await request.response().items.first else { return [] }
            catalogArtist = found
        } else {
            var search = MusicCatalogSearchRequest(term: artist.name,
                                                   types: [MusicKit.Artist.self])
            search.limit = 1
            guard let found = try await search.response().artists.first else { return [] }
            catalogArtist = found
        }
        let detailed = try await catalogArtist.with([.topSongs])
        return Array((detailed.topSongs ?? []).prefix(limit))
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

// MARK: - Detalle de artista

struct ArtistDetailView: View {
    let artist: LineupArtist
    let festivalAccent: Color
    @ObservedObject var player: FestivalPlayer

    @StateObject private var model = ArtistDetailViewModel()
    @Environment(\.dismiss) private var dismiss

    private var accent: Color { artist.accentColor ?? festivalAccent }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                hero
                metadata
                playButton
                topSongsSection
            }
            .padding()
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            LinearGradient(colors: [accent.opacity(0.45), .black],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        )
        .foregroundStyle(.white)
        .overlay(alignment: .topTrailing) { closeButton }
        .task { await model.load(artist) }
    }

    // MARK: Hero

    private var hero: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle().fill(accent.gradient)
                if let url = artist.imageURL {
                    AsyncImage(url: url) { $0.resizable().scaledToFill() }
                        placeholder: { Color.clear }
                        .clipShape(Circle())
                } else {
                    Text(initials)
                        .font(.system(size: 48, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 150, height: 150)
            .overlay(Circle().stroke(.white.opacity(0.25), lineWidth: 1))
            .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
            .padding(.top, 32)

            Text(artist.name)
                .font(.title.bold())
                .multilineTextAlignment(.center)
        }
    }

    // MARK: Metadata (tier · día · géneros)

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

    // MARK: Botón de reproducción

    private var playButton: some View {
        Button {
            Task { await player.playMix(for: [artist]) }
            dismiss()
        } label: {
            HStack {
                Image(systemName: "play.fill")
                Text("Reproducir top songs").fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(accent, in: Capsule())
            .foregroundStyle(.white)
        }
    }

    // MARK: Top songs

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

    // MARK: Cerrar

    private var closeButton: some View {
        Button { dismiss() } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.title2)
                .foregroundStyle(.white.opacity(0.6))
                .padding()
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
