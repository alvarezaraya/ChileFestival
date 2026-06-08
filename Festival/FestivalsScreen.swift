import SwiftUI

// MARK: - Pantalla raíz: paginado horizontal (un festival por página)

struct FestivalsScreen: View {
    let feed: FestivalFeed
    @StateObject private var player = FestivalPlayer()

    var body: some View {
        TabView {
            ForEach(Array(feed.festivals.enumerated()), id: \.element.id) { index, festival in
                FestivalPage(festival: festival, player: player,
                             pageIndex: index, pageCount: feed.festivals.count)
            }
        }
        // Indicador propio (debajo del botón); se oculta el del TabView.
        .tabViewStyle(.page(indexDisplayMode: .never))
        .background(.black)
        .onDisappear { player.stop() }
    }
}

// MARK: - Página de un festival

struct FestivalPage: View {
    let festival: Festival
    @ObservedObject var player: FestivalPlayer
    let pageIndex: Int
    let pageCount: Int
    @State private var selectedDay: Int? = nil   // nil = todos los días
    @State private var selectedArtist: LineupArtist?

    private var dayArtists: [LineupArtist] {
        festival.artists(onDay: selectedDay)
            .sorted { $0.billingWeight > $1.billingWeight }
    }

    var body: some View {
        VStack(spacing: 12) {
            header
            daySelector
            FestivalClusterView(artists: dayArtists, accent: festival.accentColor) { artist in
                selectedArtist = artist
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            playBar
            if pageCount > 1 { pageDots }
        }
        .padding()
        .background(
            LinearGradient(colors: [festival.accentColor.opacity(0.35), .black],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        )
        .foregroundStyle(.white)
        .sheet(item: $selectedArtist) { artist in
            ArtistDetailView(artist: artist,
                             festivalAccent: festival.accentColor,
                             player: player)
                .preferredColorScheme(.dark)
        }
    }

    // Indicador de página propio, ubicado bajo la barra de reproducción.
    private var pageDots: some View {
        HStack(spacing: 7) {
            ForEach(0..<pageCount, id: \.self) { i in
                Circle()
                    .fill(.white.opacity(i == pageIndex ? 0.95 : 0.35))
                    .frame(width: 7, height: 7)
            }
        }
        .padding(.top, 2)
    }

    private var header: some View {
        VStack(spacing: 2) {
            Text(festival.name).font(.title2.bold())
            Text("\(festival.venue) · \(festival.city)")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.7))
        }
    }

    private var daySelector: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Chip(title: "Todos", selected: selectedDay == nil) { selectedDay = nil }
                ForEach(1...max(festival.dayCount, 1), id: \.self) { day in
                    Chip(title: "Día \(day)", selected: selectedDay == day) { selectedDay = day }
                }
            }
            .padding(.horizontal, 2)
        }
    }

    @ViewBuilder private var playBar: some View {
        if player.isActive {
            MiniPlayerView(player: player, accent: festival.accentColor)
        } else {
            Button {
                Task { await player.playMix(for: dayArtists) }
            } label: {
                HStack {
                    Image(systemName: "play.fill")
                    Text(idleLabel).fontWeight(.semibold).lineLimit(1)
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(festival.accentColor, in: Capsule())
                .foregroundStyle(.white)
            }
        }
    }

    private var idleLabel: String {
        switch player.mode {
        case .needsAuthorization: "Autoriza Apple Music"
        case .error(let msg):     msg
        default:                  "Reproducir cartel"
        }
    }
}

// MARK: - Chip de día

private struct Chip: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(selected ? .white.opacity(0.9) : .white.opacity(0.15), in: Capsule())
                .foregroundStyle(selected ? .black : .white)
        }
    }
}
