#!/usr/bin/env python3
"""Summarize Time Profiler samples inside the app's GridScroll signpost."""
import argparse
from collections import Counter
import json
from pathlib import Path
import re
import subprocess
import xml.etree.ElementTree as ET


def indexed(path):
    root = ET.parse(path).getroot()
    ids = {node.attrib["id"]: node for node in root.iter() if "id" in node.attrib}

    def resolve(node):
        return ids[node.attrib["ref"]] if "ref" in node.attrib else node
    return root, resolve


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("directory", type=Path)
    parser.add_argument("--pid", type=int, help="Resolve hotspot symbols in the same still-running process.")
    args = parser.parse_args()
    intervals, resolve = indexed(args.directory / "intervals.xml")
    interval = next(row for row in intervals.findall(".//row") if resolve(row[3]).text == "GridScroll")
    start = int(resolve(interval[0]).text)
    duration = int(resolve(interval[1]).text)
    root, resolve = indexed(args.directory / "time-profile.xml")
    stacks = []
    for row in root.findall(".//row"):
        time = int(resolve(row[0]).text)
        thread = resolve(row[1]).attrib.get("fmt", "")
        if not (start <= time <= start + duration) or "Main Thread" not in thread:
            continue
        if resolve(row[4]).text != "Running":
            continue
        if args.pid and f"pid: {args.pid}" not in thread:
            raise RuntimeError("The symbolication PID does not match the recorded process.")
        frames = resolve(row[6])
        addresses = [resolve(frame).attrib["addr"] for frame in frames]
        stacks.append((int(resolve(row[5]).text), addresses))
    if not stacks:
        raise RuntimeError("No running main-thread samples in the GridScroll interval.")
    total = sum(weight for weight, _ in stacks)
    result = {
        "scrollStartSeconds": start / 1e9, "scrollDurationSeconds": duration / 1e9,
        "mainRunningSamples": len(stacks), "mainSampleWeightMS": total / 1e6,
        "weightDefinition": "Statistical sample weight; not an exact CPU duration. See frames.json for Mach thread CPU time."
    }
    if args.pid:
        inclusive = Counter()
        leaves = Counter()
        for weight, addresses in stacks:
            inclusive.update({address: weight for address in set(addresses)})
            if addresses:
                leaves[addresses[0]] += weight
        addresses = list(dict.fromkeys(
            [address for address, _ in inclusive.most_common(150)]
            + [address for address, _ in leaves.most_common(60)]
        ))
        if any(not re.fullmatch(r"0x[0-9a-fA-F]+", address) for address in addresses):
            raise RuntimeError("Unexpected address format.")
        output = subprocess.check_output(
            ["xcrun", "atos", "-p", str(args.pid), "-arch", "arm64", *addresses], text=True
        ).splitlines()
        if len(output) != len(addresses):
            raise RuntimeError("The symbol resolver returned an unexpected number of lines.")
        names = {address: symbol.split(" (in ")[0] for address, symbol in zip(addresses, output)
                 if not symbol.startswith("0x")}
        calls = Counter()
        for weight, stack in stacks:
            for name in {names[address] for address in stack if address in names}:
                calls[name] += weight
        skip = re.compile(r"^(start|main$|static App\.main|runApp|closure #1 in KitRenderer|UIApplicationMain|-\[UIApplication|GSEvent|_+CF|UC::DriverCore|schedulerStep|_UIUpdateSequence|CA::Display)")
        result["hotspots"] = [
            {"symbol": name, "inclusiveWeightMS": weight / 1e6, "mainSamplePercent": weight / total * 100}
            for name, weight in calls.most_common() if not skip.search(name)
        ][:20]
        result["hotspotDefinition"] = "Includes callees; rows overlap and must not be added together."
    destination = args.directory / "cpu-summary.json"
    destination.write_text(json.dumps(result, ensure_ascii=False, indent=2))
    print(destination.read_text())


if __name__ == "__main__":
    main()
