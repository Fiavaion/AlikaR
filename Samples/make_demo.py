#!/usr/bin/env python3
"""Builds Samples/studio-demo.arhunt/, a demo that works in any room with four
printed markers and nothing else: no GPS, no location anchors, no world map.

Four stations, one printed marker each (image anchors, 0.18 m wide):

  1-model   A product model with three colourways and finishes (tap cycles
            them), true-scale dimensions, a wall label and a credit.
  2-video   An H.264 video panel (tap to play) and an HEVC-with-alpha video
            ring (plays on its own, loops, muted).
  3-image   An image that reveals a hidden badge and plays a chime on tap, and
            a sound that plays when you move the phone close.
  4-text    Text that responds to dwelling and to the time of day.

Two spatial crit notes (one open, one resolved) show the crit feature.

The only third-party asset is the Khronos "WaterBottle" glTF sample (CC0 1.0,
Microsoft), downloaded at build time and checked against a pinned SHA-256.
It is converted here to USDZ (three colourways, textures resized to 1024 px).
Everything else (video, sound, images, markers) is generated, so the demo is
CC0 and safe to redistribute. Needs macOS (sips) and ffmpeg with libx264,
libfreetype and hevc_videotoolbox; the standard library otherwise.

    python3 -I Samples/make_demo.py
    swift run cuardach validate Samples/studio-demo.arhunt
"""

import hashlib
import json
import math
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import urllib.request
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)  # python3 -I does not put the script directory on the path
import make_sample as ms  # noqa: E402  (marker_png, png, tone, MarkerPattern port)

OUT = os.path.join(HERE, "studio-demo.arhunt")
FFMPEG = shutil.which("ffmpeg") or os.path.expanduser("~/.local/bin/ffmpeg")
FONT = "/System/Library/Fonts/Helvetica.ttc"

BOTTLE_URL = ("https://raw.githubusercontent.com/KhronosGroup/glTF-Sample-Assets/main/"
              "Models/WaterBottle/glTF-Binary/WaterBottle.glb")
BOTTLE_SHA256 = "b337e526fd6a162013c2984aeec163f5fbb4f717252724dfc3f3458bd51df94b"

CC0 = "CC0-1.0"
OWN = {"creator": "Cuardach contributors", "source": "Generated for this demo", "licence": CC0}


# --- Downloads (untrusted data: fetched, hashed, parsed, never executed) -----

def download(url, sha256, workdir):
    dest = os.path.join(workdir, os.path.basename(url))
    with urllib.request.urlopen(url, timeout=60) as r, open(dest, "wb") as f:
        shutil.copyfileobj(r, f)
    digest = hashlib.sha256(open(dest, "rb").read()).hexdigest()
    if digest != sha256:
        raise SystemExit(f"{url}: SHA-256 {digest} does not match the pinned {sha256}")
    return dest


# --- GLB (glTF 2.0 binary) reader, just enough for one textured triangle mesh -

def read_glb(path):
    d = open(path, "rb").read()
    if d[:4] != b"glTF" or struct.unpack_from("<I", d, 4)[0] != 2:
        raise SystemExit("not a glTF 2.0 binary")
    jl = struct.unpack_from("<I", d, 12)[0]
    j = json.loads(d[20:20 + jl])
    bl = struct.unpack_from("<I", d, 20 + jl)[0]
    return j, d[28 + jl:28 + jl + bl]


def accessor(j, b, index):
    a = j["accessors"][index]
    v = j["bufferViews"][a["bufferView"]]
    ncomp = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4}[a["type"]]
    fmt = {5126: "f", 5123: "H", 5125: "I"}[a["componentType"]]
    stride = v.get("byteStride") or struct.calcsize(fmt) * ncomp
    base = v.get("byteOffset", 0) + a.get("byteOffset", 0)
    out = []
    for i in range(a["count"]):
        vals = struct.unpack_from("<" + fmt * ncomp, b, base + i * stride)
        out.append(vals if ncomp > 1 else vals[0])
    return out


def image_bytes(j, b, index):
    v = j["bufferViews"][j["images"][index]["bufferView"]]
    return b[v.get("byteOffset", 0):v.get("byteOffset", 0) + v["byteLength"]]


# --- USDZ writer ----------------------------------------------------------------

def write_usdz(path, files):
    """files: [(name, bytes)], the .usda first. Entries are stored, 64-byte aligned."""
    with zipfile.ZipFile(path, "w", zipfile.ZIP_STORED) as z:
        for name, data in files:
            pos = z.fp.tell()
            header = 30 + len(name.encode())
            pad = (64 - (pos + header) % 64) % 64
            if 0 < pad < 4:
                pad += 64
            info = zipfile.ZipInfo(name, date_time=(2026, 10, 15, 0, 0, 0))
            info.compress_type = zipfile.ZIP_STORED
            if pad:
                info.extra = struct.pack("<HH", 0x1986, pad - 4) + b"\0" * (pad - 4)
            z.writestr(info, data)


def jpeg_1024(png_bytes, workdir, name):
    src = os.path.join(workdir, name + ".png")
    dst = os.path.join(workdir, name + ".jpg")
    open(src, "wb").write(png_bytes)
    subprocess.run(["sips", "-Z", "1024", "-s", "format", "jpeg", "-s", "formatOptions", "85", src, "--out", dst],
                   check=True, capture_output=True)
    return open(dst, "rb").read()


def recolour(jpeg, vf, workdir, name):
    src, dst = os.path.join(workdir, name + "-in.jpg"), os.path.join(workdir, name + "-out.jpg")
    open(src, "wb").write(jpeg)
    ffmpeg("-i", src, "-vf", vf, "-q:v", "3", dst)
    return open(dst, "rb").read()


def bottle_usda(mesh, finish):
    """UsdPreviewSurface for one finish: base texture file, roughness/metal override or None."""
    pts, nrm, uv, idx = mesh
    f = lambda t: ", ".join(f"({', '.join(f'{c:.5g}' for c in v)})" for v in t)
    tex = lambda name, node, space, extra="": f'''
        def Shader "{name}"
        {{
            uniform token info:id = "UsdUVTexture"
            asset inputs:file = @textures/{node}@
            float2 inputs:st.connect = </Bottle/Material/st.outputs:result>
            token inputs:sourceColorSpace = "{space}"
            token inputs:wrapS = "repeat"
            token inputs:wrapT = "repeat"{extra}
            float3 outputs:rgb
            float outputs:r
            float outputs:g
            float outputs:b
        }}
'''
    surface = []
    nodes = tex("Base", finish["base"], "sRGB")
    surface.append("color3f inputs:diffuseColor.connect = </Bottle/Material/Base.outputs:rgb>")
    nodes += tex("Normal", "normal.jpg", "raw", "\n            float4 inputs:scale = (2, 2, 2, 1)\n            float4 inputs:bias = (-1, -1, -1, 0)")
    surface.append("normal3f inputs:normal.connect = </Bottle/Material/Normal.outputs:rgb>")
    nodes += tex("ORM", "orm.jpg", "raw")
    surface.append("float inputs:occlusion.connect = </Bottle/Material/ORM.outputs:r>")
    if finish["rough"] is None:
        surface.append("float inputs:roughness.connect = </Bottle/Material/ORM.outputs:g>")
        surface.append("float inputs:metallic.connect = </Bottle/Material/ORM.outputs:b>")
    else:
        surface.append(f"float inputs:roughness = {finish['rough']}")
        surface.append(f"float inputs:metallic = {finish['metal']}")
    if finish["emissive"]:
        nodes += tex("Emissive", "emissive.jpg", "sRGB")
        surface.append("color3f inputs:emissiveColor.connect = </Bottle/Material/Emissive.outputs:rgb>")
    surf = "\n            ".join(surface)
    return f'''#usda 1.0
(
    defaultPrim = "Bottle"
    metersPerUnit = 1
    upAxis = "Y"
)

def Xform "Bottle" (
    kind = "component"
)
{{
    def Mesh "Body" (
        prepend apiSchemas = ["MaterialBindingAPI"]
    )
    {{
        int[] faceVertexCounts = [{", ".join(["3"] * (len(idx) // 3))}]
        int[] faceVertexIndices = [{", ".join(map(str, idx))}]
        point3f[] points = [{f(pts)}]
        normal3f[] normals = [{f(nrm)}] (
            interpolation = "vertex"
        )
        texCoord2f[] primvars:st = [{f(uv)}] (
            interpolation = "vertex"
        )
        uniform token subdivisionScheme = "none"
        rel material:binding = </Bottle/Material>
    }}

    def Material "Material"
    {{
        token outputs:surface.connect = </Bottle/Material/Surface.outputs:surface>

        def Shader "st"
        {{
            uniform token info:id = "UsdPrimvarReader_float2"
            string inputs:varname = "st"
            float2 outputs:result
        }}
{nodes}
        def Shader "Surface"
        {{
            uniform token info:id = "UsdPreviewSurface"
            {surf}
            token outputs:surface
        }}
    }}
}}
'''


def build_bottles(glb_path, assets_dir, workdir):
    j, b = read_glb(glb_path)
    prim = j["meshes"][0]["primitives"][0]
    at = prim["attributes"]
    # The sample's node is turned 180 degrees about Y and centred on the origin;
    # bake that in and stand the bottle on y = 0.
    lift = -min(p[1] for p in accessor(j, b, at["POSITION"]))
    pts = [(-x, y + lift, -z) for x, y, z in accessor(j, b, at["POSITION"])]
    nrm = [(-x, y, -z) for x, y, z in accessor(j, b, at["NORMAL"])]
    uv = [(u, 1 - v) for u, v in accessor(j, b, at["TEXCOORD_0"])]
    idx = accessor(j, b, prim["indices"])
    mesh = (pts, nrm, uv, idx)
    mat = j["materials"][0]
    pbr = mat["pbrMetallicRoughness"]
    tex_img = lambda t: j["textures"][t["index"]]["source"]
    textures = {
        "textures/base.jpg": jpeg_1024(image_bytes(j, b, tex_img(pbr["baseColorTexture"])), workdir, "base"),
        "textures/orm.jpg": jpeg_1024(image_bytes(j, b, tex_img(pbr["metallicRoughnessTexture"])), workdir, "orm"),
        "textures/normal.jpg": jpeg_1024(image_bytes(j, b, tex_img(mat["normalTexture"])), workdir, "normal"),
        "textures/emissive.jpg": jpeg_1024(image_bytes(j, b, tex_img(mat["emissiveTexture"])), workdir, "emissive"),
    }
    # Colourways are made by recolouring the base texture, so every viewer
    # shows them the same way (no reliance on shader tint inputs).
    textures["textures/base-ocean.jpg"] = recolour(textures["textures/base.jpg"], "hue=h=150", workdir, "ocean")
    textures["textures/base-mono.jpg"] = recolour(textures["textures/base.jpg"], "hue=s=0,curves=all='0/0 1/0.4'", workdir, "mono")
    finishes = {
        "bottle-original": dict(base="base.jpg", rough=None, metal=None, emissive=True),
        "bottle-ocean": dict(base="base-ocean.jpg", rough=None, metal=None, emissive=False),
        "bottle-mono": dict(base="base-mono.jpg", rough=0.85, metal=0.0, emissive=False),
    }
    for name, fin in finishes.items():
        usda = bottle_usda(mesh, fin)
        needed = ["textures/normal.jpg", "textures/orm.jpg", "textures/" + fin["base"]]
        if fin["emissive"]:
            needed.append("textures/emissive.jpg")
        write_usdz(os.path.join(assets_dir, name + ".usdz"),
                   [("bottle.usda", usda.encode())] + [(n, textures[n]) for n in needed])


# --- Generated media -----------------------------------------------------------

def ffmpeg(*args):
    subprocess.run([FFMPEG, "-hide_banner", "-loglevel", "error", "-y", *args], check=True)


def drawtext(text, size, x, y, color="white", extra=""):
    return (f"drawtext=fontfile={FONT}:text='{text}':fontsize={size}:fontcolor={color}:x={x}:y={y}{extra}")


def make_media(assets_dir, out_dir):
    out = lambda *p: os.path.join(assets_dir, *p)

    # H.264 panel: 8 s, 16:9, stereo pad. Small enough to AirDrop in a second.
    ffmpeg("-f", "lavfi", "-i",
           "gradients=s=1280x720:d=8:r=30:speed=0.04:c0=0x2E86AB:c1=0xF3A712:c2=0xE4572E:c3=0x1B1B3A:nb_colors=4:type=radial",
           "-f", "lavfi", "-i",
           "aevalsrc='0.16*(sin(2*PI*220*t)+sin(2*PI*277.18*t)+sin(2*PI*329.63*t))*(0.65+0.35*sin(2*PI*0.5*t))':s=44100:d=8",
           "-vf", ",".join([
               drawtext("Video panel", 84, "(w-text_w)/2", "h*0.34"),
               drawtext("H.264 with sound. Tap again to restart.", 38, "(w-text_w)/2", "h*0.34+110"),
               "drawbox=x='mod(t*160,1280)':y=620:w=120:h=22:color=white@0.9:t=fill",
           ]),
           "-af", "afade=t=in:d=0.3,afade=t=out:st=7.5:d=0.5",
           "-c:v", "libx264", "-crf", "27", "-preset", "medium", "-pix_fmt", "yuv420p", "-movflags", "+faststart",
           "-c:a", "aac", "-b:a", "96k", out("clip.mp4"))

    # HEVC with alpha: a pulsing colour disc on a transparent background.
    ffmpeg("-f", "lavfi", "-i",
           "gradients=s=540x540:d=6:r=24:speed=0.03:c0=0xE4572E:c1=0xF3A712:c2=0x2E86AB:c3=0xA8C686:nb_colors=4:type=spiral",
           "-f", "lavfi", "-i",
           "color=c=black:s=540x540:d=6:r=24,format=gray,"
           "geq=lum='255*clip((190+30*sin(2*PI*T/2)-hypot(X-W/2,Y-H/2))/10,0,1)'",
           "-filter_complex", "[0:v]format=rgb24[c];[1:v]format=gray[m];[c][m]alphamerge,format=bgra[v]",
           "-map", "[v]", "-c:v", "hevc_videotoolbox", "-alpha_quality", "0.8", "-b:v", "2M", "-tag:v", "hvc1",
           out("ring-alpha.mov"))

    # Opaque poster, and a badge with a transparent background (RGBA PNG).
    ffmpeg("-f", "lavfi", "-i", "gradients=s=1000x1000:d=1:r=1:c0=0x1B1B3A:c1=0xE4572E:c2=0xF3A712:nb_colors=3:type=linear:x0=0:y0=0:x1=1000:y1=1000",
           "-vf", ",".join([drawtext("TAP", 220, "(w-text_w)/2", "h*0.30"),
                            drawtext("this poster", 90, "(w-text_w)/2", "h*0.30+250")]),
           "-frames:v", "1", out("poster.png"))
    ffmpeg("-f", "lavfi", "-i", "gradients=s=800x800:d=1:r=1:c0=0x2E86AB:c1=0xA8C686:nb_colors=2:type=radial",
           "-f", "lavfi", "-i", "color=c=black:s=800x800:d=1:r=1,format=gray,"
           "geq=lum='255*clip((380-hypot(X-W/2,Y-H/2))/6,0,1)'",
           "-filter_complex",
           "[0:v]format=rgb24," + drawtext("Found it", 130, "(w-text_w)/2", "(h-text_h)/2") + "[c];"
           "[1:v]format=gray[m];[c][m]alphamerge,format=rgba[v]",
           "-map", "[v]", "-frames:v", "1", out("badge.png"))

    # A three-note chime (AAC in .m4a) and a short ping (WAV).
    notes = [(0.0, 659.25), (0.18, 830.61), (0.36, 987.77)]
    expr = "+".join(f"gte(t,{t0})*exp(-3.2*(t-{t0}))*sin(2*PI*{f}*(t-{t0}))" for t0, f in notes)
    ffmpeg("-f", "lavfi", "-i", f"aevalsrc='0.28*({expr})':s=44100:d=2.2", "-c:a", "aac", "-b:a", "96k", out("chime.m4a"))
    ms.tone(out("ping.wav"), freq=1320, seconds=0.5)

    # Cover: the title on the same palette.
    ffmpeg("-f", "lavfi", "-i", "gradients=s=1200x800:d=1:r=1:c0=0x1B1B3A:c1=0x2E86AB:c2=0xF3A712:nb_colors=3:type=linear",
           "-vf", ",".join([drawtext("Cuardach Studio Demo", 92, "(w-text_w)/2", "h*0.38"),
                            drawtext("Four markers. Every media type.", 44, "(w-text_w)/2", "h*0.38+130")]),
           "-frames:v", "1", os.path.join(out_dir, "thumbnail.png"))


# --- Manifest --------------------------------------------------------------------

def marker(aid, name):
    return {"id": aid, "tier": "image", "priority": 1, "imageFile": f"markers/{name}.png", "physicalWidthM": 0.18,
            "transform": {"position": [0, 0, 0], "rotation": [0, 0, 0, 1], "scale": [1, 1, 1]}}


def at(pos=(0, 0, 0), scale=1):
    return {"position": list(pos), "rotation": [0, 0, 0, 1], "scale": [scale] * 3}


def build_manifest():
    bottle_credit = {
        "creator": "Microsoft", "source": "Khronos glTF-Sample-Assets, WaterBottle (converted to USDZ, textures resized, two colourways added)",
        "licence": CC0, "url": "https://github.com/KhronosGroup/glTF-Sample-Assets/tree/main/Models/WaterBottle",
    }

    def text_el(eid, name, text, y, anchor_marker, state=None, behaviours=None, alt=None):
        el = {"id": eid, "name": name, "kind": "text", "text": text, "faceViewer": True,
              "transform": at((0, y, 0), 0.5),
              "anchors": [marker(f"{eid}-marker", anchor_marker)],
              "behaviours": behaviours or [],
              "label": {"altText": alt or text}}
        if state:
            el["state"] = state
        return el

    elements = [
        # 1. Model with variants
        {
            "id": "bottle", "name": "1 Model: water bottle", "kind": "model", "asset": "assets/bottle-original.usdz",
            "transform": at(),
            "anchors": [marker("bottle-marker", "bottle")],
            "designSize": {"widthM": 0.109, "heightM": 0.26, "depthM": 0.109, "lockScale": True},
            # Tapping cycles from the first entry, so the original colourway comes last:
            # the first tap then changes something visible.
            "variants": [
                {"id": "ocean", "name": "Ocean", "asset": "assets/bottle-ocean.usdz",
                 "note": "The same print recoloured blue-green. Calmer, reads as cold drinks."},
                {"id": "mono", "name": "Matte mono", "asset": "assets/bottle-mono.usdz",
                 "note": "Graphite and matte. Hides scratches best, feels the most serious."},
                {"id": "original", "name": "Original", "asset": "assets/bottle-original.usdz",
                 "note": "Glossy yellow with a red cap. Loud, and easy to find in a bag."},
            ],
            "behaviours": [
                {"id": "bottle-tap", "trigger": "tap", "retrigger": "immediately", "actions": [
                    [{"type": "cycleVariant"}],
                    [{"type": "setState", "value": "found"}],
                ]},
            ],
            "label": {
                "title": "Water bottle, three finishes", "artist": "Microsoft (model), Cuardach (colourways)", "year": "2017 / 2026",
                "medium": "Product study at 1:1, USDZ", "dimensions": "109 × 260 × 109 mm",
                "statement": "Tap the bottle to compare colourways and finishes in place. It is locked at its real size, so what you see on the table is what you would hold.",
                "altText": "A plastic water bottle about 26 centimetres tall, yellow with a red cap and a grey base, printed with a small red triangle.",
            },
            "credit": bottle_credit,
        },
        # 2. Video
        {
            "id": "clip", "name": "2 Video: panel", "kind": "video", "asset": "assets/clip.mp4",
            "transform": at((0, 0.02, 0), 0.45),
            "playback": {"loop": False, "speed": 1, "muted": False},
            "anchors": [marker("clip-marker", "clip")],
            "behaviours": [
                {"id": "clip-tap", "trigger": "tap", "retrigger": "immediately", "actions": [
                    [{"type": "setState", "value": "found"}],
                    [{"type": "playVideo"}],
                ]},
            ],
            "label": {"title": "Video panel", "medium": "H.264 video with sound, 8 seconds",
                      "statement": "Tap to play. It plays once, with sound, and a second tap restarts it.",
                      "altText": "A flat video panel with moving colour and a drifting white bar."},
            "credit": OWN,
        },
        {
            "id": "ring", "name": "2 Video: transparent ring", "kind": "video", "asset": "assets/ring-alpha.mov",
            "transform": at((0.4, 0.02, 0), 0.25),
            "playback": {"loop": True, "speed": 1, "muted": True},
            "anchors": [marker("ring-marker", "clip")],
            "behaviours": [
                {"id": "ring-start", "trigger": "start", "retrigger": "never", "actions": [[{"type": "playVideo", "loop": True}]]},
                {"id": "ring-tap", "trigger": "tap", "retrigger": "immediately", "actions": [[{"type": "playVideo", "loop": True}]]},
            ],
            "label": {"title": "Transparent video", "medium": "HEVC with alpha, looping, muted",
                      "statement": "No rectangle: the video has an alpha channel, so only the ring is drawn.",
                      "altText": "A pulsing disc of swirling orange, yellow and blue with no background."},
            "credit": OWN,
        },
        # 3. Image + sound
        {
            "id": "poster", "name": "3 Image: tap poster", "kind": "image", "asset": "assets/poster.png",
            "transform": at((0, 0.02, 0), 0.3), "faceViewer": False,
            "anchors": [marker("poster-marker", "poster")],
            "behaviours": [
                {"id": "poster-tap", "trigger": "tap", "retrigger": "afterComplete", "actions": [
                    [{"type": "setState", "value": "found"},
                     {"type": "setState", "target": "badge", "value": "visible"},
                     {"type": "scale", "factor": 0.345, "duration": 0.25},
                     {"type": "playAudio", "asset": "assets/chime.m4a"}],
                    [{"type": "scale", "factor": 0.3, "duration": 0.25}],
                ]},
            ],
            "label": {"title": "Poster", "medium": "Image and sound",
                      "statement": "Tap the poster: it chimes and reveals a badge that was hidden.",
                      "altText": "A square poster fading from navy to orange and yellow, with the words TAP this poster."},
            "credit": OWN,
        },
        {
            "id": "badge", "name": "3 Image: hidden badge", "kind": "image", "asset": "assets/badge.png",
            "state": "hidden", "faceViewer": True,
            "transform": at((0, 0.45, 0), 0.2),
            "anchors": [marker("badge-marker", "poster")],
            "behaviours": [
                {"id": "badge-tap", "trigger": "tap", "retrigger": "never", "actions": [
                    [{"type": "setState", "value": "found"}, {"type": "scale", "factor": 0.26, "duration": 0.25}],
                    [{"type": "scale", "factor": 0.2, "duration": 0.25}],
                ]},
            ],
            "label": {"title": "Hidden badge", "medium": "Transparent PNG",
                      "altText": "A round blue-green badge reading Found it, on a transparent background."},
            "credit": OWN,
        },
        {
            "id": "ping", "name": "3 Sound: proximity ping", "kind": "audio", "asset": "assets/ping.wav",
            "transform": at((0, 0.15, 0)),
            "playback": {"loop": False, "speed": 1, "muted": False, "audioFalloffM": 1},
            "anchors": [marker("ping-marker", "poster")],
            "behaviours": [
                {"id": "ping-near", "trigger": "proximityEnter", "retrigger": "afterComplete", "proximityM": 0.5,
                 "actions": [[{"type": "playAudio"}], [{"type": "delay", "seconds": 3}]]},
            ],
            "label": {"title": "Proximity ping", "medium": "Spatial sound",
                      "statement": "Move the phone to within about 50 cm of the poster and it pings. Pull back and come in again.",
                      "altText": "A short high ping that plays when the phone comes close to the poster."},
            "credit": OWN,
        },
        # 4. Text, dwell, time window
        text_el("slowlook", "4 Text: slow looking", "Hold still and look at this for four seconds.", 0.12, "slowlook",
                behaviours=[{"id": "slowlook-dwell", "trigger": "dwell", "retrigger": "never", "dwellS": 4, "proximityM": 2,
                             "actions": [[{"type": "show", "target": "stayed", "duration": 1.5}],
                                         [{"type": "setState", "target": "stayed", "value": "found"}]]}]),
        text_el("stayed", "4 Text: dwell reward", "Thank you for staying. Looking is the interaction.", 0.3, "slowlook",
                state="hidden", alt="A line of text that appears after you keep this marker in view for four seconds."),
        text_el("daytime", "4 Text: daytime line", "It is daytime. This line is only here between 6 am and 6 pm.", 0.5, "slowlook",
                state="hidden", alt="A line of text that appears between six in the morning and six in the evening.",
                behaviours=[{"id": "daytime-window", "trigger": "timeWindow", "retrigger": "never",
                             "window": {"from": "06:00", "to": "18:00"}, "actions": [[{"type": "show", "duration": 2}]]}]),
        text_el("nighttime", "4 Text: after dark line", "It is after dark. This line is only here between 6 pm and 6 am.", 0.5, "slowlook",
                state="hidden", alt="A line of text that appears between six in the evening and six in the morning.",
                behaviours=[{"id": "night-window", "trigger": "timeWindow", "retrigger": "never",
                             "window": {"from": "18:00", "to": "06:00"}, "actions": [[{"type": "show", "duration": 2}]]}]),
    ]

    return {
        "schemaVersion": 1,
        "id": "studio-demo",
        "title": "Cuardach Studio Demo",
        "author": "Cuardach contributors",
        "created": "2026-10-15T09:00:00Z",
        "cover": "thumbnail.png",
        "completionMessage": "That is the whole Studio tour: model, video, image, sound and text.",
        "label": {
            "title": "Cuardach Studio Demo",
            "artist": "Cuardach contributors",
            "year": "2026",
            "medium": "Augmented reality: 3D model, video, image, sound, text, printed markers",
            "statement": "Four printed markers, one for each kind of work. Put each flat on a table, point the camera at it, "
                         "and see what appears. Nothing here needs GPS, a scan or a particular room.",
            "altText": "A four-station demonstration of the app: a water bottle with three finishes, two videos, a poster with sound, and text that reacts to time.",
        },
        "elements": elements,
        "annotations": [
            {"id": "crit-1", "author": "Lecturer", "kind": "question", "created": "2026-10-15T11:00:00Z",
             "elementId": "bottle", "offset": [0.12, 0.3, 0], "resolved": False,
             "text": "Does the ocean colourway still look right next to the other things on your desk, or only on its own?"},
            {"id": "crit-2", "author": "Peer", "kind": "suggestion", "created": "2026-10-15T11:05:00Z",
             "elementId": "slowlook", "offset": [0, 0.2, 0], "resolved": True,
             "text": "The text is small at arm's length. Make it bigger?",
             "reply": "Done. It is half a metre wide now."},
        ],
    }


def main():
    if not os.path.isfile(FFMPEG):
        raise SystemExit("ffmpeg not found; install it or put it on PATH")
    if os.path.exists(OUT):
        shutil.rmtree(OUT)
    for sub in ("assets", "markers"):
        os.makedirs(os.path.join(OUT, sub))
    assets = os.path.join(OUT, "assets")

    with tempfile.TemporaryDirectory(prefix="cuardach-demo-dl-") as dl, \
            tempfile.TemporaryDirectory(prefix="cuardach-demo-tex-") as tex:
        glb = download(BOTTLE_URL, BOTTLE_SHA256, dl)
        build_bottles(glb, assets, tex)
    make_media(assets, OUT)

    for name in ("bottle", "clip", "poster", "slowlook"):
        ms.marker_png(os.path.join(OUT, "markers", f"{name}.png"), name)

    manifest = build_manifest()
    with open(os.path.join(OUT, "manifest.json"), "w") as f:
        json.dump(manifest, f, indent=2, sort_keys=True, ensure_ascii=False)
        f.write("\n")
    total = sum(os.path.getsize(os.path.join(d, n)) for d, _, ns in os.walk(OUT) for n in ns)
    print(f"wrote {OUT} ({total / 1e6:.1f} MB)")


if __name__ == "__main__":
    main()
