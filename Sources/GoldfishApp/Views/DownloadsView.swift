import SwiftUI
import GoldfishCore

/// User-Anfrage 2026-08-19: Downloads sollen wie eine normale Bibliothek aussehen (Kacheln
/// mit Poster/Titel) und direkt daraus abspielbar sein, statt nur einer schlichten Liste mit
/// Fortschrittsbalken. `DownloadRecord.cachedItem` (JSON-Snapshot vom Download-Zeitpunkt) macht
/// das möglich, ohne dass ein Netzwerk-Request nötig ist — wichtig, weil Downloads gerade FÜR
/// den Offline-Fall existieren.
///
/// User-Anfrage 2026-08-19 (Folgerunde): Folgen derselben Serie/desselben YouTube-Kanals sollen
/// unter EINER Kachel zusammengefasst werden (genau wie in der normalen Bibliotheksansicht),
/// UND es soll eigene Abschnitte für Filme/Serien/YouTube geben, sobald mehrere Arten
/// heruntergeladen sind — vorher lag alles ungruppiert in einem einzigen Grid.
struct DownloadsView: View {
    @EnvironmentObject var downloads: DownloadManager
    @EnvironmentObject var client: GoldfishClient
    // User-Anfrage 2026-08-26: "bei den Downloads auch einen Button, der alle Downloads
    // löscht" — Bestätigungs-Dialog, da destruktiv und nicht rückgängig zu machen.
    @State private var showingDeleteAllConfirm = false
    // User-Anfrage 2026-08-30: zusätzlich "Alle gesehenen löschen" als eigene Auswahl.
    @State private var showingDeleteWatchedConfirm = false
    #if os(tvOS)
    @State private var showTVDeleteMenu = false
    #endif
    /// User-Anfrage 2026-09-02: siehe `HomeView.path` — gleicher Zweck.
    @Binding var path: NavigationPath
    /// User-Anfrage 2026-09-02: "nach Bibliotheken trennen" — `Item` cached nur
    /// `libraryId`, keinen Namen, daher einmalig die Bibliotheksliste laden und
    /// lokal auflösen. Offline/Fehlerfall: `libraryName(for:)` fällt auf einen
    /// generischen Platzhalter zurück statt die ganze Ansicht zu blockieren.
    @State private var libraries: [Library] = []

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 150), spacing: 12, alignment: .top)]

    private var allRecords: [DownloadRecord] {
        downloads.records.values.sorted { $0.title < $1.title }
    }
    private var doneRecords: [DownloadRecord] { allRecords.filter { $0.state == .done } }
    private var inProgressRecords: [DownloadRecord] { allRecords.filter { $0.state == .downloading || $0.state == .queued } }
    private var failedRecords: [DownloadRecord] { allRecords.filter { $0.state == .failed } }

    /// Fertige Downloads mit einem gecachten `Item`-Snapshot — die Kachel-Ansicht. Downloads
    /// von vor diesem Feature (kein `itemData` gespeichert) fallen unten in `plainDoneRecords`.
    private var doneItems: [Item] { doneRecords.compactMap(\.cachedItem) }
    private var plainDoneRecords: [DownloadRecord] { doneRecords.filter { $0.cachedItem == nil } }

    private func libraryName(for id: Int64) -> String {
        libraries.first(where: { $0.id == id })?.name ?? "Bibliothek"
    }

    /// User-Anfrage 2026-09-02: "nach Bibliotheken trennen, so wie in der Mac App" — gab
    /// es zu dem Zeitpunkt auf KEINER der beiden Plattformen im Code (nur Gruppierung nach
    /// Medientyp Filme/Serien/YouTube, library-übergreifend). Jede Bibliothek bekommt jetzt
    /// ihren eigenen Abschnitt (analog `HomeView`s Library-Blöcke), darunter weiterhin die
    /// bekannte Filme/Serien/YouTube-Unterteilung — nur eben pro Bibliothek statt global.
    private var librarySections: [LibraryDownloadSection] {
        let byLibrary = Dictionary(grouping: doneItems, by: \.libraryId)
        return byLibrary.keys
            .sorted { libraryName(for: $0).localizedStandardCompare(libraryName(for: $1)) == .orderedAscending }
            .map { libID in
                let items = byLibrary[libID] ?? []
                let movies = items.filter { !$0.isEpisode && !$0.isPrivateStyle }
                    .sorted { $0.displayTitle.localizedStandardCompare($1.displayTitle) == .orderedAscending }
                let series = DownloadGroup.grouped(items.filter(\.isEpisode), key: { $0.showName }, sortItems: episodeOrder)
                    .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
                let youtube = DownloadGroup.grouped(items.filter(\.isPrivateStyle), key: { $0.channelName }, sortItems: releaseDateOrder)
                    .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
                return LibraryDownloadSection(id: libID, name: libraryName(for: libID), movieItems: movies, seriesGroups: series, youtubeGroups: youtube)
            }
    }

    /// Serien-Folgen: immer nach Staffel/Episoden-Nummer, unabhängig vom Download-Zeitpunkt.
    private func episodeOrder(_ lhs: Item, _ rhs: Item) -> Bool {
        let lhsKey = (lhs.metadata?.season ?? 0, lhs.metadata?.episode ?? 0)
        let rhsKey = (rhs.metadata?.season ?? 0, rhs.metadata?.episode ?? 0)
        return lhsKey < rhsKey
    }

    /// YouTube-Videos innerhalb eines Kanals: nach Erscheinungsdatum aufsteigend — mirrors the
    /// Browser-Default für Privat-Libraries (CLAUDE.md "Default-Sort in privaten Libs ist
    /// 'Veröffentlicht' aufsteigend").
    private func releaseDateOrder(_ lhs: Item, _ rhs: Item) -> Bool {
        (lhs.releasedAt ?? "") < (rhs.releasedAt ?? "")
    }
    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if allRecords.isEmpty {
                    ContentUnavailableMessage(text: "Noch keine Downloads. Öffne ein Video und tippe auf Für offline speichern.")
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 28) {
                            ForEach(librarySections) { section in
                                VStack(alignment: .leading, spacing: 20) {
                                    Text(section.name)
                                        .font(.title3.bold())
                                        .padding(.horizontal)

                                    downloadSection(title: "🎬 Filme", isEmpty: section.movieItems.isEmpty, showTitle: section.showsTypeHeaders) {
                                        LazyVGrid(columns: columns, spacing: 16) {
                                            ForEach(section.movieItems) { item in
                                                itemTile(item, queue: section.movieItems)
                                            }
                                        }
                                    }
                                    downloadSection(title: "📺 Serien", isEmpty: section.seriesGroups.isEmpty, showTitle: section.showsTypeHeaders) {
                                        LazyVGrid(columns: columns, spacing: 16) {
                                            ForEach(section.seriesGroups) { group in
                                                groupTile(group, placeholderSystemImage: "tv")
                                            }
                                        }
                                    }
                                    downloadSection(title: "▶️ YouTube", isEmpty: section.youtubeGroups.isEmpty, showTitle: section.showsTypeHeaders) {
                                        LazyVGrid(columns: columns, spacing: 16) {
                                            ForEach(section.youtubeGroups) { group in
                                                groupTile(group, placeholderSystemImage: "play.rectangle")
                                            }
                                        }
                                    }
                                }
                            }

                            if !plainDoneRecords.isEmpty || !inProgressRecords.isEmpty || !failedRecords.isEmpty {
                                VStack(alignment: .leading, spacing: 8) {
                                    ForEach(plainDoneRecords + inProgressRecords + failedRecords) { record in
                                        DownloadRow(record: record)
                                    }
                                }
                                .padding(.horizontal)
                            }
                        }
                        .padding(.vertical)
                    }
                }
            }
            .navigationTitle("Downloads")
            .navigationDestination(for: ItemNavTarget.self) { target in
                ItemDetailView(item: target.item, queue: target.queue)
            }
            .navigationDestination(for: DownloadGroup.self) { group in
                DownloadGroupDetailView(group: group)
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    // tvOS-Fix 2026-09-03: ein `Menu` als Toolbar-Popover truncatet auf tvOS
                    // nicht nur seinen Label-Text ("Downloa...löschen") — es scheint dort
                    // strukturell unzuverlässig zu öffnen (gleicher Befund wie beim Sortieren-/
                    // Filter-Menu in `ItemGridView`). Bei nur zwei destruktiven Optionen reicht
                    // hier ein `.confirmationDialog` statt eines eigenen Sheets.
                    #if os(tvOS)
                    Button {
                        showTVDeleteMenu = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .disabled(allRecords.isEmpty)
                    #else
                    Menu {
                        Button(role: .destructive) {
                            showingDeleteWatchedConfirm = true
                        } label: {
                            Label("Alle gesehenen löschen", systemImage: "checkmark.circle")
                        }
                        .disabled(downloads.watchedDownloadCount == 0)

                        Button(role: .destructive) {
                            showingDeleteAllConfirm = true
                        } label: {
                            Label("Alle löschen", systemImage: "trash")
                        }
                    } label: {
                        Label("Downloads löschen", systemImage: "trash")
                    }
                    .disabled(allRecords.isEmpty)
                    #endif
                }
            }
            #if os(tvOS)
            .confirmationDialog("Downloads löschen", isPresented: $showTVDeleteMenu) {
                Button("Alle gesehenen löschen", role: .destructive) {
                    showingDeleteWatchedConfirm = true
                }
                .disabled(downloads.watchedDownloadCount == 0)
                Button("Alle löschen", role: .destructive) {
                    showingDeleteAllConfirm = true
                }
                Button("Abbrechen", role: .cancel) {}
            }
            #endif
            .confirmationDialog("Wirklich ALLE \(allRecords.count) Downloads löschen?", isPresented: $showingDeleteAllConfirm, titleVisibility: .visible) {
                Button("Alle \(allRecords.count) Downloads löschen", role: .destructive) {
                    downloads.deleteAllDownloads()
                }
                Button("Abbrechen", role: .cancel) {}
            }
            .confirmationDialog("Alle \(downloads.watchedDownloadCount) gesehenen Downloads löschen?", isPresented: $showingDeleteWatchedConfirm, titleVisibility: .visible) {
                Button("\(downloads.watchedDownloadCount) gesehene Downloads löschen", role: .destructive) {
                    downloads.deleteWatchedDownloads()
                }
                Button("Abbrechen", role: .cancel) {}
            }
            // Real gap hit 2026-08-19: Downloads von VOR dem Kachel-Feature haben kein
            // gecachtes `itemData` und fielen deshalb dauerhaft in die alte Listen-Ansicht —
            // sah für den User aus, als hätte sich "nichts verändert". Holt bei vorhandener
            // Verbindung einmalig die fehlenden Snapshots nach, danach zeigen auch ältere
            // Downloads Kacheln (offline bleibt es weiterhin bei der Listen-Darstellung für
            // diese, kein Fehler, nur kein Nachholen möglich ohne Netz).
            .task {
                // Für die Bibliotheks-Überschriften (siehe `librarySections`) — offline/
                // Fehlerfall bewusst stillschweigend ignoriert, `libraryName(for:)` fällt
                // dann auf einen generischen Platzhalter zurück statt die Ansicht zu blockieren.
                libraries = (try? await client.fetchLibraries()) ?? []
                for record in plainDoneRecords {
                    if let item = try? await client.fetchItem(id: record.itemId) {
                        downloads.backfillItemData(itemId: record.itemId, item: item)
                    }
                }
                // User-Anfrage 2026-08-24: "wenn ich einen Film downloade und ihn dann auf dem
                // Server richtig zuordne, soll der Download beim nächsten Online-Sein korrigiert
                // werden" — gleiches Once-per-Öffnen-Muster wie oben (nur Metadaten, kein
                // erneuter Video-Download), aber für Downloads, die BEREITS einen Snapshot haben
                // (der obige Block deckt nur die ganz ohne `itemData` ab).
                for record in doneRecords where record.cachedItem != nil {
                    if let item = try? await client.fetchItem(id: record.itemId) {
                        downloads.refreshCachedMetadataIfChanged(itemId: record.itemId, item: item)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func downloadSection<Content: View>(title: String, isEmpty: Bool, showTitle: Bool, @ViewBuilder content: () -> Content) -> some View {
        if !isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                if showTitle {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                }
                content()
                    .padding(.horizontal)
            }
        }
    }

    @ViewBuilder
    private func itemTile(_ item: Item, queue: [Item] = []) -> some View {
        NavigationLink(value: ItemNavTarget(item: item, queue: queue)) {
            ItemCard(item: item)
                .frame(width: 150)
        }
        .buttonStyle(.plain)
        .focusableCompat(false)
        .contextMenu {
            Button(role: .destructive) {
                downloads.deleteDownload(itemId: item.id)
            } label: {
                Label("Download löschen", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private func groupTile(_ group: DownloadGroup, placeholderSystemImage: String) -> some View {
        if group.items.count == 1, let only = group.items.first {
            itemTile(only, queue: group.items)
        } else {
            NavigationLink(value: group) {
                DownloadGroupCard(group: group, placeholderSystemImage: placeholderSystemImage)
                    .frame(width: 150)
            }
            .buttonStyle(.plain)
            .focusableCompat(false)
        }
    }
}

/// Ein Bibliotheks-Abschnitt im Downloads-Tab (User-Anfrage 2026-09-02: "nach
/// Bibliotheken trennen"). Innerhalb einer Bibliothek bleibt die bekannte
/// Filme/Serien/YouTube-Unterteilung erhalten.
private struct LibraryDownloadSection: Identifiable {
    let id: Int64
    let name: String
    let movieItems: [Item]
    let seriesGroups: [DownloadGroup]
    let youtubeGroups: [DownloadGroup]

    /// Mehr als eine Art gleichzeitig in dieser Bibliothek heruntergeladen? Dann bekommt
    /// jede ihre eigene kleine Unter-Überschrift — bei nur einer Art wäre das unter der
    /// bereits vorhandenen Bibliotheks-Überschrift unnötiges Rauschen.
    var showsTypeHeaders: Bool {
        [!movieItems.isEmpty, !seriesGroups.isEmpty, !youtubeGroups.isEmpty].filter { $0 }.count > 1
    }
}

/// Mehrere heruntergeladene Episoden/Videos derselben Serie bzw. desselben YouTube-Kanals,
/// zu einer Kachel zusammengefasst (User-Anfrage 2026-08-19) — analog zur normalen
/// Bibliotheksansicht, wo eine Serie ebenfalls eine Kachel ist statt N Einzel-Episoden-Kacheln.
private struct DownloadGroup: Identifiable, Hashable {
    let id: String
    let title: String
    let items: [Item]

    /// Items ohne ermittelbaren Gruppenschlüssel (z. B. `showName == nil`) landen jeweils in
    /// einer eigenen Einzel-Gruppe statt in einem gemeinsamen "Unbekannt"-Topf — verhält sich
    /// dann wie vorher (eine Kachel pro Item). `sortItems` ordnet die Items INNERHALB einer
    /// Gruppe (User-Anfrage 2026-08-19: Episoden immer nach Folgenreihenfolge, YouTube-Videos
    /// nach Erscheinungsdatum — beides unabhängig von der Download-Reihenfolge).
    static func grouped(_ items: [Item], key: (Item) -> String?, sortItems: (Item, Item) -> Bool) -> [DownloadGroup] {
        var order: [String] = []
        var buckets: [String: [Item]] = [:]
        for item in items {
            let bucketKey = key(item) ?? "single-\(item.id)"
            if buckets[bucketKey] == nil { order.append(bucketKey) }
            buckets[bucketKey, default: []].append(item)
        }
        return order.compactMap { bucketKey in
            guard let bucketItems = buckets[bucketKey], let first = bucketItems.first else { return nil }
            return DownloadGroup(id: bucketKey, title: key(first) ?? first.displayTitle, items: bucketItems.sorted(by: sortItems))
        }
    }
}

/// Eine Staffel-Kachel im Downloads-Tab — bewusst am Stil von `ShowSeasonsView.SeasonCard`
/// orientiert (Poster + Folgenanzahl-Badge unten rechts + Titel darunter), nur ohne den
/// Gesehen-Toggle (der gehört zur Server-Staffel-Ansicht, hier reicht Öffnen+Abspielen).
private struct DownloadSeasonCard: View {
    let seasonNumber: Int
    let episodeCount: Int
    let posterURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PosterImage(url: posterURL, placeholderSystemImage: "tv", fixedWidth: 150)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .bottomTrailing) {
                    Text("\(episodeCount) Folge\(episodeCount == 1 ? "" : "n")")
                        .font(.caption2.bold())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.black.opacity(0.6), in: Capsule())
                        .foregroundStyle(.white)
                        .padding(6)
                }
            Text("Staffel \(seasonNumber)")
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
        }
        .contentShape(Rectangle())
    }
}

private struct DownloadGroupCard: View {
    let group: DownloadGroup
    let placeholderSystemImage: String
    @EnvironmentObject var client: GoldfishClient
    @EnvironmentObject var downloads: DownloadManager

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // fixedWidth: siehe PosterImage-Kommentar — verhindert, dass ein auf 2 Zeilen
            // umbrechender Titel darunter die Bildhöhe DIESER Kachel in einem LazyVGrid
            // verzerrt (bestätigter Bug, User-Bericht 2026-08-19).
            PosterImage(url: posterURL, placeholderSystemImage: placeholderSystemImage, fixedWidth: 150)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .bottomTrailing) {
                    Text("\(group.items.count)")
                        .font(.caption2.bold())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.black.opacity(0.6), in: Capsule())
                        .foregroundStyle(.white)
                        .padding(6)
                }
            Text(group.title)
                .font(.subheadline.weight(.medium))
                .lineLimit(2)
                .foregroundStyle(.primary)
        }
        .contentShape(Rectangle())
    }

    private var posterURL: URL? {
        guard let representative = group.items.first else { return nil }
        // Serien-Gruppe: das echte SHOW-Poster laden, nicht das (meist fehlende) Episoden-
        // eigene Poster — `metadata.parentId` ist die Show-Metadata-ID, exakt das gleiche
        // Muster wie `PersonItemsView`s Serien-Sammelkarte.
        //
        // Bugfix 2026-08-20 (User: "bei den Download-Serien wird nicht das Seriencover
        // geladen"): vorher wurde zuerst der (bei Episoden praktisch nie existente)
        // Poster-Cache DER EPISODE SELBST geprüft und danach direkt die NETZWERK-URL für
        // `parentId` — komplett offline blieb die Gruppen-Kachel dadurch ohne Bild, obwohl
        // `DownloadManager.cacheShowPosterIfNeeded` das Show-Cover längst lokal gecacht
        // hatte (`cachedShowPosterURL`), nur wurde diese Cache-Variante hier nie abgefragt.
        // Jetzt: erst das gecachte Show-Poster, dann online, erst danach (Fallback für
        // Nicht-Serien-Gruppen wie YouTube-Kanäle ohne parentId) die episoden-/item-eigene
        // Variante — "nur bei den Folgen nicht" gilt hier automatisch, weil diese
        // Priorisierung ausschließlich in der GRUPPEN-Kachel (`DownloadGroupCard`) greift,
        // nicht in `ItemCard`, das einzelne Episoden in `DownloadGroupDetailView` rendert.
        if let parentId = representative.metadata?.parentId {
            if let cachedShow = downloads.cachedShowPosterURL(parentId: parentId) { return cachedShow }
            if let url = client.posterURL(metadataId: parentId) { return url }
        }
        if let cached = downloads.cachedPosterURL(itemId: representative.id) { return cached }
        if let metadataId = representative.metadataId, let url = client.posterURL(metadataId: metadataId, posterPath: representative.metadata?.posterPath) {
            return url
        }
        return client.thumbURL(itemId: representative.id)
    }
}

/// Wertbasiertes Navigationsziel für eine einzelne Staffel innerhalb einer
/// `DownloadGroupDetailView` — trägt die für diese Staffel bereits gefilterten
/// Episoden mit, damit die Zielansicht ohne weiteren Lookup direkt rendern kann.
private struct DownloadSeasonTarget: Hashable {
    let showTitle: String
    let season: Int
    let items: [Item]
}

/// Geladene Episoden/Videos einer einzelnen Serie/eines Kanals — erreicht über Tap auf
/// eine `DownloadGroupCard`. User-Anfrage 2026-09-02: "wenn man auf das Cover klickt,
/// soll die Staffelübersicht der geladenen Folgen kommen", **als Kacheln, nicht als
/// Text-Überschrift** (erster Entwurf zeigte die Episoden direkt unter einer reinen
/// Text-Überschrift "Staffel N" — User-Feedback: Staffeln sollen wie in der normalen
/// Staffel-Ansicht selbst KACHELN sein, erst ein Klick öffnet die Folgen). Bei Serien
/// (Items mit `metadata.season`) jetzt zwei Navigationsstufen: Staffel-Kacheln → Klick
/// → Folgen dieser Staffel. Nur Staffeln, von denen tatsächlich Folgen geladen wurden —
/// kein "Fehlt"-Platzhalter wie in der normalen Staffel-Ansicht, das würde für
/// Offline-Downloads keinen Sinn ergeben. YouTube-Kanäle & sonstige Gruppen ohne
/// Staffel-Info fallen auf das bisherige flache Episoden-Grid zurück.
private struct DownloadGroupDetailView: View {
    let group: DownloadGroup
    @EnvironmentObject var client: GoldfishClient
    @EnvironmentObject var downloads: DownloadManager

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 150), spacing: 12, alignment: .top)]

    private var seasons: [Int] {
        Set(group.items.compactMap(\.metadata?.season)).sorted()
    }

    private func items(inSeason season: Int) -> [Item] {
        group.items
            .filter { $0.metadata?.season == season }
            .sorted { ($0.metadata?.episode ?? 0) < ($1.metadata?.episode ?? 0) }
    }

    /// Gleiche Priorisierung wie `DownloadGroupCard.posterURL` (Show-Cover statt
    /// Episoden-eigenem Poster) — es gibt keine gecachte Staffel-eigene Poster-Variante
    /// für den Offline-Fall, das Show-Cover ist die beste verfügbare Annäherung.
    private var showPosterURL: URL? {
        guard let representative = group.items.first else { return nil }
        if let parentId = representative.metadata?.parentId {
            if let cachedShow = downloads.cachedShowPosterURL(parentId: parentId) { return cachedShow }
            if let url = client.posterURL(metadataId: parentId) { return url }
        }
        if let cached = downloads.cachedPosterURL(itemId: representative.id) { return cached }
        if let metadataId = representative.metadataId, let url = client.posterURL(metadataId: metadataId, posterPath: representative.metadata?.posterPath) {
            return url
        }
        return client.thumbURL(itemId: representative.id)
    }

    @ViewBuilder
    private func episodeGrid(_ items: [Item]) -> some View {
        LazyVGrid(columns: columns, spacing: 16) {
            ForEach(items) { item in
                NavigationLink(value: ItemNavTarget(item: item, queue: items)) {
                    ItemCard(item: item)
                        .frame(width: 150)
                }
                .buttonStyle(.plain)
                .focusableCompat(false)
                .contextMenu {
                    Button(role: .destructive) {
                        downloads.deleteDownload(itemId: item.id)
                    } label: {
                        Label("Download löschen", systemImage: "trash")
                    }
                }
            }
        }
    }

    var body: some View {
        ScrollView {
            if seasons.isEmpty {
                episodeGrid(group.items)
                    .padding()
            } else {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(seasons, id: \.self) { season in
                        let seasonItems = items(inSeason: season)
                        NavigationLink(value: DownloadSeasonTarget(showTitle: group.title, season: season, items: seasonItems)) {
                            DownloadSeasonCard(seasonNumber: season, episodeCount: seasonItems.count, posterURL: showPosterURL)
                                .frame(width: 150)
                        }
                        .buttonStyle(.plain)
                        .focusableCompat(false)
                    }
                }
                .padding()
            }
        }
        .navigationTitle(group.title)
        .navigationDestination(for: DownloadSeasonTarget.self) { target in
            ScrollView {
                episodeGrid(target.items)
                    .padding()
            }
            .navigationTitle("\(target.showTitle) · Staffel \(target.season)")
        }
    }
}

private struct DownloadRow: View {
    let record: DownloadRecord
    @EnvironmentObject var downloads: DownloadManager
    @EnvironmentObject var client: GoldfishClient

    private static let speedFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useKB, .useMB, .useGB]
        f.countStyle = .binary
        return f
    }()

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(record.title)
                switch record.state {
                case .downloading, .queued:
                    if let prep = downloads.prepProgress[record.itemId] {
                        ProgressView(value: Double(prep), total: 100)
                        Text("Wird vorbereitet … \(prep) %")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ProgressView(value: record.progress)
                        HStack(spacing: 6) {
                            Text("\(Int(record.progress * 100)) %")
                            // User-Anfrage 2026-08-27: "kann man die Downloadgeschwindigkeit
                            // neben der Prozentanzeige anzeigen" — `downloadSpeeds` ist rein
                            // flüchtiger State in `DownloadManager` (siehe dort), existiert
                            // nur während der Download wirklich läuft.
                            if let speed = downloads.downloadSpeeds[record.itemId] {
                                Text("· \(Self.speedFormatter.string(fromByteCount: Int64(speed)))/s")
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                case .done:
                    Text("Fertig heruntergeladen")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .failed:
                    Text(record.errorMessage.map { "Fehlgeschlagen: \($0)" } ?? "Fehlgeschlagen")
                        .font(.caption)
                        .foregroundStyle(.red)
                    // User-Anfrage 2026-08-25: Downloads sollen nach Verbindungsverlust
                    // fortsetzbar sein (`DownloadRecord.resumeData`) — bisher gab es in der
                    // Downloads-Ansicht selbst gar keinen Retry-Weg, nur über den Umweg
                    // "Item-Detailansicht öffnen". `record.resumeData != nil` im Label macht
                    // sichtbar, ob es ein echtes Fortsetzen wird oder ein Neustart.
                    if let item = record.cachedItem {
                        Button(record.resumeData != nil ? "Fortsetzen" : "Erneut versuchen") {
                            if let url = client.downloadFileURL(itemId: item.id) {
                                downloads.startDownload(item: item, from: url)
                            }
                        }
                        .font(.caption)
                    }
                }
            }
            Spacer()
            Button(role: .destructive) {
                downloads.deleteDownload(itemId: record.itemId)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
        }
    }
}
