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
    // Playlist bearbeiten (User-Report 2026-09-11: "Playlist bearbeiten sehe ich
    // nicht") — Umbenennen/Löschen. Bewusst als sichtbarer "···"-Menü-Button pro
    // Zeile, NICHT nur per Kontextmenü (dieselbe Lektion wie beim "Zu Playlist
    // hinzufügen"-Button weiter oben in dieser Session — ein reines
    // Rechtsklick-Kontextmenü wird leicht übersehen).
    @State private var renamingPlaylist: Playlist?
    @State private var renameText = ""
    @State private var deletingPlaylist: Playlist?

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
                    HStack {
                        NavigationLink(value: playlist) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(playlist.name)
                                Text("\(playlist.itemCount) Titel").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Menu {
                            Button {
                                renameText = playlist.name
                                renamingPlaylist = playlist
                            } label: {
                                Label("Umbenennen", systemImage: "pencil")
                            }
                            Button(role: .destructive) {
                                deletingPlaylist = playlist
                            } label: {
                                Label("Löschen", systemImage: "trash")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
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
        .alert("Playlist umbenennen", isPresented: Binding(
            get: { renamingPlaylist != nil },
            set: { if !$0 { renamingPlaylist = nil } }
        ), presenting: renamingPlaylist) { playlist in
            TextField("Name", text: $renameText)
            Button("Abbrechen", role: .cancel) {}
            Button("Speichern") { Task { await rename(playlist) } }
        }
        // `presenting:` reicht den Playlist-Wert DIREKT in die Button-Action durch,
        // statt ihn im Closure erneut aus `deletingPlaylist` zu lesen (User-Report
        // 2026-09-11: "Wird jetzt angezeigt, aber funktioniert nicht (löschen)") —
        // SwiftUI setzt die Optional-gestützte `isPresented`-Bindung beim Schließen
        // des Alerts zurück auf `nil`, und zwar NICHT zuverlässig erst NACH dem
        // Button-Action-Closure. Ein `guard let playlist = deletingPlaylist` INNERHALB
        // der Action las das dadurch teils schon als `nil` — die Löschung brach still
        // ab, ohne jede Fehlermeldung. Der `presenting:`-Overload umgeht das Problem
        // strukturell, der Wert kommt als Parameter, kein erneuter State-Read nötig.
        .alert(
            "„\(deletingPlaylist?.name ?? "")“ löschen?",
            isPresented: Binding(
                get: { deletingPlaylist != nil },
                set: { if !$0 { deletingPlaylist = nil } }
            ),
            presenting: deletingPlaylist
        ) { playlist in
            Button("Abbrechen", role: .cancel) {}
            Button("Löschen", role: .destructive) { Task { await deleteSelected(playlist) } }
        } message: { _ in
            Text("Die Playlist wird unwiderruflich gelöscht.")
        }
        .task { await load() }
    }

    private func rename(_ playlist: Playlist) async {
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try await client.renamePlaylist(id: playlist.id, name: trimmed)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteSelected(_ playlist: Playlist) async {
        do {
            try await client.deletePlaylist(id: playlist.id)
            playlists.removeAll { $0.id == playlist.id }
        } catch {
            errorMessage = error.localizedDescription
        }
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
    /// "Playlist offline synchronisieren" (User-Report 2026-09-11: "wo sync ich die
    /// ganze Playlist?" — der bisherige einmalige "Playlist herunterladen"-Button war
    /// offenbar nicht als Sync-Äquivalent zum Bibliotheks-Toggle erkennbar). Gleiches
    /// Muster wie `MusicLibraryView.librarySyncEnabled`: AppStorage pro Playlist, läuft
    /// beim Öffnen erneut (deckt neu hinzugefügte Titel ab, kein Hintergrund-Daemon).
    @AppStorage private var playlistSyncEnabled: Bool

    init(playlist: Playlist) {
        self.playlist = playlist
        self._playlistSyncEnabled = AppStorage(wrappedValue: false, "musicPlaylistSync.\(playlist.id)")
    }

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
                            musicPlayer.isShuffling = true
                            musicPlayer.play(queue: tracks.shuffled(), startIndex: 0, client: client)
                        } label: {
                            Label("Shuffle", systemImage: "shuffle")
                        }
                        Toggle(isOn: $playlistSyncEnabled) {
                            Label("Playlist offline synchronisieren", systemImage: playlistSyncEnabled ? "arrow.triangle.2.circlepath.circle.fill" : "arrow.triangle.2.circlepath.circle")
                        }
                        .toggleStyle(.button)
                        .help("Alle Titel dieser Playlist automatisch offline halten")
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
                            MusicFavoriteButton(isFavorite: track.favorite) { newValue in
                                try? await client.setFavorite(itemId: track.id, favorite: newValue)
                            }
                            MusicDownloadIcon(item: track)
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle(playlist.name)
        .task {
            await load()
            syncIfNeeded()
        }
        .onChange(of: playlistSyncEnabled) { enabled in
            if enabled { syncIfNeeded() }
        }
    }

    private func syncIfNeeded() {
        guard playlistSyncEnabled else { return }
        downloadAllMissing(tracks, client: client, downloads: downloads)
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
