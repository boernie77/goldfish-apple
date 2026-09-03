import SwiftUI

extension View {
    /// `fullScreenCover` only exists on iOS; macOS/tvOS use a plain `.sheet` instead.
    @ViewBuilder
    func fullScreenCoverCompat<Content: View>(isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> Content) -> some View {
        #if os(iOS)
        self.fullScreenCover(isPresented: isPresented, content: content)
        #elseif os(tvOS)
        // tvOS-Fix 2026-09-03, ZWEITER Anlauf (User-Report nach dem ersten Versuch mit
        // explizitem `.frame`: "das weiße Fenster um die Elemente ist zu groß" — Bild blieb
        // trotzdem klein/schwarz, Controls unproportional). Root Cause: `.sheet` lässt sich
        // auf tvOS GRUNDSÄTZLICH NICHT zu echtem Vollbild zwingen — das System präsentiert
        // IMMER eine zentrierte "Form-Sheet"-Karte mit eigenem hellen Chrome/Rand, egal
        // welches `.frame` der Inhalt bekommt (kein Sheet-Modifier/keine Presentation-Detent-
        // API auf tvOS kann das umgehen). Fix: Player wird auf tvOS über
        // `.navigationDestination(isPresented:)` GESCHOBEN statt modal präsentiert — echte
        // Vollbild-Navigation ohne System-Chrome, wie jede andere Seite in der App. Setzt
        // voraus, dass der Aufrufer innerhalb der `NavigationStack` seiner Tab-Seite sitzt
        // (LibrariesView/HomeView/etc. — siehe RootView.legacyTabView), was für alle
        // aktuellen Aufrufer zutrifft. `@Environment(\.dismiss)` in `PlayerView.closePlayer()`
        // funktioniert dadurch unverändert weiter (poppt jetzt den Stack statt ein Sheet zu
        // schließen).
        // tvOS-Fix 2026-09-03, Folgebug (User-Screenshot: die Tab-Leiste "Start/Bibliotheken/
        // Einstellungen" blieb über dem gepushten Player sichtbar) — anders als ein echtes
        // `fullScreenCover` deckt eine reine Stack-Navigation die umschließende `TabView`
        // (RootView.legacyTabView) NICHT automatisch ab. `.toolbar(.hidden, for: .tabBar)`
        // auf dem gepushten Inhalt blendet sie für die Dauer der Präsentation aus.
        self.navigationDestination(isPresented: isPresented) {
            content().toolbar(.hidden, for: .tabBar)
        }
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
