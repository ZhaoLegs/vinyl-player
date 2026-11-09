import Foundation

enum HomeFeed {
    /// 保留来源顺序。重复项的新别名也记下来，避免后续缺少 UPC 的同专辑再次出现。
    static func merged<Item>(groups: [[Item]], identityKeys: (Item) -> [String]) -> [Item] {
        var seen = Set<String>()
        var result: [Item] = []
        for group in groups {
            for item in group {
                let keys = identityKeys(item)
                let duplicate = keys.contains { seen.contains($0) }
                seen.formUnion(keys)
                if !duplicate { result.append(item) }
            }
        }
        return result
    }

    /// 不把缺少日期的内容当作最近添加；相同日期保留接口顺序。
    static func latest<Item>(_ items: [Item], date: (Item) -> Date?, limit: Int) -> [Item] {
        guard limit > 0 else { return [] }
        let dated = items.enumerated().compactMap { index, item -> (Int, Item, Date)? in
            guard let value = date(item) else { return nil }
            return (index, item, value)
        }
        return dated.sorted {
            $0.2 == $1.2 ? $0.0 < $1.0 : $0.2 > $1.2
        }.prefix(limit).map { $0.1 }
    }
}

/// 分页位置按接口实际返回数量推进，不能使用去重后的显示数量。
struct MusicPageCursor {
    let pageSize: Int
    private(set) var offset = 0
    private(set) var hasMore = false

    mutating func consume(_ count: Int) {
        offset += count
        hasMore = count == pageSize && count > 0
    }
}

struct Track: Identifiable {
    let id = UUID()
    let side: String
    let bpm: Int
    let title: String
    var isPlaying: Bool = false
}

enum AlbumData {
    static let coverCount = 28
    /// 原片中被点击的是第 4 行第 1 张（1-based 索引 13）
    static let featuredIndex = 13
    static let featuredCover = "cover_13"

    static let title = "Mind Games"
    static let artist = "Deluka"
    static let catalog = "SK11X027"
    static let release = "SK_Eleven"

    static let tracks: [Track] = [
        Track(side: "A", bpm: 140, title: "Deluka - Mind Games", isPlaying: true),
        Track(side: "",  bpm: 140, title: "Deluka - Braunschweig"),
        Track(side: "B", bpm: 140, title: "Deluka - Everybody Talkin"),
        Track(side: "",  bpm: 139, title: "Deluka - Bunker")
    ]
}
