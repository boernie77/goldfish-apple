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
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif
    @State private var libraries: [Library] = []
    @State private var errorMessage: String?
    @State private var isLoading = true
    // Keyed by "server:<id>" / "local:<uuid>" — one representative poster per library tile.
    @State private var previewURLs: [String: URL] = [:]

    // Globales "Zufällig abspielen" über eine wählbare Bibliotheks-Auswahl (User-Anfrage
    // 2026-08-19), analog zum Browser-🎯-Dialog, hier aber library- statt ordnerbasiert.
    @State private var randomItem: Item?
    @State private var isLoadingRandom = false
    @State private var randomError: String?
    @State private var showingScopeSheet = false

    private let columns = [GridItem(.adaptive(minimum: 170, maximum: 220), spacing: 16)]

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
                } else if let errorMessage {
                    ContentUnavailableMessage(text: errorMessage)
                } else if libraries.isEmpty && localLibrary.libraries.isEmpty {
                    ContentUnavailableMessage(text: "Keine Bibliotheken verfügbar.")
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 16) {
                            ForEach(libraries) { lib in
                                NavigationLink(value: LibraryDestination.server(lib)) {
                                    LibraryCard(name: lib.name, kind: lib.kind, isLocal: false, previewURL: previewURLs["server:\(lib.id)"])
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
        PlayerLaunchCoordinator.shared.pendingPlayer = PlayerLaunchRequest(item: item, queue: [], queueIndex: nil, randomContext: context, startFromBeginning: false)
        openWindow(id: "player")
        randomItem = nil
    }
    #endif

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            libraries = try await client.fetchLibraries()
            errorMessage = nil
            await loadPreviews()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadPreviews() async {
        for lib in libraries {
            let key = "server:\(lib.id)"
            guard previewURLs[key] == nil else { continue }
            // A random item's poster is a cheap, representative cover — avoids fetching
            // (and discarding) the library's entire item list just to grab one image.
            if let item = try? await client.randomItem(libraryId: lib.id),
               let metadataId = item.metadataId,
               let url = client.posterURL(metadataId: metadataId) {
                previewURLs[key] = url
            } else if let item = try? await client.randomItem(libraryId: lib.id) {
                previewURLs[key] = client.thumbURL(itemId: item.id)
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
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: systemImage)
                    .font(.system(size: 46))
                    .foregroundStyle(.white.opacity(0.3))
                    .padding(16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
            .frame(height: 110)

            Text(name)
                .font(.headline)
                .lineLimit(1)
                .foregroundStyle(.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.thinMaterial)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                if let previewURL {
                    // `Color.clear` (no intrinsic size) resolved against the ZStack's own
                    // frame first, THEN the image overlaid into that already-fixed size —
                    // same fix as `PosterImage` (see its doc comment): letting AsyncImage
                    // negotiate its own frame directly is what caused some library tiles to
                    // render un-rounded/oddly-sized while others looked fine (real bug hit
                    // 2026-08-18 — only showed up for tiles whose preview came from a 16:9
                    // thumbnail instead of a 2:3 poster, i.e. a source/target aspect mismatch).
                    Color.clear
                        .overlay {
                            AsyncImage(url: previewURL) { phase in
                                switch phase {
                                case .success(let image): image.resizable().scaledToFill()
                                default: LinearGradient(colors: gradientColors, startPoint: .topLeading, endPoint: .bottomTrailing)
                                }
                            }
                        }
                        .clipped()
                    LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
                } else {
                    LinearGradient(colors: gradientColors, startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: icon)
                        .font(.system(size: 46))
                        .foregroundStyle(.white.opacity(0.25))
                        .padding(16)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }

                HStack(spacing: 4) {
                    Text(isUnavailable ? "nicht verbunden" : kindLabel)
                    if isUnavailable {
                        Image(systemName: "externaldrive.badge.xmark")
                    } else if isLocal {
                        Image(systemName: "externaldrive")
                    }
                }
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(.black.opacity(0.25), in: Capsule())
                .foregroundStyle(.white)
                .padding(10)
            }
            .frame(height: 110)

            Text(name)
                .font(.headline)
                .lineLimit(1)
                .foregroundStyle(.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.thinMaterial)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
        .opacity(isUnavailable ? 0.5 : 1)
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
