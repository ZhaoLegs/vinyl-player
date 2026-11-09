import AVFoundation
import Foundation

/// 波形条的数据来源。
/// • `.audioFile`：本地可读音频（AVURLAsset），用 AVAssetReader 按桶算 RMS，归一化后缓存。
/// • `.seeded`：Apple Music（ApplicationMusicPlayer，DRM）拿不到采样，用歌曲 ID 做种子生成
///   稳定的伪波形 —— 同一首歌每次都一样，但**不是**真实振幅。
enum WaveformSource { case audioFile, seeded }

enum Waveform {
    static let barCount = 112

    /// 以字符串（歌曲 ID）为种子的确定性伪波形，值域 0.15…1。
    static func seeded(_ seed: String, count: Int = barCount) -> [Double] {
        var hash: UInt64 = 0xcbf29ce484222325          // FNV-1a
        for byte in seed.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        var state = hash == 0 ? 0x9E3779B97F4A7C15 : hash
        func next() -> Double {                          // xorshift64*
            state ^= state >> 12; state ^= state << 25; state ^= state >> 27
            return Double((state &* 0x2545F4914F6CDD1D) >> 11) / Double(1 << 53)
        }
        let raw = (0..<count).map { _ in next() }
        // 轻度平滑 + 慢包络，让它像音乐的起伏而不是白噪声
        let phase = next() * .pi * 2
        return (0..<count).map { i in
            let a = raw[max(0, i - 1)], b = raw[i], c = raw[min(count - 1, i + 1)]
            let local = (a + 2 * b + c) / 4
            let envelope = 0.65 + 0.35 * sin(Double(i) / Double(count) * .pi * 3 + phase)
            return min(1, max(0.15, local * envelope * 1.25))
        }
    }
}

/// 本地音频文件的真实振幅包络（RMS），按 URL + 桶数缓存。
actor WaveformAnalyzer {
    static let shared = WaveformAnalyzer()
    private var cache: [String: [Double]] = [:]

    func levels(for url: URL, count: Int = Waveform.barCount) async throws -> [Double] {
        let key = "\(url.absoluteString)#\(count)"
        if let cached = cache[key] { return cached }

        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let seconds = try await asset.load(.duration).seconds
        let sampleRate = 8_000.0                         // 降采样到 8kHz 单声道再算 RMS，足够画 112 根线
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: sampleRate
        ])
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadUnknown) }

        let total = max(1, Int(seconds.isFinite ? seconds * sampleRate : 0))
        var sums = [Double](repeating: 0, count: count)
        var counts = [Int](repeating: 0, count: count)
        var index = 0
        while let buffer = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(buffer) {
            let length = CMBlockBufferGetDataLength(block)
            var data = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
            data.withUnsafeMutableBytes { raw in
                _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
            }
            for sample in data {
                let bucket = min(count - 1, index * count / total)
                sums[bucket] += Double(sample * sample)
                counts[bucket] += 1
                index += 1
            }
        }
        if reader.status == .failed { throw reader.error ?? CocoaError(.fileReadUnknown) }
        var levels = (0..<count).map { counts[$0] > 0 ? sqrt(sums[$0] / Double(counts[$0])) : 0 }
        let peak = levels.max() ?? 0
        if peak > 0 { levels = levels.map { $0 / peak } }
        cache[key] = levels
        return levels
    }
}
