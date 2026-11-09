"""Check lossless endpoint pixels and the native cycle's handoff trace.

The report distinguishes SwiftUI endpoint render pixels, presentation geometry,
and simctl native video timestamps; it never treats the 60 fps export as native.
"""
import argparse
import json
import math
from pathlib import Path
import re

from PIL import Image, ImageChops, ImageDraw, ImageStat


def opaque_box(image):
    return list(image.getchannel("A").point(lambda v: 255 if v >= 240 else 0).getbbox())


def compare(first, second, scale):
    a, b = opaque_box(first), opaque_box(second)
    center = lambda r: ((r[0] + r[2]) / 2, (r[1] + r[3]) / 2)
    ca, cb = center(a), center(b)
    return {
        "first_opaque_bbox_px": a, "second_opaque_bbox_px": b,
        "center_error_pt": math.hypot(ca[0] - cb[0], ca[1] - cb[1]) / scale,
        "width_error_pt": abs((a[2] - a[0]) - (b[2] - b[0])) / scale,
        "height_error_pt": abs((a[3] - a[1]) - (b[3] - b[1])) / scale,
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("recording")
    args = parser.parse_args()
    folder = Path(args.recording)
    endpoints = folder / "endpoints"
    geometry = json.loads((endpoints / "geometry.json").read_text())
    scale = geometry["scale"]
    mini, start, detail, end = [
        Image.open(endpoints / (name + ".png")).convert("RGBA")
        for name in ("mini", "flight-start", "detail", "flight-end")
    ]
    opening = compare(mini, start, scale)
    landing = compare(detail, end, scale)
    x, y, width, height = geometry["start"]
    cx, cy = (x + width / 2) * scale, (y + height / 2) * scale
    crop = tuple(round(v) for v in (cx - 24, cy - 24, cx + 24, cy + 24))
    a, b = mini.crop(crop), start.crop(crop)
    scores = []
    for index in range(-12, 13):
        angle = index * .25
        rotated = b.rotate(float(angle), resample=Image.Resampling.BICUBIC)
        scores.append((sum(ImageStat.Stat(ImageChops.difference(a, rotated)).mean) / 4, angle))
    score, angle = min(scores)
    opening["best_fitted_angular_offset_deg"] = angle
    opening["rgba_mean_absolute_error_0_to_255"] = score

    log = (folder / "app.log").read_text()
    owners = re.findall(r"\[mini-owner\] time=([\d.]+) owner=(\w+)", log)
    rows = re.findall(
        r"\[mini-frame\] time=([\d.]+) close=(false|true) p=([\d.e-]+) "
        r"center=\(([^,]+),([^)]+)\) side=([\d.e-]+) angle=([\d.e-]+) key=(.+)", log)
    keys = sorted({r[-1] for r in rows})
    traces = {}
    for closing in ("false", "true"):
        subset = [r for r in rows if r[1] == closing]
        if not subset:
            raise AssertionError("Missing presentation trace")
        last = subset[-1]
        target = geometry["start" if closing == "true" else "end"]
        tx, ty, side, _ = target
        target_angle = geometry["angle"] if closing == "true" else 0
        before = subset[-2]
        traces["close" if closing == "true" else "open"] = {
            "last_progress": float(last[2]),
            "last_center_error_pt": float(math.hypot(float(last[3]) - tx - side / 2,
                                                    float(last[4]) - ty - side / 2)),
            "last_width_error_pt": abs(float(last[5]) - side),
            "last_angle_error_deg": abs(float(last[6]) - target_angle),
            "previous_center_error_pt": float(math.hypot(float(before[3]) - tx - side / 2,
                                                        float(before[4]) - ty - side / 2)),
            "previous_width_error_pt": abs(float(before[5]) - side),
            "previous_angle_error_deg": abs(float(before[6]) - target_angle),
        }
    native = json.loads((folder / "native-frames.json").read_text())
    report = {
        "source": geometry["cache_key"], "captured_angle_deg": geometry["angle"],
        "endpoint_pixel_checks": {"mini_vs_flight_start": opening, "detail_vs_flight_end": landing},
        "presentation_trace_checks": traces,
        "ownership_sequence": owners,
        "one_source_for_all_logged_flight_frames": len(keys) == 1,
        "native_encoded_frames": len(native["frames"]),
        "native_avg_fps": native["streams"][0]["avg_frame_rate"],
        "ffmpeg_60fps_export_frames": len(list((folder / "frames-60").glob("*.png"))),
        "scope": "Pixels are lossless endpoint renders; trace is interpolated SwiftUI geometry. Native movie is separate.",
    }
    for item in (opening, landing):
        assert item["center_error_pt"] <= 1 and item["width_error_pt"] <= 1 and item["height_error_pt"] <= 1, item
    assert abs(angle) <= 2, opening
    assert [owner for _, owner in owners] == ["flight", "detail", "flight", "mini"], owners
    assert len(keys) == 1, keys
    (folder / "checks.json").write_text(json.dumps(report, ensure_ascii=False, indent=2))
    card = Image.new("RGB", (768, 440), "white")
    card.paste(a.resize((384, 384), Image.Resampling.NEAREST), (0, 30), a.resize((384, 384), Image.Resampling.NEAREST))
    card.paste(b.resize((384, 384), Image.Resampling.NEAREST), (384, 30), b.resize((384, 384), Image.Resampling.NEAREST))
    draw = ImageDraw.Draw(card)
    draw.text((16, 10), "Mini label (lossless endpoint)", fill="black")
    draw.text((400, 10), "Flight start (lossless endpoint)", fill="black")
    draw.text((16, 420), f"Source angle {geometry['angle']:.3f} deg; fitted difference {angle:.2f} deg", fill="black")
    card.save(folder / "endpoint-comparison.png")
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
