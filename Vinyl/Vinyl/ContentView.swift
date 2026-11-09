import SwiftUI

enum AppTab: Int, Hashable {
    case library = 0, radio, profile, search
}

/// 底部导航全程使用苹果系统控件（TabView / Tab / UITabBar），无任何自定义 tab 视图。
///
/// 官方文档核验（developer.apple.com，2026-11）：
///   • TabView / Tab / Tab(_:systemImage:value:role:content:)   iOS 18.0+
///   • TabRole.search                                           iOS 18.0+
///   • TabRole.prominent                                        iOS 27.0+
///   • .tabViewStyle(.tabBarOnly)                               iOS 18.0+
///   • .tabBarMinimizeBehavior(_:)                              iOS 26.0+
///   • .toolbarMinimizationBehavior(_:for:)                     iOS 27.0+
///
/// 原片是「4 个等宽 tab 同处一条胶囊」，所以这里 4 个都用普通 `Tab`，
/// 不写 `role:` —— 系统 tab bar 天然就是等宽 + 选中高亮，形态与原片一致。
///
/// 两个可选 role（本项目未用，因为会改变形态）：
///   • `role: .search`   iOS 18+ / 视觉分离 iOS 26+：系统把该 tab 从主 bar 摘出、
///                       作为独立玻璃圆片钉在尾端。需要「独立搜索圆钮」时再加。
///   • `role: .prominent` iOS 27+：把某个**目的地** tab（购物车 / 票夹）放到尾端并强调，
///                       一条 tab bar 只能有一个，不是动作按钮（FAB）的替代品。
/// 两者都不影响「是不是系统控件」—— 控件始终是 `TabView` + `Tab`。
struct ContentView: View {
    @State private var selection: AppTab = .library

    var body: some View {
        Group {
            if #available(iOS 27.0, *) {
                // ── iOS 27 · Xcode 27 SDK ───────────────────────────────
                // 系统 TabView 本身就是悬浮 Liquid Glass 玻璃条，不叠任何自定义背景。
                TabView(selection: $selection) {
                    iconTab("资料库", "square.grid.2x2", AppTab.library) { LibraryView() }
                    iconTab("电台", "dot.radiowaves.left.and.right", AppTab.radio) {
                        SimplePage(title: "电台", symbol: "dot.radiowaves.left.and.right")
                    }
                    iconTab("我的", "person.crop.circle", AppTab.profile) {
                        MusicAccountView()
                    }
                    // 普通 tab：系统渲染等宽条目 + 选中高亮，形态与原片一致。
                    // 需要「独立搜索圆钮」时用 role: .search；需要强调某个
                    // 目的地 tab 时用 iOS 27 的 role: .prominent（只能一个）。
                    iconTab("搜索", "magnifyingglass", AppTab.search) {
                        MusicSearchView()
                    }
                }
                .tabViewStyle(.tabBarOnly)
                .modifier(NativeTabBehavior())
                .tint(DS.ink)

            } else if #available(iOS 26.0, *) {
                // ── iOS 26 ──────────────────────────────────────────────
                // Tab(_:systemImage:value:content:) 是系统原生 Tab 结构。
                // Xcode 26 重编译后 TabView 自动变成悬浮 Liquid Glass 玻璃条，
                // 无需任何自定义背景；下滑时系统自动收成小胶囊。
                TabView(selection: $selection) {
                    iconTab("资料库", "square.grid.2x2", AppTab.library) { LibraryView() }
                    iconTab("电台", "dot.radiowaves.left.and.right", AppTab.radio) {
                        SimplePage(title: "电台", symbol: "dot.radiowaves.left.and.right")
                    }
                    iconTab("我的", "person.crop.circle", AppTab.profile) {
                        MusicAccountView()
                    }
                    iconTab("搜索", "magnifyingglass", AppTab.search) {
                        MusicSearchView()
                    }
                }
                .modifier(NativeTabBehavior())
                .tint(DS.ink)

            } else if #available(iOS 18.0, *) {
                // ── iOS 18–25 ───────────────────────────────────────────
                // 同样是系统 Tab 结构（iOS 18+），只是没有 Liquid Glass 材质，
                // 由 TabBarAppearance 的 UIBlurEffect 分支提供等效毛玻璃。
                TabView(selection: $selection) {
                    iconTab("资料库", "square.grid.2x2", AppTab.library) { LibraryView() }
                    iconTab("电台", "dot.radiowaves.left.and.right", AppTab.radio) {
                        SimplePage(title: "电台", symbol: "dot.radiowaves.left.and.right")
                    }
                    iconTab("我的", "person.crop.circle", AppTab.profile) {
                        MusicAccountView()
                    }
                    iconTab("搜索", "magnifyingglass", AppTab.search) {
                        MusicSearchView()
                    }
                }
                .tint(DS.ink)

            } else {
                // ── iOS 17 ──────────────────────────────────────────────
                // tabItem 是 iOS 17 唯一可用的系统写法，底层同样是 UITabBar。
                TabView(selection: $selection) {
                    LibraryView()
                        .tabItem { Label("资料库", systemImage: "square.grid.2x2").labelStyle(.iconOnly) }
                        .tag(AppTab.library)
                    SimplePage(title: "电台", symbol: "dot.radiowaves.left.and.right")
                        .tabItem { Label("电台", systemImage: "dot.radiowaves.left.and.right").labelStyle(.iconOnly) }
                        .tag(AppTab.radio)
                    MusicAccountView()
                        .tabItem { Label("我的", systemImage: "person.crop.circle").labelStyle(.iconOnly) }
                        .tag(AppTab.profile)
                    MusicSearchView()
                        .tabItem { Label("搜索", systemImage: "magnifyingglass").labelStyle(.iconOnly) }
                        .tag(AppTab.search)
                }
                .tint(DS.ink)
            }
        }
    }

    /// Icon on screen, spoken name for VoiceOver. `.labelStyle(.iconOnly)` keeps the title out of the bar.
    @available(iOS 18.0, *)
    private func iconTab<V: View>(_ title: String, _ symbol: String, _ value: AppTab, @ViewBuilder content: () -> V) -> some TabContent<AppTab> {
        Tab(value: value) {
            content()
        } label: {
            Label(title, systemImage: symbol)
                .labelStyle(.iconOnly)
        }
    }
}

struct SimplePage: View {
    let title: String
    let symbol: String

    var body: some View {
        ZStack {
            AuroraBackground()
            VStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(DS.secondary)
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(DS.secondary)
                Text("该页面在原片中未出现，保留为系统 Tab 的空实现")
                    .font(.system(size: 11))
                    .foregroundStyle(DS.tertiary)
            }
        }
    }
}
