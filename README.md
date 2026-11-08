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

SwiftUI 项目为 `Vinyl/Vinyl.xcodeproj`，需要 Xcode 27 SDK。源码同步了尺寸、动作时长、翻面和系统栏显隐；原生弹簧与网页关键帧插值仍有差别。当前 Linux 环境只完成 Swift 语法检查，未进行 iOS SDK 类型检查、Xcode 构建或真机录屏。

## Xcode 原生录屏

新增 GitHub Actions 工作流 **Native iOS 27 recording**，使用官方 `xcode-27` runner，来源为 [runner-images #14404](https://github.com/actions/runner-images/issues/14404)。

推送 `fix/native-ios27-recording` 分支的原生改动会自动触发，也可在工作流进入默认分支后手动运行。流程要求实际安装 Xcode 27 和 iOS 27 runtime，缺失时明确失败。

录制由 `xcrun simctl io recordVideo` 完成，应用带 `--record-demo` 参数启动后运行完整原生动画。只有收到应用关闭动画完成标记后，脚本才输出成功标记；仍需要人工查看成片，确认玻璃材质、布局和流畅度。

Actions artifact `vinyl-native-ios27-<commit>` 包含：

- `vinyl-native-ios27.mov`：原生模拟器 H.264 录屏。
- `home-final.png`：结束时的原生截图。
- `environment.json`：实际 Xcode、iOS runtime、设备类型和提交号。
- `build.log` / `recorder.log`：构建与录制日志；失败时提供 `failure.txt`。

也可以在已安装上述环境的 Mac 上运行：

```sh
python3 scripts/record_native.py --output /tmp/vinyl-native
```

工作流和录制入口已完成本地静态检查，尚未在云端运行；GitHub 推送和执行结果以实际 Actions 记录为准。
