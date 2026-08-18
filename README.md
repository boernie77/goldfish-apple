# Goldfish für Mac & iOS (Prototyp)

Native SwiftUI-App für den Goldfish-Server (dieses Repo: `/Users/christian/Projekte/Videoplayer`).
Zwei Xcode-Targets (`GoldfishMac`, `GoldfishiOS`) teilen sich den gesamten Netzwerk-/
Modell-Code im lokalen Swift-Package `Packages/GoldfishCore`.

## Aktueller Stand (MVP)

- **Login** per Username/Passwort (Cookie-Session, 30 Tage gültig, automatischer
  Session-Check beim App-Start via `/api/auth/status`) **und** per **SSO/Authentik**
  (Button „Mit SSO anmelden" öffnet den Login in einem eingebetteten WKWebView; der
  Server macht den kompletten OIDC/PKCE-Tausch selbst, die App erkennt Erfolg/Fehler
  nur am Redirect-Ziel)
- **Home-Screen** (erster Tab): Fortsetzen / Als nächstes / Zuletzt hinzugefügt pro
  Bibliothek, horizontal scrollbar
- Bibliotheken-Liste → **Ordner-Navigation** (Unterordner als Kacheln, kombiniert mit
  Items auf derselben Ebene) → Detail-Ansicht
- **Staffel-Ansicht** für TV-Bibliotheken: Top-Level-Ordner öffnet automatisch die
  Staffel-Übersicht statt einer flachen Dateiliste, mit Episoden-Liste pro Staffel
- Abspielen via `AVPlayer`/`VideoPlayer` — Direct-Play oder Server-Transcode je nach
  `/api/playback/{id}`-Antwort, inkl. Resume-Position (lesen + alle 15s speichern)
- **Offline-Download**: `/api/download/{id}` lädt die Originaldatei lokal in
  `Application Support/GoldfishDownloads/` — Abspielen danach komplett ohne Netz
  (Player prüft zuerst, ob eine lokale Datei existiert)
- Favorit/Gesehen togglebar

## Bewusst noch nicht drin (nächste Schritte)

- Hintergrund-Downloads (aktuell nur im Vordergrund, bricht ab wenn App beendet wird)
- Downloads laufen nicht automatisch über eine App-Group zwischen iOS und Mac synchron
- Kein Metadaten-Editieren, keine Bulk-Aktionen, keine Suche über Home hinweg

## Projekt öffnen & auf deinem Mac testen

1. **Xcode installiert?** Falls nicht: App Store → „Xcode" installieren (kostenlos).
2. Terminal:
   ```
   cd ~/Projekte/GoldfishApple
   open GoldfishApple.xcodeproj
   ```
3. In Xcode oben links das Scheme **„GoldfishMac"** auswählen (Dropdown neben
   Play-Button), als Ziel **„My Mac"**.
4. **Signierung einmalig einrichten:** Projekt-Navigator → `GoldfishApple` (blaues
   Icon oben) → Target `GoldfishMac` → Tab „Signing & Capabilities" → bei „Team"
   deine Apple-ID auswählen (falls noch keine hinterlegt: Xcode → Settings →
   Accounts → „+" → mit deiner normalen Apple-ID anmelden, **kein** bezahlter
   Account nötig). Xcode erstellt automatisch ein „Personal Team".
5. **⌘R** (oder Play-Button) → App baut und startet direkt auf deinem Mac.
6. Beim ersten Start: Server-Adresse (z. B. `https://goldfish.example.com`),
   deinen Goldfish-Benutzernamen + Passwort eingeben.

Kein 7-Tage-Ablauf, kein App Store nötig — die App bleibt einfach auf deinem Mac,
du kannst sie jederzeit über Xcode neu bauen und starten.

## iOS-Target testen (optional, gleiche Codebasis)

Scheme auf **„GoldfishiOS"** wechseln, als Ziel einen Simulator (z. B. „iPhone 16")
oder dein eigenes iPhone per Kabel/WLAN wählen (dort greift dann die 7-Tage-Grenze,
falls du keinen bezahlten Account hast — für den Simulator nicht relevant).

## Projekt-Struktur

```
GoldfishApple/
├── project.yml                       # xcodegen-Definition (Xcode-Projekt wird daraus generiert)
├── GoldfishApple.xcodeproj/          # generiert, nicht von Hand editieren
├── Packages/GoldfishCore/            # geteilter Code (Mac + iOS)
│   └── Sources/GoldfishCore/
│       ├── Models/Models.swift       # Codable-Structs passend zum Server-JSON
│       ├── Networking/GoldfishClient.swift
│       └── Downloads/DownloadManager.swift
└── Sources/GoldfishApp/              # SwiftUI-UI, für beide Plattformen gemeinsam
    ├── GoldfishApp.swift             # @main
    ├── Views/                        # Login, Libraries, Grid, Detail, Downloads, Settings
    └── Player/PlayerView.swift
```

## Nach Code-Änderungen: Projekt neu generieren

Wenn neue Swift-Dateien/Ordner hinzukommen oder `project.yml` geändert wird:
```
cd ~/Projekte/GoldfishApple
xcodegen generate
```
Xcode danach schließen + neu öffnen falls es offen war.

## Build-Check ohne Xcode-UI (z. B. für Claude/CI)

```
xcodebuild -project GoldfishApple.xcodeproj -scheme GoldfishMac \
  -destination 'platform=macOS' build
xcodebuild -project GoldfishApple.xcodeproj -scheme GoldfishiOS \
  -destination 'generic/platform=iOS Simulator' build
```
