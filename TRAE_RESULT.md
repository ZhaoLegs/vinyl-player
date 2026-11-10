# 官方封面匹配修复结果

验证日期：2026-11-09

工作目录：`/Users/bytedance/Documents/项目/App/vinyl-player-trae`

分支：`trae/official-covers`

六张指定专辑在干净临时缓存下实测 **6/6 命中，100%**。每张都通过 CAA 下载并用 ImageIO 解码验证，不能仅凭 MusicBrainz 搜索结果或 HEAD 返回成功计为命中。模拟器 `xcodebuild` 通过。

## 原因与证据

实际实现位于 `AppleMusicViews.swift`，`AppleMusicStore.swift` 提供专辑数据。

1. **失败被永久缓存，后续无法恢复。** Build 150 的 `lookup` 把网络错误、CAA 请求失败及真实未匹配都返回为 `nil`；调用方无条件写入 `map.json`。虽然保存了 `checkedAt`，读取时没有过期判断。首次查失败后，该 ID 每次启动都直接返回，不再联网。CAA 的错误又被 `try?` 吞掉，使部分网络失败显示为普通 miss。
2. **名称差异。** 原清洗只删括号内容，不处理 `- Single`、`- EP`、简繁体或月份数字。MusicBrainz 登记周杰伦这张为 **《11月的蕭邦》**，输入是《十一月的萧邦》。现场查询 `releasegroup:"十一月的蕭邦"` 返回 0；旧宽松查询返回 141 个候选，第一项为《11月的蕭邦》，score 100。只有简繁体转换仍不足以匹配。
3. **只取一个 release-group 不够。** 《平凡的一天》可以在 MusicBrainz 找到，但旧代码只尝试 release-group 的代表封面。新版通过该组关联的 Official release `91178088-d0ff-43c0-badc-83b35868299d` 取得封面。
4. **请求和匹配不够可靠。** 原限速预约未来时间后让多个任务同时挂起，没有真正串行执行；还对 MB、CAA 重复调用限速。请求超时仅 12 秒，没有重试。原 User-Agent 虽然存在，但地址是错误的仓库路径，联系邮箱为不可用的 `.local`。原逻辑只看搜索分数，未核验艺人；任意删括号还会把 nightcore、Taylor’s Version 等不同录音混同。

**复现边界：** 提供的真机日志为 0/24，本机用 Build 150 原始 Swift 源码、干净缓存实测为 5/6（毛不易未命中），没有复现真机的全部零命中。永久负缓存及错误吞掉可以固化首次失败；仅凭该日志无法确定原 24 张每一张首次失败的来源，也无法确定 -1005 的底层网络原因。本次修复这些已确认的代码缺陷，并用故障注入验证网络恢复。

## 改动

- 抽出 `OfficialCoverLookup.swift`，App 与命令行工具复用同一套匹配、网络及元数据缓存实现。
- 专辑清洗处理 Single、EP、Deluxe、Remastered 等版本后缀，提供简繁体查询变体，并统一中文月份与阿拉伯数字月份。保留 nightcore、Taylor’s Version 等不同录音标签。
- 查询顺序为 release-group 短语搜索 → 分词搜索 → 艺人名/别名解析并按 `arid` 搜索。候选必须同时满足清洗后的标题、艺人身份与 score ≥ 85；兼容数字和字符串 score。现场六张候选均为 100 分，无需靠降低阈值取得命中。
- 优先用 release-group 的 CAA 封面清单；缺少代表封面时浏览其 Official releases，必要时再搜索 Official release。只选 `front=true`、`approved=true` 的图片；不再用背面或任意第一张图代替封面。
- CAA 图片地址统一 HTTPS；直接下载并解码确认，500 缩略图缺失时尝试其他尺寸或原图。新下载的图片数据交给现有 `ArtworkCache`，避免二次下载。
- 全部封面网络请求进入串行队列；MusicBrainz 用单调时钟记录实际开始时间，间隔至少 1.1 秒。重试也经过同一限速。
- 每次请求带 `VinylPlayer/<版本号> (https://github.com/ZhaoLegs/vinyl-player)`。超时调整为请求 30 秒、资源 60 秒。-1005、超时等暂时性错误最多重试 **3 次**，即初次请求加最多 3 次重试，等待 1、2、4 秒；429/503 等服务错误也重试，并尊重 `Retry-After`。
- 网络错误不写负缓存。真实未匹配缓存 7 天；标题或艺人参数改变时重新查询。迁移时保留旧命中，丢弃旧版无法区分原因的负缓存。命中继续复用元数据与现有图片内存/磁盘缓存。
- `OfficialCoverStore` 保持原图片接口，未命中或错误返回 nil。`CachedArtwork` 的显示、状态更新和动画代码原样保留：Apple 封面照常加载，官方图片就绪后才替换，失败不清空已有图片。

修改源码仅涉及封面实现和新文件的 Xcode target 注册；没有修改动画、布局、歌词、播放器 UI、设计参数或主目录 `vinyl-player`。

## 真实接口验证

命令：

```sh
python3 scripts/check_official_covers.py
```

工具每次创建并清理临时缓存和 Swift 可执行文件，无需 API key。以下为最终运行结果：

| 艺人 | 输入专辑 | 结果 | 分数 | 封面路径 | 实际下载字节 |
|---|---|---|---:|---|---:|
| 周杰伦 | 十一月的萧邦 | HIT | 100 | release-group | 20,073 |
| 孙燕姿 | Stefanie | HIT | 100 | release-group | 31,353 |
| Charlie Puth | Nine Track Mind | HIT | 100 | release-group | 39,888 |
| 五月天 | 自传 | HIT | 100 | release-group | 53,238 |
| Taylor Swift | 1989 | HIT | 100 | release-group | 33,416 |
| 毛不易 | 平凡的一天 | HIT | 100 | Official release | 94,803 |

输出：`LIVE RESULT 6/6 = 100.0%`

对应 MusicBrainz ID 与图片地址：

- 周杰伦：`463ffb62-7116-399e-9721-9b46ae412b88`
  https://coverartarchive.org/release/032eee52-4ce5-49f6-a60e-44b00c778403/2801488577-500.jpg
- 孙燕姿：`7b8fe220-756f-39e7-affd-527acae860a6`
  https://coverartarchive.org/release/567d4c3b-f4e2-4ff7-93ec-7c601e1d6ee8/11902291729-500.jpg
- Charlie Puth：`3c82ff29-b9f1-4348-b20e-11d24d295845`
  https://coverartarchive.org/release/14c79c4c-1ecf-4cea-b684-a97135dcd12e/27097799196-500.jpg
- 五月天：`530bf0c2-1a4d-4743-b61b-87f7643f9bcb`
  https://coverartarchive.org/release/5322bd2f-7db6-409d-a90b-d7e7599399f2/14158532788-500.jpg
- Taylor Swift：`4d9ec1c2-58ec-48a4-aa0a-916718adead0`
  https://coverartarchive.org/release/d5cb50d8-8897-4029-b9b3-32806df7e06d/9282848916-500.jpg
- 毛不易（release ID）：`91178088-d0ff-43c0-badc-83b35868299d`
  https://coverartarchive.org/release/91178088-d0ff-43c0-badc-83b35868299d/33773635215-500.jpg

历史基线可运行 `python3 scripts/check_official_covers.py --baseline`；它直接从 Git 读取 Build 150 原始实现，隔离缓存后执行，不改写历史源码。接口数据和网络随时间变化，历史命中率不是固定保证。

## 回归与编译

`python3 scripts/check_official_covers.py --self-check` 输出 `SELF-CHECK PASSED`。离线故障夹具不计入上述真实命中率。已验证：

- 后缀、简繁体、中文月份数字及不同录音版本的区分。
- 字符串分数、艺人别名、错误艺人拒绝、短语搜索失败后的分词搜索、release 回退。
- 同专辑并发去重；三个并发网络请求实际串行，MB 开始时间间隔 ≥ 1 秒。
- 每个请求的 User-Agent、HTTPS 地址与正面图片选择。
- 热缓存及重新读取磁盘缓存不发请求；旧版命中保留、旧负缓存重查、真实负缓存过期。
- -1005/超时按 1、2、4 秒退避；最多 3 次重试；重试耗尽后再次调用可恢复，未被永久负缓存阻挡。
- HTTP 503/429 的恢复。

新匹配模块及工具通过 `swiftc -swift-version 6 -strict-concurrency=complete` 编译，无警告。

Xcode 27.2 / Swift 6.4.2，工程仍使用原 Swift 5 语言设置：

```sh
xcodebuild -project Vinyl/Vinyl.xcodeproj -scheme Vinyl \
  -configuration Debug -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/vinyl-trae-official-build \
  CODE_SIGNING_ALLOWED=NO build
```

最终输出：`** BUILD SUCCEEDED **`。原工程图片缓存的异步 NSLock 及歌词视图的 actor 隔离警告仍存在；新匹配模块无编译警告。本次未做真机网络抓包或视觉录屏，未把六张样本的命中率扩大为原 24 张或整个资料库的保证。

## 官方接口依据

- [MusicBrainz API](https://musicbrainz.org/doc/MusicBrainz_API)
- [搜索字段与 Lucene 查询规则](https://musicbrainz.org/doc/MusicBrainz_API/Search)
- [限速与 User-Agent 要求](https://musicbrainz.org/doc/MusicBrainz_API/Rate_Limiting)
- [Cover Art Archive API：release-group、release、front 与缩略图](https://musicbrainz.org/doc/Cover_Art_Archive/API)

按任务要求在 `trae/official-covers` 本地提交，不 push。
