#!/usr/bin/env python3
"""Generate the .appiconset slots from the two 1024x1024 masters.

The catalog needs one PNG per (idiom, size, scale) slot, and each slot needs a
dark twin, because every compiler -- actool and coreui-car alike -- derives
the rendition's pixel geometry from the source file. A 1024 master pointed at
a 60x60@3x slot would be labelled 3x while carrying 1024px of bitmap, so the
slots are downscaled here rather than re-pointed at the master.

The masters are used verbatim: no flattening, no alpha changes, no colour
adjustments. This script only resamples.

The output is a classic (idiom/size/scale) appiconset, not the modern
"universal 1024" single-entry form. Xcode accepts both, but the classic form
is what every toolchain in this project parses, and having one catalog all
of them understand is worth more than the modern form's brevity.
"""

from __future__ import annotations

import json
import pathlib
import sys

from PIL import Image

# (idiom, point size as actool spells it, scale) for every slot a shipping iOS
# app is expected to carry: Settings, Spotlight, home screen, iPad, App Store.
SLOTS: list[tuple[str, str, str, int]] = [
    ("iphone", "20x20", "2x", 40),
    ("iphone", "20x20", "3x", 60),
    ("iphone", "29x29", "2x", 58),
    ("iphone", "29x29", "3x", 87),
    ("iphone", "40x40", "2x", 80),
    ("iphone", "40x40", "3x", 120),
    ("iphone", "60x60", "2x", 120),
    ("iphone", "60x60", "3x", 180),
    ("ipad", "20x20", "1x", 20),
    ("ipad", "20x20", "2x", 40),
    ("ipad", "29x29", "1x", 29),
    ("ipad", "29x29", "2x", 58),
    ("ipad", "40x40", "1x", 40),
    ("ipad", "40x40", "2x", 80),
    ("ipad", "76x76", "1x", 76),
    ("ipad", "76x76", "2x", 152),
    ("ipad", "83.5x83.5", "2x", 167),
    ("ios-marketing", "1024x1024", "1x", 1024),
]

DARK_APPEARANCE = [{"appearance": "luminosity", "value": "dark"}]


def slot_name(idiom: str, size: str, scale: str, dark: bool) -> str:
    base = f"AppIcon-{idiom}-{size}@{scale}"
    return f"{base}-dark.png" if dark else f"{base}.png"


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} <AppIcon.appiconset dir>", file=sys.stderr)
        return 2

    appiconset = pathlib.Path(sys.argv[1])
    masters = {
        False: appiconset / "icon-light.png",
        True: appiconset / "icon-dark.png",
    }
    for path in masters.values():
        if not path.is_file():
            print(f"missing master: {path}", file=sys.stderr)
            return 1

    images = {dark: Image.open(path).convert("RGBA") for dark, path in masters.items()}
    for dark, image in images.items():
        if image.size != (1024, 1024):
            print(f"{masters[dark]}: expected 1024x1024, got {image.size}", file=sys.stderr)
            return 1

    entries = []
    for idiom, size, scale, pixels in SLOTS:
        for dark in (False, True):
            name = slot_name(idiom, size, scale, dark)
            if pixels == 1024:
                # Keep the master byte-for-byte: re-encoding it would only
                # inflate the file and change pixels for no reason.
                target = appiconset / name
                target.write_bytes(masters[dark].read_bytes())
            else:
                resized = images[dark].resize((pixels, pixels), Image.LANCZOS)
                resized.save(appiconset / name, format="PNG", optimize=True)
            entry = {
                "size": size,
                "idiom": idiom,
                "filename": name,
                "scale": scale,
            }
            if dark:
                entry["appearances"] = DARK_APPEARANCE
            entries.append(entry)

    contents = {"images": entries, "info": {"author": "xcode", "version": 1}}
    (appiconset / "Contents.json").write_text(
        json.dumps(contents, indent=2) + "\n", encoding="utf-8"
    )

    pngs = len([p for p in appiconset.iterdir() if p.suffix == ".png"])
    print(f"{len(entries)} slots ({pngs} PNGs on disk), catalog rewritten")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
