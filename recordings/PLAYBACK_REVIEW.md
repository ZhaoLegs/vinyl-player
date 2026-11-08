# 播放与布局验收

每个界面右下方新增「验收」按钮。点击查看当前可见元素的实际布局尺寸、左右边距、SF 字号配置、图片圆角；选择元素 A/B 可计算水平与垂直净距、左边缘差。开启「显示元素边框」后点完成，可回到界面检查边框。系统导航尺寸通过只读 UIKit 探针读取，玻璃阴影不计入布局边界。

首页的封面网格保持四列，并增加黑色 12%、模糊 4pt、向下 3pt 的阴影，另有轻微接触阴影。

曲目表的文字「Ⅱ / ▶」改为 `pause.fill` / `play.fill` SF Symbols，统一 16pt、semibold。整行可点击。底部播放/暂停按钮使用相同字号与图标，有 44pt 点击范围。Apple Music 大播放器主按钮为 30pt。

内置演示现在能播放项目原创的 24 秒验收音频。所有演示曲目使用同一段音频，界面明确标注「非原曲」。播放状态、游标与拖动位置取自 AVAudioPlayer 的实际时钟；暂停后停止推进。波形高度是该 WAV 的真实 RMS 分段，不使用随机音量动画。

Apple Music 页面使用 MusicKit 的真实播放位置、时长与状态驱动同一轨道，支持拖动及 VoiceOver 每次调整 5 秒。MusicKit 不提供解码后的 PCM，因此其轨道采用等高时间刻度，不将它称为真实音频频谱。

原生验收脚本检查 AVAudioPlayer 开始推进、暂停漂移小于 0.05 秒、跳转误差小于 0.1 秒、继续播放，并输出 `playback-check.json`。布局检查输出实际测量 `layout-review.json`，核对按钮 44pt 以及相邻封面 18pt 间距。真实 Apple Music 授权与播放仍需要签名设备、账号与订阅验收。

## 原生验收结果

源码 `7414d978e61be8fd439dca9f655a0b8c8240891a` 已通过 [Xcode 构建、原生运行与验收](https://github.com/ZhaoLegs/vinyl-player/actions/runs/42504329475)。实际环境为 Xcode 27.1 / iOS 27.2 / iPhone 17 Pro 模拟器。

播放时间推进至 2.98 秒，暂停漂移为 0 秒；跳转至 14.4 秒后继续推进至 16.40 秒。音频实际时长 24 秒，波形包含 112 个 RMS 分段。完整结果见 [播放检查数据](playback-check.json)。

已核对嵌套元素标注不会被父容器覆盖：播放按钮 16pt、迷你标题 13pt、曲目标题 15pt；发行图片宽 58pt、圆角 2pt，详情播放条与左圆按钮均为 16pt 左边距。见 [首页测量](layout-review.json)、[详情测量](detail-layout-review.json)。

- [验收面板截图](vinyl-layout-inspector.png)：可查看尺寸、字号、圆角，搜索元素、选择两项测净距。
- [实际详情截图](vinyl-playback-detail.png)：SF Symbols 图标及实际音频时间游标。
- [首页封面阴影截图](vinyl-cover-shadows.png)。
- [播放、暂停与跳转录屏](vinyl-playback-review.mp4)：原始模拟器录屏裁掉启动桌面，H.264 / 30fps / faststart；没有运动插帧，模拟器录像不包含音轨。使用内置验收音频，非原曲。
