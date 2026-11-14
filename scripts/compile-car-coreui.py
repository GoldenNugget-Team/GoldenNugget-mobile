#!/usr/bin/env python3
"""Compile Assets.car + AppIcon-partial.plist with CoreUI-car, on Linux.

The authoritative car for the app icon is compiled offline with coreui-car
(GoldenNugget-Team/CoreUi-car) — the pure-Python CoreUI asset-catalog compiler.
This script is the glue that renders the catalog's artwork and feeds it to
that compiler; `scripts/compile-assets.sh` runs it whenever no committed car
sits in the tree.

The rendition layout is byte-parallel to the on-device ground truth
(Projects/worsegestalt/tools/car/make_icon_car.py, verified rendering a real
icon — including the dark variant — by iOS CoreUI on an iPhone, iOS 27.2):

  * per icon set, one facet (`AppIcon` / `ScrappedIcon`) holding a
    MultisizeImage "holder" rendition (Part 218) whose SISM payload points at
    the 1024 pt entry, plus the concrete 1024x1024 rendition (Part 220);
  * KeyFormat token order [7 ThemeAppearance, 13 Localization, 12 Scale,
    15 Idiom, 16 Subtype, 9 Dimension2, 8 Dimension1, 24 DisplayGamut,
    21 VerticalSizeClass, 17 Identifier, 1 Element, 2 Part] — the order
    actool writes for iOS app catalogs;
  * MLEC payload with the real chunked shape: version 3 (light) / 1 (dark),
    compression 2 = gzip members, KCBC chunks of 341 pixel rows + tail
    (MLEC v0 bare payloads are ignored by on-device CoreUI);
  * rendition + facet Identifier < 0x8000 — a value >= 0x8000 reads negative
    as signed int16 and the icon silently falls back to a placeholder;
  * APPEARANCEKEYS names `UIAppearanceAny` (bits 0x0000), `UIAppearanceDark`
    (0x0001) and `ISAppearanceTintable` (0x000a);
  * deployment platform `ios` version 15.0, header fields copied from the
    proven ground truth (CoreUI 971, key semantics 2).

Artwork rendering: the Icon Composer background (automatic-gradient + glass
lighting) is reproduced as the measured vertical gradient stops above; the
catalog's layer PNG (1024x1024, Icon Composer bakes the layer's scale/position
into the export) is alpha-composited over it, once per appearance. The root
fill has no dark specialization — the measured dark background is a neutral
grey gradient (the document's dark fill specialization belongs to a squircle
layer that iOS keeps hidden). The stops are guarded: a changed fill colour
falls back to a flat fill rather than a wrong-tinted gradient.

The alternate icon (`ScrappedIcon`) ships its committed 1024 master as a
single light rendition on purpose — the alternate slot has only ever needed
"are there renditions at all" (see `scripts/check-car-appearances.py`).

Usage:
    scripts/compile-car-coreui.py [--output DIR]

Environment:
    COREUI_CAR  path to the coreui-car checkout (default ~/Projects/coreui-car)

Output: `<output>/Assets.car`, `<output>/AppIcon-partial.plist`.
Exit:   0 on success, 1 on anything the compiler or the post-check rejects.
"""
from __future__ import annotations

import argparse
import json
import os
import struct
import sys
import zlib
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
CATALOG = ROOT / "layout/Applications/GoldenNuggetMobile.app/Assets.xcassets"

sys.path.insert(0, str(HERE))  # scripts/ sibling imports (none yet, kept for parity)

# --------------------------------------------------------------------------
# coreui-car discovery


def coreui_car_path() -> Path:
    env = os.environ.get("COREUI_CAR")
    candidates = [Path(env)] if env else [Path.home() / "Projects" / "coreui-car"]
    for candidate in candidates:
        if (candidate / "coreui_car").is_dir():
            return candidate.resolve()
    searched = ", ".join(str(c) for c in candidates)
    raise SystemExit(f"compile-car-coreui: coreui-car checkout not found (set COREUI_CAR); searched {searched}")


COREUI = coreui_car_path()
sys.path.insert(0, str(COREUI))

from coreui_car import blocks, structs as S  # noqa: E402
from coreui_car.decode import gzip_compress  # noqa: E402
from coreui_car.writer import Appearance, BuildOptions, builder_from_options  # noqa: E402
from coreui_car.blocks import (CSIHeader, FacetToken, Flags, Metric, Slice,  # noqa: E402
                               TlvBlendModeOpacity, TlvBytesPerRow,
                               TlvEXIFOrientation, TlvMetrics, TlvSlices)

# Attribute-token order of a real iOS app catalog (see module docstring).
IOS_KEY_TOKENS = [7, 13, 12, 15, 16, 9, 8, 24, 21, 17, 1, 2]

APPEARANCE_ANY = 0
APPEARANCE_DARK = 1
IDIOM_PHONE = 1
ELEMENT = 85
PART_HOLDER = 218
PART_CONTENT = 220
# Facet + renditions share the Identifier attribute; must stay < 0x8000.
IDENTIFIER_APPICON = 0x4321
IDENTIFIER_SCRAPPED = 0x4322

MLEC_VERSION_LIGHT = 3
MLEC_VERSION_DARK = 1
KCBC_CHUNK_ROWS = 341


# --------------------------------------------------------------------------
# PNG decoding (stdlib only: 8-bit RGB/RGBA, non-interlaced)


class PNGError(Exception):
    pass


def decode_png(path: Path) -> tuple[int, int, bytearray]:
    """Return (width, height, RGBA8 rows packed contiguously)."""
    data = path.read_bytes()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise PNGError(f"{path.name}: not a PNG")
    width = height = 0
    bit_depth = color_type = interlace = 0
    idat = b""
    palette: bytes = b""
    off = 8
    while off < len(data):
        length = struct.unpack_from(">I", data, off)[0]
        kind = data[off + 4:off + 8]
        body = data[off + 8:off + 8 + length]
        if kind == b"IHDR":
            width, height, bit_depth, color_type, _, _, interlace = struct.unpack(">2I5B", body)
        elif kind == b"PLTE":
            palette = body
        elif kind == b"IDAT":
            idat += body
        elif kind == b"IEND":
            break
        off += 12 + length
    if bit_depth != 8:
        raise PNGError(f"{path.name}: bit depth {bit_depth} unsupported (need 8)")
    if interlace != 0:
        raise PNGError(f"{path.name}: interlaced PNGs are not supported")
    channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}.get(color_type)
    if channels is None:
        raise PNGError(f"{path.name}: color type {color_type} unsupported")
    if color_type == 3 and not palette:
        raise PNGError(f"{path.name}: indexed PNG without PLTE")

    raw = zlib.decompress(idat)
    stride = width * channels
    out = bytearray(width * height * 4)
    prev = bytearray(stride)
    pos = 0
    for y in range(height):
        if pos >= len(raw):
            raise PNGError(f"{path.name}: truncated image data")
        filter_kind = raw[pos]
        line = bytearray(raw[pos + 1:pos + 1 + stride])
        pos += 1 + stride
        if filter_kind == 1:
            for i in range(channels, len(line)):
                line[i] = (line[i] + line[i - channels]) & 255
        elif filter_kind == 2:
            for i in range(len(line)):
                line[i] = (line[i] + prev[i]) & 255
        elif filter_kind == 3:
            for i in range(len(line)):
                left = line[i - channels] if i >= channels else 0
                line[i] = (line[i] + ((left + prev[i]) >> 1)) & 255
        elif filter_kind == 4:
            for i in range(len(line)):
                left = line[i - channels] if i >= channels else 0
                up_left = prev[i - channels] if i >= channels else 0
                up = prev[i]
                p = left + up - up_left
                pa, pb, pc = abs(p - left), abs(p - up), abs(p - up_left)
                predictor = left if pa <= pb and pa <= pc else (up if pb <= pc else up_left)
                line[i] = (line[i] + predictor) & 255
        elif filter_kind != 0:
            raise PNGError(f"{path.name}: unknown filter {filter_kind}")
        prev = line
        base = y * width * 4
        if channels == 4:
            for x in range(width):
                s = x * 4
                d = base + s
                out[d] = line[s + 2]       # B
                out[d + 1] = line[s + 1]   # G
                out[d + 2] = line[s]       # R
                out[d + 3] = line[s + 3]   # A
        elif channels == 3:
            for x in range(width):
                s = x * 3
                d = base + x * 4
                out[d] = line[s + 2]
                out[d + 1] = line[s + 1]
                out[d + 2] = line[s]
                out[d + 3] = 255
        elif color_type == 3:  # indexed
            for x in range(width):
                entry = line[x] * 3
                d = base + x * 4
                out[d] = palette[entry + 2]
                out[d + 1] = palette[entry + 1]
                out[d + 2] = palette[entry]
                out[d + 3] = 255
        elif channels == 2:  # grey + alpha
            for x in range(width):
                d = base + x * 4
                g = line[x * 2]
                out[d] = out[d + 1] = out[d + 2] = g
                out[d + 3] = line[x * 2 + 1]
        else:  # greyscale
            for x in range(width):
                d = base + x * 4
                g = line[x]
                out[d] = out[d + 1] = out[d + 2] = g
                out[d + 3] = 255
    return width, height, out


# --------------------------------------------------------------------------
# Catalog reading


def parse_color(value: str) -> tuple[float, float, float]:
    """`display-p3:R,G,B,A` -> sRGB floats (P3 primaries converted)."""
    prefix, _, body = value.partition(":")
    parts = [float(p) for p in body.split(",")][:3]
    r, g, b = parts
    if prefix != "display-p3":
        return r, g, b
    # Display P3 -> sRGB, linear-light (ITU-R BT.709 primaries in, out).
    def to_linear(c: float) -> float:
        return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4

    def to_srgb(c: float) -> float:
        return 12.92 * c if c <= 0.0031308 else 1.055 * c ** (1 / 2.4) - 0.055

    lr, lg, lb = (to_linear(c) for c in (r, g, b))
    # Rows of the P3->sRGB matrix (computed once, inlined).
    m = ((1.2249401762809475, -0.2249401762809475, 0.0),
         (-0.04205695478451987, 1.0420569547845198, 0.0),
         (-0.019637554638465166, -0.07863604559082232, 1.0982736002292875))
    return tuple(round(min(1.0, max(0.0, to_srgb(
        m[i][0] * lr + m[i][1] * lg + m[i][2] * lb))), 4) for i in range(3))


def fill_colors(icon_json: dict) -> tuple[tuple[float, ...], tuple[float, ...]]:
    """The (light, dark) fill colour of the primary icon, as sRGB floats.

    The root `fill.automatic-gradient` is the only iOS-visible background (the
    squircle layers below it are hidden by default — their specialization says
    so), and it carries no dark specialization, so dark falls back to the
    first `automatic-gradient` colour under any `appearance: dark` fill
    specialization in the document — the colour the device's dark icon shows.
    """
    light = parse_color(icon_json["fill"]["automatic-gradient"])

    def walk(node, dark):
        if isinstance(node, dict):
            spec_appearance = node.get("appearance")
            value = node.get("value")
            if spec_appearance == "dark" and isinstance(value, dict) \
                    and "automatic-gradient" in value and dark is None:
                return parse_color(value["automatic-gradient"])
            for child in node.values():
                dark = walk(child, dark)
        elif isinstance(node, list):
            for child in node:
                dark = walk(child, dark)
        return dark

    return light, walk(icon_json, None) or light


# The Icon Composer background is not a flat colour: the automatic-gradient
# plus the glass lighting render as a vertical gradient. Measured from the
# reference actool render of this exact catalog (the pre-refractivity
# committed car, sampled on a pure-background column x=50 away from the
# artwork's refraction), as sRGB stops over the 1024-px canvas. The dark
# appearance's background is a neutral grey gradient — the document's dark
# fill specialization belongs to a squircle layer that iOS keeps hidden.
#
# These stops are only valid for the fill they were measured against
# (`EXPECTED_FILL_P3`). Any other fill falls back to a flat colour rather
# than shipping a wrong-tinted gradient; re-measure the stops from a fresh
# reference render before adopting a new fill.
EXPECTED_FILL_P3 = "display-p3:1.00000,0.85540,0.32426,1.00000"
LIGHT_GRADIENT_STOPS = [
    (0.000, (255, 179, 82)),
    (0.375, (255, 164, 41)),
    (0.500, (255, 158, 24)),
    (0.625, (255, 150, 5)),
    (0.750, (255, 149, 0)),
    (1.000, (255, 149, 0)),
]
DARK_GRADIENT_STOPS = [
    (0.000, (49, 49, 49)),
    (1.000, (20, 20, 20)),
]


def gradient_canvas(stops: list, width: int, height: int) -> bytearray:
    """BGRA canvas painted with a vertical multi-stop sRGB gradient."""
    canvas = bytearray(width * height * 4)
    for y in range(height):
        t = y / max(1, height - 1)
        top = 0
        while top < len(stops) - 1 and stops[top + 1][0] < t:
            top += 1
        (t0, c0), (t1, c1) = stops[top], stops[min(top + 1, len(stops) - 1)]
        f = 0.0 if t1 == t0 else (t - t0) / (t1 - t0)
        r, g, b = (round(c0[k] + (c1[k] - c0[k]) * f) for k in range(3))
        row = y * width * 4
        for x in range(width):
            i = row + x * 4
            canvas[i] = b          # BGRA memory order
            canvas[i + 1] = g
            canvas[i + 2] = r
            canvas[i + 3] = 255
    return canvas


def flat_canvas(fill: tuple[float, ...], width: int, height: int) -> bytearray:
    """BGRA canvas of one solid sRGB colour."""
    r, g, b = (round(c * 255) for c in fill)
    canvas = bytearray(width * height * 4)
    for i in range(0, len(canvas), 4):
        canvas[i] = b
        canvas[i + 1] = g
        canvas[i + 2] = r
        canvas[i + 3] = 255
    return canvas


def composite_over(canvas: bytearray, layer: tuple[int, int, bytearray]) -> bytearray:
    """Alpha-composite the BGRA layer over the BGRA canvas, in place."""
    _w, _h, layer_pixels = layer
    for i in range(0, len(layer_pixels), 4):
        a = layer_pixels[i + 3]
        if a == 0:
            continue
        if a == 255:
            canvas[i] = layer_pixels[i]
            canvas[i + 1] = layer_pixels[i + 1]
            canvas[i + 2] = layer_pixels[i + 2]
        else:
            alpha = a / 255
            canvas[i] = round(layer_pixels[i] * alpha + canvas[i] * (1 - alpha))
            canvas[i + 1] = round(layer_pixels[i + 1] * alpha + canvas[i + 1] * (1 - alpha))
            canvas[i + 2] = round(layer_pixels[i + 2] * alpha + canvas[i + 2] * (1 - alpha))
    return canvas


def icon_layer() -> tuple[int, int, bytearray]:
    """The primary icon's artwork layer, RGBA8, canvas-sized."""
    icon_json = json.loads((CATALOG / "AppIcon.icon/icon.json").read_text())
    for group in icon_json.get("groups", []):
        for layer in group.get("layers", []):
            name = layer.get("image-name")
            if name:
                return decode_png(CATALOG / "AppIcon.icon/Assets" / name)
    raise SystemExit("compile-car-coreui: no artwork layer in AppIcon.icon/icon.json")


# --------------------------------------------------------------------------
# Rendition assembly (ground-truth shape)


def build_mlec_payload(pixels: bytes, width: int, version: int) -> bytes:
    """MLEC v1/v3: counted KCBC chunks, each a gzip member of rows*4 BGRA bytes
    (3 strips of 341 rows + tail for 1024x1024)."""
    row_bytes = width * 4
    remaining = height = width
    chunks = []
    off = 0
    while remaining > 0:
        rows = min(KCBC_CHUNK_ROWS, remaining)
        chunks.append((rows, gzip_compress(pixels[off:off + rows * row_bytes])))
        off += rows * row_bytes
        remaining -= rows
    assert off == height * row_bytes
    return blocks.build_theme_payload_multi(S.COMP_GZIP, chunks, version=version,
                                            tag=b"KCBC")


def build_sism_payload(entries) -> bytes:
    """`SISM` multisize image-set payload: version 1, one entry each
    (width, height, index, idiom) — byte-parallel to the ground truth."""
    out = b"SISM" + struct.pack("<2I", 1, len(entries))
    for width, height, index, idiom in entries:
        out += struct.pack("<2I2H", width, height, index, idiom)
    return out


def build_holder_csi() -> bytes:
    """MultisizeImage rendition (Part 218): the icon-set holder whose SISM
    payload declares one 1024x1024 entry (index 1, any idiom)."""
    csi = CSIHeader(
        version=1,
        flags=Flags(),
        width=0,
        height=0,
        scale_factor=0,                 # real holder CSI scale is 0 (only the
                                        # key attribute Scale=1 matters)
        encoding=b"\x00\x00\x00\x00",   # encoding None (holder carries none)
        color_model=0,                  # ColorModel None
        modification_time=0,
        layout_type=S.LayoutType.MultisizeImage.value,
        name="AppIcon",                 # rewritten per facet by the caller's key
        tlv_length=0,
        bitmap_count=1,
        _bitmap_zero=0,
        rendition_length=0,
        tlvs=[TlvBlendModeOpacity(0, 0.0), TlvEXIFOrientation(1)],
        payload=None,
    )
    csi.payload = build_sism_payload([(1024, 1024, 1, 0)])
    return blocks.build_csi_block(csi)


def build_content_csi(name: str, pixels: bytes, width: int, version: int) -> bytes:
    """Concrete icon rendition (Part 220, OnePartScale) with the ground-truth
    TLV profile."""
    csi = CSIHeader(
        version=1,
        flags=Flags(),
        width=width,
        height=width,
        scale_factor=100,
        encoding=b"BGRA",
        color_model=S.COLORMODEL_RGB,
        modification_time=0,
        layout_type=S.LayoutType.OnePartScale.value,
        name=name,
        tlv_length=0,
        bitmap_count=1,
        _bitmap_zero=0,
        rendition_length=0,
        tlvs=[
            TlvSlices([Slice(0, 0, width, width)]),
            TlvMetrics(Metric(0, 0), Metric(0, 0), Metric(width, width)),
            TlvBlendModeOpacity(0, 1.0),
            TlvEXIFOrientation(1),
            TlvBytesPerRow(width * 4),
        ],
        payload=None,
    )
    csi.payload = build_mlec_payload(pixels, width, version)
    return blocks.build_csi_block(csi)


def key_values(*, appearance: int, scale: int, dimension2: int, part: int,
               identifier: int) -> list:
    """Rendition-key u16s ordered per IOS_KEY_TOKENS."""
    values = {t: 0 for t in IOS_KEY_TOKENS}
    values.update({
        7: appearance,       # ThemeAppearance
        12: scale,           # Scale
        15: IDIOM_PHONE,     # Idiom (1 = phone)
        9: dimension2,       # Dimension2 (0 = multisize holder, 1 = content)
        17: identifier,      # Identifier (facet grouping key)
        1: ELEMENT,          # Element
        2: part,             # Part (218 holder / 220 content)
    })
    return [values[t] for t in IOS_KEY_TOKENS]


def add_icon_set(builder, facet: str, identifier: int,
                 contents: list[tuple[str, bytes, int, int]]) -> None:
    """One facet: holder + content renditions, ground-truth keys."""
    builder.add_raw_facet(facet, blocks.build_facet_token(
        FacetToken(0, 0, [(1, ELEMENT), (2, PART_CONTENT), (17, identifier)])))
    builder.add_raw_rendition(
        blocks.encode_key_values(key_values(
            appearance=APPEARANCE_ANY, scale=1, dimension2=0, part=PART_HOLDER,
            identifier=identifier)),
        build_holder_csi())
    for name, pixels, width, version in contents:
        appearance = APPEARANCE_DARK if version == MLEC_VERSION_DARK else APPEARANCE_ANY
        builder.add_raw_rendition(
            blocks.encode_key_values(key_values(
                appearance=appearance, scale=1, dimension2=1, part=PART_CONTENT,
                identifier=identifier)),
            build_content_csi(name, pixels, width, version))


# --------------------------------------------------------------------------
# AppIcon-partial.plist


PARTIAL_PLIST = """\
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
\t<key>CFBundleIcons</key>
\t<dict>
\t\t<key>CFBundleAlternateIcons</key>
\t\t<dict>
\t\t\t<key>ScrappedIcon</key>
\t\t\t<dict>
\t\t\t\t<key>CFBundleIconName</key>
\t\t\t\t<string>ScrappedIcon</string>
\t\t\t</dict>
\t\t</dict>
\t\t<key>CFBundlePrimaryIcon</key>
\t\t<dict>
\t\t\t<key>CFBundleIconFiles</key>
\t\t\t<array>
\t\t\t\t<string>AppIcon60x60</string>
\t\t\t</array>
\t\t\t<key>CFBundleIconName</key>
\t\t\t<string>AppIcon</string>
\t\t</dict>
\t</dict>
\t<key>CFBundleIcons~ipad</key>
\t<dict>
\t\t<key>CFBundleAlternateIcons</key>
\t\t<dict>
\t\t\t<key>ScrappedIcon</key>
\t\t\t<dict>
\t\t\t\t<key>CFBundleIconName</key>
\t\t\t\t<string>ScrappedIcon</string>
\t\t\t</dict>
\t\t</dict>
\t\t<key>CFBundlePrimaryIcon</key>
\t\t<dict>
\t\t\t<key>CFBundleIconFiles</key>
\t\t\t<array>
\t\t\t\t<string>AppIcon60x60</string>
\t\t\t\t<string>AppIcon76x76</string>
\t\t\t</array>
\t\t\t<key>CFBundleIconName</key>
\t\t\t<string>AppIcon</string>
\t\t</dict>
\t</dict>
</dict>
</plist>
"""


# --------------------------------------------------------------------------
# main


def main(argv: list | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Compile the app icon's Assets.car with coreui-car.")
    parser.add_argument("--output", default=str(ROOT / "build/assets"),
                        help="output directory (default build/assets)")
    args = parser.parse_args(argv)

    icon_json = json.loads((CATALOG / "AppIcon.icon/icon.json").read_text())
    fill_raw = icon_json["fill"]["automatic-gradient"]
    if fill_raw == EXPECTED_FILL_P3:
        # Measured reference gradients (see the stops above).
        light_bg = gradient_canvas(LIGHT_GRADIENT_STOPS, 1024, 1024)
        dark_bg = gradient_canvas(DARK_GRADIENT_STOPS, 1024, 1024)
    else:
        # The document's fill changed since the gradients were measured.
        # Flat colour for both appearances until the stops are re-measured.
        print("compile-car-coreui: fill changed since the gradient was "
              "measured — rendering flat; re-measure LIGHT/DARK_GRADIENT_STOPS "
              "from a reference render", file=sys.stderr)
        light, dark = fill_colors(icon_json)
        light_bg = flat_canvas(light, 1024, 1024)
        dark_bg = flat_canvas(dark, 1024, 1024)
    layer = icon_layer()
    appicon_light = composite_over(light_bg, layer)
    appicon_dark = composite_over(dark_bg, layer)
    scrapped = decode_png(CATALOG / "ScrappedIcon.appiconset/ScrappedIcon-1024.png")
    scrapped_pixels = bytes(scrapped[2])

    opts = BuildOptions(
        deployment_platform="ios",
        deployment_platform_version="15.0",
        version_string="Xcode 26.1.1 (17B100) via AssetCatalogSimulatorAgent",
        authoring_tool="@(#)PROGRAM:CoreThemeDefinition  PROJECT:CoreThemeDefinition-653.2  [IIO-2784.1.3.3]",
        # Header fields copied verbatim from the ground-truth catalog that
        # installs with a visible icon on the device.
        coreui_version=971,
        main_version_string="@(#)PROGRAM:CoreUI  PROJECT:CoreUI-971.6",
        key_semantics=2,
    )
    builder = builder_from_options(opts, key_tokens=IOS_KEY_TOKENS)
    builder.add_appearance(Appearance("UIAppearanceAny", b"\x00\x00"))
    builder.add_appearance(Appearance("UIAppearanceDark", b"\x01\x00"))
    # Present in the ground truth even for light+dark-only icons.
    builder.add_appearance(Appearance("ISAppearanceTintable", b"\x0a\x00"))

    add_icon_set(builder, "AppIcon", IDENTIFIER_APPICON, [
        ("AppIcon_1024.png", bytes(appicon_light), 1024, MLEC_VERSION_LIGHT),
        ("AppIcon_1024_dark.png", bytes(appicon_dark), 1024, MLEC_VERSION_DARK),
    ])
    # The alternate ships a single light rendition on purpose.
    add_icon_set(builder, "ScrappedIcon", IDENTIFIER_SCRAPPED, [
        ("ScrappedIcon_1024.png", scrapped_pixels, 1024, MLEC_VERSION_LIGHT),
    ])

    data = builder.build()
    out = Path(args.output)
    out.mkdir(parents=True, exist_ok=True)
    car_path = out / "Assets.car"
    car_path.write_bytes(data)
    (out / "AppIcon-partial.plist").write_text(PARTIAL_PLIST)

    # Post-check the bytes we just wrote, so a shape drift fails here instead
    # of as a placeholder icon on the home screen.
    from coreui_car.car import load
    catalog = load(str(car_path))
    renditions = list(catalog.renditions)
    appearances: dict[int, int] = {}
    for rendition in renditions:
        value = rendition.attribute(7)  # 7 = ThemeAppearance
        appearances[value] = appearances.get(value, 0) + 1
    facets = catalog.facet_names()
    if "AppIcon" not in facets or "ScrappedIcon" not in facets:
        raise SystemExit(f"compile-car-coreui: facets missing: {facets}")
    dark_count = appearances.get(APPEARANCE_DARK, 0)
    if dark_count < 1:
        raise SystemExit("compile-car-coreui: no dark rendition in the built car")
    # Channel-order regression guard: decode the light content rendition and
    # check the top-left pixel against the measured gradient's first stop.
    # This is how the blue-background bug (RGBA bytes in a BGRA-tagged
    # rendition) would have been caught before it reached a device.
    for rendition in renditions:
        if rendition.attribute(2) == PART_CONTENT \
                and rendition.csi.name == "AppIcon_1024.png":
            from coreui_car import decode
            payload = blocks.parse_payload(rendition.csi.payload)
            pixels = b"".join(decode.decompress_chunk(payload.compression, raw)
                              for _header, raw in payload.chunks)
            b_, g_, r_ = pixels[0], pixels[1], pixels[2]
            expected = (LIGHT_GRADIENT_STOPS[0][1] if fill_raw == EXPECTED_FILL_P3
                        else tuple(round(c * 255) for c in light))
            if abs(r_ - expected[0]) > 2 or abs(g_ - expected[1]) > 2 or abs(b_ - expected[2]) > 2:
                raise SystemExit(
                    "compile-car-coreui: rendition pixel order check failed — "
                    f"top-left RGB({r_}, {g_}, {b_}), expected RGB{expected}. "
                    "The payload must carry BGRA bytes in BGRA-tagged renditions.")
            break

    print(f"compile-car-coreui: wrote {car_path} ({len(data)} bytes), "
          f"{len(renditions)} renditions across {sorted(facets)}, "
          f"appearances {dict(sorted(appearances.items()))} "
          f"(background: {'measured gradient' if fill_raw == EXPECTED_FILL_P3 else 'flat fill fallback'})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
