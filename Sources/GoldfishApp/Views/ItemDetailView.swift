import SwiftUI
import GoldfishCore

struct ItemDetailView: View {
    let item: Item
    /// Sibling items from the list this detail view was opened from — passed through
    /// to the player so its ⏮/⏭ buttons can move within that same list.
    var queue: [Item] = []

    @EnvironmentObject var client: GoldfishClient
    @EnvironmentObject var downloads: DownloadManager
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif
    @State private var showPlayer = false
    @State private var isFavorite: Bool
    @State private var isWatched: Bool
    @State private var showResumePrompt = false
    @State private var startFromBeginning = false
    @State private var isCheckingResume = false
    @State private var showingAddToPlaylist = false
    // Duplicate files of the same movie/episode (identical metadataId) collapse into one
    // tile in the grid (`groupVariants`) — this dropdown is how the user picks WHICH file
    // Play/Download/Favorite/Watched actually act on, mirrors the web app's Varianten-
    // Dropdown (CLAUDE.md "Merge-Duplikate"). Defaults to the representative tile's item.
    @State private var selectedItem: Item
    @State private var variants: [Item] = []
    /// Ton-/Untertitel-Spuren der aktuell gewählten Datei — separat nachgeladen,
    /// weil die Grid-Liste (`fetchItems`) keine `streams` mitliefert, nur
    /// `GET /api/items/{id}` (Server: `GetItemFor` → `ItemStreams`).
    @State private var streams: [MediaStream] = []
    /// Ton-/Untertitel-Vorwahl aus den Dropdowns oben — an den Player weitergereicht.
    @State private var pickedAudioIndex: Int? = nil
    @State private var pickedSubtitle: PreferredSubtitle? = nil

    init(item: Item, queue: [Item] = []) {
        self.item = item
        self.queue = queue
        _selectedItem = State(initialValue: item)
        _isFavorite = State(initialValue: item.favorite)
        _isWatched = State(initialValue: item.watched)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PosterImage(url: posterURL)
                    .frame(maxWidth: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                Text(item.displayTitle)
                    .font(.title2.bold())

                HStack(spacing: 12) {
                    if let year = item.metadata?.year {
                        Text(String(year))
                    }
                    if !item.resolutionLabel.isEmpty {
                        Text(item.resolutionLabel)
                    }
                    if let runtime = item.metadata?.runtimeMin {
                        Text("\(runtime) min")
                    }
                    // User-Anfrage 2026-08-19: FSK/Altersfreigabe soll beim Öffnen eines Films
                    // oder einer Episode mit angezeigt werden — Auflösung stand hier bereits,
                    // FSK fehlte komplett.
                    if let ageRating = item.metadata?.ageRating, !ageRating.isEmpty {
                        Text("FSK \(ageRating)")
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.secondary.opacity(0.2), in: RoundedRectangle(cornerRadius: 4))
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)

                // User-Anfrage 2026-08-19: "Länge der Datei, das Videoformat und die Größe
                // der Datei anzeigen" — bewusst getrennt von der Zeile oben: dort steht das
                // TMDB-Runtime (kann von der tatsächlichen Datei abweichen, z.B. bei
                // Doppelfolgen/Extended Cuts), hier die REALEN ffprobe-Werte der Datei.
                HStack(spacing: 12) {
                    if let container = selectedItem.container, !container.isEmpty {
                        Text(container.uppercased())
                    }
                    if selectedItem.durationSec ?? 0 > 0 {
                        Text(selectedItem.durationLabel)
                    }
                    if let sizeLabel {
                        Text(sizeLabel)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if let rating = item.metadata?.rating, rating > 0 {
                    Label(String(format: "%.1f", rating), systemImage: "star.fill")
                        .foregroundStyle(.yellow)
                        .font(.subheadline)
                }

                // User-Anfrage 2026-08-19: "kannst du in der Detailansicht das Genre noch
                // ergänzen?" — genreList gibt's im Model schon (JSON-String vom Server
                // dekodiert), fehlte hier bisher komplett in der UI.
                if let genres = item.metadata?.genreList, !genres.isEmpty {
                    Text(genres.joined(separator: " · "))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if let overview = item.metadata?.overview, !overview.isEmpty {
                    Text(overview)
                        .font(.body)
                }

                let audioStreams = streams.filter { $0.type == "audio" }
                // Nur einblendbare Untertitel (von uns erzeugt: 📝 OCR / 🎤 KI) —
                // Bitmap-Spuren (PGS/VOBSUB) kann der Player nicht darstellen.
                let subStreams = streams.filter { $0.type == "subtitle" && $0.isDisplayableGeneratedSub }
                if !audioStreams.isEmpty || !subStreams.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        if audioStreams.count > 1 {
                            Picker("🔊 Tonspur", selection: $pickedAudioIndex) {
                                ForEach(audioStreams, id: \.index) { s in
                                    Text(s.detailLabel).tag(Int?.some(s.index))
                                }
                            }
                            .font(.caption)
                        } else if let only = audioStreams.first {
                            Text("🔊 \(only.detailLabel)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if !subStreams.isEmpty {
                            Picker("💬 Untertitel", selection: $pickedSubtitle) {
                                Text("— Aus —").tag(PreferredSubtitle?.none)
                                ForEach(subStreams, id: \.index) { s in
                                    if let ps = s.asPreferredSubtitle {
                                        Text(s.detailLabel).tag(PreferredSubtitle?.some(ps))
                                    }
                                }
                            }
                            .font(.caption)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if variants.count > 1 {
                    Menu {
                        ForEach(variants) { variant in
                            Button {
                                selectedItem = variant
                                isFavorite = variant.favorite
                                isWatched = variant.watched
                            } label: {
                                if variant.id == selectedItem.id {
                                    Label(variantLabel(variant), systemImage: "checkmark")
                                } else {
                                    Text(variantLabel(variant))
                                }
                            }
                        }
                    } label: {
                        Label(variantLabel(selectedItem), systemImage: "square.stack")
                            .font(.caption)
                            .lineLimit(1)
                    }
                }

                CastStripView(metadataId: item.metadataId)

                HStack(spacing: 12) {
                    Button {
                        Task { await startPlayback() }
                    } label: {
                        if isCheckingResume {
                            ProgressView().controlSize(.small)
                        } else {
                            Label(downloads.isDownloaded(itemId: selectedItem.id) ? "Offline abspielen" : "Abspielen", systemImage: "play.fill")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isCheckingResume)

                    Button {
                        Task { await toggleFavorite() }
                    } label: {
                        Image(systemName: isFavorite ? "heart.fill" : "heart")
                    }
                    .buttonStyle(.bordered)

                    Button {
                        Task { await toggleWatched() }
                    } label: {
                        Image(systemName: isWatched ? "checkmark.circle.fill" : "checkmark.circle")
                    }
                    .buttonStyle(.bordered)

                    Button {
                        showingAddToPlaylist = true
                    } label: {
                        Image(systemName: "text.badge.plus")
                    }
                    .buttonStyle(.bordered)
                }

                DownloadButtonRow(item: selectedItem)
            }
            .padding()
        }
        .navigationTitle("")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task {
            variants = (try? await client.fetchVariants(itemId: item.id)) ?? []
            await loadStreams(for: selectedItem.id)
        }
        .onChange(of: selectedItem.id) { newID in
            Task { await loadStreams(for: newID) }
        }
        #if os(macOS)
        .onChange(of: showPlayer) { newValue in
            guard newValue else { return }
            PlayerLaunchCoordinator.shared.present(PlayerLaunchRequest(item: selectedItem, queue: queue, queueIndex: nil, randomContext: nil, startFromBeginning: startFromBeginning, preferredAudioIndex: pickedAudioIndex, preferredSubtitle: pickedSubtitle), openWindow: openWindow)
            showPlayer = false
        }
        #else
        .fullScreenCoverCompat(isPresented: $showPlayer) {
            PlayerView(item: selectedItem, queue: queue, startFromBeginning: startFromBeginning, preferredAudioIndex: pickedAudioIndex, preferredSubtitle: pickedSubtitle)
        }
        #endif
        .confirmationDialog("Wiedergabe fortsetzen?", isPresented: $showResumePrompt, titleVisibility: .visible) {
            Button("Von letzter Stelle fortsetzen") {
                startFromBeginning = false
                showPlayer = true
            }
            Button("Von Anfang abspielen") {
                startFromBeginning = true
                showPlayer = true
            }
            Button("Abbrechen", role: .cancel) {}
        }
        .sheet(isPresented: $showingAddToPlaylist) {
            AddToPlaylistSheet(item: selectedItem)
        }
    }

    private var sizeLabel: String? {
        guard let bytes = selectedItem.sizeBytes, bytes > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func variantLabel(_ variant: Item) -> String {
        var parts: [String] = []
        if let container = variant.container, !container.isEmpty { parts.append(container.uppercased()) }
        if !variant.resolutionLabel.isEmpty { parts.append(variant.resolutionLabel) }
        if let bytes = variant.sizeBytes, bytes > 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
        }
        if let bitrate = variant.bitrateKbps, bitrate > 0 { parts.append("\(bitrate) kbps") }
        let fileName = (variant.path.map { ($0 as NSString).lastPathComponent }) ?? variant.title
        return parts.isEmpty ? fileName : "\(fileName) — \(parts.joined(separator: " · "))"
    }

    /// Downloaded items and items with no meaningful resume position (≤5s, same threshold
    /// `PlayerView.setUp()` already uses) skip the dialog and just play — asking every time
    /// would be annoying for something that's barely been started.
    private func startPlayback() async {
        // User-Anfrage 2026-08-19: "bei offline Dateien merkt er sich nicht, wo man zuletzt
        // war" — dieser Zweig übersprang den Resume-Dialog für Downloads komplett (fragte nie
        // beim Server nach, weil offline ohnehin sinnlos), fragt jetzt aber den rein lokalen
        // Resume-Speicher ab (siehe DownloadManager.localResumeSeconds), der unabhängig vom
        // Server funktioniert.
        guard !downloads.isDownloaded(itemId: selectedItem.id) else {
            let resumeSec = downloads.localResumeSeconds(itemId: selectedItem.id)
            if resumeSec > 5 {
                showResumePrompt = true
            } else {
                startFromBeginning = false
                showPlayer = true
            }
            return
        }
        isCheckingResume = true
        let resumeSec = (try? await client.getResume(itemId: selectedItem.id)) ?? 0
        isCheckingResume = false
        if resumeSec > 5 {
            showResumePrompt = true
        } else {
            startFromBeginning = false
            showPlayer = true
        }
    }

    private var posterURL: URL? {
        // Offline-Poster, siehe ItemCard.posterURL-Kommentar.
        if let cached = downloads.cachedPosterURL(itemId: item.id) { return cached }
        if let metadataId = item.metadataId, let url = client.posterURL(metadataId: metadataId, posterPath: item.metadata?.posterPath) {
            return url
        }
        return client.thumbURL(itemId: item.id)
    }

    private func toggleFavorite() async {
        let newValue = !isFavorite
        isFavorite = newValue
        try? await client.setFavorite(itemId: selectedItem.id, favorite: newValue)
    }

    private func toggleWatched() async {
        let newValue = !isWatched
        isWatched = newValue
        try? await client.setWatched(itemId: selectedItem.id, watched: newValue)
        downloads.updateCachedWatched(itemId: selectedItem.id, watched: newValue)
    }

    private func loadStreams(for id: Int64) async {
        // `/api/playback/{id}` statt `/api/items/{id}` — nur der Playback-Endpoint
        // liefert auch die von uns erzeugten Untertitel (📝 OCR / 🎤 KI) mit,
        // gleiches Verhalten wie der Browser-Detail-Dialog.
        if let pb = try? await client.playback(itemId: id) {
            streams = pb.streams ?? []
        } else if let full = try? await client.fetchItem(id: id) {
            streams = full.streams ?? []
        }
        pickedSubtitle = nil
        let audio = streams.filter { $0.type == "audio" }
        pickedAudioIndex = audio.first(where: { $0.isDefault == true })?.index ?? audio.first?.index
    }
}

struct DownloadButtonRow: View {
    let item: Item
    @EnvironmentObject var client: GoldfishClient
    @EnvironmentObject var downloads: DownloadManager

    private static let speedFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useKB, .useMB, .useGB]
        f.countStyle = .binary
        return f
    }()

    var body: some View {
        HStack {
            if let record = downloads.records[item.id] {
                switch record.state {
                case .downloading, .queued:
                    if let prep = downloads.prepProgress[item.id] {
                        ProgressView(value: Double(prep), total: 100)
                            .frame(maxWidth: 160)
                        Text("Wird vorbereitet … \(prep) %")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ProgressView(value: record.progress)
                            .frame(maxWidth: 160)
                        Text("\(Int(record.progress * 100))%")
                            .font(.caption)
                        // User-Anfrage 2026-08-27: Downloadgeschwindigkeit neben der Prozentanzeige.
                        if let speed = downloads.downloadSpeeds[item.id] {
                            Text("· \(Self.speedFormatter.string(fromByteCount: Int64(speed)))/s")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Button("Abbrechen") { downloads.cancelDownload(itemId: item.id) }
                        .font(.caption)
                case .done:
                    Label("Heruntergeladen", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Button("Löschen") { downloads.deleteDownload(itemId: item.id) }
                        .font(.caption)
                case .failed:
                    VStack(alignment: .leading, spacing: 2) {
                        Label("Download fehlgeschlagen", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                        if let msg = record.errorMessage {
                            Text(msg).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Button("Erneut versuchen") { startDownload() }
                        .font(.caption)
                }
            } else {
                Button {
                    startDownload()
                } label: {
                    Label("Für offline speichern", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func startDownload() {
        guard let url = client.downloadFileURL(itemId: item.id) else { return }
        downloads.startDownload(item: item, from: url)
    }
}
