#if os(macOS)
import SwiftUI

/// Wiederverwendbares Favoriten-Herz für Tracks UND Alben (User-Wunsch
/// 2026-09-11: "was haben andere Musikplayer" → Favoriten fehlten in der
/// Mac-App komplett, obwohl der Server sie längst unterstützt — Browser hat
/// sie schon lange). Verwaltet den Anzeige-Zustand selbst (optimistisches
/// Toggle) statt eine Bindung auf `Item`/`MusicAlbum` zu verlangen — beide
/// Modelle sind Value-Types mit `let favorite`, keine Mutation von außen
/// möglich (mirrors `favorite`-Handling bei Video-Items im Browser: lokal
/// togglen, Server-Call im Hintergrund, kein Reload nötig).
struct MusicFavoriteButton: View {
    @State private var isFavorite: Bool
    let toggle: (Bool) async -> Void

    init(isFavorite: Bool, toggle: @escaping (Bool) async -> Void) {
        _isFavorite = State(initialValue: isFavorite)
        self.toggle = toggle
    }

    var body: some View {
        Button {
            isFavorite.toggle()
            let newValue = isFavorite
            Task { await toggle(newValue) }
        } label: {
            Image(systemName: isFavorite ? "heart.fill" : "heart")
                .foregroundStyle(isFavorite ? .red : .secondary)
        }
        .buttonStyle(.plain)
        .help(isFavorite ? "Aus Favoriten entfernen" : "Zu Favoriten hinzufügen")
    }
}
#endif
