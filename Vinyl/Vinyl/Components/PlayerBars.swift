import SwiftUI
import Foundation

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

/// 首页底部正在播放条
struct MiniPlayer: View {
    var body: some View {
        HStack(spacing: 8) {
            // 40pt slot is the capsule's leading circular cap. The 27pt disc is
            // centered inside that cap, not inset by an extra leading pad.
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [Color(hex: 0x3A2E68), Color(hex: 0x12141C), Color(hex: 0x0B0C10)],
                                        center: .center, startRadius: 1, endRadius: 16))
                Circle()
                    .fill(Color(hex: 0x6E5AA8))
                    .frame(width: 10, height: 10)
                Circle().fill(.white).frame(width: 3.5, height: 3.5)
            }
            .frame(width: 27, height: 27)
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 1) {
                Text("A1 · Mind Games")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DS.ink)
                Text(AlbumData.artist)
                    .font(.system(size: 10.5))
                    .foregroundStyle(DS.secondary)
            }

            Spacer(minLength: 0)
            SystemPauseButton(size: 13)
        }
        .padding(.trailing, 14)
        .glassCapsule(height: 40)
    }
}

/// 详情页底部波形控制条：112 根竖线，已播放部分为深色
struct WaveformBar: View {
    let progress: Double
    private let count = 112

    var body: some View {
        HStack(spacing: 10) {
            SystemPauseButton(size: 11)

            HStack(spacing: 1.5) {
                ForEach(0..<count, id: \.self) { i in
                    let head = i == Int(Double(count) * progress)
                    Capsule()
                        .fill(Double(i) < Double(count) * progress ? DS.ink : Color(hex: 0xB9B5B1))
                        .frame(width: 1.5, height: head ? 24 : barHeight(i))
                        .shadow(color: head ? .black.opacity(0.28) : .clear, radius: head ? 3 : 0)
                }
            }
            .frame(height: 26)
        }
        .padding(.horizontal, 14)
        .glassCapsule(height: 42)
    }

    private func barHeight(_ i: Int) -> CGFloat {
        let a = abs(sin(Double(i) * 1.7) * cos(Double(i) * 0.41))
        let b = abs(sin(Double(i) * 0.13))
        return 6 + CGFloat(a) * 13 + CGFloat(b) * 5
    }
}
