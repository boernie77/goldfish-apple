import SwiftUI
import GoldfishCore

/// Unifies server libraries and local (offline) libraries for the grid — mirrors the
/// Android app's approach: local libraries are ordinary library tiles, not a separate section.
enum LibraryDestination: Hashable {
    case server(Library)
    /// One or more local libraries — more than one when the user merged them in Settings
    /// ("Bibliotheken zusammenlegen"). No cap on how many, unlike Android's fixed 2
    /// (User-Anfrage 2026-08-18: "nein, mehr als 2").
    case local([LocalLibrary])
    case collections
    case playlists
}

struct LibrariesView: View {
    /// Bound from `MainTabView` and reset to empty every time the "Bibliotheken"-Tab is
    /// (re-)selected — so clicking it always lands back on the library overview instead of
    /// staying wherever the user last drilled down to (User-Anfrage 2026-08-18).
    @Binding var path: NavigationPath

    @EnvironmentObject var client: GoldfishClient
    @EnvironmentObject var localLibrary: LocalLibraryManager
    @EnvironmentObject var shuffleScope: ShuffleScope
    @Environment(\.scenePhase) private var scenePhase
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif
    @State private var libraries: [Library] = []
    @State private var errorMessage: String?
    @State private var isLoading = true
    // User-Anfrage 2026-08-19: "wenn ich wirklich offline bin, dann erscheinen gar keine
    // Bibliotheken, auch nicht die lokalen!!" — `errorMessage` ersetzte bisher die KOMPLETTE
    // Ansicht bei einem fehlgeschlagenen fetchLibraries()-Call, inkl. der lokalen
    // Bibliotheken (die gar keinen Netzwerk-Call brauchen). Jetzt: Server-Bibliotheken werden
    // beim ersten erfolgreichen Laden pro User auf Platte gecacht; schlägt ein Reload fehl,
    // zeigt die App weiterhin die zuletzt bekannte Liste (+ "Offline"-Badge) statt gar nichts.
    @State private var isOffline = false
    // Keyed by "server:<id>" / "local:<uuid>" — one representative poster per library tile.
    @State private var previewURLs: [String: URL] = [:]

    // Globales "Zufällig abspielen" über eine wählbare Bibliotheks-Auswahl (User-Anfrage
    // 2026-08-19), analog zum Browser-🎯-Dialog, hier aber library- statt ordnerbasiert.
    @State private var randomItem: Item?
    @State private var isLoadingRandom = false
    @State private var randomError: String?
    @State private var showingScopeSheet = false

    private let columns = [GridItem(.adaptive(minimum: 190, maximum: 220), spacing: 20, alignment: .top)]

    private var mergedLocalLibraries: [LocalLibrary] {
        localLibrary.libraries.filter { localLibrary.mergedLibraryIds.contains($0.id) }
    }
    private var standaloneLocalLibraries: [LocalLibrary] {
        // A single leftover "merged" library (e.g. right after deleting a sibling) doesn't
        // meaningfully merge into anything — show it as a normal standalone tile instead.
        mergedLocalLibraries.count >= 2
            ? localLibrary.libraries.filter { !localLibrary.mergedLibraryIds.contains($0.id) }
            : localLibrary.libraries
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if isLoading {
                    ProgressView()
                } else if libraries.isEmpty && localLibrary.libraries.isEmpty {
                    // Nur wenn WIRKLICH nichts da ist (weder Server-Cache noch lokale Libs)
                    // zeigen wir eine Vollbild-Meldung — ein reiner Netzwerkfehler mit noch
                    // leerem Cache landet hier zwangsläufig auch. Anders als früher gibt es
                    // jetzt einen "Erneut versuchen"-Button — vorher war der User in diesem
                    // Zustand bis zum App-Neustart gefangen (keine Pull-to-Refresh-Geste
                    // ohne ScrollView, kein Retry-Knopf).
                    VStack(spacing: 16) {
                        ContentUnavailableMessage(text: errorMessage ?? "Keine Bibliotheken verfügbar.")
                        Button {
                            Task { await load() }
                        } label: {
                            Label("Erneut versuchen", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isLoading)
                    }
                } else {
                    ScrollView {
                        if isOffline {
                            Button {
                                Task { await load() }
                            } label: {
                                Label(isLoading ? "Verbinde…" : "Offline — zuletzt geladene Bibliotheken · erneut versuchen", systemImage: "wifi.slash")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal)
                            }
                            .buttonStyle(.plain)
                            .disabled(isLoading)
                        }
                        LazyVGrid(columns: columns, spacing: 16) {
                            ForEach(libraries) { lib in
                                NavigationLink(value: LibraryDestination.server(lib)) {
                                    LibraryCard(name: lib.name, kind: lib.kind, isLocal: false, previewURL: previewURLs["server:\(lib.id)"], isOffline: isOffline)
                                }
                                .buttonStyle(.plain)
                                .focusableCompat(false)
                            }
                            ForEach(standaloneLocalLibraries) { lib in
                                NavigationLink(value: LibraryDestination.local([lib])) {
                                    LibraryCard(name: lib.name, kind: lib.kind, isLocal: true, previewURL: previewURLs["local:\(lib.id)"], isUnavailable: localLibrary.unavailableLibraryIds.contains(lib.id))
                                }
                                .buttonStyle(.plain)
                                .focusableCompat(false)
                            }
                            if mergedLocalLibraries.count >= 2 {
                                NavigationLink(value: LibraryDestination.local(mergedLocalLibraries)) {
                                    LibraryCard(
                                        name: localLibrary.mergedLibraryName.isEmpty
                                            ? mergedLocalLibraries.map(\.name).joined(separator: " + ")
                                            : localLibrary.mergedLibraryName,
                                        kind: mergedLocalLibraries.first?.kind ?? "private",
                                        isLocal: true,
                                        previewURL: previewURLs["local:\(mergedLocalLibraries[0].id)"],
                                        isUnavailable: mergedLocalLibraries.contains { localLibrary.unavailableLibraryIds.contains($0.id) }
                                    )
                                }
                                .buttonStyle(.plain)
                                .focusableCompat(false)
                            }

                            // Sammlungen/Playlists sind Pseudo-Bibliotheken, keine echten
                            // Ordner mit Videos — bleiben deshalb immer am Ende der Übersicht,
                            // nicht ganz vorne (User-Anfrage 2026-08-18). WICHTIG: value-based
                            // NavigationLink wie alle anderen Kacheln, NICHT `destination:` —
                            // ein destination-based Push ist NICHT Teil der gebundenen `path`
                            // NavigationPath und überlebt daher fälschlich den Tab-Reset (real
                            // bug hit 2026-08-19: Sammlung blieb offen, obwohl der Bibliotheken-
                            // Tab erneut angetippt wurde).
                            NavigationLink(value: LibraryDestination.collections) {
                                SpecialLibraryCard(name: "Sammlungen", systemImage: "square.stack.fill", colors: [.teal, .cyan])
                            }
                            .buttonStyle(.plain)
                            .focusableCompat(false)

                            NavigationLink(value: LibraryDestination.playlists) {
                                SpecialLibraryCard(name: "Playlists", systemImage: "music.note.list", colors: [.orange, .pink])
                            }
                            .buttonStyle(.plain)
                            .focusableCompat(false)
                        }
                        .padding()
                    }
                    .navigationDestination(for: LibraryDestination.self) { dest in
                        switch dest {
                        case .server(let lib): ItemGridView(library: lib)
                        case .local(let libs): LocalLibraryItemsView(libraries: libs)
                        case .collections: CollectionsView()
                        case .playlists: PlaylistsView()
                        }
                    }
                }
            }
            .navigationTitle("Bibliotheken")
            .toolbar {
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
                    .disabled(isLoadingRandom || libraries.isEmpty)

                    Button {
                        showingScopeSheet = true
                    } label: {
                        // Real bug hit 2026-08-19: "target"/"checkmark.circle" as a
                        // conditional pair made the button effectively invisible for the
                        // user ("finde ich das nur nicht?") — likely an SF-Symbol-name issue
                        // on this deployment target rendering blank. `slider.horizontal.3`
                        // has existed since SF Symbols 1.0, safest possible choice here.
                        Label("Bibliotheken für Zufall wählen", systemImage: "slider.horizontal.3")
                            .foregroundStyle(shuffleScope.isScoped ? Color.accentColor : Color.primary)
                    }
                    .disabled(libraries.isEmpty)
                }
            }
            .sheet(isPresented: $showingScopeSheet) {
                ShuffleScopeSheet(libraries: libraries)
            }
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
                    PlayerView(item: randomItem, randomContext: RandomContext(libraryId: nil, folderSelections: shuffleScope.isScoped ? shuffleScope.selections : nil, folder: nil, search: nil))
                }
            }
            #endif
            .task { await load() }
            .refreshable { await load() }
            // Zurück im Vordergrund (typisch: war offline, jetzt wieder online) →
            // Bibliotheken + Vorschaubilder neu laden. Ohne das kam die Ansicht
            // nach einer Offline-Phase nie von selbst zurück, selbst wenn die
            // Verbindung längst wieder stand.
            .onChange(of: scenePhase) { phase in
                if phase == .active, !isLoading { Task { await load() } }
            }
        }
    }

    private func playRandom() async {
        isLoadingRandom = true
        defer { isLoadingRandom = false }
        do {
            randomItem = try await client.randomItem(folderSelections: shuffleScope.isScoped ? shuffleScope.selections : nil)
        } catch {
            randomError = "Kein Video in der gewählten Auswahl gefunden."
        }
    }

    #if os(macOS)
    private func openRandomPlayerWindow(for item: Item) {
        let context = RandomContext(libraryId: nil, folderSelections: shuffleScope.isScoped ? shuffleScope.selections : nil, folder: nil, search: nil)
        PlayerLaunchCoordinator.shared.present(PlayerLaunchRequest(item: item, queue: [], queueIndex: nil, randomContext: context, startFromBeginning: false), openWindow: openWindow)
        randomItem = nil
    }
    #endif

    private static let cacheKeyPrefix = "goldfish.cachedLibraries."
    private var cacheKey: String { Self.cacheKeyPrefix + (client.currentUsername ?? "_") }

    private func load() async {
        isLoading = libraries.isEmpty
        defer { isLoading = false }
        // Zuerst den zuletzt bekannten Stand zeigen (falls vorhanden), damit bei langsamer/
        // fehlender Verbindung nicht erst eine leere Ansicht aufblitzt, bevor der Fehler
        // überhaupt feststeht.
        if libraries.isEmpty, let cached = loadCachedLibraries() {
            libraries = cached
        }
        // Vorschaubilder IMMER zuerst aus dem Platten-Cache vorbelegen — UNABHÄNGIG
        // davon, ob der fetchLibraries()-Call unten klappt. Der bisher einzige
        // Code, der `previewURLs` aus `GoldfishLibraryPreviews/*.jpg` füllt, saß
        // ausschließlich in `loadPreviews()`, und das lief NUR im Erfolgsfall.
        // Offline blieb `previewURLs` deshalb leer → jede `LibraryCard` fiel auf
        // den farbigen Gradienten-Kreis ohne Bild zurück (wiederkehrender
        // User-Bericht: "sobald Goldfish offline ist, nur noch farbige runde
        // Kacheln ohne Hintergrundbild"). Die früheren Fixes (Offline-Lib-Liste,
        // eigener Preview-Cache-Ordner, file://-Handling in PosterImage) waren
        // alle nötig, aber keiner hat den Cache-Read in den Offline-Zweig gehängt.
        hydratePreviewsFromCache()
        do {
            libraries = try await client.fetchLibraries()
            errorMessage = nil
            isOffline = false
            saveCachedLibraries(libraries)
            hydratePreviewsFromCache() // frisch dazugekommene Libs sofort aus Cache zeigen
            await loadPreviews()
        } catch {
            // 401 vom Server = Session serverseitig tot (nicht "offline" — der
            // Server hat ja geantwortet). NICHT als isOffline tarnen und NICHT die
            // rohe Server-Meldung "Session abgelaufen" als Vollbild-Fehler zeigen,
            // aus dem es kein Zurück gab. Stattdessen lokalen Login verwerfen →
            // RootView zeigt LoginView, dort kann der User sich (auch per SSO) neu
            // anmelden.
            if GoldfishClient.isAuthError(error) {
                client.markSessionInvalid()
                return
            }
            if GoldfishClient.isConnectivityError(error) {
                isOffline = true
                if libraries.isEmpty {
                    errorMessage = "Keine Verbindung zum Server — die zuletzt geladenen Bibliotheken werden angezeigt, sobald welche gecacht sind."
                }
            } else {
                // Irgendein anderer Server-/Decoding-Fehler — nicht als "offline"
                // labeln, aber die Meldung zeigen (mit Retry-Button im body).
                isOffline = false
                if libraries.isEmpty {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func loadCachedLibraries() -> [Library]? {
        guard let data = UserDefaults.standard.data(forKey: cacheKey) else { return nil }
        return try? JSONDecoder().decode([Library].self, from: data)
    }

    private func saveCachedLibraries(_ libs: [Library]) {
        guard let data = try? JSONEncoder().encode(libs) else { return }
        UserDefaults.standard.set(data, forKey: cacheKey)
    }

    // User-Anfrage 2026-08-19 (Folgerunde): "auch nicht für die Bibliotheksvorschaubilder" —
    // dieselbe Offline-Lücke wie bei den Downloads-Postern: `previewURLs` zeigte bisher immer
    // auf eine Live-Server-URL, die offline schlicht fehlschlägt. Eigener Platten-Cache,
    // gleiche Application-Support-Konvention wie `DownloadManager.posterCacheDir`.
    private static let libraryPreviewCacheDir: URL = {
        let fm = FileManager.default
        let support = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fm.temporaryDirectory
        let dir = support.appendingPathComponent("GoldfishLibraryPreviews", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private func cachedPreviewFile(key: String) -> URL {
        Self.libraryPreviewCacheDir.appendingPathComponent("\(key.replacingOccurrences(of: ":", with: "_")).jpg")
    }

    /// Belegt `previewURLs` für alle aktuell bekannten Bibliotheken aus lokalen
    /// Quellen vor (Platten-Cache bei Server-Libs, Thumbnail-Datei bei lokalen
    /// Libs). Rein lokal, kein Netzwerk — funktioniert damit auch komplett offline.
    /// Überschreibt nie einen bereits gesetzten Wert (ein erfolgreicher
    /// `loadPreviews()`-Reload gewinnt).
    private func hydratePreviewsFromCache() {
        for lib in libraries {
            let key = "server:\(lib.id)"
            guard previewURLs[key] == nil else { continue }
            let file = cachedPreviewFile(key: key)
            if FileManager.default.fileExists(atPath: file.path) {
                previewURLs[key] = file
            }
        }
        for lib in localLibrary.libraries {
            let key = "local:\(lib.id)"
            guard previewURLs[key] == nil else { continue }
            if let url = localLibrary.itemsFor(lib.id).lazy.compactMap({ localLibrary.thumbnailURL(for: $0) }).first {
                previewURLs[key] = url
            }
        }
    }

    private func loadPreviews() async {
        for lib in libraries {
            let key = "server:\(lib.id)"
            let cacheFile = cachedPreviewFile(key: key)
            // Ist für diese Bibliothek schon ein Vorschaubild gecacht, wird es
            // BEHALTEN — kein neuer Netzwerk-Fetch. User-Anfrage 2026-08-28:
            // "genau die aktuellen Bilder sollen gespeichert werden". Vorher hat
            // `loadPreviews()` bei JEDEM Öffnen ein NEUES Zufalls-Item gezogen und
            // die Cache-Datei überschrieben — das gerade sichtbare Bild war also
            // nie stabil und stimmte offline nicht mit dem zuletzt online
            // gezeigten überein. Jetzt: einmal geholt = dauerhaft dieses Bild
            // (online wie offline), bis die Cache-Datei gelöscht wird.
            if FileManager.default.fileExists(atPath: cacheFile.path) {
                if previewURLs[key] == nil { previewURLs[key] = cacheFile }
                continue
            }
            // Noch kein Bild vorhanden: EINMALIG das Poster eines Zufalls-Items als
            // repräsentatives Cover holen und dauerhaft ablegen.
            guard let item = try? await client.randomItem(libraryId: lib.id) else { continue }
            let networkURL: URL?
            if let metadataId = item.metadataId, let url = client.posterURL(metadataId: metadataId) {
                networkURL = url
            } else {
                networkURL = client.thumbURL(itemId: item.id)
            }
            guard let networkURL,
                  let (data, _) = try? await URLSession.shared.data(from: networkURL), !data.isEmpty else { continue }
            try? data.write(to: cacheFile)
            previewURLs[key] = cacheFile
        }
        for lib in localLibrary.libraries {
            let key = "local:\(lib.id)"
            guard previewURLs[key] == nil else { continue }
            if let url = localLibrary.itemsFor(lib.id).lazy.compactMap({ localLibrary.thumbnailURL(for: $0) }).first {
                previewURLs[key] = url
            }
        }
    }
}

/// Wählbare Bibliotheks-Auswahl für "Zufällig abspielen" — "Alle" (Standard) oder eine
/// individuelle Auswahl, persistiert über `ShuffleScope`. Nur Server-Bibliotheken: lokale
/// Bibliotheken haben ihr eigenes, unabhängiges Zufall-Feature (kein Server-Roundtrip nötig).
private struct ShuffleScopeSheet: View {
    let libraries: [Library]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ShuffleScopeSettingsList(libraries: libraries)
                .navigationTitle("Zufall-Auswahl")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Fertig") { dismiss() }
                    }
                }
        }
        #if os(macOS)
        .frame(minWidth: 360, minHeight: 400)
        #endif
    }
}

/// Reusable list content behind the library-scope picker — used both from the 🎯-Sheet in
/// `LibrariesView`'s toolbar AND as a pushed screen from Settings (real gap hit 2026-08-19:
/// the toolbar-only entry point wasn't discoverable enough — "finde ich immer noch nicht" —
/// so it's now reachable from Settings too, where users more readily expect global toggles).
struct ShuffleScopeSettingsList: View {
    let libraries: [Library]
    @EnvironmentObject var shuffleScope: ShuffleScope

    var body: some View {
        List {
            Section {
                Button {
                    shuffleScope.clear()
                } label: {
                    HStack {
                        Text("Alle Bibliotheken")
                        Spacer()
                        if !shuffleScope.isScoped {
                            Image(systemName: "checkmark").foregroundStyle(.tint)
                        }
                    }
                }
                .buttonStyle(.plain)
            } footer: {
                Text("Ohne Auswahl unten wirkt \"Zufällig\" auf alle Bibliotheken, die du sehen kannst.")
            }

            if !shuffleScope.selections.isEmpty {
                Section("Aktuelle Auswahl") {
                    ForEach(shuffleScope.selections) { sel in
                        HStack {
                            Text(sel.displayLabel)
                            Spacer()
                            Button {
                                shuffleScope.remove(sel)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            // Ordner-Baum statt nur Bibliotheks-Ebene (User-Anfrage 2026-08-19: "auch
            // Unterordner … auswählen können, sowie diese auch in den Bibliotheken angezeigt
            // werden") — lazy geladen über dieselbe `fetchFolders`-Route wie die normale
            // Ordner-Navigation, analog zum Browser-🎯-Dialog (CLAUDE.md "Ordner-Scoping für
            // Shuffle": dieselbe Route wie die normale Ordner-Navigation, NICHT die
            // admin-only `/all-folders`-Route des Verschieben-Dialogs).
            Section("Bibliotheken & Ordner") {
                ForEach(libraries) { lib in
                    FolderScopeRow(libraryId: lib.id, libraryName: lib.name, folder: "", displayName: lib.name, depth: 0)
                }
            }
        }
        // Gleicher Fix wie `WatchLinkSettingsView` (User-Anfrage 2026-08-19: "Textsprung
        // nach Auswahl... das habe ich oft!") — jede als NavigationLink-Ziel gepushte
        // List/Form ohne explizites Frame kann beim ersten Re-Render (hier: lazy
        // Folder-Expansion) von zentriert/schmal auf linksbündig/abgeschnitten springen.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One row in the shuffle-scope folder tree — a checkbox for this folder (or the whole
/// library when `folder == ""`) plus a lazy-loaded disclosure for its subfolders.
private struct FolderScopeRow: View {
    let libraryId: Int64
    let libraryName: String
    let folder: String
    let displayName: String
    let depth: Int

    @EnvironmentObject var client: GoldfishClient
    @EnvironmentObject var shuffleScope: ShuffleScope
    @State private var isExpanded = false
    @State private var children: [FolderTile] = []
    @State private var hasLoadedChildren = false
    @State private var isLoadingChildren = false

    private var selection: ShuffleFolderSelection {
        ShuffleFolderSelection(libraryId: libraryId, libraryName: libraryName, folder: folder)
    }
    private var isChecked: Bool { shuffleScope.isSelected(libraryId: libraryId, folder: folder) }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            if isLoadingChildren {
                ProgressView().padding(.leading, CGFloat(depth + 1) * 16)
            } else {
                ForEach(children) { tile in
                    FolderScopeRow(libraryId: libraryId, libraryName: libraryName, folder: tile.name, displayName: tile.displayName, depth: depth + 1)
                }
            }
        } label: {
            Button {
                shuffleScope.toggle(selection)
            } label: {
                HStack {
                    Image(systemName: isChecked ? "checkmark.square.fill" : "square")
                        .foregroundStyle(isChecked ? Color.accentColor : Color.secondary)
                    Text(displayName)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .onChange(of: isExpanded) { expanded in
            guard expanded, !hasLoadedChildren else { return }
            Task {
                isLoadingChildren = true
                children = (try? await client.fetchFolders(libraryId: libraryId, parent: folder.isEmpty ? nil : folder)) ?? []
                isLoadingChildren = false
                hasLoadedChildren = true
            }
        }
    }
}

/// Sammlungen/Playlists — Pseudo-Bibliotheken, gleicher visueller Stil wie `LibraryCard`
/// aber ohne Preview-Poster-Fetch (Browser-Pendant: eigene Topbar-Icons statt Library-
/// Dropdown-Einträge, siehe CLAUDE.md "Topbar-Navigation").
private struct SpecialLibraryCard: View {
    let name: String
    let systemImage: String
    let colors: [Color]

    var body: some View {
        ZStack {
            Circle()
                .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
            Image(systemName: systemImage)
                .font(.system(size: 40))
                .foregroundStyle(.white.opacity(0.25))
            Text(name)
                // User-Feedback 2026-08-19: "Beschriftung könnte etwas kräftiger sein" —
                // .headline war schon semibold, jetzt explizit .bold + etwas größer plus
                // stärkerer/doppelter Schatten für mehr Kontrast auf hellen Vorschaubildern.
                .font(.title3.weight(.bold))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.8), radius: 4)
                .shadow(color: .black.opacity(0.6), radius: 1)
                .padding(.horizontal, 16)
        }
        .frame(width: 190, height: 190)
        .clipShape(Circle())
        .shadow(color: .black.opacity(0.2), radius: 5, y: 3)
    }
}

private struct LibraryCard: View {
    let name: String
    let kind: String
    let isLocal: Bool
    let previewURL: URL?
    /// True when this is a local library whose external volume (USB-Stick, SD-Karte, …)
    /// is currently nicht eingesteckt — Kachel bleibt sichtbar statt zu verschwinden oder
    /// hart zu fehlern, nur verblasst + mit Hinweis (User-Anfrage 2026-08-19).
    var isUnavailable: Bool = false
    /// True für Server-Bibliotheken, wenn der letzte Reload fehlschlug und nur der
    /// Platten-Cache angezeigt wird (User-Anfrage 2026-08-19: "bei den online Bibliotheken
    /// soll dann der Hinweis Offline erscheinen").
    var isOffline: Bool = false

    /// Experiment 2026-08-19 (User: "Vorschaubilder passen da nicht richtig rein,
    /// versuchen wir es mit Rund... wenn es nicht schön ist, dann können wir es ja wieder
    /// ändern") — runde Kachel statt Rechteck mit separater Titel-Leiste, Beschriftung
    /// mittig im Kreis statt unten als eigener Balken. Etwas größer als die vorherige
    /// ~170-220×150-Rechteck-Kachel.
    private let diameter: CGFloat = 190

    var body: some View {
        ZStack {
            if let previewURL {
                // `PosterImage` statt eigenem `AsyncImage`: braucht ohnehin schon eine feste
                // Kreisgröße (frühere Begründung unten), UND behandelt `file://`-URLs korrekt
                // direkt von der Platte statt sie (unzuverlässig) über URLSession zu laden —
                // User-Anfrage 2026-08-19: "auch nicht für die Bibliotheksvorschaubilder"
                // (Vorschaubilder offline verschwunden, gleicher Bug wie bei Downloads-Postern).
                PosterImage(url: previewURL, aspect: 1, placeholderSystemImage: icon, fixedWidth: diameter)
                    .clipShape(Circle())
                // Radialer Verlauf zur Mitte hin abgedunkelt, damit der zentrierte Titel
                // auf JEDEM Vorschaubild lesbar bleibt, nicht nur auf dunklen.
                Circle()
                    .fill(RadialGradient(colors: [.clear, .black.opacity(0.65)], center: .center, startRadius: diameter * 0.15, endRadius: diameter * 0.55))
            } else {
                Circle()
                    .fill(LinearGradient(colors: gradientColors, startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: icon)
                    .font(.system(size: 40))
                    .foregroundStyle(.white.opacity(0.2))
            }

            VStack(spacing: 4) {
                Text(name)
                    // Gleiche Verstärkung wie SpecialLibraryCard (User-Feedback 2026-08-19).
                    .font(.title3.weight(.bold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.8), radius: 4)
                    .shadow(color: .black.opacity(0.6), radius: 1)
                HStack(spacing: 4) {
                    if isUnavailable {
                        Image(systemName: "externaldrive.badge.xmark")
                    } else if isOffline {
                        Image(systemName: "wifi.slash")
                    } else if isLocal {
                        Image(systemName: "externaldrive")
                    }
                    Text(isUnavailable ? "nicht verbunden" : (isOffline ? "Offline" : kindLabel))
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.85))
                .shadow(color: .black.opacity(0.7), radius: 2)
            }
            .padding(.horizontal, 16)
        }
        .frame(width: diameter, height: diameter)
        .clipShape(Circle())
        .shadow(color: .black.opacity(0.2), radius: 5, y: 3)
        .opacity((isUnavailable || isOffline) ? 0.6 : 1)
    }

    private var icon: String {
        switch kind {
        case "movies": return "film.fill"
        case "tv": return "tv.fill"
        default: return "photo.stack.fill"
        }
    }

    private var kindLabel: String {
        switch kind {
        case "movies": return "Filme"
        case "tv": return "Serien"
        default: return "Privat"
        }
    }

    private var gradientColors: [Color] {
        switch kind {
        case "movies": return [.blue, .indigo]
        case "tv": return [.purple, .pink]
        default: return [.teal, .green]
        }
    }
}

struct ContentUnavailableMessage: View {
    let text: String
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
            Text(text)
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(.secondary)
        .padding()
    }
}
