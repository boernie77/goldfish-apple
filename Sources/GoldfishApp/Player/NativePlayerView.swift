import SwiftUI
import AVKit

/// SwiftUI's `VideoPlayer` (AVKit-SwiftUI) crashes on some macOS builds with a Swift
/// runtime metadata-instantiation abort when embedded in a pushed/sheeted view (see
/// crash report 2026-08-17: `_AVKit_SwiftUI` / `PlatformViewRepresentableFeature`).
/// The plain AppKit/UIKit player views are far more battle-tested — wrap those directly
/// instead of going through the SwiftUI convenience view.
// Native chrome (skip buttons, scrubber) turned out unreliable on this macOS build
// (skip-back overlapping other controls, skip-forward missing, scrubber showing
// buffered-progress instead of total duration) — controls are fully custom in
// PlayerControlsBar instead, so this view is just a bare video surface.
#if os(macOS)
struct NativePlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .none
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player { nsView.player = player }
    }

    // AVPlayerView keeps its own strong reference to `player` via `.player = ...` —
    // that reference (NOT the SwiftUI @State one) is what keeps audio/video running.
    // Losing the SwiftUI reference alone does nothing; the view has to be told to let go.
    static func dismantleNSView(_ nsView: AVPlayerView, coordinator: ()) {
        nsView.player?.pause()
        nsView.player = nil
    }
}
#else
struct NativePlayerView: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.player = player
        vc.showsPlaybackControls = false
        return vc
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
        if uiViewController.player !== player { uiViewController.player = player }
    }

    // Same reasoning as the macOS AVPlayerView dismantle above.
    static func dismantleUIViewController(_ uiViewController: AVPlayerViewController, coordinator: ()) {
        uiViewController.player?.pause()
        uiViewController.player = nil
    }
}
#endif
