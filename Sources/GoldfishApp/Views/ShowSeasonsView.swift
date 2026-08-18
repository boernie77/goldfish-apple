import SwiftUI
import GoldfishCore

/// Season/show posters come straight from TMDB (raw `posterPath`, not backed by our own
/// `metadataId`) — same as the web client (`views.js`), which hits image.tmdb.org directly
/// rather than proxying through the server.
func tmdbImageURL(_ path: String?, size: String = "w342") -> URL? {
    guard let path, !path.isEmpty else { return nil }
    return URL(string: "https://image.tmdb.org/t/p/\(size)\(path)")
}

struct ShowSeasonsView: View {
    let library: Library
    let folder: String

    @EnvironmentObject var client: GoldfishClient
    @State private var seasons: SeasonsResponse?
    @State private var errorMessage: String?
    @State private var isLoading = true

    private let cardWidth: CGFloat = 150
    private var columns: [GridItem] { [GridItem(.adaptive(minimum: cardWidth, maximum: cardWidth), spacing: 12)] }

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
            } else if let errorMessage {
                ContentUnavailableMessage(text: errorMessage)
            } else if let seasons {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if let show = seasons.show {
                            ShowHeader(show: show)
                        }

                        LazyVGrid(columns: columns, spacing: 16) {
                            ForEach(seasons.seasons) { season in
                                NavigationLink(value: season) {
                                    SeasonCard(season: season)
                                        .frame(width: cardWidth)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding()
                }
            }
        }
        .navigationTitle(seasons?.show?.title ?? folder.components(separatedBy: "/").last ?? "")
        .navigationDestination(for: SeasonOut.self) { season in
            SeasonEpisodesView(library: library, season: season)
        }
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            seasons = try await client.fetchSeasons(libraryId: library.id, folder: folder)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct ShowHeader: View {
    let show: ShowOut

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            PosterImage(url: tmdbImageURL(show.posterPath), placeholderSystemImage: "tv")
                .frame(width: 140)
                .clipShape(RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 8) {
                Text(show.title ?? "")
                    .font(.title2.bold())
                HStack(spacing: 12) {
                    if let status = show.status { Text(status) }
                    if let seasons = show.numberOfSeasons { Text("\(seasons) Staffeln") }
                    if let episodes = show.numberOfEpisodes { Text("\(episodes) Folgen") }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                if let overview = show.overview, !overview.isEmpty {
                    Text(overview).font(.body)
                }

                if let cast = show.cast, !cast.isEmpty {
                    ShowCastStrip(cast: cast)
                }
            }
        }
    }
}

private struct ShowCastStrip: View {
    let cast: [ShowCastMember]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Besetzung")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(cast) { member in
                        VStack(spacing: 6) {
                            PosterImage(url: tmdbImageURL(member.profilePath, size: "w185"), aspect: 1, placeholderSystemImage: "person.fill")
                                .clipShape(Circle())
                                .frame(width: 64, height: 64)

                            Text(member.name)
                                .font(.caption.weight(.medium))
                                .lineLimit(1)
                            if let character = member.character, !character.isEmpty {
                                Text(character)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .frame(width: 76)
                    }
                }
            }
        }
    }
}

private struct SeasonCard: View {
    let season: SeasonOut
    @EnvironmentObject var client: GoldfishClient

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PosterImage(url: tmdbImageURL(season.posterPath), placeholderSystemImage: "tv")
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .bottomTrailing) {
                    Text("\(season.ownedCount)/\(season.total)")
                        .font(.caption2.bold())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.black.opacity(0.6), in: Capsule())
                        .foregroundStyle(.white)
                        .padding(6)
                }

            Text(season.name ?? "Staffel \(season.seasonNumber)")
                .font(.subheadline.weight(.medium))
                .lineLimit(2)
        }
    }
}

struct SeasonEpisodesView: View {
    let library: Library
    let season: SeasonOut

    @EnvironmentObject var client: GoldfishClient
    @State private var resolvedItem: Item?
    @State private var isResolving = false

    var body: some View {
        List {
            // `.navigationTitle` alone isn't visible on-screen on macOS — an explicit
            // Section header (with the episode count, as requested) covers both.
            Section(header: Text("\(season.name ?? "Staffel \(season.seasonNumber)") (\(season.episodes.count))")
                .font(.title3.bold())
                .foregroundStyle(.primary)
                .textCase(nil)
            ) {
                ForEach(season.episodes) { episode in
                    Button {
                        Task { await openEpisode(episode) }
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text("S\(episode.season)E\(String(format: "%02d", episode.episode)) — \(episode.title ?? "Unbekannt")")
                                    .font(.body)
                                if !episode.owned {
                                    Text("Fehlt")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if episode.watched {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            }
                        }
                    }
                    .disabled(!episode.owned)
                    .foregroundStyle(episode.owned ? .primary : .secondary)
                }
            }
        }
        .navigationTitle(season.name ?? "Staffel \(season.seasonNumber)")
        .pushDestination(item: $resolvedItem) { item in
            ItemDetailView(item: item)
        }
    }

    private func openEpisode(_ episode: EpisodeOut) async {
        guard let itemId = episode.itemId, !isResolving else { return }
        isResolving = true
        defer { isResolving = false }
        resolvedItem = try? await client.fetchItem(id: itemId)
    }
}

private extension View {
    /// SwiftUI's own `navigationDestination(item:)` needs iOS 17/macOS 14; this app targets
    /// iOS 16/macOS 13, so drive the same push manually via a Binding<Item?>.
    @ViewBuilder
    func pushDestination(item: Binding<Item?>, @ViewBuilder destination: @escaping (Item) -> some View) -> some View {
        self.navigationDestination(isPresented: Binding(
            get: { item.wrappedValue != nil },
            set: { if !$0 { item.wrappedValue = nil } }
        )) {
            if let value = item.wrappedValue {
                destination(value)
            }
        }
    }
}
