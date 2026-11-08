# Apple Music 接入

此分支在 `main` 的界面修订基础上加入 MusicKit。正常启动进入真实音乐资料库；原来的固定专辑和自动关闭动画仅用于“我的 → 查看黑胶动效演示”以及 `--record-demo`。

## 已实现的代码

- 点击“连接 Apple Music”后才请求系统授权；拒绝后提供系统设置入口，受限制时解释原因。
- 授权后通过 `MusicLibraryRequest` 读取用户的专辑、歌单，按每页 50 项加载更多，支持下拉刷新。
- 专辑/歌单详情读取全部曲目分页，展示真实名称、艺人、封面和时长；当前只展示歌曲，跳过音乐视频。
- 搜索调用 `MusicCatalogSearchRequest`，返回前 20 个专辑和前 20 首歌曲；输入防抖并取消过期查询。
- 使用整个应用共享的 `ApplicationMusicPlayer` 建立队列，播放选中的歌曲，支持暂停/继续、上一首/下一首及进度拖动。
- 迷你播放器与正在播放页从 MusicKit 读取实际歌曲及播放状态；唱片旋转跟随播放/暂停，并尊重“减少动态效果”。
- 曲库播放前检查订阅；资料库播放交由 MusicKit 判断可用性，不把“没有订阅”等同于“不能播放任何已购音乐”。
- 数据加载、播放错误显示为可关闭提示，不伪装为成功；返回前台时重新核对权限，撤销后清理个人资料。
- Debug/Release 均设置 `NSAppleMusicUsageDescription`；`Info.plist` 添加后台音频模式。

## 需要账号持有者完成的配置

**没有在本次工作中登录或修改你的 Apple Developer 账号，也没有验证真实 Apple Music 账号的播放。**

1. 在 Apple Developer 的 Certificates, Identifiers & Profiles 中打开显式 App ID `com.zhaolegs.Vinyl`。
2. 在 App Services 中启用 **MusicKit** 并保存。若改了 Bundle ID，开发者后台和 Xcode 的值必须一致。
3. 在 Xcode 的 Signing & Capabilities 中选择你自己的开发团队，使用有效签名安装到 iPhone。
4. iPhone 登录需要测试的 Apple Music 账号。打开 Vinyl，点击连接并允许访问。
5. 播放曲库歌曲需要账号具备相应 Apple Music 订阅及歌曲所在地区的播放权限。

原生 MusicKit 自动管理开发者 token，本项目不要求把私钥或 token 写入源码。配置依据：[Apple — Using Automatic Developer Token Generation](https://developer.apple.com/documentation/musickit/using-automatic-token-generation-for-apple-music-api)。

## 验证范围

`834da95` 已通过 [Xcode 27.1 Release 构建与默认启动检查](https://github.com/ZhaoLegs/vinyl-player/actions/runs/42490775142)。检查核对了构建产物中的音乐权限描述及后台音频模式，应用在无账号状态下正常显示连接页并持续运行。后续原生界面录屏与内置动效演示以该分支 Actions 为准。

`d043998` 的 [原生录制任务](https://github.com/ZhaoLegs/vinyl-player/actions/runs/42498896983) 已成功：Xcode 27.1（27A9275）、iOS 27.2、iPhone 17 Pro 模拟器，采用 `simctl io recordVideo`。视频见 [录制说明](recordings/APPLE_MUSIC_RECORDING.md)。

模拟器启动检查只验证无账号状态下的连接页，不代表真实授权、资料库读取或播放已联调通过。旧录屏展示的是内置素材动效，也不代表 MusicKit 真实播放。

真机验收：

- 首次连接、拒绝、设置中重新允许、撤销权限后返回应用。
- 有/无订阅、空资料库、大于 50 项的资料库、断网及恢复后刷新。
- 歌单和专辑全部曲目加载；不可播放歌曲提示；歌曲选择和实际声音一致。
- 连续播放、暂停/继续、切歌、拖动进度、切换标签、打开/关闭详情。
- 锁屏、后台、耳机断开及系统中断后的播放状态同步。

## 本次边界

电台仍未实现，Spotify 尚未接入。搜索暂不分页，歌单编辑、收藏、下载、随机/循环和队列编辑也未实现。真实音乐详情采用可滚动曲目页；原片封套的打开/翻面/关闭演示仍独立保留，尚未把所有演示转场接到真实专辑页。
