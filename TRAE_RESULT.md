# Vinyl 首页网格滚动性能

工作树：`/Users/bytedance/Documents/项目/App/vinyl-player-perf`

分支：`trae/perf`，基线：`fix/native-buttons-playerbar` 的 `2c19982`（Build 154）。

测量日期：2026-11-09。所有源码改动均在此工作树中。

## 结果与测量条件

固定负载下，滚动回调频率由 **33.88 次/秒提高到 59.01 次/秒**；18 秒滚动的主线程 CPU 累计时间由 **12.97 秒降到 3.23 秒，减少 75.12%**。首页和详情叠层不再因滚动坐标或播放时钟更新而执行整页 `body`。

| 指标 | 优化前 | 优化后 |
| --- | ---: | ---: |
| CADisplayLink 回调频率 | 33.88/s | 59.01/s |
| 回调间隔 P95 | 45.45ms | 17.65ms |
| 超过 1.5 个刷新预算的回调比例 | 60.39% | 0.85% |
| 估算丢失刷新比例 | 42.74% | 1.67% |
| 主线程 CPU 累计时间（Mach） | 12,972.11ms | 3,227.72ms |
| 主线程 CPU / 测量墙钟时间 | 71.94% | 17.92% |
| Time Profiler 主线程运行样本权重 | 13,016ms | 3,259ms |
| `LibraryView.home` body 更新 | 682 | 0 |
| `LibraryView.overlay` body 更新 | 682 | 0 |
| `AlbumDetailView` body 更新 | 682 | 72 |

两版都使用 Release、相同 iPhone 16 Pro 模拟器、iOS 26.5、Xcode 27.2，录制配置为 Time Profiler + SwiftUI + Points of Interest。数据集为 240 个真正通过 MusicKit `Album` 解码的固定测试对象，以仓库原有 28 张封面循环生成独立 URL；本地图片服务代替 CDN。每轮清空该专用模拟器的封面磁盘缓存，并将图片编码预热在测量区间之外。

补充长方形封面采样保护后，对最终二进制另作有效复测（Time Profiler + Points of Interest）：**57.96 次/秒、P95 17.74ms、主线程 CPU 3,180.23ms / 18.07 秒**，首页和详情叠层 body 仍均为 0 次。原始数据为 `after-complete/`；上表保留相同录制设置的正式成对结果。一次中间复测的回调与 CPU 数据已保存，但 trace 存档超时，该次不作为有效 Time Profiler 证据。

滚动由同一段 CADisplayLink 驱动，以 1,200pt/s 在顶部和底部间往返，时长约 18 秒、回调预算固定 60Hz，内容高度两版均为 5,672pt。同时按原播放轮询频率模拟 4Hz 时钟发布。`GridScroll` signpost 精确界定 Time Profiler 分析区间。

回调频率和丢失刷新估算是**主线程调度代理指标**，不是合成器呈现 FPS 或 Instruments 的真实 hitch ratio。主线程累计 CPU 使用 `thread_info(THREAD_BASIC_INFO)` 的 user + system 时间差；Time Profiler 的样本权重单独列出，用于交叉验证，不冒充精确 CPU 时长。本结果验证此固定模拟器负载，不外推真机 120Hz 或真实音乐服务网络表现。

## 实际热点

Time Profiler 原始调用栈及原生 `sample` 交叉检查确认，主要成本在视图图反复更新：

- `GraphHost.flushTransactions()`：热点定位录制中占主线程运行样本 85.85%，包含子调用。
- `AG::Graph::UpdateStack::update()`：84.39%，与上一项重叠，不能相加。
- 下层重复执行 `ForEachChild.updateValue()`、`LibraryView.gridScroll`、`LibraryView.musicCell(_:_:)`、上下文菜单构建和 MusicKit 对象复制。

定位录制额外启用了原生采样，只用于调用栈定位；其帧率不混入上表。正式前后对比使用没有额外原生采样的两轮录制。正式两轮 Time Profiler 的运行样本权重与 Mach CPU 时间分别相差约 0.34% 和 0.97%。

源码原因：

1. 每个格子的全局坐标在滚动中改变，汇总后的 `cellFrames` 写进共享 `@Published` 转场模型，使首页和隐藏的详情叠层一起失效。
2. `AppleMusicStore` 是 `ObservableObject`，并非 `@Observable`。播放位置和演示时钟与资料库数据混在同一个发布对象中；`syncPlayback()` 还每 250ms 重写未变化的标题、封面和播放状态。
3. 图片原来已在 `Task.detached` 后台解码，但网格使用 320pt 的详情渲染尺寸；3× 屏请求 960px，而实际格子只需约 230px。

## 已实施的改动

- **后台按显示尺寸解码**：网格按实际格子宽度和 `displayScale` 请求像素尺寸；ImageIO 在独立串行解码队列生成立即解码的缩略图。缓存按 URL + 显示像素尺寸区分变体，磁盘保留原压缩数据。长方形封面按短边保证显示像素，不因缩略图的长边限制而额外模糊另一轴。
- **保持放大时图片连续**：同源尺寸变体可同步提供预览；飞行封面、封套和上下文预览先显示已缓存的同一封面，后台加载其大尺寸变体。官方封面首次出现的 0.25 秒淡入保留，尺寸升级不重新淡入。
- **滚动窗口预取**：按当前行预取前两行、当前行及后四行，四个请求一批；换行取消尚未开始的批次，共享给可见格子的请求继续完成。启动缓存预取也改为匹配网格显示尺寸。
- **隔离几何查表**：`LibraryGridGeometry` 保存格子坐标，不发布整页更新。关闭飞行期间，选中格子的实时 `origin` 仍按原逻辑发布，保留收起落点跟随。
- **拆出播放时钟**：`PlaybackTimeline` 单独发布位置和演示时钟，只由波形、歌词等使用时钟的视图订阅；音乐元数据只在值变化时发布。歌曲、队列、歌词时间锚点和 seek 行为保持原语义。

阴影已检查，本轮**没有替换为 shadowPath 或预渲染**：保留原圆角与 `.shadow(.black.opacity(0.18), radius: 8, x: 0, y: 4)`，避免改变透明边缘和转场外观。实际定位的主要成本是视图图更新；本次没有获得 Render Server/GPU 阴影瓶颈数据，因此不宣称消除了 GPU 阴影成本。

波形已检查：原 `WaveformBar.barsCanvas` 和唱片沟槽已经使用 Canvas，无需重复改造。`PlayerBars.swift`、`Waveform.swift` 保持逐字节一致。

## 验证与视觉约束

- Release 和 Debug 的 `xcodebuild` 均通过，scheme `Vinyl`，iOS Simulator。
- Debug **8/8 回归检查通过**，覆盖方形缩图、长方形短边像素、大图尺寸变体、同源预览、并发内存命中、时钟发布隔离和坐标发布隔离；运行中开启后台解码线程断言。
- 前后各执行一次原有完整 `--record-demo`：放大、抽出、收回、翻面、关闭均收到 `complete`；各保存约 8 秒、1206×2622 的原生录像。
- `DesignTokens.swift`、`Model.swift`、`SleeveArtwork.swift`、`PlayerBars.swift`、`Waveform.swift` 与基线逐字节一致。`CoverFlight`、波纹及网格动画绘制代码段亦逐字节一致。
- 动画落定后的主体区域（排除状态栏和底部动态播放条），平均 RGB 通道差约 0.000004/255。静态 HTTP 封面网格因 JPEG 尺寸变体及缩图采样，平均 RGB 通道差约 1.47/255；封面内容、位置、尺寸、间距、圆角、投影参数与动画曲线一致，不声称纹理采样逐像素相同。

## 工具限制与权限

macOS 开发者工具调试权限原为 disabled；获得用户明确授权后使用 `DevToolsSecurity -enable` 开启，状态已验证为 enabled。

此模拟器不支持 Animation Hitches。默认 SwiftUI 模板因包含该仪器而不能录制，改用 Time Profiler 添加 SwiftUI 和 Points of Interest 后成功保存 trace。当前工具组合仍提示 `Trace file had no SwiftUI data`，所以官方 SwiftUI 归因表没有可用数据；上面的 body 次数来自应用内计数，不冒充 SwiftUI 仪器输出。

`xctrace symbolicate` 在两轮 trace 上以 139 退出。原始 trace 仍可导出；使用 `atos -p` 解析同一存活进程的原始地址，并以原生 `sample` 交叉检查，得到具名热点。未编造缺失的 SwiftUI 或 GPU hitch 数据。

## 证据与复现

原始数据保留在本工作树的 `build/profiles/`，大体积 trace、录像、二进制及 dSYM 均不进入提交：

- `before-final/`、`after-final/`：`scroll.trace`、`frames.json`、CPU 样本 XML、滚动区间 XML、`cpu-summary.json`、前后截图。
- `after-complete/`：最终二进制的有效 Time Profiler 复测及回调、CPU 数据。
- `hotspot-before/`：Time Profiler 定位 trace、原生调用栈和具名热点汇总。
- `perf-verification.json`：缓存与状态隔离回归结果。
- `demo-before/`、`demo-after/`：`demo.mov`、`home-final.png`、完成标记。

应用路径：基线为 `build/BaselineDerived/Build/Products/Release-iphonesimulator/Vinyl.app`；优化版为 `build/Before/Build/Products/Release-iphonesimulator/Vinyl.app`。两者使用相同计时探针，基线只加入测试数据、计数和录制开关，不包含性能优化。

在空输出目录可用 `python3 scripts/prepare_profile_baseline.py` 导出 `2c19982`，基线编译时设置 `SWIFT_ACTIVE_COMPILATION_CONDITIONS=PERF_BASELINE`。现有快照位于 `build/ProfileBaseline/`。

```sh
python3 scripts/profile_cover_server.py
```

另一个终端，替换设备 ID 和每轮不同的输出名称：

```sh
python3 scripts/profile_grid.py --device <SIMULATOR_UDID> \
  --app build/BaselineDerived/Build/Products/Release-iphonesimulator/Vinyl.app --label before-new
python3 scripts/profile_grid.py --device <SIMULATOR_UDID> \
  --app build/Before/Build/Products/Release-iphonesimulator/Vinyl.app --label after-new
```

`--cpu-only --sample-stacks` 可补录具名调用栈；`summarize_grid_trace.py` 按导出的 signpost 区间汇总 CPU 权重，`--pid` 需与尚存活的被测进程一致。`verify_perf_demo.py` 回放并录制原有动画。缓存回归使用 Debug 应用的 `--profile-grid --verify-perf`，结果写入专用模拟器的 `Documents/profile-verification.json`。

所有测试数据和诊断 UI 只在明确的模拟器参数下启用；正常启动和真机不进入测试场景。本分支仅本地提交，不执行 push。
