#if os(macOS) || os(iOS)
import GoldfishCore
import SwiftUI

/// "Wird als Nächstes gespielt" (User-Wunsch 2026-09-11: "was haben andere
/// Musikplayer" → Warteschlange einsehen/umsortieren fehlte komplett). Zeigt
/// die komplette aktuelle Queue, aktueller Titel hervorgehoben; Tippen
/// springt direkt dorthin, spätere Titel lassen sich entfernen.
struct MusicQueueView: View {
    @EnvironmentObject var client: GoldfishClient
    @EnvironmentObject var musicPlayer: MusicPlayerEngine
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if musicPlayer.queue.isEmpty {
                ContentUnavailableMessage(text: "Keine Warteschlange.")
            } else {
                List {
                    ForEach(Array(musicPlayer.queue.enumerated()), id: \.element.id) { idx, track in
                        HStack {
                            Image(systemName: idx == musicPlayer.currentIndex ? "speaker.wave.2.fill" : "music.note")
                                .foregroundStyle(idx == musicPlayer.currentIndex ? Color.accentColor : .secondary)
                                .frame(width: 20)
                            VStack(alignment: .leading) {
                                Text(track.displayTitle)
                                    .fontWeight(idx == musicPlayer.currentIndex ? .semibold : .regular)
                                Text([track.artist, track.album].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(track.durationLabel).font(.caption).foregroundStyle(.secondary)
                            if idx != musicPlayer.currentIndex {
                                Button {
                                    musicPlayer.removeFromQueue(at: idx)
                                } label: {
                                    Image(systemName: "xmark.circle")
                                }
                                .buttonStyle(.plain)
                                .help("Aus Warteschlange entfernen")
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            musicPlayer.jump(to: idx, client: client)
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Wird als Nächstes gespielt")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Fertig") { dismiss() }
            }
        }
    }
}
#endif
