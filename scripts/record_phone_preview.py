"""Capture phone .screen only (no page chrome) as a standalone portrait clip."""
import argparse
import asyncio
import subprocess
import tempfile
from pathlib import Path

from playwright.async_api import async_playwright


async def record(output: Path, fps: int = 60):
    async with async_playwright() as p:
        browser = await p.chromium.launch(args=["--no-sandbox"])
        page = await browser.new_page(
            viewport={"width": 480, "height": 960}, device_scale_factor=2
        )
        errors = []
        page.on("pageerror", lambda e: errors.append(str(e)))
        await page.goto("http://127.0.0.1:8765/preview/?capture", wait_until="networkidle")
        await page.evaluate("document.fonts.ready")
        screen = page.locator(".screen")
        await screen.wait_for()
        box = await screen.bounding_box()
        assert box, "missing .screen"
        # 185 source frames @ 30fps → double to 60fps
        frames = 370
        with tempfile.TemporaryDirectory(prefix="vinyl-phone-") as temp:
            for i in range(frames):
                f = min(185, 1 + i / 2)
                await page.evaluate("(f)=>seek(f)", f)
                await screen.screenshot(path=f"{temp}/{i:04}.png", type="png")
                if i % 60 == 0:
                    print(f"Captured {i}/{frames}", flush=True)
            subprocess.run([
                "ffmpeg", "-y", "-loglevel", "error", "-framerate", str(fps),
                "-i", f"{temp}/%04d.png",
                "-c:v", "libx264", "-crf", "18", "-pix_fmt", "yuv420p",
                "-movflags", "+faststart", str(output),
            ], check=True)
        assert not errors, errors
        print({"output": str(output), "size": output.stat().st_size, "errors": errors}, flush=True)
        await browser.close()


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--output", type=Path, required=True)
    args = ap.parse_args()
    asyncio.run(record(args.output))
