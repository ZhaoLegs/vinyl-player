#!/usr/bin/env python3
"""Compile the App's cover resolver and run the Swift verification tool."""
import argparse
import pathlib
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--self-check", action="store_true", help="Offline regression checks")
parser.add_argument("--baseline", action="store_true", help="Reproduce Build 150 using its original source")
args = parser.parse_args()

with tempfile.TemporaryDirectory(prefix="vinyl-covers-") as directory:
    work = pathlib.Path(directory)
    if args.baseline:
        old = subprocess.check_output(
            ["git", "show", "b0cb873:Vinyl/Vinyl/AppleMusicViews.swift"],
            cwd=ROOT, text=True,
        )
        query = old[old.index("struct OfficialCoverQuery:"):old.index("extension MusicCollection")]
        store = old[old.index("final class OfficialCoverStore:"):]
        store = store.replace(
            "FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]",
            'URL(fileURLWithPath: CommandLine.arguments[1])',
        )
        stub = """
import Foundation
import ImageIO
struct UIImage: Sendable {}
final class ArtworkCache: Sendable {
    static let shared = ArtworkCache()
    func cached(_ key: String) -> UIImage? { nil }
    func image(for url: URL) async -> UIImage? {
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  CGImageSourceGetCount(source) > 0 else { return nil }
            return UIImage()
        } catch { print("IMAGE ERROR: \\(error)"); return nil }
    }
}
"""
        driver = """
@main struct Check {
    static func main() async {
        let samples = [
            ("周杰伦", "十一月的萧邦"), ("孙燕姿", "Stefanie"),
            ("Charlie Puth", "Nine Track Mind"), ("五月天", "自传"),
            ("Taylor Swift", "1989"), ("毛不易", "平凡的一天")
        ]
        var hits = 0
        for (artist, title) in samples {
            let image = await OfficialCoverStore.shared.image(for:
                .init(id: artist + title, title: title, artist: artist))
            hits += image == nil ? 0 : 1
            print("\\(image == nil ? "MISS" : "HIT") \\(artist)《\\(title)》")
        }
        print("BASELINE \\(hits)/6 = \\(Double(hits) / 6 * 100)%")
        if hits < 5 { exit(1) }
    }
}
"""
        source = work / "baseline.swift"
        source.write_text(stub + query + store + driver)
        sources = [source]
    else:
        sources = [
            ROOT / "Vinyl/Vinyl/OfficialCoverLookup.swift",
            ROOT / "scripts/official_covers_check.swift",
        ]
    binary = work / "check"
    subprocess.run(
        ["xcrun", "swiftc", "-swift-version", "5", "-parse-as-library",
         *map(str, sources), "-o", str(binary)],
        check=True, cwd=ROOT,
    )
    mode = "--self-check" if args.self_check and not args.baseline else "--live"
    result = subprocess.run([str(binary), str(work / "cache"), mode], cwd=ROOT)
    raise SystemExit(result.returncode)
