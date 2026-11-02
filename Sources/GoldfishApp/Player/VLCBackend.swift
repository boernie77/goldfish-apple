#if os(macOS)
import SwiftUI
import AppKit
import VLCKit

/// Fallback-Wiedergabe über libVLC (VLCKit) für Dateien, die AVPlayer nicht abspielen kann
/// (MKV, AV1, DTS …) — statt sie vorher per ffmpeg in eine Cache-Kopie umzuschreiben.
/// Test-Feature (Branch feature/vlc-fallback); per Einstellung abschaltbar
/// (`VLCBackend.enabledKey`), dann greift wieder die bisherige Formatanpassung.
@MainActor
final class VLCBackend {
    static let enabledKey = "goldfish.mac.vlcFallback"
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    struct Track: Identifiable, Hashable {
        let id: Int32
        let name: String
    }

    let player = VLCMediaPlayer()
    /// Zeichenfläche; VLC rendert direkt hinein.
    let view = NSView()

    init(url: URL, startSeconds: Double) {
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        player.drawable = view
        let media = VLCMedia(url: url)
        if startSeconds > 1 { media.addOption(":start-time=\(Int(startSeconds))") }
        player.media = media
    }

    /// Externe Untertitel-Datei (.srt/.ass/…) zuschalten.
    func addSubtitleFile(_ url: URL) {
        _ = player.addPlaybackSlave(url, type: .subtitle, enforce: false)
    }

    /// Untertitel-Dateien neben dem Video: gleicher Basisname (`Film.srt`, `Film.de.srt`, …).
    static func sidecarSubtitles(for videoURL: URL) -> [URL] {
        let dir = videoURL.deletingLastPathComponent()
        let base = videoURL.deletingPathExtension().lastPathComponent
        let exts: Set<String> = ["srt", "ass", "ssa", "vtt", "sub"]
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        return files.filter { exts.contains($0.pathExtension.lowercased()) && $0.deletingPathExtension().lastPathComponent.hasPrefix(base) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func play() { player.play() }
    func pause() { player.pause() }
    func stop() { player.stop() }
    var isPlaying: Bool { player.isPlaying }
    var hasEnded: Bool { player.state == .ended }
    var hasFailed: Bool { player.state == .error }

    var currentSeconds: Double { Double(player.time.intValue) / 1000 }
    var durationSeconds: Double {
        let ms = player.media?.length.intValue ?? 0
        return ms > 0 ? Double(ms) / 1000 : 0
    }
    var videoSize: CGSize { player.videoSize }

    func seek(to seconds: Double) {
        player.time = VLCTime(int: Int32(max(0, seconds) * 1000))
    }

    /// 0...1 → VLC-Lautstärke 0...100 (Systempegel; >100 wäre Übersteuerung).
    func setVolume(_ v: Float) { player.audio?.volume = Int32(max(0, min(1, v)) * 100) }

    var audioTracks: [Track] { Self.tracks(player.audioTrackIndexes, player.audioTrackNames) }
    var subtitleTracks: [Track] { Self.tracks(player.videoSubTitlesIndexes, player.videoSubTitlesNames).filter { $0.id >= 0 } }
    var currentAudioTrack: Int32 {
        get { player.currentAudioTrackIndex }
        set { player.currentAudioTrackIndex = newValue }
    }
    var currentSubtitleTrack: Int32 {
        get { player.currentVideoSubTitleIndex }
        set { player.currentVideoSubTitleIndex = newValue }
    }

    private static func tracks(_ idx: [Any], _ names: [Any]) -> [Track] {
        zip(idx, names).compactMap { i, n in
            guard let num = i as? NSNumber, let name = n as? String else { return nil }
            return Track(id: num.int32Value, name: name)
        }
    }
}

struct VLCVideoSurface: NSViewRepresentable {
    let backend: VLCBackend
    func makeNSView(context: Context) -> NSView { backend.view }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
#endif
