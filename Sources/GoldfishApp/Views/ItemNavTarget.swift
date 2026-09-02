import GoldfishCore

/// Wertbasiertes Navigationsziel für `ItemDetailView` (Item + optionale Queue für
/// Vor/Zurück im Player). Ersetzt `NavigationLink(destination: ItemDetailView(...))`
/// überall dort, wo `queue` gebraucht wird — die ältere, View-basierte Variante hängt
/// den Push NICHT an einen von außen gebundenen `NavigationPath`, wodurch
/// `MainTabView`s "bin ich an der Tab-Wurzel"-Erkennung (siehe dortiger Kommentar)
/// einen Push nie bemerkte und der Goldfish-Kopfbereich die native Zurück-Leiste
/// verdeckt hielt (real reported 2026-09-02, "wenn ich wo reingehe, komme ich
/// nirgends zurück"). Wo keine Queue nötig ist, bleibt das schon vorhandene
/// `.navigationDestination(for: Item.self)` in Gebrauch.
struct ItemNavTarget: Hashable {
    let item: Item
    let queue: [Item]

    init(item: Item, queue: [Item] = []) {
        self.item = item
        self.queue = queue
    }
}

/// Wertbasiertes Navigationsziel für `PersonItemsView` (Schauspieler-Klick in
/// `CastStripView`), aus demselben Grund wie `ItemNavTarget` — ersetzt
/// `NavigationLink(destination: PersonItemsView(...))`.
struct PersonRef: Hashable {
    let tmdbId: Int64
    let name: String
}
