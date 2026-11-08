# 原生模拟器录屏

- 视频：[vinyl-native-ios27.mp4](vinyl-native-ios27.mp4)
- 构建及录制：[Actions 42477404823](https://github.com/ZhaoLegs/vinyl-player/actions/runs/42477404823)
- 录制源码：`66596571bb9bfec2a2be9e52627cb467ba34bee8`
- 环境：Xcode 27.1（27A9275），iOS 27.2（24B8117），iPhone 17 Pro 模拟器。
- 尺寸：1206×2622；时长：9.926667 秒；135 帧，保留原始可变时间戳。

使用 `simctl io recordVideo` 录制实际 SwiftUI 应用。应用预热一次后重新启动，完成打开、抽出、收回、翻到 B 面和关闭；结束截图见 [home-final.png](home-final.png)。顶部为系统玻璃按钮，首页底部为系统 TabView，迷你播放器为自定义内容加系统 `.glassEffect`。

原始 MOV（约 13.57 秒）和构建日志在 Actions artifact 中，保留 14 天。MP4 裁掉启动桌面和白屏，从第 3.641667 秒的原始画面开始，没有加速或运动插帧。转码后逐帧校验了保留帧的呈现时间，误差不超过 1 微秒。该视频用于查看模拟器的实际效果，不能证明真机帧率或与参考视频像素级一致。

转码命令（FFmpeg 6）：

```sh
ffmpeg -fflags +igndts -i vinyl-native-ios27.mov \
  -vf 'trim=start=3.6,setpts=PTS-STARTPTS' \
  -c:v libx264 -crf 18 -preset fast -bf 0 \
  -enc_time_base 1:600 -fps_mode vfr -pix_fmt yuv420p \
  -movflags +faststart -an vinyl-native-ios27.mp4
```

`igndts` 避免源 MOV 的解码时间戳影响呈现顺序；显式编码时间基保留原始帧间隔，关闭 B 帧避免输出时长受重排影响。
