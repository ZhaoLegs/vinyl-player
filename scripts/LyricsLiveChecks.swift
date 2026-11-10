import Foundation
import LyricsCore

@main
enum LyricsLiveChecks {
    static func main() async {
        if CommandLine.arguments.contains("--hit20") { await hit20(); return }
        let backupOnly = CommandLine.arguments.contains("--backup")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vinyl-lyrics-live-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = LyricsRepository(directory: directory)
        let songs: [(String, String, String?, Double)] = [
            ("夜曲", "周杰伦", "十一月的萧邦", 229),
            ("遇见", "孙燕姿", "The Moment", 209.76),
            ("消愁", "毛不易", "平凡的一天", 261.346),
            ("倔强", "五月天", "神的孩子都在跳舞", 261.618),
            ("王妃", "萧敬腾", "王妃", 221.76),
            ("Attention", "Charlie Puth", "Voicenotes", 208.8),
            ("Shape of You - Single", "Ed Sheeran", nil, 233),
            ("Flowers - Single", "Miley Cyrus", nil, 200),
            ("Blinding Lights - Single", "The Weeknd", nil, 200)
        ]
        let selected = backupOnly ? Array(songs.prefix(5)) : songs
        var hits = 0
        for (title, artist, album, duration) in selected {
            do {
                let query = LyricsQuery(title: title, artist: artist, album: album, duration: duration)
                let value = try await (backupOnly ? LyricsRepository.fetchChineseBackup(query) : repository.load(query))
                if value?.isFound == true { hits += 1 }
                let rows: Int
                switch value?.result {
                case .synced(let lines)?: rows = lines.count
                case .plain(let text)?: rows = text.components(separatedBy: .newlines).count
                default: rows = 0
                }
                print("LIVE \(artist)《\(title)》 \(value?.isFound == true ? "HIT" : "MISS") source=\(value?.source ?? "none") id=\(value?.recordID ?? "?") expected=\(duration) matched=\(value?.matchedDuration ?? -1) delta=\(abs((value?.matchedDuration ?? -1) - duration)) rows=\(rows)")
            } catch { print("LIVE \(artist)《\(title)》 ERROR \(error)") }
        }
        let rate = Double(hits) / Double(selected.count)
        print("LIVE TOTAL \(hits)/\(selected.count) (\(String(format: "%.1f", rate * 100))%) mode=\(backupOnly ? "backup" : "normal")")
        if rate < 0.85 { exit(1) }
    }

    /// t309u: the same 20 songs as the on-device t295 harness (one track per home collection), cold cache
    static func hit20() async {
        let songs: [(String, String, String?, Double)] = [
            ("I Do", "Jay Chou", nil, 216), ("空白格", "Tanya Chua", nil, 252), ("new trick", "ROSÉ", nil, 182),
            ("POLSKA JUMPSTYLE", "Mr. Polska, Natte Visstick & Vieze Asbak", nil, 140), ("傻子", "Yoga Lin", nil, 214),
            ("Hey Hey You + Angel vs Devil (Live)", "Tanya Chua", nil, 335), ("山花", "Jackson Yee", nil, 300),
            ("In My Heart", "G.E.M.", nil, 296), ("Favorite Stuff", "Khalil Fong", nil, 186),
            ("比較幸福", "Yanzi Sun", nil, 276), ("Sober", "Step.Jad", nil, 275), ("healthy habit", "Madison Beer", nil, 116),
            ("離開地球表面", "Mayday", nil, 271), ("12 to 12", "sombr", nil, 242),
            ("Peace, Love, and Cowboys", "Lainey Wilson", nil, 210), ("When Love Is Coming", "Rene Liu", nil, 250),
            ("Up All Night", "Charlie Puth", nil, 190), ("开始懂了", "孙燕姿", "我要的幸福", 271),
            ("太聪明", "陈绮贞", "吉他手", 263), ("疲惫的爱", "step.jad依加", "疲惫的爱 - Single", 285)
        ]
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vinyl-hit20-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = LyricsRepository(directory: directory)
        var hits = 0, synced = 0, yrc = 0
        for (n, (title, artist, album, duration)) in songs.enumerated() {
            let t = Date()
            do {
                let value = try await repository.load(LyricsQuery(title: title, artist: artist, album: album, duration: duration))
                let kind: String
                switch value.result {
                case .synced(let lines): kind = "synced \(lines.count) lines"; synced += 1
                case .plain: kind = "plain"
                case .none: kind = "none"
                }
                if value.isFound { hits += 1 }
                if value.source == "NetEase YRC" { yrc += 1 }
                print("HIT20 #\(n + 1) \(value.isFound ? "HIT " : "MISS") \(title) — \(artist) → \(kind) via \(value.source) in \(Int(Date().timeIntervalSince(t) * 1000))ms")
            } catch {
                print("HIT20 #\(n + 1) FAIL \(title) — \(artist) → \(error.localizedDescription) in \(Int(Date().timeIntervalSince(t) * 1000))ms")
            }
        }
        print("HIT20 TOTAL \(hits)/\(songs.count) found, \(synced) synced, \(yrc) word-timed (YRC)")
    }
}
