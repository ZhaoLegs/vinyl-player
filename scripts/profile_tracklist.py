#!/usr/bin/env python3
"""Measure the opt-in 160-song fixture for ten seconds after Instruments starts."""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import threading

BUNDLE = "com.zhaolegs.Vinyl"


def run(*args):
    return subprocess.run(args, check=True, text=True, capture_output=True).stdout.strip()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--device", required=True)
    parser.add_argument("--app", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--template", default="SwiftUI")
    parser.add_argument("--instrument", action="append", default=[])
    args = parser.parse_args()
    output = Path(args.output)
    output.mkdir(parents=True, exist_ok=False)
    run("xcrun", "simctl", "install", args.device, args.app)
    documents = Path(run("xcrun", "simctl", "get_app_container", args.device, BUNDLE, "data")) / "Documents"
    documents.mkdir(exist_ok=True)
    for name in ("profile-start", "profile-result.json"):
        (documents / name).unlink(missing_ok=True)
    subprocess.run(["xcrun", "simctl", "terminate", args.device, BUNDLE], capture_output=True)
    pid = run("xcrun", "simctl", "launch", args.device, BUNDLE, "--profile-tracklist").rsplit(":", 1)[1].strip()
    command = [
        "xcrun", "xctrace", "record", "--template", args.template,
        "--instrument", "Points of Interest", "--device", args.device, "--attach", pid,
        "--time-limit", "18s", "--output", str(output / "scroll.trace"), "--no-prompt"
    ]
    for instrument in args.instrument:
        command[5:5] = ["--instrument", instrument]
    (output / "command.json").write_text(json.dumps(command, indent=2))
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1)
    watchdog = threading.Timer(75, process.terminate)
    watchdog.start()
    began = False
    with (output / "recording.log").open("w") as log:
        for line in process.stdout:
            print(line, end="", flush=True)
            log.write(line); log.flush()
            if ("Recording started" in line or "Ctrl-C to stop" in line) and not began:
                began = True
                run("xcrun", "simctl", "io", args.device, "screenshot", str(output / "start.png"))
                (documents / "profile-start").touch()
        code = process.wait()
    watchdog.cancel()
    result = documents / "profile-result.json"
    if result.exists():
        shutil.copy2(result, output / "frames.json")
        print(result.read_text(), flush=True)
        run("xcrun", "simctl", "io", args.device, "screenshot", str(output / "end.png"))
    if code or not began or not result.exists():
        raise SystemExit(f"Recording incomplete: exit={code}, started={began}, result={result.exists()}")
    run("xcrun", "xctrace", "export", "--input", str(output / "scroll.trace"),
        "--toc", "--output", str(output / "toc.xml"))


if __name__ == "__main__":
    main()
