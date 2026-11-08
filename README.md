# Vinyl · iOS 黑胶唱片应用复刻（iOS 27 / Xcode 27）

对一段 6.17s / 185 帧的 iOS 应用录屏做逐帧拆解后的 1:1 复刻。含浏览器交互原型、SwiftUI 原生工程、逐帧分析文档与两版演示视频。

本轮重点：**让底部导航真的像 iOS 27 系统 tab bar**（宽玻璃选中滑块 + 正确几何 + 系统位置）、**mini player 改回玻璃并压到 40pt**、**唱片抽出后与封套上下居中**。此前几轮已完成的：首页网格按原片实测重排（72pt / 间距 17pt）、展开动画改为「点哪张就从那张延展」、底部渐变模糊改用系统 `scrollEdgeEffectStyle(.soft, for: .bottom)`、左右上角用系统玻璃圆按钮、底部导航用 iOS 27 系统 `TabView` / `Tab`（无 role、无自绘）。API 版本与签名逐条对照过官方文档，见 [`官方接入.md`](官方接入.md)。

## 交付内容

| 路径 | 说明 |
|---|---|
| `preview/index.html` | **浏览器高保真交互原型**。逐帧对照原片，实时参数 + **动效曲线可视化面板**（画出当前阶段的 spring 曲线与播放头）+ 系统控件接入速查卡（含 API 版本表） |
| `preview/assets/` | 28 张 iTunes 真实专辑封面（600×600 高清）+ 原片封套/挖孔封套/星球标签/图标 + 22 张原片对照帧 |
| `Vinyl/` | **完整 SwiftUI iOS 工程**（Xcode 27 / iOS 17+ 部署），底部 Tab 用系统 `TabView`，圆形按钮全部用系统 ButtonStyle |
| `Vinyl.zip` | 工程打包 |
| `Vinyl_复刻演示.mp4` | 竖屏纯手机画面演示（185 帧 / 30fps / 6.167s） |
| `Vinyl_原片对照.mp4` | 左原片 / 右复刻同步对照，带帧号、阶段名与动效参数字幕 |
| `逐帧分析.md` | 11 段分镜表、界面解构、设计代币、动效曲线、原生控件调用、实现映射 |
| `官方接入.md` | 系统控件接入的官方核验：TabView 版本表、scroll edge effect（渐变模糊）、圆形玻璃按钮，以及三个常见错误 |

## 运行

**浏览器原型**：直接用浏览器打开 `preview/index.html`（推荐 Chrome / Safari）。
- 默认自动播放 6.17s 循环，可暂停 / 拖动帧号 / 点击分镜阶段跳转；
- 点击网格**任意一张**封面，都会从那一格的位置与封面图延展到详情页；点击封套手动切换唱片抽拉；点击 `X` 返回；
- 左侧面板实时给出当前帧全部动效参数 + **当前动效曲线**，并画出绿色 spring 曲线（灰虚线为线性参考、圆点为当前帧）；参数表列出 5 段 spring 与旋转角速度的 response / damping / 过冲，当前行高亮；
- 右下角显示最接近的原片帧。

**Xcode 工程**：用 **Xcode 27**（iOS 27 SDK）打开 `Vinyl/Vinyl.xcodeproj`，选择 iPhone 15 Pro 模拟器（393×852pt）运行。
- 零第三方依赖，不需要 CocoaPods / SPM；
- 部署目标 iOS 17.0，SDK 分级用 `#available` 保护：iOS 27 → iOS 26 → iOS 18–25 → iOS 17 四级回退；
- ⚠️ **源码引用了 iOS 27 / 26 符号（`TabRole.prominent`、`toolbarMinimizationBehavior`、`.buttonStyle(.glass)`、`UIGlassEffect` 等），必须用 Xcode 27 及以上 SDK 编译**。只有 Xcode 26 时，把 `ContentView.swift` 的 iOS 27 分支与 `NativeGlassCatalog.swift` 中 `@available(iOS 27.0, *)` 的示例（`NativeProminentTab27Example`）移除即可；
- 在 **iOS 26/27 设备/模拟器**上才能看到系统 Liquid Glass；iOS 17–25 自动回退 `UIBlurEffect` / `.ultraThinMaterial`；
- 点击任意封面后，自动按原片时序演示：静止 → 唱片抽出 → 旋转 → 收回 → 3D 翻转 → 关闭。第 13 张（原片那张 Mind Games）有完整专辑数据，其余用编号占位。

## 工程结构

```
Vinyl/
├── Vinyl.xcodeproj/project.pbxproj      CreatedOnToolsVersion = 27.0
└── Vinyl/
    ├── VinylApp.swift                   @main，TabBarAppearance 条件配置
    ├── ContentView.swift                TabView 四级分支（iOS 27 / 26 / 18–25 / 17）
    ├── Model.swift                      曲目 / 专辑数据
    ├── DesignTokens.swift               颜色、尺寸、光晕背景、Motion 曲线、
    │                                    系统控件库按钮（SystemIconButton 等）、Tab 行为
    ├── Views/
    │   ├── LibraryView.swift            首页 + zoom 转场 + 统一 spring 时序驱动
    │   └── AlbumDetailView.swift        详情页 + 角速度积分旋转 + 系统玻璃顶部栏
    ├── Components/
    │   ├── NativeGlassCatalog.swift     ★ 苹果系统控件库速查（iOS 27 / SwiftUI / UIKit）
    │   ├── SleeveArtwork.swift          唱片 / 星球 / 挖孔封套 / 抽拉 / 3D 翻转
    │   └── PlayerBars.swift             Mini player + 波形条（系统 SF Symbols 控件）
    ├── Resources/                       34 张 png
    └── Assets.xcassets/
```

---

## 〇、首页几何与展开动画（本轮）

### 网格按原片实测重排

原片是 393×852pt，逐像素量出网格：列宽 46px、间距 11px、左右边距 18px（换算后 **72pt / 17pt / 27pt**），首行顶边 117pt。之前用的 80.75pt + 10pt 间距偏大偏挤，本轮全部对齐实测值：

| | 之前 | 现在（= 原片实测） |
|---|---|---|
| 列宽 | 80.75pt | **72pt** |
| 间距 | 10pt | **17pt** |
| 左右边距 | 20pt | **27pt** |
| 首行顶部 | 130pt | **118pt** |

### 延展动画：从被点击的那一格开始

之前的 `.flying` 封面是写死在第 4 行第 1 列的，点任何封面都从那一格飞出来 —— 这是明显的错位。现在的做法：

1. 点击时读该格在屏幕坐标系里的真实 `getBoundingClientRect()`，连同封面图一起注入飞行层；
2. 飞行层 `transform-origin: top left`，位移量 = `目标(43.5,130) − 起点`，缩放 = `306 / 起点边长`，一次算完，任何一格都能精确落到详情页封套位置；
3. 飞行层从 `.home` 里提出来，挂在屏幕直属层 —— 否则会跟着首页的 `opacity` / `blur` 一起淡出、变糊，延展感就没了；
4. 关闭时同一条 spring 反着跑回那一格。

SwiftUI 工程里对应 `CoverFrameKey` 改成 `[Int: CGRect]` 字典，每格用 `GeometryReader` 上报自己的 frame，点击时取 `cellFrames[index]` 作为 zoom 转场起点；飞行封面也用 `selectedIndex` 对应的图。

### 任意封面都能进详情

原片只有 Mind Games 一张的完整数据，但交互上不该「点 A 放大、落地变 B」。现在：第 13 张（原片那张）用完整数据与预制挖孔封套；其余封面用该封面图 + 同比例径向遮罩挖孔（孔径 **28.06%**，从 `sleeve_cutout.png` 的 alpha 通道实测），标题显示 `Album XX`，曲目用占位。点哪张，落地就是哪张。

### 左右上角：圆形玻璃底 + 一个图标

原来左上是一个带白底的 png、右上是彩色立体箱子图。现在两边都是同一个系统控件：

```swift
Button { } label: {
    Image(systemName: systemImage)          // 只有一个 SF Symbol
        .font(.system(size: 20))
        .frame(width: 44, height: 44)
        .contentShape(.circle)
}
.buttonStyle(.glass)          // iOS 26 · 系统玻璃
.buttonBorderShape(.circle)   // 系统把玻璃底裁成正圆
```

对应 `DesignTokens.GlassCircleButton`，首页与详情页 header 共用。圆底、镜面高光、暗描边、按压反馈、Reduce Transparency 全部由系统绘制。

### 底部渐变高斯模糊：系统 scroll edge effect

之前 `.homefade` 是一条 `linear-gradient` 到背景色，本质是「渐白」，不是模糊。iOS 26 起这是系统能力：

```swift
ScrollView { LazyVGrid(…) { … } }
    .scrollEdgeEffectStyle(.soft, for: .bottom)   // 系统渐进高斯模糊
    .safeAreaBar(edge: .bottom) { MiniPlayer() }   // 边缘效果自动延伸到 bar 后面
```

`ScrollEdgeEffectStyle.soft` 的官方定义就是「subtle, blurred boundary between pinned controls and scrolling content」。用 `safeAreaBar` 而不是 `safeAreaInset`，是因为前者会把边缘效果一起延伸过去，后者只让出空间。

iOS 17–25 没有该 API，回退分支才用 `LinearGradient` 遮罩；要真模糊需接 [`nikstar/VariableBlur`](https://github.com/nikstar/VariableBlur) 或 Metal 版 [`daprice/Variablur`](https://github.com/daprice/Variablur)（引入前请自行确认许可）。

浏览器预览里这层是 **单层 30px `backdrop-filter` + 由弱到强的同向 mask**：模糊半径固定、强度随位置渐入，下沿一直伸到 tab bar 底下。不用多层叠加，是因为 Chromium 里叠在另一层 `backdrop-filter` 之上的层拿不到正确的 backdrop，反而只剩最底一层生效、在玻璃条里留下封面的硬边。

### 底部 Tab Bar：像不像系统，关键在选中态与几何

iOS 26/27 的 iPhone tab bar 不是一个贴底的白条，而是**悬浮玻璃胶囊**：

| 项 | 系统实际值 | 常见自绘错误 |
|---|---|---|
| 位置 | 左右 16pt、距底 31pt（Home Indicator 上方 18pt） | 贴底、压住 Home Indicator |
| 高度 | 56pt 胶囊（圆角 = 高度 / 2） | 80–90pt 的「工具栏」 |
| 图标 | 25pt SF Symbol，无文字标签 | 22pt 描边图标 + 中文 label |
| 选中态 | **约 1/4 条宽的玻璃滑块**（44pt 高、胶囊形、高光边），切换时弹簧滑过去 | 54×36 的小圆角方块 / 纯白实心块 |
| 材质 | 系统折射玻璃，内容在下面滚动 | `UITabBarAppearance.backgroundEffect` 平涂模糊 |

Xcode 工程里这一整条由 `TabView { Tab(...) }` 生成，选中滑块、弹簧、材质、无障碍全部由系统绘制；浏览器原型只是按同一套几何与光学做像素级等价（见 `preview/index.html` 的 `.tabbar` / `.tabpill`）。

### Mini player：40pt 系统玻璃胶囊

mini player 不是按钮，按 Apple 的分工用 `.glassEffect(.regular, in: Capsule())`，而不是 `.buttonStyle(.glass)`：

```swift
HStack { … }
    .padding(.leading, 12).padding(.trailing, 14)
    .glassCapsule(height: 40)   // NativeGlassCapsule → .glassEffect(.regular, in: Capsule())
```

高度从 56 压到 40pt（原片实测 49px / 1.22 ≈ 40pt），缩略图 27pt，标题 13pt / 副标题 10.5pt。`safeAreaBar` 会把这层玻璃自动接到系统 scroll edge effect 上，不需要自己再画渐变。

### 唱片抽出：以封套中心缩放

原片里唱片和封套是**同一条水平中线**：封套缩小时如果还以左上角为锚点，中心会上移，唱片看起来就「掉」到封套下面。正确做法是把封套组的缩放锚点改到中心，再整体左移：

```swift
ZStack { PlanetView(); Image(coverName) }
    .scaleEffect(1 - 0.15 * pull, anchor: .center)   // 中线不动
    .offset(x: -54 * pull)                            // 只做水平让位
```

唱片本身 ⌀269pt（封套的 0.88），抽出 +56pt。这样抽出后唱片上下边缘与封套几乎齐平（原片 f052：封套 318px、唱片 329px），圆心始终对齐。

---

## 一、「苹果应该是开源的吧」——不是

**UIKit / SwiftUI 是闭源专有框架。** Apple 在 `opensource.apple.com` 开源的是 Swift 语言、Foundation、Swift Build、libdispatch、Darwin 内核、WebKit、CUPS 等，所有 UI 框架都不在其中，只有公开头文件与文档，没有源码仓库。

但**用系统控件不需要源码**。Apple 把控件与材质做成了公开的控件库 / 样式，直接调用即可：

| 控件 | 苹果系统 API（不是自绘） | 版本 |
|---|---|---|
| 底部标签栏 | `TabView` / `Tab(_:systemImage:value:role:)` | 18 |
| 搜索 tab（分离成独立圆钮） | `Tab(..., role: .search)` —— 本项目未用，会改变形态 | 18 |
| 强调某个目的地 tab | `Tab(..., role: .prominent)`（只能一个）—— 本项目未用 | 27 |
| 下滑最小化 | `.toolbarMinimizationBehavior(.onScrollDown, for: .tabBar)` | 27 |
| 只保留 tab bar | `.tabViewStyle(.tabBarOnly)` | 18 |
| **圆形玻璃按钮** | **`Button` + `.buttonStyle(.glass)`（GlassButtonStyle）** | 26 |
| 强调玻璃按钮 | `.buttonStyle(.glassProminent)` | 26 |
| 非按钮浮层容器 | `.glassEffect(.regular, in: Capsule())` | 26 |
| 多玻璃合成 / 变形 | `GlassEffectContainer` / `.glassEffectID` | 26 |
| UIKit 玻璃 | `UIGlassEffect(style:)` + `UIVisualEffectView` | 26 |
| 图标 | `Image(systemName:)`（SF Symbols） | — |

### 本轮改掉的关键问题

- **之前**：圆形按钮是 `Circle() + .glassEffect()` 拼出来的自绘控件（`NativeGlassCircle` / `GlassIconButton`），暂停图标是自绘 `Capsule()`。
- **现在**：全部换成系统控件库 —— `SystemIconButton` / `SystemImageButton` → `Button` + `.buttonStyle(.glass)`；暂停图标 → `Button("暂停", systemImage: "pause.fill")` + SF Symbols。**工程内零自绘圆形按钮**，形状、按压高光、无障碍、Reduce Transparency 全由系统渲染。
- **之前**：底部导航停在 iOS 26 的 `Tab(_:systemImage:value:)`，搜索项写成了 `role: .prominent`。
- **现在**：4 个都是**普通 `Tab`，不写 `role:`** —— 系统 tab bar 天然等宽 + 选中高亮，与原片「4 个图标同处一条胶囊」完全一致。`role: .search` 会让系统把该 tab 摘出主 bar 变成独立圆钮（形态就变了），`role: .prominent` 是 iOS 27 给「购物车 / 票夹」这类目的地 tab 用的，两者都不是原片要的形态。配套 `.tabViewStyle(.tabBarOnly)` + `.toolbarMinimizationBehavior(.onScrollDown, for: .tabBar)`。

### iOS 27 两个必须知道的变化

1. **Liquid Glass 强制启用**：用 Xcode 27 编译后，Info.plist 的关闭开关失效，标准控件自动玻璃化（零代码）。
2. **玻璃视觉更锐利**：更明确的边框、更亮的镜面高光、更暗的边缘描线；新增「设置 → 外观 → Liquid Glass」透明度滑杆，自动影响所有 App。原型 CSS 已同步这层更锐利的高光/描边。

### 一个容易踩的坑

`TabBarAppearance.configure()` 在 **iOS 26/27 分支只设 `tintColor`**。若像 iOS 18 时代那样设置 `UITabBarAppearance.backgroundEffect = UIBlurEffect(...)` 或 `backgroundColor`，会用一层平涂模糊**覆盖掉系统折射玻璃** —— 这正是「玻璃质感不对」最常见的原因。低版本（17–25）才配 `UIBlurEffect` 做等效毛玻璃。

### 与原片的关系

原片 tab bar 是悬浮胶囊，4 个图标等宽并排。iOS 26/27 的系统 `TabView` 本身就是悬浮 Liquid Glass 胶囊、tab 条目等宽、选中项高亮 —— 形态与原片一致，所以 4 个都用普通 `Tab`，不加 `role`。浏览器原型的 tab bar / 玻璃按钮是这套系统材质的 CSS 等价呈现 —— 浏览器无法实例化 UIKit 控件，真机由系统渲染。

完整的 API 版本表、签名与三个常见错误，见 [`官方接入.md`](官方接入.md)。

---

## 二、动效曲线（本轮重做）

之前的问题是**每个属性各跑一条不同的曲线**：blur 用 `easeInOutCubic`、zoom 用手写 spring、opacity 用线性、flip 用离散查表，导致「毫无曲线、节奏散架」。现在：

**一个阶段 = 一条主 spring，所有属性共享进度 p，只按 delay 错峰。**

二阶阻尼阶跃响应，与 SwiftUI `.spring(response:dampingFraction:)` 同物理模型：

```
x(t) = 1 - e^(-ζω₀t) · [cos(ωd t) + (ζω₀/ωd) · sin(ωd t)]
ω₀ = 2π / response，ωd = ω₀√(1-ζ²)
```

| 阶段 | 帧 | response | damping | 过冲 | 错峰顺序 |
|---|---|---|---|---|---|
| 打开 | f009–016 | — | — | 加速曲线 `t^1.35` | 背景模糊 → 封面缩放/位移 → 详情背景 → 文字分层淡入 |
| 抽出 | f044–051 | 0.18 | 0.62 | 8.7% | 唱片位移/封套缩放 → 圆孔半月渐变 |
| 旋转 | f052–091 | — | — | 角速度曲线 | 0 → smoothstep 缓入 → 45°/s 匀速 → smoothstep 缓出 → 0，累计 69° |
| 收回 | f092–096 | 0.14 | 0.90 | ~0% | 反向 spring，干脆无过冲 |
| 翻转 | f116–119 | — | — | 单峰往返 | `sin(π·t^1.3)`，峰值 86° 落在 f118 |
| 关闭 | f166–175 | 0.22 | 0.72 | 4.0% | 详情淡出 → 首页浮现 → 缩回 → 模糊消散 |

关键性质：
- **端点精确**：spring 归一化到阶段窗口，t=0→0、t=1→1，与静止段**无缝衔接**（f16→f17、f96→f97、f175→f176 全部零跳变）。
- **速度连续**：唱片角速度由 smoothstep 缓入/缓出并逐帧积分，f96 后完全停住，不再「突然开始 / 突然静止」。
- **曲线可见**：原型左侧「动效曲线 · 实时」面板画出当前阶段的绿色曲线、灰色线性参考与播放头圆点，参数表高亮当前行；静止段预览下一条曲线。
- **打开曲线按原片实测拟合**：把原片 f009–f016 的封面宽度逐帧量出来（72 → 104 → 129 → 156 → 191 → 229 → 266 → 306pt），得到的是「缓慢加速 → 近似线性」，不是前快后慢的过冲 spring。用 `t^1.35` 拟合后逐帧误差 < 0.03；之前用 `spring(0.20 / 0.68)` 会在第 3 帧就冲到 86%，看起来像「一闪就到」。
- **双端参数对齐**：浏览器端打开段用 `t^1.35`，SwiftUI 端用 `.easeIn(duration: 8/30)`（同为加速曲线）；其余四段两端都用同参数的 spring。

其它动效细节：位移/自转/镜面高光解耦（沟槽随盘转、环境反光方向固定）、抽出投影随位移加深、详情内容分层淡入、波形播放头 + 振幅呼吸、翻转向侧面亮度衰减、放大封面圆角收窄、玻璃按钮按压缩放反馈。

---

## 三、素材来源

- **28 张网格封面**：iTunes Search API 取真实专辑 600×600 高清封面（Daft Punk、Aphex Twin、Boards of Canada、Burial、Four Tet、Bonobo、Tycho、Kraftwerk、Brian Eno、Massive Attack、Portishead、Floating Points、Jon Hopkins、Caribou、Bicep、Amon Tobin、Nils Frahm、Ólafur Arnalds、M83、Röyksopp、Air 等，按艺人去重）。
- **`cover_13.png`**：仍由原片封套裁切生成 —— 它是 zoom 转场起点，必须与详情页封套像素一致，否则放大瞬间跳变。
- **封套 / 挖孔封套 / 星球标签 / 图标**：从原视频原分辨率帧（1600×1200）逐块裁切。
- **原片参考帧**：`preview/assets/ref/`（22 张关键帧 + 19 帧总览图）。

`Vinyl/Vinyl/Resources/` 内为同一套素材副本，已全部加入 Xcode 工程的 Resources build phase。
