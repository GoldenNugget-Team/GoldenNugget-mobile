#!/usr/bin/env bash
#
# Rebuild the vendored idevice static library for iOS, with the patched jktcp.
#
#   Vendor/patches/jktcp          jktcp v0.1.7 + reorder buffer / duplicate ACKs
#   Vendor/IDevice.xcframework/ios-arm64/libidevice_ffi.a   the artifact
#
# Why this script exists rather than a `cargo build` in your terminal:
#
#   * the toolchain lives in this repository, under .rust/, via RUSTUP_HOME and
#     CARGO_HOME. Nothing is written to ~/.cargo or ~/.rustup, and nothing is
#     installed with Homebrew, so it also runs where those are unavailable.
#   * aws-lc-sys (the default crypto backend, and the one the shipped binary was
#     built with) needs cmake. The recipe takes it from the managed Python venv
#     rather than Homebrew, for the same reason.
#   * the jktcp version is pinned by the [patch.crates-io] stanza, so a `cargo
#     update` cannot silently walk the build back to the unpatched release.
#
# Usage:
#   scripts/build-idevice-ios.sh            # build only; print where the .a is
#   scripts/build-idevice-ios.sh --install  # also swap it into Vendor (backs up)
#
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
TOOLCHAIN_ROOT="$REPO/.rust"
RUST_VERSION="1.98.1"
UPSTREAM="https://github.com/jkcoxson/idevice.git"
UPSTREAM_TAG="v0.1.68"
TARGET="aarch64-apple-ios"

INSTALL=0
for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=1 ;;
    *) echo "usage: $0 [--install]" >&2; exit 2 ;;
  esac
done

# ---------------------------------------------------------------------------
# 1. Rust toolchain + iOS std
# ---------------------------------------------------------------------------
#
# The repo-local toolchain is the macOS path: its rustup-init is an
# aarch64-apple-darwin binary. On Linux the system toolchain already carries
# the iOS std, so use it as-is. An empty `.rust/cargo` must not be put ahead of
# it on PATH, and RUSTUP_HOME must not be repointed at a toolchainless
# directory, or the rustup `cargo` proxy stops finding its toolchain.

if [[ -x "$TOOLCHAIN_ROOT/cargo/bin/cargo" ]]; then
  export RUSTUP_HOME="$TOOLCHAIN_ROOT/rustup"
  export CARGO_HOME="$TOOLCHAIN_ROOT/cargo"
  export PATH="$CARGO_HOME/bin:$PATH"
elif command -v cargo >/dev/null 2>&1 \
  && rustup target list --installed 2>/dev/null | grep -qx "$TARGET"; then
  echo "==> using the system toolchain ($(cargo --version))"
else
  mkdir -p "$TOOLCHAIN_ROOT"
  export RUSTUP_HOME="$TOOLCHAIN_ROOT/rustup"
  export CARGO_HOME="$TOOLCHAIN_ROOT/cargo"
  export PATH="$CARGO_HOME/bin:$PATH"
  echo "==> installing rustup into $TOOLCHAIN_ROOT (nothing outside this repo)"
  curl -sSf -o "$TOOLCHAIN_ROOT/rustup-init" \
    https://static.rust-lang.org/rustup/dist/aarch64-apple-darwin/rustup-init
  chmod +x "$TOOLCHAIN_ROOT/rustup-init"
  "$TOOLCHAIN_ROOT/rustup-init" -y --no-modify-path --profile minimal \
    --default-toolchain "$RUST_VERSION"
fi

echo "==> $(rustc -vV | head -1)"
rustup target list --installed | grep -qx "$TARGET" \
  || rustup target add "$TARGET"

# ---------------------------------------------------------------------------
# 2. cmake for aws-lc-sys
# ---------------------------------------------------------------------------

PYENV="$HOME/.workbuddy/binaries/python/envs/default"
if ! command -v cmake >/dev/null 2>&1 && [[ -x "$PYENV/bin/pip" ]]; then
  echo "==> installing cmake into the managed venv"
  "$PYENV/bin/pip" install --quiet cmake
fi
if [[ -d "$PYENV/bin" ]]; then
  export PATH="$PYENV/bin:$PATH"
fi
command -v cmake >/dev/null 2>&1 \
  || { echo "error: cmake not found; aws-lc-sys cannot build without it" >&2; exit 1; }
echo "==> $(cmake --version | head -1)"
# CMake 4 removed compatibility with `cmake_minimum_required(VERSION <3.5)`,
# which aws-lc-sys still uses. Harmless (ignored) on CMake 3.
export CMAKE_POLICY_VERSION_MINIMUM=3.5

# ---------------------------------------------------------------------------
# 3. Upstream checkout, with the patch wired in
# ---------------------------------------------------------------------------

SRC="$TOOLCHAIN_ROOT/idevice"
if [[ ! -d "$SRC/.git" ]]; then
  echo "==> fetching $UPSTREAM $UPSTREAM_TAG"
  rm -rf "$SRC"
  git clone --quiet --depth 1 --branch "$UPSTREAM_TAG" "$UPSTREAM" "$SRC"
fi

echo "==> wiring in Vendor/patches/jktcp"
rm -rf "$SRC/vendor"
mkdir -p "$SRC/vendor"
cp -R "$REPO/Vendor/patches/jktcp" "$SRC/vendor/jktcp"

python3 - "$SRC/Cargo.toml" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
t = p.read_text()
if "[patch.crates-io]" not in t:
    anchor = 'members = ["ffi", "idevice", "tests", "tools"]\n'
    assert anchor in t, "workspace layout changed; update the anchor"
    t = t.replace(
        anchor,
        anchor
        + "\n# Patched jktcp (reorder buffer + duplicate ACKs).\n"
        + "[patch.crates-io]\n"
        + 'jktcp = { path = "vendor/jktcp" }\n',
    )
    p.write_text(t)
PY

# Upstream v0.1.68 is older than the revision the shipped .a was cut from, and is
# missing one exported symbol the Swift side links against. Append the pieces.
# Both are idempotent: they are skipped once the symbol is present.
echo "==> applying idevice-ffi patches"
python3 - "$SRC" "$REPO/Vendor/patches/idevice-ffi" <<'PY'
import pathlib, sys

src, patches = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])

jobs = [
    # (target, snippet, "already applied" marker, anchor to insert after, or None = append)
    (
        src / "idevice/src/lib.rs",
        patches / "take_socket.rs",
        "fn take_socket",
        "    pub fn get_socket(self) -> Option<Box<dyn ReadWrite>> {\n"
        "        self.socket\n"
        "    }\n",
    ),
    (src / "ffi/src/lib.rs", patches / "idevice_to_stream.rs", "fn idevice_to_stream", None),
]

for target, snippet, marker, anchor in jobs:
    body = target.read_text()
    if marker in body:
        print(f"    already present: {marker}")
        continue
    text = snippet.read_text().strip("\n")
    if anchor is None:
        body = body.rstrip("\n") + "\n\n" + text + "\n"
    else:
        assert anchor in body, f"anchor for {snippet.name} not found in {target}"
        body = body.replace(anchor, anchor + "\n\n" + text + "\n", 1)
    target.write_text(body)
    print(f"    applied {snippet.name} -> {target.relative_to(src)}")
PY

# The shipped idevice.h is newer than any tag we can pin, and two of its
# additions are ABI-relevant in ways a symbol diff cannot see. Both are kept as
# git patches so a fresh clone of the tag reproduces them exactly.
for P in factory_info should_preserve local_tunnel redact_pairing; do
  PATCH="$REPO/Vendor/patches/idevice-ffi/$P.patch"
  echo "==> applying idevice-ffi/$P.patch"
  if git -C "$SRC" apply --reverse --check "$PATCH" 2>/dev/null; then
    echo "    already applied"
  else
    git -C "$SRC" apply "$PATCH" \
      || { echo "error: $P.patch does not apply to $SRC" >&2; exit 1; }
    echo "    applied"
  fi
done

# Same class of bug, so assert on the things that actually broke rather than on
# the patches having applied: the FFI signature must match the shipped header
# (mobilebackup2_backup took factory_info as its 5th argument and crashed the
# app on the first delegate call without it), and the delegate must be able to
# reject a payload before it is written (without should_preserve a protective
# backup stores every photo and video it was meant to drain).
grep -q "^    factory_info: crate::plist_t,$" "$SRC/ffi/src/mobilebackup2.rs" \
  || { echo "error: mobilebackup2_backup still has no factory_info parameter" >&2; exit 1; }
grep -q "fn should_store_file" "$SRC/ffi/src/mobilebackup2.rs" \
  || { echo "error: the FFI delegate still cannot reject a payload before writing it" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 4. Build
# ---------------------------------------------------------------------------
#
# `lto` and `codegen-units` are overridden back to cargo defaults on purpose.
# The shipped archive was cut that way -- 1924 members, one codegen unit per
# crate -- while the workspace's own [profile.release] asks for lto + 1 CGU.
# Two reasons to match the shipped shape:
#
#   * LTO merges every string constant into one, and scripts/patch-idevice-
#     target-identifier.sh is an in-place 16-byte substitution on a literal.
#     Under LTO its one remaining "SourceIdentifier" is shared by all four
#     call sites, so patching it also rewrites the Info/List/Extract dicts.
#     At 16 CGUs the copy is per codegen unit and only send_request is hit.
#   * With lto + codegen-units=1 the app crashed non-deterministically in use;
#     at 16 CGUs it does not. Not root-caused -- matched, not explained.

if command -v xcrun >/dev/null 2>&1; then
  SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
else
  # On Linux there is no xcrun. Take the same iPhoneOS SDK the app itself is
  # built against from xtool, and hand cc-rs (aws-lc-sys) and bindgen the
  # answers xcrun would have given, so nothing shells out to a missing tool.
  SDK_ROOT="$(xtool sdk status 2>/dev/null | sed -n 's/^  Path: //p' | head -1)"
  if [[ -z "$SDK_ROOT" || ! -d "$SDK_ROOT" ]]; then
    echo "error: no xcrun, and xtool's Darwin SDK is not installed." >&2
    echo "       run 'xtool sdk install', then re-run." >&2
    exit 1
  fi
  SDK="$SDK_ROOT/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk"
  [[ -e "$SDK" ]] || { echo "error: no iPhoneOS.sdk inside $SDK_ROOT" >&2; exit 1; }
  if [[ -L "$SDK" ]]; then
    SDK="$(readlink -f "$SDK")"
  fi
  export SDKROOT="$SDK"
  export CC_aarch64_apple_ios="$(command -v clang)"
  export CFLAGS_aarch64_apple_ios="--target=arm64-apple-ios17.0 -isysroot $SDK"
  export AR_aarch64_apple_ios="$(command -v ar)"
  echo "==> no xcrun; cross-building against $(basename "$SDK") from the xtool SDK"

  # Some crates in the workspace are `cdylib`s, so cargo links a Mach-O dylib
  # even though what ships is the staticlib (which needs no linking). The Linux
  # clang driver does not pass `-platform_version`, and the swiftly toolchain's
  # own ld64.lld refuses platform iOS; the xtool Darwin toolset's ld64.lld does
  # link it, given the platform flags. Point rustc at a clang shim that supplies
  # all three so those incidental dylibs link.
  LD64="$SDK_ROOT/toolset/bin/ld64.lld"
  [[ -x "$LD64" ]] || { echo "error: no $LD64 in the xtool Darwin SDK" >&2; exit 1; }
  IOS_LINKER="$TOOLCHAIN_ROOT/ios-link.sh"
  cat >"$IOS_LINKER" <<EOF
#!/bin/sh
exec "$(command -v clang)" --target=arm64-apple-ios17.0 -isysroot "$SDK" \\
  -fuse-ld="$LD64" -Wl,-platform_version,ios,17.0,17.0 -Wl,-arch,arm64 "\$@"
EOF
  chmod +x "$IOS_LINKER"
  export CARGO_TARGET_AARCH64_APPLE_IOS_LINKER="$IOS_LINKER"
  echo "==> Mach-O linker: $LD64 via clang shim"
fi
echo "==> cargo build --release --target $TARGET"
(
  cd "$SRC/ffi"
  BINDGEN_EXTRA_CLANG_ARGS="--sysroot=$SDK" \
  IPHONEOS_DEPLOYMENT_TARGET=17.0 \
    cargo build --release --target "$TARGET" --features obfuscate \
      --config 'profile.release.lto=false' \
      --config 'profile.release.codegen-units=16'
)

BUILT="$SRC/target/$TARGET/release/libidevice_ffi.a"
[[ -f "$BUILT" ]] || { echo "error: expected $BUILT" >&2; exit 1; }

# The [patch.crates-io] swap leaves no fingerprint on the archive, so assert on
# the shape of the artifact rather than guessing it applied.
if ! ar t "$BUILT" | grep -c "^jktcp-" >/dev/null; then
  echo "error: $BUILT has no jktcp objects — the patch may not have applied" >&2
  exit 1
fi

# The pinned tag is older than the revision the shipped .a was cut from, and is
# missing one symbol the Swift side links (IdeviceGateway.launchAppPre17).
#
# On macOS this is verified by linking, not by nm: Xcode's nm cannot parse
# rustc 1.98 objects ("Unknown attribute kind"), while clang/ld handle them.
# A probe link is also the property that matters -- the symbol resolving to a
# definition in a linked arm64 binary means the app will link too.
#
# On Linux the probe link cannot run: the swift 6.4 ld64.lld refuses
# "platform iOS" and chokes on libSystem.tbd's arm64e-ios TAPI target. Check
# the archive's export directly with llvm-nm, which parses the Mach-O members.
PROBE="$(mktemp -d)"
trap 'rm -rf "$PROBE"' EXIT
if command -v xcrun >/dev/null 2>&1; then
  cat >"$PROBE/probe.c" <<'EOF'
struct IdeviceFfiError;
extern struct IdeviceFfiError *idevice_to_stream(void *, void **);
int main(void) {
    void *stream = 0;
    return idevice_to_stream(0, &stream) == 0;
}
EOF
  if ! clang -arch arm64 -isysroot "$SDK" -miphoneos-version-min=17.0 \
    -Wl,-undefined,dynamic_lookup -Wl,-no_fixup_chains \
    "$PROBE/probe.c" "$BUILT" -o "$PROBE/probe" 2>"$PROBE/ld.log"; then
    echo "error: probe link against $BUILT failed:" >&2
    cat "$PROBE/ld.log" >&2
    exit 1
  fi
  nm "$PROBE/probe" >"$PROBE/syms" 2>/dev/null || true
  echo "==> probe link resolves _idevice_to_stream: ok"
else
  NM="$(command -v llvm-nm || command -v nm)"
  "$NM" "$BUILT" >"$PROBE/syms" 2>/dev/null || true
fi
# `grep -q` would close the pipe early and, under `pipefail`, nm's SIGPIPE would
# read as "not found". Dump to a file and grep the file instead.
if ! grep -q "[Tt] _idevice_to_stream" "$PROBE/syms"; then
  echo "error: $BUILT does not export _idevice_to_stream" >&2
  exit 1
fi

echo "==> built: $BUILT ($(wc -c <"$BUILT") bytes)"
command -v lipo >/dev/null 2>&1 && lipo -info "$BUILT" || true

# ---------------------------------------------------------------------------
# 5. Install
# ---------------------------------------------------------------------------

DEST="$REPO/Vendor/IDevice.xcframework/ios-arm64/libidevice_ffi.a"
if [[ "$INSTALL" -eq 0 ]]; then
  echo
  echo "not installed. To swap it into the project:"
  echo "  cp \"$BUILT\" \"$DEST\""
  echo "or rerun with --install (the current archive is backed up first)."
  exit 0
fi

[[ -f "$DEST" ]] || { echo "error: no $DEST to replace" >&2; exit 1; }
STAMP="$(date +%Y%m%d-%H%M%S)"
# Outside the repo tree: these archives are 70-190 MB, `Vendor/patches/` is
# tracked, and GitHub rejects any push carrying a file over 100 MB.  `.backups/`
# is gitignored.
BACKUP_DIR="$REPO/.backups"
mkdir -p "$BACKUP_DIR"
BACKUP="$BACKUP_DIR/libidevice_ffi.a.$STAMP"
echo "==> backing up the current archive to $(basename "$BACKUP")"
cp "$DEST" "$BACKUP"
cp "$BUILT" "$DEST"
echo "==> installed $DEST"
