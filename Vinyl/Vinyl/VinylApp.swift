import SwiftUI

@main
struct VinylApp: App {
    @StateObject private var music = AppleMusicStore()
    @Environment(\.scenePhase) private var scenePhase
    private var recordingDemo: Bool {
        ProcessInfo.processInfo.arguments.contains("--record-demo")
    }
    init() {
        // iOS 26 分支只设置 tintColor，绝不覆盖 UITabBarAppearance 的
        // backgroundEffect / backgroundColor —— 那会把系统原生 Liquid Glass
        // 降格成一层平涂模糊。系统 TabView 自己会渲染折射玻璃胶囊。
        TabBarAppearance.configure()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(music)
                .task(id: scenePhase) {
                    guard scenePhase == .active, !recordingDemo else { return }
                    await music.refreshAccess()
                    await music.observePlayback()
                }
                .sheet(isPresented: $music.showingPlayer) {
                    MusicPlayerView().environmentObject(music)
                }
                .alert("Apple Music", isPresented: Binding(
                    get: { music.errorMessage != nil },
                    set: { if !$0 { music.errorMessage = nil } }
                )) {
                    Button("好") { music.errorMessage = nil }
                } message: {
                    Text(music.errorMessage ?? "")
                }
        }
    }
}
