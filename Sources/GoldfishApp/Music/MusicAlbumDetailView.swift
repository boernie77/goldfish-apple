#if os(macOS) || os(iOS)
import GoldfishCore
import SwiftUI

/// Track-Liste eines Albums — Client-Pendant zu `views.js renderAlbumTracks`. Tippen auf
/// einen Titel startet die Wiedergabe in `MusicPlayerEngine` (NICHT `PlayerView`/
/// `ItemDetailView` — Musik hat serverseitig kein TMDB/Detail-Konzept, siehe
/// Server-CLAUDE.md "Persistenter Mini-Player": "ein Klick auf eine Musik-Kachel ruft
/// musicPlayAlbum() auf statt openDetail() zu öffnen").
struct MusicAlbumDetailView: View {
    let album: MusicAlbum
    /// Für den vollständigen Musik-Toolbar (User-Wunsch 2026-09-11: "Es sollen
    /// alle Buttons immer zu sehen sein! Genauso wie in der Übersicht") — die
    /// Bibliotheks-Optionen (Offline-Sync/📶/Alle Titel) brauchen die Library,
    /// die reicht `MusicLibraryView` beim Push jetzt mit durch.
    let library: Library

    @EnvironmentObject var client: GoldfishClient
    @EnvironmentObject var musicPlayer: MusicPlayerEngine
    @EnvironmentObject var downloads: DownloadManager
    @State private var tracks: [Item] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var addToPlaylistItem: Item?
    @State private var showPlaylists = false
    @State private var showOffline = false
    // Gleiche Keys wie in MusicLibraryView, damit der komplette Toolbar
    // (Listenansicht/Playlists/Sync-Toggle/Offline) auf JEDER Musik-Seite
    // identisch verfügbar ist, nicht nur auf der Album-Übersicht. "Alle
    // Titel" lebt seit 2026-09-11 nur noch dort als Ansichts-Modus (kein
    // Sheet mehr, siehe MusicLibraryView-Kommentar "soll nicht im extra
    // Fenster öffnen") — hier deshalb absichtlich nicht dupliziert.
    @AppStorage("musicLibraryListView") private var isListView = false
    @AppStorage private var librarySyncEnabled: Bool

    init(album: MusicAlbum, library: Library) {
        self.album = album
        self.library = library
        self._librarySyncEnabled = AppStorage(wrappedValue: false, "musicLibrarySync.\(library.id)")
    }

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
                    Task { await shufflePlayLibrary() }
                } label: {
                    Label("Zufallswiedergabe", systemImage: "shuffle")
                }
                .help("Zufällige Wiedergabe der ganzen Bibliothek")
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
                } label: {
                    Label("Musik-Optionen", systemImage: "ellipsis.circle")
                }
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
            // User-Report 2026-09-11: "Playlists sind nicht für das Iphone
            // kompatibel" — ein festes `minWidth:480` zwingt den Sheet-Inhalt
            // breiter als der iPhone-Bildschirm (typisch 375-430pt), SwiftUI
            // beschneidet/verschiebt den Rest dann unsichtbar. Nur auf macOS
            // sinnvoll (dort ist es die Mindestgröße eines frei skalierbaren
            // Sheet-Fensters), auf iOS/tvOS füllt der Sheet ohnehin die volle
            // Bildschirmbreite von selbst.
            #if os(macOS)
            .frame(minWidth: 480, minHeight: 480)
            #endif
        }
        .sheet(isPresented: $showOffline) {
            NavigationStack {
                MusicOfflineView(library: library)
            }
            #if os(macOS)
            .frame(minWidth: 480, minHeight: 480)
            #endif
        }
        .onChange(of: librarySyncEnabled) { enabled in
            if enabled {
                Task {
                    guard let items = try? await client.fetchItems(libraryId: library.id) else { return }
                    downloadAllMissing(items, client: client, downloads: downloads)
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            PosterImage(url: client.albumCoverURL(albumId: album.id), aspect: 1.0, placeholderSystemImage: "music.note")
                .frame(width: 140, height: 140)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(album.displayTitle).font(.title2.weight(.semibold))
                    MusicFavoriteButton(isFavorite: album.favorite ?? false) { newValue in
                        try? await client.setAlbumFavorite(albumId: album.id, favorite: newValue)
                    }
                }
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
                        musicPlayer.isShuffling = true
                        musicPlayer.play(queue: tracks.shuffled(), startIndex: 0, client: client)
                    } label: {
                        Label("Shuffle", systemImage: "shuffle")
                    }
                    .disabled(tracks.isEmpty)
                    Button {
                        downloadAllMissing(tracks, client: client, downloads: downloads)
                    } label: {
                        Label("Album herunterladen", systemImage: "arrow.down.circle")
                    }
                    .disabled(tracks.isEmpty)
                }
                // User-Report 2026-09-11 (Screenshot): "Album abspielen"/
                // "Shuffle"/"Album herunterladen" mit Text+Icon quetschten
                // sich auf dem iPhone in eine viel zu schmale HStack-Zelle
                // und der Titeltext wurde dadurch buchstabenweise
                // silbengetrennt vertikal umgebrochen ("Al-bu-m-ab-spi-
                // ele-n") — auf iOS deshalb nur noch Icons (analog zu den
                // bereits icon-only funktionierenden Toolbar-Buttons ganz
                // oben in derselben Ansicht), macOS behält Text+Icon (dort
                // genug Platz, nicht gemeldet als Problem).
                #if os(iOS)
                .labelStyle(.iconOnly)
                #endif
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

    private func shufflePlayLibrary() async {
        guard let items = try? await client.fetchItems(libraryId: library.id), !items.isEmpty else { return }
        musicPlayer.isShuffling = true
        musicPlayer.play(queue: items.shuffled(), startIndex: 0, client: client)
    }
}
#endif
