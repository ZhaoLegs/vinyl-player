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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var coverName: String = "sleeve_cutout"
    var title: String = AlbumData.title
    var artist: String = AlbumData.artist
    let pull: CGFloat
    let flip: Double
    let waveProgress: Double
    let contentAlpha: Double
    let zoom: CGFloat
    let isPresented: Bool
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
                .modifier(ArtworkHandoff(progress: reduceMotion ? 1 : zoom))
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
                    .padding(.top, 32)
                    .opacity(stage(0.09))

                releaseCard
                    .padding(.horizontal, 21)
                    .padding(.top, 22)
                    .opacity(stage(0.17))

                Spacer(minLength: 8)

                WaveformBar(progress: waveProgress)
                    .padding(.horizontal, 16)
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
            GlassCircleButton(systemImage: "xmark", size: 36, iconSize: 15,
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
            GlassCircleButton(systemImage: "cube", size: 36, iconSize: 15,
                              accessibilityText: "新建") { }
        }
        .padding(.horizontal, 20)
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

            ForEach(AlbumData.tracks) { track in
                HStack(spacing: 0) {
                    Text(track.side)
                        .frame(width: 38, alignment: .leading)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(DS.ink)
                    Text("\(track.bpm)")
                        .frame(width: 46, alignment: .leading)
                    Text(track.isPlaying ? "Ⅱ" : "▶")
                        .frame(width: 18, alignment: .leading)
                        .font(.system(size: 10))
                        .foregroundStyle(track.isPlaying ? DS.ink : DS.tertiary)
                    Text(track.title)
                    Spacer(minLength: 0)
                }
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(track.isPlaying ? DS.ink : DS.secondary)
                .frame(height: 36)
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
