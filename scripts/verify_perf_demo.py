#!/usr/bin/env python3
"""Replay and record the existing cover-flight/flip/close demo, with no animation changes."""
import argparse
import os
from pathlib import Path
import pty
import signal
import subprocess
from record_native import text, wait_for_demo, wait_until_recording_started

ROOT = Path(__file__).resolve().parents[1]
BUNDLE = "com.zhaolegs.Vinyl"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--device", required=True)
    parser.add_argument("--app", required=True)
    parser.add_argument("--label", required=True)
    args = parser.parse_args()
    destination = ROOT / "build/profiles" / args.label
    destination.mkdir(parents=True, exist_ok=False)
    subprocess.run(["xcrun", "simctl", "terminate", args.device, BUNDLE], capture_output=True)
    subprocess.run(["xcrun", "simctl", "install", args.device, args.app], check=True)
    container = Path(text("xcrun", "simctl", "get_app_container", args.device, BUNDLE, "data"))
    marker = container / "Documents/vinyl-recording-state.txt"
    marker.unlink(missing_ok=True)
    subprocess.run(["xcrun", "simctl", "launch", args.device, BUNDLE, "--record-demo"], check=True)
    wait_for_demo(marker, 40)
    subprocess.run(["xcrun", "simctl", "terminate", args.device, BUNDLE], check=True)
    marker.unlink()
    master, slave = pty.openpty()
    movie = destination / "demo.mov"
    recorder = subprocess.Popen(["xcrun", "simctl", "io", args.device,
                                 "recordVideo", "--codec=h264", str(movie)], stdout=slave, stderr=slave)
    os.close(slave)
    try:
        wait_until_recording_started(master, destination / "recorder.log", movie, recorder)
        subprocess.run(["xcrun", "simctl", "launch", args.device, BUNDLE, "--record-demo"], check=True)
        wait_for_demo(marker, 40, recorder)
        subprocess.run(["xcrun", "simctl", "io", args.device, "screenshot",
                        str(destination / "home-final.png")], check=True)
        (destination / "demo-complete.txt").write_text(marker.read_text())
    finally:
        recorder.send_signal(signal.SIGINT)
        recorder.wait(timeout=30)
        os.close(master)
    if not movie.exists() or movie.stat().st_size < 10000:
        raise RuntimeError("Demo recording is missing")
    print(f"Verified animation completion and saved {movie}")


if __name__ == "__main__":
    main()
