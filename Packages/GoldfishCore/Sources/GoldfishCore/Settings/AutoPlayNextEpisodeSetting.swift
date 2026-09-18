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
/// **Pro Konto** gespeichert: der Key enthält den Benutzernamen, deshalb reines
/// `UserDefaults` mit benutzerabhängigem Key statt eines geräteweiten Keys wie
/// `LocalPlaybackSettings.bufferSeconds` (siehe dortiger Kommentar — das ist eine
/// reine Hardware-Tuning-Einstellung, hier ist es dagegen eine Nutzer-Vorliebe,
/// dieselbe Begründung wie bei `ShuffleScope`s Per-Username-Key).
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
}
