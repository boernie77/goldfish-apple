// TrailerView — Jellyfin-artige Trailer-Wiedergabe (Mac/iOS, seit 2026-09-04).
// Server-Pendant: internal/api/cast.go getMetadataTrailer + der Browser-
// Trailer-Dialog in app.js (iframe-Embed, siehe CLAUDE.md "Trailer").
//
// NICHT auf tvOS: WKWebView/WebKit existiert dort nicht (siehe
// OIDCLoginView.swift, oberster Kommentar) — die tvOS-Variante der
// Trailer-Funktion in ItemDetailView.swift öffnet den Trailer stattdessen
// per `openURL` extern in der YouTube-App (falls installiert).
#if !os(tvOS)
import SwiftUI
import WebKit

struct TrailerSheet: View {
    let youtubeKey: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            TrailerWebViewRepresentable(youtubeKey: youtubeKey)
                // Gleicher Grund wie bei OIDCLoginView: ein NSViewRepresentable
                // hat keine intrinsische Größe, ohne explizites frame kollabiert
                // der WKWebView auf macOS auf 0 Höhe.
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle("Trailer")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Schließen") { dismiss() }
                    }
                }
        }
        #if os(macOS)
        .frame(minWidth: 720, idealWidth: 960, minHeight: 480, idealHeight: 600)
        #endif
    }
}

/// Lädt den YouTube-Embed direkt mit Autoplay — exakt das gleiche iframe-Muster
/// wie der Browser (`https://www.youtube.com/embed/<key>?autoplay=1`). Beim
/// Schließen des Sheets wird die ganze WKWebView-Instanz verworfen (SwiftUI
/// entfernt sie aus der View-Hierarchie), das stoppt die Wiedergabe zuverlässig
/// — kein manuelles `stopLoading()`/HTML-Leeren wie im Browser nötig, dort blieb
/// sonst YouTube im Hintergrund-Tab weiterlaufen (das Problem gibt es hier nicht,
/// weil das komplette WKWebView-Objekt weg ist, nicht nur sein `src`).
private func trailerRequest(_ key: String) -> URLRequest {
    let url = URL(string: "https://www.youtube.com/embed/\(key)?autoplay=1&playsinline=1")!
    return URLRequest(url: url)
}

#if os(iOS)
struct TrailerWebViewRepresentable: UIViewRepresentable {
    let youtubeKey: String

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.load(trailerRequest(youtubeKey))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
#else
struct TrailerWebViewRepresentable: NSViewRepresentable {
    let youtubeKey: String

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.load(trailerRequest(youtubeKey))
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
#endif
#endif
