---
name: goldfishapple-bugfix-chronicle
description: "Use when a GoldfishApple bug looks familiar or you need the build-by-build fix history (Build 0100-238) before re-investigating a root cause."
---

# goldfishapple-bugfix-chronicle

Chronik der gelösten Bugs von Build 0100 (2026-08-19) bis Build 238, inkl. Root-Cause-Kurzfassung und bereits gescheiterter Ansätze. Die volle Analyse liegt in DECISIONS.md „GoldfishApple" im Server-Repo.

## Harte Regeln

- Einen absoluten Container-Pfad NIE als einzige Wahrheit persistieren - immer zusätzlich den relativen Dateinamen speichern und gegen das aktuelle Verzeichnis auflösen (iOS vergibt die Container-UUID bei einem Update neu).
- `PlayerView.teardown()` muss den Stop auf JEDEM Exit-Pfad melden (Next/Prev/Shuffle/Queue), nicht nur `closePlayer()` - guarded durch `playbackStopReported` + `isServerPlayback`.
- `MusicPlayerEngine` ruft `reportStopForCurrentTrack(client:)` vor JEDEM Track-Wechsel auf - ein neuer Player-Pfad ohne Stop-Report hält serverseitige Transcode-Sessions bis zu 30 Min. am Leben.
- Vor einem erneuten Anlauf einen alten Eintrag lesen: einige Ansätze wurden schon probiert und verworfen (z. B. der tvOS-Fokus-Rahmen auf Poster-Kacheln).
- Ein neuer `#if`-gegateter Fix für macOS darf iOS/tvOS strukturell nicht berühren - nach jeder Änderung alle drei Targets bauen.

---

## Gelöste Bugs (Kurzfassung — volle Root-Cause-Analyse in DECISIONS.md „GoldfishApple" im Server-Repo)

Chronologisch, Build 0100 (2026-08-19) bis Build 207:
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
- **Downloads nach App-Update nicht mehr als offline erkannt** (iOS
  1.7/207, 2026-09-17): `DownloadRecord.filePath` speichert einen
  ABSOLUTEN Pfad inkl. der App-Container-UUID. iOS kann diese UUID bei
  einem App-Update neu vergeben — die Datei liegt dann physisch
  unverändert im (neuen) Downloads-Verzeichnis, der gespeicherte Pfad
  zeigt aber ins Leere. `isDownloaded()` lieferte `false`, die App bot nur
  „Abspielen" (Streaming) statt „Offline abspielen". Fix:
  `DownloadManager.localFileURL(itemId:)` fällt auf
  `downloadsDir + rec.fileName` zurück (gleiches Muster wie der bestehende
  Fallback in `didFinishDownloadingTo`). **Regel: nie einen absoluten
  Container-Pfad als einzige Wahrheit persistieren** — immer auch den
  relativen Dateinamen speichern und gegen das aktuelle Verzeichnis
  auflösen.

