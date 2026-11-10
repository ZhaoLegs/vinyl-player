import SwiftUI
import MusicKit

/// 黑胶唱片。t392u / Build 211：外观移植自 Podium（https://github.com/mateuszlomni/podium,
/// Podium/Views/VinylView.swift，MIT License，Copyright (c) 2026 Podium contributors，见 THIRD_PARTY_NOTICES.md）：
/// 纯色近黑盘面 Color(white: 0.05) + 26 道细沟槽（每第 5 道稍亮）+ 圆形封面标签 + 小深色主轴孔，
/// 上面叠一层不随盘转的锥形反光（AngularGradient，-30°），外加较重的软投影。
/// 尺寸 / 旋转角 / 标签尺寸（DS.discLabel）/ 所有动画保持不变：只替换绘制。
struct VinylDiscView: View {
    let angle: Angle
    var pull: CGFloat = 0
    var coverName: String = DS.coverName(AlbumData.featuredIndex)
    var artwork: Artwork? = nil
    /// t204u：与首页格子 / 飞行封面同一张（官方封面优先）
    var official: OfficialCoverQuery? = nil
    var snapshot: MiniArtworkSnapshot? = nil
    /// t397u: when set, the disc drives its own rotation (TimelineView scoped to the rotating face only), so the
    /// per-frame work is one rotationEffect instead of re-evaluating the whole detail sleeve every frame. `angle` is ignored.
    var spinClock: DiscSpinClock? = nil

    /// Podium AppTheme.background — 主轴孔颜色
    static let holeColor = Color(red: 0.025, green: 0.03, blue: 0.04)

    var body: some View {
        let _ = DiscProfile.count("VinylDiscView.body")
        ZStack {
            // t397u: the shadow is cast by a static disc-sized circle under the face (same silhouette: the face is an
            // opaque circle of the same size) — the rotating layer no longer feeds the shadow pass
            Circle()
                .fill(Color(white: 0.05))
                .shadow(color: .black.opacity(Double(0.35 + 0.20 * pull)),
                        radius: 18 + 8 * pull, y: 8 + 6 * pull)

            // ① 随盘旋转：盘面 + 沟槽（静态 Canvas）+ 标签 + 主轴孔 —— t397u: Equatable face, skipped while only the angle changes
            if let spinClock {
                TimelineView(.animation(paused: spinClock.paused)) { tl in
                    let a = spinClock.angle(tl.date)
                    face.rotationEffect(.degrees(a))
                        .onChange(of: a, initial: true) { _, v in spinClock.onAngle(v) }
                }
            } else {
                face.rotationEffect(angle)
            }

            // ② Podium：反光固定不动，唱片在其下转动
            Circle()
                .fill(AngularGradient(colors: [.clear, .white.opacity(0.07), .clear, .clear, .white.opacity(0.05), .clear],
                                      center: .center, angle: .degrees(-30)))
                .allowsHitTesting(false)
        }
        .frame(width: DS.disc, height: DS.disc)
        // Podium 投影 black 0.55 / r26 / y14；这里在抽出（pull = 1）时达到 Podium 值，收在封套里时更轻（见上方静态圆）
    }

    private var face: some View {
        DiscFace(coverName: coverName, artwork: artwork, official: official, snapshot: snapshot).equatable()
    }
}

/// t397u: time source for a self-spinning disc (detail page). `angle(date)` is evaluated only inside the disc's TimelineView.
struct DiscSpinClock {
    var paused: Bool
    var angle: (Date) -> Double
    var onAngle: (Double) -> Void = { _ in }
}

/// t397u: the rotating part of the disc (grooves + label + spindle hole), Equatable so a new angle never re-evaluates it.
struct DiscFace: View, Equatable {
    var coverName: String
    var artwork: Artwork?
    var official: OfficialCoverQuery?
    var snapshot: MiniArtworkSnapshot?
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.coverName == rhs.coverName && lhs.artwork == rhs.artwork && lhs.official == rhs.official
            && lhs.snapshot?.cacheKey == rhs.snapshot?.cacheKey && lhs.snapshot?.image === rhs.snapshot?.image
    }
    var body: some View {
        let _ = DiscProfile.count("DiscFace.body")
        ZStack {
            VinylGrooves().equatable()
            DiscLabel(coverName: coverName, artwork: artwork, official: official, size: DS.discLabel, snapshot: snapshot)
            Circle()
                .fill(VinylDiscView.holeColor)
                .frame(width: DS.disc * 0.022, height: DS.disc * 0.022)
        }
        .clipShape(Circle())
    }
}

/// Podium 盘面 + 沟槽，一次性画在静态 Canvas 里：26 道 1pt 同心环，
/// 半径 = side/2 − side·(0.05 + i·0.012)，每第 5 道 white 0.07，其余 white 0.03。
struct VinylGrooves: View, Equatable {
    static func == (a: VinylGrooves, b: VinylGrooves) -> Bool { true }
    var body: some View {
        Canvas { context, size in
            let side = min(size.width, size.height)
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            context.fill(Path(ellipseIn: CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side)),
                         with: .color(Color(white: 0.05)))
            for i in 0..<26 {
                let r = side / 2 - side * (0.05 + CGFloat(i) * 0.012)
                let rect = CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
                context.stroke(Path(ellipseIn: rect),
                               with: .color(.white.opacity(i.isMultiple(of: 5) ? 0.07 : 0.03)),
                               lineWidth: 1)
            }
        }
    }
}

/// 唱片中心标签：封面等比填充（scaledToFill）后裁成正圆，不拉伸。
struct DiscLabel: View {
    var coverName: String
    var artwork: Artwork? = nil
    /// t204u：与首页格子 / 飞行封面同一张（官方封面优先）
    var official: OfficialCoverQuery? = nil
    let size: CGFloat
    var snapshot: MiniArtworkSnapshot? = nil

    var body: some View {
        let _ = DiscProfile.count("DiscLabel.body")
        Group {
            if let snapshot {
                snapshot.content
            } else if let artwork {
                ArtworkFill(artwork: artwork, render: 160, official: official)
            } else {
                Image(coverName)
                    .resizable()
                    .scaledToFill()
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
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
    /// t204u：与首页格子 / 飞行封面同一张（官方封面优先）
    var official: OfficialCoverQuery? = nil
    var snapshot: MiniArtworkSnapshot? = nil
    var pull: CGFloat
    var flip: Double
    let spin: Angle
    /// t397u: detail page passes its spin clock here; the disc rotates itself (see VinylDiscView.spinClock)
    var spinClock: DiscSpinClock? = nil
    /// 页面宽度：用来让「抽出状态的封套 + 露出的唱片」整体落在左右 DS.contentInset 之内
    var pageWidth: CGFloat = 402
    /// t356u: lyrics merge / flip keeps the sleeve at its pulled-out size (0.85) instead of growing back to 1.0
    var holdPulledScale = false
    var animatableData: AnimatablePair<CGFloat, Double> {
        get { AnimatablePair(pull, flip) }
        set { pull = newValue.first; flip = newValue.second }
    }

    /// t360u: on-screen rect of the pulled-out sleeve (pull = 1, scale 0.85) in this view's own DS.sleeve × DS.sleeve
    /// frame coordinates (frame centred on the page). 402pt page → x -27…233.1, y 22.95…283.05 (screen x 21…281.1).
    static func pulledSleeveRect(pageWidth: CGFloat) -> CGRect {
        let side = DS.sleeve * (1 - DS.pullScale)
        let restLeft = (pageWidth - DS.sleeve) / 2
        let pullX = restLeft + DS.sleeve * DS.pullScale / 2 - DS.contentInset
        let inset = DS.sleeve * DS.pullScale / 2
        return CGRect(x: inset - pullX, y: inset, width: side, height: side)
    }

    /// t361u: on-screen sleeve rect for any pull (same formulas as body: scale 1 - pullScale·pull, or 0.85 when held;
    /// centre shifted by -sleevePullX·pull). Linear in pull, so an offset/frame driven by it under the same
    /// transaction moves exactly with the sleeve. pull 1 → x -27…233.1; pull 0 + hold → x 22.95…283.05 = screen 70.95…331.05 (402pt page).
    static func sleeveRect(pageWidth: CGFloat, pull: CGFloat, hold: Bool) -> CGRect {
        let scale = hold ? 1 - DS.pullScale : 1 - DS.pullScale * pull
        let side = DS.sleeve * scale
        let restLeft = (pageWidth - DS.sleeve) / 2
        let pullX = restLeft + DS.sleeve * DS.pullScale / 2 - DS.contentInset
        let inset = (DS.sleeve - side) / 2
        return CGRect(x: inset - pullX * pull, y: inset, width: side, height: side)
    }

    private var discInset: CGFloat { (DS.sleeve - DS.disc) / 2 }
    private var sleeveRestLeft: CGFloat { (pageWidth - DS.sleeve) / 2 }
    /// 抽出时封套左移量：缩放后的封套左缘正好落在 contentInset
    private var sleevePullX: CGFloat { sleeveRestLeft + DS.sleeve * DS.pullScale / 2 - DS.contentInset }
    /// 抽出时唱片右移量：唱片右缘正好落在 pageWidth - contentInset
    private var discPullX: CGFloat { (pageWidth - DS.contentInset) - (sleeveRestLeft + discInset + DS.disc) }

    var body: some View {
        let _ = DiscProfile.count("SleeveArtwork.body")
        ZStack(alignment: .topLeading) {
            // 唱片在封套之后，抽出时向右位移并旋转
            VinylDiscView(angle: spin, pull: pull, coverName: coverName, artwork: artwork, official: official, snapshot: snapshot,
                          spinClock: spinClock)
                .offset(x: discInset + discPullX * pull, y: discInset)
                // t176u：翻到背面（过 90° 侧立的那一帧）唱片不再渲染 → 背面的孔是干净的透明挖孔，只透出页面背景；
                // 翻回正面时（同样在 90° 处）唱片重新出现在正面孔后
                .opacity(flip > 90 ? 0 : 1)

            // 封套缩小 + 左移，制造景深（对应原片 f44–f51）
            ZStack(alignment: .topLeading) {
                // 孔是封套的真实透明挖孔（下方 mask destinationOut），孔内不画任何独立图形：
                // 透过孔看到的就是后面那一张完整的大黑胶在孔位置的那一部分（随抽出位置变化）。
                // t144u：挖孔封套是静态的（只随 pull / flip 做变换），抽成 Equatable 子视图，转盘每帧不再重算它
                // t186u：翻过 90° 后背面 = 完整封面（无孔、无唱片）；翻回正面时恢复挖孔 + 唱片
                SleeveCutout(coverName: coverName, artwork: artwork, official: official, snapshot: snapshot, solid: flip > 90).equatable()
            }
            .scaleEffect(holdPulledScale ? 1 - DS.pullScale : 1 - DS.pullScale * pull, anchor: .center)   // 以中心缩放，封套中线不动 → 唱片始终上下居中
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
    var official: OfficialCoverQuery? = nil
    var snapshot: MiniArtworkSnapshot? = nil
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.coverName == rhs.coverName && lhs.artwork == rhs.artwork && lhs.official == rhs.official
            && lhs.solid == rhs.solid && lhs.snapshot?.cacheKey == rhs.snapshot?.cacheKey
            && lhs.snapshot?.image === rhs.snapshot?.image
    }
    /// t186u：true = 背面，完整封面不挖孔
    var solid: Bool = false
    var body: some View {
        Group {
            if let snapshot {
                snapshot.content
            } else if let artwork {
                ArtworkFill(artwork: artwork, official: official)
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
                            .frame(width: solid ? 0 : DS.planet,
                                   height: solid ? 0 : DS.planet)
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
                    .opacity(solid ? 0 : 1)
                    .allowsHitTesting(false)
            }
            // t231u：歌词面（solid）去掉硬阴影，改由歌词层顶部的高斯渐变模糊做溶开过渡
            .shadow(color: .black.opacity(solid ? 0 : 0.12), radius: solid ? 0 : 8, y: solid ? 0 : 5)
    }
}
