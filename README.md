# Vinyl · 原视频对照修订版

已读取用户提供的完整 [参考视频](https://github.com/ZhaoLegs/vinyl-player/releases/download/reference-assets/vinyl-reference.mp4)，提取全部 185 帧，并对打开、抽出、翻面、关闭逐帧核对。原片为 1600×1200、30fps、6.167 秒。

## 本轮修订

- 用原视频封面替换首页不匹配的专辑素材，重新测量网格。
- 打开修正为第 6–25 帧的弧线路径和末段回稳，不再在第 16 帧提前停止。
- 补上唱片抽出后的整体缩小与回稳。
- 侧转往返改为翻到 B 面，切换中心标签。
- 关闭增加侧转，持续归位到第 185 帧。
- 详情页隐藏底部导航，波形播放器下移；清除残留条带。顶部按钮和首页导航仍保留系统控件方向。
- 保留上一轮对任务取消、连续时间采样、滚动边缘与封面交接的修复。

具体测量、验证和限制见 [视频核对](视频核对.md) 与 [修复说明](修复说明.md)。此前文档放在 [历史实现记录](历史实现记录.md)，旧的时序和“1:1”结论不再适用。

## 运行与录制

从此目录运行 `python -m http.server 8765`，访问 `http://localhost:8765/preview/`。

- 普通预览自动循环；时间轴可暂停、逐帧检查。
- `preview/?capture` 提供纯设备画面，默认暂停。
- 点击封面进入详情；点击封套抽出/收回；点击 X 返回。
- `python scripts/check_preview.py` 检查浏览器交互与主要动画边界。
- `python scripts/record_preview.py --output /workspace/vinyl-fixed.mp4` 导出 60fps 网页演示。需要 Playwright、Chromium、ffmpeg。

录制脚本实际截取 Chromium 渲染结果，按 1/60 秒时间采样编码为 MP4；它是确定性帧导出，不能用来证明设备实时达到 60fps。

SwiftUI 项目为 `Vinyl/Vinyl.xcodeproj`，需要 Xcode 27 SDK。源码同步了尺寸、动作时长、翻面和系统栏显隐；原生弹簧与网页关键帧插值仍有差别。已通过 GitHub Actions 在 macOS 上完成 Xcode 27.1 Release 构建，录制使用 iOS 27.2 的 iPhone 17 Pro 模拟器。

## Xcode 原生录屏

**已完成并核对原生录屏**：[下载 MP4](recordings/vinyl-native-ios27.mp4)（约 9.93 秒，1206×2622）· [成功的 Actions 记录](https://github.com/ZhaoLegs/vinyl-player/actions/runs/42477404823)。

录制源码提交为 `66596571bb9bfec2a2be9e52627cb467ba34bee8`。Xcode 27.1 Release 构建通过，iOS 27.2 / iPhone 17 Pro 模拟器完成首页→打开→抽出→收回→B 面→返回首页。已查看录屏抽帧，封面、唱片标签及发行图片均显示，系统 TabView 在详情隐藏、返回后恢复。这是模拟器录制；真机性能和参考视频的像素级一致性尚未验证。

新增 GitHub Actions 工作流 **Native iOS 27 recording**，使用官方 `xcode-27` runner，来源为 [runner-images #14404](https://github.com/actions/runner-images/issues/14404)。

推送 `fix/native-ios27-recording` 分支的原生改动会自动触发，也可在工作流进入默认分支后手动运行。流程要求实际安装 Xcode 27 和 iOS 27 runtime，缺失时明确失败。

录制由 `xcrun simctl io recordVideo` 完成，应用带 `--record-demo` 参数启动后运行完整原生动画。脚本先预热一次完整演示，再重新启动应用录制；只有收到应用关闭动画完成标记后，才输出成功标记。应用启动时检查全部封面与唱片图片是否成功载入，避免生成缺图录屏；成片还需要视觉核对。

Actions artifact `vinyl-native-ios27-<commit>` 包含：

- `vinyl-native-ios27.mov`：原生模拟器 H.264 录屏。
- `home-final.png`：结束时的原生截图。
- `environment.json`：实际 Xcode、iOS runtime、设备类型和提交号。
- `build.log` / `recorder.log`：构建与录制日志；失败时提供 `failure.txt`。

也可以在已安装上述环境的 Mac 上运行：

```sh
python3 scripts/record_native.py --output /tmp/vinyl-native
```

仓库中的 MP4 去掉了启动前的模拟器桌面和白屏，保留应用画面的原始呈现时间；没有加速、运动插帧或网页画面替换。原始 MOV、构建日志和环境信息保存在上述 Actions artifact（保留 14 天）；MP4、[环境信息](recordings/environment.json)和[结束截图](recordings/home-final.png)随源码长期保留。转码方法见 [录屏说明](recordings/README.md)。
