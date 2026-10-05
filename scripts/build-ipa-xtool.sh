#!/usr/bin/env bash
# Build a signed release IPA on Linux with xtool.
#
# The order matters: scripts/compile-assets.sh has to run *before* xtool, because
# xtool copies whatever is already in build/assets/ into the bundle as ordinary
# resources.  It cannot compile the catalog itself — it execs
# xtool/.xtool-tmp/actool, and that copy never gets the executable bit, so the
# launch dies before any argument is parsed.  xtool.yml documents the details.
#
# scripts/fix-sdk-arm-headers.sh runs before xtool for a different reason: an
# SDK built from a newer Xcode ships clang builtin headers whose intrinsics the
# installed Swift toolchain has no builtin for, and swift-build dies building
# `_Builtin_intrinsics` before it ever looks at this project.  It is a no-op
# once the headers match, or on a toolchain new enough not to need it.
#
# Usage: ./scripts/build-ipa-xtool.sh [--clean]
# Output: xtool/GoldenNuggetMobile.ipa, repacked in place
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ "${1:-}" == "--clean" ]]; then
    # xtool does not clean its own staging app dir, so a .xcassets left in there
    # from an earlier run makes every later build try actool again and fail.
    echo "cleaning xtool staging and .build/out"
    rm -rf xtool/GoldenNuggetMobile.app xtool/.xtool-tmp
    rm -rf .build/out/Products/Release-iphoneos/GoldenNuggetMobile-App
fi

bash scripts/fix-sdk-arm-headers.sh

bash scripts/compile-assets.sh

echo "building with xtool"
xtool dev build -c release -i

python3 scripts/repack-ipa.py xtool/GoldenNuggetMobile.ipa

echo "done: xtool/GoldenNuggetMobile.ipa"
