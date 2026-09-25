---
name: goldfishapple-detail-view
description: "Use when changing the GoldfishApple item detail dialog - resolution/FSK/download info, action rows, watch-state sync, or 'play next episode automatically'."
---

# goldfishapple-detail-view

Detail-Dialog-Features: Gesehen-Sync, Auflösung + FSK, Download-Auflösung/-Größe, Positionshöhe der Aktions-Reihe, Autoplay der nächsten Folge.

## Harte Regeln

- Serien-Nachbarschaft NIE aus der Seasons-Liste herleiten (Doppelfolgen teilen dieselbe `itemId`) - die nächste Folge liefert der Server (`GET /api/items/{id}/next-episode`).
- Wiedergabe-Einstellungen sind server-autoritativ (`GET/PUT /api/playback/preferences`); die `UserDefaults`-Kopie ist nur der Offline-Rückfall.
- Download-Größe kommt aus `DownloadRecord.bytesWritten`; die Download-Auflösung wird einmalig per `AVAsset` aus der lokalen Datei gelesen - kein neues Feld erfinden.
- Auflösungs-Labels müssen dieselbe Bucket-Formel wie `Item.resolutionLabel` nutzen (max(height, width·9/16)), damit beide Anzeigen konsistent bleiben.
- `ShowSeasonsView.ShowHeader` zeigt noch keine FSK - der Server liefert im `ShowOut`-Struct kein Age-Rating-Feld.

---

## Gesehen-Sync zwischen zwei Usern (seit 2026-08-19)

- Zwei eigene Accounts (z. B. Christian + Alex/Börnie) sollen ihren
  Gesehen-Status synchronisieren können, mutual opt-in (beide müssen
  bestätigen), respektiert dabei die eigene Library-ACL + FSK-Grenze
  **des Partners**.
- **Server-seitig implementiert** (`~/Projekte/Videoplayer/`, Tabelle
  `user_watch_links`, Endpoints unter `/api/watch-links`) — Sync wirkt
  automatisch für ALLE Clients, nicht nur die Mac-App.
- Mac-App: `GoldfishClient` (`fetchOtherUsers`, `fetchWatchLinks`,
  `requestWatchLink`, `confirmWatchLink`, `unlinkWatchLink`) + Models
  `OtherUser`/`WatchLink` in `GoldfishCore/Models/Models.swift`. UI: Section
  „Gesehen-Sync" in `SettingsView.swift` → `WatchLinkSettingsView.swift`.
- Browser/Android-UI für den Partner-Picker noch nicht gebaut — nur der
  Server-Endpoint + die Mac-App-UI sind live.

## Auflösung + FSK im Detail-Dialog (seit 2026-08-19)

- `ItemDetailView.swift`: FSK-Badge neben der Auflösungs-Anzeige, liest
  `item.metadata?.ageRating`.
- **Noch offen:** `ShowSeasonsView.swift`'s `ShowHeader` (Serien-Übersicht)
  zeigt noch keine FSK — der Server liefert dafür aktuell KEIN Age-Rating-
  Feld im `ShowOut`-Struct.

## Download-Auflösung + -Größe im Detail-Dialog (Mac/iOS/tvOS, seit Build 234/203/9, 2026-09-14)

- User-Wunsch: "wenn ein Video heruntergeladen worden ist, soll auf der
  Infoseite des Filmes stehen, wie die Auflösung des Downloads ist, und die
  Größe" — die vorhandene Auflösungs-/Größen-Anzeige (siehe oben) beschreibt
  die ORIGINALDATEI auf dem Server, die seit "Optimierte Downloads" (Server-
  CLAUDE.md „Download & Löschen") von der tatsächlich heruntergeladenen
  Datei abweichen kann.
- Größe kommt direkt aus `DownloadRecord.bytesWritten` (bereits vorhanden,
  kein neues Feld nötig). Auflösung gibt es dort nicht — wird per `AVAsset`
  (`loadTracks(withMediaType: .video)` + `naturalSize`/`preferredTransform`)
  einmalig aus der lokalen Datei gelesen, sobald ein Download existiert
  (`ItemDetailView.loadDownloadResolution(for:)`, läuft in `.task`/
  `.onChange(of: selectedItem.id)`). Gleiche Bucket-Formel wie
  `Item.resolutionLabel` (max(height, width·9/16) → "4K"/"1080p"/…), damit
  beide Anzeigen konsistent wirken.
- Neue Zeile `Label("Download", systemImage: "arrow.down.circle.fill")` +
  Auflösung + Größe, sichtbar bei `downloads.isDownloaded(itemId:)` — sitzt
  in der gemeinsamen `ItemDetailView`-Body-Struktur, also automatisch auf
  allen drei Plattformen inkl. tvOS (das dort ebenfalls Downloads hat).

## Detail-Ansicht: Aktions-Reihe höher (macOS + iOS, seit Build 215/199, 2026-09-13)

User-Wunsch: "Abspielen und Offline Speichern (inkl der Buttons für Favorit/
gesehen, etc) höher, Sie sollen zwischen Genre und den Beschreibungstext des
Films... Ähnlich wie auf Apple TV". `ItemDetailView.swift` hatte diese
Anordnung serienmäßig NUR für tvOS (`#if os(tvOS)`, seit dem Fokus-Engine-Fix
2026-09-03, siehe „Gelöste Bugs" oben) — und selbst dort saß der
Download-Button weiterhin unten, nicht zusammen mit den Action-Buttons.
macOS/iOS hatten beides ganz unten, nach Cast-Strip/Ton-Untertitel-Auswahl.

Fix: neuer `#if os(macOS) || os(iOS)`-Block direkt nach der Genre-Zeile (vor
`overview`) mit `actionButtonsRow` UND `DownloadButtonRow` zusammen — beide
gleichzeitig verschoben, wie explizit gewünscht. Zunächst nur für macOS
gebaut (Build 215), auf Nachfrage direkt am selben Tag auch auf iOS
ausgeweitet (Build 199) — die unteren Vorkommen sind jetzt vollständig
entfernt (kein Restvorkommen mehr für macOS/iOS weiter unten). tvOS behält
sein eigenes, seit 2026-09-03 bewährtes Muster unverändert (Action-Buttons
oben, Download unten, kein Bundling der beiden).

## „Nächste Folge automatisch starten" (2026-09-18, Mac 1.2/238 · iOS 1.8/208 · tvOS 1.5/13)

- Option in den Einstellungen (Sektion „Wiedergabe"), **Standard AUS**, pro Konto.
  Maßgeblich ist der **Server** (`GET/PUT /api/playback/preferences`); die
  `UserDefaults`-Kopie (`AutoPlayNextEpisodeSetting`) ist nur der Offline-Rückfall
  und wird beim Öffnen der Einstellungen und beim Start jeder Wiedergabe
  gespiegelt.
- Am Ende einer Serienfolge zeigt `PlayerView` ein Hinweis-Overlay mit
  10-Sekunden-Countdown und „Jetzt abspielen"/„Abbrechen"; danach läuft der
  Wechsel über `teardown()` + `item = next` (derselbe Weg wie ⏭), das
  Auflösungsprofil der Vorfolge wird übernommen.
- **Die nächste Folge bestimmt der SERVER** (`GET /api/items/{id}/next-episode`).
  Eine erste Fassung leitete sie clientseitig aus `fetchSeasons` ab und war
  **falsch**: der Seasons-Endpoint expandiert Doppelfolgen in einen Eintrag je
  abgedeckter Folge, beide mit derselben `itemId` — „der nächste Eintrag" traf
  die zweite Hälfte der eigenen Datei, der Autoplay hätte die beendete
  Doppelfolge erneut gestartet. **Regel: Serien-Nachbarschaft nie aus der
  Seasons-Liste herleiten.**
- Anzeigename ist `nextTitle` (TMDB-Folgentitel, Server seit v1.4.15) →
  `metadata.title` → `title`; `Item.title` ist der **Dateiname** (User-Report
  direkt nach dem ersten Test).

## „Vorspann überspringen" (Intro-Skip, Mac/iOS/tvOS)

- Server liefert `introStartSec`/`introEndSec` (absolute Sekunden) **nur** über
  `GET /api/items/{id}`, NICHT über Listen-Endpoints — `PlayerView.loadIntroMarkers`
  holt sie deshalb beim Wiedergabestart per `GoldfishClient.fetchItem(id:)` nach.
- Beide Felder sind in `Models.swift` schon lange vorhanden; neu ist nur die Player-UI.
- `PlayerView.currentTime` ist bereits absolut (`virtualOffset` eingerechnet) — die
  Offset-Korrektur, die der Browser-Player (`maybeToggleIntroSkip`) braucht, entfällt hier.
- Der Knopf liegt als eigenes ZStack-Kind im Videobild (unten rechts), NICHT in der
  Steuerleiste, und ist unabhängig von `controlsVisible` sichtbar.
- Nach einem Klick bleibt er für dieses Item weg (`introSkipUsed`) — `AVPlayer.seek`
  landet sonst gelegentlich knapp VOR dem Ziel und der Knopf flackert zurück.
- tvOS: eigenes `PlayerFocusTarget.introSkip`; beim Erscheinen wird der Fokus gesetzt,
  beim Verschwinden wieder auf `.playPause`/`.videoSurface` zurückgegeben.
- `LocalPlayerView` (lokale/externe Bibliotheken) hat KEINEN Intro-Skip — dort gibt es
  keinen Server, der einen Vorspann erkennen könnte.

