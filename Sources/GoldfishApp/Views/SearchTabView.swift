import SwiftUI
import GoldfishCore

#if os(tvOS)
// User-Wunsch 2026-09-08: eigener Tab links von "Start", damit der Suchen-Button per
// Fernbedienung DIREKT von der Tab-Leiste aus mit Links/Rechts erreichbar ist (siehe
// `RootView.swift` `MainTab`-Kommentar — die native tvOS-Tab-Leiste gibt den Fokus bei
// Links/Rechts nicht an benachbarte eigene Views ab, nur ein echter eigener Tab
// funktioniert zuverlässig).
//
// Nachtrag 2026-09-08 (User-Feedback nach dem ersten Rollout): "wir brauchen nirgends
// mehr den kleinen Suchbutton" — der Button in `ItemGridView.tvActionRow` ist entfernt,
// dieser Tab ist jetzt der EINZIGE Sucheinstieg auf tvOS. Zwei weitere Änderungen:
// (1) Kein Button+Sheet-Umweg mehr — ein permanentes `TextField` direkt im Tab, Treffer
// erscheinen sofort darunter, kein Extra-Klick nötig. (2) Scope auf die zuletzt besuchte
// Bibliothek (`LastLibraryContext`) statt immer global über alle Bibliotheken zu suchen.
struct SearchTabView: View {
    @EnvironmentObject var client: GoldfishClient
    @EnvironmentObject var lastLibraryContext: LastLibraryContext
    @Binding var path: NavigationPath

    @State private var search = ""
    @State private var searchResults: [Item] = []
    @State private var isSearching = false
    @FocusState private var searchFieldFocused: Bool
    @FocusState private var focusedSearchResultID: Item.ID?
    // User-Wunsch 2026-09-08: "wenn ich in Filme gesucht habe und wechsle nach Serien …
    // muss das Suchfeld wieder leer sein" — merkt sich, für welche Bibliothek der
    // aktuelle `search`-Text galt. Ändert sich `lastLibraryContext.libraryId` (User hat
    // anderswo eine andere Bibliothek geöffnet), wird die Suche zurückgesetzt — auch
    // wenn der Tab dabei gar nicht sichtbar war (SwiftUI hält die Tab-View im
    // Hintergrund am Leben, ein reines `.onAppear` würde bei jedem Rein-Wechseln nicht
    // zuverlässig genug feuern).
    @State private var searchedLibraryId: Int64?
    // User-Report 2026-09-08 ("bei meiner ersten Suche über die Startseite hat er Bruce
    // Willis nicht gefunden, in Filme dann schon"): Server-seitig geprüft (ListItems,
    // ACL-Klausel) — dort ist die gescopte Suche nachweislich eine Teilmenge der
    // globalen (gleiche Anfrage + Bedingung, nur eingeschränkter library_id-Filter),
    // kann also nie WENIGER liefern. Root Cause war stattdessen eine Race Condition
    // hier: jeder Tastendruck feuerte einen neuen `Task` ohne Sequenz-Sicherung — eine
    // langsamere frühere Anfrage (z. B. nur "B") konnte NACH der eigentlichen
    // "Bruce Willis"-Anfrage zurückkommen und deren korrekte Treffer mit einem leeren/
    // veralteten Zwischenergebnis überschreiben (gleiche Bugklasse wie `state.loadSeq`
    // im Browser, CLAUDE.md "Request-Sequencing"). Fix: Generation-Token, nur die
    // zuletzt gestartete Anfrage darf `searchResults` noch schreiben.
    @State private var searchRequestSeq = 0

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 16) {
                        TextField("Titel oder Schauspieler…", text: $search)
                            .font(.system(size: 34))
                            .tvLoginFieldStyle()
                            .focused($searchFieldFocused)
                        // User-Wunsch 2026-09-08: "die Suche wieder beenden und das
                        // Suchfeld löschen fehlt mir noch" — Klick leert Text + Treffer
                        // in einem Schritt, ohne die Tastatur/den Tab zu verlassen.
                        if !search.isEmpty {
                            Button {
                                search = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .padding(.horizontal)
                    .focusSection()

                    if let libraryName = lastLibraryContext.libraryName {
                        Text("Suche in „\(libraryName)“")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal)
                    }

                    if !search.isEmpty {
                        Text("\(searchResults.count) Treffer")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal)

                        if isSearching && searchResults.isEmpty {
                            ProgressView().padding(.top, 40)
                        } else if searchResults.isEmpty {
                            Text("Keine Treffer für „\(search)“.")
                                .foregroundStyle(.secondary)
                                .padding(.horizontal)
                        } else {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 220), spacing: 48, alignment: .top)], spacing: 48) {
                                ForEach(searchResults) { item in
                                    ItemCard(item: item, width: 220, queue: searchResults)
                                        .frame(width: 220)
                                        .focused($focusedSearchResultID, equals: item.id)
                                }
                            }
                            .padding(.horizontal)
                            .padding(.top, 8)
                            .focusSection()
                        }
                    }
                }
                .padding(.top, 68)
                .padding(.bottom, 16)
            }
            .navigationTitle("")
            .navigationDestination(for: ItemNavTarget.self) { target in
                ItemDetailView(item: target.item, queue: target.queue)
            }
            .onChange(of: search) { _ in
                Task { await loadSearchResults() }
            }
            .onChange(of: lastLibraryContext.libraryId) { newValue in
                guard newValue != searchedLibraryId else { return }
                search = ""
                searchResults = []
                searchedLibraryId = newValue
            }
            // Direkt beim Öffnen des Tabs die Tastatur-Fokussierung anbieten — spart den
            // sonst nötigen ersten Klick, um überhaupt tippen zu können.
            .onAppear {
                searchFieldFocused = true
                if searchedLibraryId == nil { searchedLibraryId = lastLibraryContext.libraryId }
            }
        }
    }

    private func loadSearchResults() async {
        searchRequestSeq += 1
        let mySeq = searchRequestSeq
        guard !search.isEmpty else {
            searchResults = []
            return
        }
        isSearching = true
        defer { if mySeq == searchRequestSeq { isSearching = false } }
        do {
            // Gescopt auf die zuletzt besuchte Bibliothek, falls bekannt — sonst (z. B.
            // direkt nach App-Start ohne vorherigen Bibliotheks-Besuch) global über alle
            // ACL-zugänglichen Bibliotheken, wie bisher.
            let results = try await client.fetchItems(libraryId: lastLibraryContext.libraryId, search: search)
            // Nur übernehmen, wenn währenddessen keine neuere Anfrage gestartet wurde —
            // verhindert, dass eine langsame, veraltete Antwort die aktuellen Treffer
            // überschreibt (siehe Kommentar bei `searchRequestSeq`).
            guard mySeq == searchRequestSeq else { return }
            searchResults = results
        } catch {
            if GoldfishClient.isAuthError(error) {
                client.markSessionInvalid()
                return
            }
            guard mySeq == searchRequestSeq else { return }
            searchResults = []
        }
    }
}
#endif
