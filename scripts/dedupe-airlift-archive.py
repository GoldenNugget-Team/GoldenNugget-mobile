#!/usr/bin/env python3
"""De-duplicate AirliftFFI's static archive against the IDevice archive we already link.

## The problem

`AirliftFFI.xcframework` is a prebuilt Rust `staticlib` from AirCard-iOS.  A Rust
staticlib is self-contained: it carries a compiled copy of everything it depends
on, including `core`/`alloc` and its own vendored `idevice-ffi`.  This app links
`IDevice.xcframework` (`libidevice_ffi.a`), another Rust staticlib built with the
same toolchain, so both archives carry the same `alloc` with the same crate
disambiguator — the symbols come out *identically mangled* and the link fails:

    ld64.lld: error: duplicate symbol: <alloc::string::String>::from_utf8_lossy
      defined in string.rs:628 (library/alloc/src/string.rs:628)
      libidevice_ffi.a(alloc-9b236de5ba37b474.alloc...)
      libairlift_ffi.a(airlift_ffi-1b820065ad47369a.alloc-9b236de5ba37b474...)

1680 symbols are defined by both archives.  They cannot be separated at member
granularity: the offending CGU also defines 17 private symbols that the rest of
the archive references, so deleting the member breaks it, and keeping it keeps
the duplicates.

`-allow_multiple_definition` would paper over this, but xtool exposes no linker
flag and the manifest that owns the final link is regenerated into
`xtool/.xtool-tmp/` on every run.

## What this does instead

Two steps, both operating on the archive's own metadata:

  1. Delete every member whose defined symbols are *all* also defined by
     `libidevice_ffi.a`.  Nothing can reference such a member for a symbol it
     uniquely provides, so the linker loses nothing.
  2. In the members that define a mix, demote the shared symbols to local
     (clear `N_EXT` in the symbol table) while leaving the code, the names and
     every private symbol alone.  References from elsewhere in the archive then
     bind to `libidevice_ffi.a`'s copy — the same std the rest of the app
     already uses.

Only the symbol table changes; no instruction and no symbol name is touched, and
the FFI's public entry points are never demoted (they are not in the shared set,
and that is asserted).

## Why not `llvm-nm`

The vendored `llvm-nm` is LLVM 21, the archives are LLVM 22.1.8 objects, and it
reports `Unknown attribute kind (105)` and *skips* those members — silently
leaving a third of the symbols invisible, which makes every collision analysis
built on it wrong.  The Mach-O symbol table is read here directly instead, so
the result does not depend on the toolchain's LLVM version.

## Usage

    python3 scripts/dedupe-airlift-archive.py            # rewrite in place
    python3 scripts/dedupe-airlift-archive.py --check    # report only

`libairlift_ffi.a.pristine` next to the archive is the untouched input, so
re-running is idempotent, and a failed assertion restores from it.
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
ARCHIVE = REPO / "Vendor/AirliftFFI.xcframework/ios-arm64/libairlift_ffi.a"
PRISTINE = ARCHIVE.with_suffix(".a.pristine")
IDEVICE = REPO / "Vendor/IDevice.xcframework/ios-arm64/libidevice_ffi.a"
HEADER = ARCHIVE.parent / "Headers/AirliftFFI/airlift.h"

MH_MAGIC_64 = 0xFEEDFACF
LC_SYMTAB = 0x2
N_STAB, N_TYPE, N_EXT = 0xE0, 0x0E, 0x01
N_UNDF, N_ABS, N_SECT = 0x0, 0x2, 0xE
NLIST_64_SIZE = 16


def ar_tool() -> str:
    """Locate LLVM or Apple's ar; GNU binutils cannot read Mach-O objects."""
    for candidate in (
        os.environ.get("LLVM_AR"),
        "llvm-ar",
        os.path.expanduser("~/.local/share/swiftly/toolchains/6.4.0/usr/bin/llvm-ar"),
    ):
        if not candidate:
            continue
        found = shutil.which(candidate) or (candidate if Path(candidate).is_file() else None)
        if found:
            return found
    if xcrun := shutil.which("xcrun"):
        result = subprocess.run([xcrun, "--find", "ar"], capture_output=True, text=True)
        if result.returncode == 0 and Path(result.stdout.strip()).is_file():
            return result.stdout.strip()
    sys.exit("no Mach-O ar found; set LLVM_AR to its path")


def symtab_of(data: bytes) -> tuple[int, int, int] | None:
    """(symoff, nsyms, stroff) of a 64-bit Mach-O image, or None if it has no symbols."""
    if len(data) < 32 or struct.unpack_from("<I", data, 0)[0] != MH_MAGIC_64:
        return None
    ncmds, = struct.unpack_from("<I", data, 16)
    offset = 32
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", data, offset)
        if cmd == LC_SYMTAB:
            symoff, nsyms, stroff, _strsize = struct.unpack_from("<IIII", data, offset + 8)
            return symoff, nsyms, stroff
        offset += cmdsize
    return None


def name_at(data: bytes, stroff: int, n_strx: int) -> str:
    if n_strx == 0:
        return ""
    end = data.index(b"\0", stroff + n_strx)
    return data[stroff + n_strx:end].decode("utf-8", "replace")


def externals(data: bytes) -> tuple[set[str], set[str], list[tuple[int, str, bool]]]:
    """(defined, undefined, entries) for the external symbols of a Mach-O image.

    `entries` carries the byte offset of every external symbol's `nlist_64` and
    **whether that symbol is a definition**, so a definition can be demoted to
    local later without touching code or names.  The flag is not redundant with
    `defined`: that set is deduplicated, so a name defined in one object and
    referenced in another cannot be told apart by membership alone, and demoting
    the *reference* leaves an undefined symbol the linker has to resolve from
    nowhere.  Debug (`N_STAB`) and local symbols are skipped: local symbols cannot
    collide between objects, and the archives are full of them — every Rust CGU
    has `ltmp0`…`ltmp8`, an `l_.str` and a `GCC_except_tableN` per function.
    """
    symtab = symtab_of(data)
    if symtab is None:
        return set(), set(), []
    symoff, nsyms, stroff = symtab
    defined: set[str] = set()
    undefined: set[str] = set()
    entries: list[tuple[int, str, bool]] = []
    for index in range(nsyms):
        base = symoff + index * NLIST_64_SIZE
        n_strx, n_type, _sect, _desc, _value = struct.unpack_from("<IBBHQ", data, base)
        if n_type & N_STAB or not n_type & N_EXT:
            continue
        name = name_at(data, stroff, n_strx)
        if not name:
            continue
        is_defined = n_type & N_TYPE in (N_SECT, N_ABS)
        entries.append((base, name, is_defined))
        if not is_defined:
            undefined.add(name)
        else:
            defined.add(name)
    return defined, undefined, entries


def extract(archive: Path, dest: Path) -> dict[str, Path]:
    """Unpack every member of `archive` into `dest`, keyed by member name."""
    archive = archive.resolve()
    result = subprocess.run([ar_tool(), "x", str(archive)], cwd=dest,
                            capture_output=True)
    if result.returncode != 0:
        sys.exit(f"llvm-ar failed to unpack {archive}: "
                 f"{result.stderr.decode(errors='replace').strip()}")
    # Apple's ar also extracts its symbol index, sometimes with mode 000.
    # It is archive metadata, not a Mach-O member to scan or re-archive.
    for path in dest.glob("__.SYMDEF*"):
        path.unlink()
    return {p.name: p for p in dest.iterdir() if p.is_file()}


def scan(archive: Path) -> tuple[dict[str, set[str]], set[str]]:
    """(symbols defined per member, every undefined symbol in the archive)."""
    with tempfile.TemporaryDirectory() as tmp:
        members = extract(archive, Path(tmp))
        defined: dict[str, set[str]] = {}
        undefined: set[str] = set()
        for name, path in members.items():
            got = externals(path.read_bytes())
            if got == (set(), set(), []):
                continue
            defined[name] = got[0]
            undefined |= got[1]
    return defined, undefined


def public_entry_points() -> set[str]:
    """The `al_*` functions the header declares, i.e. the library's whole point.

    Read from the header rather than hardcoded, so a FFI that grows a function
    gets its regression check for free.
    """
    if not HEADER.is_file():
        return set()
    return set(re.findall(r"\b(al_[a-z0-9_]+)\s*\(", HEADER.read_text()))


def analyse() -> dict:
    if not PRISTINE.is_file():
        sys.exit(f"missing {PRISTINE}; regenerate it from the AirCard-iOS checkout")
    if not IDEVICE.is_file():
        sys.exit(f"missing {IDEVICE}")

    airlift_defined, airlift_undefined = scan(PRISTINE)
    idevice_defined, _ = scan(IDEVICE)
    shared = set().union(*airlift_defined.values()) & set().union(*idevice_defined.values())

    redundant = sorted(name for name, symbols in airlift_defined.items()
                       if symbols and symbols <= shared)
    mixed = sorted(name for name, symbols in airlift_defined.items()
                   if symbols & shared and symbols - shared)
    kept_symbols = set().union(*[airlift_defined[n] for n in redundant + mixed]) - shared
    return {
        "defined": airlift_defined,
        "shared": shared,
        "redundant": redundant,
        "mixed": mixed,
        "kept": kept_symbols,
        "entry_points": {f"_{name}" for name in public_entry_points()},
    }


def rewrite(report: dict) -> None:
    shared, redundant, entry_points = report["shared"], report["redundant"], report["entry_points"]
    with tempfile.TemporaryDirectory() as tmp:
        work = Path(tmp)
        members = extract(PRISTINE, work)
        for name in redundant:
            (work / name).unlink(missing_ok=True)

        stripped = 0
        for name in report["mixed"]:
            path = work / name
            data = bytearray(path.read_bytes())
            # Only definitions.  A shared name that this object merely *references*
            # must keep N_EXT: clearing it would turn the reference into a local
            # undefined and the linker would have to invent it, which is a different
            # failure from the duplicate this is here to fix.
            for base, symbol, is_defined in externals(bytes(data))[2]:
                if is_defined and symbol in shared and symbol not in entry_points:
                    # Demote to local rather than delete the entry: erasing the
                    # name (n_strx = 0) leaves the linker with an anonymous symbol
                    # where a thread-local one is required, which fails with
                    # "TLVP_LOAD_PAGE… relocation requires that symbol be
                    # thread-local" for every Rust `thread_local!`/`Lazy` static.
                    # Clearing N_EXT keeps the name, the section and the TLS
                    # semantics, and only stops the definition from being
                    # exported — so the linker binds those references to
                    # libidevice_ffi.a's copy instead.
                    n_type = data[base + 4]
                    data[base + 4] = n_type & ~N_EXT
                    stripped += 1
            path.write_bytes(data)

        kept = sorted(p.name for p in work.iterdir() if p.is_file())
        if not kept:
            sys.exit("refusing to write an empty archive")
        out = work / "libairlift_ffi.a"
        # `rcs` also writes the symbol index; without it the linker cannot resolve
        # lazily and would pull in every member, which is the collision we removed.
        subprocess.run([ar_tool(), "rcs", str(out), *kept], cwd=work, check=True,
                       capture_output=True)
        before = ARCHIVE.stat().st_size
        shutil.copyfile(out, ARCHIVE)
        after = ARCHIVE.stat().st_size

    verify(report)
    print(f"dropped {len(redundant)} redundant members, demoted {stripped} duplicate "
          f"definitions to local in {len(report['mixed'])} mixed members")
    print(f"{before/1e6:.2f} MB -> {after/1e6:.2f} MB")


def verify(report: dict) -> None:
    """Assert the rewrite removed exactly what it meant to, and nothing else."""
    defined, _ = scan(ARCHIVE)
    exported = set().union(*defined.values())

    missing = report["entry_points"] - exported
    if missing:
        restore()
        sys.exit("rewrite dropped the FFI's entry points "
                 f"({', '.join(sorted(missing))}); archive restored from pristine")

    lost = (set().union(*report["defined"].values()) - exported) - report["shared"]
    if lost:
        restore()
        sys.exit(f"rewrite lost {len(lost)} symbol(s) that were not shared with "
                 f"libidevice_ffi.a, e.g. {sorted(lost)[0]}; archive restored")

    remaining = report["shared"] & exported
    if remaining:
        restore()
        sys.exit(f"{len(remaining)} duplicate definition(s) survive "
                 f"(e.g. {sorted(remaining)[0]}); archive restored from pristine")

    print(f"verified: {len(report['entry_points'])} entry points, "
          f"{len(report['shared'])} duplicates gone, "
          f"{len(report['kept'])} private symbols intact")


def restore() -> None:
    shutil.copyfile(PRISTINE, ARCHIVE)


def crate_of(member: str) -> str:
    """`<root>-<hash>.<crate>-<hash>.<crate>.<hash>-cgu.<n>.rcgu.o`, or `<lib>-<file>.o`."""
    parts = member.split(".")
    if len(parts) >= 3 and parts[0].startswith("airlift_ffi-"):
        return parts[1].split("-")[0]
    return parts[0].split("-")[0] if "-" in parts[0] else parts[0]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--check", action="store_true",
                        help="report what would change without writing")
    parser.add_argument("--verbose", action="store_true",
                        help="list every member instead of a summary per crate")
    args = parser.parse_args()

    report = analyse()
    shared, redundant, mixed = report["shared"], report["redundant"], report["mixed"]
    if not shared:
        print("nothing collides with libidevice_ffi.a — archive left alone")
        return 0

    by_crate: dict[str, list[str]] = {}
    for member in redundant:
        by_crate.setdefault(crate_of(member), []).append(member)
    stripped = sum(len(report["defined"][m] & shared) for m in mixed)

    print(f"{len(shared)} symbols are defined by both archives")
    print(f"  {len(redundant)} members define nothing of their own -> deleted")
    print(f"  {len(mixed)} members mix shared and private symbols -> "
          f"{stripped} definitions demoted to local, code kept")
    for crate in sorted(by_crate, key=lambda c: -len(by_crate[c]))[:12]:
        print(f"    {crate:24} {len(by_crate[crate]):4} members")
    if len(by_crate) > 12:
        print(f"    ... and {len(by_crate) - 12} more crates")
    if args.verbose:
        for member in redundant:
            print(f"    drop {member}")
        for member in mixed:
            print(f"    demote {member}")
    if args.check:
        print("--check: nothing written")
        return 0
    rewrite(report)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
