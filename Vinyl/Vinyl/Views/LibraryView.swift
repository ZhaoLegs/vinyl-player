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
    /// 被点开的真实 Apple Music 集合；nil = 演示封面
    @State private var selectedCollection: MusicCollection?
    @State private var collectionSongs: [Song]?
    @State private var presented = false
    /// 翻面三段动画进行中：期间忽略点击，避免叠加
    @State private var flipBusy = false
    @State private var closing = false
    @State private var autoplay = false
    @State private var zoom: CGFloat = 0
    @State private var contentAlpha: Double = 0
    @State private var blurRadius: CGFloat = 0
    @State private var origin: CGRect = .zero
    @State private var sleeveFrame: CGRect = .zero
    @State private var cellFrames: [Int: CGRect] = [:]
    @State private var selectedIndex = AlbumData.featuredIndex

    @State private var pull: CGFloat = 0
    @State private var flip: Double = 0
    @State private var demoToken = 0
    @State private var motionStart: Date = .distantPast
    @State private var recordingStarted = false
    private var recordingRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("--record-demo")
    }

    // 网格几何按原片实测：4 列、列宽 72pt、间距 17pt、左右 27pt
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 18), count: 4)

    var body: some View {
        GeometryReader { _ in
            ZStack(alignment: .topLeading) {
                AuroraBackground()
                homeContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .opacity(Double(1 - 0.72 * zoom))

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
                    keepsSpinning: !recordingRequested,
                    motionStart: motionStart,
                    onClose: { close() },
                    onToggleArtwork: { toggleArtwork() }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(contentAlpha > 0.5)

                // Keep the view alive while SwiftUI interpolates the target state.
                // Testing `zoom < 1` here removes it as soon as open() sets zoom = 1.
                flyingCover
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
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
            .onPreferenceChange(SleeveFrameKey.self) { sleeveFrame = $0 }
            .toolbar(presented ? .hidden : .visible, for: .tabBar)
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
            // t107u：参考视频左上角字形 = SF Symbol square.stack.3d.down.right（原生 toolbar 尺寸）
            GlassCircleButton(systemImage: "square.stack.3d.down.right",
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
                    Task { await music.loadLibrary(); await music.loadRecommendations() }
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
                    MiniPlayer(open: openNowPlaying)
                        .padding(.horizontal, DS.tabBarSideInset)
                        .padding(.bottom, DS.miniPlayerBottomPadding)
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
                MiniPlayer(open: openNowPlaying)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
            }
        }
    }

    private var gridScroll: some View {
        ScrollView(showsIndicators: false) {
            LazyVGrid(columns: columns, spacing: 18) {
                let real = music.collections
                if real.isEmpty {
                    // 未授权 / 资料库为空：保留内置演示封面
                    ForEach(1...AlbumData.coverCount, id: \.self) { index in
                        coverCell(index)
                    }
                } else {
                    ForEach(Array(real.enumerated()), id: \.element.id) { index, collection in
                        musicCell(index, collection)
                            .onAppear {
                                guard index == real.count - 1 else { return }
                                if music.hasMorePlaylists { Task { await music.loadMore(playlists: true) } }
                                else if music.hasMoreAlbums { Task { await music.loadMore(playlists: false) } }
                            }
                    }
                }
            }
            .padding(.horizontal, DS.contentInset)
            .padding(.top, 12)
            .padding(.bottom, 8)
        }
        .blur(radius: blurRadius)
    }

    /// 真实 Apple Music 封面格：与演示封面同尺寸、同圆角、同投影。
    @State private var nowPlayingCollection: MusicCollection? = nil

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
                                               value: [key: geo.frame(in: .named("library"))])
                    }
                }
        }
        .buttonStyle(.plain)
        // 转场期间源格子隐藏：屏幕上始终只有一个封面
        .opacity(presented && selectedCollection?.id == collection.id ? 0 : 1)
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
            Task { await music.loadLibrary() }
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
                                               value: [index: geo.frame(in: .named("library"))])
                    }
                }
        }
        .buttonStyle(.plain)
        .opacity(presented && selectedCollection == nil && selectedIndex == index ? 0 : 1)
    }

    // MARK: - Zoom 转场中的飞行封面

    private var flyingCover: some View {
        let start = origin == .zero
            ? CGRect(x: 27, y: 385, width: 72, height: 72)
            : origin
        let end = sleeveFrame == .zero
            ? CGRect(x: 43.5, y: 130, width: DS.sleeve, height: DS.sleeve)
            : sleeveFrame
        return Group {
            if let selectedCollection {
                ArtworkFill(artwork: selectedCollection.artwork)
            } else {
                Image(DS.coverName(selectedIndex)).resizable()
            }
        }
            .modifier(CoverFlight(progress: zoom, start: start, end: end, closing: closing, landed: landed,
                                 discCover: DS.coverName(selectedIndex),
                                 discArtwork: selectedCollection?.artwork))
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
        withAnimation(reduceMotion ? .easeOut(duration: 0.15) : Motion.animation(Motion.open),
                      completionCriteria: .logicallyComplete) {
            zoom = 1
            blurRadius = 18
        } completion: {
            if presented && !closing { landed = true }
        }
        // Detail copy fades in after the cover has started moving (reference frames 9–16).
        withAnimation(.easeInOut(duration: 7.0 / 30).delay(4.0 / 30)) {
            contentAlpha = 1
        }
        demoToken += 1
    }

    @State private var closeQueued = false
    @State private var curveLabel: String? = nil
    /// 打开弹簧逻辑完成（已落定）→ 详情封套接手
    @State private var landed = false
    /// 关闭飞行的目标格子（cellFrames 的 key），滚动时实时跟踪它的 frame
    @State private var targetKey: Int? = nil

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

    private func beginCloseFlight() {
        guard presented && !closing else { return }
        landed = false
        // 关闭时封面只做缩放 / 位移回到网格，不做任何翻转：
        // 即使用户翻到了 B 面，也先无动画地把 flip 归零。
        var reset = Transaction()
        reset.disablesAnimations = true
        withTransaction(reset) { flip = 0 }
        closing = true
        autoplay = false
        demoToken += 1
        withAnimation(
            reduceMotion ? .easeOut(duration: 0.15) : Motion.animation(Motion.close),
            completionCriteria: .removed
        ) {
            zoom = 0
            blurRadius = 0
        } completion: {
            presented = false
            closing = false
            pull = 0
            flip = 0
            recordingMarker("complete")
        }
        withAnimation(.easeInOut(duration: 6.0 / 30).delay(2.0 / 30)) {
            contentAlpha = 0
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
        guard await pause(150_000_000) else { return }
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

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        // 位置、尺寸、圆角、挖孔全部跟随同一个弹簧进度 p（不走参考路径、不夹断），
        // 弹簧的轻微过冲自然体现为封面越过终点一点再落定。
        let p: CGFloat = progress
        let clamped: CGFloat = min(1, max(0, p))
        let width: CGFloat = start.width + (end.width - start.width) * p
        let midX: CGFloat = start.midX + (end.midX - start.midX) * p
        let midY: CGFloat = start.midY + (end.midY - start.midY) * p
        // 打开：落定（landed）前一直是飞行封面，落定后瞬间交给几何完全相同的详情封套；关闭：始终是飞行封面
        let visible: Double = (closing || !landed) ? 1 : 0
        let hole = width * DS.planet / DS.sleeve
        content
            .frame(width: width, height: width)
            // 封套挖孔随放大逐渐出现，与详情页封套的孔完全一致
            .mask {
                Rectangle()
                    .overlay {
                        Circle().frame(width: hole, height: hole)
                            .opacity(Double(clamped))
                            .blendMode(.destinationOut)
                    }
                    .compositingGroup()
            }
            .background {
                // 孔后是与详情页同一个黑胶视图（等比缩放），交接时孔内画面一致
                VinylDiscView(angle: .zero, pull: 0, coverName: discCover, artwork: discArtwork)
                    .shadow(radius: 0)
                    .scaleEffect(width / DS.sleeve)
                    .frame(width: hole, height: hole)
                    .clipShape(Circle())
                    .opacity(Double(clamped))
            }
            // 圆角随同一弹簧进度连续变化：网格 DS.corner → 详情 0（关闭时反向）
            .clipShape(RoundedRectangle(cornerRadius: DS.corner * (1 - clamped)))
            // 投影从网格封面的 (18%, r8, y4) 连续过渡到详情封套的 (12%, r8, y5)
            .shadow(color: .black.opacity(0.18 - 0.06 * Double(clamped)), radius: 8, y: 4 + clamped)
            .offset(x: midX - width / 2, y: midY - width / 2)
            .opacity(visible)
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
