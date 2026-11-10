import Foundation
import CryptoKit

public struct LyricLine: Codable, Equatable, Identifiable, Sendable {
    public let id: Int
    public let time: Double
    public let text: String
    var marks: [Mark]? = nil
    struct Mark: Codable, Equatable, Sendable { let char: Int; let time: Double }
}

public enum LyricsResult: Codable, Equatable, Sendable {
    case synced([LyricLine])
    case plain(String)
    case none
}

public struct LyricsQuery: Sendable {
    let title: String
    let artist: String
    let album: String?
    let duration: Double?

    public init(title: String, artist: String, album: String?, duration: Double?) {
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
    }

    static func clean(_ value: String) -> String {
        var text = value
        for _ in 0..<3 {
            text = text.replacingOccurrences(of: #"\s*[\(\[（【][^\)\]）】]*[\)\]）】]"#,
                                             with: "", options: .regularExpression)
        }
        text = text.replacingOccurrences(
            of: #"(?i)\s+[-–—]\s*(?:single|live|remaster(?:ed)?|deluxe|radio edit|version|acoustic|remix|ep)\b.*$"#,
            with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?i)\s+(?:feat\.?|ft\.?|featuring)\s+.*$"#,
                                         with: "", options: .regularExpression)
        return text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func primaryArtist(_ value: String) -> String {
        let separated = value.replacingOccurrences(
            of: #"(?i)\s*(?:&|,|，|、|;|；|\s+feat\.?\s+|\s+ft\.?\s+|\s+featuring\s+)\s*"#,
            with: "\u{1F}", options: .regularExpression)
        return clean(separated.components(separatedBy: "\u{1F}").first ?? value)
    }

    static func simplified(_ value: String) -> String {
        value.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? value
    }
    static func traditional(_ value: String) -> String {
        value.applyingTransform(StringTransform("Simplified-Traditional"), reverse: false) ?? value
    }
    static func canonical(_ value: String) -> String {
        String(simplified(clean(value)).folding(options: [.caseInsensitive, .diacriticInsensitive],
                                               locale: Locale(identifier: "en_US_POSIX"))
            .filter { $0.isLetter || $0.isNumber })
    }

    /// Normalized edit similarity, with a conservative threshold at the selection boundary.
    static func artistSimilarity(_ a: String, _ b: String) -> Double {
        let lhs = Array(canonical(primaryArtist(a))), rhs = Array(canonical(primaryArtist(b)))
        guard !lhs.isEmpty, !rhs.isEmpty else { return 0 }
        if lhs == rhs { return 1 }
        var previous = Array(0...rhs.count)
        for (i, character) in lhs.enumerated() {
            var current = [i + 1]
            for (j, other) in rhs.enumerated() {
                current.append(min(current[j] + 1, previous[j + 1] + 1,
                                   previous[j] + (character == other ? 0 : 1)))
            }
            previous = current
        }
        return 1 - Double(previous[rhs.count]) / Double(max(lhs.count, rhs.count))
    }

    var isChinese: Bool {
        (title + artist).unicodeScalars.contains { (0x3400...0x9FFF).contains($0.value) }
    }
    struct Variant: Equatable, Sendable { let title: String; let artist: String }
    var variants: [Variant] {
        let t = Self.clean(title), a = Self.primaryArtist(artist)
        return [Variant(title: t, artist: a),
                Variant(title: Self.simplified(t), artist: Self.simplified(a)),
                Variant(title: Self.traditional(t), artist: Self.traditional(a))]
            .reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }
    var cacheKey: String {
        // Preserve recording labels even when search strips them. Catalog/library albums may differ.
        [Self.simplified(title).lowercased().trimmingCharacters(in: .whitespacesAndNewlines),
         Self.canonical(Self.primaryArtist(artist)),
         duration.map { String(Int($0.rounded())) } ?? "unknown"].joined(separator: "\u{1F}")
    }
}

enum LyricsParser {
    /// Existing LRC parsing and character timestamps, moved without changing timing behavior.
    static func parseLRC(_ text: String) -> [LyricLine] {
        let stamp = try! NSRegularExpression(pattern: #"\[(\d{1,3}):(\d{1,2}(?:[\.:]\d{1,3})?)\]"#)
        let word = try! NSRegularExpression(pattern: #"<(\d{1,3}):(\d{1,2}(?:[\.:]\d{1,3})?)>"#)
        var out: [(Double, String, [LyricLine.Mark]?)] = []
        for raw in text.components(separatedBy: .newlines) {
            let ns = raw as NSString
            let matches = stamp.matches(in: raw, range: NSRange(location: 0, length: ns.length))
            guard let last = matches.last else { continue }
            let rawBody = ns.substring(from: last.range.location + last.range.length)
            var body = "", marks: [LyricLine.Mark] = []
            let wns = rawBody as NSString
            var cursor = 0
            for w in word.matches(in: rawBody, range: NSRange(location: 0, length: wns.length)) {
                body += wns.substring(with: NSRange(location: cursor, length: w.range.location - cursor))
                let mm = Double(wns.substring(with: w.range(at: 1))) ?? 0
                let ss = Double(wns.substring(with: w.range(at: 2)).replacingOccurrences(of: ":", with: ".")) ?? 0
                marks.append(.init(char: body.count, time: mm * 60 + ss))
                cursor = w.range.location + w.range.length
            }
            body += wns.substring(from: cursor)
            let lead = body.prefix(while: { $0 == " " }).count
            body = body.trimmingCharacters(in: .whitespaces)
            marks = marks.map { .init(char: max(0, min(body.count, $0.char - lead)), time: $0.time) }
            guard !body.isEmpty else { continue }
            for m in matches {
                let mm = Double(ns.substring(with: m.range(at: 1))) ?? 0
                let ss = Double(ns.substring(with: m.range(at: 2)).replacingOccurrences(of: ":", with: ".")) ?? 0
                out.append((mm * 60 + ss, body, marks.isEmpty ? nil : marks))
            }
        }
        return out.sorted { $0.0 < $1.0 }.enumerated().map {
            LyricLine(id: $0.offset, time: $0.element.0, text: $0.element.1, marks: $0.element.2)
        }
    }
}

struct LyricsRecord: Decodable, Sendable {
    let id: Int?
    let trackName: String?
    let artistName: String?
    let albumName: String?
    let duration: Double?
    let instrumental: Bool?
    let plainLyrics: String?
    let syncedLyrics: String?

    func matches(_ query: LyricsQuery) -> Bool {
        guard let trackName, let artistName,
              !LyricsQuery.canonical(query.title).isEmpty,
              LyricsQuery.canonical(trackName) == LyricsQuery.canonical(query.title),
              LyricsQuery.artistSimilarity(artistName, query.artist) >= 0.85 else { return false }
        if let expected = query.duration {
            guard let duration, duration.isFinite, duration > 0, abs(duration - expected) <= 3 else { return false }
        }
        return true
    }

    var result: LyricsResult? {
        if let syncedLyrics {
            let lines = LyricsParser.parseLRC(syncedLyrics)
            if !lines.isEmpty { return .synced(lines) }
        }
        if let text = plainLyrics?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            return .plain(text)
        }
        if instrumental == true { return LyricsResult.none }
        return nil
    }
}

public struct LyricsFetch: Codable, Equatable, Sendable {
    public let result: LyricsResult
    public let source: String
    public let recordID: String?
    public let matchedDuration: Double?
    public var isFound: Bool { result != .none }
}

/// Serialize prefetch requests and retry transient transport / HTTP failures three times.
public actor LyricsHTTPClient {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    typealias Sleeper = @Sendable (Double) async throws -> Void
    static let shared = LyricsHTTPClient()
    enum Failure: Error { case invalidResponse, status(Int) }
    private let transport: Transport
    private let sleep: Sleeper
    private let spacing: Double
    private var tail: Task<Void, Never>?
    private var nextAllowed = Date.distantPast

    init(spacing: Double = 0.25, transport: @escaping Transport = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.invalidResponse }
        return (data, http)
    }, sleep: @escaping Sleeper = { try await Task.sleep(for: .seconds($0)) }) {
        self.spacing = spacing
        self.transport = transport
        self.sleep = sleep
    }

    func request(_ request: URLRequest) async throws -> (Data, Int) {
        try Task.checkCancellation()
        let previous = tail
        let task = Task {
            if let previous { await previous.value }
            return try await perform(request)
        }
        tail = Task { _ = try? await task.value }
        return try await task.value
    }

    private func perform(_ request: URLRequest) async throws -> (Data, Int) {
        for attempt in 0...3 {
            try Task.checkCancellation()
            let wait = nextAllowed.timeIntervalSinceNow
            if spacing > 0, wait > 0 { try await sleep(wait) }
            var retryAfter: Double = 0
            do {
                let (data, response) = try await transport(request)
                nextAllowed = Date().addingTimeInterval(spacing)
                let status = response.statusCode
                if status == 429 || (500...599).contains(status) {
                    if let header = response.value(forHTTPHeaderField: "Retry-After") {
                        let parser = DateFormatter()
                        parser.locale = Locale(identifier: "en_US_POSIX")
                        parser.timeZone = TimeZone(secondsFromGMT: 0)
                        parser.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
                        retryAfter = max(0, Double(header) ?? parser.date(from: header)?.timeIntervalSinceNow ?? 0)
                    }
                    throw Failure.status(status)
                }
                guard status == 200 || status == 404 else { throw Failure.status(status) }
                return (data, status)
            } catch {
                if error is CancellationError || (error as? URLError)?.code == .cancelled { throw error }
                let retryable: Bool
                if let urlError = error as? URLError {
                    retryable = [.networkConnectionLost, .timedOut, .notConnectedToInternet,
                                 .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed].contains(urlError.code)
                } else if case Failure.status(let status) = error {
                    retryable = status == 429 || (500...599).contains(status)
                } else { retryable = false }
                guard retryable, attempt < 3 else { throw error }
                let delay = max(0.5 * pow(2, Double(attempt)), retryAfter)
                print("[lyrics] retry \(attempt + 1)/3 after \(delay)s: \(error.localizedDescription)")
                try await sleep(delay)
            }
        }
        throw Failure.invalidResponse
    }
}

struct LyricsCacheEntry: Codable, Sendable {
    let version: Int
    let savedAt: Date
    let value: LyricsFetch
    func valid(at now: Date) -> Bool {
        version == 3 && (value.isFound || now.timeIntervalSince(savedAt) < LyricsRepository.notFoundTTL)
    }
}

public actor LyricsRepository {
    public static let shared = LyricsRepository()
    static let notFoundTTL: TimeInterval = 3 * 24 * 3600
    private let directory: URL
    private let client: LyricsHTTPClient
    private let now: @Sendable () -> Date
    private var memory: [String: LyricsCacheEntry] = [:]
    private var inflight: [String: Task<LyricsCacheEntry, Error>] = [:]

    public init(directory: URL) {
        self.directory = directory
        self.client = .shared
        self.now = { Date() }
    }
    init(directory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
         .appendingPathComponent("lyrics-v3", isDirectory: true),
         client: LyricsHTTPClient = .shared, now: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory
        self.client = client
        self.now = now
    }

    public func load(_ query: LyricsQuery) async throws -> LyricsFetch {
        try await loadEntry(query).value
    }

    func loadEntry(_ query: LyricsQuery) async throws -> LyricsCacheEntry {
        let key = query.cacheKey
        if let entry = memory[key], entry.valid(at: now()) { return entry }
        memory[key] = nil
        if let task = inflight[key] { return try await task.value }
        let file = directory.appendingPathComponent(
            SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined() + ".json")
        let client = client, now = now
        let task = Task.detached(priority: .utility) {
            if let data = try? Data(contentsOf: file),
               let entry = try? JSONDecoder().decode(LyricsCacheEntry.self, from: data), entry.valid(at: now()) {
                return entry
            }
            let value = try await Self.fetch(query, client: client)
            let entry = LyricsCacheEntry(version: 3, savedAt: now(), value: value)
            do {
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(entry).write(to: file, options: .atomic)
            } catch { print("[lyrics] cache write failed: \(error.localizedDescription)") }
            return entry
        }
        inflight[key] = task
        defer { inflight[key] = nil }
        let entry = try await task.value
        memory[key] = entry
        return entry
    }

    private static func request(_ host: String, _ path: String, _ items: [URLQueryItem],
                                client: LyricsHTTPClient) async throws -> (Data, Int) {
        var components = URLComponents(string: host + path)!
        components.queryItems = items
        var request = URLRequest(url: components.url!, timeoutInterval: 12)
        request.setValue("Vinyl/1.0 (iOS)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if host.contains("music.163.com") {
            request.setValue(host + "/", forHTTPHeaderField: "Referer")
            request.httpShouldHandleCookies = false
        }
        return try await client.request(request)
    }

    private static func lrclib(_ path: String, _ items: [URLQueryItem],
                               client: LyricsHTTPClient) async throws -> Data? {
        let (data, status) = try await request("https://lrclib.net", "/api/" + path, items, client: client)
        return status == 404 ? nil : data
    }

    static func selected(_ records: [LyricsRecord], _ query: LyricsQuery) -> LyricsRecord? {
        func score(_ record: LyricsRecord) -> Double {
            var score = LyricsQuery.artistSimilarity(record.artistName ?? "", query.artist) * 1000
            if case .synced = record.result { score += 20 }
            if record.result == LyricsResult.none { score -= 100 }
            if let album = query.album, LyricsQuery.canonical(record.albumName ?? "") == LyricsQuery.canonical(album) {
                score += 5
            }
            if let expected = query.duration, let actual = record.duration { score -= abs(actual - expected) }
            return score
        }
        return records.filter { $0.matches(query) && $0.result != nil }.sorted { score($0) > score($1) }.first
    }

    private static func hit(_ record: LyricsRecord, source: String) -> LyricsFetch? {
        guard let result = record.result else { return nil }
        return LyricsFetch(result: result, source: source, recordID: record.id.map(String.init),
                           matchedDuration: record.duration)
    }

    private static func fetch(_ query: LyricsQuery, client: LyricsHTTPClient) async throws -> LyricsFetch {
        var failure: Error?
        do {
            for variant in query.variants {
                var items = [URLQueryItem(name: "track_name", value: variant.title),
                             URLQueryItem(name: "artist_name", value: variant.artist)]
                if let album = query.album, !album.isEmpty { items.append(.init(name: "album_name", value: album)) }
                if let duration = query.duration, (1...3600).contains(duration) {
                    items.append(.init(name: "duration", value: String(Int(duration.rounded()))))
                }
                if let data = try await lrclib("get", items, client: client) {
                    let record = try JSONDecoder().decode(LyricsRecord.self, from: data)
                    if record.matches(query), let value = hit(record, source: "LRCLIB/get") { return value }
                }
            }
            var searches = query.variants.map {
                [URLQueryItem(name: "track_name", value: $0.title), .init(name: "artist_name", value: $0.artist)]
            }
            searches += query.variants.map(\.title).reduce(into: [String]()) {
                if !$0.contains($1) { $0.append($1) }
            }.map { [URLQueryItem(name: "track_name", value: $0)] }
            for items in searches {
                if let data = try await lrclib("search", items, client: client) {
                    let records = try JSONDecoder().decode([LyricsRecord].self, from: data)
                    if let record = selected(records, query), let value = hit(record, source: "LRCLIB/search") {
                        return value
                    }
                }
            }
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled { throw error }
            failure = error
            print("[lyrics] LRCLIB failed: \(query.title) — \(error.localizedDescription)")
        }
        if query.isChinese {
            do {
                if let value = try await fetchChineseBackup(query, client: client) { return value }
            } catch {
                if error is CancellationError || (error as? URLError)?.code == .cancelled { throw error }
                failure = error
            }
        }
        // Only all-successful empty lookups can become a three-day negative cache.
        if let failure { throw failure }
        return LyricsFetch(result: .none, source: "none", recordID: nil, matchedDuration: nil)
    }

    private struct NetEaseSearch: Decodable {
        let code: Int
        let result: Result?
        struct Result: Decodable { let songs: [Song]? }
        struct Song: Decodable {
            let id: Int
            let name: String
            let duration: Double
            let artists: [Artist]
            let album: Album?
            struct Artist: Decodable { let name: String }
            struct Album: Decodable { let name: String }
            var record: LyricsRecord {
                LyricsRecord(id: id, trackName: name, artistName: artists.map(\.name).joined(separator: " & "),
                             albumName: album?.name, duration: duration / 1000,
                             instrumental: nil, plainLyrics: nil, syncedLyrics: nil)
            }
        }
    }
    private struct NetEaseLyrics: Decodable {
        let code: Int
        let lrc: Text?
        let klyric: Text?
        let nolyric: Bool?
        let uncollected: Bool?
        struct Text: Decodable { let lyric: String? }
    }

    public static func fetchChineseBackup(_ query: LyricsQuery) async throws -> LyricsFetch? {
        try await fetchChineseBackup(query, client: .shared)
    }
    static func fetchChineseBackup(_ query: LyricsQuery, client: LyricsHTTPClient) async throws -> LyricsFetch? {
        let host = "https://music.163.com"
        var checked = Set<Int>()
        var failure: Error?
        for variant in query.variants {
            let (data, status) = try await request(host, "/api/search/get",
                [.init(name: "s", value: "\(variant.title) \(variant.artist)"), .init(name: "type", value: "1"),
                 .init(name: "limit", value: "30"), .init(name: "offset", value: "0")], client: client)
            guard status == 200 else { throw LyricsHTTPClient.Failure.status(status) }
            let search = try JSONDecoder().decode(NetEaseSearch.self, from: data)
            guard search.code == 200 else { throw LyricsHTTPClient.Failure.invalidResponse }
            let songs = (search.result?.songs ?? []).filter { $0.record.matches(query) }.sorted {
                let a = LyricsQuery.artistSimilarity($0.record.artistName ?? "", query.artist)
                let b = LyricsQuery.artistSimilarity($1.record.artistName ?? "", query.artist)
                if a != b { return a > b }
                return abs($0.duration / 1000 - (query.duration ?? $0.duration / 1000)) <
                       abs($1.duration / 1000 - (query.duration ?? $1.duration / 1000))
            }
            for song in songs.prefix(3) where checked.insert(song.id).inserted {
                do {
                    let (data, status) = try await request(host, "/api/song/lyric",
                        [.init(name: "id", value: String(song.id)), .init(name: "lv", value: "-1"),
                         .init(name: "kv", value: "-1"), .init(name: "tv", value: "-1")], client: client)
                    guard status == 200 else { throw LyricsHTTPClient.Failure.status(status) }
                    let response = try JSONDecoder().decode(NetEaseLyrics.self, from: data)
                    guard response.code == 200 else { throw LyricsHTTPClient.Failure.invalidResponse }
                    if response.nolyric == true || response.uncollected == true { continue }
                    let enhanced = response.klyric?.lyric.flatMap { $0.contains("<") ? $0 : nil }
                    let text = enhanced ?? response.lrc?.lyric
                    let plain = text.flatMap { raw -> String? in
                        guard LyricsParser.parseLRC(raw).isEmpty else { return nil }
                        let body = raw.replacingOccurrences(
                            of: #"(?im)^\s*\[(?:ar|ti|al|by|offset|re|ve):[^\]]*\]\s*$"#,
                            with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !body.isEmpty, !body.contains("[") else { return nil }
                        return body
                    }
                    let record = LyricsRecord(id: song.id, trackName: song.name,
                        artistName: song.record.artistName, albumName: song.album?.name,
                        duration: song.duration / 1000, instrumental: nil,
                        plainLyrics: plain,
                        syncedLyrics: text)
                    if let value = hit(record, source: "NetEase") { return value }
                } catch {
                    if error is CancellationError || (error as? URLError)?.code == .cancelled { throw error }
                    failure = error
                }
            }
        }
        if let failure { throw failure }
        return nil
    }
}
