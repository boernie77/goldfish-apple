import SwiftUI
import GoldfishCore
import UniformTypeIdentifiers

/// Which folder-picker request is currently active — SettingsView drives exactly ONE
/// `.fileImporter` off this instead of two independent ones (`showingFolderPicker` +
/// `reconnectingLibrary`), which turned out not to work reliably together: real bug hit
/// 2026-08-19, the Downloads-folder picker stopped opening entirely (no dialog at all)
/// once a second `.fileImporter` modifier was attached to the same view for "Ordner
/// erneut auswählen" — known SwiftUI quirk where stacking two of the same modifier type
/// on one view only reliably honors one of them.
private enum FolderPickerTarget {
    case downloads
    case reconnectLibrary(LocalLibrary)
}

struct SettingsView: View {
    @EnvironmentObject var client: GoldfishClient
    @EnvironmentObject var downloads: DownloadManager
    @EnvironmentObject var localLibrary: LocalLibraryManager
    // Two SEPARATE states instead of deriving `isPresented` from `folderPickerTarget` —
    // real bug hit 2026-08-19: SwiftUI resets `isPresented` back to `false` (running our
    // binding's `set`, which cleared `folderPickerTarget`) BEFORE calling `onCompletion`,
    // so the completion closure always read `nil` and silently did nothing. `pickerTarget`
    // is now untouched by the presentation binding — only the completion closure clears it.
    @State private var isPresentingFolderPicker = false
    @State private var pickerTarget: FolderPickerTarget?
    @State private var pickerError: String?
    @State private var showingAddLocalLibrary = false
    @State private var renamingLibrary: LocalLibrary?
    @State private var renameText = ""
    @State private var renamingMergedLibrary = false
    @State private var mergedLibraryNameDraft = ""
    @EnvironmentObject var shuffleScope: ShuffleScope
    // Real gap hit 2026-08-19: der 🎯-Button für die Zufall-Bibliotheksauswahl saß bisher
    // nur im Toolbar der "Bibliotheken"-Übersicht — der User fand ihn dort nicht ("finde
    // ich immer noch nicht"). Zusätzlicher, klar beschrifteter Zugang hier in den
    // Einstellungen, wo Nutzer eher globale App-Einstellungen erwarten.
    @State private var shuffleScopeLibraries: [Library] = []
    // Gesehen-Sync (User-Anfrage 2026-08-19): kurze Zusammenfassung des aktuellen
    // Verknüpfungsstatus für die Übersichtszeile, analog `shuffleScope`-Zeile oben.
    @State private var watchLinks: [WatchLink] = []
    #if os(macOS)
    @EnvironmentObject var transcode: LocalTranscodeService

    /// Per-User-Scoping für die "Formatanpassung"-Anzeige (siehe `LocalTranscodeService.
    /// scopedCompletedCount`'s Doc-Kommentar) — `localLibrary.libraries`/`downloads.records`
    /// sind beide bereits auf den aktuellen User gefiltert, hier nur noch auf IDs reduziert.
    private var ownedLocalItemIds: Set<UUID> {
        let ownedLibraryIds = Set(localLibrary.libraries.map(\.id))
        return Set(localLibrary.items.filter { ownedLibraryIds.contains($0.libraryId) }.map(\.id))
    }
    private var ownedDownloadItemIds: Set<Int64> {
        Set(downloads.records.keys)
    }
    private var ownedDownloadFailedItemIds: [Int64] {
        Array(transcode.downloadFailedItems.keys.filter { ownedDownloadItemIds.contains($0) })
    }
    private var scopedCompletedCount: Int {
        transcode.scopedCompletedCount(ownedLocalItemIds: ownedLocalItemIds, ownedDownloadItemIds: ownedDownloadItemIds)
    }
    #endif

    private var watchLinkSummary: String {
        if let active = watchLinks.first(where: { $0.status == "accepted" }) {
            return active.partnerName
        }
        if watchLinks.contains(where: { $0.status == "pending_incoming" }) {
            return "Anfrage offen"
        }
        if watchLinks.contains(where: { $0.status == "pending_outgoing" }) {
            return "Warte auf Bestätigung"
        }
        return "Nicht verknüpft"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    // Plain stacked Text instead of LabeledContent: on macOS, Form lays
                    // LabeledContent out as two fixed-width columns that overflow badly in a
                    // narrow window — long values (URLs, paths) push their label off the left
                    // edge, unreadable (real bug hit 2026-08-17). Stacked rows never do that.
                    SettingsInfoRow(label: "Benutzer", value: client.currentUsername ?? "-")
                    SettingsInfoRow(label: "Server", value: client.baseURL?.absoluteString ?? "-")
                    Button("Abmelden", role: .destructive) {
                        Task { await client.logout() }
                    }
                }

                Section {
                    NavigationLink {
                        ShuffleScopeSettingsList(libraries: shuffleScopeLibraries)
                    } label: {
                        HStack {
                            Text("Bibliotheken für Zufall")
                            Spacer()
                            Text(shuffleScope.isScoped ? "\(shuffleScope.selections.count) ausgewählt" : "Alle")
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Zufällig abspielen")
                } footer: {
                    Text("Schränkt den globalen 🔀-Button in der Bibliotheken-Übersicht auf eine Auswahl ein, statt auf alle Bibliotheken zu wirken.")
                }
                .task {
                    shuffleScopeLibraries = (try? await client.fetchLibraries()) ?? []
                }

                Section {
                    NavigationLink {
                        WatchLinkSettingsView(watchLinks: $watchLinks)
                    } label: {
                        HStack {
                            Text("Gesehen-Sync")
                            Spacer()
                            Text(watchLinkSummary)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Gesehen-Sync")
                } footer: {
                    Text("Verknüpft deinen Gesehen-Status mit einem anderen Benutzer — beide müssen zustimmen. Es werden nur Videos synchronisiert, auf die der jeweils andere Benutzer selbst Zugriff hat.")
                }
                .task {
                    watchLinks = (try? await client.fetchWatchLinks()) ?? []
                }

                Section("Downloads") {
                    SettingsInfoRow(label: "Ordner", value: downloads.usesCustomDirectory ? downloads.downloadsDir.path : "Standard (App-Datenordner)")
                    Button("Ordner wählen…") {
                        pickerTarget = .downloads
                        isPresentingFolderPicker = true
                    }
                    if downloads.usesCustomDirectory {
                        Button("Auf Standard zurücksetzen") {
                            downloads.resetToDefaultDirectory()
                        }
                    }
                    if let pickerError {
                        Text(pickerError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                Section("Lokale Bibliotheken") {
                    ForEach(localLibrary.libraries) { lib in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(lib.name)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Spacer(minLength: 8)
                                if localLibrary.scanningLibraryIds.contains(lib.id) {
                                    ProgressView().controlSize(.small)
                                }
                                Button {
                                    renameText = lib.name
                                    renamingLibrary = lib
                                } label: {
                                    Image(systemName: "pencil")
                                }
                                .buttonStyle(.plain)
                                Button(role: .destructive) {
                                    localLibrary.deleteLibrary(lib)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.plain)
                            }
                            if lib.ownerUsername == nil {
                                // Unbeanspruchte Legacy-Bibliothek (kein Owner gespeichert) —
                                // aktuell für JEDEN sichtbar. Explizites Beanspruchen statt
                                // automatischer Zuordnung, seit ein Login nur zum Testen
                                // fälschlich zum dauerhaften "Besitzer" gemacht wurde
                                // (User-Anfrage 2026-08-19).
                                HStack {
                                    Text("Kein Besitzer zugeordnet — für alle sichtbar")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Button("Beanspruchen") {
                                        localLibrary.claimLibrary(lib)
                                    }
                                    .font(.caption)
                                }
                            }
                            if localLibrary.unavailableLibraryIds.contains(lib.id) {
                                Label("Nicht verbunden — Datenträger einstecken, um wieder darauf zuzugreifen", systemImage: "externaldrive.badge.xmark")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                                // Externer Datenträger abgezogen/nicht eingesteckt — Ordner
                                // erneut auswählen, ohne die Bibliothek neu anzulegen
                                // (Videos/Watched/Resume bleiben erhalten).
                                Button("Ordner erneut auswählen…") {
                                    pickerTarget = .reconnectLibrary(lib)
                                    isPresentingFolderPicker = true
                                }
                                .font(.caption)
                            } else {
                                Text("\(localLibrary.itemsFor(lib.id).count) Videos · \(kindLabel(lib.kind))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                        .opacity(localLibrary.unavailableLibraryIds.contains(lib.id) ? 0.6 : 1)
                    }
                    Button("Ordner hinzufügen…") {
                        showingAddLocalLibrary = true
                    }
                    if let lastError = localLibrary.lastError {
                        Text(lastError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                #if os(macOS)
                // Real bug hit 2026-08-19 (User: "beim Benutzer Börnie fehlt der Menüpunkt des
                // Konvertierens"): dieser Abschnitt deckt sowohl lokale Bibliotheken ALS AUCH
                // Server-Downloads ab (siehe `transcode.downloadFailedItems`/
                // `currentDownloadTitle` unten), war aber komplett hinter "hat mindestens eine
                // lokale Bibliothek" versteckt — ein User wie Börnie, der nur Server-Downloads
                // nutzt und nie eine lokale Bibliothek angelegt hat, sah den ganzen Abschnitt
                // nie, obwohl er für seine Downloads durchaus relevant ist.
                if !localLibrary.libraries.isEmpty || !downloads.records.isEmpty {
                    Section {
                        if let current = transcode.currentItem {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Wird angepasst: \(current.displayTitle)")
                                    .font(.caption)
                                ProgressView(value: transcode.progress["local-\(current.id.uuidString)"] ?? 0)
                            }
                        }
                        if !transcode.queuedItems.isEmpty {
                            Text("\(transcode.queuedItems.count) weitere in der Warteschlange")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if scopedCompletedCount > 0 {
                            Text("✓ \(scopedCompletedCount) Datei(en) für Wiedergabe angepasst")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        // Nur eigene Fehler zeigen — `ownedLocalItemIds` kommt bereits
                        // per-User-gefiltert aus `localLibrary.items`.
                        ForEach(Array(transcode.failedItems.keys.filter { ownedLocalItemIds.contains($0) }), id: \.self) { id in
                            Text("⚠ Fehlgeschlagen: \(transcode.failedItems[id] ?? "")")
                                .font(.caption2)
                                .foregroundStyle(.red)
                        }
                        // Real gap hit 2026-08-19: heruntergeladene Server-Dateien hatten
                        // keinen Retry-Weg außer Löschen+Neu-Download, weil der Button hier
                        // nur lokale Bibliotheken abklapperte. Nutzer-Wunsch (2026-08-19): EIN
                        // Button für beides statt zwei getrennter — `isConverted`/
                        // `isDownloadConverted` sorgen dafür, dass bereits fertige Dateien
                        // ohnehin übersprungen werden, hier also kein unnötiges Neu-Konvertieren.
                        if !ownedDownloadFailedItemIds.isEmpty || transcode.currentDownloadTitle != nil {
                            ForEach(Array(ownedDownloadFailedItemIds), id: \.self) { id in
                                Text("⚠ Download fehlgeschlagen: \(transcode.downloadFailedItems[id] ?? "")")
                                    .font(.caption2)
                                    .foregroundStyle(.red)
                            }
                            if let title = transcode.currentDownloadTitle {
                                // User-Anfrage 2026-08-19: "bei der Formatanpassung fehlt der
                                // Fortschrittsbalken" — der Download-Pfad zeigte bisher nur
                                // Text, nie den `ProgressView`, den der lokale Pfad oben schon
                                // hatte (`transcode.progress["local-<uuid>"]`). Gleiches Muster
                                // jetzt auch für Downloads via `currentDownloadItemId`.
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Wird angepasst: \(title)")
                                        .font(.caption)
                                    if let itemId = transcode.currentDownloadItemId {
                                        ProgressView(value: transcode.progress["dl-\(itemId)"] ?? 0)
                                    }
                                }
                            }
                        }
                        // Manuell erneut anstoßen, ohne die Bibliothek zu löschen/neu
                        // anzulegen (User-Anfrage 2026-08-19) — ein normaler Scan prüft
                        // ohnehin schon jede Datei neu, nicht nur neu hinzugekommene.
                        Button {
                            Task { await localLibrary.rescanAllLibraries() }
                            transcode.rescanDownloads(records: Array(downloads.records.values)) { itemId in
                                downloads.localFileURL(itemId: itemId)
                            }
                        } label: {
                            Label("Erneut prüfen (Bibliotheken + Downloads)", systemImage: "arrow.clockwise")
                        }
                        .disabled(!localLibrary.scanningLibraryIds.isEmpty || transcode.currentDownloadTitle != nil)
                    } header: {
                        Text("Formatanpassung")
                    } footer: {
                        Text("Dateien, die macOS nicht direkt abspielen kann (z. B. MKV mit DTS-Ton), werden automatisch im Hintergrund einmalig für die Wiedergabe angepasst.")
                    }
                }
                #endif

                if localLibrary.libraries.count >= 2 {
                    Section {
                        Text("Beliebig viele lokale Bibliotheken zusammenlegen — sie erscheinen dann in der Bibliotheken-Übersicht als EINE Kachel, Videos aus allen zusammen.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(localLibrary.libraries) { lib in
                            Toggle(lib.name, isOn: Binding(
                                get: { localLibrary.mergedLibraryIds.contains(lib.id) },
                                set: { _ in localLibrary.toggleMergedLibrary(lib.id) }
                            ))
                        }
                        if localLibrary.mergedLibraryIds.count == 1 {
                            Text("Wähle noch mindestens eine weitere Bibliothek.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else if localLibrary.mergedLibraryIds.count >= 2 {
                            Text("✓ \(localLibrary.mergedLibraryIds.count) Bibliotheken werden zusammengelegt")
                                .font(.caption)
                                .foregroundStyle(.orange)
                            // User-Anfrage 2026-08-19: eigener Name statt der automatisch
                            // zusammengesetzten Einzelnamen (z.B. "a + Alex + USB-STICK"),
                            // wird schnell unhandlich bei mehr als 2-3 Bibliotheken. Real bug
                            // hit 2026-08-19: selbst ein lokaler `@State`-Entwurf, inline im
                            // `Form` gebunden, blieb untippbar — genau wie beim allerersten
                            // Versuch. Fix: derselbe bereits bewährte `.alert`+Stift-Button-
                            // Ansatz wie beim Umbenennen einer einzelnen lokalen Bibliothek
                            // (`renamingLibrary`/`renameText` oben) — ein `TextField` in einem
                            // `.alert` sitzt außerhalb der Form-Diffing-Hierarchie und war dort
                            // nachweislich problemlos tippbar.
                            HStack {
                                Text(localLibrary.mergedLibraryName.isEmpty ? "Kein eigener Name" : localLibrary.mergedLibraryName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button {
                                    mergedLibraryNameDraft = localLibrary.mergedLibraryName
                                    renamingMergedLibrary = true
                                } label: {
                                    Image(systemName: "pencil")
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    } header: {
                        Text("Bibliotheken zusammenlegen")
                    }

                    Section {
                        Text("Wähle mindestens 2 Bibliotheken, die auf doppelt vorhandene Dateien (gleicher Dateiname) geprüft werden sollen.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(localLibrary.libraries) { lib in
                            Toggle(lib.name, isOn: Binding(
                                get: { localLibrary.compareLibraryIds.contains(lib.id) },
                                set: { _ in localLibrary.toggleCompareLibrary(lib.id) }
                            ))
                        }
                        let duplicates = localLibrary.duplicateItems()
                        if localLibrary.compareLibraryIds.count >= 2 {
                            if duplicates.isEmpty {
                                Text("Keine doppelten Dateinamen gefunden.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("\(duplicates.count) Datei(en) mit doppeltem Namen:")
                                    .font(.caption.weight(.semibold))
                                ForEach(duplicates) { item in
                                    HStack {
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(item.displayTitle)
                                                .font(.caption)
                                            Text(libraryName(for: item.libraryId))
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Button(role: .destructive) {
                                            localLibrary.deleteItem(item)
                                        } label: {
                                            Image(systemName: "trash")
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                    } header: {
                        Text("Duplikate finden")
                    }
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Einstellungen")
            .fileImporter(
                isPresented: $isPresentingFolderPicker,
                allowedContentTypes: [.folder]
            ) { result in
                let target = pickerTarget
                pickerTarget = nil
                switch target {
                case .downloads:
                    switch result {
                    case .success(let url):
                        // DownloadManager owns the entire start/stopAccessingSecurityScopedResource
                        // lifecycle for the chosen folder — calling stop here too (as this used to)
                        // ends the very access grant it just started, a likely contributor to the
                        // "access lost" bug where downloads to a custom folder failed shortly after
                        // picking it.
                        downloads.setDownloadsDirectory(url)
                        pickerError = nil
                    case .failure(let error):
                        pickerError = error.localizedDescription
                    }
                case .reconnectLibrary(let lib):
                    if case .success(let url) = result {
                        Task { await localLibrary.reconnectLibrary(lib, rootURL: url) }
                    }
                case nil:
                    break
                }
            }
            .alert("Downloadordner", isPresented: Binding(
                get: { downloads.lastAccessWarning != nil },
                set: { if !$0 { downloads.lastAccessWarning = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(downloads.lastAccessWarning ?? "")
            }
            .sheet(isPresented: $showingAddLocalLibrary) {
                AddLocalLibrarySheet()
            }
            .alert("Bibliothek umbenennen", isPresented: Binding(
                get: { renamingLibrary != nil },
                set: { if !$0 { renamingLibrary = nil } }
            )) {
                TextField("Name", text: $renameText)
                Button("Abbrechen", role: .cancel) { renamingLibrary = nil }
                Button("Speichern") {
                    if let lib = renamingLibrary {
                        localLibrary.renameLibrary(lib, to: renameText)
                    }
                    renamingLibrary = nil
                }
            }
            .alert("Name der zusammengelegten Bibliothek", isPresented: $renamingMergedLibrary) {
                TextField("z.B. Alle Filme", text: $mergedLibraryNameDraft)
                Button("Abbrechen", role: .cancel) {}
                Button("Speichern") {
                    localLibrary.setMergedLibraryName(mergedLibraryNameDraft)
                }
            }
        }
    }

    private func kindLabel(_ kind: String) -> String {
        switch kind {
        case "movies": return "Filme"
        case "tv": return "Serien"
        default: return "Privat"
        }
    }

    private func libraryName(for id: UUID) -> String {
        localLibrary.libraries.first { $0.id == id }?.name ?? "?"
    }
}

private struct SettingsInfoRow: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .textSelection(.enabled)
        }
        .padding(.vertical, 2)
    }
}

/// Folder picker lives *inside* this sheet (rather than chaining a `.fileImporter` in the
/// parent straight into presenting this sheet) — triggering a second modal from within a
/// `.fileImporter` completion handler on macOS is flaky (garbled layout was reported
/// 2026-08-17, matches this exact pattern). Picking a folder here just fills in the form;
/// the user can still rename before confirming.
private struct AddLocalLibrarySheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var localLibrary: LocalLibraryManager

    @State private var rootURL: URL?
    @State private var name = ""
    @State private var kind = "movies"
    @State private var isAdding = false
    @State private var showingFolderPicker = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button {
                        showingFolderPicker = true
                    } label: {
                        Label(rootURL?.path ?? "Ordner wählen…", systemImage: "folder")
                            .lineLimit(1)
                    }
                }
                if rootURL != nil {
                    Section {
                        // Explicit stacked labels instead of `TextField("Name", ...)`/
                        // `Picker("Art", ...)`'s implicit inline label — real bug hit
                        // 2026-08-19 (User-Screenshot: "Zeilen verschoben" in this exact
                        // dialog): on macOS, a `Form` lays labeled controls out as two
                        // fixed-width columns computed from ALL labels in the surrounding
                        // context, which can misalign/overflow in a narrow sheet — same root
                        // cause already documented + fixed once for `SettingsInfoRow`
                        // elsewhere in this file. Stacked labels sidestep the shared-column
                        // computation entirely.
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Name").font(.caption).foregroundStyle(.secondary)
                            TextField("Name", text: $name)
                                .labelsHidden()
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Art").font(.caption).foregroundStyle(.secondary)
                            Picker("Art", selection: $kind) {
                                Text("Filme").tag("movies")
                                Text("Serien").tag("tv")
                                Text("Privat").tag("private")
                            }
                            .labelsHidden()
                        }
                    }
                }
                if let lastError = localLibrary.lastError {
                    Section {
                        Text(lastError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Lokale Bibliothek")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Hinzufügen") {
                        guard let rootURL else { return }
                        isAdding = true
                        Task {
                            // Sheet blieb bisher immer zu, auch bei Fehler — die
                            // Fehlermeldung in den Einstellungen war dadurch nur ein
                            // kurzes Aufblitzen, wirkte "unverändert" (real bug hit
                            // 2026-08-19). Jetzt: bei Fehler Dialog offen lassen,
                            // Fehlertext direkt hier im Sheet zeigen.
                            let ok = await localLibrary.addLibrary(rootURL: rootURL, name: name, kind: kind)
                            isAdding = false
                            if ok { dismiss() }
                        }
                    }
                    .disabled(rootURL == nil || name.isEmpty || isAdding)
                }
            }
            .fileImporter(isPresented: $showingFolderPicker, allowedContentTypes: [.folder]) { result in
                if case .success(let url) = result {
                    rootURL = url
                    if name.isEmpty { name = url.lastPathComponent }
                }
            }
        }
        .frame(minWidth: 380, minHeight: 260)
    }
}
