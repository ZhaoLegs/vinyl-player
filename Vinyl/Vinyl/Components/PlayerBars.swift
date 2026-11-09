import UIKit
import SwiftUI
import Foundation
import MusicKit

/// SF Symbols 播放 / 暂停字形（系统字形，非自绘）。
struct PlaybackSymbol: View {
    let isPlaying: Bool
    var size: CGFloat = 13
    var body: some View {
        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(DS.ink)
    }
}

/// 真实播放控制：状态来自 ApplicationMusicPlayer，而不是按钮自己的乐观状态。
struct SystemPlaybackButton: View {
    let isPlaying: Bool
    var size: CGFloat = 13
    var disabled = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            PlaybackSymbol(isPlaying: isPlaying, size: size)
                .frame(width: 32, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityLabel(isPlaying ? "暂停" : "播放")
    }
}

/// 系统 SF Symbols 播放/暂停控件（苹果控件库），工程内不自绘任何 Capsule 图标。
struct SystemPauseButton: View {
    var size: CGFloat = 14

    var body: some View {
        Button("暂停", systemImage: "pause.fill") { }
            .labelStyle(.iconOnly)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(DS.ink)
            .buttonStyle(.plain)
    }
}

/// 首页底部正在播放条：有真实 Apple Music 曲目时显示其标题 / 艺人 / 播放状态，否则显示演示内容。
struct MiniPlayer: View {
    @EnvironmentObject private var music: AppleMusicStore
    /// 点击播放条（除右侧播放键外）= 打开当前专辑的播放页
    var open: () -> Void = {}

    var body: some View {
        HStack(spacing: 7) {
            // 40pt slot is the capsule's leading circular cap. The 27pt disc is
            // centered inside that cap, not inset by an extra leading pad.
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [Color(hex: 0x3A2E68), Color(hex: 0x12141C), Color(hex: 0x0B0C10)],
                                        center: .center, startRadius: 1, endRadius: 16))
                // 中心标签 = 当前专辑封面（等比填充），主轴孔在最上层
                DiscLabel(coverName: DS.coverName(AlbumData.featuredIndex),
                          artwork: music.hasCurrentTrack ? music.currentArtwork : nil,
                          size: 10)
                Circle().fill(.white).frame(width: 3.5, height: 3.5)
            }
            .frame(width: 27, height: 27)
            // 唱片仍居中于 40pt 胶囊左端圆帽（(40-27)/2 = 6.5pt 左边距），
            // 但右侧不再留 6.5pt 空白：唱片右缘 → 文字左缘 = HStack spacing 8pt。
            .padding(.leading, 6.5)
            .frame(height: 40)

            VStack(alignment: .leading, spacing: 1) {
                Text(music.hasCurrentTrack ? music.currentTitle : music.demoMiniTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DS.ink)
                    .lineLimit(1)
                // 第二行：艺人 · 歌曲时长（灰色）
                (Text("\(music.hasCurrentTrack ? music.currentArtist : AlbumData.artist) · ")
                    + Text(musicTime(music.hasCurrentTrack ? music.duration : AppleMusicStore.demoDuration))
                        .font(.system(size: 10.5, design: .monospaced)))   // 只有 m:ss 用 SF Mono
                    .font(.system(size: 10.5))
                    .foregroundStyle(DS.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
            Color.clear.frame(width: 23, height: 1)   // 给右侧播放键（32pt − 9pt 外伸）留位
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .overlay(alignment: .trailing) {
            // 播放键独立于整条的点击：只切换播放 / 暂停
            if music.hasCurrentTrack {
                SystemPlaybackButton(isPlaying: music.isPlaying) {
                    Task { await music.togglePlayback() }
                }
                .padding(.trailing, -9)
            } else {
                SystemPlaybackButton(isPlaying: music.demoPlaying) { music.selectDemo(music.demoTrack) }
                    .padding(.trailing, -9)
            }
        }
        .padding(.trailing, 14)
        .glassCapsule(height: 40)
    }
}

/// 详情页底部波形控制条：112 根竖线，已播放部分为深色。
/// `levels` 为 0…1 的振幅（本地音频 = RMS 实测；Apple Music = 歌曲 ID 种子伪波形）；
/// 为 nil 时用原片风格的演示波形。
struct WaveformBar: View {
    let progress: Double
    var levels: [Double]? = nil
    var isPlaying: Bool = true
    var toggle: (() -> Void)? = nil
    /// 提交 seek（0…1）。轻点立即调用；长按拖动时实时调用并在松手时再提交一次。
    var seek: ((Double) -> Void)? = nil
    @Environment(\.displayScale) private var displayScale
    @State private var scrub: Double? = nil
    /// 擦洗时手指所在的竖条序号：每跨进一根新竖条触发一次 selection「刻度」触觉
    @State private var scrubBar: Int? = nil
    @State private var width: CGFloat = 1
    /// 竖条区域在整条胶囊坐标系（"wave"）里的 frame：手指 x → 进度
    @State private var barsFrame: CGRect = CGRect(x: 0, y: 0, width: 1, height: 26)
    /// 歌曲总时长（秒），用于时间气泡
    var duration: Double = 0
    private let count = Waveform.barCount

    /// 线宽 1.6pt → 3x 屏 4.8px，按整像素取整为 5px（所有竖线同一像素宽）；间距固定 2pt = 6px。
    static func pixelMetrics(scale: CGFloat) -> (bar: Int, gap: Int) {
        (max(1, Int((1.6 * scale).rounded())), max(1, Int((2.0 * scale).rounded())))
    }

    var body: some View {
        HStack(spacing: 10) {
            if let toggle {
                SystemPlaybackButton(isPlaying: isPlaying, size: 11, action: toggle)
                    .frame(width: 20)
            } else {
                SystemPauseButton(size: 11)
            }

            bars
                .frame(height: 26)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("wave")) } action: {
                    barsFrame = $0; width = max(1, $0.width)
                }
                .transaction { $0.animation = nil }   // 拖动时进度逐帧跟手，无隐式动画延迟
        }
        .padding(.horizontal, 14)
        .glassCapsule(height: 42)
        .contentShape(Capsule())
        .coordinateSpace(.named("wave"))
        // t117u：整条胶囊任意位置按住 0.25s 后左右拖 = 时间擦洗；没有点按跳转（播放键照常点）
        .gesture(scrubGesture)
        .sensoryFeedback(.selection, trigger: scrubBar) { old, new in old != nil && new != nil }
        // 激活时整条轻微放大
        .scaleEffect(scrub != nil ? 1.035 : 1)
        .animation(.spring(response: 0.28, dampingFraction: 0.72), value: scrub != nil)
        // 时间气泡：跟随手指 / 播放头，SF Mono
        .overlay(alignment: .topLeading) {
            if let s = scrub {
                Text(duration > 0 ? "\(musicTime(s * duration)) / \(musicTime(duration))" : musicTime(s * duration))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(DS.ink)
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
                    .fixedSize()
                    .position(x: barsFrame.minX + CGFloat(s) * barsFrame.width, y: -20)
                    .transaction { $0.animation = nil }
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeOut(duration: 0.2), value: scrub == nil)
        .onAppear {
            if ProcessInfo.processInfo.arguments.contains("--demo-scrub") { scrub = 0.42 }
        }
    }

    private var shown: Double { min(1, max(0, scrub ?? progress)) }

    // 所有几何都在像素网格上算：x、宽、间距都是整数像素，再除以 scale 回到 pt。
    private var bars: some View {
        Canvas { context, size in
            let scale = max(1, displayScale)
            let (barPx, gapPx) = Self.pixelMetrics(scale: scale)
            let widthPx = Int((size.width * scale).rounded(.down))
            let n = max(1, (widthPx + gapPx) / (barPx + gapPx))
            let usedPx = n * barPx + (n - 1) * gapPx
            let x0Px = (widthPx - usedPx) / 2
            let bar = CGFloat(barPx) / scale
            let played = Double(n) * shown
            let headIndex = min(n - 1, Int(played))
            for i in 0..<n {
                let head = i == headIndex && shown > 0
                let h = ((head ? 24 : barHeight(i, of: n)) * scale).rounded() / scale
                let x = CGFloat(x0Px + i * (barPx + gapPx)) / scale
                let y = (((size.height - h) / 2) * scale).rounded() / scale
                let rect = CGRect(x: x, y: y, width: bar, height: h)
                let path = Path(roundedRect: rect, cornerRadius: bar / 2)
                // 亚竖条精度：分界落在某根竖条内部时，这根竖条左段黑、右段灰，拖动时连续移动不跳格
                let frac = CGFloat(min(1, max(0, played - Double(i))))
                let gray = Color(hex: 0xB9B5B1)
                context.drawLayer { layer in
                    if head { layer.addFilter(.shadow(color: .black.opacity(0.28), radius: 3)) }
                    if frac >= 1 {
                        layer.fill(path, with: .color(DS.ink))
                    } else {
                        layer.fill(path, with: .color(gray))
                        if frac > 0 {
                            layer.clip(to: Path(CGRect(x: x, y: y, width: bar * frac, height: h)))
                            layer.fill(path, with: .color(DS.ink))
                        }
                    }
                }
            }
        }
    }

    /// 与 Canvas 相同的像素网格算法得到竖条根数，进度 → 竖条序号
    private func bar(for f: Double) -> Int {
        let scale = max(1, displayScale)
        let (barPx, gapPx) = Self.pixelMetrics(scale: scale)
        let n = max(1, (Int((width * scale).rounded(.down)) + gapPx) / (barPx + gapPx))
        return min(n - 1, Int(f * Double(n)))
    }

    private func fraction(_ x: CGFloat) -> Double {
        Double(min(1, max(0, (x - barsFrame.minX) / max(1, barsFrame.width))))
    }

    /// 长按 0.25s 后水平拖动 = 实时擦洗；开始时轻触觉，松手提交
    private var scrubGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.25)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named("wave")))
            .onChanged { value in
                switch value {
                case .first(true):
                    break
                case .second(true, let drag):
                    if scrub == nil {
                        // 长按激活擦洗：比刻度更重一点的 impact
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        scrub = shown
                        scrubBar = bar(for: shown)
                    }
                    if let drag {
                        let f = fraction(drag.location.x)
                        scrub = f            // 只更新 UI（逐帧），松手时才 seek 一次
                        scrubBar = bar(for: f)
                    }
                default: break
                }
            }
            .onEnded { value in
                if case .second(true, let drag) = value, let drag { seek?(fraction(drag.location.x)) }
                else if let s = scrub { seek?(s) }
                // 等播放器状态追上后再释放本地进度，避免回跳一帧
                scrubBar = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { scrub = nil }
            }
    }

    /// 第 i 根（共 n 根）的高度：振幅数组按比例取样到 n 根。
    private func barHeight(_ i: Int, of n: Int) -> CGFloat {
        if let levels, !levels.isEmpty {
            let k = min(levels.count - 1, i * levels.count / max(1, n))
            return 4 + CGFloat(levels[k]) * 18
        }
        let j = Double(i * count / max(1, n))
        let a = abs(sin(j * 1.7) * cos(j * 0.41))
        let b = abs(sin(j * 0.13))
        return 6 + CGFloat(a) * 13 + CGFloat(b) * 5
    }
}
