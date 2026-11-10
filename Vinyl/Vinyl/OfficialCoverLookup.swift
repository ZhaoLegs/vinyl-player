import Foundation
import ImageIO

struct OfficialCoverQuery: Hashable, Sendable {
    let id: String
    let title: String
    let artist: String

    var cacheKey: String {
        OfficialCoverText.canonical(title) + "|" + OfficialCoverText.canonical(artist)
    }
}

enum OfficialCoverText {
    static func cleanTitle(_ value: String) -> String {
        var title = value.trimmingCharacters(in: .whitespacesAndNewlines)
        // Only remove edition labels. Taylor's Version, live, nightcore, etc. describe different recordings.
        let edition = #"(?:single|ep|deluxe(?:\s+edition)?|(?:\d{4}\s+)?remaster(?:ed)?(?:\s+\d{4})?|expanded(?:\s+edition)?|special\s+edition)"#
        let suffix = #"(?i)\s*(?:[\(\[（【]\s*"# + edition + #"\s*[\)\]）】]|\s+[-–—]\s*"# + edition + #"|\s+deluxe(?:\s+edition)?)\s*$"#
        while let range = title.range(of: suffix, options: .regularExpression) {
            title.removeSubrange(range)
            title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return title
    }

    static func variants(_ value: String) -> [String] {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        var result: [String] = []
        for base in [clean, arabicMonths(clean)] {
            for text in [base, base.applyingTransform(StringTransform("Hans-Hant"), reverse: false) ?? base,
                         base.applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? base] {
                if !text.isEmpty && !result.contains(text) { result.append(text) }
            }
        }
        return result
    }

    static func canonical(_ value: String) -> String {
        let clean = arabicMonths(cleanTitle(value))
        let simplified = clean.applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? clean
        return simplified.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive],
                                  locale: Locale(identifier: "en_US_POSIX"))
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }

    static func quote(_ value: String) -> String {
        "\"\(escape(value))\""
    }

    private static func escape(_ value: String) -> String {
        let special = CharacterSet(charactersIn: #"+-&|!(){}[]^"~*?:\/"#)
        return value.unicodeScalars.map { special.contains($0) ? "\\" + String($0) : String($0) }.joined()
    }

    static func field(_ name: String, values: [String], phrase: Bool = true) -> String {
        "(" + values.map { "\(name):\(phrase ? quote($0) : "(" + escape($0) + ")")" }
            .joined(separator: " OR ") + ")"
    }

    private static func arabicMonths(_ value: String) -> String {
        var result = value
        let months = ["一", "二", "三", "四", "五", "六", "七", "八", "九", "十", "十一", "十二"]
        for (index, month) in months.enumerated().reversed() {
            result = result.replacingOccurrences(
                of: "(?<![零〇一二三四五六七八九十百千万萬])\(month)月",
                with: "\(index + 1)月", options: .regularExpression)
        }
        return result
    }
}

struct OfficialCoverMatch: Sendable {
    let url: URL
    let mbid: String
    let title: String
    let artist: String
    let score: Int
    let source: String
}

struct OfficialCoverResult: Sendable {
    let match: OfficialCoverMatch
    /// A newly verified image is handed to ArtworkCache so it is not downloaded twice.
    let imageData: Data?
}

private enum OfficialCoverError: Error {
    case http(Int, URL)
    case invalidImage(URL)
}

/// One FIFO for actual requests, including retries; actor reentrancy cannot start two requests together.
actor OfficialCoverHTTPClient {
    static let shared = OfficialCoverHTTPClient()
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    private let transport: Transport
    private let clock = ContinuousClock()
    private var lastMBStart: ContinuousClock.Instant?
    private var tail: Task<Void, Never>?
    private var generation = 0

    init(transport: Transport? = nil) {
        if let transport {
            self.transport = transport
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 60
            configuration.httpMaximumConnectionsPerHost = 1
            let session = URLSession(configuration: configuration)
            self.transport = { request in
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
                return (data, http)
            }
        }
    }

    func request(_ url: URL, accept: String = "application/json") async throws -> (Data, HTTPURLResponse) {
        let previous = tail
        generation += 1
        let current = generation
        let task = Task {
            if let previous { await previous.value }
            return try await execute(url, accept: accept)
        }
        tail = Task { _ = try? await task.value }
        defer { if generation == current { tail = nil } }
        return try await task.value
    }

    private func execute(_ url: URL, accept: String) async throws -> (Data, HTTPURLResponse) {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        var request = URLRequest(url: url)
        request.setValue("VinylPlayer/\(version) (https://github.com/ZhaoLegs/vinyl-player)",
                         forHTTPHeaderField: "User-Agent")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        for attempt in 0...3 {
            try Task.checkCancellation()
            if url.host == "musicbrainz.org" {
                if let lastMBStart {
                    try await clock.sleep(until: lastMBStart.advanced(by: .milliseconds(1100)))
                }
                lastMBStart = clock.now
            }
            do {
                let response = try await transport(request)
                if [429, 500, 502, 503, 504].contains(response.1.statusCode) {
                    guard attempt < 3 else { throw OfficialCoverError.http(response.1.statusCode, url) }
                    let backoff = Double(1 << attempt)
                    let retryAfter = Self.retryDelay(response.1.value(forHTTPHeaderField: "Retry-After"))
                    try await Task.sleep(for: .seconds(max(backoff, retryAfter)))
                    continue
                }
                return response
            } catch let error as URLError {
                guard [.networkConnectionLost, .timedOut, .cannotConnectToHost,
                       .dnsLookupFailed, .cannotFindHost].contains(error.code), attempt < 3 else { throw error }
                print("[t197u] retry \(attempt + 1)/3 \(url.host ?? ""): \(error.code.rawValue)")
                try await Task.sleep(for: .seconds(1 << attempt))
            }
        }
        throw URLError(.badServerResponse)
    }

    private static func retryDelay(_ value: String?) -> Double {
        guard let value else { return 0 }
        if let seconds = Double(value) { return max(0, seconds) }
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = TimeZone(secondsFromGMT: 0)
        format.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
        return max(0, format.date(from: value)?.timeIntervalSinceNow ?? 0)
    }
}

/// Synchronous reads support the existing first-frame memory-cache path; all mutations are scoped locks.
private final class OfficialCoverMap: @unchecked Sendable {
    struct Entry: Codable {
        var url: String?
        var checkedAt: Date
        var version: Int?
        var queryKey: String?
        var mbid: String?
        var title: String?
        var artist: String?
        var score: Int?
        var source: String?

        var match: OfficialCoverMatch? {
            guard let url, let parsed = URL(string: url) else { return nil }
            return .init(url: parsed, mbid: mbid ?? "", title: title ?? "", artist: artist ?? "",
                         score: score ?? 0, source: source ?? "cache")
        }
    }

    private let lock = NSLock()
    private let file: URL
    private var entries: [String: Entry]

    init(directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        file = directory.appendingPathComponent("map.json")
        let decoded = (try? Data(contentsOf: file)).flatMap {
            try? JSONDecoder().decode([String: Entry].self, from: $0)
        } ?? [:]
        // Build 150 persisted both real misses and transport errors as nil. Only its hits are trustworthy.
        entries = decoded.filter { $0.value.url != nil || $0.value.version == 2 }
    }

    func entry(for query: OfficialCoverQuery) -> Entry? {
        lock.withLock {
            guard let entry = entries[query.id],
                  entry.queryKey == nil || entry.queryKey == query.cacheKey else { return nil }
            if entry.url == nil && Date().timeIntervalSince(entry.checkedAt) >= 7 * 86400 { return nil }
            return entry
        }
    }

    func cachedURL(for id: String) -> URL? {
        lock.withLock { entries[id]?.match?.url }
    }

    func store(_ result: OfficialCoverResult?, for query: OfficialCoverQuery) {
        lock.withLock {
            let match = result?.match
            entries[query.id] = Entry(url: match?.url.absoluteString, checkedAt: Date(), version: 2,
                queryKey: query.cacheKey, mbid: match?.mbid, title: match?.title, artist: match?.artist,
                score: match?.score, source: match?.source)
            if let data = try? JSONEncoder().encode(entries) { try? data.write(to: file, options: .atomic) }
        }
    }
}

actor OfficialCoverLookup {
    static let shared = OfficialCoverLookup()
    private let client: OfficialCoverHTTPClient
    private nonisolated let map: OfficialCoverMap
    private let diagnostics: Bool
    private var inflight: [OfficialCoverQuery: Task<OfficialCoverResult?, Error>] = [:]
    private var tail: Task<Void, Never>?
    private var generation = 0
    private var stats = (hit: 0, miss: 0, error: 0)

    init(cacheDirectory: URL? = nil, client: OfficialCoverHTTPClient = .shared, diagnostics: Bool = false) {
        let directory = cacheDirectory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("official-covers", isDirectory: true)
        map = OfficialCoverMap(directory: directory)
        self.client = client
        self.diagnostics = diagnostics
    }

    nonisolated func cachedURL(for id: String) -> URL? { map.cachedURL(for: id) }

    func resolve(_ query: OfficialCoverQuery) async throws -> OfficialCoverResult? {
        guard !query.id.hasPrefix("playlist-"), !query.id.hasPrefix("library-songs"),
              !OfficialCoverText.canonical(query.title).isEmpty,
              !OfficialCoverText.canonical(query.artist).isEmpty else { return nil }
        if let entry = map.entry(for: query) {
            return entry.match.map { OfficialCoverResult(match: $0, imageData: nil) }
        }
        if let task = inflight[query] { return try await task.value }
        let previous = tail
        generation += 1
        let current = generation
        let task = Task {
            if let previous { await previous.value }
            return try await perform(query)
        }
        inflight[query] = task
        tail = Task { _ = try? await task.value }
        defer {
            inflight[query] = nil
            if generation == current { tail = nil }
        }
        return try await task.value
    }

    private func perform(_ query: OfficialCoverQuery) async throws -> OfficialCoverResult? {
        do {
            let result = try await lookup(query)
            map.store(result, for: query)
            if result != nil { stats.hit += 1 } else { stats.miss += 1 }
            logStats()
            return result
        } catch {
            stats.error += 1
            print("[t197u] official cover failed for \(query.artist) / \(query.title): \(error)")
            logStats()
            // A temporary error must never be written to the negative cache.
            throw error
        }
    }

    private func logStats() {
        let total = stats.hit + stats.miss + stats.error
        if total == 24 || total % 40 == 0 {
            print("[t197u] official covers: \(stats.hit)/\(total) matched, miss \(stats.miss), err \(stats.error)")
        }
    }

    private struct Candidate {
        let id: String
        let title: String
        let names: [String]
        let artistIDs: Set<String>
        let score: Int
        let source: String
        let hasFront: Bool
    }

    private func lookup(_ query: OfficialCoverQuery) async throws -> OfficialCoverResult? {
        let titles = OfficialCoverText.variants(OfficialCoverText.cleanTitle(query.title))
        let artists = OfficialCoverText.variants(query.artist)
        let titleQuery = OfficialCoverText.field("releasegroup", values: titles)
        let artistQuery = OfficialCoverText.field("artist", values: artists)
        var groups = try await search("release-group", query: "\(titleQuery) AND \(artistQuery)")
        var artistIDs = Set<String>()
        var matches = matching(groups, query: query, artistIDs: artistIDs)
        if matches.isEmpty {
            let broadTitle = OfficialCoverText.field("releasegroup", values: titles, phrase: false)
            let broadArtist = OfficialCoverText.field("artist", values: artists, phrase: false)
            groups = try await search("release-group", query: "\(broadTitle) AND \(broadArtist)")
            matches = matching(groups, query: query, artistIDs: artistIDs)
        }
        if matches.isEmpty {
            // The artist field does not consistently search aliases. Resolve identity first, then search by MBID.
            artistIDs = try await findArtists(artists)
            if !artistIDs.isEmpty {
                let ids = "(" + artistIDs.sorted().map { "arid:\($0)" }.joined(separator: " OR ") + ")"
                groups = try await search("release-group", query: "\(titleQuery) AND \(ids)")
                matches = matching(groups, query: query, artistIDs: artistIDs)
            }
        }
        if diagnostics {
            print("[t197u] \(query.artist) / \(query.title): \(groups.count) groups, \(matches.count) verified identities")
        }
        // Multiple editions can refer to the same album. Try matching groups in rank order, not arbitrary titles.
        for candidate in matches.prefix(3) {
            if let result = try await cover(candidate, query: query) { return result }
            let releases = try await browseReleases(candidate.id)
            for release in releases.prefix(8) {
                if let result = try await cover(release, query: query) { return result }
            }
        }
        // Some releases have artwork but no suitable release-group representative, or only a release title matches.
        let releaseTitle = OfficialCoverText.field("release", values: titles)
        let identity: String
        if artistIDs.isEmpty {
            identity = artistQuery
        } else {
            identity = "(" + artistIDs.sorted().map { "arid:\($0)" }.joined(separator: " OR ") + ")"
        }
        let releases = try await search("release", query: "\(releaseTitle) AND \(identity) AND status:official")
        for release in matching(releases, query: query, artistIDs: artistIDs).prefix(5) {
            if let result = try await cover(release, query: query) { return result }
        }
        return nil
    }

    private func matching(_ candidates: [Candidate], query: OfficialCoverQuery,
                          artistIDs: Set<String>) -> [Candidate] {
        candidates.filter {
            $0.score >= 85 &&
            OfficialCoverText.canonical($0.title) == OfficialCoverText.canonical(query.title) &&
            (!$0.artistIDs.isDisjoint(with: artistIDs) ||
             $0.names.contains { OfficialCoverText.canonical($0) == OfficialCoverText.canonical(query.artist) })
        }.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.hasFront != $1.hasFront { return $0.hasFront }
            return $0.id < $1.id
        }
    }

    private func search(_ entity: String, query: String) async throws -> [Candidate] {
        let json = try await mb(entity, items: [.init(name: "query", value: query), .init(name: "limit", value: "25")])
        let key = entity == "release-group" ? "release-groups" : "releases"
        return ((json[key] as? [[String: Any]]) ?? []).compactMap { candidate($0, source: entity) }
    }

    private func findArtists(_ names: [String]) async throws -> Set<String> {
        let query = OfficialCoverText.field("artist", values: names) + " OR " + OfficialCoverText.field("alias", values: names)
        let json = try await mb("artist", items: [.init(name: "query", value: query), .init(name: "limit", value: "10")])
        let expected = Set(names.map(OfficialCoverText.canonical))
        return Set(((json["artists"] as? [[String: Any]]) ?? []).compactMap { artist in
            var aliases = (artist["aliases"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
            aliases += [artist["name"], artist["sort-name"]].compactMap { $0 as? String }
            guard Self.score(artist["score"]) >= 85,
                  aliases.contains(where: { expected.contains(OfficialCoverText.canonical($0)) }) else { return nil }
            return artist["id"] as? String
        })
    }

    private func browseReleases(_ group: String) async throws -> [Candidate] {
        let json = try await mb("release", items: [
            .init(name: "release-group", value: group), .init(name: "limit", value: "100"),
            .init(name: "inc", value: "artist-credits")
        ])
        return ((json["releases"] as? [[String: Any]]) ?? [])
            .filter { ($0["status"] as? String) == "Official" }
            .compactMap { candidate($0, source: "release", defaultScore: 100) }
            .sorted { a, b in a.hasFront != b.hasFront ? a.hasFront : a.id < b.id }
    }

    private func candidate(_ json: [String: Any], source: String, defaultScore: Int = 0) -> Candidate? {
        guard let id = json["id"] as? String, UUID(uuidString: id) != nil,
              let title = json["title"] as? String else { return nil }
        let credits = json["artist-credit"] as? [[String: Any]] ?? []
        var names: [String] = []
        var ids = Set<String>()
        for credit in credits {
            let artist = credit["artist"] as? [String: Any] ?? [:]
            names += [credit["name"], artist["name"], artist["sort-name"]].compactMap { $0 as? String }
            names += (artist["aliases"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
            if let id = artist["id"] as? String { ids.insert(id) }
        }
        names.append(credits.map { ($0["name"] as? String ?? "") + ($0["joinphrase"] as? String ?? "") }.joined())
        let artwork = json["cover-art-archive"] as? [String: Any]
        return Candidate(id: id, title: title, names: names, artistIDs: ids,
            score: json["score"] == nil ? defaultScore : Self.score(json["score"]),
            source: source, hasFront: artwork?["front"] as? Bool == true)
    }

    private static func score(_ value: Any?) -> Int {
        if let number = value as? Int { return number }
        if let string = value as? String { return Int(string) ?? 0 }
        return 0
    }

    private func mb(_ entity: String, items: [URLQueryItem]) async throws -> [String: Any] {
        var components = URLComponents(string: "https://musicbrainz.org/ws/2/\(entity)")!
        components.queryItems = items + [.init(name: "fmt", value: "json")]
        let url = components.url!
        let (data, response) = try await client.request(url)
        guard response.statusCode == 200 else { throw OfficialCoverError.http(response.statusCode, url) }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }
        return json
    }

    private func cover(_ candidate: Candidate, query: OfficialCoverQuery) async throws -> OfficialCoverResult? {
        let manifest = URL(string: "https://coverartarchive.org/\(candidate.source)/\(candidate.id)")!
        let (data, response) = try await client.request(manifest)
        if response.statusCode == 404 { return nil }
        guard response.statusCode == 200 else { throw OfficialCoverError.http(response.statusCode, manifest) }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let images = json["images"] as? [[String: Any]] else { throw URLError(.cannotParseResponse) }
        // A back cover or unapproved upload must never replace the Apple album cover.
        let fronts = images.filter { $0["front"] as? Bool == true && $0["approved"] as? Bool == true }
        for front in fronts {
            let thumbnails = front["thumbnails"] as? [String: Any] ?? [:]
            var urls: [URL] = []
            for value in [thumbnails["500"], thumbnails["large"], thumbnails["250"], front["image"]] {
                guard let string = value as? String, var components = URLComponents(string: string),
                      ["http", "https"].contains(components.scheme ?? ""), components.host != nil else { continue }
                components.scheme = "https"
                if let url = components.url, !urls.contains(url) { urls.append(url) }
            }
            for url in urls {
                let (bytes, imageResponse) = try await client.request(url, accept: "image/*")
                if imageResponse.statusCode == 404 { continue }
                guard imageResponse.statusCode == 200 else { throw OfficialCoverError.http(imageResponse.statusCode, url) }
                guard let source = CGImageSourceCreateWithData(bytes as CFData, nil),
                      CGImageSourceGetCount(source) > 0,
                      CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else {
                    throw OfficialCoverError.invalidImage(url)
                }
                return OfficialCoverResult(match: .init(url: url, mbid: candidate.id, title: candidate.title,
                    artist: query.artist, score: candidate.score, source: candidate.source), imageData: bytes)
            }
        }
        return nil
    }
}
