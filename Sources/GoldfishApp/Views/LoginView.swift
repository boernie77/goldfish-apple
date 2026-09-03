import SwiftUI
import GoldfishCore

struct LoginView: View {
    @EnvironmentObject var client: GoldfishClient

    @State private var serverURLString: String = ""
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var errorMessage: String?
    @State private var isLoading = false
    @State private var showingOIDC = false
    /// true → der SSO-WebView löscht vorher seine Authentik-Sitzung, sodass die
    /// Anmeldemaske erscheint und man ein anderes Konto wählen kann.
    @State private var oidcClearSession = false

    var body: some View {
        VStack(spacing: 16) {
            // User-Anfrage 2026-08-19: "auf der Anmeldeseite ist noch der falsche Goldfish
            // (ICON)" — das echte Marken-Artwork (GoldfishLogo.imageset, dasselbe wie im
            // RootView-Header) statt des rohen 🐠-System-Emojis, das hier noch als
            // Platzhalter aus einer früheren Runde stand.
            Image("GoldfishLogo")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 14))
            Text("Goldfish")
                .font(.largeTitle.bold())

            VStack(alignment: .leading, spacing: 12) {
                TextField("Server-Adresse (z. B. https://goldfish.example.com)", text: $serverURLString)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif
                    .autocorrectionDisabled()
                    #if !os(tvOS)
                    .textFieldStyle(.roundedBorder)
                    #endif

                TextField("Benutzername", text: $username)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                    // Ohne .textContentType erkennt das OS (und damit auch der
                    // Bitwarden-AutoFill-Provider / die QuickType-Leiste) diese
                    // Felder nicht als Login-Felder → keine Ausfüll-Vorschläge.
                    .textContentType(.username)
                    #if !os(tvOS)
                    .textFieldStyle(.roundedBorder)
                    #endif

                SecureField("Passwort", text: $password)
                    .textContentType(.password)
                    #if !os(tvOS)
                    .textFieldStyle(.roundedBorder)
                    #endif
            }
            .frame(maxWidth: 360)
            // User-Anfrage 2026-08-24: "die Freigabetaste soll den Anmeldevorgang auslösen,
            // sonst muss man extra mit der Maus klicken" — Enter/Return aus JEDEM der drei
            // Felder löst jetzt denselben Login-Task aus wie ein Klick auf "Anmelden".
            .onSubmit {
                guard !serverURLString.isEmpty, !username.isEmpty, !password.isEmpty, !isLoading else { return }
                Task { await login() }
            }

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }

            Button {
                Task { await login() }
            } label: {
                if isLoading {
                    ProgressView()
                } else {
                    Text("Anmelden")
                        .frame(maxWidth: 200)
                }
            }
            .buttonStyle(.borderedProminent)
            #if !os(tvOS)
            .keyboardShortcut(.defaultAction)
            #endif
            .disabled(serverURLString.isEmpty || username.isEmpty || password.isEmpty || isLoading)

            // SSO läuft über einen eingebetteten WKWebView — WebKit existiert nicht
            // auf tvOS, daher ist SSO dort komplett ausgeblendet (nur Benutzername/
            // Passwort, siehe auch OIDCLoginView.swift).
            #if !os(tvOS)
            Button {
                startOIDC(clearSession: false)
            } label: {
                Text("Mit SSO anmelden (Authentik)")
                    .frame(maxWidth: 200)
            }
            .buttonStyle(.bordered)
            .disabled(serverURLString.isEmpty || isLoading)

            // Erzwingt die Authentik-Anmeldemaske (WebView-Sitzung wird vorher
            // geleert) — für den Wechsel zwischen z. B. Admin- und Benutzerkonto.
            Button {
                startOIDC(clearSession: true)
            } label: {
                Text("Mit anderem Konto anmelden")
                    .font(.callout)
                    .frame(maxWidth: 200)
            }
            .buttonStyle(.borderless)
            .disabled(serverURLString.isEmpty || isLoading)
            #endif
        }
        .padding(40)
        // iPad-Fix 2026-09-03: ohne explizites Full-Screen-Frame hängt der Inhalt
        // (nur so groß wie sein Inhalt) irgendwo im oberen Drittel des riesigen
        // iPad-Bildschirms statt sauber zentriert zu sein — auf dem iPhone fiel
        // das nicht auf, weil dort kaum Platz drumherum übrig blieb. maxWidth
        // deckelt die Formularbreite (verhindert ausuferndes Layout auf großen
        // iPads), das äußere .frame zentriert das Ganze auf jeder Bildschirmgröße.
        .frame(maxWidth: 480)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            if serverURLString.isEmpty, let saved = client.baseURL?.absoluteString {
                serverURLString = saved
            }
        }
        #if !os(tvOS)
        .sheet(isPresented: $showingOIDC) {
            if let url = client.baseURL {
                OIDCLoginView(baseURL: url, clearSessionFirst: oidcClearSession) {
                    Task { await refreshAfterOIDC() }
                } onFailure: { message in
                    errorMessage = message
                }
            }
        }
        #endif
    }

    private func startOIDC(clearSession: Bool) {
        errorMessage = nil
        guard let url = URL(string: serverURLString), url.scheme != nil else {
            errorMessage = "Bitte eine vollständige URL mit https:// eingeben."
            return
        }
        client.configure(serverURL: url)
        oidcClearSession = clearSession
        showingOIDC = true
    }

    private func refreshAfterOIDC() async {
        // Nach dem Cookie-Sync aus dem WKWebView kann `URLSession` den frisch
        // gesetzten Cookie minimal verzögert übernehmen — ein paar Mal kurz
        // nachfassen, bevor wir aufgeben.
        for attempt in 0..<5 {
            if let status = try? await client.authStatus(), status.loggedIn {
                client.applySessionStatus(status)
                return
            }
            if attempt < 4 { try? await Task.sleep(nanoseconds: 400_000_000) }
        }
        // Auch ein negatives Endergebnis anwenden, damit die UI nicht im
        // Unklaren hängt, und dem User sagen, was Sache ist.
        if let status = try? await client.authStatus() {
            client.applySessionStatus(status)
        }
        if !client.isLoggedIn {
            errorMessage = "SSO-Anmeldung war erfolgreich, aber die App konnte die Sitzung nicht übernehmen. Bitte die SSO-Anmeldung noch einmal starten."
        }
    }

    private func login() async {
        errorMessage = nil
        guard let url = URL(string: serverURLString), url.scheme != nil else {
            errorMessage = "Bitte eine vollständige URL mit https:// eingeben."
            return
        }
        isLoading = true
        defer { isLoading = false }
        client.configure(serverURL: url)
        do {
            try await client.login(username: username, password: password)
        } catch {
            // User-Anfrage 2026-08-19: "Kann ich offline den Benutzer wechseln? [...] Mit
            // Passwortabfrage wäre mir aber lieber" — NUR bei einem echten Verbindungsproblem
            // (kein Server erreichbar) auf den lokal gespeicherten Passwort-Verifier
            // zurückfallen, nicht bei jedem beliebigen Fehler (z.B. falsches Passwort, das der
            // Server selbst schon klar zurückgemeldet hat).
            if GoldfishClient.isConnectivityError(error) {
                switch client.loginOffline(username: username, password: password) {
                case .success:
                    errorMessage = nil
                    return
                case .wrongPassword:
                    errorMessage = "Falsches Passwort."
                case .noRememberedSession:
                    errorMessage = "Keine Verbindung zum Server — für dieses Konto ist noch kein Offline-Login gespeichert (einmal online anmelden, dann geht's auch offline)."
                case .sessionExpired:
                    errorMessage = "Offline-Anmeldung ist abgelaufen (länger als 14 Tage kein Online-Login) — bitte mit Internetverbindung erneut anmelden."
                }
            } else {
                errorMessage = error.localizedDescription
            }
        }
    }
}
