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
                    .textFieldStyle(.roundedBorder)

                TextField("Benutzername", text: $username)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)

                SecureField("Passwort", text: $password)
                    .textFieldStyle(.roundedBorder)
            }
            .frame(maxWidth: 360)

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
            .disabled(serverURLString.isEmpty || username.isEmpty || password.isEmpty || isLoading)

            Button {
                startOIDC()
            } label: {
                Text("Mit SSO anmelden (Authentik)")
                    .frame(maxWidth: 200)
            }
            .buttonStyle(.bordered)
            .disabled(serverURLString.isEmpty || isLoading)
        }
        .padding(40)
        .onAppear {
            if serverURLString.isEmpty, let saved = client.baseURL?.absoluteString {
                serverURLString = saved
            }
        }
        .sheet(isPresented: $showingOIDC) {
            if let url = client.baseURL {
                OIDCLoginView(baseURL: url) {
                    Task { await refreshAfterOIDC() }
                } onFailure: { message in
                    errorMessage = message
                }
            }
        }
    }

    private func startOIDC() {
        errorMessage = nil
        guard let url = URL(string: serverURLString), url.scheme != nil else {
            errorMessage = "Bitte eine vollständige URL mit https:// eingeben."
            return
        }
        client.configure(serverURL: url)
        showingOIDC = true
    }

    private func refreshAfterOIDC() async {
        if let status = try? await client.authStatus() {
            client.applySessionStatus(status)
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
