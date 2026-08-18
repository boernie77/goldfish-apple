import SwiftUI
import GoldfishCore

/// User-Anfrage 2026-08-19: Downloads sollen wie eine normale Bibliothek aussehen (Kacheln
/// mit Poster/Titel) und direkt daraus abspielbar sein, statt nur einer schlichten Liste mit
/// Fortschrittsbalken. `DownloadRecord.cachedItem` (JSON-Snapshot vom Download-Zeitpunkt) macht
/// das möglich, ohne dass ein Netzwerk-Request nötig ist — wichtig, weil Downloads gerade FÜR
/// den Offline-Fall existieren.
struct DownloadsView: View {
    @EnvironmentObject var downloads: DownloadManager
    @EnvironmentObject var client: GoldfishClient

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 150), spacing: 12)]

    private var allRecords: [DownloadRecord] {
        downloads.records.values.sorted { $0.title < $1.title }
    }
    private var doneRecords: [DownloadRecord] { allRecords.filter { $0.state == .done } }
    private var inProgressRecords: [DownloadRecord] { allRecords.filter { $0.state == .downloading || $0.state == .queued } }
    private var failedRecords: [DownloadRecord] { allRecords.filter { $0.state == .failed } }

    /// Fertige Downloads mit einem gecachten `Item`-Snapshot — die Kachel-Ansicht. Downloads
    /// von vor diesem Feature (kein `itemData` gespeichert) fallen unten in `plainDoneRecords`.
    private var doneItems: [Item] { doneRecords.compactMap(\.cachedItem) }
    private var plainDoneRecords: [DownloadRecord] { doneRecords.filter { $0.cachedItem == nil } }

    var body: some View {
        NavigationStack {
            Group {
                if allRecords.isEmpty {
                    ContentUnavailableMessage(text: "Noch keine Downloads. Öffne ein Video und tippe auf Für offline speichern.")
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            if !doneItems.isEmpty {
                                LazyVGrid(columns: columns, spacing: 16) {
                                    ForEach(doneItems) { item in
                                        NavigationLink(destination: ItemDetailView(item: item, queue: doneItems)) {
                                            ItemCard(item: item)
                                                .frame(width: 150)
                                        }
                                        .buttonStyle(.plain)
                                        .focusableCompat(false)
                                        .contextMenu {
                                            Button(role: .destructive) {
                                                downloads.deleteDownload(itemId: item.id)
                                            } label: {
                                                Label("Download löschen", systemImage: "trash")
                                            }
                                        }
                                    }
                                }
                                .padding(.horizontal)
                            }

                            if !plainDoneRecords.isEmpty || !inProgressRecords.isEmpty || !failedRecords.isEmpty {
                                VStack(alignment: .leading, spacing: 8) {
                                    ForEach(plainDoneRecords + inProgressRecords + failedRecords) { record in
                                        DownloadRow(record: record)
                                    }
                                }
                                .padding(.horizontal)
                            }
                        }
                        .padding(.vertical)
                    }
                }
            }
            .navigationTitle("Downloads")
            // Real gap hit 2026-08-19: Downloads von VOR dem Kachel-Feature haben kein
            // gecachtes `itemData` und fielen deshalb dauerhaft in die alte Listen-Ansicht —
            // sah für den User aus, als hätte sich "nichts verändert". Holt bei vorhandener
            // Verbindung einmalig die fehlenden Snapshots nach, danach zeigen auch ältere
            // Downloads Kacheln (offline bleibt es weiterhin bei der Listen-Darstellung für
            // diese, kein Fehler, nur kein Nachholen möglich ohne Netz).
            .task {
                for record in plainDoneRecords {
                    if let item = try? await client.fetchItem(id: record.itemId) {
                        downloads.backfillItemData(itemId: record.itemId, item: item)
                    }
                }
            }
        }
    }
}

private struct DownloadRow: View {
    let record: DownloadRecord
    @EnvironmentObject var downloads: DownloadManager

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(record.title)
                switch record.state {
                case .downloading, .queued:
                    ProgressView(value: record.progress)
                case .done:
                    Text("Fertig heruntergeladen")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .failed:
                    Text(record.errorMessage.map { "Fehlgeschlagen: \($0)" } ?? "Fehlgeschlagen")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            Spacer()
            Button(role: .destructive) {
                downloads.deleteDownload(itemId: record.itemId)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
        }
    }
}
