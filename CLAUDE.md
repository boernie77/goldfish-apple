# GoldfishApple — Mac/iOS/tvOS-Client für Goldfish

Native SwiftUI-App für den Goldfish-Server (separates Repo
`github.com/boernie77/goldfish`, lokal `~/Projekte/Videoplayer/`). Drei
Targets — `GoldfishMac`, `GoldfishiOS`, `GoldfishTV` (seit 2026-09-03, Apple
TV, `com.goldfish.tvos`, tvOS 17+) — via `xcodegen` aus `project.yml`,
gemeinsames Swift-Package `GoldfishCore`. Seit 2026-08-19 eigenes Git-Repo
(`github.com/boernie77/goldfish-apple`, privat), getrennt vom Server-Repo.

**Bei jeder Server-API-Änderung prüfen:** `GoldfishCore/GoldfishClient.swift`
(HTTP-Calls) + `GoldfishCore/Models/Models.swift` (Codable-Structs) — ein
umbenanntes JSON-Feld oder ein geändertes Antwortformat kann hier still
brechen (kein automatischer Kompatibilitäts-Check wie bei einem gemeinsamen
Repo). Diese CLAUDE.md hier enthält die volle Architektur-/Bugfix-Chronik;
im Server-Repo (`~/Projekte/Videoplayer/CLAUDE.md`) steht dazu nur noch ein
kurzer Verweis-Block mit den paar wirklich unveränderlichen Dauer-Regeln.

**⚠ Memory-Hinweis:** Einige hier erwähnte Detail-Memories
(`project_apple_tvos_port`, `feedback_apple_versioning.md`,
`project_feature_apple_music_player.md`) wurden in Sessions angelegt, die im
Server-Repo (`~/Projekte/Videoplayer/`) liefen — Claude Codes Memory ist pro
Arbeitsverzeichnis gespeichert, eine Session, die nur in diesem Repo
arbeitet, sieht sie NICHT automatisch. Die durable Fakten daraus sind
deshalb hier in dieser CLAUDE.md dupliziert; für die volle Bugfix-Chronik
(einzeln aufgeschlüsselte Commits pro Runde) ggf. im Server-Repo nachfragen
oder eine neue Memory direkt aus einer Session heraus anlegen, die in
diesem Verzeichnis arbeitet.

## GoldfishTV-Details

- Downloads-Tab seit 2026-09-04 wieder aktiv (ursprüngliche "kein Bedarf"-
  Entscheidung vom User zurückgenommen).
- Kein SSO/WebKit auf tvOS.
- **`Menu`-in-Toolbar öffnet auf tvOS zuverlässig NICHTS** → immer
  `.sheet`/`.confirmationDialog` statt `Menu` für neue tvOS-UI.
- Workaround (kein echter Fix) für den nativen `NavigationLink`-Fokus-Kasten
  auf Poster-Kacheln (überlappte den Titeltext, jetzt per Abstand
  entschärft, der Rahmen selbst ist weiterhin nicht abschaltbar) — vor
  einem erneuten Versuch prüfen, nicht dieselben vier Ansätze wiederholen.

**Seit 2026-09-08 (LIVE v1.1):** eigener Suche-Tab (statt Toolbar-Button,
library-gescoped über `LastLibraryContext`), Serien-/Staffelansicht +
Besetzungsleiste dort komplett vergrößert und die Besetzung jetzt klickbar
(behob nebenbei einen Sprung-zu-Staffel-1-Fokus-Bug), `.focusSection()`
zwischen Besetzungsleiste und Staffel-Grid. Player-Overlay zeigt jetzt
Direct-Play/Transcode-Modus + Qualität an, neue "🎞 Qualität"-Auswahl im
Info-Dialog (behebt: 4K-Filme liefen sonst im Auto-Transcode-Modus ohne
Downscale-Cap und stockten), Tonspur-Umschaltung im Player nutzt jetzt
`.confirmationDialog` statt `Menu` (war dort unzuverlässig), Auto-Hide-Timer
der Steuerleiste resettet jetzt auch bei reiner Fokus-Bewegung.

**Seit 2026-09-10 (iOS v1.2, Build 189, eingereicht):** die "🎞
Qualität"-Auswahl im Info-Dialog (oben, ursprünglich nur tvOS) gibt es
jetzt auch auf iOS (`#if os(tvOS) || os(iOS)`) — Laden/Durchreichen der
Profile lief schon immer plattformübergreifend, nur die UI fehlte. Zweiter,
unabhängiger Fund beim ersten echten iPhone-Test: die App konfigurierte
nirgends eine `AVAudioSession` — Ton blieb je nach Systemzustand (u. a.
Stumm-Schalter) komplett aus, da iOS ohne `.playback`-Kategorie auf
`.soloAmbient` zurückfällt. Fix im `init()` von `GoldfishApp.swift`,
`#if os(iOS)`-gated. Betraf vermutlich auch die bereits live stehende
1.1/187-Version (gleicher, unveränderter Code).

**Seit 2026-09-11 (Build 206):** die "🎞 Qualität"-Auswahl gibt es jetzt
auch auf macOS (`ItemDetailView.swift`, war `#if os(tvOS) || os(iOS)`,
jetzt ungegated) — User-Wunsch, kein technischer Grund für den Ausschluss
(`availableProfiles`/`pickedProfile` liefen schon immer
plattformübergreifend). Gilt für Filme/Serien/Privatvideos. Export-
Compliance-Fallstrick: Frankreich als Vertriebsland musste entfernt werden,
um eine Dokumenten-Upload-Pflicht zu vermeiden.

**Seit 2026-09-11 (iOS 1.3/196), User-Vorgabe "Alles was wir heute für
macOS gebaut haben, soll nun auch in die iOS APP. ALLES":** der bis dahin
Mac-only Musik-Player (eigener `AVPlayer`/Mini-Leiste/Album-Playlist-
Warteschlangen-Ansichten/Favoriten/Offline-Sync/AirPlay/Hintergrund-
Wiedergabe) läuft jetzt komplett auch auf iOS, inkl. Shuffle in Video-
Playlists + feste 2-Spalten-Bibliotheksgrids. Vom User live am echten
iPhone gegengeprüft über mehrere Feinschliff-Runden (Listenansicht/Player/
Sheets/Tab-Leiste/"Zuletzt abgespielt"-Filter), abschließend bestätigt
("Passt so, danke. Perfekt.").

**Wichtiger SwiftUI-Fallstrick:** eine persistente Leiste (Mini-Player)
darf auf iOS NIE als `.safeAreaInset` außen um eine `TabView` gelegt
werden — die native, von UIKit gezeichnete Tab-Leiste bleibt dabei am
Bildschirmrand verankert und wird von der eigenen Leiste optisch UND für
Taps blockiert (kompletter Tab-Wechsel war dadurch unmöglich). Die Leiste
muss stattdessen PRO Tab-Inhalt sitzen (`RootView.swift withMusicBar(...)`,
auf jedes einzelne Tab angewendet) — bei jeder künftigen "Leiste über der
Tab-Leiste"-Anforderung sofort so ansetzen.

## Architektur-Kurzfassung

- macOS: App Sandbox AUS (`GoldfishMac.entitlements` = `<dict/>`, nach
  jedem `xcodegen generate` prüfen, wird sonst zurückgesetzt).
- Player läuft NICHT als `.sheet`, sondern als eigene `WindowGroup(id:
  "player"/"localPlayer")`-Szene (`openWindow(id:)` +
  `PlayerLaunchCoordinator.shared` hält die live Swift-Werte, da
  `RandomContext`/`[Item]` nicht sinnvoll `Codable` für `openWindow(value:)`
  sind) — Sheets unterstützen kein echtes `NSWindow.toggleFullScreen`.
- Custom `AppDelegate` (`Sources/GoldfishApp/AppDelegate.swift`) für
  Window-Lifecycle-Handling, das SwiftUI pur nicht bietet (Dock-Reopen,
  Space-Handling).
- Build: `xcodebuild -scheme GoldfishMac -configuration Debug -destination
  'platform=macOS' build`, dann App-Bundle aus DerivedData auf den Desktop
  kopieren zum Testen (kein Simulator für Mac-Target nötig).
- **Signierung:** bezahlter Account (Team `SYQL3PUXA9`) signiert
  `xcodebuild ... -allowProvisioningUpdates` auch auf echte, per Xcode
  gepaarte Geräte per CLI — verifiziert für `GoldfishiOS` (echtes iPhone)
  UND `GoldfishTV` (echter Apple TV):
  `xcodebuild -scheme <Target> -destination 'id=<devicectl-UDID>'
  -allowProvisioningUpdates build`, danach `xcrun devicectl device install
  app --device <UDID> <Pfad>.app` + `xcrun devicectl device process launch
  --device <UDID> <bundle-id>`. Geräte-UDIDs via `xcrun devicectl list
  devices`. Bei einem künftigen Wechsel zurück auf einen kostenlosen
  Account greift die alte "Free-Personal-Team kann nicht signieren"-
  Einschränkung wieder — dann zuerst prüfen, ob der Account noch bezahlt ist.

## Gelöste Bugs (Kurzfassung — volle Root-Cause-Analyse in DECISIONS.md „GoldfishApple" im Server-Repo)

Chronologisch, Build 0100 (2026-08-19) bis Build 206:
- **Fenster-Verschwinden-Bug**: verwaiste Coordinator-Referenzen +
  Hauptfenster rutschte in einen eigenen Fullscreen-Space. Fix:
  `PlayerLaunchCoordinator` korrekt zurückgesetzt + `window.collectionBehavior`
  explizit gesetzt.
- **„Von Anfang" startete mitten im Video** (Transcode): identischer Root-
  Cause wie im Browser — `&fresh=1` + `_t=<timestamp>` Cache-Bust an die
  Transcode-URL (`PlayerView.transcodeURLWithParams`).
- Per-User-Isolation für lokale Bibliotheken/Downloads/Shuffle-Scope
  nachgezogen (gleiche Fehlerklasse wie der frühere Android-Bug: fehlender
  User-Filter).
- **Bibliotheks-Vorschaubilder offline weg** (Build 165):
  `hydratePreviewsFromCache()` lief nur im Online-Erfolgsfall. Fix: läuft
  jetzt immer, unabhängig vom Netzwerk-Call; Poster pro Bibliothek wird nur
  noch einmalig zufällig gezogen statt bei jedem Öffnen überschrieben.
- **Zufallsmodus-Auto-Weiter** (Build 173): `PlayerView`/`LocalPlayerView`
  starten am Videoende automatisch das nächste Zufallsvideo
  (`jumpRandom(by:1)`/`jump(by:1)`), gleicher Pfad wie ⏭.
- **Gesehene Downloads löschen + Staffel-Gesehen + lokale Sternebewertung**
  (Build 174): Downloads-Toolbar hat „Alle gesehenen löschen";
  `ShowSeasonsView.SeasonCard` markiert eine ganze Staffel auf einmal
  gesehen; lokale Items haben eine 0–3-Sternebewertung.
- **Ton-/Untertitel-Dropdowns im Detail-Dialog + Untertitel-Overlay**
  (Build 179, aktuelle Architektur): `ItemDetailView` hat zwei `Picker`
  (🔊 Tonspur = alle Audiostreams, 💬 Untertitel = nur
  `MediaStream.isDisplayableGeneratedSub`, Bitmap-Subs raus). Streams
  kommen aus `client.playback(itemId:)` (nicht `fetchItem`). Auswahl →
  `preferredAudioIndex`/`preferredSubtitle` in
  `PlayerLaunchRequest`/`PlayerView`. `PlayerView` rendert ein eigenes
  WebVTT-Overlay; `currentTime` ist im Transcode-Modus bereits absolut
  (kein Cue-Shift wie im Browser nötig).
- **Offline→online: „Session abgelaufen" ohne Weg zurück** (Build 166):
  Session wurde nach Reconnect nie neu abgeglichen, 401 wurde fälschlich
  als Connectivity-Fehler behandelt. Fix: `GoldfishClient.isAuthError()`/
  `markSessionInvalid()` + Session-Re-Check bei jedem Vordergrund-Wechsel +
  „Erneut versuchen"-Button.
- **SSO-Login schlug still fehl** (Build 167, WKWebView-Cookie-Timing) +
  **SSO-Sheet war auf macOS leer** (Build 168, `NSViewRepresentable` ohne
  explizite Größe) — zwei unabhängige Bugs auf demselben Flow, Sheet-Bug
  kam zuerst. Fixe: Cookie-Poll bis ~2,5s + explizite Sheet-Größe
  (`minWidth:720, minHeight:760`).
- **Passwort-Manager-AutoFill** (Build 169): `.textContentType(.username/
  .password)` auf den Login-Feldern nachgerüstet.
- **Signierung/Team-ID + Version in `project.yml`** (2026-08-28):
  `DEVELOPMENT_TEAM` + `CFBundleVersion` zentral in `project.yml`.
- **SSO-Kontowechsel unmöglich** (Build 171): `WKWebsiteDataStore` war
  persistent. Fix: Button „Mit anderem Konto anmelden" leert den
  DataStore vor dem Laden. SSO ist immer nur ein aktives Konto
  gleichzeitig; Offline-Kontowechsel bleibt passwort-only.
- Sammlungen sortieren Filme jetzt chronologisch nach Erscheinungsdatum,
  wie im Browser.
- **Gesehen-Status propagierte nicht ans Downloads-Grid**: Downloads-
  Kacheln rendern aus einem beim Download eingefrorenen JSON-Snapshot.
  Fix: `Item.withWatched(_:)` + `DownloadManager.updateCachedWatched(
  itemId:watched:)` an jedem `setWatched`-Call-Site.
- **Tonspur-Auswahl bei Server-Transcode** (Build 176, aktuelle
  Architektur): Auswahl läuft über `PlaybackResponse.streams` +
  `&audio=<index>` an der Transcode-URL, `restartTranscodeSession` an der
  aktuellen Position (Browser-Pendant: Audio-Dropdown im Player-Dialog).
  Zweites `waveform`-Menü in `PlayerControlsBar`, sichtbar bei >1 Spur.
- **Serien-Ordner zeigte Ordner-Kacheln UND rekursiv alle Folgen
  gleichzeitig** (Build 184/185/3, 2026-09-06): der `ShowSeasonsView`-
  Fallback (keine TMDB-Staffel-Struktur, z. B. "Terra X History") übergab
  einen konkreten Ordnerpfad an `ItemGridView` — dort lud
  `effectiveFolder=folder` REKURSIV alle Dateien (der Server kennt kein
  "nur direkte Kinder eines Unterpfads", nur `""`=alles/`"/"`=echte
  Bibliotheks-Root/`"<path>"`=rekursiv darunter), während gleichzeitig
  `showsFolderTiles=true` die direkten Unterordner als Kacheln zeigte —
  dieselben Dateien erschienen doppelt. Fix: die (weiterhin rekursiv
  geladenen) Items werden client-seitig auf echte direkte Kinder gefiltert
  (`relPath` ohne weiteren `/` nach dem `folder`-Präfix), wenn Ordner-
  Kacheln gleichzeitig gezeigt werden.

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

## Was die App NICHT hat

- Kein Windows/Linux-Target (nur macOS + iOS + tvOS).

## Eigenes Passwort ändern + schlanke iPhone-App (Build 181, 2026-09-02)

- **Passwort ändern:** `GoldfishClient.changePassword(oldPassword:
  newPassword:)` (`PUT /api/auth/password`) + „Passwort ändern…"-Button in
  `SettingsView.swift`s Account-Section.
- **iOS als reiner Online-Player:** alles, was **lokale/externe
  Bibliotheken** betrifft, ist in `SettingsView.swift` in
  `#if os(macOS) … #endif` gewrappt und existiert im iOS-Build gar nicht
  mehr. **Downloads sind davon NICHT betroffen** — separater Pfad
  (`PlayerView` + `downloads.localFileURL`).
- **Build-Nummer:** `CFBundleVersion` liegt direkt in `project.yml` (beide
  Targets), danach `xcodegen generate` laufen lassen (Entitlements bleiben
  dabei `<dict/>`).

## Lokale Bibliotheken — Player/Formatanpassung/Puffer (seit 2026-08-24, Stand Build 0153)

Externe Datenträger (USB-Platten, SD-Karten) als lokale Bibliotheken.
Mehrere I/O-Contention-Bugs (Formatanpassung pausierte nicht während
Wiedergabe, Cache-Cap nicht disk-space-aware, Eviction warf teure
Re-Encodes raus, verwaiste ffmpeg-Prozesse, N parallele Thumbnail-Loops)
sind ausgelagert in DECISIONS.md „Lokale Bibliotheken (GoldfishApple)" im
Server-Repo. **Diagnose-Reflex bei künftigen Ruckel-Reports:**
`ps aux | grep ffmpeg` (Zombie-Check) + `lsof +D <externes-Volume>` während
Wiedergabe.

Aktueller Stand (Architektur, bleibt hier):
- **Resume-Dialog**: `LocalLibraryItemsView`-Kachel-Tap fragt wie bei
  Server-Items "Von Anfang/Fortsetzen"
  (`LocalPlayerLaunchRequest.startFromBeginning`).
- **Mauszeiger**: `setHiddenUntilMouseMoves(true)` statt manuellem
  `NSCursor.hide()/unhide()`-Pairing.
- **Formatanpassungs-Priorität**: nur Dateien mit ECHTEM Re-Encode-Bedarf
  (AV1/VP9/…) werden bedingungslos vorab konvertiert; reine Remuxe
  (HEVC/H264/ProRes, `-c:v copy`) nur wenn im Cache noch Platz ist.
  `LocalTranscodeService.beginPlayback()`/`endPlayback()`/
  `waitWhilePlaybackActive()` pausiert die Queue während aktiver Wiedergabe.
- **Cache-Cap**: `maxCacheBytes` (80 GB nominell) + `minFreeBytes` (15 GB)
  über `.volumeAvailableCapacityKey`. Slow/Fast-Klassifizierung
  persistiert in `.slow-classification.json`.
- **Puffer-Regler**: `LocalPlaybackSettings.bufferSecondsKey` (global,
  Default 60s) steuert `AVPlayerItem.preferredForwardBufferDuration`.
- **Auflösung für lokale Items**: `LocalItem.width/height`
  (AVAssetTrack-Probing), gleiche Bucket-Grenzen wie der Server. Wird nur
  beim SCANNEN ermittelt.
- **Downloads fortsetzbar nach Verbindungsabbruch**: `DownloadRecord.
  resumeData`.
- **Löschen im lokalen Player + "Alle Downloads löschen"**: 🗑-Button in
  `LocalPlayerView`/`LocalPlayerControlsBar`; `DownloadManager
  .deleteAllDownloads()` bricht laufende Downloads über
  `tasks[itemId]?.cancel()` ab, NICHT über `cancelDownload()`.

## Apple Musik-Player (seit 2026-09-11, iOS seit Runde 19 User-bestätigt)

Eigener `AVPlayer`/Mini-Leiste/Album-Playlist-Warteschlangen-Ansichten/
Favoriten/Offline-Sync/AirPlay/Hintergrund-Wiedergabe, seit Build 196 auch
auf iOS. Der `.safeAreaInset`+`TabView`-Fallstrick oben ist hier der
wichtigste Merkposten für jede künftige "Leiste über der Tab-Leiste"-
Anforderung.

**🔴→✅ Suche fand keine Titel-Treffer (Bug, gefixt 2026-09-12, iOS 197/Mac
213, User-Report: "wenn ich nach einem Titel gesucht habe, dann kam kein
Treffer. Auch nicht das Album"):** `MusicLibraryView.filteredAlbums`
filterte eine Suche in der Kachel-/Listen-Übersicht (`.grid`/`.list`) bis
dahin ausschließlich gegen `album`/`artist` — nie gegen einen Track-Titel.
Ein Titel-Treffer lieferte dadurch 0 Ergebnisse, auch das enthaltende Album
tauchte nicht auf. Nur im „Alle Titel"-Modus (`filteredTracks`) funktionierte
Titelsuche schon vorher korrekt. Exakt dasselbe Muster wie der zeitgleich
gefixte Server-/Browser-Bug (siehe Server-Repo `CLAUDE.md`/DECISIONS.md,
dort wurde die Album-Bündelung einer Suche komplett durch eine flache
Track-Trefferliste ersetzt). Fix hier identisch: eine aktive Suche
außerhalb von „Alle Titel" zeigt jetzt `allTracksContent`/`filteredTracks`
(matcht Titel+Artist+Album) statt der Album-Kacheln — `allTracks` wird dafür
bei Bedarf lazy nachgeladen (`onChange(of: search)`), nicht erst beim
Umschalten in den „Alle Titel"-Modus. Suchfeld-Prompt entsprechend auf
„Titel, Künstler oder Album durchsuchen" erweitert.

**🔴→✅ Musik-Bibliothekskachel ohne Vorschaubild (Bug, gefixt 2026-09-12,
iOS 198/Mac 214, User-Report: "die Musikbibliothek hat kein Hintergrundbild,
so wie die anderen"):** `LibrariesView.loadPreviews()` holt für die
Bibliotheks-Kachel ein Zufalls-Item und fällt für dessen Vorschaubild auf
`posterURL(metadataId:)` (kein TMDB-Match bei Musik → nil) bzw.
`thumbURL(itemId:)` zurück — Musik-Tracks haben aber NIE ein Thumbnail (der
Scanner überspringt die Thumbnail-Generierung bei Audio komplett, siehe
Server-CLAUDE.md „Musik-Bibliotheken"). Beide Fallbacks lieferten für einen
Musik-Track also grundsätzlich nichts, die Kachel blieb dauerhaft ohne Bild
(kein Cache-File wurde je geschrieben, der `guard`-Fetch schlug still fehl —
heilt sich beim nächsten Start automatisch, kein Cache-Reset nötig). Fix:
neuer erster Fallback über `item.musicAlbumId` +
`client.albumCoverURL(albumId:)` (Album-Cover, existiert bei Musik-Tracks
so gut wie immer). Betrifft `LibrariesView.swift`, gemeinsame Datei für
macOS + iOS.

**🔴→✅ Nachtrag (Build Mac 217/iOS 200, 2026-09-13, User-Report: "auf dem
Mac Vorschaubild trotzdem noch weg"):** der Fix oben half nur für NEU
angelegte Cache-Einträge — `loadPreviews()`s Kurzschluss "Cache-Datei
existiert bereits → nie neu holen" (siehe Kommentar dort, User-Vorgabe
2026-08-28 "genau die aktuellen Bilder sollen gespeichert werden") vertraute
blind jeder bereits vorhandenen `.jpg`-Datei. VOR diesem Fix hatte der
Server für eine Musik-Bibliothek ohne Bild einen SVG-Platzhalter
ausgeliefert ("kein Bild"-Grafik), der unter der `.jpg`-Endung im
Anwendungs-Support-Cache landete — `AsyncImage`/`NSImage` können SVG nicht
decodieren, die Kachel blieb leer, UND der Cache-Existenz-Check ließ nie
erneut fetchen, selbst nach dem Album-Cover-Fix. Live auf dem Produktiv-Mac
verifiziert: `~/Library/Containers/com.goldfish.mac/.../GoldfishLibraryPreviews/
server_13.jpg` enthielt tatsächlich rohes SVG-Markup statt eines Rasterbilds.
Fix: `LibrariesView` prüft jetzt per ImageIO
(`CGImageSourceCreateWithURL`/`-WithData` + `CGImageSourceCreateImageAtIndex`),
ob eine (Cache-)Datei überhaupt ein echtes Rasterbild ist, BEVOR sie
vertraut/verwendet wird — sowohl beim Offline-Hydrieren
(`hydratePreviewsFromCache`) als auch beim eigentlichen `loadPreviews()`-
Cache-Check UND vor dem Schreiben frisch heruntergeladener Daten. Ein
ungültiger Cache-Treffer wird gelöscht statt genutzt, der normale
Fetch-Pfad läuft danach ganz normal weiter. Betroffene Bestands-Caches
(wie der oben gefundene `server_13.jpg`) wurden einmalig manuell vom
Produktiv-Mac gelöscht — künftige gleichartige Fälle heilen sich jetzt
automatisch selbst (kein manueller Eingriff mehr nötig).

**🔴→✅ Musik-Suche auf Mac/iOS fand "senorita" nicht für "Señorita" (Bug,
gefixt Build Mac 217/iOS 200, 2026-09-13, User-Report direkt nach dem
gleichnamigen Server-Fix — "senorita soll Señorita finden" — "gilt für ALLE
Plattformen/Server"):** anders als Browser/Android, die für Suche
ausschließlich `GET /api/items?search=` aufrufen (und damit automatisch von
der neuen server-seitigen `UNACCENT()`-Funktion profitieren, siehe
Server-CLAUDE.md "Akzent-/Diakritika-unempfindlich"), filtert
`MusicLibraryView` (Mac+iOS gemeinsame Datei) Alben/Tracks rein
CLIENT-SEITIG über die bereits geladene, im Speicher gehaltene Liste
(`filteredAlbums`/`filteredTracks`) — nie ein eigener Server-Request pro
Tastenanschlag. `String.localizedCaseInsensitiveContains` ist case-, aber
NICHT akzent-insensitiv ("Señorita" enthält "senorita" laut dieser Methode
nicht), der Server-Fix konnte diesen rein lokalen Filterpfad also gar nicht
erreichen. Fix: neuer `matchesSearch(_:)`-Helper nutzt
`.range(of:options:[.caseInsensitive, .diacriticInsensitive])` statt
`localizedCaseInsensitiveContains`, ersetzt an beiden Filterstellen
(Album-Suche + Track-Suche). Rein lokal in `MusicLibraryView.swift`
gehalten (kein gemeinsamer String-Extension-Helper angelegt — kein zweiter
Aufrufer bisher, YAGNI). **Lektion für künftige "gilt für alle
Plattformen"-Server-Fixes:** IMMER prüfen, ob ein Client den betroffenen
Datenpfad wirklich live vom Server bezieht, oder ob er (wie hier) bereits
geladene Daten zusätzlich noch einmal lokal filtert — ein reiner
Server-Fix erreicht einen solchen zweiten, client-eigenen Filterschritt
nicht automatisch mit.

### Musik-Listenspalten "Zuletzt abgespielt"/"Wiedergaben"/"Hinzugefügt" + Spalten-Auswahl (seit Mac 220, 2026-09-14)

User-Wunsch: "Ich will die Spalten zuletzt abgespielt, wie oft abgespielt
und hinzugefügt noch als Spalten in der Spaltenansicht für Alben und Lieder
haben. Und ein Dropdown, wo ich ausfählen kann, welche Spalten angezeigt
werden. Das ganze auch für MacOS und Linux und auf dem Server. Nicht für
iOS und Apple TV" — Server+Browser bereits als v1.3.26 deployed (siehe
Server-CLAUDE.md „Musik-Bibliotheken"), diese App-seitige Umsetzung ist
**ausschließlich macOS** (`#if os(macOS)`-gated), iOS/tvOS unverändert.

- **Neue Modell-Felder** (`GoldfishCore/Models.swift`, plattformübergreifend,
  aber nur auf macOS konsumiert): `Item.playCount: Int?`,
  `MusicAlbum.addedAt/lastPlayedAt/playCount: String?/String?/Int?` — kommen
  vom bereits erweiterten Server-JSON, reine additive Felder (kein Call-Site
  musste angepasst werden außer `Item.withWatched()`, das den synthetisierten
  Memberwise-Init explizit aufruft und dadurch bei jeder neuen Property
  zwingend mit durchreichen muss).
- **`Sources/GoldfishApp/Music/MusicColumns.swift`** (NEU, komplett
  `#if os(macOS)`): `MusicColumn`-Enum (`artist/album/genre/year/duration/
  count/lastPlayed/playCount/added` — deckt auch die bereits bestehenden
  Spalten mit ab, damit ein einziges Enum für alle drei Kontexte reicht),
  `MusicColumnVisibility` (UserDefaults-Allowlist pro Kontext-String
  `"albums"`/`"allTracks"`/`"albumTracks"`, Komma-getrennte Rohwerte —
  bewusst eine ALLOWLIST wie im Browser: eine neue Spalte ist nie ungefragt
  für Bestandsnutzer sichtbar), `MusicColumnsMenuContent` (wiederverwendbare
  `Toggle`-pro-Spalte-Menü-View, in ein `Menu("☰ Spalten")`/`Menu {...}
  label: Label("Spalten", ...)` eingebettet — SwiftUI rendert `Toggle`s in
  einem `Menu` nativ als ankreuzbare Einträge, kein eigenes Popover nötig).
- **Drei Aufrufstellen, drei unabhängige Sichtbarkeits-Kontexte** (bewusst
  getrennt statt ein globaler Schalter — User-Wunsch nennt "Alben UND
  Lieder", die Spaltenauswahl soll pro Ansicht sinnvoll sein):
  1. **Album-Übersicht-Listenansicht** (`MusicLibraryView.albumContent`,
     Kontext `"albums"`) — `MusicAlbumListHeader`/`MusicAlbumRow` (bereits
     bestehende, per Drag verstellbare Spalten Album/Künstler/Genre/Titel)
     bekamen die drei neuen Spalten als OPT-IN dazwischen (vor der festen
     "Titel"-Zählspalte), inkl. eigener `@AppStorage`-Breiten
     (`musicAlbumListLastPlayedWidth`/…) + demselben
     `MusicColumnResizeHandle`-Drag-Mechanismus wie die bestehenden Spalten.
     Menü sitzt im "Musik-Optionen"-Toolbar-Dropdown, neben dem bestehenden
     Sortierung-/Genre-Untermenü (macOS-Zweig).
  2. **"Alle Titel"** (`MusicLibraryView.allTracksContent`, Kontext
     `"allTracks"`) — hatte bisher gar keine Spaltenstruktur (bloße
     `HStack`-Zeile), die drei neuen Spalten wurden dort als feste,
     NICHT per Drag verstellbare Text-Slots ergänzt (kleinerer Umbau als
     bei der Album-Übersicht gerechtfertigt, da die bestehende Zeile
     ohnehin keine Kopfzeile/Spaltenraster hat) — Menü-Button direkt in der
     bestehenden Aktionsleiste ("Alle abspielen"/"Shuffle"/"Zuletzt
     abgespielt zuerst"), macOS-only via `#if`.
  3. **Album-Detail-Tracklist** (`MusicAlbumDetailView.trackRow`, Kontext
     `"albumTracks"`) — gleiches Muster wie (2): drei feste Text-Slots,
     Menü-Button als eigenes `ToolbarItem` neben "Musik-Optionen".
- **`musicDateLabel(_:)`** (in `MusicLibraryView.swift`, `internal` statt
  `private` — wird auch von `MusicAlbumDetailView.swift` genutzt):
  parst den vom Server gelieferten RFC3339-String (Go's `time.Time`-JSON,
  Format variiert leicht je nach Bruchteilssekunden/Zeitzone) lenient über
  `ISO8601DateFormatter` (zwei Versuche: mit/ohne `.withFractionalSeconds`),
  Fallback auf die ersten 10 Zeichen (`YYYY-MM-DD`) falls beide scheitern,
  `"—"` bei leerem/fehlendem Wert. Zeigt ein kurzes lokalisiertes
  `DateFormatter().dateStyle = .short`-Datum.
- **Refresh-Mechanismus:** `MusicColumnVisibility` liegt in reinem
  `UserDefaults`, SwiftUI beobachtet das nicht automatisch — jede der drei
  Views hat ein eigenes `@State private var musicColumnsRefresh = false`,
  das `MusicColumnsMenuContent` bei jedem Toggle umschaltet; die
  `visible…Columns`-computed-property liest `_ = musicColumnsRefresh`
  zuerst (erzwingt die SwiftUI-Abhängigkeit), dann erst
  `MusicColumnVisibility.visible(for:default:)`.
- **`xcodegen generate` nach dem Anlegen von `MusicColumns.swift` nötig**
  (sonst `error: cannot find type 'MusicColumn' in scope` — der Ordner
  wird per Glob in `project.yml` eingesammelt, eine neue Datei erscheint
  aber erst nach Regenerierung im `.xcodeproj`). Build-Reihenfolge für
  künftige neue Dateien in `Sources/GoldfishApp/`: Datei anlegen →
  `xcodegen generate` → erst dann bauen.
- Build-Reihenfolge geprüft: `GoldfishMac`/`GoldfishiOS`/`GoldfishTV` bauen
  alle drei sauber (Modelländerungen sind gemeinsame Datei, iOS/tvOS
  konsumieren die drei neuen Felder aber nirgends aktiv).

### Startseite: Serien-/Kanalname klickbar → Serien-/Kanalübersicht (seit Mac 219, 2026-09-13)

User-Wunsch: "wenn ich auf der Startseite auf den Seriennamen oder bei
YouTube auf den Kanalnamen klicke, [will ich] zur Serien- bzw.
Kanalübersicht kommen" — explizit nur für Mac (und Linux, eigenes Repo)
angefragt, NICHT iOS/tvOS.

- **Nur macOS geändert.** `ItemCard.titleSection` (`ItemGridView.swift`)
  zeigt bei Episoden den Serien-Namen (`item.showName`) und bei
  Privat-Style-Items den Kanal-/Top-Ordnernamen (`item.channelName`) — beide
  liefen bisher als reiner, unklickbarer `Text` durch. Neuer
  `folderLinkableText(_:folderName:)`-Helper: auf macOS, wenn
  `homeFolderLibrary` (neuer, defaultmäßig `nil`er Parameter) gesetzt ist,
  wird der Text stattdessen in einen `NavigationLink(value:
  FolderDestination(library:, folder:))` gepackt — dieselbe Ziel-Struktur,
  die `ItemGridView` beim normalen Bibliotheks-Browsing schon für
  Ordner-Kacheln nutzt. Auf iOS/tvOS bleibt der Helper ein No-op (reiner
  `Text`), unabhängig vom Parameter — dort wurde nichts angefragt und nichts
  geändert.
- **`homeFolderLibrary` wird ausschließlich von `HomeView` gesetzt**, jeder
  andere Aufrufer (Bibliotheks-Browsing, Suche, Playlists, Downloads,
  Personen-Filmografie) lässt den Parameter auf `nil` — Serien-/Kanalname
  bleibt dort unverändert reiner Text, kein zweiter, potenziell
  verwirrender Navigationspfad neben dem normalen Ordner-Browsing.
- **🔴 Wichtiger Fallstrick, noch VOR dem ersten Build gefunden (kein Live-
  Bug, beim Selbst-Review entdeckt):** `HomeRow`/`HomeHeadingRow` wickeln auf
  iOS/macOS die komplette Kachel (Poster + Titeltext) bisher in EINEN
  äußeren `NavigationLink(value: ItemNavTarget(...))`. Ein verschachtelter
  zweiter `NavigationLink` (Serien-/Kanalname) INNERHALB des Labels dieses
  äußeren Links liefert in SwiftUI/AppKit KEIN zweites, unabhängiges
  Tap-Ziel — nur der äußere Link würde reagieren, der innere wäre tot. Fix:
  auf macOS baut `ItemCard` den Link zum Item jetzt selbst, NUR ums Poster
  (`homeFolderLibrary != nil` → `NavigationLink` intern nur um
  `posterSection`, exakt das gleiche Muster, das für tvOS aus einem anderen
  Grund schon existierte — dort wegen des nativen Fokus-Rahmens). `HomeRow`
  umschließt die Karte auf macOS deshalb NICHT mehr extern (eigener
  `#elseif os(macOS)`-Zweig neben dem bestehenden `#if os(tvOS)`/`#else`),
  sonst wäre exakt dasselbe Verschachtelungsproblem eine Ebene höher wieder
  aufgetreten. iOS bleibt beim alten externen Wrap (unverändert, dort wird
  `homeFolderLibrary` nie gesetzt).
- **`queue: [Item]`-Property auf `ItemCard`** war bisher `#if os(tvOS)`-
  exklusiv (brauchte den internen Link nur dort) — jetzt plattformübergreifend
  verfügbar (Default `[]`), da macOS densel­ben internen-Link-Mechanismus aus
  demselben Grund jetzt auch braucht. Kein Verhaltensunterschied für
  bestehende Aufrufer, die den Parameter nicht setzen.
- **Bibliotheks-Zuordnung pro Item:** "Fortsetzen"/"Als nächstes" mischen
  Items ALLER sichtbaren Bibliotheken flach (`sections.flatMap(...)`) — für
  den Link muss trotzdem die RICHTIGE `Library` jedes einzelnen Items
  bekannt sein. Neuer `HomeView.library(for: Item) -> Library?`
  (Lookup über `sections.first { $0.library.id == item.libraryId }`), als
  `libraryFor`-Closure an `HomeHeadingRow`/`HomeRow` durchgereicht. Für
  "Zuletzt hinzugefügt" (pro Bibliotheks-Sektion, nicht geflacht) reicht der
  triviale `{ _ in section.library }`.
- **Ziel-Auflösung für Privat-Libraries braucht einen Live-Fetch:** anders
  als beim normalen Browsen (wo `ItemGridView` die Geschwister-Ordner-Kacheln
  der aktuellen Ebene schon geladen hat und darüber weiß, ob ein Ordner
  `drilldown` ist — zeigt selbst wieder Unterordner-Kacheln — oder flach
  ist) kennt `HomeView` diese Information nicht. Neue, macOS-exklusive
  `HomeFolderDestinationView` (`HomeView.swift`, `#if os(macOS)`): bei
  `library.isTV` direkt `ShowSeasonsView(library:, folder:)` (der Top-Ordner
  IST hier immer die Serie, kein Fetch nötig — exakt wie
  `ItemGridView.destinationView(for:)`s TV-Zweig). Sonst (Privat-Library)
  einmaliger `client.fetchFolders(libraryId:, parent: nil)`-Root-Fetch,
  Treffer per Name gematcht, `tile.drilldown` entscheidet zwischen
  `ItemGridView(showsFolderTiles: true)` (verschachtelte Kanal-Unterordner)
  und `showsFolderTiles: false` (flache Kanal-Videoliste) — spiegelt exakt
  die Logik, die ein normaler Bibliotheks-Root-Klick auf denselben Ordner
  ergäbe.
- **`.navigationDestination(for: FolderDestination.self)`** neu auf
  `HomeView`s eigenem `NavigationStack` registriert (`#if os(macOS)`) — war
  dort vorher nicht nötig, weil Home bisher nur `ItemNavTarget`-Werte pushte.
  `FolderDestination` ist dieselbe `Hashable`-Struct, die `ItemGridView`
  für sein eigenes, GETRENNTES `NavigationStack` (innerhalb einer bereits
  geöffneten Bibliothek) schon lange nutzt — beide Stacks brauchen ihre
  eigene Registrierung, ein `navigationDestination`-Modifier auf einem Stack
  greift nicht für einen anderen.
- Build getestet (compile-only, kein UI-Live-Test mangels
  Screenshot-Automatisierung für native SwiftUI-Views in dieser Session):
  `GoldfishMac`, `GoldfishiOS` (Simulator-SDK) und `GoldfishTV`
  (Simulator-SDK) bauen alle drei fehlerfrei — bestätigt, dass die
  `#if os(macOS)`-Abgrenzung iOS/tvOS strukturell nicht berührt.
- **✅ Hover-Feedback ergänzt (Mac 221, 2026-09-14, User-Report: "wäre es
  schön, dass wenn man mit der Maus drüber hovert, man ein optisches
  Feedback bekommt, dass es klickbar ist"):** `folderLinkableText`
  (`ItemGridView.swift`) zeigte den Serien-/Kanalnamen bis dahin optisch
  identisch zu normalem, unklickbarem Text — kein Cursor-Wechsel, keine
  Farb-/Unterstreichungs-Änderung. Neues `@State private var
  isHoveringFolderLink` auf `ItemCard` (macOS-only) + `.onHover` auf dem
  `NavigationLink`: Text unterstreicht sich und wechselt auf
  `Color.accentColor`, gleichzeitig `NSCursor.pointingHand.push()`/`.pop()`
  — dieselbe Cursor-Konvention wie `MusicColumnResizeHandle`
  (`MusicLibraryView.swift`, `NSCursor.resizeLeftRight`). Datei brauchte
  dafür einen macOS-gated `import AppKit` (vorher nur `SwiftUI`/
  `GoldfishCore`). `GoldfishMac`/`GoldfishiOS`/`GoldfishTV` bauen weiterhin
  alle drei fehlerfrei (Änderung komplett `#if os(macOS)`-gated).
