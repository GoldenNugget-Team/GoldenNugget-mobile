#!/usr/bin/env bash
# Make the Darwin SDK's clang builtin headers speak the toolchain's dialect.
#
# WHY THIS EXISTS
# ---------------
# `xtool dev build` gets its clang include directory from the SDK, not from the
# host toolchain: swift-build precompiles `_Builtin_intrinsics` by handing
# swift-frontend
#
#     -resource-dir <SDK>/usr/lib/swift/clang
#     -direct-clang-cc1-module-build <SDK>/usr/lib/clang/21/include/module.modulemap
#
# so the headers inside `XcodeDefault.xctoolchain` are compiled by whatever
# Swift toolchain is on PATH.  Those headers come from the Xcode the SDK was
# built from, and an Xcode newer than the toolchain ships intrinsics the
# toolchain's clang has no builtin for.  arm64-apple-ios26.0 (Swift 6.4.0's
# clang 21.0.0) against an iOS 27 SDK then dies before any project code is
# parsed, 16 times over:
#
#     arm_neon.h:50038: error: size of '__builtin_bit_cast' source type 'int'
#         does not match destination type 'int64_t' (4 vs 8 bytes)
#     arm_neon.h:50038:   __ret = __builtin_bit_cast(int64_t,
#                                __builtin_neon_vcvtns_s64_f32(__p0));
#
# The `int` is the tell: an unknown `__builtin_*` is only an implicit
# declaration in C, so it decays to `int` and `__builtin_bit_cast` then
# rejects the width.  The intrinsics missing from clang 21.0.0 are the fp16
# dot-product and fp16<->fp32 conversion family -- `__builtin_neon_vcvtns_s64_f32`,
# `__builtin_neon_vcvtps_u64_f32`, `__builtin_neon_vdotq_f32_f16`,
# `__builtin_neon_vmmlaq_f16` and friends -- which landed in LLVM after the
# toolchain was cut.  arm_neon.h (16 errors), arm_sve.h (20) and arm_sme.h (20)
# each carry them unguarded.
#
# HOW IT WORKS
# ------------
# The compiler's own resource dir already holds a version of each header that
# matches its builtins by construction, because they shipped together.  Copy
# those over the SDK's copies.  That is safe here because these headers are
# only ever fed to the clang that is compiling them: they are C headers of
# __builtin__ wrappers, nothing in the SDK's prebuilt .swiftmodule or .a
# reads them, and the project's own C sources (none -- Vendor/ ships
# prebuilt archives) are not affected.
#
# Each file is replaced with rm + cp, never `cp` over the top.  `xtool sdk
# install` hardlinks these headers -- to each other and to the pristine copies
# under the bundle's Xcode.app -- and on btrfs the include directories
# themselves share one inode, so all three paths below can be the same
# directory.  cp would write through every remaining link, editing Xcode.app's
# copies too, which is what makes the backup worthless.  (Worst case with rm
# the script just reports the same file twice.)
#
# Re-running is a no-op once the headers match, so this is safe to call from
# a build script on every build.
#
# CAVEATS
# -------
# * Reinstalling or updating the SDK (`xtool sdk install` / `xtool sdk
#   update`) puts Xcode's headers back.  Re-run this script afterwards.
# * A toolchain whose clang knows those intrinsics (Swift 6.5+, say) needs no
#   patch at all; this script notices nothing differs and does nothing.
# * Backups live in .backups/, which is gitignored -- they are ~600 KB of
#   upstream clang headers, and .backups/ is where the other patch scripts put
#   their copies.
#
# usage: scripts/fix-sdk-arm-headers.sh [--revert] [--check]
#
set -euo pipefail
cd "$(dirname "$0")/.."

# The headers whose intrinsics the toolchain may not know.  Kept as a list
# because arm_sve.h and arm_sme.h fail the same way and for the same reason;
# a future SDK that adds another such header needs one more line here.
HEADERS=(arm_neon.h arm_sve.h arm_sme.h)

BAK="$PWD/.backups/darwin-sdk-arm-headers"

die() { echo "error: $*" >&2; exit 1; }

# --- locate the SDK ---------------------------------------------------------
# `xtool sdk status` is the authority on where the SDK landed; the default
# path is only a fallback for when xtool is not on PATH (or not an AppImage
# that can answer).
sdk_path() {
    if command -v xtool >/dev/null 2>&1; then
        xtool sdk status 2>/dev/null |
            sed -n 's/^[[:space:]]*Path:[[:space:]]*//p' | head -1
    fi
}

SDK="$(sdk_path || true)"
SDK="${SDK:-$HOME/.swiftpm/swift-sdks/darwin.artifactbundle}"
[ -d "$SDK" ] || die "no Darwin SDK at $SDK -- run 'xtool sdk install <Xcode.xip>' first"

SDK_TOOLCHAIN="$SDK/Developer/Toolchains/XcodeDefault.xctoolchain"
[ -d "$SDK_TOOLCHAIN/usr/lib/swift/clang/include" ] ||
    die "$SDK is not the layout this script knows (no usr/lib/swift/clang/include)"

# --- locate the toolchain's own headers -------------------------------------
# Ask the compiler where it lives instead of guessing at swiftly's layout, so
# this keeps working under any toolchain manager.  -print-target-info reports
# .../usr/lib/swift/<platform>; two levels up is .../usr.
TC_USR="$(swift -print-target-info |
    python3 -c 'import json,sys; p=json.load(sys.stdin)["paths"]["runtimeLibraryPaths"][0]; print(p.split("/lib/swift/")[0])')"
TC_INCLUDE=""
for d in "$TC_USR"/lib/clang/*/include; do
    [ -d "$d" ] && TC_INCLUDE="$d"   # glob is sorted: last wins == newest
done
[ -n "$TC_INCLUDE" ] || die "no clang resource dir under $TC_USR/lib/clang"
TC_CLANG="$TC_USR/bin/clang"
[ -x "$TC_CLANG" ] || TC_CLANG="$(command -v clang || true)"
[ -n "$TC_CLANG" ] || die "no clang to verify with"

echo "sdk      : $SDK"
echo "toolchain: $TC_INCLUDE"

# --- the include dirs inside the SDK that hold a copy ----------------------
SDK_INCLUDES=("$SDK_TOOLCHAIN"/usr/lib/swift/clang/include)
for d in "$SDK_TOOLCHAIN"/usr/lib/clang/*/include; do
    [ -d "$d" ] && SDK_INCLUDES+=("$d")
done

# --- verify ----------------------------------------------------------------
# Compiling the headers for the SDK's own target is the only check worth
# trusting: it is exactly what swift-build does, minus the project.  Without
# this the build would fail 16 errors into an unrelated-looking module.
verify() {
    local sdk_version target probe
    sdk_version="$(basename "$(ls -d "$SDK"/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS*.sdk 2>/dev/null | head -1)" | sed 's/^iPhoneOS//; s/\.sdk$//')"
    target="arm64-apple-ios${sdk_version:-26.0}"
    probe="$(mktemp -t sdk-arm-headers.XXXXXX.c)"
    {
        for h in "${HEADERS[@]}"; do echo "#include <$h>"; done
        echo "int main(void) { return 0; }"
    } > "$probe"

    local dir rc=0 out
    for dir in "${SDK_INCLUDES[@]}"; do
        out="$("$TC_CLANG" -target "$target" -nostdinc -isystem "$dir" \
                    -x c -fsyntax-only "$probe" 2>&1)" || rc=1
        if [ "$rc" -ne 0 ]; then
            echo "verify failed for $dir (target $target):" >&2
            echo "$out" | head -20 >&2
            rm -f "$probe"
            return 1
        fi
    done
    rm -f "$probe"
    echo "verify ok: ${#HEADERS[@]} headers compile for $target"
}

case "${1:-}" in
    --check)
        verify
        exit 0
        ;;
    --revert)
        [ -d "$BAK" ] || die "no backup at $BAK -- nothing to revert"
        for h in "${HEADERS[@]}"; do
            [ -f "$BAK/$h" ] || { echo "warning: no backup of $h, skipping" >&2; continue; }
            for dir in "${SDK_INCLUDES[@]}"; do
                rm -f "$dir/$h" && cp "$BAK/$h" "$dir/$h"
                echo "reverted: $dir/$h"
            done
        done
        exit 0
        ;;
    '') ;;
    *) echo "usage: $0 [--revert|--check]" >&2; exit 2 ;;
esac

# --- patch -----------------------------------------------------------------
changed=0
for h in "${HEADERS[@]}"; do
    [ -f "$TC_INCLUDE/$h" ] || { echo "warning: $h not in the toolchain, skipping" >&2; continue; }
    for dir in "${SDK_INCLUDES[@]}"; do
        [ -f "$dir/$h" ] || continue
        cmp -s "$TC_INCLUDE/$h" "$dir/$h" && continue

        # Back up once, before anything is touched.  A second run finds the
        # backup already there and must not overwrite it with the copy it
        # wrote last time -- that would destroy the only pristine original.
        if [ ! -f "$BAK/$h" ]; then
            mkdir -p "$BAK"
            cp "$dir/$h" "$BAK/$h"
        fi

        # rm + cp, not cp in place: see the hardlink note in the header.
        rm -f "$dir/$h"
        cp "$TC_INCLUDE/$h" "$dir/$h"
        changed=$((changed + 1))
        echo "patched: $dir/$h ($(wc -c < "$dir/$h" | tr -d ' ') bytes)"
    done
done

if [ "$changed" -eq 0 ]; then
    echo "sdk arm headers already match the toolchain, nothing to do"
else
    echo "backups: $BAK (revert with $0 --revert)"
fi

verify
