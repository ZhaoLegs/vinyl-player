#!/usr/bin/env python3
"""Export Build 154 with only the same opt-in fixture/probe used by the optimized app."""
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "build/ProfileBaseline"
REVISION = "2c19982"


def replace(path, old, new):
    text = path.read_text()
    if old not in text:
        raise RuntimeError(f"Baseline anchor missing in {path}: {old!r}")
    path.write_text(text.replace(old, new, 1))


def main():
    if OUTPUT.exists():
        raise SystemExit(f"{OUTPUT} already exists; keep it or choose a fresh output directory.")
    OUTPUT.mkdir(parents=True)
    archive = subprocess.Popen(["git", "archive", REVISION], cwd=ROOT, stdout=subprocess.PIPE)
    subprocess.run(["tar", "-x", "-C", str(OUTPUT)], stdin=archive.stdout, check=True)
    archive.stdout.close()
    if archive.wait():
        raise RuntimeError("git archive failed")
    source = OUTPUT / "Vinyl/Vinyl"
    shutil.copy2(ROOT / "Vinyl/Vinyl/GridScrollProbe.swift", source / "GridScrollProbe.swift")
    replace(source / "AppleMusicStore.swift", "= HomeCache.load()",
            "= GridScrollProfile.collections() ?? HomeCache.load()")
    replace(source / "VinylApp.swift", "scenePhase == .active, !recordingDemo",
            "scenePhase == .active, !recordingDemo, !GridScrollProfile.enabled")
    library = source / "Views/LibraryView.swift"
    replace(library, "    var body: some View {",
            '    var body: some View {\n        let _ = GridScrollProfile.recordUpdate(overlayMode ? "LibraryView.overlay" : "LibraryView.home")')
    replace(library, ".task(id: music.collections.first?.id) {",
            ".task(id: music.collections.first?.id) {\n                    guard !GridScrollProfile.enabled else { return }")
    replace(library, '.coordinateSpace(name: "library")',
            '.coordinateSpace(name: "library")\n            .background { if GridScrollProfile.enabled { GridScrollProbe(music: music) } }')
    replace(source / "Views/AlbumDetailView.swift", "    var body: some View {",
            '    var body: some View {\n        let _ = GridScrollProfile.recordUpdate("AlbumDetailView")')
    artwork = source / "AppleMusicViews.swift"
    replace(artwork, "        let shown = officialImage",
            '        let _ = GridScrollProfile.recordUpdate("CachedArtwork")\n        let shown = officialImage')
    replace(artwork, "func image(for q: OfficialCoverQuery) async -> UIImage? {",
            "func image(for q: OfficialCoverQuery) async -> UIImage? {\n        guard !GridScrollProfile.enabled else { return nil }")
    replace(artwork, "func prefetch(_ items: [OfficialCoverQuery]) {",
            "func prefetch(_ items: [OfficialCoverQuery]) {\n        guard !GridScrollProfile.enabled else { return }")
    project = OUTPUT / "Vinyl/Vinyl.xcodeproj/project.pbxproj"
    replace(project, "/* Begin PBXBuildFile section */",
            "/* Begin PBXBuildFile section */\nAB10000000000000000000E1 = {isa = PBXBuildFile; fileRef = AB10000000000000000000E2; };")
    replace(project, "/* Begin PBXFileReference section */",
            '/* Begin PBXFileReference section */\nAB10000000000000000000E2 = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = GridScrollProbe.swift; sourceTree = "<group>"; };')
    replace(project, "children = (\n\t\t\t\tAB1000000000000000000002",
            "children = (\n\t\t\t\tAB10000000000000000000E2,\n\t\t\t\tAB1000000000000000000002")
    replace(project, "files = (\n\t\t\t\tAB1000000000000000000001",
            "files = (\n\t\t\t\tAB10000000000000000000E1,\n\t\t\t\tAB1000000000000000000001")
    print(f"Exported {REVISION} to {OUTPUT}; build with SWIFT_ACTIVE_COMPILATION_CONDITIONS=PERF_BASELINE.")


if __name__ == "__main__":
    main()
