// TrailerView — Jellyfin-artige Trailer-Wiedergabe (Mac/iOS, seit 2026-09-04).
// Server-Pendant: internal/api/cast.go getMetadataTrailer + der Browser-
// Trailer-Dialog in app.js (iframe-Embed, siehe CLAUDE.md "Trailer").
//
// NICHT auf tvOS: WKWebView/WebKit existiert dort nicht (siehe
// OIDCLoginView.swift, oberster Kommentar) — die tvOS-Variante der
// Trailer-Funktion in ItemDetailView.swift öffnet den Trailer stattdessen
// per `openURL` extern in der YouTube-App.
#if !os(tvOS)
import SwiftUI
import WebKit

struct TrailerSheet: View {
    let youtubeKey: String
    /// Der Server, gegen den diese Session eingeloggt ist (`client.baseURL`)
    /// — wird als `baseURL` der lokalen Embed-HTML-Seite verwendet, siehe
    /// Kommentar bei `trailerHTML`. NICHT optional gemacht/verworfen, wenn
    /// nil: dann lieber komplett auf die Watch-Seite zurückfallen (siehe dort).
    let serverBaseURL: URL?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            TrailerWebViewRepresentable(youtubeKey: youtubeKey, serverBaseURL: serverBaseURL)
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

/// **Verlauf (User-Berichte 2026-09-04, drei Anläufe):**
/// 1. Direktes `webView.load(URLRequest(embed-URL))` navigiert den WKWebView
///    SELBST zur Embed-Seite — ohne jede Parent-Seite/-Origin verweigerte
///    YouTube mit Fehler 153 ("Fehler bei der Konfiguration des Videoplayers").
/// 2. Fix-Versuch: `<iframe>` in lokaler HTML-Seite, aber `baseURL:
///    "https://www.youtube.com"` → NEUER Fehler ("Video nicht verfügbar",
///    152-4): ein Embed, dessen Parent-Origin YouTube SELBST ist, wird von
///    YouTubes Anti-Embedding-Checks als ungültiges Self-Embedding erkannt.
/// 3. Nächster Versuch: GAR KEIN iframe mehr, direkt die normale
///    `youtube.com/watch?v=…`-Seite laden — auf macOS lief das (User
///    bestätigt), auf iOS sprang YouTubes eigene mobile Webseite aber SELBST
///    per JS zur nativen YouTube-App (deren "In der App öffnen"-Verhalten,
///    KEIN iOS-Universal-Link-Hijack unsererseits) — User wollte aber
///    ausdrücklich ein Fenster INNERHALB von Goldfish, "so wie auf dem
///    Server".
///
/// **Jetzige Lösung:** zurück zum `<iframe src=".../embed/…">`-Ansatz aus
/// Versuch 2, aber mit der ECHTEN Server-Domain (`client.baseURL`, z. B.
/// `https://goldfish.<domain>`) als `baseURL` statt `youtube.com` — exakt
/// das Setup, das im Browser bereits nachweislich funktioniert (dort läuft
/// das iframe ja auch auf der echten Goldfish-Domain, nicht auf youtube.com
/// selbst). Ein legitimer Drittanbieter-Origin umgeht sowohl den
/// Self-Embedding-Fehler (152-4) als auch das App-Redirect-JS der normalen
/// Watch-Seite (die `/embed/`-Variante hat dieses Redirect-Verhalten nicht).
/// Ist `serverBaseURL` aus irgendeinem Grund nil, Fallback auf die
/// Watch-Seite (Versuch 3) statt komplett zu scheitern.
private func trailerHTML(_ key: String) -> String {
    """
    <html><head><meta name="viewport" content="width=device-width, initial-scale=1">
    <style>html,body{margin:0;background:#000;height:100%}
    iframe{position:fixed;top:0;left:0;width:100%;height:100%;border:0}</style>
    </head><body>
    <iframe src="https://www.youtube.com/embed/\(key)?autoplay=1&playsinline=1"
      allow="autoplay; encrypted-media; picture-in-picture" allowfullscreen></iframe>
    </body></html>
    """
}

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

private func loadTrailer(into webView: WKWebView, key: String, serverBaseURL: URL?) {
    guard let serverBaseURL else {
        webView.load(URLRequest(url: trailerWatchURL(key)))
        return
    }
    webView.loadHTMLString(trailerHTML(key), baseURL: serverBaseURL)
}

#if os(iOS)
struct TrailerWebViewRepresentable: UIViewRepresentable {
    let youtubeKey: String
    let serverBaseURL: URL?

    func makeUIView(context: Context) -> WKWebView {
        let webView = makeTrailerWebView()
        loadTrailer(into: webView, key: youtubeKey, serverBaseURL: serverBaseURL)
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
#else
struct TrailerWebViewRepresentable: NSViewRepresentable {
    let youtubeKey: String
    let serverBaseURL: URL?

    func makeNSView(context: Context) -> WKWebView {
        let webView = makeTrailerWebView()
        loadTrailer(into: webView, key: youtubeKey, serverBaseURL: serverBaseURL)
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
#endif
#endif
