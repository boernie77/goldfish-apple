import SwiftUI
import GoldfishCore

@main
struct GoldfishApp: App {
    @StateObject private var client = GoldfishClient.shared
    @StateObject private var downloads = DownloadManager.shared
    @StateObject private var localLibrary = LocalLibraryManager.shared
    @StateObject private var shuffleScope = ShuffleScope.shared
    #if os(macOS)
    @StateObject private var transcode = LocalTranscodeService.shared
    @StateObject private var playerLaunch = PlayerLaunchCoordinator.shared
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(client)
                .environmentObject(downloads)
                .environmentObject(localLibrary)
                .environmentObject(shuffleScope)
                #if os(macOS)
                .environmentObject(transcode)
                #endif
        }

        // Real bug hit 2026-08-19: the player was presented as a `.sheet` on macOS, and
        // sheets can't reliably support fullscreen no matter how it's approached (see
        // `PlayerLaunchCoordinator`'s doc comment for the four failed attempts) — these are
        // genuine, separate top-level windows instead, which support `toggleFullScreen`
        // natively. Opened via `openWindow(id:)` from each call site's `#if os(macOS)`
        // branch; closed via `hostWindow?.close()` from within the player (`\.dismissWindow`
        // would be the SwiftUI-native way, but needs macOS 14 — this app targets 13).
        #if os(macOS)
        WindowGroup(id: "player") {
            if let request = playerLaunch.pendingPlayer {
                PlayerView(item: request.item, queue: request.queue, queueIndex: request.queueIndex, randomContext: request.randomContext, startFromBeginning: request.startFromBeginning)
                    .environmentObject(client)
                    .environmentObject(downloads)
                    .environmentObject(transcode)
                    .frame(minWidth: 900, minHeight: 560)
                    .id(request.id)
            }
        }

        WindowGroup(id: "localPlayer") {
            if let request = playerLaunch.pendingLocalPlayer {
                LocalPlayerView(item: request.item, queue: request.queue, randomPool: request.randomPool)
                    .environmentObject(localLibrary)
                    .environmentObject(transcode)
                    .frame(minWidth: 900, minHeight: 560)
                    .id(request.id)
            }
        }
        #endif
    }
}
