import SwiftUI
import MusicKit

/// 黑胶唱片：同心沟槽 + 镜面扇形高光 + 中心标签，播放时持续旋转。
///
/// 物理细节：唱片的**沟槽与中心标签**随盘转动，但**镜面反光是环境反射，方向固定**，
/// 不能跟着转。因此把旋转层与固定高光层拆开，转起来才有真实的黑胶质感。
struct VinylDiscView: View {
    let angle: Angle
    var pull: CGFloat = 0

    var body: some View {
        ZStack {
            // 底色
            Circle()
                .fill(RadialGradient(colors: [Color(hex: 0x1E1E21), Color(hex: 0x0B0B0D), Color(hex: 0x151517)],
                                    center: .center, startRadius: 8, endRadius: DS.disc / 2))

            // ① 随盘旋转：沟槽 + 扇光 + 中心标签
            ZStack {
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
                Circle()
                    .fill(AngularGradient(colors: [
                        .white.opacity(0.10), .clear, .clear,
                        .white.opacity(0.055), .clear, .clear
                    ], center: .center))
                    .blendMode(.screen)
                Image("planet")
                    .resizable()
                    .frame(width: 80, height: 80)
                    .clipShape(Circle())
                    .overlay(Circle().fill(.white).frame(width: 5, height: 5))
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
        .shadow(color: .black.opacity(Double(0.35 + 0.12 * pull)),
                radius: 20 + 12 * pull, y: 10 + 8 * pull)
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
    var animatableData: AnimatablePair<CGFloat, Double> {
        get { AnimatablePair(pull, flip) }
        set { pull = newValue.first; flip = newValue.second }
    }

    private var discInset: CGFloat { (DS.sleeve - DS.disc) / 2 }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // 唱片在封套之后，抽出时向右位移并旋转
            VinylDiscView(angle: spin, pull: pull)
                .offset(x: discInset + DS.discPull * pull, y: discInset)

            // 封套缩小 + 左移，制造景深（对应原片 f44–f51）
            ZStack(alignment: .topLeading) {
                PlanetView(moon: pull, isBack: flip >= 90)
                    .frame(width: DS.planet, height: DS.planet)
                    .offset(x: (DS.sleeve - DS.planet) / 2,
                            y: (DS.sleeve - DS.planet) / 2)

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
                    .shadow(color: .black.opacity(0.12), radius: 8, y: 5)
            }
            .scaleEffect(1 - DS.pullScale * pull, anchor: .center)   // 以中心缩放，封套中线不动 → 唱片始终上下居中
            .offset(x: -DS.sleevePull * pull)
        }
        .frame(width: DS.sleeve, height: DS.sleeve, alignment: .topLeading)
        // 原片 f116–f119 的绕 Y 轴 3D 翻转；转到侧面时受光变暗
        .brightness(-0.16 * abs(sin(flip * .pi / 180)))
        .rotation3DEffect(.degrees(flip > 90 ? flip - 180 : flip),
                          axis: (x: 0, y: 1, z: 0), perspective: 0.55)
    }
}
