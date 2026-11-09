# 歌词加载修复结果

2026-11-09，分支 `ai/lyrics-fix`，基于 `fix/native-buttons-playerbar` 的 `8fca7b4`。
项目代码只在 `/Users/bytedance/Documents/项目/App/vinyl-player-lyrics2` 修改，主目录未动；测试和构建临时文件放在独立系统临时目录。

正常获取链路九首歌曲命中 **9/9（100%）**，达到 ≥85% 的目标。13 项单元测试全部通过；`xcodebuild` iOS Simulator Debug 编译通过。

## 原因与修复

| 原因 | 修复后的行为 |
| --- | --- |
| `LyricsStore.lyrics` 将网络失败的 `nil` 转成 `.none`，详情页因此显示“暂无歌词” | 获取失败向上抛出；详情页显示“歌词加载失败，点按重试”，点击重新加载 |
| HTTP 503 等异常和 JSON 解码失败被跳过，最后当作“没有歌词”缓存 | -1005、超时、断网及临时 HTTP 429/5xx 首次请求后最多重试三次；退避 0.5、1、2 秒，存在 Retry-After 时遵守更长的服务端等待；最终失败不写入内存或磁盘缓存 |
| 搜索直接选择第一条记录，未检查歌手，时长容差为 8 秒 | 核验清洗后的标题、主歌手相似度 ≥0.85、时长误差 ≤3 秒；已知目标时长时拒绝缺少时长的候选；优先精确歌手，再考虑同步歌词、专辑和时长 |
| 标题/歌手中的版本说明和简繁体差异降低命中率 | 去掉括号版本说明、- Single、Live、feat.、Remastered、Deluxe 等；歌手按 &、逗号、顿号、feat. 等取第一位；原文字、简体、繁体分别尝试 |
| 只有 LRCLIB 一个来源 | LRCLIB `/api/get` → `/api/search`，中文无结果再查网易云 HTTPS `/api/search/get` 和 `/api/song/lyric`；无 key、无需登录，不携带应用共享 Cookie，候选通过相同身份与时长检查 |
| 无时间轴的备用源文本可能被丢弃 | 非空纯文本返回 `.plain`，沿用居中显示；没有逐字填色和自动歌词滚动。纯音乐标记、仅元数据和空时间戳不计作命中 |
| 内存没有时间戳，磁盘“无歌词”保存 7 天 | 成功结果长期保存；确认无结果缓存 3 天，内存和磁盘共用过期规则；并发请求合并；使用 `lyrics-v3` 避免继承旧的错误否定缓存 |

数据逻辑在 [LyricsData.swift](Vinyl/Vinyl/LyricsData.swift)，详情页失败状态和同步首帧缓存在 [AlbumDetailView.swift](Vinyl/Vinyl/Views/AlbumDetailView.swift)。
搜索、解析及磁盘 I/O 在后台仓库完成，首帧同步缓存读取使用轻量键，避免在播放时钟驱动的视图更新中反复做简繁转换。

## 真实联网命中情况

测试直接调用应用使用的 `LyricsRepository`，每次使用全新的临时缓存目录，不依赖历史缓存。
《王妃》按原专辑版 221.760 秒测试；此前试验输入的 251 秒会匹配合唱版本，已核对元数据并更正，以下均为更正后的最终结果。
三首英文歌曲使用真实曲目加 `- Single` 的输入，验证后缀清洗。

| 歌曲 | 歌手 | 输入时长/秒 | 命中来源 | 记录 ID | 匹配时长/秒 | 误差/秒 | 歌词行数 |
| --- | --- | ---: | --- | --- | ---: | ---: | ---: |
| 夜曲 | 周杰伦 | 229.000 | LRCLIB/get | 16978 | 229.000 | 0.000 | 32 |
| 遇见 | 孙燕姿 | 209.760 | LRCLIB/get | 23409081 | 211.000 | 1.240 | 25 |
| 消愁 | 毛不易 | 261.346 | LRCLIB/get | 7922592 | 262.000 | 0.654 | 37 |
| 倔强 | 五月天 | 261.618 | LRCLIB/get | 7340138 | 262.000 | 0.382 | 27 |
| 王妃 | 萧敬腾 | 221.760 | LRCLIB/get | 24451377 | 221.000 | 0.760 | 29 |
| Attention | Charlie Puth | 208.800 | LRCLIB/get | 315834 | 209.000 | 0.200 | 43 |
| Shape of You - Single | Ed Sheeran | 233.000 | LRCLIB/get | 1250 | 234.000 | 1.000 | 90 |
| Flowers - Single | Miley Cyrus | 200.000 | LRCLIB/get | 1037368 | 200.000 | 0.000 | 46 |
| Blinding Lights - Single | The Weeknd | 200.000 | LRCLIB/get | 390 | 200.000 | 0.000 | 35 |

程序输出：`LIVE TOTAL 9/9 (100.0%) mode=normal`，退出码 0。最终九首均为同步歌词。

另外强制跳过 LRCLIB，单独检验网易云：

| 歌曲 | 结果 | 网易云记录 ID | 时长/秒 | 歌词行数 |
| --- | --- | --- | ---: | ---: |
| 夜曲 | 未找到符合身份/时长条件的歌词 | — | — | — |
| 遇见 | 命中 | 454828887 | 209.760 | 28 |
| 消愁 | 命中 | 569200213 | 261.346 | 57 |
| 倔强 | 命中 | 386175 | 261.618 | 69 |
| 王妃 | 命中原专辑版 | 167942 | 221.760 | 43 |

强制备用源输出 `LIVE TOTAL 4/5 (80.0%) mode=backup`。该诊断命令退出码 1，因为同样保留了 85% 断言；正常双来源链路的九首验收已通过。
备用源不能保证覆盖所有中文歌；《夜曲》目前由 LRCLIB 提供。100% 是本次指定样本、当前网络和服务数据下的结果，不代表整个曲库。

## 单元测试与缺陷复现

项目原来没有单元测试 target。本次增加最小 Swift Package 测试入口，只编译应用实际使用的 `LyricsData.swift`，无需第三方依赖。
固定 HTTP 响应、时钟和退避等待作为外部依赖注入；不替换被测获取、选择或缓存逻辑。
测试文件：[LyricsCoreTests.swift](Tests/LyricsCoreTests/LyricsCoreTests.swift)。

| 类别 | 覆盖 |
| --- | --- |
| 正常行为 | get 未命中后 search；纯文本歌词；网易云备用及公共 LRC 解析；并发请求合并；成功内存/磁盘缓存长期复用 |
| 边界 | 时长恰好 +3 秒接受、+3.01 秒拒绝；缺失候选时长拒绝；精确歌手优于近似歌手；三天前保留、到期重新查询；版本标签隔离缓存 |
| 异常 | -1005 首次加三次重试，等待 0.5/1/2 秒，恢复后重新请求成功；503 两轮加载共 8 次 HTTP 请求、不写缓存；损坏 JSON 不当作无歌词；部分来源失败不得写否定缓存 |
| 解析/显示数据 | 简繁变体和主歌手分割；Enhanced LRC 和重复行行为保持原实现；无时间轴备用文本；纯音乐与仅标签结果不计命中 |

修复前在基线真实 `LyricsStore` 上运行回归探针，只控制网络、时钟与缓存目录；以下五个断言稳定失败，退出码 1：

| 基线断言 | 原缺陷等级 | 当前回归验证 |
| --- | --- | --- |
| `network_failure_is_distinct_from_absence` | P1 | `testConnectionFailureRetriesThreeTimesAndTapRetryCanRecover` 通过 |
| `initial_request_plus_three_retries` | P1 | 同一用例验证恰好 4 次请求、3 次指数退避 |
| `http_503_does_not_enter_cache` | P1 | `testHTTP503RetriesAndDoesNotCache` 通过 |
| `reject_same_title_from_cover_singer` | P1 | `testSelectionUsesSingerSimilarityAndThreeSecondBoundary`、搜索与备用源用例通过 |
| `memory_miss_expires_after_three_days` | P2 | `testMissExpiresInMemoryAndOnDiskAfterThreeDays` 通过 |

执行轮次：基线 5 个预期失败 → 获取/缓存修复后 12 项通过 → 补充纯音乐/空标签检查后 13 项全部通过（0 failures，退出码 0）。
没有历史测试失败、未解释的单元测试失败，未放宽失败断言。

## 视觉约束与构建

与基线逐段比较，以下内容保持不变：

- 详情页封面、翻转及歌词区原有布局。
- 歌词字号 16pt、字体、颜色、行距与纯文本居中布局。
- `currentIndex` 之后的歌词滚动、逐字填色、缩放、模糊和动画实现。
- `Lyrics.bottomGap = 24`、末行滚动规则；原有加载成功的 0.2 秒渐显。
- Enhanced LRC 的既有解析与逐字时间行为。本次只移动解析代码，不修改估算或动画。

`xcodebuild` 最终输出 `BUILD SUCCEEDED`，退出码 0，使用独立 DerivedData、禁止签名的通用 iOS Simulator Debug 构建。
现有 `AppleMusicViews.swift` 和 `RelatedAlbums.swift` 中的异步锁 Swift 6 提示仍存在；这两个文件不在本次修改范围。
未运行真机断网 UI 测试；错误恢复由真实仓库单元测试验证，点击重试绑定、任务取消保护和原有 UI 范围由源码比较及 iOS 编译验证。

## 复跑命令

在本 worktree 中执行：

```sh
swift test
swift run LyricsLiveChecks
swift run LyricsLiveChecks --backup
xcodebuild -project Vinyl/Vinyl.xcodeproj -scheme Vinyl \
  -configuration Debug -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/vinyl-lyrics-derived-data \
  CODE_SIGNING_ALLOWED=NO build
```

联网脚本每次打印歌曲命中、来源、记录 ID、输入/匹配时长、误差和行数，结束后清理临时歌词缓存。
`.build`、`.swiftpm` 已忽略。未提交歌词正文、编译产物或缓存文件。
成功缓存位于系统 Caches，应用不主动过期成功条目；系统清理 Caches 后会重新请求。

测试技能的额外 `utree flush` 汇总命令已尝试，因 `/Users/bytedance/.local/bin/utree` 未安装而返回 127；不影响实际 XCTest 和 xcodebuild，本文件记录真实验证证据。
本次修改只做中文本地提交，不推送远端。
