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
    private init() {}
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
