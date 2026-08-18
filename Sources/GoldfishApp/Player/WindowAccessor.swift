#if os(macOS)
import SwiftUI
import AppKit

/// Hands back the hosting `NSWindow` once SwiftUI has actually attached the view to one —
/// needed because the player is presented as a `.sheet` on macOS (`fullScreenCoverCompat`),
/// and a sheet's window does NOT support real `NSWindow.toggleFullScreen` (sheets are
/// attached, modal-style panels; AppKit doesn't offer them the fullscreen collection
/// behavior at all — real bug hit 2026-08-19: the fullscreen button silently did nothing).
/// Grabbing the actual window lets the fullscreen button instead resize/reposition that
/// specific window directly (see `PlayerView.toggleFullScreen`), which works regardless of
/// whether it's a sheet or a normal window.
struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window { onResolve(window) }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let window = nsView.window { onResolve(window) }
    }
}
#endif
