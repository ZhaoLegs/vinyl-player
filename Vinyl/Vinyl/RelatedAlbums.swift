import SwiftUI
import MusicKit
import CryptoKit

// MARK: - t214u：详情页曲目表末尾「相似专辑」
// 数据源顺序：曲库 Album.relatedAlbums → 同歌手其他专辑（Artist.albums，排除当前）→ 都为空则整段隐藏。
// 最多 10 个、去重；按专辑 ID 内存 + 磁盘缓存（Caches/related-albums），详情打开即预取。

final class RelatedAlbumStore: @unchecked Sendable {
    static let shared = RelatedAlbumStore()
    static let limit = 10
    private static let emptyTTL: TimeInterval = 3 * 24 * 3600   // 空结果 3 天后重试；网络错误不落盘

    private struct Entry: Codable { var albums: [Album]; var source: String; var date: Date }

    private let lock = NSLock()
    private var memory: [String: Entry] = [:]
    private var inflight: [String: Task<[Album], Never>] = [:]
    private var diskMissed: Set<String> = []
    private let dir: URL = {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("related-albums", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    private func file(_ key: String) -> URL {
        let h = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return dir.appendingPathComponent(h + ".json")
    }

    /// 同步读缓存（内存 → 磁盘）；nil = 还没有结果
    func cached(_ c: MusicCollection) -> [Album]? {
        guard case .album(let a, _) = c else { return [] }
        let key = a.id.rawValue
        lock.lock(); defer { lock.unlock() }
        if let e = memory[key] { return e.albums }
        if diskMissed.contains(key) { return nil }
        guard let data = try? Data(contentsOf: file(key)),
              let e = try? JSONDecoder().decode(Entry.self, from: data) else { diskMissed.insert(key); return nil }
        if e.albums.isEmpty, Date().timeIntervalSince(e.date) > Self.emptyTTL { diskMissed.insert(key); return nil }
        memory[key] = e
        return e.albums
    }

    func prefetch(_ c: MusicCollection?) {
        guard let c else { return }
        Task.detached(priority: .utility) { _ = await self.albums(for: c) }
    }

    /// 读取（同一专辑并发请求合并成一个）
    func albums(for c: MusicCollection) async -> [Album] {
        guard case .album(let album, let isCatalog) = c else { return [] }   // 歌单 / 资料库歌曲：无相似专辑
        if let hit = cached(c) { return hit }
        let key = album.id.rawValue
        lock.lock()
        if let t = inflight[key] { lock.unlock(); return await t.value }
        let t = Task<[Album], Never> { await self.load(album, isCatalog: isCatalog) }
        inflight[key] = t
        lock.unlock()
        let r = await t.value
        lock.lock(); inflight[key] = nil; lock.unlock()
        return r
    }

    private func save(_ key: String, _ e: Entry) {
        lock.lock(); memory[key] = e; lock.unlock()
        if let data = try? JSONEncoder().encode(e) { try? data.write(to: file(key), options: .atomic) }
    }

    private func load(_ album: Album, isCatalog: Bool) async -> [Album] {
        let key = album.id.rawValue
        do {
            guard let catalogID = try await catalogID(for: album, isCatalog: isCatalog) else {
                print("[t214u] related \"\(album.title)\": no catalog id → hidden")
                save(key, Entry(albums: [], source: "none", date: Date()))
                return []
            }
            var req = MusicCatalogResourceRequest<Album>(matching: \.id, equalTo: catalogID)
            req.properties = [.relatedAlbums, .artists]
            guard let cat = try await req.response().items.first else {
                save(key, Entry(albums: [], source: "none", date: Date())); return []
            }
            var exclude: Set<String> = [catalogID.rawValue, key]
            var seenTitles: Set<String> = [Self.norm(cat.title)]
            func dedupe(_ list: [Album]) -> [Album] {
                var out: [Album] = []
                for a in list where !exclude.contains(a.id.rawValue) && !seenTitles.contains(Self.norm(a.title)) {
                    exclude.insert(a.id.rawValue); seenTitles.insert(Self.norm(a.title)); out.append(a)
                    if out.count == Self.limit { break }
                }
                return out
            }
            var source = "relatedAlbums"
            var list = dedupe(Array(cat.relatedAlbums ?? []))
            if list.isEmpty, let artist = cat.artists?.first {
                source = "artistAlbums"
                let full = try await artist.with([.albums])
                list = dedupe(Array(full.albums ?? []))
            }
            if list.isEmpty { source = "none" }
            print("[t214u] related \"\(album.title)\" (\(album.artistName)): source=\(source) n=\(list.count)")
            save(key, Entry(albums: list, source: source, date: Date()))
            return list
        } catch {
            // 网络 / 权限错误不落盘，下次再试
            print("[t214u] related \"\(album.title)\": error \(error)")
            return []
        }
    }

    private static func norm(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: " ", with: "")
    }

    /// 资料库专辑 → 曲库 ID：Apple Music API 的 library album `catalog` 关系；失败再按 UPC 查
    private func catalogID(for album: Album, isCatalog: Bool) async throws -> MusicItemID? {
        if isCatalog || !album.id.rawValue.hasPrefix("l.") { return album.id }
        struct Resp: Decodable { struct D: Decodable { let id: String }; let data: [D] }
        if let url = URL(string: "https://api.music.apple.com/v1/me/library/albums/\(album.id.rawValue)/catalog"),
           let data = try? await MusicDataRequest(urlRequest: URLRequest(url: url)).response().data,
           let id = (try? JSONDecoder().decode(Resp.self, from: data))?.data.first?.id {
            return MusicItemID(id)
        }
        if let upc = album.upc, !upc.isEmpty {
            let r = MusicCatalogResourceRequest<Album>(matching: \.upc, equalTo: upc)
            if let a = try await r.response().items.first { return a.id }
        }
        return nil
    }
}

/// 曲目表末尾的「相似专辑」横向封面列表；没有结果时整段不渲染
struct RelatedAlbumsSection: View {
    let collection: MusicCollection
    let ink: Color
    let dim: Color
    let onOpen: (MusicCollection) -> Void
    @State private var albums: [Album] = []
    @State private var loadedFor: String?

    enum Size { static let cover: CGFloat = 104 }

    var body: some View {
        let shown = loadedFor == collection.id ? albums : (RelatedAlbumStore.shared.cached(collection) ?? [])
        Group {
            if !shown.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("相似专辑")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(ink)
                        .padding(.horizontal, DS.contentInset)
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: 14) {
                            ForEach(shown, id: \.id) { a in
                                Button { onOpen(.album(a, catalog: true)) } label: {
                                    VStack(alignment: .leading, spacing: 5) {
                                        ArtworkFill(artwork: a.artwork, render: 220)
                                            .frame(width: Size.cover, height: Size.cover)
                                            .clipShape(RoundedRectangle(cornerRadius: DS.corner * Size.cover / 76.5))
                                            .shadow(color: .black.opacity(0.14), radius: 6, x: 0, y: 3)
                                        Text(a.title)
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundStyle(ink)
                                            .lineLimit(1)
                                        Text(a.artistName)
                                            .font(.system(size: 11))
                                            .foregroundStyle(dim)
                                            .lineLimit(1)
                                    }
                                    .frame(width: Size.cover, alignment: .leading)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("\(a.title)，\(a.artistName)")
                            }
                        }
                        .padding(.horizontal, DS.contentInset)
                    }
                    .scrollClipDisabled()
                }
                .padding(.top, 28)
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.25), value: shown.isEmpty)
        .task(id: collection.id) {
            let r = await RelatedAlbumStore.shared.albums(for: collection)
            albums = r; loadedFor = collection.id
        }
    }
}
