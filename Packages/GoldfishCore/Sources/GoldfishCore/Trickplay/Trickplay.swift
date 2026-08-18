import Foundation

/// Eine Sprite-Kachel für einen Zeitabschnitt — mirrors den Browser-Player
/// (CLAUDE.md "Trickplay (Hover-Vorschau)"): der Server liefert ein WebVTT-Manifest
/// (`GET /api/trickplay/{id}/thumbs.vtt`) mit einem Cue pro Intervall, jeder Cue zeigt per
/// `sprite.jpg#xywh=x,y,w,h`-Fragment auf seine Kachel im gemeinsamen Sprite-Sheet
/// (`GET /api/trickplay/{id}/sprite.jpg`).
public struct TrickplayCue: Equatable {
    public let start: Double
    public let end: Double
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int
}

public enum TrickplayVTTParser {
    /// Parst das vom Server gelieferte WebVTT (siehe `internal/trickplay/worker.go`'s
    /// `writeVTT` — fixes, einfaches Format: `WEBVTT`, dann abwechselnd eine Zeitzeile
    /// (`HH:MM:SS.mmm --> HH:MM:SS.mmm`) und eine `sprite.jpg#xywh=…`-Zeile, durch Leerzeilen
    /// getrennt). Robust statt hart auf das feste Intervall/Grid zu rechnen — überlebt
    /// künftige Format-Änderungen serverseitig, ohne den Client anzufassen.
    public static func parse(_ text: String) -> [TrickplayCue] {
        var cues: [TrickplayCue] = []
        let lines = text.components(separatedBy: .newlines)
        var i = 0
        while i < lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespaces)
            if line.contains("-->") {
                let parts = line.components(separatedBy: "-->")
                guard parts.count == 2,
                      let start = parseTimestamp(parts[0]),
                      let end = parseTimestamp(parts[1]) else {
                    i += 1
                    continue
                }
                // Nächste nicht-leere Zeile ist die xywh-Zeile.
                var j = i + 1
                while j < lines.count, lines[j].trimmingCharacters(in: .whitespaces).isEmpty { j += 1 }
                if j < lines.count, let rect = parseXYWH(lines[j]) {
                    cues.append(TrickplayCue(start: start, end: end, x: rect.0, y: rect.1, width: rect.2, height: rect.3))
                }
                i = j + 1
            } else {
                i += 1
            }
        }
        return cues
    }

    /// "00:01:23.456" (oder ohne Stunden "01:23.456") → Sekunden.
    private static func parseTimestamp(_ raw: String) -> Double? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        let dotParts = s.components(separatedBy: ".")
        let msStr = dotParts.count > 1 ? dotParts[1] : "0"
        let ms = Double(msStr) ?? 0
        let comps = dotParts[0].components(separatedBy: ":").compactMap { Double($0) }
        guard !comps.isEmpty else { return nil }
        var seconds = 0.0
        for c in comps { seconds = seconds * 60 + c }
        return seconds + ms / 1000
    }

    private static func parseXYWH(_ line: String) -> (Int, Int, Int, Int)? {
        guard let range = line.range(of: "xywh=") else { return nil }
        let nums = line[range.upperBound...].split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard nums.count == 4 else { return nil }
        return (nums[0], nums[1], nums[2], nums[3])
    }

    /// Bequeme Suche nach der passenden Kachel für eine absolute Zeit — lineare Suche reicht,
    /// eine Filmlaufzeit erzeugt selbst bei 5s-Intervall nur ein paar hundert Cues.
    public static func cue(for time: Double, in cues: [TrickplayCue]) -> TrickplayCue? {
        cues.first { time >= $0.start && time < $0.end } ?? cues.last { time >= $0.start }
    }
}
