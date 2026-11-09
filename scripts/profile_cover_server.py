#!/usr/bin/env python3
"""Deterministic localhost CDN, using the repository's existing cover artwork."""
from functools import lru_cache
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from io import BytesIO
from pathlib import Path
from PIL import Image
import re

ROOT = Path(__file__).resolve().parents[1]


@lru_cache(maxsize=200)
def cover(index, side):
    path = ROOT / "Vinyl/Vinyl/Assets.xcassets" / f"cover_{index % 28 + 1:02}.imageset"
    source = next(path.glob("*.png"))
    image = Image.open(source).convert("RGB").resize((side, side), Image.Resampling.LANCZOS)
    output = BytesIO()
    image.save(output, "JPEG", quality=95)
    return output.getvalue()


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/rectangle.jpg":
            image = Image.open(BytesIO(cover(0, 960))).resize((960, 480), Image.Resampling.LANCZOS)
            output = BytesIO()
            image.save(output, "JPEG", quality=95)
            data = output.getvalue()
            self.send_response(200)
            self.send_header("Content-Type", "image/jpeg")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        match = re.fullmatch(r"/cover/(\d+)/(\d+)x(\d+)\.jpg", self.path)
        if not match:
            self.send_error(404)
            return
        index, width, height = map(int, match.groups())
        data = cover(index % 28, min(2048, max(width, height)))
        self.send_response(200)
        self.send_header("Content-Type", "image/jpeg")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *_):
        pass


if __name__ == "__main__":
    # Warm the deterministic encoder; encoder cost is outside the measured app.
    for side in (230, 240, 960):
        for index in range(28):
            cover(index, side)
    server = ThreadingHTTPServer(("127.0.0.1", 18765), Handler)
    print("Cover server ready on 127.0.0.1:18765", flush=True)
    server.serve_forever()
