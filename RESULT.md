# 迷你播放条封面衔接修复

工作目录：`/Users/bytedance/Documents/项目/App/vinyl-player-miniflight`

分支：`ai/mini-flight`

基线：`fix/native-buttons-playerbar` / `b3f4ed5`

工程：`Vinyl/Vinyl.xcodeproj`，Scheme `Vinyl`

## 根因

1. **变量名称与实际测量不一致。** `miniDiscFrame` 的注释写着 27pt 黑胶，但基线代码实际在 `MiniDiscLabel` 上测量。标签直径是 `27 × 72 / 234 = 8.307692pt`。测量位于旋转层内，`.global` 返回旋转后的方形包围盒，而非正圆的固定直径。模拟器日志在约 215° 时回报 11.58pt，尺寸误差约 3.28pt / 39.5%，超过 1pt 要求。其中心也带有约 0.17pt 的变换/像素对齐偏移。
2. **旋转相位没有交接。** 原迷你条私有累计角度，飞行封面始终从 0° 开始；关闭也未同步落地角度。
3. **标签的中心孔不一致。** 迷你标签有 1.2pt 白孔，原飞行层没有，起飞/返回时图形会改变。
4. **图源可能不同。** 歌单的迷你条显示当前歌曲专辑封面，旧飞行层取所选歌单封面；演示切换封面时也存在类似差异。异步官方图加载还可能在飞行过程中切换位图。
5. **关闭目标可能被覆盖。** 首页格子的实时 frame 回报没有排除 `openFromMini`，会在关闭时重写 `origin`。

## 改动

- `Components/PlayerBars.swift`：
  - 在旋转容器外单独回报 `miniLabelFrame`，使用 global 坐标和恒定的 8.307692pt 直径。
  - 用共享 `MiniDiscPhase` 保存播放/暂停相位；起飞读取最近显示的角度，隐藏期间冻结，落地从同一角度继续 72°/s。
  - 仅隐藏 label，27pt 黑胶盘面保留。
  - 回报实际解析到的封面位图，供飞行使用。
- `Views/LibraryView.swift`：
  - mini 路径采用独立 `MiniCoverFlight`，通过 `frame + position` 插值，不用旧飞行层的 `scaleEffect` 放大。
  - 同一 RoundedRectangle 从标签半径连续过渡到详情封套的实际直角；白色主轴孔平滑消失/恢复，详情圆孔沿用原来的末 30% 进度。
  - 飞行图案从当前角度转到 0°，关闭反向返回；孔内黑胶使用详情当前角度。
  - `mini / flight / detail` 单一 owner 控制参与交接的三层，交接使用无动画 transaction。
  - 排除 mini 关闭时的格子 frame 覆盖；保留旧 `miniDiscFrame` 和原 `CoverFlight` 给网格既有路径。
  - mini 打开交接采用 `.removed` completion，等原弹簧的剩余位移收敛后交给详情，避免逻辑完成时还有几何余量。**Motion 中的时长、弹簧、弧线、逐轴参数未改；交接等待余量会晚于旧 `.logicallyComplete` 时刻。**
- `AppleMusicViews.swift`、`Components/SleeveArtwork.swift`、`Views/AlbumDetailView.swift`：
  - 锁定实际显示的同一 UIImage / 缓存键，官方命中优先；mini 飞行、详情封套和孔内标签共用该快照。
  - 落地帧仍保留快照，随后才恢复新封面到达时的换图。
  - 详情的尺寸、布局、间距、翻面和网格打开/关闭算法未调整。详情切到另一专辑时解除原专辑快照。
- `VinylApp.swift` 和两份诊断脚本：
  - 显式 `--debug-mini-cycle` 时才使用无账号演示数据、跳过授权并记录几何；普通启动行为不变。
  - 官方缓存测试使用内置图片作为已命中缓存夹具，不调用网络、不写缓存映射磁盘。

## 验证环境与方法

- Xcode 27.2；Release；iOS 26.5 模拟器，iPhone 16 Pro / 402×874pt / 3×。
- 专用设备：`CA9452DF-8ADA-4C5F-82EA-B629E6B318F7`。没有操作主模拟器。
- `simctl io recordVideo` 录制原生界面；`ffmpeg -vf fps=60` 抽帧。
- 同时保存 `native-frames.json`，保留原生编码帧及时间戳。模拟器录屏为可变帧率，**60fps 导出的重复/补取帧不当作真实 60fps 渲染证据**。
- 无损端点 PNG 使用本次实际显示的 UIImage、实测 global frame 和角度，通过相同 SwiftUI 组件渲染。像素测量与原生视频、插值几何日志分开统计，未将模型值冒充录像像素测量。
- 检查三层 owner 全过程、每条飞行日志的图源键，并逐帧查看打开/关闭接触表。这里的“一张封面”指参与交接的迷你 label、飞行层、详情封套，不包含首页既有专辑格子、发行卡缩略图或详情正常抽出的唱片标签。

## 结果

### 无损端点像素检查

| 情况 | 起飞角度 | mini 与飞行起点中心误差 | 直径误差 | 图案角度拟合误差 | 起点 RGBA 平均差 |
|---|---:|---:|---:|---:|---:|
| 播放中 | 215.424634° | 0pt | 0pt | 0° | 0/255 |
| 播放约 1 秒后暂停 | 73.522001° | 0pt | 0pt | 0° | 0/255 |
| 官方缓存图源夹具 | 217.210736° | 0pt | 0pt | 0° | 0/255 |

三组的详情封套与飞行终点不透明轮廓中心、宽度、高度误差也均为 0pt。详情终点裁切仍是原有直角，没有修改详情样式。

### 逐帧插值与交接

- 三组打开均到达 `progress = 1`，关闭均到达 `progress = 0`。
- mini 起落点为中心 **(41, 812)pt**，直径 **8.307692pt**。
- 最后一个交接前的插值采样，打开中心残余误差最大 **0.240pt**、宽度 **0.146pt**、角度 **0.106°**；关闭分别为 **0.184pt / 0.088pt / 0.064°**。最终交接采样误差为 0（浮点中心残差约 3.5e-14pt）。
- 三组 owner 都严格按 **flight → detail → flight → mini** 变化；可见性条件互斥，未观察到双封面或封面断档。关闭时飞行图源保持不变，mini 从最终角度恢复转动。
- 官方夹具用 `cover_06`，所选演示专辑仍为 `cover_13`；飞行和详情始终取 `official:mini-official-fixture`。这覆盖了“迷你条图源与所选集合不同”的分支。未使用已登录的真实 Apple Music 歌单或实机网络环境进行验证。
- 格子回归：诊断日志明确为 `close → tile`，沿用旧 CoverFlight，无 mini owner 切换；录屏正常返回原格子。

| 原生录像 | 原生编码帧数 | 60fps 导出帧数 |
|---|---:|---:|
| baseline | 1,204 | 688 |
| final-playing | 832 | 679 |
| final-paused | 469 | 590 |
| final-official | 1,008 | 679 |
| final-tile | 1,298 | 679 |

## 证据文件

以下路径均相对本工作目录。视频及大量抽帧保留在本地，已通过 `.gitignore` 排除，不进入提交。

- 原始基准：`recordings/mini-flight/baseline/cycle.mov`
- 最终播放往返：`recordings/mini-flight/final-playing/cycle.mov`
- 非零角度暂停：`recordings/mini-flight/final-paused/cycle.mov`
- 官方缓存图源：`recordings/mini-flight/final-official/cycle.mov`
- 格子路径回归：`recordings/mini-flight/final-tile/cycle.mov`
- 无损起点对照：`recordings/mini-flight/final-playing/endpoint-comparison.png`
- 无损端点：`recordings/mini-flight/final-playing/endpoints/{mini,flight-start,detail,flight-end}.png`
- 打开逐帧接触表：`recordings/mini-flight/final-playing/open-every-frame.jpg`
- 关闭逐帧接触表：`recordings/mini-flight/final-playing/close-every-frame.jpg`
- 关键原生录像抽帧：
  - 起飞前：`recordings/mini-flight/final-playing/frames-60/0252.png`
  - 起飞初段：`recordings/mini-flight/final-playing/frames-60/0254.png`
  - 放大途中：`recordings/mini-flight/final-playing/frames-60/0260.png`
  - 详情接手后：`recordings/mini-flight/final-playing/frames-60/0310.png`
  - 返回初段：`recordings/mini-flight/final-playing/frames-60/0523.png`
  - 缩回途中：`recordings/mini-flight/final-playing/frames-60/0530.png`
  - mini 恢复后：`recordings/mini-flight/final-playing/frames-60/0580.png`
- 完整数值：各 `final-*` 目录的 `checks.json`、`app.log`、`native-frames.json`。
- 最终编译日志：`recordings/mini-flight/final-build.log`

## 复现

```bash
xcodebuild -project Vinyl/Vinyl.xcodeproj -scheme Vinyl \
  -configuration Release -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,id=CA9452DF-8ADA-4C5F-82EA-B629E6B318F7' \
  -derivedDataPath /var/tmp/vinyl-miniflight/build CODE_SIGNING_ALLOWED=NO build

python3 scripts/record_mini_flight.py \
  --device CA9452DF-8ADA-4C5F-82EA-B629E6B318F7 \
  --app /var/tmp/vinyl-miniflight/build/Build/Products/Release-iphonesimulator/Vinyl.app \
  --output recordings/mini-flight/recheck
python3 scripts/check_mini_flight.py recordings/mini-flight/recheck
```

录制脚本可追加 `--paused`、`--official` 或 `--tile`。像素检查脚本需要 Pillow；`--tile` 使用原网格路径，不生成 mini 检查报告。

最终 `xcodebuild` 通过，脚本语法检查及 `git diff --check` 通过。仅本地提交，不 push。
