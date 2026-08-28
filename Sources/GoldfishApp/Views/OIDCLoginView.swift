import SwiftUI
import WebKit
import GoldfishCore

/// Presents the Authentik SSO flow in an embedded web view. The Goldfish server
/// owns the entire OAuth2/PKCE exchange (see internal/api/oidc.go) — this view
/// just watches where the web view ends up and reacts:
///   - lands on "/"                          → login succeeded, cookie is set
///   - lands on "/login.html?sso_error=..."  → login failed, show the message
struct OIDCLoginView: View {
    let baseURL: URL
    var onSuccess: () -> Void
    var onFailure: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            OIDCWebViewRepresentable(baseURL: baseURL) { result in
                switch result {
                case .success:
                    onSuccess()
                case .failure(let message):
                    onFailure(message)
                }
                dismiss()
            }
            // Ohne das kollabiert der WKWebView auf macOS auf 0 Höhe (ein
            // NSViewRepresentable hat keine intrinsische Größe) — das Sheet war
            // dann nur ein schmaler Streifen mit "Anmelden mit SSO" + Abbrechen,
            // die Authentik-Seite bekam keinen Platz und blieb unsichtbar. Genau
            // das Muster, das ShuffleScopeSheet in LibrariesView schon hatte.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Anmelden mit SSO")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 720, idealWidth: 900, minHeight: 760, idealHeight: 900)
        #endif
    }
}

enum OIDCResult {
    case success
    case failure(String)
}

#if os(iOS)
import UIKit

struct OIDCWebViewRepresentable: UIViewRepresentable {
    let baseURL: URL
    let onFinish: (OIDCResult) -> Void

    func makeCoordinator() -> OIDCWebCoordinator {
        OIDCWebCoordinator(baseURL: baseURL, onFinish: onFinish)
    }

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: baseURL.appendingPathComponent("api/auth/oidc/login")))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
#else
import AppKit

struct OIDCWebViewRepresentable: NSViewRepresentable {
    let baseURL: URL
    let onFinish: (OIDCResult) -> Void

    func makeCoordinator() -> OIDCWebCoordinator {
        OIDCWebCoordinator(baseURL: baseURL, onFinish: onFinish)
    }

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: baseURL.appendingPathComponent("api/auth/oidc/login")))
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
#endif

final class OIDCWebCoordinator: NSObject, WKNavigationDelegate {
    let baseURL: URL
    let onFinish: (OIDCResult) -> Void
    private var finished = false

    init(baseURL: URL, onFinish: @escaping (OIDCResult) -> Void) {
        self.baseURL = baseURL
        self.onFinish = onFinish
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !finished, let url = webView.url, url.host == baseURL.host else { return }

        if url.path == "/login.html" {
            let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
            if let error = comps?.queryItems?.first(where: { $0.name == "sso_error" })?.value {
                finished = true
                onFinish(.failure(error))
            }
            return
        }

        if url.path == "/" || url.path == "/index.html" {
            finished = true
            syncCookies(from: webView) { [onFinish] gotSession in
                if gotSession {
                    onFinish(.success)
                } else {
                    // Der `/` wurde erreicht (SSO lief also durch), aber es kam
                    // KEIN goldfish_session-Cookie im WKWebView-Store an — dann
                    // würde die App nach dem Schließen des Sheets sofort wieder
                    // auf dem Login landen. Klar melden statt still zu scheitern.
                    onFinish(.failure("SSO-Anmeldung lief durch, aber es kam kein Sitzungs-Cookie an. Bitte erneut versuchen."))
                }
            }
        }
    }

    /// WKWebView hat einen EIGENEN Cookie-Jar, getrennt von `HTTPCookieStorage.shared`
    /// (das `URLSession` nutzt) — der frisch gesetzte `goldfish_session`-Cookie muss
    /// hinüberkopiert werden, damit die normalen API-Requests ihn tragen.
    ///
    /// Wichtig: das `Set-Cookie` aus der OIDC-Callback-Weiterleitung ist beim
    /// `didFinish` für `/` oft NOCH NICHT im WKWebView-Cookie-Store gelandet
    /// (bekanntes WKWebView-Timing) — ein einmaliges `getAllCookies` direkt hier
    /// verfehlt es dann und die SSO-Anmeldung "funktioniert nicht". Deshalb bis zu
    /// ~2,5 s (8 × 0,3 s) pollen, bis der Session-Cookie auftaucht.
    private func syncCookies(from webView: WKWebView, attempt: Int = 0, completion: @escaping (_ gotSession: Bool) -> Void) {
        let host = baseURL.host ?? ""
        let store = webView.configuration.websiteDataStore.httpCookieStore
        store.getAllCookies { cookies in
            let matching = cookies.filter { cookie in
                let bare = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
                return host == bare || host.hasSuffix("." + bare) || host.contains(bare) || bare.contains(host)
            }
            let hasSession = matching.contains { $0.name == "goldfish_session" && !$0.value.isEmpty }
            if hasSession || attempt >= 8 {
                for cookie in matching { HTTPCookieStorage.shared.setCookie(cookie) }
                DispatchQueue.main.async { completion(hasSession) }
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    self.syncCookies(from: webView, attempt: attempt + 1, completion: completion)
                }
            }
        }
    }
}
