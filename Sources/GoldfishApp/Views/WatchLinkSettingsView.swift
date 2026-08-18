import SwiftUI
import GoldfishCore

/// Gesehen-Sync zwischen zwei Usern (User-Anfrage 2026-08-19). Server-seitige
/// Write-Time-Propagation (siehe Videoplayer `internal/api/watch_links.go`) —
/// diese View ist nur der Picker/Bestätigungs-Dialog, die eigentliche Sync-
/// Logik läuft komplett auf dem Server und wirkt dadurch für ALLE Clients
/// (Browser, Android, Mac), nicht nur für diese App.
struct WatchLinkSettingsView: View {
    @EnvironmentObject var client: GoldfishClient
    @Binding var watchLinks: [WatchLink]

    @State private var otherUsers: [OtherUser] = []
    @State private var selectedUsername: String = ""
    @State private var isBusy = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            if !watchLinks.isEmpty {
                Section("Verknüpfungen") {
                    ForEach(watchLinks) { link in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(link.partnerName)
                                Text(statusLabel(link.status))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if link.status == "pending_incoming" {
                                Button("Bestätigen") {
                                    Task { await confirm(link) }
                                }
                                .buttonStyle(.borderedProminent)
                            }
                            Button(link.status == "pending_incoming" ? "Ablehnen" : "Trennen", role: .destructive) {
                                Task { await unlink(link) }
                            }
                        }
                    }
                }
            }

            Section {
                if otherUsers.isEmpty {
                    Text("Keine weiteren Benutzer vorhanden.")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Benutzer", selection: $selectedUsername) {
                        Text("Bitte wählen").tag("")
                        ForEach(otherUsers) { user in
                            Text(user.username).tag(user.username)
                        }
                    }
                    Button("Anfrage senden") {
                        Task { await sendRequest() }
                    }
                    .disabled(selectedUsername.isEmpty || isBusy)
                }
                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Neue Verknüpfung anfragen")
            } footer: {
                Text("Der andere Benutzer muss die Anfrage in seinen eigenen Einstellungen bestätigen, bevor die Synchronisierung startet.")
            }
        }
        .formStyle(.grouped)
        // Fix 2026-08-19 (User: "Textsprung nach Auswahl des Benutzers... das habe ich
        // oft!"): ohne explizites Frame bricht das Layout bei jedem Re-Render durch
        // async State-Updates (hier: `reload()` setzt watchLinks/otherUsers) — der Form
        // rendert erst zentriert/schmal, springt dann auf einen linksbündigen, teils
        // abgeschnittenen Layout-Zustand um. `SettingsView`s eigenes Form hat dasselbe
        // Frame (Zeile ~412) und zeigt den Bug dort nicht — hier fehlte es einfach.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Gesehen-Sync")
        .task { await reload() }
    }

    private func statusLabel(_ status: String) -> String {
        switch status {
        case "accepted": return "Aktiv"
        case "pending_incoming": return "Wartet auf deine Bestätigung"
        case "pending_outgoing": return "Warte auf Bestätigung"
        default: return status
        }
    }

    private func reload() async {
        async let links = client.fetchWatchLinks()
        async let users = client.fetchOtherUsers()
        watchLinks = (try? await links) ?? []
        otherUsers = (try? await users) ?? []
    }

    private func sendRequest() async {
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            try await client.requestWatchLink(username: selectedUsername)
            selectedUsername = ""
            await reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func confirm(_ link: WatchLink) async {
        errorMessage = nil
        do {
            try await client.confirmWatchLink(partnerId: link.partnerId)
            await reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func unlink(_ link: WatchLink) async {
        errorMessage = nil
        do {
            try await client.unlinkWatchLink(partnerId: link.partnerId)
            await reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
