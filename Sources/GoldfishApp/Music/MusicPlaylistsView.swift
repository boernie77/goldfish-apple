#if os(macOS)
import GoldfishCore
import SwiftUI

/// Eigene Musik-Playlist-Übersicht — bewusst NICHT der generische `PlaylistsView`-Tab
/// (User-Wunsch 2026-09-11: "Musikplaylist sollte getrennt zu den anderen Playlisten
/// sein und nur über den Musikordner aufrufbar sein"). Server trennt Video-/Musik-
/// Playlists ohnehin strikt (`playlists.kind`, siehe CLAUDE.md "Playlists (per User)") —
/// der generische Tab lädt seit diesem Feature `kind: "video"` per Default, Musik-
/// Playlists erscheinen dort nicht mehr. Erreichbar ausschließlich über den
/// "🎵 Playlists"-Button in `MusicLibraryView`.
struct MusicPlaylistsView: View {
    @EnvironmentObject var client: GoldfishClient
    @EnvironmentObject var musicPlayer: MusicPlayerEngine
    @Environment(\.dismiss) private var dismiss
    @State private var playlists: [Playlist] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var newName = ""
    @State private var showingCreate = false

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
            } else if let errorMessage {
                ContentUnavailableMessage(text: errorMessage)
            } else if playlists.isEmpty {
                ContentUnavailableMessage(text: "Noch keine Musik-Playlists — oben rechts erstellen.")
            } else {
                List(playlists) { playlist in
                    NavigationLink(value: playlist) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(playlist.name)
                            Text("\(playlist.itemCount) Titel").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("🎵 Playlists")
        .navigationDestination(for: Playlist.self) { playlist in
            MusicPlaylistDetailView(playlist: playlist)
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Fertig") { dismiss() }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    newName = ""
                    showingCreate = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .alert("Neue Musik-Playlist", isPresented: $showingCreate) {
            TextField("Name", text: $newName)
            Button("Abbrechen", role: .cancel) {}
            Button("Erstellen") { Task { await create() } }
        }
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            playlists = try await client.fetchPlaylists(kind: "music")
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func create() async {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let created = try? await client.createPlaylist(name: trimmed, kind: "music") {
            playlists.append(created)
        }
    }
}

/// Track-Liste einer Musik-Playlist — strukturell identisch zu `MusicAlbumDetailView`
/// (Tippen spielt in `MusicPlayerEngine` ab), nur ohne Album-Header/Cover (eine Playlist
/// hat kein eigenes Cover) und mit Künstler+Album-Spalte statt nur Künstler, da die
/// Titel aus verschiedenen Alben stammen können.
struct MusicPlaylistDetailView: View {
    let playlist: Playlist

    @EnvironmentObject var client: GoldfishClient
    @EnvironmentObject var musicPlayer: MusicPlayerEngine
    @EnvironmentObject var downloads: DownloadManager
    @State private var tracks: [Item] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
            } else if let errorMessage {
                ContentUnavailableMessage(text: errorMessage)
            } else if tracks.isEmpty {
                ContentUnavailableMessage(text: "Playlist ist leer.")
            } else {
                List {
                    HStack {
                        Button {
                            musicPlayer.play(queue: tracks, startIndex: 0, client: client)
                        } label: {
                            Label("Alle abspielen", systemImage: "play.fill")
                        }
                        Button {
                            downloadAllMissing(tracks, client: client, downloads: downloads)
                        } label: {
                            Label("Playlist herunterladen", systemImage: "arrow.down.circle")
                        }
                    }
                    // Kein Button-Wrapper um die ganze Zeile, siehe Kommentar in
                    // MusicAlbumDetailView — das Download-Icon braucht einen echten,
                    // unabhängigen Tap-Bereich.
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { idx, track in
                        HStack {
                            trackRow(track)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    musicPlayer.play(queue: tracks, startIndex: idx, client: client)
                                }
                            Button(role: .destructive) {
                                Task { await remove(track) }
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.plain)
                            .help("Aus Playlist entfernen")
                            MusicDownloadIcon(item: track)
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle(playlist.name)
        .task { await load() }
    }

    private func trackRow(_ track: Item) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(track.displayTitle)
                    .fontWeight(musicPlayer.currentItem?.id == track.id ? .semibold : .regular)
                Text([track.artist, track.album].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if musicPlayer.currentItem?.id == track.id, musicPlayer.isPlaying {
                Image(systemName: "speaker.wave.2.fill").foregroundStyle(Color.accentColor)
            }
            Text(track.durationLabel).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            tracks = try await client.fetchPlaylistItems(id: playlist.id)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func remove(_ track: Item) async {
        try? await client.removeFromPlaylist(playlistId: playlist.id, itemId: track.id)
        tracks.removeAll { $0.id == track.id }
    }
}
#endif
