#if os(macOS)
import GoldfishCore
import SwiftUI

/// Track-Liste eines Albums — Client-Pendant zu `views.js renderAlbumTracks`. Tippen auf
/// einen Titel startet die Wiedergabe in `MusicPlayerEngine` (NICHT `PlayerView`/
/// `ItemDetailView` — Musik hat serverseitig kein TMDB/Detail-Konzept, siehe
/// Server-CLAUDE.md "Persistenter Mini-Player": "ein Klick auf eine Musik-Kachel ruft
/// musicPlayAlbum() auf statt openDetail() zu öffnen").
struct MusicAlbumDetailView: View {
    let album: MusicAlbum

    @EnvironmentObject var client: GoldfishClient
    @EnvironmentObject var musicPlayer: MusicPlayerEngine
    @EnvironmentObject var downloads: DownloadManager
    @State private var tracks: [Item] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var addToPlaylistItem: Item?
    @State private var showPlaylists = false
    // Gleicher Key wie in MusicLibraryView — Listenansicht ist dort die einzige
    // Stelle mit sichtbarer Wirkung (Album-Übersicht Kacheln/Liste), der Toggle
    // hier wirkt sich also erst beim Zurückgehen aus. Trotzdem hier mit
    // angeboten (User-Wunsch 2026-09-11: "Hier fehlen die Buttons" — sollen auf
    // JEDER Musik-Seite sichtbar sein, nicht nur auf der Album-Übersicht selbst).
    @AppStorage("musicLibraryListView") private var isListView = false

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
            } else if let errorMessage {
                ContentUnavailableMessage(text: errorMessage)
            } else {
                List {
                    Section {
                        header
                    }
                    .listRowSeparator(.hidden)
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { idx, track in
                        // KEIN Button-Wrapper um die ganze Zeile — das Download-Icon
                        // ist selbst ein Button, und ein Button verschachtelt in einem
                        // anderen Button-Label ist in SwiftUI unzuverlässig (der äußere
                        // Tap-Handler gewinnt meist, das innere Icon wäre dann tot).
                        // Play-Tap läuft stattdessen über `.onTapGesture` NUR auf dem
                        // Text-Teil der Zeile (`trackRow`), das Icon bleibt daneben ein
                        // echter, unabhängiger Button.
                        HStack {
                            trackRow(track, index: idx)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    musicPlayer.play(queue: tracks, startIndex: idx, client: client)
                                }
                            Button {
                                addToPlaylistItem = track
                            } label: {
                                Image(systemName: "text.badge.plus")
                            }
                            .buttonStyle(.plain)
                            .help("Zu Playlist hinzufügen")
                            MusicDownloadIcon(item: track)
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle(album.displayTitle)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isListView.toggle()
                } label: {
                    Label(isListView ? "Kachelansicht" : "Listenansicht", systemImage: isListView ? "square.grid.2x2" : "list.bullet")
                }
                .help(isListView ? "Album-Übersicht: zur Kachelansicht wechseln" : "Album-Übersicht: zur Listenansicht wechseln")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showPlaylists = true
                } label: {
                    Label("Playlists", systemImage: "music.note.list")
                }
                .help("Musik-Playlists")
            }
        }
        .task { await load() }
        .sheet(item: $addToPlaylistItem) { track in
            AddToPlaylistSheet(item: track, kind: "music")
        }
        .sheet(isPresented: $showPlaylists) {
            NavigationStack {
                MusicPlaylistsView()
            }
            .frame(minWidth: 480, minHeight: 480)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            PosterImage(url: client.albumCoverURL(albumId: album.id), aspect: 1.0, placeholderSystemImage: "music.note")
                .frame(width: 140, height: 140)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 4) {
                Text(album.displayTitle).font(.title2.weight(.semibold))
                Text(album.artist).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    if let year = album.year, year > 0 { Text(String(year)) }
                    if let genre = album.genre, !genre.isEmpty { Text(genre) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Button {
                        musicPlayer.play(queue: tracks, startIndex: 0, client: client)
                    } label: {
                        Label("Album abspielen", systemImage: "play.fill")
                    }
                    .disabled(tracks.isEmpty)
                    Button {
                        downloadAllMissing(tracks, client: client, downloads: downloads)
                    } label: {
                        Label("Album herunterladen", systemImage: "arrow.down.circle")
                    }
                    .disabled(tracks.isEmpty)
                }
                .padding(.top, 6)
            }
        }
        .padding(.vertical, 8)
    }

    private func trackRow(_ track: Item, index: Int) -> some View {
        HStack {
            Text(track.trackNo.map(String.init) ?? "\(index + 1)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .trailing)
            VStack(alignment: .leading) {
                Text(track.displayTitle)
                    .fontWeight(musicPlayer.currentItem?.id == track.id ? .semibold : .regular)
                if album.artist == "Verschiedene Interpreten", let artist = track.artist, !artist.isEmpty {
                    Text(artist).font(.caption).foregroundStyle(.secondary)
                }
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
            let detail = try await client.fetchAlbum(id: album.id)
            tracks = detail.tracks
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}
#endif
