#if os(macOS)
import AVFoundation
import AppKit
import Combine
import GoldfishCore
import MediaPlayer
import SwiftUI

/// Eigenständiger Audio-Player für Musik-Bibliotheken — bewusst NICHT `PlayerView`
/// (die ist auf Video/Vollbild zugeschnitten, siehe `PlayerLaunchCoordinator`).
/// User-Wunsch 2026-09-11: "eigenes Musikfenster ... mit eigenen Steuerbuttons und
/// eigenem Player" — dieser Coordinator hält die Queue + `AVPlayer`-Instanz für die
/// persistente Mini-Leiste (`MusicPlayerBar`), die über `MainTabView` als
/// `.safeAreaInset(edge: .bottom)` immer sichtbar bleibt, unabhängig von der Navigation
/// (analog zum `#miniPlayer` im Browser, der ebenfalls außerhalb von `#grid` im DOM sitzt).
///
/// Phase 1 (Mac only, siehe Diskussion 2026-09-11) — iOS/tvOS-Wiring bewusst noch nicht
/// angefasst, um deren fragile TabView-/Fokus-Anpassungen (siehe RootView.swift-Kommentare)
/// nicht mit zu riskieren.
@MainActor
final class MusicPlayerEngine: ObservableObject {
    static let shared = MusicPlayerEngine()

    @Published private(set) var queue: [Item] = []
    @Published private(set) var currentIndex: Int?
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var errorMessage: String?
    /// true während `playback(itemId:)` läuft — Mini-Leiste zeigt dann einen Spinner
    /// statt der (noch nicht bekannten) Fortschrittsanzeige.
    @Published private(set) var isLoading = false
    /// Zufallswiedergabe (User-Wunsch 2026-09-11: "was haben andere Musikplayer" —
    /// Shuffle fehlte komplett). Bewusst KEINE physische Neuordnung von `queue`
    /// (würde die sichtbare Reihenfolge in `MusicQueueView` verfälschen) —
    /// `next()` wählt bei aktivem Shuffle stattdessen einen zufälligen anderen
    /// Index, `queue` bleibt die "echte" Albumreihenfolge.
    @Published var isShuffling = false
    @Published var repeatMode: RepeatMode = .off

    enum RepeatMode {
        case off, all, one

        mutating func cycle() {
            switch self {
            case .off: self = .all
            case .all: self = .one
            case .one: self = .off
            }
        }

        var systemImage: String {
            switch self {
            case .off: return "repeat"
            case .all: return "repeat"
            case .one: return "repeat.1"
            }
        }
    }

    private var player: AVPlayer?
    private var timeObserverToken: Any?
    private var endObserver: NSObjectProtocol?
    private var albumArtCache: [Int64: NSImage] = [:]
    private var loadSeq = 0

    var currentItem: Item? {
        guard let currentIndex, queue.indices.contains(currentIndex) else { return nil }
        return queue[currentIndex]
    }

    private init() {
        configureRemoteCommands()
    }

    /// Startet Wiedergabe einer neuen Queue ab `startIndex` — Klick auf einen Titel in
    /// `MusicAlbumDetailView`/`MusicLibraryView`. Ruft ausschließlich innerhalb dieser
    /// Bibliothek gehörende Tracks als Queue durch, analog zu `state.playQueue` im Browser.
    func play(queue: [Item], startIndex: Int, client: GoldfishClient) {
        self.queue = queue
        self.currentIndex = startIndex
        Task { await loadAndPlayCurrent(client: client) }
    }

    func togglePlayPause() {
        guard let player else { return }
        if isPlaying {
            player.pause()
        } else {
            player.play()
        }
        isPlaying.toggle()
        updateNowPlayingPlaybackState()
    }

    func next(client: GoldfishClient) {
        guard let currentIndex, !queue.isEmpty else { return }
        // Repeat-Eins hat immer Vorrang, unabhängig von Shuffle — Konvention
        // jedes gängigen Musik-Players (Spotify/Apple Music/Browser).
        if repeatMode == .one {
            seek(to: 0)
            player?.play()
            isPlaying = true
            updateNowPlayingPlaybackState()
            return
        }
        if isShuffling, queue.count > 1 {
            var newIndex = currentIndex
            while newIndex == currentIndex {
                newIndex = Int.random(in: queue.indices)
            }
            self.currentIndex = newIndex
            Task { await loadAndPlayCurrent(client: client) }
            return
        }
        if currentIndex + 1 < queue.count {
            self.currentIndex = currentIndex + 1
        } else if repeatMode == .all {
            self.currentIndex = 0
        } else {
            return // Ende der Warteschlange, kein Repeat — Wiedergabe stoppt.
        }
        Task { await loadAndPlayCurrent(client: client) }
    }

    /// Direkter Sprung zu einem Titel in der Warteschlange (`MusicQueueView`-Tap).
    func jump(to index: Int, client: GoldfishClient) {
        guard queue.indices.contains(index) else { return }
        currentIndex = index
        Task { await loadAndPlayCurrent(client: client) }
    }

    /// Entfernt einen Titel aus der laufenden Warteschlange (`MusicQueueView`).
    /// Der gerade spielende Titel selbst lässt sich NICHT entfernen (dafür gibt
    /// es "Player schließen") — vermeidet den Sonderfall "aktueller Index
    /// verschwindet mitten in der Wiedergabe".
    func removeFromQueue(at index: Int) {
        guard queue.indices.contains(index), index != currentIndex else { return }
        queue.remove(at: index)
        if let currentIndex, index < currentIndex {
            self.currentIndex = currentIndex - 1
        }
    }

    func previous(client: GoldfishClient) {
        guard let currentIndex else { return }
        // Erste 3 Sekunden: zum vorherigen Titel springen (Spotify-Konvention). Danach:
        // aktuellen Titel neu starten — analog zu ⏮ auf jedem gängigen Musik-Player.
        if currentTime > 3 || currentIndex == 0 {
            seek(to: 0)
            return
        }
        self.currentIndex = currentIndex - 1
        Task { await loadAndPlayCurrent(client: client) }
    }

    func seek(to seconds: Double) {
        guard let player else { return }
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
        currentTime = seconds
        updateNowPlayingElapsedTime()
    }

    /// Schließt die Mini-Leiste (✕-Button) — stoppt die Wiedergabe komplett, anders als
    /// Pause (bewusst kein "weiterlaufen im Hintergrund ohne UI", der User soll die Leiste
    /// als echten "Player aus"-Schalter nutzen können).
    func stop() {
        player?.pause()
        player = nil
        if let timeObserverToken { player?.removeTimeObserver(timeObserverToken) }
        timeObserverToken = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        queue = []
        currentIndex = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    private func loadAndPlayCurrent(client: GoldfishClient) async {
        guard let item = currentItem else { return }
        loadSeq += 1
        let mySeq = loadSeq
        isLoading = true
        errorMessage = nil

        if let timeObserverToken { player?.removeTimeObserver(timeObserverToken) }
        timeObserverToken = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil

        // Offline-first, exakt wie PlayerView: ein heruntergeladener Track spielt lokal,
        // ganz ohne Server-Roundtrip (User-Wunsch 2026-09-11 "Offline-Synchronisation").
        // `DownloadManager` ist wie `GoldfishClient` ein App-weites Singleton (`.shared`),
        // deshalb hier direkt referenziert statt durch jeden Aufrufer durchgereicht.
        if let localURL = DownloadManager.shared.localFileURL(itemId: item.id) {
            let p = AVPlayer(url: localURL)
            player = p
            duration = item.durationSec ?? 0
            attachObservers(to: p, client: client)
            p.play()
            isPlaying = true
            isLoading = false
            updateNowPlayingInfo(client: client)
            return
        }

        do {
            let playback = try await client.playback(itemId: item.id)
            guard mySeq == loadSeq else { return } // User hat inzwischen weitergesprungen
            guard let streamURL = client.resolvedURL(forServerPath: playback.url) else {
                errorMessage = "Stream-URL konnte nicht ermittelt werden."
                isLoading = false
                return
            }
            let p = AVPlayer(url: streamURL)
            player = p
            duration = item.durationSec ?? 0
            attachObservers(to: p, client: client)
            p.play()
            isPlaying = true
            isLoading = false
            updateNowPlayingInfo(client: client)
        } catch {
            guard mySeq == loadSeq else { return }
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    private func attachObservers(to player: AVPlayer, client: GoldfishClient) {
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] time in
            guard let self else { return }
            self.currentTime = time.seconds.isFinite ? time.seconds : 0
            self.updateNowPlayingElapsedTime()
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: player.currentItem, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.next(client: client)
        }
    }

    // MARK: - MPNowPlayingInfoCenter / Systemsteuerung

    /// Native App-Vorteil gegenüber dem Browser (der das nicht kann): Sperrbildschirm,
    /// Kopfhörer-/Tastatur-Medientasten, Control Center steuern die Wiedergabe direkt.
    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            guard let self, let player = self.player, !self.isPlaying else { return .commandFailed }
            player.play()
            self.isPlaying = true
            self.updateNowPlayingPlaybackState()
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            guard let self, let player = self.player, self.isPlaying else { return .commandFailed }
            player.pause()
            self.isPlaying = false
            self.updateNowPlayingPlaybackState()
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            guard let self, let client = self.lastClient else { return .commandFailed }
            self.next(client: client)
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            guard let self, let client = self.lastClient else { return .commandFailed }
            self.previous(client: client)
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self, let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self.seek(to: event.positionTime)
            return .success
        }
    }

    /// `nextTrackCommand`/`previousTrackCommand` brauchen einen `client`, den die
    /// Remote-Command-Closures selbst nicht mitbekommen (MediaPlayer-API kennt keinen
    /// Callback-Parameter dafür) — deshalb hier gemerkt, bei jedem `play(...)` aktualisiert.
    private weak var lastClient: GoldfishClient?

    private func updateNowPlayingInfo(client: GoldfishClient) {
        lastClient = client
        guard let item = currentItem else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: item.displayTitle,
            MPMediaItemPropertyArtist: item.artist ?? "",
            MPMediaItemPropertyAlbumTitle: item.album ?? "",
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: 1.0,
        ]
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        guard let albumId = item.musicAlbumId else { return }
        Task {
            if let art = await loadAlbumArt(albumId: albumId, client: client) {
                info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: art.size) { _ in art }
                MPNowPlayingInfoCenter.default().nowPlayingInfo = info
            }
        }
    }

    private func updateNowPlayingElapsedTime() {
        guard var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func updateNowPlayingPlaybackState() {
        guard var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func loadAlbumArt(albumId: Int64, client: GoldfishClient) async -> NSImage? {
        if let cached = albumArtCache[albumId] { return cached }
        guard let url = client.albumCoverURL(albumId: albumId) else { return nil }
        guard let (data, _) = try? await URLSession.shared.data(from: url), let image = NSImage(data: data) else { return nil }
        albumArtCache[albumId] = image
        return image
    }
}
#endif
