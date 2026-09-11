#if os(macOS)
import GoldfishCore
import SwiftUI

/// "📶 Offline verfügbar" — eigener Bereich innerhalb der Musik-Bibliothek (User-Wunsch
/// 2026-09-11: NICHT in der generischen Downloads-Ansicht mitlaufen lassen, Musik bleibt
/// in sich geschlossen). Zeigt alle lokal heruntergeladenen Tracks DIESER Bibliothek —
/// filtert `DownloadManager.records` über das eingefrorene `cachedItem.libraryId`
/// (dieselbe Quelle, aus der der generische Downloads-Tab seine Kacheln baut).
struct MusicOfflineView: View {
    let library: Library

    @EnvironmentObject var client: GoldfishClient
    @EnvironmentObject var musicPlayer: MusicPlayerEngine
    @EnvironmentObject var downloads: DownloadManager

    private var offlineTracks: [Item] {
        downloads.records.values
            .filter { $0.state == .done }
            .compactMap(\.cachedItem)
            .filter { $0.libraryId == library.id }
            .sorted {
                if $0.artist != $1.artist { return ($0.artist ?? "") < ($1.artist ?? "") }
                if $0.album != $1.album { return ($0.album ?? "") < ($1.album ?? "") }
                return ($0.trackNo ?? 0) < ($1.trackNo ?? 0)
            }
    }

    var body: some View {
        Group {
            if offlineTracks.isEmpty {
                ContentUnavailableMessage(text: "Noch keine offline gespeicherten Titel. Lade Alben, Playlists oder einzelne Titel herunter, oder aktiviere die Bibliotheks-Synchronisation.")
            } else {
                List {
                    Button {
                        musicPlayer.play(queue: offlineTracks, startIndex: 0, client: client)
                    } label: {
                        Label("Alle offline abspielen", systemImage: "play.fill")
                    }
                    ForEach(offlineTracks) { track in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(track.displayTitle)
                                    .fontWeight(musicPlayer.currentItem?.id == track.id ? .semibold : .regular)
                                Text([track.artist, track.album].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(track.durationLabel).font(.caption).foregroundStyle(.secondary)
                            MusicDownloadIcon(item: track)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            let idx = offlineTracks.firstIndex(where: { $0.id == track.id }) ?? 0
                            musicPlayer.play(queue: offlineTracks, startIndex: idx, client: client)
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("📶 Offline verfügbar")
    }
}
#endif
