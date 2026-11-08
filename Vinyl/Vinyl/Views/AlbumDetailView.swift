import SwiftUI
import Foundation

/// 上报封套在 "library" 坐标空间中的位置，供 zoom 转场计算终点。
struct SleeveFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

struct AlbumDetailView: View {
    @EnvironmentObject private var playback: DemoPlaybackStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var coverName: String = "sleeve_cutout"
    var title: String = AlbumData.title
    var artist: String = AlbumData.artist
    let pull: CGFloat
    let flip: Double
    let contentAlpha: Double
    let zoom: CGFloat
    let isPresented: Bool
    var closing: Bool = false
    let motionStart: Date
    let onClose: () -> Void
    let onToggleArtwork: () -> Void

    var body: some View {
        ZStack(alignment: .top) {
            AuroraBackground()
                .opacity(contentAlpha)
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
                    SleeveArtwork(coverName: coverName, pull: pull, flip: flip, spin: spin)
                        .frame(width: DS.sleeve, height: DS.sleeve)
                        .contentShape(Rectangle())
                        .onTapGesture(perform: onToggleArtwork)
                }
                .frame(width: DS.sleeve, height: DS.sleeve)
                .reviewElement("detail-artwork", "封套画面", radius: 0, note: "306pt 画布 · 抽出唱片 260pt")
                .modifier(ArtworkHandoff(progress: reduceMotion ? 1 : zoom, closing: closing))
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: SleeveFrameKey.self,
                                               value: geo.frame(in: .named("library")))
                    }
                )
                // Breathing room under sleeve → track table (preview dtable gap ≈ 30pt).
                .padding(.top, 20)

                trackTable
                    .padding(.horizontal, 21)
                    .padding(.top, 40)
                    .opacity(stage(0.09))

                releaseCard
                    .padding(.horizontal, 21)
                    .padding(.top, 22)
                    .opacity(stage(0.17))

                Spacer(minLength: 8)

                WaveformBar(position: playback.position, duration: playback.duration,
                            isPlaying: playback.isPlaying, levels: playback.levels,
                            toggle: { playback.toggle() }, seek: { playback.seek(to: $0) })
                    .padding(.horizontal, DS.controlInset)
                    .padding(.bottom, 10)
                    .opacity(stage(0.24))
            }
            .opacity(contentAlpha)
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
        let start = 1.2, end = 3.067, ramp = 0.17, peak = Motion.spinPeak
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
            GlassCircleButton(systemImage: "xmark", iconSize: 17,
                              accessibilityText: "关闭", action: onClose)
                .reviewElement("header-left", "关闭圆按钮", font: 17, radius: 22)

            Spacer(minLength: 0)

            VStack(spacing: 1) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(DS.ink)
                    .reviewElement("detail-title", "歌曲详情标题", font: 14)
                Text(artist)
                    .font(.system(size: 11))
                    .foregroundStyle(DS.secondary)
                    .reviewElement("detail-artist", "歌曲详情艺人", font: 11)
            }

            Spacer(minLength: 0)

            // 右上角同样是系统玻璃圆按钮（Button + .buttonStyle(.glass) + .buttonBorderShape(.circle)）
            GlassCircleButton(systemImage: "cube", iconSize: 17,
                              accessibilityText: "新建") { }
                .reviewElement("header-right", "右侧圆按钮", font: 17, radius: 22)
        }
        .padding(.horizontal, DS.controlInset)
    }

    // MARK: - 曲目表

    private var trackTable: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Text("Side").frame(width: 38, alignment: .leading)
                Text("BPM").frame(width: 46, alignment: .leading)
                Text("").frame(width: 18)
                Text("Tracklist")
                Spacer(minLength: 0)
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(DS.inkSoft)
            .padding(.bottom, 20)
            .reviewElement("table-heading", "曲目表标题", font: 11, note: "Side 38pt · BPM 46pt · 图标列 18pt")

            ForEach(Array(AlbumData.tracks.enumerated()), id: \.offset) { index, track in
                let active = index == playback.selectedTrack
                Button { playback.playOrToggle(track: index) } label: {
                HStack(spacing: 0) {
                    Text(track.side)
                        .frame(width: 38, alignment: .leading)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(DS.ink)
                        .reviewElement("track-side-\(index)", "曲目 \(index + 1) Side", font: 15)
                    Text("\(track.bpm)")
                        .frame(width: 46, alignment: .leading)
                        .reviewElement("track-bpm-\(index)", "曲目 \(index + 1) BPM", font: 15)
                    PlaybackSymbol(isPlaying: active && playback.isPlaying)
                        .frame(width: 18, alignment: .leading)
                        .opacity(active ? 1 : 0.4)
                        .reviewElement("track-symbol-\(index)", "曲目 \(index + 1) SF 图标",
                                       font: DS.playbackIcon, note: "play.fill / pause.fill · semibold")
                    Text(track.title)
                        .reviewElement("track-title-\(index)", "曲目 \(index + 1) 标题", font: 15)
                    Spacer(minLength: 0)
                }
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(active ? DS.ink : DS.secondary)
                .frame(height: 36)
                .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(active && playback.isPlaying ? "暂停" : "播放验收音频")，\(track.title)")
                .reviewElement("track-row-\(index)", "曲目 \(index + 1) 行", note: "整行可点击")
            }
            Text(playback.failure ?? "内置验收音频 · 非上述原曲")
                .font(.system(size: 10)).foregroundStyle(DS.secondary)
                .padding(.top, 4)
        }
    }

    // MARK: - 发行信息卡片

    private var releaseCard: some View {
        HStack(spacing: 12) {
            Image("small_art")
                .resizable()
                .frame(width: 58, height: 58)
                .clipShape(RoundedRectangle(cornerRadius: 2))
                .reviewElement("release-art", "发行信息图片", radius: 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(AlbumData.artist)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(DS.ink)
                    .reviewElement("release-artist", "发行艺人", font: 17)
                Text(AlbumData.release)
                    .font(.system(size: 13))
                    .foregroundStyle(DS.secondary)
                    .reviewElement("release-label", "发行厂牌", font: 13)
                Text(AlbumData.catalog)
                    .font(.system(size: 10))
                    .foregroundStyle(DS.tertiary)
                    .reviewElement("release-catalog", "发行编号", font: 10)
            }
            Spacer(minLength: 0)
        }
    }
}
