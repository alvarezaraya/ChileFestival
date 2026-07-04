import Foundation
import MusicKit
import AVFoundation
import MediaPlayer
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
    // Now Playing (pantalla bloqueada / Centro de Control) para los previews.
    // En reproducción completa no se toca: la cola es de la app Música y el
    // sistema ya publica su metadata.
    private var remoteCommandsActive = false
    private var artworkFetchTask: Task<Void, Never>?

    // MARK: - Acción principal

    func playMix(for artists: [LineupArtist], storefront: String = "cl") async {
        teardownObservers()
        mode = .loading

        guard await MusicAuthorization.request() == .authorized else {
            mode = .needsAuthorization; return
        }
        // Top songs de todos los artistas EN PARALELO (concurrencia acotada):
        // en serie, un cartel grande eran decenas de round-trips encadenados y
        // el play tardaba varios segundos en arrancar.
        let (pools, firstError) = await topSongPools(for: artists)
        guard !pools.isEmpty else {
            mode = .error(firstError?.localizedDescription
                          ?? "No encontré canciones para este cartel.")
            return
        }
        await startPlayback(interleaveShuffle(pools))
    }

    /// Reproduce una lista ya resuelta (p. ej. las top songs que el detalle del
    /// artista ya muestra), sin volver a consultar el catálogo.
    func playSongs(_ songs: [Song]) async {
        teardownObservers()
        mode = .loading

        guard await MusicAuthorization.request() == .authorized else {
            mode = .needsAuthorization; return
        }
        guard !songs.isEmpty else {
            mode = .error("No encontré canciones."); return
        }
        await startPlayback(songs)
    }

    private func startPlayback(_ songs: [Song]) async {
        let subscription = try? await MusicSubscription.current
        if subscription?.canPlayCatalogContent == true {
            do { try await playFull(songs) }
            catch { mode = .error(error.localizedDescription) }
        } else {
            playPreviews(songs)
        }
    }

    // MARK: - Controles

    func togglePlayPause() {
        if previewQueue != nil {
            setPreviewPlaying(!isPlaying)
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
        stopPreviewBackend()
        teardownObservers()
        observingSystem = false
        isPlaying = false
        nowPlayingTitle = nil; nowPlayingArtist = nil; artworkURL = nil
        mode = .idle
    }

    // MARK: - Top songs

    /// Resuelve las top songs de cada artista en paralelo (máx. 6 consultas
    /// simultáneas para no gatillar rate-limiting del catálogo), preservando el
    /// orden del cartel. Los artistas que fallen o vengan vacíos se omiten; se
    /// devuelve el primer error por si TODOS fallaron (p. ej. sin red).
    private func topSongPools(for artists: [LineupArtist])
        async -> (pools: [[Song]], firstError: Error?) {
        var pools = [[Song]?](repeating: nil, count: artists.count)
        var firstError: Error?
        let limit = songsPerArtist
        await withTaskGroup(of: (Int, Result<[Song], Error>).self) { group in
            var iterator = artists.enumerated().makeIterator()
            func addNext() {
                guard let (i, artist) = iterator.next() else { return }
                group.addTask {
                    do { return (i, .success(try await ArtistCatalog.topSongs(for: artist, limit: limit))) }
                    catch { return (i, .failure(error)) }
                }
            }
            for _ in 0..<6 { addNext() }
            while let (i, result) = await group.next() {
                switch result {
                case .success(let songs): pools[i] = songs
                case .failure(let error): if firstError == nil { firstError = error }
                }
                addNext()
            }
        }
        return (pools.compactMap { $0 }.filter { !$0.isEmpty }, firstError)
    }

    /// Baraja cada pool y las intercala round-robin: todos los artistas quedan
    /// representados desde el comienzo del mix.
    private func interleaveShuffle(_ pools: [[Song]]) -> [Song] {
        ArtistCatalog.interleave(pools.map { $0.shuffled() })
    }

    // MARK: - Reproducción completa (con suscripción)

    private func playFull(_ songs: [Song]) async throws {
        stopPreviewBackend()
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
        activateRemoteCommands()
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
        updateNowPlayingInfo()
    }

    // MARK: - Now Playing + controles remotos (solo previews)

    private func setPreviewPlaying(_ playing: Bool) {
        guard let queue = previewQueue else { return }
        playing ? queue.play() : queue.pause()
        isPlaying = playing
        updateNowPlayingInfo()
    }

    /// Publica el preview actual en la pantalla bloqueada / Centro de Control.
    /// La carátula llega después (descarga cacheada) y se re-publica al llegar.
    private func updateNowPlayingInfo() {
        guard let queue = previewQueue else { return }
        var info: [String: Any] = [
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0
        ]
        if let nowPlayingTitle { info[MPMediaItemPropertyTitle] = nowPlayingTitle }
        if let nowPlayingArtist { info[MPMediaItemPropertyArtist] = nowPlayingArtist }
        if let item = queue.currentItem {
            let duration = item.duration.seconds
            if duration.isFinite, duration > 0 {
                info[MPMediaItemPropertyPlaybackDuration] = duration
            }
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = item.currentTime().seconds
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info

        artworkFetchTask?.cancel()
        guard let url = artworkURL else { return }
        artworkFetchTask = Task { [weak self] in
            guard let image = await ArtworkImageCache.shared.image(for: url, maxPixel: 600),
                  !Task.isCancelled, let self, self.previewQueue != nil else { return }
            var current = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
            current[MPMediaItemPropertyArtwork] =
                MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            MPNowPlayingInfoCenter.default().nowPlayingInfo = current
        }
    }

    /// Engancha play/pausa/siguiente/anterior del sistema al backend de
    /// previews (idempotente). En reproducción completa no hace falta: los
    /// controles remotos ya los maneja la app Música.
    private func activateRemoteCommands() {
        guard !remoteCommandsActive else { return }
        remoteCommandsActive = true
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.setPreviewPlaying(true) }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.setPreviewPlaying(false) }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlayPause() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in await self?.next() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in await self?.previous() }
            return .success
        }
    }

    private func deactivateRemoteCommands() {
        guard remoteCommandsActive else { return }
        remoteCommandsActive = false
        let center = MPRemoteCommandCenter.shared()
        [center.playCommand, center.pauseCommand, center.togglePlayPauseCommand,
         center.nextTrackCommand, center.previousTrackCommand]
            .forEach { $0.removeTarget(nil) }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    /// Suelta TODO el backend de previews: cola, carátula en vuelo, controles
    /// remotos, Now Playing y la sesión de audio (devuelve el audio a otras
    /// apps). No toca el reproductor del sistema.
    private func stopPreviewBackend() {
        guard previewQueue != nil || remoteCommandsActive else { return }
        previewQueue?.pause()
        previewQueue = nil
        artworkFetchTask?.cancel()
        artworkFetchTask = nil
        deactivateRemoteCommands()
        try? AVAudioSession.sharedInstance().setActive(
            false, options: .notifyOthersOnDeactivation)
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
