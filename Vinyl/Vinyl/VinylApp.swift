import SwiftUI

@main
struct VinylApp: App {
    @StateObject private var music = AppleMusicStore()
    @Environment(\.scenePhase) private var scenePhase
    private var recordingDemo: Bool {
        ProcessInfo.processInfo.arguments.contains("--record-demo")
            || ProcessInfo.processInfo.arguments.contains("--debug-mini-cycle")
    }
    init() {
        if ProcessInfo.processInfo.arguments.contains("--debug-mini-cycle") {
            setbuf(stdout, nil)
            if ProcessInfo.processInfo.arguments.contains("--debug-mini-official"),
               let image = UIImage(named: "cover_06") {
                OfficialCoverStore.shared.seedMiniDiagnostic(image)
            }
        }
        // iOS 26 分支只设置 tintColor，绝不覆盖 UITabBarAppearance 的
        // backgroundEffect / backgroundColor —— 那会把系统原生 Liquid Glass
        // 降格成一层平涂模糊。系统 TabView 自己会渲染折射玻璃胶囊。
        TabBarAppearance.configure()
        LyricsTrace.wipeIfCold()
        if LyricsTrace.on { setbuf(stdout, nil) }
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if TracklistProfile.enabled { TracklistProfileView() }
                else { ContentView() }
            }
                .task(id: scenePhase) {
                    if scenePhase == .active, GridScrollProfile.enabled,
                       ProcessInfo.processInfo.arguments.contains("--verify-perf") {
                        await GridScrollProfile.verify(music)
                        return
                    }
                    guard scenePhase == .active, !recordingDemo, !GridScrollProfile.enabled, !TracklistProfile.enabled else { return }
                    // 首次启动直接弹出系统的 Apple Music 授权；之后每次回到前台重新核对授权并刷新资料库。
                    if music.connectionRequested { await music.refreshAccess() }
                    else { await music.connect() }
                    await music.observePlayback()
                }
                .overlay(alignment: .top) { MusicErrorBanner() }
                .environmentObject(music)
                .environmentObject(music.timeline)
                .environmentObject(music.sleep)
                // t275u/t278u diagnostic: --debug-sleep=album | --debug-sleep=<minutes>, applied at launch
                // (was inside the --debug-open handler, so a plain home launch never set it)
                .task {
                    guard let a = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--debug-sleep=") }),
                          !music.sleep.isActive else { return }
                    let v = String(a.dropFirst("--debug-sleep=".count))
                    music.sleep.set(v == "album" ? .album : .minutes(Int(v) ?? 15))
                }
        }
    }
}
