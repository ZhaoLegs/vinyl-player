"""Capture actual Chromium-rendered frames and encode a deterministic 60fps demo.

Run a server at the repository root: python -m http.server 8765
Then: python scripts/record_preview.py --output /workspace/vinyl-fixed.mp4
Requires playwright (with Chromium), ffmpeg. This is not an iOS recording.
"""
import argparse
import asyncio
import json
import subprocess
import tempfile
from pathlib import Path

from playwright.async_api import async_playwright


async def record(output, stills):
    async with async_playwright() as p:
        browser = await p.chromium.launch(args=["--no-sandbox"])
        page = await browser.new_page(
            viewport={"width": 480, "height": 920}, device_scale_factor=1
        )
        errors = []
        page.on("pageerror", lambda error: errors.append(str(error)))
        await page.goto("http://127.0.0.1:8765/preview/?capture", wait_until="networkidle")
        await page.evaluate("document.fonts.ready")
        await page.mouse.move(0, 0)
        if stills:
            for frame in [1, 12, 25, 60, 118, 150, 169, 185]:
                await page.evaluate("(f)=>seek(f)", frame)
                await page.screenshot(path=f"/tmp/vinyl-fixed-{frame:03}.png")
        else:
            with tempfile.TemporaryDirectory(prefix="vinyl-capture-") as temp:
                # The 185 source frames span 185/30 seconds. Include the last hold.
                for i in range(370):
                    await page.evaluate("(f)=>seek(f)", min(185, 1 + i / 2))
                    await page.screenshot(path=f"{temp}/{i:04}.png")
                    if i % 60 == 0:
                        print(f"Captured {i}/370", flush=True)
                subprocess.run([
                    "ffmpeg", "-y", "-loglevel", "error", "-framerate", "60",
                    "-i", f"{temp}/%04d.png", "-c:v", "libx264", "-crf", "18",
                    "-pix_fmt", "yuv420p", "-movflags", "+faststart", str(output),
                ], check=True)
        assert not errors, errors
        print(json.dumps({"errors": errors, "output": str(output)}), flush=True)
        await browser.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, default=Path("/workspace/vinyl-fixed.mp4"))
    parser.add_argument("--stills", action="store_true")
    args = parser.parse_args()
    asyncio.run(record(args.output, args.stills))
