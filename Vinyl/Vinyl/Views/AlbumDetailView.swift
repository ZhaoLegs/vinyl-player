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
    /// 关闭时背景擦除进度（0 → 1，自上而下变透明）
    var wipe: CGFloat = 0
    /// 正常使用时唱片抽出后一直转（正在播放）；录屏演示按原片在 3.067s 停转。
    var keepsSpinning: Bool = true
    let motionStart: Date
    let onClose: () -> Void
    let onToggleArtwork: () -> Void

    @State private var pageWidth: CGFloat = 402
    @State private var favoriteBounce = 0

    /// 收藏目标：Apple Music = 正在播放的那首（在本专辑里），否则本专辑第一首；演示 = 当前演示曲目
    private var favoriteTarget: (key: String, song: Song?) {
        if collection != nil, let songs, !songs.isEmpty {
            let song = songs.first(where: { music.isCurrent($0) }) ?? songs[0]
            return ("am:" + song.id.rawValue, song)
        }
        return ("demo:\(coverName):\(music.demoTrack)", nil)
    }
    private var favoriteOn: Bool { music.isFavorite(favoriteTarget.key) }

    private func toggleFavorite() {
        let target = favoriteTarget
        favoriteBounce += 1
        Task { await music.toggleFavorite(target.key, song: target.song,
                                          fromCatalog: collection?.isCatalog ?? false) }
    }

    var body: some View {
        ZStack(alignment: .top) {
            AuroraBackground()
                .opacity(closing ? 1 : contentAlpha)
                .mask(WipeMask(progress: wipe).ignoresSafeArea())
            GeometryReader { geo in
                Color.clear
                    .onAppear { pageWidth = geo.size.width }
                    .onChange(of: geo.size.width) { _, w in pageWidth = w }
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
                    .opacity(stage(0))

                // 唱片角速度：0 → smoothstep 缓入 → 45°/s 匀速 → smoothstep 缓出 → 0。
                // 累计角度由角速度解析积分得到，C¹ 连续，不再「突然开始 / 突然停住」。
                TimelineView(.animation(paused: !isPresented || reduceMotion)) { timeline in
                    let elapsed = timeline.date.timeIntervalSince(motionStart)
                    let spin = Angle.degrees(reduceMotion ? 0 : spinDegrees(elapsed))
                    SleeveArtwork(coverName: coverName, artwork: collection?.artwork,
                                  pull: pull, flip: flip, spin: spin, pageWidth: pageWidth)
                        .frame(width: DS.sleeve, height: DS.sleeve)
                        .contentShape(Rectangle())
                        .onTapGesture(perform: onToggleArtwork)
                }
                .frame(width: DS.sleeve, height: DS.sleeve)
                .modifier(ArtworkHandoff(progress: reduceMotion ? 1 : zoom, closing: closing, landed: landed || reduceMotion))
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: SleeveFrameKey.self,
                                               value: geo.frame(in: .global))
                    }
                )
                // Breathing room under sleeve → track table (preview dtable gap ≈ 30pt).
                .padding(.top, 20)

                if collection != nil {
                    realTrackTable
                        .padding(.top, 40)
                        .opacity(stage(0.09))
                } else {
                    trackTable
                        .padding(.horizontal, DS.contentInset)
                        .padding(.top, 40)
                        .opacity(stage(0.09))

                    releaseCard
                        .padding(.horizontal, DS.contentInset)
                        .padding(.top, 22)
                        .opacity(stage(0.17))

                    Spacer(minLength: 8)
                }

                waveform
                    // 与首页 mini player 同宽（与系统 Tab bar 胶囊对齐）
                    .padding(.horizontal, DS.tabBarSideInset)
                    .padding(.bottom, 10)
                    // 底部渐变高斯模糊：从播放条顶部往上 24pt 处的全透明，渐变到屏幕底边最强；
                    // 与首页 mini player 下的系统 scroll-edge 模糊效果对应。
                    .background(alignment: .bottom) {
                        // 底部渐变毛玻璃：播放条顶部往上 48pt 起由透明渐变到屏幕底边最强，
                        // 叠一层页面底色渐变（0 → 0.6），纯色背景上也能看出来；位于内容之上、播放条之下。
                        ZStack {
                            Rectangle()
                                .fill(.regularMaterial)
                                .mask(LinearGradient(stops: [
                                    .init(color: .clear, location: 0),
                                    .init(color: .black.opacity(0.85), location: 0.4),
                                    .init(color: .black, location: 1)
                                ], startPoint: .top, endPoint: .bottom))
                            LinearGradient(colors: [Color.white.opacity(0), Color.white.opacity(0.6)],
                                           startPoint: .top, endPoint: .bottom)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 42 + 10 + 48)
                        .ignoresSafeArea(.container, edges: .bottom)
                        .allowsHitTesting(false)
                    }
                    .opacity(stage(0.24))
            }
            // 不再给整列加 contentAlpha：封套只受 ArtworkHandoff 控制（全显 / 全隐），
            // 不会出现半透明封套透出唱片的「鬼影」帧；其余内容各自按 stage() 淡入。
        }
        .task {
            guard demoLevels == nil,
                  let url = Bundle.main.url(forResource: "demo-audio", withExtension: "m4a")
                    ?? Bundle.main.url(forResource: "demo-audio", withExtension: "wav") else { return }
            demoLevels = try? await WaveformAnalyzer.shared.levels(for: url)
        }
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

    // MARK: - 顶部栏

    private var header: some View {
        HStack(spacing: 0) {
            // 苹果系统控件库：GlassButtonStyle（.buttonStyle(.glass)），
            // 形状 / 材质 / 按压高光 / 无障碍全部由系统渲染，工程内不自绘圆。
            GlassCircleButton(systemImage: "xmark",
                              accessibilityText: "关闭", action: onClose)

            Spacer(minLength: 0)

            VStack(spacing: 1) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(DS.ink)
                Text(artist)
                    .font(.system(size: 11))
                    .foregroundStyle(DS.secondary)
            }

            Spacer(minLength: 0)

            // 右上角：收藏当前播放的歌（无播放时 = 本专辑当前 / 第一首）。heart / heart.fill
            GlassCircleButton(systemImage: favoriteOn ? "heart.fill" : "heart",
                              accessibilityText: favoriteOn ? "取消收藏" : "收藏") {
                toggleFavorite()
            }
            .symbolEffect(.bounce, value: favoriteBounce)
            .sensoryFeedback(.impact(weight: .light), trigger: favoriteBounce)
        }
        .padding(.horizontal, DS.contentInset)
    }

    // MARK: - 曲目表

    // MARK: - 波形条（真实播放进度）

    /// Apple Music 正在播放属于本集合的歌时：进度 = playbackTime / duration，
    /// 高度 = 以歌曲 ID 为种子的伪波形（DRM 拿不到采样）。否则保持演示波形。
    @ViewBuilder
    private var waveform: some View {
        if collection != nil, music.hasCurrentTrack, let id = music.currentSongID {
            WaveformBar(progress: music.duration > 0 ? music.position / music.duration : 0,
                        levels: Waveform.seeded(id.rawValue),
                        isPlaying: music.isPlaying,
                        toggle: { Task { await music.togglePlayback() } },
                        seek: { music.seek(to: $0 * music.duration) },
                        duration: music.duration)
        } else {
            WaveformBar(progress: music.demoElapsed / AppleMusicStore.demoDuration,
                        levels: demoLevels,
                        isPlaying: music.demoPlaying,
                        toggle: { music.selectDemo(music.demoTrack) },
                        seek: { music.seekDemo($0) },
                        duration: AppleMusicStore.demoDuration)
        }
    }

    /// 内置演示没有音频文件；若包内放入 demo-audio.m4a/.wav，则用 AVAssetReader 实测 RMS。
    @State private var demoLevels: [Double]? = nil

    // MARK: - 真实曲目表（Apple Music）

    private var realTrackTable: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Text("Side")
                    .font(.system(size: TL.header, weight: .regular))
                    .foregroundStyle(DS.ink)
                    .frame(width: TL.sideW, alignment: .leading)
                Text("Time")
                    .font(.system(size: TL.header, weight: .regular))
                    .foregroundStyle(TL.bpmHeader)
                    .frame(width: TL.bpmW, alignment: .leading)
                Color.clear.frame(width: TL.glyphW, height: 1)
                Text("Tracklist")
                    .font(.system(size: TL.header, weight: .regular))
                    .foregroundStyle(DS.ink)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DS.contentInset)
            .padding(.bottom, TL.headerGap)

            if let songs {
                if songs.isEmpty {
                    Text("这个列表里没有可播放的歌曲")
                        .font(.system(size: 15))
                        .foregroundStyle(TL.idle)
                        .padding(.horizontal, DS.contentInset)
                    Spacer(minLength: 8)
                } else {
                    ScrollView(showsIndicators: false) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            // 行身份 = 歌曲 ID（稳定），切歌时只有两行的颜色 / 图标变化，列表本身不重建
                            ForEach(songs, id: \.id) { song in
                                realRow(sideIndex[song.id] ?? 0, song, in: songs)
                            }
                        }
                        .padding(.horizontal, DS.contentInset)
                        .padding(.bottom, 8)
                    }
                }
            } else {
                ProgressView()
                    .padding(.horizontal, DS.contentInset)
                Spacer(minLength: 8)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// 歌曲 ID → 序号（只随 songs 变化，切歌不影响）
    private var sideIndex: [MusicItemID: Int] {
        var map: [MusicItemID: Int] = [:]
        for (i, song) in (songs ?? []).enumerated() where map[song.id] == nil { map[song.id] = i }
        return map
    }

    private func realRow(_ index: Int, _ song: Song, in songs: [Song]) -> some View {
        let current = music.isCurrent(song)
        let half = (songs.count + 1) / 2
        let side = index == 0 ? "A" : (index == half && songs.count > 1 ? "B" : "")
        return Button {
            Task {
                if current { await music.togglePlayback() }
                else { await music.play(song, in: songs, fromCatalog: collection?.isCatalog ?? false) }
            }
        } label: {
            HStack(spacing: 0) {
                Text(side)
                    .font(.system(size: TL.row, weight: .medium))   // Side 字母 A/B：500 (medium)
                    .foregroundStyle(DS.ink)
                    .frame(width: TL.sideW, alignment: .leading)
                Text(musicTime(song.duration ?? 0))
                    .font(.system(size: TL.row, weight: .regular, design: .monospaced))   // t115u：时间用 SF Mono
                    .foregroundStyle(current ? TL.bpm : DS.ink)   // t104u：播放中灰、其余黑
                    .frame(width: TL.bpmW, alignment: .leading)
                    .lineLimit(1)
                Image(systemName: current && music.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: TL.glyph, weight: .regular))
                    .foregroundStyle(current ? TL.idle : DS.ink)
                    // 图标在列内右对齐：图标右缘 → 歌名首字母（含 D 的 ~1.5pt 字形边距）= 8pt，play / pause 一致
                    .frame(width: TL.glyphW - TL.glyphTrail, alignment: .center)
                    .padding(.trailing, TL.glyphTrail)
                    .offset(x: (current && music.isPlaying ? TL.pauseNudge : 0) - TL.iconShift)
                Text("\(song.artistName) - \(song.title)")
                    .font(.system(size: TL.row, weight: .regular))
                    .foregroundStyle(current ? TL.idle : DS.ink)   // t104u：播放中灰、其余黑
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .frame(height: TL.pitch)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // 不再随 isPreparing 整表禁用（plain 按钮禁用会整体变淡 = 切歌时「闪一下」）；
        // 重复点击由 AppleMusicStore.play 内的 isPreparing 守卫挡掉。
        .disabled(song.playParameters == nil)
        .opacity(song.playParameters == nil ? 0.45 : 1)
        .animation(.easeInOut(duration: 0.15), value: current)
        .animation(.easeInOut(duration: 0.15), value: current && music.isPlaying)
        .accessibilityLabel("\(current && music.isPlaying ? "暂停" : "播放") \(song.title)，\(song.artistName)")
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
                    .foregroundStyle(DS.ink)
                    .frame(width: TL.sideW, alignment: .leading)
                Text("BPM")
                    .font(.system(size: TL.header, weight: .regular))
                    .foregroundStyle(TL.bpmHeader)
                    .frame(width: TL.bpmW, alignment: .leading)
                Color.clear.frame(width: TL.glyphW, height: 1)
                Text("Tracklist")
                    .font(.system(size: TL.header, weight: .regular))
                    .foregroundStyle(DS.ink)
                Spacer(minLength: 0)
            }
            .padding(.bottom, TL.headerGap)

            ForEach(AlbumData.tracks) { track in
                let index = AlbumData.tracks.firstIndex { $0.id == track.id } ?? 0
                let current = music.demoTrack == index
                Button { music.selectDemo(index, cover: coverName) } label: {
                    HStack(spacing: 0) {
                        Text(track.side)
                            .font(.system(size: TL.row, weight: .medium))   // Side 字母 A/B：500 (medium)
                            .foregroundStyle(DS.ink)
                            .frame(width: TL.sideW, alignment: .leading)
                        Text("\(track.bpm)")
                            .font(.system(size: TL.row, weight: .regular, design: .monospaced))   // t115u：数字列用 SF Mono
                            .foregroundStyle(current ? TL.bpm : DS.ink)   // t104u：播放中灰、其余黑
                            .frame(width: TL.bpmW, alignment: .leading)
                        // SF Symbols：当前曲目播放中 = pause.fill，其余 / 暂停 = play.fill
                        Image(systemName: current && music.demoPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: TL.glyph, weight: .regular))
                            .foregroundStyle(current ? TL.idle : DS.ink)
                            // 图标在列内右对齐：图标右缘 → 歌名首字母（含 D 的 ~1.5pt 字形边距）= 8pt，play / pause 一致
                    .frame(width: TL.glyphW - TL.glyphTrail, alignment: .center)
                    .padding(.trailing, TL.glyphTrail)
                            .offset(x: (current && music.demoPlaying ? TL.pauseNudge : 0) - TL.iconShift)
                        Text(track.title)
                            .font(.system(size: TL.row, weight: .regular))
                            .foregroundStyle(current ? TL.idle : DS.ink)   // t104u：播放中灰、其余黑
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

            VStack(alignment: .leading, spacing: 2) {
                Text(AlbumData.artist)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(DS.ink)
                Text(AlbumData.release)
                    .font(.system(size: 13))
                    .foregroundStyle(DS.secondary)
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
