import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// A poster/thumbnail image guaranteed to occupy exactly `aspect` regardless of the
/// loaded image's real proportions.
///
/// Just chaining `.aspectRatio(_, contentMode: .fit)` on an `AsyncImage` that itself
/// does `.scaledToFill()` looks fine when the source image already matches the target
/// aspect (e.g. a proper 2:3 TMDB poster) — but the two modifiers actively fight once
/// the source is a different aspect (e.g. a 16:9 video-frame thumbnail for an unmatched
/// item): the image renders at its own intrinsic proportions instead of respecting the
/// card's frame, overflowing into neighboring grid cells and throwing off hit-testing
/// (real bug hit 2026-08-17 — private/Bluray libraries with lots of unmatched items).
///
/// Fix: size a `Color.clear` box first (which has no conflicting intrinsic content size),
/// then `.overlay` the image into that already-resolved frame and `.clipped()`.
struct PosterImage: View {
    let url: URL?
    var aspect: CGFloat = 2.0 / 3.0
    var placeholderSystemImage: String = "film"

    // User-Bericht 2026-08-19: EIN bestimmtes Poster ("American Fighter" 1985) zeigte
    // in JEDER Ansicht (normales Grid, Sammlung) dasselbe zugeschnitten/gezoomt wirkende
    // Bild, obwohl die Server-Datei nachweislich korrekt ist UND der Browser dasselbe
    // Poster fehlerfrei zeigt — reproduziert über mehrere App-Neubauten hinweg. Da es
    // immer GENAU dasselbe Item betrifft (nicht z.B. "immer die erste Kachel"), ist die
    // wahrscheinlichste Erklärung ein hartnäckiger Eintrag in `URLCache.shared`, den
    // `AsyncImage` intern nutzt — dieser Cache liegt auf der Festplatte im App-Caches-
    // Ordner und überlebt Neubauten der App (anders als reiner In-Memory-State). Fix:
    // Poster-Loads laufen jetzt über einen eigenen Loader mit `.reloadIgnoringLocalAndRemoteCacheData`
    // statt AsyncImage, der JEDEN Cache (lokal + protocol-level) ignoriert.
    @State private var loadedImage: PlatformImage?
    @State private var loadFailed = false

    var body: some View {
        // GeometryReader statt `Color.clear.aspectRatio(_, contentMode: .fit)` als Größen-
        // Anker: User-Bericht 2026-08-19 zeigte, dass EINE bestimmte Kachel-Position (nicht
        // an ein bestimmtes Bild gebunden — trat auch nach Neuzuordnung auf einen komplett
        // ANDEREN Film hin weiter auf) dauerhaft falsch/verschoben blieb, über mehrere App-
        // Neubauten hinweg. `.aspectRatio(_, contentMode: .fit)` auf `Color.clear` verlangt
        // eine SwiftUI-interne Größen-VERHANDLUNG mit dem Elternview — GeometryReader meldet
        // stattdessen die tatsächlich vom Elternview zugewiesene Größe direkt, ohne
        // Verhandlungsschritt. `.id(url)` erzwingt zusätzlich einen kompletten View-Neuaufbau
        // bei jeder URL-Änderung (nicht nur einen Reload des Bild-State), falls doch
        // irgendein internes Layout-/Geometrie-Caching an der View-Identität hängt.
        GeometryReader { geo in
            Group {
                if let loadedImage, !loadFailed {
                    Image(platformImage: loadedImage)
                        .resizable()
                        .scaledToFill()
                } else {
                    placeholder
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
        .aspectRatio(aspect, contentMode: .fit)
        .id(url)
        .task(id: url) { await load() }
    }

    private func load() async {
        loadedImage = nil
        loadFailed = false
        guard let url else { return }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let image = PlatformImage(data: data) else {
            loadFailed = true
            return
        }
        loadedImage = image
    }

    private var placeholder: some View {
        Rectangle()
            .fill(.secondary.opacity(0.2))
            .overlay(Image(systemName: placeholderSystemImage).foregroundStyle(.secondary))
    }
}

#if os(macOS)
typealias PlatformImage = NSImage
#else
typealias PlatformImage = UIImage
#endif

private extension Image {
    init(platformImage: PlatformImage) {
        #if os(macOS)
        self.init(nsImage: platformImage)
        #else
        self.init(uiImage: platformImage)
        #endif
    }
}
