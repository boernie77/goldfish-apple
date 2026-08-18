import SwiftUI
import GoldfishCore

struct HomeView: View {
    @EnvironmentObject var client: GoldfishClient
    @State private var sections: [HomeSection] = []
    @State private var errorMessage: String?
    @State private var isLoading = true

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView()
                } else if let errorMessage {
                    ContentUnavailableMessage(text: errorMessage)
                } else if sections.isEmpty {
                    ContentUnavailableMessage(text: "Keine Bibliotheken auf der Startseite sichtbar.")
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            HomeRow(title: "▶ Fortsetzen", items: sections.flatMap(\.continueItems))
                            HomeRow(title: "📺 Als nächstes", items: sections.flatMap(\.nextUp))

                            ForEach(sections) { section in
                                if !section.recent.isEmpty {
                                    VStack(alignment: .leading, spacing: 12) {
                                        Text(section.library.name)
                                            .font(.title3.bold())
                                            .padding(.horizontal)
                                        HomeRow(title: "🆕 Zuletzt hinzugefügt", items: section.recent)
                                    }
                                }
                            }
                        }
                        .padding(.vertical)
                    }
                }
            }
            .navigationTitle("Goldfish")
            .task { await load() }
            .refreshable { await load() }
        }
    }

    private func load() async {
        isLoading = sections.isEmpty
        defer { isLoading = false }
        do {
            let response = try await client.fetchHome()
            sections = response.sections
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct HomeRow: View {
    let title: String
    let items: [Item]

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)

                ScrollView(.horizontal, showsIndicators: false) {
                    // `.top`: real bug hit 2026-08-19 — a Home row mixes movie/TV cards
                    // (2 text lines below the poster) with Privat-Library/YouTube-style
                    // cards (3 lines: title + Kanalname + Datum, added for the channel-name
                    // display feature). A plain HStack centers children vertically by
                    // default, so the taller card's extra line pushed its poster down to
                    // stay centered against the shorter card — looked like the tiles were
                    // randomly shifted. Top alignment keeps every poster's top edge level
                    // regardless of how much text sits underneath.
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(items) { item in
                            NavigationLink(destination: ItemDetailView(item: item, queue: items)) {
                                ItemCard(item: item, width: 130)
                                    .frame(width: 130)
                            }
                            .buttonStyle(.plain)
                            .focusableCompat(false)
                        }
                    }
                    .padding(.horizontal)
                }
            }
        }
    }
}
