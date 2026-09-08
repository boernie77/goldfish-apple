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

    // User-Report 2026-09-08 ("Staffelübersicht ist zu klein und zu gedrungen/
    // eng zusammen"): die Mac/iOS-Maße (150pt-Kachel, 12pt-Abstand) sind auf
    // einem 10-Fuß-tvOS-Screen zu klein/gedrängt — gleiches Muster wie schon
    // bei der Besetzungsleiste (CastStripView) und bei ItemCard/HomeRow
    // (dort bereits 220pt/40pt etabliert und bewährt, hier übernommen statt
    // einen dritten eigenen Wert zu erfinden).
    #if os(tvOS)
    private let cardWidth: CGFloat = 220
    private let gridSpacing: CGFloat = 40
    #else
    private let cardWidth: CGFloat = 150
    private let gridSpacing: CGFloat = 12
    #endif
    private var columns: [GridItem] { [GridItem(.adaptive(minimum: cardWidth, maximum: cardWidth), spacing: gridSpacing, alignment: .top)] }

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
            } else if let errorMessage {
                ContentUnavailableMessage(text: errorMessage)
            } else if let seasons, !seasons.seasons.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if let show = seasons.show {
                            ShowHeader(show: show)
                        }

                        LazyVGrid(columns: columns, spacing: gridSpacing) {
                            ForEach(seasons.seasons) { season in
                                #if os(tvOS)
                                // Gleiches Muster wie `ItemCard`/`FolderCard` auf tvOS: der
                                // NavigationLink umschließt NUR das Poster (innerhalb von
                                // `SeasonCard`), nicht die ganze Karte inkl. Titeltext — sonst
                                // wächst der native Fokus-Rahmen mit der Titel-Zeilenzahl mit
                                // ("weißes Fenster"-Bug, siehe dortige Kommentare).
                                SeasonCard(season: season)
                                    .frame(width: cardWidth)
                                #else
                                NavigationLink(value: season) {
                                    SeasonCard(season: season)
                                        .frame(width: cardWidth)
                                }
                                .buttonStyle(.plain)
                                #endif
                            }
                        }
                        #if os(tvOS)
                        // Gegenstück zum `.focusSection()` auf der Besetzungsleiste
                        // oben (`ShowCastStrip`) — eigener Fokus-Bereich für die
                        // Staffel-Grid, damit "hoch" zuverlässig zurück zur
                        // Besetzung findet statt geometrisch zu erraten.
                        .focusSection()
                        #endif
                    }
                    .padding()
                }
            } else {
                // Fallback (User-Report 2026-09-05, "Tatort" mit Kommissar-Unterordnern
                // statt TMDB-Sendejahr-Staffeln): eine leere `seasons`-Liste bedeutete
                // bisher einen stillen leeren Bildschirm — die physische Struktur passt
                // hier schlicht nicht zu TMDB-Staffeln (oder der Ordner ist noch nicht
                // TMDB-zugeordnet). Statt dort hängenzubleiben: normale Ordner-/Dateiliste
                // dieses Ordners zeigen (mit Unterordner-Kacheln, da Show-Root-Ordner i.d.R.
                // sinnvolle Unterstruktur wie Kommissar-Duos haben können) — mirrort den
                // Web-Client-Fix in grid.js (dort zusätzlich per localStorage persistiert,
                // hier reicht der Re-Render, da SwiftUI beim erneuten Öffnen ohnehin neu lädt).
                ItemGridView(library: library, folder: folder, showsFolderTiles: true)
            }
        }
        // User-Report 2026-09-08 ("blasser Text bei jeder Serie") — gleiches
        // Muster wie ItemGridView/DownloadsView/LibrariesView: die native, fixe
        // `.navigationTitle`-Zeile auf tvOS entfernt (der Titel steht bereits
        // im eigenen `ShowHeader`/im Episoden-Zähler-Heading).
        #if os(tvOS)
        .navigationTitle("")
        #else
        .navigationTitle(seasons?.show?.title ?? folder.components(separatedBy: "/").last ?? "")
        #endif
        .navigationDestination(for: SeasonOut.self) { season in
            SeasonEpisodesView(library: library, season: season)
        }
        // Fehlte bisher hier — `ShowCastStrip` (Besetzung) verlinkt seit
        // 2026-09-08 wie `CastStripView` im Item-Detail auf `PersonRef`, aber
        // dessen `.navigationDestination(for: PersonRef.self)` war nur in
        // `ItemDetailView` registriert. `ShowSeasonsView` wird direkt von
        // `ItemGridView` aus gepusht (nicht über `ItemDetailView`), braucht die
        // Registrierung also hier zusätzlich, sonst tut der Klick nichts.
        .navigationDestination(for: PersonRef.self) { ref in
            PersonItemsView(personTmdbId: ref.tmdbId, personName: ref.name)
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
                    // User-Report 2026-09-08 ("zwischen Serienbeschreibung und
                    // Besetzung bitte etwas Abstand") — die umgebende VStack-
                    // Spacing (8pt) reichte nicht als optische Trennung zur
                    // deutlich größeren tvOS-Besetzungsleiste darunter.
                    ShowCastStrip(cast: cast)
                        #if os(tvOS)
                        .padding(.top, 16)
                        #endif
                }
            }
        }
    }
}

private struct ShowCastStrip: View {
    let cast: [ShowCastMember]

    // User-Report 2026-09-08 ("Schauspieler zu nah beieinander"): dieselbe
    // Ursache und derselbe Fix wie bei `CastStripView` (Item-Detail) — die
    // Mac/iOS-Maße (76pt-Kachel, 64pt-Foto, .caption-Schrift) sind auf einem
    // 10-Fuß-Screen zu klein/gedrängt. Bewusst OHNE die dortigen Überlauf-
    // Pfeile: diese Leiste sitzt hier eingerückt neben dem Show-Poster
    // (schmalerer, variabler Container statt der vollen Bildschirmbreite wie
    // im Item-Detail-Dialog) — die dortige "genau 6 Karten"-Rechnung geht von
    // der vollen Bildschirmbreite aus und würde hier falsch/zu breit reserven.
    // Normales horizontales Scrollen reicht, um die Überfüllung zu beheben.
    #if os(tvOS)
    private let castSpacing: CGFloat = 32
    private let castPhotoSize: CGFloat = 130
    private let castCardWidth: CGFloat = 220
    private let castNameFont: Font = .body
    private let castRoleFont: Font = .callout
    #else
    private let castSpacing: CGFloat = 14
    private let castPhotoSize: CGFloat = 64
    private let castCardWidth: CGFloat = 76
    private let castNameFont: Font = .caption
    private let castRoleFont: Font = .caption2
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Besetzung")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: castSpacing) {
                    // User-Report 2026-09-08 ("Schauspieler sind nie anklickbar" +
                    // "springt direkt zur ersten Staffel, Beschreibungstext nicht mehr
                    // sichtbar"): beide Symptome haben dieselbe Ursache. Ohne jedes
                    // fokussierbare Element in der Besetzungsleiste war die erste
                    // Staffel-Kachel darunter das erste fokussierbare Element der ganzen
                    // Seite — tvOS scrollt beim Erscheinen automatisch dorthin, was bei
                    // Shows mit vielen Staffeln (z. B. 9-1-1) den Kopfbereich samt
                    // Beschreibung aus dem sichtbaren Bereich schiebt. Mit klickbaren
                    // Besetzungs-Kacheln (wie bereits in `CastStripView` im Item-Detail)
                    // liegt das erste Fokusziel wieder oben auf der Seite.
                    ForEach(cast) { member in
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
                                if let character = member.character, !character.isEmpty {
                                    Text(character)
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
                    }
                }
            }
            #if os(tvOS)
            // User-Report 2026-09-08 ("komme jetzt zu den Staffeln, aber nicht
            // mehr hoch zur Leiste"): ohne explizite Fokus-Bereichsgrenze
            // versucht der tvOS-Fokus-Motor rein geometrisch zu erraten, wohin
            // "hoch" führt — über die Grenze einer scrollenden horizontalen
            // Leiste hinweg zur Staffel-Grid darunter (und zurück) ist das
            // unzuverlässig. `.focusSection()` macht die Besetzungsleiste zu
            // einem eigenen, klar abgegrenzten Bereich (analog zur Staffel-Grid
            // unten, siehe dort).
            .focusSection()
            #endif
        }
    }
}

private struct SeasonCard: View {
    let season: SeasonOut
    @EnvironmentObject var client: GoldfishClient
    @EnvironmentObject var downloads: DownloadManager
    // User-Anfrage 2026-08-30: "bei Staffeln den gesehen Button haben" — markiert ALLE
    // vorhandenen Folgen der Staffel auf einmal als gesehen/ungesehen. @State für sofortiges
    // UI-Feedback, mirrors EpisodeTile.watched. Startwert: alle vorhandenen Folgen gesehen?
    @State private var watchedAll: Bool
    @State private var busy = false
    #if os(tvOS)
    // Gleiches Fokus-Skalierungs-Muster wie `ItemCard.posterSection` — siehe
    // dortige Kommentar-Historie zum "weißes Fenster"-Fokusrahmen-Bug.
    @Environment(\.isFocused) private var isFocused
    #endif

    init(season: SeasonOut) {
        self.season = season
        _watchedAll = State(initialValue: season.ownedCount > 0 && season.watchedCount >= season.ownedCount)
    }

    var body: some View {
        #if os(tvOS)
        VStack(alignment: .leading, spacing: 16) {
            NavigationLink(value: season) {
                posterSection
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .buttonBorderShape(.roundedRectangle(radius: 8))

            titleSection
        }
        .contentShape(Rectangle())
        #else
        VStack(alignment: .leading, spacing: 6) {
            posterSection
            titleSection
        }
        #endif
    }

    @ViewBuilder
    private var posterSection: some View {
        PosterImage(url: tmdbImageURL(season.posterPath), placeholderSystemImage: "tv")
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .topLeading) {
                if season.ownedCount > 0 {
                    PosterToggleBadge(isOn: watchedAll, onSymbol: "checkmark.circle.fill", offSymbol: "checkmark.circle", tint: .green) {
                        toggleSeasonWatched()
                    }
                    .padding(6)
                    .disabled(busy)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                Text("\(season.ownedCount)/\(season.total)")
                    .font(.caption2.bold())
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.black.opacity(0.6), in: Capsule())
                    .foregroundStyle(.white)
                    .padding(6)
            }
            #if os(tvOS)
            .scaleEffect(isFocused ? 1.08 : 1.0)
            .shadow(color: .black.opacity(isFocused ? 0.5 : 0), radius: 12, y: 6)
            .animation(.easeOut(duration: 0.2), value: isFocused)
            #endif
    }

    @ViewBuilder
    private var titleSection: some View {
        Text(season.name ?? "Staffel \(season.seasonNumber)")
            #if os(tvOS)
            .font(.title3.weight(.semibold))
            #else
            .font(.subheadline.weight(.medium))
            #endif
            .lineLimit(2)
    }

    private func toggleSeasonWatched() {
        let newValue = !watchedAll
        watchedAll = newValue
        busy = true
        Task {
            for episode in season.episodes where episode.owned {
                guard let itemId = episode.itemId else { continue }
                try? await client.setWatched(itemId: itemId, watched: newValue)
                downloads.updateCachedWatched(itemId: itemId, watched: newValue)
            }
            busy = false
        }
    }
}

/// User-Anfrage 2026-08-19: "wenn ich eine Staffel öffne, habe ich eine Listenansicht. Das
/// soll aber auch eine Kachelansicht sein, so wie im Browser" — war bisher eine reine `List`
/// mit Text-Zeilen, während der Browser Episoden-Kacheln mit TMDB-Still-Vorschaubild zeigt.
struct SeasonEpisodesView: View {
    let library: Library
    let season: SeasonOut

    @EnvironmentObject var client: GoldfishClient
    @State private var resolvedItem: Item?
    @State private var isResolving = false

    // User-Report 2026-09-08 ("Folgen in der Staffel sind zu eng und etwas zu
    // klein"): gleiches Muster wie bei der Staffelübersicht/Besetzungsleiste —
    // die Mac/iOS-Maße (220-260pt, 16pt-Abstand) sind auf tvOS zu klein/
    // gedrängt für 16:9-Vorschaubilder auf 10-Fuß-Entfernung.
    #if os(tvOS)
    private let columns = [GridItem(.adaptive(minimum: 340, maximum: 380), spacing: 40, alignment: .top)]
    #else
    private let columns = [GridItem(.adaptive(minimum: 220, maximum: 260), spacing: 16, alignment: .top)]
    #endif

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // `.navigationTitle` alone isn't visible on-screen on macOS — an explicit
                // heading (with the episode count, as requested) covers both.
                Text("\(season.name ?? "Staffel \(season.seasonNumber)") (\(season.episodes.count))")
                    .font(.title3.bold())
                    .padding(.horizontal)

                #if os(tvOS)
                // Gleiches Muster wie `SeasonCard`/`ItemCard` auf tvOS: der
                // fokussierbare Button umschließt NUR das Vorschaubild
                // (innerhalb von `EpisodeTile`), nicht die ganze Kachel inkl.
                // Titeltext — sonst wächst der native Fokus-Rahmen mit der
                // Titel-Zeilenzahl mit.
                LazyVGrid(columns: columns, spacing: 40) {
                    ForEach(season.episodes) { episode in
                        EpisodeTile(episode: episode) {
                            Task { await openEpisode(episode) }
                        }
                        .disabled(!episode.owned || isResolving)
                    }
                }
                .padding(.horizontal)
                .environmentObject(client)
                #else
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(season.episodes) { episode in
                        Button {
                            Task { await openEpisode(episode) }
                        } label: {
                            EpisodeTile(episode: episode)
                        }
                        .buttonStyle(.plain)
                        .focusableCompat(false)
                        .disabled(!episode.owned || isResolving)
                    }
                }
                .padding(.horizontal)
                .environmentObject(client)
                #endif
            }
            .padding(.vertical)
        }
        // User-Report 2026-09-08 ("blasser Text ... in jeder Staffel") — gleiches
        // Muster wie oben in `ShowSeasonsView`: der Titel steht bereits in der
        // eigenen Überschriften-Zeile mit Folgenzähler.
        #if os(tvOS)
        .navigationTitle("")
        #else
        .navigationTitle(season.name ?? "Staffel \(season.seasonNumber)")
        #endif
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

private struct EpisodeTile: View {
    let episode: EpisodeOut
    // Nur auf tvOS gebraucht (siehe body unten) — der Öffnen-Vorgang braucht einen
    // async Fetch (`SeasonEpisodesView.openEpisode`), kann also nicht als simples
    // `NavigationLink(value:)` gebaut werden wie bei `SeasonCard`. Default-Closure
    // hält den Aufruf auf den anderen Plattformen unverändert (dort umschließt
    // weiterhin der Aufrufer selbst einen `Button`, siehe `SeasonEpisodesView.body`).
    var action: () -> Void = {}

    @EnvironmentObject var client: GoldfishClient
    @EnvironmentObject var downloads: DownloadManager
    // User-Anfrage 2026-08-19: "der Gesehen Button fehlt noch bei den Folgen" — vorher nur
    // ein statisches Icon, kein Toggle. @State für sofortiges UI-Feedback, mirrors
    // ItemCard.watched.
    @State private var watched: Bool
    #if os(tvOS)
    // Gleiches Fokus-Skalierungs-Muster wie `ItemCard`/`SeasonCard` — siehe dortige
    // Kommentar-Historie zum "weißes Fenster"-Fokusrahmen-Bug.
    @Environment(\.isFocused) private var isFocused
    #endif

    init(episode: EpisodeOut, action: @escaping () -> Void = {}) {
        self.episode = episode
        self.action = action
        _watched = State(initialValue: episode.watched)
    }

    var body: some View {
        // User-Report 2026-09-08 ("Folgen in der Staffel sind zu eng und etwas zu
        // klein"): auf tvOS umschließt der fokussierbare Button NUR das
        // Vorschaubild (wie bei `SeasonCard`/`ItemCard`), Titel/SxxExx stehen als
        // separates, nicht-fokussierbares Label darunter — sonst wächst der
        // native Fokus-Rahmen mit der Titel-Zeilenzahl mit.
        #if os(tvOS)
        VStack(alignment: .leading, spacing: 12) {
            Button(action: action) {
                stillSection
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .buttonBorderShape(.roundedRectangle(radius: 8))

            titleSection
        }
        .contentShape(Rectangle())
        #else
        VStack(alignment: .leading, spacing: 4) {
            stillSection
            titleSection
        }
        .contentShape(Rectangle())
        #endif
    }

    @ViewBuilder
    private var stillSection: some View {
        PosterImage(url: tmdbImageURL(episode.stillPath, size: "w300"), aspect: 16.0 / 9.0, placeholderSystemImage: "tv")
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .topLeading) {
                if episode.owned {
                    PosterToggleBadge(isOn: watched, onSymbol: "checkmark.circle.fill", offSymbol: "checkmark.circle", tint: .green) {
                        toggleWatched()
                    }
                    .padding(6)
                }
            }
            .overlay(alignment: .bottomLeading) {
                // User-Anfrage 2026-08-19: "bei den Serienfolgen fehlen die
                // Informationen in der Kachel, wie gesehen, Auflösung" — gleiche
                // Position/Optik wie ItemCard's Auflösungs-Badge.
                if !episode.resolutionLabel.isEmpty {
                    Text(episode.resolutionLabel)
                        .font(.caption2.bold())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.black.opacity(0.6), in: Capsule())
                        .foregroundStyle(.white)
                        .padding(6)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if !episode.owned {
                    Text("Fehlt")
                        .font(.caption2.bold())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.black.opacity(0.6), in: Capsule())
                        .foregroundStyle(.white)
                        .padding(6)
                } else if episode.durationSec != nil {
                    Text(episode.durationLabel)
                        .font(.caption2.bold())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.black.opacity(0.6), in: Capsule())
                        .foregroundStyle(.white)
                        .padding(6)
                }
            }
            .opacity(episode.owned ? 1 : 0.5)
            #if os(tvOS)
            .scaleEffect(isFocused ? 1.06 : 1.0)
            .shadow(color: .black.opacity(isFocused ? 0.5 : 0), radius: 12, y: 6)
            .animation(.easeOut(duration: 0.2), value: isFocused)
            #endif
    }

    @ViewBuilder
    private var titleSection: some View {
        Text("S\(episode.season)E\(String(format: "%02d", episode.episode))")
            #if os(tvOS)
            .font(.callout.weight(.semibold))
            #else
            .font(.caption.weight(.semibold))
            #endif
            .foregroundStyle(.secondary)
        Text(episode.title ?? "Unbekannt")
            // User-Report 2026-09-08: `.title3` war zu groß — `.headline` ist
            // noch klar größer als der ursprüngliche `.subheadline`-Wert
            // (Mac/iOS), aber deutlich zurückhaltender als `.title3`.
            #if os(tvOS)
            .font(.headline.weight(.medium))
            #else
            .font(.subheadline.weight(.medium))
            #endif
            .lineLimit(2)
            .foregroundStyle(episode.owned ? .primary : .secondary)
    }

    private func toggleWatched() {
        guard let itemId = episode.itemId else { return }
        let newValue = !watched
        watched = newValue
        Task { try? await client.setWatched(itemId: itemId, watched: newValue) }
        downloads.updateCachedWatched(itemId: itemId, watched: newValue)
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
