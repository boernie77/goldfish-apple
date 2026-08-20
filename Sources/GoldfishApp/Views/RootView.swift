import SwiftUI
import GoldfishCore

struct RootView: View {
    @EnvironmentObject var client: GoldfishClient
    @EnvironmentObject var localLibrary: LocalLibraryManager
    @EnvironmentObject var downloads: DownloadManager
    @EnvironmentObject var shuffleScope: ShuffleScope
    @State private var checkedSession = false

    var body: some View {
        Group {
            if !checkedSession {
                ProgressView("Verbinde…")
            } else if client.isLoggedIn {
                MainTabView()
            } else {
                LoginView()
            }
        }
        .task {
            await refreshSessionStatus()
        }
        // Real bug hit 2026-08-19: local libraries AND downloads had no per-user isolation —
        // every account logged into this Mac/app saw every other account's local content.
        // `LocalLibraryManager`/`DownloadManager` filter their published lists by
        // `GoldfishClient.currentUsername` internally, but need an explicit nudge to
        // recompute when that changes (login/logout/switch) since they don't otherwise
        // observe `GoldfishClient` themselves.
        .onChange(of: client.currentUsername) { newValue in
            localLibrary.userDidChange()
            downloads.userDidChange()
            shuffleScope.userDidChange()
            // Bugfix 2026-08-20: offline abgeschlossene Gesehen-Markierungen (siehe
            // DownloadManager.queuePendingWatchedSync-Kommentar) blieben bisher für immer
            // unsynced. Ein bestätigter Username-Wechsel ist ein zuverlässiges Signal "Netz
            // ist gerade da" (Login/Session-Refresh ist selbst schon ein Server-Roundtrip).
            if newValue != nil {
                Task { await downloads.syncPendingWatched(client: client) }
            }
        }
        #if os(macOS)
        // Real root cause found 2026-08-19 via Console.app: "Space Forces Hidden ... tiles=[
        // ... appName=Goldfish name=Bibliotheken space=CGSSpace]" — the main window had ended
        // up in its own native-fullscreen/Split-View Space (not just unfocused). Minimizing
        // the player then force-hid that WHOLE Space (no visible window left in it), landing
        // the user on the plain desktop of a DIFFERENT Space — not back on the app. Four
        // earlier fixes all assumed a second window existed and just wasn't frontmost, which
        // this contradicts. Fix: strip `.fullScreenPrimary` from the main window's collection
        // behavior so it can never be dragged/zoomed into a separate fullscreen Space in the
        // first place (green-button "Enter Full Screen" / Split View tiling become
        // unavailable for this window specifically — the player windows are unaffected).
        // User-Anfrage 2026-08-19 (Screenshot): "Ich will, dass das Hauptfenster IMMER hinter
        // dem Player ist" — nicht "beim Schließen/Minimieren des Players wiederherstellen"
        // (das war die falsche Interpretation der letzten ~10 Fixversuche), sondern das
        // Hauptfenster soll unabhängig davon, auf welchem virtuellen Schreibtisch (Space) der
        // separate Player gerade landet, immer sichtbar im Hintergrund stehen. `.fullScreenAuxiliary`
        // (voriger Versuch) hat das NICHT geleistet — das kennzeichnet ein Fenster nur als
        // "darf NEBEN einem fullscreen-Fenster auf DESSEN Space mitlaufen", nicht "erscheint auf
        // jedem Space". `.canJoinAllSpaces` ist die tatsächlich dafür vorgesehene Markierung:
        // das Hauptfenster wird dann auf JEDEM Space mitgerendert, exakt wie ein Utility-/HUD-
        // Fenster, das immer sichtbar bleibt — unabhängig davon, welchen Space der Player gerade
        // belegt.
        // Real finding 2026-08-19 via file-logged `collBehavior` bitmask: the
        // `.remove(.fullScreenPrimary)` call above visibly did NOT stick — the bit was still
        // set in later log snapshots despite `WindowAccessor.updateNSView` re-running this
        // closure on every SwiftUI re-render (so it's not a one-shot-too-early timing issue
        // either; something keeps re-asserting it). Rather than keep fighting
        // `collectionBehavior` racing against whatever re-sets it, disable the actual UI
        // entry point directly: the green zoom button is what puts a window into native
        // fullscreen (own dedicated Space) in the first place — confirmed root cause of "App
        // verschwindet"/"Desktop hinter dem Player": the main window's logged frame exactly
        // matched full-screen dimensions with `onScreen=false`, i.e. it silently ended up
        // fullscreen on a Space that isn't the current one. Disabling the button structurally
        // prevents that path regardless of the collectionBehavior race.
        .background {
            WindowAccessor { window in
                // Whole-value reassignment instead of `.remove()`/`.insert()` on the property —
                // belt-and-suspenders in case incremental OptionSet mutation through this
                // particular bridged property wasn't actually persisting (the exact prior
                // symptom).
                window.collectionBehavior = [.managed, .participatesInCycle, .canJoinAllSpaces]
                // User-Anfrage 2026-08-19: mit `fullScreenPrimary` weg macht der grüne Button
                // jetzt nur noch "maximieren" (bleibt auf derselben Space, kein eigener
                // Fullscreen-Space mehr möglich) — der ist also wieder sicher nutzbar, das
                // vorherige komplette Deaktivieren war zu aggressiv.
                window.standardWindowButton(.zoomButton)?.isEnabled = true
                // "Das Mutterfenster soll schon groß sein... direkt überhalb der unteren
                // Leiste bis nach oben, also fast Vollbild" — beim ersten Erscheinen auf die
                // sichtbare Bildschirmfläche (unterhalb Menüleiste, oberhalb Dock) aufziehen,
                // ohne echtes Fullscreen zu nutzen. Nur einmalig (kleines Startfenster), damit
                // eine spätere manuelle Verkleinerung durch den User nicht bei jedem Re-Render
                // rückgängig gemacht wird.
                if window.frame.width < 700, let screenFrame = window.screen?.visibleFrame {
                    window.setFrame(screenFrame, display: true)
                }
            }
        }
        #endif
    }

    private func refreshSessionStatus() async {
        defer { checkedSession = true }
        guard client.baseURL != nil else { return }
        if let status = try? await client.authStatus() {
            client.applySessionStatus(status)
        }
    }
}

private enum MainTab: Hashable {
    case home, libraries, downloads, settings
}

struct MainTabView: View {
    @EnvironmentObject var client: GoldfishClient
    @State private var selectedTab: MainTab = .home
    // Reset to empty on every select of the Bibliotheken-Tab (see `LibrariesView`'s doc
    // comment) — a custom `Binding`'s setter fires on every tap, including re-tapping the
    // tab that's already active, which a plain `@State` + `.onChange` would miss (onChange
    // only fires when the new value actually differs from the old one).
    @State private var librariesPath = NavigationPath()

    var body: some View {
        // Explicit expansion: a TabView's tab content doesn't always stretch to fill the
        // window on macOS on its own — a `Form`-rooted tab (Settings) was staying at its
        // compact intrinsic width, pinned to the leading edge with a huge empty area next
        // to it (real bug hit 2026-08-18, looked like a two-column layout issue but wasn't).
        TabView(selection: Binding(
            get: { selectedTab },
            set: { newValue in
                selectedTab = newValue
                if newValue == .libraries { librariesPath = NavigationPath() }
            }
        )) {
            HomeView()
                .tabItem { Label("Start", systemImage: "house") }
                .tag(MainTab.home)

            LibrariesView(path: $librariesPath)
                .tabItem { Label("Bibliotheken", systemImage: "books.vertical") }
                .tag(MainTab.libraries)

            DownloadsView()
                .tabItem { Label("Downloads", systemImage: "arrow.down.circle") }
                .tag(MainTab.downloads)

            SettingsView()
                .tabItem { Label("Einstellungen", systemImage: "gearshape") }
                .tag(MainTab.settings)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Real bug hit 2026-08-19: the Goldfish header was originally a plain `VStack` wrapper
        // AROUND the `TabView` — wrapping each tab's `NavigationStack` in an extra container
        // like that breaks `.toolbar` promotion to the actual macOS window title bar for the
        // content underneath (a nested NavigationStack's toolbar items need to sit reasonably
        // close to being the window's root content to reliably reach the real title bar).
        // Real symptom: the Bibliotheken tab's Sortieren/Filter/search toolbar silently
        // stopped showing up at all once this header shipped. `.safeAreaInset(edge: .top)` is
        // the SwiftUI-idiomatic way to add persistent chrome ABOVE content without disturbing
        // that content's own navigation/toolbar hierarchy — same visual result, no more
        // wrapping.
        .safeAreaInset(edge: .top, spacing: 0) {
            // Real bug hit 2026-08-19: first version used the 🐠 emoji as a placeholder —
            // the app actually HAS a real designed logo (`AppIcon.appiconset`), just never
            // exposed as a plain SwiftUI `Image` before now (`GoldfishLogo` imageset, same
            // artwork, added specifically for this header).
            HStack(spacing: 12) {
                Image("GoldfishLogo")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 32, height: 32)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                Text("Goldfish")
                    .font(.title2.bold())
                Spacer()
                if let username = client.currentUsername {
                    Text(username)
                        .font(.headline)
                        .foregroundStyle(.white)
                    Button {
                        Task { await client.logout() }
                    } label: {
                        Label("Abmelden", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 14)
            .background(.bar)
        }
    }
}
