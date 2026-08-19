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

        public var errorDescription: String? {
            switch self {
            case .ffmpegNotFound:
                return "ffmpeg wurde nicht gefunden. Bitte installieren, z.B. mit \"brew install ffmpeg\"."
            case .processFailed(let detail):
                return "Konvertierung fehlgeschlagen: \(detail)"
            }
        }
    }

    /// 0...1 while a conversion is running, keyed by the same cache key as `convertedURL(cacheKey:)`.
    @Published public private(set) var progress: [String: Double] = [:]

    // MARK: - Background queue (auto-convert after each scan, see `enqueueCompatibilityCheck`)
    // Local-library-specific — downloaded server items (see `remuxDownload` below) are
    // converted on-demand at play time instead, since there's no library scan to hook into.

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
    /// Same persisted-failure tracking as `failedItems`, but for downloaded server items
    /// (keyed by server item ID, not a local UUID) — needed so "erneut prüfen" can retry
    /// downloads too, not just local-library files.
    @Published public private(set) var downloadFailedItems: [Int64: String] = [:] {
        didSet {
            let encoded = Dictionary(uniqueKeysWithValues: downloadFailedItems.map { (String($0.key), $0.value) })
            if let data = try? JSONEncoder().encode(encoded) {
                UserDefaults.standard.set(data, forKey: Self.downloadFailedItemsKey)
            }
        }
    }
    /// Title of the download currently being retried by `rescanDownloads` — nil when idle.
    @Published public private(set) var currentDownloadTitle: String?
    /// Companion to `currentDownloadTitle` — User-Anfrage 2026-08-19: "bei der
    /// Formatanpassung fehlt der Fortschrittsbalken" für Downloads. The local-item path already
    /// showed one by keying `progress["local-<uuid>"]` off `currentItem.id`; the download path
    /// only ever exposed the title, nothing to key `progress["dl-<itemId>"]` off. Added so
    /// Settings can show the exact same `ProgressView` for downloads too.
    @Published public private(set) var currentDownloadItemId: Int64?
    /// Downloads waiting their turn — analog zu `queuedItems` für lokale Bibliotheken.
    /// User-Anfrage 2026-08-19: "kannst du die Warteschlange für Downloads mit einbauen?".
    @Published public private(set) var queuedDownloads: [DownloadRecord] = []
    private static let failedItemsKey = "goldfish.transcode.failedItems"
    private static let downloadFailedItemsKey = "goldfish.transcode.downloadFailedItems"
    private var isProcessingQueue = false
    private var isProcessingDownloads = false

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
        if let data = UserDefaults.standard.data(forKey: Self.downloadFailedItemsKey),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            downloadFailedItems = Dictionary(uniqueKeysWithValues: decoded.compactMap { key, value in
                Int64(key).map { ($0, value) }
            })
        }
        Self.purgeStaleCacheIfNeeded()
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
    /// pass the caller's own visible local-item UUIDs and download item IDs (both already
    /// per-user-filtered by `LocalLibraryManager`/`DownloadManager`) to cross-reference against
    /// the cache filenames' `local-<uuid>`/`dl-<itemId>` prefixes.
    public func scopedCompletedCount(ownedLocalItemIds: Set<UUID>, ownedDownloadItemIds: Set<Int64>) -> Int {
        cacheFileNames().filter { name in
            if name.hasPrefix("local-"), let uuid = UUID(uuidString: String(name.dropFirst("local-".count))) {
                return ownedLocalItemIds.contains(uuid)
            }
            if name.hasPrefix("dl-"), let itemId = Int64(name.dropFirst("dl-".count)) {
                return ownedDownloadItemIds.contains(itemId)
            }
            return false
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

    public func convertedDownloadURL(itemId: Int64) -> URL {
        convertedURL(cacheKey: "dl-\(itemId)")
    }

    public func isDownloadConverted(itemId: Int64) -> Bool {
        isConverted(cacheKey: "dl-\(itemId)")
    }

    /// Same probe-and-fix logic as `remux(item:sourceURL:)`, for a downloaded server item
    /// instead of a local-library one — used by `PlayerView`'s offline playback branch.
    public func remuxDownload(itemId: Int64, sourceURL: URL) async throws -> URL {
        try await remux(cacheKey: "dl-\(itemId)", sourceURL: sourceURL)
    }

    /// Probe-and-fix für EINEN frisch abgeschlossenen Download — User-Anfrage 2026-08-19:
    /// "Auch nach einem Download soll die Formatanpassung automatisch starten". Bisher lief
    /// der Fix für Downloads nur on-demand beim ersten Abspielversuch oder über den
    /// manuellen "Erneut prüfen"-Button (`rescanDownloads`); dieser Pfad hier ist der
    /// Einzel-Item-Aufruf direkt nach `DownloadManager`s `didFinishDownloadingTo`. Gleiches
    /// State-Tracking wie `rescanDownloads` (downloadFailedItems + refreshCompletedCount),
    /// damit die Formatanpassung-Anzeige in den Einstellungen konsistent bleibt, egal ob der
    /// Fix über den Bulk-Retry oder automatisch nach einem einzelnen Download lief.
    public func autoConvertDownloadIfNeeded(itemId: Int64, sourceURL: URL) async {
        guard !isDownloadConverted(itemId: itemId) else { return }
        let playable = (try? await AVURLAsset(url: sourceURL).load(.isPlayable)) ?? true
        guard !playable else { return }
        do {
            _ = try await remuxDownload(itemId: itemId, sourceURL: sourceURL)
            refreshCompletedCount()
            downloadFailedItems[itemId] = nil
        } catch {
            downloadFailedItems[itemId] = error.localizedDescription
        }
    }

    /// Called once per scan (`LocalLibraryManager.scan`) — probes each new/unconverted item
    /// for native playability and queues the incompatible ones for background conversion, so
    /// the fix happens ahead of time instead of the user hitting a dead player on first play.
    public func enqueueCompatibilityCheck(items: [LocalItem], fileURLProvider: @escaping @MainActor (LocalItem) -> URL?) {
        Task {
            for item in items {
                guard !isConverted(item), !queuedItems.contains(where: { $0.id == item.id }), currentItem?.id != item.id else { continue }
                guard let url = fileURLProvider(item) else { continue }
                let playable = (try? await AVURLAsset(url: url).load(.isPlayable)) ?? true
                if !playable {
                    queuedItems.append(item)
                }
            }
            processQueue(fileURLProvider: fileURLProvider)
        }
    }

    private func processQueue(fileURLProvider: @escaping @MainActor (LocalItem) -> URL?) {
        guard !isProcessingQueue else { return }
        isProcessingQueue = true
        Task {
            while !queuedItems.isEmpty {
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

    /// Probes all finished downloads for native playability and retries the ffmpeg fix for
    /// any that aren't converted yet — the equivalent of `enqueueCompatibilityCheck` for
    /// local-library items, but for downloaded server files. Real gap hit 2026-08-19: the
    /// "Alle lokalen Bibliotheken erneut prüfen" button only iterated `LocalLibraryManager`'s
    /// libraries, so a downloaded file that failed conversion (e.g. the `af#0:1` bug above)
    /// stayed broken forever with no way to retry short of deleting the download and
    /// re-downloading it. `records`/`fileURLProvider` are passed in rather than referencing
    /// `DownloadManager` directly to avoid a package-level dependency cycle (`DownloadManager`
    /// lives in this same module already, but keeping the same call shape as
    /// `enqueueCompatibilityCheck` here for consistency).
    public func rescanDownloads(records: [DownloadRecord], fileURLProvider: @escaping @MainActor (Int64) -> URL?) {
        guard !isProcessingDownloads else { return }
        isProcessingDownloads = true
        Task {
            // Zwei Phasen wie `enqueueCompatibilityCheck`/`processQueue` für lokale
            // Bibliotheken: erst alle wirklich inkompatiblen Downloads ermitteln (async
            // Playability-Probe) und als sichtbare Warteschlange publishen, DANN abarbeiten
            // — vorher gab es hier gar keine Zwischen-Liste, nur das aktuell laufende Item.
            var pending: [DownloadRecord] = []
            for rec in records where rec.state == .done {
                guard !isDownloadConverted(itemId: rec.itemId) else { continue }
                guard let url = fileURLProvider(rec.itemId) else { continue }
                let playable = (try? await AVURLAsset(url: url).load(.isPlayable)) ?? true
                guard !playable else { continue }
                pending.append(rec)
            }
            queuedDownloads = pending
            while !queuedDownloads.isEmpty {
                let rec = queuedDownloads.removeFirst()
                guard let url = fileURLProvider(rec.itemId) else { continue }
                currentDownloadTitle = rec.title
                currentDownloadItemId = rec.itemId
                do {
                    _ = try await remuxDownload(itemId: rec.itemId, sourceURL: url)
                    refreshCompletedCount()
                    downloadFailedItems[rec.itemId] = nil
                } catch {
                    downloadFailedItems[rec.itemId] = error.localizedDescription
                }
            }
            currentDownloadTitle = nil
            currentDownloadItemId = nil
            isProcessingDownloads = false
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
        if FileManager.default.fileExists(atPath: dest.path) { return dest }

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
        // only touch the audio at all if it's actually something AVFoundation can't play
        // (i.e. not already `aac`); otherwise `-c:a copy`, no filter graph involved whatsoever.
        let audioCodec = await Self.probeAudioCodec(sourceURL: sourceURL)
        let audioArgs: [String]
        if audioCodec == "aac" {
            audioArgs = ["-c:a", "copy"]
        } else {
            audioArgs = ["-c:a", "aac", "-ac", "2", "-channel_layout", "stereo", "-b:a", "192k"]
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

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ffmpegPath)
            // -c:v copy: no re-encode, just repackage — this is what keeps it fast (seconds,
            // not the movie's runtime). Audio alone gets transcoded since that's the actual
            // incompatibility (DTS/AC3 → AAC); +faststart moves the moov atom to the front
            // so AVPlayer can start playback before the whole file is fully written/read.
            // `-map 0:v:0 -map 0:a:0`: explicitly select only the FIRST video and FIRST audio
            // stream. Real bug hit 2026-08-19: without an explicit `-map`, ffmpeg's automatic
            // stream selection mapped BOTH audio tracks on dual-language sources (error showed
            // "af#0:1" — the audio filter graph's SECOND output stream), and the channel-count
            // probe above only ever checked stream `a:0`, so the `pan` filter got applied to a
            // second stream it wasn't validated against, failing with "Invalid argument"
            // instantly. Restricting to one video + one audio stream removes the ambiguity
            // entirely (any secondary audio/subtitle tracks are simply dropped).
            process.arguments = ["-y", "-i", sourceURL.path, "-map", "0:v:0", "-map", "0:a:0"] + videoArgs + audioArgs + ["-movflags", "+faststart", tmp.path]
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
            process.terminationHandler = { proc in
                errPipe.fileHandleForReading.readabilityHandler = nil
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
        return dest
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

    /// Codec name of the first audio stream (e.g. "aac", "dts"), or nil if unavailable.
    private static func probeAudioCodec(sourceURL: URL) async -> String? {
        guard let ffprobePath = findFFprobe() else { return nil }
        return await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ffprobePath)
            process.arguments = [
                "-v", "error", "-select_streams", "a:0",
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
