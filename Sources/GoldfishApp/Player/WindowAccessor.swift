#if os(macOS)
import SwiftUI
import AppKit

/// Hands back the hosting `NSWindow` once SwiftUI has actually attached the view to one.
/// Historical note (real bug hit 2026-08-19): the player used to be presented as a `.sheet`
/// on macOS, and a sheet's window does NOT support real `NSWindow.toggleFullScreen` (sheets
/// are attached, modal-style panels; AppKit doesn't offer them the fullscreen collection
/// behavior at all — the fullscreen button silently did nothing). Fixed by making the player
/// a genuine `WindowGroup(id: "player"/"localPlayer")` window instead (see
/// `PlayerLaunchCoordinator`) — `hostWindow` here is now simply that window's own real,
/// fullscreen-capable `NSWindow`, still grabbed via this accessor since SwiftUI only attaches
/// the view to its window asynchronously after the view hierarchy is built.
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
