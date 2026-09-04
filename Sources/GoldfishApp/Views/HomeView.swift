import SwiftUI
import GoldfishCore

struct HomeView: View {
    @EnvironmentObject var client: GoldfishClient
    @State private var sections: [HomeSection] = []
    @State private var errorMessage: String?
    @State private var isLoading = true
    @Environment(\.scenePhase) private var scenePhase
    /// User-Anfrage 2026-09-02: `MainTabView` braucht diesen Pfad, um den eigenen
    /// Goldfish-Kopfbereich nur an der Tab-Wurzel zu zeigen (siehe dortiger Kommentar) —
    /// ohne Binding hier hätte `MainTabView` keine Sicht auf die Navigationstiefe.
    @Binding var path: NavigationPath

    // User-Anfrage 2026-09-04: "Ich hätte gerne das Suchfeld schon auf der
    // Startseite (also zusätzlich)" — library-übergreifend, analog zum
    // Browser (CLAUDE.md "Startseite (Home-View)": Suchfeld matcht Titel +
    // Schauspieler über alle Libraries mit ACL-Zugriff). `client.fetchItems`
    // ohne `libraryId` macht serverseitig bereits genau das (ACL-sicher).
    #if os(tvOS)
    @State private var search = ""
    @State private var searchResults: [Item] = []
    @State private var isSearching = false
    @State private var showTVSearchSheet = false
    // Gleicher Fix wie in `ItemGridView` (User-Report: bei 2+ Treffern ließ sich
    // mit `.prefersDefaultFocus` + `.id()` gar keine Kachel mehr fokussieren) —
    // expliziter `@FocusState` + verzögerte Zuweisung statt Default-Fokus-Trick.
    @FocusState private var focusedSearchResultID: Item.ID?
    #endif

    // Unconditional (nicht nur tvOS) deklariert, damit der if-else-Zweig in `body`
    // unten ohne #if-Verzweigung mitten in der ViewBuilder-Kette auskommt (das hatte
    // sich in `PlayerView` bereits als Swift-Parser-Falle erwiesen).
    private var tvSearchActive: Bool {
        #if os(tvOS)
        !search.isEmpty
        #else
        false
        #endif
    }

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
                } else if tvSearchActive {
                    #if os(tvOS)
                    tvSearchResultsView
                    #else
                    EmptyView()
                    #endif
                } else if sections.isEmpty {
                    ContentUnavailableMessage(text: "Keine Bibliotheken auf der Startseite sichtbar.")
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            // User-Anfrage 2026-09-02: "Fortsetzen"/"Als nächstes" sollen wie
                            // die Bibliotheks-Überschriften (z.B. "Filme") aussehen — vorher
                            // nutzten sie nur `HomeRow`s eigene kleine, graue Sub-Überschrift
                            // ohne die groß-fette Titelzeile, die jeder Library-Block hat.
                            HomeHeadingRow(title: "▶ Fortsetzen", items: sections.flatMap(\.continueItems))
                            HomeHeadingRow(title: "📺 Als nächstes", items: sections.flatMap(\.nextUp))

                            ForEach(sections) { section in
                                if !section.recent.isEmpty {
                                    VStack(alignment: .leading, spacing: 12) {
                                        Text(section.library.name)
                                            .font(.title3.bold())
                                            .padding(.horizontal)
                                        HomeRow(title: "🆕 Zuletzt hinzugefügt", items: section.recent)
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
            #if os(tvOS)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showTVSearchSheet = true
                    } label: {
                        Image(systemName: search.isEmpty ? "magnifyingglass" : "magnifyingglass.circle.fill")
                    }
                }
            }
            .sheet(isPresented: $showTVSearchSheet) {
                TVSearchSheet(search: $search)
            }
            .onChange(of: search) { _ in
                Task {
                    await loadSearchResults()
                    await Task.yield()
                    focusedSearchResultID = searchResults.first?.id
                }
            }
            #endif
            .task { await load() }
            .refreshable { await load() }
            .onChange(of: scenePhase) { phase in
                if phase == .active, !isLoading { Task { await load() } }
            }
        }
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

    #if os(tvOS)
    private func loadSearchResults() async {
        guard !search.isEmpty else {
            searchResults = []
            return
        }
        isSearching = true
        defer { isSearching = false }
        do {
            // Kein `libraryId` → serverseitig library-übergreifend über alle
            // ACL-zugänglichen Bibliotheken (CLAUDE.md "Startseite (Home-View)").
            searchResults = try await client.fetchItems(search: search)
        } catch {
            if GoldfishClient.isAuthError(error) {
                client.markSessionInvalid()
                return
            }
            searchResults = []
        }
    }

    /// Ersetzt die normalen Home-Streifen, solange eine Suche aktiv ist. Fokus-Fix
    /// wie in `ItemGridView` (User-Report: "Man kommt mit dem Cursor nicht hin" —
    /// ohne den Fix bleibt der Fokus nach dem Sheet-Dismiss auf dem 🔍-Button
    /// hängen; ein erster Versuch mit `.prefersDefaultFocus`+`.id()` brach die
    /// Fokussierbarkeit sogar komplett, sobald es 2+ Treffer gab).
    private var tvSearchResultsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("\(searchResults.count) Treffer")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)

                if isSearching && searchResults.isEmpty {
                    ProgressView().padding(.top, 40)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 220), spacing: 48, alignment: .top)], spacing: 48) {
                        ForEach(searchResults) { item in
                            ItemCard(item: item, width: 220, queue: searchResults)
                                .frame(width: 220)
                                .focused($focusedSearchResultID, equals: item.id)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.top, 24)
                }
            }
            .padding(.top, 68)
            .padding(.bottom, 16)
        }
    }
    #endif
}

/// Eine Kachel-Reihe MIT groß-fetter Überschrift, im selben Stil wie ein
/// Bibliotheks-Block (Text(section.library.name).font(.title3.bold())) —
/// genutzt für "Fortsetzen"/"Als nächstes", die zuvor nur `HomeRow`s eigene
/// kleine, graue Sub-Überschrift hatten und dadurch kleiner/unwichtiger
/// wirkten als die Bibliotheks-Abschnitte darunter.
private struct HomeHeadingRow: View {
    let title: String
    let items: [Item]

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text(title)
                    .font(.title3.bold())
                    .padding(.horizontal)
                HomeRow(title: nil, items: items)
            }
        }
    }
}

private struct HomeRow: View {
    let title: String?
    let items: [Item]

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
