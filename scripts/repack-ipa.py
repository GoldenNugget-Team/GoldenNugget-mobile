#!/usr/bin/env python3
"""Recompress an IPA in place with maximum deflate, verifying every entry.

xtool stores every zip entry uncompressed (compress_type 0), so a 15 MB Mach-O
lands in the IPA as 15 MB of bytes.  Deflating it costs nothing and takes the
same payload to roughly a third.  This is safe on a *signed* IPA: the code
signature covers the Mach-O and _CodeSignature/CodeResources, not the zip
container, so recompressing does not invalidate it.

The one thing that would be lost is st_mtime, so each entry's timestamp is
carried over from the source archive.  Entry order and the external attributes
(which carry the +x bit on the app binary) are preserved as well.

Usage: repack-ipa.py <file.ipa> [...]
"""
import os
import shutil
import sys
import tempfile
import zipfile

DEFLATE = zipfile.ZIP_DEFLATED


def repack(path: str) -> tuple[int, int, int]:
    with zipfile.ZipFile(path) as src:
        infos = src.infolist()
        raw = sum(i.file_size for i in infos)
        payloads = {i.filename: src.read(i.filename) for i in infos if not i.is_dir()}

    with tempfile.NamedTemporaryFile(delete=False, suffix=".ipa", dir=os.path.dirname(path)) as tmp:
        tmp_path = tmp.name

    with zipfile.ZipFile(tmp_path, "w", DEFLATE, compresslevel=9) as dst:
        for info in infos:
            if info.is_dir():
                dst.writestr(info.filename, b"")
                continue
            data = payloads[info.filename]
            if len(data) != info.file_size or zipfile.crc32(data) != info.CRC:
                raise SystemExit(f"error: {info.filename} does not match its source CRC")
            out = zipfile.ZipInfo(info.filename, date_time=info.date_time)
            out.external_attr = info.external_attr
            out.create_system = info.create_system
            out.comment = info.comment
            dst.writestr(out, data, DEFLATE, compresslevel=9)

    # Prove the rewrite is lossless before it replaces the original.
    with zipfile.ZipFile(tmp_path) as check, zipfile.ZipFile(path) as orig:
        if set(check.namelist()) != set(orig.namelist()):
            raise SystemExit("error: entry set changed during repack")
        for name in orig.namelist():
            if check.read(name) != orig.read(name):
                raise SystemExit(f"error: {name} differs after repack")

    before = os.path.getsize(path)
    shutil.move(tmp_path, path)
    return before, os.path.getsize(path), raw


def main(argv: list[str]) -> int:
    if not argv:
        print(__doc__, file=sys.stderr)
        return 2
    for path in argv:
        if not path.endswith(".ipa"):
            print(f"skip (not an .ipa): {path}")
            continue
        if not os.path.isfile(path):
            print(f"error: no such file: {path}", file=sys.stderr)
            return 1
        before, after, raw = repack(path)
        print(f"{path}: {before:,} -> {after:,} bytes "
              f"({100 * (before - after) // max(before, 1)}% smaller, "
              f"payload {raw:,} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
