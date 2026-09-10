import SwiftUI
import GoldfishCore
#if os(iOS)
import AVFoundation
#endif

@main
struct GoldfishApp: App {
    #if os(iOS)
    // Ohne explizite AVAudioSession-Konfiguration überließ die App iOS
    // komplett sich selbst, wie sie Medien-Audio behandelt — je nach
    // Systemzustand (u.a. der physische Klingelton-/Stumm-Schalter) blieb
    // die Wiedergabe dadurch stumm. `.playback` ist exakt die Kategorie,
    // die jede Video-/Audio-App hier setzt: ignoriert den Stumm-Schalter
    // (Medienwiedergabe soll hörbar sein, das ist der ganze Zweck der App),
    // routet über Lautsprecher/verbundene Kopfhörer/AirPlay. tvOS/macOS
    // brauchen das nicht (kein Stumm-Schalter, System-Standardverhalten
    // reicht dort bereits aus — auf beiden Plattformen bislang nie
    // gemeldet). User-Report 2026-09-10: "Ich habe auf dem iPhone keinen
    // Ton!", direkt nach dem allerersten Geräte-Test der iOS-App in dieser
    // Session — kein Hinweis, dass es vorher je funktioniert hätte.
    init() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("[audio] AVAudioSession-Konfiguration fehlgeschlagen: \(error)")
        }
    }
    #endif
    @StateObject private var client = GoldfishClient.shared
    @StateObject private var downloads = DownloadManager.shared
    @StateObject private var localLibrary = LocalLibraryManager.shared
    @StateObject private var shuffleScope = ShuffleScope.shared
    @StateObject private var lastLibraryContext = LastLibraryContext.shared
    // User-Anfrage 2026-09-02: Dark-Mode-Wahlschalter im Settings-Menü — hier auf App-Ebene
    // angewendet, damit er ausnahmslos jede Szene trifft (Haupt-Fenster UND die separaten
    // Player-`WindowGroup`s auf macOS).
    @AppStorage(AppAppearance.storageKey) private var appearanceRaw: String = AppAppearance.system.rawValue
    private var preferredColorScheme: ColorScheme? { AppAppearance(rawValue: appearanceRaw)?.colorScheme }
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
                .environmentObject(lastLibraryContext)
                #if os(macOS)
                .environmentObject(transcode)
                #endif
                .preferredColorScheme(preferredColorScheme)
        }

        // Real bug hit 2026-08-19: the player was presented as a `.sheet` on macOS, and
        // sheets can't reliably support fullscreen no matter how it's approached (see
        // `PlayerLaunchCoordinator`'s doc comment for the four failed attempts) — these are
        // genuine, separate top-level windows instead, which support `toggleFullScreen`
        // natively. Opened via `openWindow(id:)` from each call site's `#if os(macOS)`
        // branch; closed via `hostWindow?.close()` from within the player (`\.dismissWindow`
        // would be the SwiftUI-native way, but needs macOS 14 — this app targets 13).
        #if os(macOS)
        // Bugfix-Historie 2026-08-20: `Window` (Singular) statt `WindowGroup` wurde hier
        // testweise eingesetzt, um doppelte Player-Fenster zu verhindern — brach dabei aber
        // sowohl freie Größenänderung als auch den Vollbild-Button (beides trotz
        // `.windowResizability`/erzwungenem `styleMask`/`collectionBehavior` nicht behebbar).
        // Zurück auf `WindowGroup` (bekannt funktionierendes Verhalten für Resize/Vollbild).
        // Die eigentliche "nur ein Player"-Regel wird jetzt NICHT mehr dem Scene-Typ
        // überlassen, sondern explizit in `PlayerLaunchCoordinator.present(...)` erzwungen
        // (prüft `playerWindow`/`localPlayerWindow` bevor `openWindow` überhaupt aufgerufen
        // wird) — robuster als sich auf SwiftUIs Fenster-Uniqueness-Garantie zu verlassen.
        WindowGroup(id: "player") {
            if let request = playerLaunch.pendingPlayer {
                PlayerView(item: request.item, queue: request.queue, queueIndex: request.queueIndex, randomContext: request.randomContext, startFromBeginning: request.startFromBeginning)
                    .environmentObject(client)
                    .environmentObject(downloads)
                    .environmentObject(transcode)
                    .frame(minWidth: 900, minHeight: 560)
                    .id(request.id)
                    .preferredColorScheme(preferredColorScheme)
            }
        }

        WindowGroup(id: "localPlayer") {
            if let request = playerLaunch.pendingLocalPlayer {
                LocalPlayerView(item: request.item, queue: request.queue, randomPool: request.randomPool, startFromBeginning: request.startFromBeginning)
                    .environmentObject(localLibrary)
                    .environmentObject(transcode)
                    .frame(minWidth: 900, minHeight: 560)
                    .id(request.id)
                    .preferredColorScheme(preferredColorScheme)
            }
        }
        #endif
    }
}
