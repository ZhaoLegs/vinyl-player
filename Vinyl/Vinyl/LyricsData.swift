import Foundation
import CryptoKit

/// t287u: lyrics latency trace. `--log-lyrics` prints ms since the last mark (lyrics toggle / album open).
enum LyricsTrace {
    static let on = ProcessInfo.processInfo.arguments.contains("--log-lyrics")
    nonisolated(unsafe) static var t0 = CFAbsoluteTimeGetCurrent()
    static func mark(_ s: @autoclosure () -> String) {
        guard on else { return }
        t0 = CFAbsoluteTimeGetCurrent(); print("[t287] T+    0ms MARK " + s())
    }
    static func log(_ s: @autoclosure () -> String) {
        guard on else { return }
        print(String(format: "[t287] T+%5.0fms ", (CFAbsoluteTimeGetCurrent() - t0) * 1000) + s())
    }
    static func kind(_ r: LyricsResult) -> String {
        switch r { case .synced(let l): return "synced \(l.count) lines"; case .plain: return "plain"; case .none: return "none" }
    }
    static func ms(since t: CFAbsoluteTime) -> Int { Int((CFAbsoluteTimeGetCurrent() - t) * 1000) }
    /// `--debug-lyrics-cold`: wipe the on-disk lyrics cache at launch so a run measures cold fetches
    static func wipeIfCold() {
        guard ProcessInfo.processInfo.arguments.contains("--debug-lyrics-cold") else { return }
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("lyrics-v3", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        print("[t287] cold: lyrics disk cache wiped")
    }
}

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
    var cacheKey: String { cacheKeys[0] }
    /// t287u: the exact key first, then ±1s neighbours — library and catalog copies of a track differ by
    /// fractions of a second, and matching already allows ±3s, so a neighbour's entry is the same lyrics.
    var cacheKeys: [String] {
        // Preserve recording labels even when search strips them. Catalog/library albums may differ.
        let head = [Self.simplified(title).lowercased().trimmingCharacters(in: .whitespacesAndNewlines),
                    Self.canonical(Self.primaryArtist(artist))]
        guard let duration else { return [(head + ["unknown"]).joined(separator: "\u{1F}")] }
        let d = Int(duration.rounded())
        return [d, d - 1, d + 1].map { (head + [String($0)]).joined(separator: "\u{1F}") }
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

/// t287u: foreground requests (the lyrics panel is waiting) never queue: short first timeout, a hedged second copy
/// if the first hasn't answered after `hedgeAfter`, one quick retry. Background prefetch shares `backgroundSlots`
/// so a whole album's prefetch can't starve the network, with a longer timeout and two retries.
public actor LyricsHTTPClient {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    typealias Sleeper = @Sendable (Double) async throws -> Void
    static let shared = LyricsHTTPClient()
    enum Failure: Error { case invalidResponse, status(Int) }
    static let backgroundSlots = 2
    static let foregroundTimeout: Double = 3
    static let longTimeout: Double = 8
    static let hedgeAfter: Double = 1.5
    static let foregroundRetries = 1, backgroundRetries = 2
    private let transport: Transport
    private let sleep: Sleeper
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(spacing: Double = 0, transport: @escaping Transport = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.invalidResponse }
        return (data, http)
    }, sleep: @escaping Sleeper = { try await Task.sleep(for: .seconds($0)) }) {
        self.transport = transport
        self.sleep = sleep
    }

    private func acquire() async {
        if active < Self.backgroundSlots { active += 1; return }
        await withCheckedContinuation { waiters.append($0) }   // slot handed over by release()
    }
    private func release() {
        if waiters.isEmpty { active -= 1 } else { waiters.removeFirst().resume() }
    }

    func request(_ request: URLRequest, foreground: Bool = false) async throws -> (Data, Int) {
        try Task.checkCancellation()
        let queued = CFAbsoluteTimeGetCurrent()
        let label = (foreground ? "FG " : "bg ") + (request.url?.host ?? "") + (request.url?.path ?? "")
        if !foreground { await acquire() }
        defer { if !foreground { release() } }
        LyricsTrace.log("http start \(label) (queued \(LyricsTrace.ms(since: queued))ms)")
        let t = CFAbsoluteTimeGetCurrent()
        do {
            let r = try await perform(request, foreground: foreground, label: label)
            LyricsTrace.log("http done  \(label) \(r.1) in \(LyricsTrace.ms(since: t))ms")
            return r
        } catch {
            LyricsTrace.log("http FAIL  \(label) in \(LyricsTrace.ms(since: t))ms: \(error.localizedDescription)")
            throw error
        }
    }

    private func perform(_ request: URLRequest, foreground: Bool, label: String) async throws -> (Data, Int) {
        let retries = foreground ? Self.foregroundRetries : Self.backgroundRetries
        for attempt in 0...retries {
            try Task.checkCancellation()
            var retryAfter: Double = 0
            do {
                let (data, response) = try await foreground
                    ? hedged(request, label: label)
                    : once(request, timeout: Self.longTimeout)
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
                guard retryable, attempt < retries else { throw error }
                let delay = foreground ? max(0.3, min(retryAfter, 2)) : max(0.5 * pow(2, Double(attempt)), retryAfter)
                print("[lyrics] retry \(attempt + 1)/\(retries) after \(delay)s: \(error.localizedDescription)")
                try await sleep(delay)
            }
        }
        throw Failure.invalidResponse
    }

    private func once(_ request: URLRequest, timeout: Double) async throws -> (Data, HTTPURLResponse) {
        var r = request; r.timeoutInterval = timeout
        return try await transport(r)
    }

    private enum HedgeEvent: Sendable {
        case primary(Result<(Data, HTTPURLResponse), Error>)
        case hedge(Result<(Data, HTTPURLResponse), Error>)
        case timer(fired: Bool)
    }
    /// Primary copy with a 3s timeout. If it is still silent after `hedgeAfter`, a second copy with a long timeout
    /// races it; the first success wins. A primary that fails before the hedge fires fails fast (→ retry).
    private func hedged(_ request: URLRequest, label: String) async throws -> (Data, HTTPURLResponse) {
        let transport = transport
        var primary = request; primary.timeoutInterval = Self.foregroundTimeout
        var backup = request; backup.timeoutInterval = Self.longTimeout
        let a = primary, b = backup
        return try await withThrowingTaskGroup(of: HedgeEvent.self) { group in
            group.addTask {
                do { return .primary(.success(try await transport(a))) } catch { return .primary(.failure(error)) }
            }
            group.addTask {
                do { try await Task.sleep(for: .seconds(Self.hedgeAfter)); return .timer(fired: true) }
                catch { return .timer(fired: false) }
            }
            var hedging = false, primaryFailure: Error?, hedgeFailure: Error?
            while let event = try await group.next() {
                switch event {
                case .primary(.success(let v)), .hedge(.success(let v)):
                    group.cancelAll(); return v
                case .primary(.failure(let e)):
                    primaryFailure = e
                    if !hedging || hedgeFailure != nil { group.cancelAll(); throw e }
                case .hedge(.failure(let e)):
                    hedgeFailure = e
                    if let primaryFailure { group.cancelAll(); throw primaryFailure }
                case .timer(let fired):
                    guard fired, primaryFailure == nil else { break }
                    hedging = true
                    LyricsTrace.log("http hedge \(label)")
                    group.addTask {
                        do { return .hedge(.success(try await transport(b))) } catch { return .hedge(.failure(error)) }
                    }
                }
            }
            throw primaryFailure ?? hedgeFailure ?? Failure.invalidResponse
        }
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
    private var inflight: [String: (task: Task<LyricsCacheEntry, Error>, foreground: Bool)] = [:]

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

    public func load(_ query: LyricsQuery, foreground: Bool = true) async throws -> LyricsFetch {
        try await loadEntry(query, foreground: foreground).value
    }

    private func file(_ key: String) -> URL {
        directory.appendingPathComponent(
            SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined() + ".json")
    }

    /// t287u: memory → in-flight (a foreground caller never waits on a background flight; it starts its own) →
    /// disk (exact key, then ±1s neighbours) → network.
    func loadEntry(_ query: LyricsQuery, foreground: Bool = true) async throws -> LyricsCacheEntry {
        let keys = query.cacheKeys, key = keys[0]
        for k in keys { if let entry = memory[k], entry.valid(at: now()) { LyricsTrace.log("repo memory hit \(query.title)"); return entry } }
        for k in keys {
            if let flight = inflight[k], flight.foreground || !foreground {
                LyricsTrace.log("repo join inflight \(query.title)")
                return try await flight.task.value
            }
        }
        let files = keys.map(file)
        let client = client, now = now
        let task = Task.detached(priority: foreground ? .userInitiated : .utility) {
            let t0 = CFAbsoluteTimeGetCurrent()
            for f in files {
                if let data = try? Data(contentsOf: f),
                   let entry = try? JSONDecoder().decode(LyricsCacheEntry.self, from: data), entry.valid(at: now()) {
                    LyricsTrace.log("repo disk hit \(query.title) in \(LyricsTrace.ms(since: t0))ms")
                    return entry
                }
            }
            LyricsTrace.log("repo fetch start \(foreground ? "FG" : "bg") \(query.title)")
            let t = CFAbsoluteTimeGetCurrent()
            let value = try await Self.fetch(query, client: client, foreground: foreground)
            LyricsTrace.log("repo fetch done \(query.title) via \(value.source) in \(LyricsTrace.ms(since: t))ms")
            let entry = LyricsCacheEntry(version: 3, savedAt: now(), value: value)
            do {
                try FileManager.default.createDirectory(at: files[0].deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(entry).write(to: files[0], options: .atomic)
            } catch { print("[lyrics] cache write failed: \(error.localizedDescription)") }
            return entry
        }
        inflight[key] = (task, foreground)
        defer { if inflight[key]?.task == task { inflight[key] = nil } }
        let entry = try await task.value
        memory[key] = entry
        return entry
    }

    private static func request(_ host: String, _ path: String, _ items: [URLQueryItem],
                                client: LyricsHTTPClient, foreground: Bool) async throws -> (Data, Int) {
        var components = URLComponents(string: host + path)!
        components.queryItems = items
        var request = URLRequest(url: components.url!, timeoutInterval: LyricsHTTPClient.longTimeout)
        request.setValue("Vinyl/1.0 (iOS)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if host.contains("music.163.com") {
            request.setValue(host + "/", forHTTPHeaderField: "Referer")
            request.httpShouldHandleCookies = false
        }
        return try await client.request(request, foreground: foreground)
    }

    private static func lrclib(_ path: String, _ items: [URLQueryItem],
                               client: LyricsHTTPClient, foreground: Bool) async throws -> Data? {
        let (data, status) = try await request("https://lrclib.net", "/api/" + path, items, client: client, foreground: foreground)
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

    private static func isCancel(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }
    private static func isSynced(_ f: LyricsFetch) -> Bool { if case .synced = f.result { return true }; return false }

    typealias Job = @Sendable () async throws -> LyricsFetch?
    /// Runs jobs concurrently; the earliest job (in list order) with a hit wins as soon as everything before it
    /// has answered. Returns the first failure alongside so callers can refuse to negative-cache a partial outage.
    static func firstHit(_ jobs: [Job]) async throws -> (LyricsFetch?, Error?) {
        guard !jobs.isEmpty else { return (nil, nil) }
        return try await withThrowingTaskGroup(of: (Int, Result<LyricsFetch?, Error>).self) { group in
            for (i, job) in jobs.enumerated() {
                group.addTask { do { return (i, .success(try await job())) } catch { return (i, .failure(error)) } }
            }
            var results: [Int: Result<LyricsFetch?, Error>] = [:], next = 0, failure: Error?
            while let next1 = try await group.next() {
                let (i, r) = next1
                if case .failure(let e) = r, isCancel(e) { group.cancelAll(); throw e }
                results[i] = r
                while let r = results[next] {
                    switch r {
                    case .success(let v?): group.cancelAll(); return (v, failure)
                    case .success(nil): break
                    case .failure(let e): failure = failure ?? e
                    }
                    next += 1
                }
                if next == jobs.count { break }
            }
            return (nil, failure)
        }
    }

    /// LRCLIB: all script variants' /get in parallel (earlier variant preferred), then all searches in parallel.
    static func fetchLRCLIB(_ query: LyricsQuery, client: LyricsHTTPClient, foreground: Bool) async throws -> LyricsFetch? {
        let gets: [Job] = query.variants.map { variant in
            var items = [URLQueryItem(name: "track_name", value: variant.title),
                         URLQueryItem(name: "artist_name", value: variant.artist)]
            if let album = query.album, !album.isEmpty { items.append(.init(name: "album_name", value: album)) }
            if let duration = query.duration, (1...3600).contains(duration) {
                items.append(.init(name: "duration", value: String(Int(duration.rounded()))))
            }
            let q = items
            return {
                guard let data = try await lrclib("get", q, client: client, foreground: foreground) else { return nil }
                let record = try JSONDecoder().decode(LyricsRecord.self, from: data)
                return record.matches(query) ? hit(record, source: "LRCLIB/get") : nil
            }
        }
        let (got, getFailure) = try await firstHit(gets)
        if let got { return got }
        // A failing /get (offline, 5xx, bad JSON) means LRCLIB is unusable right now: skip the searches, as before.
        if let getFailure { throw getFailure }
        var searches = query.variants.map {
            [URLQueryItem(name: "track_name", value: $0.title), .init(name: "artist_name", value: $0.artist)]
        }
        searches += query.variants.map(\.title).reduce(into: [String]()) {
            if !$0.contains($1) { $0.append($1) }
        }.map { [URLQueryItem(name: "track_name", value: $0)] }
        let jobs: [Job] = searches.map { items in {
            guard let data = try await lrclib("search", items, client: client, foreground: foreground) else { return nil }
            let records = try JSONDecoder().decode([LyricsRecord].self, from: data)
            return selected(records, query).flatMap { hit($0, source: "LRCLIB/search") }
        } }
        let (found, searchFailure) = try await firstHit(jobs)
        if let found { return found }
        if let searchFailure { throw searchFailure }
        return nil
    }

    /// t287u: LRCLIB and (for Chinese titles) NetEase race in parallel. A synced LRCLIB answer wins at once; a synced
    /// NetEase answer waits `preferenceGrace` for LRCLIB to keep the old preference order; otherwise synced beats plain.
    static let preferenceGrace: Double = 0.3
    private enum Leg: Sendable { case lrclib, netease }
    private static func fetch(_ query: LyricsQuery, client: LyricsHTTPClient, foreground: Bool) async throws -> LyricsFetch {
        try await withThrowingTaskGroup(of: (Leg, Result<LyricsFetch?, Error>)?.self) { group in
            group.addTask {
                do { return (.lrclib, .success(try await fetchLRCLIB(query, client: client, foreground: foreground))) }
                catch { return (.lrclib, .failure(error)) }
            }
            var pending = 1
            if query.isChinese {
                pending += 1
                group.addTask {
                    do { return (.netease, .success(try await fetchChineseBackup(query, client: client, foreground: foreground))) }
                    catch { return (.netease, .failure(error)) }
                }
            }
            var best: [Leg: LyricsFetch] = [:], failure: Error?, graceArmed = false
            while let item = try await group.next() {
                guard let answer = item else {          // grace window over
                    if let n = best[.netease], isSynced(n) { group.cancelAll(); LyricsTrace.log("race: NetEase (LRCLIB >300ms late)"); return n }
                    continue
                }
                let (leg, result) = answer
                pending -= 1
                switch result {
                case .success(let f?): best[leg] = f
                case .success(nil): break
                case .failure(let e):
                    if isCancel(e) { group.cancelAll(); throw e }
                    failure = e
                    print("[lyrics] \(leg == .lrclib ? "LRCLIB" : "NetEase") failed: \(query.title) — \(e.localizedDescription)")
                }
                if let l = best[.lrclib], isSynced(l) { group.cancelAll(); return l }
                if pending == 0 { group.cancelAll(); break }
                if let n = best[.netease], isSynced(n), !graceArmed {
                    graceArmed = true
                    group.addTask { try? await Task.sleep(for: .seconds(preferenceGrace)); return nil }
                }
            }
            if let n = best[.netease], isSynced(n) { return n }
            if let l = best[.lrclib] { return l }
            if let n = best[.netease] { return n }
            // Only all-successful empty lookups can become a three-day negative cache.
            if let failure { throw failure }
            return LyricsFetch(result: .none, source: "none", recordID: nil, matchedDuration: nil)
        }
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
        try await fetchChineseBackup(query, client: .shared, foreground: true)
    }
    static func fetchChineseBackup(_ query: LyricsQuery, client: LyricsHTTPClient,
                                   foreground: Bool = true) async throws -> LyricsFetch? {
        let host = "https://music.163.com"
        var checked = Set<Int>()
        var failure: Error?
        for variant in query.variants {
            let (data, status) = try await request(host, "/api/search/get",
                [.init(name: "s", value: "\(variant.title) \(variant.artist)"), .init(name: "type", value: "1"),
                 .init(name: "limit", value: "30"), .init(name: "offset", value: "0")], client: client, foreground: foreground)
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
                         .init(name: "kv", value: "-1"), .init(name: "tv", value: "-1")], client: client, foreground: foreground)
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
