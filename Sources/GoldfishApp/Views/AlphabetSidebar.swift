import SwiftUI

/// A-Z-Schnellnavigation am rechten Rand — mirrors den Browser (CLAUDE.md
/// "Alphabet-Sidebar rechts"): wirkt als FILTER, nicht als Scroll-Sprung. Klick auf einen
/// Buchstaben blendet alle Kacheln aus, deren Titel nicht damit beginnt; erneuter Klick
/// hebt den Filter wieder auf. "#" fasst alles zusammen, das nicht mit einem Buchstaben
/// beginnt (Zahlen, Sonderzeichen). User-Anfrage 2026-08-19: "in jeder Bibliothek auf der
/// rechten Seite eine Buchstabenleiste zum navigieren".
struct AlphabetSidebar: View {
    @Binding var selected: String?

    private static let letters: [String] = ["#"] + (UInt8(ascii: "A")...UInt8(ascii: "Z")).map { String(UnicodeScalar($0)) }

    var body: some View {
        VStack(spacing: 1) {
            ForEach(Self.letters, id: \.self) { letter in
                Button {
                    selected = (selected == letter) ? nil : letter
                } label: {
                    Text(letter)
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 16, height: 13)
                        .foregroundStyle(selected == letter ? Color.white : Color.secondary)
                        .background(selected == letter ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 3))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 3)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    /// Prüft, ob `title` zum gewählten Buchstaben passt — nil-`selected` heißt "kein Filter".
    static func matches(_ title: String, _ selected: String?) -> Bool {
        guard let selected else { return true }
        guard let first = title.trimmingCharacters(in: .whitespacesAndNewlines).uppercased().first else { return false }
        if selected == "#" { return !("A"..."Z").contains(String(first)) }
        return String(first) == selected
    }
}
