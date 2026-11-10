# 详情页长歌曲列表滚动优化

代码优化、模拟器前后测量和 Release 编译已完成。最终同环境复测中，滚动期间详情页根 body 重算从 54 次降到 0 次，歌曲行构建减少 73.4%，主线程 CPU 时间减少 16.3%。**本轮未取得官方 render hitch 数据，不能据此宣称掉帧已消除。**

## 范围和测量条件

- 工作目录：`/Users/bytedance/Documents/项目/App/vinyl-player-perf2`。
- 分支：`ai/tracklist-perf`，基线：`b3f4ed5`，来自 `fix/native-buttons-playerbar`。
- 主目录未修改；不 push，不调整版本号或编译号。
- 设备：专用 `VinylPerf-26`，iPhone 16 Pro 模拟器，iOS 26.5（23F77），UDID `CA9452DF-8ADA-4C5F-82EA-B629E6B318F7`。
- 工具：Xcode / Instruments 27.2（27B52）；Release、arm64、同一台 Mac。
- 歌单：`Tracklist performance fixture — 160 songs`，160 首。它是经 MusicKit JSONDecoder 解码的固定**合成测试歌单**，包含中英文标题、不同歌曲 ID 和时长，不是用户实际 Apple Music 歌单。
- 播放第一首；以真实播放器相同的 250ms 周期提供队列元数据和播放位置。前后模拟元数据相同，优化后重复值不再发布。
- 歌曲行不包含封面；相似专辑为空、禁用测试数据的远程检索；封套使用现有包内资源。因此本轮没有量化相似专辑封面的加载收益。
- 打开并稳定后，以 CADisplayLink 驱动 UIScrollView，60Hz、1200pt/s，上下往返约 10 秒。程序滚动可重复，但不包含真人拖拽手势识别成本。
- Instruments 录制 18 秒，以 `TracklistScroll` signpost 筛选滚动区间。主表比较关闭辅助 iOS 27 模拟器后的两次相同 Time Profiler 模板复测，未混用 iOS 27 数据。
- 基线编译、录制和采样分析均先于生产优化；基线仅加入启动参数、合成数据及计数探针。

## Instruments 限制

用户已允许开启调试权限，`DevToolsSecurity -status` 为 enabled；真机 `Legs` 在采样时离线。

已实际尝试：

| 运行方式 | iOS 26.5 | iOS 27.0 |
| --- | --- | --- |
| SwiftUI 模板 | `Hitches is not supported on this platform`，录制失败 | 同样失败 |
| Time Profiler + 独立 SwiftUI 仪器 | 可录制，但 `Trace file had no SwiftUI data` | 同样无 SwiftUI 数据 |
| Time Profiler + Points of Interest | 成功，有符号化主线程栈和滚动 signpost | 仅辅助核验，不纳入主表 |

错误原文保存在 `perf-evidence/swiftui-*-*.log` 及 `swiftui-instrument-*.log`。Time Profiler 的附属表有 “1 table without a known input source” 警告；实际导出的主线程 time-profile 栈与 signpost 均有数据。

官方 hitch 次数、总时长、SwiftUI 仪器的 body 数据均标记为不可用。以下 body 数来自明确位置的应用内计数，回调延迟来自 CADisplayLink；两者都不是官方 render hitch 指标。

## 前后对比

最终同环境复测数据：`perf-evidence/before-controlled.json`、`after-controlled.json`。

| 指标 | 修改前 | 修改后 |
| --- | ---: | ---: |
| 滚动测量时长 | 10.016044s | 10.013896s |
| 官方 render hitch 次数 | 不可用 | 不可用 |
| 官方 render hitch 总时长 | 不可用 | 不可用 |
| 详情根 `AlbumDetailView.body` | 54 次，5.39 次/s | 0 次，0 次/s |
| 曲目表构建 `TrackTable.builder` | 54 次 | 0 次 |
| 歌曲行构建 `TrackRow.builder` | 2,232 次，222.84 次/s | 594 次，59.32 次/s |
| 整份序号字典重建 | 4,464 次 | 0 次 |
| `RelatedAlbumsSection.body` | 54 次 | 0 次 |
| 波形的父级构建 | 54 次 | 0 次 |
| 独立 `DetailWaveform.body` | 尚未拆出 | 40 次，3.99 次/s |
| 独立 `DetailBottomFade.body` | 尚未拆出 | 14 次，1.40 次/s |
| `TrackRowLabel.body` | 原为内联标签，无独立计数 | 297 次，29.66 次/s |
| `EqualizerGlyph.body` | 1 次 | 1 次 |
| 主线程 CPU 时间（Mach thread_info） | 2,029.800ms | 1,698.663ms |
| CADisplayLink 回调数量 | 600 | 601 |
| 回调超过 1.5 倍 16.67ms 预算的次数 | 1 | 0 |
| 上述迟到回调的超额时间 | 11.861ms | 0ms |
| 回调间隔 P95 | 17.809ms | 17.024ms |
| 最大回调间隔 | 28.528ms | 19.209ms |

“0 次”仅指完成打开和预处理后的滚动区间，首次展示、切歌、收藏和切换数据仍会正常更新页面。歌曲行构建是 View 工厂求值，不等于 SwiftUI body 总重算；视图拆分前后不能将各类计数简单求和作同比。均衡器内部 TimelineView 的动画帧不包含在 `EqualizerGlyph.body` 计数中。

基线探针的 `maxCallbackMS` 字段误输出秒，交付的 JSON 将该字段乘 1000，并保留原值和校正说明；其余实测值未改动。原始输出仍在 `/var/tmp/vinyl-tracklist-perf/before-controlled/frames.json`。

复测中迟到回调从 1 次降到 0 次，但这仅是调度代理指标，**没有证明官方 render hitch 次数或时长改善**。已证实列表的重复计算减少；整体 CPU 的单次约 16.3% 收益仍含模拟器调度噪声，不应外推为真机帧率提升比例。

最初一组记录也保留在 `before-time.json`、`after-time.json`：详情 body 55→0，行构建 2,261→596，CPU 1,794.807→1,668.354ms，迟到回调均为 0。由于后一次运行时辅助兼容性测试模拟器仍开启，未将这组作为最终同环境主表，也没有将两组数据混合平均。

## 热点与改动

Time Profiler 在 `TracklistScroll` 区间的主线程采样权重：

| 栈 | 修改前 | 修改后 |
| --- | ---: | ---: |
| `AlbumDetailView.sideIndex.getter` | 137ms | 删除，0 样本 |
| `AlbumDetailView.realRow` | 137ms | 62ms |
| `realTrackTable` 内行构建闭包 | 278ms | 62ms |
| `AlbumDetailView.songMenu` | 29ms | 12ms |
| 全部主线程样本权重 | 2,156ms | 1,630ms |

这些是统计采样权重，包含调用关系、会互相重叠，不能相加当作真实 CPU 时间。完整摘要保存在 `before-controlled-stacks.json`、`after-controlled-stacks.json`。最初用于决定优化方向的采样摘要另存为 `before-stacks.json`。

1. **每行重复构造全量序号字典。** 原代码每行调用两次 computed `sideIndex`，每次遍历全部歌曲。改为 `TrackRows.prepare`：仅在歌曲数据变化时建立 `TrackRowModel`，预计算序号、Side A/B、时长文本、标题文本和可播放标记。ForEach 继续使用歌曲 ID。
2. **播放时钟与页面共用广播。** `AppleMusicStore` 原先每 250ms 发布位置及相同元数据。把 position / demoElapsed 放入 `PlaybackTimeline`，仅波形和歌词面板观察时钟；队列标题、ID、时长、封面和播放状态只有变动才发布。歌曲匹配仍保留原来的 ID、曲库 ID、标题与艺人回退规则。
3. **行判断扫描整份歌单。** 移除每行 `albumIsPlaying` 的重复数组扫描，直接使用原有 `music.isCurrent(song)`。只有真实集合的歌曲表会调用它；该行匹配本身已保证当前歌在这份歌曲数据中。
4. **静态行标签重复构造。** `TrackRowLabel` 只接收预处理文本、颜色和播放标记，采用 Equatable。按钮与长按菜单留在外层，避免忽略闭包变化而保留旧播放队列或菜单动作。
5. **底部接近程度牵连整个页面。** ScrollGeometry 的 transform 先夹取到 0…1，远离底部时不回传重复状态。变化仅发布到 `DetailBottomFade`，保留原来 140pt 范围、连续渐变高度公式、材质、透明度和曲线，没有把渐变离散成阶梯。
6. **相似专辑封面偏大及同步磁盘读取。** 将 render 从 220pt 改为 104pt，现有 CachedArtwork 按 displayScale 请求像素尺寸（3× 时 312px），继续使用内存 / 磁盘缓存和后台解码。body 仅读内存，磁盘缓存和网络请求在后台任务中完成。圆角与阴影参数保持原值。
7. **均衡器原本已经隔离。** 保留原来的 30Hz TimelineView、暂停停止及三柱曲线，未重写动画。

修改文件：

- `Vinyl/Vinyl/Views/AlbumDetailView.swift`：行模型、Equatable 标签、独立波形与渐变、歌词时钟订阅。
- `Vinyl/Vinyl/AppleMusicStore.swift`：时钟分离、重复元数据抑制。
- `Vinyl/Vinyl/RelatedAlbums.swift`：104pt 封面及后台缓存读取。
- `Vinyl/Vinyl/VinylApp.swift`：时钟注入、仅模拟器显式参数启用的测试入口。
- `Vinyl/Vinyl/TracklistScrollProbe.swift`、工程 Sources、两个 scripts：可重复测量与检查工具。
- `Components/PlayerBars.swift` 无变更；已有 Canvas 波形继续使用。

## 验证

- `xcodebuild -project Vinyl/Vinyl.xcodeproj -scheme Vinyl -configuration Release -destination 'platform=iOS Simulator,id=CA9452DF-8ADA-4C5F-82EA-B629E6B318F7' CODE_SIGNING_ALLOWED=NO build`：**BUILD SUCCEEDED**。
- 同 scheme 的 `-destination 'generic/platform=iOS'` Release：**BUILD SUCCEEDED**，未进行安装、签名或发布。
- 11 项模拟器运行时检查全部通过：时钟不广播到页面、seek 上下限、当前歌曲身份、预处理文本、Side A/B、重复队列不重算、重排、清空、渐变重复值抑制、原渐变公式、24pt 底部间距计算。见 `runtime-verification.json`。
- 源码比较确认歌曲长按菜单、播放动作、TL 字号列宽、rowReveal、均衡器曲线与 PlayerBars 均保持一致。见 `source-verification.json`。
- 前后首屏截图检查：文字、间距、按钮、底部材质和列表布局一致。唱片与均衡器的截图相位不同属于正在播放的既有动画。
- 歌词仅改时钟订阅位置，没有改字号、颜色、翻转、自动滚动或逐字填色代码。
- 现有异步 NSLock 警告仍存在于旧缓存代码；没有切换工程的 Swift language mode。
- 未做真机实际播放、真实歌单长按操作或官方掉帧验收；仍需真机在线时补测。

## 重跑与原始证据

优化版：

```sh
xcodebuild -project Vinyl/Vinyl.xcodeproj -scheme Vinyl -configuration Release \
  -destination 'platform=iOS Simulator,id=CA9452DF-8ADA-4C5F-82EA-B629E6B318F7' \
  -derivedDataPath /var/tmp/vinyl-tracklist-perf/after-build CODE_SIGNING_ALLOWED=NO build
python3 scripts/profile_tracklist.py \
  --device CA9452DF-8ADA-4C5F-82EA-B629E6B318F7 \
  --app /var/tmp/vinyl-tracklist-perf/after-build/Build/Products/Release-iphonesimulator/Vinyl.app \
  --output /var/tmp/vinyl-tracklist-perf/replay-after --template 'Time Profiler'
python3 scripts/summarize_tracklist_trace.py /var/tmp/vinyl-tracklist-perf/replay-after
```

运行前启动专用模拟器；output 必须是尚不存在的目录。加 `--instrument SwiftUI` 可重试独立 SwiftUI 仪器，或将 template 改为 `SwiftUI`。普通启动及任何真机启动都不会启用合成数据或计数。

运行检查：用 `simctl launch` 传入 `--profile-tracklist --verify-tracklist`，结果在 app Documents 的 `profile-verification.json`。

重建基线：在另一个从 `b3f4ed5` 创建的临时 worktree 用 `git apply --unidiff-zero` 应用 `perf-evidence/baseline-probe.patch`，并将 `baseline-probe.swift.txt` 复制成 `Vinyl/Vinyl/TracklistScrollProbe.swift`；用同一 scheme / Release 编译，再使用当前目录的 `profile_tracklist.py` 测量。不要将优化后的 probe 文件用于基线，因为它还包含新模型的检查代码。

原始 trace、导出 XML、截图和编译日志在本机 `/var/tmp/vinyl-tracklist-perf/`：

- `before-controlled/scroll.trace`、`after-controlled/scroll.trace` 为最终复测；`before-time/scroll.trace`、`after-time/scroll.trace` 为最初一组。
- 两目录的 `start.png`、`end.png`、`time-profile.xml`、`os-signpost.xml`。
- `baseline-build.log`、`after-build.log`、`device-build.log`。

小体积 JSON、采样摘要、错误日志和基线重放输入保留在仓库 `perf-evidence/`。大型 trace / 编译产物不加入 Git。
