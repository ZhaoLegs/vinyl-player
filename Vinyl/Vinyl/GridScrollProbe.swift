import SwiftUI
import MusicKit
import os.signpost
import Combine

/// Opt-in simulator fixture; never participates in a device build or normal launch.
enum GridScrollProfile {
    @MainActor static var measuring = false
    @MainActor static var viewUpdates: [String: Int] = [:]
    @MainActor static func recordUpdate(_ name: String) {
        guard enabled, measuring else { return }
        viewUpdates[name, default: 0] += 1
    }
    static let enabled: Bool = {
        #if targetEnvironment(simulator)
        return ProcessInfo.processInfo.arguments.contains("--profile-grid")
        #else
        return false
        #endif
    }()

    static func collections() -> [MusicCollection]? {
        guard enabled else { return nil }
        return (0..<240).compactMap { index in
            let json: [String: Any] = [
                "id": "perf-\(index)", "type": "albums",
                "attributes": [
                    "name": "Grid \(index)", "artistName": "Vinyl performance fixture",
                    "artwork": [
                        "width": 960, "height": 960,
                        "url": "http://127.0.0.1:18765/cover/\(index)/{w}x{h}.jpg"
                    ],
                    "trackCount": 1, "isSingle": false, "isComplete": true
                ]
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: json),
                  let album = try? JSONDecoder().decode(Album.self, from: data) else { return nil }
            return .album(album, catalog: false)
        }
    }

    #if !PERF_BASELINE
    @MainActor static func verify(_ music: AppleMusicStore) async {
        let url = URL(string: "http://127.0.0.1:18765/cover/900/960x960.jpg")!
        async let small = ArtworkCache.shared.image(for: url, pixelSize: 230)
        async let large = ArtworkCache.shared.image(for: url, pixelSize: 960)
        let (thumbnail, detail) = await (small, large)
        let rectangle = await ArtworkCache.shared.image(
            for: URL(string: "http://127.0.0.1:18765/rectangle.jpg")!, pixelSize: 230)
        let images = await withTaskGroup(of: UIImage?.self, returning: [UIImage?].self) { group in
            for _ in 0..<12 {
                group.addTask { await ArtworkCache.shared.image(for: url, pixelSize: 230) }
            }
            var result: [UIImage?] = []
            for await image in group { result.append(image) }
            return result
        }
        var storeChanges = 0, clockChanges = 0, geometryChanges = 0
        let storeSubscription = music.objectWillChange.sink { storeChanges += 1 }
        let clockSubscription = music.timeline.objectWillChange.sink { clockChanges += 1 }
        let zoom = LibraryZoomModel()
        let geometrySubscription = zoom.objectWillChange.sink { geometryChanges += 1 }
        music.seekDemo(0.2); music.seekDemo(0.3)
        zoom.gridGeometry.cellFrames = [1000: CGRect(x: 21, y: 80, width: 76.5, height: 76.5)]
        let checks: [String: Bool] = [
            "thumbnail230px": thumbnail?.cgImage?.width == 230 && thumbnail?.cgImage?.height == 230,
            "rectangleShortEdge230px": rectangle?.cgImage?.width == 460 && rectangle?.cgImage?.height == 230,
            "detail960px": detail?.cgImage?.width == 960 && detail?.cgImage?.height == 960,
            "sizeVariantsDistinct": thumbnail !== detail,
            "sameSourcePreviewAvailable": ArtworkCache.shared.cachedPreview(for: url) != nil,
            "concurrentMemoryRequestsShareImage": images.count == 12 && images.allSatisfy { $0 === thumbnail },
            "clockDoesNotPublishLibrary": storeChanges == 0 && clockChanges == 2,
            "geometryDoesNotPublishZoom": geometryChanges == 0 && zoom.gridGeometry.cellFrames[1000] != nil
        ]
        withExtendedLifetime((storeSubscription, clockSubscription, geometrySubscription)) {}
        let result: [String: Any] = ["passed": checks.values.allSatisfy { $0 }, "checks": checks]
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            try? data.write(to: documents.appendingPathComponent("profile-verification.json"), options: .atomic)
            print("[perf-verification] \(String(decoding: data, as: UTF8.self))")
        }
    }
    #endif
}

struct GridScrollProbe: UIViewRepresentable {
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

    @MainActor
    final class Coordinator: NSObject {
        private weak var view: UIView?
        private weak var music: AppleMusicStore?
        private weak var scroll: UIScrollView?
        private var timer: Timer?
        private var link: CADisplayLink?
        private var started = false
        private var start = 0.0
        private var previous = 0.0
        private var samples: [Double] = []
        private var expected: [Double] = []
        private var contentHeight: CGFloat = 0
        private var startingCPU = 0.0
        private let log = OSLog(subsystem: "com.zhaolegs.Vinyl", category: .pointsOfInterest)
        private var documents: URL {
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        }

        func install(_ view: UIView, music: AppleMusicStore) {
            self.view = view; self.music = music
            timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                guard let self else { return }
                // Match the existing playback clock's 4 Hz publication while browsing.
                self.music?.seekDemo((self.music?.demoElapsed ?? 0) / AppleMusicStore.demoDuration + 0.0005)
                guard !self.started,
                      FileManager.default.fileExists(atPath: self.documents.appendingPathComponent("profile-start").path),
                      let window = self.view?.window,
                      let scroll = self.findScroll(window),
                      scroll.contentSize.height > scroll.bounds.height else { return }
                self.started = true; self.scroll = scroll
                self.contentHeight = scroll.contentSize.height
                scroll.setContentOffset(CGPoint(x: 0, y: -scroll.adjustedContentInset.top), animated: false)
                let link = CADisplayLink(target: self, selector: #selector(self.tick(_:)))
                link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
                self.link = link
                os_signpost(.begin, log: self.log, name: "GridScroll")
                link.add(to: .main, forMode: .common)
            }
        }

        private func findScroll(_ root: UIView) -> UIScrollView? {
            if let scroll = root as? UIScrollView,
               scroll.contentSize.height > scroll.bounds.height + 100 { return scroll }
            for child in root.subviews {
                if let found = findScroll(child) { return found }
            }
            return nil
        }

        @objc private func tick(_ link: CADisplayLink) {
            let now = CACurrentMediaTime()
            if start == 0 {
                start = now; previous = now
                startingCPU = mainThreadCPU()
                GridScrollProfile.viewUpdates = [:]
                GridScrollProfile.measuring = true
                return
            }
            let elapsed = now - start
            samples.append(now - previous)
            expected.append(link.targetTimestamp - link.timestamp)
            previous = now
            guard elapsed < 18, let scroll else { finish(elapsed); return }
            let top = -scroll.adjustedContentInset.top
            let bottom = max(top, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
            let distance = max(1, bottom - top)
            let travel = CGFloat(elapsed) * 1200
            let phase = travel.truncatingRemainder(dividingBy: 2 * distance)
            let offset = top + (phase < distance ? phase : 2 * distance - phase)
            scroll.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
        }

        private func finish(_ elapsed: Double) {
            let cpu = mainThreadCPU() - startingCPU
            GridScrollProfile.measuring = false
            os_signpost(.end, log: log, name: "GridScroll")
            link?.invalidate(); link = nil
            timer?.invalidate(); timer = nil
            let sorted = samples.sorted()
            let budget = expected.sorted()[expected.count / 2]
            let missed = samples.reduce(0) { $0 + max(0, Int(($1 / budget).rounded()) - 1) }
            let result: [String: Any] = [
                "seconds": elapsed, "callbacks": samples.count,
                "callbackFPS": Double(samples.count) / elapsed,
                "frameBudgetMS": budget * 1000,
                "lateCallbackPercent": Double(samples.filter { $0 > budget * 1.5 }.count) / Double(samples.count) * 100,
                "estimatedMissedRefreshPercent": Double(missed) / Double(samples.count + missed) * 100,
                "p95CallbackMS": sorted[Int(Double(sorted.count - 1) * 0.95)] * 1000,
                "maxCallbackMS": sorted.last! * 1000,
                "contentHeight": Double(contentHeight), "speedPointsPerSecond": 1200,
                "collectionCount": 240,
                "mainThreadCPUMS": cpu * 1000,
                "mainThreadCPUPercent": cpu / elapsed * 100,
                "viewBodyUpdates": GridScrollProfile.viewUpdates,
                "note": "CADisplayLink scheduling proxy, not compositor FPS or Animation Hitches ratio"
            ]
            if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: documents.appendingPathComponent("profile-result.json"), options: .atomic)
                print("[perf-grid] \(String(decoding: data, as: UTF8.self))")
            }
        }

        private func mainThreadCPU() -> Double {
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

        func stop() {
            link?.invalidate(); timer?.invalidate()
        }
    }
}

// MARK: - t397u `--profile-disc` (simulator only)

/// Opens the featured demo album (demo mode → disc spinning), waits 10s for the open / pull-out to settle, then
/// measures a fixed 20s window: SwiftUI body counts of the disc views, process + main-thread CPU, and CADisplayLink
/// callback lateness (a scheduling proxy, not an official render hitch). Writes Documents/disc-profile.json.
enum DiscProfile {
    static let enabled: Bool = {
        #if targetEnvironment(simulator)
        return ProcessInfo.processInfo.arguments.contains("--profile-disc")
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

    static func processCPU() -> Double {
        var u = rusage(); getrusage(RUSAGE_SELF, &u)
        return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6
    }
    /// call on the main thread
    static func threadCPU() -> Double {
        var info = thread_basic_info()
        var n = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
        let port = mach_thread_self()
        defer { mach_port_deallocate(mach_task_self_, port) }
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(n)) { thread_info(port, thread_flavor_t(THREAD_BASIC_INFO), $0, &n) }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        return Double(info.user_time.seconds + info.system_time.seconds)
            + Double(info.user_time.microseconds + info.system_time.microseconds) / 1e6
    }
    static func residentMB() -> Double {
        var info = task_vm_info_data_t()
        var n = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(n)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &n) }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }

    @MainActor private final class Link: NSObject {
        var last: CFTimeInterval = 0
        var intervals: [Double] = []
        var link: CADisplayLink?
        func start() {
            let l = CADisplayLink(target: self, selector: #selector(tick(_:)))
            l.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
            l.add(to: .main, forMode: .common); link = l
        }
        @objc func tick(_ l: CADisplayLink) {
            if last > 0 { intervals.append(l.timestamp - last) }
            last = l.timestamp
        }
    }

    @MainActor static func run() async {
        try? await Task.sleep(nanoseconds: 10_000_000_000)
        counts = [:]
        let link = Link(); link.start()
        let p0 = processCPU(), m0 = threadCPU(), t0 = CACurrentMediaTime()
        measuring = true
        try? await Task.sleep(nanoseconds: 20_000_000_000)
        measuring = false
        let wall = CACurrentMediaTime() - t0, p1 = processCPU(), m1 = threadCPU()
        link.link?.invalidate()
        let iv = link.intervals.sorted()
        let budget = 1.0 / 60
        let late = link.intervals.filter { $0 > budget * 1.5 }
        let json: [String: Any] = [
            "windowS": wall,
            "processCPUms": (p1 - p0) * 1000,
            "mainThreadCPUms": (m1 - m0) * 1000,
            "mainThreadCPUPercent": (m1 - m0) / wall * 100,
            "footprintMB": residentMB(),
            "displayLinkCallbacks": link.intervals.count,
            "lateCallbacks": late.count,
            "lateExcessMs": late.reduce(0) { $0 + ($1 - budget) } * 1000,
            "intervalP95ms": iv.isEmpty ? 0 : iv[Int(Double(iv.count - 1) * 0.95)] * 1000,
            "intervalMaxMs": (iv.last ?? 0) * 1000,
            "bodyCounts": counts,
        ]
        if let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
           let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: folder.appendingPathComponent("disc-profile.json"))
        }
    }
}
