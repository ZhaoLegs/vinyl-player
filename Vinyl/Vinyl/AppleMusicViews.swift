import MusicKit
import SwiftUI
import ImageIO

struct MusicArtwork: View {
    let artwork: Artwork?
    var size: CGFloat = 72

    var body: some View {
        Group {
            if let artwork {
                ArtworkImage(artwork, width: size, height: size)
            } else {
                ZStack {
                    Color.secondary.opacity(0.1)
                    Image(systemName: "music.note").foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityHidden(true)
    }
}

struct MusicAccessView: View {
    @EnvironmentObject private var music: AppleMusicStore
    @Environment(\.openURL) private var openURL

    var body: some View {
        ContentUnavailableView {
            Label("连接 Apple Music", systemImage: "music.note")
        } description: {
            Text(music.authorization == .denied
                 ? "访问已关闭。请在系统设置中允许 Vinyl 访问媒体与 Apple Music。"
                 : music.authorization == .restricted
                 ? "此设备限制了音乐访问，请检查屏幕使用时间或设备管理设置。"
                 : "浏览你的专辑和歌单，搜索音乐并在 Vinyl 中播放。")
        } actions: {
            if music.authorization == .denied {
                Button("打开设置") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }.buttonStyle(.borderedProminent)
            } else if music.authorization != .restricted {
                Button("连接 Apple Music") { Task { await music.connect() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(music.isConnecting)
            }
        }
    }
}

struct MusicSearchView: View {
    @EnvironmentObject private var music: AppleMusicStore
    @State private var query = ""
    @State private var albums: [Album] = []
    @State private var songs: [Song] = []
    @State private var loading = false
    @State private var failure: String?
    @State private var selected: MusicCollection?

    var body: some View {
        NavigationStack {
            Group {
                if !music.authorized {
                    MusicAccessView()
                } else {
                    List {
                        if loading { ProgressView("正在搜索") }
                        if let failure { Text(failure).foregroundStyle(.secondary) }
                        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            ContentUnavailableView("搜索 Apple Music", systemImage: "magnifyingglass",
                                                   description: Text("输入歌曲、艺人或专辑名称。"))
                        } else if !loading && failure == nil && albums.isEmpty && songs.isEmpty {
                            ContentUnavailableView.search(text: query)
                        }
                        if !albums.isEmpty {
                            Section("专辑") {
                                ForEach(albums) { album in
                                    Button {
                                        selected = .album(album, catalog: true)
                                    } label: {
                                        HStack {
                                            MusicArtwork(artwork: album.artwork, size: 48)
                                            VStack(alignment: .leading) {
                                                Text(album.title)
                                                Text(album.artistName).font(.caption).foregroundStyle(.secondary)
                                            }
                                        }
                                    }.buttonStyle(.plain)
                                }
                            }
                        }
                        if !songs.isEmpty {
                            Section("歌曲") {
                                ForEach(songs) { song in
                                    MusicSongRow(song: song) {
                                        await music.play(song, in: songs, fromCatalog: true)
                                    }
                                }
                            }
                        }
                    }
                    .scrollContentBackground(.hidden)
                    .searchable(text: $query, prompt: "歌曲、艺人、专辑")
                }
            }
            .navigationTitle("搜索")
            .background { AuroraBackground() }
            .modifier(MiniPlayerBar())
            .sheet(item: $selected) { MusicCollectionView(collection: $0) }
            .task(id: "\(music.authorized)-\(query)") { await search() }
            .onChange(of: music.authorized) { _, authorized in
                if !authorized {
                    selected = nil
                    albums = []
                    songs = []
                }
            }
        }
    }

    private func search() async {
        albums = []
        songs = []
        failure = nil
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard music.authorized, !term.isEmpty else { loading = false; return }
        loading = true
        do {
            try await Task.sleep(for: .milliseconds(350))
            var request = MusicCatalogSearchRequest(term: term, types: [Album.self, Song.self])
            request.limit = 20
            let response = try await request.response()
            try Task.checkCancellation()
            albums = Array(response.albums)
            songs = Array(response.songs)
            loading = false
        } catch is CancellationError {
            // A newer query owns the loading/results state.
        } catch {
            guard !Task.isCancelled else { return }
            failure = "搜索失败：\(error.localizedDescription)"
            loading = false
        }
    }
}

struct MusicSongRow: View {
    @EnvironmentObject private var music: AppleMusicStore
    let song: Song
    let play: () async -> Void

    var body: some View {
        Button { Task { await play() } } label: {
            HStack {
                MusicArtwork(artwork: song.artwork, size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text(song.title).foregroundStyle(.primary)
                    Text(song.artistName).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if music.isCurrent(song) {
                    PlaybackSymbol(isPlaying: music.isPlaying)
                }
                if song.playParameters == nil {
                    Text("不可播放").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(musicTime(song.duration ?? 0)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(music.isPreparing || song.playParameters == nil)
        .accessibilityLabel("播放 \(song.title)，\(song.artistName)")
    }
}

struct MusicCollectionView: View {
    @EnvironmentObject private var music: AppleMusicStore
    @Environment(\.dismiss) private var dismiss
    let collection: MusicCollection
    @State private var songs: [Song] = []
    @State private var loading = true
    @State private var failure: String?
    @State private var attempt = 0

    var body: some View {
        NavigationStack {
            List {
                VStack(spacing: 12) {
                    MusicArtwork(artwork: collection.artwork, size: 230)
                    Text(collection.title).font(.title2.bold())
                    Text(collection.artist).foregroundStyle(.secondary)
                    Button("播放", systemImage: "play.fill") {
                        if let first = songs.first(where: { $0.playParameters != nil }) {
                            Task { await music.play(first, in: songs, fromCatalog: collection.isCatalog) }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(loading || music.isPreparing || !songs.contains { $0.playParameters != nil })
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
                if loading { ProgressView("正在读取曲目") }
                if let failure {
                    Text(failure)
                    Button("重试") { attempt += 1 }
                } else if !loading && songs.isEmpty {
                    Text("没有可显示的歌曲。此列表可能为空或仅包含音乐视频。").foregroundStyle(.secondary)
                }
                ForEach(Array(songs.enumerated()), id: \.offset) { _, song in
                    MusicSongRow(song: song) {
                        await music.play(song, in: songs, fromCatalog: collection.isCatalog)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background { AuroraBackground() }
            .navigationTitle("Apple Music")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("完成") { dismiss() } }
            .safeAreaInset(edge: .top) { MusicErrorBanner() }
            .onChange(of: music.authorized) { _, authorized in
                if !authorized { songs = []; dismiss() }
            }
            .task(id: attempt) {
                loading = true
                failure = nil
                do {
                    let loaded = try await collection.songs()
                    try Task.checkCancellation()
                    songs = loaded
                    loading = false
                } catch is CancellationError {
                } catch {
                    failure = "读取曲目失败：\(error.localizedDescription)"
                    loading = false
                }
            }
        }
    }
}

struct MusicAccountView: View {
    @EnvironmentObject private var music: AppleMusicStore

    var body: some View {
        NavigationStack {
            Form {
                Section("Apple Music") {
                    if music.authorized {
                        Label("已允许访问音乐", systemImage: "checkmark.circle")
                        Text(music.subscriptionKnown
                             ? (music.canPlayCatalog ? "订阅可播放 Apple Music 曲库" : "当前订阅不可播放曲库")
                             : "订阅状态暂时无法获取")
                        Button("刷新连接状态") { Task { await music.refreshAccess() } }
                        Text(music.recommendationSource.isEmpty ? "推荐：暂无" : "推荐来源：\(music.recommendationSource)")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        MusicAccessView()
                    }
                }
                Section {
                    Text("首页按最近播放、最近添加、推荐、资料库歌曲、歌单和专辑排列；滑到底部继续加载，点封面即开始播放。未授权时显示内置演示封面。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("我的")
            .modifier(MiniPlayerBar())
        }
    }
}

func musicTime(_ seconds: TimeInterval) -> String {
    let value = seconds.isFinite ? Int(max(0, seconds)) : 0
    return String(format: "%d:%02d", value / 60, value % 60)
}

/// Inline errors stay visible above presented collection/player content.
struct MusicErrorBanner: View {
    @EnvironmentObject private var music: AppleMusicStore
    var body: some View {
        if let message = music.errorMessage {
            HStack(alignment: .top) {
                Text(message).font(.callout)
                Spacer(minLength: 8)
                Button("关闭提示", systemImage: "xmark") { music.errorMessage = nil }
                    .labelStyle(.iconOnly)
            }
            .padding()
            .background(.regularMaterial)
        }
    }
}

/// 其它 tab 也挂同一个 mini player（与首页同一套宽度 / 12pt 间距 token）。
struct MiniPlayerBar: ViewModifier {
    @EnvironmentObject private var music: AppleMusicStore
    private var show: Bool { music.hasCurrentTrack || DemoMode.enabled }   // t158u
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.safeAreaBar(edge: .bottom, spacing: 0) {
                if show {
                    MiniPlayer()
                        .padding(.horizontal, DS.tabBarSideInset)
                        .padding(.bottom, DS.miniPlayerBottomPadding)
                }
            }
        } else {
            content.safeAreaInset(edge: .bottom) {
                if show { MiniPlayer().padding(.horizontal, 16).padding(.bottom, 10) }
            }
        }
    }
}

/// 用固定渲染尺寸取 MusicKit 封面，再按容器缩放：转场每帧改 frame 时不会反复重新请求图片。
struct ArtworkFill: View {
    let artwork: Artwork?
    var render: CGFloat = 320
    /// t197u：有值时后台查 MusicBrainz Cover Art Archive；命中后平滑换成官方封面
    var official: OfficialCoverQuery? = nil
    var useDisplaySize = false

    var body: some View {
        GeometryReader { geo in
            let side = max(1, geo.size.width)
            let render = useDisplaySize ? side : self.render
            Group {
                if let artwork {
                    // t193u：http(s) 封面走本地内存 + 磁盘缓存；资料库本地封面（musicKit://）仍交给系统 ArtworkImage
                    // t197u：先显示 Apple 封面，官方封面就绪后交叉淡入替换（不挡 UI）
                    CachedArtwork(artwork: artwork, side: render, official: official)
                } else if let official {
                    CachedArtwork(artwork: nil, side: render, official: official)
                } else {
                    ZStack {
                        Color(hex: 0xE4E0DC)
                        Image(systemName: "music.note")
                            .font(.system(size: render * 0.3))
                            .foregroundStyle(DS.secondary)
                    }
                    .frame(width: render, height: render)
                }
            }
            .frame(width: render, height: render)
            .scaleEffect(side / render, anchor: .topLeading)
            .frame(width: side, height: side, alignment: .topLeading)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}


// MARK: - t193u：封面持久缓存（内存 NSCache + 磁盘 Caches/artwork，键 = 请求像素尺寸下的封面 URL）

final class ArtworkCache: @unchecked Sendable {
    static let shared = ArtworkCache()
    private let memory = NSCache<NSString, UIImage>()
    private let dir: URL
    private let io = DispatchQueue(label: "vinyl.artwork.io", qos: .utility)
    private let decoder = DispatchQueue(label: "vinyl.artwork.decode", qos: .userInitiated)
    private var inflight: [String: Task<UIImage?, Never>] = [:]
    private let lock = NSLock()
    private var previews: [String: String] = [:]
    private var variants: [String: [String]] = [:]
    static let diskLimit = 200 * 1024 * 1024
    private(set) var stats = (memory: 0, disk: 0, network: 0)

    private init() {
        memory.totalCostLimit = 120 * 1024 * 1024
        dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("artwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        io.asyncAfter(deadline: .now() + 5) { [weak self] in self?.trim() }
    }

    private func file(_ key: String) -> URL {
        var h: UInt64 = 1469598103934665603
        for b in key.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return dir.appendingPathComponent(String(h, radix: 16) + ".jpg")
    }

    func cached(_ key: String) -> UIImage? { memory.object(forKey: key as NSString) }

    static func key(for url: URL, pixelSize: Int?) -> String {
        pixelSize.map { "\(url.absoluteString)#pixels=\(max(1, $0))" } ?? url.absoluteString
    }

    func cached(for url: URL, pixelSize: Int?) -> UIImage? {
        cached(Self.key(for: url, pixelSize: pixelSize))
    }

    func cachedPreview(for url: URL) -> UIImage? {
        if let full = cached(url.absoluteString) { return full }
        let keys = lock.withLock { variants[url.absoluteString] ?? [] }
        return keys.compactMap(cached).max {
            ($0.cgImage?.width ?? 0) < ($1.cgImage?.width ?? 0)
        }
    }

    func rememberPreview(_ url: URL, pixelSize: Int?, source: String) {
        lock.withLock { previews[source] = Self.key(for: url, pixelSize: pixelSize) }
    }

    func preview(for artwork: Artwork?) -> UIImage? {
        guard let source = artwork?.url(width: 1, height: 1)?.absoluteString,
              let key = lock.withLock({ previews[source] }) else { return nil }
        return cached(key)
    }

    func image(for url: URL, pixelSize: Int? = nil) async -> UIImage? {
        let key = Self.key(for: url, pixelSize: pixelSize)
        if let m = cached(key) { return m }
        let (task, created) = lock.withLock { () -> (Task<UIImage?, Never>, Bool) in
            if let existing = inflight[key] { return (existing, false) }
            let task = Task.detached(priority: .userInitiated) { [self] () -> UIImage? in
                let f = file(url.absoluteString)
                if let data = try? Data(contentsOf: f), let img = await decode(data, pixelSize: pixelSize) {
                    try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: f.path)
                    store(img, key: key, source: 1, url: url)
                    return img
                }
                guard let (data, response) = try? await URLSession.shared.data(from: url),
                      let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
                      let img = await decode(data, pixelSize: pixelSize) else { return nil }
                try? data.write(to: f, options: .atomic)
                store(img, key: key, source: 2, url: url)
                return img
            }
            inflight[key] = task
            return (task, true)
        }
        let img = await task.value
        if created { lock.withLock { inflight[key] = nil } }
        return img
    }

    private func decode(_ data: Data, pixelSize: Int?) async -> UIImage? {
        await withCheckedContinuation { continuation in
            decoder.async {
                assert(!Thread.isMainThread)
                guard let pixelSize else {
                    continuation.resume(returning: UIImage(data: data)?.preparingForDisplay())
                    return
                }
                let options = [kCGImageSourceShouldCache: false] as CFDictionary
                guard let source = CGImageSourceCreateWithData(data as CFData, options) else {
                    continuation.resume(returning: nil)
                    return
                }
                let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
                let width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? Double(pixelSize)
                let height = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? Double(pixelSize)
                // Both axes must cover the square display. Preserve the old image's
                // sampling quality for rectangular CAA covers as well as square artwork.
                let longest = max(1, max(width, height))
                let shortest = max(1, min(width, height))
                let limit = max(1, Int(min(longest, ceil(Double(pixelSize) * longest / shortest))))
                guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceShouldCacheImmediately: true,
                        kCGImageSourceThumbnailMaxPixelSize: limit
                      ] as CFDictionary) else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: UIImage(cgImage: image))
            }
        }
    }

    private func store(_ img: UIImage, key: String, source: Int, url: URL) {
        let cost = img.cgImage.map { $0.bytesPerRow * $0.height }
            ?? Int(img.size.width * img.size.height * img.scale * img.scale * 4)
        memory.setObject(img, forKey: key as NSString, cost: cost)
        lock.lock()
        var keys = variants[url.absoluteString] ?? []
        keys.removeAll { $0 == key }
        keys.insert(key, at: 0)
        variants[url.absoluteString] = Array(keys.prefix(8))
        if source == 1 { stats.disk += 1 } else { stats.network += 1 }
        let n = stats.disk + stats.network, st = stats
        lock.unlock()
        if n == 16 {
            print("[t193u] first 16 covers ready at \(String(format: "%.2f", Date().timeIntervalSince(HomeCache.launch)))s since launch (disk \(st.disk), network \(st.network))")
        }
    }

    /// 超过 200MB 时按最近使用时间（mtime）删最旧的
    private func trim() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else { return }
        var items = files.compactMap { u -> (URL, Int, Date)? in
            guard let v = try? u.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
            return (u, v.fileSize ?? 0, v.contentModificationDate ?? .distantPast)
        }
        var total = items.reduce(0) { $0 + $1.1 }
        print("[t193u] artwork disk cache: \(items.count) files, \(total / 1024 / 1024) MB")
        guard total > Self.diskLimit else { return }
        items.sort { $0.2 < $1.2 }
        for (u, size, _) in items where total > Self.diskLimit {
            try? fm.removeItem(at: u); total -= size
        }
    }

    /// 预取（首页可见 + 后几行）
    func prefetch(_ urls: [URL], pixelSize: Int? = nil) {
        Task.detached(priority: .utility) {
            for start in stride(from: 0, to: urls.count, by: 4) {
                await withTaskGroup(of: Void.self) { group in
                    for url in urls[start..<min(urls.count, start + 4)] {
                        group.addTask { _ = await self.image(for: url, pixelSize: pixelSize) }
                    }
                }
            }
        }
    }
}

@MainActor
final class GridArtworkPrefetcher {
    private var row: Int?
    private var task: Task<Void, Never>?

    func update(_ collections: [MusicCollection], around index: Int, side: CGFloat, scale: CGFloat) {
        let nextRow = index / 4
        guard row != nextRow, side > 1 else { return }
        row = nextRow
        task?.cancel()
        let pixels = max(1, Int((side * scale).rounded(.up)))
        let start = max(0, nextRow * 4 - 8)
        let end = min(collections.count, (nextRow + 5) * 4)
        let requests = collections[start..<end].compactMap { collection -> (URL, String)? in
            guard let artwork = collection.artwork,
                  let url = artwork.url(width: pixels, height: pixels),
                  url.scheme == "http" || url.scheme == "https",
                  let source = artwork.url(width: 1, height: 1)?.absoluteString else { return nil }
            return (url, source)
        }
        task = Task {
            // Four downloads per batch; fast scrolling cancels queued batches.
            // A request shared with a visible tile is allowed to finish and warm its cache.
            for start in stride(from: 0, to: requests.count, by: 4) {
                guard !Task.isCancelled else { return }
                let batch = Array(requests[start..<min(requests.count, start + 4)])
                await withTaskGroup(of: Void.self) { group in
                    for (url, source) in batch {
                        group.addTask {
                            if await ArtworkCache.shared.image(for: url, pixelSize: pixels) != nil {
                                ArtworkCache.shared.rememberPreview(url, pixelSize: pixels, source: source)
                            }
                        }
                    }
                }
            }
        }
    }

    deinit { task?.cancel() }
}

struct CachedArtwork: View {
    var artwork: Artwork? = nil
    let side: CGFloat
    var official: OfficialCoverQuery? = nil
    @Environment(\.displayScale) private var scale
    // t211u：图片带上来源 key，输入变了旧图立即失效（不会把上一个专辑的封面留在格子里）
    @State private var appleLoaded: (key: String, image: UIImage)?
    @State private var officialLoaded: (key: String, image: UIImage)?
    private var pixels: Int { max(1, Int((side * scale).rounded(.up))) }
    private var appleKey: String? { appleURL.map { ArtworkCache.key(for: $0, pixelSize: pixels) } }
    private var officialKey: String? { official.map { "\($0.id)#pixels=\(pixels)" } }
    private var appleImage: UIImage? { appleLoaded.flatMap { $0.key == appleKey ? $0.image : nil } }
    private var officialImage: UIImage? { officialLoaded.flatMap { $0.key == officialKey ? $0.image : nil } }

    private var appleURL: URL? {
        let px = pixels
        guard let artwork, let u = artwork.url(width: px, height: px),
              u.scheme == "http" || u.scheme == "https" else { return nil }
        return u
    }

    var body: some View {
        // t204u：同步读官方封面内存缓存 → 新建的视图（飞行封面 / 封套 / 标签）第一帧就和格子是同一张图，不会中途交叉淡入成「两个封面」
        let _ = GridScrollProfile.recordUpdate("CachedArtwork")
        let shown = officialImage
            ?? official.flatMap { OfficialCoverStore.shared.cachedImage(for: $0.id, pixelSize: pixels) }
            ?? (appleURL.flatMap { appleImage ?? ArtworkCache.shared.cached(for: $0, pixelSize: pixels) })
            ?? ArtworkCache.shared.preview(for: artwork)
        ZStack {
            if let shown {
                Image(uiImage: shown).resizable().interpolation(.high)
            } else if let artwork {
                // musicKit:// 本地封面或尚在加载：系统视图 / 主题色占位
                if appleURL == nil {
                    ArtworkImage(artwork, width: side, height: side)
                } else {
                    Rectangle().fill(artwork.backgroundColor.map { Color(cgColor: $0) } ?? Color(hex: 0xE4E0DC))
                }
            } else {
                Rectangle().fill(Color(hex: 0xE4E0DC))
            }
        }
        .frame(width: side, height: side)

        .task(id: appleKey) {
            guard let appleURL, let appleKey else { return }
            if let i = await ArtworkCache.shared.image(for: appleURL, pixelSize: pixels), !Task.isCancelled {
                if let source = artwork?.url(width: 1, height: 1)?.absoluteString {
                    ArtworkCache.shared.rememberPreview(appleURL, pixelSize: pixels, source: source)
                }
                appleLoaded = (appleKey, i)
            }
        }
        .task(id: officialKey) {
            guard let official, let officialKey else { return }
            if let cached = OfficialCoverStore.shared.cachedImage(for: official.id, pixelSize: pixels,
                                                                  allowFullSizeFallback: false) {
                officialLoaded = (officialKey, cached); return
            }
            let alreadyShown = OfficialCoverStore.shared.cachedImage(for: official.id) != nil
            if let img = await OfficialCoverStore.shared.image(for: official, pixelSize: pixels), !Task.isCancelled {
                // 首次命中才淡入（之后都同步命中缓存，无动画）
                if alreadyShown { officialLoaded = (officialKey, img) }
                else { withAnimation(.easeInOut(duration: 0.25)) { officialLoaded = (officialKey, img) } }
            }
        }
    }
}

/// t197u：按 MusicKit 专辑 id 查官方封面（MusicBrainz Cover Art Archive，免费无需 key）
struct OfficialCoverQuery: Hashable {
    let id: String
    let title: String
    let artist: String
}

extension MusicCollection {
    var officialQuery: OfficialCoverQuery {
        .init(id: id, title: title, artist: artist)
    }
}

/// MusicBrainz + Cover Art Archive。礼貌限速 ≈1 req/s；结果（命中 URL / 未命中）按 MusicKit id 落盘。
/// Discogs 仅在有 key 时才作后备——当前工程无 key，跳过。
final class OfficialCoverStore: @unchecked Sendable {
    static let shared = OfficialCoverStore()
    private let mapURL: URL
    private let session: URLSession
    private let lock = NSLock()
    private var map: [String: Entry] = [:]
    private var inflight: [String: Task<UIImage?, Never>] = [:]
    private var lastMBRequest = Date.distantPast
    private(set) var stats = (hit: 0, miss: 0, error: 0)

    private struct Entry: Codable {
        var url: String?       // nil = 确认未命中
        var checkedAt: Date
    }

    private init() {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("official-covers", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        mapURL = dir.appendingPathComponent("map.json")
        if let data = try? Data(contentsOf: mapURL),
           let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            map = decoded
        }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpAdditionalHeaders = [
            "User-Agent": "VinylPlayer/1.0 (https://github.com/zhaolegs/vinyl; contact@vinyl.local)",
            "Accept": "application/json"
        ]
        cfg.timeoutIntervalForRequest = 12
        session = URLSession(configuration: cfg)
        // Discogs：无 token 则完全跳过
        if ProcessInfo.processInfo.environment["DISCOGS_TOKEN"] == nil {
            print("[t197u] Discogs skipped (no DISCOGS_TOKEN); MusicBrainz CAA only")
        }
    }

    func cachedImage(for id: String, pixelSize: Int? = nil, allowFullSizeFallback: Bool = true) -> UIImage? {
        lock.lock(); let e = map[id]; lock.unlock()
        guard let u = e?.url, let url = URL(string: u) else { return nil }
        return ArtworkCache.shared.cached(for: url, pixelSize: pixelSize)
            ?? (allowFullSizeFallback ? ArtworkCache.shared.cachedPreview(for: url) : nil)
    }

    func image(for q: OfficialCoverQuery, pixelSize: Int? = nil) async -> UIImage? {
        guard !GridScrollProfile.enabled else { return nil }
        lock.lock()
        if let e = map[q.id] {
            lock.unlock()
            guard let u = e.url, let url = URL(string: u) else { return nil }
            return await ArtworkCache.shared.image(for: url, pixelSize: pixelSize)
        }
        if let t = inflight[q.id] {
            lock.unlock()
            let image = await t.value
            if pixelSize != nil { return await resizedImage(for: q.id, pixelSize: pixelSize) ?? image }
            return image
        }
        let task = Task.detached(priority: .utility) { [self] () -> UIImage? in
            let result = await lookup(q)   // .success(url?) = 确定命中/未命中；.failure = 网络错误，不落盘以便重试
            switch result {
            case .failure:
                lock.lock(); stats.error += 1; let st = stats; lock.unlock()
                print("[t197u] MB temporary failure for \(q.title) (will retry later); err total \(st.error)")
                return nil
            case .success(let url):
                lock.lock()
                map[q.id] = Entry(url: url?.absoluteString, checkedAt: Date())
                if url != nil { stats.hit += 1 } else { stats.miss += 1 }
                let st = stats
                saveLocked()
                lock.unlock()
                if (st.hit + st.miss) == 24 || (st.hit + st.miss) % 40 == 0 {
                    let total = st.hit + st.miss
                    print("[t197u] official covers: \(st.hit)/\(total) matched (\(Int(Double(st.hit)/Double(max(1,total))*100))%), miss \(st.miss), err \(st.error)")
                }
                guard let url else { return nil }
                return await ArtworkCache.shared.image(for: url)
            }
        }
        inflight[q.id] = task
        lock.unlock()
        let img = await task.value
        lock.lock(); inflight[q.id] = nil; lock.unlock()
        if pixelSize != nil { return await resizedImage(for: q.id, pixelSize: pixelSize) ?? img }
        return img
    }

    private func resizedImage(for id: String, pixelSize: Int?) async -> UIImage? {
        let value = lock.withLock { map[id]?.url }
        guard let value, let url = URL(string: value) else { return nil }
        return await ArtworkCache.shared.image(for: url, pixelSize: pixelSize)
    }

    /// 预取首页可见专辑的官方封面（排队，受 MB 限速约束）
    func prefetch(_ items: [OfficialCoverQuery]) {
        guard !GridScrollProfile.enabled else { return }
        for q in items {
            lock.lock(); let known = map[q.id] != nil; lock.unlock()
            if known { continue }
            Task.detached(priority: .utility) { _ = await self.image(for: q) }
        }
    }

    private func saveLocked() {
        if let data = try? JSONEncoder().encode(map) { try? data.write(to: mapURL, options: .atomic) }
    }

    private func throttle() async {
        lock.lock()
        let wait = max(0, 1.05 - Date().timeIntervalSince(lastMBRequest))
        lastMBRequest = Date().addingTimeInterval(wait)
        lock.unlock()
        if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
    }

    private func lookup(_ q: OfficialCoverQuery) async -> Result<URL?, Error> {
        // 歌单 / 资料库歌曲集合不适合按「专辑+艺人」查
        if q.id.hasPrefix("playlist-") || q.id.hasPrefix("library-songs") { return .success(nil) }
        await throttle()
        let title = sanitize(q.title)
        let artist = sanitize(q.artist)
        guard !title.isEmpty, !artist.isEmpty else { return .success(nil) }
        do {
            let (data, resp) = try await mbSearch(title: title, artist: artist)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200, let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let groups = json["release-groups"] as? [[String: Any]], !groups.isEmpty else {
                if code == 503 || code == 429 { return .failure(URLError(.badServerResponse)) }
                return .success(nil)
            }
            // 取最高分。同名多版本（Deluxe / nightcore 等）仍用最高分主版本；
            // 仅当第二名分数接近（差 < 5）且标题规范化后不同 → 视为歧义
            let scored: [(String, Int, String)] = groups.compactMap { g in
                guard let id = g["id"] as? String else { return nil }
                let score = g["score"] as? Int ?? 0
                let name = (g["title"] as? String) ?? ""
                return (id, score, name)
            }.sorted { $0.1 > $1.1 }
            guard let best = scored.first, best.1 >= 85 else { return .success(nil) }
            if let second = scored.dropFirst().first,
               second.1 >= 85,
               best.1 - second.1 < 5,
               sanitize(best.2).caseInsensitiveCompare(sanitize(second.2)) != .orderedSame {
                return .success(nil)
            }
            // Cover Art Archive：先试 front-500；404 再读 JSON 取任意 front
            if let url = await coverURL(releaseGroup: best.0) { return .success(url) }
            return .success(nil)
        } catch {
            print("[t197u] MB lookup failed for \(q.title): \(error)")
            return .failure(error)
        }
    }



    private func mbSearch(title: String, artist: String) async throws -> (Data, URLResponse) {
        func run(_ query: String) async throws -> (Data, URLResponse) {
            await throttle()
            var comps = URLComponents(string: "https://musicbrainz.org/ws/2/release-group/")!
            comps.queryItems = [
                .init(name: "query", value: query),
                .init(name: "fmt", value: "json"),
                .init(name: "limit", value: "5")
            ]
            return try await session.data(from: comps.url!)
        }
        // 先精确，再宽松（无引号）
        let strict = try await run("releasegroup:\"\(title)\" AND artist:\"\(artist)\"")
        let code = (strict.1 as? HTTPURLResponse)?.statusCode ?? 0
        if code == 200,
           let json = try? JSONSerialization.jsonObject(with: strict.0) as? [String: Any],
           let groups = json["release-groups"] as? [[String: Any]], !groups.isEmpty {
            return strict
        }
        return try await run("releasegroup:\(title) AND artist:\(artist)")
    }

    private func coverURL(releaseGroup mbid: String) async -> URL? {
        await throttle()
        if let front = URL(string: "https://coverartarchive.org/release-group/\(mbid)/front-500") {
            var req = URLRequest(url: front); req.httpMethod = "HEAD"
            if let (_, head) = try? await session.data(for: req) {
                let hc = (head as? HTTPURLResponse)?.statusCode ?? 0
                if (200..<400).contains(hc) { return front }
            }
        }
        // 无 front-500 时读清单，挑第一张 front（或第一张图）
        guard let listURL = URL(string: "https://coverartarchive.org/release-group/\(mbid)") else { return nil }
        await throttle()
        guard let (data, resp) = try? await session.data(from: listURL),
              ((resp as? HTTPURLResponse)?.statusCode ?? 0) == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let images = json["images"] as? [[String: Any]] else { return nil }
        let front = images.first(where: { ($0["front"] as? Bool) == true }) ?? images.first
        if let thumbs = front?["thumbnails"] as? [String: Any] {
            for key in ["500", "large", "250"] {
                if let s = thumbs[key] as? String, let u = URL(string: s) { return u }
            }
        }
        if let s = front?["image"] as? String, let u = URL(string: s) { return u }
        return nil
    }

    private func sanitize(_ s: String) -> String {
        // 去掉括号附注、特征符号，便于 MB 匹配
        var t = s
        if let r = t.range(of: #"\s*[\(\[（].*[\)\]）]"#, options: .regularExpression) {
            t.removeSubrange(r)
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
            .filter { $0 != "\"" }
    }
}
