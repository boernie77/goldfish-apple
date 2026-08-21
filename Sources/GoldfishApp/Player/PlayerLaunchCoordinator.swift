#if os(macOS)
import SwiftUI
import GoldfishCore

/// Holds the pending player-presentation request for the macOS `WindowGroup(id: "player"/
/// "localPlayer")` scenes — real bug hit 2026-08-19: FOUR separate attempts to make a
/// `.sheet`-presented player support real fullscreen all failed in a row (resize the sheet's
/// own window, target `sheetParent`, cache the main window ahead of time, look the main
/// window up fresh at click time). Sheets in AppKit have deep-seated fullscreen limitations
/// that no amount of `NSWindow` poking from inside a sheet's content reliably works around —
/// the only fix that's actually guaranteed to work is presenting the player in a genuine,
/// separate, non-sheet window, which supports `toggleFullScreen` natively with zero
/// workaround needed. `RandomContext`/`[Item]`/`[LocalItem]` aren't easily `Codable` in a way
/// that's worth wiring through SwiftUI's `openWindow(value:)`, so this coordinator just holds
/// the live Swift values directly instead — `openWindow(id:)` (no value) opens/focuses the
/// scene, which then reads whatever's currently `pending` here.
@MainActor
final class PlayerLaunchCoordinator: ObservableObject {
    static let shared = PlayerLaunchCoordinator()
    @Published var pendingPlayer: PlayerLaunchRequest?
    @Published var pendingLocalPlayer: LocalPlayerLaunchRequest?
    /// Set by `PlayerView`/`LocalPlayerView`'s `WindowAccessor` once their window resolves,
    /// cleared on close (both the programmatic `closePlayer()` path AND a direct click on the
    /// native red close button, via `NSWindow.willCloseNotification`). Real bug hit
    /// 2026-08-20 (User: "es öffnen sich manchmal mehrere Player ... der zweite ist dabei
    /// nicht sichtbar"): relying on the `WindowGroup`/`Window` scene type alone to prevent a
    /// second window (tried both) wasn't reliable — a fast second `openWindow(id:)` call
    /// (e.g. double-click, or two different views triggering playback almost simultaneously)
    /// could still race a second window into existence. Checking these directly before ever
    /// calling `openWindow` sidesteps that race entirely: no window yet known → open one; one
    /// already known → just update `pendingPlayer` (the existing window's content re-renders
    /// reactively) and bring that SAME window to front instead of opening another.
    weak var playerWindow: NSWindow?
    weak var localPlayerWindow: NSWindow?

    private init() {}

    func present(_ request: PlayerLaunchRequest, openWindow: OpenWindowAction) {
        pendingPlayer = request
        if let existing = playerWindow {
            existing.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: "player")
        }
    }

    func present(_ request: LocalPlayerLaunchRequest, openWindow: OpenWindowAction) {
        pendingLocalPlayer = request
        if let existing = localPlayerWindow {
            existing.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: "localPlayer")
        }
    }
}

struct PlayerLaunchRequest: Identifiable {
    let id = UUID()
    let item: Item
    let queue: [Item]
    let queueIndex: Int?
    let randomContext: RandomContext?
    let startFromBeginning: Bool
}

struct LocalPlayerLaunchRequest: Identifiable {
    let id = UUID()
    let item: LocalItem
    let queue: [LocalItem]
    let randomPool: [LocalItem]?
}
#endif
