import SwiftUI
import GoldfishCore

struct CastStripView: View {
    let metadataId: Int64?

    @EnvironmentObject var client: GoldfishClient
    @State private var cast: [CastMember] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Anchor for `.task` — MUST be an unconditionally-rendered leaf, not a
            // conditional Group/if-else whose content can evaluate to nothing on first
            // render. SwiftUI never mounts a `.task` attached to content that renders
            // empty on the initial pass (which is exactly the state before load() has run
            // once) — a fixed-size empty view has no conditional content, so it's always
            // present and always gets its lifecycle. Cost a long debugging session
            // 2026-08-18, don't "clean this up" back onto the conditional content below.
            Color.clear
                .frame(width: 0, height: 0)
                .task(id: metadataId) { await load() }

            if !cast.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Besetzung")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 14) {
                            ForEach(cast) { member in
                                NavigationLink(value: PersonRef(tmdbId: member.tmdbId, name: member.name)) {
                                    VStack(spacing: 6) {
                                        PosterImage(url: tmdbImageURL(member.profilePath, size: "w185"), aspect: 1, placeholderSystemImage: "person.fill")
                                            .clipShape(Circle())
                                            .frame(width: 64, height: 64)

                                        Text(member.name)
                                            .font(.caption.weight(.medium))
                                            .lineLimit(1)
                                            .foregroundStyle(.primary)
                                        if !member.character.isEmpty {
                                            Text(member.character)
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                    }
                                    .frame(width: 76)
                                }
                                .buttonStyle(.plain)
                                .focusableCompat(false)
                            }
                        }
                    }
                }
            }
        }
    }

    private func load() async {
        guard let metadataId else { return }
        do {
            cast = try await client.fetchCast(metadataId: metadataId)
        } catch {
            cast = []
        }
    }
}
