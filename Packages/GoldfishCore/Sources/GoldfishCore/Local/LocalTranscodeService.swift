import Foundation
import AVFoundation

/// Fixes local files AVFoundation can't play natively (MKV container, DTS/AC3 audio, …) by
/// remuxing them once with `ffmpeg` — video is stream-copied (no re-encode, seconds not
/// minutes), only the audio gets transcoded to AAC and the container repackaged to MP4.
/// The result is cached permanently, so this only runs once per file. Mac-only: iOS can't
/// spawn arbitrary executables — a future iOS version would need an embedded ffmpeg
/// *library* (e.g. an FFmpegKit-style binding) instead of shelling out to a binary.
///
/// Chosen over an alternate player engine (VLCKit) 2026-08-19: keeps every local file
/// playing through the same native `AVPlayer`, so seeking/PiP/AirPlay stay exactly as
/// reliable as they already are — the cost is paid once at first-play, not on every
/// playback session.
#if os(macOS)
/// Thread-safe accumulator for ffmpeg's stderr output — written from the `Pipe`'s
/// `readabilityHandler` (arbitrary background queue) and read from the process's
/// `terminationHandler` (a different queue), so a plain captured `var` isn't safe here.
private final class StderrBox: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = ""

    func append(_ chunk: String) {
        lock.lock(); defer { lock.unlock() }
        buffer += chunk
    }

    func tail(_ n: Int) -> String {
        lock.lock(); defer { lock.unlock() }
        return String(buffer.suffix(n))
    }
}

@MainActor
public final class LocalTranscodeService: ObservableObject {
    public static let shared = LocalTranscodeService()

    public enum TranscodeError: LocalizedError {
        case ffmpegNotFound
        case processFailed(String)
        case notEnoughDiskSpace(availableGB: Double)

        public var errorDescription: String? {
            switch self {
            case .ffmpegNotFound:
                return "ffmpeg wurde nicht gefunden. Bitte installieren, z.B. mit \"brew install ffmpeg\"."
            case .processFailed(let detail):
                return "Konvertierung fehlgeschlagen: \(detail)"
            case .notEnoughDiskSpace(let availableGB):
                return String(format: "Nicht genug freier Speicherplatz (nur %.1f GB frei) — Konvertierung übersprungen, um die Systemplatte nicht vollzumachen. Bitte Platz freiräumen und erneut versuchen.", availableGB)
            }
        }
    }

    /// 0...1 while a conversion is running, keyed by the same cache key as `convertedURL(cacheKey:)`.
    @Published public private(set) var progress: [String: Double] = [:]

    // MARK: - Background queue (auto-convert after each scan, see `enqueueCompatibilityCheck`)
    // Local-library-specific — downloaded server items are handled server-side now (2026-08-27:
    // `/api/download?compat=1`, see `internal/download` in the server repo), no client-side
    // conversion needed for them at all anymore.

    /// Items waiting their turn — surfaced in Settings so the user can see what's left.
    @Published public private(set) var queuedItems: [LocalItem] = []
    @Published public private(set) var currentItem: LocalItem?
    // `completedCount`/`failedItems` persist across app restarts (UserDefaults) — real bug
    // hit 2026-08-19: the whole "Formatanpassung" history section in Settings disappeared
    // after quitting and reopening the app, because these were purely in-memory `@Published`
    // state with nothing writing them to disk. The user explicitly wants the result to stay
    // visible, not just for the current run.
    // Real bug hit 2026-08-19: a full cache purge (see `purgeStaleCacheIfNeeded`) forced the
    // same 22 already-converted files to reconvert, and each success did `completedCount += 1`
    // regardless of whether that item had already been counted before — the same file re-run
    // twice became 44. An ever-incrementing counter can't be idempotent under retries by
    // construction. Fix: `completedCount` is no longer state at all, just a live count of
    // `.mp4` files actually sitting in the cache folder (`refreshCompletedCount()`) — re-
    // converting the same file replaces the same cache entry, so the count can't double no
    // matter how many times a rescan touches it, and it also self-corrects if the user ever
    // deletes files from the cache folder directly.
    @Published public private(set) var completedCount = 0
    @Published public private(set) var failedItems: [UUID: String] = [:] {
        didSet {
            let encoded = Dictionary(uniqueKeysWithValues: failedItems.map { ($0.key.uuidString, $0.value) })
            if let data = try? JSONEncoder().encode(encoded) {
                UserDefaults.standard.set(data, forKey: Self.failedItemsKey)
            }
        }
    }
    private static let failedItemsKey = "goldfish.transcode.failedItems"
    private var isProcessingQueue = false

    /// User-Report 2026-08-24: "spielt gar keine lokalen Dateien ab oder es hängt und dann
    /// läuft es plötzlich viel zu schnell, als wenn er aufholen würde" bei Videos von einer
    /// externen USB-Platte — klassisches Bandbreiten-Contention-Symptom. Die
    /// Hintergrund-Warteschlange (`processQueue`/`rescanDownloads`) liest dabei per `ffmpeg`
    /// GLEICHZEITIG von genau derselben externen Platte, von der der Player gerade abspielt
    /// (USB hat nur eine gemeinsame Bandbreite für alle Prozesse). Gleiches Muster wie
    /// Goldfish-Server's Introskip-Pause während eines Scans (CLAUDE.md): neue
    /// Warteschlangen-Items starten nicht, solange mindestens ein Player aktiv wiedergibt.
    /// Ein bereits laufender ffmpeg-Remux wird NICHT abgebrochen (würde die investierte Zeit
    /// verschwenden) — nur das Anfangen eines NEUEN Items wird zurückgehalten.
    private var activePlaybackCount = 0
    private var isPlaybackActive: Bool { activePlaybackCount > 0 }

    /// Called by `LocalPlayerView` when a local file starts playing — paired 1:1 with
    /// `endPlayback()` in `teardown()`. Counted (not a plain Bool) so two player windows open
    /// at once don't let the second one's teardown prematurely resume the queue while the
    /// first is still playing.
    public func beginPlayback() { activePlaybackCount += 1 }
    public func endPlayback() { activePlaybackCount = max(0, activePlaybackCount - 1) }

    /// Real bug hit 2026-08-24 (User: "wenn ich auf 'Erneut prüfen' klicke, passiert nichts"):
    /// `beginPlayback()`/`endPlayback()` above are only 1:1 balanced if `teardown()` actually
    /// runs — but `LocalPlayerView.onDisappear` is the SAME unreliable-on-native-red-button
    /// SwiftUI lifecycle hook already documented elsewhere in this app (see the cursor-leak
    /// fix). Close the local player window that way once while a video is playing, and
    /// `activePlaybackCount` never comes back down — `waitWhilePlaybackActive()` then blocks
    /// forever, silently freezing the ENTIRE background queue (including "Erneut prüfen") for
    /// the rest of the app session. `PlayerLaunchCoordinator` only ever allows ONE local player
    /// window open at a time (`present(_:openWindow:)` reuses an existing one), so once that
    /// window's `NSWindow.willCloseNotification` fires — a genuinely reliable signal, already
    /// used to clear `localPlayerWindow`/`pendingLocalPlayer` — there is, by construction, no
    /// local playback left at all. A hard reset there (not a decrement) is therefore always
    /// correct and immune to however many times `endPlayback()` did or didn't already fire.
    public func resetPlaybackActive() { activePlaybackCount = 0 }

    /// Real bug hit 2026-08-26 (User: "Videos stocken immer noch!"): `ps aux` zeigte VIER
    /// ffmpeg-Prozesse, alle älter als die aktuell laufende App-Instanz — verwaiste
    /// Re-Encodes aus früheren App-Läufen (während dieser Session mehrfach neu gebaut +
    /// neu gestartet), die nie beendet wurden, weil `Process()` standardmäßig NICHT beendet
    /// wird, wenn der Elternprozess (die App) sich beendet — es wird einfach zu `launchd`
    /// reparented und läuft unabhängig weiter. Vier gleichzeitige ffmpeg-Prozesse, die alle
    /// von derselben externen Platte lesen, erklären massives Ruckeln unabhängig von jedem
    /// Playback-Pause-Fix. Fix: jeder gestartete ffmpeg-`Process` wird hier getrackt,
    /// `AppDelegate.applicationWillTerminate` ruft `terminateAllActiveProcesses()` beim
    /// Beenden der App auf.
    private var activeProcesses: [ObjectIdentifier: Process] = [:]

    private func trackActiveProcess(_ process: Process) {
        activeProcesses[ObjectIdentifier(process)] = process
    }

    private func untrackActiveProcess(_ process: Process) {
        activeProcesses[ObjectIdentifier(process)] = nil
    }

    public func terminateAllActiveProcesses() {
        for process in activeProcesses.values where process.isRunning {
            process.terminate()
        }
        activeProcesses.removeAll()
    }

    /// Polled between queue items — mirrors the server's `waitWhilePaused` for Introskip.
    /// `public`, weil auch `LocalLibraryManager`s Thumbnail-/Auflösungs-Hintergrundschleife
    /// (`generateThumbnailIfNeeded`) sich hieran halten muss — real bug hit 2026-08-26: die
    /// war NICHT an dieses Pause-Signal angeschlossen, hat also während aktiver Wiedergabe
    /// weiter fröhlich andere Dateien von derselben (langsamen) SD-Karte gelesen. Gleicher
    /// I/O-Contention-Bug wie bei der Formatanpassungs-Warteschlange, nur an einer zweiten,
    /// unabhängigen Stelle.
    public func waitWhilePlaybackActive() async {
        while isPlaybackActive {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    /// Same-item conversions started from two places at once (the background queue AND the
    /// user directly opening the player) must not run ffmpeg twice on the same file — the
    /// second caller joins the first's already-running `Task` instead. Keyed the same way as
    /// `progress`/`convertedURL(cacheKey:)`.
    private var inFlightTasks: [String: Task<URL, Error>] = [:]

    /// Set once by `LocalLibraryManager` — called after each successful background
    /// conversion so a thumbnail can be (re-)generated from the now-playable copy, since the
    /// original MKV source usually fails thumbnail generation for the same reason it fails
    /// playback (AVFoundation can't demux MKV at all, independent of the codecs inside).
    public var onConverted: (@MainActor (LocalItem) -> Void)?

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.failedItemsKey),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            failedItems = Dictionary(uniqueKeysWithValues: decoded.compactMap { key, value in
                UUID(uuidString: key).map { ($0, value) }
            })
        }
        Self.purgeStaleCacheIfNeeded()
        // Real Fund 2026-08-20: eine 5,5 GB große `local-<uuid>.tmp.mp4` blieb nach einem
        // vermutlichen App-Absturz/Kill mitten in einer Konvertierung für immer liegen —
        // `performRemux` löscht den `.tmp.mp4`-Rest einer vorherigen Konvertierung nur direkt
        // VOR dem nächsten Versuch für DENSELBEN cacheKey, nicht generell. Ein Item, das
        // danach nie wieder angefasst wurde (z.B. weil es inzwischen erfolgreich lief oder
        // gelöscht wurde), ließ seinen Rest für immer im Cache-Ordner liegen — komplett
        // unsichtbar für `enforceCacheSizeCap` als "Müll", zählt dort nur als normaler
        // (potenziell nie evicteter, weil ggf. "kürzlich" modifiziert) Cache-Eintrag mit.
        // Jeder `.tmp.mp4`-Fund beim Start ist per Definition ein abgebrochener Rest, nie
        // eine gültige fertige Konvertierung — immer sicher zu löschen.
        Self.purgeOrphanedTempFiles()
        // Proaktiv beim Start prüfen, nicht erst nach der nächsten Konvertierung — der User
        // hat sich 2026-08-20 bewusst gegen ein Einmal-Aufräumen des damals schon 177 GB
        // großen Bestands entschieden, das Limit soll den Bestand aber trotzdem von selbst
        // auf 40 GB zurückführen, sobald die App das nächste Mal läuft, nicht erst beim
        // nächsten manuellen "Erneut prüfen".
        Self.enforceCacheSizeCap()
        refreshCompletedCount()
    }

    /// Real bug hit 2026-08-19: a file converted with an OLDER, buggy ffmpeg command (missing
    /// the `hvc1` video tag, the broken `pan=c0=c0|c1=c1` audio filter, or — the actual root
    /// cause of the "download plays audio, no video" report — an AV1 source blindly
    /// `-c:v copy`'d instead of re-encoded, since AVFoundation can't decode AV1 at all) stays
    /// cached as "done" forever, because `remux(cacheKey:)` treats file-existence alone as
    /// proof the conversion is correct — it never re-checks against the current ffmpeg args.
    /// Fix: bump `cacheFormatVersion` whenever the ffmpeg command changes in a way that could
    /// produce a different (better) output for already-cached files, and wipe the whole cache
    /// once when the stored version is older — forces every file, local AND downloaded, back
    /// through the current (fixed) pipeline instead of silently keeping stale broken output
    /// around. Bumped to 3 for the AV1-video-needs-re-encode + AAC-audio-skip-re-encode fixes.
    private static let cacheFormatVersion = 3
    private static let cacheFormatVersionKey = "goldfish.transcode.cacheFormatVersion"

    private static func purgeStaleCacheIfNeeded() {
        let stored = UserDefaults.standard.integer(forKey: cacheFormatVersionKey)
        guard stored < cacheFormatVersion else { return }
        if let contents = try? FileManager.default.contentsOfDirectory(at: outDir, includingPropertiesForKeys: nil) {
            for url in contents { try? FileManager.default.removeItem(at: url) }
        }
        UserDefaults.standard.set(cacheFormatVersion, forKey: cacheFormatVersionKey)
    }

    private static func purgeOrphanedTempFiles() {
        guard let contents = try? FileManager.default.contentsOfDirectory(at: outDir, includingPropertiesForKeys: nil) else { return }
        for url in contents where url.lastPathComponent.hasSuffix(".tmp.mp4") {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Recomputes `completedCount` from what's actually in the cache folder — see the comment
    /// on `completedCount` for why this replaced a manually-incremented counter.
    ///
    /// Real bug hit 2026-08-19 (User: "der Zähler muss pro Benutzer gelten, bei Börnie startet
    /// er schon mit 41 — das sind aber Anpassungen von Christian"): the cache folder
    /// (`GoldfishTranscoded`) is a single shared folder for the whole Mac, not per-user — this
    /// raw count is therefore the total across EVERY account that ever converted a file here,
    /// same class of bug as the local-libraries/downloads per-user isolation fixes. `completedCount`
    /// itself stays the unscoped total (kept for internal bookkeeping / anything that doesn't
    /// care about ownership); the UI-facing number is `scopedCompletedCount(...)` below, which
    /// filters by which local items / downloads actually belong to the CURRENT user.
    private func refreshCompletedCount() {
        completedCount = cacheFileNames().count
    }

    private func cacheFileNames() -> [String] {
        (try? FileManager.default.contentsOfDirectory(at: Self.outDir, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "mp4" && !$0.lastPathComponent.hasSuffix(".tmp.mp4") }
            .map { $0.deletingPathExtension().lastPathComponent } ?? []
    }

    /// Same count as `completedCount`, but scoped to files that belong to the CURRENT user —
    /// pass the caller's own visible local-item UUIDs (already per-user-filtered by
    /// `LocalLibraryManager`) to cross-reference against the cache filenames' `local-<uuid>`
    /// prefix. Downloads no longer produce cache entries here at all (2026-08-27: the server
    /// delivers already-compatible downloads via `?compat=1`, see `internal/download` in the
    /// server repo) — this only ever sees local/external-library conversions now.
    public func scopedCompletedCount(ownedLocalItemIds: Set<UUID>) -> Int {
        cacheFileNames().filter { name in
            guard name.hasPrefix("local-"), let uuid = UUID(uuidString: String(name.dropFirst("local-".count))) else { return false }
            return ownedLocalItemIds.contains(uuid)
        }.count
    }

    private static let outDir: URL = {
        let fm = FileManager.default
        let support = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fm.temporaryDirectory
        let dir = support.appendingPathComponent("GoldfishTranscoded", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Cache is shared between local-library items (`"local-<uuid>"`) and downloaded server
    /// items (`"dl-<itemId>"`) — real bug hit 2026-08-19: downloaded files play back through
    /// a completely different code path (`PlayerView`'s offline branch) than local-library
    /// files, but the server's `/api/download` endpoint serves the ORIGINAL, untranscoded
    /// file (CLAUDE.md "Download & Löschen") — same MKV/DTS/HEVC-tag incompatibilities apply.
    /// Unifying the cache means both paths get dedup (`inFlightTasks`) and progress tracking
    /// for free instead of two parallel, diverging implementations.
    private func convertedURL(cacheKey: String) -> URL {
        Self.outDir.appendingPathComponent("\(cacheKey).mp4")
    }

    private func isConverted(cacheKey: String) -> Bool {
        FileManager.default.fileExists(atPath: convertedURL(cacheKey: cacheKey).path)
    }

    public func convertedURL(for item: LocalItem) -> URL {
        convertedURL(cacheKey: "local-\(item.id.uuidString)")
    }

    public func isConverted(_ item: LocalItem) -> Bool {
        isConverted(cacheKey: "local-\(item.id.uuidString)")
    }

    public func deleteConverted(_ item: LocalItem) {
        try? FileManager.default.removeItem(at: convertedURL(for: item))
    }

    /// Called once per scan (`LocalLibraryManager.scan`) — probes each new/unconverted item
    /// for native playability and queues the incompatible ones for background conversion, so
    /// the fix happens ahead of time instead of the user hitting a dead player on first play.
    ///
    /// User-Anfrage 2026-08-26 (radikaler Kurswechsel, ersetzt die Fast/Slow-Prioritätslogik
    /// vom Vortag komplett): "es werden immer noch schnelle Dateien geladen, bevor die
    /// langsamen kommen — das darf nicht sein. Nur noch langsame Dateien bearbeiten, bei
    /// schnellen nur ein Vorschaubild erzeugen." Jeder noch so sorgfältig sortierte
    /// gemeinsame Queue-Mechanismus (siehe Git-Historie: erst Datei-Reihenfolge, dann
    /// `insert(at: 0)`-Priorisierung) blieb angreifbar, sobald mehrere Bibliotheken parallel
    /// scannen oder ein Lauf mitten drin neu gestartet wird. Klarster Schnitt: schnelle
    /// Dateien (reiner Stream-Copy-Remux, Sekunden) werden ab sofort NIE MEHR in den
    /// Hintergrund vorab konvertiert — nur noch beim tatsächlichen Abspielen on-demand
    /// (`LocalPlayerView.setUp()`), das ist bei Sekunden-Dauer ohnehin kaum spürbar. Die
    /// Hintergrund-Queue (`queuedItems`/`processQueue`) enthält dadurch AUSSCHLIESSLICH noch
    /// echte Re-Encodes — es gibt gar keine Fast/Slow-Mischung mehr, die falsch sortiert sein
    /// könnte. Für schnelle Dateien wird stattdessen nur ein Vorschaubild direkt aus der
    /// Quelldatei erzeugt (`LocalLibraryManager.generateThumbnailIfNeeded`s ffmpeg-Fallback,
    /// siehe dort) — dauerhaft im `thumbsDir` gespeichert, unabhängig vom (jetzt gar nicht
    /// mehr befüllten) Transcode-Cache für diese Dateien.
    public func enqueueCompatibilityCheck(items: [LocalItem], fileURLProvider: @escaping @MainActor (LocalItem) -> URL?) {
        Task {
            var slow: [LocalItem] = []
            for item in items {
                guard !isConverted(item), !queuedItems.contains(where: { $0.id == item.id }), currentItem?.id != item.id else { continue }
                guard let url = fileURLProvider(item) else { continue }
                // Real bug hit 2026-08-26, siehe `waitWhilePlaybackActive()`-Kommentar: auch
                // dieser Klassifizierungs-Durchlauf öffnet pro Item eine `AVURLAsset` — ohne
                // diese Pause würde er während aktiver Wiedergabe weiter andere Dateien von
                // derselben (ggf. langsamen) Karte lesen.
                await waitWhilePlaybackActive()
                // `?? false`, siehe Kommentar bei `autoConvertDownloadIfNeeded` — konsistent
                // mit dem play-time-Check in `LocalPlayerView`.
                let playable = (try? await AVURLAsset(url: url).load(.isPlayable)) ?? false
                guard !playable else { continue }
                guard await Self.needsSlowReencode(sourceURL: url) else { continue }
                slow.append(item)
                // Schnelle Dateien werden bewusst NICHT mehr hier gesammelt — sie werden
                // nirgends vorab konvertiert, nur beim Abspielen on-demand.
            }
            // Alte, schon vorab konvertierte "schnelle" Cache-Einträge aus früheren App-Läufen
            // (vor diesem Kurswechsel) sind jetzt reine Speicherverschwendung — nichts fragt
            // sie noch aktiv an, seit Thumbnails per ffmpeg direkt aus der Quelle kommen.
            deleteAllFastConversions()
            queuedItems.append(contentsOf: slow)
            processQueue(fileURLProvider: fileURLProvider)
        }
    }

    /// User-Anfrage 2026-08-24: "bitte dann auch alle schnellen aus dem Cache löschen, und nur
    /// die langsamen drin behalten". Items, deren Quelldatei GERADE nicht erreichbar ist
    /// (Datenträger nicht eingesteckt), werden übersprungen statt geraten — lieber einen nicht
    /// klassifizierbaren Cache-Eintrag behalten als versehentlich einen teuren
    /// Re-Encode-Output wegwerfen, den man nicht mehr neu erzeugen könnte, falls die
    /// Klassifizierung falsch geraten würde.
    ///
    /// **NICHT an "Erneut prüfen" hängen** (Regression, noch am selben Tag zurückgerollt): das
    /// erzeugt eine Endlosschleife — Datei wird konvertiert, dieselbe Aktion löscht sie
    /// (weil "schnell") direkt wieder aus dem Cache, gilt beim nächsten Scan wieder als
    /// unkonvertiert, wird erneut in die Warteschlange gepackt und erneut konvertiert. Die
    /// Warteschlange bleibt dadurch dauerhaft mit denselben schnellen Dateien beschäftigt und
    /// kommt nie zu den eigentlich wichtigen langsamen. Nur als bewusst separat ausgelöste,
    /// einmalige Aufräum-Aktion aufrufen, nie als Teil eines wiederkehrenden Buttons/Triggers.
    ///
    /// User-Anfrage 2026-08-26 (voller Speicher trotz "nur langsame konvertieren"): sofortiger
    /// manueller Cleanup-Weg statt nur passiv auf `enforceCacheSizeCap()`s Eviction zu warten.
    /// Nutzt ausschließlich die schon beim Konvertieren persistierte `.slow-classification.json`
    /// statt erneut den Quell-Codec zu proben (anders als eine frühere, nie ans UI angebundene
    /// Fassung dieser Funktion) — funktioniert dadurch auch, wenn der externe Datenträger
    /// gerade nicht eingesteckt ist, UND deckt Downloads (`dl-`/`dl-inplace-`-Keys) mit ab, nicht
    /// nur lokale Bibliotheks-Items (`local-`). Unklassifizierte Alt-Einträge (vor diesem
    /// Feature konvertiert) zählen wie überall sonst im Cap/Eviction-Code als "schnell"
    /// (sicherer Default) und werden ebenfalls gelöscht.
    /// User-Anfrage 2026-08-26 (direkt im Anschluss an den Fast/Slow-Kurswechsel): "Erneut
    /// prüfen" soll alle bisherigen Fehler wegwischen, damit man danach sieht, ob NEUE
    /// dazukommen — sonst bleiben Fehlermeldungen von schnellen Dateien für immer stehen, die
    /// jetzt bewusst nie mehr angefasst werden (siehe `enqueueCompatibilityCheck`), und der
    /// User kann nicht mehr unterscheiden "alter Fehler von vor dem Kurswechsel" von "besteht
    /// gerade wirklich noch". `@Published` mit `didSet`, das den UserDefaults-Snapshot
    /// automatisch mit aktualisiert — kein zusätzlicher Persistenz-Code nötig. Aufgerufen vom
    /// "Erneut prüfen"-Button in `SettingsView`, VOR dem eigentlichen Rescan/Retry-Aufruf.
    public func clearAllFailures() {
        failedItems = [:]
    }

    public func deleteAllFastConversions() {
        guard let cacheFiles = try? FileManager.default.contentsOfDirectory(at: Self.outDir, includingPropertiesForKeys: nil) else { return }
        let classification = Self.loadClassification()
        var removedKeys: [String] = []
        for url in cacheFiles where url.pathExtension == "mp4" && !url.lastPathComponent.hasSuffix(".tmp.mp4") {
            let key = url.deletingPathExtension().lastPathComponent
            guard classification[key] != true else { continue }
            try? FileManager.default.removeItem(at: url)
            removedKeys.append(key)
        }
        guard !removedKeys.isEmpty else { return }
        var dict = classification
        for key in removedKeys { dict[key] = nil }
        if let data = try? JSONEncoder().encode(dict) {
            try? data.write(to: Self.classificationURL)
        }
        refreshCompletedCount()
    }

    /// Same "needs a real re-encode, not just a stream-copy" decision `performRemux` makes for
    /// its video-codec switch — kept in sync with that switch's cases (`hevc`/`h264`/`prores`
    /// are fast copies, everything else needs `h264_videotoolbox`).
    private static func needsSlowReencode(sourceURL: URL) async -> Bool {
        switch await probeVideoCodec(sourceURL: sourceURL) {
        case "hevc", "h264", "prores": return false
        default: return true
        }
    }

    private func processQueue(fileURLProvider: @escaping @MainActor (LocalItem) -> URL?) {
        guard !isProcessingQueue else { return }
        isProcessingQueue = true
        Task {
            while !queuedItems.isEmpty {
                await waitWhilePlaybackActive()
                let item = queuedItems.removeFirst()
                guard let url = fileURLProvider(item) else { continue }
                currentItem = item
                do {
                    _ = try await remux(cacheKey: "local-\(item.id.uuidString)", sourceURL: url)
                    refreshCompletedCount()
                    failedItems[item.id] = nil
                    onConverted?(item)
                } catch {
                    failedItems[item.id] = error.localizedDescription
                }
            }
            currentItem = nil
            isProcessingQueue = false
        }
    }

    /// Runs the remux if not already cached. Safe to call every time before playback, and
    /// safe to call concurrently for the same item from multiple places (background queue +
    /// direct play) — joins the already-running conversion instead of starting a second one.
    public func remux(item: LocalItem, sourceURL: URL) async throws -> URL {
        try await remux(cacheKey: "local-\(item.id.uuidString)", sourceURL: sourceURL)
    }

    private func remux(cacheKey: String, sourceURL: URL) async throws -> URL {
        let dest = convertedURL(cacheKey: cacheKey)
        if FileManager.default.fileExists(atPath: dest.path) {
            // LRU-Signal für `enforceCacheSizeCap()` — ohne dieses Touch würde die
            // Eviction nach Konvertierungs-Datum statt tatsächlicher Nutzung sortieren,
            // eine oft angeschaute alte Konvertierung würde dann vor einer frisch
            // konvertierten, aber nie wieder angesehenen Datei rausfliegen.
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: dest.path)
            return dest
        }

        if let existing = inFlightTasks[cacheKey] {
            return try await existing.value
        }
        let task = Task { try await performRemux(cacheKey: cacheKey, sourceURL: sourceURL, dest: dest) }
        inFlightTasks[cacheKey] = task
        defer { inFlightTasks[cacheKey] = nil }
        return try await task.value
    }

    private func performRemux(cacheKey: String, sourceURL: URL, dest: URL) async throws -> URL {
        guard let ffmpegPath = Self.findFFmpeg() else { throw TranscodeError.ffmpegNotFound }

        // Real bug hit 2026-08-24: ein Re-Encode lief 18 Minuten, bevor er mit "No space left
        // on device" abbrach — die Platte war die ganze Zeit schon zu voll, das hätte man VORHER
        // wissen können. Erst proaktiv Platz schaffen (evict alter Cache-Einträge, siehe
        // `minFreeBytes`-Kommentar bei `enforceCacheSizeCap`), DANN prüfen ob's reicht — reicht
        // es immer noch nicht (Cache ist schon leer, Platte ist aus anderen Gründen voll), sofort
        // mit einer klaren Meldung abbrechen statt ffmpeg umsonst laufen zu lassen. Gilt genauso
        // für "wichtige" langsame Re-Encodes (User-Anfrage 2026-08-24: die sollen IMMER versucht
        // werden) — das hier ist kein Policy-Skip, sondern eine harte OS-Grenze, gegen die auch
        // Priorität nicht ankommt.
        Self.enforceCacheSizeCap()
        if let available = Self.availableDiskBytes(), available < Self.minFreeBytes {
            throw TranscodeError.notEnoughDiskSpace(availableGB: Double(available) / 1_073_741_824)
        }

        // Real failure hit 2026-08-19: "Error writing trailer: No such file or directory" —
        // `outDir` is only created once (lazily, at class init), so if anything removes it
        // mid-run (a Mac cleaner app pruning what looks like an orphaned cache folder is the
        // prime suspect here — one was seen installed with Full Disk Access), a long-running
        // ffmpeg process has nowhere left to write its output when it finally tries to close
        // the file. Re-create it right before every attempt instead of trusting it stays put.
        try? FileManager.default.createDirectory(at: Self.outDir, withIntermediateDirectories: true)

        let tmp = Self.outDir.appendingPathComponent("\(cacheKey).tmp.mp4")
        try? FileManager.default.removeItem(at: tmp)
        defer { progress[cacheKey] = nil }
        progress[cacheKey] = 0

        // `AVURLAsset.load(.duration)` frequently fails/returns 0 on MKV sources — AVFoundation
        // can't reliably read MKV metadata at all (the same limitation this whole feature
        // works around for playback). Real bug hit 2026-08-19: progress bar never moved for
        // ANY file, success or failure, because the AVFoundation-based duration probe silently
        // came back 0 essentially always for these MKV sources. `ffprobe` reads MKV duration
        // metadata reliably — use that instead.
        let totalSec = await Self.probeDuration(sourceURL: sourceURL) ?? 0

        // Real bug hit 2026-08-19: even a source with audio that's ALREADY `aac`/stereo
        // (nothing to fix at all) was force-re-encoded and threw "error code: -22 (Invalid
        // argument)" on `af#0:1` — confirmed via `ffprobe` against the actual failing file:
        // `codec_name=aac, channels=2, channel_layout=stereo`. Forcing `-ac`/`-channel_layout`
        // through ffmpeg's channel-layout-conversion machinery even on a no-op case (same
        // layout in and out) can hit exactly this class of EINVAL on some ffmpeg builds — the
        // conversion machinery doesn't short-circuit just because input == output shape. Fix:
        // only touch a stream's audio at all if it's actually something AVFoundation can't
        // play (i.e. not already `aac`); otherwise `-c:a copy`, no filter graph involved at all.
        //
        // Real bug hit 2026-08-27 (User: "ist die deutsche Tonspur im Download noch drin?"):
        // the OLD single-stream logic here (`probeAudioCodec` + `-map 0:a:0`) only ever kept
        // the FIRST audio stream — a typical dual-language rip (German + English) silently
        // lost its second track on every download/local-library conversion, unrecoverable
        // without re-downloading. Probe and keep EVERY audio stream, transcoding only the ones
        // that actually need it — `AVPlayer` exposes every kept stream via
        // `AVMediaSelectionGroup(.audible)`, which the new track-switcher in
        // `LocalPlayerView`/offline `PlayerView` reads from.
        let audioStreams = await Self.probeAudioStreams(sourceURL: sourceURL)
        var audioMapArgs: [String] = []
        var audioCodecArgs: [String] = []
        if audioStreams.isEmpty {
            // Probe fand keinen Stream (Fehlerfall) — altes Verhalten als Fallback: lieber
            // irgendeine Tonspur als gar keine.
            audioMapArgs = ["-map", "0:a:0?"]
            audioCodecArgs = ["-c:a:0", "aac", "-ac", "2", "-channel_layout", "stereo", "-b:a", "192k"]
        } else {
            for (outIdx, stream) in audioStreams.enumerated() {
                audioMapArgs.append(contentsOf: ["-map", "0:\(stream.index)"])
                if stream.codec == "aac" {
                    audioCodecArgs.append(contentsOf: ["-c:a:\(outIdx)", "copy"])
                } else {
                    audioCodecArgs.append(contentsOf: ["-c:a:\(outIdx)", "aac", "-ac", "2", "-channel_layout", "stereo", "-b:a", "192k"])
                }
                if let lang = stream.language {
                    audioCodecArgs.append(contentsOf: ["-metadata:s:a:\(outIdx)", "language=\(lang)"])
                }
            }
        }

        // `-c:v copy` preserves the bitstream exactly and is what keeps conversion fast
        // (seconds, not the movie's runtime) — but only works for codecs AVFoundation can
        // actually decode. For HEVC sources ffmpeg tags the stream `hev1` in the MP4
        // container — valid per spec but AVFoundation/QuickTime only reliably decodes HEVC
        // tagged `hvc1`; `-tag:v hvc1` only rewrites the container fourCC, zero re-encode
        // cost. Real bug hit 2026-08-19: a downloaded AV1 source (`codec_name=av01`) played
        // audio fine but showed NO video at all — AVFoundation can't decode AV1 on most Macs
        // regardless of tag/container, so blindly stream-copying it (as if it were just a
        // tagging problem like HEVC) produced a file that LOOKS converted but is still
        // unplayable video. Sources with genuinely undecodable codecs need an actual
        // re-encode to h264, not just a re-tag — using the hardware VideoToolbox encoder
        // (`h264_videotoolbox`) keeps that reasonably fast despite being a real transcode.
        let videoCodec = await Self.probeVideoCodec(sourceURL: sourceURL)
        let videoArgs: [String]
        switch videoCodec {
        case "hevc":
            videoArgs = ["-c:v", "copy", "-tag:v", "hvc1"]
        case "h264", "prores":
            videoArgs = ["-c:v", "copy"]
        default:
            // av1, vp9, mpeg2video, vc1, … — not decodable by AVFoundation at all.
            videoArgs = ["-c:v", "h264_videotoolbox", "-b:v", "6M", "-tag:v", "avc1"]
        }
        // User-Report 2026-08-26: "warum habe ich bei vielen langsamen Dateien wieder eine
        // Formatanpassung, die lief doch schon eine ganze Nacht durch — wird das nicht
        // gespeichert, wenn der externe Speicher entfernt wird?" — Konvertierung selbst WAR
        // gespeichert (Cache liegt auf der internen Mac-Platte, unabhängig von der externen
        // Platte), das Problem war `enforceCacheSizeCap()`s Eviction: bei vielen echten
        // Re-Encodes (oft mehrere GB pro Datei) füllte sich der 80-GB-Cache noch in
        // derselben Nacht, und die reine Alt-zuerst-Eviction warf dabei genau die teuren,
        // langsam erzeugten Re-Encodes wieder raus, um Platz für spätere zu schaffen — das
        // Gegenteil von der User-Priorität "langsame IMMER behalten". Fix: Klassifizierung
        // hier persistent festhalten, damit `enforceCacheSizeCap()` bei der Eviction
        // schnelle (jederzeit in Sekunden neu erzeugbare) Einträge zuerst opfert.
        Self.recordClassification(cacheKey: cacheKey, isSlow: !["hevc", "h264", "prores"].contains(videoCodec ?? ""))

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            trackActiveProcess(process)
            process.executableURL = URL(fileURLWithPath: ffmpegPath)
            // -c:v copy: no re-encode, just repackage — this is what keeps it fast (seconds,
            // not the movie's runtime). Audio gets transcoded per-stream only where actually
            // needed (DTS/AC3 → AAC); +faststart moves the moov atom to the front so AVPlayer
            // can start playback before the whole file is fully written/read.
            // `-map 0:v:0` + one `-map 0:<idx>` per audio stream (built above from
            // `probeAudioStreams`): explicitly select the first video stream plus EVERY audio
            // stream, each with its own `-c:a:N`/`-metadata:s:a:N`. Real bug hit 2026-08-19: an
            // earlier version of this restricted to a single hardcoded `-map 0:a:0` — fixed
            // that stream-selection footgun by naming every audio stream explicitly here too,
            // instead of falling back to ffmpeg's ambiguous automatic selection.
            process.arguments = ["-y", "-i", sourceURL.path, "-map", "0:v:0"] + audioMapArgs + videoArgs + audioCodecArgs + ["-movflags", "+faststart", tmp.path]
            let errPipe = Pipe()
            process.standardError = errPipe
            let stderrBox = StderrBox()

            errPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
                stderrBox.append(chunk)
                if totalSec > 0, let sec = Self.parseLastTime(chunk) {
                    Task { @MainActor in self.progress[cacheKey] = min(sec / totalSec, 0.99) }
                }
            }
            process.terminationHandler = { [weak self] proc in
                errPipe.fileHandleForReading.readabilityHandler = nil
                Task { @MainActor in self?.untrackActiveProcess(proc) }
                if proc.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    let tail = stderrBox.tail(400)
                    continuation.resume(throwing: TranscodeError.processFailed(tail))
                }
            }
            do {
                try process.run()
            } catch {
                errPipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(throwing: error)
            }
        }

        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        // Real incident 2026-08-20: dieser Cache wuchs komplett unbegrenzt (177 GB, keine
        // einzige Eviction jemals) und füllte die Systemplatte bis auf 0 Bytes frei — nicht
        // nur die Formatanpassung schlug danach fehl ("No space left on device"), sondern
        // sogar unabhängige Prozesse. Ab jetzt nach jeder erfolgreichen Konvertierung geprüft.
        Self.enforceCacheSizeCap()
        return dest
    }

    /// Deckelt den GESAMTEN Cache-Ordner (lokale Items + Downloads gemeinsam, siehe
    /// `convertedURL(cacheKey:)`-Kommentar) auf `maxCacheBytes` — älteste zuletzt GENUTZTE
    /// Datei fliegt zuerst raus (LRU über `contentModificationDate`, angestoßen sowohl bei
    /// jedem Cache-Hit oben als auch nach jeder Neu-Konvertierung), bis wieder unter dem Limit.
    /// Kein Datenverlust: eine entfernte Datei wird beim nächsten Abspielversuch einfach neu
    /// erzeugt (`remux`/`remuxDownload` prüfen ohnehin immer erst `FileManager.fileExists`).
    private static let maxCacheBytes: Int64 = 80 * 1024 * 1024 * 1024

    /// Real bug hit 2026-08-24: der 80-GB-Nominal-Cap allein reicht nicht — der tatsächlich
    /// freie Platz auf der Systemplatte (unabhängig von unserer eigenen Cache-Größe: andere
    /// Apps, Time-Machine-Snapshots, sonstige Nutzerdaten) kann viel knapper sein. `ffmpeg`
    /// lief mitten in einer 18-Minuten-Konvertierung in "No space left on device", LANGE bevor
    /// der Cache-Ordner selbst je 80 GB erreichte. Reserve, die IMMER frei bleiben muss, egal
    /// wie groß `maxCacheBytes` nominell ist.
    private static let minFreeBytes: Int64 = 15 * 1024 * 1024 * 1024

    /// `.volumeAvailableCapacityKey` (NICHT `...ForImportantUsage`) ist bewusst die
    /// KONSERVATIVE der beiden macOS-Kennzahlen. Real verifiziert 2026-08-24: auf diesem Mac
    /// meldete `...ForImportantUsage` 101 GB (das, was Finder/"Über diesen Mac" zeigt — zählt
    /// verwerfbaren Speicher wie lokale Time-Machine-Snapshots optimistisch mit), während die
    /// einfache Variante nur 35 GB zeigte (das, was `df` im Terminal zeigt — nur der Platz, der
    /// GERADE WIRKLICH frei ist). Der ENOSPC-Fehler oben ist genau dieser Unterschied: macOS
    /// räumt einen lokalen Snapshot nicht immer schnell genug weg, wenn ffmpeg am Stück viele
    /// GB in kurzer Zeit schreibt — die optimistische Zahl hätte den Space-Check also gar nicht
    /// ausgelöst und wäre wieder in dieselbe Falle gelaufen.
    private static func availableDiskBytes() -> Int64? {
        (try? outDir.resourceValues(forKeys: [.volumeAvailableCapacityKey]))?
            .volumeAvailableCapacity.map(Int64.init)
    }

    /// Deckelt den Cache auf `maxCacheBytes` UND stellt zusätzlich sicher, dass danach noch
    /// mindestens `minFreeBytes` auf der Systemplatte frei sind — je nachdem, welche der beiden
    /// Grenzen enger ist. Ohne die zweite Bedingung wäre der Cache theoretisch "im Limit",
    /// obwohl die Platte real schon voll ist (siehe `minFreeBytes`-Kommentar).
    /// Persistente Klassifizierung "brauchte einen echten Re-Encode (langsam/teuer)?" pro
    /// Cache-Key — überlebt App-Neustarts UND funktioniert auch, wenn die Quell-Datei/der
    /// externe Datenträger beim Eviction-Lauf gerade nicht erreichbar ist (Klassifizierung
    /// wird einmalig BEIM Konvertieren festgehalten, nicht bei jeder Eviction neu geprobt).
    private static let classificationURL: URL = outDir.appendingPathComponent(".slow-classification.json")

    private static func loadClassification() -> [String: Bool] {
        guard let data = try? Data(contentsOf: classificationURL),
              let dict = try? JSONDecoder().decode([String: Bool].self, from: data) else { return [:] }
        return dict
    }

    private static func recordClassification(cacheKey: String, isSlow: Bool) {
        var dict = loadClassification()
        dict[cacheKey] = isSlow
        if let data = try? JSONEncoder().encode(dict) {
            try? data.write(to: classificationURL)
        }
    }

    /// User-Report 2026-08-26: "warum habe ich bei vielen langsamen Dateien wieder eine
    /// Formatanpassung, die lief doch schon eine ganze Nacht durch" — reine Alt-zuerst-
    /// Eviction warf bei vollem Cache genau die teuren, langsam erzeugten Re-Encodes wieder
    /// raus, um Platz für neue zu schaffen. Jetzt zweistufig: erst ALLE "schnellen"
    /// (jederzeit in Sekunden neu erzeugbaren) Einträge opfern, älteste zuerst — nur wenn
    /// danach immer noch nicht genug frei ist (Cache besteht praktisch nur noch aus
    /// geschützten langsamen Re-Encodes, oder die Platte ist aus anderen Gründen knapp),
    /// werden auch langsame Einträge angetastet, ebenfalls älteste zuerst. Einträge ohne
    /// Klassifizierung (vor diesem Feature konvertiert) zählen als "schnell" — sicherer
    /// Default, der den Cache nicht permanent an unklassifizierten Alt-Einträgen festbeißt.
    private static func enforceCacheSizeCap() {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(at: outDir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else { return }
        let classification = loadClassification()
        var entries: [(url: URL, size: Int64, date: Date, isSlow: Bool)] = urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  let size = values.fileSize else { return nil }
            let cacheKey = url.deletingPathExtension().lastPathComponent
            let isSlow = classification[cacheKey] ?? false
            return (url, Int64(size), values.contentModificationDate ?? .distantPast, isSlow)
        }
        var total = entries.reduce(Int64(0)) { $0 + $1.size }
        // Wie viel MUSS mindestens raus, damit `minFreeBytes` danach wieder frei sind? (0, wenn
        // schon genug frei ist.) `availableDiskBytes()` bezieht sich auf JETZT, VOR der
        // Eviction — jede entfernte Cache-Datei gibt real Plattenplatz frei, das ist also eine
        // 1:1-Vorhersage, keine Schätzung.
        let mustFreeForDiskSpace = availableDiskBytes().map { max(0, minFreeBytes - $0) } ?? 0
        let target = max(Int64(0), min(maxCacheBytes, total - mustFreeForDiskSpace))
        guard total > target else { return }
        // Schnelle (bzw. unklassifizierte) zuerst, langsame zuletzt — innerhalb jeder Gruppe
        // älteste zuerst (bestehendes LRU-Verhalten).
        entries.sort { lhs, rhs in
            if lhs.isSlow != rhs.isSlow { return !lhs.isSlow }
            return lhs.date < rhs.date
        }
        var removedKeys: [String] = []
        for entry in entries {
            guard total > target else { break }
            try? fm.removeItem(at: entry.url)
            total -= entry.size
            removedKeys.append(entry.url.deletingPathExtension().lastPathComponent)
        }
        if !removedKeys.isEmpty {
            var dict = classification
            for key in removedKeys { dict[key] = nil }
            if let data = try? JSONEncoder().encode(dict) {
                try? data.write(to: classificationURL)
            }
        }
    }

    /// Löscht (falls vorhanden) den gecachten Konvertierungs-Output für ein einzelnes lokales
    /// Item ODER einen Download — aufgerufen aus `LocalLibraryManager.deleteItem`/
    /// `DownloadManager.deleteDownload`. Real Lücke 2026-08-20: bisher verwaiste dieser
    /// Cache-Eintrag beim Löschen des Originals dauerhaft (sichtbarer Beitrag zu den 177 GB) —
    /// die Original-Datei war weg, ihre oft mehrere GB große Konvertierungs-Kopie blieb ewig
    /// liegen, weil nichts sie je referenzierte und der Größen-Cap allein zu langsam abbaut.
    public func deleteCachedConversion(itemUUID: UUID) {
        try? FileManager.default.removeItem(at: convertedURL(cacheKey: "local-\(itemUUID.uuidString)"))
    }

    /// ffmpeg stderr progress lines look like "...time=00:12:34.56 bitrate=...". Takes the
    /// LAST match in a chunk (readabilityHandler can deliver multiple lines at once).
    /// `nonisolated` — called from the Pipe's `readabilityHandler`, which runs on an
    /// arbitrary background queue, not the MainActor `LocalTranscodeService` is bound to.
    private nonisolated static func parseLastTime(_ text: String) -> Double? {
        var lastMatch: Double?
        for line in text.components(separatedBy: "\r") + text.components(separatedBy: "\n") {
            guard let range = line.range(of: "time=") else { continue }
            let rest = line[range.upperBound...]
            let token = rest.prefix(while: { $0 != " " })
            let parts = token.split(separator: ":")
            guard parts.count == 3, let h = Double(parts[0]), let m = Double(parts[1]), let s = Double(parts[2]) else { continue }
            lastMatch = h * 3600 + m * 60 + s
        }
        return lastMatch
    }

    /// Extracts ONE preview frame directly from the source with `ffmpeg` — no container remux,
    /// no re-encode of the whole file, nothing written to the shared transcode cache. This is
    /// the replacement for pre-converting "fast" files in the background (see
    /// `enqueueCompatibilityCheck`): `AVAssetImageGenerator` can't demux the same containers
    /// AVFoundation can't play (MKV etc., independent of the codec inside), but `ffmpeg`
    /// decodes far more formats, so it can pull a frame straight out of the original file.
    /// Called from `LocalLibraryManager.generateThumbnailIfNeeded` as the fallback once the
    /// AVFoundation attempt fails. The resulting JPEG is written straight to `destJPEG` — the
    /// caller persists the path (`thumbsDir`, never evicted, unlike the transcode cache).
    public func extractThumbnailViaFFmpeg(sourceURL: URL, destJPEG: URL) async -> Bool {
        guard let ffmpegPath = Self.findFFmpeg() else { return false }
        let totalSec = await Self.probeDuration(sourceURL: sourceURL) ?? 0
        let offset = totalSec > 30 ? totalSec * 0.1 : (totalSec > 5 ? 2 : 0)
        return await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ffmpegPath)
            process.arguments = [
                "-y", "-ss", String(offset), "-i", sourceURL.path,
                "-frames:v", "1", "-q:v", "3", destJPEG.path,
            ]
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            do {
                try process.run()
            } catch {
                return false
            }
            process.waitUntilExit()
            return process.terminationStatus == 0 && FileManager.default.fileExists(atPath: destJPEG.path)
        }.value
    }

    private static func findFFmpeg() -> String? {
        for path in ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"] {
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    private static func findFFprobe() -> String? {
        for path in ["/opt/homebrew/bin/ffprobe", "/usr/local/bin/ffprobe", "/usr/bin/ffprobe"] {
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    /// Codec name of the first video stream (e.g. "hevc", "h264"), or nil if unavailable.
    private static func probeVideoCodec(sourceURL: URL) async -> String? {
        guard let ffprobePath = findFFprobe() else { return nil }
        return await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ffprobePath)
            process.arguments = [
                "-v", "error", "-select_streams", "v:0",
                "-show_entries", "stream=codec_name", "-of", "csv=p=0",
                sourceURL.path,
            ]
            let pipe = Pipe()
            process.standardOutput = pipe
            do {
                try process.run()
            } catch {
                return nil
            }
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }.value
    }

    /// One audio stream as reported by `ffprobe` — absolute container stream `index` (needed for
    /// `-map 0:<index>`, NOT the audio-only `a:N` specifier), `codec` name, and BCP-47-ish
    /// `language` tag if the source has one (used both to decide copy-vs-transcode per stream
    /// in `performRemux` and to label tracks in the audio-track switcher UI).
    struct AudioStreamInfo {
        let index: Int
        let codec: String
        let language: String?
    }

    /// Every audio stream in the source, in container order — replaces the old single-stream
    /// `probeAudioCodec` (see `performRemux`'s 2026-08-27 comment for why keeping only the
    /// first stream was a real bug for dual-language sources).
    static func probeAudioStreams(sourceURL: URL) async -> [AudioStreamInfo] {
        guard let ffprobePath = findFFprobe() else { return [] }
        return await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ffprobePath)
            process.arguments = [
                "-v", "error", "-select_streams", "a",
                "-show_entries", "stream=index,codec_name:stream_tags=language",
                "-of", "json", sourceURL.path,
            ]
            let pipe = Pipe()
            process.standardOutput = pipe
            do {
                try process.run()
            } catch {
                return []
            }
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let streams = json["streams"] as? [[String: Any]] else { return [] }
            return streams.compactMap { entry -> AudioStreamInfo? in
                guard let index = entry["index"] as? Int, let codec = entry["codec_name"] as? String else { return nil }
                let tags = entry["tags"] as? [String: String]
                return AudioStreamInfo(index: index, codec: codec, language: tags?["language"])
            }
        }.value
    }

    /// Container duration in seconds via `ffprobe` — used instead of
    /// `AVURLAsset.load(.duration)` for the progress bar's total, since AVFoundation
    /// frequently can't read duration metadata from MKV sources at all (real bug hit
    /// 2026-08-19: progress bar never advanced for any file, success or failure).
    private static func probeDuration(sourceURL: URL) async -> Double? {
        guard let ffprobePath = findFFprobe() else { return nil }
        return await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ffprobePath)
            process.arguments = [
                "-v", "error", "-show_entries", "format=duration",
                "-of", "csv=p=0", sourceURL.path,
            ]
            let pipe = Pipe()
            process.standardOutput = pipe
            do {
                try process.run()
            } catch {
                return nil
            }
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
            return Double(text)
        }.value
    }
}
#endif
