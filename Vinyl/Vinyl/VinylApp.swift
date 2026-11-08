import SwiftUI

@main
struct VinylApp: App {
    init() {
        // iOS 26 分支只设置 tintColor，绝不覆盖 UITabBarAppearance 的
        // backgroundEffect / backgroundColor —— 那会把系统原生 Liquid Glass
        // 降格成一层平涂模糊。系统 TabView 自己会渲染折射玻璃胶囊。
        TabBarAppearance.configure()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
