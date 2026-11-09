import SwiftUI
import Foundation
import MusicKit

/// SF Symbols 播放 / 暂停字形（系统字形，非自绘）。
struct PlaybackSymbol: View {
    let isPlaying: Bool
    var size: CGFloat = 13
    var body: some View {
        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(DS.ink)
    }
}

/// 真实播放控制：状态来自 ApplicationMusicPlayer，而不是按钮自己的乐观状态。
struct SystemPlaybackButton: View {
    let isPlaying: Bool
    var size: CGFloat = 13
    var disabled = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            PlaybackSymbol(isPlaying: isPlaying, size: size)
                .frame(width: 32, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityLabel(isPlaying ? "暂停" : "播放")
    }
}

/// 系统 SF Symbols 播放/暂停控件（苹果控件库），工程内不自绘任何 Capsule 图标。
struct SystemPauseButton: View {
    var size: CGFloat = 14

    var body: some View {
        Button("暂停", systemImage: "pause.fill") { }
            .labelStyle(.iconOnly)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(DS.ink)
            .buttonStyle(.plain)
    }
}

/// 首页底部正在播放条：有真实 Apple Music 曲目时显示其标题 / 艺人 / 播放状态，否则显示演示内容。
struct MiniPlayer: View {
    @EnvironmentObject private var music: AppleMusicStore

    var body: some View {
        HStack(spacing: 8) {
            // 40pt slot is the capsule's leading circular cap. The 27pt disc is
            // centered inside that cap, not inset by an extra leading pad.
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [Color(hex: 0x3A2E68), Color(hex: 0x12141C), Color(hex: 0x0B0C10)],
                                        center: .center, startRadius: 1, endRadius: 16))
                // 中心标签 = 当前专辑封面（等比填充），主轴孔在最上层
                DiscLabel(coverName: DS.coverName(AlbumData.featuredIndex),
                          artwork: music.hasCurrentTrack ? music.currentArtwork : nil,
                          size: 10)
                Circle().fill(.white).frame(width: 3.5, height: 3.5)
            }
            .frame(width: 27, height: 27)
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 1) {
                Text(music.hasCurrentTrack ? music.currentTitle : music.demoMiniTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DS.ink)
                    .lineLimit(1)
                Text(music.hasCurrentTrack ? music.currentArtist : AlbumData.artist)
                    .font(.system(size: 10.5))
                    .foregroundStyle(DS.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
            if music.hasCurrentTrack {
                SystemPlaybackButton(isPlaying: music.isPlaying, disabled: music.isPreparing) {
                    Task { await music.togglePlayback() }
                }
                .padding(.trailing, -9)
            } else {
                SystemPlaybackButton(isPlaying: music.demoPlaying) { music.selectDemo(music.demoTrack) }
                    .padding(.trailing, -9)
            }
        }
        .padding(.trailing, 14)
        .glassCapsule(height: 40)
    }
}

/// 详情页底部波形控制条：112 根竖线，已播放部分为深色。
/// `levels` 为 0…1 的振幅（本地音频 = RMS 实测；Apple Music = 歌曲 ID 种子伪波形）；
/// 为 nil 时用原片风格的演示波形。
struct WaveformBar: View {
    let progress: Double
    var levels: [Double]? = nil
    var isPlaying: Bool = true
    var toggle: (() -> Void)? = nil
    private let count = Waveform.barCount

    var body: some View {
        HStack(spacing: 10) {
            if let toggle {
                SystemPlaybackButton(isPlaying: isPlaying, size: 11, action: toggle)
                    .frame(width: 20)
            } else {
                SystemPauseButton(size: 11)
            }

            // 竖线间距按可用宽度自适应：固定 1.5pt 间距时 112 根线会把整页撑到 416pt，
            // 让首页 / 详情页内容整体向右偏出屏幕（右边距只剩 ~8pt）。
            GeometryReader { geo in
                let gap = max(0.5, (geo.size.width - CGFloat(count) * 1.5) / CGFloat(count - 1))
                let played = Double(count) * min(1, max(0, progress))
                HStack(spacing: gap) {
                    ForEach(0..<count, id: \.self) { i in
                        let head = i == Int(played)
                        Capsule()
                            .fill(Double(i) < played ? DS.ink : Color(hex: 0xB9B5B1))
                            .frame(width: 1.5, height: head ? 24 : barHeight(i))
                            .shadow(color: head ? .black.opacity(0.28) : .clear, radius: head ? 3 : 0)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
            .frame(height: 26)
        }
        .padding(.horizontal, 14)
        .glassCapsule(height: 42)
    }

    private func barHeight(_ i: Int) -> CGFloat {
        if let levels, levels.count == count {
            return 4 + CGFloat(levels[i]) * 18
        }
        let a = abs(sin(Double(i) * 1.7) * cos(Double(i) * 0.41))
        let b = abs(sin(Double(i) * 0.13))
        return 6 + CGFloat(a) * 13 + CGFloat(b) * 5
    }
}
