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
    /// 缓存键：专辑 = 专辑 ID；t242u 歌单 = "playlist-<id>"；其他（资料库歌曲）无相似专辑
    private static func key(_ c: MusicCollection) -> String? {
        switch c {
        case .album(let a, _): return a.id.rawValue
        case .playlist(let p): return "playlist-\(p.id.rawValue)"
        case .librarySongs: return nil
        }
    }

    func cached(_ c: MusicCollection) -> [Album]? {
        guard let key = Self.key(c) else { return [] }
        lock.lock(); defer { lock.unlock() }
        if let e = memory[key] { return e.albums }
        if diskMissed.contains(key) { return nil }
        guard let data = try? Data(contentsOf: file(key)),
              let e = try? JSONDecoder().decode(Entry.self, from: data) else { diskMissed.insert(key); return nil }
        if e.albums.isEmpty, Date().timeIntervalSince(e.date) > Self.emptyTTL { diskMissed.insert(key); return nil }
        memory[key] = e
        return e.albums
    }

    /// Rendering may inspect memory, but disk decoding belongs to the loading task.
    func memoryCached(_ c: MusicCollection) -> [Album]? {
        guard let key = Self.key(c) else { return [] }
        lock.lock(); defer { lock.unlock() }
        return memory[key]?.albums
    }

    func prefetch(_ c: MusicCollection?) {
        guard let c else { return }
        Task.detached(priority: .utility) { _ = await self.albums(for: c) }
    }

    /// 读取（同一专辑并发请求合并成一个）
    func albums(for c: MusicCollection, songs: [Song] = []) async -> [Album] {
        if TracklistProfile.enabled { return [] }
        guard let key = Self.key(c) else { return [] }   // 资料库歌曲：无相似专辑
        if let hit = cached(c) { return hit }
        if case .playlist = c, songs.isEmpty { return [] }   // 歌单要等曲目到了再算（不落盘）
        lock.lock()
        if let t = inflight[key] { lock.unlock(); return await t.value }
        let t = Task<[Album], Never> {
            switch c {
            case .album(let album, let isCatalog): return await self.load(album, isCatalog: isCatalog)
            case .playlist(let p): return await self.loadPlaylist(p, songs: songs, key: key)
            case .librarySongs: return []
            }
        }
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

    // MARK: t242u 歌单：出现最多的 1–2 位艺人 → 曲库 Artist.albums（排除歌单里已有的专辑），交替合并、去重，≤10

    /// 主艺人名：去掉 feat. / & / , / 、 之后的合作者
    private static func primaryArtist(_ name: String) -> String {
        var n = name
        for sep in [" feat.", " ft.", " featuring ", " & ", ", ", "、", " x ", " X "] {
            if let r = n.range(of: sep, options: .caseInsensitive) { n = String(n[..<r.lowerBound]) }
        }
        return n.trimmingCharacters(in: .whitespaces)
    }

    private func loadPlaylist(_ p: Playlist, songs: [Song], key: String) async -> [Album] {
        var counts: [String: Int] = [:]
        for s in songs { counts[Self.primaryArtist(s.artistName), default: 0] += 1 }
        let ranked = counts.filter { !$0.key.isEmpty }.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
        // 第一位必取；第二位至少出现 2 次才带上（避免一首客串就混进来）
        var top = ranked.prefix(1).map(\.key)
        if ranked.count > 1, ranked[1].value >= 2 { top.append(ranked[1].key) }
        guard !top.isEmpty else { save(key, Entry(albums: [], source: "none", date: Date())); return [] }
        let inPlaylist = Set(songs.compactMap { $0.albumTitle }.map(Self.norm))
        do {
            var lists: [[Album]] = []
            for name in top {
                var req = MusicCatalogSearchRequest(term: name, types: [Artist.self])
                req.limit = 5
                let found = try await req.response().artists
                guard let artist = found.first(where: { Self.norm($0.name) == Self.norm(name) }) ?? found.first else { continue }
                let full = try await artist.with([.albums])
                lists.append(Array(full.albums ?? []))
            }
            // 交替合并（艺人 1 第 1 张、艺人 2 第 1 张…），按 ID / 标题去重，排除歌单已有专辑
            var out: [Album] = [], ids: Set<String> = [], titles = inPlaylist
            var i = 0
            while out.count < Self.limit, lists.contains(where: { i < $0.count }) {
                for l in lists where i < l.count {
                    let a = l[i]; let t = Self.norm(a.title)
                    if !ids.contains(a.id.rawValue), !titles.contains(t) {
                        ids.insert(a.id.rawValue); titles.insert(t); out.append(a)
                        if out.count == Self.limit { break }
                    }
                }
                i += 1
            }
            print("[t242u] related playlist \"\(p.name)\": artists=\(top) n=\(out.count)")
            save(key, Entry(albums: out, source: out.isEmpty ? "none" : "playlistArtists", date: Date()))
            return out
        } catch {
            print("[t242u] related playlist \"\(p.name)\": error \(error)")
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
    /// t242u：歌单用曲目统计艺人
    var songs: [Song] = []
    let ink: Color
    let dim: Color
    let onOpen: (MusicCollection) -> Void
    @State private var albums: [Album] = []
    @State private var loadedFor: String?

    enum Size { static let cover: CGFloat = 104 }

    var body: some View {
        let _ = TracklistProfile.count("RelatedAlbumsSection.body")
        let shown = loadedFor == collection.id ? albums : (RelatedAlbumStore.shared.memoryCached(collection) ?? [])
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
                                        ArtworkFill(artwork: a.artwork, render: Size.cover)
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
        .task(id: "\(collection.id)-\(songs.count)") {
            let c = collection, tracks = songs
            let r = await Task.detached(priority: .utility) {
                await RelatedAlbumStore.shared.albums(for: c, songs: tracks)
            }.value
            guard !Task.isCancelled else { return }
            albums = r; loadedFor = collection.id
        }
    }
}
