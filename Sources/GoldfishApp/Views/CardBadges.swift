import SwiftUI

/// Shared poster-overlay toggle badge (watched ✓ / favorite ♥) — used by every card type
/// (server items, local items) so they're pixel-identical in size everywhere. Previously each
/// card styled its own badge ad hoc and they drifted apart (real bug hit 2026-08-17).
struct PosterToggleBadge: View {
    let isOn: Bool
    let onSymbol: String
    let offSymbol: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isOn ? onSymbol : offSymbol)
                .font(.caption)
                .foregroundStyle(isOn ? tint : .white)
                .frame(width: 22, height: 22)
                .background(.black.opacity(0.5), in: Circle())
        }
        .buttonStyle(.plain)
        .focusableCompat(false)
    }
}
