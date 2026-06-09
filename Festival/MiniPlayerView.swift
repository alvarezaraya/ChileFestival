import SwiftUI

struct MiniPlayerView: View {
    @ObservedObject var player: FestivalPlayer
    let accent: Color
    var onTap: () -> Void = {}

    var body: some View {
        HStack(spacing: 12) {
            // Zona tappable (carátula + texto) que abre el reproductor completo.
            // Los botones de control de la derecha capturan su propio toque.
            HStack(spacing: 12) {
                artwork
                VStack(alignment: .leading, spacing: 2) {
                    Text(titleText)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(subtitleText)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
            }
            .contentShape(Rectangle())
            .onTapGesture { onTap() }

            controls
        }
        .padding(8)
        // Al estar reproduciendo, la píldora es Liquid Glass transparente.
        .glassEffect(.clear, in: Capsule())
    }

    private var artwork: some View {
        ZStack {
            Circle().fill(accent.gradient)
            if let url = player.artworkURL {
                AsyncImage(url: url) { $0.resizable().scaledToFill() }
                    placeholder: { Color.clear }
                    .clipShape(Circle())
            } else {
                Image(systemName: "music.note").foregroundStyle(.white)
            }
        }
        .frame(width: 40, height: 40)
    }

    private var controls: some View {
        HStack(spacing: 18) {
            Button { Task { await player.previous() } } label: {
                Image(systemName: "backward.fill")
            }
            Button { player.togglePlayPause() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
            }
            Button { Task { await player.next() } } label: {
                Image(systemName: "forward.fill")
            }
        }
        .foregroundStyle(.white)
        .padding(.trailing, 6)
        .disabled(player.mode == .loading)
    }

    private var titleText: String {
        player.mode == .loading ? "Cargando mix…" : (player.nowPlayingTitle ?? "—")
    }

    private var subtitleText: String {
        if player.mode == .previewPlayback {
            return "Preview 30 s · \(player.nowPlayingArtist ?? "")"
        }
        return player.nowPlayingArtist ?? ""
    }
}
