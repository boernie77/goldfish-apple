import Foundation
import AVFoundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

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
    public var resumePosSec: Double = 0
    public var watched = false
    public var thumbnailPath: String?

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
    public func rescanAllLibraries() async {
        for library in libraries {
            await scan(library)
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
                        modifiedTime: values?.contentModificationDate ?? Date()
                    ))
                }
            }
        }

        items.removeAll { $0.libraryId == library.id }
        items.append(contentsOf: found)
        save()

        // Thumbnails happen after the scan reports done (UI already shows titles/sizes) —
        // one at a time in the background so a big library doesn't stall the scan itself.
        let needThumbs = found.filter { $0.thumbnailPath == nil }
        Task { [needThumbs] in
            for item in needThumbs {
                await generateThumbnailIfNeeded(for: item)
            }
        }

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
    public func generateThumbnailIfNeeded(for item: LocalItem) async {
        var url = fileURL(for: item)
        #if os(macOS)
        let convertedURL = LocalTranscodeService.shared.convertedURL(for: item)
        if FileManager.default.fileExists(atPath: convertedURL.path) { url = convertedURL }
        #endif
        guard let url else { return }
        let dest = Self.thumbsDir.appendingPathComponent("\(item.id.uuidString).jpg")
        if FileManager.default.fileExists(atPath: dest.path) {
            setThumbnailPath(item, path: dest.path)
            return
        }

        let asset = AVURLAsset(url: url)
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
            // Leave thumbnailPath nil — card falls back to a placeholder icon. Not worth
            // surfacing per-file (some files are just undecodable, e.g. corrupt downloads).
        }
    }

    private func setThumbnailPath(_ item: LocalItem, path: String) {
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[idx].thumbnailPath = path
        save()
    }

    public func setWatched(_ item: LocalItem, watched: Bool) {
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[idx].watched = watched
        save()
    }

    public func setResume(_ item: LocalItem, seconds: Double) {
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[idx].resumePosSec = seconds
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
