#if os(macOS)
import GoldfishCore
import SwiftUI

/// Album-Kachel-Übersicht für eine `kind=music`-Bibliothek — Client-Pendant zur
/// Browser-Album-Übersicht (`views.js renderAlbumTiles`). Ersetzt für Musik-Libraries
/// die generische `ItemGridView` (siehe `LibrariesView.navigationDestination`).
struct MusicLibraryView: View {
    let library: Library

    @EnvironmentObject var client: GoldfishClient
    @EnvironmentObject var musicPlayer: MusicPlayerEngine
    @EnvironmentObject var downloads: DownloadManager
    @State private var albums: [MusicAlbum] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var search = ""
    // Navigation per @State-Flag statt separater ToolbarItem(NavigationLink)-Buttons
    // (User-Report 2026-09-11: "ich sehe... die Playlist hinzufügen button noch die
    // Playlists" nicht) — drei einzelne ToolbarItems + Suchfeld können bei schmalerem
    // Fenster im macOS-Toolbar-Overflow (">>"-Chevron) verschwinden, den man leicht
    // übersieht. Jetzt EIN Menü-Button, der garantiert nie überläuft.
    @State private var showOffline = false
    @State private var showPlaylists = false
    @State private var showAllTracks = false
    /// Kachel-/Listenansicht der Album-Übersicht (User-Wunsch 2026-09-11) — global
    /// persistiert, analog zu `musicListView` im Browser (`CLAUDE.md` "Listenansicht").
    @AppStorage("musicLibraryListView") private var isListView = false
    /// "gesamte Bibliothek offline halten" (User-Wunsch 2026-09-11) — pro Bibliothek
    /// persistiert, kein globaler Schalter. Kein echter Push-/Hintergrund-Sync: läuft
    /// beim Öffnen der Bibliothek erneut (deckt App-Neustart + neue Titel nach einem
    /// Server-Scan ab, ohne einen eigenen Hintergrund-Daemon zu brauchen).
    @AppStorage private var librarySyncEnabled: Bool
    // Sortierung + Genre-Filter (User-Wunsch 2026-09-11: "was haben andere
    // Musikbibliotheken" — beides fehlte, Album-Übersicht war fest nach
    // Künstler/Album sortiert). Genre-Filter läuft server-seitig (genre=
    // Query-Param, ListMusicAlbumsFiltered, analog Browser), Sortierung
    // client-seitig auf der bereits geladenen Liste.
    @State private var sortOption: AlbumSort = .artist
    @State private var availableGenres: [String] = []
    @State private var selectedGenres: Set<String> = []
    @State private var navigateToAlbum: MusicAlbum?

    enum AlbumSort: String, CaseIterable {
        case artist, album, year
        var label: String {
            switch self {
            case .artist: return "Künstler"
            case .album: return "Album"
            case .year: return "Jahr"
            }
        }
    }

    init(library: Library) {
        self.library = library
        self._librarySyncEnabled = AppStorage(wrappedValue: false, "musicLibrarySync.\(library.id)")
    }

    private let cardWidth: CGFloat = 170
    private var columns: [GridItem] { [GridItem(.adaptive(minimum: cardWidth, maximum: cardWidth), spacing: 16, alignment: .top)] }

    private var filteredAlbums: [MusicAlbum] {
        var result = albums
        if !search.isEmpty {
            result = result.filter {
                $0.album.localizedCaseInsensitiveContains(search) || $0.artist.localizedCaseInsensitiveContains(search)
            }
        }
        switch sortOption {
        case .artist:
            result.sort { ($0.artist, $0.album) < ($1.artist, $1.album) }
        case .album:
            result.sort { $0.album.localizedStandardCompare($1.album) == .orderedAscending }
        case .year:
            result.sort { ($0.year ?? 0) > ($1.year ?? 0) } // neueste zuerst
        }
        return result
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
            } else if let errorMessage {
                ContentUnavailableMessage(text: errorMessage)
            } else if albums.isEmpty {
                ContentUnavailableMessage(text: "Keine Alben gefunden.")
            } else if isListView {
                // KEIN NavigationLink-Wrapper mehr um die ganze Zeile — das
                // Favoriten-Herz (User-Wunsch 2026-09-11) ist selbst ein Button,
                // und ein Button verschachtelt im Label eines NavigationLink ist
                // in SwiftUI unzuverlässig (gleiche Falle wie bei den Track-
                // Zeilen, siehe Kommentare in MusicAlbumDetailView). Tap navigiert
                // stattdessen über `.onTapGesture` + `navigationDestination(item:)`.
                List(filteredAlbums) { album in
                    MusicAlbumRow(album: album)
                        .contentShape(Rectangle())
                        .onTapGesture { navigateToAlbum = album }
                }
                .listStyle(.plain)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 20) {
                        ForEach(filteredAlbums) { album in
                            MusicAlbumCard(album: album)
                                .frame(width: cardWidth)
                                .contentShape(Rectangle())
                                .onTapGesture { navigateToAlbum = album }
                        }
                    }
                    .padding()
                    // Platz für die persistente Mini-Player-Leiste (safeAreaInset in
                    // MainTabView) — ohne das läge die letzte Album-Reihe teils dahinter.
                    .padding(.bottom, musicPlayer.currentItem != nil ? 72 : 0)
                }
            }
        }
        .navigationTitle(library.name)
        .searchable(text: $search, prompt: "Alben/Künstler durchsuchen")
        // `.navigationDestination(item:)` braucht macOS 14 (Deployment-Target ist
        // 13.0) — die `isPresented:`-Variante gibt es schon seit macOS 13. Einzige
        // `navigationDestination`-Modifier auf dieser View (kein `for:` mehr
        // daneben) — die macOS-13-Fragilität aus dem Bibliotheken-Tab-Vorfall kam
        // von MEHREREN gleichzeitigen Modifiern, nicht von diesem Typ an sich.
        .navigationDestination(isPresented: Binding(
            get: { navigateToAlbum != nil },
            set: { if !$0 { navigateToAlbum = nil } }
        )) {
            if let navigateToAlbum {
                MusicAlbumDetailView(album: navigateToAlbum, library: library)
            }
        }
        .toolbar {
            // Listenansicht + Playlists sollen IMMER sichtbar sein (User-Wunsch
            // 2026-09-11), nicht im "···"-Menü verschwinden können — beide daher
            // als eigene ToolbarItems VOR dem Menü, wie schon der Listen/Kachel-
            // Umschalter.
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isListView.toggle()
                } label: {
                    Label(isListView ? "Kachelansicht" : "Listenansicht", systemImage: isListView ? "square.grid.2x2" : "list.bullet")
                }
                .help(isListView ? "Zur Kachelansicht wechseln" : "Zur Listenansicht wechseln")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showPlaylists = true
                } label: {
                    Label("Playlists", systemImage: "music.note.list")
                }
                .help("Musik-Playlists")
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Menu("Sortierung") {
                        Picker("Sortierung", selection: $sortOption) {
                            ForEach(AlbumSort.allCases, id: \.self) { option in
                                Text(option.label).tag(option)
                            }
                        }
                        .pickerStyle(.inline)
                    }
                    if !availableGenres.isEmpty {
                        Menu("Genre") {
                            Button {
                                selectedGenres.removeAll()
                            } label: {
                                if selectedGenres.isEmpty {
                                    Label("Alle Genres", systemImage: "checkmark")
                                } else {
                                    Text("Alle Genres")
                                }
                            }
                            Divider()
                            ForEach(availableGenres, id: \.self) { genre in
                                Button {
                                    if selectedGenres.contains(genre) {
                                        selectedGenres.remove(genre)
                                    } else {
                                        selectedGenres.insert(genre)
                                    }
                                } label: {
                                    if selectedGenres.contains(genre) {
                                        Label(genre, systemImage: "checkmark")
                                    } else {
                                        Text(genre)
                                    }
                                }
                            }
                        }
                    }
                    Divider()
                    Toggle(isOn: $librarySyncEnabled) {
                        Text("Bibliothek offline synchronisieren")
                    }
                    Button {
                        showOffline = true
                    } label: {
                        Label("📶 Offline verfügbar", systemImage: "arrow.down.circle")
                    }
                    Button {
                        showAllTracks = true
                    } label: {
                        Label("🎵 Alle Titel", systemImage: "music.note.list")
                    }
                } label: {
                    Label("Musik-Optionen", systemImage: "ellipsis.circle")
                }
            }
        }
        // Sheet statt Push-Navigation (User-Report 2026-09-11: kompletter
        // Bibliotheken-Tab brach beim Zurücknavigieren) — mehrere gleichzeitige
        // `navigationDestination`-Modifier (for:/isPresented:) auf derselben View
        // sind auf macOS 13 ein bekannt fragiles SwiftUI-NavigationStack-Muster.
        // Ein Sheet mit eigenem, isoliertem `NavigationStack` innen rührt den
        // äußeren Bibliotheken-Stack gar nicht erst an — exakt das bereits
        // bewährte Muster von `AddToPlaylistSheet` an anderer Stelle im Code.
        .sheet(isPresented: $showOffline) {
            NavigationStack {
                MusicOfflineView(library: library)
            }
            .frame(minWidth: 480, minHeight: 480)
        }
        .sheet(isPresented: $showPlaylists) {
            NavigationStack {
                MusicPlaylistsView()
            }
            .frame(minWidth: 480, minHeight: 480)
        }
        .sheet(isPresented: $showAllTracks) {
            NavigationStack {
                MusicAllTracksView(library: library)
            }
            .frame(minWidth: 560, minHeight: 560)
        }
        .task {
            await load()
            await syncLibraryIfNeeded()
        }
        .onChange(of: librarySyncEnabled) { enabled in
            if enabled { Task { await syncLibraryIfNeeded() } }
        }
        .onChange(of: selectedGenres) { _ in
            Task { await load() }
        }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            albums = try await client.fetchAlbums(libraryId: library.id, genres: Array(selectedGenres))
            if availableGenres.isEmpty {
                availableGenres = (try? await client.fetchGenres(libraryId: library.id)) ?? []
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func syncLibraryIfNeeded() async {
        guard librarySyncEnabled else { return }
        guard let items = try? await client.fetchItems(libraryId: library.id) else { return }
        downloadAllMissing(items, client: client, downloads: downloads)
    }
}

/// Zeilen-Darstellung eines Albums für die Listenansicht (User-Wunsch 2026-09-11:
/// "Es fehlt noch eine Listenansicht") — kompaktes Cover-Thumbnail statt großer
/// Kachel, analog zur Browser-Album-Listenzeile (`.track-row--album`).
private struct MusicAlbumRow: View {
    let album: MusicAlbum
    @EnvironmentObject var client: GoldfishClient

    var body: some View {
        HStack(spacing: 12) {
            PosterImage(url: client.albumCoverURL(albumId: album.id), aspect: 1.0, placeholderSystemImage: "music.note")
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 5))
            VStack(alignment: .leading, spacing: 2) {
                Text(album.displayTitle)
                Text(album.artist.isEmpty ? " " : album.artist)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let count = album.trackCount, count > 0 {
                Text("\(count) Titel").font(.caption).foregroundStyle(.secondary)
            }
            MusicFavoriteButton(isFavorite: album.favorite ?? false) { newValue in
                try? await client.setAlbumFavorite(albumId: album.id, favorite: newValue)
            }
        }
    }
}

private struct MusicAlbumCard: View {
    let album: MusicAlbum
    @EnvironmentObject var client: GoldfishClient

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PosterImage(url: client.albumCoverURL(albumId: album.id), aspect: 1.0, placeholderSystemImage: "music.note")
                .clipShape(RoundedRectangle(cornerRadius: 8))
                // Titelzahl direkt auf dem Cover (User-Wunsch 2026-09-11), analog zum
                // Browser-Badge `.folder-count` unten rechts auf der Ordner-Kachel.
                .overlay(alignment: .bottomTrailing) {
                    if let count = album.trackCount, count > 0 {
                        Text("\(count) Titel")
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(.black.opacity(0.6), in: Capsule())
                            .foregroundStyle(.white)
                            .padding(6)
                    }
                }
                // Favoriten-Herz oben rechts auf dem Cover (User-Wunsch 2026-09-11).
                .overlay(alignment: .topTrailing) {
                    MusicFavoriteButton(isFavorite: album.favorite ?? false) { newValue in
                        try? await client.setAlbumFavorite(albumId: album.id, favorite: newValue)
                    }
                    .padding(6)
                    .background(.black.opacity(0.35), in: Circle())
                    .padding(6)
                }
            Text(album.displayTitle)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
            Text(album.artist.isEmpty ? " " : album.artist)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}
#endif
