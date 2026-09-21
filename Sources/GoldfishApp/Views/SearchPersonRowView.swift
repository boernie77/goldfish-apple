import SwiftUI
import GoldfishCore

/// "Aufgegliederte Trefferanzeige" (Server v1.4.22): a horizontally-scrollable row of
/// actor cards shown ABOVE the normal item results whenever a search term is active and
/// `/api/search/people` returned at least one hit. Mirrors the browser's
/// `appendSearchResultCards`/`renderSearchPersonCard` (internal/webassets/web/cards.js) —
/// same card shape (photo + name + "Schauspieler" label), same position (before movie/show
/// tiles), same tap target (existing person-filter view, `PersonItemsView` via `PersonRef`,
/// the identical navigation `CastStripView.castCard(for:)` already uses).
///
/// Shared across Mac/iOS/tvOS since the search views on each platform already share
/// `PersonRef`/`PersonItemsView`/`tmdbImageURL` — only the card sizing differs (tvOS needs
/// bigger touch/focus targets, same convention as `CastStripView`).
struct SearchPersonRowView: View {
    let people: [SearchPerson]

    #if os(tvOS)
    @FocusState private var focusedPersonId: Int64?
    private let photoSize: CGFloat = 130
    private let cardWidth: CGFloat = 160
    private let nameFont: Font = .body
    #else
    private let photoSize: CGFloat = 64
    private let cardWidth: CGFloat = 84
    private let nameFont: Font = .caption
    #endif

    var body: some View {
        if !people.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                // User-Report 2026-09-20 (Screenshot): "es werden bei Schauspielern
                // leider null Treffer angezeigt, obwohl es zwei Treffer gibt ...
                // es muss pro Kategorie die Anzahl der Treffer geben" — die
                // "Filme"-Überschrift zeigt bereits "(N)", diese Zeile fehlte hier.
                Text("Schauspieler (\(people.count))")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(people) { person in
                            personCard(for: person)
                        }
                    }
                }
                #if os(tvOS)
                .focusSection()
                #endif
            }
        }
    }

    @ViewBuilder
    private func personCard(for person: SearchPerson) -> some View {
        NavigationLink(value: PersonRef(tmdbId: person.tmdbId, name: person.name)) {
            VStack(spacing: 6) {
                PosterImage(
                    url: tmdbImageURL(person.profilePath, size: "w185"),
                    aspect: 1,
                    placeholderSystemImage: "person.fill"
                )
                .clipShape(Circle())
                .frame(width: photoSize, height: photoSize)

                Text(person.name)
                    .font(nameFont.weight(.medium))
                    .lineLimit(1)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.primary)

                // Matches the browser's small "Schauspieler"/"Actor" label under the name.
                Text("Schauspieler")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(width: cardWidth)
        }
        .buttonStyle(.plain)
        .focusableCompat(false)
        #if os(tvOS)
        .focused($focusedPersonId, equals: person.tmdbId)
        #endif
    }
}
