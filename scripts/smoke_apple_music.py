"""Launch the real app without demo flags and capture its connection screen.

Does not pretend that unsigned CI has an Apple Music account/subscription.
"""
import argparse
import json
from pathlib import Path
import subprocess
import shutil
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
    console = None
    try:
        run("xcrun", "simctl", "boot", udid)
        run("xcrun", "simctl", "bootstatus", udid, "-b", timeout=240)
        run("xcrun", "simctl", "ui", udid, "appearance", "light")
        run("xcrun", "simctl", "install", udid, str(app))
        with (output / "console.log").open("w") as log:
            console = subprocess.Popen(
                ["xcrun", "simctl", "launch", "--console-pty", udid, "com.zhaolegs.Vinyl"],
                stdout=log, stderr=subprocess.STDOUT)
            time.sleep(30)
        run("xcrun", "simctl", "io", udid, "screenshot", str(output / "apple-music-connect.png"))
        # terminate fails if the application crashed or never stayed running.
        run("xcrun", "simctl", "terminate", udid, "com.zhaolegs.Vinyl")
        (output / "smoke.json").write_text(json.dumps({
            "xcode": xcode, "runtime": runtime["version"], "device": device["name"],
            "result": "launched without demo flags; remained alive",
            "limits": "No account authorization or real playback tested",
        }, indent=2))
    finally:
        with (output / "system.log").open("w") as log:
            try:
                subprocess.run(["xcrun", "simctl", "spawn", udid, "log", "show",
                                "--style", "compact", "--last", "10m", "--predicate",
                                'process == "Vinyl" OR eventMessage CONTAINS "com.zhaolegs.Vinyl"'],
                               stdout=log, stderr=subprocess.STDOUT, timeout=90)
            except subprocess.TimeoutExpired:
                pass
        diagnostics = output / "diagnostics"
        diagnostics.mkdir(exist_ok=True)
        for folder in [Path.home() / "Library/Logs/DiagnosticReports",
                       Path.home() / f"Library/Developer/CoreSimulator/Devices/{udid}/data/Library/Logs/CrashReporter"]:
            if folder.exists():
                for report in folder.rglob("Vinyl*"):
                    if report.is_file():
                        shutil.copy2(report, diagnostics / report.name)
        if console is not None and console.poll() is None:
            console.terminate()
        subprocess.run(["xcrun", "simctl", "shutdown", udid], capture_output=True)
        subprocess.run(["xcrun", "simctl", "delete", udid], capture_output=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    smoke(args.app, args.output)
