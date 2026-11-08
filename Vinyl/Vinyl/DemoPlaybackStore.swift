import AVFoundation
import SwiftUI

/// Real local audio for layout acceptance; never presented as the named songs.
@MainActor
final class DemoPlaybackStore: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var position: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var selectedTrack = 0
    @Published private(set) var levels: [Double] = []
    @Published private(set) var failure: String?
    private var audio: AVAudioPlayer?

    func playOrToggle(track: Int) {
        if audio != nil && track == selectedTrack { toggle(); return }
        selectedTrack = track
        guard prepare() else { return }
        audio?.currentTime = 0
        previousPosition = 0
        start()
    }

    func toggle() {
        guard prepare(), let audio else { return }
        if audio.isPlaying { audio.pause() }
        else { start() }
        sync()
    }

    func seek(to seconds: Double) {
        guard seconds.isFinite, prepare(), let audio else { return }
        audio.currentTime = min(audio.duration, max(0, seconds))
        previousPosition = audio.currentTime
        sync()
    }

    func observe() async {
        while !Task.isCancelled {
            sync()
            do { try await Task.sleep(for: .milliseconds(100)) }
            catch { return }
        }
    }
    func load() { _ = prepare() }

    private func prepare() -> Bool {
        if audio != nil { return true }
        do {
            guard let url = Bundle.main.url(forResource: "acceptance-audio", withExtension: "wav") else {
                throw CocoaError(.fileNoSuchFile)
            }
            audio = try AVAudioPlayer(contentsOf: url)
            audio?.prepareToPlay()
            duration = audio?.duration ?? 0
            // Static RMS envelope of the actual local sample, not random bars.
            let file = try AVAudioFile(forReading: url)
            if let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                             frameCapacity: AVAudioFrameCount(file.length)) {
                try file.read(into: buffer)
                if let samples = buffer.floatChannelData?[0] {
                    let n = Int(buffer.frameLength)
                    levels = (0..<112).map { bin in
                        let lo = bin * n / 112, hi = (bin + 1) * n / 112
                        guard hi > lo else { return 0 }
                        var sum = 0.0
                        for i in lo..<hi { sum += Double(samples[i] * samples[i]) }
                        return sqrt(sum / Double(hi - lo))
                    }
                    let peak = levels.max() ?? 1
                    if peak > 0 { levels = levels.map { $0 / peak } }
                }
            }
            return true
        } catch {
            failure = "验收音频无法播放：\(error.localizedDescription)"
            audio = nil
            return false
        }
    }

    private func start() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback)
            try AVAudioSession.sharedInstance().setActive(true)
            if let audio {
                if audio.currentTime >= audio.duration - 0.01 {
                    audio.currentTime = 0
                    previousPosition = 0
                }
                if !audio.play() { failure = "验收音频启动失败" }
            }
        } catch { failure = error.localizedDescription }
        sync()
    }

    private func sync() {
        position = audio?.currentTime ?? 0
        isPlaying = audio?.isPlaying ?? false
        if !isPlaying, let audio, position < 0.01, duration > 0 {
            // AVAudioPlayer resets currentTime when reaching its natural end.
            // Keep the last observed end position instead of claiming playback.
            if previousPosition > duration - 0.3 { position = duration }
        }
        previousPosition = position
    }
    private var previousPosition = 0.0

    func stop() {
        audio?.pause()
        sync()
    }

    /// CI drives the same player commands as the visible controls and verifies
    /// the actual AVAudioPlayer clock, including pause and seek.
    func acceptanceCheck() async {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let reportURL = documents.appendingPathComponent("playback-check.json")
        do {
            load()
            guard duration > 0, !levels.isEmpty, failure == nil else { throw CheckFailure() }
            seek(to: 0)
            toggle()
            try await Task.sleep(for: .seconds(3))
            sync()
            let advanced = position
            guard isPlaying, advanced > 1 else { throw CheckFailure() }
            toggle()
            let paused = position
            try await Task.sleep(for: .seconds(1))
            sync()
            let drift = abs(position - paused)
            guard !isPlaying, drift < 0.05 else { throw CheckFailure() }
            let target = duration * 0.6
            seek(to: target)
            guard abs(position - target) < 0.1 else { throw CheckFailure() }
            toggle()
            try await Task.sleep(for: .seconds(2))
            sync()
            guard isPlaying, position > target + 1 else { throw CheckFailure() }
            stop()
            let report: [String: Any] = ["result": "complete", "duration": duration,
                                        "advanced": advanced, "pausedDrift": drift,
                                        "seekTarget": target, "resumedPosition": position,
                                        "envelopeBins": levels.count, "source": "AVAudioPlayer.currentTime"]
            let data = try JSONSerialization.data(withJSONObject: report, options: .prettyPrinted)
            try data.write(to: reportURL)
        } catch {
            let data = try? JSONSerialization.data(withJSONObject:
                ["result": "failed", "reason": failure ?? error.localizedDescription])
            try? data?.write(to: reportURL)
        }
    }
    private struct CheckFailure: Error { }
}
