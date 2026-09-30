---
name: goldfishapple-overview
description: "Use when working on the GoldfishApple client basics - product/stack, target layout, GoldfishTV specifics, architecture, or what the app deliberately does not have."
---

# goldfishapple-overview

Produkt/Stack, Target-Layout, GoldfishTV-Details und Architektur des Mac/iOS/tvOS-Clients (Original-Kopfblöcke der CLAUDE.md).

## Harte Regeln

- Keine Apple-Produktbegriffe in Name/Untertitel/Werbetext - Apple hat deswegen zweimal nach Guideline 5.2.5 abgelehnt (Skill `goldfishapple-appstore-guidelines`).
- iOS: eine persistente Leiste (Mini-Player) NIE als `.safeAreaInset` außen um eine `TabView` legen - sie sitzt PRO Tab-Inhalt (`RootView.swift withMusicBar(...)`).
- tvOS: `Menu` in einer Toolbar öffnet zuverlässig NICHTS - immer `.sheet`/`.confirmationDialog`.
- Der Player läuft NICHT als `.sheet`, sondern als eigene `WindowGroup`-Szene (Sheets können kein echtes `NSWindow.toggleFullScreen`).
- macOS-App-Sandbox bleibt AUS, `GoldfishMac.entitlements` muss `<dict/>` bleiben - nach jedem `xcodegen generate` prüfen.
- Nach jeder neuen Datei in `Sources/GoldfishApp/` oder Änderung an `project.yml`: erst `xcodegen generate`, dann bauen.
- Signierung über das bezahlte Team `SYQL3PUXA9` (`-allowProvisioningUpdates`).

---

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

## Startseite (HomeView) — Server-Funktionen ab 1.4.48/1.4.49

- **Serienposter** in allen drei Streifen („▶ Fortsetzen" seit 2026-09-29, „📺 Als nächstes",
  „🆕 Zuletzt hinzugefügt"):
  `ItemCard(preferShowPoster: true)` zeigt bei Folgen `/api/poster/metadata/{parentId}?v=
  {showPosterPath}` — nur wenn der Server `metadata.parentId > 0` UND `metadata.showPosterPath`
  (optional, `omitempty`) liefert, sonst Folgenbild wie bisher.
- **Einheitliche Kacheln** (2026-09-29, nur Startseite): `ItemCard(uniformPosterFrame: true,
  uniformSubtitleLines:)` — jedes Bild füllt die 2:3-Kachel (aspect fill). Items ohne Poster
  (`metadataId` fehlt/0, also private Videos) laden `GoldfishClient.portraitThumbURL(itemId:)`
  = `/api/thumb/{id}?format=portrait` (Server ab 1.4.54: 400×600, Mitte 2:3 aus dem
  Originalvideo, gecacht; Audio/Fehler → normales Vorschaubild, Musik-Cover also mittig
  beschnitten); Serien-/Filmposter wie bisher. ⚠ Die erste Variante (Commit 18a19d5:
  `PosterImage.fitNonPosterImages`, kleines Bild aspect-fit vor unscharfer, abgedunkelter
  Kopie) hat der User als „furchtbar" abgelehnt und ist wieder entfernt — nicht wieder einführen.
  Titel `lineLimit(2, reservesSpace: true)`, darunter feste Zahl einzeiliger Unterzeilen (leere
  Zeile als Platzhalter): `HomeRow` setzt 2, wenn der Streifen ein `isPrivateStyle`-Item hat
  (Kanal + Datum), sonst 1. Bibliotheks-Raster/Suche/Playlists nutzen den Modus NICHT.
- **„Aus „Als nächstes" entfernen"**: `POST /api/home/nextup/{itemId}/hide` (204, 404 = keine
  Folge), blendet die ganze Serie aus, bis man weiterschaut. Kontextmenü nur im
  Als-nächstes-Streifen (`ItemCard.onHideNextUp` → `NextUpHideMenu`); auf tvOS hängt es am
  fokussierbaren `NavigationLink` (Langdruck). Kachel verschwindet lokal erst nach Erfolg.
- **Verweildauer** in `HomeAndNavPreferencesView`: `continueMaxAgeDays`/`nextUpMaxAgeDays` aus
  `GET /api/home/preferences` (fehlend → 0 = unbegrenzt), Schreiben per `PUT /api/home/strips`
  mit nur dem geänderten Feld. Nur 0/7/14/30/60/90/180/365. tvOS-Picker `.navigationLink`,
  sonst `.menu`.
- **Reine Kompilierprüfung ohne Schlüsselbund-Abfrage:** `CODE_SIGNING_ALLOWED=NO
  CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""`; beim Mac-Target zusätzlich
  `EXPANDED_CODE_SIGN_IDENTITY="-"`, sonst scheitert die Skriptphase „Codesign eingebettetes
  ffmpeg/ffprobe" mit „no identity found". iOS/tvOS gegen `generic/platform=… Simulator`.

## Ordner-Sammlungen, Kommissar-Zeile, Ermittler-Katalog, Dateigröße (Server 1.4.57–1.4.68)

Stand 2026-09-30, nur Build + Code-Review (nicht interaktiv getestet).

- **Ordner-Sammlungen:** `GET /api/collections` liefert zusätzlich `kind: "folder"` (negative
  `id`, `libraryId`, `folder`, `drilldown`, `movieCount` = Dateien). `Collection` hat dafür
  optionale Felder + `isFolderCollection`. `CollectionsView` lädt parallel `/api/libraries`
  und pusht `ForcedFolderDestination(library, folder, showsFolderTiles: true)`; Zähler
  „N Dateien", Cover immer `/api/poster/collection/{id}`. Ohne passende Bibliothek →
  Fallback auf die alte Film-Liste (`CollectionDetailView`).
- **`ForcedFolderDestination`** (ItemGridView.swift) statt `FolderDestination`: SwiftUI nutzt
  bei mehrfach registrierten Zielen desselben Typs nur das der Wurzel nächste — das
  TV-Root-Grid hätte sonst eine `ShowSeasonsView` gebaut. Der Wert trägt
  `showsFolderTiles`, jeder Handler baut zustandslos
  `ItemGridView(…, forcedFolderView: true)`. Erzwungene Ansicht = Unterordner-Kacheln auch in
  Film-Bibliotheken, Unterordner bleiben erzwungen (`tile.drilldown` → Kacheln, sonst flach).
- **Kommissar-Zeile:** `Item.episodeGroup`/`episodeGroupFolder` (GoldfishCore, gleiche Regex
  wie `cards.js`). `ItemCard.freeTitleSection` zeigt sie unter SxxExx. iOS/macOS im
  Bibliotheks-Raster: `ItemCard(episodeGroupLibrary:)` → die Karte baut den Item-Link selbst
  nur ums Poster, die Zeile ist ein zweiter `NavigationLink` (ItemGridView darf die Karte
  dann NICHT außen umschließen). tvOS: Kontextmenü „Alle Folgen: <Name>"
  (`CardContextMenu`, ersetzt `NextUpHideMenu`) → `tvGroupTarget` →
  `navigationDestination(isPresented:)`. Nicht verlinkt, wenn der Ordner schon offen ist.
  Kommissar-Ansicht: Default-Sortierung Erstausstrahlung aufsteigend (wenn nichts gespeichert).
  Startseite (einheitliche Kacheln) und `EpisodeTile` (Staffel-Ansicht, kein `relPath`)
  zeigen die Zeile bewusst nicht.
- **Ermittler-Katalog:** `GoldfishClient.fetchCatalog(libraryId:folder:team:)` →
  `CatalogResponse`. Nur in der erzwungenen Ansicht: auf Kommissar-Ebene (Ordner mit `/`)
  Zähler „owned/total Folgen vorhanden" im Kopf und `CatalogMissingCard`-Platzhalter
  (`GridEntry.missing`), bei Sortierung Erstausstrahlung aufsteigend vor die erste Folge mit
  späterem `metadata.releaseDate` einsortiert, sonst hinten; ausgeblendet bei aktiver
  Suche/Filter/Buchstabe. Serien-Wurzel: Abschnitt „Ermittler ohne eigenen Ordner"
  (`CatalogTeamCard` → `CatalogTeamDestination` → `CatalogTeamView`, nur Platzhalter wie im
  Browser). Platzhalter sind auf tvOS fokussierbar (Info-Alert), sonst scrollt die
  Fokus-Engine nicht bis zu Platzhaltern am Rasterende. Views in `CatalogViews.swift`.
- **Dateigröße:** Kacheln zeigen die Größe jetzt (Film: „Jahr · Größe", Privat: „Datum ·
  Größe", Folge: eigene Zeile), abschaltbar per drei lokalen Schaltern unter
  Einstellungen → Darstellung (`DisplaySettings.showSize{Movies,Tv,Private}Key`, Default an).
  Bibliotheksart: `ItemCard(libraryKind:)` aus `ItemGridView`, sonst aus dem Item abgeleitet
  (Folge → Serie, Privat-Stil → Privat, sonst Film).

## Was die App NICHT hat

- Kein Windows/Linux-Target (nur macOS + iOS + tvOS).

