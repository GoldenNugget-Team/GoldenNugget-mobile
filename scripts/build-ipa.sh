#!/bin/zsh
# Build an unsigned device IPA from the Xcode project.
# Usage: ./scripts/build-ipa.sh [Debug|Release] [--clean]   (default: Release)
# Output: build/GoldenNuggetMobile.ipa (unsigned — sideload via AltStore/SideStore/LiveContainer)
#
# --clean wipes build/xderived first.  Reach for it after touching anything
# under Vendor/: an incremental build can refresh a .swiftmodule WITHOUT
# relinking the app, so the build reports success while the IPA still carries
# the previous logic.  The staleness check below catches that either way, which
# is why it looks only at the linked binary and not at the modules.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="Release"
CLEAN=0
for arg in "$@"; do
  case "$arg" in
    Debug|Release) CONFIG="$arg" ;;
    --clean)       CLEAN=1 ;;
    *) echo "unknown argument: $arg (expected Debug, Release or --clean)" >&2; exit 2 ;;
  esac
done

DERIVED="$(pwd)/build/xderived"
if (( CLEAN )); then
  echo "cleaning $DERIVED"
  rm -rf "$DERIVED"
fi

xcodebuild -project GoldenNuggetMobile.xcodeproj \
  -scheme GoldenNuggetMobile \
  -configuration "$CONFIG" \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=NO build

APP_PATH="$DERIVED/Build/Products/${CONFIG}-iphoneos/GoldenNuggetMobile.app"
BINARY="$APP_PATH/GoldenNuggetMobile"
if [ ! -f "$BINARY" ]; then
  echo "error: expected app binary not found at $BINARY" >&2
  exit 1
fi

# Post-build staleness check.  A .swift newer than the linked binary means the
# app was NOT relinked — the exact shape of "build says OK, IPA has old code".
# The scan set is clean: no .swift lives under .build, .swiftpm or patches.
stale="$(find Nugget Vendor -name '*.swift' -newer "$BINARY" -print -quit 2>/dev/null || true)"
if [ -n "$stale" ]; then
  echo "error: $stale is newer than $BINARY" >&2
  echo "       the app binary was not relinked; re-run with --clean" >&2
  exit 1
fi

mkdir -p build
rm -rf build/Payload build/GoldenNuggetMobile.ipa
mkdir -p build/Payload
cp -R "$APP_PATH" build/Payload/GoldenNuggetMobile.app

# Drop the loose icon PNGs actool leaves at the bundle root.
#
# The icon is an Icon Composer stack inside Assets.xcassets, and actool compiles
# it into Assets.car — but it *also* writes the primary icon out as loose PNGs
# (AppIcon60x60@2x.png, AppIcon76x76@2x~ipad.png).  Those files carry the LIGHT
# artwork only (measured: mean rgb ~(226,160,58) against the stack's light layer
# (214,143,36) and dark layer (109,67,30)), and a loose icon at the bundle root
# wins over the catalog's rendition — so shipping them puts the light icon on a
# dark home screen and the dark half never shows.  Same decision as the xtool
# bundle in xtool.yml, which ships the car and no loose icons.
#
# `ASSETCATALOG_COMPILER_STANDALONE_ICON_BEHAVIOR = none` does NOT suppress them:
# measured with --standalone-icon-behavior default/all/none, an icon stack emits
# the same two files every time (the setting governs .appiconset icons).
rm -f build/Payload/GoldenNuggetMobile.app/AppIcon*.png(N)

# Strip symbol tables out of the *copy* we are about to package, not out of
# DerivedData — the unstripped product stays available for debugging.  This
# build is unsigned (CODE_SIGNING_ALLOWED=NO above, the sideloader signs
# afterwards), so nothing is invalidated, and Release already asks Xcode for it
# via COPY_PHASE_STRIP; the explicit `strip` here makes the IPA lean regardless
# of which configuration produced it.  Worth ~8.5 MB raw: 47% of the app binary
# and 33% of EMProxy is symbol table, nearly all Rust names from statically
# linked vendored libraries.
for macho in build/Payload/GoldenNuggetMobile.app/GoldenNuggetMobile \
            build/Payload/GoldenNuggetMobile.app/Frameworks/EMProxy.framework/EMProxy; do
  if [ -f "$macho" ]; then
    before="$(stat -f%z "$macho")"
    strip -S "$macho"
    echo "stripped $macho: $before -> $(stat -f%z "$macho") bytes"
  fi
done

(cd build && zip -qry GoldenNuggetMobile.ipa Payload)
python3 scripts/repack-ipa.py build/GoldenNuggetMobile.ipa
rm -rf build/Payload

echo "done: build/GoldenNuggetMobile.ipa (unsigned, ${CONFIG})"
