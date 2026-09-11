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
    /// Kacheln/Liste/Alle Titel — EIN gemeinsamer 3-Wege-Umschalter (User-Wunsch
    /// 2026-09-11: "der Button Alle Titel gehört neben die Listen/Grid Ansicht.
    /// Und soll nicht im extra Fenster öffnen"). "Alle Titel" war zuvor ein
    /// eigenes Sheet (`MusicAllTracksView`) — jetzt einfach ein dritter Modus
    /// direkt in dieser Ansicht, kein separates Fenster/Sheet mehr nötig.
    /// Global persistiert, analog zu `musicListView` im Browser.
    @AppStorage("musicLibraryDisplayMode") private var displayMode: DisplayMode = .grid

    enum DisplayMode: String {
        case grid, list, allTracks
    }
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
    /// Sortierrichtung (User-Wunsch 2026-09-11: "bei Sortierung fehlt die
    /// Richtung") — EIN gemeinsamer Schalter für alle drei Sortierfelder,
    /// analog zum ⬆/⬇-Button neben dem Sort-Dropdown im Browser.
    @State private var sortAscending = true
    @State private var availableGenres: [String] = []
    @State private var selectedGenres: Set<String> = []
    @State private var navigateToAlbum: MusicAlbum?
    // "Alle Titel"-Modus (User-Wunsch 2026-09-11) — eigener, lazy geladener
    // Datensatz statt der Album-Liste; nutzt dasselbe Suchfeld wie die
    // Album-Übersicht, filtert aber Titel/Künstler/Album statt Alben.
    @State private var allTracks: [Item] = []
    @State private var allTracksLoaded = false
    // Spaltenbreiten der Album-Listenansicht per Drag verstellbar (User-Wunsch
    // 2026-09-11: "zumindest beim Mac macht eine Größenverstellung der Spalten
    // Sinn") — persistiert wie im Browser (dort `musicColumns:*` in
    // localStorage), hier via AppStorage. Als Bindings an Header+Zeilen
    // durchgereicht statt eigenständiger @AppStorage in `MusicAlbumRow`, weil
    // separate Structs mit je eigenem @AppStorage sich beim Ziehen nicht
    // gegenseitig live aktualisieren würden (kein gemeinsamer Observer).
    @AppStorage("musicAlbumListArtistWidth") private var artistColWidth: Double = 160
    @AppStorage("musicAlbumListGenreWidth") private var genreColWidth: Double = 120

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
        // `localizedStandardCompare` statt des rohen `<`-Operators (User-Report
        // 2026-09-11: "Ist großes A und kleines a unterschiedlich?" — genau das
        // war der Bug: Swifts Standard-`String`-Vergleich ist NICHT case-
        // insensitiv, "voXXclub" landete dadurch vor "a-ha"/"k.d. lang" statt
        // danach). `localizedStandardCompare` ist case-/akzent-insensitiv und
        // sortiert natürlich (analog zur server-seitigen NATSORT-Collation).
        switch sortOption {
        case .artist:
            result.sort {
                let artistOrder = $0.artist.localizedStandardCompare($1.artist)
                let order = artistOrder == .orderedSame
                    ? $0.album.localizedStandardCompare($1.album)
                    : artistOrder
                return sortAscending ? order == .orderedAscending : order == .orderedDescending
            }
        case .album:
            result.sort {
                let order = $0.album.localizedStandardCompare($1.album)
                return sortAscending ? order == .orderedAscending : order == .orderedDescending
            }
        case .year:
            result.sort {
                sortAscending ? ($0.year ?? 0) < ($1.year ?? 0) : ($0.year ?? 0) > ($1.year ?? 0)
            }
        }
        return result
    }

    private var filteredTracks: [Item] {
        guard !search.isEmpty else { return allTracks }
        return allTracks.filter {
            $0.displayTitle.localizedCaseInsensitiveContains(search)
                || ($0.artist ?? "").localizedCaseInsensitiveContains(search)
                || ($0.album ?? "").localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Trefferzahl der aktuellen Filterung (Suche/Genre) — User-Report
            // 2026-09-11: "die Trefferanzahl beim Filtern wird in keiner Ansicht
            // angezeigt": `.navigationSubtitle` (erster Versuch) landet im
            // nativen Fenstertitel, der in dieser App unsichtbar/nicht gerendert
            // ist (kein sichtbarer Titlebar-Bereich in den Screenshots dieser
            // Session) — deshalb jetzt als echtes, garantiert sichtbares
            // Text-Element im Inhaltsbereich.
            HStack {
                Text(displayMode == .allTracks ? "\(filteredTracks.count) Titel" : "\(filteredAlbums.count) Alben")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal)
            .padding(.top, 8)

            Group {
                switch displayMode {
                case .allTracks:
                    allTracksContent
                case .grid, .list:
                    albumContent
                }
            }
        }
        .navigationTitle(library.name)
        .searchable(text: $search, prompt: displayMode == .allTracks ? "Titel/Künstler/Album durchsuchen" : "Alben/Künstler durchsuchen")
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
            // Kacheln/Liste/Alle Titel als EIN Segment-Control (User-Wunsch
            // 2026-09-11: "der Button Alle Titel gehört neben die Listen/Grid
            // Ansicht") — ersetzt den früheren einzelnen Kachel/Liste-Umschalter
            // UND den separaten "Alle Titel"-Sheet-Button.
            ToolbarItem(placement: .primaryAction) {
                Picker("Ansicht", selection: $displayMode) {
                    Image(systemName: "square.grid.2x2").tag(DisplayMode.grid)
                    Image(systemName: "list.bullet").tag(DisplayMode.list)
                    Image(systemName: "music.note.list").tag(DisplayMode.allTracks)
                }
                .pickerStyle(.segmented)
                .frame(width: 110)
                .help("Kacheln / Liste / Alle Titel")
            }
            // Zufallswiedergabe der GANZEN Bibliothek (User-Wunsch 2026-09-11:
            // "Shuffleplay fehlt in der Übersicht ... aus der kompletten
            // Bibliothek shuffeln") — unabhängig vom ⇄-Shuffle-Toggle in der
            // Mini-Leiste, der nur die AKTUELL laufende Queue mischt.
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
                    Menu("Sortierung") {
                        Picker("Sortierung", selection: $sortOption) {
                            ForEach(AlbumSort.allCases, id: \.self) { option in
                                Text(option.label).tag(option)
                            }
                        }
                        .pickerStyle(.inline)
                        Divider()
                        Button {
                            sortAscending.toggle()
                        } label: {
                            Label(sortAscending ? "Aufsteigend" : "Absteigend", systemImage: sortAscending ? "arrow.up" : "arrow.down")
                        }
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
        .task {
            await load()
            await syncLibraryIfNeeded()
            if displayMode == .allTracks { await loadAllTracks() }
        }
        .onChange(of: displayMode) { newMode in
            if newMode == .allTracks, !allTracksLoaded {
                Task { await loadAllTracks() }
            }
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

    /// Lädt ALLE Titel der Bibliothek (nicht nur das gerade offene Album) und
    /// startet die Wiedergabe gemischt ab einem zufälligen Titel — schaltet
    /// dafür auch gleich den Shuffle-Modus der Engine ein, damit `next()`
    /// (Titel-Ende, ⏭) ebenfalls weiter zufällig bleibt statt in die (bereits
    /// gemischte, aber danach fixe) Reihenfolge zurückzufallen.
    private func shufflePlayLibrary() async {
        guard let items = try? await client.fetchItems(libraryId: library.id), !items.isEmpty else { return }
        // Hörbücher (.m4b) automatisch ausschließen (User-Wunsch 2026-09-11:
        // "noch besser wäre, wenn shuffle Hörbücher automatisch nicht
        // abspielt") — gleiche Konvention wie der Browser
        // (`ItemFilter.ExcludeAudiobooks`, siehe Server-CLAUDE.md
        // "Shuffle-Play"): ein Roman zufällig mitten in einer Hörbuch-Serie
        // zu starten ergibt beim Musik-Shuffle keinen Sinn.
        let playable = items.filter { $0.container?.lowercased() != "m4b" }
        guard !playable.isEmpty else { return }
        musicPlayer.isShuffling = true
        musicPlayer.play(queue: playable.shuffled(), startIndex: 0, client: client)
    }

    private func loadAllTracks() async {
        guard let items = try? await client.fetchItems(libraryId: library.id) else { return }
        allTracks = items.sorted {
            if $0.artist != $1.artist { return ($0.artist ?? "") < ($1.artist ?? "") }
            if $0.album != $1.album { return ($0.album ?? "") < ($1.album ?? "") }
            return ($0.trackNo ?? 0) < ($1.trackNo ?? 0)
        }
        allTracksLoaded = true
    }

    @ViewBuilder
    private var albumContent: some View {
        if isLoading {
            ProgressView()
        } else if let errorMessage {
            ContentUnavailableMessage(text: errorMessage)
        } else if albums.isEmpty {
            ContentUnavailableMessage(text: "Keine Alben gefunden.")
        } else if displayMode == .list {
            // KEIN NavigationLink-Wrapper mehr um die ganze Zeile — das
            // Favoriten-Herz (User-Wunsch 2026-09-11) ist selbst ein Button,
            // und ein Button verschachtelt im Label eines NavigationLink ist
            // in SwiftUI unzuverlässig (gleiche Falle wie bei den Track-
            // Zeilen, siehe Kommentare in MusicAlbumDetailView). Tap navigiert
            // stattdessen über `.onTapGesture` + `navigationDestination(isPresented:)`.
            VStack(spacing: 0) {
                MusicAlbumListHeader(artistWidth: $artistColWidth, genreWidth: $genreColWidth)
                List(filteredAlbums) { album in
                    MusicAlbumRow(album: album, artistWidth: artistColWidth, genreWidth: genreColWidth)
                        .contentShape(Rectangle())
                        .onTapGesture { navigateToAlbum = album }
                }
                .listStyle(.plain)
            }
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

    /// "Alle Titel"-Inhalt — inline statt Sheet (User-Wunsch 2026-09-11), teilt
    /// sich das Suchfeld der Bibliotheksansicht (filtert dann Titel statt Alben).
    @ViewBuilder
    private var allTracksContent: some View {
        if !allTracksLoaded {
            ProgressView()
        } else if allTracks.isEmpty {
            ContentUnavailableMessage(text: "Keine Titel gefunden.")
        } else {
            List {
                HStack {
                    Button {
                        musicPlayer.play(queue: filteredTracks, startIndex: 0, client: client)
                    } label: {
                        Label("Alle abspielen", systemImage: "play.fill")
                    }
                    .disabled(filteredTracks.isEmpty)
                    Button {
                        // Hörbücher (.m4b) auch hier vom Shuffle ausschließen,
                        // siehe Kommentar in `shufflePlayLibrary()`.
                        let playable = filteredTracks.filter { $0.container?.lowercased() != "m4b" }
                        guard !playable.isEmpty else { return }
                        musicPlayer.isShuffling = true
                        musicPlayer.play(queue: playable.shuffled(), startIndex: 0, client: client)
                    } label: {
                        Label("Shuffle abspielen", systemImage: "shuffle")
                    }
                    .disabled(filteredTracks.isEmpty)
                }
                ForEach(Array(filteredTracks.enumerated()), id: \.element.id) { idx, track in
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
                        MusicFavoriteButton(isFavorite: track.favorite) { newValue in
                            try? await client.setFavorite(itemId: track.id, favorite: newValue)
                        }
                        MusicDownloadIcon(item: track)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        musicPlayer.play(queue: filteredTracks, startIndex: idx, client: client)
                    }
                }
            }
            .listStyle(.plain)
        }
    }
}

/// Spaltenbreiten der Album-Listenansicht — Min/Max-Grenzen für den Drag-Resize
/// in `MusicColumnResizeHandle`, geteilt zwischen Kopfzeile (`MusicAlbumListHeader`)
/// und Datenzeile (`MusicAlbumRow`), damit beide exakt fluchten.
private enum MusicAlbumColumn {
    static let widthRange: ClosedRange<CGFloat> = 60...400
    static let countWidth: CGFloat = 60
}

/// Ziehbarer Spaltentrenner (User-Wunsch 2026-09-11: "zumindest beim Mac macht
/// eine Größenverstellung der Spalten Sinn") — analog zum `.col-resize-handle`
/// im Browser (`views.js`/`music.js`). Sitzt als `.overlay` am rechten Rand der
/// jeweiligen Spalte (nicht als eigenes HStack-Element), damit Kopfzeile und
/// Datenzeile exakt dieselbe Spacing-Struktur behalten und bündig fluchten —
/// nur die Kopfzeile trägt den Handle, die Breite wirkt sich über das Binding
/// aber sofort auch auf die Datenzeilen aus. `NSCursor.resizeLeftRight` zeigt
/// beim Hovern den Größenänderungs-Cursor, wie man es von macOS-Tabellen kennt.
private struct MusicColumnResizeHandle: View {
    @Binding var width: Double
    @State private var dragStartWidth: Double?
    @State private var isHovering = false

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: 16) // User-Feedback 2026-09-11: "Ziehbereich etwas
            // größer machen um wenige Pixel" (war 10pt, oft knapp verfehlt)
            .overlay(
                Rectangle()
                    .fill(isHovering ? Color.accentColor.opacity(0.6) : Color.secondary.opacity(0.35))
                    .frame(width: isHovering ? 2 : 1)
            )
            .contentShape(Rectangle())
            .onHover { hovering in
                isHovering = hovering
                if hovering {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if dragStartWidth == nil { dragStartWidth = width }
                        let proposed = (dragStartWidth ?? width) + value.translation.width
                        width = min(max(proposed, MusicAlbumColumn.widthRange.lowerBound), MusicAlbumColumn.widthRange.upperBound)
                    }
                    .onEnded { _ in dragStartWidth = nil }
            )
    }
}

/// Kopfzeile mit Spaltentiteln für die Album-Listenansicht (User-Wunsch
/// 2026-09-11: "extra Spalten mit Künstler und Genre", Spaltenbreiten
/// verstellbar seit demselben Tag). Identische Spacing-Struktur wie
/// `MusicAlbumRow` (`spacing: 12`), damit beide Zeilen bündig fluchten —
/// die Resize-Handles sitzen als Overlay am rechten Spaltenrand, verändern
/// also nicht die HStack-Breiten selbst.
private struct MusicAlbumListHeader: View {
    @Binding var artistWidth: Double
    @Binding var genreWidth: Double

    var body: some View {
        HStack(spacing: 12) {
            // KEIN Cover-Platzhalter mehr vor "Album" (User-Report 2026-09-11:
            // "die Überschrift Alben gehört nach links über die Cover") — die
            // Überschrift steht bewusst schon eine Zeile höher als die
            // Cover-Thumbnails der Datenzeilen darunter, soll also bündig ab
            // dem linken Rand beginnen statt erst nach der 44pt-Cover-Lücke.
            Text("Album")
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .trailing) {
                    // Statischer Trenner (kein Drag) — "Album" bleibt die
                    // flexible Füllspalte, nur Künstler/Genre sind verstellbar.
                    // User-Report: "Zwischen Album und Künstler fehlt der
                    // Trennstrich" — bisher gab es dort GAR keinen Handle.
                    Rectangle().fill(Color.secondary.opacity(0.35)).frame(width: 1)
                }
            Text("Künstler")
                .frame(width: artistWidth, alignment: .leading)
                .overlay(alignment: .trailing) {
                    MusicColumnResizeHandle(width: $artistWidth).offset(x: 14)
                }
            Text("Genre")
                .frame(width: genreWidth, alignment: .leading)
                .overlay(alignment: .trailing) {
                    MusicColumnResizeHandle(width: $genreWidth).offset(x: 14)
                }
            Text("Titel").frame(width: MusicAlbumColumn.countWidth, alignment: .trailing)
            Color.clear.frame(width: 22, height: 1) // Favoriten-Spalte
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal)
        .padding(.vertical, 4)
    }
}

/// Zeilen-Darstellung eines Albums für die Listenansicht (User-Wunsch 2026-09-11:
/// "Es fehlt noch eine Listenansicht", später ergänzt um Künstler-/Genre-Spalten
/// + Spaltenbreiten) — kompaktes Cover-Thumbnail statt großer Kachel, analog zur
/// Browser-Album-Listenzeile (`.track-row--album`).
private struct MusicAlbumRow: View {
    let album: MusicAlbum
    let artistWidth: Double
    let genreWidth: Double
    @EnvironmentObject var client: GoldfishClient

    var body: some View {
        HStack(spacing: 12) {
            PosterImage(url: client.albumCoverURL(albumId: album.id), aspect: 1.0, placeholderSystemImage: "music.note")
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 5))
            Text(album.displayTitle)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(album.artist)
                .lineLimit(1)
                .foregroundStyle(.secondary)
                .frame(width: artistWidth, alignment: .leading)
            Text(album.genre ?? "")
                .lineLimit(1)
                .foregroundStyle(.secondary)
                .frame(width: genreWidth, alignment: .leading)
            Text(album.trackCount.map { "\($0)" } ?? "")
                .foregroundStyle(.secondary)
                .frame(width: MusicAlbumColumn.countWidth, alignment: .trailing)
            MusicFavoriteButton(isFavorite: album.favorite ?? false) { newValue in
                try? await client.setAlbumFavorite(albumId: album.id, favorite: newValue)
            }
            .frame(width: 22)
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
