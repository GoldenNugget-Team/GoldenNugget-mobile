#!/usr/bin/env python3
"""Check that the AirliftFFI archive the app links is the one this source builds.

    scripts/check-airlift-install.py

Three archives are in play and only the middle one is linked:

    Vendor/AirliftFFI/rust-core/target/aarch64-apple-ios/release/libairlift_ffi.a
        what `cargo build --target aarch64-apple-ios` just produced
    Vendor/AirliftFFI.xcframework/ios-arm64/libairlift_ffi.a.pristine
        that build, kept as the de-duplication's input
    Vendor/AirliftFFI.xcframework/ios-arm64/libairlift_ffi.a
        the de-duplicated copy, and the only one the app links

The failure this exists to catch is the quiet one: the Rust is edited, the crate
is rebuilt, and the rebuild never reaches `Vendor/`, so the app links the
previous build and the fix is in the source but not on the device. Comparing the
`al_*` entry points does **not** catch it — the export set is the same 13 names
whichever build produced the archive, which is exactly what a first version of
this check reported: a stale archive and a current one both "matched". So the
evidence is content, not symbols:

  1  the pristine is the current build, byte for byte
  2  the linked copy's members are a subset of the pristine's, and there are
     strictly fewer of them — the de-duplication ran, and it ran on this build
  3  the linked copy's members are byte-identical to the pristine's, except for
     a bounded handful the de-duplication rewrote in place
  4  the `al_*` entry points are unchanged by all of that

Check 3 is a bound rather than a proof for a specific reason: the de-duplication
demotes 1680 duplicate definitions to local, which rewrites the members that
mixed shared and private symbols. It reports the count instead of hiding it, so a
number that grows is a question worth asking about.

What this cannot catch: a linked copy restored from a backup of an older build
whose changed members happen to be the same ones the de-duplication rewrote.
Re-running `scripts/build-airlift-ffi-ios.sh --install` is the fix for that.
"""

from __future__ import annotations

import hashlib
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BUILD = ROOT / "Vendor/AirliftFFI/rust-core/target/aarch64-apple-ios/release/libairlift_ffi.a"
XCF = ROOT / "Vendor/AirliftFFI.xcframework/ios-arm64"
PRISTINE = XCF / "libairlift_ffi.a.pristine"
LINKED = XCF / "libairlift_ffi.a"

# The de-duplication rewrites 17 members on this archive; a rebuild does not
# change how many it rewrites, but a *different* build can change what lands in
# them. Ten more than observed leaves room for a toolchain shifting a couple of
# CGUs without hiding a whole-archive swap.
REWRITTEN_MEMBERS_ALLOWED = 27

failures: list[str] = []


def fail(message: str) -> None:
    print(f"  ✗ {message}")
    failures.append(message)


def pass_(message: str) -> None:
    print(f"  ✓ {message}")


def read_archive(path: Path) -> dict[str, bytes]:
    """Members of a `ar` archive, by name.

    Names are read from the `#1/<len>` convention, which is what a Linux `ar`
    writes — GNU `ar t` agrees on the names this recovers, and the inner
    `libplist_shims.a` is GNU-format too (cc-rs builds it on the host). The
    symbol index (`//`, `__.SYMDEF`) is not a member and is skipped.
    """
    members: dict[str, bytes] = {}
    with path.open("rb") as handle:
        if handle.read(8) != b"!<arch>\n":
            raise ValueError(f"{path} is not an ar archive")
        while True:
            header = handle.read(60)
            if len(header) < 60:
                break
            name = header[0:16].decode("ascii", "replace").rstrip()
            size = int(header[48:58].decode().strip() or "0")
            data = handle.read(size)
            if size % 2:
                handle.read(1)
            if name.startswith("#1/"):
                length = int(name[3:])
                # The name length is padded to an even boundary, so it carries
                # trailing NULs; strip them or every reported name is unreadable.
                real = data[:length].decode("utf-8", "replace").rstrip("\x00").rstrip("/")
                # Apple's ar can encode the symbol index as a BSD long name.
                # It is metadata even in this form, not an added object member.
                if not real.startswith("__.SYMDEF"):
                    members[real] = data[length:]
            elif name not in ("/", "/SYM64/", "//", "__.SYMDEF", "__.SYMDEF SORTED"):
                members[name.rstrip("\x00").rstrip("/")] = data
    return members


def nm_tool() -> str:
    for name in ("llvm-nm", "nm"):
        from shutil import which

        found = which(name)
        if found:
            return found
    sys.exit("check-airlift-install: no llvm-nm or nm on PATH")


def entry_points(path: Path) -> set[str]:
    """The `al_*` C entry points an archive exports.

    `nm`'s exit code is ignored: the pristine archive has duplicate symbols
    across members and `llvm-nm` exits 1 while still listing every symbol, and
    under `pipefail` that would fail a pipeline that is otherwise fine.
    """
    listed = subprocess.run([nm_tool(), "-g", "--defined-only", str(path)],
                            capture_output=True, text=True).stdout
    return {token for line in listed.splitlines() for token in line.split()
            if token.startswith("_al_")}


def digest(path: Path) -> str:
    hasher = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            hasher.update(chunk)
    return hasher.hexdigest()


for archive in (BUILD, PRISTINE, LINKED):
    if not archive.is_file():
        sys.exit(f"check-airlift-install: no archive at {archive}")

# 1  The build reached Vendor.
if digest(BUILD) == digest(PRISTINE):
    pass_("pristine is the current aarch64-apple-ios build")
else:
    fail("the pristine is NOT the current build — the crate was rebuilt without "
         "--install, so the app still links the previous one")

build_members = read_archive(BUILD)
pristine_members = read_archive(PRISTINE)
linked_members = read_archive(LINKED)
print(f"    build {len(build_members)} members, pristine {len(pristine_members)}, "
      f"linked {len(linked_members)}")

# 2  The de-duplication ran, on this build, and dropped rather than added.
extra = sorted(set(linked_members) - set(pristine_members))
if extra:
    fail(f"{len(extra)} member(s) in the linked archive are not in the pristine one: "
         + ", ".join(extra[:3]))
elif len(linked_members) >= len(pristine_members):
    fail("the linked archive has no fewer members than the pristine — the "
         "de-duplication never ran on it")
else:
    pass_(f"linked ⊂ pristine: {len(pristine_members) - len(linked_members)} redundant "
          "members dropped")

# 3  Same bytes, except where the de-duplication rewrote members in place.
mismatched = [name for name, data in linked_members.items()
              if name in pristine_members and pristine_members[name] != data]
missing = sorted(name for name in linked_members if name not in pristine_members)
if mismatched:
    if len(mismatched) <= REWRITTEN_MEMBERS_ALLOWED:
        pass_(f"{len(mismatched)} member(s) rewritten by the de-duplication "
              f"(<= {REWRITTEN_MEMBERS_ALLOWED})")
    else:
        fail(f"{len(mismatched)} member(s) differ from the pristine, above the "
             f"{REWRITTEN_MEMBERS_ALLOWED} the de-duplication is expected to rewrite — "
             f"first: {sorted(mismatched)[:3]}")
else:
    pass_("every linked member is byte-identical to the pristine one")
if missing and not extra:
    pass_(f"{len(missing)} pristine member(s) dropped, as expected")

# 4  The public API survived the de-duplication.
built_entries = entry_points(BUILD)
linked_entries = entry_points(LINKED)
if built_entries == linked_entries:
    pass_(f"{len(linked_entries)} al_* entry point(s), unchanged")
else:
    fail(f"the linked archive exports {sorted(linked_entries)} but the build exports "
         f"{sorted(built_entries)}")

print("airlift install check passed" if not failures
      else f"{len(failures)} check(s) failed")
sys.exit(1 if failures else 0)
