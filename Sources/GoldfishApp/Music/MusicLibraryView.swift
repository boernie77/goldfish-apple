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

    init(library: Library) {
        self.library = library
        self._librarySyncEnabled = AppStorage(wrappedValue: false, "musicLibrarySync.\(library.id)")
    }

    private let cardWidth: CGFloat = 170
    private var columns: [GridItem] { [GridItem(.adaptive(minimum: cardWidth, maximum: cardWidth), spacing: 16, alignment: .top)] }

    private var filteredAlbums: [MusicAlbum] {
        guard !search.isEmpty else { return albums }
        return albums.filter {
            $0.album.localizedCaseInsensitiveContains(search) || $0.artist.localizedCaseInsensitiveContains(search)
        }
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
                List(filteredAlbums) { album in
                    NavigationLink(value: album) {
                        MusicAlbumRow(album: album)
                    }
                }
                .listStyle(.plain)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 20) {
                        ForEach(filteredAlbums) { album in
                            NavigationLink(value: album) {
                                MusicAlbumCard(album: album)
                                    .frame(width: cardWidth)
                            }
                            .buttonStyle(.plain)
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
        .navigationDestination(for: MusicAlbum.self) { album in
            MusicAlbumDetailView(album: album, library: library)
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
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            albums = try await client.fetchAlbums(libraryId: library.id)
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
