import SwiftUI
import GoldfishCore

/// Library-übergreifende Filmografie eines Schauspielers — Gegenstück zum Browser-Klick
/// auf einen Cast-Eintrag (`state.personFilter`, `GET /api/items?personId=<tmdb>`).
///
/// Split wie im Browser (CLAUDE.md "Person-Filter"): Filme als normale Kacheln, Serien als
/// EINE Sammelkachel pro Show statt einer Kachel pro Folge (sonst bei Serien mit vielen
/// Gastauftritten unübersichtlich, User-Anfrage 2026-08-18). Anders als der Browser navigiert
/// ein Klick auf die Show-Kachel hier NICHT zum vollen Serien-Ordner, sondern zu einer Liste,
/// die auf genau die Folgen mit diesem Schauspieler beschränkt bleibt — explizit so gewünscht,
/// weil eine Serie mit 200 Folgen und nur 3 Gastauftritten sonst genauso unübersichtlich wäre.
struct PersonItemsView: View {
    let personTmdbId: Int64
    let personName: String

    @EnvironmentObject var client: GoldfishClient
    @State private var items: [Item] = []
    @State private var personDetails: PersonDetails?
    @State private var isLoading = true
    @State private var errorMessage: String?
    /// „Nur Treffer": blendet die nicht vorhandenen Filmografie-Einträge aus.
    /// Persistiert global (analog Browser `state.personOwnedOnly`).
    @AppStorage("personOwnedOnly") private var ownedOnly = false
    // User-Anfrage 2026-08-19: "Sortierfeld nicht sichtbar" + "sehe nicht, nach welchem
    // Schauspieler gefiltert wurde" — `.navigationTitle` allein rendert auf macOS keinen
    // sichtbaren Text (nur der Fenstertitel wird gesetzt, gleiche bereits bekannte Falle wie
    // in `ItemGridView`), und diese Ansicht hatte bisher überhaupt keine Sortierung.
    @State private var sort: ItemSort = .title
    @State private var ascending = true
    #if os(tvOS)
    @State private var showTVSortSheet = false
    #endif

    private let cardWidth: CGFloat = 150
    private var columns: [GridItem] { [GridItem(.adaptive(minimum: cardWidth, maximum: cardWidth), spacing: 12, alignment: .top)] }

    private var movies: [Item] {
        sortItems(items.filter { $0.metadata?.season == nil })
    }

    private func sortItems(_ list: [Item]) -> [Item] {
        let sorted: [Item]
        switch sort {
        case .title:
            sorted = list.sorted { $0.displayTitle.localizedStandardCompare($1.displayTitle) == .orderedAscending }
        case .released:
            sorted = list.sorted { ($0.metadata?.year ?? 0) < ($1.metadata?.year ?? 0) }
        case .added:
            sorted = list.sorted { ($0.addedAt ?? "") < ($1.addedAt ?? "") }
        case .duration:
            sorted = list.sorted { ($0.durationSec ?? 0) < ($1.durationSec ?? 0) }
        case .rating:
            sorted = list.sorted { ($0.metadata?.rating ?? 0) < ($1.metadata?.rating ?? 0) }
        case .played:
            // `Item` hat kein `lastPlayedAt`-Feld (der Server sortiert `sort=played` selbst
            // serverseitig über `us.last_played_at`, gibt es aber nicht im Item-JSON zurück)
            // — diese Ansicht sortiert clientseitig eine bereits geladene Liste, kann also
            // nicht danach sortieren. Reihenfolge bleibt unverändert, kein Absturz/Crash.
            sorted = list
        case .resolution:
            // Gleiche `max(height, width*9/16)`-Formel wie der Server (`sort=resolution`,
            // `internal/store/sqlite.go`) — hier clientseitig, da `items` schon geladen ist.
            sorted = list.sorted { lhs, rhs in
                let l = lhs.height.map { h in max(Double(h), Double(lhs.width ?? 0) * 9.0 / 16.0) } ?? 0
                let r = rhs.height.map { h in max(Double(h), Double(rhs.width ?? 0) * 9.0 / 16.0) } ?? 0
                return l < r
            }
        case .filename:
            // Letztes Pfadsegment (physischer Dateiname) — gleiche Idee wie der Server-Sort
            // `sort=filename` (NATSORT über i.title), hier vereinfacht per String-Vergleich
            // über das letzte relPath-Segment, da diese Liste bereits vollständig geladen ist.
            sorted = list.sorted {
                let l = ($0.relPath ?? "").components(separatedBy: "/").last ?? ""
                let r = ($1.relPath ?? "").components(separatedBy: "/").last ?? ""
                return l.localizedStandardCompare(r) == .orderedAscending
            }
        }
        return ascending ? sorted : sorted.reversed()
    }

    private var showGroups: [PersonShowGroup] {
        let episodes = items.filter { $0.metadata?.season != nil }
        let grouped = Dictionary(grouping: episodes) { "\($0.libraryId):\(topFolder($0.relPath))" }
        return grouped.values.compactMap { eps -> PersonShowGroup? in
            guard let first = eps.first else { return nil }
            let sorted = eps.sorted {
                let s0 = $0.metadata?.season ?? 0, s1 = $1.metadata?.season ?? 0
                if s0 != s1 { return s0 < s1 }
                return ($0.metadata?.episode ?? 0) < ($1.metadata?.episode ?? 0)
            }
            return PersonShowGroup(
                key: "\(first.libraryId):\(topFolder(first.relPath))",
                folderName: topFolder(first.relPath),
                parentId: first.metadata?.parentId,
                episodes: sorted
            )
        }.sorted { $0.folderName.localizedStandardCompare($1.folderName) == .orderedAscending }
    }

    private func topFolder(_ relPath: String?) -> String {
        guard let relPath else { return "" }
        return relPath.components(separatedBy: "/").first ?? relPath
    }

    /// Vorhandene Filme nach TMDB-ID (erste Variante gewinnt).
    private var ownedMovieByTmdb: [Int64: Item] {
        var m: [Int64: Item] = [:]
        for it in movies {
            guard let tid = it.metadata?.tmdbId else { continue }
            if m[tid] == nil { m[tid] = it }
        }
        return m
    }

    /// Vorhandene Serien-Sammelkacheln nach Show-TMDB-ID (`parentId`).
    private var ownedShowByTmdb: [Int64: PersonShowGroup] {
        var m: [Int64: PersonShowGroup] = [:]
        for g in showGroups {
            guard let pid = g.parentId else { continue }
            if m[pid] == nil { m[pid] = g }
        }
        return m
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
            } else if let errorMessage {
                ContentUnavailableMessage(text: errorMessage)
            } else if items.isEmpty {
                ContentUnavailableMessage(text: "Keine Videos mit \(personName) gefunden.")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        // User-Anfrage 2026-08-19: "wird auch bei einer Schauspielerfilterung
                        // die Trefferanzahl angezeigt" — vorher fehlte hier jede Gesamtzahl,
                        // nur die Serien-Sammelkacheln zeigten ihre Folgenanzahl. Filme +
                        // Episoden zusammengezählt, analog zur "N Treffer"-Anzeige in
                        // `ItemGridView`.
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("🎭 \(personName)")
                                .font(.title2.bold())
                            // Zählt wie im Browser Kacheln, nicht rohe Items: Filme einzeln,
                            // Serien als EINE Sammelkachel — sonst würde eine Serie mit 40
                            // Gastauftritten allein die Zahl dominieren, obwohl nur eine
                            // Kachel dafür zu sehen ist.
                            Text("(\(movies.count + showGroups.count) Treffer)")
                                .font(.title3)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal)

                        if let filmography = personDetails?.filmography, !filmography.isEmpty {
                            filmographySection(filmography)
                        } else {
                            ownedOnlySection
                        }
                    }
                    .padding(.vertical)
                }
            }
        }
        .navigationTitle(personName)
        .navigationDestination(for: ItemNavTarget.self) { target in
            ItemDetailView(item: target.item, queue: target.queue)
        }
        .navigationDestination(for: PersonShowGroup.self) { group in
            PersonShowEpisodesView(group: group, personName: personName)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if let f = personDetails?.filmography, !f.isEmpty {
                    Button {
                        ownedOnly.toggle()
                    } label: {
                        #if os(tvOS)
                        Image(systemName: ownedOnly ? "checkmark.square.fill" : "square")
                        #else
                        Label("Nur Treffer", systemImage: ownedOnly ? "checkmark.square.fill" : "square")
                        #endif
                    }
                }
                // tvOS-Fix 2026-09-03: gleiches `Menu`-in-Toolbar-Problem wie in `ItemGridView`
                // (truncateter Text + unzuverlässiges Öffnen) — dieselbe `TVSortSheet`
                // wiederverwendet statt eine zweite, fast identische Sheet-View zu bauen.
                #if os(tvOS)
                Button {
                    showTVSortSheet = true
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
                #else
                Menu {
                    ForEach(ItemSort.allCases) { option in
                        Button {
                            sort = option
                        } label: {
                            Label(option.label, systemImage: sort == option ? "checkmark" : "")
                        }
                    }
                    Divider()
                    Button {
                        ascending.toggle()
                    } label: {
                        Label(ascending ? "Aufsteigend" : "Absteigend", systemImage: ascending ? "arrow.up" : "arrow.down")
                    }
                } label: {
                    Label("Sortieren", systemImage: "arrow.up.arrow.down")
                }
                #endif
            }
        }
        #if os(tvOS)
        .sheet(isPresented: $showTVSortSheet) {
            TVSortSheet(sort: $sort, ascending: $ascending)
        }
        #endif
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        do {
            items = try await client.fetchItems(personId: personTmdbId)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        personDetails = try? await client.fetchPersonDetails(tmdbId: personTmdbId)
        isLoading = false
    }

    // MARK: - Filmografie (owned + ausgegraut, wie im Browser)

    @ViewBuilder
    private func filmographySection(_ filmography: [PersonCredit]) -> some View {
        let byMovie = ownedMovieByTmdb
        let byShow = ownedShowByTmdb
        Text("🎞 Filmografie · \(filmography.count)")
            .font(.headline)
            .padding(.horizontal)
        LazyVGrid(columns: columns, spacing: 16) {
            ForEach(filmography) { cr in
                if cr.mediaType == "movie", let owned = byMovie[cr.tmdbId] {
                    NavigationLink(value: ItemNavTarget(item: owned, queue: movies)) {
                        ItemCard(item: owned).frame(width: cardWidth)
                    }
                    .buttonStyle(.plain)
                    .focusableCompat(false)
                } else if cr.mediaType == "tv", let owned = byShow[cr.tmdbId] {
                    NavigationLink(value: owned) {
                        PersonShowCard(group: owned).frame(width: cardWidth)
                    }
                    .buttonStyle(.plain)
                    .focusableCompat(false)
                } else if !ownedOnly {
                    PersonMissingCard(credit: cr).frame(width: cardWidth)
                }
            }
            // Vorhandenes, das TMDB nicht in der Filmografie listet, nie verstecken.
            ForEach(leftoverOwnedMovies(filmography)) { item in
                NavigationLink(value: ItemNavTarget(item: item, queue: movies)) {
                    ItemCard(item: item).frame(width: cardWidth)
                }
                .buttonStyle(.plain)
                .focusableCompat(false)
            }
            ForEach(leftoverOwnedShows(filmography)) { group in
                NavigationLink(value: group) {
                    PersonShowCard(group: group).frame(width: cardWidth)
                }
                .buttonStyle(.plain)
                .focusableCompat(false)
            }
        }
        .padding(.horizontal)
    }

    private func leftoverOwnedMovies(_ filmography: [PersonCredit]) -> [Item] {
        let known = Set(filmography.filter { $0.mediaType == "movie" }.map(\.tmdbId))
        return movies.filter { it in
            guard let tid = it.metadata?.tmdbId else { return true }
            return !known.contains(tid)
        }
    }

    private func leftoverOwnedShows(_ filmography: [PersonCredit]) -> [PersonShowGroup] {
        let known = Set(filmography.filter { $0.mediaType == "tv" }.map(\.tmdbId))
        return showGroups.filter { g in
            guard let pid = g.parentId else { return true }
            return !known.contains(pid)
        }
    }

    @ViewBuilder
    private var ownedOnlySection: some View {
        if !movies.isEmpty {
            Text("🎬 Filme").font(.headline).padding(.horizontal)
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(movies) { item in
                    NavigationLink(value: ItemNavTarget(item: item, queue: movies)) {
                        ItemCard(item: item).frame(width: cardWidth)
                    }
                    .buttonStyle(.plain)
                    .focusableCompat(false)
                }
            }
            .padding(.horizontal)
        }
        if !showGroups.isEmpty {
            Text("📺 Serien").font(.headline).padding(.horizontal)
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(showGroups) { group in
                    NavigationLink(value: group) {
                        PersonShowCard(group: group).frame(width: cardWidth)
                    }
                    .buttonStyle(.plain)
                    .focusableCompat(false)
                }
            }
            .padding(.horizontal)
        }
    }
}

/// Ausgegraute Kachel für einen Filmografie-Eintrag, den der Nutzer NICHT besitzt
/// (Poster direkt von TMDB). Gegenstück zu `renderPersonFilmCard` im Browser.
private struct PersonMissingCard: View {
    let credit: PersonCredit

    private var posterURL: URL? {
        guard let p = credit.posterPath, !p.isEmpty else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/w342\(p)")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PosterImage(url: posterURL, placeholderSystemImage: credit.mediaType == "tv" ? "tv" : "film")
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .top) {
                    Text("nicht vorhanden")
                        .font(.caption2.bold())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.black.opacity(0.65), in: Capsule())
                        .foregroundStyle(.white)
                        .padding(6)
                }
            Text(credit.title)
                .font(.subheadline.weight(.medium))
                .lineLimit(2)
            if let y = credit.year, y > 0 {
                Text(String(y)).font(.caption).foregroundStyle(.secondary)
            }
            if let c = credit.character, !c.isEmpty {
                Text(c).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .opacity(0.5)
        .grayscale(0.6)
        .contentShape(Rectangle())
    }
}

struct PersonShowGroup: Identifiable, Hashable {
    let key: String
    let folderName: String
    let parentId: Int64?
    let episodes: [Item]
    var id: String { key }
}

private struct PersonShowCard: View {
    let group: PersonShowGroup
    @EnvironmentObject var client: GoldfishClient

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PosterImage(url: posterURL, placeholderSystemImage: "tv")
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .bottomTrailing) {
                    Text("\(group.episodes.count) Folge\(group.episodes.count == 1 ? "" : "n")")
                        .font(.caption2.bold())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.black.opacity(0.6), in: Capsule())
                        .foregroundStyle(.white)
                        .padding(6)
                }

            Text(group.folderName)
                .font(.subheadline.weight(.medium))
                .lineLimit(2)
                .foregroundStyle(.primary)
        }
        .contentShape(Rectangle())
    }

    private var posterURL: URL? {
        guard let parentId = group.parentId, let url = client.posterURL(metadataId: parentId) else { return nil }
        return url
    }
}

/// Nur die Folgen aus `group.episodes` — keine weitere Server-Anfrage nötig, die Liste steht
/// schon fest, sobald `PersonItemsView` geladen hat.
private struct PersonShowEpisodesView: View {
    let group: PersonShowGroup
    let personName: String

    private let cardWidth: CGFloat = 150
    private var columns: [GridItem] { [GridItem(.adaptive(minimum: cardWidth, maximum: cardWidth), spacing: 12, alignment: .top)] }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(group.episodes) { item in
                    NavigationLink(value: ItemNavTarget(item: item, queue: group.episodes)) {
                        ItemCard(item: item)
                            .frame(width: cardWidth)
                    }
                    .buttonStyle(.plain)
                    .focusableCompat(false)
                }
            }
            .padding()
        }
        .navigationTitle(group.folderName)
    }
}
