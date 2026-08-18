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
            syncCookies(from: webView) { [onFinish] in
                onFinish(.success)
            }
        }
    }

    /// WKWebView keeps its own cookie jar, separate from URLSession's shared storage —
    /// copy the freshly-set session cookie over so subsequent API requests carry it.
    private func syncCookies(from webView: WKWebView, completion: @escaping () -> Void) {
        let host = baseURL.host ?? ""
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
            for cookie in cookies where cookie.domain.contains(host) {
                HTTPCookieStorage.shared.setCookie(cookie)
            }
            DispatchQueue.main.async { completion() }
        }
    }
}
