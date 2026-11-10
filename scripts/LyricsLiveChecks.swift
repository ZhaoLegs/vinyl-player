import Foundation
import LyricsCore

@main
enum LyricsLiveChecks {
    static func main() async {
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
}
