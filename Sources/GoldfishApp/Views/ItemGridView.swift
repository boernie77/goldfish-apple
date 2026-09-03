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
    private let cardWidth: CGFloat = 150
    private var columns: [GridItem] { [GridItem(.adaptive(minimum: cardWidth, maximum: cardWidth), spacing: 12, alignment: .top)] }

    /// Ausgelagert aus `body` — der große kombinierte ViewBuilder-Ausdruck brachte den
    /// Type-Checker sonst zum Timeout ("unable to type-check ... in reasonable time"),
    /// nachdem `displayedFolders`/`displayedItems` dazukamen.
    @ViewBuilder
    private var itemGrid: some View {
        LazyVGrid(columns: columns, spacing: 16) {
            ForEach(displayedFolders) { tile in
                NavigationLink(value: FolderDestination(library: library, folder: tile.name)) {
                    FolderCard(tile: tile)
                        .frame(width: cardWidth)
                }
                .buttonStyle(.plain)
                .focusableCompat(false)
            }
            ForEach(displayedItems) { item in
                NavigationLink(value: ItemNavTarget(item: item, queue: items)) {
                    ItemCard(item: item)
                        .frame(width: cardWidth)
                }
                .buttonStyle(.plain)
                .focusableCompat(false)
            }
        }
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
                    }
                    .padding(.vertical)
                }
                .overlay(alignment: .trailing) {
                    if !folders.isEmpty || !items.isEmpty {
                        AlphabetSidebar(selected: $alphaFilter)
                            .padding(.trailing, 4)
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
                Button {
                    Task { await playRandom() }
                } label: {
                    if isLoadingRandom {
                        ProgressView()
                    } else {
                        Label("Zufällig", systemImage: "shuffle")
                    }
                }
                .disabled(isLoadingRandom)

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
            }
        }
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
            folders = try await foldersTask
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct FolderCard: View {
    let tile: FolderTile
    @EnvironmentObject var client: GoldfishClient

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PosterImage(url: posterURL, placeholderSystemImage: "folder")
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .bottomTrailing) {
                    Text("\(tile.itemCount)")
                        .font(.caption2.bold())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.black.opacity(0.6), in: Capsule())
                        .foregroundStyle(.white)
                        .padding(6)
                }

            Text(tile.metadata?.title ?? tile.displayName)
                .font(.subheadline.weight(.medium))
                .lineLimit(2)
                .foregroundStyle(.primary)
        }
        .contentShape(Rectangle())
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

    init(item: Item, width: CGFloat = 150) {
        self.item = item
        self.width = width
        _watched = State(initialValue: item.watched)
        _favorite = State(initialValue: item.favorite)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
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

            // Episodes: show name on top, "S07E23 · Episodentitel" below.
            // Movies/everything else: title on top, year below (when known).
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
        .contentShape(Rectangle())
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
