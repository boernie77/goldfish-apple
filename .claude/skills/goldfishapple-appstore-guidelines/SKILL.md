---
name: goldfishapple-appstore-guidelines
description: "Use when writing anything user-visible for App Store Connect (app name, subtitle, marketing text, description, metadata) for GoldfishApple Mac/iOS/tvOS."
---

# goldfishapple-appstore-guidelines

App-Store-Compliance: die Guideline-5.2.5-Ablehnungen, die Produkt-/Modul-/Bundle-Namen und die Umsetzung.

## Harte Regeln

- Keine Apple-Produktbegriffe (Mac, Apple TV, iPhone, iPad, Watch) als Teil des App-Namens oder als Marketingaussage („für den Mac“). Zwei Ablehnungen nach 5.2.5: tvOS-Untertitel 2026-09-08 und Mac-App-NAME 2026-09-17.
- Eine reine Kompatibilitätsangabe im Beschreibungstext („läuft auf dem Mac“) ist laut Apples Markenrichtlinien erlaubt, wurde nicht beanstandet und bleibt stehen.
- Bundle-ID `com.goldfish.mac` bleibt unverändert - ein Wechsel wäre eine neue App, Bestandsnutzer könnten nicht aktualisieren.
- PRODUCT_NAME/PRODUCT_MODULE_NAME bleiben getrennt: Produkt `Goldfish.app`, Modulname `GoldfishMac`; der Target-NAME bleibt `GoldfishMac` (alle `xcodebuild -scheme GoldfishMac`-Aufrufe bleiben gültig).
- GoldfishTV trägt mit „TV" im Namen dasselbe Risiko - vor dem nächsten tvOS-Update vorsorglich umbenennen.
- Frankreich bleibt als Vertriebsland entfernt (vermeidet eine Dokumenten-Upload-Pflicht).

---

## ⚠ Kein Apple-Produktbegriff im App-Namen (Guideline 5.2.5, 2026-09-17)

Apple lehnte **GoldfishMac 1.0 (235)** ab: *"Terms for Mac in the app name
in an inappropriate manner."* Eine frühere Einschätzung, ein
Plattformbegriff direkt am Produktnamen (Vorbilder wie "CleanMyMac") sei
unkritisch, war damit **falsch** — 2026-09-08 war bereits derselbe Absatz
5.2.5 im tvOS-UNTERTITEL beanstandet worden ("Dein Medienserver für Apple
TV"), diesmal traf es den NAMEN.

**Regel:** in Name, Untertitel, Werbetext und Beschreibung keine
Apple-Produktbegriffe (Mac, Apple TV, iPhone, iPad, Watch) als Teil des
Produktnamens oder als Marketingaussage ("für den Mac") verwenden. Eine
reine Kompatibilitätsangabe im Beschreibungstext ("läuft auf dem Mac") ist
laut Apples Markenrichtlinien erlaubt, wurde hier nicht beanstandet und
blieb daher stehen.

**Umsetzung (Commits `338d09a`/`8b93b22`):**
- Mac-Target in `project.yml`: `PRODUCT_NAME: Goldfish` +
  `PRODUCT_MODULE_NAME: GoldfishMac`. Das Bundle heißt dadurch
  **Goldfish.app** (auch in der Menüleiste, `CFBundleName` = `$(PRODUCT_NAME)`),
  der Swift-Modulname bleibt `GoldfishMac`, die **Bundle-ID
  `com.goldfish.mac` bleibt unverändert** (ein Wechsel wäre eine neue App,
  bestehende Nutzer könnten nicht aktualisieren).
- **Der Target-NAME bleibt `GoldfishMac`** — alle `xcodebuild -scheme
  GoldfishMac`-Aufrufe in dieser CLAUDE.md gelten unverändert. Nur das
  gebaute Produkt liegt jetzt unter `Goldfish.app` statt `GoldfishMac.app`
  (betrifft Skripte/Screenshot-Workflows, die direkt auf
  `GoldfishMac.app/Contents/MacOS/GoldfishMac` zeigten).
- App Store Connect: Name **„Goldfish Desktop"** (Deutsch ist die einzige
  Lokalisierung), Version von 1.0 auf **1.1** umbenannt, Build **1.1 (237)**
  zugewiesen, erneut übermittelt.

**GoldfishTV trägt mit „TV" im Namen dasselbe Risiko** und wurde bisher nur
wegen des Untertitels beanstandet — vor dem nächsten tvOS-Update vorsorglich
umbenennen, statt auf eine zweite Ablehnung zu warten.
