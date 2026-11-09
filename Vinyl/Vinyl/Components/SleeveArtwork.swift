import SwiftUI
import MusicKit

/// 黑胶唱片：同心沟槽 + 镜面扇形高光 + 中心标签，播放时持续旋转。
///
/// 物理细节：唱片的**沟槽与中心标签**随盘转动，但**镜面反光是环境反射，方向固定**，
/// 不能跟着转。因此把旋转层与固定高光层拆开，转起来才有真实的黑胶质感。
struct VinylDiscView: View {
    let angle: Angle
    var pull: CGFloat = 0
    /// 中心标签 = 该专辑自己的封面（等比 aspect-fill 进圆形标签，演示用 Assets 封面，Apple Music 用 MusicKit 封面）
    var coverName: String = DS.coverName(AlbumData.featuredIndex)
    var artwork: Artwork? = nil

    var body: some View {
        ZStack {
            // 底色
            Circle()
                .fill(RadialGradient(colors: [Color(hex: 0x1E1E21), Color(hex: 0x0B0B0D), Color(hex: 0x151517)],
                                    center: .center, startRadius: 8, endRadius: DS.disc / 2))

            // ① 随盘旋转：沟槽 + 扇光 + 中心标签
            ZStack {
                // t144u：沟槽是静态图形，抽成 Equatable 子视图 → 唱片每帧转动（TimelineView）时不再重绘 Canvas
                VinylGrooves().equatable()
                Circle()
                    .fill(AngularGradient(colors: [
                        .white.opacity(0.10), .clear, .clear,
                        .white.opacity(0.055), .clear, .clear
                    ], center: .center))
                    .blendMode(.screen)
                DiscLabel(coverName: coverName, artwork: artwork, size: DS.discLabel)
                    .overlay(Circle().fill(.white).frame(width: 5, height: 5))   // 主轴孔在最上层
            }
            .clipShape(Circle())
            .rotationEffect(angle)

            // ② 固定环境镜面反光（不随盘转）：右下主高光 + 左上弱高光
            Circle()
                .fill(AngularGradient(colors: [
                    .clear, .clear, .white.opacity(0.05),
                    .white.opacity(0.20), .clear, .white.opacity(0.11), .clear
                ], center: .center))
                .blendMode(.screen)
            Circle().stroke(.white.opacity(0.08), lineWidth: 1)
            Circle()
                .stroke(.black.opacity(0.55), lineWidth: 12)
                .blur(radius: 12)
                .clipShape(Circle())
        }
        .frame(width: DS.disc, height: DS.disc)
        // 抽出时唱片离开封套、投影随位移加深，制造景深
        .shadow(color: .black.opacity(Double(0.17 + 0.06 * pull)),   // 原 0.35 + 0.12·pull，减半
                radius: 20 + 12 * pull, y: 10 + 8 * pull)
    }
}

/// 同心沟槽（静态；外观与原 Canvas 完全一致）
struct VinylGrooves: View, Equatable {
    static func == (a: VinylGrooves, b: VinylGrooves) -> Bool { true }
    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            var r: CGFloat = 26
            while r < size.width / 2 - 3 {
                let rect = CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
                context.stroke(Path(ellipseIn: rect),
                               with: .color(.white.opacity(0.045)),
                               lineWidth: 0.7)
                r += 2.4
            }
        }
    }
}

/// 唱片中心标签：封面等比填充（scaledToFill）后裁成正圆，不拉伸。
struct DiscLabel: View {
    var coverName: String
    var artwork: Artwork? = nil
    let size: CGFloat

    var body: some View {
        Group {
            if let artwork {
                ArtworkFill(artwork: artwork, render: 160)
            } else {
                Image(coverName)
                    .resizable()
                    .scaledToFill()
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().stroke(.black.opacity(0.25), lineWidth: 0.5))
    }
}

/// 封套中心圆孔后的「星球」：静止为蓝色星空，抽出唱片后变为黑白半月（原片 f52–f91）。
struct PlanetView: View {
    let moon: CGFloat
    var isBack = false

    var body: some View {
        ZStack {
            Image(isBack ? "planet_back" : "planet")
                .resizable()
            Circle()
                .fill(LinearGradient(stops: [
                    .init(color: Color(hex: 0xF0EBE0), location: 0),
                    .init(color: Color(hex: 0xF0EBE0), location: 0.5),
                    .init(color: Color(hex: 0x0A0A0C), location: 0.5),
                    .init(color: Color(hex: 0x0A0A0C), location: 1)
                ], startPoint: .leading, endPoint: .trailing))
                .opacity(Double(moon))
        }
        .clipShape(Circle())
        .overlay(Circle().stroke(.white.opacity(0.12), lineWidth: 1))
    }
}

/// 封套 + 唱片的完整组合动效。自身尺寸固定为 sleeve×sleeve（306），位置由父视图决定。
/// 层次（从下到上）：唱片 → 圆孔星球 → 挖孔封套。
struct SleeveArtwork: View, Animatable {
    /// 封套图：默认原片挖孔素材；点其它专辑时传入该封面，用同一比例的遮罩挖孔
    var coverName: String = "sleeve_cutout"
    /// 真实 Apple Music 封面；有值时替代 coverName 位图，同一套挖孔遮罩。
    var artwork: Artwork? = nil
    var pull: CGFloat
    var flip: Double
    let spin: Angle
    /// 页面宽度：用来让「抽出状态的封套 + 露出的唱片」整体落在左右 DS.contentInset 之内
    var pageWidth: CGFloat = 402
    var animatableData: AnimatablePair<CGFloat, Double> {
        get { AnimatablePair(pull, flip) }
        set { pull = newValue.first; flip = newValue.second }
    }

    private var discInset: CGFloat { (DS.sleeve - DS.disc) / 2 }
    private var sleeveRestLeft: CGFloat { (pageWidth - DS.sleeve) / 2 }
    /// 抽出时封套左移量：缩放后的封套左缘正好落在 contentInset
    private var sleevePullX: CGFloat { sleeveRestLeft + DS.sleeve * DS.pullScale / 2 - DS.contentInset }
    /// 抽出时唱片右移量：唱片右缘正好落在 pageWidth - contentInset
    private var discPullX: CGFloat { (pageWidth - DS.contentInset) - (sleeveRestLeft + discInset + DS.disc) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // 唱片在封套之后，抽出时向右位移并旋转
            VinylDiscView(angle: spin, pull: pull, coverName: coverName, artwork: artwork)
                .offset(x: discInset + discPullX * pull, y: discInset)

            // 封套缩小 + 左移，制造景深（对应原片 f44–f51）
            ZStack(alignment: .topLeading) {
                // 孔是封套的真实透明挖孔（下方 mask destinationOut），孔内不画任何独立图形：
                // 透过孔看到的就是后面那一张完整的大黑胶在孔位置的那一部分（随抽出位置变化）。
                // t144u：挖孔封套是静态的（只随 pull / flip 做变换），抽成 Equatable 子视图，转盘每帧不再重算它
                SleeveCutout(coverName: coverName, artwork: artwork).equatable()
            }
            .scaleEffect(1 - DS.pullScale * pull, anchor: .center)   // 以中心缩放，封套中线不动 → 唱片始终上下居中
            .offset(x: -sleevePullX * pull)
        }
        .frame(width: DS.sleeve, height: DS.sleeve, alignment: .topLeading)
        // 原片 f116–f119 的绕 Y 轴 3D 翻转；转到侧面时受光变暗
        // t161u：静止（0° / 180°）时亮度严格为 0，不让一个 ~1e-17 的滤镜常驻在挖孔封套上
        .brightness(abs(sin(flip * .pi / 180)) < 0.001 ? 0 : -0.16 * abs(sin(flip * .pi / 180)))
        .rotation3DEffect(.degrees(flip > 90 ? flip - 180 : flip),
                          axis: (x: 0, y: 1, z: 0), perspective: 0.55)
    }
}

/// 挖孔封套本体（外观与原内联实现一致）
struct SleeveCutout: View, Equatable {
    var coverName: String
    var artwork: Artwork?
    var body: some View {
        Group {
            if let artwork {
                ArtworkFill(artwork: artwork)
            } else {
                Image(coverName).resizable()
            }
        }
            .frame(width: DS.sleeve, height: DS.sleeve)
            // 孔直径 = sleeve × 28.06% ≈ 86pt，与原片 sleeve_cutout 实测一致
            .mask {
                Rectangle()
                    .overlay {
                        Circle()
                            .frame(width: DS.planet,
                                   height: DS.planet)
                            .blendMode(.destinationOut)
                    }
                    .compositingGroup()
            }
            // t161u：挖孔内缘一圈细暗边 + 内阴影：唱片收进封套（标签 = 同一张封面）时孔依然清楚可见
            .overlay {
                Circle()
                    .strokeBorder(.black.opacity(0.35), lineWidth: 1)
                    .background(Circle().strokeBorder(.black.opacity(0.18), lineWidth: 4).blur(radius: 2.5))
                    .frame(width: DS.planet, height: DS.planet)
                    .clipShape(Circle())
                    .allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(0.12), radius: 8, y: 5)
    }
}
