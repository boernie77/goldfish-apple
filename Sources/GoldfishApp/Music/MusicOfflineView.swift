#if os(macOS) || os(iOS)
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
    @Environment(\.dismiss) private var dismiss
    @AppStorage private var librarySyncEnabled: Bool
    @State private var confirmCancel = false
    @State private var confirmDeleteAll = false

    init(library: Library) {
        self.library = library
        // Gleicher Schlüssel wie MusicLibraryView: nach dem Aufräumen muss der Sync aus sein,
        // sonst lädt das nächste Öffnen der Bibliothek alles wieder an.
        self._librarySyncEnabled = AppStorage(wrappedValue: false, "musicLibrarySync.\(library.id)")
    }

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
                    HStack {
                        Button {
                            musicPlayer.play(queue: offlineTracks, startIndex: 0, client: client)
                        } label: {
                            Label("Alle offline abspielen", systemImage: "play.fill")
                        }
                        Button {
                            // Hörbücher vom Shuffle ausschließen (User-Wunsch
                            // 2026-09-14) — fehlte hier bisher komplett, nicht
                            // mal ein .m4b-Check, siehe Kommentar bei
                            // `MusicLibraryView.shufflePlayLibrary()`.
                            let playable = offlineTracks.filter { !$0.isLikelyAudiobook }
                            guard !playable.isEmpty else { return }
                            musicPlayer.play(queue: playable.shuffled(), startIndex: 0, client: client, shuffle: true)
                        } label: {
                            Label("Shuffle", systemImage: "shuffle")
                        }
                    }
                    // Siehe Kommentar in MusicAlbumDetailView.header.
                    #if os(iOS)
                    .labelStyle(.iconOnly)
                    #endif
                    ForEach(offlineTracks) { track in
                        // Tap-Gesture NUR auf dem Text-Teil (`trackRow`), NICHT auf der
                        // ganzen HStack — Favoriten-Herz und Download-Icon sind selbst
                        // echte Buttons, und ein `.onTapGesture` über einer Zeile MIT
                        // eingebetteten Buttons ist in SwiftUI unzuverlässig (gleiche
                        // Falle wie bei verschachtelten Button-in-Button-Konstrukten,
                        // siehe Kommentare in MusicAlbumDetailView/MusicPlaylistsView —
                        // hier beim ursprünglichen Bau von MusicOfflineView übersehen,
                        // User-Report 2026-09-11: "Es kommt gar nicht bis zum Player").
                        HStack {
                            trackRow(track)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    let idx = offlineTracks.firstIndex(where: { $0.id == track.id }) ?? 0
                                    musicPlayer.play(queue: offlineTracks, startIndex: idx, client: client)
                                }
                            MusicFavoriteButton(isFavorite: track.favorite) { newValue in
                                try? await client.setFavorite(itemId: track.id, favorite: newValue)
                            }
                            MusicDownloadIcon(item: track)
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("📶 Offline verfügbar")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Fertig") { dismiss() }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        confirmCancel = true
                    } label: {
                        Label("Laufende Downloads abbrechen (\(downloads.unfinishedMusicCount(libraryId: library.id)))", systemImage: "xmark.circle")
                    }
                    .disabled(downloads.unfinishedMusicCount(libraryId: library.id) == 0)
                    Button(role: .destructive) {
                        confirmDeleteAll = true
                    } label: {
                        Label("Alle Offline-Musik löschen", systemImage: "trash")
                    }
                } label: {
                    Label("Aufräumen", systemImage: "ellipsis.circle")
                }
            }
        }
        .confirmationDialog("Alle laufenden und wartenden Musik-Downloads abbrechen? Die Synchronisation wird ausgeschaltet.", isPresented: $confirmCancel, titleVisibility: .visible) {
            Button("Abbrechen der Downloads", role: .destructive) {
                librarySyncEnabled = false
                downloads.cancelUnfinishedMusic(libraryId: library.id)
            }
            Button("Zurück", role: .cancel) {}
        }
        .confirmationDialog("ALLE offline gespeicherte Musik dieser Bibliothek löschen? Die Synchronisation wird ausgeschaltet.", isPresented: $confirmDeleteAll, titleVisibility: .visible) {
            Button("Alles löschen", role: .destructive) {
                librarySyncEnabled = false
                downloads.deleteAllMusic(libraryId: library.id)
            }
            Button("Zurück", role: .cancel) {}
        }
    }

    private func trackRow(_ track: Item) -> some View {
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
        }
    }
}
#endif
