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
            MusicAlbumDetailView(album: album)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Toggle(isOn: $librarySyncEnabled) {
                    Label("Bibliothek offline synchronisieren", systemImage: librarySyncEnabled ? "arrow.triangle.2.circlepath.circle.fill" : "arrow.triangle.2.circlepath.circle")
                }
                .toggleStyle(.button)
                .help("Alle Titel dieser Bibliothek automatisch offline halten")
            }
            ToolbarItem(placement: .primaryAction) {
                NavigationLink {
                    MusicOfflineView(library: library)
                } label: {
                    Label("Offline verfügbar", systemImage: "arrow.down.circle.fill")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                NavigationLink {
                    MusicPlaylistsView()
                } label: {
                    Label("Playlists", systemImage: "music.note.list")
                }
            }
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

private struct MusicAlbumCard: View {
    let album: MusicAlbum
    @EnvironmentObject var client: GoldfishClient

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PosterImage(url: client.albumCoverURL(albumId: album.id), aspect: 1.0, placeholderSystemImage: "music.note")
                .clipShape(RoundedRectangle(cornerRadius: 8))
            Text(album.displayTitle)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
            Text(album.artist.isEmpty ? " " : album.artist)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let count = album.trackCount, count > 0 {
                Text("\(count) Titel")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
#endif
