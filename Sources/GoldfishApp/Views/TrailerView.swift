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

/// **Verlauf (User-Berichte 2026-09-04, zwei gescheiterte Anläufe):**
/// 1. Direktes `webView.load(URLRequest(embed-URL))` navigiert den WKWebView
///    SELBST zur Embed-Seite — ohne jede Parent-Seite/-Origin verweigerte
///    YouTube mit Fehler 153 ("Fehler bei der Konfiguration des Videoplayers").
/// 2. Der naheliegende Fix — ein `<iframe>` in einer lokalen HTML-Seite via
///    `loadHTMLString(..., baseURL: "https://www.youtube.com")` — führte zu
///    einem NEUEN Fehler ("Video nicht verfügbar", 152-4): die `baseURL` war
///    ebenfalls `youtube.com`, ein Embed, dessen Parent-Origin YouTube selbst
///    ist, wird von YouTubes eigenen Anti-Embedding-Checks als ungültig
///    erkannt (kein echtes Drittanbieter-Embedding).
///
/// **Aktuelle, robuste Lösung:** GAR KEIN `/embed/`-iframe mehr — stattdessen
/// die normale öffentliche `youtube.com/watch?v=…`-Seite direkt laden, exakt
/// so, als würde man sie in Safari öffnen. Das ist die einzige Variante, die
/// nicht von Embedding-spezifischen Restriktionen (Studio-seitig deaktiviertes
/// Embedding, Origin-Checks) betroffen sein kann, weil es kein Embedding ist.
/// Kompromiss: zeigt YouTubes normale mobile Oberfläche statt eines
/// chromelosen Players (kein 1:1-Look wie der Browser-Dialog mehr möglich).
private func trailerWatchURL(_ key: String) -> URL {
    URL(string: "https://www.youtube.com/watch?v=\(key)")!
}

private func makeTrailerWebView() -> WKWebView {
    let config = WKWebViewConfiguration()
    // Ohne das bleibt Autoplay mit Ton auf iOS/macOS stumm bis zu einem
    // manuellen Tap auf den Play-Button im Player — wir wollen aber sofort
    // starten (User-Vorgabe: "soll direkt das Video starten").
    config.mediaTypesRequiringUserActionForPlayback = []
    #if os(iOS)
    config.allowsInlineMediaPlayback = true
    #endif
    return WKWebView(frame: .zero, configuration: config)
}

#if os(iOS)
struct TrailerWebViewRepresentable: UIViewRepresentable {
    let youtubeKey: String

    func makeUIView(context: Context) -> WKWebView {
        let webView = makeTrailerWebView()
        webView.load(URLRequest(url: trailerWatchURL(youtubeKey)))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
#else
struct TrailerWebViewRepresentable: NSViewRepresentable {
    let youtubeKey: String

    func makeNSView(context: Context) -> WKWebView {
        let webView = makeTrailerWebView()
        webView.load(URLRequest(url: trailerWatchURL(youtubeKey)))
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
#endif
#endif
