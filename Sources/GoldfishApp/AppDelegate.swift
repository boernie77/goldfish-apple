#if os(macOS)
import AppKit

/// Real bug hit 2026-08-19 (User-Anfrage): closing the player window (now a genuine separate
/// `WindowGroup(id: "player")`, see `GoldfishApp.swift`'s doc comment) left the app with no
/// visible window at all — clicking the Dock icon again did nothing, because a plain SwiftUI
/// `App` with no `NSApplicationDelegate` doesn't implement the standard AppKit "reopen the
/// main window when the Dock icon is clicked and no windows are visible" behavior on its own.
/// This is the minimal, standard fix: bring the main (non-player) window back to front, or —
/// if it was closed too — open a fresh one via the same mechanism the Dock icon would
/// otherwise fail to trigger.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Real bug hit 2026-08-19 (User-Anfrage: "beim Verkleinern des Players verschwindet die
    /// App" — 0085's Dock-reopen-Fix half nicht, weil das Problem beim MINIMIEREN liegt, nicht
    /// beim Schließen). macOS gruppiert standardmäßig mehrere Fenster derselben App
    /// automatisch zu Tabs EINES Fensters (`NSWindow.allowsAutomaticWindowTabbing`, an sich
    /// für Dokumentfenster gedacht) — bei mehreren `WindowGroup`-Fenstern wie hier (Haupt-
    /// fenster + Player) kann das dazu führen, dass sie sich als Tabs desselben Fensters
    /// verhalten: Minimieren "des Players" minimiert dann das GANZE Fenster inkl. aller
    /// Tabs, also auch das Hauptfenster — sieht aus wie "die App verschwindet komplett".
    /// Global deaktiviert beim App-Start, damit jedes Fenster unabhängig bleibt.
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] notification in
            self?.handlePlayerWindowClosing(notification)
        }
        // User-Anfrage 2026-08-19: "beim Schließen erscheint wieder die App, beim Verkleinern
        // sieht man aber den Desktop" — der Close-Handler oben deckt nur `willClose` ab.
        // Minimieren des Players ist ein komplett separates Event (`didMiniaturize`), das
        // vorher nur geloggt, nie behandelt wurde. Gleiche Fix-Logik wie beim Schließen.
        NotificationCenter.default.addObserver(forName: NSWindow.didMiniaturizeNotification, object: nil, queue: .main) { [weak self] notification in
            self?.handlePlayerWindowMinimizing(notification)
        }

        // Real gap hit 2026-08-19: six fix attempts in a row didn't resolve "app disappears",
        // AND the NSLog-based diagnostic ("filter Console.app for GoldfishWin") never showed a
        // single line even while actively streaming and reproducing — Console.app itself isn't
        // reliably surfacing this app's NSLog output for some reason. Switching to a plain text
        // file instead: no Console.app involved at all, just appended lines on disk that get
        // read back directly.
        logWindowEvent("applicationDidFinishLaunching")
        for name: Notification.Name in [NSWindow.didBecomeKeyNotification, NSWindow.willCloseNotification, NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification, NSApplication.didResignActiveNotification, NSApplication.didBecomeActiveNotification, NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.logWindowEvent(name.rawValue)
            }
        }
    }

    private static let logURL = URL(fileURLWithPath: NSHomeDirectory() + "/Desktop/goldfish-window-debug.log")

    private func logWindowEvent(_ event: String) {
        // Added 2026-08-19: `canJoinAllSpaces` (Spaces-based fix) didn't help either — next
        // theory to rule in/out is that the main window's `isVisible=true` is technically true
        // while its actual on-screen frame/screen has drifted outside any real display's
        // bounds (isVisible only means "not literally ordered out", it says nothing about
        // whether the frame overlaps a physical screen).
        let windows = NSApp.windows.map { w -> String in
            "[id=\(w.identifier?.rawValue ?? "nil") vis=\(w.isVisible) mini=\(w.isMiniaturized) title=\(w.title) level=\(w.level.rawValue) frame=\(w.frame) onScreen=\(w.isOnActiveSpace) screen=\(w.screen?.frame.debugDescription ?? "nil") collBehavior=\(w.collectionBehavior.rawValue)]"
        }
        let line = "\(Date()) event=\(event) isActive=\(NSApp.isActive) isHidden=\(NSApp.isHidden) windowCount=\(NSApp.windows.count) windows=\(windows.joined(separator: " "))\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: Self.logURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: Self.logURL)
        }
    }

    private func handlePlayerWindowClosing(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow else { return }
        let isPlayerWindow: (NSWindow) -> Bool = { ($0.identifier?.rawValue ?? "").localizedCaseInsensitiveContains("player") }
        guard isPlayerWindow(closingWindow) else { return }
        // Real root cause found 2026-08-19 via the file-logged window dump: the main window's
        // `isVisible` stayed `true` THE ENTIRE TIME the "app disappeared" — it was never
        // closed or hidden. What actually happened is the app resigning active
        // (NSApplicationDidResignActiveNotification, isActive=false) with no window taking
        // key status, at which point macOS shows the desktop even though a visible-but-
        // unfocused NSWindow object still technically exists. The old guard here
        // (`!NSApp.windows.contains(where: { $0.isVisible && ... })`) treated "a window is
        // visible" as "nothing to do" — which is exactly backwards: `isVisible` != frontmost/
        // key/on-screen-in-current-Space. That guard silently no-opped every single time.
        // Fix: only check whether ANOTHER player-type window is still open (in which case
        // leave it alone); otherwise always force the main window forward, regardless of its
        // own reported `isVisible`.
        DispatchQueue.main.async {
            let anotherPlayerWindowStillOpen = NSApp.windows.contains {
                $0 !== closingWindow && isPlayerWindow($0) && $0.isVisible && !$0.isMiniaturized
            }
            guard !anotherPlayerWindowStillOpen else { return }
            self.activateMainWindow()
        }
    }

    private func handlePlayerWindowMinimizing(_ notification: Notification) {
        guard let minimizingWindow = notification.object as? NSWindow else { return }
        let isPlayerWindow: (NSWindow) -> Bool = { ($0.identifier?.rawValue ?? "").localizedCaseInsensitiveContains("player") }
        guard isPlayerWindow(minimizingWindow) else { return }
        DispatchQueue.main.async {
            let anotherPlayerWindowStillOpen = NSApp.windows.contains {
                $0 !== minimizingWindow && isPlayerWindow($0) && $0.isVisible && !$0.isMiniaturized
            }
            guard !anotherPlayerWindowStillOpen else { return }
            self.activateMainWindow()
        }
    }

    /// Matches this app's actual main content window specifically — SwiftUI's own generated
    /// identifiers for `WindowGroup` scenes contain "AppWindow" (e.g. "...-1-AppWindow-1");
    /// filtering only on "not a player window" also caught assorted title-less helper/popup
    /// windows AppKit creates internally (level 26 menu-extra windows, nil-id input-context
    /// windows) — real bug hit 2026-08-19, `first(where:)` sometimes grabbed one of those
    /// instead of the actual main window.
    private func activateMainWindow() {
        let isPlayerWindow: (NSWindow) -> Bool = { ($0.identifier?.rawValue ?? "").localizedCaseInsensitiveContains("player") }
        guard let mainWindow = NSApp.windows.first(where: { !isPlayerWindow($0) && ($0.identifier?.rawValue.contains("AppWindow") ?? false) }) else { return }
        if mainWindow.isMiniaturized {
            mainWindow.deminiaturize(nil)
        }
        mainWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Real bug hit 2026-08-19: `hasVisibleWindows` (the `flag` param) reports `true` even
        // in the broken state (main window's `isVisible` stays true, see `activateMainWindow`'s
        // doc comment) — trusting it here meant this handler also no-opped instead of
        // re-focusing anything. Always try to activate the main window ourselves.
        let isPlayerWindow: (NSWindow) -> Bool = { ($0.identifier?.rawValue ?? "").localizedCaseInsensitiveContains("player") }
        if NSApp.windows.contains(where: { !isPlayerWindow($0) && ($0.identifier?.rawValue.contains("AppWindow") ?? false) }) {
            activateMainWindow()
            return false
        }
        // No window at all (main one was closed too) — let AppKit fall through to its
        // default handling, which re-creates the primary `WindowGroup` scene's window.
        return true
    }
}
#endif
