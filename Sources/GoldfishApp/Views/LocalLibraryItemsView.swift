import SwiftUI
import GoldfishCore

private enum LocalSort: String, CaseIterable, Identifiable {
    case name, date, size
    var id: String { rawValue }
    var label: String {
        switch self {
        case .name: return "Name"
        case .date: return "Datum"
        case .size: return "Größe"
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

    init(library: LocalLibrary) { self.libraries = [library] }
    init(libraries: [LocalLibrary]) { self.libraries = libraries }

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
    @State private var search = ""
    @State private var sort: LocalSort = .name
    @State private var ascending = true
    @State private var watchedFilter: LocalWatchedFilter = .all

    private let cardWidth: CGFloat = 150
    private var columns: [GridItem] { [GridItem(.adaptive(minimum: cardWidth, maximum: cardWidth), spacing: 12)] }

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
        switch sort {
        case .name:
            result.sort { $0.displayTitle.localizedStandardCompare($1.displayTitle) == (ascending ? .orderedAscending : .orderedDescending) }
        case .date:
            result.sort { ascending ? $0.modifiedTime < $1.modifiedTime : $0.modifiedTime > $1.modifiedTime }
        case .size:
            result.sort { ascending ? $0.sizeBytes < $1.sizeBytes : $0.sizeBytes > $1.sizeBytes }
        }
        return result
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(displayName)
                        .font(.title2.bold())
                    Text("(\(displayedItems.count))")
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
                                playingItem = item
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
                    playingItem = displayedItems.randomElement()
                } label: {
                    Label("Zufällig", systemImage: "shuffle")
                }
                .disabled(displayedItems.isEmpty)

                Menu {
                    Picker("Sortierung", selection: $sort) {
                        ForEach(LocalSort.allCases) { option in
                            Text(option.label).tag(option)
                        }
                    }
                    Button {
                        ascending.toggle()
                    } label: {
                        Label(ascending ? "Aufsteigend" : "Absteigend", systemImage: ascending ? "arrow.up" : "arrow.down")
                    }
                } label: {
                    Label("Sortieren", systemImage: "arrow.up.arrow.down")
                }

                Menu {
                    Picker("Gesehen-Status", selection: $watchedFilter) {
                        ForEach(LocalWatchedFilter.allCases) { option in
                            Text(option.label).tag(option)
                        }
                    }
                } label: {
                    Label("Filter", systemImage: watchedFilter != .all ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                }

                Button {
                    for lib in libraries { Task { await localLibrary.scan(lib) } }
                } label: {
                    Label("Neu einlesen", systemImage: "arrow.clockwise")
                }
                .disabled(isScanning)
            }
        }
        #if os(macOS)
        .onChange(of: playingItem) { newValue in
            guard let newValue else { return }
            PlayerLaunchCoordinator.shared.pendingLocalPlayer = LocalPlayerLaunchRequest(
                item: newValue,
                queue: playFromShuffle ? [] : displayedItems,
                randomPool: playFromShuffle ? displayedItems : nil
            )
            openWindow(id: "localPlayer")
            playingItem = nil
        }
        #else
        .fullScreenCoverCompat(isPresented: Binding(get: { playingItem != nil }, set: { if !$0 { playingItem = nil } })) {
            if let playingItem {
                if playFromShuffle {
                    LocalPlayerView(item: playingItem, randomPool: displayedItems)
                } else {
                    LocalPlayerView(item: playingItem, queue: displayedItems)
                }
            }
        }
        #endif
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
