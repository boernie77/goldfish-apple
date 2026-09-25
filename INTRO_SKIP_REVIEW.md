# Review: „Vorspann überspringen" (Intro-Skip) — Umsetzung von `INTRO_SKIP_PLAN.md`

Reviewer: Opus 5 · Datum: 2026-09-25 · Branch `feature/intro-skip-clients` (Basis `722fb79`)
Grundlage: `git diff` im Arbeitsverzeichnis (nichts gestaged, nichts committet).

## Status

**OK mit kleinen Fixes** — mit einer Einschränkung: **die drei Builds konnten hier nicht
ausgeführt werden** (die Review-Umgebung ist Linux, es gibt weder `xcodebuild` noch eine
Swift-Toolchain). Akzeptanzkriterium 11 des Plans ist damit **offen** und muss auf dem Mac
nachgeholt werden. Alles andere ist „Build-freies Code-Review" — **nicht** „getestet".

Der Plan wurde ansonsten **vollständig und wortgetreu** umgesetzt (Schritte 1–8), ohne
Scope-Creep. Gefunden und selbst behoben habe ich zwei echte tvOS-Fokus-Defekte, die aus der
Wechselwirkung des neuen Knopfes mit bestehendem Code entstehen und im Plan nicht bedacht waren.

## Was tatsächlich geändert wurde

| Datei | Umfang |
|---|---|
| `Sources/GoldfishApp/Player/PlayerView.swift` | 174 Zeilen, **ausschließlich Einfügungen**, keine Löschungen (vor meinen Fixes) |
| `.claude/skills/goldfishapple-detail-view/SKILL.md` | +17 Zeilen (Doku-Abschnitt) |
| `INTRO_SKIP_PLAN.md` | untracked (Plandatei selbst) |

`git diff -- Packages/` ist leer, `grep -rn "introSkip\|introStartSec\|introEndSec" Sources/
Packages/` trifft außerhalb von `PlayerView.swift` nur die schon vorhandenen Modellfelder
(`Models.swift:151/152/293`). Kein `project.yml`, kein `LocalPlayerView`, kein
`NativePlayerView`, kein `PlayerControlsBar`, keine neue Einstellung, keine Lokalisierung,
keine neue Datei (→ `xcodegen generate` zu Recht nicht nötig), kein Commit/Push.

## Gefundene Probleme und was ich behoben habe

### 1. tvOS: Der Auto-Hide-Timer reißt dem sichtbaren Knopf den Fokus weg — BEHOBEN

`PlayerView.swift`, Auto-Hide-Task in `resetAutoHide()` (~Z. 937 ff.).

Beim Ausblenden der Steuerleiste setzte der Task **bedingungslos**
`tvFocusTarget = .videoSurface`. Der Intro-Knopf hängt aber bewusst **nicht** an
`controlsVisible` und bleibt dabei stehen. Konkreter Ablauf: Wiedergabe startet →
`attachObservers` → `resetAutoHide()` startet den Timer; der Vorspann beginnt meist bei ~0 s,
der Knopf erscheint und holt sich den Fokus; **3,5 s später** blendet der Timer die Leiste aus
und zieht den Fokus auf die Videofläche. Da sich `isIntroSkipVisible` dabei **nicht** ändert,
feuert `.onChange(of: isIntroSkipVisible)` nicht mehr — der Knopf bleibt für den Rest des
Vorspanns sichtbar, aber **nicht fokussiert und per Select nicht auslösbar**.

Fix (tvOS-only, eine Zeile plus Kommentar):

```swift
tvFocusTarget = isIntroSkipVisible ? .introSkip : .videoSurface
```

### 2. tvOS: Verzögertes Fokus-Setzen ohne Re-Check — BEHOBEN

`PlayerView.swift`, `.onChange(of: isIntroSkipVisible)` im `body` (~Z. 678 ff.).

Das Setzen des Fokus läuft laut Plan einen Runloop-Tick verzögert
(`Task { @MainActor in await Task.yield(); tvFocusTarget = .introSkip }`). Ist der Knopf in
genau diesem Tick schon wieder verschwunden (⏭ gedrückt, Vorspann-Fenster zu Ende,
Stream-Fehler, „Nächste Folge"-Overlay), zeigt der Fokus auf ein nicht mehr existierendes
Ziel — exakt die Fehlerklasse „verwaister Fokus / nichts mehr auswählbar", die in dieser Datei
mehrfach dokumentiert ist. Fix: `guard isIntroSkipVisible else { return }` vor der Zuweisung.

### 3. Doku-Nachtrag zum Fix 1 — NICHT möglich, bitte manuell nachziehen

Ich wollte den tvOS-Fallstrick aus Fix 1 in
`.claude/skills/goldfishapple-detail-view/SKILL.md` ergänzen (AGENTS.md: neue Erkenntnisse
gehören in den Themenskill). Der Schreibzugriff auf die Datei wurde in dieser Session
verweigert. Vorgeschlagener Zusatz-Bullet im neuen Abschnitt:

> tvOS-Fallstrick: der Auto-Hide-Task in `resetAutoHide()` setzt beim Ausblenden der Leiste
> den Fokus auf `.videoSurface` — das würde ihn dem noch sichtbaren Intro-Knopf wegreißen
> (`.onChange(of: isIntroSkipVisible)` feuert danach nicht mehr). Deshalb dort
> `tvFocusTarget = isIntroSkipVisible ? .introSkip : .videoSurface`.

Außerdem endet die Skill-Datei jetzt mit einer überzähligen Leerzeile (kosmetisch).

## Geprüft und in Ordnung (Negativbefunde, mit Begründung)

- **Grenzwerte / Off-by-one:** `currentTime >= start && currentTime < end` (strikt kleiner am
  Ende, wie im Plan gefordert), zusätzlich `end > start` gegen unsinnige Serverdaten. Nach dem
  Sprung setzt `seek(toAbsolute:)` `currentTime` sofort auf `end` → der Knopf wäre selbst ohne
  `introSkipUsed` weg; das Flag ist zusätzliche Absicherung, kein Fehler.
- **Feldnamen:** `introStartSec`/`introEndSec` stimmen mit `Models.swift:151/152` überein und
  werden in `Item.withWatched` (Z. 293) mitgereicht. Der Client nutzt einen `JSONDecoder` ohne
  `keyDecodingStrategy` und `Item` hat keine `CodingKeys` → die Felder werden nur dekodiert,
  wenn der Server sie **camelCase** liefert. Das ist Bestandscode, nicht Teil dieses Diffs,
  aber die einzige stille Bruchstelle zum Server (siehe offene Punkte).
- **Null-Checks:** `loadIntroMarkers` ist durchgehend best-effort (`try?`), `skipIntro()`
  hat `guard let end`, `isIntroSkipVisible` entpackt beide Optionals. Kein Pfad kann crashen.
- **Generation-Guard:** der Fetch-Pfad prüft `generation == setupGeneration, full.id == item.id`.
  Der frühe Rückgabepfad (`item` hat die Marker schon) prüft die Generation *nicht* — das ist
  hier trotzdem korrekt: `item` ist `@State`, der Zugriff liest den **aktuellen** Wert, es
  können also nie Marker eines *anderen* Items geschrieben werden. Kein Handlungsbedarf.
- **`seek(toAbsolute:)`** statt `player?.seek(...)` → Transcode-Fall (`restartTranscodeSession`)
  und Clamping auf `duration` sind abgedeckt.
- **`PlayerFocusTarget.introSkip`:** es gibt nirgends ein `switch` über den Enum, das neue Case
  kann also keine Exhaustiveness brechen.
- **`#if` in Modifier-Ketten** (im `Label`, hinter dem `Button`, im `body`) entspricht 1:1 dem
  bereits im selben File verwendeten Muster (z. B. Z. 497–510, 1505–1517, 627–633).
- **`.onChange(of:perform:)`** in der Ein-Parameter-Form, wie Z. 721 → macOS-13-tauglich.
- **`#if os(...)`-Grenzen** sauber getrennt; der komplette Fokus-Code steht in `#if os(tvOS)`,
  der Kapsel-Look im `#else`-Zweig. macOS/iOS und tvOS beeinflussen sich strukturell nicht.
- **Konventionen:** Aufbau des Overlays (VStack/Spacer, `.transition(.opacity)`), die
  Fokus-Rückgabe `controlsVisible ? .playPause : .videoSurface` und das
  `Task { await Task.yield() }`-Muster sind identisch zu `nextEpisodeBanner` /
  `cancelNextEpisode()` / `resetAutoHide()`. Deutsche UI-Texte hart im Code, wie im Repo üblich.
- **Öffentliches Repo:** keine echten Namen, Mails, IPs oder Hostnamen im neuen Code.
- **AGENTS.md Regel 10 (Stop-Reports):** `skipIntro()` beendet/wechselt keine Wiedergabe,
  sondern spult nur — ein Stop-Report ist hier korrekterweise nicht fällig.

## Offene Punkte für den Menschen

**Zuerst, blockierend:**

1. **Die drei Builds nachholen** (hier nicht ausführbar), erst danach gilt die Umsetzung als
   fertig:
   ```bash
   xcodebuild -scheme GoldfishMac -configuration Debug -destination 'platform=macOS' build
   xcodebuild -scheme GoldfishiOS -configuration Debug -destination 'generic/platform=iOS Simulator' build
   xcodebuild -scheme GoldfishTV -configuration Debug -destination 'generic/platform=tvOS Simulator' build
   ```

**Nur am echten Gerät prüfbar (UI ist mit Agenten-Mitteln nicht interaktiv testbar):**

2. **Mac:** Folge mit erkanntem Vorspann → Knopf erscheint pünktlich unten rechts, überdeckt
   die Steuerleiste nicht, Klick springt ans Vorspann-Ende, Knopf verschwindet.
3. **Mac/iOS:** Tippen/Klicken **neben** dem Knopf (der Overlay-Container spannt über den
   ganzen Bildschirm) muss die Steuerleiste weiterhin ein-/ausblenden. Spacer sind in SwiftUI
   normalerweise nicht trefferempfindlich, das Untertitel-Overlay setzt trotzdem vorsichtshalber
   `.allowsHitTesting(false)`. Falls Tippen während des Vorspanns tot ist: denselben Modifier
   auf den Overlay-Container legen und den Knopf davon ausnehmen.
4. **iOS (echtes Gerät):** Hoch- und Querformat, Knopf vollständig sichtbar und antippbar.
5. **tvOS:** Knopf erscheint mit sichtbarem Fokusrahmen, Select springt, danach ist die
   Steuerleiste weiterhin normal erreichbar. Wegen Fix 1 explizit prüfen: Knopf muss auch
   **nach** dem automatischen Ausblenden der Leiste (~3,5 s) noch fokussiert sein.
6. **tvOS, bewusste Plan-Entscheidung, bitte bewerten:** Der Knopf zieht den Fokus **immer** an
   sich, auch wenn der Nutzer gerade in der sichtbaren Steuerleiste navigiert (z. B. direkt nach
   dem Scrubben in den Vorspann hinein). Das widerspricht der in `resetAutoHide()` dokumentierten
   Regel „dem User nicht ständig den Fokus wegreißen". Ich habe es nicht geändert, weil der Plan
   es ausdrücklich so vorgibt. Falls es sich am Gerät störend anfühlt: Fokus nur holen, wenn
   `!controlsVisible`.
7. **tvOS:** Während der Knopf den Fokus hat, greifen die `.onMoveCommand`-Handler der
   Videofläche/Leiste nicht — prüfen, ob sich die Steuerleiste mitten im Vorspann trotzdem
   normal aufrufen lässt.
8. **Transcode-Wiedergabe:** Sprung ans Vorspann-Ende außerhalb des Puffers → Session-Neustart.
   Nebenbemerkung: `restartTranscodeSession` meldet für die alte Session keinen Stop (Bestand,
   gilt für jedes Scrubben) — Intro-Skip macht diesen Pfad nur häufiger. Falls serverseitig
   Sessions auflaufen, ist das dort zu betrachten, nicht in diesem Diff.
9. **Serverfeld verifizieren:** Einmal an einer Folge mit bekanntem Vorspann gegenprüfen, dass
   `GET /api/items/{id}` die Felder wirklich als `introStartSec`/`introEndSec` (camelCase)
   liefert — sonst dekodiert der Client sie still als `nil` und es erscheint nie ein Knopf.
10. **⏭ mitten im Vorspann:** Knopf verschwindet, erscheint in der neuen Folge an deren eigener
    Position neu.
11. Doku-Nachtrag aus Punkt 3 oben in den Skill übernehmen.

Nicht committet, nicht gepusht.
