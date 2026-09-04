// TrailerPlayerView — Jellyfin-artige Trailer-Wiedergabe (Mac/iOS/tvOS,
// seit 2026-09-04). Server-Pendant: internal/api/cast.go
// getMetadataTrailerStream + internal/ytdlp (siehe CLAUDE.md "Trailer").
//
// Verlauf (mehrere gescheiterte WebView-Anläufe, alle User-Berichte
// 2026-09-04, siehe Git-Historie dieser Datei für Details): direktes
// YouTube-Embed in einem WKWebView scheiterte an YouTubes Anti-Embedding-
// Checks (Fehler 153/152-4) bzw. sprang auf iOS in die native YouTube-App.
// tvOS hat ohnehin GAR KEIN WebKit (siehe OIDCLoginView.swift). Die jetzige,
// robuste Lösung: der SERVER extrahiert per yt-dlp eine direkt abspielbare
// Stream-URL (GET /api/metadata/{id}/trailer-stream) — die App braucht dafür
// gar kein WebKit mehr, nur noch AVKit/AVPlayer, das auf allen drei
// Plattformen gleich funktioniert.
import SwiftUI
import AVKit

struct TrailerPlayerView: View {
    let streamURL: URL
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer

    init(streamURL: URL) {
        self.streamURL = streamURL
        _player = State(initialValue: AVPlayer(url: streamURL))
    }

    var body: some View {
        VideoPlayer(player: player)
            .onAppear { player.play() }
            .onDisappear { player.pause() }
            .ignoresSafeArea()
            #if !os(tvOS)
            // tvOS dismisst eine navigationDestination-Vollbildseite über den
            // Menu-Knopf der Fernbedienung (siehe fullScreenCoverCompat) — ein
            // zusätzlicher Schließen-Button bräuchte dort sowieso eigenen
            // Fokus-Handling-Aufwand. Mac/iOS haben kein Äquivalent zum
            // Menu-Knopf, deshalb dort ein sichtbarer ✕-Button oben rechts.
            .overlay(alignment: .topTrailing) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.6))
                }
                .buttonStyle(.plain)
                .padding()
            }
            #endif
    }
}
