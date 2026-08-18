import Foundation
#if canImport(Combine)
import Combine
#endif

public struct DownloadRecord: Codable, Identifiable, Equatable {
    public let itemId: Int64
    public let title: String
    public let fileName: String
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
        self.session = URLSession(configuration: config, delegate: self, delegateQueue: nil)

        loadIndex()

        // A stored bookmark can resolve without throwing (`resolveBookmarkedDirectory`
        // above) yet still not be genuinely writable — e.g. after switching this build
        // from ad-hoc to a real Team signature, real bug hit 2026-08-19: downloads failed
        // deep into `didFinishDownloadingTo` with "couldn't be moved… folder doesn't
        // exist" instead of failing fast and falling back. Validate for real right at
        // launch instead of waiting for the first download to hit it mid-transfer.
        ensureWritableDownloadsDir()
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

        let task = session.downloadTask(with: remoteURL)
        task.taskDescription = String(item.id)
        tasks[item.id] = task
        task.resume()
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
        removeRecord(itemId: itemId)
        saveIndex()
    }

    public func deleteDownload(itemId: Int64) {
        if let url = localFileURL(itemId: itemId) {
            try? FileManager.default.removeItem(at: url)
        }
        removeRecord(itemId: itemId)
        saveIndex()
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
        }
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
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let idStr = task.taskDescription, let itemId = Int64(idStr), let error else { return }
        Task { @MainActor in
            guard var rec = self.records[itemId] else { return }
            if (error as NSError).code != NSURLErrorCancelled {
                rec.state = .failed
                rec.errorMessage = error.localizedDescription
                self.setRecord(rec)
                self.saveIndex()
            }
            self.tasks[itemId] = nil
        }
    }
}
