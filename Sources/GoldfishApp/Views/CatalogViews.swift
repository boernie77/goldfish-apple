import SwiftUI
import GoldfishCore

// Ermittler-Katalog (Server ab 1.4.65, bisher nur Tatort): fehlende Folgen je Kommissar
// aus dem Wikipedia-Katalog des Servers (`GET /api/libraries/{id}/catalog`). Greift nur in
// der erzwungenen Ordner-Ansicht (Ordner-Sammlung bzw. Klick auf die Kommissar-Zeile),
// genau wie `applyCatalogGaps` im Browser (views.js).

/// Ausgegrauter Platzhalter für eine Folge, die in der Bibliothek fehlt. Antippen zeigt die
/// Katalog-Angaben (wie der Klick im Browser). Auf tvOS fokussierbar, damit die Fokus-Engine
/// auch bis zu Platzhaltern am Ende des Rasters scrollen kann.
struct CatalogMissingCard: View {
    let entry: CatalogEntry
    var width: CGFloat = 150

    @State private var showInfo = false
    #if os(tvOS)
    @Environment(\.isFocused) private var isFocused
    #endif

    var body: some View {
        #if os(tvOS)
        VStack(alignment: .leading, spacing: 24) {
            Button {
                showInfo = true
            } label: {
                posterSection
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .buttonBorderShape(.roundedRectangle(radius: 8))

            titleSection
        }
        .contentShape(Rectangle())
        .alert(alertTitle, isPresented: $showInfo) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
        #else
        Button {
            showInfo = true
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                posterSection
                titleSection
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusableCompat(false)
        .alert(alertTitle, isPresented: $showInfo) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
        #endif
    }

    @ViewBuilder
    private var posterSection: some View {
        PosterImage(url: nil, placeholderSystemImage: "tv", fixedWidth: width)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .opacity(0.45)
            .overlay(alignment: .topTrailing) {
                Text("Fehlt")
                    .font(.caption2.bold())
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.orange, in: Capsule())
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
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.title)
                .font(.subheadline.weight(.medium))
                .lineLimit(2)
                .foregroundStyle(.secondary)
            HStack(spacing: 4) {
                Text("Nr. \(entry.nr)").fontWeight(.semibold)
                if let date = entry.dateLabel {
                    Text(date)
                }
            }
            .font(.caption)
            .lineLimit(1)
            .foregroundStyle(.secondary)
            Text("Fehlt")
                .font(.caption2.bold())
                .foregroundStyle(.red)
        }
    }

    private var teamLabel: String { (entry.ermittler ?? []).joined(separator: " / ") }

    private var alertTitle: String { "Nr. \(entry.nr): \(entry.title)" }

    private var alertMessage: String {
        var lines: [String] = []
        var first = entry.sender ?? ""
        if let date = entry.dateLabel {
            first += first.isEmpty ? "Erstausstrahlung \(date)" : " · Erstausstrahlung \(date)"
        }
        if !first.isEmpty { lines.append(first) }
        if !teamLabel.isEmpty { lines.append("Ermittler: \(teamLabel)") }
        lines.append("Fehlt in der Bibliothek.")
        return lines.joined(separator: "\n")
    }
}

/// Kachel eines Ermittler-Teams ohne eigenen Unterordner (Abschnitt „Ermittler ohne eigenen
/// Ordner" in der Serien-Wurzel einer Ordner-Sammlung) → `CatalogTeamView`.
struct CatalogTeamCard: View {
    let group: CatalogGroup
    let library: Library
    let folder: String
    var width: CGFloat = 150

    #if os(tvOS)
    @Environment(\.isFocused) private var isFocused
    #endif

    private var destination: CatalogTeamDestination {
        CatalogTeamDestination(library: library, folder: folder, team: group.team)
    }

    var body: some View {
        #if os(tvOS)
        VStack(alignment: .leading, spacing: 24) {
            NavigationLink(value: destination) {
                posterSection
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .buttonBorderShape(.roundedRectangle(radius: 8))

            titleSection
        }
        .contentShape(Rectangle())
        #else
        NavigationLink(value: destination) {
            VStack(alignment: .leading, spacing: 6) {
                posterSection
                titleSection
            }
            .contentShape(Rectangle())
        }
        .cardButtonStyleCompat()
        .focusableCompat(false)
        #endif
    }

    @ViewBuilder
    private var posterSection: some View {
        PosterImage(url: nil, placeholderSystemImage: "person.2", fixedWidth: width)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .opacity(0.6)
            .overlay(alignment: .bottomTrailing) {
                Text("\(group.owned)/\(group.total) \(group.total == 1 ? "Folge" : "Folgen")")
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
        VStack(alignment: .leading, spacing: 2) {
            Text(group.team)
                .font(.subheadline.weight(.medium))
                .lineLimit(2)
                .foregroundStyle(.primary)
            Text("kein eigener Ordner")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// Alle fehlenden Folgen eines Teams ohne eigenen Ordner
/// (`?folder=<Serie>&team=<Team>`). Vorhandene Folgen liegen verstreut in anderen Ordnern
/// und werden — wie im Browser — hier nicht gelistet, nur der Zähler berücksichtigt sie.
struct CatalogTeamView: View {
    let library: Library
    let folder: String
    let team: String

    @EnvironmentObject var client: GoldfishClient
    @State private var catalog: CatalogResponse?
    @State private var isLoading = true
    @State private var errorMessage: String?

    #if os(tvOS)
    private let cardWidth: CGFloat = 240
    private var columns: [GridItem] { [GridItem(.adaptive(minimum: cardWidth, maximum: cardWidth), spacing: 48, alignment: .top)] }
    private let spacing: CGFloat = 48
    #elseif os(iOS)
    private let cardWidth: CGFloat = 150
    private var columns: [GridItem] { [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)] }
    private let spacing: CGFloat = 16
    #else
    private let cardWidth: CGFloat = 150
    private var columns: [GridItem] { [GridItem(.adaptive(minimum: cardWidth, maximum: cardWidth), spacing: 12, alignment: .top)] }
    private let spacing: CGFloat = 16
    #endif

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
            } else if let errorMessage {
                ContentUnavailableMessage(text: errorMessage)
            } else if let catalog, catalog.available {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("🕵 \(team)")
                                .font(.title2.bold())
                            Text("· \(catalog.owned ?? 0)/\(catalog.total ?? 0) Folgen vorhanden")
                                .font(.title3)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal)

                        let missing = (catalog.missing ?? []).sorted { $0.date < $1.date }
                        if missing.isEmpty {
                            Text("Keine Folge fehlt.")
                                .foregroundStyle(.secondary)
                                .padding(.horizontal)
                        } else {
                            LazyVGrid(columns: columns, spacing: spacing) {
                                ForEach(missing) { entry in
                                    CatalogMissingCard(entry: entry, width: cardWidth)
                                        .frame(width: cardWidth)
                                }
                            }
                            .padding(.horizontal)
                            #if os(tvOS)
                            .padding(.top, 24)
                            .focusSection()
                            #endif
                        }
                    }
                    .padding(.vertical)
                }
            } else {
                ContentUnavailableMessage(text: "Kein Katalog für diesen Ordner.")
            }
        }
        #if os(tvOS)
        .navigationTitle("")
        #else
        .navigationTitle(team)
        #endif
        .task { await load() }
    }

    private func load() async {
        isLoading = catalog == nil
        defer { isLoading = false }
        do {
            catalog = try await client.fetchCatalog(libraryId: library.id, folder: folder, team: team)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
