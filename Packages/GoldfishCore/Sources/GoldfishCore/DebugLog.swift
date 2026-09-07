import Foundation

/// Zeitweiliger Diagnose-Logger für die Sandbox-Migrations-Tests 2026-09-07 (Vollbild-Start +
/// Downloadordner-Zugriff) — schreibt in dieselbe Datei wie `AppDelegate.logWindowEvent`
/// (`~/Desktop/goldfish-window-debug.log`), damit beide Diagnosen chronologisch in einem Log
/// landen, ohne über Console.app zu müssen (siehe Memory feedback_nslog_console_unreliable —
/// NSLog/Console.app war schon einmal unzuverlässig). Kann nach Abschluss der Testrunde wieder
/// entfernt werden, ist bewusst simpel gehalten (kein Log-Rotation etc.).
public enum DebugLog {
    private static let url = URL(fileURLWithPath: NSHomeDirectory() + "/Desktop/goldfish-window-debug.log")

    public static func write(_ message: String) {
        let line = "\(Date()) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}
