import SwiftUI
import GoldfishCore

struct HomeView: View {
    @EnvironmentObject var client: GoldfishClient
    #if os(tvOS)
    @EnvironmentObject var lastLibraryContext: LastLibraryContext
    #endif
    @State private var sections: [HomeSection] = []
    @State private var errorMessage: String?
    @State private var isLoading = true
    @Environment(\.scenePhase) private var scenePhase
    /// User-Anfrage 2026-09-02: `MainTabView` braucht diesen Pfad, um den eigenen
    /// Goldfish-Kopfbereich nur an der Tab-Wurzel zu zeigen (siehe dortiger Kommentar) —
    /// ohne Binding hier hätte `MainTabView` keine Sicht auf die Navigationstiefe.
    @Binding var path: NavigationPath

    // User-Anfrage 2026-09-04: "Ich hätte gerne das Suchfeld schon auf der
    // Startseite (also zusätzlich)" — ursprünglich hier als Toolbar-Button/Overlay gelöst.
    // User-Wunsch 2026-09-08: nach mehreren gescheiterten Fokus-Fixen (Button unerreichbar
    // bzw. nur über Umweg erreichbar) auf tvOS in einen eigenen Tab ausgelagert
    // (`SearchTabView.swift`, links von "Start" in `RootView.swift`) — die native
    // tvOS-Tab-Leiste gibt den Fokus bei Links/Rechts nicht an benachbarte eigene Views ab,
    // nur ein echter Tab ist zuverlässig per Fernbedienung direkt erreichbar. Die komplette
    // Such-Logik lebt jetzt dort, hier komplett entfernt (kein zweiter, redundanter
    // Suchpfad mehr).

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if isLoading {
                    ProgressView()
                } else if let errorMessage {
                    VStack(spacing: 16) {
                        ContentUnavailableMessage(text: errorMessage)
                        Button {
                            Task { await load() }
                        } label: {
                            Label("Erneut versuchen", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isLoading)
                    }
                } else if sections.isEmpty {
                    ContentUnavailableMessage(text: "Keine Bibliotheken auf der Startseite sichtbar.")
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            // User-Anfrage 2026-09-02: "Fortsetzen"/"Als nächstes" sollen wie
                            // die Bibliotheks-Überschriften (z.B. "Filme") aussehen — vorher
                            // nutzten sie nur `HomeRow`s eigene kleine, graue Sub-Überschrift
                            // ohne die groß-fette Titelzeile, die jeder Library-Block hat.
                            HomeHeadingRow(title: "▶ Fortsetzen", items: sections.flatMap(\.continueItems), libraryFor: library(for:))
                            HomeHeadingRow(title: "📺 Als nächstes", items: sections.flatMap(\.nextUp), libraryFor: library(for:))

                            ForEach(sections) { section in
                                if !section.recent.isEmpty {
                                    VStack(alignment: .leading, spacing: 12) {
                                        Text(section.library.name)
                                            .font(.title3.bold())
                                            .padding(.horizontal)
                                        HomeRow(title: "🆕 Zuletzt hinzugefügt", items: section.recent, libraryFor: { _ in section.library })
                                    }
                                }
                            }
                        }
                        // User-Anfrage 2026-09-02: "Fortsetzen" war direkt unterm eigenen
                        // Goldfish-Header abgeschnitten — die generische `.padding(.vertical)`
                        // reichte als Abstand zur ERSTEN Überschrift nicht (alle Überschriften
                        // darunter, z.B. "Als nächstes", waren normal sichtbar — nur der ganz
                        // oberste Abstand war zu knapp). Expliziter, großzügigerer Top-Wert
                        // statt des generischen Werts.
                        .padding(.top, 68)
                        .padding(.bottom, 16)
                    }
                }
            }
            // User-Anfrage 2026-09-02: "zweites Goldfish unterhalb vom Logo" — der eigene
            // Goldfish-Kopfbereich (Logo+Titel, siehe RootView) UND die native große
            // Navigationsleisten-Titelzeile zeigten an der Tab-Wurzel gleichzeitig
            // "Goldfish". Leer statt doppelt — der Zurück-Pfeil bei gepushten Screens
            // zeigt dann einfach nur den Chevron ohne Textlabel (Standardverhalten).
            .navigationTitle("")
            // Folgefehler (User-Report 2026-09-02): eine LEERE Titelzeile im großen
            // Titel-Modus (Default) klappt auf null Höhe zusammen — dadurch rutschte der
            // Inhalt (allen voran "Fortsetzen") zu weit nach oben, direkt unter/hinter den
            // eigenen Goldfish-Kopfbereich. `.inline` hält die Leiste auf konstanter,
            // kompakter Standardhöhe, unabhängig vom (leeren) Titeltext.
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            // User-Anfrage 2026-09-02: die Home-Kacheln nutzten bisher `NavigationLink
            // (destination:)` (View-basiert) statt wertbasierter Navigation wie
            // `ItemGridView` — ein View-basierter Push aktualisiert den von außen
            // gebundenen `path` NICHT, wodurch `MainTabView`s "bin ich an der Tab-Wurzel"-
            // Erkennung (siehe dortiger Kommentar) einen Push von der Startseite aus nie
            // bemerkte und der Goldfish-Kopfbereich die native Zurück-Leiste weiter
            // verdeckte ("über die Startseite kein Zurück-Pfeil", real reported).
            .navigationDestination(for: ItemNavTarget.self) { target in
                ItemDetailView(item: target.item, queue: target.queue)
            }
            #if os(macOS)
            // User-Wunsch 2026-09-13 (macOS): Klick auf Serien-/Kanalname in einer
            // Home-Kachel (siehe `ItemCard.folderLinkableText`) soll zur Serien-/
            // Kanalübersicht springen. `FolderDestination` ist dieselbe Ziel-Struktur,
            // die `ItemGridView` beim normalen Bibliotheks-Browsing schon nutzt. Nur
            // macOS pusht diesen Wert (iOS/tvOS geben `homeFolderLibrary` nie mit).
            .navigationDestination(for: FolderDestination.self) { dest in
                HomeFolderDestinationView(destination: dest)
            }
            #endif
            .task { await load() }
            #if os(tvOS)
            // User-Wunsch 2026-09-08: "kommt man von Start, dann globale Suche" — sonst
            // blieb der Scope aus der zuletzt besuchten Bibliothek hängen, auch nachdem
            // man längst wieder auf der Startseite war. Jedes Erscheinen von Start setzt
            // den Kontext explizit zurück (analog dazu, wie jede `ItemGridView`-Instanz
            // ihn auf sich selbst setzt) — Downloads/Einstellungen fassen ihn bewusst
            // NICHT an (User-Bestätigung: "passt so für mich"), der zuletzt besuchte
            // Bibliotheks-Scope bleibt von dort aus erreichbar.
            .onAppear { lastLibraryContext.clear() }
            #endif
            .refreshable { await load() }
            .onChange(of: scenePhase) { phase in
                if phase == .active, !isLoading { Task { await load() } }
            }
        }
    }

    /// "Fortsetzen"/"Als nächstes" mischen Items ALLER Bibliotheken flach
    /// (`sections.flatMap(...)`) — für den Serien-/Kanalname-Link (siehe
    /// `ItemCard.homeFolderLibrary`) braucht jedes Item seine eigene `Library` zurück,
    /// nicht nur die eine Library der gerade betrachteten Sektion.
    private func library(for item: Item) -> Library? {
        sections.first { $0.library.id == item.libraryId }?.library
    }

    private func load() async {
        isLoading = sections.isEmpty
        defer { isLoading = false }
        do {
            let response = try await client.fetchHome()
            sections = response.sections
            errorMessage = nil
        } catch {
            // 401 = tote Session, nicht "offline": lokalen Login verwerfen, RootView
            // schwenkt auf LoginView statt "Session abgelaufen" als Sackgasse zu zeigen.
            if GoldfishClient.isAuthError(error) {
                client.markSessionInvalid()
                return
            }
            errorMessage = error.localizedDescription
        }
    }

}

/// Eine Kachel-Reihe MIT groß-fetter Überschrift, im selben Stil wie ein
/// Bibliotheks-Block (Text(section.library.name).font(.title3.bold())) —
/// genutzt für "Fortsetzen"/"Als nächstes", die zuvor nur `HomeRow`s eigene
/// kleine, graue Sub-Überschrift hatten und dadurch kleiner/unwichtiger
/// wirkten als die Bibliotheks-Abschnitte darunter.
private struct HomeHeadingRow: View {
    let title: String
    let items: [Item]
    /// Löst pro Item dessen Bibliothek auf (User-Wunsch 2026-09-13: Serien-/
    /// Kanalname-Link braucht die richtige `Library`, "Fortsetzen"/"Als nächstes"
    /// mischen aber Items mehrerer Bibliotheken flach) — siehe `HomeView.library(for:)`.
    var libraryFor: (Item) -> Library? = { _ in nil }

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text(title)
                    .font(.title3.bold())
                    .padding(.horizontal)
                HomeRow(title: nil, items: items, libraryFor: libraryFor)
            }
        }
    }
}

private struct HomeRow: View {
    let title: String?
    let items: [Item]
    var libraryFor: (Item) -> Library? = { _ in nil }

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                if let title {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    // `.top`: real bug hit 2026-08-19 — a Home row mixes movie/TV cards
                    // (2 text lines below the poster) with Privat-Library/YouTube-style
                    // cards (3 lines: title + Kanalname + Datum, added for the channel-name
                    // display feature). A plain HStack centers children vertically by
                    // default, so the taller card's extra line pushed its poster down to
                    // stay centered against the shorter card — looked like the tiles were
                    // randomly shifted. Top alignment keeps every poster's top edge level
                    // regardless of how much text sits underneath.
                    // tvOS-Fix 2026-09-03: größerer Kartenabstand, damit die fokussierte
                    // Kachel beim Hochskalieren (siehe `ItemCard.posterSection`,
                    // scaleEffect 1.08) nicht in die Nachbarkachel hineinreicht. Auch die
                    // Kartenbreite selbst ist auf tvOS größer (10-Fuß-UI — bei 130pt wie
                    // auf dem iPhone passen Titel/Jahr/Badges auf dem großen Bildschirm
                    // kaum lesbar drauf).
                    #if os(tvOS)
                    let tileWidth: CGFloat = 220
                    let tileSpacing: CGFloat = 40
                    #else
                    let tileWidth: CGFloat = 130
                    let tileSpacing: CGFloat = 12
                    #endif
                    HStack(alignment: .top, spacing: tileSpacing) {
                        ForEach(items) { item in
                            #if os(tvOS)
                            // Der NavigationLink steckt jetzt INNERHALB von ItemCard (nur
                            // ums Poster, siehe dortiger Kommentar) — hier also nur noch
                            // die Karte selbst, kein zusätzlicher äußerer Link mehr.
                            ItemCard(item: item, width: tileWidth, queue: items)
                                .frame(width: tileWidth)
                            #elseif os(macOS)
                            // User-Wunsch 2026-09-13: Serien-/Kanalname soll zur Serien-/
                            // Kanalübersicht springen, das Poster weiterhin zum Item selbst
                            // — zwei unabhängige Tap-Ziele. Dafür baut `ItemCard` (wie auf
                            // tvOS) den Link INTERN nur ums Poster, statt hier extern die
                            // ganze Karte zu umschließen (ein NavigationLink verschachtelt in
                            // einem anderen liefert sonst kein zweites eigenes Tap-Ziel).
                            ItemCard(item: item, width: tileWidth, queue: items, homeFolderLibrary: libraryFor(item))
                                .frame(width: tileWidth)
                            #else
                            NavigationLink(value: ItemNavTarget(item: item, queue: items)) {
                                ItemCard(item: item, width: tileWidth)
                                    .frame(width: tileWidth)
                            }
                            .cardButtonStyleCompat()
                            .focusableCompat(false)
                            #endif
                        }
                    }
                    .padding(.horizontal)
                    // tvOS-Fix 2026-09-03 (User-Report: fokussierte Kachel oben abgeschnitten):
                    // die horizontale ScrollView clippt ihren Inhalt an den eigenen Bounds —
                    // ohne vertikalen Zusatzraum reicht die hochskalierte Kachel
                    // (`posterSection`s `scaleEffect(1.08)` + Schatten) oben/unten über den
                    // sichtbaren Bereich hinaus und wird dort abgeschnitten.
                    #if os(tvOS)
                    .padding(.vertical, 24)
                    #endif
                }
            }
        }
    }
}

#if os(macOS)
/// Ziel des Serien-/Kanalname-Links auf der Startseite (User-Wunsch 2026-09-13).
/// Anders als beim normalen Bibliotheks-Browsing (`ItemGridView.destinationView(for:)`)
/// kennt HomeView nicht die Geschwister-Ordner-Kacheln der Zielbibliothek (die
/// dort schon geladene `folders`-Liste sagt, ob ein Ordner "drilldown" ist, also
/// selbst wieder Unterordner-Kacheln zeigt statt einer flachen Dateiliste) — hier
/// wird das einmalig live nachgefragt, exakt derselbe `parent: nil`-Root-Fetch wie
/// beim Öffnen einer Bibliothek von ihrer Wurzel aus.
private struct HomeFolderDestinationView: View {
    let destination: FolderDestination
    @EnvironmentObject var client: GoldfishClient
    @State private var showsFolderTiles = false
    @State private var isResolved = false

    var body: some View {
        Group {
            // TV-Bibliothek: der Top-Ordner IST die Serie — direkt zum Staffel-Browser,
            // exakt wie `ItemGridView.destinationView(for:)` es beim normalen Browsing
            // von der Library-Wurzel aus tut. Kein Root-Fetch nötig.
            if destination.library.isTV, let folder = destination.folder {
                ShowSeasonsView(library: destination.library, folder: folder)
            } else if isResolved {
                ItemGridView(library: destination.library, folder: destination.folder, showsFolderTiles: showsFolderTiles)
            } else {
                ProgressView()
                    .task { await resolve() }
            }
        }
    }

    private func resolve() async {
        if let folder = destination.folder,
           let tiles = try? await client.fetchFolders(libraryId: destination.library.id, parent: nil),
           let tile = tiles.first(where: { $0.name == folder }) {
            showsFolderTiles = tile.drilldown
        }
        isResolved = true
    }
}
#endif
