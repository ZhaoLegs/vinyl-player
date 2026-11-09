import SwiftUI
import UIKit
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
    @Environment(\.openURL) private var openURL
    @EnvironmentObject private var music: AppleMusicStore
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
    private var cellFrames: [Int: CGRect] { get { zm.cellFrames } nonmutating set { if zm.cellFrames != newValue { zm.cellFrames = newValue } } }
    private var selectedIndex: Int { get { zm.selectedIndex } nonmutating set { zm.selectedIndex = newValue } }

    private var pull: CGFloat { get { zm.pull } nonmutating set { zm.pull = newValue } }
    private var flip: Double { get { zm.flip } nonmutating set { zm.flip = newValue } }
    private var demoToken: Int { get { zm.demoToken } nonmutating set { zm.demoToken = newValue } }
    private var motionStart: Date { get { zm.motionStart } nonmutating set { zm.motionStart = newValue } }
    private var recordingStarted: Bool { get { zm.recordingStarted } nonmutating set { zm.recordingStarted = newValue } }
    private var recordingRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("--record-demo")
    }

    // 网格几何按原片实测：4 列、列宽 72pt、间距 17pt、左右 27pt
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 18), count: 4)

    var body: some View {
        if overlayMode {
            detailLayer
                .onPreferenceChange(SleeveFrameKey.self) { sleeveFrame = $0 }
                .allowsHitTesting(presented)
        } else {
            homeBody
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
            .onPreferenceChange(CoverFrameKey.self) { frames in
                cellFrames = frames
                // 关闭飞行期间用户滚动首页：目标格子的实时 frame 每帧更新到 origin，
                // CoverFlight 用当前弹簧进度向这个实时 frame 插值，落点永远在格子上。
                if closing, let key = targetKey, let live = frames[key] { origin = live }
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
            GlassCircleButton(systemImage: "square.3.layers.3d.down.right",
                              accessibilityText: music.authorized ? "Vinyl" : "连接 Apple Music") {
                connectMusic()
            }
            // 隐藏调试：长按循环切换放大曲线 A/B/C，并短暂显示曲线名
            .simultaneousGesture(LongPressGesture(minimumDuration: 0.6).onEnded { _ in
                let curve = Motion.cycleZoomCurve()
                withAnimation(.easeOut(duration: 0.15)) { curveLabel = curve.name }
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1))
                    withAnimation(.easeIn(duration: 0.2)) { curveLabel = nil }
                }
            })
            Spacer(minLength: 0)
            GlassCircleButton(systemImage: "cube", accessibilityText: "刷新资料库") {
                if music.authorized {
                    Task { await music.refreshHome() }
                } else { connectMusic() }
            }
        }
        .padding(.horizontal, DS.contentInset)
        .padding(.top, 6)
    }

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
                    // t158u：没有真实正在播放的曲目时不显示假的 mini player
                    if music.hasCurrentTrack || DemoMode.enabled {
                        MiniPlayer(open: openNowPlaying)
                            .padding(.horizontal, DS.tabBarSideInset)
                            .padding(.bottom, DS.miniPlayerBottomPadding)
                            .transition(.opacity)
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
                if music.hasCurrentTrack || DemoMode.enabled {
                    MiniPlayer(open: openNowPlaying)
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
                        musicCell(index, collection)
                            .id(1000 + index)
                    }
                }
            }
            .padding(.horizontal, DS.contentInset)
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
            proxy.scrollTo(key, anchor: .center)
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
        .modifier(GridRipple(progress: zoom, closing: closing,
                             anchor: gridAnchorUnit,
                             enabled: (Motion.zoomPerAxis || Motion.zoomFluid) && !reduceMotion))
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
            ArtworkFill(artwork: collection.artwork)   // 与飞行封面 / 封套同一渲染尺寸，避免换分辨率
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
        .modifier(TileReveal(progress: zoom, isTarget: presented && selectedCollection?.id == collection.id,
                             closing: closing))
        .accessibilityLabel("\(collection.title)，\(collection.artist)")
    }

    /// 点开真实集合：沿用同一套放大转场 + 唱片自动滑出，同时读取曲目并从第一首可播放的歌开始播。
    private func openCollection(_ collection: MusicCollection, startPlayback: Bool = true) {
        selectedCollection = collection
        nowPlayingCollection = collection
        collectionSongs = nil
        open()
        Task {
            do {
                let songs = try await collection.songs()
                guard selectedCollection?.id == collection.id else { return }
                collectionSongs = songs
                if startPlayback, let first = songs.first(where: { $0.playParameters != nil }) {
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
        if music.hasCurrentTrack, let collection = nowPlayingCollection {
            let i = music.collections.firstIndex { $0.id == collection.id }
            origin = i.flatMap { cellFrames[1000 + $0] } ?? origin
            targetKey = i.map { 1000 + $0 }
            openCollection(collection, startPlayback: false)
        } else {
            let index = AlbumData.featuredIndex
            origin = cellFrames[index] ?? origin
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
        .modifier(TileReveal(progress: zoom, isTarget: presented && selectedCollection == nil && selectedIndex == index,
                             closing: closing))
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
            wipe: wipe,
            keepsSpinning: !recordingRequested,
            motionStart: motionStart,
            onClose: { close() },
            onToggleArtwork: { toggleArtwork() },
            canPage: { dir in pageNeighbor(dir) != nil },
            onSwipeBegan: { swipeBegan() },
            onPage: { dir in pageAlbum(dir) },
            onSwipeSettled: { swipeSettled() }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    private var flyingCover: some View {
        let start = flightStart
        let end = flightEnd
        return Group {
            if let selectedCollection {
                ArtworkFill(artwork: selectedCollection.artwork)
            } else {
                Image(DS.coverName(selectedIndex)).resizable()
            }
        }
            .modifier(CoverFlight(progress: zoom, start: start, end: end, closing: closing, landed: landed,
                                 discCover: DS.coverName(selectedIndex),
                                 discArtwork: selectedCollection?.artwork,
                                 perAxis: Motion.zoomPerAxis && !reduceMotion,
                                 fluid: Motion.zoomFluid && !reduceMotion))
            .opacity(presented && !reduceMotion ? 1 : 0)
    }

    // MARK: - 动效时序（对应原片 185 帧 / 30fps）

    private func open() {
        guard !presented else { return }
        presented = true
        closing = false
        autoplay = true
        pull = 0
        flip = 0
        motionStart = Date()
        // 一条主 spring 驱动封面缩放与背景模糊（同一进度，不再各跑一条曲线）；
        // 详情文字用带 delay 的从曲线错峰淡入，形成「先放大 → 再显内容」的节奏。
        landed = false
        var noAnim = Transaction(); noAnim.disablesAnimations = true
        withTransaction(noAnim) { wipe = 0 }
        // t149u：按本次格子 → 封套的距离决定弹簧时长（封面、网格缩放、模糊、抽唱片延迟共用）
        Motion.setFlight(start: flightStart, end: flightEnd)
        withAnimation(reduceMotion ? .easeOut(duration: 0.15) : Motion.animation(Motion.open),
                      completionCriteria: .logicallyComplete) {
            zoom = 1
        } completion: {
            if presented && !closing { landed = true }
        }
        withAnimation(reduceMotion ? .easeOut(duration: 0.15) : Motion.zoomBackdrop) {
            blurRadius = 18
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
    /// 开始横滑：唱片先收回封套
    private func swipeBegan() {
        demoToken += 1          // 取消尚未执行的自动抽出
        flipBusy = false
        withAnimation(Motion.animation(Motion.retract)) { pull = 0 }
    }
    /// 换到相邻专辑：只换展示内容，不动播放
    private func pageAlbum(_ dir: Int) {
        guard let key = pageNeighbor(dir) else { return }
        var t = Transaction(); t.disablesAnimations = true
        withTransaction(t) {
            pull = 0
            flip = 0
            targetKey = key
            if key >= 1000 {
                let c = music.collections[key - 1000]
                selectedCollection = c
                collectionSongs = nil
                Task {
                    let songs = (try? await c.songs()) ?? []
                    guard selectedCollection?.id == c.id else { return }
                    collectionSongs = songs
                }
            } else {
                selectedIndex = key
                selectedCollection = nil
                collectionSongs = nil
            }
            if let f = cellFrames[key] { origin = f }
            scrollRequest = key      // 首页网格滚到该格子，关闭时飞回它
        }
    }
    /// 新封套落定：0.15s 后唱片用原有弹簧抽出
    private func swipeSettled() {
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
        // t131u：飞回「当前显示的那张专辑」的格子（实时 frame）
        if let k = targetKey, let f = cellFrames[k] { origin = f }
        Motion.setFlight(start: flightStart, end: flightEnd)
        landed = false
        // 关闭时封面只做缩放 / 位移回到网格，不做任何翻转：
        // 即使用户翻到了 B 面，也先无动画地把 flip 归零。
        var reset = Transaction()
        reset.disablesAnimations = true
        withTransaction(reset) {
            flip = 0
            // 网格瞬间变清晰、不再变暗：此刻被不透明的详情背景完整盖住，看不到这一跳；
            // 之后背景自上而下擦除，逐步露出清晰的网格。
            blurRadius = 0
            gridDim = 0
            wipe = 0
        }
        closing = true
        autoplay = false
        demoToken += 1
        withAnimation(
            reduceMotion ? .easeOut(duration: 0.15) : Motion.zoomCurve.closeAnimation,
            completionCriteria: .removed
        ) {
            zoom = 0
        } completion: {
            presented = false
            closing = false
            pull = 0
            flip = 0
            recordingMarker("complete")
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
            if flip < 90 {
                if pull > 0.01 {
                    withAnimation(animate ? Motion.animation(Motion.retract) : nil) { pull = 0 }
                    if animate { try? await Task.sleep(for: .seconds(Motion.retract.duration)) }
                }
                guard presented && !closing else { return }
                withAnimation(animate ? Motion.animation(Motion.flip) : nil) { flip = 180 }
                if animate { try? await Task.sleep(for: .seconds(Motion.flip.duration)) }
            } else {
                withAnimation(animate ? Motion.animation(Motion.flip) : nil) { flip = 0 }
                if animate { try? await Task.sleep(for: .seconds(Motion.flip.duration)) }
                guard presented && !closing else { return }
                withAnimation(animate ? Motion.animation(Motion.pull) : nil) { pull = 1 }
                if animate { try? await Task.sleep(for: .seconds(Motion.pull.duration)) }
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
    var perAxis: Bool = true
    /// t147u：单一进度 + 弧线（与 perAxis 互斥）
    var fluid: Bool = false

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
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
        let gs: CGFloat = (perAxis || fluid) ? CGFloat(FlightCurves.gridScale(u, closing: closing)) : 1
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
                    VinylDiscView(angle: .zero, pull: 0, coverName: discCover, artwork: discArtwork)
                        .shadow(radius: 0)
                        .scaleEffect(base / DS.sleeve)
                        .frame(width: holeFull, height: holeFull)
                        .clipShape(Circle())
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: DS.corner * (1 - clamped) / k))
            .compositingGroup()
            .scaleEffect(k, anchor: .center)
            .shadow(color: .black.opacity(0.18 - 0.06 * Double(clamped)), radius: 8, y: 4 + clamped)
            .offset(x: midX - base / 2, y: midY - base / 2)
            .opacity(visible)
    }
}

/// t138u：首页网格整体缩放（与 CoverFlight 同一 progress → 同一帧同一值）
struct GridRipple: AnimatableModifier {
    var progress: CGFloat
    var closing: Bool
    var anchor: UnitPoint
    var enabled: Bool
    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }
    func body(content: Content) -> some View {
        let u = Double(min(1, max(0, closing ? 1 - progress : progress)))
        let s = enabled ? CGFloat(FlightCurves.gridScale(u, closing: closing)) : 1
        let a = anchor
        content.visualEffect { c, _ in c.scaleEffect(s, anchor: a) }
    }
}

struct ArtworkHandoff: AnimatableModifier {
    var progress: CGFloat
    var closing: Bool = false
    var landed: Bool = false

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        // 飞行封面落定后才显示（几何与飞行终点完全一致），关闭时立即隐藏，由飞行封面飞回
        let shown: Double = (!closing && (landed || progress >= 1.5)) ? 1 : 0
        content
            .opacity(shown)
    }
}


/// t121u：关闭时目标格子在缩小的后 35% 就显示在飞行封面下方（飞行封面四边收拢到它身上再淡出），
/// 打开 / 详情期间隐藏，保证屏幕上不会同时出现两个不同尺寸的同一封面。
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
final class LibraryZoomModel: ObservableObject {
    @Published var selectedCollection: MusicCollection?
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
    @Published var cellFrames: [Int: CGRect] = [:]
    @Published var selectedIndex: Int = AlbumData.featuredIndex
    @Published var pull: CGFloat = 0
    @Published var flip: Double = 0
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

/// t158u：演示数据只在模拟器录屏 / 调试参数下使用；正常启动永远不显示假数据
enum DemoMode {
    static let enabled: Bool = {
        let a = ProcessInfo.processInfo.arguments
        return a.contains("--record-demo") || a.contains("--open-featured")
    }()
}

/// t158u：加载中的封面占位：与封面同尺寸、同圆角的浅色方块，无文字
struct HomePlaceholder: View {
    static let count = 20
    var body: some View {
        RoundedRectangle(cornerRadius: DS.corner)
            .fill(Color.primary.opacity(0.05))
            .aspectRatio(1, contentMode: .fit)
            .accessibilityHidden(true)
    }
}
