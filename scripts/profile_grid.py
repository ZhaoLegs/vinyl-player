#!/usr/bin/env python3
"""Record the same 18-second scroll interval with Instruments and a frame callback probe."""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import sys
import threading
import time

ROOT = Path(__file__).resolve().parents[1]
BUNDLE = "com.zhaolegs.Vinyl"


def run(*args, **kwargs):
    return subprocess.run(args, check=True, text=True, capture_output=True, **kwargs).stdout.strip()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--device", required=True)
    parser.add_argument("--app", required=True)
    parser.add_argument("--label", required=True)
    parser.add_argument("--template", default="Time Profiler")
    parser.add_argument("--cpu-only", action="store_true")
    parser.add_argument("--sample-stacks", action="store_true",
                        help="Also collect native sample stacks if xctrace symbolication is unavailable.")
    args = parser.parse_args()
    destination = ROOT / "build" / "profiles" / args.label
    destination.mkdir(parents=True, exist_ok=False)
    run("xcrun", "simctl", "install", args.device, args.app)
    container = Path(run("xcrun", "simctl", "get_app_container", args.device, BUNDLE, "data"))
    documents = container / "Documents"
    documents.mkdir(exist_ok=True)
    for name in ("profile-start", "profile-result.json"):
        (documents / name).unlink(missing_ok=True)
    # This command is only used on the dedicated VinylPerf simulator.
    shutil.rmtree(container / "Library/Caches/artwork", ignore_errors=True)
    subprocess.run(["xcrun", "simctl", "terminate", args.device, BUNDLE], capture_output=True)
    output = run("xcrun", "simctl", "launch", args.device, BUNDLE, "--profile-grid")
    pid = output.rsplit(":", 1)[1].strip()
    command = [
        "xcrun", "xctrace", "record", "--template", args.template,
        "--device", args.device, "--attach", pid,
        "--time-limit", "26s", "--output", str(destination / "scroll.trace"), "--no-prompt"
    ]
    command[5:5] = ["--instrument", "Points of Interest"]
    if not args.cpu_only:
        command[5:5] = ["--instrument", "SwiftUI"]
    (destination / "command.json").write_text(json.dumps(command, indent=2))
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1)
    began = False
    sampler = None
    def preserve_result():
        for _ in range(150):
            result = documents / "profile-result.json"
            if result.exists():
                shutil.copy2(result, destination / "frames.json")
                print(result.read_text(), flush=True)
                return
            time.sleep(0.2)
    watchdog = threading.Timer(120, process.terminate)
    watchdog.start()
    with (destination / "recording.log").open("w") as log:
        for line in process.stdout:
            log.write(line); log.flush()
            print(line, end="", flush=True)
            if ("Recording started" in line or "Ctrl-C to stop" in line) and not began:
                began = True
                run("xcrun", "simctl", "io", args.device, "screenshot", str(destination / "start.png"))
                (documents / "profile-start").touch()
                if args.sample_stacks:
                    sampler = subprocess.Popen(
                        ["/usr/bin/sample", pid, "18", "1", "-file", str(destination / "native-stacks.txt")],
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                threading.Thread(target=preserve_result, daemon=True).start()
        code = process.wait()
    watchdog.cancel()
    if sampler is not None:
        try:
            sampler.wait(timeout=35)
        except subprocess.TimeoutExpired:
            sampler.terminate()
    if code or not began:
        sys.exit(f"Instruments did not start successfully (exit {code}).")
    result = documents / "profile-result.json"
    if not result.exists():
        sys.exit("The scroll probe did not finish; do not treat this trace as a measurement.")
    shutil.copy2(result, destination / "frames.json")
    run("xcrun", "simctl", "io", args.device, "screenshot", str(destination / "end.png"))
    print(result.read_text())
    print(f"Saved {destination}", flush=True)


if __name__ == "__main__":
    main()
