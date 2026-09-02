import SwiftUI

/// Dark-Mode-Wahlschalter (User-Anfrage 2026-09-02, Settings-Menü). Geräteweite
/// `@AppStorage`-Einstellung statt eines account-gescoped Settings-Objekts —
/// gilt genau wie das Erscheinungsbild jeder anderen App unabhängig vom
/// eingeloggten Goldfish-Benutzer.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    static let storageKey = "goldfish.appearance"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Hell"
        case .dark: return "Dunkel"
        }
    }

    /// `nil` lässt SwiftUI dem System-Erscheinungsbild folgen.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}
