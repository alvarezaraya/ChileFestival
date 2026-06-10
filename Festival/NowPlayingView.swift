import SwiftUI

/// Reproductor a pantalla completa propio de la app. Controla la misma cola del
/// sistema (app Música) vía `FestivalPlayer`: carátula grande, transporte y un
/// acceso secundario para saltar a la app Música.
struct NowPlayingView: View {
    @ObservedObject var player: FestivalPlayer
    let accent: Color
    let onClose: () -> Void

    @Environment(\.openURL) private var openURL

    var body: some View {
        ZStack {
            background
            VStack(spacing: 0) {
                grabber
                Spacer(minLength: 8)
                artwork
                Spacer(minLength: 24)
                titleBlock
                Spacer(minLength: 32)
                controls
                Spacer(minLength: 24)
                openInMusic
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 28)
            .foregroundStyle(.white)
        }
    }

    // MARK: - Piezas

    private var background: some View {
        LinearGradient(colors: [accent.opacity(0.55), .black],
                       startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
    }

    private var grabber: some View {
        Capsule()
            .fill(.white.opacity(0.4))
            .frame(width: 40, height: 5)
            .padding(.top, 10)
            .contentShape(Rectangle())
            .onTapGesture { onClose() }
            .accessibilityLabel("Cerrar reproductor")
            .accessibilityAddTraits(.isButton)
    }

    private var artwork: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(accent.gradient)
            if let url = player.artworkURL {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        Image(systemName: "music.note")
                            .font(.system(size: 64))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                }
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: 64))
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.45), radius: 24, y: 14)
        .scaleEffect(player.isPlaying ? 1 : 0.92)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: player.isPlaying)
    }

    private var titleBlock: some View {
        VStack(spacing: 6) {
            Text(player.nowPlayingTitle ?? "—")
                .font(.title2.bold())
                .lineLimit(1)
            Text(player.nowPlayingArtist ?? "")
                .font(.title3)
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)
            if player.mode == .previewPlayback {
                Text("Preview · 30 s")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(.white.opacity(0.15), in: Capsule())
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .multilineTextAlignment(.center)
    }

    private var controls: some View {
        // Tres tercios iguales del ancho disponible: el play/pausa queda fijo al
        // centro aunque el icono cambie de ancho, y los laterales balanceados.
        HStack(spacing: 0) {
            Button { Task { await player.previous() } } label: {
                Image(systemName: "backward.fill")
                    .font(.title)
                    .frame(maxWidth: .infinity)
            }
            .accessibilityLabel("Anterior")
            Button { player.togglePlayPause() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 52))
                    .frame(maxWidth: .infinity)
            }
            .accessibilityLabel(player.isPlaying ? "Pausar" : "Reproducir")
            Button { Task { await player.next() } } label: {
                Image(systemName: "forward.fill")
                    .font(.title)
                    .frame(maxWidth: .infinity)
            }
            .accessibilityLabel("Siguiente")
        }
        .frame(maxWidth: .infinity)
        .foregroundStyle(.white)
    }

    private var openInMusic: some View {
        Button {
            openURL(player.musicAppURL)
        } label: {
            Label("Abrir en Música", systemImage: "arrow.up.forward.app")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 18).padding(.vertical, 10)
                .background(.white.opacity(0.15), in: Capsule())
        }
        .foregroundStyle(.white)
    }
}
