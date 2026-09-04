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

/// **Wichtig — YouTube-Fehler 153 ("Fehler bei der Konfiguration des
/// Videoplayers"):** ein direktes `webView.load(URLRequest(url:
/// youtube.com/embed/…))` navigiert den WKWebView SELBST zur Embed-URL —
/// die Embed-Seite ist dann das TOP-Level-Dokument ohne jede Parent-Seite/
/// -Origin. YouTubes Player-Skript prüft genau das (Referrer/Parent-Frame)
/// und verweigert die Wiedergabe mit Fehler 153 + einem nutzlosen "Auf
/// YouTube ansehen"-Link (User-Bericht 2026-09-04, nur auf iOS reproduziert,
/// macOS lief zufällig durch). Fix: eine winzige lokale HTML-Seite MIT einem
/// echten `<iframe>` drumherum laden (`loadHTMLString`, `baseURL =
/// https://www.youtube.com` gibt der Seite eine gültige Origin) — exakt das
/// Muster, das der Browser-Trailer-Dialog (`app.js`, echtes `<iframe>` in
/// `#trailerFrameWrap`) ohnehin die ganze Zeit nutzt.
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
        webView.loadHTMLString(trailerHTML(youtubeKey), baseURL: URL(string: "https://www.youtube.com"))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
#else
struct TrailerWebViewRepresentable: NSViewRepresentable {
    let youtubeKey: String

    func makeNSView(context: Context) -> WKWebView {
        let webView = makeTrailerWebView()
        webView.loadHTMLString(trailerHTML(youtubeKey), baseURL: URL(string: "https://www.youtube.com"))
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
#endif
#endif
