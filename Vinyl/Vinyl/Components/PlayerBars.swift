import UIKit
import SwiftUI
import Foundation
import MusicKit

/// SF Symbols 播放 / 暂停字形（系统字形，非自绘）。
struct PlaybackSymbol: View {
    let isPlaying: Bool
    var size: CGFloat = 13
    /// t180u：详情页内 = 专辑主题色；首页 mini player 不在详情环境里 → 默认墨色
    @Environment(\.detailTheme) private var theme
    var body: some View {
        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(theme.ink)
            // t134u：播放 ↔ 暂停字形用系统 replace 符号过渡交叉淡入
            .contentTransition(.symbolEffect(.replace))
            .animation(.easeInOut(duration: 0.2), value: isPlaying)
    }
}

/// t136u：迷你播放条字形光学平衡（SF Symbols semibold 实测墨迹）：
/// 13pt 时 pause.fill 8.25×12.00（面积 80）、play.fill 10.15×11.95（73）、forward.fill 18.05×10.95（121）——
/// 播放 / 暂停其实比 forward 更高，「显小」来自墨迹面积只有它的 66% / 61%。
/// 播放 / 暂停放大到 14.5pt（+11.5%）：pause 10.0×13.9（112）、play 12.0×13.9（101）≈ forward 面积的 92% / 83%，
/// 再大会明显比 forward 高出一截。三者墨迹中心都在字形框中心（偏差 ≤ 0.03pt），按钮同高 40pt → 同一中心线。
enum MiniGlyph {
    static let playPause: CGFloat = 14.5
    static let forward: CGFloat = 13
}

/// t134u：按下缩小 + 弹性回弹的按钮样式（可复用）。
/// 按下：缩到 0.82，spring(response 0.2, damping 0.7)，快而不弹；
/// 松开：回到 1，spring(response 0.35, damping 0.55)，带一点过冲。
/// 只做视觉缩放，不改布局 → 点击热区不变。
struct PressShrinkButtonStyle: ButtonStyle {
    var pressedScale: CGFloat = 0.82
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? pressedScale : 1)
            .animation(configuration.isPressed
                       ? .spring(response: 0.2, dampingFraction: 0.7)
                       : .spring(response: 0.35, dampingFraction: 0.55),
                       value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PressShrinkButtonStyle {
    static var pressShrink: PressShrinkButtonStyle { PressShrinkButtonStyle() }
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
        .buttonStyle(.pressShrink)
        .disabled(disabled)
        .accessibilityLabel(isPlaying ? "暂停" : "播放")
    }
}

/// t132u：迷你播放条「下一首」：forward.fill，与 PlaybackSymbol 同 13pt semibold、同墨色；
/// 可见槽 36×40pt，点击热区外扩到 44×48pt；每次点击轻触觉。
struct NextTrackButton: View {
    var size: CGFloat = 13
    let action: () -> Void
    @State private var taps = 0
    var body: some View {
        Button {
            taps += 1
            action()
        } label: {
            Image(systemName: "forward.fill")
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(DS.ink)
                .frame(width: 36, height: 40)
                .contentShape(Rectangle().inset(by: -4))
        }
        .buttonStyle(.pressShrink)
        .sensoryFeedback(.impact(weight: .light), trigger: taps)
        .accessibilityLabel("下一首")
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
    @EnvironmentObject private var zm: LibraryZoomModel
    /// 点击播放条（除右侧播放键外）= 打开当前专辑的播放页
    var open: () -> Void = {}
    /// t184u：还没播放过时显示的默认条目（首页第一个专辑 + 它的第一首）；nil = 沿用原逻辑
    var suggestion: MiniSuggestion? = nil
    /// 详情从 mini 打开/缩回期间只隐藏封面标签，黑胶盘面保留。
    var hideDisc: Bool = false
    var onDiscFrame: (CGRect) -> Void = { _ in }
    var onLabelFrame: (CGRect) -> Void = { _ in }
    /// t226u：标签封面与首页格子 / 详情封套同源（官方封面优先，否则同一个 Apple Artwork + 同一缓存尺寸）
    var coverArtwork: Artwork? = nil
    var coverOfficial: OfficialCoverQuery? = nil

    /// 没有正在播放的曲目、且不是演示模式时才用默认条目
    private var sug: MiniSuggestion? { music.hasCurrentTrack || DemoMode.enabled ? nil : suggestion }
    private var title: String { music.hasCurrentTrack ? music.currentTitle : (sug?.title ?? music.demoMiniTitle) }
    private var artist: String { music.hasCurrentTrack ? music.currentArtistDisplay : (sug?.artist ?? AlbumData.artist) }
    private var durationValue: Double { music.hasCurrentTrack ? music.duration : (sug.map { $0.duration } ?? AppleMusicStore.demoDuration) }
    /// 只在换歌时变化（时长后到不会触发动画）
    private var trackKey: String { title + "\u{1}" + artist }
    /// 中心标签的身份：换专辑封面时才交叉淡入
    private var labelKey: String {
        if music.hasCurrentTrack {
            return music.currentArtwork?.url(width: 75, height: 75)?.absoluteString ?? ("t:" + trackKey)
        }
        if let sug { return "s:" + sug.key }
        return music.demoCoverName
    }

    var body: some View {
        HStack(spacing: 7) {
            // 40pt slot is the capsule's leading circular cap. The 27pt disc is
            // centered inside that cap, not inset by an extra leading pad.
            ZStack {
                Circle()
                    // 与大唱片同色的黑胶底（去掉原来的紫色中心）
                    .fill(RadialGradient(colors: [Color(hex: 0x1E1E21), Color(hex: 0x0B0B0D), Color(hex: 0x151517)],
                                        center: .center, startRadius: 1, endRadius: 13.5))
                // t126u：中心标签 = 正在播放歌曲所属专辑的封面（圆形裁切），比例与详情页大唱片一致
                // （DS.discLabel / DS.disc = 72 / 234）；主轴孔同比例（5 / 234）。换歌时交叉淡入。
                MiniDiscLabel(coverName: music.demoCoverName,
                              artwork: coverArtwork ?? (music.hasCurrentTrack ? music.currentArtwork : sug?.artwork),
                              official: coverOfficial,
                              key: labelKey + (coverOfficial?.id ?? ""),
                              discSize: 27,
                              snapshot: zm.miniArtwork,
                              onResolved: { if zm.miniRenderedArtwork != $0 { zm.miniRenderedArtwork = $0 } })
                    // 保留旧几何回报给网格不可见时的既有回退路径；mini 飞行另用外层稳定的圆形 frame。
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { onDiscFrame($0) }
                    .opacity(hideDisc ? 0 : 1)
            }
            .frame(width: 27, height: 27)
            // t122u：播放时小唱片匀速旋转（5s 一圈），暂停停在当前角度，继续时从该角度接着转
            .modifier(MiniDiscRotation(phase: zm.miniPhase,
                                      playing: music.hasCurrentTrack ? music.isPlaying : (sug == nil && music.demoPlaying)))
            // 测量放在旋转修饰器外：正圆直径恒定，不采用旋转矩形的包围盒。
            .onGeometryChange(for: CGRect.self) { geo in
                let disc = geo.frame(in: .global)
                let side = 27 * DS.discLabel / DS.disc
                return CGRect(x: disc.midX - side / 2, y: disc.midY - side / 2,
                              width: side, height: side)
            } action: { onLabelFrame($0) }
            // 唱片仍居中于 40pt 胶囊左端圆帽（(40-27)/2 = 6.5pt 左边距），
            // 但右侧不再留 6.5pt 空白：唱片右缘 → 文字左缘 = HStack spacing 8pt。
            .padding(.leading, 6.5)
            .frame(height: 40)

            VStack(alignment: .leading, spacing: 1) {
                // t123u：换歌时逐词上飘动画（旧词向上淡出，新词从下方 8pt 模糊淡入，逐词错开）
                FloatingText(key: trackKey,
                             tokens: FloatingText.words(title, font: .system(size: MiniText.title, weight: .semibold)),
                             color: DS.ink)
                // 第二行：艺人 · 歌曲时长（灰色，m:ss 用 SF Mono）；比第一行稍晚开始
                FloatingText(key: trackKey,
                             tokens: FloatingText.words(artist + " ·", font: .system(size: MiniText.artist))
                                + [.init(text: musicTime(durationValue), font: .system(size: MiniText.artist, design: .monospaced))],
                             color: DS.ink,          // t130u：第二行与歌名同为黑色
                             startDelay: 0.08)
            }

            Spacer(minLength: 0)
            // t275u: sleep timer indicator, just left of the play / next buttons
            SleepBadge(color: DS.secondary)
                .padding(.trailing, 6)
            // 给右侧「播放 + 下一首」两键留位（32 + 36 − 9pt 外伸 = 59pt），标题在此之前截断
            Color.clear.frame(width: 59, height: 1)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .overlay(alignment: .trailing) {
            // 播放键 / 下一首独立于整条的点击
            HStack(spacing: 0) {
                if music.hasCurrentTrack {
                    SystemPlaybackButton(isPlaying: music.isPlaying, size: MiniGlyph.playPause) {
                        Task { await music.togglePlayback() }
                    }
                } else if let sug {
                    // t184u：默认条目 = 暂停态；播放 = 从第 1 首开始播这张专辑
                    SystemPlaybackButton(isPlaying: false, size: MiniGlyph.playPause) { sug.play(0) }
                } else {
                    SystemPlaybackButton(isPlaying: music.demoPlaying, size: MiniGlyph.playPause) { music.selectDemo(music.demoTrack) }
                }
                // t132u：下一首（forward.fill，与暂停键同字号 / 字重 / 颜色），热区 44pt，轻触觉
                NextTrackButton {
                    if music.hasCurrentTrack { Task { await music.skip(next: true) } }
                    else if let sug { sug.play(1) }      // t184u：下一首 = 第 2 首
                    else { music.nextDemo() }
                }
            }
            .padding(.trailing, -9)
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
    /// t180u：已播放竖条 / 播放头 / 时间气泡 = 主题色，未播放 = 主题色低透明度
    @Environment(\.detailTheme) private var theme
    /// 擦洗时手指所在的竖条序号：每跨进一根新竖条触发一次 selection「刻度」触觉
    @State private var scrubBar: Int? = nil
    /// t124u：直接抓住播放头拖动（不需要长按）
    @State private var grabbed = false
    /// t167u：按下播放头 / 擦洗中 → 播放头变粗（0 = 常态，1 = 选中）
    @State private var headDown = false
    @State private var headGrow: CGFloat = 0
    private var headActive: Bool { headDown || scrubBar != nil }
    @State private var width: CGFloat = 1
    /// 竖条区域在整条胶囊坐标系（"wave"）里的 frame：手指 x → 进度
    @State private var barsFrame: CGRect = CGRect(x: 0, y: 0, width: 1, height: 26)
    /// 歌曲总时长（秒），用于时间气泡
    var duration: Double = 0
    /// t306u: browsing an album other than the playing one → "<title> · <artist>" in the time-bubble style,
    /// shown when `labelPulse` changes (cover landed) and on a tap of the bar, auto-hidden after `labelHold`
    var nowPlayingLabel: String? = nil
    var labelPulse: Int = 0
    static let labelHold: Double = 3
    @State private var labelVisible = false
    @State private var labelToken = 0
    private let count = Waveform.barCount

    /// 线宽 1.6pt → 3x 屏 4.8px，按整像素取整为 5px（所有竖线同一像素宽）；间距固定 2pt = 6px。
    static func pixelMetrics(scale: CGFloat) -> (bar: Int, gap: Int) {
        (max(1, Int((1.6 * scale).rounded())), max(1, Int((2.0 * scale).rounded())))
    }

    var body: some View {
        HStack(spacing: 10) {
            if let toggle {
                // t300u/t301u: same symbol, 14.5pt semibold and 32×40 target as the mini player; colour stays the album theme ink.
                // -6pt side padding keeps the bar's 20pt layout slot, so the waveform doesn't move.
                SystemPlaybackButton(isPlaying: isPlaying, size: MiniGlyph.playPause, action: toggle)
                    .padding(.horizontal, -6)
            } else {
                SystemPauseButton(size: MiniGlyph.playPause)
            }

            bars
                .frame(height: 26)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("wave")) } action: {
                    barsFrame = $0; width = max(1, $0.width)
                }
                // （t167u：进度去隐式动画移到 bars 内部 transaction(value: shown)，播放头变粗动画不受影响）
        }
        .padding(.horizontal, 14)
        .glassCapsule(height: 42)
        .contentShape(Capsule())
        // t124u：播放头热区（44pt 宽、整条高），按下横向移动 > 4pt 立即开始擦洗，优先于页面滚动
        .overlay(alignment: .topLeading) {
            Color.clear
                .contentShape(Rectangle())
                .frame(width: 44, height: 42)
                .position(x: max(barsFrame.minX + 16, barsFrame.minX + CGFloat(shown) * barsFrame.width), y: 21)
                .highPriorityGesture(handleGesture)
                // t167u：手指一按下（还没开始拖）播放头就变粗
                .simultaneousGesture(DragGesture(minimumDistance: 0)
                    .onChanged { _ in if !headDown { headDown = true } }
                    .onEnded { _ in headDown = false })
        }
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
                    .foregroundStyle(theme.ink)
                    .padding(.horizontal, 9)
                    .frame(height: 24)              // 气泡固定 24pt 高（文字 + 上下 5pt）
                    .fixedSize()
                    .modifier(BubbleGlass())
                    // t127u：气泡底边 → 播放条（放大 3.5% 后的可见）顶边 = 12pt。
                    // overlay 用未缩放的 42pt 布局框，放大后顶边上移 42·0.035/2 = 0.735pt，一并补上：
                    // 中心 y = −(0.735 + 12 + 24/2)
                    .position(x: barsFrame.minX + CGFloat(s) * barsFrame.width,
                              y: -(42 * 0.035 / 2 + 12 + 12))
                    .transaction { $0.animation = nil }
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeOut(duration: 0.2), value: scrub == nil)
        // t306u: same bubble (font / padding / 24pt / BubbleGlass / position above the bar / 0.2s fade), centred
        .overlay(alignment: .topLeading) {
            if labelVisible, scrub == nil, let label = nowPlayingLabel {
                Text(label)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(theme.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 9)
                    .frame(height: 24)
                    // t314u: hug the text (glass on the padded text itself); the outer fixed-width frame only
                    // caps the proposal at the bar width and centres it — tail "…" only past the cap
                    .modifier(BubbleGlass())
                    .frame(width: max(80, barsFrame.width))
                    .position(x: barsFrame.midX, y: -(42 * 0.035 / 2 + 12 + 12))
                    .transaction { $0.animation = nil }
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeOut(duration: 0.2), value: labelVisible)
        .simultaneousGesture(TapGesture().onEnded { pulseLabel() })
        .onChange(of: labelPulse) { _, v in if v > 0 { pulseLabel() } }
        .onChange(of: nowPlayingLabel == nil) { _, none in if none { labelVisible = false } }
        .onAppear {
            if ProcessInfo.processInfo.arguments.contains("--demo-scrub") { scrub = 0.42 }
            if labelPulse > 0 { pulseLabel() }
        }
        .onChange(of: headActive) { _, on in
            // t167u：选中 = 弹性 0.25s（轻微回弹）；松手 = 平滑 0.3s 回到常态
            withAnimation(on ? .spring(duration: Head.pressDuration, bounce: Head.pressBounce)
                             : .spring(duration: Head.releaseDuration, bounce: 0)) { headGrow = on ? 1 : 0 }
        }
    }

    private var shown: Double { min(1, max(0, scrub ?? progress)) }

    private func pulseLabel() {
        guard nowPlayingLabel != nil else { return }
        labelVisible = true
        labelToken &+= 1
        let token = labelToken
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(Self.labelHold))
            if token == labelToken { labelVisible = false }
        }
    }

    // 所有几何都在像素网格上算：x、宽、间距都是整数像素，再除以 scale 回到 pt。
    /// t167u：播放头选中态参数
    enum Head {
        static let activeWidth: CGFloat = 4.5     // 常态 = 竖条宽（3x 屏 5px ≈ 1.67pt）
        static let restHeight: CGFloat = 24
        static let activeHeight: CGFloat = 26.4   // ×1.1
        static let pressDuration = 0.25, pressBounce = 0.3, releaseDuration = 0.3
    }

    private var bars: some View {
        HeadGrowLayer(grow: headGrow) { g in barsCanvas(g) }
            // 只有进度变化时去掉隐式动画（逐帧跟手）；播放头变粗的动画照常插值
            .transaction(value: shown) { $0.animation = nil }
    }

    private func barsCanvas(_ g: CGFloat) -> some View {
        Canvas { context, size in
            let scale = max(1, displayScale)
            let (barPx, gapPx) = Self.pixelMetrics(scale: scale)
            let widthPx = Int((size.width * scale).rounded(.down))
            let n = max(1, (widthPx + gapPx) / (barPx + gapPx))
            let usedPx = n * barPx + (n - 1) * gapPx
            let x0Px = (widthPx - usedPx) / 2
            let bar = CGFloat(barPx) / scale
            // t120u：按整根竖条走（刻度感），不在竖条内部做亚像素进度
            let playedBars = min(n, Int((Double(n) * shown).rounded(.down)))
            // 播放头 = 最后一根已播放的竖条（吸附在竖条上，不在竖条之间滑动）
            let headIndex = playedBars - 1
            for i in 0..<n {
                let head = i == headIndex
                // t167u：播放头宽 / 高按 g 插值，以竖条中心为轴向两侧变粗（不位移、不影响其它竖条）
                let headH = Head.restHeight + (Head.activeHeight - Head.restHeight) * g
                let h = head ? headH : ((barHeight(i, of: n)) * scale).rounded() / scale
                let x = CGFloat(x0Px + i * (barPx + gapPx)) / scale
                let w = head ? bar + (Head.activeWidth - bar) * g : bar
                let y = head ? (size.height - h) / 2 : (((size.height - h) / 2) * scale).rounded() / scale
                let rect = CGRect(x: x + (bar - w) / 2, y: y, width: w, height: h)
                // t183u：两端始终是正圆（圆形 Capsule；默认 continuous 圆角在 r = w/2 时两端会发平）
                let path = Capsule(style: .circular).path(in: rect)
                let color = i < playedBars ? theme.ink : theme.track
                // t267u: playhead = round-capped Capsule, no shadow (same size / colour / position)
                context.fill(path, with: .color(color))
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

    /// 竖条总数（与 Canvas 同一像素网格算法）
    private var barTotal: Int {
        let scale = max(1, displayScale)
        let (barPx, gapPx) = Self.pixelMetrics(scale: scale)
        return max(1, (Int((width * scale).rounded(.down)) + gapPx) / (barPx + gapPx))
    }
    /// 擦洗位置吸附到整根竖条：k 根已播放 → 进度 k / n
    private func snapped(_ f: Double) -> (steps: Int, fraction: Double) {
        let n = barTotal
        let k = min(n, max(0, Int((f * Double(n)).rounded())))
        return (k, Double(k) / Double(n))
    }

    private func fraction(_ x: CGFloat) -> Double {
        Double(min(1, max(0, (x - barsFrame.minX) / max(1, barsFrame.width))))
    }

    /// 长按 0.25s 后水平拖动 = 实时擦洗；开始时轻触觉，松手提交
    /// 抓住播放头直接拖：吸附整根竖条、每格一次刻度触觉，松手 seek
    private var handleGesture: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named("wave"))
            .onChanged { drag in
                if scrub == nil {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    grabbed = true
                    let snap = snapped(shown)
                    scrub = snap.fraction
                    scrubBar = snap.steps
                }
                let snap = snapped(fraction(drag.location.x))
                if snap.steps != scrubBar {
                    scrub = snap.fraction
                    scrubBar = snap.steps
                }
            }
            .onEnded { drag in
                seek?(snapped(fraction(drag.location.x)).fraction)
                scrubBar = nil
                grabbed = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { scrub = nil }
            }
    }

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
                        let snap = snapped(shown)
                        scrub = snap.fraction
                        scrubBar = snap.steps
                    }
                    if let drag {
                        // 一根竖条一格：只有跨进新的一格才更新进度，并触发一次刻度触觉
                        let snap = snapped(fraction(drag.location.x))
                        if snap.steps != scrubBar {
                            scrub = snap.fraction
                            scrubBar = snap.steps
                        }
                    }
                default: break
                }
            }
            .onEnded { value in
                if case .second(true, let drag) = value, let drag { seek?(snapped(fraction(drag.location.x)).fraction) }
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


// MARK: - 迷你播放条：旋转唱片

/// 播放中按角速度累计旋转；暂停冻结当前角度，恢复时从该角度继续（不回 0）。
struct SpinWhilePlaying: ViewModifier {
    let playing: Bool
    var degreesPerSecond: Double = 72      // 5s 一圈
    @State private var base: Double = 0
    @State private var start: Date? = nil

    func body(content: Content) -> some View {
        TimelineView(.animation(paused: !playing)) { context in
            let running = start.map { context.date.timeIntervalSince($0) * degreesPerSecond } ?? 0
            content.rotationEffect(.degrees(base + running))
        }
        .onAppear { if playing { start = Date() } }
        .onChange(of: playing) { _, now in
            if now { start = Date() }
            else if let s = start { base += Date().timeIntervalSince(s) * degreesPerSecond; start = nil }
        }
    }
}

/// 只在播放/暂停及交接时发布状态；TimelineView 的逐帧角度不广播到整个首页。
@MainActor
final class MiniDiscPhase: ObservableObject {
    @Published private(set) var base = 0.0
    @Published private(set) var start: Date?
    private(set) var playing = false
    private var held = false
    var presentedAngle = 0.0

    func angle(at date: Date) -> Double {
        base + (start.map { max(0, date.timeIntervalSince($0)) * 72 } ?? 0)
    }

    func setPlaying(_ value: Bool) {
        guard playing != value else { return }
        base = angle(at: Date()).truncatingRemainder(dividingBy: 360)
        playing = value
        start = value && !held ? Date() : nil
    }

    func hold() -> Double {
        let angle = presentedAngle.truncatingRemainder(dividingBy: 360)
        held = true
        base = angle
        start = nil
        return angle
    }

    func resume(from angle: Double) {
        held = false
        base = angle
        presentedAngle = angle
        start = playing ? Date() : nil
    }
}

struct MiniDiscRotation: ViewModifier {
    @ObservedObject var phase: MiniDiscPhase
    let playing: Bool

    // t266u: the mini-player disc stays static (angle 0) whether playing or paused;
    // no TimelineView / per-frame work here. phase is never started, so hold() hands off 0 to the flight.
    func body(content: Content) -> some View {
        content
    }
}

// MARK: - 迷你播放条：逐词上飘文字

/// t189u：迷你播放条字号（标题 13 → 12，第二行 10.5 → 11.5）
enum MiniText {
    static let title: CGFloat = 12
    static let artist: CGFloat = 11.5
}

struct FloatingText: View {
    struct Token: Equatable {
        var text: String
        var font: Font
        var separator = " "

        func displayText(at index: Int) -> String {
            (index == 0 ? "" : separator) + text
        }

        static func == (a: Token, b: Token) -> Bool {
            a.text == b.text && a.separator == b.separator
        }
    }
    let key: String
    let tokens: [Token]
    let color: Color
    var startDelay: Double = 0
    /// t188u：详情页标题居中用 .center
    var alignment: Alignment = .leading
    /// false = 首次出现直接显示（只在 key 变化时上飘）
    var animateOnAppear = true

    @State private var shownKey: String? = nil
    @State private var previous: [Token] = []
    @State private var phase: Double = 1

    private static let stagger = 0.045
    private static let wordDuration = 0.35

    /// 按空格切词；没有空格的中日韩文本按字切
    static func words(_ s: String, font: Font) -> [Token] {
        let text = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        let cjk = text.unicodeScalars.contains { (0x3000...0x9FFF).contains($0.value) || (0xAC00...0xD7AF).contains($0.value) }
        if parts.count <= 1 && cjk {
            return text.map { Token(text: String($0), font: font, separator: "") }
        }
        return parts.map { Token(text: $0, font: font) }
    }

    private var total: Double { startDelay + Self.wordDuration + Self.stagger * Double(max(tokens.count, previous.count)) }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            ZStack(alignment: alignment) {
                if !previous.isEmpty { row(previous, entering: false) }
                row(tokens, entering: true)
            }
            // 放不下时退回单行 … 截断文字；t188u：整行同样上飘（旧行上移淡出、新行从下方淡入）
            ZStack(alignment: alignment) {
                if !previous.isEmpty {
                    plainText(previous)
                        .modifier(WordFloat(phase: phase, index: 0, entering: false, total: total, delay: startDelay))
                }
                plainText(tokens)
                    .modifier(WordFloat(phase: phase, index: 0, entering: true, total: total, delay: startDelay))
            }
        }
        .onAppear { animate(fromScratch: true) }
        .onChange(of: key) { _, _ in animate(fromScratch: false) }
    }

    private func plainText(_ list: [Token]) -> some View {
        list.enumerated().reduce(Text("")) { acc, item in
            acc + Text(item.element.displayText(at: item.offset)).font(item.element.font)
        }
        .foregroundStyle(color)
        .lineLimit(1)
        .truncationMode(.tail)
    }

    private func row(_ list: [Token], entering: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(list.enumerated()), id: \.offset) { i, t in
                Text(t.displayText(at: i))
                    .font(t.font)
                    .foregroundStyle(color)
                    .fixedSize()
                    .modifier(WordFloat(phase: phase, index: i, entering: entering,
                                        total: total, delay: startDelay))
            }
        }
        .lineLimit(1)
    }

    private func animate(fromScratch: Bool) {
        guard shownKey != key else { return }
        var t = Transaction(); t.disablesAnimations = true
        if fromScratch && !animateOnAppear {
            withTransaction(t) { previous = []; phase = 1 }
            shownKey = key; lastTokens = tokens
            return
        }
        withTransaction(t) {
            previous = fromScratch || shownKey == nil ? [] : lastTokens
            phase = 0
        }
        shownKey = key
        lastTokens = tokens
        withAnimation(.linear(duration: total)) { phase = 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + total + 0.05) {
            if shownKey == key { previous = [] }
        }
    }
    @State private var lastTokens: [Token] = []
}

/// 单个词的上飘：phase 为整体线性时钟，按词序错开后各自 easeOut
private struct WordFloat: AnimatableModifier {
    var phase: Double
    let index: Int
    let entering: Bool
    let total: Double
    let delay: Double
    var animatableData: Double { get { phase } set { phase = newValue } }

    func body(content: Content) -> some View {
        let t = phase * total - delay - Double(index) * 0.045
        let local = min(1, max(0, t / 0.35))
        let e = 1 - pow(1 - local, 3)        // easeOutCubic
        let y: CGFloat = entering ? 8 * (1 - e) : -8 * e
        let alpha: Double = entering ? e : 1 - e
        let blur: CGFloat = entering ? 4 * (1 - e) : 3 * e
        content
            .offset(y: y)
            .opacity(alpha)
            .blur(radius: blur)
    }
}


/// t126u：迷你唱片中心标签。尺寸按大唱片比例缩放；换封面时新旧交叉淡入（不闪白），随盘一起转。
struct MiniDiscLabel: View {
    @Environment(\.displayScale) private var displayScale
    var coverName: String
    var artwork: Artwork?
    var official: OfficialCoverQuery? = nil
    var key: String
    var discSize: CGFloat
    var snapshot: MiniArtworkSnapshot? = nil
    var onResolved: (MiniArtworkSnapshot) -> Void = { _ in }

    private var labelSize: CGFloat { discSize * DS.discLabel / DS.disc }   // 27 → 8.31pt
    private var holeSize: CGFloat { max(1.2, discSize * 5 / DS.disc) }     // 27 → 1.2pt

    var body: some View {
        ZStack {
            Group {
                if let snapshot {
                    snapshot.content.frame(width: labelSize, height: labelSize)
                } else if artwork != nil || official != nil {
                    // t226u：原来是播放队列条目的 Artwork（ArtworkImage 75px，不走缓存、也不是官方封面）；
                    // 现在用与格子同一个 ArtworkFill（同 render 尺寸 → 同一缓存键），官方封面优先
                    ArtworkFill(artwork: artwork, official: official, animatesOfficial: false, onResolved: { image in
                        var resolved = MiniArtworkSnapshot(coverName: coverName, artwork: artwork,
                                                           official: official, scale: displayScale)
                        resolved.image = image
                        onResolved(resolved)
                    })
                        .frame(width: labelSize, height: labelSize)
                } else {
                    Image(coverName).resizable().scaledToFill()
                        .frame(width: labelSize, height: labelSize)
                        .onAppear { reportAsset() }
                        .onChange(of: coverName) { _, _ in reportAsset() }
                }
            }
            .clipShape(Circle())
            .id(snapshot?.cacheKey ?? key)
            .transition(.opacity)
            Circle().fill(.white).frame(width: holeSize, height: holeSize)
        }
        .frame(width: labelSize, height: labelSize)
        .animation(snapshot == nil ? .easeInOut(duration: 0.25) : nil, value: key)
    }

    private func reportAsset() {
        onResolved(MiniArtworkSnapshot(coverName: coverName, artwork: nil, official: nil, scale: displayScale))
    }
}


/// t127u：时间气泡背景 = 系统 Liquid Glass（iOS 26+），旧系统退回 material
struct BubbleGlass: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: Capsule())
        } else {
            content
                .background(.regularMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        }
    }
}

/// t167u：让 Canvas 里的播放头粗细可以被 withAnimation 逐帧插值
struct HeadGrowLayer<Content: View>: View, Animatable {
    var grow: CGFloat
    let content: (CGFloat) -> Content
    var animatableData: CGFloat {
        get { grow }
        set { grow = newValue }
    }
    var body: some View { content(grow) }
}

/// t184u：首页 mini player 的默认条目（还没播放任何歌时）
struct MiniSuggestion {
    let key: String
    let title: String
    let artist: String
    let duration: Double
    let artwork: Artwork?
    /// 从第 i 首开始播放
    let play: (Int) -> Void
}
