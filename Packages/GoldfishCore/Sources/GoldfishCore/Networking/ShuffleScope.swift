import Foundation
#if canImport(Combine)
import Combine
#endif

/// One chosen scope entry for the global "Zufällig abspielen" shuffle — a whole library
/// (`folder == ""`) or a specific subfolder within one, recursive (matches the server's
/// `ItemFilter.Folders`/`FolderSelector`, CLAUDE.md "Ordner-Scoping für Shuffle"). Mirrors
/// the Browser's `state.shuffleFolders`/`#shuffleScopeDialog` (User-Anfrage 2026-08-19:
/// "auch Unterordner … auswählen können, sowie diese auch in den Bibliotheken angezeigt
/// werden" — i.e. the same folder tree used for normal browsing, not a separate concept).
public struct ShuffleFolderSelection: Codable, Hashable, Identifiable {
    public let libraryId: Int64
    public let libraryName: String
    /// Full relative path (server convention, see `Folder.Name` / `FolderTile.name`) — empty
    /// string selects the whole library.
    public let folder: String

    public init(libraryId: Int64, libraryName: String, folder: String) {
        self.libraryId = libraryId
        self.libraryName = libraryName
        self.folder = folder
    }

    public var id: String { "\(libraryId):\(folder)" }

    public var displayLabel: String {
        folder.isEmpty ? libraryName : "\(libraryName) / \(folder.components(separatedBy: "/").last ?? folder)"
    }
}

/// Persisted scope for the global "Zufällig abspielen" shuffle in `LibrariesView`. Local
/// libraries aren't part of this — they already have their own, separate per-library shuffle
/// (`LocalLibraryItemsView`'s 🔀 button), matching the Browser's app, which also has no
/// concept of local libraries at all.
@MainActor
public final class ShuffleScope: ObservableObject {
    public static let shared = ShuffleScope()

    /// Empty = "alle Bibliotheken" (kein Scoping) — same convention as the Browser's
    /// `state.shuffleFolders`, where an empty selection falls back to the broader default.
    ///
    /// Real bug hit 2026-08-19 (same class as `LocalLibraryManager`/`DownloadManager`, found
    /// right after fixing those): this was a SINGLE UserDefaults key shared by every account
    /// on the Mac — one user's folder/library scope silently showed up (and applied!) for
    /// every other user too, including folders from libraries that user's server ACL doesn't
    /// even grant them access to. Fixed by keying storage per username instead of a shared
    /// merge like the other two managers — scope selections are a pure local UI preference,
    /// not data that needs to survive across accounts, so full separation (not "unclaimed =
    /// visible to all") is both simpler and correct here.
    @Published public var selections: [ShuffleFolderSelection] {
        didSet {
            guard let user = currentUsername() else { return }
            if let data = try? JSONEncoder().encode(selections) {
                UserDefaults.standard.set(data, forKey: Self.key(for: user))
            }
        }
    }

    public var isScoped: Bool { !selections.isEmpty }

    private func currentUsername() -> String? { GoldfishClient.shared.currentUsername }

    // "v2" — replaces the earlier library-only `Set<Int64>` scheme (2026-08-19, same day)
    // once folder-level selection was added; old key intentionally abandoned rather than
    // migrated, the previous scheme only shipped for a few hours and never widely used.
    private static func key(for user: String) -> String { "goldfish.shuffleScope.selections.v2.\(user)" }

    private init() {
        selections = []
        load()
    }

    /// Call when the logged-in account changes (login/logout/switch) — reloads the scope for
    /// the new user instead of leaving the previous user's selections active. `RootView` calls
    /// this on every `client.currentUsername` change, same as the other two managers.
    public func userDidChange() {
        load()
    }

    private func load() {
        guard let user = currentUsername(),
              let data = UserDefaults.standard.data(forKey: Self.key(for: user)),
              let decoded = try? JSONDecoder().decode([ShuffleFolderSelection].self, from: data) else {
            selections = []
            return
        }
        selections = decoded
    }

    public func isSelected(libraryId: Int64, folder: String) -> Bool {
        selections.contains { $0.libraryId == libraryId && $0.folder == folder }
    }

    public func toggle(_ selection: ShuffleFolderSelection) {
        if let idx = selections.firstIndex(where: { $0.id == selection.id }) {
            selections.remove(at: idx)
        } else {
            selections.append(selection)
        }
    }

    public func remove(_ selection: ShuffleFolderSelection) {
        selections.removeAll { $0.id == selection.id }
    }

    public func clear() { selections = [] }
}
