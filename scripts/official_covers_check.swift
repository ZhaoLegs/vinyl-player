import Foundation

private enum CheckError: Error { case failed(String) }

private func expect(_ condition: Bool, _ message: String) throws {
    guard condition else { throw CheckError.failed(message) }
}

/// Offline fixtures exercise transport failures and identity checks; they are not live hit-rate data.
private actor FixtureServer {
    enum Mode { case success, releaseFallback, wrongArtist, missing, artistAlias, tokenSearch,
                discogsOnly, discogsLarger, discogsTie, discogsSpacer }
    var mode: Mode
    var failures: [URLError.Code]
    var httpFailures: [Int]
    var requests: [URLRequest] = []
    var starts: [Date] = []
    var active = 0
    var maximumActive = 0
    let group = "7b8fe220-756f-39e7-affd-527acae860a6"
    let release = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    let artistID = "11111111-2222-3333-4444-555555555555"

    init(_ mode: Mode = .success, failures: [URLError.Code] = [], httpFailures: [Int] = []) {
        self.mode = mode
        self.failures = failures
        self.httpFailures = httpFailures
    }

    func handle(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        starts.append(Date())
        active += 1
        maximumActive = max(maximumActive, active)
        defer { active -= 1 }
        try await Task.sleep(for: .milliseconds(15))
        if !failures.isEmpty { throw URLError(failures.removeFirst()) }
        let url = request.url!
        if !httpFailures.isEmpty {
            return (Data(), HTTPURLResponse(url: url, statusCode: httpFailures.removeFirst(),
                httpVersion: "HTTP/1.1", headerFields: ["Retry-After": "0"])!)
        }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let query = items.first { $0.name == "query" }?.value ?? ""
        let isSearch = items.contains { $0.name == "query" }
        var status = 200
        var json: [String: Any] = [:]
        if url.path.hasPrefix("/ws/2/artist") {
            json = ["artists": mode == .artistAlias ? [[
                "id": artistID, "name": "孫燕姿", "score": "100",
                "aliases": [["name": "Stefanie Sun"]]
            ]] : []]
        } else if url.path.hasPrefix("/ws/2/release-group") {
            let empty = mode == .missing || mode == .discogsOnly || (mode == .artistAlias && !query.contains("arid:")) ||
                (mode == .tokenSearch && query.contains("\""))
            json = ["release-groups": empty ? [] : [candidate()]]
        } else if url.path.hasPrefix("/ws/2/release") {
            json = ["releases": isSearch ? [] : [[
                "id": release, "title": "Stefanie", "status": "Official",
                "cover-art-archive": ["front": true],
                "artist-credit": credits()
            ]]]
        } else if url.host == "api.discogs.com" {
            if url.path.hasPrefix("/database/search") {
                json = ["results": discogsResults()]
            } else if url.path.hasPrefix("/releases/") {
                json = discogsRelease()
            } else {
                status = 404
            }
        } else if url.host == "coverartarchive.org", url.path.hasSuffix(".jpg") {
            return (Self.png1x1, HTTPURLResponse(url: url, statusCode: 200,
                httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "image/png"])!)
        } else if url.host == "i.discogs.com" {
            if url.path.contains("spacer.gif") {
                status = 200
                return (Data(), HTTPURLResponse(url: url, statusCode: 200,
                    httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "image/gif"])!)
            }
            let png = (mode == .discogsLarger && url.path.contains("large")) ? Self.png2x2 : Self.png1x1
            return (png, HTTPURLResponse(url: url, statusCode: 200,
                httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "image/png"])!)
        } else {
            if mode == .releaseFallback && url.path.contains("/release-group/") {
                status = 404
            } else {
                json = ["images": [
                    ["front": false, "approved": true, "image": "https://coverartarchive.org/back.jpg"],
                    ["front": true, "approved": true,
                     "thumbnails": ["500": "http://coverartarchive.org/release/\(release)/500.jpg"]]
                ]]
            }
        }
        return (try JSONSerialization.data(withJSONObject: json),
                HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"])!)
    }

    private func credits() -> [[String: Any]] {
        [["name": mode == .wrongArtist ? "Other Artist" : "孫燕姿",
          "artist": ["id": artistID, "name": mode == .wrongArtist ? "Other Artist" : "孙燕姿",
                     "aliases": mode == .wrongArtist ? [] : [["name": "Stefanie Sun"]]]]]
    }

    private func candidate() -> [String: Any] {
        ["id": group, "title": "Stefanie", "score": "100", "artist-credit": credits()]
    }

    func count() -> Int { requests.count }

    static let png1x1 = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+j7XsAAAAASUVORK5CYII=")!
    static let png2x2 = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAEUlEQVR4nGP4z8DwH4QZYAwAR8oH+WdZbrcAAAAASUVORK5CYII=")!

    private func discogsResults() -> [[String: Any]] {
        switch mode {
        case .discogsOnly, .discogsLarger, .discogsTie, .discogsSpacer:
            let image: String
            switch mode {
            case .discogsSpacer: image = "https://i.discogs.com/images/spacer.gif"
            case .discogsLarger: image = "https://i.discogs.com/large.png"
            default: image = "https://i.discogs.com/cover.jpg"
            }
            return [["id": 4242, "title": "孙燕姿 - Stefanie", "cover_image": image]]
        default:
            return []
        }
    }

    private func discogsRelease() -> [String: Any] {
        switch mode {
        case .discogsLarger:
            return ["images": [[
                "type": "primary", "uri": "https://i.discogs.com/large.png",
                "width": 2, "height": 2
            ]]]
        case .discogsOnly, .discogsTie:
            return ["images": [[
                "type": "primary", "uri": "https://i.discogs.com/cover.jpg",
                "width": 1, "height": 1
            ]]]
        default:
            return ["images": []]
        }
    }
}

@main
private struct OfficialCoversCheck {
    static func main() async {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        do {
            if CommandLine.arguments.contains("--self-check") {
                try await selfCheck(root)
            } else {
                try await liveCheck(root)
            }
        } catch {
            print("FAIL: \(error)")
            exit(1)
        }
    }

    private static func selfCheck(_ root: URL) async throws {
        let expected: [(String, String)] = [
            (" 十一月的萧邦 - Single ", "十一月的萧邦"),
            ("Stefanie - EP", "Stefanie"),
            ("Nine Track Mind (Deluxe)", "Nine Track Mind"),
            ("1989 [Remastered]", "1989"),
            ("1989 (Taylor’s Version)", "1989 (Taylor’s Version)")
        ]
        for (input, output) in expected {
            try expect(OfficialCoverText.cleanTitle(input) == output, "title cleanup: \(input)")
        }
        try expect(OfficialCoverText.canonical("十一月的蕭邦") ==
                   OfficialCoverText.canonical("十一月的萧邦"), "Chinese conversion")
        try expect(OfficialCoverText.canonical("十一月的萧邦") ==
                   OfficialCoverText.canonical("11月的蕭邦"), "Chinese / Arabic month number")
        try expect(OfficialCoverText.canonical("1989 [nightcore]") !=
                   OfficialCoverText.canonical("1989"), "must preserve distinct recordings")
        print("PASS: suffix cleanup, simplified/traditional Chinese, distinct versions")

        let server = FixtureServer()
        let client = OfficialCoverHTTPClient(transport: { try await server.handle($0) })
        let directory = root.appendingPathComponent("success")
        let lookup = OfficialCoverLookup(cacheDirectory: directory, client: client)
        let query = OfficialCoverQuery(id: "album", title: "Stefanie (Deluxe)", artist: "孙燕姿")
        async let first = lookup.resolve(query)
        async let second = lookup.resolve(query)
        let results = try await [first, second]
        try expect(results.allSatisfy { $0?.match.score == 100 }, "string score and concurrent dedup")
        try expect(results[0]?.match.url.scheme == "https", "CAA URLs must use HTTPS")
        let count = await server.count()
        let hosts = await server.requests.map { $0.url?.host ?? "" }
        let mbCaa = hosts.filter { $0 == "musicbrainz.org" || $0 == "coverartarchive.org" }.count
        let discogs = hosts.filter { $0 == "api.discogs.com" }.count
        try expect(mbCaa == 3, "one MB search, one CAA manifest, one image for concurrent callers")
        try expect(discogs >= 1 && !hosts.contains("i.discogs.com"),
                   "CAA hit still queries Discogs; empty Discogs results must not download images")
        _ = try await lookup.resolve(query)
        let restarted = OfficialCoverLookup(cacheDirectory: directory, client: client)
        _ = try await restarted.resolve(query)
        try expect(await server.count() == count, "warm and disk cache must avoid network")
        let requests = await server.requests
        try expect(requests.allSatisfy {
            ($0.value(forHTTPHeaderField: "User-Agent") ?? "").contains("github.com/ZhaoLegs/vinyl-player")
        }, "meaningful User-Agent on every request")
        print("PASS: front selection, string score, HTTPS, concurrent dedup, persistent hit cache, User-Agent")

        let queueServer = FixtureServer()
        let queueClient = OfficialCoverHTTPClient(transport: { try await queueServer.handle($0) })
        let queueURL = URL(string: "https://musicbrainz.org/ws/2/release-group?query=Stefanie")!
        async let requestA = queueClient.request(queueURL)
        async let requestB = queueClient.request(queueURL)
        async let requestC = queueClient.request(queueURL)
        _ = try await [requestA, requestB, requestC]
        try expect(await queueServer.maximumActive == 1, "requests must execute serially despite actor suspension")
        let queueStarts = await queueServer.starts
        for (a, b) in zip(queueStarts, queueStarts.dropFirst()) {
            try expect(b.timeIntervalSince(a) >= 1, "concurrent request spacing")
        }
        print("PASS: three concurrent requests execute serially and obey the rate limit")

        let fallbackServer = FixtureServer(.releaseFallback)
        let fallback = OfficialCoverLookup(cacheDirectory: root.appendingPathComponent("release"),
            client: OfficialCoverHTTPClient(transport: { try await fallbackServer.handle($0) }))
        let releaseResult = try await fallback.resolve(query)
        try expect(releaseResult?.match.source == "release", "release-group 404 must try official releases")
        print("PASS: release-group → official release fallback")

        let aliasServer = FixtureServer(.artistAlias)
        let aliasLookup = OfficialCoverLookup(cacheDirectory: root.appendingPathComponent("alias"),
            client: OfficialCoverHTTPClient(transport: { try await aliasServer.handle($0) }))
        let aliasResult = try await aliasLookup.resolve(
            .init(id: "alias", title: "Stefanie", artist: "Stefanie Sun"))
        try expect(aliasResult != nil, "artist alias → arid query")
        let mbStarts = zip(await aliasServer.requests, await aliasServer.starts)
            .filter { $0.0.url?.host == "musicbrainz.org" }.map { $0.1 }
        for (a, b) in zip(mbStarts, mbStarts.dropFirst()) {
            try expect(b.timeIntervalSince(a) >= 1, "MusicBrainz maximum one request per second")
        }
        print("PASS: artist aliases, actual MusicBrainz request intervals ≥ 1 second")

        let tokenServer = FixtureServer(.tokenSearch)
        let tokenLookup = OfficialCoverLookup(cacheDirectory: root.appendingPathComponent("tokens"),
            client: OfficialCoverHTTPClient(transport: { try await tokenServer.handle($0) }))
        let tokenResult = try await tokenLookup.resolve(query)
        try expect(tokenResult != nil, "phrase search miss must try a token search and verify identity locally")
        print("PASS: phrase search → token search fallback")

        for mode in [FixtureServer.Mode.wrongArtist, .missing] {
            let missServer = FixtureServer(mode)
            let miss = OfficialCoverLookup(cacheDirectory: root.appendingPathComponent("\(mode)"),
                client: OfficialCoverHTTPClient(transport: { try await missServer.handle($0) }))
            let result = try await miss.resolve(query)
            try expect(result == nil, "wrong artist / no metadata must fall back")
            let before = await missServer.count()
            _ = try await miss.resolve(query)
            try expect(await missServer.count() == before, "confirmed miss cache")
            let calls = await missServer.requests
            try expect(!calls.contains { $0.url?.host == "coverartarchive.org" }, "reject wrong artist before CAA")
        }
        print("PASS: wrong-artist rejection and confirmed miss cache")

        let retryServer = FixtureServer(failures: [.networkConnectionLost, .timedOut, .networkConnectionLost])
        let retry = OfficialCoverLookup(cacheDirectory: root.appendingPathComponent("retry"),
            client: OfficialCoverHTTPClient(transport: { try await retryServer.handle($0) }))
        let retryResult = try await retry.resolve(query)
        try expect(retryResult != nil, "transient network failures must recover")
        let retryStarts = await retryServer.starts
        for (index, delay) in [1.0, 2.0, 4.0].enumerated() {
            try expect(retryStarts[index + 1].timeIntervalSince(retryStarts[index]) >= delay,
                       "exponential retry delay \(delay)")
        }
        print("PASS: -1005 / timeout retry after 1, 2, 4 seconds")

        let errorServer = FixtureServer(failures: Array(repeating: .networkConnectionLost, count: 4))
        let errors = OfficialCoverLookup(cacheDirectory: root.appendingPathComponent("errors"),
            client: OfficialCoverHTTPClient(transport: { try await errorServer.handle($0) }))
        do {
            _ = try await errors.resolve(query)
            throw CheckError.failed("must surface exhausted retry")
        } catch is URLError {}
        let errorCount = await errorServer.count()
        let errorHosts = await errorServer.requests.map { $0.url?.host ?? "" }
        try expect(errorHosts.filter { $0 == "musicbrainz.org" }.count == 4, "maximum three retries after first MusicBrainz attempt")
        try expect(errorHosts.contains("api.discogs.com"), "Discogs is still queried after a MusicBrainz transport error")
        try expect(errorCount >= 5, "MusicBrainz retries plus at least one Discogs search")
        let recovered = try await errors.resolve(query)
        try expect(recovered != nil, "network failure must not become a persistent miss")
        print("PASS: retry cap and recovery after exhausted retries")

        let busyServer = FixtureServer(httpFailures: [503, 429])
        let busyClient = OfficialCoverHTTPClient(transport: { try await busyServer.handle($0) })
        let (_, busyResponse) = try await busyClient.request(queueURL)
        let busyCount = await busyServer.count()
        try expect(busyResponse.statusCode == 200 && busyCount == 3, "503 / 429 retry")
        print("PASS: HTTP 503 / 429 exponential retry")

        struct LegacyEntry: Codable { let url: String?; let checkedAt: Date }
        let legacyDir = root.appendingPathComponent("legacy")
        try FileManager.default.createDirectory(at: legacyDir, withIntermediateDirectories: true)
        let legacy = ["hit": LegacyEntry(url: "https://coverartarchive.org/cached.jpg", checkedAt: Date()),
                      "miss": LegacyEntry(url: nil, checkedAt: Date())]
        try JSONEncoder().encode(legacy).write(to: legacyDir.appendingPathComponent("map.json"))
        let migrationServer = FixtureServer()
        let migration = OfficialCoverLookup(cacheDirectory: legacyDir,
            client: OfficialCoverHTTPClient(transport: { try await migrationServer.handle($0) }))
        _ = try await migration.resolve(.init(id: "hit", title: "Stefanie", artist: "孙燕姿"))
        try expect(await migrationServer.count() == 0, "legacy hit must survive migration")
        let migratedMiss = try await migration.resolve(.init(id: "miss", title: "Stefanie", artist: "孙燕姿"))
        try expect(migratedMiss != nil, "legacy false miss must be rechecked")
        print("PASS: preserve Build 150 hits and invalidate Build 150 false misses")

        struct ExpiredEntry: Encodable {
            let checkedAt: Date
            let version = 2
            let queryKey: String
        }
        let expiredDir = root.appendingPathComponent("expired")
        try FileManager.default.createDirectory(at: expiredDir, withIntermediateDirectories: true)
        try JSONEncoder().encode(["album": ExpiredEntry(checkedAt: Date().addingTimeInterval(-8 * 86400),
                                                        queryKey: query.cacheKey)])
            .write(to: expiredDir.appendingPathComponent("map.json"))
        let expiredServer = FixtureServer()
        let expiredLookup = OfficialCoverLookup(cacheDirectory: expiredDir,
            client: OfficialCoverHTTPClient(transport: { try await expiredServer.handle($0) }))
        let expiredResult = try await expiredLookup.resolve(query)
        try expect(expiredResult != nil, "confirmed misses expire after seven days")
        print("PASS: confirmed miss expiry")

        let discogsOnlyServer = FixtureServer(.discogsOnly)
        let discogsOnly = OfficialCoverLookup(cacheDirectory: root.appendingPathComponent("discogs-only"),
            client: OfficialCoverHTTPClient(transport: { try await discogsOnlyServer.handle($0) }))
        let discogsOnlyResult = try await discogsOnly.resolve(query)
        try expect(discogsOnlyResult?.match.source == "discogs", "Discogs must fill a CAA miss")
        try expect(discogsOnlyResult?.match.url.host == "i.discogs.com", "use the Discogs image URL as returned")
        let discogsCalls = await discogsOnlyServer.requests
        try expect(discogsCalls.contains { $0.url?.path == "/database/search" }, "Discogs database search")
        try expect(discogsCalls.allSatisfy {
            ($0.value(forHTTPHeaderField: "User-Agent") ?? "").contains("github.com/ZhaoLegs/vinyl-player")
        }, "User-Agent on Discogs requests")
        print("PASS: Discogs covers a Cover Art Archive miss")

        let largerServer = FixtureServer(.discogsLarger)
        let larger = OfficialCoverLookup(cacheDirectory: root.appendingPathComponent("discogs-larger"),
            client: OfficialCoverHTTPClient(transport: { try await largerServer.handle($0) }))
        let largerResult = try await larger.resolve(query)
        try expect(largerResult?.match.source == "discogs", "larger Discogs image must beat a 1×1 CAA image")
        print("PASS: larger Discogs image wins over CAA")

        let tieServer = FixtureServer(.discogsTie)
        let tie = OfficialCoverLookup(cacheDirectory: root.appendingPathComponent("discogs-tie"),
            client: OfficialCoverHTTPClient(transport: { try await tieServer.handle($0) }))
        let tieResult = try await tie.resolve(query)
        try expect(tieResult?.match.source != "discogs", "equal pixel area must keep the CAA result")
        print("PASS: CAA wins a pixel-area tie")

        let spacerServer = FixtureServer(.discogsSpacer)
        let spacer = OfficialCoverLookup(cacheDirectory: root.appendingPathComponent("discogs-spacer"),
            client: OfficialCoverHTTPClient(transport: { try await spacerServer.handle($0) }))
        let spacerResult = try await spacer.resolve(query)
        try expect(spacerResult?.match.source != "discogs", "spacer.gif must not replace the official cover")
        print("PASS: Discogs spacer.gif is ignored")

        setenv("DISCOGS_TOKEN", "unit-test-token", 1)
        let authServer = FixtureServer()
        let authClient = OfficialCoverHTTPClient(transport: { try await authServer.handle($0) })
        let discogsURL = URL(string: "https://api.discogs.com/database/search?type=release&artist=Sun&release_title=Stefanie")!
        _ = try await authClient.request(discogsURL)
        let authHeader = await authServer.requests.last?.value(forHTTPHeaderField: "Authorization")
        try expect(authHeader == "Discogs token=unit-test-token", "optional token is sent only to api.discogs.com")
        unsetenv("DISCOGS_TOKEN")
        let plainServer = FixtureServer()
        let plainClient = OfficialCoverHTTPClient(transport: { try await plainServer.handle($0) })
        _ = try await plainClient.request(discogsURL)
        try expect(await plainServer.requests.last?.value(forHTTPHeaderField: "Authorization") == nil,
                   "no Authorization header without a token")
        print("PASS: optional Discogs token header")

        // One client hitting both hosts: MusicBrainz must not wait out the Discogs 2.5s lane.
        let laneServer = FixtureServer()
        let laneClient = OfficialCoverHTTPClient(transport: { try await laneServer.handle($0) })
        let mbURL = URL(string: "https://musicbrainz.org/ws/2/release-group?query=Stefanie")!
        _ = try await laneClient.request(discogsURL)
        let afterDiscogs = Date()
        _ = try await laneClient.request(mbURL)
        let mbWait = Date().timeIntervalSince(afterDiscogs)
        try expect(mbWait < 1.5, "MusicBrainz must not wait for the Discogs 2.5s lane (waited \(mbWait))")
        // Two Discogs requests on the unauthenticated lane must be ≥ 2.5s apart.
        let gapServer = FixtureServer()
        let gapClient = OfficialCoverHTTPClient(transport: { try await gapServer.handle($0) })
        _ = try await gapClient.request(discogsURL)
        _ = try await gapClient.request(discogsURL)
        let gapStarts = await gapServer.starts
        try expect(gapStarts[1].timeIntervalSince(gapStarts[0]) >= 2.5, "Discogs unauthenticated spacing")
        print("PASS: Discogs and MusicBrainz throttle on separate host lanes")

        print("SELF-CHECK PASSED")
    }

    private static func liveCheck(_ root: URL) async throws {
        let lookup = OfficialCoverLookup(cacheDirectory: root, diagnostics: true)
        let samples = [
            ("周杰伦", "十一月的萧邦"), ("孙燕姿", "Stefanie"),
            ("Charlie Puth", "Nine Track Mind"), ("五月天", "自传"),
            ("Taylor Swift", "1989"), ("毛不易", "平凡的一天")
        ]
        var hits = 0
        for (artist, title) in samples {
            do {
                if let result = try await lookup.resolve(.init(id: artist + title, title: title, artist: artist)) {
                    hits += 1
                    print("HIT \(artist)《\(title)》 score=\(result.match.score) source=\(result.match.source)")
                    print("  MBID: \(result.match.mbid)")
                    print("  Image: \(result.match.url.absoluteString) (\(result.imageData?.count ?? 0) bytes verified)")
                } else {
                    print("MISS \(artist)《\(title)》 → Apple artwork")
                }
            } catch { print("ERROR \(artist)《\(title)》: \(error) → Apple artwork") }
        }
        print(String(format: "LIVE RESULT %d/6 = %.1f%%", hits, Double(hits) / 6 * 100))
        try expect(hits >= 5, "target ≥ 80% requires at least 5/6 verified cover images")
    }
}
