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
    @State private var albums: [MusicAlbum] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var search = ""

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
        .task { await load() }
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
        }
    }
}
#endif
