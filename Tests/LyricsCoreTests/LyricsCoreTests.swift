import Foundation
import XCTest
@testable import LyricsCore

private actor HTTPStub {
    var requests: [URLRequest] = []
    var waits: [Double] = []
    var failing = false
    var responder: (URLRequest) throws -> (Int, String)
    init(_ responder: @escaping (URLRequest) throws -> (Int, String)) { self.responder = responder }
    func fail(_ value: Bool) { failing = value }
    func sleep(_ seconds: Double) { waits.append(seconds) }
    func send(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        if failing { throw URLError(.networkConnectionLost) }
        let (status, body) = try responder(request)
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status,
                                               httpVersion: nil, headerFields: nil)!)
    }
    func client() -> LyricsHTTPClient {
        LyricsHTTPClient(spacing: 0, transport: { try await self.send($0) },
                         sleep: { await self.sleep($0) })
    }
}

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_700_000_000)
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return date }
    func advance(_ interval: Double) { lock.lock(); defer { lock.unlock() }; date.addTimeInterval(interval) }
}

final class LyricsCoreTests: XCTestCase {
    private let query = LyricsQuery(title: "Attention", artist: "Charlie Puth", album: nil, duration: 209)
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("vinyl-lyrics-test-\(UUID())")
    }
    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }
    private static let hit = #"{"id":7,"trackName":"Attention","artistName":"Charlie Puth","duration":209,"syncedLyrics":"[00:01]hello\n[00:05]next"}"#
    private func missing() -> HTTPStub {
        HTTPStub { $0.url!.path == "/api/get" ? (404, "{}") : (200, "[]") }
    }

    // Regression: -1005 must throw, retry (t287u: foreground = once, after 0.3s), and never enter either cache.
    func testConnectionFailureRetriesThreeTimesAndTapRetryCanRecover() async throws {
        let stub = HTTPStub { _ in (200, Self.hit) }
        await stub.fail(true)
        let repository = LyricsRepository(directory: directory, client: await stub.client())
        do { _ = try await repository.load(query); XCTFail("network failure became a result") }
        catch { XCTAssertTrue(error is URLError) }
        let requests = await stub.requests
        let waits = await stub.waits
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(waits, [0.3])
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        await stub.fail(false)
        let recovered = try await repository.load(query)
        XCTAssertTrue(recovered.isFound)
        let count = await stub.requests.count
        XCTAssertEqual(count, 3)
    }

    // Regression: server failures cannot masquerade as a cacheable absence.
    func testHTTP503RetriesAndDoesNotCache() async throws {
        let stub = HTTPStub { _ in (503, "{}") }
        let repository = LyricsRepository(directory: directory, client: await stub.client())
        for _ in 0..<2 {
            do { _ = try await repository.load(query); XCTFail("503 became .none") }
            catch LyricsHTTPClient.Failure.status(503) {}
        }
        let count = await stub.requests.count
        XCTAssertEqual(count, 4)   // t287u: 2 loads × (1 try + 1 foreground retry)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testMalformedResponseIsFailureRatherThanAbsence() async throws {
        let stub = HTTPStub { _ in (200, "{invalid") }
        let repository = LyricsRepository(directory: directory, client: await stub.client())
        do { _ = try await repository.load(query); XCTFail("invalid JSON became .none") }
        catch { XCTAssertTrue(error is DecodingError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testTitleCleanupAndPrimaryArtistAndScriptVariants() {
        for title in ["Attention - Single", "Attention (Live)", "Attention (feat. Guest)",
                      "Attention [Remastered]", "Attention (Deluxe)", "Attention（现场版）"] {
            XCTAssertEqual(LyricsQuery.clean(title), "Attention")
        }
        for artist in ["Charlie Puth & Guest", "Charlie Puth, Guest", "Charlie Puth、Guest",
                       "Charlie Puth feat. Guest"] {
            XCTAssertEqual(LyricsQuery.primaryArtist(artist), "Charlie Puth")
        }
        let cn = LyricsQuery(title: "遇見 - Single", artist: "孫燕姿、嘉賓", album: nil, duration: 210)
        XCTAssertTrue(cn.variants.contains { $0.title == "遇见" && $0.artist == "孙燕姿" })
        XCTAssertTrue(cn.variants.contains { $0.title == "遇見" && $0.artist == "孫燕姿" })
        XCTAssertNotEqual(query.cacheKey, LyricsQuery(title: "Attention (Live)", artist: "Charlie Puth",
                                                     album: nil, duration: 209).cacheKey)
    }

    // Regression + boundaries: reject a cover, unknown candidate duration, or >3 seconds.
    func testSelectionUsesSingerSimilarityAndThreeSecondBoundary() throws {
        let records = try JSONDecoder().decode([LyricsRecord].self, from: Data("""
        [{"id":1,"trackName":"Attention","artistName":"Cover Singer","duration":209,"syncedLyrics":"[00:01]wrong"},
         {"id":2,"trackName":"Attention","artistName":"Charlie Puth","duration":212,"plainLyrics":"correct"},
         {"id":3,"trackName":"Attention","artistName":"Charlie Puth","duration":212.01,"syncedLyrics":"[00:01]wrong"},
         {"id":4,"trackName":"Attention","artistName":"Charlie Puth","syncedLyrics":"[00:01]unknown"},
         {"id":5,"trackName":"Attention","artistName":"Charlies Puth","duration":209,"syncedLyrics":"[00:01]similar"},
         {"id":6,"trackName":"Different","artistName":"Charlie Puth","duration":209,"syncedLyrics":"[00:01]wrong"}]
        """.utf8))
        XCTAssertEqual(records.filter { $0.matches(query) }.compactMap(\.id), [2, 5])
        XCTAssertEqual(LyricsRepository.selected(records, query)?.id, 2, "exact singer ranks above fuzzy singer")
    }

    func testGetMissSearchSelectsCorrectSingerAndPlainLyrics() async throws {
        let stub = HTTPStub { request in
            if request.url!.path == "/api/get" { return (404, "{}") }
            return (200, """
            [{"trackName":"Attention","artistName":"Cover Singer","duration":209,"syncedLyrics":"[00:01]cover"},
             {"id":8,"trackName":"Attention","artistName":"Charlie Puth","duration":209,"plainLyrics":"  static text\\nsecond line  "}]
            """)
        }
        let repository = LyricsRepository(directory: directory, client: await stub.client())
        let value = try await repository.load(query)
        XCTAssertEqual(value.source, "LRCLIB/search")
        XCTAssertEqual(value.result, .plain("static text\nsecond line"))
        let count = await stub.requests.count
        XCTAssertEqual(count, 3)   // t287u: 1 get, then both searches in parallel
    }

    func testChineseFallbackRejectsCoverAndUsesSameLRCParserWithoutCookies() async throws {
        let stub = HTTPStub { request in
            switch request.url!.path {
            case "/api/get": return (404, "{}")
            case "/api/search": return (200, "[]")
            case "/api/search/get":
                return (200, """
                {"code":200,"result":{"songs":[
                {"id":88,"name":"遇见","duration":210000,"artists":[{"name":"cover"}]},
                {"id":89,"name":"遇见","duration":210000,"artists":[{"name":"孙燕姿"}]}]}}
                """)
            default: return (200, #"{"code":200,"lrc":{"lyric":"[00:01]<00:01>你<00:02>好\n[00:05]next"}}"#)
            }
        }
        let cn = LyricsQuery(title: "遇见", artist: "孙燕姿", album: nil, duration: 210)
        let value = try await LyricsRepository(directory: directory, client: await stub.client()).load(cn)
        XCTAssertEqual(value.source, "NetEase")
        XCTAssertEqual(value.recordID, "89")
        XCTAssertEqual(value.result, .synced(LyricsParser.parseLRC("[00:01]<00:01>你<00:02>好\n[00:05]next")))
        let requests = await stub.requests.filter { $0.url!.host == "music.163.com" }
        XCTAssertTrue(requests.allSatisfy { !$0.httpShouldHandleCookies && $0.value(forHTTPHeaderField: "Referer") != nil })
    }

    func testUntimedBackupLyricsRemainPlain() async throws {
        let stub = HTTPStub { request in
            request.url!.path == "/api/search/get"
                ? (200, #"{"code":200,"result":{"songs":[{"id":89,"name":"遇见","duration":210000,"artists":[{"name":"孙燕姿"}]}]}}"#)
                : (200, #"{"code":200,"lrc":{"lyric":"第一句\n第二句"}}"#)
        }
        let value = try await LyricsRepository.fetchChineseBackup(
            LyricsQuery(title: "遇见", artist: "孙燕姿", album: nil, duration: 210), client: await stub.client())
        XCTAssertEqual(value?.result, .plain("第一句\n第二句"))
    }

    func testBackupAbsenceAndMetadataOnlyAreNotPlainLyricHits() async throws {
        for response in [#"{"code":200,"nolyric":true,"lrc":{"lyric":"纯音乐，请欣赏"}}"#,
                         #"{"code":200,"lrc":{"lyric":"[ar:孙燕姿]\n[ti:遇见]\n[00:01]"}}"#] {
            let stub = HTTPStub { request in
                request.url!.path == "/api/search/get"
                    ? (200, #"{"code":200,"result":{"songs":[{"id":89,"name":"遇见","duration":210000,"artists":[{"name":"孙燕姿"}]}]}}"#)
                    : (200, response)
            }
            let value = try await LyricsRepository.fetchChineseBackup(
                LyricsQuery(title: "遇见", artist: "孙燕姿", album: nil, duration: 210), client: await stub.client())
            XCTAssertNil(value)
        }
    }

    // Regression: both the running app and a reopened app must expire a miss at three days.
    func testMissExpiresInMemoryAndOnDiskAfterThreeDays() async throws {
        let clock = Clock(), stub = missing()
        let client = await stub.client()
        let repository = LyricsRepository(directory: directory, client: client, now: { clock.now() })
        let first = try await repository.loadEntry(query)
        XCTAssertEqual(first.value.result, .none)
        let count = await stub.requests.count
        clock.advance(LyricsRepository.notFoundTTL - 1)
        XCTAssertTrue(first.valid(at: clock.now()))
        _ = try await repository.load(query)
        _ = try await LyricsRepository(directory: directory, client: client, now: { clock.now() }).load(query)
        let cached = await stub.requests.count
        XCTAssertEqual(count, cached)
        clock.advance(1)
        XCTAssertFalse(first.valid(at: clock.now()), "peek uses this same expiry predicate")
        _ = try await repository.load(query)
        let afterMemory = await stub.requests.count
        XCTAssertGreaterThan(afterMemory, count)
        clock.advance(LyricsRepository.notFoundTTL)
        _ = try await LyricsRepository(directory: directory, client: client, now: { clock.now() }).load(query)
        let afterDisk = await stub.requests.count
        XCTAssertGreaterThan(afterDisk, afterMemory)
    }

    func testSuccessfulCacheIsPermanentAndConcurrentLoadsShareOneFlight() async throws {
        let clock = Clock(), stub = HTTPStub { _ in (200, Self.hit) }
        let client = await stub.client()
        let repository = LyricsRepository(directory: directory, client: client, now: { clock.now() })
        async let a = repository.load(query)
        async let b = repository.load(query)
        let (first, second) = try await (a, b)
        XCTAssertEqual(first, second)
        clock.advance(10 * 365 * 86400)
        let memory = try await repository.load(query)
        let disk = try await LyricsRepository(directory: directory, client: client, now: { clock.now() }).load(query)
        XCTAssertEqual(memory, first)
        XCTAssertEqual(disk, first)
        let count = await stub.requests.count
        XCTAssertEqual(count, 1)
    }

    func testPartialServiceFailureCannotBecomeNegativeCache() async throws {
        let stub = HTTPStub { request in
            if request.url!.path == "/api/get" { return (404, "{}") }
            if request.url!.path == "/api/search" { return (503, "{}") }
            return (200, #"{"code":200,"result":{"songs":[]}}"#)
        }
        let repository = LyricsRepository(directory: directory, client: await stub.client())
        do {
            _ = try await repository.load(LyricsQuery(title: "遇见", artist: "孙燕姿", album: nil, duration: 210))
            XCTFail("partial outage became .none")
        } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testParserPreservesExistingEnhancedAndRepeatedLineBehavior() {
        let lines = LyricsParser.parseLRC("[ar:artist]\n[00:10][00:30]<00:10>你<00:12>好\n[00:40] next ")
        XCTAssertEqual(lines.map(\.time), [10, 30, 40])
        XCTAssertEqual(lines.map(\.text), ["你好", "你好", "next"])
        XCTAssertEqual(lines[0].marks, [.init(char: 0, time: 10), .init(char: 1, time: 12)])
        XCTAssertEqual(lines[1].marks, lines[0].marks)
        XCTAssertTrue(LyricsParser.parseLRC("static text\n[ar:artist]\n[00:01]").isEmpty)
    }
}
