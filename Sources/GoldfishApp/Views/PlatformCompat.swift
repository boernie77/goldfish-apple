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
}
