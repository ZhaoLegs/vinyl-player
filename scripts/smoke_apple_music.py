"""Launch the real app without demo flags and capture its connection screen.

Does not pretend that unsigned CI has an Apple Music account/subscription.
"""
import argparse
import json
from pathlib import Path
import subprocess
import time

from record_native import choose_device, choose_runtime, select_xcode, text, run


def smoke(app, output):
    output.mkdir(parents=True, exist_ok=True)
    xcode = select_xcode()
    runtime = choose_runtime(json.loads(text("xcrun", "simctl", "list", "runtimes", "--json"))["runtimes"])
    types = json.loads(text("xcrun", "simctl", "list", "devicetypes", "--json"))["devicetypes"]
    supported = {d["identifier"] for d in runtime.get("supportedDeviceTypes", [])}
    device = choose_device([d for d in types if not supported or d["identifier"] in supported])
    udid = text("xcrun", "simctl", "create", "Vinyl MusicKit Smoke",
                device["identifier"], runtime["identifier"])
    try:
        run("xcrun", "simctl", "boot", udid)
        run("xcrun", "simctl", "bootstatus", udid, "-b", timeout=240)
        run("xcrun", "simctl", "ui", udid, "appearance", "light")
        run("xcrun", "simctl", "install", udid, str(app))
        launch = text("xcrun", "simctl", "launch", udid, "com.zhaolegs.Vinyl")
        time.sleep(8)
        run("xcrun", "simctl", "io", udid, "screenshot", str(output / "apple-music-connect.png"))
        # terminate fails if the application crashed or never stayed running.
        run("xcrun", "simctl", "terminate", udid, "com.zhaolegs.Vinyl")
        (output / "smoke.json").write_text(json.dumps({
            "xcode": xcode, "runtime": runtime["version"], "device": device["name"],
            "launch": launch, "result": "launched without demo flags; remained alive",
            "limits": "No account authorization or real playback tested",
        }, indent=2))
    finally:
        subprocess.run(["xcrun", "simctl", "shutdown", udid], capture_output=True)
        subprocess.run(["xcrun", "simctl", "delete", udid], capture_output=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    smoke(args.app, args.output)
