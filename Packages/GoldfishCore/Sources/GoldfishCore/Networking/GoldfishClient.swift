import Foundation
import CryptoKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

public enum GoldfishError: Error, LocalizedError {
    case invalidURL
    case notConfigured
    case server(Int, String)
    case decoding(Error)

    public var errorDescription: String? {
        switch self {
        case .invalidURL: return "Ungültige Server-Adresse"
        case .notConfigured: return "Kein Server konfiguriert"
        case .server(let code, let msg): return msg.isEmpty ? "Server-Fehler \(code)" : msg
        case .decoding(let e): return "Antwort konnte nicht gelesen werden: \(e.localizedDescription)"
        }
    }
}

@MainActor
public final class GoldfishClient: ObservableObject {
    public static let shared = GoldfishClient()

    @Published public private(set) var baseURL: URL?
    @Published public private(set) var currentUsername: String?
    @Published public private(set) var isAdmin: Bool = false
    @Published public private(set) var isLoggedIn: Bool = false
    /// User-Anfrage 2026-08-19: "Kann ich offline den Benutzer wechseln?" — Konten, deren
    /// Session-Cookie einmal online erfolgreich gesetzt wurde, bleiben hier gelistet und
    /// lassen sich OHNE Netzwerk-Call zurückwechseln (`switchToRememberedAccount`).
    @Published public private(set) var rememberedAccounts: [RememberedAccount] = []

    private let session: URLSession
    private let decoder: JSONDecoder

    private init() {
        let config = URLSessionConfiguration.default
        config.httpCookieStorage = .shared
        config.httpShouldSetCookies = true
        config.httpCookieAcceptPolicy = .always
        self.session = URLSession(configuration: config)
        self.decoder = JSONDecoder()

        if let saved = UserDefaults.standard.string(forKey: "goldfish.baseURL"), let url = URL(string: saved) {
            self.baseURL = url
        }
        self.currentUsername = UserDefaults.standard.string(forKey: "goldfish.username")
        self.isLoggedIn = self.currentUsername != nil
        self.rememberedAccounts = Self.loadRememberedAccountsList()
    }

    public func configure(serverURL: URL) {
        var url = serverURL
        if url.absoluteString.hasSuffix("/") {
            url = URL(string: String(url.absoluteString.dropLast()))!
        }
        self.baseURL = url
        UserDefaults.standard.set(url.absoluteString, forKey: "goldfish.baseURL")
    }

    // MARK: - URL building

    private func makeURL(_ path: String, query: [URLQueryItem] = []) throws -> URL {
        guard let base = baseURL else { throw GoldfishError.notConfigured }
        var comps = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        comps.path = base.path + path
        if !query.isEmpty { comps.queryItems = query }
        guard let u = comps.url else { throw GoldfishError.invalidURL }
        return u
    }

    /// Public URL builder for asset endpoints (posters, streaming) consumed directly by SwiftUI/AVKit.
    public func assetURL(_ path: String) -> URL? {
        guard let base = baseURL else { return nil }
        return base.appendingPathComponent(path)
    }

    // Root Cause 2026-09-04 (App-Review-Aufnahme: grauer "Wiedergabe nicht möglich"-Screen,
    // Simulator-Log zeigte den Stream-Request mit "received response, status 401"):
    // `AVPlayer(url:)` schickt das HttpOnly-`goldfish_session`-Cookie NICHT zuverlässig mit
    // seinem eigenen Resource-Loader-Request mit (AVFoundations Netzwerk-Stack teilt sich
    // `HTTPCookieStorage.shared` anders als eine normale `URLSession`-Anfrage) — betraf sowohl
    // tvOS als auch den iOS-Simulator, war vorher durch die kaputte IPv6-Route auf tvOS
    // verdeckt. Der Server unterstützt genau für diesen Fall (Chromecast/FireTV/AVPlayer)
    // bereits einen `?session=<token>`-Query-Param-Fallback (`internal/api/auth.go
    // resolveSessionToken`) — dieser Client hat ihn nie genutzt. Fix: an jede über diese
    // Funktion aufgelöste Stream-URL den Token aus dem Cookie zusätzlich als Query-Param
    // anhängen. Einziger Aufrufer dieser Funktion ist `PlayerView` (Stream-/Transcode-Restart-
    // URLs), Poster/Thumbnails laufen über andere Funktionen und normale `URLSession`-Requests,
    // die das Cookie bereits korrekt mitschicken.
    public func resolvedURL(forServerPath path: String) -> URL? {
        guard let base = baseURL else { return nil }
        let resolved: URL?
        if path.hasPrefix("http://") || path.hasPrefix("https://") {
            resolved = URL(string: path)
        } else {
            var comps = URLComponents(url: base, resolvingAgainstBaseURL: false)!
            // path already contains its own query string (e.g. "/api/transcode/1/index.m3u8?profile=...")
            if let sepIdx = path.firstIndex(of: "?") {
                comps.path = base.path + String(path[path.startIndex..<sepIdx])
                comps.query = String(path[path.index(after: sepIdx)...])
            } else {
                comps.path = base.path + path
            }
            resolved = comps.url
        }
        guard let resolved else { return nil }
        guard let token = sessionToken else { return resolved }
        var comps = URLComponents(url: resolved, resolvingAgainstBaseURL: false)!
        var items = comps.queryItems ?? []
        items.append(URLQueryItem(name: "session", value: token))
        comps.queryItems = items
        return comps.url ?? resolved
    }

    private var sessionToken: String? {
        guard let base = baseURL else { return nil }
        return HTTPCookieStorage.shared.cookies(for: base)?.first(where: { $0.name == "goldfish_session" })?.value
    }

    // MARK: - Generic request helpers

    private func perform<T: Decodable>(_ path: String, method: String = "GET", query: [URLQueryItem] = [], jsonBody: Data? = nil, timeout: TimeInterval? = nil) async throws -> T {
        var req = URLRequest(url: try makeURL(path, query: query))
        req.httpMethod = method
        if let timeout { req.timeoutInterval = timeout }
        if let jsonBody {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = jsonBody
        }
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw GoldfishError.server(0, "Keine Antwort vom Server")
        }
        guard (200..<300).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw GoldfishError.server(http.statusCode, msg)
        }
        if data.isEmpty {
            // Endpoints like 204 No Content decode into Void-ish callers; avoid crashing here.
            if T.self == EmptyResponse.self {
                return EmptyResponse() as! T
            }
        }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw GoldfishError.decoding(error)
        }
    }

    /// Raw response bytes without decoding — for endpoints whose JSON shape varies by server
    /// state (see `fetchCollectionParts`'s parts-vs-plain-items fallback).
    private func performRaw(_ path: String, query: [URLQueryItem] = []) async throws -> Data {
        let req = URLRequest(url: try makeURL(path, query: query))
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw GoldfishError.server(0, "Keine Antwort vom Server")
        }
        guard (200..<300).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw GoldfishError.server(http.statusCode, msg)
        }
        return data
    }

    /// Roher Text einer Server-Ressource (authentifiziert) — z.B. eine
    /// WebVTT-Untertitel-Datei für den Player-Overlay.
    public func fetchText(serverPath: String) async throws -> String {
        let data = try await performRaw(serverPath)
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func performVoid(_ path: String, method: String = "PUT", query: [URLQueryItem] = [], jsonBody: Data? = nil) async throws {
        var req = URLRequest(url: try makeURL(path, query: query))
        req.httpMethod = method
        if let jsonBody {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = jsonBody
        }
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw GoldfishError.server(0, "Keine Antwort vom Server")
        }
        guard (200..<300).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw GoldfishError.server(http.statusCode, msg)
        }
    }

    // MARK: - Auth

    public func authStatus() async throws -> AuthStatus {
        try await perform("/api/auth/status")
    }

    /// Reconciles local login state with what the server actually knows (e.g. an expired cookie).
    public func applySessionStatus(_ status: AuthStatus) {
        if status.loggedIn {
            currentUsername = status.username
            isAdmin = status.isAdmin
            isLoggedIn = true
            if let username = status.username {
                UserDefaults.standard.set(username, forKey: "goldfish.username")
                // Kein rememberCurrentSession hier: dieser Pfad deckt auch OIDC-Logins ab, für
                // die es kein Goldfish-eigenes Passwort gibt, gegen das offline verifiziert
                // werden könnte — Offline-Kontowechsel bleibt bewusst auf Passwort-Logins
                // beschränkt (siehe login()).
            }
        } else {
            currentUsername = nil
            isAdmin = false
            isLoggedIn = false
            UserDefaults.standard.removeObject(forKey: "goldfish.username")
        }
    }

    public func login(username: String, password: String) async throws {
        let body = try JSONEncoder().encode(["username": username, "password": password])
        let resp: LoginResponse = try await perform("/api/auth/login", method: "POST", jsonBody: body)
        currentUsername = resp.username
        isAdmin = resp.isAdmin
        isLoggedIn = true
        UserDefaults.standard.set(resp.username, forKey: "goldfish.username")
        rememberCurrentSession(username: resp.username, isAdmin: resp.isAdmin, password: password)
    }

    /// True wenn `error` daran scheiterte, den Server überhaupt zu erreichen (kein Internet,
    /// DNS, Timeout, …) — im Unterschied zu einem Server-seitigen Ablehnen (401 falsches
    /// Passwort). `LoginView` nutzt das, um NUR bei echten Verbindungsproblemen den
    /// Offline-Fallback zu versuchen, nicht bei einem simplen Tippfehler im Passwort.
    public static func isConnectivityError(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost,
             .cannotFindHost, .timedOut, .dnsLookupFailed, .internationalRoamingOff,
             .dataNotAllowed:
            return true
        default:
            return false
        }
    }

    /// True wenn der Server MIT einer Antwort abgelehnt hat, weil die Session
    /// ungültig ist (401 "nicht angemeldet" / "Session abgelaufen") — im
    /// Unterschied zu einem reinen Verbindungsproblem (`isConnectivityError`).
    /// Ein 401 beweist, dass der Server erreichbar ist — die App darf das NICHT
    /// als "offline" behandeln, sondern muss zurück auf den Login.
    public static func isAuthError(_ error: Error) -> Bool {
        if case GoldfishError.server(401, _) = error { return true }
        return false
    }

    /// Aufrufen, wenn ein normaler API-Request 401 liefert, obwohl der Server
    /// erreichbar ist: der lokal gemerkte Login ist tot. Lokalen Zustand +
    /// Cookies für diesen Host wegräumen, damit `RootView` den Login-Screen
    /// zeigt statt endlos weiter 401 zu kassieren. War der eigentliche Grund
    /// für "offline → online → Bibliotheken kommen nicht wieder, Fehler
    /// Session abgelaufen": nichts hat diesen Zustand je aufgelöst.
    public func markSessionInvalid() {
        currentUsername = nil
        isAdmin = false
        isLoggedIn = false
        UserDefaults.standard.removeObject(forKey: "goldfish.username")
        if let base = baseURL, let cookies = HTTPCookieStorage.shared.cookies(for: base) {
            cookies.forEach { HTTPCookieStorage.shared.deleteCookie($0) }
        }
    }

    // MARK: - Gemerkte Konten (Offline-Benutzerwechsel)

    public struct RememberedAccount: Codable, Identifiable, Equatable {
        public let username: String
        public let isAdmin: Bool
        public var id: String { username }
    }

    private static let rememberedAccountsKey = "goldfish.rememberedAccounts"

    private static func loadRememberedAccountsList() -> [RememberedAccount] {
        guard let data = UserDefaults.standard.data(forKey: rememberedAccountsKey),
              let list = try? JSONDecoder().decode([RememberedAccount].self, from: data) else { return [] }
        return list
    }

    private func saveRememberedAccountsList(_ list: [RememberedAccount]) {
        rememberedAccounts = list
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: Self.rememberedAccountsKey)
        }
    }

    /// Keychain-Einträge sind pro Server gescoped (Host im Key) — dieselbe Kombination aus
    /// Username kann auf zwei verschiedenen Goldfish-Servern völlig unterschiedliche Accounts
    /// meinen.
    private func keychainKey(for username: String) -> String {
        "\(baseURL?.host ?? "_")|\(username)"
    }

    /// Läuft nach jedem erfolgreichen PASSWORT-Login (nicht OIDC — da gibt es kein
    /// Goldfish-eigenes Passwort zu prüfen) — sichert die Session-Cookies UND einen lokalen
    /// Passwort-Verifier (gesalzener SHA256-Hash, NICHT das Klartext-Passwort), damit dieses
    /// Konto später per Passwort-Eingabe offline freigeschaltet werden kann. User-Anfrage
    /// 2026-08-19: "Mit Passwortabfrage wäre mir aber lieber" — ein reiner Klick-Wechsel ohne
    /// erneute Passworteingabe wäre auf dem gemeinsam genutzten Familien-Mac keine echte
    /// Zugriffskontrolle zwischen den Konten gewesen.
    private func rememberCurrentSession(username: String, isAdmin: Bool, password: String) {
        guard let base = baseURL, let cookies = HTTPCookieStorage.shared.cookies(for: base), !cookies.isEmpty else { return }
        guard let cookieData = try? NSKeyedArchiver.archivedData(withRootObject: cookies, requiringSecureCoding: true) else { return }
        KeychainHelper.set(cookieData, forKey: keychainKey(for: username))

        let salt = (KeychainHelper.get(forKey: verifierKey(for: username)).flatMap { try? JSONDecoder().decode(PasswordVerifier.self, from: $0) }?.salt)
            ?? UUID().uuidString
        let verifier = PasswordVerifier(salt: salt, hash: Self.hash(password: password, salt: salt), savedAt: Date())
        if let verifierData = try? JSONEncoder().encode(verifier) {
            KeychainHelper.set(verifierData, forKey: verifierKey(for: username))
        }

        var list = Self.loadRememberedAccountsList().filter { $0.username != username }
        list.append(RememberedAccount(username: username, isAdmin: isAdmin))
        saveRememberedAccountsList(list)
    }

    private struct PasswordVerifier: Codable {
        let salt: String
        let hash: String
        let savedAt: Date
    }

    private func verifierKey(for username: String) -> String { keychainKey(for: username) + "|pw" }

    private static func hash(password: String, salt: String) -> String {
        let digest = SHA256.hash(data: Data((salt + password).utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Wie lange eine offline verifizierte Anmeldung gültig bleibt, bevor zwingend wieder ein
    /// echter Online-Login nötig ist — User-Anfrage: "zumindest immer für 14 Tage. Spätestens
    /// dann muss man wieder online gehen". Jeder erfolgreiche ONLINE-Login (siehe `login()`)
    /// setzt die 14 Tage neu, weil `rememberCurrentSession` `savedAt` dabei immer neu schreibt.
    private static let offlineGracePeriod: TimeInterval = 14 * 24 * 60 * 60

    public enum OfflineLoginResult {
        case success
        case wrongPassword
        case noRememberedSession
        case sessionExpired
    }

    /// User-Anfrage 2026-08-19: "Kann ich offline den Benutzer wechseln?" — prüft das
    /// eingegebene Passwort gegen den lokal gespeicherten Verifier (kein Netzwerk-Call) und
    /// stellt bei Erfolg die gemerkten Session-Cookies wieder her. `LoginView` ruft das NUR
    /// auf, wenn der normale Online-Login zuvor an einem echten Verbindungsproblem gescheitert
    /// ist (siehe `isConnectivityError`), nicht bei jedem beliebigen Fehler.
    public func loginOffline(username: String, password: String) -> OfflineLoginResult {
        guard let verifierData = KeychainHelper.get(forKey: verifierKey(for: username)),
              let verifier = try? JSONDecoder().decode(PasswordVerifier.self, from: verifierData) else {
            return .noRememberedSession
        }
        guard Self.hash(password: password, salt: verifier.salt) == verifier.hash else {
            return .wrongPassword
        }
        guard Date().timeIntervalSince(verifier.savedAt) <= Self.offlineGracePeriod else {
            return .sessionExpired
        }
        guard switchToRememberedAccount(username: username) else { return .noRememberedSession }
        return .success
    }

    private func switchToRememberedAccount(username: String) -> Bool {
        guard let base = baseURL,
              let data = KeychainHelper.get(forKey: keychainKey(for: username)),
              let cookies = try? NSKeyedUnarchiver.unarchivedObject(ofClasses: [NSArray.self, HTTPCookie.self], from: data) as? [HTTPCookie] else {
            return false
        }
        // Erst alle aktuell für diesen Host gesetzten Cookies entfernen — sonst könnte ein
        // Cookie des VORHERIGEN Kontos neben den neuen stehen bleiben.
        if let existing = HTTPCookieStorage.shared.cookies(for: base) {
            for c in existing { HTTPCookieStorage.shared.deleteCookie(c) }
        }
        for cookie in cookies { HTTPCookieStorage.shared.setCookie(cookie) }
        let remembered = rememberedAccounts.first { $0.username == username }
        currentUsername = username
        isAdmin = remembered?.isAdmin ?? false
        isLoggedIn = true
        UserDefaults.standard.set(username, forKey: "goldfish.username")
        return true
    }

    public func forgetRememberedAccount(username: String) {
        KeychainHelper.delete(forKey: keychainKey(for: username))
        KeychainHelper.delete(forKey: verifierKey(for: username))
        saveRememberedAccountsList(rememberedAccounts.filter { $0.username != username })
    }

    /// URL to open in a web view to start the Authentik SSO flow. The server handles the
    /// entire OAuth2/PKCE exchange itself and sets the session cookie on success.
    public var oidcLoginURL: URL? {
        assetURL("/api/auth/oidc/login")
    }

    public func logout() async {
        _ = try? await performVoid("/api/auth/logout", method: "POST")
        currentUsername = nil
        isAdmin = false
        isLoggedIn = false
        UserDefaults.standard.removeObject(forKey: "goldfish.username")
        if let base = baseURL, let cookies = HTTPCookieStorage.shared.cookies(for: base) {
            cookies.forEach { HTTPCookieStorage.shared.deleteCookie($0) }
        }
    }

    // MARK: - Libraries

    public func fetchLibraries() async throws -> [Library] {
        try await perform("/api/libraries")
    }

    /// Pollt den Fortschritt der server-seitigen Formatanpassung (`?compat=1`).
    /// Stößt sie serverseitig an, falls nötig und noch nicht laufend/gecacht —
    /// der Client muss also nur wiederholt aufrufen, bis `state == "ready"`.
    public func compatDownloadStatus(itemId: Int64) async throws -> CompatPrep {
        try await perform("/api/download/\(itemId)/compat-status")
    }

    public func fetchHome() async throws -> HomeResponse {
        try await perform("/api/home")
    }

    // MARK: - Items

    public func fetchItems(
        libraryId: Int64? = nil,
        folder: String? = nil,
        search: String? = nil,
        sort: ItemSort? = nil,
        ascending: Bool? = nil,
        watched: WatchedFilter? = nil,
        favoritesOnly: Bool = false,
        buckets: [String] = [],
        personId: Int64? = nil
    ) async throws -> [Item] {
        var query: [URLQueryItem] = []
        if let libraryId { query.append(URLQueryItem(name: "libraryId", value: String(libraryId))) }
        if let folder { query.append(URLQueryItem(name: "folder", value: folder)) }
        if let search, !search.isEmpty { query.append(URLQueryItem(name: "search", value: search)) }
        if let sort, sort != .title { query.append(URLQueryItem(name: "sort", value: sort.rawValue)) }
        if let ascending { query.append(URLQueryItem(name: "dir", value: ascending ? "asc" : "desc")) }
        if let watched, watched != .all { query.append(URLQueryItem(name: "watched", value: watched.rawValue)) }
        // Server: `favorite=yes` (internal/api/items.go, ItemFilter.Favorite) — User-Anfrage
        // 2026-08-19: "der Filter Favoriten fehlt", war bisher nirgends im Mac/iOS-Client
        // verdrahtet trotz vorhandener Server-Unterstützung.
        if favoritesOnly { query.append(URLQueryItem(name: "favorite", value: "yes")) }
        for bucket in buckets { query.append(URLQueryItem(name: "bucket", value: bucket)) }
        if let personId { query.append(URLQueryItem(name: "personId", value: String(personId))) }
        return try await perform("/api/items", query: query)
    }

    /// `folderSelections` scopes shuffle to one or more libraries/subfolders at once
    /// (User-Anfrage 2026-08-19: "Zufällig Abspielen" auf eine Auswahl von Bibliotheken UND
    /// Unterordnern beschränkbar, analog zum Browser-🎯-Dialog). The server already supports
    /// repeated `folderSel=<libId>:<relPath>` query params (CLAUDE.md "Ordner-Scoping für
    /// Shuffle" / `ItemFilter.Folders`) — no server change needed. `libraryId`/`libraryIds`
    /// stay for the PER-LIBRARY shuffle inside `ItemGridView`, unrelated to the global scope.
    public func randomItem(libraryId: Int64? = nil, libraryIds: [Int64]? = nil, folderSelections: [ShuffleFolderSelection]? = nil, folder: String? = nil, search: String? = nil) async throws -> Item {
        var query: [URLQueryItem] = []
        if let folderSelections, !folderSelections.isEmpty {
            for sel in folderSelections {
                query.append(URLQueryItem(name: "folderSel", value: "\(sel.libraryId):\(sel.folder)"))
            }
        } else if let libraryIds, !libraryIds.isEmpty {
            for id in libraryIds { query.append(URLQueryItem(name: "libraryId", value: String(id))) }
        } else if let libraryId {
            query.append(URLQueryItem(name: "libraryId", value: String(libraryId)))
        }
        if let folder { query.append(URLQueryItem(name: "folder", value: folder)) }
        if let search, !search.isEmpty { query.append(URLQueryItem(name: "search", value: search)) }
        return try await perform("/api/items/random", query: query)
    }

    public func fetchItem(id: Int64) async throws -> Item {
        try await perform("/api/items/\(id)")
    }

    /// All sibling files sharing the same `metadataId` as `itemId` (including `itemId`
    /// itself) — powers the "Varianten"-Picker in `ItemDetailView`.
    public func fetchVariants(itemId: Int64) async throws -> [Item] {
        try await perform("/api/items/\(itemId)/variants")
    }

    public func fetchSeasons(libraryId: Int64, folder: String) async throws -> SeasonsResponse {
        try await perform("/api/libraries/\(libraryId)/seasons", query: [URLQueryItem(name: "folder", value: folder)])
    }

    public func fetchCast(metadataId: Int64) async throws -> [CastMember] {
        try await perform("/api/metadata/\(metadataId)/cast")
    }

    /// Nur für Filme (`tmdb_type=movie`) — der Server antwortet mit 404, wenn kein
    /// öffentlicher YouTube-Trailer gefunden wurde (Normalfall bei den meisten
    /// Filmen), das ist hier ein regulärer `throw`, kein Sonderfall.
    public func fetchTrailer(metadataId: Int64) async throws -> TrailerInfo {
        try await perform("/api/metadata/\(metadataId)/trailer")
    }

    /// Server lädt den Trailer per yt-dlp herunter/muxt ihn (kein WebKit auf
    /// tvOS nötig, siehe CLAUDE.md "Trailer") und liefert eine RELATIVE URL
    /// zur fertigen Datei (`/api/trailer-file/{key}`) — gegen `baseURL`
    /// aufgelöst, damit sie direkt an `AVPlayer` gegeben werden kann. Kann
    /// fehlschlagen (502), wenn der Download gerade nicht klappt — Aufrufer
    /// sollte dann auf ein externes Öffnen zurückfallen, nicht hart scheitern.
    public func fetchTrailerStreamURL(metadataId: Int64) async throws -> URL {
        struct Response: Decodable { let url: String }
        let resp: Response = try await perform("/api/metadata/\(metadataId)/trailer-stream")
        guard let url = URL(string: resp.url, relativeTo: baseURL)?.absoluteURL else {
            throw URLError(.badURL)
        }
        return url
    }

    /// Bio-Daten + volle Filmografie einer Person (live von TMDB, serverseitig
    /// gecacht). Gegenstück zum Browser `GET /api/person/{tmdbId}`.
    public func fetchPersonDetails(tmdbId: Int64) async throws -> PersonDetails {
        try await perform("/api/person/\(tmdbId)")
    }

    public func fetchFolders(libraryId: Int64, parent: String? = nil) async throws -> [FolderTile] {
        var query: [URLQueryItem] = []
        if let parent, !parent.isEmpty { query.append(URLQueryItem(name: "parent", value: parent)) }
        return try await perform("/api/libraries/\(libraryId)/folders", query: query)
    }

    // MARK: - Resume

    public func getResume(itemId: Int64) async throws -> Double {
        let resp: ResumePosition = try await perform("/api/items/\(itemId)/resume")
        return resp.positionSec
    }

    public func setResume(itemId: Int64, positionSec: Double) async throws {
        let body = try JSONEncoder().encode(ResumePosition(positionSec: positionSec))
        try await performVoid("/api/items/\(itemId)/resume", method: "PUT", jsonBody: body)
    }

    // MARK: - Watched / Favorite

    public func setWatched(itemId: Int64, watched: Bool) async throws {
        let body = try JSONEncoder().encode(["watched": watched])
        try await performVoid("/api/items/\(itemId)/watched", method: "PUT", jsonBody: body)
    }

    public func setFavorite(itemId: Int64, favorite: Bool) async throws {
        let body = try JSONEncoder().encode(["favorite": favorite])
        try await performVoid("/api/items/\(itemId)/favorite", method: "PUT", jsonBody: body)
    }

    // MARK: - Eigenes Passwort ändern

    /// Ändert das Passwort des aktuell angemeldeten Users. Der Server prüft
    /// `oldPassword` gegen den gespeicherten Hash (403 bei falschem Passwort)
    /// und verlangt `newPassword` >= 6 Zeichen (400 sonst) — beide Fehler
    /// kommen über `GoldfishError.server` mit dem Server-Text direkt
    /// verwendbar in der UI an (siehe `errorDescription`).
    public func changePassword(oldPassword: String, newPassword: String) async throws {
        let body = try JSONEncoder().encode(["oldPassword": oldPassword, "newPassword": newPassword])
        try await performVoid("/api/auth/password", method: "PUT", jsonBody: body)
    }

    // MARK: - Trickplay (Hover-Vorschau im Player)

    /// Lädt + parst das VTT-Manifest. Wirft nicht bei fehlenden Trickplay-Daten (404 vom
    /// Server, z.B. `trickplayStatus != "done"`) — liefert einfach ein leeres Array, damit
    /// der Player die Vorschau still weglässt statt einen Fehler zu zeigen.
    public func fetchTrickplayCues(itemId: Int64) async -> [TrickplayCue] {
        guard let data = try? await performRaw("/api/trickplay/\(itemId)/thumbs.vtt"),
              let text = String(data: data, encoding: .utf8) else { return [] }
        return TrickplayVTTParser.parse(text)
    }

    /// Lädt das komplette Sprite-Sheet als `CGImage` (nicht als `URL`, damit der Aufrufer
    /// nicht selbst eine zweite, unauthentifizierte `URLSession` bräuchte — die Session-Cookie-
    /// Auth läuft hier über dieselbe `session`-Instanz wie jeder andere Request).
    public func fetchTrickplaySprite(itemId: Int64) async -> CGImage? {
        guard let data = try? await performRaw("/api/trickplay/\(itemId)/sprite.jpg") else { return nil }
        #if os(macOS)
        guard let nsImage = NSImage(data: data) else { return nil }
        var rect = CGRect(origin: .zero, size: nsImage.size)
        return nsImage.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        #else
        return UIImage(data: data)?.cgImage
        #endif
    }

    // MARK: - Watch-Link (Gesehen-Sync zwischen zwei Usern)

    public func fetchOtherUsers() async throws -> [OtherUser] {
        try await perform("/api/users/names")
    }

    public func fetchWatchLinks() async throws -> [WatchLink] {
        try await perform("/api/watch-links")
    }

    public func requestWatchLink(username: String) async throws {
        let body = try JSONEncoder().encode(["username": username])
        try await performVoid("/api/watch-links", method: "POST", jsonBody: body)
    }

    public func confirmWatchLink(partnerId: Int64) async throws {
        try await performVoid("/api/watch-links/\(partnerId)/confirm", method: "POST")
    }

    public func unlinkWatchLink(partnerId: Int64) async throws {
        try await performVoid("/api/watch-links/\(partnerId)", method: "DELETE")
    }

    // MARK: - Playback

    public func playback(itemId: Int64, mode: String = "auto") async throws -> PlaybackResponse {
        try await perform("/api/playback/\(itemId)", query: [URLQueryItem(name: "mode", value: mode)])
    }

    // MARK: - Collections

    public func fetchCollections() async throws -> [Collection] {
        try await perform("/api/collections")
    }

    /// `/api/collections/{id}/items` returns `[CollectionPart]` for collections whose parts
    /// have already been fetched from TMDB, but falls back to a plain `[Item]` for older
    /// collections that predate the parts feature (see `internal/api/collections.go`
    /// `collectionItems`) — try the normal shape first, then fall back rather than erroring.
    public func fetchCollectionParts(id: Int64) async throws -> [CollectionPart] {
        let data = try await performRaw("/api/collections/\(id)/items")
        if let parts = try? decoder.decode([CollectionPart].self, from: data) {
            return parts
        }
        let items = try decoder.decode([Item].self, from: data)
        return items.map {
            CollectionPart(tmdbMovieId: $0.metadata?.tmdbId ?? $0.id, title: $0.displayTitle, releaseDate: $0.releasedAt, posterPath: $0.metadata?.posterPath, owned: true, hidden: false, item: $0)
        }
    }

    public func hideCollectionPart(collectionId: Int64, tmdbMovieId: Int64) async throws {
        try await performVoid("/api/collections/\(collectionId)/parts/\(tmdbMovieId)/hide", method: "POST")
    }

    public func unhideCollectionPart(collectionId: Int64, tmdbMovieId: Int64) async throws {
        try await performVoid("/api/collections/\(collectionId)/parts/\(tmdbMovieId)/hide", method: "DELETE")
    }

    public func collectionPosterURL(id: Int64) -> URL? {
        assetURL("/api/poster/collection/\(id)")
    }

    // MARK: - Playlists

    public func fetchPlaylists() async throws -> [Playlist] {
        try await perform("/api/playlists")
    }

    public func createPlaylist(name: String) async throws -> Playlist {
        let body = try JSONEncoder().encode(["name": name])
        return try await perform("/api/playlists", method: "POST", jsonBody: body)
    }

    public func renamePlaylist(id: Int64, name: String) async throws {
        let body = try JSONEncoder().encode(["name": name])
        try await performVoid("/api/playlists/\(id)", method: "PUT", jsonBody: body)
    }

    public func deletePlaylist(id: Int64) async throws {
        try await performVoid("/api/playlists/\(id)", method: "DELETE")
    }

    public func fetchPlaylistItems(id: Int64) async throws -> [Item] {
        try await perform("/api/playlists/\(id)/items")
    }

    public struct AddPlaylistItemResponse: Decodable { public let added: Bool }

    @discardableResult
    public func addToPlaylist(playlistId: Int64, itemId: Int64) async throws -> Bool {
        let body = try JSONEncoder().encode(["itemId": itemId])
        let resp: AddPlaylistItemResponse = try await perform("/api/playlists/\(playlistId)/items", method: "POST", jsonBody: body)
        return resp.added
    }

    public func removeFromPlaylist(playlistId: Int64, itemId: Int64) async throws {
        try await performVoid("/api/playlists/\(playlistId)/items/\(itemId)", method: "DELETE")
    }

    public func reorderPlaylist(id: Int64, itemIds: [Int64]) async throws {
        let body = try JSONEncoder().encode(["itemIds": itemIds])
        try await performVoid("/api/playlists/\(id)/items", method: "PUT", jsonBody: body)
    }

    public func fetchPlaylistsForItem(itemId: Int64) async throws -> [Playlist] {
        try await perform("/api/items/\(itemId)/playlists")
    }

    // MARK: - Assets

    /// `posterPath` (optional): der TMDB-Pfad-String aus `metadata.posterPath`. Der Server
    /// cached das Poster unter einem vom Pfad abgeleiteten Dateinamen (sha1(posterPath), siehe
    /// `internal/enrich/worker.go` `posterFilename`) — die URL selbst bleibt aber bei jedem
    /// Re-Match unter derselben `metadataId` gleich. Ohne Cache-Busting kann ein Client-seitiger
    /// URL-Cache (Browser ODER `AsyncImage`/`URLCache.shared` in der Mac/iOS-App — beide teilen
    /// sich denselben System-Cache) nach einer Neuzuordnung noch das ALTE Poster unter derselben
    /// URL zeigen (User-Bericht 2026-08-19: "American Fighter"-Kachel zeigte ein zugeschnittenes/
    /// falsch wirkendes Poster, reproduzierbar sowohl im Browser als auch in der nativen App —
    /// die Datei auf dem Server war nachweislich korrekt, also ein Client-Cache-Problem). Ein
    /// `?v=<posterPath>`-Query erzwingt bei jeder Änderung des TMDB-Posters eine komplett neue
    /// URL, der alte Cache-Eintrag wird nie wieder getroffen.
    public func posterURL(metadataId: Int64, posterPath: String? = nil) -> URL? {
        guard let base = assetURL("/api/poster/metadata/\(metadataId)") else { return nil }
        guard let posterPath, !posterPath.isEmpty else { return base }
        var comps = URLComponents(url: base, resolvingAgainstBaseURL: false)
        comps?.queryItems = [URLQueryItem(name: "v", value: posterPath)]
        return comps?.url ?? base
    }

    public func thumbURL(itemId: Int64) -> URL? {
        assetURL("/api/thumb/\(itemId)")
    }

    /// `?compat=1`: der Server entscheidet jetzt selbst (analog zu Jellyfins
    /// Geräteprofil-Direct-Play-Logik), ob die Datei schon abspielbar ist, und
    /// liefert sonst eine einmalig serverseitig erzeugte, kompatible Kopie
    /// (`internal/download` im Server-Repo) — ersetzt die frühere client-
    /// seitige Nachbearbeitung per lokalem ffmpeg (`LocalTranscodeService`,
    /// die jetzt nur noch für lokale/externe Bibliotheken ohne Server läuft).
    /// Nützt auch iOS, das nie ein eigenes ffmpeg zur Nachbearbeitung hatte.
    public func downloadFileURL(itemId: Int64) -> URL? {
        guard let base = assetURL("/api/download/\(itemId)") else { return nil }
        var comps = URLComponents(url: base, resolvingAgainstBaseURL: false)
        comps?.queryItems = [URLQueryItem(name: "compat", value: "1")]
        return comps?.url ?? base
    }
}

private struct EmptyResponse: Decodable {}
