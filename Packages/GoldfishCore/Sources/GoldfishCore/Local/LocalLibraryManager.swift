import Foundation
import AVFoundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// User-Anfrage 2026-08-25: "kann man durch größeres Puffern flüssiger abspielen" (langsame
/// externe Quelle) — Regler in den Einstellungen (`SettingsView`), gilt für ALLE Goldfish-
/// Accounts auf diesem Mac (bewusst nicht account-gescoped, reine Geräte-/Hardware-Tuning-
/// Einstellung, kein Nutzer-Datum). Gelesen von `LocalPlayerView.setUp()` für
/// `AVPlayerItem.preferredForwardBufferDuration`. `defaultBufferSeconds` ist der Wert, der sich
/// beim ersten Test (fest auf 60 verdrahtet) bereits bewährt hat — Slider startet dort, nicht
/// bei irgendeinem Neutralwert.
/// User-Anfrage 2026-08-25: "neben der Anzahl an Dateien auch immer die Gesamtgröße in GB,
/// deaktivierbar im Menü" — EIN gemeinsamer Schalter für Server- UND lokale Bibliotheken
/// (`ItemGridView` + `LocalLibraryItemsView`), damit ein Toggle an einer Stelle überall
/// gilt. Default AN — der User will die Größe standardmäßig sehen, "deaktivierbar" heißt
/// nur, dass es abschaltbar sein soll, nicht dass es erst manuell angeschaltet werden muss.
public enum DisplaySettings {
    public static let showTotalSizeKey = "goldfish.showTotalSize"
}

public enum LocalPlaybackSettings {
    public static let bufferSecondsKey = "goldfish.localBufferSeconds"
    public static let defaultBufferSeconds: Double = 60
    public static var bufferSeconds: Double {
        let stored = UserDefaults.standard.double(forKey: bufferSecondsKey)
        return stored > 0 ? stored : defaultBufferSeconds
    }
}

public struct LocalLibrary: Codable, Identifiable, Hashable {
    public let id: UUID
    public var name: String
    public var kind: String // "movies" | "tv" | "private"
    public var bookmarkData: Data
    public var createdAt: Date
    /// Server account (username) that added this library — real bug hit 2026-08-19: local
    /// libraries had NO per-user isolation at all, every account logged into this Mac/app
    /// install saw every other account's local libraries (folders, item lists, everything).
    /// Mirrors the Android app's `LocalLibraryEntity.ownerUsername` fix (same class of bug,
    /// same root cause: local content lives outside the server's own ACL system entirely).
    /// Optional only so libraries persisted before this field existed still decode — nil
    /// means "unclaimed legacy library", visible to everyone until explicitly claimed via
    /// `LocalLibraryManager.claimLibrary` (NOT auto-assigned to whoever happens to be logged
    /// in — that guessed wrong once already, see the comment on `refreshVisibleLibraries`).
    public var ownerUsername: String?

    public init(id: UUID = UUID(), name: String, kind: String, bookmarkData: Data, createdAt: Date = Date(), ownerUsername: String? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.bookmarkData = bookmarkData
        self.createdAt = createdAt
        self.ownerUsername = ownerUsername
    }
}

public struct LocalItem: Codable, Identifiable, Hashable {
    public let id: UUID
    public let libraryId: UUID
    public var relPath: String
    public var fileName: String
    public var sizeBytes: Int64
    public var modifiedTime: Date
    /// Zeitpunkt, an dem diese Datei erstmals in die Bibliothek eingelesen wurde (nicht die
    /// Datei-mtime, die ist `modifiedTime`) — User-Anfrage 2026-08-27: "der Filter bei
    /// externen Bibliotheken 'zuletzt Hinzugefügt' fehlt mir noch", analog zum Server-Sort
    /// `added` (`items.added_at`). Optional, damit bereits bestehende, vor diesem Feature
    /// gescannte Indizes weiter dekodieren (fehlt einfach, `LocalLibraryItemsView` fällt für
    /// diese Alt-Items auf `modifiedTime` zurück). Bleibt bei einem Rescan unverändert
    /// erhalten (`scan()` übernimmt `existing.addedAt`, setzt es nur für WIRKLICH neue Dateien).
    public var addedAt: Date? = nil
    public var resumePosSec: Double = 0
    public var watched = false
    /// User-Anfrage 2026-08-30: "bei lokalen Bibliotheken eine Sternebewertung, maximal 3
    /// Sterne, und danach filtern können". 0 = keine Bewertung, 1–3 = Sterne. Non-optional
    /// mit Default, damit vor diesem Feature gescannte Indizes weiter dekodieren (Swift
    /// synthetisiert `decodeIfPresent` für Properties mit Default-Wert). Bleibt bei einem
    /// Rescan erhalten — `scan()` übernimmt bestehende Items komplett und überschreibt nur
    /// Größe/mtime.
    public var rating: Int = 0
    public var thumbnailPath: String?
    /// User-Anfrage 2026-08-25: "bei den lokalen Dateien hätte ich gerne in den Kacheln noch
    /// die Auflösung, und als Filter möchte ich auch nach Auflösung filtern können" — Server-
    /// Items haben `width`/`height` schon immer (ffprobe beim Scan), lokale Items bisher nie.
    /// Optional + nachträglich befüllt (siehe `LocalLibraryManager.generateThumbnailIfNeeded`),
    /// damit bereits gescannte Bestandsdateien beim nächsten Rescan automatisch nachgezogen
    /// werden, ohne die komplette Bibliothek neu einlesen zu müssen.
    public var width: Int?
    public var height: Int?

    /// Gleiche Formel + Bucket-Grenzen wie der Server (CLAUDE.md "resLabel(it)" /
    /// `internal/store/sqlite.go` ResBuckets) — Cinemascope-Filme landen dadurch im richtigen
    /// Bucket basierend auf der horizontalen statt nur der vertikalen Auflösung.
    public var resolutionLabel: String {
        guard let h = height, let w = width, h > 0 else { return "" }
        let effective = max(Double(h), Double(w) * 9.0 / 16.0)
        switch effective {
        case 2000...: return "4K"
        case 1000..<2000: return "1080p"
        case 700..<1000: return "720p"
        default: return "\(Int(effective))p"
        }
    }

    /// Für den Auflösungs-Filter — welcher `ResolutionBucket` dieses Item zugeordnet ist, nil
    /// wenn (noch) keine Auflösung bekannt ist (Item fällt dann bei aktivem Filter weder rein
    /// noch raus, siehe `LocalLibraryItemsView`s Filter-Logik).
    public var resolutionBucket: ResolutionBucket? {
        guard let h = height, let w = width, h > 0 else { return nil }
        let effective = Int(max(Double(h), Double(w) * 9.0 / 16.0))
        switch effective {
        case 2000...: return .uhd4k
        case 1400..<2000: return .uhd2k
        case 1000..<1400: return .fhd1080
        case 700..<1000: return .hd720
        case 540..<700: return .sd576
        case 500..<540: return .sd540
        case 440..<500: return .sd480
        default: return .low
        }
    }

    /// User-Anfrage 2026-08-25: "im Doppelpfeilmenü auch einen Filter nach Auflösung, wo er
    /// alle Dateien nach Auflösung sortiert" — numerischer Wert für `LocalLibraryItemsView`s
    /// Sortier-Menü, gleiche `max(height, width*9/16)`-Formel wie `resolutionBucket`, nur
    /// nicht in Buckets gerundet (echte Sortierung, nicht nur Gruppierung).
    public var effectiveResolution: Int? {
        guard let h = height, let w = width, h > 0 else { return nil }
        return Int(max(Double(h), Double(w) * 9.0 / 16.0))
    }

    /// User-Anfrage 2026-08-20: "zuletzt Abgespielt" fehlte als Sortierung für lokale
    /// Bibliotheken — es gab bisher gar keinen Zeitstempel dafür. Wird bei jedem echten
    /// Wiedergabe-Fortschritt gesetzt (`LocalLibraryManager.setResume`), nicht bei einem
    /// manuellen "als ungesehen markieren"-Toggle.
    public var lastPlayedAt: Date?

    public var displayTitle: String {
        (fileName as NSString).deletingPathExtension
    }
}

private let videoExtensions: Set<String> = [
    "mp4", "m4v", "mov", "mkv", "avi", "webm", "wmv", "flv", "ts", "mpg", "mpeg", "3gp", "vob"
]

@MainActor
public final class LocalLibraryManager: ObservableObject {
    public static let shared = LocalLibraryManager()

    /// FILTERED to the currently logged-in user — this is the only list the UI ever reads.
    /// `allLibrariesOnDisk` below is the real, cross-user persisted truth; `libraries` is
    /// recomputed from it by `refreshVisibleLibraries()` on every mutation and on login/logout.
    @Published public private(set) var libraries: [LocalLibrary] = []
    /// Full, unfiltered, persisted set — includes OTHER users' libraries too. Never exposed
    /// directly; exists so `save()` doesn't destroy another user's libraries when the current
    /// user's list changes. All mutating methods (`addLibrary`, `deleteLibrary`, …) operate on
    /// this, then call `refreshVisibleLibraries()` to update the public `libraries`.
    private var allLibrariesOnDisk: [LocalLibrary] = []
    @Published public private(set) var items: [LocalItem] = []
    @Published public private(set) var scanningLibraryIds: Set<UUID> = []
    /// Real bug hit 2026-08-26 (User: Ruckeln trotz aller Playback-Pause-Fixes; `lsof` zeigte
    /// DREI gleichzeitig offene Dateien auf derselben SD-Karte): `scan()` feuerte bisher pro
    /// Bibliothek einen EIGENEN, unabhängigen Thumbnail-/Auflösungs-Hintergrund-Task ab — bei
    /// mehreren Bibliotheken (User hat zwei) konnte also jede Bibliothek gleichzeitig ihr
    /// eigenes Item offen halten, selbst wenn jede einzelne Schleife für sich schon brav
    /// `waitWhilePlaybackActive()` respektierte. Jetzt EINE geteilte Warteschlange über ALLE
    /// Bibliotheken (gleiches Single-Worker-Muster wie `LocalTranscodeService.processQueue`),
    /// garantiert höchstens EIN Hintergrund-Datei-Handle für Thumbnails/Auflösung insgesamt.
    private var thumbnailQueue: [LocalItem] = []
    private var isProcessingThumbnails = false
    @Published public var lastError: String?
    /// Bibliotheken, deren Wurzel-Ordner gerade nicht erreichbar ist — z.B. ein externer
    /// USB-Stick/SD-Karte, die abgezogen wurde. Statt hart zu fehlern (User-Anfrage
    /// 2026-08-19: "sollen alle dort enthaltenen Dateien … im lokalen Ordner verblassen")
    /// bleiben die Einträge sichtbar, UI dimmt sie nur ab. Wird bei jedem fehlgeschlagenen
    /// `resolveRoot`-Versuch aktualisiert (Scan, Player-Open, Thumbnail-Generierung).
    @Published public private(set) var unavailableLibraryIds: Set<UUID> = []
    /// Lokale Bibliotheken, die im Browsing als EINE erscheinen sollen — anders als
    /// Android (dort exakt 2, altersbasiert ersetzt) ist hier explizit KEIN Limit
    /// gewünscht (User-Anfrage 2026-08-18: "nein, mehr als 2").
    @Published public private(set) var mergedLibraryIds: Set<UUID> = []
    /// Custom display name for the merged-libraries tile — User-Anfrage 2026-08-19: ohne
    /// diesen fällt die Kachel auf die zusammengesetzten Einzelnamen zurück (z.B. "a + Alex"),
    /// was schnell unhandlich wird bei mehr als 2-3 zusammengelegten Bibliotheken.
    @Published public private(set) var mergedLibraryName: String = ""
    /// Beliebig viele lokale Bibliotheken, die gegeneinander auf doppelte Dateinamen
    /// geprüft werden — mirrors Android's `compareLocalLibraryIds` (Settings →
    /// "Vergleichs-Filter"). Match-Kriterium ist NUR der Dateiname, keine Size/Hash —
    /// gleiche Konvention wie Android (`LocalAppDatabase.findDuplicateFileNames`).
    @Published public private(set) var compareLibraryIds: Set<UUID> = []

    private var activeRoots: [UUID: URL] = [:]
    private let indexURL: URL

    private init() {
        let fm = FileManager.default
        let support = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fm.temporaryDirectory
        let dir = support.appendingPathComponent("GoldfishLocalLibraries", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        self.indexURL = dir.appendingPathComponent("index.json")
        load()
        // Background availability tracking (mount/unmount, initial warm-up) runs over ALL
        // libraries regardless of owner — it only ever updates true/false reachability, never
        // exposes content, and keeps working correctly across a user switch without needing
        // to re-resolve everything from scratch on every login.
        for lib in allLibrariesOnDisk { _ = resolveRoot(for: lib) }
        refreshVisibleLibraries()
        #if os(macOS)
        LocalTranscodeService.shared.onConverted = { [weak self] item in
            Task { await self?.generateThumbnailIfNeeded(for: item) }
        }
        observeVolumeChanges()
        #endif
    }

    /// Call when the logged-in account changes (login/logout/switch) — recomputes the
    /// publicly-visible `libraries` list for the new user. `RootView` calls this on every
    /// `client.currentUsername` change.
    public func userDidChange() {
        refreshVisibleLibraries()
    }

    private func currentUsername() -> String? { GoldfishClient.shared.currentUsername }

    /// Recomputes `libraries` (the only list the UI ever sees) from `allLibrariesOnDisk`,
    /// scoped to the current user. Real bug hit 2026-08-19: the FIRST version of this
    /// auto-attributed any unowned legacy library to whoever happened to be logged in the
    /// first time this ran — Börnie logged in only briefly to VERIFY the isolation fix, and
    /// got silently made the permanent "owner" of libraries Christian actually created. There
    /// is no way to guess the true original owner from old data, so this no longer guesses at
    /// all: an unowned library stays visible to EVERYONE (safe fallback, matches the pre-fix
    /// behavior for that one case) until its real creator explicitly claims it via
    /// `claimLibrary`, surfaced in Settings.
    private func refreshVisibleLibraries() {
        guard let user = currentUsername() else {
            libraries = []
            return
        }
        libraries = allLibrariesOnDisk.filter { $0.ownerUsername == user || $0.ownerUsername == nil }
    }

    /// Explicit, user-initiated ownership assignment for a library that predates
    /// `ownerUsername` (shows up in Settings only for libraries with no owner yet) — the only
    /// way an unowned library's owner is ever set, replacing the removed auto-migration.
    public func claimLibrary(_ library: LocalLibrary) {
        guard library.ownerUsername == nil, let user = currentUsername(),
              let idx = allLibrariesOnDisk.firstIndex(where: { $0.id == library.id }) else { return }
        allLibrariesOnDisk[idx].ownerUsername = user
        save()
        refreshVisibleLibraries()
    }

    #if os(macOS)
    // Real bug hit 2026-08-19: unplugging a USB-Stick/SD-Karte was only ever detected LAZILY
    // — `resolveRoot(for:)` only re-checks the filesystem when something actually tries to
    // use the library (scan, player-open, thumbnail generation). The user saw the whole
    // library stay "available" (not dimmed) until they happened to try playing a now-missing
    // file, and plugging the stick back in was never picked up at all since nothing ever
    // called `resolveRoot` again on its own. `NSWorkspace`'s mount/unmount notifications fix
    // both: react to the actual OS-level event instead of waiting for a failed access.
    private func observeVolumeChanges() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.recheckAllRoots() }
        }
        nc.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.retryUnavailableLibraries() }
        }
    }

    /// Re-verifies every currently-known library against the filesystem — triggered by
    /// `didUnmountNotification`, whose payload carries the device path, not something
    /// directly comparable to our bookmark-resolved `file://` root URLs, so re-checking all
    /// of them (cheap: just a `fileExists` per library) is simpler than trying to match the
    /// specific volume that went away.
    private func recheckAllRoots() {
        for library in allLibrariesOnDisk { _ = resolveRoot(for: library) }
    }

    /// After a mount event: retry every library currently marked unavailable via its saved
    /// bookmark — if the same USB-Stick came back at the same mount point, this reconnects
    /// it automatically (no manual "Ordner erneut wählen" step) and re-scans to pick up
    /// anything that changed while it was disconnected. Uses `allLibrariesOnDisk` (not just
    /// the current user's `libraries`) so this keeps working for a background/other-user
    /// library too — `scan()` itself only touches `items`/`activeRoots`, both keyed by
    /// library ID and safe regardless of which account is currently displayed.
    private func retryUnavailableLibraries() async {
        let candidates = allLibrariesOnDisk.filter { unavailableLibraryIds.contains($0.id) }
        for library in candidates where resolveRoot(for: library) != nil {
            await scan(library)
        }
    }
    #endif

    public func itemsFor(_ libraryId: UUID) -> [LocalItem] {
        items.filter { $0.libraryId == libraryId }.sorted { $0.displayTitle.localizedStandardCompare($1.displayTitle) == .orderedAscending }
    }

    /// Kombinierte, alphabetisch sortierte Liste über mehrere zusammengelegte
    /// Bibliotheken hinweg — keine Ordner-Trennung zwischen den Libs, gleiche
    /// Konvention wie Android's `loadMerged`.
    public func itemsFor(_ libraryIds: Set<UUID>) -> [LocalItem] {
        items.filter { libraryIds.contains($0.libraryId) }.sorted { $0.displayTitle.localizedStandardCompare($1.displayTitle) == .orderedAscending }
    }

    // Plain (non-security-scoped) bookmarks on both platforms — App Sandbox was removed
    // from the Mac target 2026-08-19 (see `GoldfishMac.entitlements`), so there's no
    // sandbox extension to persist and no `startAccessingSecurityScopedResource()` dance
    // needed at all. `.withSecurityScope` bookmarks turned out to fail unpredictably even
    // for internal APFS folders under a free "Personal Team" signature — not just the
    // exFAT USB-stick case that started this investigation.
    private static let bookmarkOptions: URL.BookmarkCreationOptions = []
    private static let resolveOptions: URL.BookmarkResolutionOptions = []

    private func resolveRoot(for library: LocalLibrary) -> URL? {
        if let cached = activeRoots[library.id] {
            // Re-check on every call, not just once at resolve time — a USB-Stick/SD-Karte
            // pulled out mid-session must flip to "unavailable" immediately, not only after
            // the app restarts and the bookmark cache is empty again.
            guard FileManager.default.fileExists(atPath: cached.path) else {
                activeRoots[library.id] = nil
                unavailableLibraryIds.insert(library.id)
                return nil
            }
            return cached
        }
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: library.bookmarkData, options: Self.resolveOptions, relativeTo: nil, bookmarkDataIsStale: &isStale),
              FileManager.default.fileExists(atPath: url.path) else {
            unavailableLibraryIds.insert(library.id)
            return nil
        }
        unavailableLibraryIds.remove(library.id)
        activeRoots[library.id] = url
        return url
    }

    /// `rootURL` must come straight from a picker (`.fileImporter`/`NSOpenPanel`) — already
    /// accessible for this call, used both to create the persistable bookmark and as the
    /// live root for the very first scan.
    @discardableResult
    public func addLibrary(rootURL: URL, name: String, kind: String) async -> Bool {
        lastError = nil
        guard let bookmark = try? rootURL.bookmarkData(options: Self.bookmarkOptions, includingResourceValuesForKeys: nil, relativeTo: nil) else {
            lastError = "Konnte keinen Zugriff auf den Ordner einrichten."
            return false
        }
        let library = LocalLibrary(name: name, kind: kind, bookmarkData: bookmark, ownerUsername: currentUsername())
        allLibrariesOnDisk.append(library)
        activeRoots[library.id] = rootURL
        save()
        refreshVisibleLibraries()
        await scan(library)
        return true
    }

    /// Re-grants access to a library whose external volume was unplugged and remounted
    /// (or moved) — `rootURL` must be freshly picked (same folder, already accessible).
    public func reconnectLibrary(_ library: LocalLibrary, rootURL: URL) async {
        guard library.ownerUsername == nil || library.ownerUsername == currentUsername() else { return }
        activeRoots[library.id] = rootURL
        unavailableLibraryIds.remove(library.id)
        if let bookmark = try? rootURL.bookmarkData(options: Self.bookmarkOptions, includingResourceValuesForKeys: nil, relativeTo: nil),
           let idx = allLibrariesOnDisk.firstIndex(where: { $0.id == library.id }) {
            allLibrariesOnDisk[idx].bookmarkData = bookmark
        }
        save()
        refreshVisibleLibraries()
        await scan(library)
    }

    /// Re-scans every local library — a `scan()` already re-checks EVERY item's playability
    /// on each run, not just newly-discovered files (`enqueueCompatibilityCheck`'s
    /// `!isConverted` guard naturally skips already-fixed files and retries anything not yet
    /// successfully converted), so this doubles as "retry all format fixes" without deleting
    /// and re-adding any library (User-Anfrage 2026-08-19).
    /// User-Report 2026-08-24: "wenn ich auf 'Erneut prüfen' klicke, passiert nichts — aber
    /// sobald ich [eine bestimmte, nicht angeschlossene] Platte einstecke, läuft es los." Bei
    /// zwei lokalen Bibliotheken auf zwei verschiedenen externen Platten wartete die zweite
    /// (angeschlossene, mit den eigentlich gewünschten Dateien) bisher darauf, dass die ERSTE
    /// in der Liste fertig ist — sequenzielles `for … await scan(...)`. War Bibliothek 1 (nicht
    /// angeschlossen) langsam oder blockierte am Auflösen ihres jetzt toten Bookmarks, kam
    /// Bibliothek 2 nie an die Reihe, obwohl ihr Datenträger die ganze Zeit verfügbar war.
    /// Fix: alle Bibliotheken parallel scannen, keine wartet mehr auf eine andere.
    public func rescanAllLibraries() async {
        await withTaskGroup(of: Void.self) { group in
            for library in libraries {
                group.addTask { await self.scan(library) }
            }
        }
    }

    public func scan(_ library: LocalLibrary) async {
        guard let root = resolveRoot(for: library) else {
            lastError = "Zugriff auf \"\(library.name)\" verloren — bitte Bibliothek löschen und Ordner erneut wählen."
            return
        }
        scanningLibraryIds.insert(library.id)
        defer { scanningLibraryIds.remove(library.id) }

        let fm = FileManager.default
        var found: [LocalItem] = []
        let existingById = Dictionary(uniqueKeysWithValues: items.filter { $0.libraryId == library.id }.map { ($0.relPath, $0) })

        if let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey], options: [.skipsHiddenFiles]) {
            for case let fileURL as URL in enumerator {
                let name = fileURL.lastPathComponent
                let isDir = (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                if isDir {
                    if name.lowercased() == "sample" || name.lowercased() == "samples" {
                        enumerator.skipDescendants()
                    }
                    continue
                }
                guard videoExtensions.contains(fileURL.pathExtension.lowercased()) else { continue }
                let relPath = String(fileURL.path.dropFirst(root.path.count + 1))
                let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])

                if var existing = existingById[relPath] {
                    existing.sizeBytes = Int64(values?.fileSize ?? 0)
                    existing.modifiedTime = values?.contentModificationDate ?? existing.modifiedTime
                    found.append(existing)
                } else {
                    found.append(LocalItem(
                        id: UUID(), libraryId: library.id, relPath: relPath, fileName: name,
                        sizeBytes: Int64(values?.fileSize ?? 0),
                        modifiedTime: values?.contentModificationDate ?? Date(),
                        addedAt: Date()
                    ))
                }
            }
        }

        items.removeAll { $0.libraryId == library.id }
        items.append(contentsOf: found)
        save()

        // Thumbnails happen after the scan reports done (UI already shows titles/sizes) —
        // one at a time in the background so a big library doesn't stall the scan itself.
        // Auch Bestandsdateien mit Thumbnail, aber ohne Auflösung (Feature nachträglich
        // hinzugefügt, 2026-08-25) laufen hier mit durch — `generateThumbnailIfNeeded` probt
        // die Auflösung unabhängig davon, ob das Thumbnail selbst schon existiert.
        let needThumbs = found.filter { $0.thumbnailPath == nil || $0.width == nil }
        enqueueThumbnailGeneration(needThumbs)

        // Same idea for playability: files AVFoundation can't natively decode (MKV/DTS, …)
        // get fixed proactively in the background instead of the user discovering it by
        // hitting a dead player on first tap (User-Anfrage 2026-08-19).
        #if os(macOS)
        LocalTranscodeService.shared.enqueueCompatibilityCheck(items: found) { [weak self] item in
            self?.fileURL(for: item)
        }
        #endif
    }

    public func fileURL(for item: LocalItem) -> URL? {
        guard let library = libraries.first(where: { $0.id == item.libraryId }), let root = resolveRoot(for: library) else { return nil }
        return root.appendingPathComponent(item.relPath)
    }

    public func renameLibrary(_ library: LocalLibrary, to newName: String) {
        guard library.ownerUsername == nil || library.ownerUsername == currentUsername() else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let idx = allLibrariesOnDisk.firstIndex(where: { $0.id == library.id }) else { return }
        allLibrariesOnDisk[idx].name = trimmed
        save()
        refreshVisibleLibraries()
    }

    public func deleteLibrary(_ library: LocalLibrary) {
        guard library.ownerUsername == nil || library.ownerUsername == currentUsername() else { return }
        if let root = activeRoots[library.id] { root.stopAccessingSecurityScopedResource() }
        activeRoots[library.id] = nil
        allLibrariesOnDisk.removeAll { $0.id == library.id }
        items.removeAll { $0.libraryId == library.id }
        mergedLibraryIds.remove(library.id)
        compareLibraryIds.remove(library.id)
        unavailableLibraryIds.remove(library.id)
        save()
        refreshVisibleLibraries()
    }

    public func deleteItem(_ item: LocalItem) {
        if let url = fileURL(for: item) { try? FileManager.default.removeItem(at: url) }
        if let thumbnailPath = item.thumbnailPath {
            try? FileManager.default.removeItem(atPath: thumbnailPath)
        }
        #if os(macOS)
        LocalTranscodeService.shared.deleteCachedConversion(itemUUID: item.id)
        #endif
        items.removeAll { $0.id == item.id }
        save()
    }

    public func thumbnailURL(for item: LocalItem) -> URL? {
        guard let path = item.thumbnailPath, FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    private static let thumbsDir: URL = {
        let fm = FileManager.default
        let support = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fm.temporaryDirectory
        let dir = support.appendingPathComponent("GoldfishLocalThumbs", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Frame extraction, same idea as Android's `MediaProbe.extractFrame` — 10% into the
    /// video for anything over 30s, 2s in for short clips, first frame otherwise. No FFmpeg
    /// needed on Apple platforms; AVAssetImageGenerator covers this natively.
    ///
    /// Prefers the transcoded copy over the original when one exists (macOS only) — real bug
    /// hit 2026-08-19: thumbnails for MKV sources never rendered at all, same root cause as
    /// playback (`AVFoundation` can't demux MKV regardless of the codecs inside it), and at
    /// scan time the background conversion usually hasn't produced a copy yet anyway. Called
    /// again from `LocalTranscodeService`'s completion hook once a conversion finishes, so
    /// items that failed here on the first pass get a real thumbnail shortly after.
    /// Sammelpunkt für ALLE Bibliotheken (siehe `thumbnailQueue`-Kommentar) — `scan()` ruft
    /// das statt direkt einen eigenen Task zu starten, damit parallele Scans mehrerer
    /// Bibliotheken sich nicht gegenseitig I/O-Bandbreite auf demselben externen Datenträger
    /// wegnehmen.
    private func enqueueThumbnailGeneration(_ items: [LocalItem]) {
        thumbnailQueue.append(contentsOf: items)
        processThumbnailQueue()
    }

    private func processThumbnailQueue() {
        guard !isProcessingThumbnails else { return }
        isProcessingThumbnails = true
        Task {
            while !thumbnailQueue.isEmpty {
                #if os(macOS)
                await LocalTranscodeService.shared.waitWhilePlaybackActive()
                #endif
                let item = thumbnailQueue.removeFirst()
                await generateThumbnailIfNeeded(for: item)
            }
            isProcessingThumbnails = false
        }
    }

    public func generateThumbnailIfNeeded(for item: LocalItem) async {
        var url = fileURL(for: item)
        #if os(macOS)
        let convertedURL = LocalTranscodeService.shared.convertedURL(for: item)
        if FileManager.default.fileExists(atPath: convertedURL.path) { url = convertedURL }
        #endif
        guard let url else { return }
        let asset = AVURLAsset(url: url)

        if item.width == nil || item.height == nil {
            await probeResolutionIfNeeded(for: item, asset: asset)
        }

        let dest = Self.thumbsDir.appendingPathComponent("\(item.id.uuidString).jpg")
        if FileManager.default.fileExists(atPath: dest.path) {
            setThumbnailPath(item, path: dest.path)
            return
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true

        do {
            let durationSec = try await asset.load(.duration).seconds
            let offset = durationSec > 30 ? durationSec * 0.1 : (durationSec > 5 ? 2 : 0)
            let cgImage = try await generator.image(at: CMTime(seconds: offset, preferredTimescale: 600)).image

            #if os(macOS)
            let rep = NSBitmapImageRep(cgImage: cgImage)
            guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else { return }
            #else
            guard let data = UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.85) else { return }
            #endif
            try data.write(to: dest)
            setThumbnailPath(item, path: dest.path)
        } catch {
            // Real Fund 2026-08-26: AVFoundation demuxes the source itself (`url` above is only
            // the converted copy if one ALREADY exists) — for a "fast" file (MKV+hevc/h264)
            // that no longer gets pre-converted in the background at all (see
            // `LocalTranscodeService.enqueueCompatibilityCheck`), this always fails here, same
            // demux limitation that made playback fail in the first place. `ffmpeg` decodes far
            // more containers than AVFoundation, so it can still pull a preview frame straight
            // out of the untouched original — no container remux, nothing written to the
            // transcode cache, just the one JPEG.
            #if os(macOS)
            if await LocalTranscodeService.shared.extractThumbnailViaFFmpeg(sourceURL: url, destJPEG: dest) {
                setThumbnailPath(item, path: dest.path)
            }
            #endif
        }
    }

    private func setThumbnailPath(_ item: LocalItem, path: String) {
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[idx].thumbnailPath = path
        save()
    }

    /// Video-Track-`naturalSize` inkl. `preferredTransform` (rotierte Handy-Aufnahmen liefern
    /// sonst vertauschte Breite/Höhe) — kein ffprobe nötig, funktioniert identisch auf iOS.
    private func probeResolutionIfNeeded(for item: LocalItem, asset: AVURLAsset) async {
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else { return }
        guard let size = try? await track.load(.naturalSize),
              let transform = try? await track.load(.preferredTransform) else { return }
        let transformed = size.applying(transform)
        let width = Int(abs(transformed.width))
        let height = Int(abs(transformed.height))
        guard width > 0, height > 0 else { return }
        setResolution(item, width: width, height: height)
    }

    private func setResolution(_ item: LocalItem, width: Int, height: Int) {
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[idx].width = width
        items[idx].height = height
        save()
    }

    public func setWatched(_ item: LocalItem, watched: Bool) {
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[idx].watched = watched
        save()
    }

    /// User-Anfrage 2026-08-30: Sternebewertung für lokale Items, max. 3 Sterne. `rating`
    /// wird auf 0…3 geklemmt; 0 hebt eine bestehende Bewertung wieder auf.
    public func setRating(_ item: LocalItem, rating: Int) {
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[idx].rating = max(0, min(3, rating))
        save()
    }

    public func setResume(_ item: LocalItem, seconds: Double) {
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[idx].resumePosSec = seconds
        items[idx].lastPlayedAt = Date()
        save()
    }

    public func toggleMergedLibrary(_ id: UUID) {
        if mergedLibraryIds.contains(id) { mergedLibraryIds.remove(id) } else { mergedLibraryIds.insert(id) }
        save()
    }

    /// Real bug hit 2026-08-19: trimming on every keystroke (via the live TextField binding)
    /// stripped a just-typed trailing space immediately, making it impossible to type a
    /// multi-word name at all ("Alle " kept snapping back to "Alle" before the next letter
    /// could follow). Store the raw value; `LibraryCard`/`displayName` only check `.isEmpty`
    /// for the fallback decision, which a whitespace-only string still fails harmlessly.
    public func setMergedLibraryName(_ name: String) {
        mergedLibraryName = name
        save()
    }

    public func toggleCompareLibrary(_ id: UUID) {
        if compareLibraryIds.contains(id) { compareLibraryIds.remove(id) } else { compareLibraryIds.insert(id) }
        save()
    }

    /// Dateinamen, die in mindestens 2 der gewählten `compareLibraryIds`-Bibliotheken
    /// vorkommen — reine Dateiname-basierte Erkennung (keine Größe/Hash), gleiche
    /// Konvention wie Android. Berechnet on-demand, nichts wird persistiert.
    public func duplicateFileNames() -> Set<String> {
        guard compareLibraryIds.count >= 2 else { return [] }
        var byName: [String: Set<UUID>] = [:]
        for item in items where compareLibraryIds.contains(item.libraryId) {
            byName[item.fileName, default: []].insert(item.libraryId)
        }
        return Set(byName.filter { $0.value.count >= 2 }.keys)
    }

    /// Alle Items, deren Dateiname doppelt vorkommt — für die Settings-Liste, damit der
    /// User sie direkt sehen (und ggf. eins der Duplikate löschen) kann, ohne erst in
    /// jede betroffene Bibliothek einzeln reinklicken zu müssen.
    public func duplicateItems() -> [LocalItem] {
        let names = duplicateFileNames()
        guard !names.isEmpty else { return [] }
        return items.filter { compareLibraryIds.contains($0.libraryId) && names.contains($0.fileName) }
            .sorted { $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending }
    }

    private struct Index: Codable {
        var libraries: [LocalLibrary]
        var items: [LocalItem]
        var mergedLibraryIds: Set<UUID>?
        var compareLibraryIds: Set<UUID>?
        var mergedLibraryName: String?
    }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let index = try? JSONDecoder().decode(Index.self, from: data) else { return }
        allLibrariesOnDisk = index.libraries
        items = index.items
        mergedLibraryIds = index.mergedLibraryIds ?? []
        compareLibraryIds = index.compareLibraryIds ?? []
        mergedLibraryName = index.mergedLibraryName ?? ""
    }

    /// Persists `allLibrariesOnDisk` (ALL users' libraries), not the filtered `libraries` —
    /// saving the filtered view here would silently delete every other account's local
    /// libraries the next time this user's manager writes to disk.
    private func save() {
        let index = Index(libraries: allLibrariesOnDisk, items: items, mergedLibraryIds: mergedLibraryIds, compareLibraryIds: compareLibraryIds, mergedLibraryName: mergedLibraryName)
        if let data = try? JSONEncoder().encode(index) {
            try? data.write(to: indexURL)
        }
    }
}
