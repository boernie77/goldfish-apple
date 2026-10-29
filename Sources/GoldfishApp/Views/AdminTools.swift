#if os(macOS)
import SwiftUI
import GoldfishCore

// Verwaltungsfunktionen für Administratoren (Mac): Verschieben, Umbenennen,
// Zuordnung ändern, Metadaten bearbeiten; dazu Scan und Protokoll in den
// Einstellungen. Der Server prüft die Admin-Rechte bei jeder dieser Routen
// selbst — die App blendet die Bedienung nur aus, wenn `client.isAdmin` fehlt.

// MARK: - Menü auf der Infoseite

struct AdminItemMenu: View {
    let item: Item
    /// Nach einer Änderung aufgerufen; der Aufrufer lädt den Titel neu.
    let onChanged: () -> Void

    @EnvironmentObject var client: GoldfishClient
    @State private var sheet: AdminSheet?
    @State private var confirmRename = false
    @State private var message: String?

    private enum AdminSheet: String, Identifiable {
        case move, match, metadata
        var id: String { rawValue }
    }

    var body: some View {
        Menu {
            Button("Verschieben …") { sheet = .move }
            Button("Umbenennen …") { confirmRename = true }
            Button("Zuordnung ändern …") { sheet = .match }
            Button("Metadaten bearbeiten …") { sheet = .metadata }
        } label: {
            Image(systemName: "gearshape")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Verwaltung (Admin)")
        .sheet(item: $sheet) { which in
            switch which {
            case .move: AdminMoveSheet(item: item, onChanged: onChanged)
            case .match: AdminMatchSheet(item: item, onChanged: onChanged)
            case .metadata: AdminMetadataSheet(item: item, onChanged: onChanged)
            }
        }
        .confirmationDialog("Datei umbenennen?", isPresented: $confirmRename) {
            Button("Umbenennen") {
                Task {
                    do {
                        let result = try await client.adminRenameItem(itemId: item.id)
                        message = "Umbenannt: \(result.newBase ?? "ok")"
                        onChanged()
                    } catch {
                        message = "Umbenennen fehlgeschlagen: \(error.localizedDescription)"
                    }
                }
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Die Datei wird nach dem Namensschema aus der TMDB-Zuordnung umbenannt.")
        }
        .alert("Verwaltung", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(message ?? "")
        }
    }
}

// MARK: - Verschieben

private struct AdminMoveSheet: View {
    let item: Item
    let onChanged: () -> Void

    @EnvironmentObject var client: GoldfishClient
    @Environment(\.dismiss) private var dismiss
    @State private var libraries: [Library] = []
    @State private var libraryId: Int64 = 0
    @State private var folder = ""
    @State private var busy = false
    @State private var error: String?
    @State private var askCrossDevice = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Verschieben").font(.title2.bold())
            Text("Die Datei wird auf dem Server physisch verschoben. Ein neuer Ordnername wird bei Bedarf angelegt.")
                .font(.callout).foregroundStyle(.secondary)
            Picker("Ziel-Bibliothek", selection: $libraryId) {
                ForEach(libraries) { Text($0.name).tag($0.id) }
            }
            TextField("Zielordner (leer = Wurzel)", text: $folder)
                .textFieldStyle(.roundedBorder)
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Spacer()
                Button("Abbrechen") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Verschieben") { Task { await start() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || libraryId == 0)
            }
        }
        .padding(20)
        .frame(width: 440)
        .task {
            libraries = (try? await client.fetchLibraries()) ?? []
            libraryId = item.libraryId
            folder = (item.relPath ?? "").split(separator: "/").dropLast().joined(separator: "/")
        }
        .confirmationDialog("Datenträgerwechsel", isPresented: $askCrossDevice) {
            Button("Ja, verschieben", role: .destructive) { Task { await move(crossDevice: true) } }
            Button("Abbrechen", role: .cancel) { busy = false }
        } message: {
            Text("Die Datei würde auf einen ANDEREN Datenträger kopiert, nicht nur innerhalb desselben Laufwerks verschoben. Das kann je nach Größe dauern.")
        }
    }

    private func start() async {
        busy = true
        error = nil
        do {
            let target = folder.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
            let preview = try await client.adminMovePreview(itemId: item.id, targetFolder: target, targetLibraryId: libraryId)
            if preview.anyCrossDevice { askCrossDevice = true } else { await move(crossDevice: false) }
        } catch {
            self.error = error.localizedDescription
            busy = false
        }
    }

    private func move(crossDevice: Bool) async {
        do {
            let target = folder.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
            try await client.adminMoveItem(itemId: item.id, targetFolder: target, targetLibraryId: libraryId, allowCrossDevice: crossDevice)
            onChanged()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
        busy = false
    }
}

// MARK: - Zuordnung ändern

private struct AdminMatchSheet: View {
    let item: Item
    let onChanged: () -> Void

    @EnvironmentObject var client: GoldfishClient
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var kind = "movie"
    @State private var season = 1
    @State private var episode = 1
    @State private var results: [AdminSearchResult] = []
    @State private var status = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Zuordnung ändern").font(.title2.bold())
            HStack {
                TextField("Titel", text: $query).textFieldStyle(.roundedBorder).onSubmit { Task { await search() } }
                Button("Suchen") { Task { await search() } }
            }
            Picker("Art", selection: $kind) {
                Text("Film").tag("movie")
                Text("Serie").tag("tv")
                Text("Episode einer Serie").tag("episode")
            }
            if kind == "episode" {
                HStack {
                    Stepper("Staffel \(season)", value: $season, in: 0...99)
                    Stepper("Folge \(episode)", value: $episode, in: 0...999)
                }
            }
            if !status.isEmpty { Text(status).font(.callout).foregroundStyle(.secondary) }
            List(results) { res in
                Button {
                    Task { await apply(res) }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(res.title ?? "?")\(res.year.map { " (\($0))" } ?? "")")
                        Text(String((res.overview ?? "").prefix(120))).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
            .frame(minHeight: 180)
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Button("Zuordnung entfernen", role: .destructive) { Task { await unmatch() } }
                Spacer()
                Button("Schließen") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 520, height: 520)
        .onAppear {
            query = item.metadata?.title ?? item.title
            switch item.metadata?.tmdbType {
            case "episode": kind = "episode"
            case "tv": kind = "tv"
            default: kind = "movie"
            }
            season = item.metadata?.season ?? 1
            episode = item.metadata?.episode ?? 1
        }
    }

    private func search() async {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        status = "Suche …"
        error = nil
        do {
            results = try await client.adminSearchMetadata(query: text, kind: kind == "movie" ? "movie" : "tv")
            status = results.isEmpty ? "Keine Treffer." : ""
        } catch {
            status = ""
            self.error = error.localizedDescription
        }
    }

    private func apply(_ res: AdminSearchResult) async {
        do {
            try await client.adminSetItemMetadata(itemId: item.id, tmdbType: kind, tmdbId: res.id, season: season, episode: episode)
            onChanged()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func unmatch() async {
        do {
            try await client.adminUnmatchItem(itemId: item.id)
            onChanged()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Metadaten bearbeiten

private struct AdminMetadataSheet: View {
    let item: Item
    let onChanged: () -> Void

    @EnvironmentObject var client: GoldfishClient
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var originalTitle = ""
    @State private var year = ""
    @State private var releaseDate = ""
    @State private var runtime = ""
    @State private var rating = ""
    @State private var genres = ""
    @State private var ageRating = ""
    @State private var overview = ""
    @State private var error: String?

    private let ageOptions = ["", "0", "6", "12", "16", "18"]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Metadaten bearbeiten").font(.title2.bold())
            if item.metadata == nil {
                Text("Keine Metadaten zum Bearbeiten – erst eine Zuordnung wählen.").foregroundStyle(.secondary)
            } else {
                Form {
                    TextField("Titel", text: $title)
                    TextField("Originaltitel", text: $originalTitle)
                    TextField("Jahr", text: $year)
                    TextField("Erscheinungsdatum (JJJJ-MM-TT)", text: $releaseDate)
                    TextField("Laufzeit (Minuten)", text: $runtime)
                    TextField("Bewertung (0–10)", text: $rating)
                    TextField("Genres (Komma getrennt)", text: $genres)
                    Picker("Altersfreigabe (FSK)", selection: $ageRating) {
                        ForEach(ageOptions, id: \.self) { Text($0.isEmpty ? "keine Angabe" : "FSK \($0)").tag($0) }
                    }
                    VStack(alignment: .leading) {
                        Text("Beschreibung")
                        TextEditor(text: $overview).frame(height: 90).border(Color.secondary.opacity(0.3))
                    }
                }
            }
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Spacer()
                Button("Abbrechen") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Speichern") { Task { await save() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(item.metadata == nil)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear {
            guard let m = item.metadata else { return }
            title = m.title ?? ""
            originalTitle = m.originalTitle ?? ""
            year = m.year.map(String.init) ?? ""
            let date = String((m.releaseDate ?? "").prefix(10))
            releaseDate = date.hasPrefix("0001") ? "" : date
            runtime = m.runtimeMin.map(String.init) ?? ""
            rating = m.rating.map { String($0) } ?? ""
            genres = m.genreList.joined(separator: ", ")
            ageRating = m.ageRating ?? ""
            overview = m.overview ?? ""
        }
    }

    private func save() async {
        guard let m = item.metadata else { return }
        let names = genres.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let genreJSON = (try? JSONEncoder().encode(names)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let fields = GoldfishClient.AdminMetadataFields(
            title: title.trimmingCharacters(in: .whitespaces),
            originalTitle: originalTitle.trimmingCharacters(in: .whitespaces),
            year: Int(year) ?? 0,
            releaseDate: releaseDate.trimmingCharacters(in: .whitespaces),
            overview: overview.trimmingCharacters(in: .whitespacesAndNewlines),
            rating: Double(rating.replacingOccurrences(of: ",", with: ".")) ?? 0,
            runtimeMin: Int(runtime) ?? 0,
            genres: genreJSON,
            ageRating: ageRating
        )
        do {
            try await client.adminUpdateMetadata(metadataId: m.id, fields: fields)
            onChanged()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Scan

struct AdminScanView: View {
    @EnvironmentObject var client: GoldfishClient
    @State private var libraries: [Library] = []
    @State private var status: AdminScanStatus?
    @State private var message: String?

    var body: some View {
        Form {
            Section("Status") {
                if let status, status.isActive {
                    let progress = (status.total ?? 0) > 0 ? "\(status.done ?? 0)/\(status.total ?? 0)" : ""
                    Text("Scan läuft \(progress)")
                    if let current = status.current, !current.isEmpty {
                        Text(current).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Button("Abbrechen", role: .destructive) { Task { try? await client.adminCancelScan() } }
                } else {
                    Text("Kein Scan aktiv")
                    if let error = status?.lastError, !error.isEmpty {
                        Text("Letzter Fehler: \(error)").font(.caption).foregroundStyle(.secondary)
                    } else if let s = status, (s.new ?? 0) > 0 || (s.removed ?? 0) > 0 {
                        Text("Zuletzt: \(s.new ?? 0) neu, \(s.removed ?? 0) entfernt").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Section("Bibliotheken scannen") {
                Button("Alle Bibliotheken") { Task { await start(nil) } }
                ForEach(libraries) { lib in
                    Button(lib.name) { Task { await start(lib.id) } }
                }
            }
            if let message { Text(message).font(.callout).foregroundStyle(.secondary) }
        }
        .formStyle(.grouped)
        .navigationTitle("Scan")
        .task {
            libraries = (try? await client.fetchLibraries()) ?? []
            while !Task.isCancelled {
                status = try? await client.adminScanStatus()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private func start(_ id: Int64?) async {
        do {
            try await client.adminStartScan(libraryId: id)
            message = "Scan gestartet"
        } catch {
            message = "Scan nicht gestartet: \(error.localizedDescription)"
        }
    }
}

// MARK: - Protokoll

struct AdminLogView: View {
    @EnvironmentObject var client: GoldfishClient
    @State private var entries: [AdminLogEntry] = []
    @State private var category = ""
    @State private var exhausted = false
    @State private var error: String?

    private let categories: [(String, String)] = [("Alle", ""), ("Anmeldung", "auth"), ("Wiedergabe", "playback"), ("Verwaltung", "admin"), ("Jobs", "job")]

    var body: some View {
        List {
            Picker("Kategorie", selection: $category) {
                ForEach(categories, id: \.1) { Text($0.0).tag($0.1) }
            }
            .pickerStyle(.segmented)
            if let error { Text("Protokoll nicht abrufbar: \(error)").foregroundStyle(.red) }
            ForEach(entries) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(entry.action ?? ""): \(entry.detail ?? "")").lineLimit(3)
                    Text([formatted(entry.at), entry.username ?? "System", entry.device ?? ""].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if !exhausted && !entries.isEmpty {
                Button("Ältere laden") { Task { await load(reset: false) } }
            }
        }
        .navigationTitle("Protokoll")
        .task(id: category) { await load(reset: true) }
    }

    private func load(reset: Bool) async {
        let before = reset ? 0 : (entries.last?.id ?? 0)
        do {
            let page = try await client.adminActivityLog(category: category, beforeId: before)
            entries = reset ? page : entries + page
            exhausted = page.count < 100
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func formatted(_ raw: String?) -> String {
        guard let raw else { return "" }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        guard let date = iso.date(from: raw) ?? plain.date(from: raw) else { return raw }
        return date.formatted(date: .numeric, time: .standard)
    }
}
#endif
