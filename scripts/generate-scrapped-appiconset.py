#!/usr/bin/env python3
"""Generate `ScrappedIcon.appiconset` in Telegram's exact shape.

The alternate icon rendered a theme-aware but empty placeholder on iOS 27.
Eight earlier builds varied the plist keys and the asset kind one axis at a
time, but never the combination that Telegram actually ships:

    classic .appiconset  +  CFBundleIconFiles  +  UIPrerenderedIcon

`Telegram/Telegram-iOS/Info.plist` declares its alternates as
`CFBundleIconFiles: [<appiconset name>]` with `UIPrerenderedIcon: true`, and
`AppIcons.xcassets/BlackIcon.appiconset/Contents.json` is a full 18-entry
iphone/ipad/ios-marketing matrix. Those alternates work in the field, so the
matrix is copied verbatim here instead of guessed.

The 1024x1024 master is opaque and was upscaled from a 180x180 source, so it
proves the mechanism rather than the artwork; replace it with the real master
when one exists.
"""

import argparse
import json
import pathlib
import subprocess
import sys

from PIL import Image

CATALOG = pathlib.Path(
    "layout/Applications/GoldenNuggetMobile.app/Assets.xcassets"
)
SET = CATALOG / "ScrappedIcon.appiconset"

# (idiom, points, scale) -> pixel size. Mirrors Telegram's BlackIcon matrix.
MATRIX = [
    ("iphone", 20, 2),
    ("iphone", 20, 3),
    ("iphone", 29, 2),
    ("iphone", 29, 3),
    ("iphone", 40, 2),
    ("iphone", 40, 3),
    ("iphone", 60, 2),
    ("iphone", 60, 3),
    ("ipad", 20, 1),
    ("ipad", 20, 2),
    ("ipad", 29, 1),
    ("ipad", 29, 2),
    ("ipad", 40, 1),
    ("ipad", 40, 2),
    ("ipad", 76, 1),
    ("ipad", 76, 2),
    ("ipad", 83.5, 2),
]


def px(points: float, scale: int) -> int:
    return int(round(points * scale))


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument(
        "master",
        nargs="?",
        default="assets-src/scrapped-1024.png",
        help="opaque 1024x1024 PNG master (default: %(default)s)",
    )
    args = ap.parse_args()
    master_path = pathlib.Path(args.master)
    if not master_path.exists():
        print(
            f"нет мастера: {master_path}\n"
            "Передай путь к своему 1024x1024 PNG: generate-scrapped-appiconset.py <master>",
            file=sys.stderr,
        )
        return 1
    with Image.open(master_path) as im:
        master = im.convert("RGB")
        if master.size != (1024, 1024):
            print(f"мастер {master.size}, ожидался 1024x1024", file=sys.stderr)
            return 1

    if SET.exists():
        subprocess.run(["rm", "-rf", str(SET)], check=True)
    SET.mkdir(parents=True)

    images = []
    for idiom, points, scale in MATRIX:
        side = px(points, scale)
        name = f"ScrappedIcon-{side}.png"
        master.resize((side, side), Image.LANCZOS).save(SET / name, optimize=True)
        size = f"{points:g}x{points:g}"
        images.append(
            {
                "filename": name,
                "idiom": idiom,
                "scale": f"{scale}x",
                "size": size,
            }
        )

    # Telegram leaves the marketing slot unnamed; we ship a real 1024 so the set
    # is self-contained.
    master.save(SET / "ScrappedIcon-1024.png", optimize=True)
    images.append(
        {
            "filename": "ScrappedIcon-1024.png",
            "idiom": "ios-marketing",
            "scale": "1x",
            "size": "1024x1024",
        }
    )

    (SET / "Contents.json").write_text(
        json.dumps({"images": images, "info": {"author": "xcode", "version": 1}},
                   indent=2) + "\n"
    )
    print(f"{SET}: {len(images)} записей, {len(list(SET.glob('*.png')))} png")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
