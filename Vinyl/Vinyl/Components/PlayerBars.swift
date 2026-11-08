import SwiftUI

struct PlaybackSymbol: View {
    let isPlaying: Bool
    var size: CGFloat = DS.playbackIcon
    var body: some View {
        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
            .font(.system(size: size, weight: .semibold))
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(DS.ink)
    }
}

struct SystemPlaybackButton: View {
    let isPlaying: Bool
    var size: CGFloat = DS.playbackIcon
    var disabled = false
    var reviewID = "playback-control"
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            PlaybackSymbol(isPlaying: isPlaying, size: size)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityLabel(isPlaying ? "暂停" : "播放")
        .reviewElement(reviewID, "播放 / 暂停按钮", font: size, note: "SF Symbols · semibold · 44pt 点击范围")
    }
}

struct MiniPlayer: View {
    @EnvironmentObject private var playback: DemoPlaybackStore
    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle().fill(RadialGradient(colors: [Color(hex: 0x3A2E68), Color(hex: 0x12141C), Color(hex: 0x0B0C10)],
                                            center: .center, startRadius: 1, endRadius: 16))
                Circle().fill(Color(hex: 0x6E5AA8)).frame(width: 10, height: 10)
                Circle().fill(.white).frame(width: 3.5, height: 3.5)
            }
            .frame(width: 27, height: 27)
            .reviewElement("mini-disc", "迷你唱片", radius: 13.5)
            .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 1) {
                Text(AlbumData.tracks[playback.selectedTrack].title)
                    .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    .reviewElement("mini-title", "首页歌曲标题", font: 13)
                Text("验收音频 · 非原曲")
                    .font(.system(size: 10.5)).foregroundStyle(DS.secondary)
                    .reviewElement("mini-artist", "首页音频来源", font: 10.5)
            }
            Spacer(minLength: 0)
            SystemPlaybackButton(isPlaying: playback.isPlaying) { playback.toggle() }
        }
        .padding(.trailing, 2)
        .glassCapsule(height: 44)
        .reviewElement("home-player", "首页歌曲信息条", radius: 22, note: "底部布局留白 18pt")
    }
}

/// Real playback position. MusicKit does not expose decoded PCM; without an
/// envelope this is a uniform time track, never claimed to be a real spectrum.
struct WaveformBar: View {
    let position: Double
    let duration: Double
    let isPlaying: Bool
    var levels: [Double] = []
    let toggle: () -> Void
    let seek: (Double) -> Void
    @State private var dragged: Double?
    private let count = 112
    private var progress: Double {
        dragged ?? (duration > 0 ? min(1, max(0, position / duration)) : 0)
    }

    var body: some View {
        HStack(spacing: 6) {
            SystemPlaybackButton(isPlaying: isPlaying, disabled: duration <= 0, action: toggle)
            GeometryReader { proxy in
                Canvas { context, size in
                    let step = size.width / CGFloat(count)
                    for i in 0..<count {
                        let level = levels.indices.contains(i) ? levels[i] : 0.65
                        let height = CGFloat(6 + min(1, max(0, level)) * 18)
                        let rect = CGRect(x: CGFloat(i) * step, y: (size.height - height) / 2,
                                          width: min(1.5, step * 0.55), height: height)
                        context.fill(Path(roundedRect: rect, cornerRadius: 0.75),
                                     with: .color(Double(i) / Double(count) < progress ? DS.ink : DS.tertiary))
                    }
                    let cursor = CGRect(x: min(size.width - 2, max(0, CGFloat(progress) * size.width)),
                                        y: 0, width: 2, height: size.height)
                    context.fill(Path(roundedRect: cursor, cornerRadius: 1), with: .color(DS.ink))
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { dragged = Double(min(1, max(0, $0.location.x / max(1, proxy.size.width)))) }
                    .onEnded {
                        let value = min(1, max(0, $0.location.x / max(1, proxy.size.width)))
                        seek(Double(value) * duration)
                        dragged = nil
                    })
                .accessibilityElement()
                .accessibilityLabel("播放进度")
                .accessibilityValue("\(Int(position)) 秒，共 \(Int(duration)) 秒")
                .accessibilityAdjustableAction { direction in
                    seek(position + (direction == .increment ? 5 : -5))
                }
            }
            .frame(height: 26)
            .reviewElement("wave-track", "播放时间轨道", note: levels.isEmpty
                           ? "112 根时间刻度 · 游标 2pt · 数据来自播放时钟，非频谱"
                           : "112 个真实音频 RMS 分段 · 游标 2pt")
        }
        .padding(.leading, 2)
        .padding(.trailing, 14)
        .frame(maxWidth: .infinity)
        .glassCapsule(height: 44)
        .reviewElement("detail-player", "详情播放条", radius: 22, note: "左右边距 16pt")
    }
}
