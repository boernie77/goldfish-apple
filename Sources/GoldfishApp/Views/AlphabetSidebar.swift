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

    // tvOS-Fix 2026-09-03 (User-Report: "die Buchstabenleiste ist auch zu klein"): die
    // Original-Maße (Font 10, 16×13pt) sind für Maus/Touch dimensioniert — auf einem
    // 10-Fuß-TV-Bildschirm aus Sofa-Entfernung unlesbar UND als Fokus-Ziel für den Remote
    // viel zu klein, um zuverlässig einen einzelnen Buchstaben zu treffen.
    // Zweiter Anlauf (User: "Buchstabenleiste zu groß"): 44pt pro Buchstabe × 27 Zeilen
    // ergibt eine ~1300pt hohe Säule, die den Bildschirm sprengt — deutlich moderater
    // dimensioniert, bleibt aber immer noch klar größer als die ursprünglichen 13pt.
    #if os(tvOS)
    private let letterFont: Font = .system(size: 14, weight: .semibold)
    private let letterSize: CGFloat = 26
    #else
    private let letterFont: Font = .system(size: 10, weight: .semibold)
    private let letterHeight: CGFloat = 13
    private let letterWidth: CGFloat = 16
    #endif

    var body: some View {
        VStack(spacing: 1) {
            ForEach(Self.letters, id: \.self) { letter in
                Button {
                    selected = (selected == letter) ? nil : letter
                } label: {
                    Text(letter)
                        .font(letterFont)
                        #if os(tvOS)
                        .frame(width: letterSize, height: letterSize)
                        #else
                        .frame(width: letterWidth, height: letterHeight)
                        #endif
                        .foregroundStyle(selected == letter ? Color.white : Color.secondary)
                        .background(selected == letter ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 3))
                }
                .buttonStyle(.plain)
                #if os(tvOS)
                .focusEffectDisabled()
                #endif
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
