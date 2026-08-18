import SwiftUI

/// A poster/thumbnail image guaranteed to occupy exactly `aspect` regardless of the
/// loaded image's real proportions.
///
/// Just chaining `.aspectRatio(_, contentMode: .fit)` on an `AsyncImage` that itself
/// does `.scaledToFill()` looks fine when the source image already matches the target
/// aspect (e.g. a proper 2:3 TMDB poster) — but the two modifiers actively fight once
/// the source is a different aspect (e.g. a 16:9 video-frame thumbnail for an unmatched
/// item): the image renders at its own intrinsic proportions instead of respecting the
/// card's frame, overflowing into neighboring grid cells and throwing off hit-testing
/// (real bug hit 2026-08-17 — private/Bluray libraries with lots of unmatched items).
///
/// Fix: size a `Color.clear` box first (which has no conflicting intrinsic content size),
/// then `.overlay` the image into that already-resolved frame and `.clipped()`.
struct PosterImage: View {
    let url: URL?
    var aspect: CGFloat = 2.0 / 3.0
    var placeholderSystemImage: String = "film"

    var body: some View {
        Color.clear
            .aspectRatio(aspect, contentMode: .fit)
            .overlay {
                if let url {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().scaledToFill()
                        default:
                            placeholder
                        }
                    }
                } else {
                    placeholder
                }
            }
            .clipped()
    }

    private var placeholder: some View {
        Rectangle()
            .fill(.secondary.opacity(0.2))
            .overlay(Image(systemName: placeholderSystemImage).foregroundStyle(.secondary))
    }
}
