import SwiftUI
import GoldfishCore

/// Genre-Sektion der Suche (Server ab 1.5.12, `/api/items?genreSearch=`): erscheint UNTER den
/// Titeltreffern mit eigener Überschrift, analog zum Browser (`appendSearchResultCards`,
/// cards.js). Titeltreffer sind bereits herausgefiltert (macht der Aufrufer).
struct SearchGenreSectionView: View {
    let items: [Item]
    var libraryKind: String? = nil

    #if os(tvOS)
    private let columns = [GridItem(.adaptive(minimum: 220, maximum: 220), spacing: 48, alignment: .top)]
    #elseif os(iOS)
    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
    #else
    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 150), spacing: 12, alignment: .top)]
    #endif

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("🏷 Genre (\(items.count))")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(items) { item in
                        #if os(tvOS)
                        ItemCard(item: item, width: 220, queue: items, libraryKind: libraryKind)
                            .frame(width: 220)
                        #else
                        ItemCard(item: item, queue: items, libraryKind: libraryKind)
                        #endif
                    }
                }
                #if os(tvOS)
                .focusSection()
                #endif
            }
        }
    }
}
