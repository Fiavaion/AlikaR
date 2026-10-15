#!/usr/bin/env python3
"""Builds Samples/courtyard-hunt.arhunt/, a small demo bundle that exercises
every manifest feature: all MVP triggers and actions, image/geo/gps anchors,
hidden elements unlocked by another, and the Studio extensions (labels,
credits, variants, design size, crit notes, dwell and time-window triggers).

Assets are generated placeholders (simple coloured meshes, a tone, flat
images) so the sample is small and licence-free. ARWorldMap anchors cannot be
synthesised; scan anchors are added on device by re-saving the sample there.

    python3 Samples/make_sample.py
    swift run cuardach validate Samples/courtyard-hunt.arhunt
"""

import json
import math
import os
import shutil
import struct
import wave
import zipfile
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "courtyard-hunt.arhunt")

# NCAD, Thomas Street, Dublin (approximate courtyard centre).
SITE = (53.3436, -6.2806)


def offset(lat, lon, east_m, north_m):
    r = 6371008.8
    return (lat + north_m / r * 180 / math.pi,
            lon + east_m / (r * math.cos(lat * math.pi / 180)) * 180 / math.pi)


# --- Marker pattern: a port of CuardachCore.MarkerPattern --------------------

M64 = (1 << 64) - 1


def fnv1a(s):
    h = 0xCBF29CE484222325
    for b in s.encode("utf-8"):
        h = ((h ^ b) * 0x100000001B3) & M64
    return h


class SplitMix64:
    def __init__(self, seed):
        self.state = seed

    def next(self):
        self.state = (self.state + 0x9E3779B97F4A7C15) & M64
        z = self.state
        z = ((z ^ (z >> 30)) * 0xBF58476D1CE4E5B9) & M64
        z = ((z ^ (z >> 27)) * 0x94D049BB133111EB) & M64
        return z ^ (z >> 31)


def marker_cells(seed, size=12):
    rng = SplitMix64(fnv1a(seed))
    c = [[False] * size for _ in range(size)]
    for r in range(size):
        for col in range(size):
            if r in (0, size - 1) or col in (0, size - 1):
                c[r][col] = True
            else:
                c[r][col] = rng.next() & 1 == 1
    for r, col in [(1, 1), (1, 2), (2, 1), (2, 2)]:
        c[r][col] = False
    for r, col in [(size - 3, size - 3), (size - 3, size - 2), (size - 2, size - 3), (size - 2, size - 2)]:
        c[r][col] = True
    return c


# --- Tiny PNG writer ---------------------------------------------------------

def png(path, width, height, pixel):
    """pixel(x, y) -> (r, g, b)"""
    raw = bytearray()
    for y in range(height):
        raw.append(0)
        for x in range(width):
            raw.extend(pixel(x, y))

    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n")
        f.write(chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)))
        f.write(chunk(b"IDAT", zlib.compress(bytes(raw), 9)))
        f.write(chunk(b"IEND", b""))


def marker_png(path, seed, cell_px=40, quiet=1):
    cells = marker_cells(seed)
    n = len(cells) + 2 * quiet
    size = n * cell_px

    def px(x, y):
        r, c = y // cell_px - quiet, x // cell_px - quiet
        black = 0 <= r < len(cells) and 0 <= c < len(cells) and cells[r][c]
        return (0, 0, 0) if black else (255, 255, 255)

    png(path, size, size, px)


# --- USDZ: a box mesh with a UsdPreviewSurface material ------------------------

def box_usda(name, w, h, d, rgb, roughness=0.5, metallic=0.0):
    x, z = w / 2, d / 2
    pts = [(-x, 0, -z), (x, 0, -z), (x, h, -z), (-x, h, -z), (-x, 0, z), (x, 0, z), (x, h, z), (-x, h, z)]
    faces = [0, 3, 2, 1, 4, 5, 6, 7, 0, 4, 7, 3, 1, 2, 6, 5, 3, 7, 6, 2, 0, 1, 5, 4]
    p = ", ".join(f"({a:.4f}, {b:.4f}, {c:.4f})" for a, b, c in pts)
    f = ", ".join(map(str, faces))
    r, g, b = rgb
    return f'''#usda 1.0
(
    defaultPrim = "{name}"
    metersPerUnit = 1
    upAxis = "Y"
)

def Xform "{name}" (
    kind = "component"
)
{{
    def Mesh "Body" (
        prepend apiSchemas = ["MaterialBindingAPI"]
    )
    {{
        int[] faceVertexCounts = [4, 4, 4, 4, 4, 4]
        int[] faceVertexIndices = [{f}]
        point3f[] points = [{p}]
        uniform token subdivisionScheme = "none"
        rel material:binding = </{name}/Material>
    }}

    def Material "Material"
    {{
        token outputs:surface.connect = </{name}/Material/Surface.outputs:surface>

        def Shader "Surface"
        {{
            uniform token info:id = "UsdPreviewSurface"
            color3f inputs:diffuseColor = ({r}, {g}, {b})
            float inputs:roughness = {roughness}
            float inputs:metallic = {metallic}
            token outputs:surface
        }}
    }}
}}
'''


def usdz(path, usda_text):
    """USDZ is an uncompressed zip whose file data is 64-byte aligned."""
    data = usda_text.encode("utf-8")
    name = "model.usda"
    header_len = 30 + len(name)
    pad = (64 - header_len % 64) % 64
    if 0 < pad < 4:
        pad += 64
    info = zipfile.ZipInfo(name, date_time=(2026, 10, 15, 0, 0, 0))
    info.compress_type = zipfile.ZIP_STORED
    if pad:
        info.extra = struct.pack("<HH", 0x1986, pad - 4) + b"\0" * (pad - 4)
    with zipfile.ZipFile(path, "w", zipfile.ZIP_STORED) as z:
        z.writestr(info, data)


def tone(path, freq=660, seconds=1.2, rate=22050):
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        frames = bytearray()
        n = int(seconds * rate)
        for i in range(n):
            env = min(1, i / (0.01 * rate)) * math.exp(-3 * i / n)
            s = 0.6 * env * (math.sin(2 * math.pi * freq * i / rate) + 0.3 * math.sin(2 * math.pi * freq * 2.76 * i / rate))
            frames.extend(struct.pack("<h", int(max(-1, min(1, s)) * 32000)))
        w.writeframes(bytes(frames))


def main():
    if os.path.exists(OUT):
        shutil.rmtree(OUT)
    for sub in ("assets", "markers", "maps"):
        os.makedirs(os.path.join(OUT, sub))
    a = lambda *p: os.path.join(OUT, *p)

    usdz(a("assets", "heron.usdz"), box_usda("Heron", 0.25, 0.6, 0.15, (0.25, 0.42, 0.72)))
    usdz(a("assets", "lamp-brass.usdz"), box_usda("Lamp", 0.3, 1.2, 0.3, (0.78, 0.6, 0.3), 0.3, 1.0))
    usdz(a("assets", "lamp-steel.usdz"), box_usda("Lamp", 0.3, 1.2, 0.3, (0.7, 0.72, 0.75), 0.25, 1.0))
    usdz(a("assets", "lamp-ash.usdz"), box_usda("Lamp", 0.3, 1.2, 0.3, (0.86, 0.79, 0.66), 0.8, 0.0))
    usdz(a("assets", "key.usdz"), box_usda("Key", 0.12, 0.04, 0.3, (0.9, 0.75, 0.2), 0.2, 1.0))
    tone(a("assets", "bell.wav"))
    tone(a("assets", "chime.wav"), freq=990, seconds=0.6)

    def cover(x, y):
        t = y / 400
        return (int(20 + 30 * t), int(60 + 80 * t), int(70 + 60 * (1 - t)))

    png(a("thumbnail.png"), 600, 400, cover)
    png(a("assets", "map-fragment.png"), 400, 300,
        lambda x, y: (240, 236, 226) if (x // 25 + y // 25) % 2 else (196, 112, 60))

    for el in ("heron", "lamp", "fragment"):
        marker_png(a("markers", f"{el}.png"), el)

    heron_ll = offset(*SITE, east_m=-12, north_m=6)
    lamp_ll = offset(*SITE, east_m=8, north_m=-4)
    bell_ll = offset(*SITE, east_m=30, north_m=25)
    frag_ll = offset(*SITE, east_m=-20, north_m=-18)

    def gps(aid, ll, radius=15, fallback=True):
        return {"id": aid, "tier": "gps", "priority": 4, "lat": round(ll[0], 7), "long": round(ll[1], 7),
                "radiusM": radius, "allowPlaneFallback": fallback}

    def marker(aid, el, width=0.18):
        return {"id": aid, "tier": "image", "priority": 1, "imageFile": f"markers/{el}.png", "physicalWidthM": width,
                "transform": {"position": [0, 0.05, 0], "rotation": [0, 0, 0, 1], "scale": [1, 1, 1]}}

    def ident(pos=(0, 0, 0), scale=1):
        return {"position": list(pos), "rotation": [0, 0, 0, 1], "scale": [scale] * 3}

    manifest = {
        "schemaVersion": 1,
        "id": "sample-courtyard-hunt",
        "title": "Courtyard Hunt",
        "author": "Cuardach sample",
        "created": "2026-10-15T09:00:00Z",
        "cover": "thumbnail.png",
        "completionMessage": "You found everything. Thank you for looking closely.",
        "label": {
            "title": "Courtyard Hunt",
            "artist": "Cuardach sample",
            "year": "2026",
            "medium": "Augmented reality: 3D models, sound, text, printed markers",
            "statement": "A short walk around one courtyard, built to show what the app can do.\n\n"
                         "Find the heron to unlock the key. Stand with the lamp long enough and it changes. "
                         "After dark, a line of text appears that daytime visitors never see.",
            "altText": "A courtyard walk with five pieces: a heron, a lamp, a bell, a map fragment and a hidden key.",
        },
        "elements": [
            {
                "id": "heron", "name": "Blue Heron", "kind": "model", "asset": "assets/heron.usdz",
                "transform": ident(),
                "anchors": [
                    marker("heron-marker", "heron"),
                    {"id": "heron-geo", "tier": "geo", "priority": 0, "lat": round(heron_ll[0], 7),
                     "long": round(heron_ll[1], 7), "alt": 21.0, "heading": 90.0},
                    gps("heron-gps", heron_ll),
                ],
                "behaviours": [
                    {"id": "heron-idle", "trigger": "start", "retrigger": "never",
                     "actions": [[{"type": "rotate", "degrees": 20, "duration": 2}]]},
                    {"id": "heron-tap", "trigger": "tap", "retrigger": "afterComplete", "actions": [
                        [{"type": "rotate", "degrees": 360, "duration": 2}, {"type": "playAudio", "asset": "assets/chime.wav"}],
                        [{"type": "setState", "value": "found"}],
                        [{"type": "setState", "target": "key", "value": "visible"}],
                    ]},
                ],
                "label": {"title": "Blue Heron", "artist": "Cuardach sample", "year": "2026",
                          "medium": "3D model (placeholder geometry)",
                          "altText": "A tall, narrow blue block standing in for a heron, about knee height."},
                "credit": {"creator": "Cuardach contributors", "source": "Own work", "licence": "CC0-1.0"},
            },
            {
                "id": "key", "name": "Hidden Key", "kind": "model", "asset": "assets/key.usdz",
                "state": "hidden",
                "transform": ident((0.4, 0, 0)),
                "anchors": [marker("key-marker", "heron"), gps("key-gps", heron_ll)],
                "behaviours": [
                    {"id": "key-tap", "trigger": "tap", "retrigger": "never", "actions": [
                        [{"type": "scale", "factor": 1.6, "duration": 0.4}],
                        [{"type": "scale", "factor": 1.0, "duration": 0.4}],
                        [{"type": "setState", "value": "found"}],
                    ]},
                ],
                "label": {"altText": "A small gold bar, revealed after the heron is found."},
                "credit": {"creator": "Cuardach contributors", "source": "Own work", "licence": "CC0-1.0"},
            },
            {
                "id": "lamp", "name": "Lamp", "kind": "model", "asset": "assets/lamp-brass.usdz",
                "transform": ident(),
                "anchors": [marker("lamp-marker", "lamp"), gps("lamp-gps", lamp_ll)],
                "designSize": {"widthM": 0.3, "heightM": 1.2, "depthM": 0.3, "lockScale": True},
                "variants": [
                    {"id": "brass", "name": "Brass", "asset": "assets/lamp-brass.usdz", "note": "Warm at dusk; dates quickly in daylight."},
                    {"id": "steel", "name": "Brushed steel", "asset": "assets/lamp-steel.usdz", "note": "Reads as institutional against the brick."},
                    {"id": "ash", "name": "Ash", "asset": "assets/lamp-ash.usdz", "note": "Closest to the courtyard benches."},
                ],
                "behaviours": [
                    {"id": "lamp-tap", "trigger": "tap", "retrigger": "immediately", "actions": [[{"type": "cycleVariant"}]]},
                    {"id": "lamp-dwell", "trigger": "dwell", "retrigger": "never", "dwellS": 8, "proximityM": 4,
                     "actions": [[{"type": "setVariant", "variant": "ash"}], [{"type": "setState", "value": "found"}]]},
                ],
                "label": {"title": "Lamp, three finishes", "medium": "Product study at 1:1", "dimensions": "300 × 1200 × 300 mm",
                          "statement": "Tap to compare finishes in place. Look for eight seconds and it settles on the one the designer chose.",
                          "altText": "A floor lamp, 1.2 metres tall, as a simple column."},
                "credit": {"creator": "Cuardach contributors", "source": "Own work", "licence": "CC0-1.0"},
            },
            {
                "id": "bell", "name": "Bell", "kind": "audio", "asset": "assets/bell.wav",
                "transform": ident((0, 1.5, 0)),
                "playback": {"loop": False, "speed": 1, "muted": False, "audioFalloffM": 3},
                "anchors": [gps("bell-gps", bell_ll, radius=20)],
                "behaviours": [
                    {"id": "bell-near", "trigger": "proximityEnter", "retrigger": "afterComplete", "proximityM": 6,
                     "actions": [[{"type": "playAudio"}], [{"type": "delay", "seconds": 4}]]},
                ],
                "label": {"title": "Bell", "medium": "Sound"},
                "credit": {"creator": "Cuardach contributors", "source": "Synthesised", "licence": "CC0-1.0"},
            },
            {
                "id": "fragment", "name": "Map Fragment", "kind": "image", "asset": "assets/map-fragment.png",
                "faceViewer": True,
                "transform": ident((0, 1.2, 0)),
                "anchors": [marker("fragment-marker", "fragment"), gps("fragment-gps", frag_ll)],
                "behaviours": [
                    {"id": "fragment-tap", "trigger": "tap", "actions": [[{"type": "setState", "value": "found"}]]},
                ],
                "label": {"altText": "A chequered orange and cream square, like a torn piece of a map."},
                "credit": {"creator": "Cuardach contributors", "source": "Own work", "licence": "CC0-1.0"},
            },
            {
                "id": "night-text", "name": "After Dark", "kind": "text",
                "text": "The courtyard keeps its own hours.",
                "state": "hidden", "faceViewer": True,
                "transform": ident((0, 2.0, 0)),
                "anchors": [marker("night-marker", "lamp"), gps("night-gps", lamp_ll)],
                "behaviours": [
                    {"id": "night-window", "trigger": "timeWindow", "retrigger": "never",
                     "window": {"from": "18:00", "to": "06:00"}, "actions": [[{"type": "show", "duration": 2}]]},
                ],
                "label": {"altText": "A line of text that appears only between six in the evening and six in the morning."},
            },
        ],
        "annotations": [
            {"id": "crit-1", "author": "Lecturer", "kind": "question", "created": "2026-10-15T11:00:00Z",
             "elementId": "lamp", "offset": [0, 1.4, 0], "resolved": False,
             "text": "Does the ash finish hold up next to the benches at night, or only by day?"},
            {"id": "crit-2", "author": "Peer", "kind": "strength", "created": "2026-10-15T11:05:00Z",
             "elementId": "heron", "resolved": True, "text": "Unlocking the key from the heron is a nice surprise.",
             "reply": "Thanks, keeping it."},
        ],
    }
    manifest["siteHint"] = {"lat": SITE[0], "long": SITE[1], "radiusM": 60}
    with open(a("manifest.json"), "w") as f:
        json.dump(manifest, f, indent=2, sort_keys=True, ensure_ascii=False)
        f.write("\n")
    os.rmdir(a("maps"))
    print(f"wrote {OUT}")


if __name__ == "__main__":
    main()
