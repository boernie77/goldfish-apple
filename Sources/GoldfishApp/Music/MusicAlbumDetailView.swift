#if os(macOS)
import GoldfishCore
import SwiftUI

/// Track-Liste eines Albums — Client-Pendant zu `views.js renderAlbumTracks`. Tippen auf
/// einen Titel startet die Wiedergabe in `MusicPlayerEngine` (NICHT `PlayerView`/
/// `ItemDetailView` — Musik hat serverseitig kein TMDB/Detail-Konzept, siehe
/// Server-CLAUDE.md "Persistenter Mini-Player": "ein Klick auf eine Musik-Kachel ruft
/// musicPlayAlbum() auf statt openDetail() zu öffnen").
struct MusicAlbumDetailView: View {
    let album: MusicAlbum

    @EnvironmentObject var client: GoldfishClient
    @EnvironmentObject var musicPlayer: MusicPlayerEngine
    @State private var tracks: [Item] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var addToPlaylistItem: Item?

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
            } else if let errorMessage {
                ContentUnavailableMessage(text: errorMessage)
            } else {
                List {
                    Section {
                        header
                    }
                    .listRowSeparator(.hidden)
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { idx, track in
                        Button {
                            musicPlayer.play(queue: tracks, startIndex: idx, client: client)
                        } label: {
                            trackRow(track, index: idx)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button {
                                addToPlaylistItem = track
                            } label: {
                                Label("Zu Playlist hinzufügen", systemImage: "text.badge.plus")
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle(album.displayTitle)
        .task { await load() }
        .sheet(item: $addToPlaylistItem) { track in
            AddToPlaylistSheet(item: track, kind: "music")
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            PosterImage(url: client.albumCoverURL(albumId: album.id), aspect: 1.0, placeholderSystemImage: "music.note")
                .frame(width: 140, height: 140)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 4) {
                Text(album.displayTitle).font(.title2.weight(.semibold))
                Text(album.artist).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    if let year = album.year, year > 0 { Text(String(year)) }
                    if let genre = album.genre, !genre.isEmpty { Text(genre) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                Button {
                    musicPlayer.play(queue: tracks, startIndex: 0, client: client)
                } label: {
                    Label("Album abspielen", systemImage: "play.fill")
                }
                .disabled(tracks.isEmpty)
                .padding(.top, 6)
            }
        }
        .padding(.vertical, 8)
    }

    private func trackRow(_ track: Item, index: Int) -> some View {
        HStack {
            Text(track.trackNo.map(String.init) ?? "\(index + 1)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .trailing)
            VStack(alignment: .leading) {
                Text(track.displayTitle)
                    .fontWeight(musicPlayer.currentItem?.id == track.id ? .semibold : .regular)
                if album.artist == "Verschiedene Interpreten", let artist = track.artist, !artist.isEmpty {
                    Text(artist).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if musicPlayer.currentItem?.id == track.id, musicPlayer.isPlaying {
                Image(systemName: "speaker.wave.2.fill").foregroundStyle(Color.accentColor)
            }
            Text(track.durationLabel).font(.caption).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            let detail = try await client.fetchAlbum(id: album.id)
            tracks = detail.tracks
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}
#endif
