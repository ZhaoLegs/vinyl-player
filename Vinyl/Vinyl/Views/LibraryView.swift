import SwiftUI
import UIKit

/// 上报被点击封面在 "library" 坐标空间中的 frame，作为 zoom 转场起点。
struct CoverFrameKey: PreferenceKey {
    static var defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

struct LibraryView: View {
    @StateObject private var playback = DemoPlaybackStore()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var presented = false
    @State private var closing = false
    @State private var autoplay = false
    @State private var zoom: CGFloat = 0
    @State private var contentAlpha: Double = 0
    @State private var blurRadius: CGFloat = 0
    @State private var origin: CGRect = .zero
    @State private var sleeveFrame: CGRect = .zero
    @State private var cellFrames: [Int: CGRect] = [:]
    @State private var selectedIndex = AlbumData.featuredIndex

    @State private var pull: CGFloat = 0
    @State private var flip: Double = 0
    @State private var demoToken = 0
    @State private var motionStart: Date = .distantPast
    @State private var recordingStarted = false
    private var recordingRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("--record-demo")
    }

    // 网格几何按原片实测：4 列、列宽 72pt、间距 17pt、左右 27pt
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 18), count: 4)

    var body: some View {
        GeometryReader { _ in
            ZStack(alignment: .topLeading) {
                AuroraBackground()
                homeContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .opacity(Double(1 - 0.72 * zoom))
                    .reviewVisible(!presented)

                AlbumDetailView(
                    coverName: DS.coverName(selectedIndex),
                    title: selectedIndex == AlbumData.featuredIndex ? AlbumData.title
                          : String(format: "Album %02d", selectedIndex),
                    artist: selectedIndex == AlbumData.featuredIndex ? AlbumData.artist
                          : "Various Artists",
                    pull: pull,
                    flip: flip,
                    contentAlpha: contentAlpha,
                    zoom: zoom,
                    isPresented: presented,
                    closing: closing,
                    motionStart: motionStart,
                    onClose: { close() },
                    onToggleArtwork: { toggleArtwork() }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(contentAlpha > 0.5)
                .reviewVisible(presented)

                // Keep the view alive while SwiftUI interpolates the target state.
                // Testing `zoom < 1` here removes it as soon as open() sets zoom = 1.
                flyingCover
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .coordinateSpace(name: "library")
            .environmentObject(playback)
            .task {
                playback.load()
                await playback.observe()
            }
            .onDisappear { playback.stop() }
            .onPreferenceChange(CoverFrameKey.self) { cellFrames = $0 }
            .onPreferenceChange(SleeveFrameKey.self) { sleeveFrame = $0 }
            .toolbar(presented ? .hidden : .visible, for: .tabBar)
            .task(id: demoToken) {
                await runDemo()
            }
            .task {
                if ProcessInfo.processInfo.arguments.contains("--review-detail") {
                    try? await Task.sleep(for: .seconds(1))
                    origin = cellFrames[AlbumData.featuredIndex] ?? .zero
                    open()
                    autoplay = false
                    demoToken += 1
                }
            }
            .task {
                guard ProcessInfo.processInfo.arguments.contains("--playback-check") else { return }
                try? await Task.sleep(for: .seconds(2))
                origin = cellFrames[AlbumData.featuredIndex] ?? .zero
                open()
                autoplay = false
                demoToken += 1
                await playback.acceptanceCheck()
            }
            .task {
                guard recordingRequested && !recordingStarted else { return }
                recordingStarted = true
                let requiredImages = (1...AlbumData.coverCount).map(DS.coverName)
                    + ["planet", "planet_back", "small_art", "sleeve_cutout"]
                let missing = requiredImages.filter { UIImage(named: $0) == nil }
                guard missing.isEmpty else {
                    recordingMarker("failed: missing images: " + missing.joined(separator: ", "))
                    return
                }
                // Give the scene time to report actual cover and sleeve geometry.
                do { try await Task.sleep(nanoseconds: 1_500_000_000) }
                catch { return }
                guard let measuredOrigin = cellFrames[AlbumData.featuredIndex],
                      sleeveFrame != .zero, !reduceMotion else {
                    recordingMarker("failed")
                    return
                }
                origin = measuredOrigin
                selectedIndex = AlbumData.featuredIndex
                recordingMarker("started")
                playback.playOrToggle(track: 0)
                open()
            }
        }
    }

    // MARK: - 首页

    private var homeContent: some View {
        libraryScroller
    }

    /// 左右上角：一个圆形玻璃底 + 一个 SF Symbol，全部由系统按钮样式绘制
    private var header: some View {
        HStack {
            // Assets logo mark inside system glass circle (not SF Symbol opticaldisc).
            GlassCircleButton(assetImage: "logo", iconSize: 17, accessibilityText: "Vinyl") { }
                .reviewElement("header-left", "左侧圆按钮", font: 17, radius: 22)
            Spacer(minLength: 0)
            GlassCircleButton(systemImage: "cube", iconSize: 17, accessibilityText: "新建") { }
                .reviewElement("header-right", "右侧圆按钮", font: 17, radius: 22)
        }
        .padding(.horizontal, DS.controlInset)
        .padding(.top, 6)
    }

    /// Both bars belong to the scroll view, so the system can soften both edges.
    @ViewBuilder
    private var libraryScroller: some View {
        if #available(iOS 26.0, *) {
            gridScroll
                // 原生 scroll edge effect：.soft = 渐进模糊，随内容接近边缘逐渐增强
                .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
                .safeAreaBar(edge: .top, spacing: 0) {
                    header
                        .padding(.bottom, 6)
                }
                // safeAreaBar 会把 mini player 贴到底部安全区，并**自动把滚动边缘效果延伸到它**，
                // 所以不需要再手写 LinearGradient mask。
                .safeAreaBar(edge: .bottom, spacing: 0) {
                    MiniPlayer()
                        .padding(.horizontal, DS.controlInset)
                        .padding(.bottom, DS.playerNavigationSpacing)
                }
        } else {
            // iOS 17–25 没有该 API：退回渐变遮罩（纯外观降级）。
            // 需要真模糊时接 VariableBlur / Variablur，见 README「底部渐变模糊」一节。
            VStack(spacing: 0) {
                header
                gridScroll
                    .mask(
                        LinearGradient(stops: [
                            .init(color: .black, location: 0),
                            .init(color: .black, location: 0.86),
                            .init(color: .clear, location: 1)
                        ], startPoint: .top, endPoint: .bottom)
                    )
                MiniPlayer()
                    .padding(.horizontal, DS.controlInset)
                    .padding(.bottom, DS.playerNavigationSpacing)
            }
        }
    }

    private var gridScroll: some View {
        ScrollView(showsIndicators: false) {
            LazyVGrid(columns: columns, spacing: 18) {
                ForEach(1...AlbumData.coverCount, id: \.self) { index in
                    coverCell(index)
                }
            }
            .padding(.horizontal, 20.5)
            .padding(.top, 12)
            .padding(.bottom, 8)
        }
        .blur(radius: blurRadius)
    }

    private func coverCell(_ index: Int) -> some View {
        Button {
            // 起点 = 被点击那一格在 library 坐标系里的真实 frame
            origin = cellFrames[index] ?? origin
            selectedIndex = index
            open()
        } label: {
            Image(DS.coverName(index))
                .resizable()
                .aspectRatio(1, contentMode: .fill)
                .clipShape(RoundedRectangle(cornerRadius: DS.corner))
                .coverShadow()
                .reviewElement("cover-\(index)", "专辑封面 \(index)", radius: DS.corner,
                               note: "阴影：黑色 12% / 模糊 4pt / 下移 3pt")
                .background {
                    GeometryReader { geo in
                        Color.clear.preference(key: CoverFrameKey.self,
                                               value: [index: geo.frame(in: .named("library"))])
                    }
                }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Zoom 转场中的飞行封面

    private var flyingCover: some View {
        let start = origin == .zero
            ? CGRect(x: 27, y: 385, width: 72, height: 72)
            : origin
        let end = sleeveFrame == .zero
            ? CGRect(x: 43.5, y: 130, width: DS.sleeve, height: DS.sleeve)
            : sleeveFrame
        return Image(DS.coverName(selectedIndex))
            .resizable()
            .modifier(CoverFlight(progress: zoom, start: start, end: end, closing: closing))
            .opacity(presented && !reduceMotion ? 1 : 0)
    }

    // MARK: - 动效时序（对应原片 185 帧 / 30fps）

    private func open() {
        guard !presented else { return }
        presented = true
        closing = false
        autoplay = true
        pull = 0
        flip = 0
        motionStart = Date()
        // 一条主 spring 驱动封面缩放与背景模糊（同一进度，不再各跑一条曲线）；
        // 详情文字用带 delay 的从曲线错峰淡入，形成「先放大 → 再显内容」的节奏。
        withAnimation(reduceMotion ? .easeOut(duration: 0.15) : Motion.animation(Motion.open)) {
            zoom = 1
            blurRadius = 18
        }
        // Detail copy fades in after the cover has started moving (reference frames 9–16).
        withAnimation(.easeInOut(duration: 7.0 / 30).delay(4.0 / 30)) {
            contentAlpha = 1
        }
        demoToken += 1
    }

    private func close() {
        guard presented && !closing else { return }
        closing = true
        autoplay = false
        demoToken += 1
        withAnimation(
            reduceMotion ? .easeOut(duration: 0.15) : Motion.animation(Motion.close),
            completionCriteria: .removed
        ) {
            zoom = 0
            blurRadius = 0
        } completion: {
            presented = false
            closing = false
            pull = 0
            flip = 0
            recordingMarker("complete")
        }
        withAnimation(.easeInOut(duration: 6.0 / 30).delay(2.0 / 30)) {
            contentAlpha = 0
        }
    }

    private func toggleArtwork() {
        guard presented && !closing else { return }
        autoplay = false
        demoToken += 1
        let pulling = pull < 0.5
        withAnimation(reduceMotion ? nil : Motion.animation(pulling ? Motion.pull : Motion.retract)) {
            pull = pulling ? 1 : 0
        }
    }

    /// Source f5 is the opening trigger. Offsets below are relative to that trigger.
    @MainActor
    private func runDemo() async {
        guard presented && !closing && autoplay && !reduceMotion else { return }
        guard await pause(1_200_000_000) else { return }
        withAnimation(Motion.animation(Motion.pull)) { pull = 1 }

        guard await pause(1_666_666_667) else { return }
        withAnimation(Motion.animation(Motion.retract)) { pull = 0 }

        guard await pause(766_666_667) else { return }
        // The source turns to side B, with readable artwork and a different label.
        withAnimation(Motion.animation(Motion.flip)) { flip = 180 }

        guard await pause(1_700_000_000) else { return }
        close()
    }

    @MainActor
    private func pause(_ nanoseconds: UInt64) async -> Bool {
        do {
            try await Task.sleep(nanoseconds: nanoseconds)
            return !Task.isCancelled && presented && !closing && autoplay
        } catch {
            return false
        }
    }

    /// Only the explicit simulator recording launch writes these completion markers.
    private func recordingMarker(_ phase: String) {
        guard recordingRequested else { return }
        guard let folder = FileManager.default.urls(for: .documentDirectory,
                                                     in: .userDomainMask).first else { return }
        try? phase.write(to: folder.appendingPathComponent("vinyl-recording-state.txt"),
                         atomically: true, encoding: .utf8)
    }
}

/// Derive geometry and handoff opacity from the *interpolated* presentation value.
private struct CoverFlight: AnimatableModifier {
    var progress: CGFloat
    let start: CGRect
    let end: CGRect
    var closing: Bool = false

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let linear = min(1, max(0, progress))
        let along = closing ? (1 - linear) : linear
        let sourceFrame = Double(closing ? (165 + along * 20) : (5 + along * 22))
        let sample = Motion.sample(closing ? Motion.closePath : Motion.openPath, frame: sourceFrame)
        let span = Motion.referenceSleeveSize - Motion.referenceCellSize
        let amount = CGFloat((sample.size - Motion.referenceCellSize) / span)
        let clamped = min(1, max(0, amount))
        let refStraightX = Motion.referenceCell.x + (Motion.referenceSleeve.x - Motion.referenceCell.x) * clamped
        let refStraightY = Motion.referenceCell.y + (Motion.referenceSleeve.y - Motion.referenceCell.y) * clamped
        let nativeX = start.minX + (end.minX - start.minX) * clamped
        let nativeY = start.minY + (end.minY - start.minY) * clamped
        let width = start.width + (end.width - start.width) * amount
        let turn = closing ? Motion.sampleYaw(frame: sourceFrame) : 0
        let visible = closing ? 1.0 : (1 - min(1, max(0, (linear - 0.88) / 0.12)))
        content
            .frame(width: width, height: width)
            .clipShape(RoundedRectangle(cornerRadius: DS.corner * (1 - clamped) + 2 * clamped))
            .rotation3DEffect(.degrees(turn), axis: (x: 0, y: 1, z: 0), perspective: 0.55)
            .shadow(color: .black.opacity(0.25), radius: 20 * clamped, y: 8 * clamped)
            .offset(x: nativeX + (sample.x - refStraightX),
                    y: nativeY + (sample.y - refStraightY))
            .opacity(visible)
    }
}

struct ArtworkHandoff: AnimatableModifier {
    var progress: CGFloat
    var closing: Bool = false

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let shown = closing ? 0 : min(1, max(0, (progress - 0.88) / 0.12))
        content.opacity(Double(shown))
    }
}
