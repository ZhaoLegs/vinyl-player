// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VinylLyrics",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "LyricsCore", path: "Vinyl/Vinyl",
                exclude: ["AppleMusicStore.swift", "AppleMusicViews.swift", "Assets.xcassets",
                          "Components", "ContentView.swift", "DesignTokens.swift", "Info.plist",
                          "Model.swift", "RelatedAlbums.swift", "Resources", "Views",
                          "VinylApp.swift", "Waveform.swift"],
                sources: ["LyricsData.swift"]),
        .testTarget(name: "LyricsCoreTests", dependencies: ["LyricsCore"]),
        .executableTarget(name: "LyricsLiveChecks", dependencies: ["LyricsCore"],
                          path: "scripts", exclude: ["check_preview.py", "record_native.py",
                          "record_phone_preview.py", "record_preview.py"],
                          sources: ["LyricsLiveChecks.swift"])
    ]
)
