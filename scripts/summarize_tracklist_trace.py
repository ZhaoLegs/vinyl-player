#!/usr/bin/env python3
"""Summarize main-thread sample weights within the TracklistScroll signpost."""
import argparse
from collections import Counter
import json
from pathlib import Path
import subprocess
import xml.etree.ElementTree as ET


def export(directory, schema):
    output = directory / (schema + ".xml")
    subprocess.run([
        "xcrun", "xctrace", "export", "--input", str(directory / "scroll.trace"),
        "--xpath", f'/trace-toc/run[@number="1"]/data/table[@schema="{schema}"]',
        "--output", str(output)
    ], check=True)
    root = ET.parse(output).getroot()
    ids = {node.get("id"): node for node in root.iter() if node.get("id")}
    def resolve(node):
        return ids[node.get("ref")] if node.get("ref") else node
    return root, resolve


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("directory", type=Path)
    args = parser.parse_args()
    root, resolve = export(args.directory, "os-signpost")
    intervals = {}
    for row in root.iter("row"):
        columns = list(row)
        if len(columns) < 7 or resolve(columns[6]).text != "TracklistScroll":
            continue
        intervals[resolve(columns[3]).text] = int(resolve(columns[0]).text)
    start, end = intervals["Begin"], intervals["End"]
    root, resolve = export(args.directory, "time-profile")
    inclusive = Counter()
    leaves = Counter()
    main_weight = 0
    sample_count = 0
    for row in root.iter("row"):
        columns = list(row)
        timestamp = int(resolve(columns[0]).text)
        if not start <= timestamp <= end or "Main Thread" not in resolve(columns[1]).get("fmt", ""):
            continue
        weight = int(resolve(columns[5]).text)
        frames = [resolve(frame) for frame in resolve(columns[6]).iter("frame")]
        main_weight += weight
        sample_count += 1
        for name in {frame.get("name", "") for frame in frames}:
            inclusive[name] += weight
        if frames:
            leaves[frames[0].get("name", "")] += weight
    app_frames = [(name, weight) for name, weight in inclusive.most_common()
                  if any(token in name for token in ("AlbumDetailView", "TrackRows", "TrackRowLabel",
                                                     "DetailWaveform", "DetailBottomFade"))]
    result = {
        "intervalSeconds": (end - start) / 1e9,
        "mainThreadSamples": sample_count,
        "mainThreadSampleWeightMS": main_weight / 1e6,
        "appInclusiveSampleWeightMS": {name: weight / 1e6 for name, weight in app_frames},
        "topLeafSampleWeightMS": {name: weight / 1e6 for name, weight in leaves.most_common(20)},
        "note": "Sample weights are statistical attribution; inclusive frames overlap and must not be added."
    }
    destination = args.directory / "stacks-summary.json"
    destination.write_text(json.dumps(result, ensure_ascii=False, indent=2))
    print(destination.read_text())


if __name__ == "__main__":
    main()
