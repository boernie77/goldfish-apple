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
    @State private var isLoading = true
    @State private var errorMessage: String?
    // User-Anfrage 2026-08-19: "Sortierfeld nicht sichtbar" + "sehe nicht, nach welchem
    // Schauspieler gefiltert wurde" — `.navigationTitle` allein rendert auf macOS keinen
    // sichtbaren Text (nur der Fenstertitel wird gesetzt, gleiche bereits bekannte Falle wie
    // in `ItemGridView`), und diese Ansicht hatte bisher überhaupt keine Sortierung.
    @State private var sort: ItemSort = .title
    @State private var ascending = true

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
                        if !movies.isEmpty {
                            Text("🎬 Filme")
                                .font(.headline)
                                .padding(.horizontal)
                            LazyVGrid(columns: columns, spacing: 16) {
                                ForEach(movies) { item in
                                    NavigationLink(destination: ItemDetailView(item: item, queue: movies)) {
                                        ItemCard(item: item)
                                            .frame(width: cardWidth)
                                    }
                                    .buttonStyle(.plain)
                                    .focusableCompat(false)
                                }
                            }
                            .padding(.horizontal)
                        }
                        if !showGroups.isEmpty {
                            Text("📺 Serien")
                                .font(.headline)
                                .padding(.horizontal)
                            LazyVGrid(columns: columns, spacing: 16) {
                                ForEach(showGroups) { group in
                                    NavigationLink(destination: PersonShowEpisodesView(group: group, personName: personName)) {
                                        PersonShowCard(group: group)
                                            .frame(width: cardWidth)
                                    }
                                    .buttonStyle(.plain)
                                    .focusableCompat(false)
                                }
                            }
                            .padding(.horizontal)
                        }
                    }
                    .padding(.vertical)
                }
            }
        }
        .navigationTitle(personName)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
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
            }
        }
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
        isLoading = false
    }
}

struct PersonShowGroup: Identifiable {
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
                    NavigationLink(destination: ItemDetailView(item: item, queue: group.episodes)) {
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
