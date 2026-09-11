#if os(macOS) || os(iOS)
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
    // User-Report 2026-09-11: "Da erkennt man nur einen Teil der
    // Steuerelemente" — die Mac-Leiste (Shuffle/⏮/⏯/⏭/Repeat + Slider +
    // Queue/AirPlay/Schließen, alles in EINER Zeile) ist für ein breites
    // Fenster designt; auf einem iPhone (≈375-430pt) reicht der Platz nicht
    // annähernd, der Rest der Controls fällt unsichtbar rechts raus. Auf
    // iOS deshalb eine eigene, kompakte Leiste (Cover/Titel + ⏯/⏭) — Tippen
    // auf die Zeile öffnet ein Sheet mit ALLEN Controls (Shuffle/⏮/Repeat/
    // Fortschritt/Queue/AirPlay), analog zu Apple Music/Spotifys
    // "Mini-Player tippen → voller Player".
    #if os(iOS)
    @State private var showFullControls = false
    #endif

    var body: some View {
        if let item = musicPlayer.currentItem {
            #if os(iOS)
            compactBar(item: item)
                .sheet(isPresented: $showFullControls) {
                    NavigationStack {
                        fullControlsSheet(item: item)
                    }
                }
                .sheet(isPresented: $showQueue) {
                    NavigationStack {
                        MusicQueueView()
                    }
                }
            #else
            macBar(item: item)
            #endif
        }
    }

    #if os(iOS)
    private func compactBar(item: Item) -> some View {
        HStack(spacing: 12) {
            PosterImage(url: item.musicAlbumId.flatMap { client.albumCoverURL(albumId: $0) }, aspect: 1.0, placeholderSystemImage: "music.note")
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 5))
            VStack(alignment: .leading, spacing: 1) {
                Text(item.displayTitle).font(.subheadline.weight(.medium)).lineLimit(1)
                Text(item.artist ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            HStack(spacing: 20) {
                Button { musicPlayer.togglePlayPause() } label: {
                    if musicPlayer.isLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: musicPlayer.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title2)
                    }
                }
                .disabled(musicPlayer.isLoading)

                Button { musicPlayer.next(client: client) } label: {
                    Image(systemName: "forward.fill")
                }
                .disabled(!musicPlayer.isShuffling && musicPlayer.repeatMode == .off && (musicPlayer.currentIndex ?? 0) + 1 >= musicPlayer.queue.count)
            }
            .buttonStyle(.plain)
            .font(.body)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .overlay(Divider(), alignment: .top)
        .contentShape(Rectangle())
        .onTapGesture { showFullControls = true }
    }

    private func fullControlsSheet(item: Item) -> some View {
        VStack(spacing: 20) {
            PosterImage(url: item.musicAlbumId.flatMap { client.albumCoverURL(albumId: $0) }, aspect: 1.0, placeholderSystemImage: "music.note")
                .frame(width: 220, height: 220)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .padding(.top, 12)

            VStack(spacing: 4) {
                Text(item.displayTitle).font(.title3.weight(.semibold)).multilineTextAlignment(.center)
                Text(item.artist ?? "").font(.subheadline).foregroundStyle(.secondary)
            }

            progressSlider

            HStack(spacing: 32) {
                Button { musicPlayer.isShuffling.toggle() } label: {
                    Image(systemName: "shuffle")
                }
                .foregroundStyle(musicPlayer.isShuffling ? Color.accentColor : .primary)

                Button { musicPlayer.previous(client: client) } label: {
                    Image(systemName: "backward.fill").font(.title2)
                }
                .disabled(musicPlayer.currentIndex == 0 && musicPlayer.currentTime <= 3)

                Button { musicPlayer.togglePlayPause() } label: {
                    if musicPlayer.isLoading {
                        ProgressView()
                    } else {
                        Image(systemName: musicPlayer.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 40))
                    }
                }
                .disabled(musicPlayer.isLoading)

                Button { musicPlayer.next(client: client) } label: {
                    Image(systemName: "forward.fill").font(.title2)
                }
                .disabled(!musicPlayer.isShuffling && musicPlayer.repeatMode == .off && (musicPlayer.currentIndex ?? 0) + 1 >= musicPlayer.queue.count)

                Button { musicPlayer.repeatMode.cycle() } label: {
                    Image(systemName: musicPlayer.repeatMode.systemImage)
                }
                .foregroundStyle(musicPlayer.repeatMode == .off ? .primary : Color.accentColor)
            }
            .buttonStyle(.plain)
            .font(.title3)

            HStack(spacing: 28) {
                Button { showQueue = true } label: {
                    Image(systemName: "list.bullet")
                }
                AirPlayButton()
                    .frame(width: 24, height: 24)
                Button { musicPlayer.stop() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .font(.title3)

            Spacer()
        }
        .padding()
        .navigationTitle("Wird abgespielt")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Fertig") { showFullControls = false }
            }
        }
    }
    #endif

    #if os(macOS)
    private func macBar(item: Item) -> some View {
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
    #endif

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
