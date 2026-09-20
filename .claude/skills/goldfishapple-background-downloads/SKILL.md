---
name: goldfishapple-background-downloads
description: "Use when touching GoldfishApple background downloads on iOS (URLSession background session, iOSAppDelegate, completionHandler)."
---

# goldfishapple-background-downloads

Downloads im Hintergrund auf iOS - Hintergrund-`URLSession`, `iOSAppDelegate`, die `completionHandler`-Regel und die akzeptierten Grenzen.

## Harte Regeln

- Nur iOS bekommt die Hintergrund-`URLSessionConfiguration` (`#if os(iOS)`, Identifier `com.goldfish.iosdev.downloads`) - Mac/tvOS bleiben auf `.default`.
- Der `completionHandler` darf NICHT sofort aufgerufen werden - nur aus `DownloadManager.urlSessionDidFinishEvents(forBackgroundURLSession:)`.
- `isDiscretionary = false` (Download startet sofort) + `sessionSendsLaunchEvents = true` bleiben gesetzt.
- Kein spezielles App-Store-Entitlement nötig - `UIBackgroundModes: [audio]` ist ein komplett separater Mechanismus und bleibt unverändert.
- Hintergrund-Session-Verhalten nur auf einem echten Gerät verifizieren - Simulator-Verhalten weicht ab.
- Akzeptierte Grenze: die Compat-Polling-Phase (`prepareThenTransfer`, `Task.sleep`-Schleife) kann eine Hintergrund-Session nicht am Leben halten.

---

## Downloads im Hintergrund weiter (iOS, seit Build 205, 2026-09-14)

- User-Wunsch: "Downloads sollen im Hintergrund weiterlaufen, auch wenn das
  Handy in Standby geht" — `DownloadManager` (`Packages/GoldfishCore/
  Sources/GoldfishCore/Downloads/DownloadManager.swift`, geteilt für alle
  drei Plattformen) lief bisher überall auf einer normalen Vordergrund-
  `URLSession` (`.default`), die iOS beim Suspendieren der App abwürgt —
  ein Download blieb dann einfach stehen, bis die App wieder aktiv war.
- **Nur iOS bekommt eine `URLSessionConfiguration.background(withIdentifier:
  "com.goldfish.iosdev.downloads")`** (`#if os(iOS)` in `DownloadManager
  .init()`), Mac/tvOS bleiben unverändert bei `.default` — kein bekannter
  Bedarf dort (Mac läuft ohnehin durchgehend, tvOS hat kein "Standby" im
  gleichen Sinn). `isDiscretionary = false` (der Download soll sofort
  losgehen, nicht erst zu einem vom System gewählten "günstigen" Zeitpunkt)
  + `sessionSendsLaunchEvents = true`.
- **Neuer `iOSAppDelegate`** (`Sources/GoldfishApp/AppDelegate+iOS.swift`,
  analog zum bestehenden macOS-`AppDelegate.swift`, per
  `@UIApplicationDelegateAdaptor` in `GoldfishApp.swift` eingehängt):
  implementiert `application(_:handleEventsForBackgroundURLSession:
  completionHandler:)` — der einzige Hook, den iOS braucht, um die
  (ggf. zwischenzeitlich beendete) App zu reaktivieren, sobald für die
  Hintergrund-Session Delegate-Callbacks zuzustellen sind. Reicht den
  `completionHandler` nur an `DownloadManager.storeBackgroundCompletion
  Handler(_:forIdentifier:)` durch.
- **⚠ Der `completionHandler` darf NICHT sofort aufgerufen werden** — erst
  `DownloadManager.urlSessionDidFinishEvents(forBackgroundURLSession:)`
  (neuer Delegate-Callback, feuert nachdem ALLE für diesen Lauf
  ausstehenden Delegate-Aufrufe verarbeitet sind) ruft ihn auf. Vorher
  aufrufen würde iOS erlauben, die App wieder zu suspendieren, bevor z. B.
  die fertige Datei ins Downloads-Verzeichnis verschoben wurde.
- **Kein spezielles App-Store-Entitlement nötig** (anders als z. B.
  Background-Audio/VoIP) — nur die Background-Session-Config + der
  Delegate-Hookup. `UIBackgroundModes: [audio]` (siehe Musik-Player-Sektion)
  bleibt unverändert, ist ein komplett separater Mechanismus.
- **Bekannte, akzeptierte Grenze:** die Compat-Formatanpassungs-Polling-
  Phase (`prepareThenTransfer`, pollt `compat-status` alle 2 s) ist eine
  reine `Task.sleep`-Schleife, KEINE `URLSessionTask` — eine Hintergrund-
  Session kann sie nicht am Leben halten. Wird die App suspendiert, während
  der Server eine Datei noch remuxt/transkodiert (`?compat=1`, kann bei
  großen Blu-ray-Rips mehrere Minuten dauern), pausiert das Polling und
  läuft erst beim nächsten Vordergrund-Aufenthalt weiter — GENAU wie
  bisher. Sobald der eigentliche Byte-Transfer gestartet ist
  (`launchTransfer`), läuft er unabhängig vom App-Zustand bis zum Ende
  weiter, das ist der eigentlich angefragte Fall (großer, bereits
  angelaufener Download beim Sperren des Handys).
- **Serverseitig kein Risiko analog der Transcode-Session-Saga**: ein
  Download ist für den Server nur ein HTTP-GET, kein laufender ffmpeg-
  Prozess, der "vergessen" werden könnte — der Download-Cache räumt sich
  ohnehin nach Fristen selbst auf (Server-CLAUDE.md „Download & Löschen" →
  Cache-Fristen), und die Compat-Formatanpassung ist bereits gegen
  mehrfaches Anstoßen abgesichert (`maxConcurrentPreps` + Single-Flight
  pro Datei).
- **Test-Status:** kompiliert für iOS-Device-Architektur (`xcodebuild
  -destination 'generic/platform=iOS'`) und für macOS — echtes
  Hintergrund-Session-Verhalten lässt sich nur auf einem echten Gerät
  verifizieren (Simulator-Verhalten für Background-URLSession weicht ab),
  noch nicht auf dem echten iPhone getestet.

