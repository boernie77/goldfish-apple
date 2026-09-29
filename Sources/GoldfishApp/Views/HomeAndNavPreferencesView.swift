import SwiftUI
import GoldfishCore

/// Startseiten-/Bibliotheks-Anpassung — Server-Pendant zum Browser-Dialog "🏠 Startseite
/// anpassen" (CLAUDE.md "Startseite (Home-View)" → "Pro-User-Overrides, DREI unabhängige
/// Achsen"), bis 2026-09-07 nie an die Apple-App nachgezogen (siehe Memory
/// project_todo_apple_home_customization). Alle drei Achsen sind bewusst GETRENNTE
/// Server-Endpoints/Datenmodelle — kein gemeinsames Schema, siehe HomeLibraryPref/
/// NavLibraryPref in Models.swift.
///
/// Reihenfolge über ▲▼-Buttons statt Drag&Drop — genau wie der Browser selbst
/// (`views.js buildLibPrefList()`, kein Drag&Drop dort), und das funktioniert uniform über
/// macOS/iOS/tvOS hinweg ohne die Form/List-onMove-Eigenheiten jeder Plattform einzeln lösen
/// zu müssen.
struct HomeAndNavPreferencesView: View {
    @EnvironmentObject var client: GoldfishClient

    @State private var homeLibraries: [HomeLibraryPref] = []
    @State private var navLibraries: [NavLibraryPref] = []
    @State private var showContinue = true
    @State private var showNextUp = true
    /// Verweildauer der Streifen in Tagen (0 = unbegrenzt), Server ab 1.4.49.
    @State private var continueMaxAgeDays = 0
    @State private var nextUpMaxAgeDays = 0
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        Form {
            if let errorMessage {
                Section {
                    Text(errorMessage).font(.caption).foregroundStyle(.red)
                }
            }

            Section {
                Toggle("▶ Fortsetzen anzeigen", isOn: $showContinue)
                    .onChange(of: showContinue) { new in
                        Task { try? await client.setHomeStrips(showContinue: new) }
                    }
                Toggle("📺 Als nächstes anzeigen", isOn: $showNextUp)
                    .onChange(of: showNextUp) { new in
                        Task { try? await client.setHomeStrips(showNextUp: new) }
                    }
            } header: {
                Text("Startseiten-Streifen")
            } footer: {
                Text("Gilt global, bibliotheksübergreifend — steuert nur, ob die beiden Streifen überhaupt erscheinen.")
            }

            // Verweildauer (Server ab 1.4.49): Bindings mit eigenem `set` statt `.onChange`,
            // damit das Befüllen in `reload()` keinen überflüssigen PUT auslöst. Nur das
            // geänderte Feld wird geschickt.
            Section {
                maxAgePicker("⏳ Fortsetzen bleibt", selection: Binding(
                    get: { continueMaxAgeDays },
                    set: { newValue in
                        continueMaxAgeDays = newValue
                        Task { try? await client.setHomeStripMaxAge(continueDays: newValue) }
                    }
                ))
                maxAgePicker("⏳ Als nächstes bleibt", selection: Binding(
                    get: { nextUpMaxAgeDays },
                    set: { newValue in
                        nextUpMaxAgeDays = newValue
                        Task { try? await client.setHomeStripMaxAge(nextUpDays: newValue) }
                    }
                ))
            } header: {
                Text("Verweildauer")
            } footer: {
                Text("Gerechnet ab dem letzten Abspielen. Ältere Einträge verschwinden nur aus der Ansicht.")
            }

            Section {
                if isLoading {
                    ProgressView()
                } else if homeLibraries.isEmpty {
                    Text("Keine Bibliotheken verfügbar.").foregroundStyle(.secondary)
                } else {
                    ForEach(Array(homeLibraries.enumerated()), id: \.element.id) { index, pref in
                        libraryRow(
                            name: pref.name,
                            isOn: Binding(
                                get: { homeLibraries[index].onHome },
                                set: { newValue in
                                    homeLibraries[index].onHome = newValue
                                    Task { try? await client.setHomePreference(libraryId: pref.libraryId, onHome: newValue) }
                                }
                            ),
                            canMoveUp: index > 0,
                            canMoveDown: index < homeLibraries.count - 1,
                            onMoveUp: { moveHome(index, by: -1) },
                            onMoveDown: { moveHome(index, by: 1) }
                        )
                    }
                }
            } header: {
                Text("Bibliotheken auf der Startseite")
            } footer: {
                Text("Welche Bibliotheken auf der Startseite erscheinen und in welcher Reihenfolge.")
            }

            Section {
                if isLoading {
                    ProgressView()
                } else if navLibraries.isEmpty {
                    Text("Keine Bibliotheken verfügbar.").foregroundStyle(.secondary)
                } else {
                    ForEach(Array(navLibraries.enumerated()), id: \.element.id) { index, pref in
                        libraryRow(
                            name: pref.name,
                            isOn: Binding(
                                get: { navLibraries[index].onNav },
                                set: { newValue in
                                    navLibraries[index].onNav = newValue
                                    Task { try? await client.setNavPreference(libraryId: pref.libraryId, onNav: newValue) }
                                }
                            ),
                            canMoveUp: index > 0,
                            canMoveDown: index < navLibraries.count - 1,
                            onMoveUp: { moveNav(index, by: -1) },
                            onMoveDown: { moveNav(index, by: 1) }
                        )
                    }
                }
            } header: {
                Text("Bibliotheken-Übersicht")
            } footer: {
                Text("Welche Bibliotheken in der Bibliotheken-Übersicht erscheinen und in welcher Reihenfolge.")
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Startseite & Bibliotheken")
        .task { await reload() }
    }

    /// Erlaubte Werte laut Server (`PUT /api/home/strips`) — andere lehnt er ab.
    private static let maxAgeOptions: [(days: Int, label: String)] = [
        (0, "unbegrenzt"), (7, "1 Woche"), (14, "2 Wochen"), (30, "1 Monat"),
        (60, "2 Monate"), (90, "3 Monate"), (180, "6 Monate"), (365, "1 Jahr"),
    ]

    @ViewBuilder
    private func maxAgePicker(_ title: String, selection: Binding<Int>) -> some View {
        Picker(title, selection: selection) {
            ForEach(Self.maxAgeOptions, id: \.days) { option in
                Text(option.label).tag(option.days)
            }
        }
        #if os(tvOS)
        // tvOS: kein `Menu`-basierter Picker (öffnet dort unzuverlässig nichts, siehe
        // AGENTS.md) — `.navigationLink` schiebt eine eigene Auswahlliste auf den Stack.
        .pickerStyle(.navigationLink)
        #else
        .pickerStyle(.menu)
        #endif
    }

    @ViewBuilder
    private func libraryRow(name: String, isOn: Binding<Bool>, canMoveUp: Bool, canMoveDown: Bool, onMoveUp: @escaping () -> Void, onMoveDown: @escaping () -> Void) -> some View {
        HStack {
            Toggle(name, isOn: isOn)
            Spacer(minLength: 12)
            Button { onMoveUp() } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.borderless)
            .disabled(!canMoveUp)
            Button { onMoveDown() } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.borderless)
            .disabled(!canMoveDown)
        }
    }

    private func moveHome(_ index: Int, by delta: Int) {
        let target = index + delta
        guard homeLibraries.indices.contains(target) else { return }
        homeLibraries.swapAt(index, target)
        Task { try? await client.setHomeOrder(ids: homeLibraries.map(\.libraryId)) }
    }

    private func moveNav(_ index: Int, by delta: Int) {
        let target = index + delta
        guard navLibraries.indices.contains(target) else { return }
        navLibraries.swapAt(index, target)
        Task { try? await client.setNavOrder(ids: navLibraries.map(\.libraryId)) }
    }

    private func reload() async {
        isLoading = homeLibraries.isEmpty && navLibraries.isEmpty
        defer { isLoading = false }
        errorMessage = nil
        async let home = client.fetchHomePreferences()
        async let nav = client.fetchNavPreferences()
        do {
            let (homeResult, navResult) = try await (home, nav)
            homeLibraries = homeResult.libraries
            showContinue = homeResult.showContinue
            showNextUp = homeResult.showNextUp
            continueMaxAgeDays = homeResult.continueMaxAgeDays
            nextUpMaxAgeDays = homeResult.nextUpMaxAgeDays
            navLibraries = navResult.libraries
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
