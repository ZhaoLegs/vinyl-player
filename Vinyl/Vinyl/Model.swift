import Foundation

struct Track: Identifiable {
    let id = UUID()
    let side: String
    let bpm: Int
    let title: String
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
        Track(side: "A", bpm: 140, title: "Deluka - Mind Games"),
        Track(side: "",  bpm: 140, title: "Deluka - Braunschweig"),
        Track(side: "B", bpm: 140, title: "Deluka - Everybody Talkin"),
        Track(side: "",  bpm: 139, title: "Deluka - Bunker")
    ]
}
