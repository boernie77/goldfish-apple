#if os(macOS)
import GoldfishCore
import SwiftUI

/// Persistente Mini-Player-Leiste — von `MainTabView` als `.safeAreaInset(edge: .bottom)`
/// eingebunden, bleibt dadurch über jede Navigation hinweg sichtbar (analog zum
/// Browser-`#miniPlayer`, der außerhalb von `#grid` im DOM sitzt und jeden `loadItems()`-
/// Aufruf übersteht). User-Wunsch 2026-09-11: "eigene Steuerbuttons und eigener Player".
struct MusicPlayerBar: View {
    @EnvironmentObject var client: GoldfishClient
    @EnvironmentObject var musicPlayer: MusicPlayerEngine
    @State private var showQueue = false

    var body: some View {
        if let item = musicPlayer.currentItem {
            HStack(spacing: 14) {
                PosterImage(url: item.musicAlbumId.flatMap { client.albumCoverURL(albumId: $0) }, aspect: 1.0, placeholderSystemImage: "music.note")
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 5))

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.displayTitle).font(.subheadline.weight(.medium)).lineLimit(1)
                    Text(item.artist ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(minWidth: 120, alignment: .leading)

                Spacer(minLength: 12)

                HStack(spacing: 18) {
                    // Shuffle/Repeat vor den Transportbuttons — Konvention jedes
                    // gängigen Musik-Players (Spotify/Apple Music). User-Wunsch
                    // 2026-09-11: "was haben andere Musikplayer".
                    Button { musicPlayer.isShuffling.toggle() } label: {
                        Image(systemName: "shuffle")
                    }
                    .foregroundStyle(musicPlayer.isShuffling ? Color.accentColor : .primary)
                    .help("Zufallswiedergabe")

                    Button { musicPlayer.previous(client: client) } label: {
                        Image(systemName: "backward.fill")
                    }
                    .disabled(musicPlayer.currentIndex == 0 && musicPlayer.currentTime <= 3)

                    Button { musicPlayer.togglePlayPause() } label: {
                        if musicPlayer.isLoading {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: musicPlayer.isPlaying ? "pause.fill" : "play.fill")
                                .font(.title3)
                        }
                    }
                    .disabled(musicPlayer.isLoading)

                    Button { musicPlayer.next(client: client) } label: {
                        Image(systemName: "forward.fill")
                    }
                    .disabled(!musicPlayer.isShuffling && musicPlayer.repeatMode == .off && (musicPlayer.currentIndex ?? 0) + 1 >= musicPlayer.queue.count)

                    Button { musicPlayer.repeatMode.cycle() } label: {
                        Image(systemName: musicPlayer.repeatMode.systemImage)
                    }
                    .foregroundStyle(musicPlayer.repeatMode == .off ? .primary : Color.accentColor)
                    .help("Wiederholen (Aus/Alle/Einzeln)")
                }
                .buttonStyle(.plain)
                .font(.body)

                progressSlider
                    .frame(minWidth: 160, maxWidth: 320)

                HStack(spacing: 14) {
                    Button { showQueue = true } label: {
                        Image(systemName: "list.bullet")
                    }
                    .buttonStyle(.plain)
                    .help("Wird als Nächstes gespielt")

                    // Natives AirPlay-Icon — fixe Größe, AVRoutePickerView bringt
                    // sein eigenes Kreis-Icon mit, keine zusätzliche Umrandung.
                    AirPlayButton()
                        .frame(width: 20, height: 20)

                    Button { musicPlayer.stop() } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(.bar)
            .overlay(Divider(), alignment: .top)
            .sheet(isPresented: $showQueue) {
                NavigationStack {
                    MusicQueueView()
                }
                .frame(minWidth: 420, minHeight: 480)
            }
        }
    }

    private var progressSlider: some View {
        HStack(spacing: 6) {
            Text(formatted(musicPlayer.currentTime)).font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            Slider(
                value: Binding(
                    get: { musicPlayer.currentTime },
                    set: { musicPlayer.seek(to: $0) }
                ),
                in: 0...max(musicPlayer.duration, 1)
            )
            Text(formatted(musicPlayer.duration)).font(.caption2).foregroundStyle(.secondary).monospacedDigit()
        }
    }

    private func formatted(_ sec: Double) -> String {
        let s = max(0, Int(sec.rounded()))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
#endif
