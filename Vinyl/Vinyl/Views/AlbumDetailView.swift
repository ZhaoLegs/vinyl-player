import SwiftUI
import Foundation
import MusicKit

/// 上报封套在 "library" 坐标空间中的位置，供 zoom 转场计算终点。
struct SleeveFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

struct AlbumDetailView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var music: AppleMusicStore
    @Environment(\.openURL) private var openURL
    /// t230u：唱片角度 = 已累计角度 + 本段播放以来的角度（暂停时定格，不回 0°）
    @State private var spinBase: Double = 0
    @State private var spinFrom: Date? = nil
    /// t236u：左上角关闭圆钮实测直径（首帧前用 44pt 兜底）
    var coverName: String = "sleeve_cutout"
    /// 真实 Apple Music 集合（nil = 内置演示专辑）
    var collection: MusicCollection? = nil
    /// 该集合的歌曲；nil = 仍在读取
    var songs: [Song]? = nil
    var title: String = AlbumData.title
    var artist: String = AlbumData.artist
    let pull: CGFloat
    let flip: Double
    let waveProgress: Double
    let contentAlpha: Double
    let zoom: CGFloat
    let isPresented: Bool
    var closing: Bool = false
    var landed: Bool = false
    var miniOwner: MiniArtworkOwner? = nil
    var miniArtwork: MiniArtworkSnapshot? = nil
    /// t160u：点封面翻面后 = 歌词模式（曲目表淡出、歌词淡入）
    var lyricsMode: Bool = false
    /// 关闭时背景擦除进度（0 → 1，自上而下变透明）
    var wipe: CGFloat = 0
    /// 正常使用时唱片抽出后一直转（正在播放）；录屏演示按原片在 3.067s 停转。
    var keepsSpinning: Bool = true
    let motionStart: Date
    let onClose: () -> Void
    var onSpinAngle: (Double) -> Void = { _ in }
    let onToggleArtwork: () -> Void
    /// t131u：封面区横滑切专辑。dir = +1 下一张（左滑）/ −1 上一张（右滑）
    var canPage: (Int) -> Bool = { _ in false }
    var onSwipeBegan: () -> Void = {}
    var onPage: (Int) -> Void = { _ in }
    var onSwipeSettled: () -> Void = {}
    /// t214u：点「相似专辑」→ 走与横滑相同的换专辑流程（封套滑出 / 滑入、标题逐词浮起、自动播第一首）
    var onJump: (MusicCollection) -> Void = { _ in }

    @State private var pageWidth: CGFloat = 402
    /// 封套跟手的横向位移（pt）
    @State private var swipeX: CGFloat = 0
    /// t154u：逐行出现的时间轴（秒，0 → Reveal.total 线性推进；每行 / 播放条按各自 delay 取 easeOut 进度）
    @State private var reveal: CGFloat = Reveal.total
    /// t157u：播放条入场进度（0 = 在屏幕外，1 = 落位）
    @State private var barIn: CGFloat = 0
    /// t219u：曲目表可视区底边 / 时间条顶边（同一坐标系实测），最后一行（或相似专辑）底 → 时间条顶 = 24pt
    @State private var listBottomY: CGFloat = 0
    /// t251u：封面放大真正落定（landed，来自打开弹簧的 completion）后才淡入：标题 → 曲目表（整块）
    @State private var titleIn: Double = 0
    @State private var listIn: Double = 0
    /// t247u：封套（封面）下缘 / 歌词区顶 —— 歌词滚动区与顶部渐变模糊向上延伸到封面下缘，不再在半路硬切
    @State private var sleeveBottomY: CGFloat = 0
    @State private var lyricsTopY: CGFloat = 0
    private var lyricsGap: CGFloat { sleeveBottomY > 0 && lyricsTopY > sleeveBottomY ? lyricsTopY - sleeveBottomY : 0 }
    @State private var barTopY: CGFloat = 0
    /// t219u：曲目表滚到底的接近程度 0…1（底部模糊在时间条上方的部分随之收拢，不挡最后一行）
    @State private var scrollEnd = DetailScrollEnd()
    @StateObject private var trackRows = TrackRows()
    /// 滑入距离 = 播放条高 42 + 底部间距 10 + 底部安全区（整条完全在屏幕外起步）
    /// （不在 body 里读 UIWindow：那会让整个详情层不渲染；底部安全区由页面 GeometryReader 写入）
    @State private var bottomSafe: CGFloat = 34
    private var barTravel: CGFloat { 42 + 10 + bottomSafe }
    /// nil = 未判定；true = 横向主导（接管）；false = 纵向（交给列表滚动）
    @State private var swipeAxisH: Bool? = nil
    @State private var swipeBusy = false
    @State private var swipeBase: CGFloat = 0
    @State private var swipeSettle = 0
    @State private var favoriteBounce = 0
    /// t172u：专辑主题色（MusicKit Artwork 颜色优先，位图兜底；近白 / 无彩色 → 默认黑）
    @State private var theme = DetailTheme.standard
    private var themeKey: String { collection?.id ?? "demo:" + coverName }

    /// 收藏目标：Apple Music = 正在播放的那首（在本专辑里），否则本专辑第一首；演示 = 当前演示曲目
    private var favoriteTarget: (key: String, song: Song?) {
        if collection != nil, let songs, !songs.isEmpty {
            let song = songs.first(where: { music.isCurrent($0) }) ?? songs[0]
            return ("am:" + song.id.rawValue, song)
        }
        return ("demo:\(coverName):\(music.demoTrack)", nil)
    }
    /// t160u：歌词对象 = 本专辑里正在播放的那首，否则本专辑第一首
    private var lyricsSong: Song? {
        guard let songs, !songs.isEmpty else { return nil }
        return songs.first(where: { music.isCurrent($0) }) ?? songs[0]
    }
    private var favoriteOn: Bool { music.isFavorite(favoriteTarget.key) }

    private func toggleFavorite() {
        let target = favoriteTarget
        favoriteBounce += 1
        Task { await music.toggleFavorite(target.key, song: target.song,
                                          fromCatalog: collection?.isCatalog ?? false) }
    }

    var body: some View {
        let _ = TracklistProfile.count("AlbumDetailView.body")
        let _ = GridScrollProfile.recordUpdate("AlbumDetailView")
        ZStack(alignment: .top) {
            AuroraBackground()
                .opacity(closing ? 1 : contentAlpha)
                .mask(WipeMask(progress: wipe).ignoresSafeArea())
            GeometryReader { geo in
                Color.clear
                    .onAppear { pageWidth = geo.size.width; bottomSafe = geo.safeAreaInsets.bottom > 0 ? geo.safeAreaInsets.bottom : 34 }
                    .onChange(of: geo.size.width) { _, w in pageWidth = w }
                    .onChange(of: geo.safeAreaInsets.bottom) { _, b in bottomSafe = b > 0 ? b : 34 }
            }
            Rectangle()
                .fill(.ultraThinMaterial)
                .opacity(0.35 * (closing ? 1 : contentAlpha))
                .mask(WipeMask(progress: wipe).ignoresSafeArea())
                .ignoresSafeArea()

            VStack(spacing: 0) {
                header
                    .frame(height: 52)
                    .padding(.top, 0)
                    .opacity(isPresented ? stage(0) : 0)

                // 唱片角速度：0 → smoothstep 缓入 → 45°/s 匀速 → smoothstep 缓出 → 0。
                // 累计角度由角速度解析积分得到，C¹ 连续，不再「突然开始 / 突然停住」。
                // t230u：只在真实播放器正在播放「这张专辑」时转（打开但没播 / 暂停 = 停在当前角度），恢复播放时从当前角度缓入继续
                TimelineView(.animation(paused: !isPresented || reduceMotion || spinFrom == nil)) { timeline in
                    let spin = Angle.degrees(reduceMotion ? 0 : spinAngle(at: timeline.date))
                    SleeveArtwork(coverName: coverName, artwork: collection?.artwork, official: collection?.officialQuery,
                                  snapshot: miniArtwork,
                                  pull: pull, flip: flip, spin: spin, pageWidth: pageWidth)
                        .frame(width: DS.sleeve, height: DS.sleeve)
                        .contentShape(Rectangle())
                        .onTapGesture(perform: onToggleArtwork)
                        .onChange(of: spin.degrees, initial: true) { _, angle in onSpinAngle(angle) }
                }
                .frame(width: DS.sleeve, height: DS.sleeve)
                .modifier(ArtworkHandoff(progress: reduceMotion ? 1 : zoom, closing: closing,
                                         landed: landed || reduceMotion, miniOwner: miniOwner))
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: SleeveFrameKey.self,
                                               value: geo.frame(in: .global))
                    }
                )
                // t131u：只在封面区横滑翻专辑（位移在 SleeveFrameKey 测量之后，不影响转场终点）
                .offset(x: swipeX)
                .simultaneousGesture(albumSwipe, including: landed && !closing ? .all : .subviews)
                .sensoryFeedback(.impact(weight: .light), trigger: swipeSettle)
                .onAppear {
                    guard ProcessInfo.processInfo.arguments.contains("--demo-swipe") else { return }
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(3.2))
                        onSwipeBegan()
                        withAnimation(.linear(duration: 0.25)) { swipeX = -110 }
                        try? await Task.sleep(for: .seconds(0.3))
                        commitSwipe(dir: 1)
                    }
                }
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(TrackInset.space)).maxY } action: { sleeveBottomY = $0 }
                // Breathing room under sleeve → track table (preview dtable gap ≈ 30pt).
                .padding(.top, 20)

                if collection != nil {
                    // t160u：曲目表 ⇄ 歌词，同一位置交叉淡变（只动 opacity）
                    ZStack(alignment: .top) {
                        realTrackTable
                            .opacity(lyricsMode ? 0 : 1)
                            .allowsHitTesting(!lyricsMode)
                        if lyricsMode {
                            Group {
                                if let songs, let song = lyricsSong {
                                    LyricsPanel(song: song, songs: songs, albumTitle: title,
                                                fromCatalog: collection?.isCatalog ?? false,
                                                topExtend: lyricsGap)
                                } else if songs != nil {
                                    LyricsPanel.emptyText
                                }
                            }
                            // t247u：歌词区向上延伸到封面下缘（滚动区不再在封面下 60pt 处被截断）
                            .padding(.top, -lyricsGap)
                            // t231u / t247u：顶部高斯渐变模糊从封面下缘一直铺到首行，连续无硬边
                            .overlay(alignment: .top) { lyricsTopFade }
                            .opacity(closing ? contentAlpha : 1)
                            .transition(.asymmetric(
                                insertion: .opacity.animation(.easeOut(duration: Lyrics.fadeIn).delay(Lyrics.fadeInDelay)),
                                removal: .opacity.animation(.easeOut(duration: Lyrics.fadeOut))))
                        }
                    }
                    .animation(.easeOut(duration: Lyrics.fadeOut), value: lyricsMode)
                    .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(TrackInset.space)).minY } action: { lyricsTopY = $0 }
                    .padding(.top, 40)
                    .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(TrackInset.space)).maxY } action: { listBottomY = $0 }
                    // t251u：整个曲目表 / 歌词容器一次性淡入（不逐行），落定后比标题晚 0.06s
                    .opacity(listIn)
                    .visualEffect { [listIn, closing] c, _ in c.offset(y: closing ? 0 : DetailReveal.rise * (1 - listIn)) }
                } else {
                    trackTable
                        .padding(.horizontal, DS.contentInset)
                        .padding(.top, 40)

                    releaseCard
                        .padding(.horizontal, DS.contentInset)
                        .padding(.top, 22)
                        .modifier(rowReveal(AlbumData.tracks.count + 1))

                    Spacer(minLength: 8)
                }

                waveform
                    // t219u：时间条顶边（布局位置；滑入动画的 offset 在后面，不影响这里测得的值）
                    .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(TrackInset.space)).minY } action: { barTopY = $0 }
                    // 与首页 mini player 同宽（与系统 Tab bar 胶囊对齐）
                    .padding(.horizontal, DS.tabBarSideInset)
                    .padding(.bottom, 10)
                    // 底部渐变高斯模糊：从播放条顶部往上 24pt 处的全透明，渐变到屏幕底边最强；
                    // 与首页 mini player 下的系统 scroll-edge 模糊效果对应。
                    // t166u：底部渐变高斯模糊改为独立的更高一层（见 bottomFade），只淡入淡出、不随播放条位移
                    .background(alignment: .bottom) {
                        bottomFade
                            .offset(y: closing ? 0 : -(1 - barIn) * barTravel)   // 抵消播放条的滑入位移 → 模糊层本身原地淡入
                    }
                    // t157u：封面放大结束（landed）后，播放条从屏幕底边外向上滑入 + 淡入（spring 0.4s，bounce 0）；
                    // 关闭时仍随 contentAlpha 一起 0.12s 快速淡出（不位移）
                    .opacity(closing ? contentAlpha : (contentAlpha > 0.001 ? Double(barIn) : 0))
                    .offset(y: closing ? 0 : (1 - barIn) * barTravel)
            }
            .coordinateSpace(.named(TrackInset.space))
            // 不再给整列加 contentAlpha：封套只受 ArtworkHandoff 控制（全显 / 全隐），
            // 不会出现半透明封套透出唱片的「鬼影」帧；其余内容各自按 stage() 淡入。
        }
        .onChange(of: songs, initial: true) { _, tracks in trackRows.prepare(tracks ?? []) }
        .onAppear {
            startReveal(delay: openRevealDelay)
            // 横滑换专辑时详情视图会重建（@State 归零），封面早已落定 → 时间条直接保持显示，不再消失
            if landed && !closing {
                var t = Transaction(); t.disablesAnimations = true
                withTransaction(t) { barIn = 1 }
            }
        }
        .onChange(of: motionStart) { _, _ in startReveal(delay: openRevealDelay) }
        .onChange(of: motionStart) { _, _ in
            guard miniArtwork != nil else { return }
            spinBase = 0
            spinFrom = nil
            onSpinAngle(0)
        }
        .onAppear { if discSpinning { spinFrom = Date() } }
        .onChange(of: discSpinning) { _, on in
            if on { spinFrom = Date() }
            else { spinBase = spinAngle(at: Date()); spinFrom = nil }
        }
        .onChange(of: landed) { _, now in
            guard now, !closing else {
                // 新一次打开开始（landed 复位）：瞬间归零，等这次放大落定再淡入
                if !now && !closing { setCopy(0, animated: false) }
                return
            }
            withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(duration: 0.4, bounce: 0)) { barIn = 1 }
            setCopy(1, animated: !reduceMotion)
        }
        // t251u：关闭 → 标题 / 曲目表 0.15s 快速淡出，封面飞回期间不可见
        .onChange(of: closing) { _, now in if now { setCopy(0, animated: true) } }
        .onAppear {
            // 横滑换专辑 / 视图重建时封面早已落定：直接显示
            if landed && !closing { setCopy(1, animated: false) }
        }
        // t169u：详情页打开 / 横滑换专辑 → 预取本专辑歌词（正在播放 / 第一首优先，其余随后）
        .task(id: "\(isPresented)-" + (songs ?? []).map(\.id.rawValue).joined(separator: ",")) {
            guard isPresented, let songs, !songs.isEmpty else { return }
            let first = lyricsSong.map { [$0] } ?? []
            LyricsStore.shared.prefetch(first + songs.filter { $0.id != first.first?.id }, reason: "album")
        }
        .environment(\.detailTheme, theme)
        // t172u：换专辑时主题色 0.25s 交叉过渡
        .animation(.easeInOut(duration: 0.25), value: theme)
        .task(id: themeKey) { await loadTheme() }
        .onChange(of: isPresented) { _, shown in
            // t156u：关闭完成后把逐行时间轴归零，下次打开从头错峰
            guard !shown else { return }
            var t = Transaction(); t.disablesAnimations = true
            withTransaction(t) { reveal = 0; barIn = 0; titleIn = 0; listIn = 0 }
        }
        .task {
            guard demoLevels == nil,
                  let url = Bundle.main.url(forResource: "demo-audio", withExtension: "m4a")
                    ?? Bundle.main.url(forResource: "demo-audio", withExtension: "wav") else { return }
            demoLevels = try? await WaveformAnalyzer.shared.levels(for: url)
        }
    }

    private func loadTheme() async {
        let key = themeKey
        let picked: (ThemeColor.RGB?, String)
        if let hit = ThemeColor.cache[key] {
            picked = hit
        } else if let art = collection?.artwork, case let r = ThemeColor.fromArtwork(art), r.1 != "no-artwork-colors" {
            picked = r
        } else {
            let name = coverName
            picked = await Task.detached(priority: .userInitiated) { ThemeColor.fromImage(UIImage(named: name)) }.value
        }
        ThemeColor.cache[key] = picked
        print("[t172u] theme \(title): \(picked.1) \(picked.0?.hex ?? "default black")")
        let next = picked.0.map { DetailTheme.tinted(Color(red: $0.r, green: $0.g, blue: $0.b)) } ?? .standard
        if next != theme { theme = next }
    }

    // MARK: - t166u 底部渐变高斯模糊

    /// 播放条顶部往上 BottomFade.above 起：模糊 0 → 底边最强（单层 material + 平滑多段 alpha 渐变遮罩，无色带），
    /// 叠页面底色 0 → 0.85 渐变；位于曲目表 / 歌词之上、播放条之下，不接收触摸。
    /// t231u：歌词层顶部渐变模糊（强 → 弱），高度 LyricsTopFade.height；不挡触摸
    private var lyricsTopFade: some View {
        TopProgressiveBlurMaterial(height: lyricsGap + LyricsTopFade.height)
    }

    private var bottomFade: some View {
        DetailBottomFade(end: scrollEnd, lyricsMode: lyricsMode)
    }

    /// t219u：= 24 + (列表可视区底 − 时间条顶)；两者在 VStack 里相接时就是 24pt
    private var trackBottomInset: CGFloat {
        TrackInset.bottomPadding(listBottom: listBottomY, barTop: barTopY)
    }

    // MARK: - t154u 逐行出现

    /// 打开：在封面飞行进度 ≈ 85% 时开始。Fluid 是 bounce 0 的临界阻尼弹簧
    /// x(t) = 1 − (1 + ωt)e^(−ωt)，ω = 2π / d；x = 0.85 ⇔ ωt ≈ 3.37 ⇔ t ≈ 0.536·d。
    private var openRevealDelay: Double {
        switch Motion.zoomCurve {
        case .fluid: return 0.536 * Motion.fluidOpen
        case .ref: return 0.85 * Motion.refOpen
        default: return 0.85 * 0.4
        }
    }

    private func startReveal(delay: Double) {
        var t = Transaction(); t.disablesAnimations = true
        if reduceMotion { withTransaction(t) { reveal = Reveal.total }; return }
        withTransaction(t) { reveal = 0 }
        if !landed { withTransaction(t) { barIn = 0 } }
        withAnimation(.linear(duration: Double(Reveal.total)).delay(delay)) { reveal = Reveal.total }
    }

    /// t251u：标题 / 曲目表的显隐。淡入：标题 0.28s easeOut，曲目表晚 0.06s；淡出：两者 0.15s。
    /// 每次都以目标值收尾（不依赖上一次动画是否跑完），快速开关也不会停在半透明。
    private func setCopy(_ v: Double, animated: Bool) {
        if DetailReveal.log { print("[t251u] setCopy \(v) animated=\(animated) t=\(Date().timeIntervalSince1970)") }
        if !animated {
            var t = Transaction(); t.disablesAnimations = true
            withTransaction(t) { titleIn = v; listIn = v }
        } else if v > 0 {
            withAnimation(.easeOut(duration: DetailReveal.fadeIn)) { titleIn = v }
            withAnimation(.easeOut(duration: DetailReveal.fadeIn).delay(DetailReveal.listDelay)) { listIn = v }
        } else {
            withAnimation(.easeOut(duration: DetailReveal.fadeOut)) { titleIn = v; listIn = v }
        }
    }

    /// 第 i 行（0 = 表头）：delay = i × 0.035s（上限 0.35s）；首屏之外的行（i > 10）不参与错峰，直接显示
    /// t251u：真实专辑 / 歌单（collection != nil）不再逐行错峰 —— 整个容器由 listIn 统一淡入
    private func rowReveal(_ i: Int) -> StaggerReveal {
        if collection != nil {
            return StaggerReveal(reveal: Reveal.total, delay: 0, duration: 0.001, rise: 0, closing: false, closeAlpha: 1)
        }
        let d: CGFloat = i > Reveal.visibleRows ? 0 : min(Reveal.maxStagger, CGFloat(i) * Reveal.stagger)
        return StaggerReveal(reveal: i > Reveal.visibleRows ? Reveal.total : reveal, delay: d,
                             duration: Reveal.rowDuration, rise: Reveal.rowRise,
                             closing: closing, closeAlpha: contentAlpha)
    }

    /// 详情内容分层淡入：标题 → 曲目 → 发行信息 → 波形条，比整体淡入更接近系统转场
    private func stage(_ delay: Double) -> Double {
        max(0, min(1, (contentAlpha - delay) / (1 - delay)))
    }

    /// 角速度积分（度）。smoothstep(u)=3u²-2u³，其积分 S(u)=u³-0.5u⁴，S(1)=0.5。
    /// 缓入段 ∫peak·smoothstep = peak·ramp·S(u)；匀速段 peak·Δt；
    /// 缓出段 ∫peak·(1-smoothstep) = peak·ramp·(u - S(u))。
    private func spinDegrees(_ t: TimeInterval) -> Double {
        let start = 1.2, ramp = 0.17, peak = Motion.spinPeak
        let end = keepsSpinning ? Double.infinity : 3.067
        guard t > start else { return 0 }
        let S = { (u: Double) -> Double in u * u * u - 0.5 * u * u * u * u }

        var acc = 0.0
        let a = min(max(t - start, 0), ramp)
        acc += peak * ramp * S(a / ramp)                       // 缓入

        if t > start + ramp {
            let b = min(t, end - ramp) - (start + ramp)
            if b > 0 { acc += peak * b }                       // 匀速
        }
        if t > end - ramp {
            let u = min(max(t - (end - ramp), 0), ramp) / ramp
            acc += peak * ramp * (u - S(u))                    // 缓出
        }
        return acc                                             // 到 end 后停在最终角度
    }

    // MARK: - 封面横滑切专辑（t131u）

    /// 判定阈值：最小 10pt 才开始识别；|dx| > 1.4·|dy| 才算横向主导（否则交给列表纵向滚动）；
    /// 松手位移 > 70pt 或预测位移 > 160pt 即翻页；首尾专辑橡皮筋阻尼。
    private var albumSwipe: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { v in
                guard !swipeBusy else { return }
                let dx = v.translation.width, dy = v.translation.height
                if swipeAxisH == nil {
                    swipeAxisH = abs(dx) > abs(dy) * 1.4
                    // t185u：以识别那一刻的位移为零点，封套 + 唱片从 0 开始跟手，不会跳 10pt
                    if swipeAxisH == true { swipeBase = dx; onSwipeBegan() }
                }
                guard swipeAxisH == true else { return }
                let x = dx - swipeBase
                let dir = x < 0 ? 1 : -1
                swipeX = canPage(dir) ? x : rubberBand(x)
            }
            .onEnded { v in
                defer { swipeAxisH = nil }
                guard swipeAxisH == true, !swipeBusy else { return }
                let dx = v.translation.width - swipeBase
                let dir = dx < 0 ? 1 : -1
                let flick = abs(v.predictedEndTranslation.width) > 160
                if canPage(dir) && (abs(dx) > 70 || flick) {
                    commitSwipe(dir: dir)
                } else {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.82), completionCriteria: .logicallyComplete) {
                        swipeX = 0
                    } completion: { onSwipeSettled() }
                }
            }
    }

    /// 首尾：位移按 x·0.55 / (1 + |x|/220) 衰减，最多拉出约 120pt
    private func rubberBand(_ x: CGFloat) -> CGFloat {
        x * 0.55 / (1 + abs(x) / 220)
    }

    /// 旧封套顺手势方向滑出 → 换专辑 → 新封套从另一侧滑入落定 → 轻触觉 → 0.15s 后唱片抽出
    private func commitSwipe(dir: Int) {
        swipeBusy = true
        let out = -CGFloat(dir) * (pageWidth + 40)
        withAnimation(.easeIn(duration: 0.16), completionCriteria: .logicallyComplete) {
            swipeX = out
        } completion: {
            onPage(dir)
            // t154u：新专辑的曲目表同样逐行出现（随新封套滑入开始）
            startReveal(delay: 0.08)
            var t = Transaction(); t.disablesAnimations = true
            withTransaction(t) { swipeX = -out }
            withAnimation(.spring(response: 0.38, dampingFraction: 0.86), completionCriteria: .logicallyComplete) {
                swipeX = 0
            } completion: {
                swipeBusy = false
                swipeSettle += 1
                onSwipeSettled()
            }
        }
    }

    /// t214u：与 commitSwipe 同一套动画，只是目标专辑由外部给定
    private func commitJump(to c: MusicCollection) {
        swipeBusy = true
        let dir = 1
        let out = -CGFloat(dir) * (pageWidth + 40)
        withAnimation(.easeIn(duration: 0.16), completionCriteria: .logicallyComplete) {
            swipeX = out
        } completion: {
            onJump(c)
            startReveal(delay: 0.08)
            var t = Transaction(); t.disablesAnimations = true
            withTransaction(t) { swipeX = -out }
            withAnimation(.spring(response: 0.38, dampingFraction: 0.86), completionCriteria: .logicallyComplete) {
                swipeX = 0
            } completion: {
                swipeBusy = false
                swipeSettle += 1
                onSwipeSettled()
            }
        }
    }

    // MARK: - 顶部栏

    private var header: some View {
        HStack(spacing: 0) {
            // 苹果系统控件库：GlassButtonStyle（.buttonStyle(.glass)），
            // 形状 / 材质 / 按压高光 / 无障碍全部由系统渲染，工程内不自绘圆。
            GlassCircleButton(systemImage: "xmark",
                              accessibilityText: "关闭", action: onClose)

            // t129u：标题 / 艺人各限一行，超长在右侧以 … 截断；占满两按钮之间（两侧各留 10pt），绝不压到按钮
            VStack(spacing: 1) {
                // t188u：横滑换专辑时，标题 / 艺人与迷你播放条同款逐词上飘（FloatingText，同一组参数）；
                // 放不下时整行上飘 + 单行 … 截断；颜色跟随主题色
                FloatingText(key: themeKey,
                             tokens: FloatingText.words(title, font: .system(size: 16, weight: .semibold)),   // t202u：14 → 16pt
                             color: theme.ink, alignment: .center, animateOnAppear: false)
                FloatingText(key: themeKey,
                             tokens: FloatingText.words(artist, font: .system(size: 11)),
                             color: theme.dim, startDelay: 0.08, alignment: .center, animateOnAppear: false)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 10)
            // t251u：标题 / 艺人在放大落定后淡入 + 上浮 8 → 0（只做视觉位移，不影响布局测量）
            .opacity(titleIn)
            .visualEffect { [titleIn, closing] c, _ in c.offset(y: closing ? 0 : DetailReveal.rise * (1 - titleIn)) }

            // t238u：右上角只留「更多」——与左侧关闭钮同规格的系统玻璃圆钮（同 label / 同 glass 样式 → 同直径、同图标、同中线），
            // 点击弹原生 Menu；「喜欢」已并入菜单顶栏（MenuTopBar）
            GlassCircleMenu(systemImage: "ellipsis", accessibilityText: "更多") {
                if let collection { detailMenu(collection) }
            }
            .disabled(collection == nil)
        }
        .padding(.horizontal, DS.contentInset)
    }

    // MARK: - 曲目表

    // MARK: - 波形条（真实播放进度）

    /// Apple Music 正在播放属于本集合的歌时：进度 = playbackTime / duration，
    /// 高度 = 以歌曲 ID 为种子的伪波形（DRM 拿不到采样）。否则保持演示波形。
    /// t230u：唱片是否该转（以播放器 playbackStatus 为准；演示模式看演示播放状态）
    private var discSpinning: Bool {
        guard isPresented, !closing else { return false }
        if miniArtwork != nil, !landed { return false }
        if collection != nil { return albumIsPlaying && music.isPlaying }
        return music.demoPlaying
    }
    /// 缓入 0.3s（smoothstep 角速度积分，C¹ 连续）后匀速 Motion.spinPeak °/s
    private func spinAngle(at date: Date) -> Double {
        guard let from = spinFrom else { return spinBase }
        let x = max(0, date.timeIntervalSince(from)), r = 0.3, peak = Motion.spinPeak
        let ramped: Double
        if x < r { let u = x / r; ramped = peak * r * (u * u * u - 0.5 * u * u * u * u) }
        else { ramped = peak * (r * 0.5 + (x - r)) }
        return spinBase + ramped
    }

    /// t223u：正在播放的是不是这张专辑（只看本专辑曲目里有没有当前曲目）
    private var albumIsPlaying: Bool {
        guard collection != nil, music.hasCurrentTrack, let songs else { return false }
        return songs.contains { music.isCurrent($0) }
    }

    private var waveform: some View {
        let _ = TracklistProfile.count("DetailWaveform.builder")
        return DetailWaveform(collection: collection, songs: songs,
                              albumIsPlaying: albumIsPlaying, demoLevels: demoLevels)
    }

    /// 内置演示没有音频文件；若包内放入 demo-audio.m4a/.wav，则用 AVAssetReader 实测 RMS。
    @State private var demoLevels: [Double]? = nil

    // MARK: - 真实曲目表（Apple Music）

    private var realTrackTable: some View {
        let _ = TracklistProfile.count("TrackTable.builder")
        return VStack(alignment: .leading, spacing: 0) {
            if let songs {
                if songs.isEmpty {
                    trackTableHeader
                    // t181u：空 / 失败提示在空列表区域（封套底 → 时间条顶）上下、屏幕左右居中
                    Text("这个列表里没有可播放的歌曲")
                        .font(.system(size: 15))
                        .foregroundStyle(theme.dim)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.bottom, TL.headerGap + TL.header)   // 抵消表头高度 → 相对整块空区域居中
                } else {
                    ScrollView(showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 0) {
                            trackTableHeader
                            LazyVStack(alignment: .leading, spacing: 0) {
                                // 行身份 = 歌曲 ID（稳定），切歌时只有两行的颜色 / 图标变化，列表本身不重建
                                ForEach(trackRows.rows, id: \.id) { row in
                                    realRow(row, in: songs)
                                        .modifier(rowReveal(row.index + 1))
                                }
                            }
                            .padding(.horizontal, DS.contentInset)
                        }
                        // 视口上延到实测封面下沿，等高留白保持表头和首行初始位置。
                        .padding(.top, lyricsGap)
                        // t219u：滚到底时最后一行（有相似专辑时 = 相似专辑）底边距时间条顶 24pt，
                        // 由实测的列表底 / 时间条顶算出（不写死安全区 / 播放条高度）
                        .padding(.bottom, trackBottomInset)
                    }
                    .modifier(TopProgressiveBlurMask(height: lyricsGap + LyricsTopFade.height))
                    .overlay(alignment: .top) { lyricsTopFade }
                    .padding(.top, -lyricsGap)
                    .modifier(ScrollEndProximity(range: TrackInset.fadeRange) { scrollEnd.update($0) })
                }
            } else {
                trackTableHeader
                // t181u：读取中的 loading 在空列表区域上下、屏幕左右居中（不再贴在表头下面）
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.bottom, TL.headerGap + TL.header)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var trackTableHeader: some View {
        HStack(spacing: 0) {
            Text("Side")
                .font(.system(size: TL.header, weight: .regular))
                .foregroundStyle(theme.ink)
                .frame(width: TL.sideW, alignment: .leading)
            Text("Time")
                .font(.system(size: TL.header, weight: .regular))
                .foregroundStyle(theme.header)
                .frame(width: TL.bpmW, alignment: .leading)
            Color.clear.frame(width: TL.glyphW, height: 1)
            Text("Tracklist")
                .font(.system(size: TL.header, weight: .regular))
                .foregroundStyle(theme.ink)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.contentInset)
        .padding(.bottom, TL.headerGap)
        .modifier(rowReveal(0))
    }

    /// 歌曲菜单：喜欢 / 共享 → 前往专辑 / 艺人。
    @ViewBuilder
    private func songMenu(_ song: Song) -> some View {
        let catalog = collection?.isCatalog ?? false
        let key = "am:" + song.id.rawValue
        MenuTopBar(liked: music.isFavorite(key),
                   shareURL: song.url,
                   like: { Task { await music.toggleFavorite(key, song: song, fromCatalog: catalog) } })
        Section {
            // 当前页就是这张专辑 → 省略「前往专辑」；歌单里的歌 → 解析它的专辑后用相似专辑同一条换专辑路径打开
            if let album = song.albumTitle, !album.isEmpty, !(collection.map { if case .album = $0 { return true }; return false } ?? false) {
                Button {
                    Task {
                        if let a = try? await song.with([.albums]).albums?.first {
                            await MainActor.run { if !swipeBusy { commitJump(to: .album(a, catalog: catalog)) } }
                        }
                    }
                } label: {
                    Label { Text("前往专辑"); Text(album) } icon: { Image(systemName: "square.stack") }
                }
            }
            if let url = song.artistURL {
                Button { openURL(url) } label: {
                    Label { Text("前往艺人"); Text(song.artistName) } icon: { Image(systemName: "music.microphone") }
                }
            }
        }
    }

    /// t233u：「更多」菜单 = 首页长按同一结构（不含从首页隐藏）
    @ViewBuilder
    private func detailMenu(_ c: MusicCollection) -> some View {
        MenuTopBar(liked: music.isLoved(c),
                   shareURL: c.shareURL,
                   like: { Task { await music.toggleLove(c) } })
        Section {
            Button("随机播放", systemImage: "shuffle") { Task { await music.playCollection(c, shuffle: true) } }
        }
        if let url = c.artistURL {
            Section {
                Button { openURL(url) } label: {
                    Label { Text("前往艺人"); Text(c.artist) } icon: { Image(systemName: "music.microphone") }
                }
            }
        }
    }

    private func realRow(_ row: TrackRowModel, in songs: [Song]) -> some View {
        TracklistProfile.count("TrackRow.builder")
        let song = row.song
        let current = music.isCurrent(song)
        return Button {
            Task {
                if current { await music.togglePlayback() }
                else { await music.play(song, in: songs, fromCatalog: collection?.isCatalog ?? false) }
            }
        } label: {
            TrackRowLabel(side: row.side, time: row.time, title: row.title,
                          current: current, playing: current && music.isPlaying,
                          ink: theme.ink, mid: theme.mid)
                .equatable()
        }
        .buttonStyle(.plain)
        // 不再随 isPreparing 整表禁用（plain 按钮禁用会整体变淡 = 切歌时「闪一下」）；
        // 重复点击由 AppleMusicStore.play 内的 isPreparing 守卫挡掉。
        .disabled(!row.playable)
        .opacity(row.playable ? 1 : 0.45)
        // t229u：歌曲长按菜单（结构对齐 Apple Music）
        .contextMenu { songMenu(song) }
        .animation(.easeInOut(duration: 0.15), value: current)
        .animation(.easeInOut(duration: 0.15), value: current && music.isPlaying)
        .accessibilityLabel("\(current && music.isPlaying ? "暂停" : "播放") \(song.title)，\(song.artistName)")
    }

    private struct TrackRowLabel: View, Equatable {
        let side: String
        let time: String
        let title: String
        let current: Bool
        let playing: Bool
        let ink: Color
        let mid: Color

        var body: some View {
            let _ = TracklistProfile.count("TrackRowLabel.body")
            HStack(spacing: 0) {
                Text(side)
                    .font(.system(size: TL.row, weight: .medium))
                    .foregroundStyle(ink)
                    .frame(width: TL.sideW, alignment: .leading)
                Text(time)
                    .font(.system(size: TL.row, weight: .regular, design: .monospaced))
                    .foregroundStyle(current ? mid : ink)
                    .frame(width: TL.bpmW, alignment: .leading)
                    .lineLimit(1)
                Group {
                    if current {
                        EqualizerGlyph(playing: playing, color: ink, height: TL.glyph * 0.85)
                    } else {
                        Image(systemName: "play.fill")
                            .font(.system(size: TL.glyph, weight: .regular))
                            .foregroundStyle(ink)
                    }
                }
                .frame(width: TL.glyphW - TL.glyphTrail, alignment: .center)
                .padding(.trailing, TL.glyphTrail)
                .offset(x: -TL.iconShift)
                Text(title)
                    .font(.system(size: TL.row, weight: .regular))
                    .foregroundStyle(ink)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .frame(height: TL.pitch)
            .contentShape(Rectangle())
        }
    }

    // 原片实测（960×720 视频，屏宽 289px ↔ 393pt）：列起点相对内容左缘
    // Side 0 / BPM 39.5 / 图标 89.5（原片 81.5，按要求右移 8pt 贴近曲名）/ 曲名 104.5pt；行距 36pt；表头 12pt，曲名 15pt，播放图标 13pt（字形高 ≈ 曲名大写高）。
    private enum TL {
        static let sideW: CGFloat  = 39.5
        static let bpmW: CGFloat   = 50
        static let glyphW: CGFloat = 15
        static let iconShift: CGFloat = 2.0 / 3   // 整列图标左移，play 墨迹右缘 → 歌名 = 8.0pt
        static let glyphTrail: CGFloat = 7.5   // 图标列居中；实测 play.fill 墨迹右缘 → 歌名首字 = 8.0pt
        static let pauseNudge: CGFloat = 2.0 / 3         // 居中后 pause 墨迹中心比 play 偏左 0.67pt，右移使两者墨迹中心重合
        static let header: CGFloat = 12
        static let row: CGFloat    = 15
        static let glyph: CGFloat  = 13
        static let pitch: CGFloat  = 36
        static let headerGap: CGFloat = 16.5
        static let bpmHeader = Color(hex: 0x8F8D8E)
        static let bpm       = Color(hex: 0x7A787B)
        static let idle      = DS.secondary          // 非当前曲目：灰（0x8B8783），当前曲目：DS.ink 黑
    }

    private var trackTable: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Text("Side")
                    .font(.system(size: TL.header, weight: .regular))
                    .foregroundStyle(theme.ink)
                    .frame(width: TL.sideW, alignment: .leading)
                Text("BPM")
                    .font(.system(size: TL.header, weight: .regular))
                    .foregroundStyle(theme.header)
                    .frame(width: TL.bpmW, alignment: .leading)
                Color.clear.frame(width: TL.glyphW, height: 1)
                Text("Tracklist")
                    .font(.system(size: TL.header, weight: .regular))
                    .foregroundStyle(theme.ink)
                Spacer(minLength: 0)
            }
            .padding(.bottom, TL.headerGap)
            .modifier(rowReveal(0))

            ForEach(AlbumData.tracks) { track in
                let index = AlbumData.tracks.firstIndex { $0.id == track.id } ?? 0
                // t131u：灰色「正在播放」行只出现在真正在播放的那张专辑里
                let current = music.demoTrack == index && music.demoCoverName == coverName
                Button { music.selectDemo(index, cover: coverName) } label: {
                    HStack(spacing: 0) {
                        Text(track.side)
                            .font(.system(size: TL.row, weight: .medium))   // Side 字母 A/B：500 (medium)
                            .foregroundStyle(theme.ink)
                            .frame(width: TL.sideW, alignment: .leading)
                        Text("\(track.bpm)")
                            .font(.system(size: TL.row, weight: .regular, design: .monospaced))   // t115u：数字列用 SF Mono
                            .foregroundStyle(current ? theme.mid : theme.ink)   // t104u：播放中灰、其余黑
                            .frame(width: TL.bpmW, alignment: .leading)
                        // SF Symbols：当前曲目播放中 = pause.fill，其余 / 暂停 = play.fill
                        Image(systemName: current && music.demoPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: TL.glyph, weight: .regular))
                            .foregroundStyle(current ? theme.dim : theme.ink)
                            // 图标在列内右对齐：图标右缘 → 歌名首字母（含 D 的 ~1.5pt 字形边距）= 8pt，play / pause 一致
                    .frame(width: TL.glyphW - TL.glyphTrail, alignment: .center)
                    .padding(.trailing, TL.glyphTrail)
                            .offset(x: (current && music.demoPlaying ? TL.pauseNudge : 0) - TL.iconShift)
                        Text(track.title)
                            .font(.system(size: TL.row, weight: .regular))
                            .foregroundStyle(current ? theme.dim : theme.ink)   // t104u：播放中灰、其余黑
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .frame(height: TL.pitch)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .animation(.easeInOut(duration: 0.15), value: current)
                .animation(.easeInOut(duration: 0.15), value: current && music.demoPlaying)
                .accessibilityLabel("\(current && music.demoPlaying ? "暂停" : "播放") \(track.title)")
                .modifier(rowReveal(index + 1))
            }
        }
    }

    // MARK: - 发行信息卡片

    private var releaseCard: some View {
        HStack(spacing: 12) {
            // 原来是从参考视频里截的 58pt 低清占位图 small_art（黑底白色符号），不是封面；
            // 改为该专辑自己的封面资源（与网格 / 封套同一张图）。
            Image(coverName == "sleeve_cutout" ? DS.coverName(AlbumData.featuredIndex) : coverName)
                .resizable()
                .aspectRatio(1, contentMode: .fill)
                .frame(width: 58, height: 58)
                .clipShape(RoundedRectangle(cornerRadius: 2))
                // t137u：这张 58pt 缩略图与飞行封面是同一张图 —— 飞行期间（打开未落定 / 关闭中）完全隐藏，
                // 保证转场的每一帧屏幕上只有一个封面实例；落定后才淡入。
                .opacity(landed && !closing ? 1 : 0)
                .animation(landed && !closing ? .easeOut(duration: 0.2) : nil, value: landed && !closing)

            VStack(alignment: .leading, spacing: 2) {
                Text(AlbumData.artist)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(theme.ink)
                Text(AlbumData.release)
                    .font(.system(size: 13))
                    .foregroundStyle(theme.dim)
                Text(AlbumData.catalog)
                    .font(.system(size: 10))
                    .foregroundStyle(DS.tertiary)
            }
            Spacer(minLength: 0)
        }
    }
}


/// 自上而下的擦除遮罩：progress 0 = 全不透明；随 progress 增大，35% 屏高的羽化带从顶边向下扫过，
/// 上方先变透明，progress 1 时整屏透明。
struct WipeMask: View {
    var progress: CGFloat
    private let feather: CGFloat = 0.35
    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            VStack(spacing: 0) {
                Color.clear.frame(height: h)
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                    .frame(height: h * feather)
                Color.black.frame(height: h * 2)
            }
            .frame(width: geo.size.width, height: h * (3 + feather), alignment: .top)
            // 羽化带顶边位置 = (progress·(1+feather) − feather)·h
            .offset(y: (progress * (1 + feather) - feather) * h - h)
        }
    }
}


// MARK: - t154u 逐行出现参数 + 修饰器（只改 opacity / offset，不触发布局）

/// t251u：详情标题 / 曲目表在封面放大落定后的淡入淡出
enum DetailReveal {
    static let fadeIn: Double = 0.28
    static let listDelay: Double = 0.06
    static let fadeOut: Double = 0.15
    static let rise: CGFloat = 8
    static let log = ProcessInfo.processInfo.arguments.contains("--log-reveal")
}

enum Reveal {
    static let stagger: CGFloat = 0.035
    static let maxStagger: CGFloat = 0.35
    static let visibleRows = 10
    static let rowDuration: CGFloat = 0.28
    static let rowRise: CGFloat = 8
    static let barDuration: CGFloat = 0.25
    static let barRise: CGFloat = 6
    static let total: CGFloat = maxStagger + rowDuration
}

struct StaggerReveal: AnimatableModifier {
    var reveal: CGFloat
    var delay: CGFloat
    var duration: CGFloat
    var rise: CGFloat
    var closing: Bool
    var closeAlpha: Double
    var animatableData: CGFloat {
        get { reveal }
        set { reveal = newValue }
    }
    func body(content: Content) -> some View {
        let t = min(1, max(0, (reveal - delay) / duration))
        let e = 1 - pow(1 - t, 3)   // easeOut
        content
            // t156u：详情未打开（contentAlpha = 0：首次启动 / 关闭完成后）时整块隐藏，不透到首页
            .opacity(closing ? closeAlpha : (closeAlpha > 0.001 ? Double(e) : 0))
            .offset(y: closing ? 0 : rise * (1 - e))
    }
}

// MARK: - 菜单顶栏（喜欢 / 共享）

/// 保持固定两个普通 Button，避免可选 ShareLink 影响原生横排菜单的桥接。
struct MenuTopBar: View {
    let liked: Bool
    let shareURL: URL?
    let like: () -> Void
    var body: some View {
        ControlGroup {
            Button(action: like) { Label(liked ? "取消喜欢" : "喜欢", systemImage: liked ? "star.fill" : "star") }
            Button { if let shareURL { ShareSheet.present(shareURL) } } label: { Label("共享", systemImage: "square.and.arrow.up") }
                .disabled(shareURL == nil)
        }
    }
}

/// 系统分享面板（UIActivityViewController），从最上层 VC 弹出；菜单收起后再弹，避免与菜单动画冲突
enum ShareSheet {
    @MainActor static func present(_ url: URL) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
                  var top = scene.keyWindow?.rootViewController else { return }
            while let p = top.presentedViewController { top = p }
            let vc = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            vc.popoverPresentationController?.sourceView = top.view
            top.present(vc, animated: true)
        }
    }
}

/// Row display strings are prepared only when the queue data changes.
struct TrackRowModel: Identifiable {
    let song: Song
    let index: Int
    let side: String
    let time: String
    let title: String
    let playable: Bool
    var id: MusicItemID { song.id }
}

@MainActor
final class TrackRows: ObservableObject {
    @Published private(set) var rows: [TrackRowModel] = []
    private var source: [Song] = []
    func prepare(_ songs: [Song]) {
        guard source != songs else { return }
        source = songs
        TracklistProfile.count("TrackRows.prepare")
        let half = (songs.count + 1) / 2
        var indices: [MusicItemID: Int] = [:]
        rows = songs.enumerated().map { offset, song in
            let index = indices[song.id] ?? offset
            indices[song.id] = index
            return TrackRowModel(song: song, index: index,
                                 side: index == 0 ? "A" : (index == half && songs.count > 1 ? "B" : ""),
                                 time: musicTime(song.duration ?? 0),
                                 title: "\(song.artistName) - \(song.title)",
                                 playable: song.playParameters != nil)
        }
    }
}

@MainActor
final class DetailScrollEnd: ObservableObject {
    @Published private(set) var proximity: CGFloat = 0
    func update(_ value: CGFloat) {
        guard proximity != value else { return }
        proximity = value
    }
}

private struct DetailBottomFade: View {
    @ObservedObject var end: DetailScrollEnd
    let lyricsMode: Bool
    var body: some View {
        let _ = TracklistProfile.count("DetailBottomFade.body")
        ZStack {
            Rectangle()
                .fill(.regularMaterial)
                .mask(LinearGradient(stops: BottomFade.blurStops, startPoint: .top, endPoint: .bottom))
                .opacity(lyricsMode ? 0.5 : 1)
            LinearGradient(stops: BottomFade.tintStops, startPoint: .top, endPoint: .bottom)
                .opacity(lyricsMode ? 0.5 : 1)
        }
        .animation(.easeOut(duration: 0.25), value: lyricsMode)
        .frame(maxWidth: .infinity)
        .frame(height: BottomFade.height - (BottomFade.above - TrackInset.gap) * (lyricsMode ? 0 : end.proximity))
        .ignoresSafeArea(.container, edges: .bottom)
        .allowsHitTesting(false)
    }
}

private struct DetailWaveform: View {
    @EnvironmentObject private var music: AppleMusicStore
    @EnvironmentObject private var timeline: PlaybackTimeline
    let collection: MusicCollection?
    let songs: [Song]?
    let albumIsPlaying: Bool
    let demoLevels: [Double]?
    var body: some View {
        let _ = TracklistProfile.count("DetailWaveform.body")
        if collection != nil, !albumIsPlaying {
            let first = songs?.first { $0.playParameters != nil }
            WaveformBar(progress: 0,
                        levels: Waveform.seeded(first?.id.rawValue ?? collection?.id ?? "idle"),
                        isPlaying: false,
                        toggle: {
                            guard let first, let songs else { return }
                            Task { await music.play(first, in: songs, fromCatalog: collection?.isCatalog ?? false) }
                        },
                        seek: { _ in }, duration: first?.duration ?? 0)
        } else if collection != nil, music.hasCurrentTrack, let id = music.currentSongID {
            WaveformBar(progress: music.duration > 0 ? timeline.position / music.duration : 0,
                        levels: Waveform.seeded(id.rawValue), isPlaying: music.isPlaying,
                        toggle: { Task { await music.togglePlayback() } },
                        seek: { music.seek(to: $0 * music.duration) }, duration: music.duration)
        } else {
            WaveformBar(progress: timeline.demoElapsed / AppleMusicStore.demoDuration,
                        levels: demoLevels, isPlaying: music.demoPlaying,
                        toggle: { music.selectDemo(music.demoTrack) },
                        seek: { music.seekDemo($0) }, duration: AppleMusicStore.demoDuration)
        }
    }
}

// MARK: - t225u 正在播放：3 柱均衡器

struct EqualizerGlyph: View {
    let playing: Bool
    let color: Color
    var height: CGFloat = 11
    private let rest: [CGFloat] = [0.35, 0.55, 0.30]

    var body: some View {
        let _ = TracklistProfile.count("EqualizerGlyph.body")
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !playing)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: height * 0.16) {
                ForEach(0..<3, id: \.self) { i in
                    let speed = [5.1, 6.7, 4.3][i], phase = [0.0, 1.7, 3.1][i]
                    let live = 0.25 + 0.75 * (0.5 + 0.5 * sin(t * speed + phase))
                    RoundedRectangle(cornerRadius: height * 0.09)
                        .fill(color)
                        .frame(width: height * 0.2, height: height * (playing ? CGFloat(live) : rest[i]))
                }
            }
            .frame(height: height, alignment: .bottom)
        }
        .accessibilityLabel(playing ? "正在播放" : "已暂停")
    }
}

// MARK: - t219u 曲目表底部间距

enum TrackInset {
    static let space = "detailColumn"
    static let gap: CGFloat = 24            // 最后一行 / 相似专辑底 → 时间条顶（与歌词同一规则）
    static let fadeRange: CGFloat = 140     // 距底部 140pt 内模糊逐步收拢
    static func bottomPadding(listBottom: CGFloat, barTop: CGFloat) -> CGFloat {
        guard barTop > 0, listBottom > 0 else { return gap }
        return max(0, gap + listBottom - barTop)
    }
}

/// 滚动视图距离内容底部的接近程度（iOS 18 onScrollGeometryChange；iOS 17 恒为 0）
struct ScrollEndProximity: ViewModifier {
    let range: CGFloat
    let action: (CGFloat) -> Void
    static func proximity(distance: CGFloat, range: CGFloat) -> CGFloat {
        min(1, max(0, 1 - distance / range))
    }
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollGeometryChange(for: CGFloat.self) { g in
                let d = g.contentSize.height + g.contentInsets.bottom - g.visibleRect.maxY
                return Self.proximity(distance: d, range: range)
            } action: { _, proximity in
                action(proximity)
            }
        } else {
            content
        }
    }
}

// MARK: - t160u 歌词（LRCLIB）

/// 歌词与曲目表共用的视口透明度遮罩；只作用于滚动容器，不给歌曲行添加模糊。
struct TopProgressiveBlurMask: ViewModifier {
    let height: CGFloat

    func body(content: Content) -> some View {
        content.mask {
            VStack(spacing: 0) {
                LinearGradient(stops: LyricsTopFade.spanAlphaStops, startPoint: .bottom, endPoint: .top)
                    .frame(height: height)
                Color.black
            }
        }
    }
}

/// 复用歌词原有的单层系统材质；两端透明，不叠白色底色，不拦截手势。
struct TopProgressiveBlurMaterial: View {
    let height: CGFloat

    var body: some View {
        Rectangle()
            .fill(.ultraThinMaterial)
            .mask(LinearGradient(stops: LyricsTopFade.materialStops, startPoint: .top, endPoint: .bottom))
            .opacity(LyricsTopFade.materialOpacity)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .allowsHitTesting(false)
    }
}

/// t166u：底部渐变模糊（不含安全区的可见高度；加上 34pt 安全区 ≈ 196pt）
/// t231u：歌词顶部渐变模糊（封面下缘 → 歌词溶开；与 BottomFade 同手法，方向相反）
enum LyricsTopFade {
    static let height: CGFloat = 38   // t243u：72 → 38pt，强度减半（见 materialOpacity / alphaFloor）
    static let materialOpacity: Double = 0.3   // 0.6 → 0.3
    /// 内容 alpha 渐变：顶边最低 0.35（原 0 → 完全溶掉），保证首行清楚
    static let alphaFloor: Double = 0.35
    static let alphaStops: [Gradient.Stop] = (0...10).map { i in
        let x = Double(i) / 10; let u = min(1, (1 - x) / 0.7); let y = u * u * (3 - 2 * u)
        return .init(color: .black.opacity(1 - (1 - alphaFloor) * (1 - y)), location: x)
    }
    /// t247u：延伸到封面下缘的内容 alpha：封面下缘 0 → 带底 1（smoothstep，startPoint .bottom）——完全溶开，没有可见边
    static let spanAlphaStops: [Gradient.Stop] = (0...12).map { i in
        let x = Double(i) / 12; let u = 1 - x; let y = u * u * (3 - 2 * u)
        return .init(color: .black.opacity(y), location: x)
    }
    /// t247u：模糊层遮罩（startPoint .top）：上缘 0 → 25% 处最强 → 底 0，上下都不出现 material 硬边
    static let materialStops: [Gradient.Stop] = (0...12).map { i in
        let x = Double(i) / 12
        let up = min(1, x / 0.25), down = min(1, (1 - x) / 0.75)
        let y = (up * up * (3 - 2 * up)) * (down * down * (3 - 2 * down))
        return .init(color: .black.opacity(y), location: x)
    }
    /// 顶部满模糊 → 底部 0（smoothstep）
    static let blurStops: [Gradient.Stop] = (0...10).map { i in
        let x = Double(i) / 10; let u = min(1, (1 - x) / 0.7); let y = u * u * (3 - 2 * u)
        return .init(color: .black.opacity(y), location: x)
    }
    /// 页面底色：顶部 ≈0.75 → 底部 0
    static let tintStops: [Gradient.Stop] = (0...10).map { i in
        let x = Double(i) / 10; let u = 1 - x; let y = 0.75 * u * u * (3 - 2 * u)
        return .init(color: Color.white.opacity(y), location: x)
    }
}

enum BottomFade {
    static let above: CGFloat = 110                     // 播放条顶部往上延伸
    static let height: CGFloat = 42 + 10 + above        // 162 + 安全区
    static let contentInset: CGFloat = above + 16       // 列表 / 歌词底部留白
    // 平滑 ease-in 曲线的多段 stop（smoothstep 采样），避免两段线性拐点处的色带
    /// 模糊遮罩：顶部 0 → 60% 处满强度（smoothstep），之后保持最强
    static let blurStops: [Gradient.Stop] = (0...10).map { i in
        let x = Double(i) / 10; let u = min(1, x / 0.6); let y = u * u * (3 - 2 * u)
        return .init(color: .black.opacity(y), location: x)
    }
    /// 页面底色：0 → 0.85（smoothstep，覆盖整段高度）
    static let tintStops: [Gradient.Stop] = (0...10).map { i in
        let x = Double(i) / 10; let y = 0.85 * x * x * (3 - 2 * x)
        return .init(color: Color.white.opacity(y), location: x)
    }
}

// MARK: - t172u 专辑主题色

/// 详情页文字配色：ink = 主文字；dim = 次级（非当前行 / 未唱歌词）；mid = 当前行时间；header = 表头 Time 列
struct DetailTheme: Equatable {
    var ink: Color, dim: Color, mid: Color, header: Color
    /// t180u：时间条未播放竖条
    var track: Color
    static let standard = DetailTheme(ink: DS.ink, dim: DS.secondary, mid: Color(hex: 0x7A787B), header: Color(hex: 0x8F8D8E),
                                      track: Color(hex: 0xB9B5B1))
    static func tinted(_ c: Color) -> DetailTheme {
        DetailTheme(ink: c, dim: c.opacity(0.45), mid: c.opacity(0.62), header: c.opacity(0.55), track: c.opacity(0.3))
    }
}

private struct DetailThemeKey: EnvironmentKey { static let defaultValue = DetailTheme.standard }
extension EnvironmentValues {
    var detailTheme: DetailTheme {
        get { self[DetailThemeKey.self] }
        set { self[DetailThemeKey.self] = newValue }
    }
}

/// 主题色选取：优先 MusicKit Artwork 自带的颜色（background / primary / secondary / tertiary / quaternaryTextColor），
/// 取其中「最饱和、非近白」的一个，压暗到与浅色页面背景对比度 ≥ 4.5:1；都偏灰 / 近白 → nil（默认黑）。
/// 没有 Artwork 颜色（演示 / 本地封面）时才从位图取色（40×40 降采样，后台线程）。
enum ThemeColor {
    static let minChroma: CGFloat = 0.18      // max(r,g,b) − min(r,g,b)，低于此视为无彩色
    static let pageLuminance: CGFloat = 0.88  // 详情页浅色背景（极光 + 白）相对亮度
    static let minContrast: CGFloat = 4.5

    struct RGB { var r, g, b: CGFloat
        var chroma: CGFloat { max(r, g, b) - min(r, g, b) }
        var luminance: CGFloat {
            func l(_ c: CGFloat) -> CGFloat { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
            return 0.2126 * l(r) + 0.7152 * l(g) + 0.0722 * l(b)
        }
        init(r: CGFloat, g: CGFloat, b: CGFloat) { self.r = r; self.g = g; self.b = b }
        init?(_ cg: CGColor?) {
            guard let cg, let c = cg.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil),
                  let p = c.components, p.count >= 3 else { return nil }
            r = p[0]; g = p[1]; b = p[2]
        }
        var hex: String { String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255)) }
    }

    /// 压暗（保持色相）直到对比度达标
    static func readable(_ c: RGB) -> RGB {
        var x = c
        for _ in 0..<40 where (pageLuminance + 0.05) / (x.luminance + 0.05) < minContrast {
            x = RGB(r: x.r * 0.92, g: x.g * 0.92, b: x.b * 0.92)
        }
        return x
    }

    @MainActor static var cache: [String: (RGB?, String)] = [:]

    static func fromArtwork(_ a: Artwork) -> (RGB?, String) {
        let fields: [(String, CGColor?)] = [("backgroundColor", a.backgroundColor), ("primaryTextColor", a.primaryTextColor),
                                            ("secondaryTextColor", a.secondaryTextColor), ("tertiaryTextColor", a.tertiaryTextColor),
                                            ("quaternaryTextColor", a.quaternaryTextColor)]
        let cands = fields.compactMap { f -> (String, RGB)? in RGB(f.1).map { (f.0, $0) } }
        guard !cands.isEmpty else { return (nil, "no-artwork-colors") }
        let ok = cands.filter { $0.1.chroma >= minChroma && $0.1.luminance < 0.85 }
        guard let best = ok.max(by: { $0.1.chroma < $1.1.chroma }) else { return (nil, "neutral→black") }
        return (readable(best.1), best.0)
    }

    /// 位图兜底：40×40，量化到 4bit/通道，按「出现次数 × 色度²」取最佳色块的平均色
    static func fromImage(_ img: UIImage?) -> (RGB?, String) {
        guard let cg = img?.cgImage else { return (nil, "no-image") }
        let n = 40
        var px = [UInt8](repeating: 0, count: n * n * 4)
        guard let ctx = CGContext(data: &px, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return (nil, "ctx") }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: n, height: n))
        var buckets: [Int: (count: Int, r: CGFloat, g: CGFloat, b: CGFloat)] = [:]
        for i in stride(from: 0, to: px.count, by: 4) {
            let c = RGB(r: CGFloat(px[i]) / 255, g: CGFloat(px[i + 1]) / 255, b: CGFloat(px[i + 2]) / 255)
            guard c.chroma >= minChroma, c.luminance < 0.85, c.luminance > 0.01 else { continue }
            let k = (Int(px[i]) >> 4) << 8 | (Int(px[i + 1]) >> 4) << 4 | (Int(px[i + 2]) >> 4)
            var e = buckets[k] ?? (0, 0, 0, 0); e.count += 1; e.r += c.r; e.g += c.g; e.b += c.b; buckets[k] = e
        }
        let minCount = n * n / 50   // 至少占 2%
        let best = buckets.values.filter { $0.count >= minCount }.max { a, b in
            let ca = RGB(r: a.r / CGFloat(a.count), g: a.g / CGFloat(a.count), b: a.b / CGFloat(a.count))
            let cb = RGB(r: b.r / CGFloat(b.count), g: b.g / CGFloat(b.count), b: b.b / CGFloat(b.count))
            return CGFloat(a.count) * ca.chroma * ca.chroma < CGFloat(b.count) * cb.chroma * cb.chroma
        }
        guard let best else { return (nil, "pixels-neutral→black") }
        let c = RGB(r: best.r / CGFloat(best.count), g: best.g / CGFloat(best.count), b: best.b / CGFloat(best.count))
        return (readable(c), "pixels")
    }
}

enum Lyrics {
    static let merge: Double = 0.45        // t245u：0.3 → 0.45（×1.5）；t162u：封套与唱片向中间合拢：spring 0.3s，bounce 0
    static let flip: Double = 0.5          // 封套 Y 轴翻转：spring 0.5s，bounce 0
    static let fadeOut: Double = 0.2       // 曲目表淡出
    static let fadeIn: Double = 0.25       // 歌词淡入
    static let fadeInDelay: Double = merge // t245u：随合拢时长 0.3 → 0.45；t162u：歌词在翻转阶段（合拢 0.3s 之后）淡入
    static let anchor = UnitPoint(x: 0.5, y: 1.0 / 3)   // 当前行滚到列表高度 1/3 处
    static let lineGap: CGFloat = 24      // t248u：16 → 24pt
    // t240u：Apple Music 风格
    static let fontSize: CGFloat = 19     // t248u：16 → 19pt
    static let activeScale: CGFloat = 1.12
    static let dimOpacity: Double = 0.42     // 非当前行（t243u：0.35 → 0.42，6–8 行可读）
    static let unsungOpacity: Double = 0.5   // 当前行未唱部分
    static let scroll = Animation.spring(duration: 0.45, bounce: 0)   // 阻尼 ease-out
    /// t252u：换行上滚时，离当前行越远的行越晚起步（每步 28ms，最多 100ms）——瀑布式延迟，不是整块硬滚
    static let staggerStep: Double = 0.028
    static let staggerMax: Double = 0.100
    static func staggerDelay(_ distance: Int) -> Double {
        min(staggerMax, Double(max(0, distance)) * staggerStep)
    }
    /// 未量到高度时的估算（19pt 粗体单行 ≈ 26，加一点行距）
    static let estimatedLineH: CGFloat = 28
    /// 两侧平分放大余量：当前行居中放大后仍不出界，且换行位置与非当前行一致（不重排）
    static let scaleRoom: CGFloat = 44    // t248u：40 → 44（19pt 行宽 ×1.12 仍在内容宽内，不重排）
    /// t243u：非当前行模糊 1.5 / 2 / 2.5pt（最多 2.5）
    /// t247u：再降 → 0.6 / 0.9 / 1.2pt（最多 1.2）
    static func blur(distance d: Int) -> CGFloat { d <= 0 ? 0 : min(1.2, 0.6 + CGFloat(d - 1) * 0.3) }
    /// t244u：当前行 1.0 → 1.12 弹性放大（上一行同一弹簧缩回），明显可见的小回弹
    static let scaleSpring = Animation.spring(duration: 0.55, bounce: 0.3)
    /// t244u / t253u：已唱字上浮；带轻微过冲曲线（bounce≈0.2），不要阴影（阴影会让浮动和字形对不齐）
    static let lift: CGFloat = 2.5
    /// 上浮进度曲线：easeOut + 轻微过冲，再落回 1（灵动，不橡皮筋）
    static func liftProgress(_ k: Double) -> CGFloat {
        let t = max(0, min(1, k))
        let e = 1 - pow(1 - t, 3)                    // easeOut
        let bounce = 0.20
        let over = e + bounce * sin(.pi * e) * (1 - e) // 中后段略过冲再回落
        return CGFloat(over)
    }
    static var font: Font { .system(size: fontSize, weight: .bold) }
    static let topInset: CGFloat = LyricsTopFade.height * 0.55   // t231u：首行落在顶部模糊带之下，可读；上方溶开
    static let bottomGap: CGFloat = 24     // t175u：最后一行底 → 时间条顶 = 24pt
    static let lookahead: Double = 0.15    // 播放时钟 0.25s 一跳，提前一点点亮下一行
}

/// 同步提供首帧缓存；后台数据仓库负责合并请求、磁盘缓存与失败重试。
@MainActor
final class LyricsStore {
    static let shared = LyricsStore()
    static let maxConcurrent = 3
    private var memory: [String: LyricsCacheEntry] = [:]
    /// 统计（用于日志）
    private(set) var stats = (requested: 0, cached: 0, fetched: 0, found: 0, notFound: 0, failed: 0)

    private func key(_ title: String, _ artist: String, duration: Double?) -> String {
        // 首帧同步读取只做轻量字符串处理；搜索用的简繁转换交给后台仓库。
        [title.lowercased(), artist.lowercased(), duration.map(String.init(describing:)) ?? "unknown"]
            .joined(separator: "\u{1F}")
    }

    /// 同步查内存（歌词面板第一帧直接用，命中就不出现 loading）
    func peek(_ title: String, _ artist: String, duration: Double?) -> LyricsResult? {
        let key = key(title, artist, duration: duration)
        guard let entry = memory[key], entry.valid(at: Date()) else { memory[key] = nil; return nil }
        return entry.value.result
    }

    func lyrics(title: String, artist: String, album: String?, duration: Double?) async throws -> LyricsResult {
        let query = LyricsQuery(title: title, artist: artist, album: album, duration: duration)
        stats.requested += 1
        if let hit = peek(title, artist, duration: duration) { stats.cached += 1; return hit }
        do {
            let entry = try await LyricsRepository.shared.loadEntry(query)
            memory[key(title, artist, duration: duration)] = entry
            stats.fetched += 1
            if entry.value.isFound { stats.found += 1 } else { stats.notFound += 1 }
            return entry.value.result
        } catch {
            stats.failed += 1
            throw error
        }
    }

    /// t169u：后台预取（已缓存的跳过，最多 3 个并发）；列表顺序 = 优先级
    func prefetch(_ songs: [Song], reason: String) {
        let todo = songs.filter { peek($0.title, $0.artistName, duration: $0.duration) == nil }
        guard !todo.isEmpty else { return }
        let skipped = songs.count - todo.count
        Task(priority: .utility) { @MainActor in
            var next = 0
            await withTaskGroup(of: Void.self) { group in
                func add() {
                    guard next < todo.count else { return }
                    let s = todo[next]; next += 1
                    group.addTask { @MainActor in
                        _ = try? await LyricsStore.shared.lyrics(title: s.title, artist: s.artistName,
                                                                album: s.albumTitle, duration: s.duration)
                    }
                }
                for _ in 0..<Self.maxConcurrent { add() }
                while await group.next() != nil { add() }
            }
            let st = stats
            print("[t169u] prefetch \(reason): \(todo.count) queued, \(skipped) already cached | total requested \(st.requested), memory hits \(st.cached), loaded \(st.fetched) (found \(st.found), none \(st.notFound)), failed \(st.failed)")
        }
    }

}

/// 歌词面板：统一 16pt；普通行和逐字填色使用相同字体与居中排版。
struct LyricsPanel: View {
    @EnvironmentObject private var music: AppleMusicStore
    @EnvironmentObject private var timeline: PlaybackTimeline
    @Environment(\.detailTheme) private var theme
    let song: Song
    let songs: [Song]
    let albumTitle: String
    let fromCatalog: Bool
    /// t247u：歌词区向上延伸到封面下缘的高度（内容顶部留白 + alpha 渐变带同步加高）
    var topExtend: CGFloat = 0
    @State private var result: LyricsResult?
    @State private var loadedID: MusicItemID?
    @State private var loadFailed = false
    @State private var retryID = UUID()
    /// 播放时钟 0.25s 一跳：记下最近一次的位置与时刻，帧间按真实时间外推
    @State private var anchorPos: Double = 0
    @State private var anchorDate = Date()
    /// t252u：自绘跟随偏移（替代 ScrollViewReader.scrollTo 的整块硬滚）；各行用不同 delay 追同一目标 → 瀑布延迟
    @State private var followY: CGFloat = 0
    @State private var lineHeights: [Int: CGFloat] = [:]
    @State private var viewportH: CGFloat = 0

    private func lineEnd(_ lines: [LyricLine], _ i: Int) -> Double {
        let start = lines[i].time
        let next = i + 1 < lines.count ? lines[i + 1].time : start + Karaoke.maxLine
        return start + max(0.3, min(Karaoke.maxLine, next - start))
    }

    static var emptyText: some View { EmptyLyrics() }
    struct EmptyLyrics: View {
        @Environment(\.detailTheme) private var theme
        var body: some View {
        Text("暂无歌词")
            .font(.system(size: 15))   // t249u：空状态固定 15pt regular（不跟歌词字号）
            .foregroundStyle(theme.dim)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.bottom, 80)
        }
    }

    var body: some View {
        Group {
            switch loadedID == song.id ? result : LyricsStore.shared.peek(song.title, song.artistName, duration: song.duration) {
            case .synced(let lines)?: synced(lines)
            case .plain(let text)?:
                ScrollView(showsIndicators: false) {
                    Text(text)
                        .font(Lyrics.font)
                        .foregroundStyle(theme.ink.opacity(0.85))
                        .lineSpacing(Lyrics.lineGap)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.horizontal, DS.contentInset)
                        .padding(.top, Lyrics.topInset + topExtend)
                        .padding(.bottom, Lyrics.bottomGap)
                }
                .modifier(TopProgressiveBlurMask(height: topExtend + LyricsTopFade.height))
            case .none?: Self.emptyText
            case nil:
                if loadedID == song.id && loadFailed {
                    Button {
                        loadFailed = false
                        result = nil
                        retryID = UUID()
                    } label: {
                        Text("歌词加载失败，点按重试")
                            .font(.system(size: 15))   // t255u: match empty-state 15pt
                            .foregroundStyle(theme.dim)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 80)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.bottom, 80)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: timeline.position) { _, p in anchorPos = p; anchorDate = Date() }
        .onAppear { anchorPos = timeline.position; anchorDate = Date() }
        .task(id: "\(song.id.rawValue):\(retryID)") {
            let requestID = song.id
            loadFailed = false
            if let hit = LyricsStore.shared.peek(song.title, song.artistName, duration: song.duration) {
                result = hit; loadedID = requestID; return
            }
            do {
                let r = try await LyricsStore.shared.lyrics(title: song.title, artist: song.artistName,
                                                           album: song.albumTitle ?? albumTitle,
                                                           duration: song.duration)
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.2)) { result = r; loadedID = requestID }
            } catch {
                guard !Task.isCancelled else { return }
                result = nil; loadedID = requestID; loadFailed = true
            }
        }
    }

    private func currentIndex(_ lines: [LyricLine]) -> Int {
        guard music.isCurrent(song) else { return -1 }
        let t = timeline.position + Lyrics.lookahead
        guard let first = lines.first, t >= first.time else { return -1 }
        var lo = 0, hi = lines.count - 1
        while lo < hi { let mid = (lo + hi + 1) / 2; if lines[mid].time <= t { lo = mid } else { hi = mid - 1 } }
        return lo
    }

    private func synced(_ lines: [LyricLine]) -> some View {
        let current = currentIndex(lines)
        return GeometryReader { geo in
            ZStack(alignment: .top) {
                VStack(alignment: .center, spacing: Lyrics.lineGap) {
                    ForEach(lines) { line in
                        let isCurrent = line.id == current
                        let d = current < 0 ? 0 : abs(line.id - current)
                        Group {
                            if isCurrent {
                                KaraokeLine(line: line, end: lineEnd(lines, line.id),
                                            anchorPos: anchorPos, anchorDate: anchorDate,
                                            playing: music.isPlaying)
                                    .transition(.identity)
                            } else {
                                Text(line.text)
                                    .font(Lyrics.font)
                                    .foregroundStyle(theme.ink)
                                    .transition(.identity)
                            }
                        }
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, Lyrics.scaleRoom / 2)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .background {
                            GeometryReader { g in
                                Color.clear.preference(key: LyricHeightKey.self,
                                                       value: [line.id: g.size.height])
                            }
                        }
                        .scaleEffect(isCurrent ? Lyrics.activeScale : 1, anchor: .center)
                        .animation(Lyrics.scaleSpring, value: isCurrent)
                        .opacity(isCurrent ? 1 : (current < 0 ? Lyrics.unsungOpacity : Lyrics.dimOpacity))
                        .blur(radius: Lyrics.blur(distance: d))
                        // t252u：同一 followY，离当前行越远 delay 越大 → 上滚时逐行迟一点跟上
                        .offset(y: followY)
                        .animation(Lyrics.scroll.delay(Lyrics.staggerDelay(d)), value: followY)
                        .contentShape(Rectangle())
                        .onTapGesture { seek(to: line) }
                    }
                }
                .padding(.horizontal, DS.contentInset)
                .padding(.top, Lyrics.topInset + topExtend)
                .padding(.bottom, Lyrics.bottomGap)
                .animation(Lyrics.scroll, value: current)   // 透明度 / 模糊随换行一起走
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .modifier(TopProgressiveBlurMask(height: topExtend + LyricsTopFade.height))
            .onAppear { viewportH = geo.size.height; snapFollow(current, lines: lines, animated: false) }
            .onChange(of: geo.size.height) { _, h in viewportH = h; snapFollow(current, lines: lines, animated: false) }
            .onPreferenceChange(LyricHeightKey.self) { lineHeights.merge($0) { _, n in n }; snapFollow(current, lines: lines, animated: false) }
            .onChange(of: current) { _, i in snapFollow(i, lines: lines, animated: i >= 0) }
            .onChange(of: song.id) { _, _ in
                followY = 0; lineHeights = [:]
            }
        }
    }

    /// 把当前行中心放到视口 1/3 处。
    /// animated=true：裸改 followY，让各行自己的 `.animation(scroll.delay(stagger))` 接力追（外层 withAnimation 会吞掉 delay）。
    /// animated=false：瞬间到位（首帧 / 改尺寸 / 量到高度）。
    private func snapFollow(_ current: Int, lines: [LyricLine], animated: Bool) {
        let target: CGFloat = {
            guard current >= 0, viewportH > 0 else { return 0 }
            let topPad = Lyrics.topInset + topExtend
            var y: CGFloat = topPad
            for i in 0..<current {
                y += (lineHeights[i] ?? Lyrics.estimatedLineH) + Lyrics.lineGap
            }
            y += (lineHeights[current] ?? Lyrics.estimatedLineH) / 2
            return viewportH * Lyrics.anchor.y - y
        }()
        if abs(target - followY) < 0.5 { return }
        if animated {
            followY = target
        } else {
            var t = Transaction(); t.disablesAnimations = true
            withTransaction(t) { followY = target }
        }
    }

    /// 点某一行 → 跳到该行时间；不是正在播放的歌就先播放它再跳
    private func seek(to line: LyricLine) {
        if music.isCurrent(song) { music.seek(to: line.time); return }
        Task { @MainActor in
            await music.play(song, in: songs, fromCatalog: fromCatalog)
            for _ in 0..<40 {
                if music.isCurrent(song), music.duration > 0 { music.seek(to: line.time); return }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }
}

/// t252u：各行实测高度（多行折行后）
private struct LyricHeightKey: PreferenceKey {
    static var defaultValue: [Int: CGFloat] = [:]
    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) { value.merge(nextValue()) { _, n in n } }
}

// MARK: - t165u 逐字变黑（卡拉 OK）

enum Karaoke {
    static let maxLine: Double = 8          // 没有下一行 / 间隔过长时，一行最多填 8s
    static let maxExtrapolate: Double = 0.5 // 播放时钟外推上限
}

/// 当前行：灰字底 + 逐字黑色。用同一段 Text 拼接（同字重 600），换行 / 居中与普通行完全一致，
/// 多行时自然一行一行填；边界那个字按小数进度在灰 → 黑之间插值，过渡顺滑。
struct KaraokeLine: View {
    @Environment(\.detailTheme) private var theme
    let line: LyricLine
    let end: Double
    let anchorPos: Double
    let anchorDate: Date
    let playing: Bool

    private var chars: [Character] { Array(line.text) }

    /// 有效字：CJK / 字母 / 数字记 1，空格与标点记 0
    private static func weight(_ c: Character) -> Double {
        c.isLetter || c.isNumber ? 1 : 0
    }

    /// 已唱字数（含小数）
    private func filled(at t: Double) -> Double {
        let cs = chars
        if let marks = line.marks, !marks.isEmpty {
            // 词级时间戳：在相邻两个标记之间按字线性插值
            let pts = [LyricLine.Mark(char: 0, time: line.time)] + marks + [LyricLine.Mark(char: cs.count, time: end)]
            for k in 0..<(pts.count - 1) where t < pts[k + 1].time {
                let a = pts[k], b = pts[k + 1]
                let f = b.time > a.time ? max(0, (t - a.time) / (b.time - a.time)) : 1
                return Double(a.char) + f * Double(b.char - a.char)
            }
            return Double(cs.count)
        }
        let total = cs.reduce(0) { $0 + Self.weight($1) }
        guard total > 0 else { return Double(cs.count) }
        var target = max(0, min(1, (t - line.time) / max(0.01, end - line.time))) * total
        for (i, c) in cs.enumerated() {
            let w = Self.weight(c)
            if w == 0 { continue }
            if target < w { return Double(i) + target / w }
            target -= w
        }
        return Double(cs.count)
    }

    /// t240u：已唱 → 1.0，未唱 → 0.5；边界是约 2.5 个字宽的柔和渐变带，随进度由左到右线性推进（无回弹）。
    /// 逐字着色（而非整块蒙版），多行折行时也是一行一行擦亮。
    static let softWidth: Double = 2.5

    var body: some View {
        TimelineView(.animation(paused: !playing)) { tl in
            let dt = playing ? min(Karaoke.maxExtrapolate, max(0, tl.date.timeIntervalSince(anchorDate))) : 0
            let n = filled(at: anchorPos + dt)
            if #available(iOS 18.0, *) {
                // t244u：TextRenderer 逐字绘制 —— 擦亮 0.5 → 1.0、已唱字上浮 2pt、正在唱的字柔光（只这一行逐帧）
                Text(verbatim: line.text)
                    .font(Lyrics.font)
                    .foregroundStyle(theme.ink)
                    .textRenderer(KaraokeRenderer(n: n, count: chars.count, soft: Self.softWidth, glow: theme.ink))
            } else {
                legacy(n)
            }
        }
    }

    private func legacy(_ n: Double) -> Text {
        do {
            let cs = chars
            let w = Self.softWidth
            // [0, lit) 全亮；[lit, dim) 渐变带；[dim, end) 未唱
            let lit = max(0, min(cs.count, Int(floor(n - w))))
            let dimStart = max(lit, min(cs.count, Int(ceil(n))))
            let hi = theme.ink, lo = theme.ink.opacity(Lyrics.unsungOpacity)
            var text = Text(verbatim: String(cs[0..<lit])).foregroundColor(hi)
            for i in lit..<dimStart {
                let u = max(0, min(1, (n - Double(i)) / w))
                let k = u * u * (3 - 2 * u)
                let o = Lyrics.unsungOpacity + (1 - Lyrics.unsungOpacity) * k
                text = Text("\(text)\(Text(verbatim: String(cs[i])).foregroundColor(theme.ink.opacity(o)))")
            }
            if dimStart < cs.count {
                text = Text("\(text)\(Text(verbatim: String(cs[dimStart...])).foregroundColor(lo))")
            }
            return text.font(Lyrics.font)
        }
    }
}

/// t244u：逐字（glyph）绘制。字序按 glyph 顺序映射到字符进度（CJK 一字一 glyph；拉丁连字时按比例近似）。
@available(iOS 18.0, *)
struct KaraokeRenderer: TextRenderer {
    var n: Double
    var count: Int
    var soft: Double
    var glow: Color   // t253u：保留参数；浮动不再用阴影发光

    func draw(layout: Text.Layout, in ctx: inout GraphicsContext) {
        _ = glow
        let slices = layout.flatMap { $0 }.flatMap { $0 }
        let scale = Double(max(1, count)) / Double(max(1, slices.count))
        for (g, slice) in slices.enumerated() {
            let i = Double(g) * scale
            let u = max(0, min(1, (n - i) / soft))
            let k = u * u * (3 - 2 * u)
            var c = ctx
            // t253u：上浮用曲线进度；不做 shadow（避免字形视觉中心与浮动错位）
            let rise = Lyrics.liftProgress(k)
            c.opacity = Lyrics.unsungOpacity + (1 - Lyrics.unsungOpacity) * k
            c.translateBy(x: 0, y: -Lyrics.lift * rise)
            c.draw(slice)
        }
    }
}

extension Color {
    /// 线性 RGB 插值（用于边界字的灰 → 黑过渡）
    static func mix(_ a: Color, _ b: Color, _ t: Double) -> Color {
        let ua = UIColor(a), ub = UIColor(b)
        var (r1, g1, b1, a1): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        var (r2, g2, b2, a2): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        ua.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        ub.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        let k = CGFloat(max(0, min(1, t)))
        return Color(red: r1 + (r2 - r1) * k, green: g1 + (g2 - g1) * k, blue: b1 + (b2 - b1) * k,
                     opacity: a1 + (a2 - a1) * k)
    }
}
