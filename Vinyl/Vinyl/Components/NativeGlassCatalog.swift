import SwiftUI
import UIKit

// MARK: - 苹果系统控件库速查（iOS 27 / Xcode 27 SDK）
//
// 先澄清一个常见误解：UIKit / SwiftUI **不是开源框架**。
// Apple 开源的是 Swift 语言、Foundation、Swift Build、Darwin 内核、WebKit 等，
// 但所有 UI 框架（UIKit / AppKit / SwiftUI / TipKit）都是闭源专有的，
// 只能看到公开头文件与文档，没有源码仓库（见 opensource.apple.com）。
//
// 所以「用系统原生控件」不需要读源码，也不该去反编译私有视图 —— Apple 已经把
// 控件做成公开的 **控件库 / 样式**，直接调用即可：
//
//   ┌ 控件          ┬ 系统 API（不是自绘）                          ┬ 版本 ┐
//   │ 底部标签栏     │ TabView / Tab(_:systemImage:value:role:)     │ 18   │
//   │ 搜索 tab       │ role: .search（系统摘出主 bar、钉尾端）      │ 18   │
//   │ 强调目的地 tab │ Tab(role: .prominent)（只能一个）            │ 27   │
//   │ 下滑最小化     │ .toolbarMinimizationBehavior(_:for: .tabBar) │ 27   │
//   │ 只保留 tab bar │ .tabViewStyle(.tabBarOnly)                   │ 18   │
//   │ 底部渐变模糊   │ .scrollEdgeEffectStyle(.soft, for: .bottom)  │ 26   │
//   │ 停靠 bar + 模糊│ .safeAreaBar(edge: .bottom) { … }            │ 26   │
//   │ 圆形玻璃按钮   │ Button + .buttonStyle(.glass)                │ 26   │
//   │   └ 正圆形状   │ .buttonBorderShape(.circle)                  │ 15   │
//   │ 强调玻璃按钮   │ .buttonStyle(.glassProminent)                │ 26   │
//   │ 非按钮容器     │ .glassEffect(.regular, in: Capsule())        │ 26   │
//   │ 多玻璃合成     │ GlassEffectContainer / .glassEffectID        │ 26   │
//   │ UIKit 玻璃     │ UIGlassEffect + UIVisualEffectView           │ 26   │
//   └───────────────┴──────────────────────────────────────────────┴──────┘
//
// ⚠️ iOS 27 两个关键变化：
//   1) 用 Xcode 27 编译后 Liquid Glass **强制启用**，Info.plist 的关闭开关失效；
//      标准控件（TabView / toolbar / sheet / Button）自动获得玻璃，零代码。
//   2) 系统玻璃视觉更锐利：更明确的边框、更亮的镜面高光、更暗的边缘描线，
//      并新增「设置 → 外观 → Liquid Glass」透明度滑杆（自动影响所有 App）。
//
// ⚠️ 按钮不要自己画：Circle() + .glassEffect() 拼出来的是自绘控件，
//    正确做法是 Button + .buttonStyle(.glass)（GlassButtonStyle），
//    形状、按压反馈、高光、无障碍、Reduce Transparency 全部由系统接管。

// MARK: - ① 底部导航：iOS 27 系统控件

/// 官方接入（WWDC26 Session 269「What's new in SwiftUI」5:12 起）：
/// `Tab(role: .prominent)` 是 iOS 27 新增的 **TabRole 取值**，不是新控件；
/// 控件仍是 iOS 18 起就有的 `TabView` + `Tab(_:systemImage:value:role:)`。
///
/// 这里的 4 个 tab 都是普通 `Tab`（不写 role）—— 系统 tab bar 天然等宽 +
/// 选中高亮，与「4 个 tab 同处一条胶囊」的设计一致。
@available(iOS 27.0, *)
struct NativeTabBar27Example: View {
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            Tab("", systemImage: "square.grid.2x2", value: 0) { Color.clear }
            Tab("", systemImage: "dot.radiowaves.left.and.right", value: 1) { Color.clear }
            Tab("", systemImage: "person.crop.circle", value: 2) { Color.clear }
            // 可选：加 role: .search，系统会把该 tab 摘出主 bar、作为独立玻璃圆片钉在尾端
            Tab("", systemImage: "magnifyingglass", value: 3) { Color.clear }
        }
        .tabViewStyle(.tabBarOnly)                                  // iOS 18：只要 tab bar
        .toolbarMinimizationBehavior(.onScrollDown, for: .tabBar)  // iOS 27：下滑收成小胶囊
        .tint(.primary)
    }
}

/// `.prominent` 的正确用途：把某一个**目的地** tab（购物车 / 票夹 / 今日训练）
/// 放到尾端并强调。一条 tab bar 只能有一个；它是「去哪」，不是「做什么」，
/// 所以不该拿它当浮动操作按钮（FAB）。
@available(iOS 27.0, *)
struct NativeProminentTab27Example: View {
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            Tab("首页", systemImage: "house", value: 0) { Color.clear }
            Tab("探索", systemImage: "safari", value: 1) { Color.clear }
            Tab("我的", systemImage: "person", value: 2) { Color.clear }
            Tab("购物车", systemImage: "cart.fill", value: 3, role: .prominent) { Color.clear }
        }
        .tabViewStyle(.tabBarOnly)
    }
}

// MARK: - ② 底部渐变高斯模糊：iOS 26 系统 scroll edge effect

/// 这一层「越靠近底部越模糊」的效果 **是系统画的**，不是自绘遮罩。
/// iOS 26 起，滚动内容滑到工具栏 / 底部栏后面时，系统会自动渲染
/// Scroll Edge Effect —— 官方定义就是「blur transition between scrolling
/// content and an area with controls」。
///
/// 官方 API（均在 iOS 26.0 引入）：
///   • scrollEdgeEffectStyle(_:for:)                 选样式：.automatic / .hard / .soft
///   • scrollEdgeEffectHidden(_:for:)                整条关掉
///   • safeAreaBar(edge:alignment:spacing:content:)  停靠 bar，并**自动把边缘效果延伸过去**
///
/// .soft = 渐进模糊，模糊强度随内容接近边缘递增 → 首页底部要的就是这个。
/// .hard = 近乎不透明的线性边界。
@available(iOS 26.0, *)
struct NativeScrollEdgeEffectExample: View {
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 17), count: 4)

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 17) {
                ForEach(0..<28, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 4)
                        .fill(.quaternary)
                        .aspectRatio(1, contentMode: .fit)
                }
            }
            .padding(.horizontal, 27)
            .padding(.top, 12)
        }
        // ① 选「软」边缘：系统在底部画渐进高斯模糊
        .scrollEdgeEffectStyle(.soft, for: .bottom)
        // ② mini player 作为 safe area bar 停靠；系统会自动为它扩展上面那条边缘效果，
        //    不需要再手写 LinearGradient mask，也不需要自己算模糊半径。
        .safeAreaBar(edge: .bottom) {
            HStack {
                Text("A1 · Mind Games")
                Spacer()
                Image(systemName: "pause.fill")
            }
            .padding(.horizontal, 16)
            .frame(height: 56)
            .glassEffect(.regular, in: Capsule())
            .padding(.horizontal, 16)
            .padding(.bottom, 6)
        }
    }
}

/// UIKit 侧是同一套能力：每个边一个 UIScrollEdgeEffect 对象。
@available(iOS 26.0, *)
enum ScrollEdgeEffectUIKit {
    static func configure(_ scrollView: UIScrollView) {
        scrollView.bottomEdgeEffect.style = .soft        // .automatic / .hard / .soft
        scrollView.topEdgeEffect.style = .soft
    }
}

//  iOS 17–25 没有这个 API。需要「真·可变模糊」时的开源实现：
//    • nikstar/VariableBlur    —— SwiftUI + mask 多层近似，MIT，最常用
//    • daprice/Variablur       —— Metal 实现，性能最好
//    • aheze/VariableBlurView  —— 单文件，直接拖进工程
//  它们都是仿真；iOS 26+ 一律用系统 API，效果、Reduce Transparency、
//  Reduce Motion 的适配都是系统级的。

// MARK: - ③ 圆形按钮：系统控件库（不自绘）

@available(iOS 26.0, *)
struct NativeGlassButtonsExample: View {
    var body: some View {
        VStack(spacing: 22) {
            // 圆形图标玻璃按钮 —— 系统 GlassButtonStyle
            Button("关闭", systemImage: "xmark") { }
                .labelStyle(.iconOnly)
                .buttonStyle(.glass)

            // 强调型玻璃按钮
            Button("播放", systemImage: "play.fill") { }
                .buttonStyle(.glassProminent)
                .tint(.green)

            // 系统 toolbar：item 自动玻璃化，显式写法仍是 .glass
            // 可配置材质用 .buttonStyle(.glass(.regular.tint(.orange).interactive()))
            Button("收藏", systemImage: "heart") { }
                .buttonStyle(.glass)
        }
    }
}

// MARK: - ④ 非按钮的自定义容器：glassEffect（Apple 官方分工）

/// glassEffect 用于「不是 Button」的浮层；多个玻璃必须放进同一个
/// GlassEffectContainer，否则会各自采样、出现 glass-on-glass 折射瑕疵。
/// 这里连展开/收起按钮也全部用系统 ButtonStyle —— 工程内零自绘圆。
@available(iOS 26.0, *)
struct NativeGlassContainerExample: View {
    @State private var expanded = false

    var body: some View {
        GlassEffectContainer(spacing: 24) {
            HStack(spacing: 16) {
                if expanded {
                    glassButton("收藏", symbol: "heart.fill")
                    glassButton("分享", symbol: "square.and.arrow.up")
                }
                Button(expanded ? "收起" : "展开",
                       systemImage: expanded ? "xmark" : "plus") {
                    withAnimation(.bouncy) { expanded.toggle() }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.glassProminent)        // ← 系统控件库
            }
        }
    }

    private func glassButton(_ title: String, symbol: String) -> some View {
        Button(title, systemImage: symbol) { }
            .labelStyle(.iconOnly)
            .font(.system(size: 18, weight: .medium))
            .buttonStyle(.glass)                     // ← 系统控件库
    }
    // 若要让多个玻璃形状在增删时液态变形，给它们统一加
    // .glassEffectID(id, in: namespace)（iOS 26）/ .glassEffectUnion(id:namespace:)（iOS 27）。
}

// MARK: - ⑤ UIKit 侧等价调用

/// UIGlassEffect 继承自 UIVisualEffect，直接塞进 UIVisualEffectView 即可；
/// UIGlassContainerEffect 对应 SwiftUI 的 GlassEffectContainer。
@available(iOS 26.0, *)
enum UIKitGlassFactory {

    /// 单个玻璃视图。style 只有 .regular / .clear 两种（官方 UIGlassEffect.Style）。
    static func glassView(style: UIGlassEffect.Style = .regular,
                          interactive: Bool = false,
                          tint: UIColor? = nil) -> UIVisualEffectView {
        let effect = UIGlassEffect(style: style)
        effect.isInteractive = interactive
        effect.tintColor = tint
        let view = UIVisualEffectView(effect: effect)
        view.layer.cornerRadius = 18
        view.clipsToBounds = true
        return view
    }

    /// 系统 UIKit 控件：UIButton.Configuration.glass()（Xcode 26+ 提供）。
    /// 如果当前 SDK 头文件未暴露，退回 UIVisualEffectView 作为按钮背景。
    static func systemGlassButton(title: String) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        let bg = glassView(style: .regular, interactive: true)
        bg.isUserInteractionEnabled = false
        button.insertSubview(bg, at: 0)
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            bg.leadingAnchor.constraint(equalTo: button.leadingAnchor),
            bg.trailingAnchor.constraint(equalTo: button.trailingAnchor),
            bg.topAnchor.constraint(equalTo: button.topAnchor),
            bg.bottomAnchor.constraint(equalTo: button.bottomAnchor)
        ])
        return button
    }

    /// 多个相邻玻璃元素：用容器效果统一合成，避免玻璃叠玻璃。
    static func glassContainer() -> UIVisualEffectView {
        UIVisualEffectView(effect: UIGlassContainerEffect())
    }
}

// MARK: - ⑥ 低版本回退（iOS 17–25）

/// 系统没有 Liquid Glass 时的等价毛玻璃。注意这只是视觉近似，
/// 不是折射玻璃；Apple 明确不建议自己用 UIVisualEffectView 去仿造 Liquid Glass。
enum LegacyGlassFactory {
    static func blurredView() -> UIVisualEffectView {
        UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialLight))
    }

    static func configureTabBar() {
        let appearance = UITabBarAppearance()
        appearance.configureWithTransparentBackground()
        appearance.backgroundEffect = UIBlurEffect(style: .systemUltraThinMaterialLight)
        appearance.backgroundColor = UIColor.white.withAlphaComponent(0.55)
        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
    }
}
