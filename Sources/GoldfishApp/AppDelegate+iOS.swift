#if os(iOS)
import UIKit
import GoldfishCore

/// User-Anfrage 2026-09-14: "Downloads sollen im Hintergrund weiterlaufen,
/// auch wenn das Handy in Standby geht" — `DownloadManager` lief bisher
/// (alle drei Plattformen) auf einer normalen Vordergrund-`URLSession`
/// (`.default`), die iOS beim Suspendieren der App abwürgt. Auf iOS nutzt
/// `DownloadManager` jetzt stattdessen eine `URLSessionConfiguration
/// .background(withIdentifier:)`-Session — der eigentliche Byte-Transfer
/// läuft dabei in einem System-Daemon (`nsurlsessiond`), unabhängig vom
/// App-Prozess. Das braucht genau diesen einen Hook: iOS reaktiviert die
/// (ggf. zwischenzeitlich beendete) App per
/// `application(_:handleEventsForBackgroundURLSession:completionHandler:)`,
/// sobald für diese Session Delegate-Callbacks zuzustellen sind (Fortschritt,
/// fertig, Fehler) — ohne diesen Delegate-Callback bekäme die App die
/// Ergebnisse eines im Hintergrund abgeschlossenen Downloads nie zugestellt.
///
/// Der `completionHandler` wird NICHT hier sofort aufgerufen, sondern erst
/// von `DownloadManager.urlSessionDidFinishEvents(forBackgroundURLSession:)`,
/// nachdem alle für diesen Lauf anstehenden Delegate-Aufrufe verarbeitet
/// sind (Datei ins Downloads-Verzeichnis verschoben etc.) — ruft man ihn zu
/// früh auf, darf iOS die App wieder suspendieren, bevor das fertig ist.
final class iOSAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                      handleEventsForBackgroundURLSession identifier: String,
                      completionHandler: @escaping () -> Void) {
        DownloadManager.shared.storeBackgroundCompletionHandler(completionHandler, forIdentifier: identifier)
    }
}
#endif
