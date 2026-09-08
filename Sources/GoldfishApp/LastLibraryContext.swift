import Foundation
#if canImport(Combine)
import Combine
#endif

/// Merkt sich, in welcher Bibliothek der User zuletzt unterwegs war — rein transient
/// (kein UserDefaults, keine Persistenz über App-Neustarts hinweg nötig, anders als
/// `ShuffleScope`). Wird von `ItemGridView.onAppear` bei JEDER Instanz aktualisiert
/// (Root UND Unterordner tragen dieselbe `library`), von `SearchTabView` (tvOS) gelesen,
/// um die Suche auf genau diese Bibliothek zu scopen statt global über alle zu suchen —
/// User-Wunsch 2026-09-08: "die Suche soll sich nur auf die Bibliothek beziehen, von
/// woraus sie geöffnet wurde".
@MainActor
final class LastLibraryContext: ObservableObject {
    static let shared = LastLibraryContext()

    @Published var libraryId: Int64?
    @Published var libraryName: String?

    private init() {}

    func update(libraryId: Int64, libraryName: String) {
        self.libraryId = libraryId
        self.libraryName = libraryName
    }

    /// `RootView` ruft das beim Wechsel auf den Downloads-/Einstellungen-Tab NICHT auf —
    /// nur beim Logout, damit nach einem Kontowechsel keine fremde Bibliotheks-ID
    /// hängen bleibt (gleiche Vorsicht wie bei `ShuffleScope.userDidChange`).
    func clear() {
        libraryId = nil
        libraryName = nil
    }
}
