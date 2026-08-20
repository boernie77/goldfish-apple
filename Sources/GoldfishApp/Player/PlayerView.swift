import SwiftUI
import AVKit
import GoldfishCore
#if os(macOS)
import AppKit
#endif

/// Scope for "another random video" when the player was opened via 🔀 Zufällig —
/// lets ⏭ keep pulling fresh random items instead of just moving through a fixed list.
struct RandomContext {
    let libraryId: Int64?
    /// Set instead of `libraryId` for the global, multi-library shuffle (User-Anfrage
    /// 2026-08-19: "auf alle, oder auf eine Auswahl") — nil means either "single library"
    /// (use `libraryId`) or "all libraries" (both nil).
    var libraryIds: [Int64]? = nil
    /// The `ShuffleScope` selection, when active — takes priority over `libraryId`/
    /// `libraryIds`/`folder` entirely (mirrors the Browser's `randomParams()` priority:
    /// `state.shuffleFolders` wins over the currently open library/folder, CLAUDE.md
    /// "Ordner-Scoping für Shuffle" — User-Anfrage 2026-08-19: "so wie im Browser auch").
    var folderSelections: [ShuffleFolderSelection]? = nil
    let folder: String?
    let search: String?
}

struct PlayerView: View {
    /// Optional sibling list the item was opened from (a folder's items, a season's
    /// episodes, a home row, …) — powers the ⏮/⏭ buttons. Empty/absent when opened
    /// standalone (no prev/next shown).
    let queue: [Item]
    let randomContext: RandomContext?
    /// Set when the caller already asked "von Anfang oder von letzter Stelle" (see
    /// `ItemDetailView`'s play-resume prompt) and the user chose to restart — skips the
    /// resume-position lookup in `setUp()` entirely instead of fetching it and ignoring it.
    let startFromBeginning: Bool
    @State private var queueIndex: Int
    @State private var item: Item
    // History of visited items while in random mode — mirrors the web app's
    // shuffleHistory: ⏭ fetches a new random item and appends; ⏮ just walks back.
    @State private var randomHistory: [Item] = []
    @State private var randomHistoryIndex = 0
    @State private var isLoadingRandomNext = false

    @EnvironmentObject var client: GoldfishClient
    @EnvironmentObject var downloads: DownloadManager
    // Real change 2026-08-19: the player is now a genuine `WindowGroup(id: "player")` window
    // on macOS (not a `.sheet`), so closing it means closing that window explicitly —
    // `@Environment(\.dismiss)` targets sheet/fullScreenCover-style presentations, not a
    // top-level Window scene. `\.dismissWindow` would be the SwiftUI-native way to do this,
    // but it needs macOS 14 (this app targets 13) — `hostWindow?.close()` is the plain
    // `NSWindow` equivalent, available always. iOS keeps `fullScreenCover` + `dismiss()`.
    #if !os(macOS)
    @Environment(\.dismiss) private var dismiss
    #endif

    @State private var player: AVPlayer?
    @State private var errorMessage: String?
    @State private var resumeTimer: Timer?
    @State private var timeObserverToken: Any?
    @State private var didEndObserverToken: NSObjectProtocol?

    @State private var isPlaying = false
    @State private var currentTime: Double = 0
    @State private var duration: Double = 0
    // User-Anfrage 2026-08-19 (Folgerunde): "die gesehen werden nicht gesynct" trotz des
    // Teardown-Fixes — Verdacht: `.onDisappear` feuert nicht zuverlässig, wenn das
    // WindowGroup-Fenster über den nativen roten Schließen-Knopf statt den eigenen
    // "Schließen"-Button beendet wird (bekanntes Muster in dieser App, siehe die
    // AppDelegate-Fensterverwaltungs-Bugs). Fix: dieselbe 90%-Prüfung läuft jetzt auch im
    // periodischen 15s-Resume-Timer mit, nicht nur einmalig bei `teardown()` — deckt also
    // JEDE Art, den Player zu verlassen, ab, nicht nur den Klick auf den eigenen Button.
    // Flag verhindert wiederholte `setWatched`-Calls im selben Player-Life-Cycle.
    @State private var hasMarkedWatchedThisSession = false
    @State private var isScrubbing = false
    @State private var volume: Float = 1.0

    // HLS transcode sessions only produce output up to the current playback position —
    // seeking past that needs a brand-new session starting at the target offset (same
    // problem + fix as the web player's virtualOffset/session-restart, see CLAUDE.md
    // "Transcode-Seek"). `virtualOffset` is the absolute start-second of the *current*
    // AVPlayerItem; the player's own currentTime() is always relative to that.
    @State private var isTranscode = false
    @State private var transcodeURLTemplate: String?
    @State private var virtualOffset: Double = 0

    @State private var controlsVisible = true
    @State private var hideControlsTask: Task<Void, Never>?
    /// User-Anfrage 2026-08-19: Favoriten- und Playlist-Symbol auch im Steuerfeld —
    /// mirrors `ItemDetailView`'s `isFavorite`/`showingAddToPlaylist`, updated in `setUp()`
    /// from the (possibly changed, via ⏮/⏭) current `item`.
    @State private var isFavorite = false
    @State private var showingAddToPlaylist = false
    /// Actual decoded frame size (e.g. "1080p"), read from `AVPlayerItem.presentationSize`
    /// — the real rendered resolution, not just the source file's metadata, so it reflects
    /// a transcode profile downscale too. Mirrors the Browser's Buffer-Overlay convention
    /// (CLAUDE.md: "Auflösung aus video.videoWidth/Height — tatsächliche Render-Auflösung").
    /// User-Anfrage 2026-08-19: sichtbar solange die Steuerleiste eingeblendet ist.
    @State private var currentResolutionLabel: String?
    // User-Anfrage 2026-08-19: "Trickbilder" (Hover-Vorschau in der Scrub-Leiste) — nutzt
    // dieselben Endpoints wie der Browser (`/api/trickplay/{id}/thumbs.vtt`+`sprite.jpg`),
    // siehe CLAUDE.md "Trickplay (Hover-Vorschau)". Leer bleiben (kein Fehler), wenn der
    // Server noch keine Daten hat (`item.trickplayStatus != "done"`) oder der Fetch fehlschlägt.
    @State private var trickplayCues: [TrickplayCue] = []
    @State private var trickplaySprite: CGImage?
    #if os(macOS)
    @EnvironmentObject var transcode: LocalTranscodeService
    @State private var isConverting = false
    @State private var isFullScreen = false
    @State private var hostWindow: NSWindow?
    // User-Anfrage 2026-08-19: "Player immer genau in dem Format wie das Video öffnen,
    // so dass weder unten noch auf der Seite ein schwarzer Balken ist. Auch von der
    // Größe etwas größer wie zuletzt geöffnet." — einmal pro Fenster-Öffnung gesetzt,
    // sobald die echte Video-Auflösung (`presentationSize`) bekannt ist.
    @State private var hasSizedWindowToVideo = false
    #endif

    init(item: Item, queue: [Item] = [], queueIndex: Int? = nil, randomContext: RandomContext? = nil, startFromBeginning: Bool = false) {
        _item = State(initialValue: item)
        self.queue = queue
        self.randomContext = randomContext
        self.startFromBeginning = startFromBeginning
        _queueIndex = State(initialValue: queueIndex ?? queue.firstIndex(where: { $0.id == item.id }) ?? 0)
        _randomHistory = State(initialValue: randomContext != nil ? [item] : [])
    }

    private var hasPrev: Bool {
        randomContext != nil ? randomHistoryIndex > 0 : (!queue.isEmpty && queueIndex > 0)
    }
    private var hasNext: Bool {
        randomContext != nil || (!queue.isEmpty && queueIndex < queue.count - 1)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            #if os(macOS)
            WindowAccessor { window in
                if hostWindow !== window {
                    hostWindow = window
                    observeFullScreenChanges(for: window)
                }
            }
            .frame(width: 0, height: 0)

            if isConverting {
                VStack(spacing: 12) {
                    ProgressView(value: transcode.progress["dl-\(item.id)"] ?? 0).frame(maxWidth: 260).tint(.white)
                    Text("Format wird angepasst (einmalig) …")
                        .foregroundStyle(.white)
                    Button("Abbrechen") { teardown(); closePlayer() }
                        .buttonStyle(.plain)
                        .foregroundStyle(.white.opacity(0.7))
                }
            } else if let player {
                NativePlayerView(player: player)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { toggleControlsVisibility() }
            } else if let errorMessage {
                VStack(spacing: 12) {
                    Text(errorMessage).foregroundStyle(.white)
                    Button("Schließen") { closePlayer() }
                }
            } else {
                ProgressView().tint(.white)
            }
            #else
            if let player {
                NativePlayerView(player: player)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { toggleControlsVisibility() }
            } else if let errorMessage {
                VStack(spacing: 12) {
                    Text(errorMessage).foregroundStyle(.white)
                    Button("Schließen") { closePlayer() }
                }
            } else {
                ProgressView().tint(.white)
            }
            #endif

            VStack {
                // Real bug hit 2026-08-19 (User-Anfrage): das obere Schließen-Kreuz ist jetzt
                // redundant (auch im Steuerfeld) — entfernt, die Top-Bar existiert nur noch
                // als Platzhalter für den Titelbalken-Abstand.
                Color.clear.frame(height: 1).padding(.top, 28)
                Spacer()
                if player != nil {
                    // Real bug hit 2026-08-19 (User-Anfrage): die vorherige Version schob
                    // das GANZE Paar (Steuerfeld + Info) mit nur einem linken Spacer nach
                    // rechts, statt das Steuerfeld selbst zentriert zu lassen — dadurch war
                    // das Steuerfeld nicht mehr in der Bildschirmmitte, UND Auflösung/Titel
                    // standen übereinander statt nebeneinander zu passen. Fix: `ZStack` mit
                    // Standard-`.center`-Ausrichtung hält `PlayerControlsBar` exakt so
                    // zentriert wie ursprünglich; der Info-Block liegt in einer EIGENEN,
                    // volle-Breite-HStack-Schicht links verankert (`.padding(.leading, 40)`
                    // + `frame(maxWidth: 320)`), kann das Steuerfeld dadurch nie überlappen,
                    // egal wie breit das Fenster ist. Dateiname kürzt bei Überlänge mit "…"
                    // (`lineLimit(1)` + `truncationMode(.tail)`) statt ins Steuerfeld zu ragen.
                    ZStack {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                if let currentResolutionLabel {
                                    Text(currentResolutionLabel)
                                        .font(.caption2.bold())
                                }
                                Text(item.displayTitle)
                                    .font(.caption2)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.6), radius: 3)
                            .frame(maxWidth: 320, alignment: .leading)
                            .padding(.leading, 40)
                            Spacer()
                        }

                        PlayerControlsBar(
                            isPlaying: $isPlaying,
                            currentTime: $currentTime,
                            duration: duration,
                            isScrubbing: $isScrubbing,
                            volume: $volume,
                            trickplayCues: trickplayCues,
                            trickplaySprite: trickplaySprite,
                            hasPrev: hasPrev,
                            hasNext: hasNext,
                            onTogglePlay: { togglePlay(); resetAutoHide() },
                            onSkip: { seek(toAbsolute: currentTime + $0); resetAutoHide() },
                            onScrubEnd: { seek(toAbsolute: $0); resetAutoHide() },
                            onVolumeChange: { player?.volume = $0; resetAutoHide() },
                            onPrev: { Task { await jump(by: -1) } },
                            onNext: { Task { await jump(by: 1) } },
                            isFavorite: isFavorite,
                            onToggleFavorite: toggleFavorite,
                            onAddToPlaylist: { showingAddToPlaylist = true },
                            isFullScreen: fullScreenStateForControlsBar,
                            onToggleFullScreen: fullScreenToggleForControlsBar,
                            onClose: { teardown(); closePlayer() }
                        )
                    }
                    .padding(.bottom, 24)
                }
            }
            .opacity(controlsVisible ? 1 : 0)
            .animation(.easeInOut(duration: 0.25), value: controlsVisible)
        }
        .task(id: item.id) { await setUp() }
        .onDisappear {
            hideControlsTask?.cancel()
            #if os(macOS)
            NSCursor.unhide()
            #endif
            teardown()
        }
        .sheet(isPresented: $showingAddToPlaylist) {
            AddToPlaylistSheet(item: item)
        }
        #if os(macOS)
        // User-Anfrage 2026-08-19: "Der Mauszeiger verschwindet nicht, wenn ich den Player
        // vergrößere" — bisher gab es GAR KEINE Cursor-Ausblendung, nur das eigene
        // Steuerfeld faded per Timer weg. `NSCursor` folgt jetzt `controlsVisible`. Bewegung
        // zählt zusätzlich als Aktivität (nicht nur Klicks) — sonst bliebe der Cursor
        // unsichtbar, obwohl man die Maus bewegt, weil `resetAutoHide()` bisher nur von
        // Button-Taps aus aufgerufen wurde.
        .onContinuousHover { phase in
            if case .active = phase { resetAutoHide() }
        }
        .onChange(of: controlsVisible) { visible in
            if visible { NSCursor.unhide() } else { NSCursor.hide() }
        }
        #endif
    }

    private func toggleControlsVisibility() {
        controlsVisible.toggle()
        if controlsVisible { resetAutoHide() } else { hideControlsTask?.cancel() }
    }

    #if os(macOS)
    /// Real bug hit 2026-08-19, four times over: `.sheet`-based presentation fundamentally
    /// doesn't support real fullscreen no matter which window is targeted or how (frame-
    /// resize, `sheetParent`, cached/fresh main-window lookups all failed). Fix: the player
    /// is now a genuine `WindowGroup(id: "player")` window (see `PlayerLaunchCoordinator`),
    /// so `hostWindow` here is simply ITS OWN real, fullscreen-capable window — no more
    /// guessing which window is the "right" one.
    private func toggleFullScreen() {
        hostWindow?.toggleFullScreen(nil)
    }

    private func observeFullScreenChanges(for window: NSWindow) {
        // Bugfix 2026-08-20 (User: "der Vergrößern-Pfeil im Steuerfeld funktioniert immer
        // noch nicht", nach dem Umstieg von `WindowGroup` auf `Window` für Single-Instance-
        // Fenster): `Window`-Szenen setzen offenbar nicht automatisch dieselbe
        // Fullscreen-/Resize-Fähigkeit wie `WindowGroup` — `styleMask` ohne `.resizable`
        // ODER `collectionBehavior` ohne `.fullScreenPrimary` lässt `toggleFullScreen(nil)`
        // stillschweigend nichts tun (kein Fehler, kein Crash, einfach No-op). Beides hier
        // defensiv erzwingen, statt uns auf das Scene-Default zu verlassen.
        window.styleMask.insert(.resizable)
        window.collectionBehavior.insert(.fullScreenPrimary)
        NotificationCenter.default.addObserver(forName: NSWindow.didEnterFullScreenNotification, object: window, queue: .main) { _ in
            isFullScreen = true
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main) { _ in
            isFullScreen = false
        }
    }

    private static let lastWindowWidthKey = "goldfish.player.lastWindowWidth"

    /// Setzt die Fenster-Inhaltsgröße exakt auf das Seitenverhältnis der echten Video-
    /// Auflösung — bei falschem Fensterformat legt AVPlayerView (Videogravity `resizeAspect`)
    /// sonst schwarze Balken oben/unten oder seitlich an. Breite basiert auf der zuletzt
    /// verwendeten Fensterbreite (persistiert), etwas hochskaliert ("etwas größer wie
    /// zuletzt geöffnet"), auf die neue Video-Breite umgerechnet und auf den sichtbaren
    /// Bildschirmbereich begrenzt.
    private func sizeWindowToVideo(_ videoSize: CGSize) {
        guard let window = hostWindow, isFullScreen == false else { return }
        let aspect = videoSize.width / videoSize.height
        guard aspect.isFinite, aspect > 0 else { return }

        let lastWidth = UserDefaults.standard.double(forKey: Self.lastWindowWidthKey)
        var width: CGFloat = lastWidth > 0 ? CGFloat(lastWidth) * 1.12 : 1100
        var height = width / aspect

        if let screenFrame = window.screen?.visibleFrame {
            let maxWidth = screenFrame.width * 0.92
            let maxHeight = screenFrame.height * 0.92
            if width > maxWidth { width = maxWidth; height = width / aspect }
            if height > maxHeight { height = maxHeight; width = height * aspect }
        }

        window.setContentSize(NSSize(width: width, height: height))
        window.center()
    }

    /// Merkt sich die aktuelle Fensterbreite für die nächste `sizeWindowToVideo`-Berechnung
    /// — läuft beim Schließen, sodass eine manuelle Größenänderung durch den User (Ziehen am
    /// Fensterrand) als neue Basis übernommen wird, nicht nur der automatisch gesetzte Wert.
    private func saveWindowSizeForNextTime() {
        guard let window = hostWindow, let contentSize = window.contentView?.frame.size, contentSize.width > 0 else { return }
        UserDefaults.standard.set(Double(contentSize.width), forKey: Self.lastWindowWidthKey)
    }
    #endif

    private func closePlayer() {
        #if os(macOS)
        // Real bug found 2026-08-19: this cleared the window (`hostWindow?.close()`) but
        // never reset `PlayerLaunchCoordinator.pendingPlayer` to nil — SwiftUI's
        // `WindowGroup(id: "player")` scene never learns the content should go away, since
        // that reset only happens the SwiftUI-native way via `dismissWindow(id:)` (macOS 14+,
        // unavailable at this app's macOS 13 deployment target). Closing the NSWindow directly
        // while SwiftUI still thinks it has live content to show for that scene leaves
        // SwiftUI's own window bookkeeping out of sync with AppKit's — the suspected cause of
        // the main window going fully untracked (empty "Fenster" menu) after closing/
        // minimizing the player, since AppKit's window-list an SwiftUI's scene graph can
        // diverge from there. Reset FIRST so the scene's body evaluates to nothing before the
        // window itself is torn down.
        saveWindowSizeForNextTime()
        PlayerLaunchCoordinator.shared.pendingPlayer = nil
        hostWindow?.close()
        #else
        dismiss()
        #endif
    }

    /// Plain (non-`#if`-gated) accessors for `PlayerControlsBar` — keeps the call site free
    /// of conditional-compilation syntax around individual arguments (that pattern doesn't
    /// parse cleanly inside a multi-argument initializer call).
    private var fullScreenStateForControlsBar: Bool {
        #if os(macOS)
        isFullScreen
        #else
        false
        #endif
    }
    private var fullScreenToggleForControlsBar: (() -> Void)? {
        #if os(macOS)
        { toggleFullScreen(); resetAutoHide() }
        #else
        nil
        #endif
    }

    /// Controls fade out after a few seconds of inactivity while playing (matches
    /// standard video-player conventions) — restarted on every scrub/skip/volume/tap.
    private func resetAutoHide() {
        controlsVisible = true
        hideControlsTask?.cancel()
        hideControlsTask = Task {
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            guard !Task.isCancelled, isPlaying else { return }
            controlsVisible = false
        }
    }

    private func teardown() {
        resumeTimer?.invalidate()
        resumeTimer = nil
        if let token = timeObserverToken, let player { player.removeTimeObserver(token) }
        timeObserverToken = nil
        if let token = didEndObserverToken { NotificationCenter.default.removeObserver(token) }
        didEndObserverToken = nil
        if let player {
            // Capture + pause synchronously — by the time an async Task actually runs,
            // `self.player` would already be nil below and saveResume() would no-op.
            let seconds = virtualOffset + player.currentTime().seconds
            player.pause()
            if seconds.isFinite, seconds > 0 {
                let capturedSeconds = seconds
                Task { await maybeMarkWatchedOrSaveResume(seconds: capturedSeconds) }
            }
        }
        player = nil
    }

    private func jump(by delta: Int) async {
        if let randomContext {
            await jumpRandom(by: delta, context: randomContext)
            return
        }
        let newIndex = queueIndex + delta
        guard queue.indices.contains(newIndex) else { return }
        teardown()
        queueIndex = newIndex
        item = queue[newIndex]
        // .task(id: item.id) picks up the new item and calls setUp() automatically.
    }

    private func jumpRandom(by delta: Int, context: RandomContext) async {
        guard !isLoadingRandomNext else { return }
        if delta < 0 {
            let newIndex = randomHistoryIndex - 1
            guard randomHistory.indices.contains(newIndex) else { return }
            teardown()
            randomHistoryIndex = newIndex
            item = randomHistory[newIndex]
            return
        }
        // Already stepped back earlier and there's forward history — reuse it instead
        // of fetching a fresh random item, matching the web shuffle's history behavior.
        if randomHistoryIndex + 1 < randomHistory.count {
            teardown()
            randomHistoryIndex += 1
            item = randomHistory[randomHistoryIndex]
            return
        }
        isLoadingRandomNext = true
        defer { isLoadingRandomNext = false }
        guard let next = try? await client.randomItem(libraryId: context.libraryId, libraryIds: context.libraryIds, folderSelections: context.folderSelections, folder: context.folder, search: context.search) else { return }
        teardown()
        randomHistory.append(next)
        randomHistoryIndex = randomHistory.count - 1
        item = next
    }

    private func setUp() async {
        errorMessage = nil
        isTranscode = false
        transcodeURLTemplate = nil
        virtualOffset = 0
        currentTime = 0
        duration = item.durationSec ?? 0
        currentResolutionLabel = nil
        isFavorite = item.favorite
        hasMarkedWatchedThisSession = false
        trickplayCues = []
        trickplaySprite = nil
        if item.trickplayStatus == "done" {
            Task { await loadTrickplay() }
        }

        // Offline-first: if this item was downloaded, play the local file — works with no
        // network at all. The server's `/api/download` endpoint serves the ORIGINAL,
        // untranscoded file (CLAUDE.md "Download & Löschen") — same MKV/DTS/HEVC-tag
        // incompatibilities as local-library files apply, so run it through the same
        // compatibility check + remux before handing it to AVPlayer (real bug hit
        // 2026-08-19: downloaded MKV files showed the same black-screen/no-thumbnail symptom
        // as local-library ones, going through a completely separate code path than never
        // got the fix).
        if let localURL = downloads.localFileURL(itemId: item.id) {
            var playURL = localURL
            #if os(macOS)
            if transcode.isDownloadConverted(itemId: item.id) {
                playURL = transcode.convertedDownloadURL(itemId: item.id)
            } else {
                let playable = (try? await AVURLAsset(url: localURL).load(.isPlayable)) ?? false
                if !playable {
                    isConverting = true
                    do {
                        playURL = try await transcode.remuxDownload(itemId: item.id, sourceURL: localURL)
                    } catch {
                        isConverting = false
                        errorMessage = error.localizedDescription
                        return
                    }
                    isConverting = false
                }
            }
            #endif
            let p = AVPlayer(url: playURL)
            self.player = p
            attachObservers(to: p)
            // User-Anfrage 2026-08-19: "bei offline Dateien merkt er sich nicht, wo man
            // zuletzt war" — dieser Zweig hat nie eine Resume-Position gelesen. Rein lokaler
            // Speicher (siehe DownloadManager.localResumeSeconds), unabhängig vom Server.
            let resumeSec = startFromBeginning ? 0 : downloads.localResumeSeconds(itemId: item.id)
            if resumeSec > 5 {
                await p.seek(to: CMTime(seconds: resumeSec, preferredTimescale: 600))
            }
            p.play()
            startResumeTimer(for: p)
            return
        }

        do {
            let resumeSec = startFromBeginning ? 0 : ((try? await client.getResume(itemId: item.id)) ?? 0)
            let playback = try await client.playback(itemId: item.id)
            isTranscode = playback.mode == "transcode"
            transcodeURLTemplate = isTranscode ? playback.url : nil

            let startAt = resumeSec > 5 ? resumeSec : 0
            // Real bug hit 2026-08-19 (User: "hatten wir schon im Browser") — same root
            // cause as DECISIONS.md "„Von Anfang" startet mitten im Film": the server caches
            // transcode sessions per (itemID, profile, audio, startSec, …). A `start=0`
            // session from an earlier playback of this item can still be alive (5 min idle
            // GC) with minutes of material already transcoded ahead — `StartOrGet` just
            // matches and reuses it, so the player gets handed a playlist that's already
            // far past position 0. Browser fix (player.js, `applyPlayback`): append `fresh=1`
            // whenever the resume position is 0, which makes the server force-stop any
            // existing session and start a clean one; `_t=<timestamp>` cache-busts so the
            // player doesn't reuse anything from its own memory for an identical URL either.
            let requestURL = isTranscode ? transcodeURLWithParams(playback.url, start: startAt) : playback.url
            guard let streamURL = client.resolvedURL(forServerPath: requestURL) else {
                errorMessage = "Stream-URL konnte nicht ermittelt werden."
                return
            }
            virtualOffset = isTranscode ? startAt : 0

            let p = AVPlayer(url: streamURL)
            self.player = p
            attachObservers(to: p)
            if !isTranscode, startAt > 0 {
                await p.seek(to: CMTime(seconds: startAt, preferredTimescale: 600))
            }
            p.play()
            startResumeTimer(for: p)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func urlWithStart(_ path: String, start: Double) -> String {
        guard start > 0 else { return path }
        let separator = path.contains("?") ? "&" : "?"
        return "\(path)\(separator)start=\(start)"
    }

    /// Transcode-only: adds `start=`, a `_t=` cache-bust, and — only when starting at 0 —
    /// `fresh=1` so the server force-restarts any lingering session instead of handing back
    /// an already-advanced playlist. Mirrors `player.js`'s `applyPlayback` exactly (see
    /// DECISIONS.md "„Von Anfang" startet mitten im Film" for why every one of these three
    /// pieces is required together).
    private func transcodeURLWithParams(_ path: String, start: Double) -> String {
        var url = urlWithStart(path, start: start)
        let separator = url.contains("?") ? "&" : "?"
        url += "\(separator)_t=\(Int(Date().timeIntervalSince1970 * 1000))"
        if start == 0 {
            url += "&fresh=1"
        }
        return url
    }

    private func attachObservers(to player: AVPlayer) {
        isPlaying = true
        player.volume = volume
        resetAutoHide()

        // [weak player]: the closure is stored ON `player` itself (addPeriodicTimeObserver
        // registers it internally) — capturing `player` strongly here creates a genuine
        // retain cycle that keeps the AVPlayer alive (and, worse, still audible if pause()
        // is ever skipped on some path) even after every other reference is dropped.
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak player] time in
            guard !isScrubbing, let player else { return }
            currentTime = virtualOffset + time.seconds
            if duration <= 0, let itemDuration = player.currentItem?.duration.seconds, itemDuration.isFinite, itemDuration > 0 {
                duration = virtualOffset + itemDuration
            }
            isPlaying = player.timeControlStatus == .playing
            if let size = player.currentItem?.presentationSize, size.width > 0, size.height > 0 {
                currentResolutionLabel = Self.resolutionLabel(for: size)
                #if os(macOS)
                if !hasSizedWindowToVideo {
                    hasSizedWindowToVideo = true
                    sizeWindowToVideo(size)
                }
                #endif
            }
        }

        // Sicherheitsnetz analog player.js' `vjs.on("ended", …)` (CLAUDE.md "markWatchedNow:
        // gemeinsamer Pfad für 90-%-Threshold UND ended-Event"): der 90-%-Check in
        // `maybeMarkWatchedOrSaveResume` verlässt sich auf `item.durationSec` vom Server —
        // bei manchen yt-dlp-Privat-Lib-Downloads ist dieser ffprobe-Wert unzuverlässig
        // (falsch hoch geschätzt bei defekten/gemergten Containern), sodass 90 % der
        // GEMELDETEN Laufzeit real nie erreicht wird, obwohl das Video fertig durchgelaufen
        // ist (User-Bericht 2026-08-19: "Was der Frühling kostet" wurde nicht als gesehen
        // markiert). `didPlayToEndTimeNotification` ist unabhängig von der Dauer-Berechnung
        // und feuert garantiert beim echten Ende — markiert dann unconditional als gesehen.
        didEndObserverToken = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { _ in
            Task { await markWatchedNow() }
        }
    }

    /// Unconditional "gesehen"-Markierung beim echten Wiedergabe-Ende — Ergänzung zu
    /// `maybeMarkWatchedOrSaveResume`'s 90-%-Heuristik, siehe deren Aufrufstelle oben.
    private func markWatchedNow() async {
        guard !hasMarkedWatchedThisSession else { return }
        hasMarkedWatchedThisSession = true
        downloads.updateCachedWatched(itemId: item.id, watched: true)
        if (try? await client.setWatched(itemId: item.id, watched: true)) != nil {
            downloads.clearPendingWatchedSync(itemId: item.id)
        } else {
            // Offline (oder sonst ein Netzwerkfehler) — Server erfährt es sonst NIE, siehe
            // `DownloadManager.queuePendingWatchedSync`-Kommentar. Wird automatisch nachgeholt,
            // sobald wieder eine Session bestätigt wird (`RootView.syncPendingWatched`).
            downloads.queuePendingWatchedSync(itemId: item.id)
        }
        try? await client.setResume(itemId: item.id, positionSec: 0)
    }

    /// Same bucket formula as `Item.resolutionLabel` (`max(height, width*9/16)`) — keeps
    /// Cinemascope sources (e.g. 1920×800) correctly bucketed as 1080p instead of 720p, and
    /// keeps the label consistent with the rest of the app instead of a second convention.
    private static func resolutionLabel(for size: CGSize) -> String {
        let effective = max(Double(size.height), Double(size.width) * 9.0 / 16.0)
        switch effective {
        case 2000...: return "4K"
        case 1000..<2000: return "1080p"
        case 700..<1000: return "720p"
        default: return "\(Int(effective))p"
        }
    }

    private func togglePlay() {
        guard let player else { return }
        if player.timeControlStatus == .playing {
            player.pause()
        } else {
            player.play()
        }
    }

    /// `target` is an absolute position in the item's full runtime (matches what the
    /// scrubber/labels show). For direct play this is just a normal seek; for a
    /// transcode session it may require starting a fresh ffmpeg session at `target`
    /// if that's outside what the current session has produced so far.
    private func seek(toAbsolute target: Double) {
        guard let player else { return }
        let clamped = duration > 0 ? max(0, min(target, duration)) : max(0, target)

        guard isTranscode else {
            player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600))
            currentTime = clamped
            return
        }

        let relative = clamped - virtualOffset
        let seekable = player.currentItem?.seekableTimeRanges.last?.timeRangeValue
        let withinSeekable = seekable.map { relative >= CMTimeGetSeconds($0.start) && relative <= CMTimeGetSeconds($0.start) + CMTimeGetSeconds($0.duration) } ?? false

        if relative >= 0, withinSeekable {
            player.seek(to: CMTime(seconds: relative, preferredTimescale: 600))
            currentTime = clamped
        } else {
            restartTranscodeSession(atAbsolute: clamped)
        }
    }

    private func restartTranscodeSession(atAbsolute target: Double) {
        guard let template = transcodeURLTemplate,
              let url = client.resolvedURL(forServerPath: urlWithStart(template, start: target)) else { return }
        let wasPlaying = isPlaying

        // Explicitly silence + release the outgoing session — swapping `self.player` alone
        // does NOT stop the old AVPlayer, it just changes what the view *shows*; the old
        // instance keeps producing audio in the background otherwise (real bug hit 2026-08-17:
        // scrubbing past the buffered range played both the old and new session at once).
        if let token = timeObserverToken, let oldPlayer = player {
            oldPlayer.removeTimeObserver(token)
            oldPlayer.pause()
        }
        timeObserverToken = nil

        let p = AVPlayer(url: url)
        self.player = p
        virtualOffset = target
        currentTime = target
        attachObservers(to: p)
        if wasPlaying { p.play() }
    }

    private func startResumeTimer(for player: AVPlayer) {
        resumeTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in
            Task { await saveResume() }
        }
    }

    private func saveResume() async {
        guard let player else { return }
        let seconds = virtualOffset + player.currentTime().seconds
        guard seconds.isFinite, seconds > 0 else { return }
        await maybeMarkWatchedOrSaveResume(seconds: seconds)
    }

    /// CLAUDE.md "Auto-Markierung bei 90% Laufzeit" — real gap hit 2026-08-19 (User: "es wird
    /// nicht mit dem Server synchronisiert, welche Folgen ich schon geschaut habe"): this
    /// player never auto-marked items watched at all (online OR offline/downloaded), that
    /// logic only ever existed in `LocalPlayerView` (pure local libraries). Runs from BOTH the
    /// periodic 15s resume-timer AND `teardown()`, since relying on `teardown()`/`onDisappear`
    /// alone turned out not to be enough (see `hasMarkedWatchedThisSession`'s doc comment).
    /// Bugfix 2026-08-20 (User: "wird sie am Ende nicht als gesehen markiert"): `try?` allein
    /// ließ eine offline fehlgeschlagene Markierung für immer unsynced — jetzt in
    /// `DownloadManager.queuePendingWatchedSync` nachgehalten, siehe dessen Kommentar.
    private func maybeMarkWatchedOrSaveResume(seconds: Double) async {
        if duration > 0, seconds >= duration * 0.9 {
            guard !hasMarkedWatchedThisSession else { return }
            hasMarkedWatchedThisSession = true
            downloads.updateCachedWatched(itemId: item.id, watched: true)
            if (try? await client.setWatched(itemId: item.id, watched: true)) != nil {
                downloads.clearPendingWatchedSync(itemId: item.id)
            } else {
                downloads.queuePendingWatchedSync(itemId: item.id)
            }
            downloads.setLocalResume(itemId: item.id, seconds: 0)
        } else {
            try? await client.setResume(itemId: item.id, positionSec: seconds)
            // Läuft IMMER mit, nicht nur offline — reiner lokaler Speicher, kostet nichts
            // und dient als verlässlicher Fallback, falls der Server-Call fehlschlägt
            // (Netzwerk weg, siehe Kommentar oben) oder gar keine Verbindung besteht.
            downloads.setLocalResume(itemId: item.id, seconds: seconds)
        }
    }

    private func loadTrickplay() async {
        let cues = await client.fetchTrickplayCues(itemId: item.id)
        guard !cues.isEmpty else { return }
        trickplayCues = cues
        trickplaySprite = await client.fetchTrickplaySprite(itemId: item.id)
    }

    private func toggleFavorite() {
        let newValue = !isFavorite
        isFavorite = newValue
        Task { try? await client.setFavorite(itemId: item.id, favorite: newValue) }
    }
}

private struct PlayerControlsBar: View {
    @Binding var isPlaying: Bool
    @Binding var currentTime: Double
    let duration: Double
    @Binding var isScrubbing: Bool
    @Binding var volume: Float
    var trickplayCues: [TrickplayCue] = []
    var trickplaySprite: CGImage? = nil
    let hasPrev: Bool
    let hasNext: Bool
    let onTogglePlay: () -> Void
    let onSkip: (Double) -> Void
    let onScrubEnd: (Double) -> Void
    let onVolumeChange: (Float) -> Void
    let onPrev: () -> Void
    let onNext: () -> Void
    /// User-Anfrage 2026-08-19: Favoriten- und Playlist-Symbol auch im Steuerfeld.
    var isFavorite: Bool = false
    var onToggleFavorite: (() -> Void)? = nil
    var onAddToPlaylist: (() -> Void)? = nil
    /// nil on iOS (no `NSWindow` fullscreen concept there) — User-Anfrage 2026-08-19: den
    /// Fullscreen-Button zusätzlich zur Top-Bar auch ins Steuerfeld selbst bauen.
    var isFullScreen: Bool = false
    var onToggleFullScreen: (() -> Void)? = nil
    /// User-Anfrage 2026-08-19: Schließen-Kreuz zusätzlich im Steuerfeld.
    var onClose: (() -> Void)? = nil

    @State private var scrubValue: Double = 0
    @State private var volumeBeforeMute: Float = 1.0

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                Text(formatTime(isScrubbing ? scrubValue : currentTime))
                ScrubberWithPreview(
                    isScrubbing: $isScrubbing,
                    scrubValue: $scrubValue,
                    currentTime: currentTime,
                    duration: duration,
                    trickplayCues: trickplayCues,
                    trickplaySprite: trickplaySprite,
                    onScrubEnd: onScrubEnd
                )
                Text(formatTime(duration))
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.white)

            HStack(spacing: 16) {
                HStack(spacing: 12) {
                    if let onClose {
                        Button(action: onClose) {
                            Image(systemName: "xmark")
                        }
                    }
                    HStack(spacing: 4) {
                        Button {
                            if volume > 0 {
                                volumeBeforeMute = volume
                                volume = 0
                            } else {
                                volume = volumeBeforeMute > 0 ? volumeBeforeMute : 1
                            }
                            onVolumeChange(volume)
                        } label: {
                            Image(systemName: volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        Slider(value: Binding(get: { volume }, set: { volume = $0; onVolumeChange($0) }), in: 0...1)
                            .frame(width: 60)
                    }
                }
                .foregroundStyle(.white)

                Spacer(minLength: 12)

                HStack(spacing: 18) {
                    Button { onPrev() } label: {
                        Image(systemName: "backward.end.fill")
                    }.disabled(!hasPrev).opacity(hasPrev ? 1 : 0.35)

                    Button { onSkip(-15) } label: {
                        Image(systemName: "gobackward.15")
                    }
                    Button(action: onTogglePlay) {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .font(.title2)
                    }
                    Button { onSkip(15) } label: {
                        Image(systemName: "goforward.15")
                    }

                    Button { onNext() } label: {
                        Image(systemName: "forward.end.fill")
                    }.disabled(!hasNext).opacity(hasNext ? 1 : 0.35)
                }
                .font(.title3)

                Spacer(minLength: 12)
                HStack(spacing: 12) {
                    if let onToggleFavorite {
                        Button(action: onToggleFavorite) {
                            Image(systemName: isFavorite ? "heart.fill" : "heart")
                                .foregroundStyle(isFavorite ? Color.red : Color.white)
                        }
                    }
                    if let onAddToPlaylist {
                        Button(action: onAddToPlaylist) {
                            Image(systemName: "text.badge.plus")
                        }
                    }
                    if let onToggleFullScreen {
                        Button(action: onToggleFullScreen) {
                            Image(systemName: isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        }
                    }
                }
                .frame(minWidth: 64, alignment: .trailing)
            }
            .foregroundStyle(.white)
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        .fixedSize(horizontal: false, vertical: true) // guard against any accidental vertical stretch from the parent
        // User-Anfrage 2026-08-19: "Steuerfenster des Players ein klein wenig größer machen".
        .frame(maxWidth: 560)
        .padding(.horizontal, 40)
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

/// Scrub-Slider + Trickplay-Hover-Vorschau. Ein normaler SwiftUI-`Slider` allein verrät
/// keine Mauszeiger-Position — deshalb sitzt hier zusätzlich ein `.onContinuousHover`
/// (macOS) auf demselben `GeometryReader`, der die Slider-Breite kennt, um Fraktion→Zeit
/// umzurechnen. Auf iOS gibt es kein Hover; dort zeigt die Vorschau nur während des aktiven
/// Ziehens (`isScrubbing`) — mirrors, was die Plattform überhaupt hergibt.
private struct ScrubberWithPreview: View {
    @Binding var isScrubbing: Bool
    @Binding var scrubValue: Double
    let currentTime: Double
    let duration: Double
    let trickplayCues: [TrickplayCue]
    let trickplaySprite: CGImage?
    let onScrubEnd: (Double) -> Void

    #if os(macOS)
    @State private var hoverFraction: CGFloat?
    #endif

    private var previewTime: Double? {
        if isScrubbing { return scrubValue }
        #if os(macOS)
        if let hoverFraction { return Double(hoverFraction) * max(duration, 1) }
        #endif
        return nil
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Slider(
                    value: Binding(
                        get: { isScrubbing ? scrubValue : currentTime },
                        set: { scrubValue = $0 }
                    ),
                    in: 0...max(duration, 1),
                    onEditingChanged: { editing in
                        if editing {
                            isScrubbing = true
                            scrubValue = currentTime
                        } else {
                            onScrubEnd(scrubValue)
                            isScrubbing = false
                        }
                    }
                )
                .frame(width: geo.size.width)

                if let previewTime, !trickplayCues.isEmpty, let sprite = trickplaySprite,
                   let cue = TrickplayVTTParser.cue(for: previewTime, in: trickplayCues) {
                    let fraction = duration > 0 ? CGFloat(previewTime / duration) : 0
                    let previewWidth: CGFloat = 160
                    let centerX = fraction * geo.size.width
                    let clampedX = min(max(centerX - previewWidth / 2, 0), max(geo.size.width - previewWidth, 0))
                    TrickplaySpriteView(sprite: sprite, cue: cue, time: previewTime)
                        .offset(x: clampedX, y: -104)
                        .allowsHitTesting(false)
                }
            }
            #if os(macOS)
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    hoverFraction = min(max(location.x / geo.size.width, 0), 1)
                case .ended:
                    hoverFraction = nil
                }
            }
            #endif
        }
        .frame(height: 24)
    }
}

/// Ein einzelnes Sprite-Kachel-Crop aus dem Trickplay-Sheet, gerendert als kleine
/// Vorschau-Karte mit Zeitstempel — mirrors den Browser-Hover (CLAUDE.md "Trickplay
/// (Hover-Vorschau)": Sprite-Ausschnitt via Zeit-zu-Kachel-Zuordnung).
private struct TrickplaySpriteView: View {
    let sprite: CGImage
    let cue: TrickplayCue
    let time: Double

    var body: some View {
        VStack(spacing: 4) {
            Group {
                if let cropped = sprite.cropping(to: CGRect(x: cue.x, y: cue.y, width: cue.width, height: cue.height)) {
                    Image(decorative: cropped, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Color.black
                }
            }
            .frame(width: 160, height: 90)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.white.opacity(0.5), lineWidth: 1))

            Text(previewFormatTime(time))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.black.opacity(0.75), in: Capsule())
        }
        .shadow(color: .black.opacity(0.5), radius: 6, y: 3)
    }

    private func previewFormatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
