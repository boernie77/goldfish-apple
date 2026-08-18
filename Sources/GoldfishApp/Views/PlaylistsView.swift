import SwiftUI
import GoldfishCore

struct PlaylistsView: View {
    @EnvironmentObject var client: GoldfishClient
    @State private var playlists: [Playlist] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var showingCreate = false
    @State private var newName = ""
    // User-Anfrage 2026-08-19: "im Sammlungen und Playlist fehlt das Suchfeld" — rein
    // clientseitig, wie bei `CollectionsView` (keine Server-Suche für diesen Endpunkt, aber
    // auch keine nötig bei einer überschaubaren Playlist-Anzahl).
    @State private var search = ""

    private let columns = [GridItem(.adaptive(minimum: 170, maximum: 220), spacing: 16)]

    private var filteredPlaylists: [Playlist] {
        guard !search.isEmpty else { return playlists }
        return playlists.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
            } else if let errorMessage {
                ContentUnavailableMessage(text: errorMessage)
            } else if playlists.isEmpty {
                ContentUnavailableMessage(text: "Noch keine Playlists.")
            } else if filteredPlaylists.isEmpty {
                ContentUnavailableMessage(text: "Keine Playlists gefunden.")
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(filteredPlaylists) { playlist in
                            NavigationLink(destination: PlaylistDetailView(playlist: playlist, onDeleted: { Task { await load() } })) {
                                PlaylistCard(playlist: playlist)
                            }
                            .buttonStyle(.plain)
                            .focusableCompat(false)
                        }
                    }
                    .padding()
                }
            }
        }
        .navigationTitle("Playlists")
        #if os(iOS)
        .searchable(text: $search, prompt: "Suchen")
        #endif
        .toolbar {
            #if os(macOS)
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
            ToolbarItem(placement: .primaryAction) {
                Button {
                    newName = ""
                    showingCreate = true
                } label: {
                    Label("Neue Playlist", systemImage: "plus")
                }
            }
        }
        .alert("Neue Playlist", isPresented: $showingCreate) {
            TextField("Name", text: $newName)
            Button("Abbrechen", role: .cancel) {}
            Button("Erstellen") {
                Task { await create() }
            }
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        isLoading = true
        do {
            playlists = try await client.fetchPlaylists()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func create() async {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        _ = try? await client.createPlaylist(name: trimmed)
        await load()
    }
}

private struct PlaylistCard: View {
    let playlist: Playlist
    @EnvironmentObject var client: GoldfishClient

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                if let posterURL {
                    Color.clear
                        .overlay { AsyncImage(url: posterURL) { phase in
                            switch phase {
                            case .success(let image): image.resizable().scaledToFill()
                            default: LinearGradient(colors: [.blue, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing)
                            }
                        } }
                        .clipped()
                    LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
                } else {
                    LinearGradient(colors: [.blue, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "music.note.list")
                        .font(.system(size: 46))
                        .foregroundStyle(.white.opacity(0.3))
                        .padding(16)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }
                Text("\(playlist.itemCount) Video\(playlist.itemCount == 1 ? "" : "s")")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.black.opacity(0.25), in: Capsule())
                    .foregroundStyle(.white)
                    .padding(10)
            }
            .frame(height: 110)

            Text(playlist.name)
                .font(.headline)
                .lineLimit(1)
                .foregroundStyle(.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.thinMaterial)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
    }

    private var posterURL: URL? {
        if let metadataId = playlist.posterMetadataId, metadataId > 0, let url = client.posterURL(metadataId: metadataId) {
            return url
        }
        if let itemId = playlist.posterItemId, itemId > 0, let url = client.thumbURL(itemId: itemId) {
            return url
        }
        return nil
    }
}

struct PlaylistDetailView: View {
    let playlist: Playlist
    var onDeleted: (() -> Void)? = nil

    @EnvironmentObject var client: GoldfishClient
    @Environment(\.dismiss) private var dismiss
    @State private var items: [Item] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var showingDeleteConfirm = false
    @State private var showingRename = false
    @State private var renameText = ""

    private let cardWidth: CGFloat = 150
    private var columns: [GridItem] { [GridItem(.adaptive(minimum: cardWidth, maximum: cardWidth), spacing: 12)] }

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
            } else if let errorMessage {
                ContentUnavailableMessage(text: errorMessage)
            } else if items.isEmpty {
                ContentUnavailableMessage(text: "Diese Playlist ist leer.")
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(items) { item in
                            NavigationLink(destination: ItemDetailView(item: item, queue: items)) {
                                ItemCard(item: item)
                                    .frame(width: cardWidth)
                            }
                            .buttonStyle(.plain)
                            .focusableCompat(false)
                            .contextMenu {
                                Button("Aus Playlist entfernen", role: .destructive) {
                                    Task { try? await client.removeFromPlaylist(playlistId: playlist.id, itemId: item.id); await load() }
                                }
                            }
                        }
                    }
                    .padding()
                }
            }
        }
        .navigationTitle(playlist.name)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        renameText = playlist.name
                        showingRename = true
                    } label: {
                        Label("Umbenennen", systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        showingDeleteConfirm = true
                    } label: {
                        Label("Playlist löschen", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .alert("Playlist umbenennen", isPresented: $showingRename) {
            TextField("Name", text: $renameText)
            Button("Abbrechen", role: .cancel) {}
            Button("Speichern") {
                Task { try? await client.renamePlaylist(id: playlist.id, name: renameText) }
            }
        }
        .confirmationDialog("Playlist löschen?", isPresented: $showingDeleteConfirm, titleVisibility: .visible) {
            Button("Löschen", role: .destructive) {
                Task {
                    try? await client.deletePlaylist(id: playlist.id)
                    onDeleted?()
                    dismiss()
                }
            }
            Button("Abbrechen", role: .cancel) {}
        }
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        do {
            items = try await client.fetchPlaylistItems(id: playlist.id)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

/// "Zu Playlist hinzufügen" — opened from `ItemDetailView`. Lädt die eigenen Playlists,
/// zeigt eine Checkmark für die, die das Item schon enthalten (via `fetchPlaylistsForItem`),
/// Tap fügt hinzu/entfernt.
struct AddToPlaylistSheet: View {
    let item: Item
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var client: GoldfishClient

    @State private var playlists: [Playlist] = []
    @State private var memberOf: Set<Int64> = []
    @State private var isLoading = true
    @State private var newName = ""
    @State private var showingCreate = false
    @State private var toastMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView()
                } else if playlists.isEmpty {
                    ContentUnavailableMessage(text: "Noch keine Playlists — unten erstellen.")
                } else {
                    List(playlists) { playlist in
                        Button {
                            Task { await toggle(playlist) }
                        } label: {
                            HStack {
                                Text(playlist.name)
                                Spacer()
                                if memberOf.contains(playlist.id) {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("Zu Playlist hinzufügen")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fertig") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        newName = ""
                        showingCreate = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .alert("Neue Playlist", isPresented: $showingCreate) {
                TextField("Name", text: $newName)
                Button("Abbrechen", role: .cancel) {}
                Button("Erstellen") { Task { await createAndAdd() } }
            }
        }
        .task { await load() }
        .frame(minWidth: 320, minHeight: 360)
    }

    private func load() async {
        isLoading = true
        async let allTask = client.fetchPlaylists()
        async let memberTask = client.fetchPlaylistsForItem(itemId: item.id)
        playlists = (try? await allTask) ?? []
        memberOf = Set((try? await memberTask)?.map(\.id) ?? [])
        isLoading = false
    }

    private func toggle(_ playlist: Playlist) async {
        if memberOf.contains(playlist.id) {
            try? await client.removeFromPlaylist(playlistId: playlist.id, itemId: item.id)
            memberOf.remove(playlist.id)
        } else {
            _ = try? await client.addToPlaylist(playlistId: playlist.id, itemId: item.id)
            memberOf.insert(playlist.id)
        }
    }

    private func createAndAdd() async {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let created = try? await client.createPlaylist(name: trimmed) else { return }
        playlists.append(created)
        _ = try? await client.addToPlaylist(playlistId: created.id, itemId: item.id)
        memberOf.insert(created.id)
    }
}
