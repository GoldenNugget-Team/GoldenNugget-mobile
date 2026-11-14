#!/usr/bin/env bash
# Compile Assets.xcassets into Assets.car + AppIcon-partial.plist, on Linux.
#
# xtool cannot compile an asset catalog: it copies actool out of the darwin SDK
# into xtool/.xtool-tmp/actool and execs it, that copy loses the executable bit
# (0755 -> 0664), and the SDK actool is arm64 Mach-O which an x86_64 Linux host
# cannot execute even with the bit restored.
#
# Two icon paths:
#   * When a compiled car sits in the tree
#     (layout/Applications/GoldenNuggetMobile.app/Assets.car), that car is
#     authoritative and is copied through unchanged.  It is compiled by actool
#     on macOS — the .github/workflows/assets-car.yml workflow (push on
#     Assets.xcassets/** or manual `workflow_dispatch` with `commit: true`),
#     which commits the freshly compiled car back into the tree.  That is the
#     only route that renders the iconstack the way Xcode does (glass,
#     tintable appearance); regenerate it after any catalog edit (an outdated
#     car is how the device ends up showing yesterday's icon while Xcode,
#     which compiles the catalog fresh, shows today's).
#   * Otherwise scripts/compile-car-coreui.py renders the catalog's artwork
#     (layer PNG over the measured gradient/fill, per appearance) and feeds it
#     to coreui-car's compiler (GoldenNugget-Team/CoreUi-car) — pure Python,
#     the no-macOS fallback between workflow runs.  See that script's
#     docstring for the rendition ground truth and its limits.
#
# A build is then plain `xtool dev build` plus this step first.
#
# Keep in sync with project.yml / pbxproj / xtool.yml deploymentTarget.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CATALOG="$ROOT/layout/Applications/GoldenNuggetMobile.app/Assets.xcassets"
OUT="$ROOT/build/assets"

if [[ ! -d "$CATALOG" ]]; then
    echo "compile-assets: no catalog at $CATALOG" >&2
    exit 1
fi

COMMITTED_CAR="$ROOT/layout/Applications/GoldenNuggetMobile.app/Assets.car"

if [[ -s "$COMMITTED_CAR" ]]; then
    # Authoritative path.  The car was compiled by actool on macOS —
    # .github/workflows/assets-car.yml commits it after every catalog edit.
    echo "compile-assets: using the committed car ($(stat -c%s "$COMMITTED_CAR") bytes)"
    rm -rf "$OUT"
    mkdir -p "$OUT"
    cp "$COMMITTED_CAR" "$OUT/Assets.car"
    cp "$ROOT/layout/Applications/GoldenNuggetMobile.app/AppIcon-partial.plist" \
       "$OUT/AppIcon-partial.plist" 2>/dev/null || true
    echo "compile-assets: wrote $(ls -1 "$OUT" | wc -l) files to build/assets"
    exit 0
fi

echo "compile-assets: no committed car — compiling with coreui-car (fallback)"
python3 "$ROOT/scripts/compile-car-coreui.py" --output "$OUT"
# The appearance split is the whole point of this catalog, so it is checked
# where a build log can be read rather than only on a dark home screen.
python3 "$ROOT/scripts/check-car-appearances.py" "$OUT/Assets.car" \
    --require-dark --name AppIcon
python3 "$ROOT/scripts/check-car-appearances.py" "$OUT/Assets.car" --name ScrappedIcon
echo "compile-assets: wrote $(ls -1 "$OUT" | wc -l) files to build/assets"
