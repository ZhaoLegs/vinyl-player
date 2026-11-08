import SwiftUI

/// 上报被点击封面在 "library" 坐标空间中的 frame，作为 zoom 转场起点。
struct CoverFrameKey: PreferenceKey {
    static var defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

struct LibraryView: View {
    @State private var presented = false
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

    // 网格几何按原片实测：4 列、列宽 72pt、间距 17pt、左右 27pt
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 17), count: 4)

    var body: some View {
        GeometryReader { _ in
            ZStack(alignment: .topLeading) {
                homeContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .blur(radius: blurRadius)
                    .opacity(Double(1 - 0.72 * zoom))

                if presented && zoom < 0.995 {
                    flyingCover
                }

                AlbumDetailView(
                    coverName: DS.coverName(selectedIndex),
                    title: selectedIndex == AlbumData.featuredIndex ? AlbumData.title
                          : String(format: "Album %02d", selectedIndex),
                    artist: selectedIndex == AlbumData.featuredIndex ? AlbumData.artist
                          : "Various Artists",
                    pull: pull,
                    flip: flip,
                    waveProgress: 0.18,
                    contentAlpha: contentAlpha,
                    motionStart: motionStart,
                    onClose: { close() },
                    onToggleArtwork: { toggleArtwork() }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(contentAlpha > 0.5)
            }
            .coordinateSpace(name: "library")
            .onPreferenceChange(CoverFrameKey.self) { cellFrames = $0 }
            .onPreferenceChange(SleeveFrameKey.self) { sleeveFrame = $0 }
            .task(id: demoToken) {
                await runDemo()
            }
        }
    }

    // MARK: - 首页

    private var homeContent: some View {
        VStack(spacing: 0) {
            header
            libraryScroller
        }
    }

    /// 左右上角：一个圆形玻璃底 + 一个 SF Symbol，全部由系统按钮样式绘制
    private var header: some View {
        HStack {
            GlassCircleButton(systemImage: "opticaldisc", accessibilityText: "Vinyl") { }
            Spacer(minLength: 0)
            GlassCircleButton(systemImage: "cube", accessibilityText: "新建") { }
        }
        .padding(.horizontal, 27)
        .padding(.top, 6)
    }

    /// 底部「渐变高斯模糊」——iOS 26 起是系统能力，不是自绘遮罩。
    @ViewBuilder
    private var libraryScroller: some View {
        if #available(iOS 26.0, *) {
            gridScroll
                // 原生 scroll edge effect：.soft = 渐进模糊，随内容接近边缘逐渐增强
                .scrollEdgeEffectStyle(.soft, for: .bottom)
                // safeAreaBar 会把 mini player 贴到底部安全区，并**自动把滚动边缘效果延伸到它**，
                // 所以不需要再手写 LinearGradient mask。
                .safeAreaBar(edge: .bottom) {
                    MiniPlayer()
                        .padding(.horizontal, 16)
                        .padding(.bottom, 6)
                }
        } else {
            // iOS 17–25 没有该 API：退回渐变遮罩（纯外观降级）。
            // 需要真模糊时接 VariableBlur / Variablur，见 README「底部渐变模糊」一节。
            VStack(spacing: 0) {
                gridScroll
                    .mask(
                        LinearGradient(stops: [
                            .init(color: .black, location: 0),
                            .init(color: .black, location: 0.86),
                            .init(color: .clear, location: 1)
                        ], startPoint: .top, endPoint: .bottom)
                    )
                MiniPlayer()
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
            }
        }
    }

    private var gridScroll: some View {
        ScrollView(showsIndicators: false) {
            LazyVGrid(columns: columns, spacing: 17) {
                ForEach(1...AlbumData.coverCount, id: \.self) { index in
                    coverCell(index)
                }
            }
            .padding(.horizontal, 27)
            .padding(.top, 12)
            .padding(.bottom, 8)
        }
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
        let width = start.width + (end.width - start.width) * zoom
        let x = start.minX + (end.minX - start.minX) * zoom
        let y = start.minY + (end.minY - start.minY) * zoom

        return Image(DS.coverName(selectedIndex))
            .resizable()
            .frame(width: width, height: width)
            .clipShape(RoundedRectangle(cornerRadius: DS.corner * (1 - zoom) + 2 * zoom))
            .shadow(color: .black.opacity(0.25), radius: 20 * zoom, y: 8 * zoom)
            .offset(x: x, y: y)
            .opacity(Double(zoom > 0.9 ? (1 - zoom) * 10 : 1))
    }

    // MARK: - 动效时序（对应原片 185 帧 / 30fps）

    private func open() {
        guard !presented else { return }
        presented = true
        motionStart = Date()
        // 一条主 spring 驱动封面缩放与背景模糊（同一进度，不再各跑一条曲线）；
        // 详情文字用带 delay 的从曲线错峰淡入，形成「先放大 → 再显内容」的节奏。
        withAnimation(Motion.animation(Motion.open)) {
            zoom = 1
            blurRadius = 18
        }
        withAnimation(.easeOut(duration: 0.19).delay(0.08)) {
            contentAlpha = 1
        }
        demoToken += 1
    }

    private func close() {
        withAnimation(Motion.animation(Motion.close)) {
            zoom = 0
            blurRadius = 0
            contentAlpha = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            presented = false
            pull = 0
            flip = 0
        }
    }

    private func toggleArtwork() {
        let pulling = pull < 0.5
        withAnimation(Motion.animation(pulling ? Motion.pull : Motion.retract)) {
            pull = pulling ? 1 : 0
        }
    }

    /// f17–f43 静止 → f44–f51 抽出 → f52–f91 旋转 → f92–f96 收回
    /// → f97–f115 静止 → f116–f119 3D 翻转 → f120–f165 静止 → f166 关闭
    @MainActor
    private func runDemo() async {
        guard presented else { return }
        try? await Task.sleep(nanoseconds: 900_000_000)
        guard presented else { return }
        withAnimation(Motion.animation(Motion.pull)) { pull = 1 }

        try? await Task.sleep(nanoseconds: 1_600_000_000)
        guard presented else { return }
        withAnimation(Motion.animation(Motion.retract)) { pull = 0 }

        try? await Task.sleep(nanoseconds: 700_000_000)
        guard presented else { return }
        // 翻转也走 spring，避免 easeInOut 在 4 帧内硬起硬停
        withAnimation(Motion.animation(Motion.flip)) { flip = 86 }
        try? await Task.sleep(nanoseconds: 70_000_000)
        withAnimation(Motion.animation(Motion.flip)) { flip = 0 }

        try? await Task.sleep(nanoseconds: 1_500_000_000)
        guard presented else { return }
        close()
    }
}
