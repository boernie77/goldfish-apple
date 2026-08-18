import Foundation

// MARK: - Auth

public struct AuthStatus: Decodable {
    public let setup: Bool
    public let loggedIn: Bool
    public let username: String?
    public let isAdmin: Bool
}

public struct LoginResponse: Decodable {
    public let username: String
    public let isAdmin: Bool
}

// MARK: - Watch-Link (Gesehen-Sync zwischen zwei Usern, User-Anfrage 2026-08-19)

public struct OtherUser: Decodable, Identifiable, Hashable {
    public let id: Int64
    public let username: String
}

public struct WatchLink: Decodable, Identifiable, Hashable {
    public let partnerId: Int64
    public let partnerName: String
    /// "accepted" | "pending_outgoing" | "pending_incoming"
    public let status: String
    public var id: Int64 { partnerId }
}

// MARK: - Library

public struct Library: Decodable, Identifiable, Hashable {
    public let id: Int64
    public let name: String
    public let path: String
    public let kind: String
    public let onHome: Bool
    public let sortOrder: Int?
    public let channelLabelOnTop: Bool?

    public var isMovies: Bool { kind == "movies" }
    public var isTV: Bool { kind == "tv" }
    public var isPrivate: Bool { kind == "private" }
}

// MARK: - Metadata

public struct Metadata: Codable, Hashable {
    public let id: Int64
    public let tmdbType: String?
    public let tmdbId: Int64?
    public let parentId: Int64?
    public let title: String?
    public let originalTitle: String?
    public let year: Int?
    public let releaseDate: String?
    public let overview: String?
    public let rating: Double?
    public let genres: String?
    public let runtimeMin: Int?
    public let posterPath: String?
    public let backdropPath: String?
    public let season: Int?
    public let episode: Int?
    public let imdbId: String?
    public let ageRating: String?

    /// `genres` is a JSON-encoded string array coming from the server, not a native array.
    public var genreList: [String] {
        guard let genres, let data = genres.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }
}

// MARK: - Item

public struct Item: Codable, Identifiable, Hashable {
    public let id: Int64
    public let libraryId: Int64
    public let path: String?
    public let relPath: String?
    public let title: String
    public let container: String?
    public let videoCodec: String?
    public let audioCodec: String?
    public let width: Int?
    public let height: Int?
    public let durationSec: Double?
    public let sizeBytes: Int64?
    public let bitrateKbps: Int?
    public let hasThumb: Bool?
    public let releasedAt: String?
    public let addedAt: String?
    public let metadataId: Int64?
    public let metadataConfirmed: Bool?
    public let episodeEnd: Int?
    public let metadata: Metadata?
    public let watched: Bool
    public let watchedAt: String?
    public let favorite: Bool
    public let favoritedAt: String?
    public let trickplayStatus: String?
    public let variantCount: Int?
    public let variantSplit: Bool?
    public let introStartSec: Double?
    public let introEndSec: Double?

    public var displayTitle: String {
        metadata?.title ?? title
    }

    public var resolutionLabel: String {
        guard let h = height, let w = width, h > 0 else { return "" }
        let effective = max(Double(h), Double(w) * 9.0 / 16.0)
        switch effective {
        case 2000...: return "4K"
        case 1000..<2000: return "1080p"
        case 700..<1000: return "720p"
        default: return "\(Int(effective))p"
        }
    }

    public var durationLabel: String {
        let sec = Int((durationSec ?? 0).rounded())
        let h = sec / 3600
        let m = (sec % 3600) / 60
        let s = sec % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    public var ratingLabel: String? {
        guard let rating = metadata?.rating, rating > 0 else { return nil }
        return String(format: "★ %.1f", rating)
    }

    public var isEpisode: Bool { metadata?.tmdbType == "episode" }

    /// Show name for an episode item — mirrors the web client's `renderCard`: the show
    /// name isn't a metadata field, it's the first path segment of `relPath`.
    public var showName: String? {
        guard isEpisode, let relPath, !relPath.isEmpty else { return nil }
        let segments = relPath.split(separator: "/")
        return segments.count > 1 ? String(segments[0]) : nil
    }

    /// "S07E23" (or "S07E23-24" for a double-episode range) — nil when not an episode.
    public var episodeCode: String? {
        guard isEpisode, let season = metadata?.season, let episode = metadata?.episode else { return nil }
        let s = String(format: "%02d", season)
        let e = String(format: "%02d", episode)
        if let end = episodeEnd, end > episode {
            return "S\(s)E\(e)-\(String(format: "%02d", end))"
        }
        return "S\(s)E\(e)"
    }

    public var episodeName: String? {
        guard isEpisode else { return nil }
        return metadata?.title
    }

    /// True for "YouTube-style" items in a Privat-Library (CLAUDE.md "Privatvideos: kind=private
    /// → keine TMDB-Calls") — no automatic TMDB match, so `metadata` is either absent or a
    /// manually-entered `tmdb_type=custom` entry (CLAUDE.md "Edit-Metadata-Dialog"). `Item`
    /// doesn't carry its library's `kind` directly, so this infers it from the absence of a
    /// real TMDB match instead — a movie/tv/episode item always has `metadata?.tmdbType` set
    /// to one of those three values.
    public var isPrivateStyle: Bool {
        !isEpisode && (metadata == nil || metadata?.tmdbType == "custom" || metadata?.tmdbType == nil)
    }

    /// Top-level folder of `relPath` for a Privat-Library item — the "channel" in a YouTube-
    /// style library (User-Anfrage 2026-08-19: Downloads-Kacheln sollen Kanalname zeigen).
    public var channelName: String? {
        guard isPrivateStyle, let relPath, !relPath.isEmpty else { return nil }
        let segments = relPath.split(separator: "/")
        return segments.count > 1 ? String(segments[0]) : nil
    }

    /// `releasedAt`'s date portion, formatted for display — nil for Go's zero `time.Time`
    /// (serializes as "0001-01-01T00:00:00Z" when nothing was ever set) so an empty download
    /// tile doesn't show a bogus year-1 date.
    /// Copy with `watched` overridden — used by `DownloadManager.updateCachedWatched` to keep
    /// a download's cached `Item` snapshot (frozen at download time, see `DownloadRecord.
    /// itemData`'s doc comment) in sync with the real watched state after playback, instead of
    /// permanently showing whatever it looked like the moment the download finished (real bug
    /// hit 2026-08-19: "was auf dem Server als gesehen markiert ist, sehe ich nicht in der
    /// App" — the Downloads tab's tiles read this frozen snapshot, so a later `setWatched`
    /// call never showed up there without this).
    public func withWatched(_ watched: Bool) -> Item {
        Item(id: id, libraryId: libraryId, path: path, relPath: relPath, title: title,
             container: container, videoCodec: videoCodec, audioCodec: audioCodec, width: width,
             height: height, durationSec: durationSec, sizeBytes: sizeBytes, bitrateKbps: bitrateKbps,
             hasThumb: hasThumb, releasedAt: releasedAt, addedAt: addedAt, metadataId: metadataId,
             metadataConfirmed: metadataConfirmed, episodeEnd: episodeEnd, metadata: metadata,
             watched: watched, watchedAt: watchedAt, favorite: favorite, favoritedAt: favoritedAt,
             trickplayStatus: trickplayStatus, variantCount: variantCount, variantSplit: variantSplit,
             introStartSec: introStartSec, introEndSec: introEndSec)
    }

    public var releasedDateLabel: String? {
        guard let releasedAt, let date = ISO8601DateFormatter().date(from: releasedAt) else { return nil }
        let year = Calendar(identifier: .gregorian).component(.year, from: date)
        guard year > 1900 else { return nil }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.locale = Locale(identifier: "de_DE")
        return formatter.string(from: date)
    }
}

/// Client-side merge of items that share the same `metadataId` into one representative
/// tile — mirrors the web app's `groupVariants` (app.js) exactly: representative =
/// highest resolution, tie-broken by highest bitrate. Items with `variantSplit == true`
/// are deliberately excluded from grouping (CLAUDE.md "Varianten trennen") even though
/// they share a `metadataId` with siblings. The caller reads `item.variantCount` (already
/// computed server-side, see `attachVariantCounts`) for the "×N" badge — this function
/// only decides which single Item wins the slot, it doesn't itself count variants.
public func groupVariants(_ items: [Item]) -> [Item] {
    var order: [Int64] = []
    var reps: [Int64: Item] = [:]
    var out: [Item] = []
    for item in items {
        guard let metadataId = item.metadataId, metadataId > 0, item.variantSplit != true else {
            out.append(item)
            continue
        }
        if let existing = reps[metadataId] {
            let itHeight = item.height ?? 0, exHeight = existing.height ?? 0
            let itBitrate = item.bitrateKbps ?? 0, exBitrate = existing.bitrateKbps ?? 0
            if itHeight > exHeight || (itHeight == exHeight && itBitrate > exBitrate) {
                reps[metadataId] = item
            }
        } else {
            order.append(metadataId)
            reps[metadataId] = item
        }
    }
    for id in order {
        if let rep = reps[id] { out.append(rep) }
    }
    // Restore original relative ordering (movies expect chronological/title order, not
    // "ungrouped first, then all groups appended") by re-sorting `out` to match each
    // representative's first-seen position among all items.
    let firstSeenIndex: [Int64: Int] = {
        var map: [Int64: Int] = [:]
        for (idx, item) in items.enumerated() where map[item.id] == nil {
            map[item.id] = idx
        }
        return map
    }()
    return out.sorted { (firstSeenIndex[$0.id] ?? 0) < (firstSeenIndex[$1.id] ?? 0) }
}

// MARK: - Sorting & Filtering

public enum ItemSort: String, CaseIterable, Identifiable, Equatable {
    case title
    case released
    case added
    case duration
    case rating

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .title: return "Titel"
        case .released: return "Veröffentlicht"
        case .added: return "Hinzugefügt"
        case .duration: return "Laufzeit"
        case .rating: return "Bewertung"
        }
    }

    /// Matches the server's per-field default direction (grid.js `sortDefaultDir`).
    public var defaultAscending: Bool {
        self == .title
    }
}

public enum WatchedFilter: String, CaseIterable, Identifiable, Equatable {
    case all
    case yes
    case no

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .all: return "Alle"
        case .yes: return "Nur gesehen"
        case .no: return "Nur ungesehen"
        }
    }
}

public enum ResolutionBucket: String, CaseIterable, Identifiable, Equatable, Hashable {
    case uhd4k = "4k"
    case uhd2k = "2k"
    case fhd1080 = "1080p"
    case hd720 = "720p"
    case sd576 = "576p"
    case sd540 = "540p"
    case sd480 = "480p"
    case low = "360p"

    public var id: String { rawValue }
    public var label: String { rawValue.uppercased() }
}

// MARK: - Cast

public struct CastMember: Decodable, Identifiable, Hashable {
    public let personId: Int64
    public let tmdbId: Int64
    public let name: String
    public let profilePath: String?
    public let character: String
    public let role: String
    public let order: Int

    public var id: Int64 { personId }
}

// MARK: - Collections

public struct Collection: Decodable, Identifiable, Hashable {
    public let id: Int64
    public let tmdbId: Int64
    public let name: String
    public let posterPath: String?
    public let backdropPath: String?
    public let movieCount: Int
    public let partCount: Int?
    public let hiddenCount: Int?
    public let unreleasedCount: Int?
    public let fallbackMetaId: Int64?

    /// Mirrors the web app's `complete = movieCount >= partCount - hiddenCount` — unreleased
    /// parts don't count as "missing" (CLAUDE.md "Sammlungs-Komplett-Badge").
    public var isComplete: Bool {
        guard let partCount, partCount > 0 else { return false }
        return movieCount >= partCount - (hiddenCount ?? 0) - (unreleasedCount ?? 0)
    }
}

/// A single entry in a collection: either an owned movie (`item` populated) or a
/// placeholder for a part the library doesn't have (`item` nil).
public struct CollectionPart: Decodable, Identifiable {
    public let tmdbMovieId: Int64
    public let title: String
    public let releaseDate: String?
    public let posterPath: String?
    public let owned: Bool
    public let hidden: Bool
    public let item: Item?

    public var id: Int64 { tmdbMovieId }

    public init(tmdbMovieId: Int64, title: String, releaseDate: String?, posterPath: String?, owned: Bool, hidden: Bool, item: Item?) {
        self.tmdbMovieId = tmdbMovieId
        self.title = title
        self.releaseDate = releaseDate
        self.posterPath = posterPath
        self.owned = owned
        self.hidden = hidden
        self.item = item
    }
}

// MARK: - Playlists

public struct Playlist: Decodable, Identifiable, Hashable {
    public let id: Int64
    public let name: String
    public let itemCount: Int
    public let posterItemId: Int64?
    public let posterMetadataId: Int64?
}

// MARK: - Folders

public struct FolderTile: Decodable, Identifiable, Hashable {
    public let name: String
    public let itemCount: Int
    public let thumbItemId: Int64
    public let metadataId: Int64?
    public let metadata: Metadata?
    public let drilldown: Bool

    public var id: String { name }
    public var displayName: String { name.components(separatedBy: "/").last ?? name }
}

// MARK: - Resume

public struct ResumePosition: Codable {
    public let positionSec: Double
}

// MARK: - Playback

public struct PlaybackResponse: Decodable {
    public let mode: String
    public let reason: String?
    public let item: Item
    public let url: String
}

// MARK: - Home

public struct HomeSection: Decodable, Identifiable {
    public let library: Library
    public let continueItems: [Item]
    public let nextUp: [Item]
    public let recent: [Item]

    public var id: Int64 { library.id }

    enum CodingKeys: String, CodingKey {
        case library
        case continueItems = "continue"
        case nextUp
        case recent
    }
}

public struct HomeResponse: Decodable {
    public let sections: [HomeSection]
}

// MARK: - TV Seasons

public struct ShowCastMember: Decodable, Identifiable, Hashable {
    public let tmdbId: Int64
    public let name: String
    public let character: String?
    public let profilePath: String?

    public var id: Int64 { tmdbId }
}

public struct ShowOut: Decodable {
    public let title: String?
    public let overview: String?
    public let firstAirDate: String?
    public let status: String?
    public let rating: Double?
    public let posterPath: String?
    public let backdropPath: String?
    public let numberOfSeasons: Int?
    public let numberOfEpisodes: Int?
    public let cast: [ShowCastMember]?
}

public struct EpisodeOut: Decodable, Identifiable, Hashable {
    public let season: Int
    public let episode: Int
    public let title: String?
    public let overview: String?
    public let stillPath: String?
    public let owned: Bool
    public let watched: Bool
    public let itemId: Int64?

    public var id: String { "\(season)-\(episode)" }
}

public struct SeasonOut: Decodable, Identifiable, Hashable {
    public let seasonNumber: Int
    public let name: String?
    public let posterPath: String?
    public let episodes: [EpisodeOut]
    public let ownedCount: Int
    public let watchedCount: Int
    public let total: Int

    public var id: Int { seasonNumber }
}

public struct SeasonsResponse: Decodable {
    public let showTmdbId: Int64
    public let show: ShowOut?
    public let seasons: [SeasonOut]
}
