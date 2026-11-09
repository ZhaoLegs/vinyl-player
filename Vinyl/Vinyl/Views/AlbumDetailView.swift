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
    /// 正常使用时唱片抽出后一直转（正在播放）；录屏演示按原片在 3.067s 停转。
    var keepsSpinning: Bool = true
    let motionStart: Date
    let onClose: () -> Void
    let onToggleArtwork: () -> Void

    @State private var pageWidth: CGFloat = 402

    var body: some View {
        ZStack(alignment: .top) {
            AuroraBackground()
                .opacity(contentAlpha)
            GeometryReader { geo in
                Color.clear
                    .onAppear { pageWidth = geo.size.width }
                    .onChange(of: geo.size.width) { _, w in pageWidth = w }
            }
            Rectangle()
                .fill(.ultraThinMaterial)
                .opacity(0.35 * contentAlpha)
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
                .modifier(ArtworkHandoff(progress: reduceMotion ? 1 : zoom, closing: closing))
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: SleeveFrameKey.self,
                                               value: geo.frame(in: .named("library")))
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
                    .opacity(stage(0.24))
            }
            .opacity(contentAlpha)
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

            // 右上角同样是系统玻璃圆按钮（Button + .buttonStyle(.glass) + .buttonBorderShape(.circle)）
            GlassCircleButton(systemImage: "cube",
                              accessibilityText: "新建") { }
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
                        toggle: { Task { await music.togglePlayback() } })
        } else {
            WaveformBar(progress: music.demoElapsed / AppleMusicStore.demoDuration,
                        levels: demoLevels,
                        isPlaying: music.demoPlaying,
                        toggle: { music.selectDemo(music.demoTrack) })
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
                            ForEach(Array(songs.enumerated()), id: \.offset) { index, song in
                                realRow(index, song, in: songs)
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

    private func realRow(_ index: Int, _ song: Song, in songs: [Song]) -> some View {
        let current = music.currentSongID == song.id
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
                    .font(.system(size: TL.row, weight: .regular))
                    .foregroundStyle(DS.ink)
                    .frame(width: TL.sideW, alignment: .leading)
                Text(musicTime(song.duration ?? 0))
                    .font(.system(size: TL.row, weight: .regular).monospacedDigit())
                    .foregroundStyle(current ? DS.ink : TL.bpm)
                    .frame(width: TL.bpmW, alignment: .leading)
                    .lineLimit(1)
                Image(systemName: current && music.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: TL.glyph, weight: .regular))
                    .foregroundStyle(DS.ink)
                    .frame(width: TL.glyphW, alignment: .leading)
                Text("\(song.artistName) - \(song.title)")
                    .font(.system(size: TL.row, weight: .regular))
                    .foregroundStyle(current ? DS.ink : TL.idle)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .frame(height: TL.pitch)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(song.playParameters == nil || music.isPreparing)
        .opacity(song.playParameters == nil ? 0.45 : 1)
        .accessibilityLabel("\(current && music.isPlaying ? "暂停" : "播放") \(song.title)，\(song.artistName)")
    }

    // 原片实测（960×720 视频，屏宽 289px ↔ 393pt）：列起点相对内容左缘
    // Side 0 / BPM 39.5 / 图标 81.5 / 曲名 104.5pt；行距 36pt；表头 12pt，曲名 15pt，播放图标 13pt（字形高 ≈ 曲名大写高）。
    private enum TL {
        static let sideW: CGFloat  = 39.5
        static let bpmW: CGFloat   = 42
        static let glyphW: CGFloat = 23
        static let header: CGFloat = 12
        static let row: CGFloat    = 15
        static let glyph: CGFloat  = 13
        static let pitch: CGFloat  = 36
        static let headerGap: CGFloat = 16.5
        static let bpmHeader = Color(hex: 0x8F8D8E)
        static let bpm       = Color(hex: 0x7A787B)
        static let idle      = Color(hex: 0x625F63)
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

            ForEach(Array(AlbumData.tracks.enumerated()), id: \.offset) { index, track in
                let current = music.demoTrack == index
                Button { music.selectDemo(index) } label: {
                    HStack(spacing: 0) {
                        Text(track.side)
                            .font(.system(size: TL.row, weight: .regular))
                            .foregroundStyle(DS.ink)
                            .frame(width: TL.sideW, alignment: .leading)
                        Text("\(track.bpm)")
                            .font(.system(size: TL.row, weight: .regular))
                            .foregroundStyle(current ? DS.ink : TL.bpm)
                            .frame(width: TL.bpmW, alignment: .leading)
                        // SF Symbols：当前曲目播放中 = pause.fill，其余 / 暂停 = play.fill
                        Image(systemName: current && music.demoPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: TL.glyph, weight: .regular))
                            .foregroundStyle(DS.ink)
                            .frame(width: TL.glyphW, alignment: .leading)
                        Text(track.title)
                            .font(.system(size: TL.row, weight: .regular))
                            .foregroundStyle(current ? DS.ink : TL.idle)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .frame(height: TL.pitch)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(current && music.demoPlaying ? "暂停" : "播放") \(track.title)")
            }
        }
    }

    // MARK: - 发行信息卡片

    private var releaseCard: some View {
        HStack(spacing: 12) {
            Image("small_art")
                .resizable()
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
