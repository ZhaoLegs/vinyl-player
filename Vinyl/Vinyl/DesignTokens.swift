import SwiftUI
import UIKit

extension Color {
    init(hex: UInt, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: alpha)
    }
}

enum DS {
    // 颜色：取自原片取样
    static let ink        = Color(hex: 0x1A1A1C)
    static let inkSoft    = Color(hex: 0x2A2927)
    static let secondary  = Color(hex: 0x8B8783)
    static let tertiary   = Color(hex: 0xB6B1AC)
    static let paper      = Color(hex: 0xF4F1EE)
    static let accent     = Color(hex: 0x8FD694)
    static let vinyl      = Color(hex: 0x111113)

    // 尺寸：以 iPhone 393pt 宽为基准，与原片 480px 屏幕按 0.819 换算
    static let sleeve: CGFloat     = 306
    static let sleeveTop: CGFloat  = 126
    // 抽出后封套缩到 (1 - pullScale)=0.85 → 260.1pt；唱片直径 234（原 260 缩小 10%），
    // 圆心仍与封套同一条水平中线，上下各比缩放后的封套内缩 13pt。
    static let disc: CGFloat       = 234
    /// 唱片中心标签直径：原 80/260 的比例 → 72
    static let discLabel: CGFloat  = 72
    // 抽出位移不再是固定值：SleeveArtwork 按页面宽度计算，让封套左缘 = 21pt、唱片右缘 = 宽 - 21pt。
    static let pullScale: CGFloat  = 0.15
    static let planet: CGFloat     = 86
    static let corner: CGFloat     = 5
    static let capsule: CGFloat    = 28

    /// 首页与详情页共用的左右内容边距（原片实测：网格 / 曲目表 / 发行卡左缘均为 21pt）。
    static let contentInset: CGFloat = 21

    /// 系统导航栏玻璃圆钮：在 iOS 27 模拟器里用原生 ToolbarItem 实测直径 136px@3x（≈45.3pt，含玻璃描边），
    /// .glass 样式会在 label 外再加一圈内边距，label 取 30pt 时渲染直径与原生一致。
    static let barButtonLabel: CGFloat = 30
    /// 原生 toolbar 图标 = 17pt 字号 + .large imageScale（实测与原生 cube 字形同宽同高）。
    static let barButtonGlyph: CGFloat = 17

    /// 底部 mini player：与系统 Tab bar 玻璃胶囊左右对齐，且与其上缘可见间距 4pt。
    static let tabBarSideInset: CGFloat = 21
    static let miniPlayerGap: CGFloat = 4
    /// safeAreaBar 的底边比 Tab bar 玻璃胶囊的可见上缘低 5.33pt（iOS 27 模拟器 3x 截图实测，
    /// padding 每 +1pt 间距 +1pt），所以底部 padding = 间距 + 5.33（可见边缘对边缘）。
    static let miniPlayerBottomPadding: CGFloat = miniPlayerGap + 5.33

    static func coverName(_ index: Int) -> String {
        String(format: "cover_%02d", index)
    }
}

// MARK: - 原生动效（时长按原片校正，曲线仍需真机核对）
//
// 关键原则：一个阶段 = 一条主 spring 曲线，所有属性共享同一进度，
// 只按 delay 做错峰；绝不让 blur / zoom / opacity 各跑一条不同的曲线
// （那正是「动画节奏毫无曲线、看起来散架」的根源）。
//
// 二阶阻尼阶跃响应：x(t) = 1 - e^(-ζω₀t)·[cos(ωd t) + (ζω₀/ωd)·sin(ωd t)]
//   ω₀ = 2π / response，ωd = ω₀√(1-ζ²)
// 与 SwiftUI .spring(response:dampingFraction:) 物理模型一致。

enum Motion {
    struct Spring {
        let response: Double       // 秒
        let damping: Double        // dampingFraction，<1 有过冲
        let duration: Double       // 该阶段在 30fps 下的实际秒数
        var followsMeasuredPath: Bool = false
        var springy: Bool = false
    }

    /// Stage windows measured from the attached reference (30fps, frame 1 at t=0).
    /// Open is source frames 5→27, pull 41→55, retract 91→97, flip 114→125, close 165→185.
    /// These replace the earlier 8/30 and 10/30 guesses. Not a claim of pixel-perfect playback.
    /// 封面放大 / 缩回转场：弹簧，带轻微可见回弹（开与关同一组参数）。
    /// response 0.5s、dampingFraction 0.72 ≈ 过冲 ~6%，CoverFlight / ArtworkHandoff 把过冲映射成封面的轻微放大 / 缩小。
    static let zoomSpring: (response: Double, damping: Double) = (0.5, 0.72)
    static let zoomDuration: Double = 0.5
    /// 飞行封面 → 详情封套的交接点（弹簧进度首次 ≥ 0.97；0.72 阻尼下回落不会再低于它）
    static let handoff: CGFloat = 0.97
    /// 唱片抽出的小弹簧落定
    static let pullSpring: (response: Double, damping: Double) = (0.42, 0.78)
    static let open    = Spring(response: 0, damping: 0, duration: zoomDuration, followsMeasuredPath: true)
    static let pull    = Spring(response: pullSpring.response, damping: pullSpring.damping, duration: 14.0 / 30, springy: true)
    static let retract = Spring(response: 0.22, damping: 0.92, duration: 6.0 / 30)
    static let flip    = Spring(response: 0.10, damping: 0.92, duration: 11.0 / 30)
    static let close   = Spring(response: 0, damping: 0, duration: zoomDuration, followsMeasuredPath: true)

    static func animation(_ s: Spring) -> Animation {
        // Open/close: a spring drives CoverFlight's progress along OPEN_PATH / CLOSE_PATH (overshoot = slight scale).
        if s.followsMeasuredPath {
            return .spring(response: zoomSpring.response, dampingFraction: zoomSpring.damping)
        }
        if s.springy { return .spring(response: s.response, dampingFraction: s.damping) }
        return .timingCurve(0.42, 0.0, 0.2, 1.0, duration: s.duration)
    }

    struct SleeveKey {
        var frame: Double
        var x: Double
        var y: Double
        var size: Double
    }

    // preview/index.html OPEN_PATH / CLOSE_PATH, measured from the reference video.
    static let openPath: [SleeveKey] = [
        .init(frame: 5, x: 20.3, y: 391.3, size: 73.7),
        .init(frame: 6, x: 23.1, y: 388.3, size: 75.2),
        .init(frame: 7, x: 33, y: 376.6, size: 79.8),
        .init(frame: 8, x: 48.9, y: 354.5, size: 89.6),
        .init(frame: 9, x: 63.5, y: 326.9, size: 104.7),
        .init(frame: 10, x: 73.3, y: 299.1, size: 122.1),
        .init(frame: 11, x: 78.4, y: 273.5, size: 141),
        .init(frame: 12, x: 79.6, y: 249.6, size: 160.9),
        .init(frame: 13, x: 77.8, y: 228.3, size: 182),
        .init(frame: 14, x: 73.5, y: 208.9, size: 204.2),
        .init(frame: 15, x: 67.8, y: 191.2, size: 226.7),
        .init(frame: 16, x: 61.7, y: 175.5, size: 247.8),
        .init(frame: 17, x: 55.5, y: 161, size: 267.4),
        .init(frame: 18, x: 50.2, y: 148.4, size: 283.7),
        .init(frame: 19, x: 45.4, y: 138.1, size: 297.1),
        .init(frame: 20, x: 42.3, y: 130.9, size: 306.5),
        .init(frame: 21, x: 40.2, y: 126.4, size: 312.5),
        .init(frame: 22, x: 39.3, y: 124.6, size: 315.4),
        .init(frame: 23, x: 39.4, y: 124.7, size: 315.6),
        .init(frame: 24, x: 39.9, y: 125.6, size: 314.8),
        .init(frame: 25, x: 40.1, y: 126.1, size: 314.4),
        .init(frame: 27, x: 39.5, y: 126, size: 314)
    ]

    static let closePath: [SleeveKey] = [
        .init(frame: 165, x: 39.5, y: 126, size: 314),
        .init(frame: 166, x: 47, y: 135, size: 300),
        .init(frame: 167, x: 67, y: 155, size: 267),
        .init(frame: 168, x: 82, y: 191, size: 220),
        .init(frame: 169, x: 88, y: 232, size: 180),
        .init(frame: 170, x: 92, y: 270, size: 151),
        .init(frame: 171, x: 79, y: 296, size: 128),
        .init(frame: 172, x: 67.4, y: 317.3, size: 111),
        .init(frame: 173, x: 59.5, y: 334.2, size: 101),
        .init(frame: 175, x: 48.6, y: 354.9, size: 88.8),
        .init(frame: 179, x: 31.9, y: 378.2, size: 78.9),
        .init(frame: 185, x: 20.3, y: 391.3, size: 73.7)
    ]

    static let closeYaw: [(frame: Double, degrees: Double)] = [
        (165, 0), (166, -18), (167, -43), (168, -71), (169, -94),
        (170, -122), (171, -144), (172, -162), (173, -178), (178, -180), (185, -180)
    ]

    static func sample(_ keys: [SleeveKey], frame: Double) -> SleeveKey {
        if frame <= keys[0].frame { return keys[0] }
        if frame >= keys[keys.count - 1].frame { return keys[keys.count - 1] }
        var index = 0
        while index < keys.count - 1 && frame >= keys[index + 1].frame { index += 1 }
        let a = keys[index]
        let b = keys[index + 1]
        let t = (frame - a.frame) / (b.frame - a.frame)
        return SleeveKey(frame: frame,
                         x: a.x + (b.x - a.x) * t,
                         y: a.y + (b.y - a.y) * t,
                         size: a.size + (b.size - a.size) * t)
    }

    static func sampleYaw(frame: Double) -> Double {
        let keys = closeYaw
        if frame <= keys[0].frame { return keys[0].degrees }
        if frame >= keys[keys.count - 1].frame { return keys[keys.count - 1].degrees }
        var index = 0
        while index < keys.count - 1 && frame >= keys[index + 1].frame { index += 1 }
        let a = keys[index]
        let b = keys[index + 1]
        let t = (frame - a.frame) / (b.frame - a.frame)
        return a.degrees + (b.degrees - a.degrees) * t
    }

    /// Reference cell and settled sleeve, used only to recover the measured arc.
    static let referenceCell = CGPoint(x: 20.3, y: 391.3)
    static let referenceSleeve = CGPoint(x: 39.5, y: 126)
    static let referenceCellSize = 73.7
    static let referenceSleeveSize = 314.0

    /// 唱片角速度：起步缓入 → 45°/s 匀速 → 收尾缓出，累计角度 C¹ 连续。
    static let spinPeak = 45.0            // 度/秒
}

// MARK: - 底层彩色光晕（原片的液态玻璃 / 珍珠白背景）

private struct Blob {
    let x: CGFloat, y: CGFloat, radius: CGFloat, opacity: Double
    let color: Color
}

struct AuroraBackground: View {
    private let blobs: [Blob] = [
        .init(x: 0.12, y: 0.08, radius: 120, opacity: 0.60, color: Color(hex: 0xFFC4D6)),
        .init(x: 0.88, y: 0.16, radius: 160, opacity: 0.55, color: Color(hex: 0xC6E0FF)),
        .init(x: 0.78, y: 0.56, radius: 180, opacity: 0.50, color: Color(hex: 0xFFE1B6)),
        .init(x: 0.18, y: 0.78, radius: 200, opacity: 0.50, color: Color(hex: 0xCEF0DC)),
        .init(x: 0.50, y: 1.00, radius: 170, opacity: 0.45, color: Color(hex: 0xE4D6FF))
    ]

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: 0xFAF8F6), Color(hex: 0xEDEAE7), Color(hex: 0xF4F0EE)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            GeometryReader { geo in
                ForEach(Array(blobs.enumerated()), id: \.offset) { _, b in
                    RadialGradient(colors: [b.color.opacity(b.opacity), .clear],
                                   center: .center, startRadius: 0, endRadius: b.radius)
                        .frame(width: b.radius * 2, height: b.radius * 2)
                        .position(x: geo.size.width * b.x, y: geo.size.height * b.y)
                        .blur(radius: 34)
                }
            }
        }
        .ignoresSafeArea()
    }
}

// MARK: - 苹果系统控件库（iOS 26+ Liquid Glass / iOS 27 强制启用）
//
// 事实：UIKit / SwiftUI 是闭源专有框架，Apple 开源的只有 Swift 语言、Foundation、
// Darwin 内核、WebKit 等。但「用系统控件」不需要源码 —— Apple 提供了公开控件样式：
//
//   • 按钮  → Button + .buttonStyle(.glass)  = GlassButtonStyle（系统控件库）
//             形状、材质、按压高光、无障碍、Reduce Transparency 全部由系统渲染。
//             ⚠️ 不要自己用 Circle() + glassEffect() 拼一个圆 —— 那是自绘控件。
//   • 标签栏 → TabView / Tab（iOS 27 起 role: .prominent）
//   • 工具栏 → ToolbarItem + .buttonStyle(.glass)
//   • 非按钮的自定义容器 → .glassEffect(.regular, in: Capsule())（Apple 官方建议）
//
// iOS 27 + Xcode 27 起 Liquid Glass 强制生效（Info.plist 关闭开关失效），
// 且系统玻璃更锐利：更明确的边框、更亮的镜面高光、更暗的边缘描线。

/// 系统圆形玻璃图标按钮。由 GlassButtonStyle 提供一切视觉与交互，本工程零自绘。
struct SystemIconButton: View {
    let title: String
    let systemName: String
    var pointSize: CGFloat = 15
    let action: () -> Void

    @ViewBuilder
    var body: some View {
        if #available(iOS 26.0, *) {
            Button(title, systemImage: systemName, action: action)
                .labelStyle(.iconOnly)
                .font(.system(size: pointSize, weight: .semibold))
                .buttonStyle(.glass)                 // ← 苹果系统控件库
        } else {
            // iOS 17–25：系统 .bordered 样式 + 系统材质，仍是系统控件
            Button(title, systemImage: systemName, action: action)
                .labelStyle(.iconOnly)
                .font(.system(size: pointSize, weight: .semibold))
                .buttonStyle(.bordered)
                .tint(DS.ink)
        }
    }
}

/// 圆形玻璃按钮 —— 纯系统控件，零自绘：
/// `Button` + `.buttonStyle(.glass)` + `.buttonBorderShape(.circle)`。
/// 圆底和外圈高光全部由系统绘制；label 里只有一个 SF Symbol。
/// （iOS 17–25 回退到 `.ultraThinMaterial` + 描边，仅为外观降级，逻辑不变。）
struct GlassCircleButton: View {
    var systemImage: String? = nil
    var assetImage: String? = nil
    /// 资产图标的边长；默认与原生 toolbar 的 cube 字形同宽（≈21pt）。
    var iconSize: CGFloat = 21
    var accessibilityText: String = ""
    let action: () -> Void

    @ViewBuilder
    private var label: some View {
        // 与原生导航栏圆钮同尺寸：字形 17pt + .large，label 固定 DS.barButtonLabel，
        // 其余内边距由系统 glass 样式提供（实测渲染直径与原生 ToolbarItem 相同）。
        Group {
            if let assetImage {
                Image(assetImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: iconSize, height: iconSize)
            } else if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: DS.barButtonGlyph, weight: .medium))
                    .imageScale(.large)
            }
        }
        .frame(width: DS.barButtonLabel, height: DS.barButtonLabel)
        .contentShape(.circle)
    }

    @ViewBuilder
    var body: some View {
        let a11y = accessibilityText.isEmpty ? (assetImage ?? systemImage ?? "button") : accessibilityText
        if #available(iOS 26.0, *) {
            Button(action: action) { label }
                .buttonStyle(.glass)              // ← 苹果系统控件库
                .buttonBorderShape(.circle)       // ← 让系统把玻璃底裁成正圆
                .tint(DS.ink)
                .accessibilityLabel(a11y)
        } else {
            Button(action: action) {
                label.foregroundStyle(DS.ink)
                    .padding(7)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().strokeBorder(.white.opacity(0.65), lineWidth: 0.8))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(a11y)
        }
    }
}

/// 系统玻璃按钮，label 使用 Assets 里的自定义图（保留给需要位图 logo 的场景）。
struct SystemImageButton: View {
    let title: String
    let imageName: String
    var size: CGFloat = 36
    var iconSize: CGFloat = 18
    var opacity: Double = 0.85
    let action: () -> Void

    @ViewBuilder
    var body: some View {
        if #available(iOS 26.0, *) {
            Button(action: action) {
                label
            }
            .buttonStyle(.glass)                     // ← 苹果系统控件库
            .buttonBorderShape(.circle)
            .tint(DS.ink)
            .accessibilityLabel(title)
        } else {
            Button(action: action) {
                label
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().strokeBorder(.white.opacity(0.65), lineWidth: 0.8))
            }
            .buttonStyle(.plain)
            .tint(DS.ink)
            .accessibilityLabel(title)
        }
    }

    private var label: some View {
        Image(imageName)
            .resizable()
            .scaledToFit()
            .frame(width: iconSize, height: iconSize)
            .opacity(opacity)
            .contentShape(.circle)
    }
}

/// 胶囊玻璃容器（mini player / 波形条）—— 不是按钮，按 Apple 官方分工用
/// glassEffect(in:) 而非 buttonStyle。iOS 17–25 回退到系统材质。
struct NativeGlassCapsule: ViewModifier {
    var height: CGFloat = 56

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .frame(height: height)
                .glassEffect(.regular, in: Capsule())
        } else {
            content
                .frame(height: height)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().stroke(.white.opacity(0.72), lineWidth: 1))
                .shadow(color: .black.opacity(0.07), radius: 18, y: 4)
        }
    }
}

/// 同屏多个玻璃元素必须共享一个采样域，否则会出现 glass-on-glass 折射瑕疵。
struct NativeGlassContainer<Content: View>: View {
    private let spacing: CGFloat
    private let content: Content

    init(spacing: CGFloat = 24, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    @ViewBuilder
    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

extension View {
    func nativeGlassCapsule(height: CGFloat = 56) -> some View {
        modifier(NativeGlassCapsule(height: height))
    }
    /// 保留旧调用点，统一走原生玻璃分支
    func glassCapsule(height: CGFloat = 56) -> some View {
        nativeGlassCapsule(height: height)
    }
}

// MARK: - 系统 Tab bar
//
// iOS 27 起系统 TabView 本身就是悬浮 Liquid Glass 胶囊，且 Xcode 27 编译后
// 强制启用（不再允许 Info.plist 关闭）。因此 iOS 26/27 分支绝不能设置
// UITabBarAppearance 的 backgroundEffect / backgroundColor —— 那会把系统折射
// 玻璃覆盖成一层平涂模糊，正是「玻璃质感不对」的根源。

enum TabBarAppearance {
    static func configure() {
        if #available(iOS 26.0, *) {
            // 只设选中色，其余（材质、折射、高光、内缩、安全区、无障碍）全部交给系统
            UITabBar.appearance().tintColor =
                UIColor(red: 26.0 / 255, green: 26.0 / 255, blue: 28.0 / 255, alpha: 1)
        } else {
            // iOS 17–25：系统未提供 Liquid Glass，用公开外观 API 配置等效毛玻璃
            let appearance = UITabBarAppearance()
            appearance.configureWithTransparentBackground()
            appearance.backgroundEffect = UIBlurEffect(style: .systemUltraThinMaterialLight)
            appearance.backgroundColor = UIColor.white.withAlphaComponent(0.55)
            appearance.shadowColor = .clear

            // Icons only — hide any residual tab titles.
            let hiddenTitle: [NSAttributedString.Key: Any] = [
                .foregroundColor: UIColor.clear,
                .font: UIFont.systemFont(ofSize: 0.01)
            ]

            let normal = appearance.stackedLayoutAppearance.normal
            normal.iconColor = UIColor(red: 26.0 / 255, green: 26.0 / 255, blue: 28.0 / 255, alpha: 0.72)
            normal.titleTextAttributes = hiddenTitle

            let selected = appearance.stackedLayoutAppearance.selected
            selected.iconColor = UIColor(red: 26.0 / 255, green: 26.0 / 255, blue: 28.0 / 255, alpha: 1)
            selected.titleTextAttributes = hiddenTitle

            UITabBarItem.appearance().setTitleTextAttributes(hiddenTitle, for: .normal)
            UITabBarItem.appearance().setTitleTextAttributes(hiddenTitle, for: .selected)

            UITabBar.appearance().standardAppearance = appearance
            UITabBar.appearance().scrollEdgeAppearance = appearance
            UITabBar.appearance().tintColor =
                UIColor(red: 26.0 / 255, green: 26.0 / 255, blue: 28.0 / 255, alpha: 1)
        }
    }
}

// MARK: - TabView 的系统最小化行为（按 SDK 分级）

struct NativeTabBehavior: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 27.0, *) {
            // iOS 27：统一的 toolbar 最小化 API，可精确指定作用到 tabBar
            content.toolbarMinimizationBehavior(.onScrollDown, for: .tabBar)
        } else if #available(iOS 26.0, *) {
            // iOS 26：专用于 tab bar 的旧 API
            content.tabBarMinimizeBehavior(.onScrollDown)
        } else {
            content
        }
    }
}
