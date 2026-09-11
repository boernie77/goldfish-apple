#if os(macOS)
import GoldfishCore
import SwiftUI

/// Kompaktes Download-Icon für eine einzelne Zeile (Track-Liste in Album/Playlist/
/// Offline-Ansicht) — Kurzform von `DownloadButtonRow` (Detail-Dialog-Variante, zu
/// breit für eine Listenzeile). Nutzt dieselbe `DownloadManager`-Infrastruktur wie
/// Video-Downloads (`ItemDetailView.startDownload`), Musik ist dafür kein Sonderfall.
struct MusicDownloadIcon: View {
    let item: Item
    @EnvironmentObject var client: GoldfishClient
    @EnvironmentObject var downloads: DownloadManager

    var body: some View {
        Group {
            if let record = downloads.records[item.id] {
                switch record.state {
                case .downloading, .queued:
                    ProgressView(value: record.progress)
                        .frame(width: 20, height: 20)
                        .help("Wird heruntergeladen — Klick zum Abbrechen")
                        .onTapGesture { downloads.cancelDownload(itemId: item.id) }
                case .done:
                    Button {
                        downloads.deleteDownload(itemId: item.id)
                    } label: {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                    .buttonStyle(.plain)
                    .help("Offline verfügbar — Klick zum Löschen")
                case .failed:
                    Button {
                        start()
                    } label: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                    .help("Download fehlgeschlagen — Klick für erneuten Versuch")
                }
            } else {
                Button {
                    start()
                } label: {
                    Image(systemName: "arrow.down.circle")
                }
                .buttonStyle(.plain)
                .help("Für offline speichern")
            }
        }
        .frame(width: 22)
    }

    private func start() {
        guard let url = client.downloadFileURL(itemId: item.id) else { return }
        downloads.startDownload(item: item, from: url)
    }
}

/// Bulk-Download-Helfer für "Album herunterladen"/"Playlist herunterladen"/den
/// Bibliotheks-Sync-Toggle — startet nur Tracks, die noch nicht heruntergeladen sind
/// oder gerade laufen (`records[id] == nil`), damit ein wiederholter Aufruf (z. B. der
/// periodische Bibliotheks-Sync) nicht dieselben fertigen Downloads erneut anstößt.
@MainActor
func downloadAllMissing(_ items: [Item], client: GoldfishClient, downloads: DownloadManager) {
    for item in items where downloads.records[item.id] == nil {
        guard let url = client.downloadFileURL(itemId: item.id) else { continue }
        downloads.startDownload(item: item, from: url)
    }
}
#endif
