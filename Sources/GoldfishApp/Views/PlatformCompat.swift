import SwiftUI

extension View {
    /// `fullScreenCover` only exists on iOS; macOS uses a plain large `.sheet` instead.
    @ViewBuilder
    func fullScreenCoverCompat<Content: View>(isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> Content) -> some View {
        #if os(iOS)
        self.fullScreenCover(isPresented: isPresented, content: content)
        #else
        self.sheet(isPresented: isPresented) {
            content()
                .frame(minWidth: 900, minHeight: 560)
        }
        #endif
    }

    /// macOS-only `.focusable(false)` — the single-Bool overload needs iOS 17 (our target is
    /// 16), and the bug this exists for (search-field click hangs the app while AppKit walks
    /// the whole window's tab-order for its password-autofill heuristic, real bug hit
    /// 2026-08-18) is AppKit-specific anyway. No-op on iOS.
    @ViewBuilder
    func focusableCompat(_ isFocusable: Bool) -> some View {
        #if os(macOS)
        self.focusable(isFocusable)
        #else
        self
        #endif
    }

    /// tvOS-Fix 2026-09-03 (User-Report: weißes Fokus-Rechteck sieht "komisch" aus und
    /// ist "bei jedem Film unterschiedlich"): `.buttonStyle(.plain)` unterdrückt auf
    /// tvOS NICHT den automatischen System-Fokus-Effekt — der zeichnet stattdessen eine
    /// weiße, abgerundete Fläche über die GESAMTE Bounding-Box des Buttons, inklusive
    /// des Titeltexts UNTER dem Poster. Da die Titelzeilen-Anzahl je Film variiert
    /// (1 vs. 2 Zeilen), variiert auch diese Box — exakt das beobachtete Symptom.
    /// `.buttonStyle(.card)` ist tvOS' dafür vorgesehener Stil: der Fokus-/Hover-Effekt
    /// (Skalierung + Schatten) folgt dann der tatsächlichen Content-Form des Buttons
    /// (hier: nur das Poster, da genau das der Button-Inhalt ist) statt einer groben
    /// Bounding-Box. Auf anderen Plattformen bleibt `.plain` unverändert.
    @ViewBuilder
    func cardButtonStyleCompat() -> some View {
        #if os(tvOS)
        self.buttonStyle(.card)
        #else
        self.buttonStyle(.plain)
        #endif
    }
}
