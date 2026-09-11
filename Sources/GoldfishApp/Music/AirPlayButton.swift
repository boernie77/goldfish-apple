#if os(macOS) || os(iOS)
import AVKit
import SwiftUI

/// Natives AirPlay-Ausgabe-Icon (User-Wunsch 2026-09-11: "was haben andere
/// Musikplayer") — `AVRoutePickerView` ist AVKits fertige Systemkomponente
/// für Audio-/Video-Ausgabegeräte (AirPlay-Lautsprecher, HomePod, …), zeigt
/// automatisch alle im Netzwerk verfügbaren Ziele, ohne eigene Geräte-Suche.
/// Auf iOS/macOS identisch verfügbar, nur der Wrapper-Typ unterscheidet sich
/// (NSViewRepresentable vs. UIViewRepresentable).
#if os(macOS)
struct AirPlayButton: NSViewRepresentable {
    func makeNSView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.isRoutePickerButtonBordered = false
        return view
    }

    func updateNSView(_ nsView: AVRoutePickerView, context: Context) {}
}
#else
struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
#endif
#endif
