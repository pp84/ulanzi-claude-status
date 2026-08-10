#!/usr/bin/env python3
"""capture-screens.py - record the TC001's real 32x8 matrix into animated GIFs.

The README's motion graphics are captured from the hardware, not simulated: this
pushes each screen to the device, switches to it, then polls AWTRIX's /api/screen
(which returns the live 256-pixel RGB888 framebuffer) and encodes the frames.

    python3 tools/capture-screens.py --ip 192.168.1.100 --out docs/screens

Requires Pillow. It disturbs the running rotation while it works and restores it
at the end; the ticker rebuilds anything it misses within ~5 min.
"""
import argparse
import json
import time
import urllib.error
import urllib.request
from pathlib import Path

from PIL import Image

W, H = 32, 8

# name -> payload posted to /api/custom. Mirrors screens.json plus the two
# pseudo-screens and the notification states, so the README shows everything.
EFFECTS = [
    ("matrix", {"effect": "Matrix", "text": ""}),
    ("pong", {"effect": "PingPong", "text": "", "effectSettings": {"speed": -4.5}}),
    ("brick", {"effect": "BrickBreaker", "text": ""}),
    ("snake", {"effect": "Snake", "text": ""}),
    ("fireworks", {"effect": "Fireworks", "text": ""}),
    ("ripple", {"effect": "Ripple", "text": ""}),
    ("chase", {"effect": "TheaterChase", "text": ""}),
    ("eyes", {"effect": "LookingEyes", "text": ""}),
    ("stars", {"effect": "TwinklingStars", "text": ""}),
    ("countdown", {"text": "61 DAYS TO GO", "rainbow": True, "scrollSpeed": 75}),
    ("usage", {"text": [{"t": "3H24 ", "c": "#34C759"}, {"t": "71%", "c": "#34C759"}],
               "scrollSpeed": 75}),
]

# Held notifications - captured via /api/notify rather than the app loop.
NOTIFICATIONS = [
    ("working", {"text": "WORKING", "color": "#2A7AFF", "hold": True,
                 "stack": False, "textCase": 2}),
    ("waiting", {"text": "WAITING", "color": "#FF2A2A", "hold": True,
                 "stack": False, "textCase": 2}),
]


def post(ip, path, payload=None):
    body = b"" if payload is None else json.dumps(payload).encode()
    req = urllib.request.Request(f"http://{ip}{path}", data=body, method="POST",
                                 headers={"Content-Type": "application/json"})
    try:
        urllib.request.urlopen(req, timeout=5).read()
    except urllib.error.URLError as e:
        print(f"  ! POST {path}: {e}")


def frame(ip):
    """One 32x8 frame, or None if the device hiccups mid-capture."""
    try:
        raw = json.load(urllib.request.urlopen(f"http://{ip}/api/screen", timeout=3))
    except Exception:
        return None
    if not isinstance(raw, list) or len(raw) != W * H:
        return None
    img = Image.new("RGB", (W, H))
    img.putdata([((p >> 16) & 0xFF, (p >> 8) & 0xFF, p & 0xFF) for p in raw])
    return img


def render(img, scale, gap):
    """Blow a frame up into an LED-panel look: lit dots on a dark grid."""
    out = Image.new("RGB", (W * scale, H * scale), (10, 10, 12))
    px = out.load()
    src = img.load()
    for y in range(H):
        for x in range(W):
            r, g, b = src[x, y]
            for dy in range(gap, scale - gap):
                for dx in range(gap, scale - gap):
                    px[x * scale + dx, y * scale + dy] = (r, g, b)
    return out


def capture(ip, seconds, scale, gap):
    """Poll as fast as the device answers; the HTTP round-trip is the frame rate.

    Returns (frames, ms-per-frame) so the GIF plays back at the speed it was
    actually sampled at, rather than a rate we guessed.
    """
    frames, stamps = [], []
    deadline = time.time() + seconds
    while time.time() < deadline:
        f = frame(ip)
        if f is not None:
            frames.append(render(f, scale, gap))
            stamps.append(time.time())
    if len(stamps) < 2:
        return frames, 100
    deltas = sorted(b - a for a, b in zip(stamps, stamps[1:]))
    return frames, max(20, int(deltas[len(deltas) // 2] * 1000))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ip", required=True)
    ap.add_argument("--out", default="docs/screens")
    ap.add_argument("--seconds", type=float, default=6.0)
    ap.add_argument("--scale", type=int, default=8)
    ap.add_argument("--gap", type=int, default=1)
    ap.add_argument("--only", help="comma-separated subset of screen names")
    args = ap.parse_args()

    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    wanted = set(args.only.split(",")) if args.only else None

    # Start from a clean panel: a held notification masks the whole app loop.
    post(args.ip, "/api/notify/dismiss")
    time.sleep(0.5)

    for name, payload in EFFECTS:
        if wanted and name not in wanted:
            continue
        print(f"capturing {name} ...")
        post(args.ip, f"/api/custom?name=_cap_{name}", {**payload, "duration": 30})
        time.sleep(1.0)
        post(args.ip, "/api/switch", {"name": f"_cap_{name}"})
        time.sleep(1.0)
        frames, ms = capture(args.ip, args.seconds, args.scale, args.gap)
        save(out / f"{name}.gif", frames, ms)
        post(args.ip, f"/api/custom?name=_cap_{name}")   # empty body removes it

    for name, payload in NOTIFICATIONS:
        if wanted and name not in wanted:
            continue
        print(f"capturing {name} ...")
        post(args.ip, "/api/notify", payload)
        time.sleep(1.0)
        frames, ms = capture(args.ip, args.seconds, args.scale, args.gap)
        save(out / f"{name}.gif", frames, ms)
        post(args.ip, "/api/notify/dismiss")

    print("done. the ticker restores the normal rotation within ~5 min "
          "(or: rm -f ~/.claude/.screens-checked && bash ~/.claude/claude-ticker.sh)")


def save(path, frames, ms):
    if not frames:
        print(f"  ! no frames for {path.name}")
        return
    frames[0].save(path, save_all=True, append_images=frames[1:],
                   duration=ms, loop=0, optimize=True)
    print(f"  -> {path} ({len(frames)} frames @ {ms}ms, "
          f"{path.stat().st_size // 1024} KB)")


if __name__ == "__main__":
    main()
