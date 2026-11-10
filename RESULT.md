# 曲目表顶部渐变模糊与菜单精简

实现、Release 编译和 160 首固定列表的模拟器前后测量已完成。**真机已安装并正常启动最终版本，但随后断开；真机列表/歌词截图对比、真实 100 首以上歌单的滚动性能验收尚未完成。**

## 范围与提交

- worktree：`/Users/bytedance/Documents/项目/App/vinyl-player-listfade`
- 分支：`ai/tracklist-top-blur`
- 基准：`fix/native-buttons-playerbar`，Build 170，`5f4892f`
- 菜单独立提交：`ea3ec8c`，精简首页和详情菜单，移除资料库添加与不可见队列操作。
- 渐变独立提交：`9e75f8cb317dabda5602d4899fab2f71280bcb62`，复用歌词顶部渐变模糊，让曲目表在封面下沿平滑淡出。
- 本报告随后单独提交；不 push，未修改主目录，未调整版本号或编译号。

## 原因与实现

原 `realTrackTable` 的表头在 ScrollView 外，歌曲行的滚动视口从表头下方开始。文字经过这条裁切边界时直接消失。歌词已有 `sleeveBottomY` / `lyricsTopY` 的运行时测量，通过 `lyricsGap` 上延视口并补偿内容顶部留白。

现在歌曲列表使用同一个 `lyricsGap`：

1. ScrollView 外层 `.padding(.top, -lyricsGap)`，把视口顶边上延到实测封面下沿。
2. 内容 `.padding(.top, lyricsGap)`，抵消扩展，保持首屏表头和首行的位置。
3. 表头移入滚动内容，随歌曲一起滚动、淡出，避免歌名上滑时与固定表头重叠；表头的字体、列宽、间距代码不变。它现在也位于渐变带内，所以初始对比度会受顶部遮罩影响。
4. 歌曲行仍在 LazyVStack 中，仍使用歌曲 ID、原有预处理模型和 Equatable 行标签。
5. 空列表和 loading 状态保留原表头和占位布局。

共用组件位于 `Vinyl/Vinyl/Views/AlbumDetailView.swift`：

- `TopProgressiveBlurMask`：直接抽取原歌词的 VStack + `spanAlphaStops` 遮罩。歌曲 ScrollView、普通歌词 ScrollView、同步歌词视口三处使用同一个 modifier。
- `TopProgressiveBlurMaterial`：直接抽取原 `lyricsTopFade` 的单层 `.ultraThinMaterial`、渐变材质遮罩和 0.3 透明度。`lyricsTopFade` 仅改为调用此组件，歌词侧的原有调用位置不变；列表侧将它叠在扩展后的视口顶部。
- `realTrackTable` / `trackTableHeader`：视口扩展、等高补偿留白、滚动表头。
- `LyricsPanel.body` / `LyricsPanel.synced`：仅将原内联透明度遮罩替换为共用 modifier，原留白、滚动跟随、逐字填色、逐行模糊和动画不变。
- `.gitignore`：忽略本轮本地截图和测量产物，避免把二进制证据加入代码提交。

`LibraryView.detailLayer` 中，专辑、歌单以及迷你播放条打开的真实集合都使用同一个 AlbumDetailView / realTrackTable，因此代码路径均接入此效果；这些入口的真机逐项验收仍待补。

## 渐变数值

数值直接引用原 `LyricsTopFade`，没有复制另一套曲线，也没有新加固定高斯半径：

- 渐变带高度：`lyricsGap + 38pt`。正常约 `60 + 38 = 98pt`，实际以运行时的封面和列表边界测量为准。
- 内容透明度：13 个采样点。令 `t` 为从顶部到底部的归一化距离，alpha = `t² × (3 − 2t)`；顶部 0，底部 1。
- 材质遮罩：同样 13 个采样点；`up = min(1, t / 0.25)`，`down = min(1, (1 − t) / 0.75)`，强度 = `smoothstep(up) × smoothstep(down)`。
- 遮罩顶部和底部均为 0，在带高 25% 处达到 1；98pt 时对应 24.5pt。
- 材质：`.ultraThinMaterial`，整体 opacity = **0.3**，不叠白色底色，`allowsHitTesting(false)`。
- 系统材质的实际模糊半径由系统实现决定，源码没有可报告的固定半径；与歌词使用同一实现。
- 顶部只增加一条材质层和一个视口透明度遮罩，没有给歌曲行添加 `.blur`，没有按滚动偏移修改顶部模糊参数。
- 原底部渐变、最后一行距离时间条 24pt 的计算、歌曲行样式、均衡器、详情淡入和顶部按钮布局均不变。

## 新增的菜单要求

用户在执行中要求精简菜单，单独提交在 `ea3ec8c`：

- `AlbumDetailView.songMenu`、`detailMenu`、`LibraryView.collectionMenu`：移除添加到播放列表、加到队列末尾、下一首播放，以及集合菜单中的普通“播放”。
- `MenuTopBar`：移除资料库“添加”及其参数；保持固定两个普通 Button：喜欢/取消喜欢、共享。仍使用原系统分享面板，URL 不可用时共享置灰。
- 集合菜单保留随机播放、前往艺人；歌曲菜单保留原有前往专辑/艺人；首页原有“从首页隐藏”保留。
- 没有删除 AppleMusicStore 的底层 API 或修改播放规则。
- 源码检查确认三个入口均已移除指定条目。最终真机菜单横排显示和实际点击操作未完成验收。

## 前后滚动性能

最终有效测量使用专用 **VinylListfade-26**，iPhone 16 Pro 模拟器，iOS 26.5（23F77），UDID `C98EAC8C-1C56-4729-B562-9CF9B2DDE0F5`。

使用现有 TracklistScrollProbe、Release、固定合成 MusicKit 歌单 **Tracklist performance fixture — 160 songs**，60Hz / 1200pt/s 上下往返约 10 秒。它不是用户的真实 Apple Music 歌单，也不包含真人拖拽成本。基线来自菜单精简后、渐变改动前的 `ea3ec8c`；菜单不打开，不影响比较。两次测量均等待编译结束，且没有其他模拟器启动。

| 指标 | 改前 | 改后 |
| --- | ---: | ---: |
| 测量时长 | 10.016608s | 10.015154s |
| 官方 render hitch 次数/时长 | 未取得 | 未取得 |
| AlbumDetailView.body | 0 | 0 |
| TrackTable.builder | 0 | 0 |
| TrackRow.builder | 596（59.50/s） | 588（58.71/s） |
| TrackRowLabel.body | 298 | 294 |
| DetailWaveform.body | 40 | 40 |
| DetailBottomFade.body | 15 | 15 |
| EqualizerGlyph.body | 1 | 1 |
| 主线程 CPU 时间 | 1491.181ms | 1755.898ms |
| CADisplayLink 回调 | 600 | 601 |
| 回调预算 | 16.666667ms | 16.666667ms |
| 超过 1.5 倍预算的回调 | 1 | 0 |
| 迟到回调超额时间 | 17.036417ms | 0ms |
| 回调间隔 P95 | 17.089375ms | 16.946750ms |
| 最大回调间隔 | 33.703084ms | 17.378708ms |

0 次表示计数器在稳定滚动区间没有记录到该项，首次布局不包括在内。行构建不等于所有 SwiftUI body 求值；均衡器的内部 TimelineView 动画帧也不包含在组件 body 计数中。

新增材质层后，本次 CPU 时间增加 **264.717ms，约 17.75%**。回调保持稳定且没有新增整页重算，但单次模拟器结果不证明真机掉帧改善，也不能据此声称没有 GPU 渲染成本。迟到回调只是调度代理，不能冒充官方 render hitch。

曾尝试 Time Profiler + Points of Interest；期间本机可用空间降到约 127MiB，终端执行存储报错，随后本轮 build/listfade 目录被外部删除、原模拟器被关闭。该次录制不完整，没有可用 trace，未纳入比较。恢复后创建了上述独立模拟器，用现有探针完成有效前后测量。

## 验证与截图

- 模拟器和指定真机 Release `xcodebuild`：均 **BUILD SUCCEEDED**，scheme Vinyl，真机 `DEVELOPMENT_TEAM=X5LU97BQ66`。
- 真机：iPhone 16 Pro `00008140-0018346C1108801C`，实际系统 iOS 27.2。最终版本已签名安装，并通过无参数的正常启动运行；没有用 `--record-demo`。
- 既有 11 项运行时检查前后都通过，包括播放时钟不广播整页、稳定歌曲 ID、原底部渐变公式、24pt 底部间距计算。
- 源码比较确认 LyricsTopFade、歌曲行代码、歌词滚动动画区段未变。
- 首行标题截图墨迹包围盒前后完全相同，位移 **0px**。阈值为 RGB 最低通道 < 90 的墨迹比较中，4902→4904 像素，仅 2 个阈值像素变化；不能宣称整张截图逐像素一致。唱片和均衡器本来就有动画。
- 模拟器滚动终点截图可见曲目在封面下方连续淡出，没有原列表顶部的明显裁切线；这不是最终真机验收截图。

所有以下路径相对 worktree 根目录：

- `recordings/listfade/before-probe/start.png`、`end.png`：160 首合成歌单改前。
- `recordings/listfade/after-probe/start.png`、`end.png`：同歌单改后，end.png 展示顶部淡出。
- `recordings/listfade/first-row-comparison.png`：首行标题局部前后并排。
- `recordings/listfade/before-probe/frames.json`、`after-probe/frames.json`：性能原始数据。
- 两个 probe 目录内的 `verification.json`：既有运行时检查。
- `recordings/listfade/source-and-layout-checks.json`、`menu-source-checks.json`：源码及首行布局检查。
- `recordings/listfade/before-playlist-initial.png`：基准真机正常打开 **A-List Mandopop: Best of 2026** 的首屏；未读取该真实歌单的总曲目数，不能把它算作已确认的 100 首验收。
- `.build/listfade/after-sim-build.log`、`after-device-build.log`：最终编译日志；`.build/listfade/measure_probe.py` 为本轮轻量采集脚本。

## 尚未完成的验收

- 真机在采集中出现未由本轮操作触发的切歌、切专辑和切歌词，随后设备断开；最终查询为 unavailable。
- 尚缺真实 100 首以上歌单的真机滚动性能数据，以及封面下沿列表淡出/模糊与歌词的同设备截图对比。
- 尚缺专辑、歌单、迷你播放条三个入口的逐项真机验证。
- 尚缺最终菜单的真机横排显示、喜欢、共享、随机播放和前往艺人的操作验收。
- 尚未测试横屏、动态字体和辅助功能特殊设置；不宣称这些场景已通过。

设备重新连接并空闲后，可继续在本 worktree 安装最终版本正常启动，补齐上述截图和测量，再更新本报告。
