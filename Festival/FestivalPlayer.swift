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

    // SystemMusicPlayer = el reproductor de la app Música del sistema. La cola y
    // el "now playing" se comparten: lo que encolamos suena en Música, y lo que
    // el usuario haga en Música (cambiar de tema, pausar) se refleja aquí.
    private let player = SystemMusicPlayer.shared
    private var cancellables = Set<AnyCancellable>()
    private var observingSystem = false

    /// URL para "Abrir en Música": la página de la canción actual si la conocemos
    /// (abre Música justo ahí), o el esquema `music://` como respaldo (la cola es
    /// compartida, así que Música muestra lo mismo que suena).
    var musicAppURL: URL {
        if previewQueue != nil, previewSongs.indices.contains(previewIndex),
           let url = previewSongs[previewIndex].url {
            return url
        }
        if let song = player.queue.currentEntry?.item as? Song, let url = song.url {
            return url
        }
        return URL(string: "music://")!
    }

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
        // No detenemos el reproductor del sistema (= app Música): su cola es
        // compartida y el usuario espera que Música siga sonando al salir.
        // Solo soltamos nuestro backend de previews y los observers.
        previewQueue?.pause()
        previewQueue = nil
        teardownObservers()
        observingSystem = false
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
        player.queue = SystemMusicPlayer.Queue(for: songs)
        player.state.shuffleMode = .off
        try await player.play()
        mode = .fullPlayback
        observeSystemPlayback()
    }

    /// Engancha los observers del reproductor del sistema (idempotente). A partir
    /// de aquí, cualquier cambio en la app Música —tema, play/pause, carátula—
    /// se refleja en la UI, y nuestros controles manejan esa misma reproducción.
    private func observeSystemPlayback() {
        guard !observingSystem else { syncFromSystem(); return }
        observingSystem = true

        // Título/carátula en vivo: la cola es Observable.
        player.queue.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.syncFromSystem() }
            .store(in: &cancellables)
        // Estado play/pause en vivo.
        player.state.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.syncFromSystem() }
            .store(in: &cancellables)

        syncFromSystem()
    }

    /// Vuelca el estado actual de la app Música a las propiedades publicadas.
    private func syncFromSystem() {
        // Si estamos en modo preview (sin suscripción), ese backend manda.
        guard previewQueue == nil else { return }

        isPlaying = player.state.playbackStatus == .playing
        let entry = player.queue.currentEntry
        nowPlayingTitle = entry?.title
        nowPlayingArtist = entry?.subtitle
        artworkURL = entry?.artwork?.url(width: 600, height: 600)

        // Muestra/oculta el mini-player según haya algo cargado en Música.
        if entry != nil {
            if !isFullPlayback { mode = .fullPlayback }
        } else if isFullPlayback {
            mode = .idle
        }
    }

    private var isFullPlayback: Bool {
        if case .fullPlayback = mode { return true }
        return false
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
        artworkURL = song.artwork?.url(width: 600, height: 600)
    }

    // MARK: - Limpieza

    private func teardownObservers() {
        cancellables.removeAll()
        observingSystem = false
        removePreviewObserver()
    }

    private func removePreviewObserver() {
        if let token = previewEndToken {
            NotificationCenter.default.removeObserver(token)
            previewEndToken = nil
        }
    }
}
