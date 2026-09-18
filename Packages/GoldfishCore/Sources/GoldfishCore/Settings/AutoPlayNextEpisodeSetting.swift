import Foundation

/// User-Wunsch 2026-09-18: „Nächste Folge automatisch starten" samt Übernahme der
/// zuletzt gewählten Auflösung.
///
/// Wirkt in `PlayerView` am Ende JEDER Serienfolge: ist die Option an und gibt es
/// eine weitere Folge DERSELBEN Serie, erscheint ein Hinweis-Overlay mit
/// 10-Sekunden-Countdown („Jetzt abspielen" / „Abbrechen"). Läuft der Countdown ab
/// oder wird „Jetzt abspielen" gedrückt, startet die nächste Folge im SELBEN Player
/// — mit demselben Auflösungs-/Transcode-Profil wie die vorige Folge. Ist die Option
/// AUS, ändert sich das Verhalten nicht (kein Overlay, keine zusätzliche Anfrage).
///
/// **Pro Konto** — der maßgebliche Wert liegt aber auf dem SERVER
/// (`GET/PUT /api/playback/preferences`, Server seit v1.4.13): nur so gilt die
/// Einstellung auch in Browser, Android-, Fire-TV- und Linux-App. Die
/// `UserDefaults` hier sind die lokale KOPIE davon, mit Per-Username-Key, damit
/// mehrere Konten auf demselben Gerät getrennt bleiben. Gelesen wird sie (a) vom
/// Ende-Handler des Players, der nicht auf einen Netz-Abruf warten darf, und
/// (b) offline. Gespiegelt wird sie beim Öffnen der Einstellungen und beim
/// Start einer Wiedergabe.
///
/// Standard AUS — `UserDefaults.bool(forKey:)` liefert für einen nie gesetzten Key
/// `false`, genau die gewünschte Vorgabe. Kein eigener Default-Wert nötig.
public enum AutoPlayNextEpisodeSetting {
    public static let keyPrefix = "goldfish.autoPlayNextEpisode."

    /// Bewusst NICHT über `GoldfishClient.shared.currentUsername` (`@MainActor`):
    /// dieser Wert hier ist damit von jeder Isolation aus lesbar (PlayerView-
    /// Methoden sind nicht @MainActor-isoliert) — gelesen wird exakt derselbe
    /// Key, den `GoldfishClient.init`/`login`/`logout` schreiben.
    private static var currentUsername: String? {
        UserDefaults.standard.string(forKey: "goldfish.username")
    }

    private static func key(for user: String) -> String { "\(keyPrefix)\(user)" }

    /// `false` ohne eingeloggten Benutzer: ohne Konto kann der Schalter gar nicht
    /// gesetzt worden sein (die Einstellungen sind nur eingeloggt erreichbar), und
    /// ein gemeinsamer Fallback-Key würde die gewünschte Kontentrennung aufheben.
    public static var isEnabled: Bool {
        guard let user = currentUsername else { return false }
        return UserDefaults.standard.bool(forKey: key(for: user))
    }

    public static func setEnabled(_ enabled: Bool) {
        guard let user = currentUsername else { return }
        UserDefaults.standard.set(enabled, forKey: key(for: user))
    }

    /// Übernimmt den Serverwert in die lokale Kopie (Pro Konto).
    ///
    /// Aufrufer: `SettingsView` (beim Öffnen der Einstellungen und nach jedem
    /// Umschalten) und `PlayerView` (beim Start einer Wiedergabe) — so wirkt
    /// eine im Browser oder auf einem anderen Gerät getroffene Wahl auch hier.
    @discardableResult
    public static func refreshFromServer(using client: GoldfishClient) async -> Bool? {
        guard let prefs = try? await client.fetchPlaybackPreferences() else { return nil }
        guard let enabled = prefs.autoplayNext else { return nil }
        setEnabled(enabled)
        return enabled
    }
}
