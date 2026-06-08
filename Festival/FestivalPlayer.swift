import Foundation
import MusicKit
import AVFoundation
import Combine

@MainActor
final class FestivalPlayer: ObservableObject {

    enum Mode: Equatable {
        case idle, loading, fullPlayback, previewPlayback, needsAuthorization
        case error(String)
    }

    @Published private(set) var mode: Mode = .idle
    @Published private(set) var isPlaying = false
    @Published private(set) var nowPlayingTitle: String?
    @Published private(set) var nowPlayingArtist: String?
    @Published private(set) var artworkURL: URL?

    /// Cuántas de las top songs de cada artista entran al mix.
    var songsPerArtist = 3

    var isActive: Bool {
        switch mode {
        case .fullPlayback, .previewPlayback, .loading: true
        default: false
        }
    }

    private let player = ApplicationMusicPlayer.shared
    private var cancellables = Set<AnyCancellable>()

    // Backend de previews (sin suscripción).
    private var previewQueue: AVQueuePlayer?
    private var previewSongs: [Song] = []
    private var previewURLs: [URL] = []
    private var previewIndex = 0
    private var previewEndToken: NSObjectProtocol?

    // MARK: - Acción principal

    func playMix(for artists: [LineupArtist], storefront: String = "cl") async {
        teardownObservers()
        mode = .loading

        guard await MusicAuthorization.request() == .authorized else {
            mode = .needsAuthorization; return
        }
        do {
            var pools: [[Song]] = []
            for artist in artists {
                let songs = try await topSongs(for: artist)
                if !songs.isEmpty { pools.append(songs) }
            }
            guard !pools.isEmpty else {
                mode = .error("No encontré canciones para este cartel."); return
            }
            let mix = interleaveShuffle(pools)

            let subscription = try? await MusicSubscription.current
            if subscription?.canPlayCatalogContent == true {
                try await playFull(mix)
            } else {
                playPreviews(mix)
            }
        } catch {
            mode = .error(error.localizedDescription)
        }
    }

    // MARK: - Controles

    func togglePlayPause() {
        if let queue = previewQueue {
            isPlaying ? queue.pause() : queue.play()
            isPlaying.toggle()
        } else {
            Task {
                if isPlaying { player.pause() } else { try? await player.play() }
            }
        }
    }

    func next() async {
        if previewQueue != nil { startPreview(at: previewIndex + 1) }
        else { try? await player.skipToNextEntry() }
    }

    func previous() async {
        if previewQueue != nil { startPreview(at: max(0, previewIndex - 1)) }
        else { try? await player.skipToPreviousEntry() }
    }

    func stop() {
        player.stop()
        previewQueue?.pause()
        previewQueue = nil
        teardownObservers()
        isPlaying = false
        nowPlayingTitle = nil; nowPlayingArtist = nil; artworkURL = nil
        mode = .idle
    }

    // MARK: - Top songs

    private func topSongs(for artist: LineupArtist) async throws -> [Song] {
        try await ArtistCatalog.topSongs(for: artist, limit: songsPerArtist)
    }

    private func interleaveShuffle(_ pools: [[Song]]) -> [Song] {
        var pools = pools.map { $0.shuffled() }
        var result: [Song] = []
        var keepGoing = true
        while keepGoing {
            keepGoing = false
            for i in pools.indices where !pools[i].isEmpty {
                result.append(pools[i].removeFirst()); keepGoing = true
            }
        }
        return result
    }

    // MARK: - Reproducción completa (con suscripción)

    private func playFull(_ songs: [Song]) async throws {
        previewQueue = nil
        player.queue = ApplicationMusicPlayer.Queue(for: songs)
        player.state.shuffleMode = .off
        try await player.play()
        mode = .fullPlayback
        observeFullPlayback()
    }

    private func observeFullPlayback() {
        // Título/carátula en vivo: la cola es Observable.
        player.queue.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.refreshFullMetadata() }
            .store(in: &cancellables)
        // Estado play/pause en vivo.
        player.state.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                guard let self else { return }
                self.isPlaying = self.player.state.playbackStatus == .playing
            }
            .store(in: &cancellables)

        isPlaying = player.state.playbackStatus == .playing
        refreshFullMetadata()
    }

    private func refreshFullMetadata() {
        let entry = player.queue.currentEntry
        nowPlayingTitle = entry?.title
        nowPlayingArtist = entry?.subtitle
        artworkURL = entry?.artwork?.url(width: 120, height: 120)
    }

    // MARK: - Previews de 30 s (sin suscripción)

    private func playPreviews(_ mix: [Song]) {
        previewSongs = mix.filter { $0.previewAssets?.first?.url != nil }
        previewURLs = previewSongs.compactMap { $0.previewAssets?.first?.url }
        guard !previewURLs.isEmpty else {
            mode = .error("No hay previews disponibles."); return
        }
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)
        mode = .previewPlayback
        startPreview(at: 0)
    }

    /// Reconstruye la AVQueuePlayer desde `index` (permite ir hacia atrás).
    private func startPreview(at index: Int) {
        guard previewURLs.indices.contains(index) else { stop(); return }
        previewIndex = index
        removePreviewObserver()

        let items = previewURLs[index...].map(AVPlayerItem.init)
        let queue = AVQueuePlayer(items: Array(items))
        previewQueue = queue

        previewEndToken = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.advancePreview() }
            }

        queue.play()
        isPlaying = true
        refreshPreviewMetadata()
    }

    private func advancePreview() {
        previewIndex += 1
        if previewIndex >= previewSongs.count { stop(); return }
        refreshPreviewMetadata()   // la AVQueuePlayer ya avanzó sola
    }

    private func refreshPreviewMetadata() {
        guard previewSongs.indices.contains(previewIndex) else { return }
        let song = previewSongs[previewIndex]
        nowPlayingTitle = song.title
        nowPlayingArtist = song.artistName
        artworkURL = song.artwork?.url(width: 120, height: 120)
    }

    // MARK: - Limpieza

    private func teardownObservers() {
        cancellables.removeAll()
        removePreviewObserver()
    }

    private func removePreviewObserver() {
        if let token = previewEndToken {
            NotificationCenter.default.removeObserver(token)
            previewEndToken = nil
        }
    }
}
