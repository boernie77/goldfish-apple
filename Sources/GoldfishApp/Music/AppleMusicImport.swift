#if os(iOS)
import GoldfishCore
import MediaPlayer
import SwiftUI

/// Playlists aus der Apple-Musik-App (nur lokal auf dem Gerät liegende eigene Titel) in
/// Goldfish-Musik-Playlists übernehmen (User-Wunsch 2026-10-31). Die Titel werden über
/// Titel + Künstler (Rückfall: Titel + Album, dann eindeutiger Titel) mit den Titeln
/// der Goldfish-Bibliothek abgeglichen; was nicht gefunden wird, steht am Ende in einer Liste.
struct AppleMusicImportView: View {
    let library: Library

    @EnvironmentObject var client: GoldfishClient
    @Environment(\.dismiss) private var dismiss

    private struct LocalTrack { let title: String; let artist: String; let album: String }
    private struct LocalList: Identifiable {
        let id: UInt64
        let name: String
        let tracks: [LocalTrack]
    }
    private struct ImportResult: Identifiable {
        let id = UUID()
        let name: String
        let total: Int
        let added: Int
        let missing: [String]
    }

    @State private var authorized: Bool?
    @State private var lists: [LocalList] = []
    @State private var selected: Set<UInt64> = []
    @State private var running = false
    @State private var progress = ""
    @State private var results: [ImportResult] = []
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if !results.isEmpty {
                resultList
            } else if running {
                VStack(spacing: 12) {
                    ProgressView()
                    Text(progress).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .padding()
            } else if authorized == nil {
                ProgressView()
            } else if authorized == false {
                ContentUnavailableMessage(text: "Kein Zugriff auf die Apple-Musik-Mediathek. Erlaube ihn in den iOS-Einstellungen unter Goldfish → Medien & Apple Music.")
            } else if lists.isEmpty {
                ContentUnavailableMessage(text: "Keine Playlists mit Titeln auf diesem Gerät gefunden.")
            } else {
                List(lists) { list in
                    Button {
                        if selected.contains(list.id) { selected.remove(list.id) } else { selected.insert(list.id) }
                    } label: {
                        HStack {
                            Image(systemName: selected.contains(list.id) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selected.contains(list.id) ? Color.accentColor : .secondary)
                            VStack(alignment: .leading) {
                                Text(list.name)
                                Text("\(list.tracks.count) Titel").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Aus Apple Musik")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(results.isEmpty ? "Abbrechen" : "Fertig") { dismiss() }
                    .disabled(running)
            }
            if results.isEmpty, authorized == true, !lists.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button("Importieren (\(selected.count))") { Task { await runImport() } }
                        .disabled(selected.isEmpty || running)
                }
            }
        }
        .alert("Fehler", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .task { await loadLocalPlaylists() }
    }

    private var resultList: some View {
        List(results) { r in
            VStack(alignment: .leading, spacing: 4) {
                Text(r.name).fontWeight(.semibold)
                Text("\(r.added) von \(r.total) Titeln übernommen").font(.caption).foregroundStyle(.secondary)
                if !r.missing.isEmpty {
                    DisclosureGroup("Nicht gefunden (\(r.missing.count))") {
                        ForEach(r.missing, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                    }
                    .font(.caption)
                }
            }
            .padding(.vertical, 2)
        }
        .listStyle(.plain)
    }

    private func loadLocalPlaylists() async {
        let status: MPMediaLibraryAuthorizationStatus
        if MPMediaLibrary.authorizationStatus() == .notDetermined {
            status = await withCheckedContinuation { cont in
                MPMediaLibrary.requestAuthorization { cont.resume(returning: $0) }
            }
        } else {
            status = MPMediaLibrary.authorizationStatus()
        }
        guard status == .authorized else { authorized = false; return }
        let collections = MPMediaQuery.playlists().collections ?? []
        lists = collections.compactMap { c -> LocalList? in
            guard let pl = c as? MPMediaPlaylist else { return nil }
            let tracks = pl.items.map {
                LocalTrack(title: $0.title ?? "", artist: $0.artist ?? "", album: $0.albumTitle ?? "")
            }
            guard !tracks.isEmpty else { return nil }
            return LocalList(id: pl.persistentID, name: pl.name ?? "Playlist", tracks: tracks)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        authorized = true
    }

    private static func norm(_ s: String) -> String {
        let folded = s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        return String(folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    private func runImport() async {
        running = true
        defer { running = false }
        progress = "Lade Titel der Goldfish-Bibliothek …"
        let goldfish: [Item]
        do {
            goldfish = try await client.fetchItems(libraryId: library.id).items
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        var byTitleArtist: [String: [Item]] = [:]
        var byTitleAlbum: [String: [Item]] = [:]
        var byTitle: [String: [Item]] = [:]
        for it in goldfish {
            let t = Self.norm(it.displayTitle)
            byTitleArtist["\(t)|\(Self.norm(it.artist ?? ""))", default: []].append(it)
            byTitleAlbum["\(t)|\(Self.norm(it.album ?? ""))", default: []].append(it)
            byTitle[t, default: []].append(it)
        }
        let existing = ((try? await client.fetchPlaylists(kind: "music")) ?? []).map(\.name)
        var out: [ImportResult] = []
        for list in lists where selected.contains(list.id) {
            progress = "„\(list.name)“ wird übertragen …"
            var matched: [Item] = []
            var seen = Set<Int64>()
            var missing: [String] = []
            for tr in list.tracks {
                let t = Self.norm(tr.title)
                let hit = byTitleArtist["\(t)|\(Self.norm(tr.artist))"]?.first
                    ?? byTitleAlbum["\(t)|\(Self.norm(tr.album))"]?.first
                    ?? ({ () -> Item? in
                        let c = byTitle[t] ?? []
                        return c.count == 1 ? c[0] : nil
                    })()
                if let hit {
                    if seen.insert(hit.id).inserted { matched.append(hit) }
                } else {
                    missing.append([tr.artist, tr.title].filter { !$0.isEmpty }.joined(separator: " – "))
                }
            }
            guard !matched.isEmpty else {
                out.append(ImportResult(name: list.name, total: list.tracks.count, added: 0, missing: missing))
                continue
            }
            let name = existing.contains(list.name) ? "\(list.name) (Apple Musik)" : list.name
            do {
                let pl = try await client.createPlaylist(name: name, kind: "music")
                var added = 0
                for (i, it) in matched.enumerated() {
                    progress = "„\(list.name)“: \(i + 1) von \(matched.count)"
                    if (try? await client.addToPlaylist(playlistId: pl.id, itemId: it.id)) == true { added += 1 }
                }
                out.append(ImportResult(name: name, total: list.tracks.count, added: added, missing: missing))
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        results = out
    }
}
#endif
