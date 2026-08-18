import SwiftUI
import AVKit
import GoldfishCore
#if os(macOS)
import AppKit
#endif

/// Plays a local file directly — no server involved, no transcode-seek complexity
/// (progressive local file, AVPlayer seeks anywhere instantly).
struct LocalPlayerView: View {
    /// Sibling items from the list this was opened from — powers ⏮/⏭. Empty/absent when
    /// opened standalone (no prev/next shown), same convention as the server `PlayerView`.
    let queue: [LocalItem]
    /// Non-nil when opened via the 🔀 Zufällig button — ⏭ then keeps drawing a fresh random
    /// item from this pool instead of walking `queue` in order (mirrors `PlayerView`'s
    /// `RandomContext`/`randomHistory`, just without a network round-trip since local items
    /// are already all in memory).
    let randomPool: [LocalItem]?

    @State private var item: LocalItem
    @State private var queueIndex: Int
    @State private var randomHistory: [LocalItem] = []
    @State private var randomHistoryIndex = 0

    @EnvironmentObject var localLibrary: LocalLibraryManager
    #if !os(macOS)
    @Environment(\.dismiss) private var dismiss
    #endif

    @State private var player: AVPlayer?
    @State private var errorMessage: String?
    @State private var resumeTimer: Timer?

    @State private var isPlaying = false
    @State private var currentTime: Double = 0
    @State private var duration: Double = 0
    @State private var isScrubbing = false
    @State private var volume: Float = 1.0
    @State private var timeObserverToken: Any?

    @State private var controlsVisible = true
    @State private var hideControlsTask: Task<Void, Never>?
    /// Real rendered frame size — mirrors `PlayerView`'s same-named state (User-Anfrage
    /// 2026-08-19: Auflösungsanzeige solange die Steuerleiste eingeblendet ist).
    @State private var currentResolutionLabel: String?
    // Surfaces the ACTUAL underlying NSError when AVFoundation can't play a file — AVKit's
    // own glyph for this is a silent gray "can't play" icon with no text at all.
    @State private var diagnosticError: String?
    #if os(macOS)
    @EnvironmentObject var transcode: LocalTranscodeService
    @State private var isConverting = false
    @State private var isFullScreen = false
    @State private var hostWindow: NSWindow?
    #endif

    init(item: LocalItem, queue: [LocalItem] = [], randomPool: [LocalItem]? = nil) {
        _item = State(initialValue: item)
        self.queue = queue
        self.randomPool = randomPool
        _queueIndex = State(initialValue: queue.firstIndex(where: { $0.id == item.id }) ?? 0)
        _randomHistory = State(initialValue: randomPool != nil ? [item] : [])
    }

    private var hasPrev: Bool {
        randomPool != nil ? randomHistoryIndex > 0 : (!queue.isEmpty && queueIndex > 0)
    }
    private var hasNext: Bool {
        (randomPool?.isEmpty == false) || (!queue.isEmpty && queueIndex < queue.count - 1)
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
                    ProgressView(value: transcode.progress["local-\(item.id.uuidString)"] ?? 0).frame(maxWidth: 260).tint(.white)
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

            if let diagnosticError {
                VStack {
                    Text(diagnosticError)
                        .font(.caption)
                        .foregroundStyle(.white)
                        .padding(8)
                        .background(.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 8))
                        .padding(.top, 60)
                        .padding(.horizontal)
                    Spacer()
                }
            }

            VStack {
                Color.clear.frame(height: 1).padding(.top, 28)
                Spacer()
                if player != nil {
                    // Same fix as `PlayerView` — see that file's comment for why a `ZStack`
                    // (keeps the control bar exactly centered) replaced the previous
                    // single-Spacer `HStack` (shifted the whole pair off-center).
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

                        LocalPlayerControlsBar(
                            isPlaying: $isPlaying,
                            currentTime: $currentTime,
                            duration: duration,
                            isScrubbing: $isScrubbing,
                            volume: $volume,
                            hasPrev: hasPrev,
                            hasNext: hasNext,
                            onTogglePlay: { togglePlay(); resetAutoHide() },
                            onSkip: { seek(to: currentTime + $0); resetAutoHide() },
                            onScrubEnd: { seek(to: $0); resetAutoHide() },
                            onVolumeChange: { player?.volume = $0; resetAutoHide() },
                            onPrev: { jump(by: -1) },
                            onNext: { jump(by: 1) },
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
            teardown()
        }
    }

    private func toggleControlsVisibility() {
        controlsVisible.toggle()
        if controlsVisible { resetAutoHide() } else { hideControlsTask?.cancel() }
    }

    #if os(macOS)
    /// Same fix as `PlayerView.toggleFullScreen` — the player is now a genuine
    /// `WindowGroup(id: "localPlayer")` window, so `hostWindow` is simply ITS OWN
    /// fullscreen-capable window.
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
    #endif

    private func closePlayer() {
        #if os(macOS)
        // Same fix as PlayerView.closePlayer() — see its doc comment (2026-08-19).
        PlayerLaunchCoordinator.shared.pendingLocalPlayer = nil
        hostWindow?.close()
        #else
        dismiss()
        #endif
    }

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

    private func resetAutoHide() {
        controlsVisible = true
        hideControlsTask?.cancel()
        hideControlsTask = Task {
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            guard !Task.isCancelled, isPlaying else { return }
            controlsVisible = false
        }
    }

    private func jump(by delta: Int) {
        if let randomPool, !randomPool.isEmpty {
            if delta < 0 {
                let newIndex = randomHistoryIndex - 1
                guard randomHistory.indices.contains(newIndex) else { return }
                teardown()
                randomHistoryIndex = newIndex
                item = randomHistory[newIndex]
                return
            }
            if randomHistoryIndex + 1 < randomHistory.count {
                teardown()
                randomHistoryIndex += 1
                item = randomHistory[randomHistoryIndex]
                return
            }
            // Avoid immediately repeating the same item when the pool has more than one entry.
            var next = randomPool.randomElement()!
            if randomPool.count > 1 {
                while next.id == item.id { next = randomPool.randomElement()! }
            }
            teardown()
            randomHistory.append(next)
            randomHistoryIndex = randomHistory.count - 1
            item = next
            return
        }
        let newIndex = queueIndex + delta
        guard queue.indices.contains(newIndex) else { return }
        teardown()
        queueIndex = newIndex
        item = queue[newIndex]
    }

    private func setUp() async {
        errorMessage = nil
        currentTime = 0
        duration = 0
        diagnosticError = nil
        currentResolutionLabel = nil
        guard let sourceURL = localLibrary.fileURL(for: item) else {
            errorMessage = "Datei nicht gefunden — Ordnerzugriff evtl. verloren."
            return
        }

        var playURL = sourceURL
        #if os(macOS)
        if transcode.isConverted(item) {
            playURL = transcode.convertedURL(for: item)
        } else {
            // Read-permission failures (TCC, revoked bookmark, …) don't throw synchronously —
            // AVPlayer just sits there and AVKit shows its own silent "can't play" glyph.
            // Explicitly probing the asset here also catches genuinely unplayable formats
            // (MKV container, DTS/AC3 audio, …) BEFORE handing anything to AVPlayer, so we
            // can remux instead of showing a dead player (real case hit 2026-08-19: H.264
            // video + DTS audio in an .mkv — AVFoundation reads the file fine, just can't
            // decode the audio track, `asset.load(.isPlayable)` returns false, no thrown error).
            let playable = (try? await AVURLAsset(url: sourceURL).load(.isPlayable)) ?? false
            if !playable {
                isConverting = true
                do {
                    playURL = try await transcode.remux(item: item, sourceURL: sourceURL)
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
        player = p
        isPlaying = true
        p.volume = volume

        timeObserverToken = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak p] time in
            guard !isScrubbing, let p else { return }
            currentTime = time.seconds
            if duration <= 0, let d = p.currentItem?.duration.seconds, d.isFinite, d > 0 { duration = d }
            isPlaying = p.timeControlStatus == .playing
            if let size = p.currentItem?.presentationSize, size.width > 0, size.height > 0 {
                currentResolutionLabel = Self.resolutionLabel(for: size)
            }
        }

        if item.resumePosSec > 5 {
            await p.seek(to: CMTime(seconds: item.resumePosSec, preferredTimescale: 600))
        }
        p.play()
        resetAutoHide()

        resumeTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
            Task { @MainActor in saveResume() }
        }
    }

    private func teardown() {
        resumeTimer?.invalidate()
        resumeTimer = nil
        if let token = timeObserverToken, let player { player.removeTimeObserver(token) }
        timeObserverToken = nil
        if let player {
            let seconds = player.currentTime().seconds
            player.pause()
            if seconds.isFinite {
                if duration > 0, seconds >= duration * 0.9 {
                    localLibrary.setWatched(item, watched: true)
                    localLibrary.setResume(item, seconds: 0)
                } else if seconds > 0 {
                    localLibrary.setResume(item, seconds: seconds)
                }
            }
        }
        self.player = nil
    }

    private func togglePlay() {
        guard let player else { return }
        if player.timeControlStatus == .playing { player.pause() } else { player.play() }
    }

    private func seek(to target: Double) {
        guard let player else { return }
        let clamped = duration > 0 ? max(0, min(target, duration)) : max(0, target)
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600))
        currentTime = clamped
    }

    private func saveResume() {
        guard let player else { return }
        let seconds = player.currentTime().seconds
        guard seconds.isFinite, seconds > 0 else { return }
        localLibrary.setResume(item, seconds: seconds)
    }

    /// Same bucket formula as `Item.resolutionLabel`/`PlayerView.resolutionLabel(for:)`.
    private static func resolutionLabel(for size: CGSize) -> String {
        let effective = max(Double(size.height), Double(size.width) * 9.0 / 16.0)
        switch effective {
        case 2000...: return "4K"
        case 1000..<2000: return "1080p"
        case 700..<1000: return "720p"
        default: return "\(Int(effective))p"
        }
    }
}

private struct LocalPlayerControlsBar: View {
    @Binding var isPlaying: Bool
    @Binding var currentTime: Double
    let duration: Double
    @Binding var isScrubbing: Bool
    @Binding var volume: Float
    let hasPrev: Bool
    let hasNext: Bool
    let onTogglePlay: () -> Void
    let onSkip: (Double) -> Void
    let onScrubEnd: (Double) -> Void
    let onVolumeChange: (Float) -> Void
    let onPrev: () -> Void
    let onNext: () -> Void
    var isFullScreen: Bool = false
    var onToggleFullScreen: (() -> Void)? = nil
    var onClose: (() -> Void)? = nil

    @State private var scrubValue: Double = 0
    @State private var volumeBeforeMute: Float = 1.0

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                Text(formatTime(isScrubbing ? scrubValue : currentTime))
                Slider(
                    value: Binding(get: { isScrubbing ? scrubValue : currentTime }, set: { scrubValue = $0 }),
                    in: 0...max(duration, 1),
                    onEditingChanged: { editing in
                        if editing { isScrubbing = true; scrubValue = currentTime }
                        else { onScrubEnd(scrubValue); isScrubbing = false }
                    }
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
                            if volume > 0 { volumeBeforeMute = volume; volume = 0 }
                            else { volume = volumeBeforeMute > 0 ? volumeBeforeMute : 1 }
                            onVolumeChange(volume)
                        } label: {
                            Image(systemName: volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill").font(.caption)
                        }
                        .buttonStyle(.plain)
                        Slider(value: Binding(get: { volume }, set: { volume = $0; onVolumeChange($0) }), in: 0...1)
                            .frame(width: 60)
                    }
                }
                .foregroundStyle(.white)

                Spacer(minLength: 12)
                HStack(spacing: 18) {
                    Button(action: onPrev) { Image(systemName: "backward.end.fill") }
                        .disabled(!hasPrev)
                        .opacity(hasPrev ? 1 : 0.35)
                    Button { onSkip(-15) } label: { Image(systemName: "gobackward.15") }
                    Button(action: onTogglePlay) {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill").font(.title3)
                    }
                    Button { onSkip(15) } label: { Image(systemName: "goforward.15") }
                    Button(action: onNext) { Image(systemName: "forward.end.fill") }
                        .disabled(!hasNext)
                        .opacity(hasNext ? 1 : 0.35)
                }
                Spacer(minLength: 12)
                if let onToggleFullScreen {
                    Button(action: onToggleFullScreen) {
                        Image(systemName: isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    }
                    .frame(width: 64, alignment: .trailing)
                } else {
                    Color.clear.frame(width: 64)
                }
            }
            .foregroundStyle(.white)
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 440)
        .padding(.horizontal, 40)
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
