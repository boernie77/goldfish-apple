# Goldfish für Mac, iPhone/iPad & Apple TV

Native SwiftUI-App für den [Goldfish-Videoserver](https://github.com/boernie77/goldfish)
(selbstgehostet, Jellyfin-light). Drei Xcode-Targets — **GoldfishMac**,
**GoldfishiOS**, **GoldfishTV** — teilen sich den kompletten Netzwerk-/
Modell-/Download-Code im lokalen Swift-Package `Packages/GoldfishCore`.

## ✅ Offiziell im App Store

Alle drei Plattformen sind unter dem gemeinsamen App-Store-Eintrag
**„Goldfish Media"** veröffentlicht (App Store durchsuchen nach „Goldfish
Media" — oder auf iPhone/iPad/Mac/Apple TV direkt im App Store danach
suchen). Aktueller Stand:

| Plattform | Version | Bemerkung |
|---|---|---|
| iOS/iPadOS | 1.3 | reiner Online-Player + Downloads, inkl. vollem Musik-Player |
| macOS | 1.0 | zusätzlich lokale/externe Bibliotheken + Formatanpassung |
| tvOS (Apple TV) | 1.1 | Fokus auf Wiedergabe + Downloads, kein SSO/WebKit |

Für den eigenen Gebrauch reicht die Installation aus dem App Store — dieses
Repo ist für **Entwicklung/Weiterbau** gedacht (neue Features, Bugfixes,
lokale Test-Builds vor der nächsten Store-Einreichung).

## Features (Kurzüberblick)

- **Login**: Email/Passwort oder SSO über Authentik (eingebettetes WebView,
  nur Mac/iOS — tvOS hat kein WebKit).
- **Home-Screen**: Fortsetzen / Als nächstes / Zuletzt hinzugefügt pro
  Bibliothek, plus eigener Such-Tab (library-gescoped).
- **Bibliotheks-/Ordner-Navigation** inkl. **Staffel-Ansicht** für Serien
  (Poster, Cast-Leiste, Episoden pro Staffel).
- **Player**: Direct Play/Server-Transcode je nach `/api/playback/{id}`,
  Qualitäts-Auswahl, Ton-/Untertitel-Umschaltung (inkl. KI-/OCR-generierter
  Untertitel), Trailer-Wiedergabe (YouTube, per `yt-dlp`-Server-Extraktion),
  Resume-Position.
- **Downloads/Offline**: Video- und Musik-Downloads, komplett ohne
  Netzwerk abspielbar.
- **Musik-Player** (Mac + iOS): eigener Mini-Player mit Warteschlange,
  Playlists, Favoriten, Offline-Sync, AirPlay, Hintergrund-Wiedergabe —
  funktional an Apple Music/Spotify angelehnt.
- **Gesehen-Sync zwischen zwei Accounts** (z. B. zwei Familienmitglieder),
  respektiert dabei die Library-ACL + FSK-Grenze des Partners.
- **Nur macOS**: lokale/externe Bibliotheken (USB-Platten etc.) mit
  automatischer Formatanpassung/Puffer-Verwaltung, unabhängig vom Server.
- **Nicht enthalten** (bewusst): Admin-Bereich (Nutzerverwaltung,
  Library-Manager, Scan-Steuerung) — das bleibt Browser-only.

## Projekt öffnen & lokal bauen

1. **Xcode installiert?** Falls nicht: App Store → „Xcode" (kostenlos).
2. Terminal:
   ```bash
   cd ~/Projekte/GoldfishApple
   open GoldfishApple.xcodeproj
   ```
3. Scheme oben links wählen: **GoldfishMac** (Ziel „My Mac"), **GoldfishiOS**
   (Ziel: Simulator oder eigenes iPhone) oder **GoldfishTV** (Ziel:
   tvOS-Simulator oder eigenes Apple TV).
4. **Signierung**: Projekt-Navigator → `GoldfishApple` → jeweiliges Target →
   Tab „Signing & Capabilities" → Team auswählen. Mit einem kostenlosen
   Apple-Account läuft die App nur auf dem Simulator bzw. 7 Tage auf einem
   angeschlossenen eigenen Gerät; mit einem bezahlten Entwickler-Account
   (hier: Team `SYQL3PUXA9`) funktioniert auch die dauerhafte Installation
   auf echten Geräten sowie App-Store-Einreichungen.
5. **⌘R** → App baut und startet.

Beim ersten Start: Server-Adresse (z. B. `https://goldfish.example.com`),
Goldfish-Benutzername + Passwort eingeben (oder „Mit SSO anmelden", falls am
Server konfiguriert).

## Auf ein echtes iPhone/Apple TV installieren (ohne Xcode-UI)

Mit dem bezahlten Team (`SYQL3PUXA9`) funktioniert die komplette Kette auch
rein über die Kommandozeile — praktisch für schnelle Testzyklen:

```bash
# Geräte-UDID herausfinden
xcrun devicectl list devices

# Bauen + signieren
xcodebuild -project GoldfishApple.xcodeproj -scheme GoldfishiOS \
  -destination 'id=<UDID>' -allowProvisioningUpdates build

# Installieren + starten (Pfad zur .app aus dem xcodebuild-Output, i. d. R.
# unter ~/Library/Developer/Xcode/DerivedData/.../Build/Products/Debug-iphoneos/)
xcrun devicectl device install app --device <UDID> <Pfad-zur-App>.app
xcrun devicectl device process launch --device <UDID> com.goldfish.iosdev
```

Für `GoldfishTV` analog, Bundle-ID `com.goldfish.tvos`.

## Projekt-Struktur

```
GoldfishApple/
├── project.yml                       # xcodegen-Definition (3 Targets: Mac/iOS/TV)
├── GoldfishApple.xcodeproj/           # generiert, nicht von Hand editieren
├── Packages/GoldfishCore/             # geteilter Code (alle 3 Plattformen)
│   └── Sources/GoldfishCore/
│       ├── Models/                    # Codable-Structs passend zum Server-JSON
│       ├── Networking/                # GoldfishClient
│       ├── Downloads/                 # DownloadManager (Video + Musik)
│       ├── Local/                     # lokale/externe Bibliotheken (nur Mac)
│       └── Trickplay/                 # Hover-Vorschau-Sprites
└── Sources/GoldfishApp/                # SwiftUI-UI
    ├── GoldfishApp.swift               # @main
    ├── Views/                          # Login, Libraries, Grid, Detail, Home, Suche, …
    ├── Music/                          # eigenständiger Musik-Player (Mac + iOS)
    ├── Player/PlayerView.swift         # Video-Wiedergabe (AVPlayer)
    └── Resources/                      # Assets, Info.plists, ffmpeg-Binaries (nur Mac)
```

## Nach Code-Änderungen: Projekt neu generieren

Wenn neue Swift-Dateien/Ordner hinzukommen oder `project.yml` geändert wird:
```bash
cd ~/Projekte/GoldfishApple
xcodegen generate
```
Xcode danach schließen + neu öffnen, falls es offen war. **Achtung:**
`GoldfishMac.entitlements` (App Sandbox) nach jedem `generate` prüfen — wird
gelegentlich zurückgesetzt, siehe Kommentare in der Datei.

## Build-Check ohne Xcode-UI (z. B. für CI/Claude)

```bash
xcodebuild -project GoldfishApple.xcodeproj -scheme GoldfishMac \
  -destination 'platform=macOS' build
xcodebuild -project GoldfishApple.xcodeproj -scheme GoldfishiOS \
  -destination 'generic/platform=iOS Simulator' build
xcodebuild -project GoldfishApple.xcodeproj -scheme GoldfishTV \
  -destination 'generic/platform=tvOS Simulator' build
```

## Neue Version einreichen (Kurz-Checkliste)

1. Version/Build in `project.yml` für das betroffene Target hochzählen
   (`CFBundleShortVersionString`/`CFBundleVersion`), danach `xcodegen generate`.
2. Auf einem echten Gerät verifizieren (siehe oben), nicht nur im Simulator —
   gerade Audio-/Berechtigungs-Bugs zeigen sich oft nur auf echter Hardware.
3. In App Store Connect: neue Version über den „+"-Button neben der
   jeweiligen Plattform anlegen (nicht die bereits „Bereit für Vertrieb"
   stehende Version editieren), Build zuweisen, „Neues in dieser Version"
   ausfüllen, Export-Compliance-Fragen beantworten, zur Prüfung einreichen.
4. Bei bereits **live** stehenden Versionen ist die Beschreibung selbst
   NICHT mehr direkt editierbar — nur der Werbetext. Eine geänderte
   Beschreibung braucht immer eine neue Versionseinreichung.
