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

    /// tvOS-Fix 2026-09-03, DRITTER Anlauf (User-Screenshot zeigte: die graue/weiße
    /// Fläche hinter der Kachel war nach den ersten beiden Versuchen IMMER NOCH da).
    /// Root Cause, jetzt tatsächlich verifiziert: tvOS zeichnet den automatischen
    /// System-Fokus-Hintergrund UNABHÄNGIG vom `.buttonStyle` — weder `.plain` noch
    /// `.card` schalten ihn ab, das ist ein separater Fokus-Effekt-Layer, der ohne
    /// explizites Opt-out immer mitläuft. `.focusEffectDisabled()` (tvOS 17+, unser
    /// Minimum) ist der tatsächlich dafür vorgesehene Schalter — erst DAMIT verschwindet
    /// die Fläche wirklich, und der eigene Skalierungs-/Schatten-Effekt in `ItemCard`/
    /// `FolderCard` (`@Environment(\.isFocused)`) bleibt als einziges Fokus-Feedback übrig.
    @ViewBuilder
    func cardButtonStyleCompat() -> some View {
        #if os(tvOS)
        self.buttonStyle(.plain).focusEffectDisabled()
        #else
        self.buttonStyle(.plain)
        #endif
    }

    /// tvOS-Fix 2026-09-03 (User-Report: Text in den Login-Feldern sitzt oben/links
    /// statt zentriert): ohne `.textFieldStyle(.roundedBorder)` (existiert auf tvOS
    /// nicht) fällt das Feld auf tvOS' EIGENE, native Editier-Darstellung zurück,
    /// deren interne Text-Position sich nicht sauber beeinflussen lässt. Fix: die
    /// Pille selbst zeichnen (`.textFieldStyle(.plain)` + eigenes Padding/Capsule) —
    /// SwiftUI zentriert den Text darin zuverlässig vertikal, exakt wie ein normales
    /// Textfeld auf jeder anderen Plattform.
    #if os(tvOS)
    @ViewBuilder
    func tvLoginFieldStyle() -> some View {
        self
            .textFieldStyle(.plain)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(.regularMaterial, in: Capsule())
    }
    #endif
}
