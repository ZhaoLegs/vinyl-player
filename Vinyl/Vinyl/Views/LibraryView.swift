import SwiftUI
import UIKit
import CoreImage
import MusicKit

/// 上报被点击封面在 "library" 坐标空间中的 frame，作为 zoom 转场起点。
struct CoverFrameKey: PreferenceKey {
    static var defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

struct LibraryView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale
    @Environment(\.openURL) private var openURL
    @EnvironmentObject private var music: AppleMusicStore
    @State private var showingSearch = false
    @State private var showingSettings = false
    /// t125u：转场状态放在共享模型里 —— Tab 里的实例画首页，ContentView 叠在 TabView 之上的实例画详情层
    @EnvironmentObject private var zm: LibraryZoomModel
    var overlayMode = false
    /// 被点开的真实 Apple Music 集合；nil = 演示封面
    private var selectedCollection: MusicCollection? { get { zm.selectedCollection } nonmutating set { zm.selectedCollection = newValue } }
    private var collectionSongs: [Song]? { get { zm.collectionSongs } nonmutating set { zm.collectionSongs = newValue } }
    private var presented: Bool { get { zm.presented } nonmutating set { zm.presented = newValue } }
    /// 翻面三段动画进行中：期间忽略点击，避免叠加
    private var flipBusy: Bool { get { zm.flipBusy } nonmutating set { zm.flipBusy = newValue } }
    private var closing: Bool { get { zm.closing } nonmutating set { zm.closing = newValue } }
    private var autoplay: Bool { get { zm.autoplay } nonmutating set { zm.autoplay = newValue } }
    private var zoom: CGFloat { get { zm.zoom } nonmutating set { zm.zoom = newValue } }
    private var contentAlpha: Double { get { zm.contentAlpha } nonmutating set { zm.contentAlpha = newValue } }
    private var blurRadius: CGFloat { get { zm.blurRadius } nonmutating set { zm.blurRadius = newValue } }
    /// 首页网格变暗程度（打开时随封面一起到 1；关闭时瞬间归 0，由详情背景的自上而下擦除露出清晰网格）
    private var gridDim: CGFloat { get { zm.gridDim } nonmutating set { zm.gridDim = newValue } }
    /// 关闭时详情模糊背景的自上而下擦除进度：0 = 全覆盖，1 = 全部消失
    private var wipe: CGFloat { get { zm.wipe } nonmutating set { zm.wipe = newValue } }
    // t144u：几何类代理相同值不写回（@Published 无论值是否相等都会发 objectWillChange，导致两棵视图树整树失效）
    private var origin: CGRect { get { zm.origin } nonmutating set { if zm.origin != newValue { zm.origin = newValue } } }
    private var sleeveFrame: CGRect { get { zm.sleeveFrame } nonmutating set { if zm.sleeveFrame != newValue { zm.sleeveFrame = newValue } } }
    private var cellFrames: [Int: CGRect] {
        get { zm.gridGeometry.cellFrames }
        nonmutating set { zm.gridGeometry.cellFrames = newValue }
    }
    private var selectedIndex: Int { get { zm.selectedIndex } nonmutating set { zm.selectedIndex = newValue } }

    private var pull: CGFloat { get { zm.pull } nonmutating set { zm.pull = newValue } }
    private var flip: Double { get { zm.flip } nonmutating set { zm.flip = newValue } }
    private var lyricsMode: Bool { get { zm.lyricsMode } nonmutating set { zm.lyricsMode = newValue } }
    private var demoToken: Int { get { zm.demoToken } nonmutating set { zm.demoToken = newValue } }
    private var motionStart: Date { get { zm.motionStart } nonmutating set { zm.motionStart = newValue } }
    private var recordingStarted: Bool { get { zm.recordingStarted } nonmutating set { zm.recordingStarted = newValue } }
    private var recordingRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("--record-demo")
    }

    // 网格几何按原片实测：4 列、列宽 72pt、间距 17pt、左右 27pt
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 18), count: 4)
    @State private var artworkPrefetcher = GridArtworkPrefetcher()

    var body: some View {
        let _ = GridScrollProfile.recordUpdate(overlayMode ? "LibraryView.overlay" : "LibraryView.home")
        if overlayMode {
            detailLayer
                .onPreferenceChange(SleeveFrameKey.self) { sleeveFrame = $0 }
                // t223u：在详情里点了某首歌 / 播放键 → 这张专辑才成为「正在播放」的专辑（mini player 打开 / 封面来源随之更新）
                .onChange(of: music.currentSongID) { _, _ in
                    guard presented, let c = selectedCollection, let songs = collectionSongs,
                          songs.contains(where: { music.isCurrent($0) }) else { return }
                    nowPlayingCollection = c
                }
                .allowsHitTesting(presented)
        } else {
            homeBody
                // t196u：原生搜索 sheet（.searchable）
                .sheet(isPresented: Binding(get: { Features.searchEnabled && showingSearch },
                                            set: { showingSearch = $0 })) {
                    LibrarySearchSheet(
                        onOpen: { c in
                            showingSearch = false
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                openCollection(c, startPlayback: false)
                            }
                        },
                        onPlay: { song, list, fromCatalog in
                            showingSearch = false
                            Task { await music.play(song, in: list, fromCatalog: fromCatalog) }
                        }
                    )
                    .environmentObject(music)
                    .presentationDetents([.large])
                }
                // t184u：懒加载首页第一个专辑的曲目（给默认 mini player 用）
                .task(id: music.collections.first?.id) {
                    guard !GridScrollProfile.enabled else { return }
                    guard let c = music.collections.first, !music.hasCurrentTrack else { return }
                    let songs = (try? await c.songs()) ?? []
                    suggestID = c.id; suggestSongs = songs
                }
                // t222u：诊断 —— --debug-mini-cycle：启动 3s 后模拟点 mini player 打开详情，4s 后关闭（录屏取帧用）
                .task {
                    guard ProcessInfo.processInfo.arguments.contains("--debug-mini-cycle") else { return }
                    if ProcessInfo.processInfo.arguments.contains("--debug-mini-paused") {
                        try? await Task.sleep(for: .seconds(1))
                        music.selectDemo(music.demoTrack)
                        try? await Task.sleep(for: .seconds(2))
                    } else {
                        try? await Task.sleep(for: .seconds(3))
                    }
                    print("[t222u] mini open, disc frame \(zm.miniDiscFrame)")
                    print("[mini-flight] label=\(zm.miniLabelFrame), angle=\(zm.miniPhase.presentedAngle)")
                    if ProcessInfo.processInfo.arguments.contains("--debug-mini-tile") {
                        origin = cellFrames[AlbumData.featuredIndex] ?? origin
                        targetKey = AlbumData.featuredIndex
                        selectedIndex = AlbumData.featuredIndex
                        open()
                    } else {
                        openNowPlaying()
                    }
                    try? await Task.sleep(for: .seconds(4))
                    print("[t222u] close → \(zm.openFromMini ? "mini" : "tile")")
                    close()
                }
                .onChange(of: zm.miniOwner) { _, owner in
                    guard ProcessInfo.processInfo.arguments.contains("--debug-mini-cycle") else { return }
                    print("[mini-owner] time=\(Date().timeIntervalSince1970) owner=\(owner)")
                }
                // t219u：诊断 —— --debug-open=<标题片段> 启动参数：首页加载后直接打开匹配的专辑 / 歌单（不播放），用于设备截图量间距
                .task(id: music.homePageRevision) {
                    guard let arg = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--debug-open=") }),
                          !presented else { return }
                    let q = String(arg.dropFirst("--debug-open=".count)).lowercased()
                    print("[t221u] home titles: " + music.collections.map(\.title).joined(separator: " | "))
                    guard let i = music.collections.firstIndex(where: { $0.title.lowercased().contains(q) }) else { return }
                    try? await Task.sleep(for: .seconds(1))
                    // t287u: this task re-runs when playback bumps homePageRevision, and a cancelled `try? sleep`
                    // falls straight through — fire the diagnostic open only once (it used to open + flip twice)
                    guard !DebugOnce.opened else { return }
                    DebugOnce.opened = true
                    origin = cellFrames[1000 + i] ?? origin
                    targetKey = 1000 + i
                    // t240u：--debug-play 时打开即播放（截播放态歌词）；默认不播放
                    let debugPlay = ProcessInfo.processInfo.arguments.contains("--debug-play")
                    LyricsTrace.mark("debug-open \(music.collections[i].title)")
                    openCollection(music.collections[i], startPlayback: debugPlay)
                    // t231u：诊断 —— 加 --debug-lyrics 时落定后翻到歌词页（截图顶部过渡用）
                    // 不随 .task 取消（开始播放会刷新 homePageRevision → 本 task 被取消重跑）
                    if ProcessInfo.processInfo.arguments.contains("--debug-lyrics") { Task { @MainActor in
                        try? await Task.sleep(for: .seconds(2.5))
                        toggleArtwork()
                        // t287u: --debug-lyrics-bench — 8s later, time lookups for tracks 2–4 one by one (what a track switch waits for)
                        if ProcessInfo.processInfo.arguments.contains("--debug-lyrics-bench"),
                           let songs = try? await music.collections[i].songs() {
                            try? await Task.sleep(for: .seconds(8))
                            for s in songs.dropFirst().prefix(3) {
                                let t = CFAbsoluteTimeGetCurrent()
                                let r = try? await LyricsStore.shared.lyrics(title: s.title, artist: s.artistName,
                                                                            album: s.albumTitle, duration: s.duration)
                                print("[t287] BENCH \(s.title): \(LyricsTrace.ms(since: t))ms → \(r.map(LyricsTrace.kind) ?? "FAILED")")
                            }
                        }
                        if debugPlay {
                            try? await Task.sleep(for: .seconds(2))
                            if music.duration > 60 { music.seek(to: 50) }
                        }
                    } }
                }
                // t197u：首页可见 + 随后几行预取 MusicBrainz 官方封面（限速，不挡 UI）
                .task(id: music.homePageRevision) {
                    let qs = music.collections.prefix(32).map(\.officialQuery)
                    OfficialCoverStore.shared.prefetch(Array(qs))
                }
                // t169u：开始播放一首歌 → 预取它 + 队列里接下来 2 首的歌词
                // t295u: --debug-lyrics-hitrate — cold lookups (temp cache dir) for ~20 songs across home albums / playlists,
                // one line per song with the outcome; miss reasons come from the [t295] lines in the repository
                .task(id: music.homePageRevision) {
                    guard ProcessInfo.processInfo.arguments.contains("--debug-lyrics-hitrate"),
                          !music.collections.isEmpty, !DebugOnce.hitrate else { return }
                    DebugOnce.hitrate = true
                    // unstructured: a homePageRevision bump must not cancel the run halfway
                    Task { @MainActor in
                    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lyrics-hitrate-\(UUID())")
                    var picked: [(Song, MusicCollection)] = []
                    // one track (the middle one) from each of the first 20 home collections: playlists + library albums
                    for c in music.collections.prefix(30) where picked.count < 20 {
                        guard let songs = try? await c.songs(), !songs.isEmpty else { continue }
                        picked.append((songs[songs.count / 2], c))
                    }
                    for legacy in [true, false] {
                    LyricsTrace.legacy = legacy
                    let mode = legacy ? "BEFORE(b180 matching)" : "AFTER"
                    let repo = LyricsRepository(directory: dir.appendingPathComponent(mode))
                    var hits = 0, synced = 0
                    let t0 = CFAbsoluteTimeGetCurrent()
                    for (n, pair) in picked.enumerated() {
                        let (s, c) = pair
                        let q = LyricsQuery(title: s.title, artist: s.artistName, album: s.albumTitle, duration: s.duration)
                        let t = CFAbsoluteTimeGetCurrent()
                        do {
                            let f = try await repo.load(q)
                            let kind = LyricsTrace.kind(f.result)
                            if f.isFound { hits += 1 }
                            if case .synced = f.result { synced += 1 }
                            print("[t295] \(legacy ? "B" : "A")#\(n + 1) \(f.isFound ? "HIT " : "MISS") \(s.title) — \(s.artistName) [\(Int(s.duration ?? 0))s, \(c.isCatalog ? "catalog" : "library") \(c.title)] → \(kind) via \(f.source) in \(LyricsTrace.ms(since: t))ms")
                        } catch {
                            print("[t295] \(legacy ? "B" : "A")#\(n + 1) FAIL \(s.title) — \(s.artistName) [\(Int(s.duration ?? 0))s, \(c.title)] → error \(error.localizedDescription) in \(LyricsTrace.ms(since: t))ms")
                        }
                    }
                    print("[t295] RESULT \(mode) \(hits)/\(picked.count) found (\(synced) synced) in \(LyricsTrace.ms(since: t0))ms")
                    }
                    LyricsTrace.legacy = false
                    try? FileManager.default.removeItem(at: dir)
                    }
                }
                // 调试参数 --log-themes：打印前 8 个首页专辑的主题色选取 + 预取第一张专辑歌词（不改界面）
                .task(id: music.homePageRevision) {
                    guard ProcessInfo.processInfo.arguments.contains("--log-themes"), !music.collections.isEmpty else { return }
                    for c in music.collections.prefix(8) {
                        let r = c.artwork.map(ThemeColor.fromArtwork) ?? (nil, "no-artwork")
                        print("[t172u] \(c.title) — \(c.artist): \(r.1) \(r.0?.hex ?? "default black")")
                    }
                    for c in music.collections.prefix(10) {
                        do { let songs = try await c.songs(); print("[t181u] \(c.title): \(songs.count) songs, catalog=\(c.isCatalog)") }
                        catch { print("[t181u] \(c.title): FAILED \(error)") }
                    }
                    if let c = music.collections.first, let songs = try? await c.songs() {
                        LyricsStore.shared.prefetch(songs, reason: "debug album \(c.title)")
                    }
                }
                .task(id: music.currentSongID) {
                    guard music.currentSongID != nil else { return }
                    let entries = Array(ApplicationMusicPlayer.shared.queue.entries)
                    let cur = ApplicationMusicPlayer.shared.queue.currentEntry
                    let i = entries.firstIndex(where: { $0.id == cur?.id }) ?? 0
                    let songs = entries.dropFirst(i).prefix(3).compactMap { e -> Song? in
                        if case .song(let s) = e.item { return s } else { return nil }
                    }
                    LyricsStore.shared.prefetch(songs, reason: "queue")
                }
        }
    }

    private var homeBody: some View {
        GeometryReader { _ in
            ZStack(alignment: .topLeading) {
                AuroraBackground()
                homeContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .opacity(Double(1 - 0.72 * gridDim))

            }
            .overlay(alignment: .top) {
                if let curveLabel {
                    Text(curveLabel)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(.black.opacity(0.75), in: Capsule())
                        .padding(.top, 60)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
            }
            .coordinateSpace(name: "library")
            .background {
                if GridScrollProfile.enabled { GridScrollProbe(music: music) }
            }
            .onPreferenceChange(CoverFrameKey.self) { frames in
                cellFrames = frames
                // 关闭飞行期间用户滚动首页：目标格子的实时 frame 每帧更新到 origin，
                // CoverFlight 用当前弹簧进度向这个实时 frame 插值，落点永远在格子上。
                if closing, !zm.openFromMini, let key = targetKey, let live = frames[key] { origin = live }
            }
            .task(id: demoToken) {
                await runDemo()
            }
            .task {
                guard recordingRequested && !recordingStarted else { return }
                recordingStarted = true
                let requiredImages = (1...AlbumData.coverCount).map(DS.coverName)
                    + ["planet", "planet_back", "small_art", "sleeve_cutout"]
                let missing = requiredImages.filter { UIImage(named: $0) == nil }
                guard missing.isEmpty else {
                    recordingMarker("failed: missing images: " + missing.joined(separator: ", "))
                    return
                }
                // Give the scene time to report actual cover and sleeve geometry.
                do { try await Task.sleep(nanoseconds: 1_500_000_000) }
                catch { return }
                guard let measuredOrigin = cellFrames[AlbumData.featuredIndex],
                      sleeveFrame != .zero, !reduceMotion else {
                    recordingMarker("failed")
                    return
                }
                origin = measuredOrigin
                selectedIndex = AlbumData.featuredIndex; targetKey = AlbumData.featuredIndex
                recordingMarker("started")
                open()
            }
        }
    }

    // MARK: - 首页

    private var homeContent: some View {
        libraryScroller
    }

    /// 左右上角：一个圆形玻璃底 + 一个 SF Symbol，全部由系统按钮样式绘制
    private var header: some View {
        HStack {
            // Assets logo mark inside system glass circle (not SF Symbol opticaldisc).
            // 左上 logo：未连接时 = 连接 Apple Music 的入口（被拒绝时打开系统设置）
            // t107u：参考视频左上角字形 = SF Symbol square.3.layers.3d.down.right（用户 t111u 选定）（原生 toolbar 尺寸）
            // t196u：左上角叠层按钮 — 点按仍连接 / 标识；长按菜单 = 刷新资料库 + 显示已隐藏
            GlassCircleButton(systemImage: "square.3.layers.3d.down.right",
                              accessibilityText: music.authorized ? "Vinyl" : "连接 Apple Music") {
                connectMusic()
            }
            .contextMenu {
                Button("刷新资料库", systemImage: "arrow.clockwise") {
                    if music.authorized { Task { await music.refreshHome() } }
                    else { connectMusic() }
                }
                if music.hiddenCount > 0 {
                    Button("显示已隐藏的 \(music.hiddenCount) 项", systemImage: "eye") {
                        withAnimation(.spring(duration: 0.4, bounce: 0)) { music.unhideAll() }
                    }
                }
            }
            Spacer(minLength: 0)
            // t196u：右上角 = 搜索（同款玻璃圆按钮）；原 cube 刷新入口移到左上长按
            // t216u：搜索先隐藏（Features.searchEnabled）；右上角留空，不恢复 cube
            if Features.searchEnabled {
                GlassCircleButton(systemImage: "magnifyingglass", accessibilityText: "搜索") {
                    if music.authorized { showingSearch = true }
                    else { connectMusic() }
                }
            }
            // t292u：右上角 = 设置（同款玻璃圆按钮）
            GlassCircleButton(systemImage: "gearshape", accessibilityText: "设置") { showingSettings = true }
                .sheet(isPresented: $showingSettings) {
                    SettingsSheet()
                        .environmentObject(music)
                        .environmentObject(music.sleep)
                        .presentationDetents([.medium, .large])
                }
        }
        // t217u：顶部居中显示软件名（CFBundleDisplayName，未设置则 "Vinyl"），与左右按钮垂直居中；
        // 详情打开 / 转场期间隐藏，不会透到详情页
        .overlay {
            Text(Self.appName)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                // t270u: always present at full opacity (no hide on open / pop-in after the blur on close)
                .allowsHitTesting(false)
                .accessibilityAddTraits(.isHeader)
        }
        .padding(.horizontal, DS.contentInset)
        .padding(.top, 6)
    }
    private static let appName: String = {
        let n = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
        return (n?.isEmpty == false) ? n! : "Vinyl"
    }()

    /// Both bars belong to the scroll view, so the system can soften both edges.
    @ViewBuilder
    private var libraryScroller: some View {
        if #available(iOS 26.0, *) {
            gridScroll
                // 原生 scroll edge effect：.soft = 渐进模糊，随内容接近边缘逐渐增强
                .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
                .safeAreaBar(edge: .top, spacing: 0) {
                    header
                        .padding(.bottom, 6)
                }
                // safeAreaBar 会把 mini player 贴到底部安全区，并**自动把滚动边缘效果延伸到它**，
                // 所以不需要再手写 LinearGradient mask。
                .safeAreaBar(edge: .bottom, spacing: 0) {
                    VStack(spacing: 10) {
                    // t293u：未授权 / 无订阅时的 Apple Music 卡片
                    AppleMusicCard()
                        .padding(.horizontal, DS.tabBarSideInset)
                    // t158u：没有真实正在播放的曲目时不显示假的 mini player
                    if showMini {
                        MiniPlayer(open: openNowPlaying, suggestion: miniSuggestion,
                                   hideDisc: presented && !zm.flyToTile,
                                   onDiscFrame: { zm.miniDiscFrame = $0 },
                                   onLabelFrame: { if zm.miniLabelFrame != $0 { zm.miniLabelFrame = $0 } },
                                   coverArtwork: miniCover.0, coverOfficial: miniCover.1)
                            .padding(.horizontal, DS.tabBarSideInset)
                            .padding(.bottom, DS.miniPlayerBottomPadding)
                            .transition(.opacity)
                    }
                    }
                }
        } else {
            // iOS 17–25 没有该 API：退回渐变遮罩（纯外观降级）。
            // 需要真模糊时接 VariableBlur / Variablur，见 README「底部渐变模糊」一节。
            VStack(spacing: 0) {
                header
                gridScroll
                    .mask(
                        LinearGradient(stops: [
                            .init(color: .black, location: 0),
                            .init(color: .black, location: 0.86),
                            .init(color: .clear, location: 1)
                        ], startPoint: .top, endPoint: .bottom)
                    )
                AppleMusicCard().padding(.horizontal, 16).padding(.bottom, 8)
                if showMini {
                    MiniPlayer(open: openNowPlaying, suggestion: miniSuggestion,
                               hideDisc: presented && !zm.flyToTile,
                               onDiscFrame: { zm.miniDiscFrame = $0 },
                               onLabelFrame: { if zm.miniLabelFrame != $0 { zm.miniLabelFrame = $0 } },
                               coverArtwork: miniCover.0, coverOfficial: miniCover.1)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 10)
                }
            }
        }
    }

    private var gridScroll: some View {
        ScrollViewReader { proxy in
        ScrollView(showsIndicators: false) {
            LazyVStack(spacing: 0) {
            LazyVGrid(columns: columns, spacing: 18) {
                let real = music.collections
                if real.isEmpty && DemoMode.enabled {
                    // t158u：内置演示封面只在 --record-demo（模拟器录屏）里出现
                    ForEach(1...AlbumData.coverCount, id: \.self) { index in
                        coverCell(index).id(index)
                    }
                } else if real.isEmpty {
                    // t158u：真实数据到达前 = 同网格的浅色圆角占位（无文字）；授权被拒 / 加载失败另见 homeEmptyNotice
                    if homeNotice == nil {
                        ForEach(0..<HomePlaceholder.count, id: \.self) { i in
                            HomePlaceholder().id(-1 - i)
                        }
                        .transition(.opacity)
                    }
                } else {
                    ForEach(Array(real.enumerated()), id: \.element.id) { index, collection in
                        // t211u：视图身份 = 集合 id（原来 .id(1000 + index) 按位置复用视图：
                        // 隐藏一个后，该位置的格子继承了被隐藏专辑的 @State 封面图，看起来「没隐藏」）
                        musicCell(index, collection)
                            .id(collection.id)
                            .transition(.scale(scale: 0.85).combined(with: .opacity))
                    }
                }
            }
            .padding(.horizontal, DS.contentInset)
            // t322u: the push blur, one layer for the whole grid (driven by pushAway on the push springs)
            .blur(radius: TilePushAway.layerBlur && zm.pushAway && zm.pushAnchor != nil ? TilePushAway.blurRadius : 0)
            .background { if PushFPS.on { PushFPSProbe(active: zm.pushAway) } }
            .padding(.top, 12)
            .padding(.bottom, 8)
            // t158u：真实封面 0.25s 淡入替换占位
            .animation(.easeOut(duration: 0.25), value: music.collections.isEmpty)
            if let notice = homeNotice, music.collections.isEmpty, !DemoMode.enabled {
                Text(notice)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                    .padding(.top, 160)
                    .transition(.opacity)
            }
            if music.hasMoreHome, !music.collections.isEmpty {
                // 即使下一页只有重复封面或更多歌曲，也能继续推进；打开详情时暂停分页。
                Color.clear
                    .frame(height: 1)
                    .task(id: "\(music.homePageRevision)-\(presented)") {
                        guard !presented else { return }
                        await music.loadMoreHome()
                    }
            }
            }
        }
        .onChange(of: scrollRequest) { _, key in
            guard let key else { return }
            // t211u：真实格子的滚动 id = 集合 id（key 仍是 1000 + 位置）
            if key >= 1000, music.collections.indices.contains(key - 1000) {
                proxy.scrollTo(music.collections[key - 1000].id, anchor: .center)
            } else {
                proxy.scrollTo(key, anchor: .center)
            }
        }
        }
        // t145u：恢复 build 134 的高斯模糊外观（打开时均匀淡入；关闭时由详情背景自上而下羽化擦除）
        .blur(radius: blurRadius)
        // t146u：详情打开 / 飞行期间首页网格不可滚动、不接收触摸
        .scrollDisabled(presented)
        .allowsHitTesting(!presented)
        // t138u：原片关闭时网格整体从 0.955 放大回 1（打开时缩到 0.955），与飞行封面同一进度驱动。
        // 用 visualEffect（纯渲染变换，不影响布局 / 不改格子测得的 frame）。
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { gridFrame = $0 }
        // t210u：去掉网格整体缩放（open 0.95 / close 0.943→1）——网格在封面飞入飞出时始终保持 1.0 静止
    }

    /// t184u：真实资料加载完成后 mini player 常驻；占位阶段（还没有真实数据）隐藏
    private var showMini: Bool { music.hasCurrentTrack || DemoMode.enabled || !music.collections.isEmpty }
    @State private var suggestSongs: [Song]? = nil
    @State private var suggestID: String? = nil
    /// 没播过任何歌：默认显示首页第一个专辑（封面 + 第一首歌名 + 艺人 · 时长，暂停态）；歌曲未读到前先显示专辑名 / 艺人
    private var miniSuggestion: MiniSuggestion? {
        guard let c = music.collections.first else { return nil }
        let songs = suggestID == c.id ? suggestSongs : nil
        let first = songs?.first
        return MiniSuggestion(key: c.id + (first?.id.rawValue ?? ""),
                              title: first?.title ?? c.title,
                              artist: first?.artistName ?? c.artist,
                              duration: first?.duration ?? 0,
                              artwork: c.artwork,
                              play: { i in
                                  Task { @MainActor in
                                      var list = songs ?? []
                                      if list.isEmpty { list = (try? await c.songs()) ?? [] }
                                      guard !list.isEmpty else { return }
                                      nowPlayingCollection = c
                                      await music.play(list[min(i, list.count - 1)], in: list, fromCatalog: c.isCatalog)
                                  }
                              })
    }

    /// t158u：首页无内容时的简短中文提示（nil = 仍在加载，显示占位格）
    private var homeNotice: String? {
        switch music.authorization {
        case .denied: return "未获得 Apple Music 访问权限\n点左上角按钮前往设置开启"
        case .restricted: return "此设备限制了 Apple Music 访问"
        default: break
        }
        guard music.authorized, music.homeLoadedOnce, !music.isLoading else { return nil }
        return music.errorMessage != nil ? "资料库加载失败\n点右上角按钮重试" : "资料库里还没有内容"
    }

    /// 屏幕锚点换算成网格自身坐标系的 UnitPoint
    private var gridAnchorUnit: UnitPoint {
        let a = FlightCurves.gridAnchor
        let screen = UIScreen.main.bounds.size
        guard gridFrame.width > 1, gridFrame.height > 1 else { return UnitPoint(x: a.x, y: a.y) }
        return UnitPoint(x: (a.x * screen.width - gridFrame.minX) / gridFrame.width,
                         y: (a.y * screen.height - gridFrame.minY) / gridFrame.height)
    }

    /// 真实 Apple Music 封面格：与演示封面同尺寸、同圆角、同投影。
    private var nowPlayingCollection: MusicCollection? { get { zm.nowPlayingCollection } nonmutating set { zm.nowPlayingCollection = newValue } }

    private func musicCell(_ index: Int, _ collection: MusicCollection) -> some View {
        let key = 1000 + index
        return Button {
            origin = cellFrames[key] ?? origin
            targetKey = key
            openCollection(collection)
        } label: {
            ArtworkFill(artwork: collection.artwork, official: collection.officialQuery, useDisplaySize: true)
                .clipShape(RoundedRectangle(cornerRadius: DS.corner))
                .shadow(color: .black.opacity(0.18), radius: 8, x: 0, y: 4)
                .background {
                    GeometryReader { geo in
                        Color.clear.preference(key: CoverFrameKey.self,
                                               value: [key: geo.frame(in: .global)])
                    }
                }
        }
        .buttonStyle(.plain)
        // 转场期间源格子隐藏：屏幕上始终只有一个封面
        .modifier(TileReveal(progress: zoom, isTarget: presented && zm.flyToTile && selectedCollection?.id == collection.id,
                             closing: closing))
        .modifier(TilePushAway(zm: zm, key: key))
        .accessibilityLabel("\(collection.title)，\(collection.artist)")
        .onAppear {
            let side = max(1, (gridFrame.width - 2 * DS.contentInset - 3 * 18) / 4)
            artworkPrefetcher.update(music.collections, around: index, side: side, scale: displayScale)
        }
        // t192u：长按 = 系统原生上下文菜单（抬起预览 + 玻璃材质由系统渲染）；点按仍是 Button 打开详情，滚动不受影响
        .contextMenu {
            collectionMenu(collection).menuItemDefaults()
        } preview: {
            ArtworkFill(artwork: collection.artwork, official: collection.officialQuery)
                .frame(width: 280, height: 280)
                .clipShape(RoundedRectangle(cornerRadius: DS.corner * 280 / 76.5))
        }
    }

    // 长按菜单：喜欢 / 共享 → 随机播放 → 前往艺人 → 从首页隐藏。
    @ViewBuilder
    private func collectionMenu(_ c: MusicCollection) -> some View {
        MenuTopBar(liked: music.isLoved(c),
                   shareURL: c.shareURL,
                   like: { Task { await music.toggleLove(c) } })
        Section {
            Button("随机播放", systemImage: "shuffle") { Task { await music.playCollection(c, shuffle: true) } }
        }
        if let url = c.artistURL {
            Section {
                // 工程里没有歌手页 → 在 Apple Music 中打开歌手（副标题 = 艺人名）
                Button { openURL(url) } label: {
                    Label { Text("前往艺人"); Text(c.artist) } icon: { Image(systemName: "music.microphone") }
                }
            }
        }
        Section {
            Button("从首页隐藏", systemImage: "eye.slash", role: .destructive) {
                withAnimation(.spring(duration: 0.4, bounce: 0)) { music.hideFromHome(c) }
            }
        }
    }

    /// 点开真实集合：沿用同一套放大转场 + 唱片自动滑出，同时读取曲目并从第一首可播放的歌开始播。
    private func openCollection(_ collection: MusicCollection, startPlayback: Bool = true) {
        selectedCollection = collection
        // t223u：只有真的开始播放这张时才记为 nowPlayingCollection（打开但不播放 ≠ 正在播放）
        let startPlayback = startPlayback && shouldAutoplay(collection)
        collectionSongs = TrackPrefetch.shared.cached(collection)   // t330u
        open()
        prefetchNeighbours()
        Task {
            do {
                if let cached = TrackPrefetch.shared.cached(collection) {
                    if startPlayback, let first = cached.first(where: { $0.playParameters != nil }) {
                        nowPlayingCollection = collection
                        await music.play(first, in: cached, fromCatalog: collection.isCatalog)
                    }
                    return
                }
                let songs = try await collection.songs()
                guard selectedCollection?.id == collection.id else { return }
                collectionSongs = songs
                upgradeToCatalogTracks(collection, shown: songs)
                if startPlayback, let first = songs.first(where: { $0.playParameters != nil }) {
                    nowPlayingCollection = collection
                    await music.play(first, in: songs, fromCatalog: collection.isCatalog)
                }
            } catch {
                guard selectedCollection?.id == collection.id else { return }
                collectionSongs = []
                music.errorMessage = "读取曲目失败：\(error.localizedDescription)"
            }
        }
    }

    /// 迷你播放条点击：打开正在播放的专辑（不重新开始播放）；演示模式打开演示专辑。
    private func openNowPlaying() {
        guard !presented else { return }
        // t222u：从 mini player 打开 → 封面从 mini 唱片位置放大，关闭时缩回 mini 唱片；格子保持可见、不滚动网格
        let fromMini = zm.miniLabelFrame != .zero
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            zm.openFromMini = fromMini
            zm.flyToTile = !fromMini
            if fromMini {
                zm.miniArtwork = zm.miniArtwork ?? zm.miniRenderedArtwork
                    ?? MiniArtworkSnapshot(coverName: music.demoCoverName, artwork: miniCover.0,
                                           official: miniCover.1, scale: displayScale)
                zm.miniAngle = zm.miniPhase.hold()
                zm.detailDiscAngle = 0
                zm.miniOwner = .flight
                if ProcessInfo.processInfo.arguments.contains("--debug-mini-cycle") {
                    renderMiniEndpoints()
                }
            }
        }
        if !music.hasCurrentTrack, !DemoMode.enabled, let c = music.collections.first {
            // t184u：默认条目 → 打开首页第一个专辑（不自动开始播放）
            origin = fromMini ? zm.miniLabelFrame : (cellFrames[1000] ?? origin)
            targetKey = 1000
            openCollection(c, startPlayback: false)
            return
        }
        if music.hasCurrentTrack, let collection = nowPlayingCollection {
            let i = music.collections.firstIndex { $0.id == collection.id }
            origin = fromMini ? zm.miniLabelFrame : (i.flatMap { cellFrames[1000 + $0] } ?? origin)
            targetKey = i.map { 1000 + $0 }
            openCollection(collection, startPlayback: false)
        } else {
            let index = AlbumData.featuredIndex
            origin = fromMini ? zm.miniLabelFrame : (cellFrames[index] ?? origin)
            targetKey = index
            selectedIndex = index
            selectedCollection = nil
            collectionSongs = nil
            open()
        }
    }

    private func connectMusic() {
        switch music.authorization {
        case .denied, .restricted:
            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
        case .authorized:
            Task { await music.refreshHome() }
        default:
            Task { await music.connect() }
        }
    }

    /// 诊断附加证据：用正在显示的位图、实测 global frame 和角度生成无损端点。
    /// 不把这些静态渲染当成录屏帧；实际动画另由 simctl 记录。
    @MainActor private func renderMiniEndpoints() {
        guard let snapshot = zm.miniArtwork,
              let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let directory = documents.appendingPathComponent("mini-endpoints", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let size = UIScreen.main.bounds.size
        let start = zm.miniLabelFrame, end = flightEnd, angle = zm.miniAngle
        func save<V: View>(_ view: V, _ name: String) {
            let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height))
            renderer.scale = displayScale
            if let data = renderer.uiImage?.pngData() {
                try? data.write(to: directory.appendingPathComponent(name + ".png"))
            }
        }
        save(MiniDiscLabel(coverName: snapshot.coverName, artwork: nil, key: snapshot.cacheKey,
                           discSize: 27, snapshot: snapshot)
            .rotationEffect(.degrees(angle)).position(x: start.midX, y: start.midY), "mini")
        save(snapshot.content.modifier(MiniCoverFlight(progress: 0, start: start, end: end, angle: angle,
                                                       discAngle: 0, snapshot: snapshot, closing: false,
                                                       perAxis: Motion.zoomPerAxis, fluid: Motion.zoomFluid)), "flight-start")
        save(SleeveArtwork(coverName: snapshot.coverName, snapshot: snapshot, pull: 0, flip: 0,
                           spin: .zero, pageWidth: size.width).position(x: end.midX, y: end.midY), "detail")
        save(snapshot.content.modifier(MiniCoverFlight(progress: 1, start: start, end: end, angle: angle,
                                                       discAngle: 0, snapshot: snapshot, closing: false,
                                                       perAxis: Motion.zoomPerAxis, fluid: Motion.zoomFluid)), "flight-end")
        let values: [String: Any] = [
            "scale": displayScale, "angle": angle, "cache_key": snapshot.cacheKey,
            "start": [start.minX, start.minY, start.width, start.height],
            "end": [end.minX, end.minY, end.width, end.height],
            "note": "Lossless SwiftUI endpoint renders using actual measured frames; separate from native video."
        ]
        if let data = try? JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: directory.appendingPathComponent("geometry.json"))
        }
    }

    private func coverCell(_ index: Int) -> some View {
        Button {
            // 起点 = 被点击那一格在 library 坐标系里的真实 frame
            origin = cellFrames[index] ?? origin
            targetKey = index
            selectedIndex = index
            selectedCollection = nil
            collectionSongs = nil
            open()
        } label: {
            Image(DS.coverName(index))
                .resizable()
                .aspectRatio(1, contentMode: .fill)
                .clipShape(RoundedRectangle(cornerRadius: DS.corner))
                // 原片首页封面带一层柔和投影（网格左右留有 21pt 边距，不会被裁切）
                .shadow(color: .black.opacity(0.18), radius: 8, x: 0, y: 4)
                .background {
                    GeometryReader { geo in
                        Color.clear.preference(key: CoverFrameKey.self,
                                               value: [index: geo.frame(in: .global)])
                    }
                }
        }
        .buttonStyle(.plain)
        .modifier(TileReveal(progress: zoom, isTarget: presented && zm.flyToTile && selectedCollection == nil && selectedIndex == index,
                             closing: closing))
        .modifier(TilePushAway(zm: zm, key: index))
    }


    /// 叠在 TabView 之上的详情层：详情页（遵守安全区）+ 飞行封面（全局坐标，忽略安全区）
    private var detailLayer: some View {
        ZStack {
        AlbumDetailView(
            coverName: DS.coverName(selectedIndex),
            collection: selectedCollection,
            songs: collectionSongs,
            title: selectedCollection?.title
                  ?? (selectedIndex == AlbumData.featuredIndex ? AlbumData.title
                      : String(format: "Album %02d", selectedIndex)),
            artist: selectedCollection?.artist
                  ?? (selectedIndex == AlbumData.featuredIndex ? AlbumData.artist
                      : "Various Artists"),
            pull: pull,
            flip: flip,
            waveProgress: 0.18,
            contentAlpha: contentAlpha,
            zoom: zoom,
            isPresented: presented,
            closing: closing,
            landed: landed,
            miniOwner: zm.openFromMini && !reduceMotion ? zm.miniOwner : nil,
            miniArtwork: zm.openFromMini ? zm.miniArtwork : nil,
            lyricsMode: lyricsMode,
            wipe: wipe,
            keepsSpinning: !recordingRequested,
            motionStart: motionStart,
            onClose: { close() },
            onSpinAngle: { zm.detailDiscAngle = $0 },
            onToggleArtwork: { toggleArtwork() },
            canPage: { dir in pageNeighbor(dir) != nil },
            neighbour: { dir in
                guard let key = pageNeighbor(dir) else { return nil }
                if key >= 1000 {
                    let c = music.collections[key - 1000]
                    return PagerPeek(coverName: DS.coverName(selectedIndex), artwork: c.artwork, official: c.officialQuery)
                }
                return PagerPeek(coverName: DS.coverName(key), artwork: nil, official: nil)
            },
            onSwipeBegan: { swipeBegan() },
            onPage: { dir in pageAlbum(dir) },
            onSwipeSettled: { swipeSettled() },
            onJump: { c in jumpToAlbum(c) },
            playingPage: { playingPage() },
            onPlayedAlbum: { c in nowPlayingCollection = c }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // t203u：详情层（含顶部专辑名 / 艺人）只在打开 / 关闭转场期间渲染，关闭后绝不残留在首页顶部
        .opacity(presented ? 1 : 0)
        // t146u：详情页整屏吃掉触摸（空白背景也算），上下滑不会穿透到首页网格
        .contentShape(Rectangle())
        .allowsHitTesting(contentAlpha > 0.5)

        // Keep the view alive while SwiftUI interpolates the target state.
        // Testing `zoom < 1` here removes it as soon as open() sets zoom = 1.

            // t128u：飞行封面用全局坐标定位 —— 减去本容器的全局原点（之前漏减了顶部安全区 62pt，
            // 导致整条轨迹下移 62pt、落定时跳回）。
            GeometryReader { g in
                let o = g.frame(in: .global).origin
                flyingCover
                    .offset(x: -o.x, y: -o.y)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .allowsHitTesting(false)
        }
    }

    // MARK: - Zoom 转场中的飞行封面

    private var flightStart: CGRect {
        origin == .zero ? CGRect(x: 27, y: 385, width: 72, height: 72) : origin
    }
    private var flightEnd: CGRect {
        sleeveFrame == .zero ? CGRect(x: 43.5, y: 130, width: DS.sleeve, height: DS.sleeve) : sleeveFrame
    }

    @ViewBuilder private var flyingCover: some View {
        let start = flightStart
        let end = flightEnd
        if zm.openFromMini, let snapshot = zm.miniArtwork {
            snapshot.content
                .modifier(MiniCoverFlight(progress: zoom, start: start, end: end, angle: zm.miniAngle,
                                          discAngle: zm.detailDiscAngle, snapshot: snapshot,
                                          closing: closing, perAxis: Motion.zoomPerAxis && !reduceMotion,
                                          fluid: Motion.zoomFluid && !reduceMotion))
                .opacity(presented && !reduceMotion && zm.miniOwner == .flight ? 1 : 0)
        } else {
        Group {
            if let selectedCollection {
                ArtworkFill(artwork: selectedCollection.artwork, official: selectedCollection.officialQuery)
            } else {
                Image(DS.coverName(selectedIndex)).resizable()
            }
        }
            .modifier(CoverFlight(progress: zoom, start: start, end: end, closing: closing, landed: landed,
                                 discCover: DS.coverName(selectedIndex),
                                 discArtwork: selectedCollection?.artwork,
                                 discOfficial: selectedCollection?.officialQuery,
                                 perAxis: Motion.zoomPerAxis && !reduceMotion,
                                 fluid: Motion.zoomFluid && !reduceMotion,
                                 shrink: 0,   // t210u：网格不缩放 → 起落点 = 格子原位
                                 startCorner: zm.flyToTile ? DS.corner : start.width / 2))   // t222u：mini 端 = 圆形唱片
            .opacity(presented && !reduceMotion ? 1 : 0)
        }
    }

    // MARK: - 动效时序（对应原片 185 帧 / 30fps）

    private func open() {
        guard !presented else { return }
        GridBackdrop.shared.capture()   // t335u: grid as it looks now, before the push / blur / dim start
        presented = true
        closing = false
        autoplay = true
        pull = 0
        flip = 0
        lyricsMode = false
        motionStart = Date()
        // t187u：原片打开 = 整个网格同步缩到 0.95（f5→f9，≈0.13s，无逐格错峰），模糊在缩小之后才开始
        // t210u：打开时网格不再整体缩小、不再发涟漪
        // 一条主 spring 驱动封面缩放与背景模糊（同一进度，不再各跑一条曲线）；
        // 详情文字用带 delay 的从曲线错峰淡入，形成「先放大 → 再显内容」的节奏。
        landed = false
        var noAnim = Transaction(); noAnim.disablesAnimations = true
        withTransaction(noAnim) { wipe = 0 }
        // t149u：按本次格子 → 封套的距离决定弹簧时长（封面、网格缩放、模糊、抽唱片延迟共用）
        Motion.setFlight(start: flightStart, end: flightEnd)
        // t290u: Cove.X push-away of the other tiles (not when opening from the mini player / reduce motion)
        if !zm.openFromMini && !reduceMotion {
            zm.pushAnchor = origin
            zm.pushFrames = cellFrames
            if TilePushAway.pushOut {
                withAnimation(TilePushAway.open) { zm.pushAway = true }
                // t327u: Cove.X 0.38s easeOut fade restored (removed in t322u)
                withAnimation(TilePushAway.fade) { zm.pushOpacity = 0 }
            }
        } else { zm.pushAnchor = nil }
        if DetailReveal.log { print("[t251u] zoom start t=\(Date().timeIntervalSince1970) fluidOpen=\(Motion.fluidOpen)") }
        withAnimation(reduceMotion ? .easeOut(duration: 0.15) : Motion.animation(Motion.open),
                      completionCriteria: zm.openFromMini ? .removed : .logicallyComplete) {
            zoom = 1
        } completion: {
            if DetailReveal.log { print("[t251u] zoom complete → landed t=\(Date().timeIntervalSince1970)") }
            if presented && !closing {
                var transaction = Transaction(); transaction.disablesAnimations = true
                withTransaction(transaction) {
                    landed = true
                    if zm.openFromMini { zm.miniOwner = .detail }
                }
            }
        }
        withAnimation(reduceMotion ? .easeOut(duration: 0.15) : Motion.zoomBackdrop.delay(GridMotion.blurDelay)) {
            blurRadius = 4   // t326u: 8 → 4pt; t324u: 18 → 8pt (stacks on the per-tile push blur); dim unchanged
            gridDim = 1
        }
        // Detail copy fades in after the cover has started moving (reference frames 9–16).
        withAnimation(.easeInOut(duration: 7.0 / 30).delay(4.0 / 30)) {
            contentAlpha = 1
        }
        demoToken += 1
    }

    private var closeQueued: Bool { get { zm.closeQueued } nonmutating set { zm.closeQueued = newValue } }
    private var curveLabel: String? { get { zm.curveLabel } nonmutating set { zm.curveLabel = newValue } }
    /// 打开弹簧逻辑完成（已落定）→ 详情封套接手
    private var landed: Bool { get { zm.landed } nonmutating set { zm.landed = newValue } }
    /// 关闭飞行的目标格子（cellFrames 的 key），滚动时实时跟踪它的 frame
    private var gridFrame: CGRect { get { zm.gridFrame } nonmutating set { if zm.gridFrame != newValue { zm.gridFrame = newValue } } }
    private var scrollRequest: Int? { get { zm.scrollRequest } nonmutating set { zm.scrollRequest = newValue } }
    private var targetKey: Int? { get { zm.targetKey } nonmutating set { zm.targetKey = newValue } }

    private func close() {
        guard presented && !closing && !closeQueued else { return }
        // 唱片抽出时先收回封套（不旋转、不翻面），收好后再开始缩回网格，
        // 保证飞行封面起点与静止封套完全重合。
        if pull > 0.01 && !reduceMotion {
            closeQueued = true
            autoplay = false
            demoToken += 1
            withAnimation(Motion.animation(Motion.retract)) { pull = 0 }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(Motion.retract.duration + 0.04))
                closeQueued = false
                beginCloseFlight()
            }
            return
        }
        beginCloseFlight()
    }

    // MARK: - t131u 封面横滑切专辑

    /// 首页网格顺序里的所有格子 key：演示 = 1…N；Apple Music = 1000 + i
    private var pageKeys: [Int] {
        music.collections.isEmpty ? Array(1...AlbumData.coverCount)
                                  : music.collections.indices.map { 1000 + $0 }
    }
    private var currentPageKey: Int {
        if let targetKey { return targetKey }
        if let c = selectedCollection, let i = music.collections.firstIndex(where: { $0.id == c.id }) { return 1000 + i }
        return selectedIndex
    }
    private func pageNeighbor(_ dir: Int) -> Int? {
        let keys = pageKeys
        guard let i = keys.firstIndex(of: currentPageKey) else { return nil }
        let j = i + dir
        return keys.indices.contains(j) ? keys[j] : nil
    }
    /// t341u: the playing album (home's now-playing collection) and its page offset from the page on screen
    private func playingPage() -> (collection: MusicCollection, offset: Int?)? {
        guard music.hasCurrentTrack, let c = nowPlayingCollection else { return nil }
        let keys = pageKeys
        guard let here = keys.firstIndex(of: currentPageKey),
              let i = music.collections.firstIndex(where: { $0.id == c.id }),
              let there = keys.firstIndex(of: 1000 + i) else { return (c, nil) }
        return (c, there - here)
    }
    /// 开始横滑：唱片先收回封套
    private func swipeBegan() {
        demoToken += 1          // 取消尚未执行的自动抽出
        flipBusy = false
        // t185u：识别到横滑时不再收回唱片（那会让封套 + 唱片抖一下）；整组跟手平移，换专辑后才应用新专辑的唱片状态
    }
    /// 换到相邻专辑：只换展示内容，不动播放
    private func pageAlbum(_ dir: Int) {
        guard let key = pageNeighbor(dir) else { return }
        var t = Transaction(); t.disablesAnimations = true
        withTransaction(t) {
            zm.miniArtwork = nil
            pull = 0
            flip = 0
            lyricsMode = false
            targetKey = key
            if key >= 1000 {
                let c = music.collections[key - 1000]
                selectedCollection = c
                // t330u: a prefetched neighbour renders its full tracklist at once (no loading state)
                let cached = TrackPrefetch.shared.cached(c)
                collectionSongs = cached
                TrackPrefetch.shared.pageChanged(prefetched: cached != nil)
                Task {
                    let songs: [Song]
                    if let cached { songs = cached } else { songs = await TrackPrefetch.shared.quick(c) }
                    guard selectedCollection?.id == c.id else { return }
                    if cached == nil {
                        collectionSongs = songs
                        TrackPrefetch.shared.tracksShown()
                        upgradeToCatalogTracks(c, shown: songs)
                    }
                    // t185u：换到新专辑后自动从第一首开始播放；t223u：仅当当前没有在播放时（否则只展示，不打断）
                    if shouldAutoplay(c), let first = songs.first(where: { $0.playParameters != nil }) {
                        nowPlayingCollection = c
                        await music.play(first, in: songs, fromCatalog: c.isCatalog)
                    }
                }
            } else {
                selectedIndex = key
                selectedCollection = nil
                collectionSongs = nil
            }
            if let f = cellFrames[key] { origin = f }
            // t222u：不再滚动首页网格去找格子；关闭时格子可见就飞回它，否则飞回 mini player
        }
    }
    /// t283u: library tracks show immediately; the full catalog tracklist replaces them when it arrives
    /// (only if it is longer and the same album is still open). Failures keep the library tracks.
    private func upgradeToCatalogTracks(_ c: MusicCollection, shown: [Song]) {
        guard case .album(_, catalog: false) = c else { return }
        Task {
            let fetched = await c.catalogSongs(librarySongs: shown)
            guard let full = fetched, full.count > shown.count else {
                TrackPrefetch.shared.store(c, shown)   // t330u: no longer catalog list → library tracks are the full list
                return
            }
            guard selectedCollection?.id == c.id, collectionSongs?.count == shown.count else {
                TrackPrefetch.shared.store(c, full); return
            }
            collectionSongs = full
            TrackPrefetch.shared.store(c, full)
        }
    }

    /// t214u：从「相似专辑」换到任意专辑（可以不在首页里）：与 pageAlbum 相同的换专辑 + 自动播第一首。
    /// 若该专辑在首页里 → 关闭时飞回它的格子；不在 → 关闭时飞回上一次的格子位置。
    private func jumpToAlbum(_ c: MusicCollection) {
        var t = Transaction(); t.disablesAnimations = true
        withTransaction(t) {
            zm.miniArtwork = nil
            pull = 0
            flip = 0
            lyricsMode = false
            let i = music.collections.firstIndex { $0.id == c.id }
            if let i {
                targetKey = 1000 + i
                if let f = cellFrames[1000 + i] { origin = f }
            }
            selectedCollection = c
            collectionSongs = TrackPrefetch.shared.cached(c)   // t330u
        }
        TrackPrefetch.shared.pageChanged(prefetched: collectionSongs != nil)
        Task {
            let cached = TrackPrefetch.shared.cached(c)
            let songs: [Song]
            if let cached { songs = cached } else { songs = await TrackPrefetch.shared.quick(c) }
            guard selectedCollection?.id == c.id else { return }
            if cached == nil { collectionSongs = songs; TrackPrefetch.shared.tracksShown(); upgradeToCatalogTracks(c, shown: songs) }
            if shouldAutoplay(c), let first = songs.first(where: { $0.playParameters != nil }) {   // t223u
                nowPlayingCollection = c
                await music.play(first, in: songs, fromCatalog: c.isCatalog)
            }
        }
    }
    /// t223u：打开 / 横滑 / 相似专辑时是否自动播第一首：
    /// 没有在播放（从没播过 / 停止 / 暂停）且打开的不是当前这张 → 播；正在播放 → 只展示不打断；就是当前这张 → 什么都不重来
    private func shouldAutoplay(_ c: MusicCollection) -> Bool {
        if music.isPlaying { return false }
        if music.hasCurrentTrack, nowPlayingCollection?.id == c.id { return false }
        return true
    }
    /// t226u：mini player 封面 = 正在播放专辑在格子 / 详情里用的同一张图；歌单里的歌 → 该歌自己的专辑
    private var miniCover: (Artwork?, OfficialCoverQuery?) {
        if ProcessInfo.processInfo.arguments.contains("--debug-mini-cycle"),
           ProcessInfo.processInfo.arguments.contains("--debug-mini-official") {
            return (nil, OfficialCoverQuery(id: "mini-official-fixture", title: "Fixture", artist: "Fixture"))
        }
        guard music.hasCurrentTrack else {
            guard let c = music.collections.first else { return (nil, nil) }
            return (c.artwork, c.officialQuery)
        }
        if let c = nowPlayingCollection, case .album = c { return (c.artwork, c.officialQuery) }
        let album = music.currentAlbumTitle
        guard !album.isEmpty else { return (music.currentArtwork, nil) }
        return (music.currentArtwork, OfficialCoverQuery(id: "track-album:\(album)|\(music.currentArtist)",
                                                         title: album, artist: music.currentArtist))
    }
    /// t222u：格子是否在首页可见区域内（顶栏之下、mini player 之上，至少大半可见）
    private func tileVisible(_ f: CGRect) -> Bool {
        let screen = UIScreen.main.bounds
        let top: CGFloat = 100
        let bottom: CGFloat = zm.miniDiscFrame == .zero ? screen.height - 90 : zm.miniDiscFrame.minY - 12
        return f.midY > top && f.midY < bottom && f.minX >= -1 && f.maxX <= screen.width + 1
    }
    /// 新封套落定：0.15s 后唱片用原有弹簧抽出
    /// t330u: warm the full tracklists (library + catalog completion) of the ±2 neighbours of the page on screen;
    /// prefetches for albums outside that window are cancelled.
    private func prefetchNeighbours() {
        guard !music.collections.isEmpty else { return }
        let keys = pageKeys
        guard let i = keys.firstIndex(of: currentPageKey) else { return }
        let window = (-2...2).compactMap { d -> MusicCollection? in
            let j = i + d
            guard d != 0, keys.indices.contains(j), keys[j] >= 1000 else { return nil }
            return music.collections[keys[j] - 1000]
        }
        TrackPrefetch.shared.prefetch(window)
    }
    private func swipeSettled() {
        TrackPrefetch.shared.settled(hasTracks: collectionSongs != nil)
        prefetchNeighbours()
        demoToken += 1
        let token = demoToken
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.15))
            guard token == demoToken, presented, !closing, flip < 90 else { return }
            withAnimation(Motion.animation(Motion.pull)) { pull = 1 }
        }
    }

    private func beginCloseFlight() {
        guard presented && !closing else { return }
        // t290u: tiles come back first; the un-pushed frames are the close-flight targets
        if zm.pushAnchor != nil {
            cellFrames = cellFrames.merging(zm.pushFrames) { _, unpushed in unpushed }
            if !TilePushAway.pushOut {
                // t329u: jump to the pushed-out state with no animation (the grid is still fully covered by the
                // opaque detail backdrop at this instant, so nothing flashes), then play the return as before
                var snap = Transaction(); snap.disablesAnimations = true
                withTransaction(snap) { zm.pushAway = true; zm.pushOpacity = 0 }
                // the pushed state must be committed (rendered once) before the return starts, else SwiftUI
                // coalesces true → false into no change and nothing animates
                DispatchQueue.main.async {
                    withAnimation(TilePushAway.close) { zm.pushAway = false }
                    withAnimation(TilePushAway.fade) { zm.pushOpacity = 1 }
                }
            } else {
                withAnimation(TilePushAway.close) { zm.pushAway = false }
                withAnimation(TilePushAway.fade) { zm.pushOpacity = 1 }
            }
        }
        // t131u：飞回「当前显示的那张专辑」的格子（实时 frame）
        // t222u：从 mini player 打开 → 飞回 mini 唱片；从格子打开 → 当前专辑格子在屏幕上可见就飞回它，否则飞回 mini 唱片
        let tile: CGRect? = zm.openFromMini ? nil : targetKey.flatMap { cellFrames[$0] }.flatMap { tileVisible($0) ? $0 : nil }
        if let tile {
            origin = tile
            zm.flyToTile = true
        } else if zm.openFromMini, zm.miniLabelFrame != .zero {
            origin = zm.miniLabelFrame
            zm.flyToTile = false
        } else if zm.miniDiscFrame != .zero {
            origin = zm.miniDiscFrame
            zm.flyToTile = false
        } else if let k = targetKey, let f = cellFrames[k] {
            origin = f; zm.flyToTile = true
        }
        Motion.setFlight(start: flightStart, end: flightEnd)
        landed = false
        // 关闭时封面只做缩放 / 位移回到网格，不做任何翻转：
        // 即使用户翻到了 B 面，也先无动画地把 flip 归零。
        var reset = Transaction()
        reset.disablesAnimations = true
        withTransaction(reset) {
            if zm.openFromMini { zm.miniOwner = .flight }
            flip = 0
            // 网格瞬间变清晰、不再变暗：此刻被不透明的详情背景完整盖住，看不到这一跳；
            // 之后背景自上而下擦除，逐步露出清晰的网格。
            blurRadius = 0
            gridDim = 0
            wipe = 0
        }
        closing = true
        autoplay = false
        // t187u：原片关闭 = 清晰网格先停在 0.95，封面快落位时整体放大回 1（f171→f184，≈0.43s，无过冲、无逐格错峰）
        // t210u：关闭时不再整体放大回 1、不再发涟漪
        demoToken += 1
        withAnimation(
            reduceMotion ? .easeOut(duration: 0.15) : Motion.zoomCurve.closeAnimation,
            completionCriteria: .removed
        ) {
            zoom = 0
        } completion: {
            var transaction = Transaction(); transaction.disablesAnimations = true
            withTransaction(transaction) {
                if zm.openFromMini {
                    zm.miniPhase.resume(from: zm.miniAngle)
                    zm.miniOwner = .mini
                }
                presented = false
                closing = false
                pull = 0
                flip = 0
                lyricsMode = false
                zm.openFromMini = false
                zm.flyToTile = true
            }
            recordingMarker("complete")
            // 落地帧仍用锁定的位图；稍后才恢复官方封面到达时的原有换图逻辑。
            if zm.miniArtwork != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    guard !presented else { return }
                    withAnimation(.easeInOut(duration: 0.25)) { zm.miniArtwork = nil }
                }
            }
        }
        // 曲目 / 波形等文字比背景擦除更早消失，避免叠在露出的网格上
        withAnimation(.easeOut(duration: 0.12)) {
            contentAlpha = 0
        }
        // t121u：模糊背景自上而下渐变擦除（Ref 关闭曲线形状，0.4s）
        withAnimation(reduceMotion ? .easeOut(duration: 0.15) : Motion.closeBackdrop) {
            wipe = 1
        }
    }

    /// 用户点封套 = 翻过来看封套背面，纯视觉，不碰播放器（不暂停、不切歌）。期间点击一律忽略。
    /// 正面 → 背面：① 唱片收回封套（retract，原片 f91→97 = 0.20s）→ ② 封套绕 Y 轴翻到背面（flip，原片 f114→125 = 0.367s）。
    /// 背面 → 正面：① 封套翻回正面（0.367s）→ ② 唱片再滑出（pull，原片 f41→55 = 0.467s）。
    /// 打开详情时绝不自动翻面。
    private func toggleArtwork() {
        guard presented && !closing && !flipBusy else { return }
        flipBusy = true
        Task { @MainActor in
            defer { flipBusy = false }
            let animate = !reduceMotion
            // t160u / t162u：① 封套与唱片同时向中间合拢（spring 0.3s，bounce 0）→ ② 合在一起绕 Y 轴翻转（spring 0.5s，bounce 0）。
            // 返回：先翻回，再一起分开回原位。曲目表点击即淡出 0.2s，歌词在翻转阶段淡入。
            let turn: Animation? = animate ? .spring(duration: Lyrics.flip, bounce: 0) : nil
            let merge: Animation? = animate ? .spring(duration: Lyrics.merge, bounce: 0) : nil
            if flip < 90 {
                LyricsTrace.mark("lyrics toggle (fade-in delay \(Lyrics.fadeInDelay)s + \(Lyrics.fadeIn)s)")
                lyricsMode = true
                if pull > 0.01 {
                    withAnimation(merge) { pull = 0 }
                    if animate { try? await Task.sleep(for: .seconds(Lyrics.merge)) }
                }
                guard presented && !closing else { return }
                withAnimation(turn) { flip = 180 }
                if animate { try? await Task.sleep(for: .seconds(Lyrics.flip)) }
            } else {
                lyricsMode = false
                withAnimation(turn) { flip = 0 }
                if animate { try? await Task.sleep(for: .seconds(Lyrics.flip)) }
                guard presented && !closing else { return }
                withAnimation(merge) { pull = 1 }
                if animate { try? await Task.sleep(for: .seconds(Lyrics.merge)) }
            }
        }
    }

    /// Source f5 is the opening trigger. Offsets below are relative to that trigger.
    @MainActor
    private func runDemo() async {
        // 减弱动态效果：唱片直接处于抽出 / 播放状态，不做位移动画。
        if reduceMotion && presented && !closing && autoplay && !recordingRequested { pull = 1; return }
        guard presented && !closing && autoplay && !reduceMotion else { return }
        // 等封面弹簧落定（landed）后再停 0.15s，唱片才用自己的柔和弹簧滑出
        for _ in 0..<40 where !landed {
            guard await pause(50_000_000) else { return }
        }
        // 原片：点击后 1.2s（f5→f41）唱片开始抽出，封面在 f22–27 落定后约停 0.47s
        let sinceTap = Date().timeIntervalSince(motionStart)
        // t119u：点击后 0.6s（封面落定后约 0.2s）开始抽出；t135u：随打开时长同比缩放 → 0.48s / 最少 0.12s
        let k = Motion.openScale
        let wait = max(0.15 * k, 0.6 * k - sinceTap)
        guard await pause(UInt64(wait * 1_000_000_000)) else { return }
        // 用户已翻到背面 / 正在翻：不自动抽出
        guard flip < 90 && !flipBusy else { return }
        // 点开封面：唱片自动滑出并开始播放（唱片持续旋转）。
        withAnimation(Motion.animation(Motion.pull)) { pull = 1 }
        // 正常点击打开到此为止：不自动收回、不自动翻面、不自动关闭。
        // 只有 --record-demo 录屏启动才继续复现原片的完整演示序列。
        guard recordingRequested else { return }

        guard await pause(1_666_666_667) else { return }
        withAnimation(Motion.animation(Motion.retract)) { pull = 0 }

        guard await pause(766_666_667) else { return }
        // The source turns to side B, with readable artwork and a different label.
        withAnimation(Motion.animation(Motion.flip)) { flip = 180 }

        guard await pause(1_700_000_000) else { return }
        close()
    }

    @MainActor
    private func pause(_ nanoseconds: UInt64) async -> Bool {
        do {
            try await Task.sleep(nanoseconds: nanoseconds)
            return !Task.isCancelled && presented && !closing && autoplay
        } catch {
            return false
        }
    }

    /// Only the explicit simulator recording launch writes these completion markers.
    private func recordingMarker(_ phase: String) {
        guard recordingRequested else { return }
        guard let folder = FileManager.default.urls(for: .documentDirectory,
                                                     in: .userDomainMask).first else { return }
        try? phase.write(to: folder.appendingPathComponent("vinyl-recording-state.txt"),
                         atomically: true, encoding: .utf8)
    }
}

/// Derive geometry and handoff opacity from the *interpolated* presentation value.
private struct CoverFlight: AnimatableModifier {
    var progress: CGFloat
    let start: CGRect
    let end: CGRect
    var closing: Bool = false
    var landed: Bool = false
    var discCover: String = DS.coverName(AlbumData.featuredIndex)
    var discArtwork: Artwork? = nil
    var discOfficial: OfficialCoverQuery? = nil
    var perAxis: Bool = true
    /// t147u：单一进度 + 弧线（与 perAxis 互斥）
    var fluid: Bool = false
    /// t187u：网格整体缩小量（0 = 原尺寸，1 = GridMotion.minScale），与网格同一个动画值 → 落点永远与格子重合
    var shrink: CGFloat = 0
    /// t222u：起落点圆角（格子 = DS.corner，mini 唱片 = 半径 → 圆形）
    var startCorner: CGFloat = DS.corner

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(progress, shrink) }
        set { progress = newValue.first; shrink = newValue.second }
    }

    func body(content: Content) -> some View {
        // 位置、尺寸、圆角、挖孔全部跟随同一个弹簧进度 p（不走参考路径、不夹断），
        // 弹簧的轻微过冲自然体现为封面越过终点一点再落定。
        let p: CGFloat = progress
        // t128u：逐轴曲线（Ref）：progress 是线性时间；x / y / 尺寸各自按原片拟合的贝塞尔取值 → 弧线轨迹。
        // 关闭时 progress 1→0，u = 已用时间 = 1 − progress，分量 = 1 − closeCurve(u)。
        let u = Double(min(1, max(0, closing ? 1 - p : p)))
        let fluidSize: CGFloat = p - Motion.fluidSizeLag * p * (1 - p)
        let fx: CGFloat = fluid ? p : !perAxis ? p : CGFloat(closing ? 1 - FlightCurves.value(FlightCurves.closeX, u) : FlightCurves.value(FlightCurves.openX, u))
        let fy: CGFloat = !perAxis ? p : CGFloat(closing ? 1 - FlightCurves.value(FlightCurves.closeY, u) : FlightCurves.value(FlightCurves.openY, u))
        let fs: CGFloat = fluid ? fluidSize : !perAxis ? p : CGFloat(closing ? 1 - FlightCurves.value(FlightCurves.closeS, u) : FlightCurves.value(FlightCurves.openS, u))
        let clamped: CGFloat = min(1, max(0, fs))
        // t138u：起点格子跟着网格整体缩放（锚点 = 屏幕 46.5% / 68%），落点永远与正在缩放的格子重合
        let gs: CGFloat = (perAxis || fluid) ? 1 - (1 - GridMotion.minScale) * shrink : 1
        let screen = UIScreen.main.bounds.size
        let ax = FlightCurves.gridAnchor.x * screen.width, ay = FlightCurves.gridAnchor.y * screen.height
        let sW = start.width * gs
        let sX = ax + (start.midX - ax) * gs, sY = ay + (start.midY - ay) * gs
        let width: CGFloat = sW + (end.width - sW) * fs
        var midX: CGFloat = sX + (end.midX - sX) * fx
        var midY: CGFloat = sY + (end.midY - sY) * fy
        if fluid {
            // 二次贝塞尔弧线：控制点 = 弦中点 + 法向 bow，朝 (终点 x, 起点 y) 一侧（先横后竖）
            let dx = end.midX - sX, dy = end.midY - sY
            let len = max(1, (dx * dx + dy * dy).squareRoot())
            var nx = -dy / len, ny = dx / len
            let cornerX = end.midX - (sX + dx / 2), cornerY = sY - (sY + dy / 2)
            if nx * cornerX + ny * cornerY < 0 { nx = -nx; ny = -ny }
            let cx = sX + dx / 2 + nx * Motion.fluidBow, cy = sY + dy / 2 + ny * Motion.fluidBow
            let t = p, it = 1 - p
            midX = it * it * sX + 2 * it * t * cx + t * t * end.midX
            midY = it * it * sY + 2 * it * t * cy + t * t * end.midY
        }
        // 原图放大：飞行全程就是格子那张图本身（同图、同裁切、方形等比），只有圆角随尺寸连续变化。
        // 封套挖孔只在尺寸最后 15% 才淡入（关闭时最先 15% 淡出），与详情封套交接处完全一致，
        // 其余 85% 的路程画面就是原图在放大 / 缩小，没有任何换图或叠影。
        // t137u：挖孔不再淡入（那等于在同一位置叠第二层画面）：孔是同一张封面上的遮罩，
        // 在尺寸进度最后 30% 由 0 直径平滑张开到封套孔径（关闭时反向收拢）；孔后的唱片始终不透明，只透过孔可见。
        let holeT: CGFloat = min(1, max(0, (clamped - 0.70) / 0.30))
        let holeOpen: CGFloat = holeT * holeT * (3 - 2 * holeT)
        let visible: Double = (closing || !landed) ? 1 : 0
        // t140u：飞行全程不改布局：固定以终点尺寸（306pt）排版一次，只做 scale + offset 变换（渲染服务端插值），
        // 圆角 / 孔径 / 投影按缩放比反算到内容坐标系，屏幕上的视觉值与之前一致。
        let base: CGFloat = max(1, end.width)
        let k: CGFloat = width / base
        let holeFull: CGFloat = base * DS.planet / DS.sleeve
        let holeNowC: CGFloat = holeFull * holeOpen
        return content
            .frame(width: base, height: base)
            .mask {
                Rectangle()
                    .overlay {
                        Circle().frame(width: holeNowC, height: holeNowC)
                            .blendMode(.destinationOut)
                    }
                    .compositingGroup()
            }
            .background {
                if holeOpen > 0 {
                    // 孔后是与详情页同一个黑胶视图（等比缩放），交接时孔内画面一致
                    VinylDiscView(angle: .zero, pull: 0, coverName: discCover, artwork: discArtwork, official: discOfficial)
                        .shadow(radius: 0)
                        .scaleEffect(base / DS.sleeve)
                        .frame(width: holeFull, height: holeFull)
                        .clipShape(Circle())
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: startCorner * (1 - clamped) / k))
            .compositingGroup()
            .scaleEffect(k, anchor: .center)
            .shadow(color: .black.opacity(0.18 - 0.06 * Double(clamped)), radius: 8, y: 4 + clamped)
            .offset(x: midX - base / 2, y: midY - base / 2)
            .opacity(visible)
    }
}

/// mini 标签独立用 frame + position 插值；网格保留原 CoverFlight。
private struct MiniCoverFlight: AnimatableModifier {
    var progress: CGFloat
    let start: CGRect
    let end: CGRect
    let angle: Double
    let discAngle: Double
    let snapshot: MiniArtworkSnapshot
    let closing: Bool
    let perAxis: Bool
    let fluid: Bool

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let p = progress
        let u = Double(min(1, max(0, closing ? 1 - p : p)))
        let fx: CGFloat = fluid || !perAxis ? p : CGFloat(closing
            ? 1 - FlightCurves.value(FlightCurves.closeX, u) : FlightCurves.value(FlightCurves.openX, u))
        let fy: CGFloat = !perAxis ? p : CGFloat(closing
            ? 1 - FlightCurves.value(FlightCurves.closeY, u) : FlightCurves.value(FlightCurves.openY, u))
        let fs: CGFloat = fluid ? p - Motion.fluidSizeLag * p * (1 - p) : !perAxis ? p : CGFloat(closing
            ? 1 - FlightCurves.value(FlightCurves.closeS, u) : FlightCurves.value(FlightCurves.openS, u))
        let t = min(1, max(0, fs))
        let width = max(0.1, start.width + (end.width - start.width) * fs)
        var x = start.midX + (end.midX - start.midX) * fx
        var y = start.midY + (end.midY - start.midY) * fy
        if fluid {
            let dx = end.midX - start.midX, dy = end.midY - start.midY
            let length = max(1, hypot(dx, dy))
            var nx = -dy / length, ny = dx / length
            if nx * dx / 2 + ny * -dy / 2 < 0 { nx = -nx; ny = -ny }
            let cx = start.midX + dx / 2 + nx * Motion.fluidBow
            let cy = start.midY + dy / 2 + ny * Motion.fluidBow
            x = (1 - p) * (1 - p) * start.midX + 2 * (1 - p) * p * cx + p * p * end.midX
            y = (1 - p) * (1 - p) * start.midY + 2 * (1 - p) * p * cy + p * p * end.midY
        }
        let holeT = min(1, max(0, (t - 0.70) / 0.30))
        let holeOpen = holeT * holeT * (3 - 2 * holeT)
        let hole = width * DS.planet / DS.sleeve * holeOpen
        let pinT = min(1, t / 0.15)
        let pin = 1 - pinT * pinT * (3 - 2 * pinT)
        // SleeveCutout 实际终点是直角；圆角从 mini 正圆半径连续归零。
        let radius = start.width / 2 * (1 - t)
        let rotation = angle * Double(1 - t)
        let ratio = width / DS.sleeve
        let masked = content
            .frame(width: width, height: width)
            .mask {
                RoundedRectangle(cornerRadius: radius)
                    .overlay {
                        Circle().frame(width: hole, height: hole).blendMode(.destinationOut)
                    }
                    .compositingGroup()
            }
        let backed = masked.background {
                if holeOpen > 0 {
                    VinylDiscView(angle: .degrees(closing ? discAngle : 0), pull: 0,
                                  coverName: snapshot.coverName, snapshot: snapshot)
                        .scaleEffect(ratio)
                        .frame(width: hole, height: hole)
                        .clipShape(Circle())
                }
            }
        let withPin = backed.overlay {
                Circle().fill(.white).frame(width: 1.2, height: 1.2).opacity(Double(pin))
            }
        return withPin.overlay {
                Circle()
                    .strokeBorder(.black.opacity(0.35 * Double(holeOpen)), lineWidth: ratio)
                    .background(Circle().strokeBorder(.black.opacity(0.18 * Double(holeOpen)),
                                                      lineWidth: 4 * ratio).blur(radius: 2.5 * ratio))
                    .frame(width: hole, height: hole)
                    .clipShape(Circle())
            }
            .rotationEffect(.degrees(rotation))
            .shadow(color: .black.opacity(0.12 * Double(t)), radius: 8 * t, y: 5 * t)
            .position(x: x, y: y)
            .onChange(of: progress) { _, value in
                guard ProcessInfo.processInfo.arguments.contains("--debug-mini-cycle") else { return }
                print("[mini-frame] time=\(Date().timeIntervalSince1970) close=\(closing) p=\(value) center=(\(x),\(y)) side=\(width) angle=\(rotation) key=\(snapshot.cacheKey)")
            }
    }
}

/// t187u：首页网格整体缩放（原片逐帧实测：所有格子同一缩放、同一锚点，无逐格错峰、无过冲）
enum GridMotion {
    /// 原片列距 113.3 → 107.2px（4 列中心跨度 339 → 321.5）≈ 0.95
    static let minScale: CGFloat = 0.95
    /// 打开：f5→f9 缩到 0.95（≈0.13s，ease-out）
    static let open: Animation = .timingCurve(0.556, -0.094, 0.592, 1.094, duration: 0.13)
    /// 模糊 / 变暗在缩小基本完成后才开始（原片 f9→f10 起才糊）
    static let blurDelay: Double = 0.16
    /// 关闭：清晰网格停在 0.95，0.12s 后用 0.43s 放大回 1（原片 f171→f184，拟合 bezier）
    static let close: Animation = .timingCurve(0.293, 0.305, 0.470, 0.829, duration: 0.43).delay(0.12)
}

/// t191u：径向涟漪。每个格子延迟 d / speed 后做一次欠阻尼弹簧振荡：
/// s = 1 − a(d)·f(τ)/f_peak，f(τ) = e^(−ζωτ)·sin(ω_d τ)；ω = 2π/0.45s，ζ = 0.5
/// → 1 → 下沉到 1 − a(d)（τ≈0.087s）→ 轻微回弹 ≈ 1 + 0.16·a(d)（τ≈0.35s）→ 1
/// a(d) = A·e^(−d/350pt)；关闭 A = 0.10（中心 0.90），打开 A = 0.05
enum Wave {
    static let closeAmplitude = 0.10
    static let openAmplitude = 0.05
    static let falloff = 350.0          // pt
    static let speed = 1400.0           // pt/s
    static let response = 0.45
    static let damping = 0.5
    static let omega = 2 * Double.pi / response
    static let omegaD = omega * (1 - damping * damping).squareRoot()
    static let decay = damping * omega
    static let tPeak = atan(omegaD / decay) / omegaD
    static let fPeak = exp(-decay * tPeak) * sin(omegaD * tPeak)
    static let settle = 0.9             // 单格振荡持续
    static let total = 1000.0 / speed + settle
    static func scale(t: Double, distance d: Double, amplitude A: Double) -> Double {
        let tau = t - d / speed
        guard tau > 0, tau < settle else { return 1 }
        let f = exp(-decay * tau) * sin(omegaD * tau) / fPeak
        return 1 - A * exp(-d / falloff) * f
    }
}

struct WaveRipple: AnimatableModifier {
    var t: CGFloat
    let distance: Double
    let amp: Double
    let enabled: Bool
    var animatableData: CGFloat {
        get { t }
        set { t = newValue }
    }
    func body(content: Content) -> some View {
        let s: CGFloat = enabled && distance >= 0 && Double(t) < Wave.total
            ? CGFloat(Wave.scale(t: Double(t), distance: distance, amplitude: amp)) : 1
        return content.visualEffect { c, _ in c.scaleEffect(s, anchor: .center) }
    }
}

struct GridRipple: AnimatableModifier {
    var shrink: CGFloat
    var anchor: UnitPoint
    var enabled: Bool
    var animatableData: CGFloat {
        get { shrink }
        set { shrink = newValue }
    }
    func body(content: Content) -> some View {
        let s = enabled ? 1 - (1 - GridMotion.minScale) * shrink : 1
        let a = anchor
        content.visualEffect { c, _ in c.scaleEffect(s, anchor: a) }
    }
}

struct ArtworkHandoff: AnimatableModifier {
    var progress: CGFloat
    var closing: Bool = false
    var landed: Bool = false
    var miniOwner: MiniArtworkOwner? = nil

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        // 飞行封面落定后才显示（几何与飞行终点完全一致），关闭时立即隐藏，由飞行封面飞回
        let shown: Double = miniOwner.map { $0 == .detail ? 1 : 0 }
            ?? ((!closing && (landed || progress >= 1.5)) ? 1 : 0)
        content
            .opacity(shown)
    }
}


/// t121u：关闭时目标格子在缩小的后 35% 就显示在飞行封面下方（飞行封面四边收拢到它身上再淡出），
/// 打开 / 详情期间隐藏，保证屏幕上不会同时出现两个不同尺寸的同一封面。
/// t290u: Cove.X push-away (Cove.X Sources/CoveXKit/Views/MainWindowView.swift, read-only reference):
/// - offset = unit vector (tapped tile centre → this tile centre) × max(viewport w, h) × 0.8, no scale
///   (feedRadialScatterOffset 8226–8249; collapsedScatterScale: 1 at 5040 / 5175 / 7440)
/// - open: spring(response: 0.36, dampingFraction: 0.88) (10094 / 10117), opacity → 0 easeOut 0.38 right after (7905–7911)
/// - close: spring(response: 0.38, dampingFraction: 0.9) (12772), opacity → 1 easeOut 0.38 (12775)
/// The tapped tile is never moved (it is hidden by TileReveal while the cover flies).
struct TilePushAway: ViewModifier {
    @ObservedObject var zm: LibraryZoomModel
    let key: Int
    /// t327u: back to Cove.X's full push (0.8 × longer screen side); t322u's 0.18 short push looked buggy
    static let factor: CGFloat = 0.8
    /// t329u: single switch for the push-OUT on open. false = tiles stay put on open (grid blur / dim only);
    /// the return on close is kept either way (tiles snap invisibly to the pushed state, then spring back).
    static let pushOut = true   // t333u: re-enabled
    static let open = Animation.spring(response: 0.36, dampingFraction: 0.88)
    static let close = Animation.spring(response: 0.38, dampingFraction: 0.9)
    static let fade = Animation.easeOut(duration: 0.38)

    /// t316u: softer push — pushed tiles also blur 0 → 20pt and scale 1 → 0.92, driven by the same `pushAway`
    /// value, so they ride the push springs (open 0.36/0.88, close 0.38/0.9). The tapped tile is untouched.
    /// Per tile by default; `--push-blur-layer` blurs the whole grid layer once instead (cheaper, for A/B on device).
    static let blurRadius: CGFloat = 20
    /// t327u: 0.92 → 1 (Cove.X collapsedScatterScale = 1); the shrink made tiles shift inward against the push
    static let scale: CGFloat = 1
    /// t323u: blur is per tile again (it must follow each tile's own displacement); no grid-layer push blur
    static let layerBlur = false


    /// Unit direction (tapped tile → this tile) and distance; nil for the tapped tile / untracked tiles.
    private var geometry: (dir: CGSize, dist: CGFloat)? {
        // frames snapshotted at open: the live preference frames include this offset (would feed back)
        guard let anchor = zm.pushAnchor, let me = zm.pushFrames[key] else { return nil }
        let dx = me.midX - anchor.midX, dy = me.midY - anchor.midY
        if abs(dx) < 0.5 && abs(dy) < 0.5 { return nil }          // the tapped tile itself
        let d = max(sqrt(dx * dx + dy * dy), 1)
        return (CGSize(width: dx / d, height: dy / d), d)
    }
    /// t324u: peak blur (near tile … far tile, ≥ one screen-length away), lowered from 12…24pt; the single tuning point
    static let peakBlur: ClosedRange<CGFloat> = 3...8   // t326u: 6…14 → 3…8
    func body(content: Content) -> some View {
        let longer = max(UIScreen.main.bounds.width, UIScreen.main.bounds.height)
        let g = geometry
        let t = g.map { min($0.dist / longer, 1) } ?? 0
        content
            .modifier(PushDisplacement(progress: zm.pushAway && g != nil ? 1 : 0,
                                       vector: g.map { CGSize(width: $0.dir.width * longer * Self.factor,
                                                              height: $0.dir.height * longer * Self.factor) } ?? .zero,
                                       maxBlur: Self.peakBlur.lowerBound + (Self.peakBlur.upperBound - Self.peakBlur.lowerBound) * t,
                                       minScale: Self.scale))
            // t327u: fade restored; the tapped tile (and opens from the mini player) stay at full opacity
            .opacity(zm.pushAnchor == nil || (g == nil && zm.pushFrames[key] != nil) ? 1 : zm.pushOpacity)
    }
}

/// t323u: one animated progress p drives offset, blur and scale together, so blur = maxBlur × |offset| / |maxOffset|
/// at every frame of the push springs (out and back); p = 0 ⇒ resting position, blur exactly 0.
struct PushDisplacement: ViewModifier, Animatable {
    var progress: Double
    let vector: CGSize
    let maxBlur: CGFloat
    let minScale: CGFloat
    var animatableData: Double { get { progress } set { progress = newValue } }
    func body(content: Content) -> some View {
        let p = CGFloat(progress)
        let k = min(max(p, 0), 1)
        content
            .scaleEffect(1 - (1 - minScale) * k)
            .blur(radius: maxBlur * k)
            .offset(x: vector.width * p, y: vector.height * p)
    }
}

/// t316u: `--log-push-fps` — counts frames during the 0.6s after a push starts / ends (CADisplayLink at 120Hz)
enum PushFPS { static let on = ProcessInfo.processInfo.arguments.contains("--log-push-fps") }
struct PushFPSProbe: View {
    let active: Bool
    var body: some View {
        Color.clear.onChange(of: active) { _, on in PushFPSCounter.shared.start(label: on ? "push open" : "push close") }
    }
}
final class PushFPSCounter: NSObject {
    static let shared = PushFPSCounter()
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0, started: CFTimeInterval = 0, frames = 0, long = 0, worst: CFTimeInterval = 0
    private var label = ""
    func start(label: String) {
        link?.invalidate()
        self.label = label; frames = 0; long = 0; worst = 0; last = 0; started = CACurrentMediaTime()
        let l = CADisplayLink(target: self, selector: #selector(tick(_:)))
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        l.add(to: .main, forMode: .common)
        link = l
    }
    @objc private func tick(_ l: CADisplayLink) {
        if last > 0 {
            let dt = l.timestamp - last
            frames += 1; worst = max(worst, dt)
            if dt > 1.5 / 120 { long += 1 }
        }
        last = l.timestamp
        if l.timestamp - started >= 0.6 {
            l.invalidate(); link = nil
            let fps = Double(frames) / max(0.001, l.timestamp - started)
            print("[t316u] \(label)\(TilePushAway.layerBlur ? " (layer blur)" : " (per-tile blur)"): \(frames) frames, \(String(format: "%.0f", fps)) fps, \(long) long frames, worst \(String(format: "%.1f", worst * 1000))ms")
        }
    }
}

struct TileReveal: AnimatableModifier {
    var progress: CGFloat
    let isTarget: Bool
    let closing: Bool
    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }
    func body(content: Content) -> some View {
        // 实测：提前显示格子会和尚未完全落定的飞行封面错位叠成双图 → 目标格子在落定交接前保持隐藏
        let shown: Double = isTarget ? 0 : 1
        content.opacity(shown)
    }
}


/// t125u：首页与详情层（叠在 TabView 之上）共享的转场状态
enum MiniArtworkOwner { case mini, flight, detail }

@MainActor
final class LibraryZoomModel: ObservableObject {
    // Frames are an imperative lookup for the flight origin, not a rendering input.
    // Only the selected live origin is published during closing, exactly as before.
    let gridGeometry = LibraryGridGeometry()
    @Published var selectedCollection: MusicCollection?
    /// t222u：本次详情从哪里打开（网格格子 / 底部 mini player），关闭时回到同一处
    @Published var openFromMini = false
    /// t222u：本次飞行的另一端是格子（隐藏该格子）还是 mini player 唱片（隐藏 mini 唱片、格子保持可见）
    @Published var flyToTile = true
    /// 兼容原网格回退路径的旧标签包围盒；mini 飞行不再采用这一旋转后的矩形。
    @Published var miniDiscFrame: CGRect = .zero
    /// 未旋转容器内的标签正圆（8.3077pt），与飞行层同为 global 坐标。
    @Published var miniLabelFrame: CGRect = .zero
    @Published var miniOwner: MiniArtworkOwner = .mini
    @Published var miniArtwork: MiniArtworkSnapshot?
    var miniRenderedArtwork: MiniArtworkSnapshot?
    let miniPhase = MiniDiscPhase()
    var miniAngle = 0.0
    var detailDiscAngle = 0.0
    @Published var collectionSongs: [Song]?
    @Published var presented: Bool = false
    @Published var flipBusy: Bool = false
    @Published var closing: Bool = false
    @Published var autoplay: Bool = false
    @Published var zoom: CGFloat = 0
    @Published var contentAlpha: Double = 0
    @Published var blurRadius: CGFloat = 0
    @Published var gridDim: CGFloat = 0
    @Published var wipe: CGFloat = 0
    @Published var origin: CGRect = .zero
    @Published var sleeveFrame: CGRect = .zero
    @Published var selectedIndex: Int = AlbumData.featuredIndex
    /// t290u: push-away state (TilePushAway); anchor = the tapped tile's global frame (nil = opened from mini)
    @Published var pushAway = false
    @Published var pushOpacity: Double = 1
    var pushAnchor: CGRect?
    var pushFrames: [Int: CGRect] = [:]
    @Published var pull: CGFloat = 0
    @Published var flip: Double = 0
    /// t187u：网格整体缩小量 0…1（打开 → 1，关闭 → 0）
    @Published var gridShrink: CGFloat = 0
    /// t191u：涟漪时钟（秒）、波源格子、中心振幅
    @Published var waveT: CGFloat = 10
    @Published var waveOrigin: Int? = nil
    @Published var waveAmp: Double = 0.10
    /// t160u：封面翻到背面 = 歌词模式
    @Published var lyricsMode: Bool = false
    @Published var demoToken: Int = 0
    @Published var motionStart: Date = .distantPast
    @Published var recordingStarted: Bool = false
    @Published var nowPlayingCollection: MusicCollection? = nil
    @Published var closeQueued: Bool = false
    @Published var curveLabel: String? = nil
    @Published var landed: Bool = false
    @Published var targetKey: Int? = nil
    @Published var scrollRequest: Int? = nil
    @Published var gridFrame: CGRect = .zero
}

final class LibraryGridGeometry {
    var cellFrames: [Int: CGRect] = [:]
}

/// t158u：演示数据只在模拟器录屏 / 调试参数下使用；正常启动永远不显示假数据
/// t216u：功能开关（关掉的功能代码保留，只是不出现在界面上）
enum Features {
    /// 首页右上角搜索按钮 + 搜索面板
    static let searchEnabled = false
}

enum DemoMode {
    static let enabled: Bool = {
        let a = ProcessInfo.processInfo.arguments
        return a.contains("--record-demo") || a.contains("--open-featured") || a.contains("--debug-mini-cycle")
    }()
}

/// t158u：加载中的封面占位：与封面同尺寸、同圆角的浅色方块，无文字
struct HomePlaceholder: View {
    /// t178u：铺满整屏（含 mini player / 底部区域）：行数 = ⌈屏高 / 行距⌉ + 1，× 4 列
    static var count: Int {
        let b = UIScreen.main.bounds.size
        let cell = (b.width - 2 * DS.contentInset - 3 * 18) / 4
        let pitch = max(1, cell + 18)
        return (Int((b.height / pitch).rounded(.up)) + 1) * 4
    }
    var body: some View {
        RoundedRectangle(cornerRadius: DS.corner)
            .fill(Color.primary.opacity(0.05))
            .aspectRatio(1, contentMode: .fit)
            .accessibilityHidden(true)
    }
}


// MARK: - t196u：搜索

struct LibrarySearchSheet: View {
    @EnvironmentObject private var music: AppleMusicStore
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var searching = false
    @State private var albums: [MusicCollection] = []
    @State private var songs: [(Song, Bool)] = []   // (song, fromCatalog)
    @State private var recent: [String] = UserDefaults.standard.stringArray(forKey: "vinyl.recentSearches") ?? []
    var onOpen: (MusicCollection) -> Void
    var onPlay: (Song, [Song], Bool) -> Void

    var body: some View {
        NavigationStack {
            Group {
                if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    if recent.isEmpty {
                        ContentUnavailableView("搜索音乐", systemImage: "magnifyingglass",
                                               description: Text("按专辑、歌单或歌曲名称搜索"))
                    } else {
                        List {
                            Section("最近搜索") {
                                ForEach(recent, id: \.self) { term in
                                    Button(term) { query = term }
                                }
                                Button("清除", role: .destructive) {
                                    recent = []; UserDefaults.standard.removeObject(forKey: "vinyl.recentSearches")
                                }
                            }
                        }
                    }
                } else if searching && albums.isEmpty && songs.isEmpty {
                    ProgressView("搜索中…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if albums.isEmpty && songs.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 18) {
                            if !albums.isEmpty {
                                Text("专辑与歌单").font(.headline).padding(.horizontal, 16)
                                LazyVGrid(columns: [GridItem(.flexible(), spacing: 14),
                                                    GridItem(.flexible(), spacing: 14),
                                                    GridItem(.flexible(), spacing: 14)], spacing: 14) {
                                    ForEach(albums) { c in
                                        Button { remember(query); onOpen(c) } label: {
                                            VStack(alignment: .leading, spacing: 6) {
                                                ArtworkFill(artwork: c.artwork, official: c.officialQuery)
                                                    .clipShape(RoundedRectangle(cornerRadius: DS.corner))
                                                    .aspectRatio(1, contentMode: .fit)
                                                Text(c.title).font(.caption.weight(.semibold)).lineLimit(1)
                                                Text(c.artist).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                            }
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                .padding(.horizontal, 16)
                            }
                            if !songs.isEmpty {
                                Text("歌曲").font(.headline).padding(.horizontal, 16).padding(.top, 8)
                                ForEach(Array(songs.enumerated()), id: \.offset) { _, item in
                                    let (song, catalog) = item
                                    Button {
                                        remember(query)
                                        onPlay(song, songs.map(\.0), catalog)
                                    } label: {
                                        HStack(spacing: 12) {
                                            ArtworkFill(artwork: song.artwork, render: 96)
                                                .frame(width: 48, height: 48)
                                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(song.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                                                Text(song.artistName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                            }
                                            Spacer(minLength: 0)
                                            Image(systemName: "play.fill").font(.caption).foregroundStyle(.secondary)
                                        }
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 6)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .padding(.vertical, 12)
                    }
                }
            }
            .navigationTitle("搜索")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "专辑、歌单、歌曲")
            .task(id: query) { await runSearch() }
        }
    }

    private func remember(_ term: String) {
        let t = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        var r = recent.filter { $0.caseInsensitiveCompare(t) != .orderedSame }
        r.insert(t, at: 0)
        recent = Array(r.prefix(8))
        UserDefaults.standard.set(recent, forKey: "vinyl.recentSearches")
    }

    @MainActor
    private func runSearch() async {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard term.count >= 1 else { albums = []; songs = []; return }
        searching = true
        defer { searching = false }
        // ① 本地首页筛选
        let q = term.lowercased()
        var local = music.collections.filter {
            $0.title.lowercased().contains(q) || $0.artist.lowercased().contains(q)
        }
        var songHits: [(Song, Bool)] = []
        // ② 资料库搜索
        do {
            var req = MusicLibrarySearchRequest(term: term, types: [Album.self, Playlist.self, Song.self])
            req.limit = 25
            let r = try await req.response()
            local += r.albums.map { .album($0, catalog: false) }
            local += r.playlists.map { .playlist($0) }
            songHits += r.songs.map { ($0, false) }
        } catch { print("[t196u] library search: \(error)") }
        // ③ 曲库搜索
        do {
            var req = MusicCatalogSearchRequest(term: term, types: [Album.self, Playlist.self, Song.self])
            req.limit = 25
            let r = try await req.response()
            local += r.albums.map { .album($0, catalog: true) }
            local += r.playlists.map { .playlist($0) }
            songHits += r.songs.map { ($0, true) }
        } catch { print("[t196u] catalog search: \(error)") }
        // 去重（按 id）
        var seen = Set<String>()
        albums = local.filter { seen.insert($0.id).inserted }
        var seenS = Set<String>()
        songs = songHits.filter { seenS.insert($0.0.id.rawValue).inserted }
    }
}

@MainActor enum DebugOnce { static var opened = false; static var hitrate = false }

// MARK: - t292u 设置

/// 首页右上角齿轮打开的原生设置表单（NavigationStack + Form）。
struct SettingsSheet: View {
    @EnvironmentObject private var music: AppleMusicStore
    @EnvironmentObject private var sleep: SleepTimer
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @AppStorage(LyricsFontSize.key) private var fontSize = LyricsFontSize.standard.rawValue
    @AppStorage(LyricsTiming.offsetKey) private var offset = 0
    @State private var cacheBytes: Int?
    @State private var confirmClear = false
    @State private var showOffer = false

    var body: some View {
        NavigationStack {
            Form {
                Section("睡眠定时") {
                    sleepRow("关闭", nil)
                    sleepRow("播完这张专辑", .album)
                    ForEach([15, 30, 45, 60], id: \.self) { n in sleepRow("\(n) 分钟", .minutes(n)) }
                }
                Section("歌词") {
                    Picker("歌词字号", selection: $fontSize) {
                        ForEach(LyricsFontSize.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    Stepper(value: Binding(get: { offset }, set: { offset = LyricsTiming.clampOffset($0) }),
                            in: LyricsTiming.offsetRange, step: LyricsTiming.offsetStep) {
                        LabeledContent("歌词偏移", value: LyricsTiming.offsetLabel(offset))
                    }
                    Button("清除歌词缓存", role: .destructive) { confirmClear = true }
                        .badge(cacheBytes.map { Text(ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file)) })
                        .confirmationDialog("清除歌词缓存？", isPresented: $confirmClear, titleVisibility: .visible) {
                            Button("清除", role: .destructive) {
                                Task {
                                    await LyricsRepository.shared.clearCache()
                                    LyricsStore.shared.clearMemory()
                                    cacheBytes = await LyricsRepository.shared.cacheBytes()
                                }
                            }
                        } message: { Text("已下载的歌词会在下次打开时重新获取。") }
                }
                Section("Apple Music") {
                    LabeledContent("授权", value: authText)
                    LabeledContent("订阅", value: subscriptionText)
                    switch music.authorization {
                    case .denied, .restricted:
                        Button("打开设置") { if let u = URL(string: UIApplication.openSettingsURLString) { openURL(u) } }
                    case .notDetermined:
                        Button("授权 Apple Music") { Task { await music.connect() } }
                    default:
                        if music.subscriptionKnown && !music.canPlayCatalog {
                            Button("订阅 Apple Music") { showOffer = true }
                        }
                    }
                }
                Section {
                    LabeledContent("版本", value: Self.version)
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
            .musicSubscriptionOffer(isPresented: $showOffer, options: .init(messageIdentifier: .playMusic))
            .onChange(of: showOffer) { _, open in if !open { Task { await music.refreshAccess() } } }
            .task { cacheBytes = await LyricsRepository.shared.cacheBytes() }
        }
    }

    private func sleepRow(_ title: String, _ mode: SleepTimer.Mode?) -> some View {
        Button { if let mode { sleep.set(mode) } else { sleep.cancel() } } label: {
            HStack {
                Text(title).foregroundStyle(.primary)
                Spacer()
                if sleep.mode == mode { Image(systemName: "checkmark").foregroundStyle(.tint) }
            }
        }
    }

    private var authText: String {
        switch music.authorization {
        case .authorized: return "已授权"
        case .denied: return "已拒绝"
        case .restricted: return "受限制"
        default: return "未授权"
        }
    }
    private var subscriptionText: String {
        guard music.authorized else { return "—" }
        guard music.subscriptionKnown else { return "暂时无法获取" }
        return music.canPlayCatalog ? "可播放完整曲库" : "未订阅"
    }
    static var version: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(v) (\(b))"
    }
}

// MARK: - t293u 首页 Apple Music 卡片

/// 仅在「未授权」或「已授权但无订阅」时出现。`--debug-music-card=unauthorized|nosubscription` 强制某一状态（截图用）。
struct AppleMusicCard: View {
    @EnvironmentObject private var music: AppleMusicStore
    @Environment(\.openURL) private var openURL
    @State private var showOffer = false
    enum Kind { case unauthorized, noSubscription }

    static let forced: Kind? = {
        guard let a = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--debug-music-card=") }) else { return nil }
        switch a.dropFirst("--debug-music-card=".count) {
        case "unauthorized": return .unauthorized
        case "nosubscription": return .noSubscription
        default: return nil
        }
    }()
    private var kind: Kind? {
        if let f = Self.forced { return f }
        if !music.authorized { return .unauthorized }
        if music.subscriptionKnown && !music.canPlayCatalog { return .noSubscription }
        return nil
    }

    var body: some View {
        if let kind {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(kind == .unauthorized ? "连接 Apple Music" : "订阅 Apple Music")
                        .font(.headline)
                    Text(kind == .unauthorized ? "授权后可播放你的资料库" : "订阅后可播放完整曲库")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                button(kind)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .modifier(CardGlass())
            .musicSubscriptionOffer(isPresented: $showOffer, options: .init(messageIdentifier: .playMusic))
            .onChange(of: showOffer) { _, open in if !open { Task { await music.refreshAccess() } } }
        }
    }

    @ViewBuilder
    private func button(_ kind: Kind) -> some View {
        let b = Button(kind == .unauthorized ? "授权" : "订阅") {
            switch kind {
            case .unauthorized:
                if music.authorization == .denied || music.authorization == .restricted {
                    if let u = URL(string: UIApplication.openSettingsURLString) { openURL(u) }
                } else { Task { await music.connect() } }
            case .noSubscription:
                showOffer = true
            }
        }
        if #available(iOS 26.0, *) { b.buttonStyle(.glass) } else { b.buttonStyle(.bordered) }
    }
}

private struct CardGlass: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        } else {
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
    }
}


/// t330u: in-memory tracklist cache for detail-page swiping, keyed by collection ID. `full` = library tracks,
/// replaced by the longer catalog completion when there is one (same rule as upgradeToCatalogTracks).
/// `--log-prefetch` prints settle → tracks-shown timings.
@MainActor
final class TrackPrefetch {
    static let shared = TrackPrefetch()
    static let log = ProcessInfo.processInfo.arguments.contains("--log-prefetch")
    private var cache: [String: [Song]] = [:]
    private var tasks: [String: Task<[Song], Never>] = [:]
    private var settleAt: Date?
    private var pendingPrefetched: Bool?

    func cached(_ c: MusicCollection) -> [Song]? { cache[c.id] }
    func store(_ c: MusicCollection, _ songs: [Song]) { if !songs.isEmpty { cache[c.id] = songs } }

    /// Not cached: join an in-flight prefetch if there is one, else read the library tracks directly
    /// (shown at once; the caller then upgrades to the catalog completion, which also fills the cache).
    func quick(_ c: MusicCollection) async -> [Song] {
        if let hit = cache[c.id] { return hit }
        if let task = tasks[c.id] { return await task.value }
        let songs = (try? await c.songs()) ?? []
        if case .album(_, catalog: false) = c {} else { store(c, songs) }   // library albums: cached after completion
        return songs
    }

    func prefetch(_ window: [MusicCollection]) {
        let keep = Set(window.map(\.id))
        for (id, task) in tasks where !keep.contains(id) { task.cancel(); tasks[id] = nil }
        for c in window where cache[c.id] == nil && tasks[c.id] == nil { _ = start(c) }
    }

    private func start(_ c: MusicCollection) -> Task<[Song], Never> {
        let id = c.id
        let t0 = Date()
        let task = Task<[Song], Never> { @MainActor in
            defer { self.tasks[id] = nil }
            let library = (try? await c.songs()) ?? []
            guard !Task.isCancelled else { return library }
            var songs = library
            if let fuller = await c.catalogSongs(librarySongs: library), fuller.count > library.count { songs = fuller }
            guard !Task.isCancelled else { return songs }
            self.store(c, songs)
            if Self.log { print("[t330u] prefetched \(c.title): \(songs.count) tracks in \(Int(Date().timeIntervalSince(t0) * 1000))ms") }
            return songs
        }
        tasks[id] = task
        return task
    }

    // timing probe
    func pageChanged(prefetched: Bool) { settleAt = nil; pendingPrefetched = prefetched }
    func settled(hasTracks: Bool) {
        guard let pre = pendingPrefetched else { return }
        if hasTracks {
            if Self.log { print("[t330u] settle → tracks 0ms (\(pre ? "prefetched" : "loaded before settle"))") }
            pendingPrefetched = nil
        } else { settleAt = Date() }
    }
    func tracksShown() {
        guard let at = settleAt else { return }   // arrived before the settle: reported by settled()
        if Self.log { print("[t330u] settle → tracks \(Int(Date().timeIntervalSince(at) * 1000))ms (not prefetched)") }
        settleAt = nil; pendingPrefetched = nil
    }
}


/// t335u: the detail page's background colour = a static snapshot of the home screen taken at open (before the
/// tiles are pushed away), captured at 0.2× scale and pre-blurred once with Core Image, so nothing is re-blurred
/// per frame. Shown under the detail content with a white wash for legibility.
@MainActor
final class GridBackdrop: ObservableObject {
    static let shared = GridBackdrop()
    static let blur: CGFloat = 40          // pt (8 px at the 0.2× capture scale)
    static let wash: Double = 0.6          // white over the blurred covers
    static let scale: CGFloat = 0.2
    @Published private(set) var image: UIImage?
    /// mean relative luminance of the washed backdrop (what the detail text actually sits on)
    private(set) var pageLuminance: CGFloat = ThemeColor.pageLuminance
    private let context = CIContext(options: [.cacheIntermediates: false])

    func capture() {
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).flatMap(\.windows).first(where: \.isKeyWindow) else { return }
        let t0 = Date()
        let format = UIGraphicsImageRendererFormat(); format.scale = Self.scale; format.opaque = true
        let shot = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
        }
        guard let cg = shot.cgImage else { return }
        let input = CIImage(cgImage: cg)
        let blurred = input.clampedToExtent()
            .applyingGaussianBlur(sigma: Double(Self.blur * Self.scale) / 2)
            .cropped(to: input.extent)
        if let out = context.createCGImage(blurred, from: input.extent) {
            image = UIImage(cgImage: out, scale: Self.scale, orientation: .up)
        }
        var px = [UInt8](repeating: 0, count: 4)
        let avg = input.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: input.extent)])
        context.render(avg, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        let w = CGFloat(Self.wash)
        func mix(_ v: UInt8) -> CGFloat { w + (1 - w) * CGFloat(v) / 255 }
        pageLuminance = ThemeColor.RGB(r: mix(px[0]), g: mix(px[1]), b: mix(px[2])).luminance
        if TrackPrefetch.log { print("[t335u] backdrop mean luminance \(String(format: "%.2f", pageLuminance))") }
        if TrackPrefetch.log { print("[t335u] backdrop captured in \(Int(Date().timeIntervalSince(t0) * 1000))ms") }
    }
}

struct DetailBackdrop: View {
    @ObservedObject private var backdrop = GridBackdrop.shared
    var body: some View {
        Color(hex: 0xF4F0EE)        // neutral fallback (no snapshot yet)
            .overlay {
                if let image = backdrop.image {
                    Image(uiImage: image).resizable().interpolation(.medium).scaledToFill()
                }
            }
            .overlay { Color.white.opacity(GridBackdrop.wash) }
            .clipped()
            .ignoresSafeArea()
            .allowsHitTesting(false)
    }
}
