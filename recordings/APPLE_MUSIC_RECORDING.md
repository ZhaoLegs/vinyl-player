# 当前版本原生录屏

录制源码：`d043998c3eea09636a0a9f408db23cc8757f91b1`。
[Actions 构建与录制成功记录](https://github.com/ZhaoLegs/vinyl-player/actions/runs/42498896983)。

- [Apple Music 界面切换](vinyl-apple-music-interface.mp4)：9.43 秒，未连接账号的资料库、我的、搜索界面。标签切换由录制参数自动驱动，不是触摸输入验证。
- [黑胶动效演示](vinyl-current-animation.mp4)：7.60 秒，内置素材的打开、抽出、收回、翻面及关闭转场。不是 Apple Music 音频播放演示。

实际环境：Xcode 27.1、iOS 27.2、iPhone 17 Pro 模拟器，原始录制使用 `simctl io recordVideo`。保留原始 MOV 与日志在上述 Actions artifact 中。

成片剪掉启动桌面和白屏，用 FFmpeg 读取原始显示时间戳，输出 H.264、1206×2622、30fps、yuv420p 和 faststart MP4。30fps 是兼容性编码；重复帧没有运动插帧，不代表应用实时达到 30fps。两段成片均已检查有效时长、完整解码和抽帧画面。

未录制账号授权、真实资料库或真实音频。开发者服务配置与签名真机验收仍需完成，见 [Apple Music 接入说明](../APPLE_MUSIC.md)。
