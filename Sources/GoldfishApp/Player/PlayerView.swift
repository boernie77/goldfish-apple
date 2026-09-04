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

/// Ein Untertitel-Cue aus einer WebVTT-Datei (absolute Filmzeit in Sekunden).
struct SubtitleCue: Equatable {
    let start: Double
    let end: Double
    let text: String
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
    /// Ton-/Untertitel-Vorwahl aus dem Detail-Dialog (Dropdowns dort).
    let preferredAudioIndex: Int?
    let preferredSubtitle: PreferredSubtitle?
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
    // tvOS-Fix 2026-09-03 (User-Report: "spielt nichts ab", Position hängt dauerhaft an der
    // Resume-Sekunde fest, `player.currentItem?.status` erreicht dabei nie `.failed` — der
    // simple Status-Check von vorhin griff also nicht): ein Stream, der aus Netzwerksicht
    // scheitert (z. B. App Transport Security blockt eine http://-Segment-URL, 4xx/5xx vom
    // Server, DNS-Fehler), lässt `AVPlayerItem.status` oft auf `.readyToPlay` stehen — das
    // Item "kennt" seine Metadaten (Dauer) schon aus dem HLS-Playlist-Header, hängt aber beim
    // eigentlichen Segment-Laden fest. Der zuverlässige Kanal dafür ist NICHT `.status`,
    // sondern `AVPlayerItemNewErrorLogEntry` (das native HTTP-Error-Log jedes Requests).
    @State private var errorLogObserverToken: NSObjectProtocol?

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

    /// Audio-track switcher (User-Anfrage 2026-08-27: "Tonspur wählen können", zuerst für den
    /// Mac-Download von Kill Bill geprüft — der Download hatte bis dahin nur die englische Spur,
    /// weil `LocalTranscodeService`s Konvertierung nur den ERSTEN Audiostream behielt, siehe den
    /// Fix dort). Nur relevant, wenn `AVPlayer` eine echte lokale/originale Datei abspielt
    /// (Download ODER Direct-Play) — bei einer Server-Transcode-Session (`isTranscode == true`)
    /// entscheidet der Server serverseitig über die Audiospur (Browser-Pendant: das Audio-
    /// Dropdown im Player-Dialog dort steuert genau diesen Query-Parameter), hier gibt es
    /// nichts lokal umzuschalten.
    @State private var audioSelectionGroup: AVMediaSelectionGroup?
    @State private var audioOptions: [AVMediaSelectionOption] = []
    @State private var selectedAudioOption: AVMediaSelectionOption?

    /// Tonspur-Auswahl bei einer Server-Transcode-Session: hier gibt es KEINE
    /// lokale `AVMediaSelectionGroup` (der HLS-Stream enthält nur die eine vom
    /// Server gewählte Spur). Stattdessen listet der Server alle Quell-Audiospuren
    /// in `PlaybackResponse.streams`; ein Wechsel hängt `&audio=<index>` an die
    /// Transcode-URL und startet die ffmpeg-Session neu (Browser-Pendant: das
    /// Audio-Dropdown im Player-Dialog). `nil` = Server-Default (erste/als default
    /// markierte Spur).
    @State private var transcodeAudioTracks: [MediaStream] = []
    @State private var selectedTranscodeAudioIndex: Int?

    /// Untertitel-Overlay: geparste Cues aus der erzeugten WebVTT (📝 OCR /
    /// 🎤 KI). Der Server liefert absolute Filmzeit-Stempel; `currentTime` ist
    /// hier ebenfalls absolut (virtualOffset schon eingerechnet) → kein Shift.
    @State private var subtitleCues: [SubtitleCue] = []
    @State private var subtitlesOn = false

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
    @State private var isFullScreen = false
    @State private var hostWindow: NSWindow?
    // User-Anfrage 2026-08-19: "Player immer genau in dem Format wie das Video öffnen,
    // so dass weder unten noch auf der Seite ein schwarzer Balken ist. Auch von der
    // Größe etwas größer wie zuletzt geöffnet." — einmal pro Fenster-Öffnung gesetzt,
    // sobald die echte Video-Auflösung (`presentationSize`) bekannt ist.
    @State private var hasSizedWindowToVideo = false
    #endif

    init(item: Item, queue: [Item] = [], queueIndex: Int? = nil, randomContext: RandomContext? = nil, startFromBeginning: Bool = false,
         preferredAudioIndex: Int? = nil, preferredSubtitle: PreferredSubtitle? = nil) {
        _item = State(initialValue: item)
        self.queue = queue
        self.randomContext = randomContext
        self.startFromBeginning = startFromBeginning
        self.preferredAudioIndex = preferredAudioIndex
        self.preferredSubtitle = preferredSubtitle
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
                    PlayerLaunchCoordinator.shared.playerWindow = window
                    observeFullScreenChanges(for: window)
                    observeWindowClose(for: window)
                }
            }
            .frame(width: 0, height: 0)

            // tvOS-Fix 2026-09-03: Reihenfolge bewusst umgestellt — vorher gewann `player`
            // immer schon, sobald `AVPlayer(url:)` erfolgreich KONSTRUIERT wurde, selbst wenn
            // der zugehörige `AVPlayerItem` danach asynchron mit `.status == .failed`
            // scheiterte (siehe der neue Status-Check in `attachObservers`). Ein stiller
            // schwarzer Bildschirm statt einer Fehlermeldung war die Folge — `errorMessage`
            // muss Vorrang haben, damit ein Spätfehler den Player-Zweig sofort ablöst.
            if let errorMessage {
                VStack(spacing: 12) {
                    Text(errorMessage).foregroundStyle(.white)
                    Button("Schließen") { closePlayer() }
                }
            } else if let player {
                NativePlayerView(player: player)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { toggleControlsVisibility() }
            } else {
                ProgressView().tint(.white)
            }
            #else
            // tvOS-Fix 2026-09-03: Reihenfolge bewusst umgestellt — vorher gewann `player`
            // immer schon, sobald `AVPlayer(url:)` erfolgreich KONSTRUIERT wurde, selbst wenn
            // der zugehörige `AVPlayerItem` danach asynchron mit `.status == .failed`
            // scheiterte (siehe der neue Status-Check in `attachObservers`). Ein stiller
            // schwarzer Bildschirm statt einer Fehlermeldung war die Folge — `errorMessage`
            // muss Vorrang haben, damit ein Spätfehler den Player-Zweig sofort ablöst.
            if let errorMessage {
                VStack(spacing: 12) {
                    Text(errorMessage).foregroundStyle(.white)
                    Button("Schließen") { closePlayer() }
                }
            } else if let player {
                ZStack {
                    NativePlayerView(player: player)
                        .ignoresSafeArea()
                    #if os(tvOS)
                    // tvOS-Fix 2026-09-04, zweiter Anlauf. Hintergrund: `isUserInteractionEnabled
                    // = false` auf der Video-Fläche (NativePlayerView.swift, gegen Fokus-Diebstahl
                    // durch AVPlayerViewController) blockiert dort JEDE Eingabe — der frühere
                    // `.onTapGesture` direkt auf der Video-Fläche feuerte deshalb nie. Der erste
                    // Ersatz (unsichtbarer Vollbild-`Button`) hatte zwei neue Fehler (User-Fotos):
                    // (a) sobald er Fokus bekam, malte tvOS seinen nativen weißen "Lift"-Effekt
                    //     über den GANZEN Bildschirm ("großes weißes Fenster", nicht wegzubekommen),
                    // (b) Pfeiltasten bewegten den Fokus auf diesen Button statt die Leiste zu holen.
                    // Jetzt: eine unsichtbare, fokussierbare Fläche OHNE Button-Semantik und mit
                    // `.focusEffectDisabled()` (kein Lift), die nur fokussierbar ist, solange die
                    // Leiste ausgeblendet ist — Select (Tap) UND jede Pfeiltaste holen die Leiste
                    // zurück. Sobald sie sichtbar ist, verliert diese Fläche die Fokussierbarkeit
                    // und die Fokus-Engine springt auf die echten Steuerelement-Buttons.
                    Color.clear
                        .contentShape(Rectangle())
                        .focusable(!controlsVisible)
                        .focusEffectDisabled()
                        .onTapGesture { resetAutoHide() }
                        .onMoveCommand { _ in resetAutoHide() }
                    #endif
                }
            } else {
                ProgressView().tint(.white)
            }
            #endif

            // Untertitel-Overlay (WebVTT-Cues, siehe loadSubtitleCues). Rückt
            // hoch, wenn die Steuerleiste sichtbar ist, damit sie nicht überdeckt.
            if let cue = activeSubtitleText {
                VStack {
                    Spacer()
                    Text(cue)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .shadow(color: .black.opacity(0.9), radius: 3, x: 0, y: 1)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 4)
                        .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
                        .padding(.bottom, controlsVisible ? 96 : 44)
                }
                .allowsHitTesting(false)
                .transition(.opacity)
            }

            VStack {
                // User-Anfrage 2026-09-02: Titel/Auflösung lagen unten links direkt neben
                // dem Steuerfeld und kollidierten dort im Hochkantformat (schmale Breite)
                // damit — jetzt eigener Block oben links, komplett getrennt vom Steuerfeld.
                if player != nil {
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
                        Spacer()
                    }
                    .padding(.leading, 20)
                    .padding(.top, 28)
                } else {
                    Color.clear.frame(height: 1).padding(.top, 28)
                }
                Spacer()
                if player != nil {
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
                            onClose: { teardown(); closePlayer() },
                            audioOptions: audioOptions,
                            selectedAudioOption: selectedAudioOption,
                            onSelectAudioOption: selectAudioOption,
                            transcodeAudioTracks: transcodeAudioTracks,
                            selectedTranscodeAudioIndex: selectedTranscodeAudioIndex,
                            onSelectTranscodeAudio: selectTranscodeAudio,
                            hasSubtitles: !subtitleCues.isEmpty,
                            subtitlesOn: subtitlesOn,
                            onToggleSubtitles: { subtitlesOn.toggle(); resetAutoHide() }
                        )
                        .padding(.bottom, 24)
                }
            }
            .opacity(controlsVisible ? 1 : 0)
            .animation(.easeInOut(duration: 0.25), value: controlsVisible)
            #if os(tvOS)
            // tvOS-Fix 2026-09-04: Opacity 0 nimmt die Buttons NICHT aus der Fokus-Engine —
            // eine unsichtbare Leiste könnte sonst weiterhin Fokus fangen und ein Select
            // würde blind z. B. 15s springen. Ausgeblendet = nicht fokussierbar; der
            // Fokus geht dann auf die Vollbild-Fläche (siehe `Color.clear.focusable(...)`).
            .disabled(!controlsVisible)
            #endif
        }
        #if os(tvOS)
        // tvOS-Fix 2026-09-04: physische Play/Pause-Taste der Fernbedienung. Vorher über
        // `MPRemoteCommandCenter` (Now-Playing-Kanal) — funktionierte nur für die erste
        // Pause, danach nicht mehr für Play: nach `pause()` gilt die App für tvOS nicht
        // mehr als aktiv abspielend und die Kommandos werden nicht mehr zugestellt.
        // `.onPlayPauseCommand` ist der fokus-basierte SwiftUI-Weg: feuert für die
        // fokussierte View ODER einen Vorfahren, also sowohl wenn die unsichtbare
        // Vollbild-Fläche als auch wenn ein Leisten-Button den Fokus hat. Genau EIN
        // Kanal — kein Doppel-Toggle mehr (pause+play = nichts) möglich.
        .onPlayPauseCommand {
            togglePlay()
            resetAutoHide()
        }
        #endif
        .task(id: item.id) { await setUp() }
        .onDisappear {
            hideControlsTask?.cancel()
            #if os(macOS)
            NSCursor.setHiddenUntilMouseMoves(false)
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
        //
        // Real bug hit 2026-08-23 (User: "Mauszeiger verschwindet öfters auf der Seite" —
        // also außerhalb des Players!): `NSCursor.hide()`/`unhide()` ist ein app-weiter,
        // REFCOUNTED Stack, nicht auf dieses Fenster beschränkt. Falls `onDisappear` nicht
        // feuert (dasselbe bereits dokumentierte Zuverlässigkeitsproblem beim Schließen über
        // den nativen roten Knopf statt den eigenen "Schließen"-Button, siehe den
        // Gesehen-Sync-Fix oben bei `hasMarkedWatchedThisSession`) bleibt ein offener
        // `hide()`-Call für immer unbalanciert stehen — der Cursor bleibt dann versteckt,
        // auch auf der normalen Bibliotheksseite, weit nachdem der Player geschlossen wurde.
        // `setHiddenUntilMouseMoves(true)` hat kein Refcount-Problem: einmaliger, sich selbst
        // aufhebender Zustand, der bei JEDER Mausbewegung automatisch endet — kein `unhide()`
        // nötig, also nichts, das durch einen verpassten `onDisappear` leaken kann.
        .onContinuousHover { phase in
            if case .active = phase { resetAutoHide() }
        }
        .onChange(of: controlsVisible) { visible in
            if !visible { NSCursor.setHiddenUntilMouseMoves(true) }
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
        NotificationCenter.default.addObserver(forName: NSWindow.didEnterFullScreenNotification, object: window, queue: .main) { _ in
            isFullScreen = true
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main) { _ in
            isFullScreen = false
        }
    }

    /// Clears the coordinator's tracked window reference no matter HOW the window closes —
    /// via `closePlayer()` (which already does this directly) OR via the user clicking the
    /// native red close button, which bypasses `closePlayer()` entirely. Without this, closing
    /// via the red button would leave `PlayerLaunchCoordinator.playerWindow` pointing at a
    /// dead window, so the NEXT play attempt would call `makeKeyAndOrderFront` on a closed
    /// window instead of opening a fresh one — silently doing nothing.
    private func observeWindowClose(for window: NSWindow) {
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            if PlayerLaunchCoordinator.shared.playerWindow === window {
                PlayerLaunchCoordinator.shared.playerWindow = nil
            }
            if PlayerLaunchCoordinator.shared.pendingPlayer != nil {
                PlayerLaunchCoordinator.shared.pendingPlayer = nil
            }
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
        // User-Report 2026-09-04 (tvOS, aber plattformunabhängiger Bug): die Steuerelemente
        // verschwanden dauerhaft nicht mehr, auch ganz ohne jede Fernbedienungs-Eingabe. Ursache:
        // die alte Fassung prüfte NUR EINMALIG nach 3,5s, ob `isPlaying` gerade true ist — traf
        // dieser eine Check ausgerechnet auf eine kurze `timeControlStatus`-Schwankung (z. B.
        // kurzes Nachpuffern bei Transcode/HLS, siehe auch die "stall danger"-Warnung weiter
        // oben in dieser Datei), gab die Prüfung endgültig auf und NICHTS versuchte es je wieder
        // — die Steuerelemente blieben für den Rest der Wiedergabe sichtbar. Fix: statt einer
        // einmaligen Prüfung wiederholt alle 3,5s nachsehen, bis entweder wirklich ausgeblendet
        // werden kann oder der Task abgebrochen wird (neue Nutzer-Aktivität/Schließen).
        hideControlsTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_500_000_000)
                if Task.isCancelled { return }
                if isPlaying {
                    controlsVisible = false
                    return
                }
            }
        }
    }

    private func teardown() {
        resumeTimer?.invalidate()
        resumeTimer = nil
        if let token = timeObserverToken, let player { player.removeTimeObserver(token) }
        timeObserverToken = nil
        if let token = didEndObserverToken { NotificationCenter.default.removeObserver(token) }
        didEndObserverToken = nil
        if let token = errorLogObserverToken { NotificationCenter.default.removeObserver(token) }
        errorLogObserverToken = nil
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

    /// Populates `audioOptions`/`selectedAudioOption` from the asset's `.audible` media
    /// selection group, if it has more than one option — a single-track source (the common
    /// case) leaves the switcher hidden entirely (`PlayerControlsBar` only shows it when
    /// `audioOptions.count > 1`).
    private func loadAudioOptions(for player: AVPlayer) async {
        audioSelectionGroup = nil
        audioOptions = []
        selectedAudioOption = nil
        guard let asset = player.currentItem?.asset else { return }
        guard let group = try? await asset.loadMediaSelectionGroup(for: .audible) else { return }
        audioSelectionGroup = group
        audioOptions = group.options
        selectedAudioOption = player.currentItem?.currentMediaSelection.selectedMediaOption(in: group) ?? group.defaultOption
    }

    private func selectAudioOption(_ option: AVMediaSelectionOption) {
        guard let group = audioSelectionGroup else { return }
        player?.currentItem?.select(option, in: group)
        selectedAudioOption = option
    }

    /// Hängt `&audio=<index>` an eine Transcode-URL, wenn eine Nicht-Default-Spur
    /// gewählt ist. Der Server-Session-Key enthält den Audio-Index (`a%d`), ein
    /// Wechsel erzeugt also serverseitig eine eigene ffmpeg-Session.
    private func appendAudioParam(_ path: String) -> String {
        guard let idx = selectedTranscodeAudioIndex else { return path }
        let sep = path.contains("?") ? "&" : "?"
        return "\(path)\(sep)audio=\(idx)"
    }

    /// Transcode-Tonspur umschalten: Auswahl merken und die ffmpeg-Session an der
    /// aktuellen Position mit dem neuen `audio=`-Parameter neu starten. Browser-
    /// Pendant: `applySubtitleChoice`/Audio-`change`-Handler in `player.js`, die
    /// `applyPlayback` mit neuem Query erneut aufrufen.
    private func selectTranscodeAudio(_ index: Int) {
        guard isTranscode, index != selectedTranscodeAudioIndex else { return }
        selectedTranscodeAudioIndex = index
        restartTranscodeSession(atAbsolute: currentTime)
    }

    // MARK: - Untertitel-Overlay (WebVTT)

    /// Der aktuell aktive Untertitel-Text (Cue mit start ≤ currentTime ≤ end).
    private var activeSubtitleText: String? {
        guard subtitlesOn, !subtitleCues.isEmpty else { return nil }
        return subtitleCues.first(where: { currentTime >= $0.start && currentTime <= $0.end })?.text
    }

    /// Lädt die erzeugte WebVTT (📝 OCR / 🎤 KI), parst sie und aktiviert das Overlay.
    private func loadSubtitleCues(_ pref: PreferredSubtitle) async {
        let path = pref.vttPath(itemID: item.id)
        guard let vtt = try? await client.fetchText(serverPath: path) else {
            subtitleCues = []
            subtitlesOn = false
            return
        }
        let cues = Self.parseVTT(vtt)
        subtitleCues = cues
        subtitlesOn = !cues.isEmpty
    }

    static func parseVTT(_ raw: String) -> [SubtitleCue] {
        var text = raw
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var out: [SubtitleCue] = []
        for block in text.components(separatedBy: "\n\n") {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            guard let tIdx = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = lines[tIdx].components(separatedBy: "-->")
            guard parts.count == 2,
                  let start = parseVTTTimestamp(parts[0]),
                  let end = parseVTTTimestamp(parts[1]) else { continue }
            let body = lines[(tIdx + 1)...]
                .joined(separator: "\n")
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty {
                out.append(SubtitleCue(start: start, end: end, text: body))
            }
        }
        return out
    }

    static func parseVTTTimestamp(_ s: String) -> Double? {
        let token = s.trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init) ?? ""
        let comps = token.replacingOccurrences(of: ",", with: ".").split(separator: ":").map { Double($0) ?? 0 }
        switch comps.count {
        case 3: return comps[0] * 3600 + comps[1] * 60 + comps[2]
        case 2: return comps[0] * 60 + comps[1]
        default: return nil
        }
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
        subtitleCues = []
        subtitlesOn = false
        // Bei jedem Item-Wechsel (⏮/⏭) zurück auf Server-Default; sonst würde die
        // Audiospur-Wahl vom vorigen Video auf ein Item mit ganz anderer
        // Stream-Reihenfolge übertragen.
        transcodeAudioTracks = []
        selectedTranscodeAudioIndex = nil
        if item.trickplayStatus == "done" {
            Task { await loadTrickplay() }
        }

        // Offline-first: if this item was downloaded, play the local file — works with no
        // network at all. Since 2026-08-27 the server itself already delivers a compatible
        // file for the download (`/api/download?compat=1`, see `internal/download` in the
        // server repo — mirrors what Jellyfin's official apps do: the SERVER decides/fixes
        // compatibility before the client ever sees the file, same way it already does for
        // Direct Play vs. transcode streaming). No client-side remux needed anymore for
        // downloads at all — `LocalTranscodeService` now only exists for local/external
        // libraries scanned directly off disk, which have no server to ask.
        if let localURL = downloads.localFileURL(itemId: item.id) {
            let p = AVPlayer(url: localURL)
            self.player = p
            attachObservers(to: p)
            await loadAudioOptions(for: p)
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

            // Tonspur-Auswahl (nur Transcode): alle Quell-Audiospuren vom Server
            // übernehmen; Startwahl = Vorwahl aus dem Detail-Dialog, sonst die
            // als default markierte, sonst die erste.
            if isTranscode {
                transcodeAudioTracks = (playback.streams ?? []).filter { $0.type == "audio" }
                if let pref = preferredAudioIndex, transcodeAudioTracks.contains(where: { $0.index == pref }) {
                    selectedTranscodeAudioIndex = pref
                } else {
                    selectedTranscodeAudioIndex = transcodeAudioTracks.first(where: { $0.isDefault == true })?.index
                        ?? transcodeAudioTracks.first?.index
                }
            }
            // Untertitel-Vorwahl aus dem Detail-Dialog laden (WebVTT-Overlay).
            if let ps = preferredSubtitle {
                await loadSubtitleCues(ps)
            }

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
            let audioBase = isTranscode ? appendAudioParam(playback.url) : playback.url
            let requestURL = isTranscode ? transcodeURLWithParams(audioBase, start: startAt) : playback.url
            guard let streamURL = client.resolvedURL(forServerPath: requestURL) else {
                errorMessage = "Stream-URL konnte nicht ermittelt werden."
                return
            }
            virtualOffset = isTranscode ? startAt : 0

            // Diagnose 2026-09-03 (tvOS: "spielt nichts ab", stille FigStreamPlayer/CFHTTP/
            // HLS-FASB-Fehler in der Xcode-Konsole ohne jede AVPlayerItem-Fehlermeldung) —
            // zeigt die tatsächlich geladene URL (Schema/Host besonders wichtig: http vs.
            // https, LAN-IP vs. Domain), um den Netzwerk-Fehlschlag einzugrenzen.
            #if DEBUG
            print("[PlayerView] isTranscode=\(isTranscode) startAt=\(startAt) streamURL=\(streamURL.absoluteString)")
            #endif

            let p = AVPlayer(url: streamURL)
            self.player = p
            attachObservers(to: p)
            // Nur bei Direct-Play sinnvoll — bei einer Transcode-Session entscheidet der
            // Server über die Audiospur (Browser-Pendant: das Audio-Dropdown dort), es gibt
            // hier serverseitig nur die eine ausgewählte Spur im Stream.
            if !isTranscode {
                await loadAudioOptions(for: p)
            }
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
            // tvOS-Fix 2026-09-03 (User-Report: "spielt nichts ab", stiller schwarzer
            // Bildschirm ohne jede Meldung): bisher wurde ein asynchron gescheiterter
            // `AVPlayerItem` (z. B. Netzwerk-/URL-Fehler NACH dem erfolgreichen
            // `AVPlayer(url:)`-Konstruktor-Aufruf) nirgendwo beobachtet — `errorMessage`
            // blieb nil, der `player`-Zweig (siehe body oben) zeigte einfach dauerhaft
            // Schwarz. Reuse des ohnehin laufenden 0,5s-Timers statt eines eigenen KVO-
            // Observers.
            if player.currentItem?.status == .failed, errorMessage == nil {
                errorMessage = player.currentItem?.error?.localizedDescription ?? "Wiedergabe fehlgeschlagen."
                return
            }
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
            Task {
                await markWatchedNow()
                // User-Wunsch 2026-08-28: im Zufallsmodus am Videoende automatisch
                // das nächste Zufallsvideo starten (wie der Browser-Shuffle,
                // player.js `vjs.on("ended", …)` → nächstes Item). jumpRandom(by:1)
                // ist derselbe Pfad wie ein Klick auf ⏭.
                if let ctx = randomContext {
                    await jumpRandom(by: 1, context: ctx)
                }
            }
        }

        errorLogObserverToken = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemNewErrorLogEntry,
            object: player.currentItem,
            queue: .main
        ) { [weak player] _ in
            guard errorMessage == nil,
                  let event = player?.currentItem?.errorLog()?.events.last else { return }
            let comment = event.errorComment ?? "unbekannter Netzwerkfehler"
            // tvOS-Fix 2026-09-04 (User-Report auf echtem Gerät: "Stream-Fehler (-16832)"
            // erschien zweimal, im jeweils NÄCHSTEN Versuch spielte das Video dann aber
            // trotzdem): dieser Observer wurde als generischer Auffang für stille 401-
            // Fehlschläge gebaut (siehe Kommentar oben), behandelt aber JEDEN neuen
            // Error-Log-Eintrag als fatal — inklusive harmloser, sich selbst erholender
            // HLS-Pufferwarnungen wie "restarting 2.002000s from end of live playlist;
            // target duration 2s - stall danger". Das ist AVFoundations normales
            // Verhalten am Rand unserer wachsenden `#EXT-X-PLAYLIST-TYPE:EVENT`-Playlist
            // (Client holt kurzzeitig den Server ein, bevor das nächste Segment fertig
            // transkodiert ist) — kein echter Abbruch, AVPlayer puffert einfach nach.
            // Fix: dieses bekannte, unschädliche Muster explizit ausfiltern statt jeden
            // Log-Eintrag als Totalausfall zu werten.
            if comment.localizedCaseInsensitiveContains("stall danger")
                || comment.localizedCaseInsensitiveContains("end of live playlist") {
                return
            }
            errorMessage = "Stream-Fehler (\(event.errorStatusCode)): \(comment)"
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
              let url = client.resolvedURL(forServerPath: urlWithStart(appendAudioParam(template), start: target)) else { return }
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
    /// User-Anfrage 2026-08-27: Tonspur wählbar machen (Download/Direct-Play — bei einer
    /// Server-Transcode-Session bleibt das leer, siehe `PlayerView.setUp()`). Button erscheint
    /// nur, wenn die Quelle wirklich mehr als eine Audiospur hat.
    var audioOptions: [AVMediaSelectionOption] = []
    var selectedAudioOption: AVMediaSelectionOption? = nil
    var onSelectAudioOption: ((AVMediaSelectionOption) -> Void)? = nil
    /// Tonspur-Auswahl bei Server-Transcode (parallel zu `audioOptions`, das nur
    /// für lokale/Direct-Play-Quellen greift). Menü erscheint bei >1 Spur.
    var transcodeAudioTracks: [MediaStream] = []
    var selectedTranscodeAudioIndex: Int? = nil
    var onSelectTranscodeAudio: ((Int) -> Void)? = nil
    /// Untertitel-Einblendung (WebVTT-Overlay). Button erscheint nur, wenn Cues
    /// geladen sind (Vorwahl aus dem Detail-Dialog, siehe `PlayerView.loadSubtitleCues`).
    var hasSubtitles: Bool = false
    var subtitlesOn: Bool = false
    var onToggleSubtitles: (() -> Void)? = nil

    @State private var scrubValue: Double = 0
    @State private var volumeBeforeMute: Float = 1.0
    // User-Anfrage 2026-09-02: im iPhone-Hochkantformat war die Leiste (fixe
    // 40pt-Außenpolsterung + volle Lautstärke-Slider-Breite) zu breit fürs
    // schmale Fenster und lief über/quetschte Icons. `horizontalSizeClass`
    // ist auf iPhones in Hoch- UND Querformat `.compact`, auf iPad/Mac
    // `.regular` — kompakte Werte greifen also gezielt auf dem iPhone.
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    private var isCompact: Bool { horizontalSizeClass == .compact }

    // tvOS-Fix 2026-09-04 (User-Report auf echtem Apple TV, mit Foto belegt): die
    // Steuerelemente saßen so eng beieinander, dass sie sich sichtbar überlappten.
    // Ursache: alle Abstände hier unterscheiden bisher nur "iPhone (isCompact)" vs.
    // "iPad/Mac" — auf tvOS greift mangels Size-Class-Konzept immer der iPad/Mac-Wert,
    // obwohl tvOS' 10-Fuß-UI die Symbole selbst schon deutlich größer rendert
    // (SwiftUIs Standard-Textstile sind auf tvOS grundsätzlich größer skaliert). Gleiche
    // Lücke wie bei iPhone/iPad — hier extra großzügige tvOS-Werte statt die iPad-Werte
    // mitzubenutzen.
    private func spacing(compact: CGFloat, regular: CGFloat, tv: CGFloat) -> CGFloat {
        #if os(tvOS)
        return tv
        #else
        return isCompact ? compact : regular
        #endif
    }

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

            HStack(spacing: spacing(compact: 8, regular: 16, tv: 36)) {
                HStack(spacing: spacing(compact: 6, regular: 12, tv: 26)) {
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
                        // Auf dem iPhone hat das Steuerfeld im Hochkantformat zu wenig Platz
                        // für den Slider (iOS hat ohnehin Hardware-Lautstärketasten) — nur
                        // der Mute-Button bleibt, Regler nur auf breiteren Screens (iPad/Mac).
                        // `Slider` existiert außerdem gar nicht auf tvOS — dort regelt die
                        // Fernbedienung/der Fernseher die Lautstärke ohnehin systemseitig.
                        #if !os(tvOS)
                        if !isCompact {
                            Slider(value: Binding(get: { volume }, set: { volume = $0; onVolumeChange($0) }), in: 0...1)
                                .frame(width: 60)
                        }
                        #endif
                    }
                }
                .foregroundStyle(.white)

                Spacer(minLength: spacing(compact: 6, regular: 12, tv: 30))

                HStack(spacing: spacing(compact: 10, regular: 18, tv: 42)) {
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

                Spacer(minLength: spacing(compact: 6, regular: 12, tv: 30))
                HStack(spacing: spacing(compact: 8, regular: 12, tv: 32)) {
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
                    if audioOptions.count > 1, let onSelectAudioOption {
                        Menu {
                            ForEach(audioOptions, id: \.self) { option in
                                Button {
                                    onSelectAudioOption(option)
                                } label: {
                                    if option == selectedAudioOption {
                                        Label(option.displayName, systemImage: "checkmark")
                                    } else {
                                        Text(option.displayName)
                                    }
                                }
                            }
                        } label: {
                            Image(systemName: "waveform")
                        }
                    } else if transcodeAudioTracks.count > 1, let onSelectTranscodeAudio {
                        Menu {
                            ForEach(transcodeAudioTracks, id: \.index) { track in
                                Button {
                                    onSelectTranscodeAudio(track.index)
                                } label: {
                                    if track.index == selectedTranscodeAudioIndex {
                                        Label(Self.audioTrackLabel(track), systemImage: "checkmark")
                                    } else {
                                        Text(Self.audioTrackLabel(track))
                                    }
                                }
                            }
                        } label: {
                            Image(systemName: "waveform")
                        }
                    }
                    if hasSubtitles, let onToggleSubtitles {
                        Button(action: onToggleSubtitles) {
                            Image(systemName: subtitlesOn ? "captions.bubble.fill" : "captions.bubble")
                                .foregroundStyle(subtitlesOn ? Color.yellow : Color.white)
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
        .padding(.horizontal, isCompact ? 10 : 20)
        .padding(.vertical, 12)
        .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        .fixedSize(horizontal: false, vertical: true) // guard against any accidental vertical stretch from the parent
        // User-Anfrage 2026-08-19: "Steuerfenster des Players ein klein wenig größer machen".
        // User-Anfrage 2026-09-02: die feste 40pt-Außenpolsterung ließ auf dem iPhone im
        // Hochkantformat zu wenig Breite für die Leiste übrig ("zu groß, passt nicht") —
        // auf schmalen (compact) Screens deutlich reduziert.
        // tvOS-Fix 2026-09-04: die 560pt-Deckelung war für iPhone/iPad/Mac gedacht — mit den
        // größeren tvOS-Abständen oben (siehe `spacing(...)`) hätte sie den ganzen Effekt
        // sofort wieder zunichtegemacht (Inhalt zusammengequetscht statt nur breiter verteilt).
        .frame(maxWidth: spacing(compact: 560, regular: 560, tv: 1050))
        .padding(.horizontal, isCompact ? 8 : 40)
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// „DEU · Directors Cut · ac3 · 5.1" — gleiche Bestandteile wie das
    /// Audio-Dropdown im Browser (`player.js`).
    static func audioTrackLabel(_ s: MediaStream) -> String {
        var parts: [String] = []
        if let l = s.language, !l.isEmpty { parts.append(l.uppercased()) }
        if let t = s.title, !t.isEmpty { parts.append(t) }
        if let c = s.codec, !c.isEmpty { parts.append(c) }
        if let ch = s.channels, ch > 0 { parts.append(ch == 6 ? "5.1" : (ch == 8 ? "7.1" : "\(ch)ch")) }
        return parts.isEmpty ? "Spur \(s.index)" : parts.joined(separator: " · ")
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
    #if os(tvOS)
    // tvOS-Fix 2026-09-04 (User-Report: "Spulen über die Zeitleiste geht nicht,
    // wenn ich lange auf der rechten Pfeiltaste bleibe"): die Siri-Remote feuert
    // `onMoveCommand` bei gehaltener Taste wiederholt (Auto-Repeat), und
    // `onScrubEnd` löst bei einer Transcode-Session `restartTranscodeSession`
    // aus — das reißt den AVPlayer komplett ab und baut einen neuen auf. Ohne
    // Debounce riss jedes Auto-Repeat-Event den gerade erst neu aufgebauten
    // Player sofort wieder ein, bevor er überhaupt etwas anzeigen konnte —
    // sichtbar passierte nie ein Sprung. Jetzt: `scrubValue` akkumuliert
    // während des Haltens (Basis ist `scrubValue`, nicht `currentTime`, die ja
    // noch gar nicht aktualisiert wurde), der echte Seek feuert erst, wenn für
    // 400ms kein weiteres Move-Event mehr kam.
    @State private var scrubCommitTask: Task<Void, Never>?
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
                #if os(tvOS)
                // `Slider` existiert nicht auf tvOS — als erster funktionaler Ersatz
                // ±10s-Sprünge über Links/Rechts-Wischen auf der Siri-Remote-Touchfläche
                // (`onMoveCommand`), solange die Leiste fokussiert ist. Echtes
                // Drag-Scrubbing wäre ein eigener Anlauf (Fokus-Engine + Touch-Surface-
                // Geschwindigkeit), hier bewusst erstmal minimal gehalten.
                ProgressView(value: isScrubbing ? scrubValue : currentTime, total: max(duration, 1))
                    .frame(width: geo.size.width)
                    .focusable(true)
                    .onMoveCommand { direction in
                        let base = isScrubbing ? scrubValue : currentTime
                        let delta: Double
                        switch direction {
                        case .left: delta = -10
                        case .right: delta = 10
                        default: return
                        }
                        scrubValue = min(max(duration, 1), max(0, base + delta))
                        isScrubbing = true
                        scrubCommitTask?.cancel()
                        scrubCommitTask = Task {
                            try? await Task.sleep(nanoseconds: 400_000_000)
                            if Task.isCancelled { return }
                            onScrubEnd(scrubValue)
                            isScrubbing = false
                        }
                    }
                #else
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
                #endif

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
