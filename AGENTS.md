# GoldfishApple — Projektregeln

> **`CLAUDE.md` ist absichtlich nur der Import-Shim `@AGENTS.md` — nicht beschreiben.**
> Regeln, die in jeder Session gelten, gehören in diese Datei; Detailwissen in einen
> Themenskill unter `.claude/skills/<thema>/SKILL.md`. Ein Wächter-Hook
> (`~/.hermes/hooks/claude_md_shim_guard.py`, registriert in `~/.claude/settings.json`)
> lehnt Schreibzugriffe auf `CLAUDE.md` ab und setzt sie bei Drift automatisch zurück —
> auch nach Änderungen per Editor oder Skript. Claude-Code-Spezifisches, das Hermes
> bewusst nicht sehen soll, gehört nach `.claude/rules/`.

**Diese Datei wird bei jedem Agentenstart vollständig geladen — deshalb kurz halten.**
Detailwissen liegt in den Themenskills (`.claude/skills/`, Tabelle unten), nicht hier. Neue
Erkenntnisse gehören in den passenden Themenskill, nicht in diese Datei; sie ist bewusst unter
der harten 20.000-Zeichen-Ladegrenze von Hermes und unterhalb der von Anthropic empfohlenen
200-Zeilen-Marke.
Der vollständige Text der früheren Sammel-`CLAUDE.md` (Stand 2026-09-20) liegt verbatim im
Skill `goldfishapple-full-archive`.

---

## Produkt & Stack

**GoldfishApple** ist der native SwiftUI-Client für den Goldfish-Server (separates Repo
`github.com/boernie77/goldfish`, lokal `~/Projekte/Videoplayer/`).

- Drei Targets: `GoldfishMac`, `GoldfishiOS`, `GoldfishTV` (tvOS 17+, Bundle-ID
  `com.goldfish.tvos`) — aus `project.yml` via `xcodegen` generiert.
- Gemeinsames Swift-Package **`GoldfishCore`** für HTTP-Client, Modelle und Downloads
  (`Packages/GoldfishCore/Sources/GoldfishCore/`).
- Eigenes Repo `github.com/boernie77/goldfish-apple`, getrennt vom Server-Repo und NICHT mit
  ihm mitversioniert.
- Bundle-IDs: Mac `com.goldfish.mac`, iOS `com.goldfish.iosdev`.

## Harte Verbote (gelten in jeder Session)

Diese Regeln haben schon Geld, Zeit oder eine App-Store-Freigabe gekostet. Nicht relativieren.

1. **Keine Apple-Produktbegriffe** (Mac, Apple TV, iPhone, iPad, Watch) als Teil des
   App-**Namens**, im **Untertitel**, in Werbetext oder Marketingaussage ("für den Mac").
   Apple hat deswegen **zweimal** nach Guideline 5.2.5 abgelehnt: 2026-09-08 (tvOS-Untertitel)
   und 2026-09-17 (Mac-App-**NAME**). Eine reine Kompatibilitätsangabe im Beschreibungstext
   ("läuft auf dem Mac") ist laut Apples Markenrichtlinien erlaubt, wurde nicht beanstandet und
   bleibt stehen. Details: Skill `goldfishapple-appstore-guidelines`.
2. **Bundle-ID `com.goldfish.mac` bleibt unverändert.** Ein Wechsel wäre eine neue App —
   bestehende Nutzer könnten nicht aktualisieren.
3. **iOS: NIE eine persistente Leiste als `.safeAreaInset` außen um eine `TabView` legen.** Die
   nativen, von UIKit gezeichneten Tab-Leiste bleibt am Bildschirmrand verankert und wird von der
   eigenen Leiste optisch UND für Taps blockiert (Tab-Wechsel komplett unmöglich). Die Leiste
   (Mini-Player) sitzt **pro Tab-Inhalt** (`RootView.swift withMusicBar(...)`, auf jedes einzelne
   Tab angewendet).
4. **tvOS: NIE `Menu` in einer Toolbar** — öffnet dort zuverlässig NICHTS. Immer
   `.sheet`/`.confirmationDialog` für neue tvOS-UI.
5. **macOS-App-Sandbox bleibt AUS** und `GoldfishMac.entitlements` muss `<dict/>` bleiben.
   **Nach jedem `xcodegen generate` prüfen** — xcodegen setzt die Datei sonst zurück.
6. **Signierung läuft über das bezahlte Team `SYQL3PUXA9`** (`-allowProvisioningUpdates`). Bei
   einem Wechsel zurück auf einen kostenlosen Account greift die alte "Free-Personal-Team kann
   nicht signieren"-Einschränkung wieder — dann zuerst prüfen, ob das Konto noch bezahlt ist.
7. **Einen absoluten Container-Pfad NIE als einzige Wahrheit persistieren** — immer zusätzlich
   den relativen Dateinamen speichern und gegen das aktuelle Verzeichnis auflösen. (iOS kann die
   App-Container-UUID bei einem Update neu vergeben; Downloads galten danach als "nicht offline".)
8. **Serien-Nachbarschaft NIE aus der Seasons-Liste herleiten** — Doppelfolgen teilen dieselbe
   `itemId`, "der nächste Eintrag" ist die zweite Hälfte der eigenen Datei. Die nächste Folge
   bestimmt der **Server** (`GET /api/items/{id}/next-episode`).
9. **Der Player läuft NICHT als `.sheet`**, sondern als eigene
   `WindowGroup(id: "player"/"localPlayer")`-Szene (`openWindow(id:)` +
   `PlayerLaunchCoordinator.shared`) — Sheets unterstützen kein echtes
   `NSWindow.toggleFullScreen`.
10. **Stop-Reports auf ALLEN Exit-Pfaden** prüfen: jeder Pfad, der eine Wiedergabe beendet oder
    wechselt (Next/Prev/Shuffle/Queue), muss den Stop melden — nicht nur der Schließen-Button.
    Sonst laufen serverseitige Transcode-Sessions bis zu 30 Minuten mit voller Last weiter.

## Repo ist ÖFFENTLICH (MIT)

`boernie77/goldfish-apple` ist öffentlich. Bei jeder Änderung prüfen, ob committeter Code oder
Kommentare echte Namen, E-Mails, interne IPs, Hostnamen oder Secrets enthalten. Platzhalter in
spitzen Klammern (`<UDID>`, `<devicectl-UDID>`, `<Target>`, `<bundle-id>`, `<dict/>`,
`<externes-Volume>`, `<Pfad>`, `<timestamp>`, `<index>`, `<path>`) sind Absicht — **nicht durch
echte Werte ersetzen.**

## Versionierung

- Die App-Targets (`GoldfishMac`/`GoldfishiOS`/`GoldfishTV`) zählen unabhängig vom Server-Repo.
- `DEVELOPMENT_TEAM` und `CFBundleVersion` liegen zentral in `project.yml` (beide Targets).
- Nach jeder Änderung an `project.yml` oder nach dem Anlegen einer **neuen** Datei in
  `Sources/GoldfishApp/`: **`xcodegen generate` laufen lassen, erst dann bauen** (sonst
  `error: cannot find type ... in scope` — der Ordner wird per Glob eingesammelt, eine neue Datei
  erscheint erst nach der Regenerierung im `.xcodeproj`).

## Build & Release

- Mac: `xcodebuild -scheme GoldfishMac -configuration Debug -destination 'platform=macOS' build`,
  danach das App-Bundle aus DerivedData auf den Desktop kopieren zum Testen (kein Simulator für
  das Mac-Target nötig).
- iOS/tvOS auf echte Geräte: `xcodebuild -scheme <Target> -destination 'id=<devicectl-UDID>'
  -allowProvisioningUpdates build` → `xcrun devicectl device install app --device <UDID>
  <Pfad>.app` → `xcrun devicectl device process launch --device <UDID> <bundle-id>`.
  Geräte-UDIDs via `xcrun devicectl list devices`.
- Das gebaute Mac-Produkt heißt **`Goldfish.app`** (nicht mehr `GoldfishMac.app`), der
  **Target-NAME bleibt `GoldfishMac`** — alle `xcodebuild -scheme GoldfishMac`-Aufrufe gelten
  unverändert.
- Hintergrund-`URLSession`-Verhalten nur auf einem echten Gerät verifizieren (Simulator weicht
  ab). tvOS-UI (Fokus, Sheets) ebenfalls nur am echten Apple TV bzw. im tvOS-Simulator prüfen.
- `GoldfishApple.xcodeproj/` ist generiert und git-ignoriert — nie von Hand editieren.

## Vor jedem Commit

- Alle drei Targets bauen lassen, mindestens das geänderte: `GoldfishMac` (macOS),
  `GoldfishiOS` (Simulator-SDK), `GoldfishTV` (Simulator-SDK).
- `#if os(...)`-Grenzen explizit prüfen: Änderungen für macOS dürfen iOS/tvOS strukturell nicht
  berühren (und umgekehrt).
- Kein `git add`/`commit`/`push` ohne ausdrücklichen Auftrag.

## API-Kompatibilität zum Server (stille Brüche)

Die App ist NICHT mit dem Server mitversioniert — es gibt keinen automatischen
Kompatibilitäts-Check wie innerhalb eines gemeinsamen Repos.

**Bei jeder Server-API-Änderung prüfen:**
- `Packages/GoldfishCore/Sources/GoldfishCore/GoldfishClient.swift` (HTTP-Calls)
- `Packages/GoldfishCore/Sources/GoldfishCore/Models/Models.swift` (Codable-Structs)

Ein umbenanntes JSON-Feld oder ein geändertes Antwortformat bricht hier still. Neue Felder
additiv halten; eine neue Property in `Item`/`MusicAlbum` muss in `Item.withWatched()`
mitdurchgereicht werden (der synthetisierte Memberwise-Init ruft sie sonst nicht mit).

## Wiederkehrende SwiftUI-/AppKit-Fallstricke

- Zwei `Button`s in derselben `List`-Zeile reagieren ohne `.contentShape(Rectangle())` gemeinsam
  auf einen Tap — jeder Button braucht seine eigene, klar abgegrenzte Trefferfläche.
- Ein verschachtelter `NavigationLink` innerhalb des Labels eines äußeren `NavigationLink`
  liefert KEIN zweites, unabhängiges Tap-Ziel — der innere wäre tot. Den Link ums Poster bauen,
  nicht um die ganze Karte.
- `UserDefaults`-gesteuerte Sichtbarkeiten (`MusicColumnVisibility`) werden von SwiftUI nicht
  automatisch beobachtet — jede View braucht einen eigenen Refresh-State.
- Die UI ist mit den Mitteln einer Agenten-Session **nicht interaktiv testbar** (kein
  UI-Automatisierungswerkzeug für native macOS-Fenster). Klick-/Hover-Verhalten muss der User im
  echten Fenster gegenprüfen — das ehrlich als "nur Build + Code-Review" ausweisen, nicht als
  "getestet".

## Wo das Detailwissen liegt

| Skill | Wofür |
|---|---|
| `goldfishapple-overview` | Produkt/Stack, Target-Layout, GoldfishTV-Details, Architektur, was die App nicht hat |
| `goldfishapple-bugfix-chronicle` | Gelöste Bugs Build 0100–238, Root-Cause-Kurzfassung, bereits gescheiterte Ansätze |
| `goldfishapple-detail-view` | Detail-Dialog: Auflösung/FSK/Download-Info, Aktions-Reihe, Gesehen-Sync, Autoplay nächste Folge |
| `goldfishapple-background-downloads` | iOS-Hintergrund-Downloads (URLSession background, iOSAppDelegate, completionHandler) |
| `goldfishapple-local-libraries` | Lokale/externe Bibliotheken, lokaler Player, Formatanpassung, Cache/Puffer, Passwort ändern, schlanke iOS-App |
| `goldfishapple-music-player` | Musik-Player: Mini-Leiste, Album-/Titel-Listen, Spalten, Sortierung, Suche, Shuffle, Hörbuch-Erkennung, Offline |
| `goldfishapple-appstore-guidelines` | App-Store-Connect-Texte, Guideline 5.2.5, Produkt-/Modul-/Bundle-Namen |
| `goldfishapple-full-archive` | Vollständiges Original der früheren CLAUDE.md, verbatim — Fallback, wenn etwas fehlt |

Alle Skills liegen unter `.claude/skills/` und sind über den Symlink `.hermes/skills/` auch für
Hermes sichtbar (`.hermes/` ist git-ignoriert). Claude Code liest sie aus `.claude/skills/`,
Hermes nach `hermes skills trust` ebenfalls — eine Datei, zwei Agenten.

## Regel für neue Erkenntnisse

Neue dokumentationswürdige Erkenntnisse gehören **in den passenden Themenskill**, nicht in diese
Datei. Was hier steht, muss bei jeder einzelnen Session relevant sein — alles andere kostet nur
Kontext und senkt die Befolgungsrate.
