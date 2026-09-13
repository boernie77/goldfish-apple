#if os(macOS) || os(iOS)
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
    // User-Report 2026-09-11: "Wenn man auf Sortieren oder Genre klickt,
    // dann ploppt kurz das Menü auf, aber verschwindet gleich wieder" — ein
    // `Menu` VERSCHACHTELT in einem anderen `Menu` (Sortierung/Genre als
    // Untermenüs von "Musik-Optionen") ist auf iOS in einer Toolbar
    // nachweislich unzuverlässig, exakt dasselbe Muster wie das bereits in
    // CLAUDE.md dokumentierte "Menu-in-Toolbar auf tvOS öffnet zuverlässig
    // nichts" — dort ist die etablierte Lösung ebenfalls ein Sheet statt
    // eines verschachtelten Menüs. Auf iOS ersetzt ein Sheet die beiden
    // Untermenüs; macOS behält die (dort funktionierende) Menu-in-Menu-UI.
    #if os(iOS)
    @State private var showSortGenreSheet = false
    #endif
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
    // User-Korrektur 2026-09-11 ("Der Trennstrich zwischen Album und Künstler
    // ist nicht verschiebbar! Das war doch der Sinn des ganzen!!"): Runde 10
    // hatte dort nur eine STATISCHE Linie ergänzt, weil "Album" bis dahin die
    // flexible Füllspalte (`maxWidth: .infinity`) war — eine Füllspalte kann
    // keine per Drag verstellbare "Breite" im selben Sinn haben wie eine feste
    // Spalte. Fix: "Album" bekommt jetzt genau wie Künstler/Genre eine eigene
    // feste, per Drag verstellbare Breite; ein Spacer() am Zeilenende füllt
    // den verbleibenden Platz (Album ist nicht mehr die Füllspalte).
    @AppStorage("musicAlbumListAlbumWidth") private var albumColWidth: Double = 260
    @AppStorage("musicAlbumListArtistWidth") private var artistColWidth: Double = 160
    @AppStorage("musicAlbumListGenreWidth") private var genreColWidth: Double = 120
    // Drei neue, OPT-IN-Spalten (User-Wunsch 2026-09-14: "zuletzt abgespielt/
    // wie oft abgespielt/hinzugefügt als Spalten... und ein Dropdown, wo ich
    // auswählen kann, welche Spalten angezeigt werden") — Breiten wie die
    // bestehenden Spalten per AppStorage, Sichtbarkeit separat über
    // `MusicColumnVisibility` (siehe MusicColumns.swift), Default: alle drei
    // ausgeblendet (Allowlist-Prinzip, analog zum Browser).
    @AppStorage("musicAlbumListLastPlayedWidth") private var lastPlayedColWidth: Double = 130
    @AppStorage("musicAlbumListPlayCountWidth") private var playCountColWidth: Double = 90
    @AppStorage("musicAlbumListAddedWidth") private var addedColWidth: Double = 120
    // "Alle Titel" bekommt dieselbe Spalten-Kopfzeile + feste, per Drag
    // verstellbare Breiten wie die Album-Listenansicht (User-Wunsch
    // 2026-09-14: "Alle Titel ist optisch völlig anders aufgebaut ... Bitte
    // einheitlich, so wie die Listenansicht der Alben") — vorher eine
    // Karten-artige Zeile (Titel+Künstler/Album gestapelt, keine Kopfzeile,
    // keine Spaltenbreiten). Eigene Breiten-Keys, weil die Spaltenbedeutung
    // eine andere ist (Titel/Künstler/Album statt Album/Künstler/Genre).
    @AppStorage("musicAllTracksTitleWidth") private var atTitleWidth: Double = 220
    @AppStorage("musicAllTracksArtistWidth") private var atArtistWidth: Double = 160
    @AppStorage("musicAllTracksAlbumWidth") private var atAlbumWidth: Double = 200
    @AppStorage("musicAllTracksLastPlayedWidth") private var atLastPlayedWidth: Double = 130
    @AppStorage("musicAllTracksPlayCountWidth") private var atPlayCountWidth: Double = 90
    @AppStorage("musicAllTracksAddedWidth") private var atAddedWidth: Double = 120
    #if os(macOS)
    @State private var musicColumnsRefresh = false
    private var visibleAlbumColumns: Set<MusicColumn> {
        _ = musicColumnsRefresh
        return MusicColumnVisibility.visible(for: "albums", default: [])
    }
    private var visibleAllTracksColumns: Set<MusicColumn> {
        _ = musicColumnsRefresh
        return MusicColumnVisibility.visible(for: "allTracks", default: [])
    }
    #endif

    // "genre"/"count"/"lastPlayed"/"playCount"/"added" seit 2026-09-13 ergänzt
    // (User-Wunsch: "warum klappt die Sortierung der Spalten nicht so, wie in
    // der Linux App, indem man auf den Kopf der Spalte klickt" — GoldfishLinux
    // nutzt dafür ein natives Gtk.ColumnView, dessen Spalten von Haus aus per
    // Klick sortieren, siehe dortiges `widgets/column_list.py`). Dieselbe
    // `AlbumSort`/`sortOption`/`sortAscending`-State treibt jetzt SOWOHL das
    // bestehende Sortier-Menü in der Toolbar ALS AUCH einen Klick auf die
    // Spaltenüberschrift in `MusicAlbumListHeader` — ein Klick dort setzt
    // exakt dieselben @State-Variablen, keine zweite, parallele Sortierlogik.
    enum AlbumSort: String, CaseIterable {
        case artist, album, genre, year, count, lastPlayed, playCount, added
        var label: String {
            switch self {
            case .artist: return "Künstler"
            case .album: return "Album"
            case .genre: return "Genre"
            case .year: return "Jahr"
            case .count: return "Titel"
            case .lastPlayed: return "Zuletzt gehört"
            case .playCount: return "Wiedergaben"
            case .added: return "Hinzugefügt"
            }
        }
    }

    // Pendant zu `AlbumSort` für die "Alle Titel"-Ansicht — ersetzt seit
    // 2026-09-13 den vorherigen ad-hoc `recentlyPlayedFirst`-Bool-Toggle
    // (der nur "nach zuletzt gehört sortieren, ja/nein" konnte): Klick auf
    // JEDE Spaltenüberschrift in `MusicTrackListHeader` sortiert jetzt danach,
    // ein zweiter Klick auf dieselbe Spalte dreht die Richtung um — exakt das
    // Verhalten, das der User von der Linux-App kannte. Eigene @State-
    // Variablen statt Wiederverwendung von `sortOption`/`sortAscending`, da
    // Album- und Track-Ansicht unabhängig ihre zuletzt gewählte Sortierung
    // behalten sollen (Umschalten zwischen den Modi wechselt sonst überraschend
    // die jeweils andere Ansicht mit).
    enum TrackSort: String, CaseIterable {
        case title, artist, album, duration, lastPlayed, playCount, added
        var label: String {
            switch self {
            case .title: return "Titel"
            case .artist: return "Künstler"
            case .album: return "Album"
            case .duration: return "Dauer"
            case .lastPlayed: return "Zuletzt gehört"
            case .playCount: return "Wiedergaben"
            case .added: return "Hinzugefügt"
            }
        }
    }

    init(library: Library) {
        self.library = library
        self._librarySyncEnabled = AppStorage(wrappedValue: false, "musicLibrarySync.\(library.id)")
    }

    private let cardWidth: CGFloat = 170
    // User-Wunsch 2026-09-11: immer 2 Kacheln pro Zeile auf iOS, siehe ItemGridView.swift.
    #if os(iOS)
    private var columns: [GridItem] { [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)] }
    #else
    private var columns: [GridItem] { [GridItem(.adaptive(minimum: cardWidth, maximum: cardWidth), spacing: 16, alignment: .top)] }
    #endif

    // Rein client-seitige Filterung über bereits geladene Alben/Tracks (kein
    // Server-Roundtrip) — `localizedCaseInsensitiveContains` ist case-, aber
    // NICHT akzent-insensitiv. User-Wunsch 2026-09-13: "senorita" soll auch
    // "Señorita" finden, server-seitig via UNACCENT() bereits gelöst — diese
    // Ansicht hier ruft die Suche aber nie über den Server ab, filtert
    // stattdessen selbst über die im Speicher gehaltene Liste, war also von
    // dem Fix unberührt. `.diacriticInsensitive` gleicht das clientseitig an.
    private func matchesSearch(_ text: String) -> Bool {
        text.range(of: search, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    private var filteredAlbums: [MusicAlbum] {
        var result = albums
        if !search.isEmpty {
            result = result.filter {
                matchesSearch($0.album) || matchesSearch($0.artist)
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
        case .genre:
            result.sort {
                let order = ($0.genre ?? "").localizedStandardCompare($1.genre ?? "")
                return sortAscending ? order == .orderedAscending : order == .orderedDescending
            }
        case .count:
            result.sort {
                sortAscending ? ($0.trackCount ?? 0) < ($1.trackCount ?? 0) : ($0.trackCount ?? 0) > ($1.trackCount ?? 0)
            }
        case .lastPlayed, .playCount, .added:
            result.sort { musicOptionalCompare(sortKeyValue(for: sortOption, $0), sortKeyValue(for: sortOption, $1), ascending: sortAscending) }
        }
        return result
    }

    /// Rohwert für die drei "Aggregat"-Sortierfelder, die nicht einfach per
    /// `<`/`localizedStandardCompare` vergleichbar sind (String? für Datum,
    /// Int? für Wiedergaben) — ein gemeinsamer Helfer statt drei Fast-
    /// identische `.sort {}`-Blöcke.
    private func sortKeyValue(for option: AlbumSort, _ album: MusicAlbum) -> MusicSortValue {
        switch option {
        case .lastPlayed: return .text(album.lastPlayedAt)
        case .playCount: return .number(album.playCount.map(Double.init))
        case .added: return .text(album.addedAt)
        default: return .text(nil)
        }
    }

    private func sortKeyValue(for option: TrackSort, _ track: Item) -> MusicSortValue {
        switch option {
        case .lastPlayed: return .text(track.lastPlayedAt)
        case .playCount: return .number(track.playCount.map(Double.init))
        case .added: return .text(track.addedAt)
        case .duration: return .number(track.durationSec)
        default: return .text(nil)
        }
    }

    /// Sortierung der "Alle Titel"-Ansicht per Klick auf eine Spaltenüberschrift
    /// (`MusicTrackListHeader`, seit 2026-09-13) — ersetzt den vorherigen
    /// ad-hoc `recentlyPlayedFirst`-Bool-Toggle (konnte nur "nach zuletzt
    /// gehört, ja/nein"), User-Wunsch: "warum klappt die Sortierung der
    /// Spalten nicht so, wie in der Linux App, indem man auf den Kopf der
    /// Spalte klickt". Eigene @State-Variablen statt Wiederverwendung von
    /// `sortOption`/`sortAscending` — siehe Kommentar bei `TrackSort` oben.
    @State private var trackSortOption: TrackSort = .title
    @State private var trackSortAscending = true

    private var filteredTracks: [Item] {
        var result = allTracks
        switch trackSortOption {
        case .title:
            result.sort {
                let order = $0.displayTitle.localizedStandardCompare($1.displayTitle)
                return trackSortAscending ? order == .orderedAscending : order == .orderedDescending
            }
        case .artist:
            result.sort {
                let order = ($0.artist ?? "").localizedStandardCompare($1.artist ?? "")
                return trackSortAscending ? order == .orderedAscending : order == .orderedDescending
            }
        case .album:
            result.sort {
                let order = ($0.album ?? "").localizedStandardCompare($1.album ?? "")
                return trackSortAscending ? order == .orderedAscending : order == .orderedDescending
            }
        case .duration, .lastPlayed, .playCount, .added:
            result.sort { musicOptionalCompare(sortKeyValue(for: trackSortOption, $0), sortKeyValue(for: trackSortOption, $1), ascending: trackSortAscending) }
        }
        guard !search.isEmpty else { return result }
        return result.filter {
            matchesSearch($0.displayTitle)
                || matchesSearch($0.artist ?? "")
                || matchesSearch($0.album ?? "")
        }
    }

    // Eine aktive Suche außerhalb von "Alle Titel" zeigt jetzt die
    // matchenden TRACKS selbst als Trefferliste (User-Report 2026-09-12:
    // "wenn ich nach einem Titel gesucht habe, dann kam kein Treffer. Auch
    // nicht das Album" — die Album-Kacheln/Liste filterten bis dahin nur
    // gegen Album-/Künstlername, nie gegen Track-Titel, exakt das gleiche
    // Muster wie der zeitgleich gefixte Server-/Browser-Bug). Nutzt
    // denselben Track-Zeilen-Renderer wie "Alle Titel" (`allTracksContent`/
    // `filteredTracks`), lädt `allTracks` dafür bei Bedarf lazy nach.
    private var showingTrackSearchResults: Bool { !search.isEmpty && displayMode != .allTracks }

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
                Text(displayMode == .allTracks || showingTrackSearchResults ? "\(filteredTracks.count) Titel" : "\(filteredAlbums.count) Alben")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal)
            .padding(.top, 8)

            Group {
                if showingTrackSearchResults {
                    if !allTracksLoaded {
                        ProgressView()
                    } else {
                        allTracksContent
                    }
                } else {
                    switch displayMode {
                    case .allTracks:
                        allTracksContent
                    case .grid, .list:
                        albumContent
                    }
                }
            }
        }
        .navigationTitle(library.name)
        .searchable(text: $search, prompt: displayMode == .allTracks ? "Titel/Künstler/Album durchsuchen" : "Titel, Künstler oder Album durchsuchen")
        .onChange(of: search) { newValue in
            if !newValue.isEmpty, !allTracksLoaded {
                Task { await loadAllTracks() }
            }
        }
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
            // NUR im Kachelmodus (User-Wunsch 2026-09-14: "der Shuffle Button
            // ist jetzt ja doppelt. Der obere kann bei Musik dann entfernt
            // werden. Zumindest in der Listenansicht") — Listen-/Alle-Titel-
            // Modus haben seither ihre eigene, inline Shuffle-Aktion direkt
            // über der Titelliste (siehe `musicActionRow`), der Toolbar-Knopf
            // wäre dort ein reines Duplikat.
            if displayMode == .grid {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await shufflePlayLibrary() }
                    } label: {
                        Label("Zufallswiedergabe", systemImage: "shuffle")
                    }
                    .help("Zufällige Wiedergabe der ganzen Bibliothek")
                }
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
                    #if os(iOS)
                    // Siehe Kommentar bei `showSortGenreSheet` oben — ein
                    // Button statt eines verschachtelten Menüs, öffnet einen
                    // zuverlässigen Sheet statt eines flackernden Untermenüs.
                    Button {
                        showSortGenreSheet = true
                    } label: {
                        Label("Sortieren & Genre", systemImage: "line.3.horizontal.decrease.circle")
                    }
                    #else
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
                    Menu("☰ Spalten") {
                        MusicColumnsMenuContent(
                            context: "albums",
                            available: [.lastPlayed, .playCount, .added],
                            defaultVisible: [],
                            refreshToken: $musicColumnsRefresh
                        )
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
                    #endif
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
        #if os(iOS)
        .sheet(isPresented: $showSortGenreSheet) {
            NavigationStack {
                List {
                    Section("Sortierung") {
                        Picker("Sortierung", selection: $sortOption) {
                            ForEach(AlbumSort.allCases, id: \.self) { option in
                                Text(option.label).tag(option)
                            }
                        }
                        .pickerStyle(.inline)
                        Button {
                            sortAscending.toggle()
                        } label: {
                            Label(sortAscending ? "Aufsteigend" : "Absteigend", systemImage: sortAscending ? "arrow.up" : "arrow.down")
                        }
                    }
                    if !availableGenres.isEmpty {
                        Section("Genre") {
                            Button {
                                selectedGenres.removeAll()
                            } label: {
                                HStack {
                                    Text("Alle Genres")
                                    Spacer()
                                    if selectedGenres.isEmpty {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                            ForEach(availableGenres, id: \.self) { genre in
                                Button {
                                    if selectedGenres.contains(genre) {
                                        selectedGenres.remove(genre)
                                    } else {
                                        selectedGenres.insert(genre)
                                    }
                                } label: {
                                    HStack {
                                        Text(genre)
                                        Spacer()
                                        if selectedGenres.contains(genre) {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .navigationTitle("Sortieren & Genre")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Fertig") { showSortGenreSheet = false }
                    }
                }
            }
        }
        #endif
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
            // Siehe Kommentar in MusicAlbumDetailView: minWidth:480 sprengt
            // den iPhone-Bildschirm, nur auf macOS sinnvoll.
            #if os(macOS)
            .frame(minWidth: 480, minHeight: 480)
            #endif
        }
        .sheet(isPresented: $showPlaylists) {
            NavigationStack {
                MusicPlaylistsView()
            }
            #if os(macOS)
            .frame(minWidth: 480, minHeight: 480)
            #endif
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

    /// "Alle abspielen" für die Album-Listenansicht (User-Wunsch 2026-09-14:
    /// dieselbe Aktionsreihe wie "Alle Titel" — dort ist "Alle abspielen"
    /// serverseitig sortiert). Bewusst ein frischer Fetch statt des `allTracks`-
    /// Zwischenspeichers aus dem "Alle Titel"-Modus, analog zu
    /// `shufflePlayLibrary()` direkt darunter — beide Aktionen dieser Zeile
    /// sollen unabhängig vom aktuell gewählten Anzeige-Modus funktionieren.
    private func playLibraryInOrder() async {
        guard let items = try? await client.fetchItems(libraryId: library.id), !items.isEmpty else { return }
        musicPlayer.play(queue: items, startIndex: 0, client: client)
    }

    /// Lädt ALLE Titel der Bibliothek (nicht nur das gerade offene Album) und
    /// startet die Wiedergabe gemischt ab einem zufälligen Titel — schaltet
    /// dafür auch gleich den Shuffle-Modus der Engine ein, damit `next()`
    /// (Titel-Ende, ⏭) ebenfalls weiter zufällig bleibt statt in die (bereits
    /// gemischte, aber danach fixe) Reihenfolge zurückzufallen.
    private func shufflePlayLibrary() async {
        guard let items = try? await client.fetchItems(libraryId: library.id), !items.isEmpty else { return }
        // Hörbücher automatisch ausschließen (User-Wunsch 2026-09-11:
        // "noch besser wäre, wenn shuffle Hörbücher automatisch nicht
        // abspielt", erweitert 2026-09-14: "Bitte Hörbücher, Hörbuch,
        // Audiobook ausschließen" — reiner .m4b-Container-Check übersah ein
        // Hörbuch mit MP3-Kapiteln) — gleiche Konvention wie der Browser/
        // Server (`ItemFilter.ExcludeAudiobooks`, siehe Server-CLAUDE.md
        // "Shuffle-Play"): ein Roman zufällig mitten in einer Hörbuch-Serie
        // zu starten ergibt beim Musik-Shuffle keinen Sinn.
        let playable = items.filter { !$0.isLikelyAudiobook }
        guard !playable.isEmpty else { return }
        musicPlayer.play(queue: playable.shuffled(), startIndex: 0, client: client, shuffle: true)
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
            // User-Report 2026-09-11: "Die Ansicht Liste ist nicht für das
            // Iphone optimiert. Da sieht man gar nichts" — `MusicAlbumRow`/
            // `MusicAlbumListHeader` sind auf feste, per Drag verstellbare
            // Spaltenbreiten ausgelegt (Cover 44 + Album 260 + Künstler 160 +
            // Genre 120 + Titelzahl 60 + Favorit 22 + Abstände ≈ 750pt) — auf
            // einem iPhone (typisch 375-430pt Breite) weit mehr, als je
            // hinpasst, der Rest fällt unsichtbar rechts raus. Auf iOS
            // deshalb eine eigene, kompakte Zeile ohne feste Spaltenbreiten
            // (Cover+Titel/Künstler/Genre gestapelt, kein Resize — macht auf
            // Touch ohnehin keinen Sinn).
            #if os(iOS)
            List(filteredAlbums) { album in
                MusicAlbumRowCompact(album: album)
                    .contentShape(Rectangle())
                    .onTapGesture { navigateToAlbum = album }
            }
            .listStyle(.plain)
            // Siehe Kommentar in MusicAlbumDetailView — `List` braucht den
            // Mini-Player-Sicherheitsabstand explizit, sonst verdeckt die
            // Leiste die letzte Zeile.
            .safeAreaInset(edge: .bottom) {
                if musicPlayer.currentItem != nil {
                    Color.clear.frame(height: 64)
                }
            }
            #else
            // Kopfbereich MUSS strukturell identisch zu `allTracksContent` sein
            // (User-Report 2026-09-13, mit Screenshot: "Über und unter den
            // Spaltenüberschriften ist eine Linie!!" — nur in "Alle Titel" sichtbar,
            // in der Album-Übersicht fehlte sie komplett). Ursache war KEIN Stil-
            // Unterschied, sondern eine echte Strukturabweichung: `allTracksContent`
            // legt `musicActionRow`/`MusicTrackListHeader` als Zeilen DIREKT in die
            // `List` (List zeichnet automatisch Trennlinien über/unter jeder eigenen
            // Zeile) — diese Ansicht hatte Aktionsreihe+Kopfzeile bisher AUSSERHALB
            // der List in einem separaten `VStack` stehen, wo nie eine Trennlinie
            // gezeichnet wird. Fix: exakt dieselbe Struktur — EINE `List`, die auch
            // die Aktionsreihe und die Kopfzeile als eigene Zeilen enthält, kein
            // äußerer VStack mehr, kein manuelles `.padding()` (die Track-Variante
            // hat das auch nicht — für echte Pixelgleichheit keine zusätzlichen
            // Modifier hier einführen, die dort fehlen).
            List {
                musicActionRow(
                    disablePlayShuffle: filteredAlbums.isEmpty,
                    columnsContext: "albums",
                    onPlay: { Task { await playLibraryInOrder() } },
                    onShuffle: { Task { await shufflePlayLibrary() } }
                )
                MusicAlbumListHeader(
                    albumWidth: $albumColWidth, artistWidth: $artistColWidth, genreWidth: $genreColWidth,
                    lastPlayedWidth: $lastPlayedColWidth, playCountWidth: $playCountColWidth, addedWidth: $addedColWidth,
                    visibleColumns: visibleAlbumColumns,
                    sortOption: $sortOption, sortAscending: $sortAscending
                )
                // Zusätzlicher Abstand unter der Trennlinie der Kopfzeile
                // (User-Wunsch 2026-09-13) — eine eigene, unsichtbare Zeile
                // zwischen Kopfzeile und erster Datenzeile. `edges: .bottom`
                // (statt pauschal `.hidden`) ist hier wichtig: `.hidden` ohne
                // `edges:` blendet BEIDE Trennlinien dieser Zeile aus — damit
                // verschwand die eigentlich gewünschte Linie UNTER der
                // Kopfzeile gleich mit (die "obere" Linie dieser Abstandszeile
                // IST die untere Linie der Kopfzeile, dieselbe Trennlinie).
                // Nur die EIGENE untere Trennlinie dieser Zeile (zur ersten
                // Datenzeile hin) wird ausgeblendet, sonst gäbe es dort zwei
                // Linien mit nur 8pt Abstand dazwischen.
                Color.clear.frame(height: 8).listRowSeparator(.hidden, edges: .bottom)
                ForEach(filteredAlbums) { album in
                    MusicAlbumRow(
                        album: album, albumWidth: albumColWidth, artistWidth: artistColWidth, genreWidth: genreColWidth,
                        lastPlayedWidth: lastPlayedColWidth, playCountWidth: playCountColWidth, addedWidth: addedColWidth,
                        visibleColumns: visibleAlbumColumns
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { navigateToAlbum = album }
                }
            }
            .listStyle(.plain)
            #endif
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

    /// Gemeinsame Aktionsreihe für "Alle Titel" UND die Album-Listenansicht
    /// (User-Wunsch 2026-09-14: "Diese müssen dann aber auch genauso bei der
    /// Listenansicht der Alben sein, wenn es optisch gleich sein soll" +
    /// "die Beschriftung der Buttons Alle Abspielen etc kann weg. Das Icon
    /// reicht") — nur EINE Stelle für Play/Shuffle/Spalten-Menü, statt zwei
    /// unabhängig gepflegter, potenziell auseinanderlaufender Kopien.
    /// `.contentShape(Rectangle())` auf allen Buttons: siehe "Alle Titel"-
    /// Bugfix-Historie oben (mehrere `Button`s in derselben List-Zeile ohne
    /// eigene Trefferfläche lösten sich sonst gegenseitig aus). Farbe zeigt
    /// den aktiven Wiedergabe-Modus (`musicPlayer.isShuffling`), braucht
    /// dafür `.buttonStyle(.plain)` (sonst überschreibt die automatische
    /// List-Blaufärbung die bedingte Farbe).
    /// Der frühere separate "Zuletzt abgespielt zuerst"-Knopf (nur in "Alle
    /// Titel") ist seit 2026-09-13 raus (User-Report: "Der Kopfbereich schaut
    /// immer noch unterschiedlich aus ... bei der Listenansicht der Album und
    /// Songansicht") — er war der letzte Unterschied zwischen den beiden
    /// Aktionsreihen. Sortieren nach "Zuletzt gehört" geht jetzt gleichwertig
    /// (und für BEIDE Ansichten identisch bedienbar) per Klick auf die
    /// gleichnamige Spaltenüberschrift, siehe `TrackSort`/`AlbumSort` oben.
    @ViewBuilder
    private func musicActionRow(
        disablePlayShuffle: Bool,
        columnsContext: String,
        onPlay: @escaping () -> Void,
        onShuffle: @escaping () -> Void
    ) -> some View {
        HStack {
            Button(action: onPlay) {
                Label("Alle abspielen", systemImage: "play.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(musicPlayer.isShuffling ? Color.primary : Color.accentColor)
            .contentShape(Rectangle())
            .disabled(disablePlayShuffle)
            Button(action: onShuffle) {
                Label("Shuffle abspielen", systemImage: "shuffle")
            }
            .buttonStyle(.plain)
            .foregroundStyle(musicPlayer.isShuffling ? Color.accentColor : Color.primary)
            .contentShape(Rectangle())
            .disabled(disablePlayShuffle)
            #if os(macOS)
            Spacer()
            Menu {
                MusicColumnsMenuContent(
                    context: columnsContext,
                    available: [.lastPlayed, .playCount, .added],
                    defaultVisible: [],
                    refreshToken: $musicColumnsRefresh
                )
            } label: {
                Label("Spalten", systemImage: "line.3.horizontal")
            }
            #endif
        }
        .labelStyle(.iconOnly)
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
                musicActionRow(
                    disablePlayShuffle: filteredTracks.isEmpty,
                    columnsContext: "allTracks",
                    onPlay: { musicPlayer.play(queue: filteredTracks, startIndex: 0, client: client) },
                    onShuffle: {
                        // Hörbücher auch hier vom Shuffle ausschließen,
                        // siehe Kommentar in `shufflePlayLibrary()`.
                        let playable = filteredTracks.filter { !$0.isLikelyAudiobook }
                        guard !playable.isEmpty else { return }
                        musicPlayer.play(queue: playable.shuffled(), startIndex: 0, client: client, shuffle: true)
                    }
                )
                // macOS: dieselbe Spalten-Kopfzeile + feste Breiten wie die
                // Album-Listenansicht (User-Wunsch 2026-09-14, siehe
                // `atTitleWidth` oben) — vorher eine optisch andere,
                // Karten-artige Zeile ohne Kopfzeile/Spaltenraster. iOS
                // bleibt bei der bisherigen, kompakten Zeile (feste
                // Spaltenbreiten ergeben auf iPhone-Breite keinen Sinn,
                // gleiche Begründung wie bei `MusicAlbumRowCompact`).
                #if os(macOS)
                MusicTrackListHeader(
                    titleWidth: $atTitleWidth, artistWidth: $atArtistWidth, albumWidth: $atAlbumWidth,
                    lastPlayedWidth: $atLastPlayedWidth, playCountWidth: $atPlayCountWidth, addedWidth: $atAddedWidth,
                    visibleColumns: visibleAllTracksColumns,
                    sortOption: $trackSortOption, sortAscending: $trackSortAscending
                )
                // Gleicher zusätzlicher Abstand wie in der Album-Übersicht, siehe
                // Kommentar dort.
                Color.clear.frame(height: 8).listRowSeparator(.hidden, edges: .bottom)
                #endif
                ForEach(Array(filteredTracks.enumerated()), id: \.element.id) { idx, track in
                    #if os(macOS)
                    MusicTrackListRow(
                        track: track, titleWidth: atTitleWidth, artistWidth: atArtistWidth, albumWidth: atAlbumWidth,
                        lastPlayedWidth: atLastPlayedWidth, playCountWidth: atPlayCountWidth, addedWidth: atAddedWidth,
                        visibleColumns: visibleAllTracksColumns,
                        isCurrent: musicPlayer.currentItem?.id == track.id, isPlaying: musicPlayer.isPlaying
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        musicPlayer.play(queue: filteredTracks, startIndex: idx, client: client)
                    }
                    #else
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
                    #endif
                }
            }
            .listStyle(.plain)
            // Siehe Kommentar in MusicAlbumDetailView.
            .safeAreaInset(edge: .bottom) {
                if musicPlayer.currentItem != nil {
                    Color.clear.frame(height: 64)
                }
            }
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

/// Formatiert einen vom Server gelieferten Datums-String (RFC3339, teils mit
/// Bruchteilssekunden/Zeitzone) als kurzes, lesbares Datum für die neuen
/// Spalten "Zuletzt gehört"/"Hinzugefügt" — lenient statt ein hartes Format
/// zu erzwingen, weil Go's `time.Time`-JSON-Encoding leicht variiert.
func musicDateLabel(_ iso: String?) -> String {
    guard let iso, !iso.isEmpty else { return "—" }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    var date = formatter.date(from: iso)
    if date == nil {
        formatter.formatOptions = [.withInternetDateTime]
        date = formatter.date(from: iso)
    }
    guard let date else { return String(iso.prefix(10)) }
    let out = DateFormatter()
    out.dateStyle = .short
    out.timeStyle = .none
    return out.string(from: date)
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
                #if os(macOS)
                if hovering {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
                #endif
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
    @Binding var albumWidth: Double
    @Binding var artistWidth: Double
    @Binding var genreWidth: Double
    #if os(macOS)
    @Binding var lastPlayedWidth: Double
    @Binding var playCountWidth: Double
    @Binding var addedWidth: Double
    var visibleColumns: Set<MusicColumn> = []
    #endif
    // Klick-zum-Sortieren (seit 2026-09-13, User-Wunsch: "warum klappt die
    // Sortierung der Spalten nicht so, wie in der Linux App, indem man auf
    // den Kopf der Spalte klickt") — dieselben @State-Variablen wie das
    // bestehende Sortier-Menü in der Toolbar, siehe `MusicLibraryView.AlbumSort`.
    @Binding var sortOption: MusicLibraryView.AlbumSort
    @Binding var sortAscending: Bool

    private func toggle(_ column: MusicLibraryView.AlbumSort) {
        if sortOption == column { sortAscending.toggle() } else { sortOption = column; sortAscending = true }
    }

    var body: some View {
        HStack(spacing: 12) {
            // KEIN Cover-Platzhalter mehr vor "Album" (User-Report 2026-09-11:
            // "die Überschrift Alben gehört nach links über die Cover") — die
            // Überschrift steht bewusst schon eine Zeile höher als die
            // Cover-Thumbnails der Datenzeilen darunter, soll also bündig ab
            // dem linken Rand beginnen statt erst nach der 44pt-Cover-Lücke.
            // "Album" bekommt eine eigene, per Drag verstellbare Breite
            // (User-Korrektur 2026-09-11: "Der Trennstrich zwischen Album
            // und Künstler ist nicht verschiebbar! Das war doch der Sinn des
            // ganzen!!" — die vorherige Version war nur eine statische
            // Linie, weil "Album" bis dahin die flexible Füllspalte war).
            MusicSortableHeaderLabel(title: "Album", isActive: sortOption == .album, ascending: sortAscending, alignment: .leading) { toggle(.album) }
                .frame(width: albumWidth, alignment: .leading)
                .overlay(alignment: .trailing) {
                    MusicColumnResizeHandle(width: $albumWidth).offset(x: 14)
                }
            MusicSortableHeaderLabel(title: "Künstler", isActive: sortOption == .artist, ascending: sortAscending, alignment: .leading) { toggle(.artist) }
                .frame(width: artistWidth, alignment: .leading)
                .overlay(alignment: .trailing) {
                    MusicColumnResizeHandle(width: $artistWidth).offset(x: 14)
                }
            MusicSortableHeaderLabel(title: "Genre", isActive: sortOption == .genre, ascending: sortAscending, alignment: .leading) { toggle(.genre) }
                .frame(width: genreWidth, alignment: .leading)
                .overlay(alignment: .trailing) {
                    MusicColumnResizeHandle(width: $genreWidth).offset(x: 14)
                }
            #if os(macOS)
            if visibleColumns.contains(.lastPlayed) {
                MusicSortableHeaderLabel(title: "Zuletzt gehört", isActive: sortOption == .lastPlayed, ascending: sortAscending, alignment: .leading) { toggle(.lastPlayed) }
                    .frame(width: lastPlayedWidth, alignment: .leading)
                    .overlay(alignment: .trailing) {
                        MusicColumnResizeHandle(width: $lastPlayedWidth).offset(x: 14)
                    }
            }
            if visibleColumns.contains(.playCount) {
                MusicSortableHeaderLabel(title: "Wiedergaben", isActive: sortOption == .playCount, ascending: sortAscending, alignment: .trailing) { toggle(.playCount) }
                    .frame(width: playCountWidth, alignment: .trailing)
                    .overlay(alignment: .trailing) {
                        MusicColumnResizeHandle(width: $playCountWidth).offset(x: 14)
                    }
            }
            if visibleColumns.contains(.added) {
                MusicSortableHeaderLabel(title: "Hinzugefügt", isActive: sortOption == .added, ascending: sortAscending, alignment: .leading) { toggle(.added) }
                    .frame(width: addedWidth, alignment: .leading)
                    .overlay(alignment: .trailing) {
                        MusicColumnResizeHandle(width: $addedWidth).offset(x: 14)
                    }
            }
            #endif
            MusicSortableHeaderLabel(title: "Titel", isActive: sortOption == .count, ascending: sortAscending, alignment: .trailing) { toggle(.count) }
                .frame(width: MusicAlbumColumn.countWidth, alignment: .trailing)
            Color.clear.frame(width: 22, height: 1) // Favoriten-Spalte
            Spacer(minLength: 0) // füllt den Rest (Album ist nicht mehr die Füllspalte)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal)
        .padding(.vertical, 4)
    }
}

/// Ein Spalten-Label in der Musik-Kopfzeile, klickbar zum Sortieren (seit
/// 2026-09-13) — analog zum Klicksortieren auf `Gtk.ColumnView` in der
/// Linux-App (`widgets/column_list.py` dort: "Ein Klick auf den Kopf
/// sortiert, wenn die Spalte einen Sortierschlüssel mitbringt"). Zeigt bei
/// aktiver Sortierung einen kleinen Pfeil neben dem Spaltentext, auf der
/// Seite, zu der die Zellen selbst ausgerichtet sind (rechtsbündige Spalten
/// wie „Wiedergaben" bekommen den Pfeil links vom Text, sonst rechts).
private struct MusicSortableHeaderLabel: View {
    let title: String
    let isActive: Bool
    let ascending: Bool
    let alignment: Alignment
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 2) {
                if alignment == .trailing, isActive {
                    Image(systemName: ascending ? "chevron.up" : "chevron.down").font(.caption2)
                }
                Text(title)
                if alignment != .trailing, isActive {
                    Image(systemName: ascending ? "chevron.up" : "chevron.down").font(.caption2)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

/// Zeilen-Darstellung eines Albums für die Listenansicht (User-Wunsch 2026-09-11:
/// "Es fehlt noch eine Listenansicht", später ergänzt um Künstler-/Genre-Spalten
/// + Spaltenbreiten) — kompaktes Cover-Thumbnail statt großer Kachel, analog zur
/// Browser-Album-Listenzeile (`.track-row--album`).
/// Kompakte, iOS-only Album-Listenzeile ohne feste Spaltenbreiten (siehe
/// Kommentar bei ihrem Aufrufer in `albumContent`) — Titel/Künstler/Genre
/// stapeln sich statt in eigenen Spalten nebeneinander zu stehen, damit
/// nichts auf schmalen iPhone-Breiten abgeschnitten wird.
private struct MusicAlbumRowCompact: View {
    let album: MusicAlbum
    @EnvironmentObject var client: GoldfishClient

    var body: some View {
        HStack(spacing: 12) {
            PosterImage(url: client.albumCoverURL(albumId: album.id), aspect: 1.0, placeholderSystemImage: "music.note")
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 5))
            VStack(alignment: .leading, spacing: 2) {
                Text(album.displayTitle).lineLimit(1)
                HStack(spacing: 4) {
                    Text(album.artist).foregroundStyle(.secondary).lineLimit(1)
                    if let genre = album.genre, !genre.isEmpty {
                        Text("·").foregroundStyle(.secondary)
                        Text(genre).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .font(.caption)
            }
            Spacer(minLength: 8)
            if let count = album.trackCount {
                Text("\(count)").font(.caption).foregroundStyle(.secondary)
            }
            MusicFavoriteButton(isFavorite: album.favorite ?? false) { newValue in
                try? await client.setAlbumFavorite(albumId: album.id, favorite: newValue)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct MusicAlbumRow: View {
    let album: MusicAlbum
    let albumWidth: Double
    let artistWidth: Double
    let genreWidth: Double
    #if os(macOS)
    var lastPlayedWidth: Double = 130
    var playCountWidth: Double = 90
    var addedWidth: Double = 120
    var visibleColumns: Set<MusicColumn> = []
    #endif
    @EnvironmentObject var client: GoldfishClient

    var body: some View {
        HStack(spacing: 12) {
            PosterImage(url: client.albumCoverURL(albumId: album.id), aspect: 1.0, placeholderSystemImage: "music.note")
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 5))
            Text(album.displayTitle)
                .lineLimit(1)
                .frame(width: albumWidth, alignment: .leading)
            Text(album.artist)
                .lineLimit(1)
                .foregroundStyle(.secondary)
                .frame(width: artistWidth, alignment: .leading)
            Text(album.genre ?? "")
                .lineLimit(1)
                .foregroundStyle(.secondary)
                .frame(width: genreWidth, alignment: .leading)
            #if os(macOS)
            if visibleColumns.contains(.lastPlayed) {
                Text(musicDateLabel(album.lastPlayedAt))
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
                    .frame(width: lastPlayedWidth, alignment: .leading)
            }
            if visibleColumns.contains(.playCount) {
                Text(album.playCount.map { "\($0)" } ?? "—")
                    .foregroundStyle(.secondary)
                    .frame(width: playCountWidth, alignment: .trailing)
            }
            if visibleColumns.contains(.added) {
                Text(musicDateLabel(album.addedAt))
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
                    .frame(width: addedWidth, alignment: .leading)
            }
            #endif
            Text(album.trackCount.map { "\($0)" } ?? "")
                .foregroundStyle(.secondary)
                .frame(width: MusicAlbumColumn.countWidth, alignment: .trailing)
            MusicFavoriteButton(isFavorite: album.favorite ?? false) { newValue in
                try? await client.setAlbumFavorite(albumId: album.id, favorite: newValue)
            }
            .frame(width: 22)
            Spacer(minLength: 0)
        }
    }
}

#if os(macOS)
/// Kopfzeile für "Alle Titel" — identische Spacing-Struktur/Resize-Mechanik
/// wie `MusicAlbumListHeader` (User-Wunsch 2026-09-14: "auf dem Mac ist die
/// Seite Alle Titel optisch völlig anders aufgebaut, wie die Listenansicht
/// der Alben ... Bitte einheitlich aufbauen, so wie die Listenansicht der
/// Alben ist"). Vorher eine Karten-artige Zeile ohne jede Kopfzeile.
private struct MusicTrackListHeader: View {
    @Binding var titleWidth: Double
    @Binding var artistWidth: Double
    @Binding var albumWidth: Double
    @Binding var lastPlayedWidth: Double
    @Binding var playCountWidth: Double
    @Binding var addedWidth: Double
    var visibleColumns: Set<MusicColumn> = []
    // Klick-zum-Sortieren (seit 2026-09-13) — Pendant zu `MusicAlbumListHeader`,
    // eigene @State-Variablen (`MusicLibraryView.TrackSort`), siehe Kommentar
    // dort und bei `TrackSort` selbst.
    @Binding var sortOption: MusicLibraryView.TrackSort
    @Binding var sortAscending: Bool

    private func toggle(_ column: MusicLibraryView.TrackSort) {
        if sortOption == column { sortAscending.toggle() } else { sortOption = column; sortAscending = true }
    }

    var body: some View {
        HStack(spacing: 12) {
            MusicSortableHeaderLabel(title: "Titel", isActive: sortOption == .title, ascending: sortAscending, alignment: .leading) { toggle(.title) }
                .frame(width: titleWidth, alignment: .leading)
                .overlay(alignment: .trailing) {
                    MusicColumnResizeHandle(width: $titleWidth).offset(x: 14)
                }
            MusicSortableHeaderLabel(title: "Künstler", isActive: sortOption == .artist, ascending: sortAscending, alignment: .leading) { toggle(.artist) }
                .frame(width: artistWidth, alignment: .leading)
                .overlay(alignment: .trailing) {
                    MusicColumnResizeHandle(width: $artistWidth).offset(x: 14)
                }
            MusicSortableHeaderLabel(title: "Album", isActive: sortOption == .album, ascending: sortAscending, alignment: .leading) { toggle(.album) }
                .frame(width: albumWidth, alignment: .leading)
                .overlay(alignment: .trailing) {
                    MusicColumnResizeHandle(width: $albumWidth).offset(x: 14)
                }
            if visibleColumns.contains(.lastPlayed) {
                MusicSortableHeaderLabel(title: "Zuletzt gehört", isActive: sortOption == .lastPlayed, ascending: sortAscending, alignment: .leading) { toggle(.lastPlayed) }
                    .frame(width: lastPlayedWidth, alignment: .leading)
                    .overlay(alignment: .trailing) {
                        MusicColumnResizeHandle(width: $lastPlayedWidth).offset(x: 14)
                    }
            }
            if visibleColumns.contains(.playCount) {
                MusicSortableHeaderLabel(title: "Wiedergaben", isActive: sortOption == .playCount, ascending: sortAscending, alignment: .trailing) { toggle(.playCount) }
                    .frame(width: playCountWidth, alignment: .trailing)
                    .overlay(alignment: .trailing) {
                        MusicColumnResizeHandle(width: $playCountWidth).offset(x: 14)
                    }
            }
            if visibleColumns.contains(.added) {
                MusicSortableHeaderLabel(title: "Hinzugefügt", isActive: sortOption == .added, ascending: sortAscending, alignment: .leading) { toggle(.added) }
                    .frame(width: addedWidth, alignment: .leading)
                    .overlay(alignment: .trailing) {
                        MusicColumnResizeHandle(width: $addedWidth).offset(x: 14)
                    }
            }
            MusicSortableHeaderLabel(title: "Dauer", isActive: sortOption == .duration, ascending: sortAscending, alignment: .trailing) { toggle(.duration) }
                .frame(width: MusicAlbumColumn.countWidth, alignment: .trailing)
            Color.clear.frame(width: 22, height: 1) // Favoriten-Spalte
            Color.clear.frame(width: 22, height: 1) // Download-Spalte
            Spacer(minLength: 0)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal)
        .padding(.vertical, 4)
    }
}

/// Zeilen-Darstellung für "Alle Titel" — Pendant zu `MusicAlbumRow`, gleiche
/// Spacing-Struktur, damit Kopf- und Datenzeile bündig fluchten.
private struct MusicTrackListRow: View {
    let track: Item
    let titleWidth: Double
    let artistWidth: Double
    let albumWidth: Double
    var lastPlayedWidth: Double = 130
    var playCountWidth: Double = 90
    var addedWidth: Double = 120
    var visibleColumns: Set<MusicColumn> = []
    let isCurrent: Bool
    let isPlaying: Bool
    @EnvironmentObject var client: GoldfishClient

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Text(track.displayTitle)
                    .lineLimit(1)
                    .fontWeight(isCurrent ? .semibold : .regular)
                if isCurrent && isPlaying {
                    Image(systemName: "speaker.wave.2.fill")
                        .foregroundStyle(Color.accentColor)
                        .font(.caption)
                }
            }
            .frame(width: titleWidth, alignment: .leading)
            Text(track.artist ?? "")
                .lineLimit(1)
                .foregroundStyle(.secondary)
                .frame(width: artistWidth, alignment: .leading)
            Text(track.album ?? "")
                .lineLimit(1)
                .foregroundStyle(.secondary)
                .frame(width: albumWidth, alignment: .leading)
            if visibleColumns.contains(.lastPlayed) {
                Text(musicDateLabel(track.lastPlayedAt))
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
                    .frame(width: lastPlayedWidth, alignment: .leading)
            }
            if visibleColumns.contains(.playCount) {
                Text(track.playCount.map { "\($0)" } ?? "—")
                    .foregroundStyle(.secondary)
                    .frame(width: playCountWidth, alignment: .trailing)
            }
            if visibleColumns.contains(.added) {
                Text(musicDateLabel(track.addedAt))
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
                    .frame(width: addedWidth, alignment: .leading)
            }
            Text(track.durationLabel)
                .foregroundStyle(.secondary)
                .frame(width: MusicAlbumColumn.countWidth, alignment: .trailing)
            MusicFavoriteButton(isFavorite: track.favorite) { newValue in
                try? await client.setFavorite(itemId: track.id, favorite: newValue)
            }
            .frame(width: 22)
            MusicDownloadIcon(item: track)
                .frame(width: 22)
            Spacer(minLength: 0)
        }
    }
}
#endif

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

/// Gemeinsamer Vergleichs-Helfer für die "Aggregat"-Sortierspalten (Datum als
/// ISO-`String?`, Zahl als `Double?`) in `filteredAlbums`/`filteredTracks` —
/// erspart drei fast identische `.sort {}`-Blöcke pro Spalte. Ein fehlender
/// Wert (nil ODER leerer String) landet IMMER ans Ende, unabhängig von der
/// Sortierrichtung (kein sinnvoller "kleinster Wert" für "nie gespielt"/
/// "nie hinzugefügt") — analog zum Browser, wo `musicSortRows`
/// (`music.js`) fehlende Werte über `String(va || "")` genauso ans Ende
/// eines aufsteigenden Textvergleichs schiebt.
enum MusicSortValue {
    case text(String?)
    case number(Double?)
}

func musicOptionalCompare(_ a: MusicSortValue, _ b: MusicSortValue, ascending: Bool) -> Bool {
    switch (a, b) {
    case let (.text(rawA), .text(rawB)):
        let x = (rawA?.isEmpty == false) ? rawA : nil
        let y = (rawB?.isEmpty == false) ? rawB : nil
        switch (x, y) {
        case let (x?, y?): return ascending ? x < y : x > y
        case (nil, nil): return false
        case (.some, nil): return true
        case (nil, .some): return false
        }
    case let (.number(x), .number(y)):
        switch (x, y) {
        case let (x?, y?): return ascending ? x < y : x > y
        case (nil, nil): return false
        case (.some, nil): return true
        case (nil, .some): return false
        }
    default: return false
    }
}
#endif
