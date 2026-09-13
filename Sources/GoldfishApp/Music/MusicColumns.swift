#if os(macOS)
import SwiftUI

/// Musik-Listenspalten (User-Wunsch 2026-09-14): "Zuletzt abgespielt"/
/// "Wiedergaben"/"Hinzugefügt" als Spalten für Alben UND Titel, dazu ein
/// Dropdown zum Ein-/Ausblenden — analog zum Browser (`music.js
/// MUSIC_LIST_CONTEXTS`), aber bewusst NUR auf macOS gebaut (User-Vorgabe:
/// "Nicht für iOS und Apple TV"). Diese Datei bündelt die drei
/// wiederverwendeten Bausteine (Spalten-Enum, Sichtbarkeits-Speicher,
/// "☰ Spalten"-Menü), damit die Album-Übersicht, "Alle Titel" und die
/// Album-Detail-Trackliste dieselbe Konvention teilen statt sie dreimal
/// unabhängig zu erfinden.
enum MusicColumn: String, CaseIterable {
    case artist, album, genre, year, duration, count, lastPlayed, playCount, added

    var label: String {
        switch self {
        case .artist: return "Künstler"
        case .album: return "Album"
        case .genre: return "Genre"
        case .year: return "Jahr"
        case .duration: return "Dauer"
        case .count: return "Titel"
        case .lastPlayed: return "Zuletzt gehört"
        case .playCount: return "Wiedergaben"
        case .added: return "Hinzugefügt"
        }
    }
}

/// Persistiert, welche `MusicColumn`s pro Kontext ("albums"/"allTracks"/
/// "albumTracks") sichtbar sind — als explizite Allowlist in UserDefaults
/// (Komma-getrennte Rohwerte), analog zum Browser-`localStorage`-Muster.
/// Bewusst eine ALLOWLIST (nicht Denylist): eine künftig neu hinzugefügte
/// Spalte taucht dadurch nie automatisch ungefragt bei jedem auf, sondern
/// bleibt unsichtbar, bis der User sie im Menü aktiv anhakt.
enum MusicColumnVisibility {
    private static func key(_ context: String) -> String { "musicColumnsVisible.\(context)" }

    static func visible(for context: String, default defaultVisible: Set<MusicColumn>) -> Set<MusicColumn> {
        guard let raw = UserDefaults.standard.string(forKey: key(context)) else { return defaultVisible }
        let saved = Set(raw.split(separator: ",").compactMap { MusicColumn(rawValue: String($0)) })
        return saved
    }

    static func setVisible(_ columns: Set<MusicColumn>, for context: String) {
        let raw = columns.map(\.rawValue).joined(separator: ",")
        UserDefaults.standard.set(raw, forKey: key(context))
    }
}

/// Wiederverwendbarer Menü-Inhalt (als `Toggle` pro Spalte) — vom Aufrufer in
/// ein `Menu("☰ Spalten") { MusicColumnsMenuContent(...) }` eingebettet.
/// SwiftUI's `Menu` rendert `Toggle`s nativ als ankreuzbare Menüpunkte, kein
/// eigenes Popover/Checkbox-UI nötig (anders als im Browser, wo es dafür
/// extra HTML/CSS/JS brauchte).
struct MusicColumnsMenuContent: View {
    let context: String
    let available: [MusicColumn]
    let defaultVisible: Set<MusicColumn>
    @Binding var refreshToken: Bool

    var body: some View {
        ForEach(available, id: \.self) { column in
            Toggle(column.label, isOn: Binding(
                get: { MusicColumnVisibility.visible(for: context, default: defaultVisible).contains(column) },
                set: { isOn in
                    var current = MusicColumnVisibility.visible(for: context, default: defaultVisible)
                    if isOn { current.insert(column) } else { current.remove(column) }
                    MusicColumnVisibility.setVisible(current, for: context)
                    refreshToken.toggle()
                }
            ))
        }
    }
}
#endif
