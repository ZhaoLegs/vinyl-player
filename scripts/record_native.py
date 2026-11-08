"""Build with Xcode 27 and record an actual iOS 27 simulator via simctl.

Works on the official xcode-27 Actions image or a Mac with the same SDK/runtime.
Never falls back to a browser, an older SDK, or an older simulator runtime.
"""
import argparse
import json
import os
from pathlib import Path
import platform
import re
import signal
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
BUNDLE = "com.zhaolegs.Vinyl"


def run(*args, **kwargs):
    try:
        return subprocess.run(args, check=True, text=True, **kwargs)
    except subprocess.CalledProcessError as error:
        if error.stderr:
            print(error.stderr, flush=True)
        raise


def text(*args):
    return run(*args, capture_output=True).stdout.strip()


def choose_runtime(runtimes):
    available = [r for r in runtimes if r.get("isAvailable")
                 and r["identifier"].startswith("com.apple.CoreSimulator.SimRuntime.iOS-")
                 and r["version"].split(".")[0] == "27"]
    if not available:
        raise RuntimeError("No available iOS 27 simulator runtime. Install it in Xcode.")
    # Some newer runtimes support only one device (for example iPhone Duo).
    # Prefer a runtime supporting the target phone over an incompatible newer one.
    preferred = [r for r in available if any(
        d["name"] == "iPhone 17 Pro" for d in r.get("supportedDeviceTypes", []))]
    if preferred:
        available = preferred
    return max(available, key=lambda r: tuple(map(int, r["version"].split("."))))


def choose_device(types):
    phones = [d for d in types if d.get("productFamily") == "iPhone"]
    for name in ("iPhone 17 Pro", "iPhone 16 Pro", "iPhone 15 Pro"):
        for d in phones:
            if d["name"] == name:
                return d
    if not phones:
        raise RuntimeError("No iPhone simulator device type is installed.")
    return phones[-1]


def select_xcode():
    paths = list(Path("/Applications").glob("Xcode*.app/Contents/Developer"))
    current = subprocess.run(["xcode-select", "-p"], capture_output=True, text=True)
    if current.returncode == 0:
        paths.insert(0, Path(current.stdout.strip()))
    for developer in dict.fromkeys(paths):
        env = dict(os.environ, DEVELOPER_DIR=str(developer))
        result = subprocess.run(["xcodebuild", "-version"], env=env,
                                capture_output=True, text=True)
        if result.returncode == 0 and re.search(r"^Xcode 27(?:\.|\s|$)", result.stdout):
            os.environ["DEVELOPER_DIR"] = str(developer)
            return result.stdout.strip()
    raise RuntimeError("Xcode 27 is required. No matching installation found.")


def wait_for_demo(marker, timeout, recorder=None):
    deadline = time.monotonic() + timeout
    previous = None
    while True:
        if recorder is not None and recorder.poll() is not None:
            raise RuntimeError("simctl recorder exited during the demo")
        phase = marker.read_text().strip() if marker.exists() else ""
        if phase != previous:
            print(f"Native demo phase: {phase!r}", flush=True)
            previous = phase
        if phase == "complete":
            return
        if phase.startswith("failed") or time.monotonic() > deadline:
            raise RuntimeError(f"Native demo did not complete (phase={phase!r})")
        time.sleep(.2)


def record(output):
    output.mkdir(parents=True, exist_ok=True)
    if platform.system() != "Darwin":
        raise RuntimeError("Native recording requires macOS with Xcode 27.")
    xcode = select_xcode()
    runtimes = json.loads(text("xcrun", "simctl", "list", "runtimes", "--json"))["runtimes"]
    runtime = choose_runtime(runtimes)
    types = json.loads(text("xcrun", "simctl", "list", "devicetypes", "--json"))["devicetypes"]
    supported = {d["identifier"] for d in runtime.get("supportedDeviceTypes", [])}
    device = choose_device([d for d in types if not supported or d["identifier"] in supported])
    metadata = {"xcode": xcode, "runtime": runtime, "deviceType": device,
                "commit": text("git", "-C", str(ROOT), "rev-parse", "HEAD"),
                "capture": "simctl io recordVideo; native SwiftUI app"}
    (output / "environment.json").write_text(json.dumps(metadata, indent=2))
    udid = None
    recorder = None
    try:
        udid = text("xcrun", "simctl", "create", "Vinyl Native Recording",
                    device["identifier"], runtime["identifier"])
        run("xcrun", "simctl", "boot", udid)
        run("xcrun", "simctl", "bootstatus", udid, "-b", timeout=180)
        run("xcrun", "simctl", "ui", udid, "appearance", "light")
        run("xcrun", "simctl", "status_bar", udid, "override",
            "--time", "15:30", "--batteryState", "charged", "--batteryLevel", "100")
        with tempfile.TemporaryDirectory(prefix="vinyl-native-build-") as derived:
            with (output / "build.log").open("w") as log:
                run("xcodebuild", "-project", str(ROOT / "Vinyl/Vinyl.xcodeproj"),
                    "-scheme", "Vinyl", "-configuration", "Release",
                    "-sdk", "iphonesimulator", "-destination", f"id={udid}",
                    "-derivedDataPath", derived, "CODE_SIGNING_ALLOWED=NO",
                    "ONLY_ACTIVE_ARCH=YES",
                    "build", stdout=log, stderr=subprocess.STDOUT, timeout=900)
            app = Path(derived) / "Build/Products/Release-iphonesimulator/Vinyl.app"
            run("xcrun", "simctl", "install", udid, str(app))
            container = Path(text("xcrun", "simctl", "get_app_container", udid, BUNDLE, "data"))
            marker = container / "Documents/vinyl-recording-state.txt"
            # A fresh CI simulator can spend tens of seconds compiling rendering
            # pipelines. Exercise the complete UI before the recorded launch.
            print("Warming native rendering pipelines", flush=True)
            run("xcrun", "simctl", "launch", udid, BUNDLE, "--record-demo")
            wait_for_demo(marker, timeout=180)
            run("xcrun", "simctl", "terminate", udid, BUNDLE)
            marker.unlink()
            print("Starting warmed native recording", flush=True)
            with (output / "recorder.log").open("w") as log:
                recorder = subprocess.Popen(
                    ["xcrun", "simctl", "io", udid, "recordVideo", "--codec=h264",
                     str(output / "vinyl-native-ios27.mov")],
                    stdout=log, stderr=subprocess.STDOUT)
                # Wait for the recorder's readiness message, not an arbitrary startup delay.
                deadline = time.monotonic() + 15
                while "Recording started" not in (output / "recorder.log").read_text():
                    if recorder.poll() is not None or time.monotonic() > deadline:
                        raise RuntimeError("simctl recorder failed to start; see recorder.log")
                    time.sleep(.1)
                run("xcrun", "simctl", "launch", udid, BUNDLE, "--record-demo")
                wait_for_demo(marker, timeout=120, recorder=recorder)
                # Include the settled home screen after the animation-completion marker.
                time.sleep(1)
                run("xcrun", "simctl", "io", udid, "screenshot", str(output / "home-final.png"))
                recorder.send_signal(signal.SIGINT)
                recorder.wait(timeout=20)
                if recorder.returncode != 0:
                    raise RuntimeError(f"simctl recording failed: {recorder.returncode}")
                recorder = None
            movie = output / "vinyl-native-ios27.mov"
            if not movie.exists() or movie.stat().st_size < 10_000:
                raise RuntimeError("Native recording is missing or too small")
            (output / "demo-complete.txt").write_text(
                "App reported animation completion. Inspect the MOV to verify visual quality.\n")
            print(f"Native simulator recording: {movie}", flush=True)
    finally:
        if udid and not (output / "demo-complete.txt").exists():
            subprocess.run(["xcrun", "simctl", "io", udid, "screenshot",
                            str(output / "failure-screen.png")], capture_output=True,
                           timeout=30)
        if recorder is not None and recorder.poll() is None:
            recorder.send_signal(signal.SIGINT)
            try:
                recorder.wait(timeout=15)
            except subprocess.TimeoutExpired:
                recorder.kill()
                recorder.wait()
        if udid:
            subprocess.run(["xcrun", "simctl", "shutdown", udid], capture_output=True)
            subprocess.run(["xcrun", "simctl", "delete", udid], capture_output=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        record(args.output.resolve())
    except Exception as error:
        args.output.mkdir(parents=True, exist_ok=True)
        (args.output / "failure.txt").write_text(str(error) + "\n")
        raise
