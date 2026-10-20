#!/bin/zsh
# Type-check the GoldenNuggetMobile sources WITHOUT running xcodebuild.
#
# Why this exists: `xcodebuild` needs to evaluate SwiftPM manifests, which means
# it shells out to `sandbox-exec` and writes ~/.swiftpm.  In a sandboxed
# environment that fails with "sandbox_apply: Operation not permitted", leaving
# no compiler gate at all.  `swiftc -typecheck` needs none of that — it only
# reads the SDK and the already-built .swiftmodule files, so it runs anywhere.
#
# The gate is only as fresh as those .swiftmodule files.  If you changed
# anything under Vendor/, rebuild once with Xcode first, or the check will
# report phantom "has no member" errors for symbols you just added.
#
# Usage: scripts/typecheck.sh [path/to/Products-iphoneos]
set -euo pipefail
cd "$(dirname "$0")/.."

PRODUCTS="${1:-}"
# `--first <pattern>` hoists every matching source to the front of the list.
# Load-bearing, not cosmetic: `swiftc -typecheck` reports diagnostics for the
# files it reaches and then stops, so a source that always errors (a stale
# vendored module turns `Nugget/Core/AfcFileExplorer.swift` into 28 phantom
# errors) means **nothing after it in the list is checked at all** — a
# brand-new file with a real error reads as a clean pass.  `scripts/typecheck.sh
# "" --first AppShell.swift` is how you check a file sitting behind that.
FIRST=""
if [[ "${2:-}" == "--first" ]]; then FIRST="${3:-}"; fi
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"

# Default to the FRESHEST Products dir.  Debug and Release are built at
# different times, and picking the older one turns API a recent build added into
# phantom "has no member" errors.  Prefer whichever main module is newest.
if [[ -z "$PRODUCTS" ]]; then
  best=""; best_mtime=0
  for candidate in build/xderived/Build/Products/Debug-iphoneos \
                   build/xderived/Build/Products/Release-iphoneos; do
    [[ -d "$candidate" ]] || continue
    mtime="$(stat -f '%m' "$candidate" 2>/dev/null || echo 0)"
    if (( mtime > best_mtime )); then best="$candidate"; best_mtime="$mtime"; fi
  done
  PRODUCTS="$best"
fi

if [[ -z "$PRODUCTS" || ! -d "$PRODUCTS/Minimuxer.swiftmodule" ]]; then
  echo "error: no built Swift modules found (looked in build/xderived/Build/Products/)" >&2
  echo "       build once with Xcode so the vendored modules exist, or pass the" >&2
  echo "       path to a Products-iphoneos directory as \$1." >&2
  exit 2
fi
echo "modules: $PRODUCTS"

# The source list is whatever SwiftPM resolves for the target — the same call
# scripts/sync-pbxproj-sources.py uses to reconcile the Xcode project, so the
# two cannot disagree.  It used to be scraped out of Package.swift with a regex
# for ".swift" literals, which silently returned an EMPTY list once the manifest
# declared its sources as a directory — and an empty list type-checks clean.
python3 - > /tmp/typecheck-sources.txt <<'PY'
import importlib.util
spec = importlib.util.spec_from_file_location(
    "sync_pbxproj", "scripts/sync-pbxproj-sources.py")
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
print("\n".join(mod.resolved_sources()))
PY

n=$(wc -l < /tmp/typecheck-sources.txt | tr -d ' ')
if (( n < 10 )); then
  echo "error: SwiftPM resolved only $n source(s) — refusing to report a clean gate" >&2
  exit 2
fi

# Hoist `--first` matches above everything else.
if [[ -n "$FIRST" ]]; then
  python3 - "$FIRST" <<'PYEOF'
import sys, pathlib
pattern = sys.argv[1]
path = pathlib.Path("/tmp/typecheck-sources.txt")
lines = path.read_text().splitlines()
head = [line for line in lines if pattern in line]
if not head:
    sys.exit("error: --first matched no source: %s" % pattern)
rest = [line for line in lines if pattern not in line]
path.write_text("\n".join(head + rest) + "\n")
print("checking first: %s" % ", ".join(head))
PYEOF
fi

echo "type-checking $n sources against $SDK"

# Staleness guard.  The gate reads the .swiftmodule files, not the vendored
# sources, so a Vendor/ edit that has not been rebuilt shows up as a phantom
# "has no member" / "extra argument" error on a perfectly good call site.
stale="$(find Vendor -name '*.swift' -newer "$PRODUCTS/Minimuxer.swiftmodule" -print -quit 2>/dev/null || true)"
if [[ -n "$stale" ]]; then
  echo "WARNING: $stale is newer than the modules in $PRODUCTS." >&2
  echo "         Errors naming a vendor symbol are PHANTOM until you rebuild with" >&2
  echo "         Xcode; errors in Nugget/ are real either way." >&2
fi

# `-target` must match the deployment target this project actually builds with
# (Package.swift, project.yml and Info.plist all say 26.0).  An older one turns
# every newer API into a *false* "only available in iOS 17.0 or newer" error --
# which is what ios16.0 did to `onChange(of:initial:_:)` in
# GoldenNuggetView.swift.  (Comments go above the command, never between its
# backslash-continued lines: a `#` there eats the joined line's remainder.)
xargs < /tmp/typecheck-sources.txt xcrun swiftc -typecheck \
  -disable-sandbox \
  -sdk "$SDK" \
  -target arm64-apple-ios26.0 \
  -swift-version 5 \
  -I "$PRODUCTS" \
  -I Vendor/IDevice.xcframework/ios-arm64/Headers \
  -I Vendor/AirliftFFI.xcframework/ios-arm64/Headers \
  -I Vendor/EMProxy.xcframework/ios-arm64/Headers \
  -I Vendor/libimobiledevice.xcframework/ios-arm64/Headers \
  > /tmp/typecheck.log 2>&1 || true

# `-disable-sandbox` is load-bearing: without it the driver sandboxes
# swift-plugin-server, which cannot run nested, so every SwiftUI `@State` macro
# fails to expand and the run reports ~80 phantom errors cascading out of
# GoldenNuggetView.swift ("cannot find '$bundleID' in scope", "cannot assign to property:
# 'logs' is immutable").  Journal only the line count, never `| head` — closing
# the pipe early SIGPIPEs the compiler and leaves a truncated log that reads as
# a clean pass.

# `grep -c` exits 1 on zero matches, hence the `|| true` guards.
errors=$(grep -c 'error:' /tmp/typecheck.log || true)
warnings=$(grep -c 'warning:' /tmp/typecheck.log || true)
own=$(grep -cE '^Nugget/(Core|Views|AppPackage|Tunnel|NuggetApp)[^:]*:.*(warning|error):' /tmp/typecheck.log || true)
echo "=== $errors error(s), $warnings warning(s) ($own in Nugget/ app code) ==="
if (( errors > 0 )); then
  echo "NOTE: swiftc -typecheck stops reporting after the first failing file, so" >&2
  echo "      sources behind it are NOT checked in this run.  To guarantee a" >&2
  echo "      file is checked, hoist it:  scripts/typecheck.sh \"$PRODUCTS\" --first <substring>" >&2
fi
exit "$errors"

