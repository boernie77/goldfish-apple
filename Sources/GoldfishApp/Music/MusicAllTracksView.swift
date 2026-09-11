#if os(macOS)
import GoldfishCore
import SwiftUI

/// "🎵 Alle Titel" — flache Liste ALLER Tracks einer Musik-Bibliothek, unabhängig
/// von der Album-Struktur (User-Wunsch 2026-09-11, Client-Pendant zu
/// `views.js renderAllTracksList`/`#musicAllTracksBtn`). Holt den ganz normalen
/// `/api/items?libraryId=`-Endpoint (liefert Musik-Items generisch mit, kein
/// eigener Server-Endpoint nötig — Browser-CLAUDE.md "'🎵 Alle Titel'-Ansicht").
struct MusicAllTracksView: View {
    let library: Library

    @EnvironmentObject var client: GoldfishClient
    @EnvironmentObject var musicPlayer: MusicPlayerEngine
    @EnvironmentObject var downloads: DownloadManager
    @Environment(\.dismiss) private var dismiss
    @State private var tracks: [Item] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var search = ""

    private var filteredTracks: [Item] {
        guard !search.isEmpty else { return tracks }
        return tracks.filter {
            $0.displayTitle.localizedCaseInsensitiveContains(search)
                || ($0.artist ?? "").localizedCaseInsensitiveContains(search)
                || ($0.album ?? "").localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
            } else if let errorMessage {
                ContentUnavailableMessage(text: errorMessage)
            } else if tracks.isEmpty {
                ContentUnavailableMessage(text: "Keine Titel gefunden.")
            } else {
                List {
                    HStack {
                        Button {
                            musicPlayer.play(queue: filteredTracks, startIndex: 0, client: client)
                        } label: {
                            Label("Alle abspielen", systemImage: "play.fill")
                        }
                        .disabled(filteredTracks.isEmpty)
                    }
                    ForEach(Array(filteredTracks.enumerated()), id: \.element.id) { idx, track in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(track.displayTitle)
                                    .fontWeight(musicPlayer.currentItem?.id == track.id ? .semibold : .regular)
                                Text([track.artist, track.album].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if musicPlayer.currentItem?.id == track.id, musicPlayer.isPlaying {
                                Image(systemName: "speaker.wave.2.fill").foregroundStyle(Color.accentColor)
                            }
                            Text(track.durationLabel).font(.caption).foregroundStyle(.secondary)
                            MusicFavoriteButton(isFavorite: track.favorite) { newValue in
                                try? await client.setFavorite(itemId: track.id, favorite: newValue)
                            }
                            MusicDownloadIcon(item: track)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            musicPlayer.play(queue: filteredTracks, startIndex: idx, client: client)
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("🎵 Alle Titel")
        .searchable(text: $search, prompt: "Titel/Künstler/Album durchsuchen")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Fertig") { dismiss() }
            }
        }
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            let items = try await client.fetchItems(libraryId: library.id)
            tracks = items.sorted {
                if $0.artist != $1.artist { return ($0.artist ?? "") < ($1.artist ?? "") }
                if $0.album != $1.album { return ($0.album ?? "") < ($1.album ?? "") }
                return ($0.trackNo ?? 0) < ($1.trackNo ?? 0)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}
#endif
