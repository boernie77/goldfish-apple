import SwiftUI
import GoldfishCore

struct CastStripView: View {
    let metadataId: Int64?

    @EnvironmentObject var client: GoldfishClient
    @State private var cast: [CastMember] = []
    #if os(tvOS)
    // User-Wunsch 2026-09-08: Pfeile links/rechts sollen mit der tatsächlichen
    // Scroll-Position mitgehen ("links dann das gleiche, wenn man die Leiste
    // bewegt") — auf tvOS läuft das Scrollen der Leiste über den Fokus (Siri
    // Remote bewegt den Fokus, die ScrollView folgt automatisch), daher reicht
    // es, sich zu merken, welche Karte gerade fokussiert ist, statt echten
    // Scroll-Offset zu messen.
    @FocusState private var focusedMemberId: Int64?
    #endif

    #if os(tvOS)
    private let castSpacing: CGFloat = 32
    private let castPhotoSize: CGFloat = 130
    // Fest reservierter Platz an beiden Rändern für die Pfeil-Badges — User-Report
    // 2026-09-08 ("Schauspieler müssen etwas zusammenrücken, damit für die Pfeile
    // Platz ist"): ohne das rendern Karten direkt bis an den Bildschirmrand, der
    // Pfeil (als Overlay AUSSERHALB des scrollenden Inhalts) landet dann zwangsläufig
    // über der letzten Karte statt daneben. Nur reserviert, wenn `hasOverflow` (s. u.)
    // tatsächlich zutrifft — sonst bleibt bei wenig Besetzung kein sinnloser Leerraum.
    private let castEdgeReserve: CGFloat = 64
    // User-Report 2026-09-08: "Namen … immer noch unvollständig" — 150pt reichte bei
    // längeren Namen (z. B. "Arnold Schwarzenegger") trotz größerer Schrift nicht,
    // wurde mit "…" abgeschnitten. Deutlich breiter (220pt, klar mehr als das 130pt-
    // Foto) UND zweizeilig statt einzeilig erzwungen (Name UND Rolle) — deckt auch
    // sehr lange Namen ohne Abschneiden ab, ohne dass die Karte unrealistisch breit
    // werden müsste.
    private let castCardWidth: CGFloat = 220
    private let castNameFont: Font = .body
    private let castRoleFont: Font = .callout
    // User-Report 2026-09-08: ein erster Versuch maß die tatsächliche Inhalts-/
    // Viewport-Breite live per GeometryReader+PreferenceKey — die Content-Messung
    // blieb dabei zuverlässig bei 0 hängen (PreferenceKey-Propagation aus einem
    // `.background` INNERHALB einer horizontalen ScrollView funktioniert dafür nicht
    // wie erwartet, bekannter SwiftUI-Layout-Sonderfall). Die Viewport-Breite ließ
    // sich dabei aber sauber messen (konstant ~1728pt auf dem echten Gerät/Simulator-
    // Screen) — daraus ergibt sich ein verlässlicher, einfacher Schwellenwert statt
    // fragiler Live-Messung: (1728 + Abstand) / (Kartenbreite + Abstand) ≈ 6,9 → 6
    // Karten passen sicher rein, ab der 7. wird gescrollt.
    private var maxVisibleCards: Int { 6 }
    private var hasOverflow: Bool { cast.count > maxVisibleCards }
    // User-Report 2026-09-08 ("Pfeil auf letzter halber Kachel gefällt mir nicht —
    // nur 6 Kacheln anzeigen, dann sitzt der Pfeil immer auf dem Hintergrund"):
    // exakte Breite für GENAU `maxVisibleCards` volle Karten (kein Sliver einer
    // 7. Karte). Wird der ScrollView selbst als `.frame(width:)` mitgegeben (statt
    // nur `maxWidth: .infinity`) — die ScrollView clippt an dieser Breite hart,
    // eine angeschnittene Folgekarte kann dadurch strukturell nie mehr sichtbar
    // werden, unabhängig von der Scroll-/Fokus-Position.
    private var visibleContentWidth: CGFloat {
        CGFloat(maxVisibleCards) * castCardWidth + CGFloat(maxVisibleCards - 1) * castSpacing
    }
    #else
    private let castSpacing: CGFloat = 14
    private let castPhotoSize: CGFloat = 64
    private let castCardWidth: CGFloat = 76
    private let castNameFont: Font = .caption
    private let castRoleFont: Font = .caption2
    #endif

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

                    // User-Report 2026-09-08 (tvOS): "sehr eng zusammen, man kann dort
                    // keinen Namen lesen" — die Mac/iOS-Maße (76pt Kachel, 64pt Foto,
                    // .caption-Schrift) sind auf einem 10-Fuß-Screen viel zu klein/
                    // gedrängt. Eigene, deutlich größere Werte nur für tvOS; die
                    // horizontale Scrollbarkeit (nur diese Leiste, nicht die restliche
                    // Detailseite) gab es bereits vorher — hier nur die Kachelgröße
                    // angepasst, kein struktureller Umbau nötig.
                    #if os(tvOS)
                    // User-Report 2026-09-08 ("Pfeil auf letzter halber Kachel gefällt
                    // mir nicht — nur 6 Kacheln anzeigen, dann sitzt der Pfeil immer auf
                    // dem Hintergrund"): die Pfeil-Slots sind jetzt ECHTE Geschwister
                    // NEBEN der ScrollView (nicht mehr als Overlay/Reserve INNERHALB des
                    // scrollenden Inhalts) — dadurch kann dort strukturell nie eine
                    // (auch nur angeschnittene) Karte landen, unabhängig von der
                    // Scroll-Position. Der Slot bleibt immer gleich breit (Layout
                    // springt beim Erscheinen/Verschwinden des Pfeils nicht), nur das
                    // Icon selbst blendet sich per Opacity ein/aus.
                    HStack(alignment: .top, spacing: 0) {
                        if hasOverflow {
                            castEdgeIndicator(
                                systemImage: "chevron.left",
                                visible: focusedMemberId != nil && focusedMemberId != cast.first?.tmdbId
                            )
                        }
                        castScrollView
                            .frame(width: hasOverflow ? visibleContentWidth : nil, alignment: .leading)
                        if hasOverflow {
                            castEdgeIndicator(
                                systemImage: "chevron.right",
                                visible: focusedMemberId == nil || focusedMemberId != cast.last?.tmdbId
                            )
                        }
                    }
                    .focusSection()
                    #else
                    castScrollView
                    #endif
                }
            }
        }
    }

    // Die eigentliche Besetzungsleiste als eigene Sub-View, da sie sowohl auf tvOS
    // (innerhalb des Pfeil-HStacks) als auch auf den anderen Plattformen (direkt,
    // ohne Pfeile) gebraucht wird.
    private var castScrollView: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: castSpacing) {
                ForEach(cast) { member in
                    castCard(for: member)
                }
            }
        }
    }

    #if os(tvOS)
    // User-Report 2026-09-08 ("komischer Schatten um die Pfeile"): der frühere
    // Verlauf+separater Rechteck-Hintergrund hinter dem Icon erzeugte eine sichtbare
    // harte Kante zwischen beiden. Einfacher, sauberer runder Chip statt Verlauf.
    // `.ultraThinMaterial` war auf dem dunklen Detail-Hintergrund kaum sichtbar —
    // deckendes Schwarz mit Transparenz (wie sonst im Player-Overlay) ist zuverlässig
    // erkennbar. `visible` blendet nur das Icon ein/aus (Opacity) — der Slot selbst
    // bleibt immer gleich breit reserviert, sonst würde die ScrollView bei
    // erscheinendem/verschwindendem Pfeil seitlich hin- und herspringen.
    @ViewBuilder
    private func castEdgeIndicator(systemImage: String, visible: Bool) -> some View {
        Image(systemName: systemImage)
            .font(.title3.weight(.bold))
            .foregroundStyle(.white)
            .frame(width: 44, height: 44)
            .background(Color.black.opacity(0.7), in: Circle())
            .opacity(visible ? 1 : 0)
            .frame(width: castEdgeReserve, height: castPhotoSize)
            .allowsHitTesting(false)
    }
    #endif

    @ViewBuilder
    private func castCard(for member: CastMember) -> some View {
        NavigationLink(value: PersonRef(tmdbId: member.tmdbId, name: member.name)) {
            VStack(spacing: 8) {
                PosterImage(url: tmdbImageURL(member.profilePath, size: "w185"), aspect: 1, placeholderSystemImage: "person.fill")
                    .clipShape(Circle())
                    .frame(width: castPhotoSize, height: castPhotoSize)

                Text(member.name)
                    .font(castNameFont.weight(.medium))
                    .multilineTextAlignment(.center)
                    #if os(tvOS)
                    .lineLimit(2)
                    #else
                    .lineLimit(1)
                    #endif
                    .foregroundStyle(.primary)
                if !member.character.isEmpty {
                    Text(member.character)
                        .font(castRoleFont)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        #if os(tvOS)
                        .lineLimit(2)
                        #else
                        .lineLimit(1)
                        #endif
                }
            }
            .frame(width: castCardWidth)
        }
        .buttonStyle(.plain)
        .focusableCompat(false)
        #if os(tvOS)
        .focused($focusedMemberId, equals: member.tmdbId)
        #endif
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
