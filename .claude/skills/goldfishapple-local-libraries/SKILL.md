---
name: goldfishapple-local-libraries
description: "Use when working on GoldfishApple local/external libraries (USB, SD cards), the local player, format adaptation, cache limits or buffering - and on password change / the deliberately slim iOS build."
---

# goldfishapple-local-libraries

Lokale Bibliotheken von externen Datenträgern (Player, Formatanpassung, Cache, Puffer) sowie Passwortänderung und die bewusst schlanke iOS-App.

## Harte Regeln

- iOS ist ein reiner Online-Player: alles zu lokalen/externen Bibliotheken ist in `SettingsView.swift` in `#if os(macOS)` gewrappt und existiert im iOS-Build nicht. Downloads sind davon NICHT betroffen (separater Pfad).
- Passwortänderung läuft über `GoldfishClient.changePassword(oldPassword:newPassword:)` (`PUT /api/auth/password`).
- `CFBundleVersion` liegt in `project.yml` (beide Targets) - danach `xcodegen generate` (Entitlements bleiben `<dict/>`).
- Formatanpassung konvertiert nur Dateien mit ECHTEM Re-Encode-Bedarf vorab; reine Remuxe nur, wenn im Cache noch Platz ist.
- `DownloadManager.deleteAllDownloads()` bricht laufende Downloads über `tasks[itemId]?.cancel()` ab, NICHT über `cancelDownload()`.
- Bei Ruckel-Reports zuerst `ps aux | grep ffmpeg` (Zombie-Check) + `lsof +D <externes-Volume>` während der Wiedergabe.

---

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

