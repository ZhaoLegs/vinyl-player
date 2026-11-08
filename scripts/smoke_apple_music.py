"""Launch the real app without demo flags and capture its connection screen.

Does not pretend that unsigned CI has an Apple Music account/subscription.
"""
import argparse
import json
from pathlib import Path
import subprocess
import shutil
import signal
import time

from record_native import choose_device, choose_runtime, select_xcode, text, run, wait_for_demo


def capture(udid, output, name, launch_args, completion):
    movie = output / f"{name}.mov"
    with (output / f"{name}-recorder.log").open("w") as log:
        recorder = subprocess.Popen(
            ["xcrun", "simctl", "io", udid, "recordVideo", "--codec=h264", str(movie)],
            stdout=log, stderr=subprocess.STDOUT)
        try:
            deadline = time.monotonic() + 30
            while "Recording started" not in (output / f"{name}-recorder.log").read_text():
                if recorder.poll() is not None or time.monotonic() > deadline:
                    raise RuntimeError("Recorder did not become ready")
                time.sleep(.1)
            run("xcrun", "simctl", "launch", udid, "com.zhaolegs.Vinyl", *launch_args)
            completion(recorder)
        finally:
            if recorder.poll() is None:
                recorder.send_signal(signal.SIGINT)
                recorder.wait(timeout=30)
        if recorder.returncode != 0 or movie.stat().st_size < 10_000:
            raise RuntimeError(f"Invalid recording: {name}")


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
        print("Booting simulator", flush=True)
        run("xcrun", "simctl", "boot", udid)
        run("xcrun", "simctl", "bootstatus", udid, "-b", timeout=480)
        print("Installing app", flush=True)
        run("xcrun", "simctl", "ui", udid, "appearance", "light")
        run("xcrun", "simctl", "status_bar", udid, "override",
            "--time", "9:41", "--batteryState", "charged", "--batteryLevel", "100")
        run("xcrun", "simctl", "install", udid, str(app))
        print("Launching default connection screen", flush=True)
        with (output / "console.log").open("w") as log:
            console = subprocess.Popen(
                ["xcrun", "simctl", "launch", "--console-pty", udid, "com.zhaolegs.Vinyl"],
                stdout=log, stderr=subprocess.STDOUT)
            time.sleep(30)
        run("xcrun", "simctl", "io", udid, "screenshot", str(output / "apple-music-connect.png"))
        # terminate fails if the application crashed or never stayed running.
        run("xcrun", "simctl", "terminate", udid, "com.zhaolegs.Vinyl")
        print("Recording Apple Music onboarding and tab navigation", flush=True)
        capture(udid, output, "apple-music-interface", ["--record-ui"],
                lambda recorder: time.sleep(13))
        run("xcrun", "simctl", "terminate", udid, "com.zhaolegs.Vinyl")
        container = Path(text("xcrun", "simctl", "get_app_container", udid,
                              "com.zhaolegs.Vinyl", "data"))
        marker = container / "Documents/vinyl-recording-state.txt"
        print("Capturing settled home layout", flush=True)
        run("xcrun", "simctl", "launch", udid, "com.zhaolegs.Vinyl", "--layout-check")
        time.sleep(30)
        run("xcrun", "simctl", "io", udid, "screenshot", str(output / "vinyl-home-layout.png"))
        run("xcrun", "simctl", "terminate", udid, "com.zhaolegs.Vinyl")
        marker.unlink(missing_ok=True)
        print("Checking layout inspector", flush=True)
        run("xcrun", "simctl", "launch", udid, "com.zhaolegs.Vinyl",
            "--layout-check", "--review-check")
        time.sleep(8)
        run("xcrun", "simctl", "io", udid, "screenshot", str(output / "layout-inspector.png"))
        layout = container / "Documents/layout-review.json"
        if not layout.exists():
            raise RuntimeError("Layout inspector did not produce measurements")
        measurements = json.loads(layout.read_text())
        indexed = {item["id"]: item for item in measurements}
        assert abs(indexed["header-left"]["width"] - 44) < 1
        assert abs(indexed["cover-2"]["x"] - indexed["cover-1"]["x"]
                   - indexed["cover-1"]["width"] - 18) < 1
        shutil.copy2(layout, output / "layout-review.json")
        run("xcrun", "simctl", "terminate", udid, "com.zhaolegs.Vinyl")
        print("Checking real local audio pause, seek and progress", flush=True)
        playback_report = container / "Documents/playback-check.json"
        playback_report.unlink(missing_ok=True)
        def checked_playback(recorder):
            deadline = time.monotonic() + 90
            while not playback_report.exists():
                if recorder.poll() is not None or time.monotonic() > deadline:
                    raise RuntimeError("Playback acceptance timed out")
                time.sleep(.2)
            report = json.loads(playback_report.read_text())
            if report["result"] != "complete":
                raise RuntimeError(f"Playback acceptance failed: {report}")
            shutil.copy2(playback_report, output / "playback-check.json")
            run("xcrun", "simctl", "io", udid, "screenshot", str(output / "playback-detail.png"))
            time.sleep(1)
        capture(udid, output, "playback-acceptance", ["--layout-check", "--playback-check"], checked_playback)
        run("xcrun", "simctl", "terminate", udid, "com.zhaolegs.Vinyl")
        print("Warming built-in vinyl animation demo", flush=True)
        run("xcrun", "simctl", "launch", udid, "com.zhaolegs.Vinyl", "--record-demo")
        wait_for_demo(marker, timeout=180)
        run("xcrun", "simctl", "terminate", udid, "com.zhaolegs.Vinyl")
        marker.unlink()
        print("Recording built-in vinyl animation demo", flush=True)
        def demo_complete(recorder):
            wait_for_demo(marker, timeout=120, recorder=recorder)
            time.sleep(1)
        capture(udid, output, "vinyl-animation-demo", ["--record-demo"], demo_complete)
        run("xcrun", "simctl", "terminate", udid, "com.zhaolegs.Vinyl")
        (output / "smoke.json").write_text(json.dumps({
            "xcode": xcode, "runtime": runtime["version"], "device": device["name"],
            "result": "launched without demo flags; remained alive",
            "limits": "No account authorization or real playback tested",
            "commit": text("git", "rev-parse", "HEAD"),
            "capture": "Native SwiftUI app; simctl io recordVideo",
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
