import SwiftUI
import GoldfishCore

/// A navigable destination inside a library: either a subfolder tile grid, a flat
/// item grid, or (for TV shows) the season browser.
struct FolderDestination: Hashable {
    let library: Library
    let folder: String?
}

struct ItemGridView: View {
    let library: Library
    var folder: String? = nil
    /// Root level and drilldown-enabled folders show subfolder tiles; everything else is flat.
    var showsFolderTiles: Bool = true

    @EnvironmentObject var client: GoldfishClient
    @EnvironmentObject var shuffleScope: ShuffleScope
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif
    @State private var folders: [FolderTile] = []
    @State private var items: [Item] = []
    @State private var search = ""
    @State private var errorMessage: String?
    @State private var isLoading = true

    @State private var sort: ItemSort
    @State private var ascending: Bool
    @State private var watchedFilter: WatchedFilter = .all
    @State private var favoritesOnly = false
    @State private var selectedBuckets: Set<ResolutionBucket> = []
    // User-Anfrage 2026-08-25: "neben der Anzahl an Dateien auch immer die Gesamtgröße in
    // GB, deaktivierbar im Menü" + Nachfrage "wenn man in weitere Unterordner geht, auch
    // dort" — `items` ist bereits die aktuelle Ordner-Ebene (Breadcrumb-Navigation lädt bei
    // jedem Wechsel neu), die Summe folgt dem also automatisch auf jeder Tiefe, ohne
    // Extra-Logik. Gemeinsamer Schalter mit `LocalLibraryItemsView`
    // (`DisplaySettings.showTotalSizeKey`).
    @AppStorage(DisplaySettings.showTotalSizeKey) private var showTotalSize = true
    @State private var randomItem: Item?
    @State private var isLoadingRandom = false
    @State private var randomError: String?
    /// User-Anfrage 2026-08-19: "in jeder Bibliothek auf der rechten Seite eine
    /// Buchstabenleiste zum navigieren" — filtert wie im Browser (CLAUDE.md
    /// "Alphabet-Sidebar rechts"), kein Scroll-Sprung.
    @State private var alphaFilter: String?
    // tvOS-Fix 2026-09-03 (User-Report: "die Filterbuttons zeigen nichts an. Funktionieren
    // nicht"): ein `Menu` als Toolbar-Popover scheint auf tvOS nicht zuverlässig ein
    // sichtbares Overlay zu öffnen (vermutlich ein Anker-/Positionierungsproblem des
    // `ToolbarItemGroup`-Bridging auf tvOS — mit Icon-only-Buttons ohne intrinsische Text-
    // breite besonders ausgeprägt). Fix: auf tvOS eigene, garantiert sichtbare Sheets
    // (Vollbild-Liste) statt eines angehefteten Menüs — dasselbe robuste Pattern wie jeder
    // andere Auswahl-Dialog in der App.
    #if os(tvOS)
    @State private var showTVSortSheet = false
    @State private var showTVFilterSheet = false
    // User-Anfrage 2026-09-04: "Was übrigens auch noch fehlt, ist ein Suchfeld" —
    // `.searchable(text:)` lief bisher nur auf iOS, macOS hat sein eigenes
    // Toolbar-TextField (siehe Kommentar dort), tvOS hatte GAR KEINEN Einstieg.
    // Gleiches Sheet-statt-Menü-Muster wie Sortieren/Filter.
    @State private var showTVSearchSheet = false
    #endif

    /// Custom init only to set the sort defaults from `library.kind` — everything else keeps
    /// the compiler-synthesized memberwise behavior's parameter shape/defaults.
    /// User-Anfrage 2026-08-19: YouTube-Style Privat-Libraries sollen innerhalb der Kanäle
    /// immer "Veröffentlicht aufsteigend" (älteste zuerst) als Standard zeigen, nicht Titel —
    /// mirrors the Browser's `restoreSortForContext()` (CLAUDE.md "UI": "Default-Sort in
    /// privaten Libs ist 'Veröffentlicht' aufsteigend").
    init(library: Library, folder: String? = nil, showsFolderTiles: Bool = true) {
        self.library = library
        self.folder = folder
        self.showsFolderTiles = showsFolderTiles
        // User-Anfrage 2026-08-19: "eine Bibliothek soll sich die letzte Sortierung merken" —
        // vorher immer der harte kind-abhängige Default, jede Navigation zurück in eine
        // Bibliothek/einen Ordner setzte die Sortierung zurück. Gleiche Konvention wie der
        // Browser (CLAUDE.md: `sort:lib:<libID>:<folder>` in localStorage).
        let key = Self.sortStorageKey(libraryId: library.id, folder: folder)
        if let savedRaw = UserDefaults.standard.string(forKey: key), let saved = ItemSort(rawValue: savedRaw) {
            _sort = State(initialValue: saved)
            _ascending = State(initialValue: UserDefaults.standard.object(forKey: key + ".asc") as? Bool ?? saved.defaultAscending)
        } else {
            _sort = State(initialValue: library.isPrivate ? .released : .title)
            _ascending = State(initialValue: true)
        }
    }

    private static func sortStorageKey(libraryId: Int64, folder: String?) -> String {
        "goldfish.sort.\(libraryId).\(folder ?? "_")"
    }
    private var sortStorageKey: String { Self.sortStorageKey(libraryId: library.id, folder: folder) }

    private var isFilterActive: Bool {
        !search.isEmpty || watchedFilter != .all || favoritesOnly || !selectedBuckets.isEmpty
    }

    private var totalSizeLabel: String {
        let bytes = items.reduce(Int64(0)) { $0 + ($1.sizeBytes ?? 0) }
        return String(format: "%.1f GB", Double(bytes) / 1_000_000_000)
    }

    private var displayedFolders: [FolderTile] {
        folders.filter { AlphabetSidebar.matches($0.metadata?.title ?? $0.displayName, alphaFilter) }
    }
    private var displayedItems: [Item] {
        items.filter { AlphabetSidebar.matches($0.displayTitle, alphaFilter) }
    }

    // Fixed (min == max) column width instead of a fully adaptive grid: adaptive grids
    // on macOS can miscompute their initial width right after a NavigationStack push,
    // which visually collapses the grid into one smeared column. A fixed cell size sidesteps that.
    // tvOS-Fix 2026-09-03: größere Kacheln (10-Fuß-UI) + größerer Abstand, damit die
    // fokussierte Kachel beim Hochskalieren (siehe ItemCard/FolderCard `posterSection`,
    // scaleEffect 1.08) nicht die Nachbarkachel berührt.
    #if os(tvOS)
    private let cardWidth: CGFloat = 240
    private var columns: [GridItem] { [GridItem(.adaptive(minimum: cardWidth, maximum: cardWidth), spacing: 48, alignment: .top)] }
    #else
    private let cardWidth: CGFloat = 150
    private var columns: [GridItem] { [GridItem(.adaptive(minimum: cardWidth, maximum: cardWidth), spacing: 12, alignment: .top)] }
    #endif

    /// Ausgelagert aus `body` — der große kombinierte ViewBuilder-Ausdruck brachte den
    /// Type-Checker sonst zum Timeout ("unable to type-check ... in reasonable time"),
    /// nachdem `displayedFolders`/`displayedItems` dazukamen.
    @ViewBuilder
    private var itemGrid: some View {
        #if os(tvOS)
        LazyVGrid(columns: columns, spacing: 48) {
            ForEach(displayedFolders) { tile in
                // Der NavigationLink steckt jetzt INNERHALB von FolderCard/ItemCard
                // (nur ums Poster) — siehe Kommentar dort. Kein äußerer Link mehr nötig.
                FolderCard(tile: tile, library: library)
                    .frame(width: cardWidth)
            }
            ForEach(displayedItems) { item in
                ItemCard(item: item, width: cardWidth, queue: items)
                    .frame(width: cardWidth)
            }
        }
        #else
        LazyVGrid(columns: columns, spacing: 16) {
            ForEach(displayedFolders) { tile in
                NavigationLink(value: FolderDestination(library: library, folder: tile.name)) {
                    FolderCard(tile: tile)
                        .frame(width: cardWidth)
                }
                .cardButtonStyleCompat()
                .focusableCompat(false)
            }
            ForEach(displayedItems) { item in
                NavigationLink(value: ItemNavTarget(item: item, queue: items)) {
                    ItemCard(item: item)
                        .frame(width: cardWidth)
                }
                .cardButtonStyleCompat()
                .focusableCompat(false)
            }
        }
        #endif
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
            } else if let errorMessage {
                ContentUnavailableMessage(text: errorMessage)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        // `.navigationTitle` alone doesn't render as visible on-screen text on
                        // macOS (it only sets the window titlebar) — show an explicit heading too.
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(folder?.components(separatedBy: "/").last ?? library.name)
                                .font(.title2.bold())
                            Text(showTotalSize && !items.isEmpty ? "(\(folders.count + items.count) · \(totalSizeLabel))" : "(\(folders.count + items.count))")
                                .font(.title3)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal)

                        // User-Anfrage 2026-08-19: "bei Such- oder Filterergebnissen will ich
                        // immer die Anzahl der Treffer sehen" — vorher nur bei Textsuche
                        // sichtbar, jetzt auch bei jedem aktiven Filter (Gesehen/Favorit/
                        // Auflösung) ohne Suchtext, analog zum Browser (`filterActive` in
                        // grid.js).
                        if isFilterActive {
                            Text("\(items.count) Treffer")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal)
                        }

                        itemGrid
                            .padding(.horizontal)
                            .padding(.trailing, 28)
                            // tvOS-Fix 2026-09-03: siehe LibrariesView-Kommentar — extra
                            // Abstand, damit der Fokusrahmen der ersten Kachelreihe nicht
                            // oben von der ScrollView abgeschnitten wird.
                            #if os(tvOS)
                            .padding(.top, 24)
                            #endif
                    }
                    .padding(.vertical)
                }
                .overlay(alignment: .trailing) {
                    if !folders.isEmpty || !items.isEmpty {
                        AlphabetSidebar(selected: $alphaFilter)
                            .padding(.trailing, 4)
                            // tvOS-Fix 2026-09-03 (User: "Buchstabenleiste etwas nach unten"):
                            // vertikal zentriert saß die Leiste zu nah an der Toolbar-Zeile.
                            #if os(tvOS)
                            .offset(y: 40)
                            #endif
                    }
                }
            }
        }
        .onChange(of: folder) { _ in alphaFilter = nil }
        .navigationTitle(folder?.components(separatedBy: "/").last ?? library.name)
        .navigationDestination(for: Item.self) { item in
            ItemDetailView(item: item)
        }
        .navigationDestination(for: ItemNavTarget.self) { target in
            ItemDetailView(item: target.item, queue: target.queue)
        }
        .navigationDestination(for: FolderDestination.self) { dest in
            destinationView(for: dest)
        }
        #if os(iOS)
        .searchable(text: $search, prompt: "Suchen")
        #endif
        .toolbar {
            #if os(macOS)
            // Not `.searchable` here: its macOS search field is an NSTokenTextView-backed
            // control that seems to be exactly what triggers AppKit's password-autofill
            // heuristic scan (`_showPasswordAutoFillIfNecessaryForView`) — that scan walks
            // the whole window's key-view loop and hung the app for 50+ seconds on a large
            // grid (real bug hit 2026-08-18, `.focusable(false)` on the grid's own controls
            // alone didn't fix it). A plain TextField sidesteps whatever specifically about
            // the search-field implementation triggers that scan.
            ToolbarItem(placement: .principal) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Suchen", text: $search)
                        .textFieldStyle(.plain)
                    if !search.isEmpty {
                        Button {
                            search = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .focusableCompat(false)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                .frame(width: 220)
            }
            #endif
            ToolbarItemGroup(placement: .primaryAction) {
                #if os(tvOS)
                Button {
                    showTVSearchSheet = true
                } label: {
                    Image(systemName: search.isEmpty ? "magnifyingglass" : "magnifyingglass.circle.fill")
                }
                #endif

                Button {
                    Task { await playRandom() }
                } label: {
                    if isLoadingRandom {
                        ProgressView()
                    } else {
                        // tvOS-Fix 2026-09-03, zweiter Anlauf (User-Report: Text blieb trotz
                        // `.fixedSize()` abgeschnitten — "Z...lig" — UND der Button war dadurch
                        // kaum noch zuverlässig treffbar/auslösbar). `ToolbarItemGroup`
                        // komprimiert ihre Kinder auf tvOS offenbar so aggressiv, dass selbst
                        // die erzwungene intrinsische Größe nicht half. Icon-only umgeht das
                        // Problem komplett, statt weiter gegen die Kompression anzukämpfen.
                        #if os(tvOS)
                        Image(systemName: "shuffle")
                        #else
                        Label("Zufällig", systemImage: "shuffle")
                        #endif
                    }
                }
                .disabled(isLoadingRandom)

                #if os(tvOS)
                Button {
                    showTVSortSheet = true
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
                #else
                Menu {
                    // Real bug hit 2026-08-19: a `Picker` nested inside a `Menu` renders as
                    // a native AppKit SUBMENU (its own panel, its own disclosure chevron) —
                    // that chevron consistently pointed right even when the submenu itself
                    // opened to the left near the window's trailing edge, an AppKit rendering
                    // quirk outside SwiftUI's control. Flattening into plain `Button`s in the
                    // SAME top-level menu (no submenu at all) sidesteps the whole issue.
                    ForEach(ItemSort.allCases) { option in
                        Button {
                            sort = option
                        } label: {
                            Label(option.label, systemImage: sort == option ? "checkmark" : "")
                        }
                    }
                    Divider()
                    Button {
                        ascending.toggle()
                    } label: {
                        Label(ascending ? "Aufsteigend" : "Absteigend", systemImage: ascending ? "arrow.up" : "arrow.down")
                    }
                } label: {
                    Label("Sortieren", systemImage: "arrow.up.arrow.down")
                }
                #endif

                #if os(tvOS)
                Button {
                    showTVFilterSheet = true
                } label: {
                    Image(systemName: hasActiveFilters ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                }
                #else
                Menu {
                    ForEach(WatchedFilter.allCases) { option in
                        Button {
                            watchedFilter = option
                        } label: {
                            Label(option.label, systemImage: watchedFilter == option ? "checkmark" : "")
                        }
                    }
                    Divider()
                    // User-Anfrage 2026-08-19: "der Filter Favoriten fehlt" — der Server
                    // unterstützt `favorite=yes` schon lange (CLAUDE.md "Filter-UI"), war nur
                    // nirgends im Mac/iOS-Client verdrahtet.
                    Button {
                        favoritesOnly.toggle()
                    } label: {
                        Label("Nur Favoriten", systemImage: favoritesOnly ? "heart.fill" : "heart")
                    }
                    Divider()
                    // User-Anfrage 2026-09-03: "man erkennt nicht, welche Auflösung gewählt
                    // ist" — der echte Grund war NICHT das Menü-Schließverhalten (siehe
                    // .modernMenuStaysOpen() unten), sondern dass hier vorher IMMER ein
                    // "checkmark"-Symbol im Label steckte und nur per .opacity() aus-/
                    // eingeblendet wurde (User-Anfrage 2026-09-02, s. Git-Historie). SwiftUI
                    // bridged Menu-Inhalte auf natives UIMenu, und dabei wird das Icon als
                    // statisches Bild übernommen — die Opacity wird dabei ignoriert. Ergebnis:
                    // JEDE Auflösung zeigte immer einen Haken, unabhängig vom echten Zustand.
                    // Fix: echtes Icon-Paar (checkmark/circle) statt Opacity-Trick — reserviert
                    // genauso zuverlässig die Icon-Spalte (immer ein echtes Icon vorhanden),
                    // spiegelt aber den tatsächlichen Auswahlzustand korrekt wider.
                    ForEach(ResolutionBucket.allCases) { bucket in
                        Button {
                            if selectedBuckets.contains(bucket) {
                                selectedBuckets.remove(bucket)
                            } else {
                                selectedBuckets.insert(bucket)
                            }
                        } label: {
                            Label(bucket.label, systemImage: selectedBuckets.contains(bucket) ? "checkmark.circle.fill" : "circle")
                        }
                    }
                    Divider()
                    Button {
                        showTotalSize.toggle()
                    } label: {
                        Label("Gesamtgröße anzeigen", systemImage: showTotalSize ? "checkmark" : "")
                    }
                } label: {
                    Label("Filter", systemImage: hasActiveFilters ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                }
                // User-Anfrage 2026-09-03: "man erkennt nicht, welche Auflösung gewählt ist" —
                // war kein Anzeige-Bug (der Haken war schon korrekt gesetzt), sondern ein
                // Interaktionsproblem: ein SwiftUI-`Menu` schließt sich standardmäßig nach JEDEM
                // Tap auf einen Button darin. Bei den Auflösungs-Kästchen (Mehrfachauswahl) hieß
                // das: ein Tap togglete den Haken korrekt, aber das Menü klappte sofort zu, bevor
                // man das gesehen hat — beim nächsten Öffnen sah es dann so aus, als hätte sich
                // nichts geändert (bzw. man musste raten, was gerade an/aus war). `.disabled`
                // hält das Menü über mehrere Taps offen, exakt wie eine Checkbox-Liste.
                .modernMenuStaysOpen()
                #endif
            }
        }
        #if os(tvOS)
        .sheet(isPresented: $showTVSortSheet) {
            TVSortSheet(sort: $sort, ascending: $ascending)
        }
        .sheet(isPresented: $showTVFilterSheet) {
            TVFilterSheet(watchedFilter: $watchedFilter, favoritesOnly: $favoritesOnly, selectedBuckets: $selectedBuckets, showTotalSize: $showTotalSize)
        }
        .sheet(isPresented: $showTVSearchSheet) {
            TVSearchSheet(search: $search)
        }
        #endif
        .task { await load() }
        .onChange(of: search) { _ in Task { await load() } }
        .onChange(of: sort) { newValue in
            ascending = newValue.defaultAscending
            UserDefaults.standard.set(newValue.rawValue, forKey: sortStorageKey)
            Task { await load() }
        }
        .onChange(of: ascending) { newValue in
            UserDefaults.standard.set(newValue, forKey: sortStorageKey + ".asc")
            Task { await load() }
        }
        .onChange(of: watchedFilter) { _ in Task { await load() } }
        .onChange(of: favoritesOnly) { _ in Task { await load() } }
        .onChange(of: selectedBuckets) { _ in Task { await load() } }
        .alert("Kein Video gefunden", isPresented: Binding(get: { randomError != nil }, set: { if !$0 { randomError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(randomError ?? "")
        }
        #if os(macOS)
        .onChange(of: randomItem) { newValue in
            guard let newValue else { return }
            openRandomPlayerWindow(for: newValue)
        }
        #else
        .fullScreenCoverCompat(isPresented: Binding(get: { randomItem != nil }, set: { if !$0 { randomItem = nil } })) {
            if let randomItem {
                PlayerView(item: randomItem, randomContext: RandomContext(libraryId: library.id, folderSelections: shuffleScope.isScoped ? shuffleScope.selections : nil, folder: folder, search: search.isEmpty ? nil : search))
            }
        }
        #endif
    }

    private var hasActiveFilters: Bool {
        watchedFilter != .all || favoritesOnly || !selectedBuckets.isEmpty
    }

    private func playRandom() async {
        isLoadingRandom = true
        defer { isLoadingRandom = false }
        do {
            // Eine aktive globale Auswahl hat Vorrang vor der gerade offenen Bibliothek/Ordner
            // — exakt wie im Browser (`randomParams()`-Priorität: `state.shuffleFolders` vor
            // `state.currentLibrary`, CLAUDE.md "Ordner-Scoping für Shuffle"; User-Anfrage
            // 2026-08-19: "so wie im Browser auch! … Auswahl schränkt das weiter ein").
            if shuffleScope.isScoped {
                randomItem = try await client.randomItem(folderSelections: shuffleScope.selections, search: search.isEmpty ? nil : search)
            } else {
                randomItem = try await client.randomItem(libraryId: library.id, folder: folder, search: search.isEmpty ? nil : search)
            }
        } catch {
            randomError = "In diesem Bereich wurde kein Video gefunden."
        }
    }

    #if os(macOS)
    // Extracted out of the `.onChange` closure — real bug hit 2026-08-19: the nested
    // ternary + struct-literal-inside-struct-literal expression made the Swift type-checker
    // time out ("unable to type-check this expression in reasonable time") when inlined
    // directly in the view's modifier chain. A plain function body type-checks statement by
    // statement instead of as one giant expression.
    private func openRandomPlayerWindow(for item: Item) {
        let context = RandomContext(libraryId: library.id, folderSelections: shuffleScope.isScoped ? shuffleScope.selections : nil, folder: folder, search: search.isEmpty ? nil : search)
        PlayerLaunchCoordinator.shared.present(PlayerLaunchRequest(item: item, queue: [], queueIndex: nil, randomContext: context, startFromBeginning: false), openWindow: openWindow)
        randomItem = nil
    }
    #endif

    @ViewBuilder
    private func destinationView(for dest: FolderDestination) -> some View {
        // Top-level folder in a TV library = a show — hand off to the season browser
        // instead of a flat/drilldown item grid (mirrors the web app's default behavior).
        if dest.library.isTV, folder == nil, let name = dest.folder {
            ShowSeasonsView(library: dest.library, folder: name)
        } else if let tile = folders.first(where: { $0.name == dest.folder }), tile.drilldown {
            ItemGridView(library: dest.library, folder: dest.folder, showsFolderTiles: true)
        } else {
            ItemGridView(library: dest.library, folder: dest.folder, showsFolderTiles: false)
        }
    }

    // Movies libraries never show folder tiles at all in the web app — every movie
    // lives in its own folder, so browsing is always flat (`flatView` in grid.js is
    // forced true for `kind==="movies"`). TV/private libraries do use folder tiles.
    private var effectivelyShowsFolderTiles: Bool { showsFolderTiles && !library.isMovies }

    private func load() async {
        isLoading = items.isEmpty && folders.isEmpty
        defer { isLoading = false }
        do {
            // User-Anfrage 2026-08-19: "wenn ich in den Serien suche, dann soll er nur
            // Serien zeigen, keine Folgen" — die normale Suche (unten) läuft über
            // /api/items?search= und liefert flache EPISODEN-Treffer, weil sie gegen
            // Episode-Titel/relPath matcht. Nur im TV-Library-ROOT (nicht innerhalb
            // einer schon geöffneten Serie) macht eine Serien-Namens-Suche Sinn — dort
            // werden stattdessen alle Show-Ordner geladen und client-seitig nach Namen
            // gefiltert, keine Episoden-Treffer mehr gemischt.
            if library.kind == "tv", folder == nil, !search.isEmpty {
                let allFolders = try await client.fetchFolders(libraryId: library.id, parent: nil)
                let q = search.trimmingCharacters(in: .whitespaces)
                folders = allFolders.filter {
                    ($0.metadata?.title ?? $0.displayName).localizedCaseInsensitiveContains(q)
                }
                items = []
                errorMessage = nil
                return
            }
            // Server semantics (internal/store/sqlite.go ListItems): folder="" means
            // "no filter at all" (every item in the library, any depth!), folder="/"
            // means "only items with no subfolder", folder="<path>" means "under path,
            // recursively". Root of a non-flat library MUST send "/", not omit the
            // param, or every nested item leaks into the root view alongside the tiles.
            // User-Anfrage 2026-08-19: "der Favoritenfilter soll alle Favoriten aus dieser
            // Ebene und den Ebenen darunter anzeigen, so wie im Browser auch" — CLAUDE.md
            // "Filter-UI": Favoriten-Filter ist eine flache, rekursive Ansicht (wie
            // Duplikate/Verdächtige Zuordnungen), NICHT auf die aktuelle Ordner-Ebene
            // beschränkt (der bisherige `folder ?? "/"`-Fallback für TV/Privat-Libs zeigt
            // nur die Root-Ebene selbst, keine Unterordner — Favoriten in Unterordnern
            // blieben dadurch unsichtbar). Gleiche Behandlung wie eine aktive Suche.
            let effectiveFolder: String?
            if !search.isEmpty || favoritesOnly {
                // Root spans the whole library, recursively; a subfolder stays scoped to
                // that folder (also recursive) — matches grid.js's search-vs-flatView branch.
                effectiveFolder = folder
            } else if library.isMovies {
                effectiveFolder = nil
            } else {
                effectiveFolder = folder ?? "/"
            }
            async let itemsTask = client.fetchItems(
                libraryId: library.id,
                folder: effectiveFolder,
                search: search.isEmpty ? nil : search,
                sort: sort,
                ascending: ascending,
                watched: watchedFilter,
                favoritesOnly: favoritesOnly,
                buckets: selectedBuckets.map(\.rawValue)
            )
            async let foldersTask: [FolderTile] = effectivelyShowsFolderTiles && search.isEmpty && !favoritesOnly
                ? client.fetchFolders(libraryId: library.id, parent: folder)
                : []
            // Same-metadataId duplicates (multiple file variants of one movie/episode)
            // collapse into a single tile with a "×N" badge — matches the web app's
            // `groupVariants`, was missing entirely here (real bug hit 2026-08-19: user
            // saw duplicate movies as two separate tiles).
            items = groupVariants(try await itemsTask)
            folders = sortFolderTiles(try await foldersTask)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // User-Report 2026-09-03 (Apple TV): "Filter Veröffentlicht und Hinzugefügt zeigen keine
    // Veränderung" — kein tvOS-Bug, sondern eine bestehende Lücke der ganzen App (Mac/iOS
    // gleichermaßen betroffen, gleiche Datei): `sort`/`ascending` wirkten bisher nur auf
    // `items`, nie auf `folders`. Der Server liefert Ordner-/Show-Kacheln immer NATSORT-
    // alphabetisch zurück (`internal/store/sqlite.go topLevelFolders`, kein `sort=`-Query
    // auf `/api/libraries/{id}/folders`) — identisch zum Browser (`grid.js` sortiert Kacheln
    // ausschließlich über `folderCollator`, ignoriert den Sort-Dropdown komplett). Für
    // Laufzeit/Auflösung/Zuletzt-abgespielt gibt es ohnehin keine sinnvolle Kachel-Entsprechung
    // (bleibt bei der Server-Reihenfolge). Für Titel/Veröffentlicht/Hinzugefügt/Bewertung sind
    // die nötigen Werte bereits vorhanden (`FolderTile.metadata`/`.addedAt`, letzteres neu als
    // `MAX(added_at)` pro Ordner vom Server) — hier sortieren wir client-seitig nach.
    // Folgefund (User-Report "Sortierung nach Name umgekehrt getestet, Pfeil ändert sich,
    // Sortierung blieb gleich"): `.title` gehörte ursprünglich zur "keine Entsprechung"-
    // Gruppe, in der Annahme, Namen blieben ohnehin immer alphabetisch — falsch, `ascending`
    // soll auch hier umkehren, der Server liefert aber IMMER aufsteigend (NATSORT). Jetzt
    // ebenfalls client-seitig sortiert.
    private func sortFolderTiles(_ tiles: [FolderTile]) -> [FolderTile] {
        func precedes<T: Comparable>(_ a: T?, _ b: T?, ascending: Bool) -> Bool {
            switch (a, b) {
            case let (a?, b?): return ascending ? a < b : a > b
            case (nil, nil): return false
            case (nil, _): return false // fehlender Wert landet ans Ende, unabhängig von ascending
            case (_, nil): return true
            }
        }
        switch sort {
        case .title:
            return tiles.sorted {
                let result = ($0.metadata?.title ?? $0.displayName).localizedStandardCompare($1.metadata?.title ?? $1.displayName)
                return ascending ? result == .orderedAscending : result == .orderedDescending
            }
        case .released:
            return tiles.sorted { precedes($0.metadata?.releaseDate, $1.metadata?.releaseDate, ascending: ascending) }
        case .added:
            return tiles.sorted { precedes($0.addedAt, $1.addedAt, ascending: ascending) }
        case .rating:
            return tiles.sorted { precedes($0.metadata?.rating, $1.metadata?.rating, ascending: ascending) }
        case .duration, .resolution, .played:
            return tiles
        }
    }
}

struct FolderCard: View {
    let tile: FolderTile
    @EnvironmentObject var client: GoldfishClient
    #if os(tvOS)
    // Gleiches Muster wie `ItemCard` — siehe dortiger Kommentar zum nativen
    // tvOS-Fokushintergrund, der sich sonst über Poster UND Titeltext erstreckt.
    @Environment(\.isFocused) private var isFocused
    let library: Library
    #endif

    var body: some View {
        #if os(tvOS)
        // Fünfter Anlauf 2026-09-04 (User-Foto-Beleg: der native Fokus-Rahmen überlappt
        // sichtbar den Titeltext darunter, macht ihn kaum lesbar) — NICHT wieder versuchen,
        // den Rahmen selbst wegzubekommen (vier Ansätze bereits gescheitert: .buttonStyle(.card),
        // .focusEffectDisabled(), Struktur-Split Poster/Titel, .buttonBorderShape — alle drei
        // letzteren stecken unten noch drin, halfen aber nicht vollständig). Stattdessen
        // Workaround am eigentlichen Symptom: großzügiger Abstand zwischen Poster und
        // Titeltext, damit der überschießende Rahmen selbst wenn er weiterhin übergreift,
        // den Text nicht mehr erreicht.
        VStack(alignment: .leading, spacing: 24) {
            NavigationLink(value: FolderDestination(library: library, folder: tile.name)) {
                posterSection
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .buttonBorderShape(.roundedRectangle(radius: 8))

            titleSection
        }
        .contentShape(Rectangle())
        #else
        VStack(alignment: .leading, spacing: 6) {
            posterSection
            titleSection
        }
        .contentShape(Rectangle())
        #endif
    }

    @ViewBuilder
    private var posterSection: some View {
            PosterImage(url: posterURL, placeholderSystemImage: "folder")
                .clipShape(RoundedRectangle(cornerRadius: 8))
                // User-Report 2026-09-03: Show-Kacheln zeigten weder Bewertung noch Jahr/
                // Folgenanzahl — nur den nackten itemCount unten rechts. Rating-Badge jetzt
                // oben rechts, gleiches Capsule-Styling wie `ItemCard.posterSection` (dort
                // .yellow für den Stern), damit beide Kachel-Arten optisch zusammenpassen.
                .overlay(alignment: .topTrailing) {
                    if let ratingLabel = tile.ratingLabel {
                        Text(ratingLabel)
                            .font(.caption2.bold())
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.black.opacity(0.6), in: Capsule())
                            .foregroundStyle(.yellow)
                            .padding(6)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    Text("\(tile.itemCount)")
                        .font(.caption2.bold())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.black.opacity(0.6), in: Capsule())
                        .foregroundStyle(.white)
                        .padding(6)
                }
                #if os(tvOS)
                .scaleEffect(isFocused ? 1.08 : 1.0)
                .shadow(color: .black.opacity(isFocused ? 0.5 : 0), radius: 12, y: 6)
                .animation(.easeOut(duration: 0.2), value: isFocused)
                #endif
    }

    @ViewBuilder
    private var titleSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(tile.metadata?.title ?? tile.displayName)
                .font(.subheadline.weight(.medium))
                .lineLimit(2)
                .foregroundStyle(.primary)
            // Jahr · Folgenanzahl — nur bei echten Show-Ordnern (mit TMDB-Metadata), siehe
            // `FolderTile.episodeMetaLabel`. Generische Ordner (z. B. in Privat-Libs) bleiben
            // unverändert ohne zweite Zeile.
            if let meta = tile.episodeMetaLabel {
                Text(meta)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var posterURL: URL? {
        if let metadataId = tile.metadataId, let url = client.posterURL(metadataId: metadataId) {
            return url
        }
        if tile.thumbItemId > 0, let url = client.thumbURL(itemId: tile.thumbItemId) {
            return url
        }
        return nil
    }
}

struct ItemCard: View {
    let item: Item
    /// Real bug hit 2026-08-19: hatte das früher hart auf 150 einprogrammiert — brach
    /// HomeView's Reihen, die 130 nutzen (Poster überlappte die Nachbarkachel, weil
    /// PosterImage.fixedWidth die äußere `.frame(width: 130)`-Vorgabe ignorierte). JEDER
    /// Aufrufer muss seine tatsächliche Kartenbreite hier mitgeben, nicht nur außen per
    /// `.frame(width:)` — beide müssen übereinstimmen.
    var width: CGFloat = 150
    @EnvironmentObject var client: GoldfishClient
    @EnvironmentObject var downloads: DownloadManager
    @State private var watched: Bool
    @State private var favorite: Bool
    #if os(tvOS)
    // tvOS-Fix 2026-09-03, zweiter (korrekter) Anlauf: weder `.buttonStyle(.plain)`
    // (kein Fokus-Feedback) noch `.buttonStyle(.card)` (verzerrt/beschneidet das
    // Poster durch eigenes Layout-Padding) passen für unser zusammengesetztes
    // Poster+Titeltext-Layout. Der Fokus-Effekt wird stattdessen hier selbst,
    // NUR auf dem Poster, über `@Environment(\.isFocused)` gebaut (skaliert +
    // Schatten) — der Titeltext darunter bleibt unverändert an fester Position,
    // dadurch keine variierende Box mehr je nach Zeilenzahl.
    @Environment(\.isFocused) private var isFocused
    // tvOS-Fix 2026-09-03, DRITTER Anlauf (User: "das weiße Fenster ist immer noch
    // da", nachdem `.buttonStyle(.card)` UND `.focusEffectDisabled()` beide nicht
    // reichten): der native tvOS-Fokushintergrund gehört zum `NavigationLink`
    // selbst und umfasst IMMER dessen kompletten Label-Inhalt — solange Poster UND
    // Titeltext gemeinsam das Label bilden, bleibt die Fläche zwangsläufig so groß
    // wie beide zusammen (und variiert mit der Zeilenzahl des Titels). Einzig
    // wirksamer Ausweg: der `NavigationLink` umschließt auf tvOS NUR noch das
    // Poster, der Titeltext steht strukturell AUSSERHALB (separates, nicht
    // fokussierbares Label direkt darunter) — dafür braucht `ItemCard` hier die
    // Navigations-Queue selbst, um den Link intern zu bauen statt sich vom
    // Aufrufer umschließen zu lassen (siehe `body` unten).
    var queue: [Item] = []
    #endif

    init(item: Item, width: CGFloat = 150, queue: [Item] = []) {
        self.item = item
        self.width = width
        _watched = State(initialValue: item.watched)
        _favorite = State(initialValue: item.favorite)
        #if os(tvOS)
        self.queue = queue
        #endif
    }

    var body: some View {
        #if os(tvOS)
        // Fünfter Anlauf — siehe ausführlicher Kommentar bei `FolderCard`: großzügiger
        // Abstand statt eines weiteren Versuchs, den nativen Fokus-Rahmen selbst zu entfernen.
        VStack(alignment: .leading, spacing: 24) {
            NavigationLink(value: ItemNavTarget(item: item, queue: queue)) {
                posterSection
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .buttonBorderShape(.roundedRectangle(radius: 8))

            titleSection
        }
        .contentShape(Rectangle())
        #else
        VStack(alignment: .leading, spacing: 4) {
            posterSection
            titleSection
        }
        .contentShape(Rectangle())
        #endif
    }

    @ViewBuilder
    private var posterSection: some View {
            // fixedWidth: siehe PosterImage.fixedWidth-Kommentar für den Bug, den das umgeht.
            PosterImage(url: posterURL, fixedWidth: width)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .topLeading) {
                    VStack(spacing: 3) {
                        PosterToggleBadge(isOn: watched, onSymbol: "checkmark.circle.fill", offSymbol: "checkmark.circle", tint: .green) {
                            toggleWatched()
                        }
                        PosterToggleBadge(isOn: favorite, onSymbol: "heart.fill", offSymbol: "heart", tint: .red) {
                            toggleFavorite()
                        }
                    }
                    .padding(6)
                }
                .overlay(alignment: .topTrailing) {
                    // Rating above, variant-count badge below it — same stacking order as
                    // the web app's card overlay table (CLAUDE.md "Kachel-Overlay-Positionen"):
                    // never side-by-side, top:6 vs top:34, so they don't collide.
                    VStack(alignment: .trailing, spacing: 4) {
                        if let ratingLabel = item.ratingLabel {
                            Text(ratingLabel)
                                .font(.caption2.bold())
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(.black.opacity(0.6), in: Capsule())
                                .foregroundStyle(.yellow)
                        }
                        if let variantCount = item.variantCount, variantCount > 1 {
                            Text("×\(variantCount)")
                                .font(.caption2.bold())
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(.black.opacity(0.6), in: Capsule())
                                .foregroundStyle(.white)
                        }
                    }
                    .padding(6)
                }
                .overlay(alignment: .bottomLeading) {
                    if !item.resolutionLabel.isEmpty {
                        Text(item.resolutionLabel)
                            .font(.caption2.bold())
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.black.opacity(0.6), in: Capsule())
                            .foregroundStyle(.white)
                            .padding(6)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    Text(item.durationLabel)
                        .font(.caption2.bold())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.black.opacity(0.6), in: Capsule())
                        .foregroundStyle(.white)
                        .padding(6)
                }
                #if os(tvOS)
                .scaleEffect(isFocused ? 1.08 : 1.0)
                .shadow(color: .black.opacity(isFocused ? 0.5 : 0), radius: 12, y: 6)
                .animation(.easeOut(duration: 0.2), value: isFocused)
                #endif
    }

    // Episodes: show name on top, "S07E23 · Episodentitel" below.
    // Movies/everything else: title on top, year below (when known).
    @ViewBuilder
    private var titleSection: some View {
            if item.isEpisode {
                Text(item.showName ?? item.displayTitle)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                    .foregroundStyle(.primary)
                HStack(spacing: 4) {
                    if let code = item.episodeCode {
                        Text(code).fontWeight(.semibold)
                    }
                    if let name = item.episodeName, !name.isEmpty {
                        Text(name)
                    }
                }
                .font(.caption)
                .lineLimit(1)
                .foregroundStyle(.secondary)
            } else {
                Text(item.displayTitle)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                    .foregroundStyle(.primary)
                if item.isPrivateStyle {
                    // YouTube-/Urlaubsvideo-Style Privat-Library (User-Anfrage 2026-08-19):
                    // Kanalname (Top-Ordner) + Erscheinungsdatum statt Jahr — anders als der
                    // Browser (CLAUDE.md: Top-Ordner NICHT auf der Kachel), bewusste
                    // App-spezifische Abweichung auf expliziten Nutzerwunsch.
                    if let channelName = item.channelName {
                        Text(channelName)
                            .font(.caption)
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                    }
                    if let releasedDateLabel = item.releasedDateLabel {
                        Text(releasedDateLabel)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } else if let year = item.metadata?.year {
                    Text(String(year))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
    }

    private func toggleWatched() {
        let newValue = !watched
        watched = newValue
        Task { try? await client.setWatched(itemId: item.id, watched: newValue) }
        // Keeps a downloaded item's frozen tile-snapshot in sync too — see
        // `Item.withWatched`'s doc comment.
        downloads.updateCachedWatched(itemId: item.id, watched: newValue)
    }

    private func toggleFavorite() {
        let newValue = !favorite
        favorite = newValue
        Task { try? await client.setFavorite(itemId: item.id, favorite: newValue) }
    }

    private var posterURL: URL? {
        // Offline-Poster (User-Anfrage 2026-08-19): für heruntergeladene Items bevorzugt das
        // beim Download-Start gecachte Poster von Platte, statt live vom Server zu laden —
        // sonst zeigt die Kachel ohne Netz nur den Platzhalter.
        if let cached = downloads.cachedPosterURL(itemId: item.id) { return cached }
        if let metadataId = item.metadataId, let url = client.posterURL(metadataId: metadataId, posterPath: item.metadata?.posterPath) {
            return url
        }
        return client.thumbURL(itemId: item.id)
    }
}

#if os(tvOS)
/// tvOS-Fix 2026-09-03: Ersatz für das Sortieren-`Menu` (siehe Kommentar an der
/// Aufrufstelle) — eine echte Vollbild-Liste statt eines Toolbar-Popovers, das auf tvOS
/// unzuverlässig nichts sichtbares öffnete. Tap auf eine Zeile schließt das Sheet direkt
/// (Einfachauswahl, kein "offen halten" nötig wie beim Filter-Sheet).
// Nicht `private` — wird auch von `PersonItemsView` für ihr eigenes Sortieren-Menü
// wiederverwendet (gleiches tvOS-Menu-in-Toolbar-Problem, siehe dortiger Kommentar).
struct TVSortSheet: View {
    @Binding var sort: ItemSort
    @Binding var ascending: Bool
    @Environment(\.dismiss) private var dismiss

    // tvOS-Fix 2026-09-03 (User-Report: "weiße Schrift hinter weißem Balken"): `.navigationTitle`
    // + `.toolbar` überlappten sich in diesem Sheet sichtbar statt sich ordentlich
    // anzuordnen — ein eigener, manuell gebauter Header umgeht das System-Nav-Bar-Layout
    // komplett, statt gegen dessen tvOS-Sheet-Eigenheiten anzukämpfen.
    // tvOS-Fix 2026-09-03 (Folge-Bug, User-Report "gleicher Fehler" nach dem Sheet-Umbau):
    // `.sheet` präsentiert auf tvOS NICHT automatisch vollbildschirm wie auf iOS, sondern als
    // zentriertes "Form-Sheet", das sich an die intrinsische Größe seines Inhalts anpasst.
    // Ohne explizites `.frame` schrumpfte der VStack auf die Breite/Höhe des Header-Texts —
    // die `List` darunter bekam 0pt Höhe zugewiesen und war unsichtbar (nur der schwebende
    // "Sortieren"-Pill war zu sehen). Fix: fester `.frame` auf dem VStack, groß genug für
    // Header + alle Listenzeilen auf einem 10-Fuß-Screen.
    var body: some View {
        VStack(spacing: 0) {
            Text("Sortieren")
                .font(.title2.bold())
                .padding()
            List {
                // User-Anfrage 2026-09-03: der separate "Richtung"-Eintrag ganz unten (eigene
                // Section, eine Interaktion "extra") wirkte losgelöst von der eigentlichen
                // Sortierauswahl. Fix: erneutes Antippen der BEREITS gewählten Option togglet
                // jetzt die Richtung direkt — kein zweiter Menüpunkt mehr nötig, ein Pfeil
                // (↑/↓) statt Haken zeigt bei der aktiven Zeile zusätzlich die Richtung an.
                Section("Sortieren nach") {
                    ForEach(ItemSort.allCases) { option in
                        Button {
                            if sort == option {
                                ascending.toggle()
                            } else {
                                sort = option
                                ascending = option.defaultAscending
                            }
                            dismiss()
                        } label: {
                            HStack {
                                Text(option.label)
                                Spacer()
                                if sort == option {
                                    Image(systemName: ascending ? "arrow.up" : "arrow.down")
                                }
                            }
                        }
                    }
                }
            }
        }
        .frame(width: 900, height: 700)
    }
}

/// tvOS-Fix 2026-09-03: Ersatz für das Filter-`Menu`. Anders als beim Sortieren-Sheet
/// bleibt dieses Sheet nach jedem Tap offen (Mehrfachauswahl bei den Auflösungs-Buckets),
/// der User schließt es selbst über den "Fertig"-Button oder die Menü-Taste der Fernbedienung.
private struct TVFilterSheet: View {
    @Binding var watchedFilter: WatchedFilter
    @Binding var favoritesOnly: Bool
    @Binding var selectedBuckets: Set<ResolutionBucket>
    @Binding var showTotalSize: Bool
    @Environment(\.dismiss) private var dismiss

    // tvOS-Fix 2026-09-03: siehe Kommentar bei `TVSortSheet` — manueller Header statt
    // `.navigationTitle`+`.toolbar`, die sich hier sichtbar überlappt hatten ("Filter"-Titel
    // hinter dem "Fertig"-Button, beides weiß auf weiß kaum lesbar).
    // tvOS-Fix 2026-09-03 (Folge-Bug): siehe Kommentar bei `TVSortSheet` — explizites `.frame`
    // nötig, sonst schrumpft das Sheet auf die Header-Textgröße und die Liste ist unsichtbar.
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Filter")
                    .font(.title2.bold())
                Spacer()
                Button("Fertig") { dismiss() }
            }
            .padding()
            List {
                Section("Gesehen") {
                    ForEach(WatchedFilter.allCases) { option in
                        Button {
                            watchedFilter = option
                        } label: {
                            HStack {
                                Text(option.label)
                                Spacer()
                                if watchedFilter == option {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }
                Section {
                    Button {
                        favoritesOnly.toggle()
                    } label: {
                        HStack {
                            Label("Nur Favoriten", systemImage: favoritesOnly ? "heart.fill" : "heart")
                            Spacer()
                            if favoritesOnly {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
                Section("Auflösung") {
                    ForEach(ResolutionBucket.allCases) { bucket in
                        Button {
                            if selectedBuckets.contains(bucket) {
                                selectedBuckets.remove(bucket)
                            } else {
                                selectedBuckets.insert(bucket)
                            }
                        } label: {
                            HStack {
                                Text(bucket.label)
                                Spacer()
                                if selectedBuckets.contains(bucket) {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }
                Section {
                    Button {
                        showTotalSize.toggle()
                    } label: {
                        HStack {
                            Text("Gesamtgröße anzeigen")
                            Spacer()
                            if showTotalSize {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
        }
        .frame(width: 900, height: 900)
    }
}

/// tvOS-Fix 2026-09-04: Ersatz für `.searchable(text:)`, das auf iOS/macOS funktioniert,
/// auf tvOS aber nirgends ein sichtbares Sucheingabefeld erzeugt (User-Report: "Was
/// übrigens auch noch fehlt, ist ein Suchfeld"). Gleiches Sheet-Muster wie Sortieren/
/// Filter — ein `TextField` reicht hier, tvOS öffnet dafür automatisch seine native
/// Tastatur, sobald es fokussiert wird (identisches Verhalten wie im Login-Formular).
private struct TVSearchSheet: View {
    @Binding var search: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 24) {
            HStack {
                Text("Suchen")
                    .font(.title2.bold())
                Spacer()
                Button("Fertig") { dismiss() }
            }
            TextField("Titel oder Schauspieler…", text: $search)
                .tvLoginFieldStyle()
            if !search.isEmpty {
                Button {
                    search = ""
                } label: {
                    Label("Suche löschen", systemImage: "xmark.circle")
                }
            }
            Spacer()
        }
        .padding(40)
        .frame(width: 900, height: 500)
    }
}
#endif

// Hält ein `Menu` über mehrere Taps offen statt sich nach jedem Button-Tap zu schließen —
// nötig für Mehrfachauswahl-Menüs (Auflösungs-Filter). `.menuActionDismissBehavior` kam erst
// mit iOS 16.4/macOS 13.3 dazu, App-Deployment-Target ist iOS 16.0 — daher #available-Gate
// statt direktem Aufruf.
private extension View {
    @ViewBuilder
    func modernMenuStaysOpen() -> some View {
        // `.disabled` existiert als MenuActionDismissBehavior-Fall NUR auf iOS/iPadOS
        // (macOS-Menüs schließen sich systemweit immer nach einem Klick, dort nicht
        // übersteuerbar) — deshalb zusätzlich zum Availability-Check ein Plattform-Gate.
        #if os(iOS)
        if #available(iOS 16.4, *) {
            self.menuActionDismissBehavior(.disabled)
        } else {
            self
        }
        #else
        self
        #endif
    }
}
