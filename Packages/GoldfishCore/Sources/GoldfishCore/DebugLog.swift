import Foundation
import os

/// Zeitweiliger Diagnose-Logger für die Sandbox-Migrations-Tests 2026-09-07 (Vollbild-Start +
/// Downloadordner-Zugriff). Ursprünglich als Datei-Log nach `~/Desktop/goldfish-window-debug.log`
/// gebaut (analog `AppDelegate.logWindowEvent`) — **funktionierte unter App Sandbox NICHT**:
/// `~/Desktop/*` ist ohne die eigene `com.apple.security.files.desktop-folder.read-write`-
/// Entitlement (die dieses Projekt bewusst NICHT hat, siehe GoldfishMac.entitlements — kein
/// Anwendungsfall dafür, nur unnötige zusätzliche Berechtigung fürs App-Review) unter Sandbox
/// blockiert; der `try?`-Write schluckte den Fehler still, die Log-Datei entstand nie (real
/// erlebt: der Downloadordner-Fehler-Alert erschien korrekt, aber keine einzige Log-Zeile
/// landete auf der Platte). `os.Logger`/Unified Logging braucht dagegen KEIN
/// Dateisystem-Entitlement — Ausgabe abrufbar mit
/// `log show --predicate 'subsystem == "com.goldfish.mac"' --last 10m` (oder `log stream`
/// live mitlaufen lassen) direkt vom Terminal aus.
public enum DebugLog {
    private static let logger = Logger(subsystem: "com.goldfish.mac", category: "sandbox-debug")

    public static func write(_ message: String) {
        logger.log("\(message, privacy: .public)")
    }
}
