import Foundation
#if canImport(Combine)
import Combine
#endif

public struct DownloadRecord: Codable, Identifiable, Equatable {
    public let itemId: Int64
    public let title: String
    /// `var`, nicht `let` — `convertDownloadInPlace` (LocalTranscodeService) benennt die
    /// Datei beim In-Place-Konvertieren ggf. um (z.B. `.mkv` → `.mp4`), der Record muss dem
    /// folgen können.
    public var fileName: String
    /// Absolute path at the time the download finished — kept even if the user later
    /// changes the downloads directory, so older files stay findable.
    public var filePath: String
    public var bytesExpected: Int64
    public var bytesWritten: Int64
    public var state: State
    public var errorMessage: String?
    /// JSON snapshot of the full `Item` at download time (poster/metadata/etc.) — lets the
    /// Downloads tab show real tiles (poster, title, episode code, …) and open the normal
    /// `ItemDetailView`/`PlayerView` fully offline, without a `client.fetchItem` round-trip
    /// that would just fail with no network. Optional so existing persisted downloads from
    /// before this field existed decode fine (nil → falls back to a plain list row).
    public var itemData: Data?
    /// Server account (username) that started this download — real bug hit 2026-08-19: same
    /// class of issue as `LocalLibrary.ownerUsername`, downloads had no per-user isolation at
    /// all when everyone on the Mac shares the default downloads folder. Optional only so
    /// downloads persisted before this field existed still decode.
    public var ownerUsername: String?
    /// User-Anfrage 2026-08-25: "wenn er die Internetverbindung verliert, soll er das, was
    /// bereits runtergeladen ist, speichern und dann da weitermachen, wo er abgebrochen hat —
    /// jetzt beginnt er immer von vorne." `URLSession`s Standard-Mechanismus dafür: bei einem
    /// Verbindungsabbruch liefert der `NSError` (falls der Server Range-Requests unterstützt,
    /// was Goldfishs Download-Endpoint tut) `resumeData` — ein Foundation-verwaltetes Paket,
    /// das den bereits heruntergeladenen Teil referenziert. Persistiert im Record (nicht nur
    /// im Speicher), damit ein Resume auch nach einem App-Neustart noch funktioniert, nicht
    /// nur solange der Task-Objekt-Verweis im Speicher lebt. Wird bei erfolgreichem Abschluss
    /// UND beim expliziten Abbrechen (`cancelDownload`, der den ganzen Record löscht) wieder
    /// verworfen — nur ein durch NETZWERKFEHLER unterbrochener Download soll fortsetzbar
    /// bleiben.
    public var resumeData: Data?

    public enum State: String, Codable {
        case queued, downloading, done, failed
    }

    public var id: Int64 { itemId }

    public var progress: Double {
        guard bytesExpected > 0 else { return 0 }
        return Double(bytesWritten) / Double(bytesExpected)
    }

    public var cachedItem: Item? {
        guard let itemData else { return nil }
        return try? JSONDecoder().decode(Item.self, from: itemData)
    }
}

@MainActor
public final class DownloadManager: NSObject, ObservableObject {
    public static let shared = DownloadManager()

    /// FILTERED to the currently logged-in user — the only dict the UI ever reads.
    /// `allRecordsOnDisk` is the real, cross-user persisted truth (everyone on this Mac
    /// typically shares the same default downloads folder, hence the same index file).
    @Published public private(set) var records: [Int64: DownloadRecord] = [:]
    private var allRecordsOnDisk: [Int64: DownloadRecord] = [:]
    @Published public private(set) var downloadsDir: URL
    /// True once a folder the user picked is in use (vs. the app-private default).
    @Published public private(set) var usesCustomDirectory = false
    /// Bytes/Sekunde, geglättet (EMA) aus den `didWriteData`-Deltas — User-Anfrage
    /// 2026-08-27: "kann man die Downloadgeschwindigkeit neben der Prozentanzeige
    /// anzeigen". Rein flüchtig (kein Persistieren nötig, ergibt über App-Neustarts
    /// hinweg ohnehin keinen Sinn) — Eintrag verschwindet, sobald der Download endet
    /// (fertig, fehlgeschlagen, abgebrochen), damit die UI nicht eine eingefrorene
    /// letzte Geschwindigkeit weiter anzeigt.
    @Published public private(set) var downloadSpeeds: [Int64: Double] = [:]
    /// Letzter Sample-Zeitpunkt + -Byte-Stand pro Item, um die Rate zwischen zwei
    /// `didWriteData`-Aufrufen zu berechnen. Gedrosselt auf min. 0.3s Abstand, sonst
    /// würde bei sehr häufigen kleinen Callbacks (schnelles LAN) die Rate zu stark
    /// zwischen einzelnen Chunks springen.
    private var lastSpeedSample: [Int64: (time: Date, bytes: Int64)] = [:]

    private var session: URLSession!
    private var tasks: [Int64: URLSessionDownloadTask] = [:]
    private var indexURL: URL { downloadsDir.appendingPathComponent(".goldfish-index.json") }
    private var downloadsDirIsSecurityScoped = false

    private static let bookmarkKey = "goldfish.downloadDirBookmark"

    private override init() {
        if let resolved = Self.resolveBookmarkedDirectory() {
            self.downloadsDir = resolved.url
            self.downloadsDirIsSecurityScoped = resolved.isSecurityScoped
            self.usesCustomDirectory = true
        } else {
            self.downloadsDir = Self.defaultDirectory()
            self.usesCustomDirectory = false
        }
        super.init()

        try? FileManager.default.createDirectory(at: downloadsDir, withIntermediateDirectories: true)

        let config = URLSessionConfiguration.default
        config.httpCookieStorage = .shared
        // `?compat=1`: der Server prüft die Datei und remuxt/transkodiert sie bei
        // Bedarf per ffmpeg, BEVOR das erste Byte fließt (siehe Server-Package
        // `internal/download`). Bei großen Dateien dauert dieses Vorbereiten
        // länger als die 60-Sekunden-Default von `timeoutIntervalForRequest`
        // ("wie lange auf weitere Daten warten") — der Task lief dann in einen
        // Timeout und wurde per `resumeData` neu gestartet, was serverseitig
        // eine NEUE Konvertierung auslöste: der Download blieb endlos bei 99 %.
        // Großzügig anheben. Der Server führt die Konvertierung inzwischen auch
        // dann zu Ende, wenn wir hier abbrechen (wärmt den Cache), aber mit dem
        // höheren Timeout kommt der Normalfall in einem Rutsch durch.
        config.timeoutIntervalForRequest = 600
        self.session = URLSession(configuration: config, delegate: self, delegateQueue: nil)

        loadIndex()

        // A stored bookmark can resolve without throwing (`resolveBookmarkedDirectory`
        // above) yet still not be genuinely writable — e.g. after switching this build
        // from ad-hoc to a real Team signature, real bug hit 2026-08-19: downloads failed
        // deep into `didFinishDownloadingTo` with "couldn't be moved… folder doesn't
        // exist" instead of failing fast and falling back. Validate for real right at
        // launch instead of waiting for the first download to hit it mid-transfer.
        ensureWritableDownloadsDir()

        // User-Anfrage 2026-08-27 ("wie löst Jellyfin das eigentlich"): Downloads werden
        // jetzt VOM SERVER schon kompatibel ausgeliefert (`?compat=1` an `/api/download`,
        // siehe `GoldfishClient.downloadFileURL` + Server-Package `internal/download`) —
        // keine client-seitige Nachbearbeitung per lokalem ffmpeg mehr nötig. Die frühere
        // `LocalTranscodeService`-Anbindung hier (`onDownloadConverted`, `rescanDownloads`,
        // In-Place-Konvertierung) ist komplett entfernt; `LocalTranscodeService` bleibt nur
        // noch für lokale/externe Bibliotheken zuständig, die keinen Server zum Fragen haben.
    }

    private static func defaultDirectory() -> URL {
        let fm = FileManager.default
        let support = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fm.temporaryDirectory
        return support.appendingPathComponent("GoldfishDownloads", isDirectory: true)
    }

    // Plain (non-security-scoped) bookmarks on both platforms — App Sandbox was removed
    // from the Mac target 2026-08-19 (see `GoldfishMac.entitlements`), so there's no
    // sandbox extension for `.withSecurityScope` to persist against. Gating on
    // `startAccessingSecurityScopedResource()`'s return value used to make a custom
    // Downloads folder silently fall back to nil (default dir) — was very likely the
    // real cause of a "couldn't be moved… folder doesn't exist" download failure that
    // showed up right after switching this build to a real Team signature.
    private static func resolveBookmarkedDirectory() -> (url: URL, isSecurityScoped: Bool)? {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale) else { return nil }
        return (url, false)
    }

    /// Call after the user picks a folder via NSOpenPanel (macOS) or a UIDocumentPicker
    /// folder picker (iOS). The URL must already be accessible (the picker grants that).
    public func setDownloadsDirectory(_ url: URL) {
        guard let bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) else { return }

        UserDefaults.standard.set(bookmark, forKey: Self.bookmarkKey)
        downloadsDir = url
        downloadsDirIsSecurityScoped = false
        usesCustomDirectory = true
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        loadIndex()
    }

    public func resetToDefaultDirectory() {
        if downloadsDirIsSecurityScoped { downloadsDir.stopAccessingSecurityScopedResource() }
        UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
        downloadsDir = Self.defaultDirectory()
        downloadsDirIsSecurityScoped = false
        usesCustomDirectory = false
        try? FileManager.default.createDirectory(at: downloadsDir, withIntermediateDirectories: true)
        loadIndex()
    }

    private func loadIndex() {
        allRecordsOnDisk.removeAll()
        if let data = try? Data(contentsOf: indexURL),
           let list = try? JSONDecoder().decode([DownloadRecord].self, from: data) {
            for rec in list { allRecordsOnDisk[rec.itemId] = rec }
        }
        refreshVisibleRecords()
    }

    /// Call when the logged-in account changes (login/logout/switch) — recomputes the
    /// publicly-visible `records` dict for the new user. `RootView` calls this on every
    /// `client.currentUsername` change.
    public func userDidChange() {
        refreshVisibleRecords()
    }

    private func currentUsername() -> String? { GoldfishClient.shared.currentUsername }

    // User-Anfrage 2026-08-19: "bei offline Dateien merkt er sich nicht, wo man zuletzt
    // war, er fängt immer von vorne an" — PlayerView's Offline-Zweig (lokal heruntergeladene
    // Datei) hat nie eine Resume-Position gelesen ODER geschrieben, nur die Online-Variante
    // rief `client.getResume`/`setResume` auf (die im Offline-Fall stillschweigend fehlschlagen
    // — `try?`). Eigener, rein lokaler Resume-Speicher, gleiches Muster wie
    // `LocalLibraryManager.setResume`/`resumePosSec` für Bibliotheks-Items. Per-User gekeyt wie
    // die Records selbst.
    private static let resumeKey = "goldfish.downloadResumePositions"

    private func resumeStoreKey(itemId: Int64) -> String {
        "\(currentUsername() ?? "_")|\(itemId)"
    }

    public func localResumeSeconds(itemId: Int64) -> Double {
        let all = UserDefaults.standard.dictionary(forKey: Self.resumeKey) as? [String: Double] ?? [:]
        return all[resumeStoreKey(itemId: itemId)] ?? 0
    }

    public func setLocalResume(itemId: Int64, seconds: Double) {
        var all = UserDefaults.standard.dictionary(forKey: Self.resumeKey) as? [String: Double] ?? [:]
        let key = resumeStoreKey(itemId: itemId)
        if seconds > 5 {
            all[key] = seconds
        } else {
            all.removeValue(forKey: key)
        }
        UserDefaults.standard.set(all, forKey: Self.resumeKey)
    }

    // User-Anfrage 2026-08-20: "Wenn ich eine Offlinefolge schaue, dann wird sie am Ende
    // nicht als gesehen markiert" — `PlayerView.markWatchedNow`/`maybeMarkWatchedOrSaveResume`
    // riefen zwar schon `client.setWatched` auf, aber nur `try?`-abgesichert: offline schlägt
    // der Call stillschweigend fehl und es gab bisher KEINEN Retry, sobald wieder Netz da ist
    // — der Server-Zustand blieb also für immer "ungesehen", auch wenn `downloads.
    // updateCachedWatched` die lokale Downloads-Kachel schon korrekt aktualisierte. Persistenter
    // Pending-Set, cross-user (Gesehen-Status ist server-seitig sowieso pro angemeldetem
    // Account, kein zusätzlicher Owner-Filter hier nötig) — `RootView` ruft `syncPendingWatched`
    // bei jedem `client.currentUsername`-Wechsel auf (= zuverlässiger Beleg für "Netz ist da").
    private static let pendingWatchedSyncKey = "goldfish.pendingWatchedSync"

    public func queuePendingWatchedSync(itemId: Int64) {
        var all = Set((UserDefaults.standard.array(forKey: Self.pendingWatchedSyncKey) as? [Int64]) ?? [])
        all.insert(itemId)
        UserDefaults.standard.set(Array(all), forKey: Self.pendingWatchedSyncKey)
    }

    public func clearPendingWatchedSync(itemId: Int64) {
        var all = Set((UserDefaults.standard.array(forKey: Self.pendingWatchedSyncKey) as? [Int64]) ?? [])
        all.remove(itemId)
        UserDefaults.standard.set(Array(all), forKey: Self.pendingWatchedSyncKey)
    }

    /// Vom Player NICHT direkt aufgerufen (der kennt nur EIN Item) — `RootView` ruft das
    /// stattdessen global auf, sobald eine Session bestätigt wurde, damit auch Offline-
    /// Markierungen aus einer VORHERIGEN App-Sitzung (App zwischenzeitlich beendet, nie wieder
    /// online gegangen) nachgeholt werden, nicht nur die der laufenden.
    public func syncPendingWatched(client: GoldfishClient) async {
        let pending = Set((UserDefaults.standard.array(forKey: Self.pendingWatchedSyncKey) as? [Int64]) ?? [])
        guard !pending.isEmpty else { return }
        for itemId in pending {
            if (try? await client.setWatched(itemId: itemId, watched: true)) != nil {
                clearPendingWatchedSync(itemId: itemId)
            }
        }
    }

    /// Recomputes `records` (the only dict the UI ever sees) from `allRecordsOnDisk`, scoped
    /// to the current user. Real bug hit 2026-08-19 (same fix as `LocalLibraryManager`'s
    /// `refreshVisibleLibraries`): auto-attributing an unowned legacy record to whoever
    /// happens to be logged in is unsafe — someone logging in just to verify the fix gets
    /// silently made the permanent "owner". An unowned record stays visible to everyone
    /// instead, no auto-claim.
    private func refreshVisibleRecords() {
        guard let user = currentUsername() else {
            records = [:]
            return
        }
        records = allRecordsOnDisk.filter { $0.value.ownerUsername == user || $0.value.ownerUsername == nil }
        cacheAllDownloadPostersIfNeeded()
    }

    /// Persists `allRecordsOnDisk` (ALL users' download records), not the filtered `records`
    /// — saving the filtered view here would silently delete every other account's download
    /// history the next time this user's manager writes the shared index file to disk.
    private func saveIndex() {
        let list = Array(allRecordsOnDisk.values)
        if let data = try? JSONEncoder().encode(list) {
            try? data.write(to: indexURL)
        }
    }

    /// Writes a record into BOTH the persisted `allRecordsOnDisk` and — only if it belongs to
    /// the current user — the publicly-visible `records`. Used by every mutation site instead
    /// of touching `records` directly, so per-user isolation can't be bypassed by a call site
    /// forgetting to mirror the change into the cross-user store.
    private func setRecord(_ rec: DownloadRecord) {
        allRecordsOnDisk[rec.itemId] = rec
        let visible = rec.ownerUsername == currentUsername() || rec.ownerUsername == nil
        records[rec.itemId] = visible ? rec : nil
    }

    private func removeRecord(itemId: Int64) {
        allRecordsOnDisk[itemId] = nil
        records[itemId] = nil
    }

    /// Fills in `itemData` for a download made before that field existed (real gap hit
    /// 2026-08-19: the Downloads tab's new tile grid only shows records that have a cached
    /// `Item` snapshot — everything downloaded before this feature shipped had none, so it
    /// silently fell back to the old plain-list rendering forever, looking like the feature
    /// "did nothing"). Called by `DownloadsView` with a freshly-fetched `Item` once online;
    /// a no-op if the record already has data or no longer exists (e.g. deleted meanwhile).
    public func backfillItemData(itemId: Int64, item: Item) {
        guard var rec = records[itemId], rec.itemData == nil else { return }
        rec.itemData = try? JSONEncoder().encode(item)
        setRecord(rec)
        saveIndex()
    }

    /// Keeps a download's frozen `Item` snapshot in sync with the real watched state — see
    /// `Item.withWatched`'s doc comment for the bug this fixes. Called right after any
    /// successful `client.setWatched` for an item that also happens to be downloaded.
    public func updateCachedWatched(itemId: Int64, watched: Bool) {
        guard var rec = records[itemId], let item = rec.cachedItem else { return }
        rec.itemData = try? JSONEncoder().encode(item.withWatched(watched))
        setRecord(rec)
        saveIndex()
    }

    /// User-Anfrage 2026-08-24: "wenn ich einen Film downloade, und dann feststelle er ist
    /// falsch zugeordnet, und ihn auf dem Server richtig zuordne — kann der Download beim
    /// nächsten Online-Sein korrigiert werden?" — nur die METADATEN (Titel/Poster/Jahr/etc.)
    /// werden aktualisiert, die heruntergeladene Videodatei selbst bleibt unangetastet (ein
    /// Re-Match ändert nie die Datei, nur ihre TMDB-Zuordnung). No-op, wenn sich
    /// `metadataId` nicht geändert hat — verhindert unnötiges Poster-Neuladen bei jedem
    /// Online-Check. Aufgerufen von `DownloadsView` mit einem frisch von
    /// `client.fetchItem` geholten `Item`, gleiches Muster wie `backfillItemData`.
    public func refreshCachedMetadataIfChanged(itemId: Int64, item: Item) {
        guard var rec = records[itemId], rec.cachedItem?.metadataId != item.metadataId else { return }
        rec.itemData = try? JSONEncoder().encode(item)
        setRecord(rec)
        saveIndex()
        // `force: true` — die alte Poster-Datei liegt schon unter demselben `<itemId>.jpg`-
        // Pfad und würde sonst von `cachePosterIfNeeded`s "schon vorhanden"-Guard für immer
        // stehen bleiben, obwohl sie jetzt zum FALSCHEN Film gehört.
        cachePosterIfNeeded(for: item, force: true)
        if let parentId = item.metadata?.parentId {
            cacheShowPosterIfNeeded(parentId: parentId)
        }
    }

    public func localFileURL(itemId: Int64) -> URL? {
        guard let rec = records[itemId], rec.state == .done else { return nil }
        let url = URL(fileURLWithPath: rec.filePath)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    public func isDownloaded(itemId: Int64) -> Bool {
        localFileURL(itemId: itemId) != nil
    }

    /// Security-scoped bookmarks for a user-picked folder can silently stop resolving to a
    /// *writable* location — e.g. every ad-hoc-signed dev rebuild can invalidate the grant
    /// even though the bookmark itself still "resolves" (real bug hit 2026-08-17: user's
    /// custom "Movies" folder produced "couldn't be moved ... folder doesn't exist" even
    /// though it existed in Finder). Verify with an actual write, not just bookmark resolution,
    /// and fall back to the always-writable default directory rather than failing outright.
    @discardableResult
    private func ensureWritableDownloadsDir() -> Bool {
        // Re-create the folder before every check, custom AND default — same defensive
        // pattern as `LocalTranscodeService`'s outDir fix: a Mac cleaner app pruning what
        // looks like an orphaned cache/empty folder mid-download is a real, observed cause
        // here (real bug hit 2026-08-19, same suspect app as the transcode-cache deletion:
        // "BuhoCleaner" was seen installed with Full Disk Access). Cheap and harmless even
        // when nothing was actually deleted.
        try? FileManager.default.createDirectory(at: downloadsDir, withIntermediateDirectories: true)
        guard usesCustomDirectory else { return true }
        let probe = downloadsDir.appendingPathComponent(".goldfish-write-check")
        let fm = FileManager.default
        if fm.createFile(atPath: probe.path, contents: Data()) {
            try? fm.removeItem(at: probe)
            return true
        }
        // Lost access to the custom folder — fall back so downloads keep working, and make
        // the loss visible via `usesCustomDirectory` flipping back to false in Settings.
        lastAccessWarning = "Zugriff auf \"\(downloadsDir.lastPathComponent)\" verloren — wechsle zurück auf den Standard-Downloadordner. Bitte Ordner in den Einstellungen erneut auswählen."
        resetToDefaultDirectory()
        return false
    }

    @Published public var lastAccessWarning: String?

    public func startDownload(item: Item, from remoteURL: URL) {
        guard tasks[item.id] == nil else { return }
        ensureWritableDownloadsDir()

        // User-Anfrage 2026-08-25: bei einem "Erneut versuchen" nach Verbindungsverlust nicht
        // stumpf neu von vorne anfangen, wenn Foundation uns `resumeData` für genau diesen
        // Download aufgehoben hat — gleiche Ziel-Datei/gleicher Dateiname wie beim
        // ursprünglichen Versuch (KEINE neue `resolveFilenameConflict`-Runde, die würde sonst
        // fälschlich eine " (2)"-Datei neben der nie geschriebenen Zieldatei planen).
        if var rec = records[item.id], rec.state == .failed, let resumeData = rec.resumeData {
            rec.state = .downloading
            rec.errorMessage = nil
            rec.resumeData = nil
            setRecord(rec)
            saveIndex()
            let task = session.downloadTask(withResumeData: resumeData)
            task.taskDescription = String(item.id)
            tasks[item.id] = task
            task.resume()
            return
        }

        let ext = (item.container?.lowercased()).flatMap { $0.isEmpty ? nil : $0 } ?? (item.path as NSString?)?.pathExtension ?? "mp4"
        // Named after the title shown in Goldfish (User-Anfrage 2026-08-19) instead of the
        // bare numeric item ID — mirrors the server's auto-rename convention (CLAUDE.md
        // "Auto-Rename bestätigter Filme"): "<Title> (<Year>).<ext>", same sanitize rules
        // (strip filesystem-illegal characters, trim trailing dots/spaces), same
        // " (2)"/" (3)" conflict suffix if a file with that name already exists.
        let titlePart = Self.sanitizeFilename(item.displayTitle)
        let base: String
        if let year = item.metadata?.year, year > 0 {
            base = "\(titlePart) (\(year))"
        } else {
            base = titlePart
        }
        let fileName = resolveFilenameConflict(base: base, ext: ext)
        let destination = downloadsDir.appendingPathComponent(fileName)

        setRecord(DownloadRecord(itemId: item.id, title: item.displayTitle, fileName: fileName,
                                  filePath: destination.path,
                                  bytesExpected: item.sizeBytes ?? 0, bytesWritten: 0, state: .downloading, errorMessage: nil,
                                  itemData: try? JSONEncoder().encode(item), ownerUsername: currentUsername()))
        saveIndex()
        cachePosterIfNeeded(for: item)
        // Bugfix 2026-08-20: nur `cacheAllDownloadPostersIfNeeded` (Batch, App-Start/"Erneut
        // prüfen") cachte bisher das SHOW-Poster — ein frischer Einzel-Download einer Episode
        // bekam sein Serien-Cover dadurch erst beim nächsten App-Start, nicht sofort.
        if let parentId = item.metadata?.parentId {
            cacheShowPosterIfNeeded(parentId: parentId)
        }

        let task = session.downloadTask(with: remoteURL)
        task.taskDescription = String(item.id)
        tasks[item.id] = task
        task.resume()
    }

    // User-Anfrage 2026-08-19: "werden die [Poster] gespeichert für die Offlinenutzung oder
    // werden die jedes Mal online gezogen?" — bisher wurden Downloads-Poster IMMER live vom
    // Server geladen (seit dem Cache-Bust-Fix sogar explizit unter Umgehung jedes Caches),
    // waren also offline unsichtbar. Poster werden jetzt einmalig beim Download-Start auf
    // Platte gecacht (gleiche Application-Support-Cache-Konvention wie
    // `LocalTranscodeService.outDir`), unabhängig vom eigentlichen Video-Download.
    private static let posterCacheDir: URL = {
        let fm = FileManager.default
        let support = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fm.temporaryDirectory
        let dir = support.appendingPathComponent("GoldfishDownloadPosters", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// nil solange kein Poster gecacht wurde (z.B. noch nicht heruntergeladen, oder das Item
    /// hat gar kein TMDB-Poster) — Aufrufer fallen dann auf die Live-Server-URL zurück.
    public func cachedPosterURL(itemId: Int64) -> URL? {
        let url = Self.posterCacheDir.appendingPathComponent("\(itemId).jpg")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func cachePosterIfNeeded(for item: Item, force: Bool = false) {
        guard force || cachedPosterURL(itemId: item.id) == nil else { return }
        // User-Anfrage 2026-08-19 (Folgerunde): "klappt das nur für Filme und Serien, nicht
        // für Private Dateien wie YouTube" — Privat-Bibliotheks-Items haben (fast) nie ein
        // TMDB-Poster (`metadataId`/`posterPath` fehlen), der bisherige Code brach dafür
        // komplett ab statt auf das Video-Thumbnail zurückzufallen, das `ItemCard.posterURL`
        // online längst als Fallback nutzt (`client.thumbURL`). Gleicher Fallback hier.
        let sourceURL: URL?
        if let metadataId = item.metadataId, let posterPath = item.metadata?.posterPath, !posterPath.isEmpty {
            sourceURL = GoldfishClient.shared.posterURL(metadataId: metadataId, posterPath: posterPath)
        } else if item.hasThumb == true {
            sourceURL = GoldfishClient.shared.thumbURL(itemId: item.id)
        } else {
            sourceURL = nil
        }
        guard let sourceURL else { return }
        let destination = Self.posterCacheDir.appendingPathComponent("\(item.id).jpg")
        Task {
            guard let (data, _) = try? await URLSession.shared.data(from: sourceURL), !data.isEmpty else { return }
            try? data.write(to: destination)
        }
    }

    /// Show-Poster für Serien-Downloads — Episoden haben fast nie ein eigenes Poster
    /// (`metadata.posterPath` meist leer), die Downloads-Kachel zeigt stattdessen das
    /// SHOW-Poster über `metadata.parentId` (siehe `DownloadGroupCard.posterURL`). Eigener
    /// Cache-Namensraum (`show-<parentId>.jpg`), weil mehrere Episoden-Downloads sich
    /// dasselbe Show-Poster teilen — pro Show nur einmal laden, nicht pro Episode.
    public func cachedShowPosterURL(parentId: Int64) -> URL? {
        let url = Self.posterCacheDir.appendingPathComponent("show-\(parentId).jpg")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func cacheShowPosterIfNeeded(parentId: Int64) {
        guard cachedShowPosterURL(parentId: parentId) == nil else { return }
        guard let posterURL = GoldfishClient.shared.posterURL(metadataId: parentId) else { return }
        let destination = Self.posterCacheDir.appendingPathComponent("show-\(parentId).jpg")
        Task {
            guard let (data, _) = try? await URLSession.shared.data(from: posterURL), !data.isEmpty else { return }
            try? data.write(to: destination)
        }
    }

    // User-Anfrage 2026-08-19 (Folgerunde): "er sich von allen Downloads die Bilder zieht
    // und speichert. Nicht erst, wenn ich es öffne" — `cachePosterIfNeeded` beim Download-
    // Start deckte nur NEUE Downloads ab, nicht die schon vorhandenen (vor diesem Feature
    // heruntergeladen) UND nicht das Show-Poster (das kam bisher nur lazy beim Öffnen der
    // Serien-Übersicht zustande). Läuft proaktiv über ALLE aktuell sichtbaren Downloads —
    // wird von `refreshVisibleRecords()` bei jedem Login/App-Start angestoßen, zusätzlich
    // manuell über den bestehenden "Erneut prüfen"-Button (siehe SettingsView).
    public func cacheAllDownloadPostersIfNeeded() {
        for record in records.values {
            guard record.state == .done, let item = record.cachedItem else { continue }
            cachePosterIfNeeded(for: item)
            if let parentId = item.metadata?.parentId {
                cacheShowPosterIfNeeded(parentId: parentId)
            }
        }
    }

    /// Same sanitize rules as the server's `rename.SanitizeFilename` (CLAUDE.md
    /// "Auto-Rename bestätigter Filme"): strip filesystem-illegal characters and control
    /// characters, trim trailing dots/spaces (Windows/exFAT dislike both).
    private static func sanitizeFilename(_ raw: String) -> String {
        let illegal = CharacterSet(charactersIn: "<>:\"/\\|?*")
        var name = String(raw.unicodeScalars.filter { !illegal.contains($0) && !CharacterSet.controlCharacters.contains($0) })
        while name.hasSuffix(".") || name.hasSuffix(" ") { name.removeLast() }
        return name.isEmpty ? "Download" : name
    }

    /// Appends " (2)", " (3)", … if `base.ext` already exists in the current downloads
    /// directory — same convention as the server's `rename.ResolveConflict`.
    private func resolveFilenameConflict(base: String, ext: String) -> String {
        var candidate = "\(base).\(ext)"
        var n = 2
        while FileManager.default.fileExists(atPath: downloadsDir.appendingPathComponent(candidate).path), n <= 99 {
            candidate = "\(base) (\(n)).\(ext)"
            n += 1
        }
        return candidate
    }

    public func cancelDownload(itemId: Int64) {
        tasks[itemId]?.cancel()
        tasks[itemId] = nil
        clearSpeedSample(itemId: itemId)
        removeRecord(itemId: itemId)
        saveIndex()
    }

    public func deleteDownload(itemId: Int64) {
        if let url = localFileURL(itemId: itemId) {
            try? FileManager.default.removeItem(at: url)
        }
        if let cachedPoster = cachedPosterURL(itemId: itemId) {
            try? FileManager.default.removeItem(at: cachedPoster)
        }
        clearSpeedSample(itemId: itemId)
        removeRecord(itemId: itemId)
        saveIndex()
    }

    /// User-Anfrage 2026-08-26: "bei den Downloads auch einen Button, der alle Downloads
    /// löscht" — nur die aktuell sichtbaren (per-User-gefilterten) `records`, nicht
    /// `allRecordsOnDisk` direkt, damit ein geteilter Downloads-Ordner nicht versehentlich
    /// die Downloads eines ANDEREN Accounts auf diesem Mac mitlöscht. Bricht laufende
    /// Downloads direkt ab (nicht über `cancelDownload` — das löscht den Record selbst
    /// schon, `deleteDownload` unten würde die zugehörige Datei dann nicht mehr finden)
    /// und räumt danach für JEDES Item einheitlich über `deleteDownload` auf (Datei +
    /// Poster + Formatanpassungs-Cache + Record), egal ob es fertig, laufend oder
    /// fehlgeschlagen war.
    public func deleteAllDownloads() {
        for itemId in Array(records.keys) {
            tasks[itemId]?.cancel()
            tasks[itemId] = nil
            deleteDownload(itemId: itemId)
        }
    }
}

extension DownloadManager: @preconcurrency URLSessionDownloadDelegate {
    // `@preconcurrency` on this conformance only suppresses the COMPILER's isolation
    // checking — it does NOT insert an actual actor hop at runtime. URLSession calls these
    // methods on its own private delegate queue (we pass `delegateQueue: nil` at session
    // creation), never the main thread. Real crash hit 2026-08-19: an earlier "fix" removed
    // the `Task { @MainActor in }` wrappers on the theory that the class being `@MainActor`
    // already made these methods actor-isolated at runtime — wrong for `@preconcurrency`
    // conformances. Mutating `@Published records` directly on that background queue crashed
    // (SIGABRT) deep inside SwiftUI's Combine pipeline, which hit an AppKit main-thread-only
    // assertion (`-[NSMenu itemArray]`) while propagating the change. Every method here must
    // stay wrapped in `Task { @MainActor in }` for that reason.

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                            didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                            totalBytesExpectedToWrite: Int64) {
        guard let idStr = downloadTask.taskDescription, let itemId = Int64(idStr) else { return }
        Task { @MainActor in
            guard var rec = self.records[itemId] else { return }
            rec.bytesWritten = totalBytesWritten
            if totalBytesExpectedToWrite > 0 { rec.bytesExpected = totalBytesExpectedToWrite }
            self.setRecord(rec)
            self.updateSpeedSample(itemId: itemId, bytes: totalBytesWritten)
        }
    }

    /// Berechnet die geglättete Downloadrate aus dem Byte-Delta seit dem letzten Sample.
    /// Gedrosselt auf min. 0.3s zwischen zwei Berechnungen (siehe `lastSpeedSample`-Kommentar).
    private func updateSpeedSample(itemId: Int64, bytes: Int64) {
        let now = Date()
        guard let last = lastSpeedSample[itemId] else {
            lastSpeedSample[itemId] = (now, bytes)
            return
        }
        let elapsed = now.timeIntervalSince(last.time)
        guard elapsed >= 0.3 else { return }
        let deltaBytes = bytes - last.bytes
        lastSpeedSample[itemId] = (now, bytes)
        guard deltaBytes >= 0 else { return }
        let instantRate = Double(deltaBytes) / elapsed
        // Exponentiell geglättet statt der reinen Momentan-Rate — sonst hüpft die Anzeige
        // bei jedem Callback sichtbar, weil einzelne TCP-Chunks unterschiedlich groß ankommen.
        if let existing = downloadSpeeds[itemId] {
            downloadSpeeds[itemId] = existing * 0.7 + instantRate * 0.3
        } else {
            downloadSpeeds[itemId] = instantRate
        }
    }

    private func clearSpeedSample(itemId: Int64) {
        lastSpeedSample[itemId] = nil
        downloadSpeeds[itemId] = nil
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                            didFinishDownloadingTo location: URL) {
        guard let idStr = downloadTask.taskDescription, let itemId = Int64(idStr) else { return }
        let httpStatus = (downloadTask.response as? HTTPURLResponse)?.statusCode

        // Stage 1 — MUST happen synchronously, right here, before this method returns:
        // `location` is a temp file URLSession deletes the instant the delegate call ends.
        // This touches only plain `FileManager` calls, no `self`/`@Published` access at all,
        // so it's safe to run on whatever thread we were actually called on. Staging it into
        // OUR OWN temp file decouples "must move before returning" from "must touch
        // `@Published` state on MainActor" — the two requirements that were fighting each
        // other across this bug's last three attempted fixes.
        let stagedURL = FileManager.default.temporaryDirectory.appendingPathComponent("goldfish-dl-\(itemId).tmp")
        try? FileManager.default.removeItem(at: stagedURL)
        let staged = (try? FileManager.default.moveItem(at: location, to: stagedURL)) != nil

        // Stage 2 — back on MainActor for everything that touches `records`/`tasks`.
        Task { @MainActor in
            self.clearSpeedSample(itemId: itemId)
            guard var rec = self.records[itemId] else { return }
            // HTTP-level failures (401/404/500/...) land here too, not in didCompleteWithError
            // — the download "succeeds" as far as URLSession is concerned, it just downloaded
            // an error page. Surface a proper message instead of a silent bad file.
            if let httpStatus, !(200..<300).contains(httpStatus) {
                rec.state = .failed
                rec.errorMessage = "Server antwortete mit Status \(httpStatus)"
                self.setRecord(rec)
                self.tasks[itemId] = nil
                self.saveIndex()
                try? FileManager.default.removeItem(at: stagedURL)
                return
            }
            guard staged else {
                rec.state = .failed
                rec.errorMessage = "Heruntergeladene Datei ging beim Verschieben verloren."
                self.setRecord(rec)
                self.tasks[itemId] = nil
                self.saveIndex()
                return
            }
            let fm = FileManager.default
            var dest = URL(fileURLWithPath: rec.filePath)
            try? fm.removeItem(at: dest)
            do {
                try fm.moveItem(at: stagedURL, to: dest)
                rec.state = .done
                rec.errorMessage = nil
            } catch {
                // Access to the custom folder can vanish between the pre-flight check in
                // startDownload() and now (long downloads) — retry once into the always-
                // writable default directory instead of just losing the finished download.
                if self.usesCustomDirectory {
                    self.ensureWritableDownloadsDir()
                    dest = self.downloadsDir.appendingPathComponent(rec.fileName)
                    if (try? fm.moveItem(at: stagedURL, to: dest)) != nil {
                        rec.filePath = dest.path
                        rec.state = .done
                        rec.errorMessage = nil
                    } else {
                        rec.state = .failed
                        rec.errorMessage = error.localizedDescription
                    }
                } else {
                    rec.state = .failed
                    rec.errorMessage = error.localizedDescription
                }
            }
            self.setRecord(rec)
            self.tasks[itemId] = nil
            self.saveIndex()
            // Kein Aufruf einer Formatanpassung mehr nötig — der Server liefert die Datei
            // bereits kompatibel aus (`?compat=1`, siehe `GoldfishClient.downloadFileURL`).
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let idStr = task.taskDescription, let itemId = Int64(idStr), let error else { return }
        Task { @MainActor in
            self.clearSpeedSample(itemId: itemId)
            guard var rec = self.records[itemId] else { return }
            if (error as NSError).code != NSURLErrorCancelled {
                rec.state = .failed
                rec.errorMessage = error.localizedDescription
                // User-Anfrage 2026-08-25: Verbindungsabbruch soll den Download fortsetzbar
                // machen statt komplett von vorne — Foundation packt den bereits
                // heruntergeladenen Teil in `resumeData`, wenn der Server (wie Goldfishs
                // Download-Endpoint) Range-Requests unterstützt. Nicht jeder Fehler liefert
                // das (z.B. wenn der Server selbst Range gar nicht erst zulässt) — dann bleibt
                // `resumeData` nil und "Erneut versuchen" startet ganz normal neu.
                rec.resumeData = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
                self.setRecord(rec)
                self.saveIndex()
            }
            self.tasks[itemId] = nil
        }
    }
}
