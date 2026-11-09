"""Record the opt-in mini cycle on an existing simulator; never touches other devices.

Usage: python3 scripts/record_mini_flight.py --device UUID --app /path/Vinyl.app
       --output recordings/mini-flight/baseline [--paused] [--tile]
Native timestamps are saved separately from the requested ffmpeg 60 fps export.
"""
import argparse
import json
import os
from pathlib import Path
import pty
import select
import signal
import shutil
import subprocess
import time


def run(*args):
    return subprocess.run(args, check=True, capture_output=True, text=True).stdout.strip()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--device", required=True)
    parser.add_argument("--app", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--paused", action="store_true")
    parser.add_argument("--tile", action="store_true")
    parser.add_argument("--official", action="store_true")
    args = parser.parse_args()
    output = Path(args.output).resolve()
    output.mkdir(parents=True, exist_ok=True)
    run("xcrun", "simctl", "install", args.device, args.app)
    master, slave = pty.openpty()
    recorder = subprocess.Popen(
        ["xcrun", "simctl", "io", args.device, "recordVideo", "--codec=h264",
         "--force", str(output / "cycle.mov")], stdout=slave, stderr=slave)
    os.close(slave)
    log = ""
    try:
        deadline = time.monotonic() + 30
        while "Recording started" not in log:
            if recorder.poll() is not None or time.monotonic() > deadline:
                raise RuntimeError("Recorder did not start: " + log)
            ready, _, _ = select.select([master], [], [], .2)
            if ready:
                log += os.read(master, 65536).decode("utf-8", "replace")
        launch = ["xcrun", "simctl", "launch", "--terminate-running-process",
                  "--stdout=" + str(output / "app.log"),
                  "--stderr=" + str(output / "app-error.log"),
                  args.device, "com.zhaolegs.Vinyl", "--debug-mini-cycle"]
        if args.paused:
            launch.append("--debug-mini-paused")
        if args.tile:
            launch.append("--debug-mini-tile")
        if args.official:
            launch.append("--debug-mini-official")
        run(*launch)
        # Allow the native open, disc retraction and close animations to finish.
        time.sleep(11)
    finally:
        if recorder.poll() is None:
            recorder.send_signal(signal.SIGINT)
        recorder.wait(timeout=30)
        os.close(master)
        (output / "recorder.log").write_text(log)
    container = Path(run("xcrun", "simctl", "get_app_container", args.device, "com.zhaolegs.Vinyl", "data"))
    endpoints = container / "Documents" / "mini-endpoints"
    if endpoints.exists() and not args.tile:
        shutil.copytree(endpoints, output / "endpoints", dirs_exist_ok=True)
    probe = run("ffprobe", "-v", "error", "-select_streams", "v:0",
                "-show_streams", "-show_frames", "-of", "json", str(output / "cycle.mov"))
    (output / "native-frames.json").write_text(probe)
    frames = output / "frames-60"
    frames.mkdir(exist_ok=True)
    run("ffmpeg", "-v", "error", "-i", str(output / "cycle.mov"),
        "-vf", "fps=60", str(frames / "%04d.png"))
    info = json.loads(probe)
    print(json.dumps({"output": str(output), "native_frames": len(info["frames"]),
                      "exported_frames": len(list(frames.glob("*.png"))),
                      "fps": info["streams"][0]["avg_frame_rate"]}))


if __name__ == "__main__":
    main()
