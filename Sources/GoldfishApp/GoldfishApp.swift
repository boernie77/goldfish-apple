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
        // Bugfix 2026-08-20 (User: "es öffnen sich manchmal mehrere Player ... es darf immer
        // nur ein Player offen sein"): `WindowGroup` ist per Design für MEHRERE gleichzeitige
        // Instanzen gedacht (wie Dokumentfenster) — jeder `openWindow(id: "player")`-Aufruf
        // (vier Call-Sites: ItemDetailView, LibrariesView, ItemGridView,
        // LocalLibraryItemsView) erzeugte deshalb ein GANZ NEUES Fenster, auch wenn schon
        // eines offen war (z.B. Doppelklick, schnelles Play in zwei Ansichten). `Window`
        // (Singular, seit macOS 13 verfügbar — Deployment-Target dieser App) ist dagegen
        // waschecht Single-Instance: ein erneuter `openWindow(id:)`-Aufruf bei bereits
        // offenem Fenster bringt es nur nach vorne, statt ein zweites zu öffnen. Der Inhalt
        // bleibt trotzdem reaktiv — `pendingPlayer` ist weiterhin `@Published`, ein neuer
        // Request lässt die Scene-Closure neu evaluieren, `.id(request.id)` erzwingt einen
        // frischen `PlayerView` (neuer `@State`) für das neue Item im SELBEN Fenster.
        // Bugfix 2026-08-20 (User: "jetzt kann ich das Fenster nicht mehr vergrößern"):
        // `Window`-Szenen sind, anders als `WindowGroup`, standardmäßig NICHT frei
        // größenveränderlich — ohne dieses explizite Modifier klemmt SwiftUI die Fenstergröße
        // an die Content-Ideal-Größe fest. `.contentMinSize` erlaubt Vergrößern beliebig nach
        // oben, Verkleinern nur bis zum `.frame(minWidth:minHeight:)` unten. Gilt PRO Scene,
        // deshalb an beiden `Window`-Blöcken einzeln (nicht nur am letzten).
        Window("Player", id: "player") {
            if let request = playerLaunch.pendingPlayer {
                PlayerView(item: request.item, queue: request.queue, queueIndex: request.queueIndex, randomContext: request.randomContext, startFromBeginning: request.startFromBeginning)
                    .environmentObject(client)
                    .environmentObject(downloads)
                    .environmentObject(transcode)
                    .frame(minWidth: 900, minHeight: 560)
                    .id(request.id)
            }
        }
        .windowResizability(.contentMinSize)

        Window("Lokaler Player", id: "localPlayer") {
            if let request = playerLaunch.pendingLocalPlayer {
                LocalPlayerView(item: request.item, queue: request.queue, randomPool: request.randomPool)
                    .environmentObject(localLibrary)
                    .environmentObject(transcode)
                    .frame(minWidth: 900, minHeight: 560)
                    .id(request.id)
            }
        }
        .windowResizability(.contentMinSize)
        #endif
    }
}
