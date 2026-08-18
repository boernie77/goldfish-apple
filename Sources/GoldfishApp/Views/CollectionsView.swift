import SwiftUI
import GoldfishCore

struct CollectionsView: View {
    @EnvironmentObject var client: GoldfishClient
    @State private var collections: [Collection] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    // User-Anfrage 2026-08-19: "im Sammlungen und Playlist fehlt das Suchfeld" — beide Listen
    // hatten bisher gar keine Suche, rein clientseitig (keine Server-Suche für diese beiden
    // Endpunkte, aber Sammlungen/Playlists sind ohnehin überschaubar viele — kein Roundtrip
    // nötig, matcht einfach gegen die schon geladene Liste).
    @State private var search = ""

    // Fixed (min == max) column width — gleicher Fix wie CollectionDetailView/ItemGridView
    // (echtes Adaptive-Grid kann die Kachelbreite beim ersten Renderpass falsch berechnen).
    private let cardWidth: CGFloat = 190
    private var columns: [GridItem] { [GridItem(.adaptive(minimum: cardWidth, maximum: cardWidth), spacing: 16)] }

    private var filteredCollections: [Collection] {
        guard !search.isEmpty else { return collections }
        return collections.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
            } else if let errorMessage {
                ContentUnavailableMessage(text: errorMessage)
            } else if collections.isEmpty {
                ContentUnavailableMessage(text: "Keine Sammlungen gefunden.")
            } else if filteredCollections.isEmpty {
                ContentUnavailableMessage(text: "Keine Sammlungen gefunden.")
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(filteredCollections) { collection in
                            NavigationLink(destination: CollectionDetailView(collection: collection)) {
                                CollectionCard(collection: collection)
                                    .frame(width: cardWidth)
                            }
                            .buttonStyle(.plain)
                            .focusableCompat(false)
                        }
                    }
                    .padding()
                }
            }
        }
        .navigationTitle("Sammlungen")
        #if os(iOS)
        .searchable(text: $search, prompt: "Suchen")
        #else
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Suchen", text: $search)
                        .textFieldStyle(.plain)
                    if !search.isEmpty {
                        Button {
                            search = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .focusableCompat(false)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                .frame(width: 220)
            }
        }
        #endif
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        isLoading = true
        do {
            collections = try await client.fetchCollections()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

private struct CollectionCard: View {
    let collection: Collection
    @EnvironmentObject var client: GoldfishClient

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PosterImage(url: posterURL, placeholderSystemImage: "square.stack")
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .topLeading) {
                    if collection.isComplete {
                        Text("✓ komplett")
                            .font(.caption2.bold())
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.green, in: Capsule())
                            .foregroundStyle(.white)
                            .padding(6)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    Text(countLabel)
                        .font(.caption2.bold())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.black.opacity(0.6), in: Capsule())
                        .foregroundStyle(.white)
                        .padding(6)
                }

            Text(collection.name)
                .font(.subheadline.weight(.medium))
                .lineLimit(2)
                .foregroundStyle(.primary)
        }
        .contentShape(Rectangle())
    }

    private var countLabel: String {
        if let partCount = collection.partCount, partCount > 0 {
            return "\(collection.movieCount)/\(partCount) Filme"
        }
        return "\(collection.movieCount) Filme"
    }

    private var posterURL: URL? {
        if let url = client.collectionPosterURL(id: collection.id), !collection.posterPath.isNilOrEmpty {
            return url
        }
        if let fallbackId = collection.fallbackMetaId, fallbackId > 0 {
            return client.posterURL(metadataId: fallbackId)
        }
        return nil
    }
}

private extension Optional where Wrapped == String {
    var isNilOrEmpty: Bool { self?.isEmpty ?? true }
}

struct CollectionDetailView: View {
    let collection: Collection

    @EnvironmentObject var client: GoldfishClient
    @State private var parts: [CollectionPart] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var showHidden = false

    // Fixed (min == max) column width statt eines echten Adaptive-Grids — gleicher Fix wie
    // `ItemGridView.cardWidth` (User-Bericht 2026-08-19: erste Kachel einer Sammlung zeigte
    // ein zugeschnitten/gezoomt wirkendes Poster, andere Kacheln daneben normal). Adaptive
    // Grids können auf macOS ihre Breite direkt nach einem NavigationStack-Push falsch
    // berechnen — der erste Renderpass proposed eine falsche/ambige Breite, bevor die echte
    // Grid-Spaltenbreite feststeht, wodurch `PosterImage`s `.aspectRatio(2/3, contentMode:
    // .fit)` sie in eine zu kurze Box zwingt (symmetrischer Crop oben+unten). Eine feste
    // Breite umgeht das komplett, siehe `ItemGridView`s Kommentar zum selben Bug.
    private let cardWidth: CGFloat = 150
    private var columns: [GridItem] { [GridItem(.adaptive(minimum: cardWidth, maximum: cardWidth), spacing: 16)] }

    private var visibleParts: [CollectionPart] {
        showHidden ? parts : parts.filter { !$0.hidden }
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
            } else if let errorMessage {
                ContentUnavailableMessage(text: errorMessage)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        let hiddenCount = parts.filter { $0.hidden }.count
                        if hiddenCount > 0 {
                            Button(showHidden ? "Ausgeblendete verstecken" : "\(hiddenCount) ausgeblendet · alle anzeigen") {
                                showHidden.toggle()
                            }
                            .font(.caption)
                            .padding(.horizontal)
                        }
                        LazyVGrid(columns: columns, spacing: 16) {
                            ForEach(visibleParts) { part in
                                CollectionPartCard(part: part, collectionId: collection.id) {
                                    await load()
                                }
                                .frame(width: cardWidth)
                            }
                        }
                        .padding(.horizontal)
                    }
                    .padding(.vertical)
                }
            }
        }
        .navigationTitle(collection.name)
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        do {
            // User-Anfrage 2026-08-18: innerhalb einer Sammlung (z.B. James Bond) immer
            // chronologisch nach Erscheinungsdatum sortieren — so wie im Browser
            // (CLAUDE.md: "sortiert chronologisch nach Release-Jahr"). Server liefert keine
            // garantierte Reihenfolge, also hier client-seitig sortiert. Teile ohne Datum
            // (noch nicht erschienen/unbekannt) landen ans Ende.
            parts = (try await client.fetchCollectionParts(id: collection.id)).sorted { lhs, rhs in
                switch (lhs.releaseDate, rhs.releaseDate) {
                case let (l?, r?): return l < r
                case (nil, nil): return false
                case (nil, _): return false
                case (_, nil): return true
                }
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

private struct CollectionPartCard: View {
    let part: CollectionPart
    let collectionId: Int64
    let onChange: () async -> Void

    @EnvironmentObject var client: GoldfishClient

    var body: some View {
        Group {
            if let item = part.item {
                // Owned part: reuse the same `ItemCard` every other movie grid uses, so
                // watched/favorite/rating/resolution/duration badges + year all show up
                // exactly like everywhere else — a hand-rolled minimal card here was
                // missing all of that (real bug hit 2026-08-19).
                NavigationLink(destination: ItemDetailView(item: item)) {
                    ItemCard(item: item)
                }
                .buttonStyle(.plain)
                .focusableCompat(false)
            } else {
                missingPartBody
            }
        }
        .opacity(part.hidden ? 0.45 : 1)
        .contextMenu {
            if part.hidden {
                Button("Wieder anzeigen") {
                    Task { try? await client.unhideCollectionPart(collectionId: collectionId, tmdbMovieId: part.tmdbMovieId); await onChange() }
                }
            } else {
                Button("Ausblenden", role: .destructive) {
                    Task { try? await client.hideCollectionPart(collectionId: collectionId, tmdbMovieId: part.tmdbMovieId); await onChange() }
                }
            }
        }
    }

    /// No `Item` exists for these (library doesn't own the file) — only the TMDB-basic
    /// info the server sent along (title/releaseDate/posterPath) is available at all.
    private var missingPartBody: some View {
        VStack(alignment: .leading, spacing: 4) {
            PosterImage(url: posterURL, placeholderSystemImage: "film")
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .topTrailing) {
                    Text("Fehlt")
                        .font(.caption2.bold())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.orange, in: Capsule())
                        .foregroundStyle(.white)
                        .padding(6)
                }
            Text(part.title)
                .font(.subheadline.weight(.medium))
                .lineLimit(2)
                .foregroundStyle(.primary)
            if let year = releaseYear {
                Text(year)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }

    private var releaseYear: String? {
        guard let releaseDate = part.releaseDate, releaseDate.count >= 4 else { return nil }
        return String(releaseDate.prefix(4))
    }

    private var posterURL: URL? {
        guard let posterPath = part.posterPath, !posterPath.isEmpty else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/w342\(posterPath)")
    }
}
