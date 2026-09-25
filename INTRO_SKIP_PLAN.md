# Implementierungsplan: „Vorspann überspringen" (Intro-Skip) in GoldfishApple

> **Für das ausführende Modell:** Dieser Plan ist vollständig. Du brauchst KEINEN Zugriff auf
> das Server-Repo (`Videoplayer`) und musst dort nichts nachlesen — alle nötigen Server-Fakten
> stehen unten in „Ausgangslage". Arbeite die Schritte **in der angegebenen Reihenfolge** ab.
> Alle Datei-Zeilennummern beziehen sich auf den Stand **vor** deiner ersten Änderung (Commit
> `722fb79`, Branch `feature/intro-skip-clients`); nach jedem Einfügen verschieben sich die
> folgenden Nummern — orientiere dich deshalb immer zusätzlich an den zitierten Codezeilen,
> nicht nur an der Zahl.

---

## Ausgangslage (bereits vorhanden, NICHT neu bauen)

1. **Datenmodell ist fertig.** `Packages/GoldfishCore/Sources/GoldfishCore/Models/Models.swift`
   Zeile 151–152:
   ```swift
   public let introStartSec: Double?
   public let introEndSec: Double?
   ```
   Beide werden bereits dekodiert und in `Item.withWatched(_:)` (Zeile 293) mitdurchgereicht.
   **An Models.swift ist NICHTS zu ändern.**

2. **Server-Verhalten.** Die beiden Felder liefert NUR `GET /api/items/{id}`
   (Server-Handler `GetItemFor`). Listen-Endpoints (`/api/items`, `/api/items/random`,
   Playlists, Home, Collections) liefern sie **nicht**. Sie sind `null`, wenn es keine
   Erkennung gibt oder kein Vorspann gefunden wurde. Beide Werte sind **absolute
   Sekunden-Positionen im Video**.

3. **Client-Methode existiert schon:**
   `Packages/GoldfishCore/Sources/GoldfishCore/Networking/GoldfishClient.swift` Zeile 537:
   ```swift
   public func fetchItem(id: Int64) async throws -> Item { try await perform("/api/items/\(id)") }
   ```
   **An GoldfishClient.swift ist NICHTS zu ändern.**

4. **Das `Item`, mit dem `PlayerView` geöffnet wird, stammt fast immer aus einer Liste**
   (`ItemGridView`, `PlaylistsView`, `LibrariesView`-Zufall, …) und hat die Intro-Felder
   deshalb typischerweise `nil` — auch wenn der Server sie für dieses Item kennt. Der Player
   muss die Marker daher selbst über `fetchItem(id:)` nachladen (Schritt 4 unten).

5. **Wichtiger Vorteil gegenüber dem Browser:** In `PlayerView` ist `currentTime` **bereits
   absolut**. Der Zeit-Observer rechnet den Transcode-Offset schon ein
   (`PlayerView.swift:1493` → `currentTime = virtualOffset + time.seconds`), und
   `seek(toAbsolute:)` (Zeile 1703) nimmt ebenfalls eine absolute Position entgegen und startet
   bei Bedarf die Transcode-Session neu. **Du musst also KEINE eigene `virtualOffset`-Korrektur
   bauen** — das Pendant zur `maybeToggleIntroSkip`-Offset-Rechnung aus `player.js` existiert
   hier bereits. Vergleiche `introStartSec`/`introEndSec` direkt mit `currentTime`.

6. **Vorbild-Feature im selben File:** „Nächste Folge automatisch starten"
   (`PlayerView.swift`, Zustand ab Zeile 148, Overlay `nextEpisodeBanner(for:)` ab Zeile 1396).
   Genau dieses Muster — `@State`-Flags in `PlayerView`, ein `@ViewBuilder`-Overlay als
   ZStack-Kind, tvOS-Fokus über ein `PlayerFocusTarget`-Case — wird hier 1:1 nachgebaut.

7. **Sprache:** Die App hat **keine** `Localizable.strings`/`.xcstrings` — alle UI-Texte stehen
   hart auf Deutsch im Code (`"Jetzt abspielen"`, `"Abbrechen"`, `"Schließen"`). Der neue Text
   lautet deshalb wörtlich **`"Vorspann überspringen"`**, ohne Lokalisierungs-Infrastruktur.

---

## Alle Änderungen liegen in EINER Datei

`Sources/GoldfishApp/Player/PlayerView.swift` (2281 Zeilen, gemeinsamer Code für
GoldfishMac / GoldfishiOS / GoldfishTV).

**Es wird KEINE neue Datei angelegt** → `xcodegen generate` ist **nicht** nötig (das ist nur
beim Anlegen neuer Dateien in `Sources/GoldfishApp/` oder beim Ändern von `project.yml`
erforderlich).

---

## Schritt 1 — Neue `@State`-Felder anlegen

**Datei:** `Sources/GoldfishApp/Player/PlayerView.swift`
**Stelle:** direkt **nach** Zeile 191 (`@State private var carriedOverProfile: String?`) und
**vor** dem Kommentarblock „Audio-track switcher" (Zeile 193).

Einfügen:

```swift

    // MARK: - „Vorspann überspringen" (Server-Erkennung)

    /// Absolute Start-/Endposition des erkannten Vorspanns in Sekunden, so wie der
    /// Server sie in `GET /api/items/{id}` liefert (`introStartSec`/`introEndSec`).
    /// Beide `nil` = keine Erkennung vorhanden → es gibt keinen Knopf. Sie kommen
    /// NUR über den Item-Endpoint, nicht über die Listen-Endpoints — deshalb werden
    /// sie in `setUp()` eigens nachgeladen (siehe `loadIntroMarkers`).
    @State private var introStartSec: Double?
    @State private var introEndSec: Double?
    /// Gesetzt, sobald der Nutzer in DIESER Wiedergabe einmal auf „Vorspann
    /// überspringen" getippt hat. Der Knopf bleibt danach für dieses Item weg, auch
    /// wenn der Nutzer anschließend wieder in den Vorspann-Bereich zurückspult:
    /// `AVPlayer.seek(to:)` landet ohne Toleranzangabe auch mal ein paar
    /// Zehntelsekunden VOR dem Ziel — ohne dieses Flag könnte der Knopf direkt nach
    /// dem Sprung kurz wieder auftauchen. Wird in `setUp()` pro Item zurückgesetzt.
    @State private var introSkipUsed = false
```

---

## Schritt 2 — Sichtbarkeits-Logik als `private var`

**Stelle:** direkt **nach** der `hasNext`-Property (endet Zeile 307, `}`) und **vor**
`var body: some View {` (Zeile 309).

Einfügen:

```swift

    /// Sichtbarkeit des „Vorspann überspringen"-Knopfes — exakt die Regel des
    /// Browser-Players (`player.js maybeToggleIntroSkip`): sichtbar, solange die
    /// aktuelle Position im erkannten Vorspann-Fenster liegt. `currentTime` ist hier
    /// bereits ABSOLUT (der Zeit-Observer rechnet `virtualOffset` schon ein, siehe
    /// `attachObservers`), also ist im Gegensatz zum Browser keine eigene
    /// Offset-Korrektur nötig.
    private var isIntroSkipVisible: Bool {
        guard !introSkipUsed,
              errorMessage == nil,
              player != nil,
              !didFinishPlayback,
              nextEpisodeItem == nil,
              let start = introStartSec,
              let end = introEndSec,
              end > start else { return false }
        return currentTime >= start && currentTime < end
    }
```

**Warum die einzelnen Guards:**
- `introSkipUsed` → siehe Schritt 1.
- `errorMessage == nil` / `player != nil` → kein Knopf über der Fehlermeldung bzw. über dem
  Lade-Spinner (Player-Wechsel: zwischen `teardown()` und dem nächsten `setUp()` ist `player`
  kurz `nil`).
- `!didFinishPlayback` / `nextEpisodeItem == nil` → am Folgenende hat das
  „Nächste Folge"-Overlay Vorrang; zwei konkurrierende Overlays (auf tvOS zusätzlich zwei
  konkurrierende Fokus-Ziele) wären ein Fehler.
- `end > start` → defensiv gegen unsinnige Serverdaten.

---

## Schritt 3 — Zustands-Reset und Nachladen in `setUp()`

**Datei:** dieselbe. Funktion `setUp()` beginnt Zeile 1083.

### 3a) Reset im Zurücksetz-Block

**Stelle:** direkt **nach** Zeile 1118 (`subtitlesOn = false`) und **vor** dem Kommentar
„Bei jedem Item-Wechsel (⏮/⏭) zurück auf Server-Default" (Zeile 1119).

Einfügen:

```swift
        // Vorspann-Marker gehören zum ITEM — bei jedem Wechsel (⏮/⏭/Zufall/nächste
        // Folge) zurücksetzen, sonst zeigt der Knopf die Werte des vorigen Videos.
        introStartSec = nil
        introEndSec = nil
        introSkipUsed = false
```

### 3b) Nachladen anstoßen

**Stelle:** direkt **nach** dem Trickplay-Block (Zeilen 1124–1126):

```swift
        if item.trickplayStatus == "done" {
            Task { await loadTrickplay() }
        }
```

Einfügen:

```swift
        // Vorspann-Marker holen (siehe `loadIntroMarkers`) — bewusst im Hintergrund
        // wie `loadTrickplay()`: der Wiedergabestart darf darauf nicht warten, und
        // ein Fehlschlag (offline, alter Server) bedeutet einfach „kein Knopf".
        Task { await loadIntroMarkers(generation: myGeneration) }
```

> **Achtung:** `myGeneration` ist die lokale Konstante aus Zeile 1095
> (`let myGeneration = setupGeneration`) — sie steht an dieser Stelle bereits zur Verfügung.
> Diese Zeile muss also **nach** Zeile 1095 stehen (das ist sie automatisch).

> Die Zeile steht bewusst **vor** dem `if let localURL = downloads.localFileURL(...)`-Zweig
> (Zeile 1136), damit sie für Offline-Downloads UND Server-Streaming gleichermaßen läuft.

---

## Schritt 4 — Drei neue private Methoden

**Stelle:** direkt **nach** `nextEpisodeLabel(_:)` (endet Zeile 1469, `}`) und **vor**
`private func attachObservers(to player: AVPlayer)` (Zeile 1471).

Einfügen:

```swift

    // MARK: - „Vorspann überspringen"

    /// Lädt `introStartSec`/`introEndSec` für das aktuell laufende Item.
    ///
    /// Die Felder kommen serverseitig NUR aus `GET /api/items/{id}` (`GetItemFor`),
    /// nicht aus den Listen-Endpoints — das `Item`, mit dem der Player geöffnet
    /// wurde, stammt aber fast immer aus einer Liste und hat sie deshalb `nil`.
    /// Sind sie am vorhandenen `item` ausnahmsweise schon gesetzt (z. B. über den
    /// Detail-Dialog gekommen), spart das den zusätzlichen Abruf.
    ///
    /// Best-effort: schlägt der Abruf fehl (offline, älterer Server), bleiben die
    /// Marker `nil` und es erscheint schlicht kein Knopf — kein Fehlerdialog, keine
    /// Auswirkung auf die Wiedergabe.
    ///
    /// `generation` ist die `setupGeneration` des aufrufenden `setUp()`-Durchlaufs
    /// (gleiches Muster wie dort, siehe den `setupGeneration`-Kommentar oben): ist
    /// inzwischen ein NEUERER Durchlauf gestartet — etwa weil der Nutzer währenddessen
    /// ⏭ gedrückt hat —, dürfen die Marker des alten Items nicht mehr geschrieben
    /// werden.
    private func loadIntroMarkers(generation: Int) async {
        let currentItemId = item.id
        if item.introStartSec != nil, item.introEndSec != nil {
            introStartSec = item.introStartSec
            introEndSec = item.introEndSec
            return
        }
        guard let full = try? await client.fetchItem(id: currentItemId) else { return }
        guard generation == setupGeneration, full.id == item.id else { return }
        introStartSec = full.introStartSec
        introEndSec = full.introEndSec
    }

    /// Klick auf „Vorspann überspringen": ans Ende des Vorspanns springen.
    /// `seek(toAbsolute:)` erledigt dabei beides — den einfachen Sprung bei Direct
    /// Play/Download und, falls die Zielposition außerhalb des bereits
    /// transkodierten Bereichs liegt, den kompletten Neustart der Transcode-Session
    /// (`restartTranscodeSession`). Die Steuerleiste wird bewusst NICHT eingeblendet
    /// (kein `resetAutoHide()`): der Nutzer will weitergucken, nicht bedienen.
    private func skipIntro() {
        guard let end = introEndSec else { return }
        introSkipUsed = true
        seek(toAbsolute: end)
        #if os(tvOS)
        // Der Knopf verschwindet im selben Render-Durchlauf — ohne explizites neues
        // Ziel bliebe der Fokus auf tvOS verwaist hängen (dieselbe Fehlerklasse wie
        // in `resetAutoHide()`/`cancelNextEpisode()` dokumentiert).
        tvFocusTarget = controlsVisible ? .playPause : .videoSurface
        #endif
    }

    /// Der Knopf selbst — auffällig im Videobild unten rechts, NICHT in der
    /// Steuerleiste (Vorbild: der Browser-Player). Er ist bewusst unabhängig von
    /// `controlsVisible`: er erscheint auch, wenn die Steuerleiste gerade
    /// ausgeblendet ist, und rückt nur höher, wenn sie sichtbar ist, damit er sie
    /// nicht überdeckt (gleiches Muster wie das Untertitel-Overlay in `body`).
    @ViewBuilder
    private func introSkipButton() -> some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                Button {
                    skipIntro()
                } label: {
                    Label("Vorspann überspringen", systemImage: "forward.end.alt.fill")
                        #if os(tvOS)
                        .font(.system(size: 28, weight: .semibold))
                        #else
                        .font(.headline)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        #endif
                }
                #if os(tvOS)
                // Auf tvOS bewusst der Standard-Buttonstil: nur der liefert den
                // nativen Fokus-Effekt, an dem der Nutzer per Fernbedienung erkennt,
                // dass der Knopf gerade ausgewählt ist.
                .focused($tvFocusTarget, equals: .introSkip)
                #else
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .background(.black.opacity(0.75), in: Capsule())
                .overlay(Capsule().stroke(.white.opacity(0.65), lineWidth: 1))
                .shadow(color: .black.opacity(0.5), radius: 8, y: 2)
                #endif
            }
            #if os(tvOS)
            .padding(.trailing, 80)
            .padding(.bottom, controlsVisible ? 260 : 120)
            #else
            .padding(.trailing, 28)
            .padding(.bottom, controlsVisible ? 120 : 56)
            #endif
        }
        .transition(.opacity)
    }
```

---

## Schritt 5 — Knopf in `body` einhängen

**Stelle:** in der äußeren `ZStack` von `body`, **nach** dem `#if os(tvOS)` /
`.disabled(!controlsVisible)` / `#endif`-Block, der zur Steuerleisten-`VStack` gehört
(Zeilen 592–598), und **vor** dem Kommentarblock „„Nächste Folge automatisch starten"…"
(Zeile 600) bzw. dem `if let nextEpisodeItem {` (Zeile 606).

Einfügen:

```swift

            // „Vorspann überspringen" (Server-Erkennung, Browser-Pendant:
            // `maybeToggleIntroSkip` in `player.js`): eigenes ZStack-Kind NACH der
            // Steuerleiste, damit der Knopf über ihr liegt und von ihrer
            // `.opacity(...)`/`.disabled(...)`-Behandlung unberührt bleibt — er soll
            // gerade auch bei ausgeblendeter Leiste sichtbar und bedienbar sein.
            // Vor dem „Nächste Folge"-Overlay, das am Folgenende Vorrang hat.
            if isIntroSkipVisible {
                introSkipButton()
            }
```

---

## Schritt 6 — tvOS-Fokus: neues `PlayerFocusTarget`-Case

**Stelle:** im `private enum PlayerFocusTarget: Hashable` (Zeilen 1808–1819), direkt
**nach** `case nextEpisodeCancel` (Zeile 1818) und vor der schließenden `}`.

Einfügen:

```swift
    /// Der „Vorspann überspringen"-Knopf — auf tvOS explizit fokussiert, sobald er
    /// erscheint (Siri Remote hat keinen Zeiger; ohne gesetztes Ziel wäre er nur über
    /// Umwege erreichbar). Siehe `PlayerView.body`, `.onChange(of: isIntroSkipVisible)`.
    case introSkip
```

---

## Schritt 7 — tvOS-Fokus: Ziel setzen und wieder freigeben

**Stelle:** in `body`, direkt **nach** `.task(id: item.id) { await setUp() }` (Zeile 624) und
**vor** `.onDisappear {` (Zeile 625).

Einfügen:

```swift
        #if os(tvOS)
        // Erscheint der Knopf, bekommt er den Fokus — sonst müsste der Nutzer ihn per
        // D-Pad erst suchen, während der Vorspann schon läuft. Ein Runloop-Tick
        // Verzögerung, weil der Knopf im selben Render-Durchlauf noch gar nicht
        // existiert (dieselbe Race wie beim Wieder-Einblenden der Steuerleiste, siehe
        // `resetAutoHide()`). Verschwindet er wieder, MUSS der Fokus explizit
        // weitergereicht werden — ein fokussierter View, der verschwindet, lässt den
        // Fokus auf tvOS sonst verwaist zurück (dokumentierter Fehler in dieser Datei).
        .onChange(of: isIntroSkipVisible) { visible in
            if visible {
                Task { @MainActor in
                    await Task.yield()
                    tvFocusTarget = .introSkip
                }
            } else if tvFocusTarget == .introSkip {
                tvFocusTarget = controlsVisible ? .playPause : .videoSurface
            }
        }
        #endif
```

> **API-Hinweis:** Deployment-Targets sind macOS 13 / iOS 16 / tvOS 17 → benutze die **alte**
> `.onChange(of:perform:)`-Form mit **einem** Closure-Parameter, genau wie oben gezeigt und wie
> bereits in Zeile 657 dieser Datei verwendet. Die neue Zwei-Parameter-Form (`{ old, new in }`)
> würde auf macOS 13 nicht übersetzen.

---

## Schritt 8 — Dokumentation nachziehen (Pflicht laut `AGENTS.md`)

**Datei:** `.claude/skills/goldfishapple-detail-view/SKILL.md`
**Stelle:** ans **Ende** der Datei anhängen (dort steht bereits der Abschnitt
„„Nächste Folge automatisch starten"" — dieselbe Familie von Player-Features).

Anhängen:

```markdown

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
```

---

## Randfälle — so verhalten sie sich (bewusst, nicht nachbessern)

| Fall | Verhalten | Warum es automatisch stimmt |
|---|---|---|
| Server liefert `null`/Felder fehlen | Kein Knopf | `guard let start … let end …` in `isIntroSkipVisible` |
| Kein Netz / alter Server | Kein Knopf, keine Fehlermeldung | `try?` in `loadIntroMarkers` |
| Nutzer pausiert im Vorspann | Knopf bleibt sichtbar | Sichtbarkeit hängt nur an `currentTime`, nicht an `isPlaying` |
| Nutzer spult (Scrubber) | Knopf „friert" während des Ziehens ein, aktualisiert sich beim Loslassen | Der Zeit-Observer aktualisiert `currentTime` bei `isScrubbing` nicht; `onScrubEnd` → `seek(toAbsolute:)` setzt `currentTime` sofort |
| Nutzer spult in den Vorspann hinein | Knopf erscheint (sofern noch nicht benutzt) | rein positionsabhängig |
| Nutzer spult nach dem Skip zurück in den Vorspann | Knopf bleibt weg | `introSkipUsed` — bewusst so (siehe Kommentar in Schritt 1) |
| Transcode-Session, Skip liegt außerhalb des Puffers | Session startet an `introEndSec` neu, Knopf verschwindet | `seek(toAbsolute:)` → `restartTranscodeSession`, setzt `virtualOffset`/`currentTime` auf das Ziel |
| Tonspur-Wechsel (Transcode-Neustart) mitten im Vorspann | Knopf bleibt korrekt | Marker sind absolut und bleiben unverändert; `currentTime` bleibt absolut |
| Wechsel zum nächsten Video (⏮/⏭/Zufall/nächste Folge) | Knopf-Zustand komplett zurückgesetzt | Reset-Block in `setUp()` (Schritt 3a), der über `.task(id: item.id)` bei jedem Item-Wechsel läuft |
| Während des Wechsels (`player == nil`) | Kein Knopf | `player != nil`-Guard |
| Videoende / „Nächste Folge"-Overlay | Kein Knopf | `!didFinishPlayback`, `nextEpisodeItem == nil` |
| Stream-Fehler | Kein Knopf, nur die Fehlermeldung | `errorMessage == nil`-Guard |
| Offline abgespielter Download mit bekannten Markern | Knopf funktioniert normal | `loadIntroMarkers` läuft vor dem Download-Zweig; `virtualOffset` ist dort 0 |

---

## Was NICHT geändert werden darf (Scope-Grenzen)

- ❌ **`Packages/GoldfishCore/**`** — weder `Models.swift` noch `GoldfishClient.swift`. Alles
  Nötige ist vorhanden. Insbesondere **kein** neues Feld an `Item` und **keine** Änderung an
  `Item.withWatched(_:)`.
- ❌ **`Sources/GoldfishApp/Player/LocalPlayerView.swift`** — lokale/externe Bibliotheken haben
  keinen Server und damit keine Vorspann-Erkennung.
- ❌ **`Sources/GoldfishApp/Player/NativePlayerView.swift`** — die Video-Fläche bleibt
  unangetastet (`isUserInteractionEnabled = false` ist ein dokumentierter tvOS/iOS-Fix).
- ❌ **`PlayerControlsBar`** (ab Zeile 1821) — der Knopf gehört ausdrücklich NICHT in die
  Steuerleiste. Keine neuen Parameter an `PlayerControlsBar`.
- ❌ **Musik-Player** (`Sources/GoldfishApp/Music/**`), **Detail-Dialog**
  (`ItemDetailView.swift`), **Downloads**, **Server-Repo**.
- ❌ **`project.yml`** — keine Versions-/Build-Nummern-Bumps, kein `xcodegen generate`
  (es entsteht keine neue Datei).
- ❌ **`CLAUDE.md`** — ist nur der Import-Shim, ein Wächter-Hook lehnt Schreibzugriffe ab.
- ❌ **Keine neue Einstellung/kein Schalter** („Vorspann automatisch überspringen" o. ä.) —
  ausdrücklich nicht Teil dieses Auftrags.
- ❌ **Kein `git add` / `git commit` / `git push`** ohne ausdrücklichen Auftrag des Nutzers.
- ❌ Keine echten Namen, E-Mails, IPs oder Hostnamen in Code/Kommentaren — das Repo ist
  öffentlich (MIT).

---

## Akzeptanzkriterien (Prüfliste für den Reviewer)

1. **Nur eine Produktivdatei geändert:** `git status` zeigt außer
   `Sources/GoldfishApp/Player/PlayerView.swift`,
   `.claude/skills/goldfishapple-detail-view/SKILL.md` und dieser Plan-Datei nichts an.
2. **Kein Datenmodell angefasst:** `git diff -- Packages/` ist leer.
3. `PlayerView` besitzt genau drei neue `@State`-Felder: `introStartSec`, `introEndSec`,
   `introSkipUsed` — alle drei werden in `setUp()` zurückgesetzt
   (`grep -n "introSkipUsed" Sources/GoldfishApp/Player/PlayerView.swift` zeigt mindestens
   Deklaration, Reset in `setUp()`, Guard in `isIntroSkipVisible`, Setzen in `skipIntro()`).
4. **Keine eigene Offset-Rechnung:** im Diff taucht `virtualOffset` **nicht** neu auf; der
   Vergleich läuft direkt gegen `currentTime`.
5. **Sichtbarkeitsregel** entspricht dem Browser: `currentTime >= introStartSec &&
   currentTime < introEndSec` (strikt kleiner beim Ende!), plus die Guards aus Schritt 2.
6. **Knopftext** ist wörtlich `"Vorspann überspringen"`; kein Lokalisierungs-Mechanismus
   eingeführt.
7. **Platzierung:** Der Knopf ist ein eigenes Kind der äußeren `ZStack` in `body`, steht NACH
   der Steuerleisten-`VStack` und VOR `if let nextEpisodeItem`, und ist NICHT Teil von
   `PlayerControlsBar`. Er hängt nicht an `controlsVisible` (nur sein `.padding(.bottom, …)`
   tut das).
8. **Skip-Aktion** ruft `seek(toAbsolute: introEndSec)` auf — nicht `player?.seek(...)` direkt
   (sonst bricht der Transcode-Fall).
9. **tvOS:** `PlayerFocusTarget` hat das neue Case `introSkip`; der Knopf ist mit
   `.focused($tvFocusTarget, equals: .introSkip)` verdrahtet; beim Verschwinden wird der Fokus
   in **beiden** Pfaden (`skipIntro()` und `.onChange(of: isIntroSkipVisible)`) explizit
   weitergereicht.
10. **`.onChange`** verwendet die Ein-Parameter-Form (macOS-13-kompatibel).
11. **Alle drei Targets bauen fehlerfrei** (siehe nächster Abschnitt).
12. `#if os(...)`-Grenzen sauber: der tvOS-Fokuscode steht komplett in `#if os(tvOS)`, der
    Kapsel-Hintergrund des Knopfes im `#else`-Zweig — macOS/iOS und tvOS beeinflussen sich
    strukturell nicht.
13. Die Skill-Datei ist um den Abschnitt „Vorspann überspringen" ergänzt.

---

## Test-/Verifikationsschritte

Alle Befehle **aus dem Repo-Root** ausführen (`.../GoldfishApple`). `xcodegen generate` ist
**nicht** nötig (keine neue Datei, keine `project.yml`-Änderung).

```bash
# 1) macOS-Target
xcodebuild -scheme GoldfishMac -configuration Debug -destination 'platform=macOS' build

# 2) iOS-Target (Simulator-SDK genügt zum Bauen)
xcodebuild -scheme GoldfishiOS -configuration Debug \
  -destination 'generic/platform=iOS Simulator' build

# 3) tvOS-Target (Simulator-SDK genügt zum Bauen)
xcodebuild -scheme GoldfishTV -configuration Debug \
  -destination 'generic/platform=tvOS Simulator' build
```

Alle drei müssen mit `** BUILD SUCCEEDED **` enden. Schlägt einer fehl, ist die Umsetzung
**nicht** fertig — auch dann nicht, wenn die anderen beiden durchlaufen.

Ergänzend (billig, sofort aussagekräftig):

```bash
# Erwartet: keine Treffer außerhalb von PlayerView.swift und der Skill-/Plan-Dateien
grep -rn "introSkip\|introStartSec\|introEndSec" Sources/ Packages/

# Erwartet: leer (Datenmodell unberührt)
git diff --stat -- Packages/
```

### Was NICHT automatisiert testbar ist — ehrlich so ausweisen

Die UI dieser App ist mit Agenten-Mitteln **nicht** interaktiv prüfbar (kein
UI-Automatisierungswerkzeug für native macOS-/tvOS-Fenster). Im Abschlussbericht deshalb
ausdrücklich **„Build + Code-Review"** schreiben, nicht „getestet". Diese Punkte muss der
Nutzer selbst am echten Gerät gegenprüfen — bitte als Liste an ihn weitergeben:

1. **Mac:** Serienfolge mit erkanntem Vorspann starten → Knopf erscheint pünktlich unten
   rechts, überdeckt die Steuerleiste nicht, Klick springt ans Vorspann-Ende, Knopf
   verschwindet.
2. **Mac:** Video ohne Erkennung → es erscheint nie ein Knopf.
3. **iOS (echtes Gerät):** Hoch- und Querformat — Knopf bleibt vollständig sichtbar und
   antippbar, kollidiert nicht mit der Steuerleiste.
4. **tvOS (echtes Apple TV):** Knopf erscheint MIT sichtbarem Fokusrahmen; Select löst den
   Sprung aus; danach lässt sich die Steuerleiste weiterhin normal aufrufen und bedienen
   (kein „nichts mehr fokussierbar"-Zustand).
5. **Transcode-Wiedergabe** (nicht Direct Play): Sprung ans Vorspann-Ende funktioniert auch,
   wenn dort noch nichts gepuffert war (Session-Neustart).
6. **⏭ zur nächsten Folge** mitten im Vorspann: Knopf verschwindet, erscheint in der neuen
   Folge an deren eigener Vorspann-Position neu.
