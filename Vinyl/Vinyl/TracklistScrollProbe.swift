import SwiftUI
import MusicKit
import os.signpost
import Combine

/// Only enabled by an explicit launch argument on the simulator.
enum TracklistProfile {
    static let enabled: Bool = {
        #if targetEnvironment(simulator)
        return ProcessInfo.processInfo.arguments.contains("--profile-tracklist")
        #else
        return false
        #endif
    }()
    @MainActor static var measuring = false
    @MainActor static var counts: [String: Int] = [:]
    @MainActor static func count(_ name: String) {
        guard enabled, measuring else { return }
        counts[name, default: 0] += 1
    }
    static let songs: [Song] = (0..<160).map { i in
        decode(Song.self, [
            "id": "tracklist-perf-\(i)", "type": "songs",
            "attributes": [
                "name": i.isMultiple(of: 2) ? "测试歌曲 \(i + 1)" : "Track \(i + 1)",
                "artistName": "Vinyl performance fixture",
                "albumName": "Tracklist performance fixture",
                "durationInMillis": (180 + i) * 1000,
                "playParams": ["id": "tracklist-perf-\(i)", "kind": "song"]
            ]
        ])
    }
    static let collection = MusicCollection.playlist(decode(Playlist.self, [
        "id": "tracklist-perf-160", "type": "playlists",
        "attributes": [
            "name": "Tracklist performance fixture — 160 songs",
            "curatorName": "Synthetic MusicKit data", "canEdit": false,
            "isChart": false, "playlistType": "user-shared"
        ]
    ]))
    private static func decode<T: Decodable>(_ type: T.Type, _ json: [String: Any]) -> T {
        do { return try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: json)) }
        catch { preconditionFailure("Invalid profiling fixture: \(error)") }
    }

    @MainActor static func verify(_ music: AppleMusicStore) {
        guard enabled, ProcessInfo.processInfo.arguments.contains("--verify-tracklist") else { return }
        music.profilePlayback(time: 30)
        var storeChanges = 0, clockChanges = 0
        let storeToken = music.objectWillChange.sink { storeChanges += 1 }
        let clockToken = music.timeline.objectWillChange.sink { clockChanges += 1 }
        music.profilePlayback(time: 31)
        music.profilePlayback(time: 31)
        music.profilePlayback(time: 32)
        let isolatedRealClock = storeChanges == 0 && clockChanges == 2 && music.position == 32
        music.seekDemo(-1); music.seekDemo(2)
        let isolatedDemoClock = storeChanges == 0 && clockChanges == 4 && music.demoElapsed == AppleMusicStore.demoDuration

        let models = TrackRows()
        models.prepare(songs)
        let idsAndText = models.rows.map(\.id) == songs.map(\.id)
            && models.rows[0].time == "3:00" && models.rows[159].time == "5:39"
            && models.rows.allSatisfy { $0.title == "\($0.song.artistName) - \($0.song.title)" && $0.playable }
        let sideLabels = models.rows.enumerated().allSatisfy {
            $0.element.side == ($0.offset == 0 ? "A" : ($0.offset == 80 ? "B" : ""))
        }
        var modelChanges = 0
        let modelToken = models.objectWillChange.sink { modelChanges += 1 }
        models.prepare(songs)
        let unchangedQueue = modelChanges == 0
        models.prepare(Array(songs.reversed()))
        let reorder = modelChanges == 1 && models.rows.first?.id == songs.last?.id
            && models.rows.first?.side == "A" && models.rows[80].side == "B"
        models.prepare([])
        let cleared = modelChanges == 2 && models.rows.isEmpty

        let fade = DetailScrollEnd()
        var fadeChanges = 0
        let fadeToken = fade.objectWillChange.sink { fadeChanges += 1 }
        fade.update(0); fade.update(0.5); fade.update(0.5); fade.update(1)
        let checks: [String: Bool] = [
            "realClockDoesNotPublishPage": isolatedRealClock,
            "demoClockDoesNotPublishPageAndSeekClamps": isolatedDemoClock,
            "currentSongIdentityMatchesOnlySelectedSong": music.isCurrent(songs[0]) && !music.isCurrent(songs[1]),
            "stableIDsAndPreformattedText": idsAndText,
            "sideABMatchesOriginal": sideLabels,
            "unchangedQueueDoesNotRebuild": unchangedQueue,
            "queueReorderUpdatesIDsAndSides": reorder,
            "emptyQueueClearsModels": cleared,
            "fadeSuppressesDuplicateWrites": fadeChanges == 2,
            "fadeCurveUnchanged": (-20...180).allSatisfy {
                ScrollEndProximity.proximity(distance: CGFloat($0), range: 140)
                    == min(1, max(0, 1 - CGFloat($0) / 140))
            },
            "lastRowGap24pt": TrackInset.bottomPadding(listBottom: 700, barTop: 700) == 24
                && TrackInset.bottomPadding(listBottom: 0, barTop: 0) == 24
                && TrackInset.bottomPadding(listBottom: 680, barTop: 700) == 4
        ]
        withExtendedLifetime((storeToken, clockToken, modelToken, fadeToken)) {}
        let result: [String: Any] = ["passed": checks.values.allSatisfy { $0 }, "checks": checks]
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            try? data.write(to: documents.appendingPathComponent("profile-verification.json"), options: .atomic)
        }
    }
}

struct TracklistProfileView: View {
    @EnvironmentObject private var music: AppleMusicStore
    var body: some View {
        AlbumDetailView(collection: TracklistProfile.collection, songs: TracklistProfile.songs,
                        title: TracklistProfile.collection.title, artist: TracklistProfile.collection.artist,
                        pull: 1, flip: 0, waveProgress: 1, contentAlpha: 1, zoom: 1,
                        isPresented: true, landed: true, keepsSpinning: true,
                        motionStart: .now, onClose: {}, onToggleArtwork: {})
            .background(TracklistScrollProbe(music: music))
            .task { TracklistProfile.verify(music) }
    }
}

struct TracklistScrollProbe: UIViewRepresentable {
    let music: AppleMusicStore
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        context.coordinator.install(view, music: music)
        return view
    }
    func updateUIView(_ uiView: UIView, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator() }
    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) { coordinator.stop() }

    @MainActor final class Coordinator: NSObject {
        private weak var view: UIView?
        private weak var music: AppleMusicStore?
        private weak var scroll: UIScrollView?
        private var timer: Timer?
        private var link: CADisplayLink?
        private var started = false
        private var start = 0.0
        private var previous = 0.0
        private var samples: [Double] = []
        private var budgets: [Double] = []
        private var initialCPU = 0.0
        private var clock = 30.0
        private let log = OSLog(subsystem: "com.zhaolegs.Vinyl", category: .pointsOfInterest)
        private var documents: URL {
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        }
        func install(_ view: UIView, music: AppleMusicStore) {
            self.view = view; self.music = music
            timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                // The timer is installed on the main run loop.
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.clock += 0.25
                    self.music?.profilePlayback(time: self.clock)
                    guard !self.started,
                          FileManager.default.fileExists(atPath: self.documents.appendingPathComponent("profile-start").path),
                          let window = self.view?.window, let scroll = self.findScroll(window) else { return }
                    self.started = true; self.scroll = scroll
                    scroll.setContentOffset(CGPoint(x: 0, y: -scroll.adjustedContentInset.top), animated: false)
                    let link = CADisplayLink(target: self, selector: #selector(self.tick(_:)))
                    link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
                    self.link = link
                    os_signpost(.begin, log: self.log, name: "TracklistScroll")
                    link.add(to: .main, forMode: .common)
                }
            }
        }
        private func findScroll(_ root: UIView) -> UIScrollView? {
            if let s = root as? UIScrollView, s.contentSize.height > s.bounds.height + 100 { return s }
            for child in root.subviews { if let s = findScroll(child) { return s } }
            return nil
        }
        @objc private func tick(_ link: CADisplayLink) {
            let now = CACurrentMediaTime()
            if start == 0 {
                start = now; previous = now; initialCPU = mainCPU()
                TracklistProfile.counts = [:]; TracklistProfile.measuring = true
                return
            }
            let elapsed = now - start
            samples.append(now - previous); budgets.append(link.targetTimestamp - link.timestamp)
            previous = now
            guard elapsed < 10, let scroll else { finish(elapsed); return }
            let top = -scroll.adjustedContentInset.top
            let bottom = max(top, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
            let distance = max(1, bottom - top)
            let phase = (CGFloat(elapsed) * 1200).truncatingRemainder(dividingBy: 2 * distance)
            scroll.setContentOffset(CGPoint(x: 0, y: top + (phase < distance ? phase : 2 * distance - phase)), animated: false)
        }
        private func finish(_ elapsed: Double) {
            let cpu = mainCPU() - initialCPU
            TracklistProfile.measuring = false
            os_signpost(.end, log: log, name: "TracklistScroll")
            stop()
            let sorted = samples.sorted(), budget = budgets.sorted()[budgets.count / 2]
            let late = samples.filter { $0 > budget * 1.5 }
            let result: [String: Any] = [
                "playlist": TracklistProfile.collection.title, "songCount": TracklistProfile.songs.count,
                "seconds": elapsed, "speedPointsPerSecond": 1200, "callbacks": samples.count,
                "frameBudgetMS": budget * 1000, "lateCallbackCount": late.count,
                "lateCallbackExcessMS": late.reduce(0) { $0 + max(0, $1 - budget) } * 1000,
                "p95CallbackMS": sorted[Int(Double(sorted.count - 1) * 0.95)] * 1000,
                "maxCallbackMS": (sorted.last ?? 0) * 1000,
                "mainThreadCPUMS": cpu * 1000, "viewEvaluations": TracklistProfile.counts,
                "note": "Synthetic MusicKit fixture; CADisplayLink lateness is a scheduling proxy, NOT an official render hitch."
            ]
            if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: documents.appendingPathComponent("profile-result.json"), options: .atomic)
            }
        }
        private func mainCPU() -> Double {
            var info = thread_basic_info()
            var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    thread_info(pthread_mach_thread_np(pthread_self()), thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
                }
            }
            guard result == KERN_SUCCESS else { return .nan }
            return Double(info.user_time.seconds + info.system_time.seconds)
                + Double(info.user_time.microseconds + info.system_time.microseconds) / 1_000_000
        }
        func stop() { link?.invalidate(); link = nil; timer?.invalidate(); timer = nil }
    }
}
