import SwiftUI
import GoldfishCore

struct HomeView: View {
    @EnvironmentObject var client: GoldfishClient
    @State private var sections: [HomeSection] = []
    @State private var errorMessage: String?
    @State private var isLoading = true
    @Environment(\.scenePhase) private var scenePhase
    /// User-Anfrage 2026-09-02: `MainTabView` braucht diesen Pfad, um den eigenen
    /// Goldfish-Kopfbereich nur an der Tab-Wurzel zu zeigen (siehe dortiger Kommentar) —
    /// ohne Binding hier hätte `MainTabView` keine Sicht auf die Navigationstiefe.
    @Binding var path: NavigationPath

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if isLoading {
                    ProgressView()
                } else if let errorMessage {
                    VStack(spacing: 16) {
                        ContentUnavailableMessage(text: errorMessage)
                        Button {
                            Task { await load() }
                        } label: {
                            Label("Erneut versuchen", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isLoading)
                    }
                } else if sections.isEmpty {
                    ContentUnavailableMessage(text: "Keine Bibliotheken auf der Startseite sichtbar.")
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            // User-Anfrage 2026-09-02: "Fortsetzen"/"Als nächstes" sollen wie
                            // die Bibliotheks-Überschriften (z.B. "Filme") aussehen — vorher
                            // nutzten sie nur `HomeRow`s eigene kleine, graue Sub-Überschrift
                            // ohne die groß-fette Titelzeile, die jeder Library-Block hat.
                            HomeHeadingRow(title: "▶ Fortsetzen", items: sections.flatMap(\.continueItems))
                            HomeHeadingRow(title: "📺 Als nächstes", items: sections.flatMap(\.nextUp))

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
                        // User-Anfrage 2026-09-02: "Fortsetzen" war direkt unterm eigenen
                        // Goldfish-Header abgeschnitten — die generische `.padding(.vertical)`
                        // reichte als Abstand zur ERSTEN Überschrift nicht (alle Überschriften
                        // darunter, z.B. "Als nächstes", waren normal sichtbar — nur der ganz
                        // oberste Abstand war zu knapp). Expliziter, großzügigerer Top-Wert
                        // statt des generischen Werts.
                        .padding(.top, 68)
                        .padding(.bottom, 16)
                    }
                }
            }
            // User-Anfrage 2026-09-02: "zweites Goldfish unterhalb vom Logo" — der eigene
            // Goldfish-Kopfbereich (Logo+Titel, siehe RootView) UND die native große
            // Navigationsleisten-Titelzeile zeigten an der Tab-Wurzel gleichzeitig
            // "Goldfish". Leer statt doppelt — der Zurück-Pfeil bei gepushten Screens
            // zeigt dann einfach nur den Chevron ohne Textlabel (Standardverhalten).
            .navigationTitle("")
            // Folgefehler (User-Report 2026-09-02): eine LEERE Titelzeile im großen
            // Titel-Modus (Default) klappt auf null Höhe zusammen — dadurch rutschte der
            // Inhalt (allen voran "Fortsetzen") zu weit nach oben, direkt unter/hinter den
            // eigenen Goldfish-Kopfbereich. `.inline` hält die Leiste auf konstanter,
            // kompakter Standardhöhe, unabhängig vom (leeren) Titeltext.
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            // User-Anfrage 2026-09-02: die Home-Kacheln nutzten bisher `NavigationLink
            // (destination:)` (View-basiert) statt wertbasierter Navigation wie
            // `ItemGridView` — ein View-basierter Push aktualisiert den von außen
            // gebundenen `path` NICHT, wodurch `MainTabView`s "bin ich an der Tab-Wurzel"-
            // Erkennung (siehe dortiger Kommentar) einen Push von der Startseite aus nie
            // bemerkte und der Goldfish-Kopfbereich die native Zurück-Leiste weiter
            // verdeckte ("über die Startseite kein Zurück-Pfeil", real reported).
            .navigationDestination(for: ItemNavTarget.self) { target in
                ItemDetailView(item: target.item, queue: target.queue)
            }
            .task { await load() }
            .refreshable { await load() }
            .onChange(of: scenePhase) { phase in
                if phase == .active, !isLoading { Task { await load() } }
            }
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
            // 401 = tote Session, nicht "offline": lokalen Login verwerfen, RootView
            // schwenkt auf LoginView statt "Session abgelaufen" als Sackgasse zu zeigen.
            if GoldfishClient.isAuthError(error) {
                client.markSessionInvalid()
                return
            }
            errorMessage = error.localizedDescription
        }
    }
}

/// Eine Kachel-Reihe MIT groß-fetter Überschrift, im selben Stil wie ein
/// Bibliotheks-Block (Text(section.library.name).font(.title3.bold())) —
/// genutzt für "Fortsetzen"/"Als nächstes", die zuvor nur `HomeRow`s eigene
/// kleine, graue Sub-Überschrift hatten und dadurch kleiner/unwichtiger
/// wirkten als die Bibliotheks-Abschnitte darunter.
private struct HomeHeadingRow: View {
    let title: String
    let items: [Item]

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text(title)
                    .font(.title3.bold())
                    .padding(.horizontal)
                HomeRow(title: nil, items: items)
            }
        }
    }
}

private struct HomeRow: View {
    let title: String?
    let items: [Item]

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                if let title {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                }

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
                            NavigationLink(value: ItemNavTarget(item: item, queue: items)) {
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
