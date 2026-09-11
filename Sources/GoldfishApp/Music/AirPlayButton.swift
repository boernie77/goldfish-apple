#if os(macOS)
import AVKit
import SwiftUI

/// Natives AirPlay-Ausgabe-Icon (User-Wunsch 2026-09-11: "was haben andere
/// Musikplayer") — `AVRoutePickerView` ist AVKits fertige Systemkomponente
/// für Audio-/Video-Ausgabegeräte (AirPlay-Lautsprecher, HomePod, …), zeigt
/// automatisch alle im Netzwerk verfügbaren Ziele, ohne eigene Geräte-Suche.
struct AirPlayButton: NSViewRepresentable {
    func makeNSView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.isRoutePickerButtonBordered = false
        return view
    }

    func updateNSView(_ nsView: AVRoutePickerView, context: Context) {}
}
#endif
