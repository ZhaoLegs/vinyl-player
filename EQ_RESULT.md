# 歌曲行均衡器方头修改结果

## 交付范围

- Worktree：`/Users/bytedance/Documents/项目/App/vinyl-player-eqbars`
- 分支：`ai/eq-square-caps`
- 基准：`fix/native-buttons-playerbar` 的最新本地提交 `5f4892f`（Build 170）。
- 代码提交：`f22ebee628dc746efbac8ab50322efdac14fc275`。
- 仅在上述 worktree 修改并本地提交，没有 push。

## 修改文件、行号和形状

唯一源码修改：`Vinyl/Vinyl/Views/AlbumDetailView.swift:1112`，`EqualizerGlyph.body` 中每根竖条的形状。

```swift
// 修改前
RoundedRectangle(cornerRadius: height * 0.09)

// 修改后
Rectangle()
```

调用位置：同文件第 766 行，当前歌曲的 `TrackRowLabel`。

只替换形状构造器，其余代码逐字保留：

- 三根竖条，宽度 `height * 0.2`，间距 `height * 0.16`，底部对齐。
- 调用高度 `TL.glyph * 0.85`，颜色仍为原来的 `ink` / `.fill(color)`。
- 动态高度公式、幅度及 `speed = [5.1, 6.7, 4.3]`、`phase = [0.0, 1.7, 3.1]` 不变。
- `TimelineView(.animation(minimumInterval: 1 / 30, paused: !playing))` 不变。
- 暂停高度比例 `[0.35, 0.55, 0.30]` 不变；暂停与播放共用同一个 `Rectangle()`。
- 未修改其他界面、功能、布局、版本号或动画参数。

## 首页和迷你播放条

全项目查找确认：`EqualizerGlyph` 仅在详情页歌曲行调用，首页和迷你播放条没有使用这个跳动均衡器，也没有另一套同用途的三柱均衡器。

`Components/PlayerBars.swift:365` 的 `Capsule(style: .circular).path(in: rect)` 属于另一套 `WaveformBar` 波形进度条，用于显示播放进度、播放头及拖动定位，不是歌曲前面的跳动均衡器。按“不要改别的界面”的要求保留其圆头，也保留播放按钮、玻璃容器等其他 Capsule。

## 编译和真机验收

2026-11-10，在指定设备上完成验收：

- iPhone 16 Pro，UDID：`00008140-0018346C1108801C`，有线连接、已配对、开发者模式开启。
- 设备实际系统版本：iOS 27.2。
- Scheme：`Vinyl`，配置：`Release`，`DEVELOPMENT_TEAM=X5LU97BQ66`。
- `xcodebuild` 结果：`BUILD SUCCEEDED`，安装成功。
- 正常启动 `com.zhaolegs.Vinyl`，没有传入任何应用启动参数，未使用 `--record-demo`。启动记录见 `build/eq-square-caps/evidence/launch.json`。
- 在真实 Apple Music 播放状态下打开详情页，核对周杰伦《那天下雨了》和蔡健雅《Bluebirds (Live)》的当前歌曲图标。后者完成连续播放、暂停、恢复播放验证。

构建命令：

```sh
xcodebuild -project Vinyl/Vinyl.xcodeproj \
  -scheme Vinyl -configuration Release \
  -destination 'id=00008140-0018346C1108801C' \
  -derivedDataPath build/eq-square-caps/DerivedData \
  DEVELOPMENT_TEAM=X5LU97BQ66 -allowProvisioningUpdates build
```

### 放大确认与动画验证

原始截图来自 `xcrun devicectl device capture screenshot`，分辨率均为 `1206 × 2622`，不是模拟器或网页预览。

从《Bluebirds (Live)》歌曲行截取原始像素，用最近邻方式放大 12 倍。三根竖条上下边缘均为平直横边，两侧为垂直边，四角为直角；播放和暂停均无圆头。

连续截图中，竖条深色像素的高度如下，单位为原始截图像素：

| 状态 / 截图 | 左柱 | 中柱 | 右柱 |
| --- | ---: | ---: | ---: |
| 播放 01 | 26 | 14 | 22 |
| 播放 02 | 28 | 12 | 33 |
| 播放 03 | 32 | 27 | 28 |
| 暂停 01 | 12 | 19 | 10 |
| 暂停 02 | 12 | 19 | 10 |

三张播放截图的高度组合不同，确认三柱正常跳动。两张暂停截图的均衡器区域逐像素一致，确认静止；其比例符合原有暂停高度。验收后已恢复播放。

系统拒绝 CLI 录屏，错误为 `The capability “Screen Recording” is not supported by this device`。因此使用连续原始截图验证高度变化，没有把静态图冒充录屏；动画节奏和幅度保持不变的依据是唯一源码差异只有形状这一行。

## 截图和证据路径

以下路径均相对于本 worktree 根目录，证据保存在已忽略的 `build/` 中，不提交图片或构建产物。

- 完整播放截图：
  - `build/eq-square-caps/evidence/bluebirds-playing-01.png`
  - `build/eq-square-caps/evidence/bluebirds-playing-02.png`
  - `build/eq-square-caps/evidence/bluebirds-playing-03.png`
- 完整暂停截图：
  - `build/eq-square-caps/evidence/bluebirds-paused-01.png`
  - `build/eq-square-caps/evidence/bluebirds-paused-02.png`
- 播放方头 12 倍放大图：`build/eq-square-caps/evidence/bluebirds-playing-01-glyph-12x.png`
- 暂停方头 12 倍放大图：`build/eq-square-caps/evidence/bluebirds-paused-01-glyph-12x.png`
- 歌曲行裁剪图：`build/eq-square-caps/evidence/bluebirds-playing-01-row.png`、`build/eq-square-caps/evidence/bluebirds-paused-01-row.png`
- 周杰伦歌曲的补充截图：`build/eq-square-caps/evidence/playing.png`、`build/eq-square-caps/evidence/playing-glyph-12x.png`。完整截图中菜单已展开，但歌曲行和均衡器未被遮挡；主验收采用上述无遮挡的 Bluebirds 截图。
- 编译日志：`build/eq-square-caps/evidence/build.log`

本报告另作本地文档提交；上面的完整 hash 指向只包含单行形状修改、且已经真机编译验收的代码提交。
