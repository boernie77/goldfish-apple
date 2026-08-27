import SwiftUI
import GoldfishCore

private enum LocalSort: String, CaseIterable, Identifiable {
    case name, date, size, played, resolution, added
    var id: String { rawValue }
    var label: String {
        switch self {
        case .name: return "Name"
        case .date: return "Datum"
        case .size: return "Größe"
        case .played: return "Zuletzt abgespielt"
        case .resolution: return "Auflösung"
        case .added: return "Zuletzt hinzugefügt"
        }
    }
}

private enum LocalWatchedFilter: String, CaseIterable, Identifiable {
    case all, unwatched, watched
    var id: String { rawValue }
    var label: String {
        switch self {
        case .all: return "Alle"
        case .unwatched: return "Nur ungesehen"
        case .watched: return "Nur gesehen"
        }
    }
}

struct LocalLibraryItemsView: View {
    /// Meist genau eine Bibliothek — mehr als eine, wenn der User in den Einstellungen
    /// lokale Bibliotheken "zusammengelegt" hat (`LocalLibraryManager.mergedLibraryIds`);
    /// dann werden die Items aller gemergten Libs flach kombiniert, keine Ordner-Trennung
    /// (gleiche Konvention wie Android's `loadMerged`).
    let libraries: [LocalLibrary]

    init(library: LocalLibrary) {
        self.libraries = [library]
        let key = Self.sortStorageKey(libraryIds: [library.id])
        if let savedRaw = UserDefaults.standard.string(forKey: key), let saved = LocalSort(rawValue: savedRaw) {
            _sort = State(initialValue: saved)
            _ascending = State(initialValue: UserDefaults.standard.object(forKey: key + ".asc") as? Bool ?? true)
        }
    }
    init(libraries: [LocalLibrary]) {
        self.libraries = libraries
        let key = Self.sortStorageKey(libraryIds: Set(libraries.map(\.id)))
        if let savedRaw = UserDefaults.standard.string(forKey: key), let saved = LocalSort(rawValue: savedRaw) {
            _sort = State(initialValue: saved)
            _ascending = State(initialValue: UserDefaults.standard.object(forKey: key + ".asc") as? Bool ?? true)
        }
    }

    // User-Anfrage 2026-08-19/20: "eine Bibliothek soll sich die letzte Sortierung merken" —
    // gleiche Konvention wie `ItemGridView.sortStorageKey`, nur mit den (ggf. mehreren
    // gemergten) UUID-Library-IDs statt einer einzelnen Int64.
    private static func sortStorageKey(libraryIds: Set<UUID>) -> String {
        "goldfish.localSort.\(libraryIds.map(\.uuidString).sorted().joined(separator: ","))"
    }
    private var sortStorageKey: String { Self.sortStorageKey(libraryIds: libraryIds) }

    private var displayName: String {
        if libraries.count >= 2, !localLibrary.mergedLibraryName.isEmpty { return localLibrary.mergedLibraryName }
        return libraries.map(\.name).joined(separator: " + ")
    }
    private var libraryIds: Set<UUID> { Set(libraries.map(\.id)) }

    @EnvironmentObject var localLibrary: LocalLibraryManager
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif
    @State private var playingItem: LocalItem?
    @State private var playFromShuffle = false
    // User-Report 2026-08-23: "werde ich nicht gefragt, ob ich von vorne oder der letzten
    // Stelle schauen möchte" — anders als `ItemDetailView` (Server-Items) sprang dieser
    // Tap-Handler direkt in den Player, las `item.resumePosSec` nur lautlos in
    // `LocalPlayerView.setUp()`. Gleicher Dialog + gleiche State-Namen wie dort.
    @State private var showResumePrompt = false
    @State private var startFromBeginning = false
    @State private var pendingPlayItem: LocalItem?
    @State private var search = ""
    @State private var sort: LocalSort = .name
    @State private var ascending = true
    @State private var watchedFilter: LocalWatchedFilter = .all
    // User-Anfrage 2026-08-25: "als Filter möchte ich in allen Bibliotheken auch nach
    // Auflösung filtern können" — gleicher `ResolutionBucket`-Typ + Multi-Select wie
    // `ItemGridView` (Server-Bibliotheken), hier client-seitig statt per API-Query gefiltert,
    // da lokale Items ohnehin komplett im Speicher sind.
    @State private var selectedBuckets: Set<ResolutionBucket> = []
    // User-Anfrage 2026-08-25: "neben der Anzahl an Dateien auch immer die Gesamtgröße in
    // GB, deaktivierbar im Menü" — gemeinsamer Schalter mit `ItemGridView`
    // (`DisplaySettings.showTotalSizeKey`), ein Toggle gilt für beide Bibliotheks-Arten.
    @AppStorage(DisplaySettings.showTotalSizeKey) private var showTotalSize = true

    private var totalSizeLabel: String {
        let bytes = displayedItems.reduce(Int64(0)) { $0 + $1.sizeBytes }
        return String(format: "%.1f GB", Double(bytes) / 1_000_000_000)
    }

    private let cardWidth: CGFloat = 150
    private var columns: [GridItem] { [GridItem(.adaptive(minimum: cardWidth, maximum: cardWidth), spacing: 12, alignment: .top)] }

    private var isScanning: Bool {
        libraries.contains { localLibrary.scanningLibraryIds.contains($0.id) }
    }

    private var isUnavailable: Bool {
        libraries.contains { localLibrary.unavailableLibraryIds.contains($0.id) }
    }

    // Real bug hit 2026-08-19: this view can represent SEVERAL merged libraries at once
    // (`libraries`, plural — see the doc comment above). `isUnavailable` being a single
    // boolean for the whole view dimmed EVERY item, including ones belonging to a library
    // that's still perfectly reachable, whenever just ONE of the merged libraries (e.g. the
    // one on a removed USB-Stick) went away. Dimming needs to be per-item, keyed by which
    // specific library that item actually belongs to.
    private func isItemUnavailable(_ item: LocalItem) -> Bool {
        localLibrary.unavailableLibraryIds.contains(item.libraryId)
    }

    private var displayedItems: [LocalItem] {
        var result = localLibrary.itemsFor(libraryIds)
        if !search.isEmpty {
            result = result.filter { $0.displayTitle.localizedCaseInsensitiveContains(search) }
        }
        switch watchedFilter {
        case .all: break
        case .unwatched: result = result.filter { !$0.watched }
        case .watched: result = result.filter { $0.watched }
        }
        if !selectedBuckets.isEmpty {
            result = result.filter { item in
                guard let bucket = item.resolutionBucket else { return false }
                return selectedBuckets.contains(bucket)
            }
        }
        switch sort {
        case .name:
            result.sort { $0.displayTitle.localizedStandardCompare($1.displayTitle) == (ascending ? .orderedAscending : .orderedDescending) }
        case .date:
            result.sort { ascending ? $0.modifiedTime < $1.modifiedTime : $0.modifiedTime > $1.modifiedTime }
        case .size:
            result.sort { ascending ? $0.sizeBytes < $1.sizeBytes : $0.sizeBytes > $1.sizeBytes }
        case .played:
            // Nie abgespielte Items (lastPlayedAt == nil) fallen ans Ende, unabhängig von
            // der Richtung — ein "nie gesehen"-Item hat schlicht keine sinnvolle Position
            // in einer Zeitleiste.
            result.sort { lhs, rhs in
                switch (lhs.lastPlayedAt, rhs.lastPlayedAt) {
                case (nil, nil): return false
                case (nil, _): return false
                case (_, nil): return true
                case let (l?, r?): return ascending ? l < r : l > r
                }
            }
        case .resolution:
            // Gleiches Nil-Handling wie `.played` — Items ohne (noch nicht geprobte)
            // Auflösung fallen ans Ende, unabhängig von der Richtung.
            result.sort { lhs, rhs in
                switch (lhs.effectiveResolution, rhs.effectiveResolution) {
                case (nil, nil): return false
                case (nil, _): return false
                case (_, nil): return true
                case let (l?, r?): return ascending ? l < r : l > r
                }
            }
        case .added:
            // User-Anfrage 2026-08-27: "der Filter bei externen Bibliotheken 'zuletzt
            // Hinzugefügt' fehlt mir noch" — analog zum Server-Sort `added`
            // (`items.added_at`). Alt-Items ohne `addedAt` (vor diesem Feature gescannt)
            // fallen auf `modifiedTime` zurück statt ans Ende zu rutschen — für Bestandsdateien
            // ist "wann zuletzt verändert" die beste verfügbare Näherung an "wann hinzugefügt".
            result.sort { lhs, rhs in
                let l = lhs.addedAt ?? lhs.modifiedTime
                let r = rhs.addedAt ?? rhs.modifiedTime
                return ascending ? l < r : l > r
            }
        }
        return result
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(displayName)
                        .font(.title2.bold())
                    Text(showTotalSize ? "(\(displayedItems.count) · \(totalSizeLabel))" : "(\(displayedItems.count))")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)

                if isScanning {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Scanne Ordner …")
                    }
                    .padding(.horizontal)
                }

                if isUnavailable {
                    Label("Datenträger nicht verbunden — Videos werden verblasst angezeigt, bis er wieder eingesteckt ist.", systemImage: "externaldrive.badge.xmark")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .padding(.horizontal)
                }

                let items = displayedItems
                if items.isEmpty && !isScanning {
                    ContentUnavailableMessage(text: "Keine Videos in diesem Ordner gefunden.")
                        .padding(.horizontal)
                } else {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(items) { item in
                            Button {
                                playFromShuffle = false
                                startPlayback(item)
                            } label: {
                                LocalItemCard(item: item)
                                    .frame(width: cardWidth)
                                    .opacity(isItemUnavailable(item) ? 0.5 : 1)
                            }
                            .buttonStyle(.plain)
                            .focusableCompat(false)
                            .disabled(isItemUnavailable(item))
                            .contextMenu {
                                Button(item.watched ? "Als ungesehen markieren" : "Als gesehen markieren") {
                                    localLibrary.setWatched(item, watched: !item.watched)
                                }
                                Button("Löschen", role: .destructive) {
                                    localLibrary.deleteItem(item)
                                }
                            }
                        }
                    }
                    .padding(.horizontal)
                }
            }
            .padding(.vertical)
        }
        .navigationTitle(displayName)
        #if os(iOS)
        .searchable(text: $search, prompt: "Suchen")
        #endif
        .toolbar {
            #if os(macOS)
            // Same custom TextField pattern as `ItemGridView` — `.searchable()` on macOS
            // triggers the AppKit password-autofill key-view-loop hang, see that file's
            // comment for the full story.
            ToolbarItem(placement: .principal) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Suchen", text: $search)
                        .textFieldStyle(.plain)
                    if !search.isEmpty {
                        Button {
                            search = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .focusableCompat(false)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                .frame(width: 220)
            }
            #endif
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    playFromShuffle = true
                    startFromBeginning = false
                    playingItem = displayedItems.randomElement()
                } label: {
                    Label("Zufällig", systemImage: "shuffle")
                }
                .disabled(displayedItems.isEmpty)

                Menu {
                    // Flache Buttons statt `Picker` — ein `Picker` in einer `Menu` rendert als
                    // native AppKit-Submenu (eigenes Panel, eigener Disclosure-Chevron), siehe
                    // dieselbe Erklärung + denselben Fix in `ItemGridView`. Angeglichen, damit
                    // Online- und lokale Bibliotheken optisch identisch aussehen.
                    ForEach(LocalSort.allCases) { option in
                        Button {
                            sort = option
                        } label: {
                            Label(option.label, systemImage: sort == option ? "checkmark" : "")
                        }
                    }
                    Divider()
                    Button {
                        ascending.toggle()
                    } label: {
                        Label(ascending ? "Aufsteigend" : "Absteigend", systemImage: ascending ? "arrow.up" : "arrow.down")
                    }
                } label: {
                    Label("Sortieren", systemImage: "arrow.up.arrow.down")
                }

                Menu {
                    ForEach(LocalWatchedFilter.allCases) { option in
                        Button {
                            watchedFilter = option
                        } label: {
                            Label(option.label, systemImage: watchedFilter == option ? "checkmark" : "")
                        }
                    }
                    Divider()
                    ForEach(ResolutionBucket.allCases) { bucket in
                        Button {
                            if selectedBuckets.contains(bucket) {
                                selectedBuckets.remove(bucket)
                            } else {
                                selectedBuckets.insert(bucket)
                            }
                        } label: {
                            Label(bucket.label, systemImage: selectedBuckets.contains(bucket) ? "checkmark" : "")
                        }
                    }
                    Divider()
                    Button {
                        showTotalSize.toggle()
                    } label: {
                        Label("Gesamtgröße anzeigen", systemImage: showTotalSize ? "checkmark" : "")
                    }
                } label: {
                    Label("Filter", systemImage: (watchedFilter != .all || !selectedBuckets.isEmpty) ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                }

                Button {
                    for lib in libraries { Task { await localLibrary.scan(lib) } }
                } label: {
                    Label("Neu einlesen", systemImage: "arrow.clockwise")
                }
                .disabled(isScanning)
            }
        }
        .onChange(of: sort) { newValue in
            UserDefaults.standard.set(newValue.rawValue, forKey: sortStorageKey)
        }
        .onChange(of: ascending) { newValue in
            UserDefaults.standard.set(newValue, forKey: sortStorageKey + ".asc")
        }
        .confirmationDialog("Wiedergabe fortsetzen?", isPresented: $showResumePrompt, titleVisibility: .visible) {
            Button("Von letzter Stelle fortsetzen") {
                startFromBeginning = false
                confirmPlayback()
            }
            Button("Von Anfang abspielen") {
                startFromBeginning = true
                confirmPlayback()
            }
            Button("Abbrechen", role: .cancel) { pendingPlayItem = nil }
        }
        #if os(macOS)
        .onChange(of: playingItem) { newValue in
            guard let newValue else { return }
            PlayerLaunchCoordinator.shared.present(LocalPlayerLaunchRequest(
                item: newValue,
                queue: playFromShuffle ? [] : displayedItems,
                randomPool: playFromShuffle ? displayedItems : nil,
                startFromBeginning: startFromBeginning
            ), openWindow: openWindow)
            playingItem = nil
        }
        #else
        .fullScreenCoverCompat(isPresented: Binding(get: { playingItem != nil }, set: { if !$0 { playingItem = nil } })) {
            if let playingItem {
                if playFromShuffle {
                    LocalPlayerView(item: playingItem, randomPool: displayedItems, startFromBeginning: startFromBeginning)
                } else {
                    LocalPlayerView(item: playingItem, queue: displayedItems, startFromBeginning: startFromBeginning)
                }
            }
        }
        #endif
    }

    /// Skips the dialog for items with no meaningful resume position (≤5s), same threshold
    /// `LocalPlayerView.setUp()`/`ItemDetailView.startPlayback()` already use.
    private func startPlayback(_ item: LocalItem) {
        if item.resumePosSec > 5 {
            pendingPlayItem = item
            showResumePrompt = true
        } else {
            startFromBeginning = false
            playingItem = item
        }
    }

    private func confirmPlayback() {
        guard let item = pendingPlayItem else { return }
        pendingPlayItem = nil
        playingItem = item
    }
}

private struct LocalItemCard: View {
    let item: LocalItem
    @EnvironmentObject var localLibrary: LocalLibraryManager

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            PosterImage(url: localLibrary.thumbnailURL(for: item), aspect: 16.0/9.0, placeholderSystemImage: "film")
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .topLeading) {
                    PosterToggleBadge(isOn: item.watched, onSymbol: "checkmark.circle.fill", offSymbol: "checkmark.circle", tint: .green) {
                        localLibrary.setWatched(item, watched: !item.watched)
                    }
                    .padding(6)
                }
                .overlay(alignment: .bottomTrailing) {
                    Text(fmtSize(item.sizeBytes))
                        .font(.caption2.bold())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.black.opacity(0.6), in: Capsule())
                        .foregroundStyle(.white)
                        .padding(6)
                }
                // User-Anfrage 2026-08-25: "bei den lokalen Dateien hätte ich gerne in den
                // Kacheln noch die Auflösung" — gleiche Position wie der Browser-`.res-badge`
                // (unten links, CLAUDE.md "Kachel-Overlay-Positionen"), leer wenn (noch) keine
                // Auflösung geprobt wurde.
                .overlay(alignment: .bottomLeading) {
                    if !item.resolutionLabel.isEmpty {
                        Text(item.resolutionLabel)
                            .font(.caption2.bold())
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.black.opacity(0.6), in: Capsule())
                            .foregroundStyle(.white)
                            .padding(6)
                    }
                }

            Text(item.displayTitle)
                .font(.subheadline.weight(.medium))
                .lineLimit(2)
                .foregroundStyle(.primary)
        }
        .contentShape(Rectangle())
    }

    private func fmtSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
