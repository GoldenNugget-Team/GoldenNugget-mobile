#!/usr/bin/env python3
"""Report the appearance split of a compiled Assets.car, and fail if the dark
half is missing.

The app icon is the one asset in this project where "it compiled" and "it
works" are different claims: actool accepts a catalog that silently drops the
`luminosity=dark` entries of an `.appiconset`, and the resulting car looks
perfectly valid. The symptom only shows up on a dark home screen, long after
the build, so the check has to happen here instead.

The container is a BOM ("BOMStore") written big-endian; the rendition keys and
the FACETKEYS values inside it are little-endian. Layout, as emitted by actool
and by coreui-car's compiler alike:

    0x00  "BOMStore"
    0x08  version
    0x0c  blockCount
    0x10  indexOffset, 0x14 indexLength
    0x18  varsOffset,  0x1c varsLength
    index:  count u32, then (addr u32, len u32) per block
    vars:   count u32, then { blockID u32, nameLen u8, name }
    tree:   'tree' u32, version u32, childBlockID u32, blockSize u32,
            pathCount u32, isPathInternal u8, 8 reserved
    leaf:   isLeaf u16, count u16, forward u32, backward u32,
            then count * { valueBlockID u32, keyBlockID u32 }

KEYFORMAT names each slot of a rendition key, and the list is per catalog, so
the appearance slot is located by attribute id 7 rather than assumed.

Usage: check-car-appearances.py <Assets.car> [--require-dark] [--name AppIcon]
Exit:  0 when the expectations hold, 1 otherwise.
"""
import struct
import sys
from collections import Counter


class Bom:
    def __init__(self, path):
        self.d = open(path, "rb").read()
        if self.d[:8] != b"BOMStore":
            raise ValueError("not a BOM container: %r" % self.d[:8])
        index_off = struct.unpack_from(">I", self.d, 0x10)[0]
        vars_off = struct.unpack_from(">I", self.d, 0x18)[0]

        count = struct.unpack_from(">I", self.d, index_off)[0]
        self.blocks = {}
        for i in range(count):
            addr, length = struct.unpack_from(">2I", self.d, index_off + 4 + 8 * i)
            if addr:
                self.blocks[i] = (addr, length)

        nvars = struct.unpack_from(">I", self.d, vars_off)[0]
        self.vars = {}
        off = vars_off + 4
        for _ in range(nvars):
            block_id = struct.unpack_from(">I", self.d, off)[0]
            name_len = self.d[off + 4]
            self.vars[self.d[off + 5:off + 5 + name_len].decode("utf-8", "replace")] = block_id
            off += 5 + name_len

    def block(self, block_id):
        addr, length = self.blocks[block_id]
        return self.d[addr:addr + length]

    def key_format(self):
        kf = self.block(self.vars["KEYFORMAT"])
        count = struct.unpack_from("<I", kf, 8)[0]
        return [struct.unpack_from("<I", kf, 12 + 4 * i)[0] for i in range(count)]

    def renditions(self):
        """Yield (key values, rendition name) for every entry of RENDITIONS."""
        header = self.block(self.vars["RENDITIONS"])
        child = struct.unpack_from(">I", header, 8)[0]
        n = struct.unpack_from(">H", self.block(child), 2)[0]
        for i in range(n):
            value_id, key_id = struct.unpack_from(">2I", self.block(child), 12 + 8 * i)
            key = self.block(key_id)
            values = struct.unpack("<%dH" % (len(key) // 2), key)
            name = self.block(value_id)[40:168].rstrip(b"\x00").decode("utf-8", "replace")
            yield values, name

    def appearance_rows(self):
        if "APPEARANCEKEYS" not in self.vars:
            return []
        header = self.block(self.vars["APPEARANCEKEYS"])
        child = struct.unpack_from(">I", header, 8)[0]
        n = struct.unpack_from(">H", self.block(child), 2)[0]
        rows = []
        for i in range(n):
            value_id, key_id = struct.unpack_from(">2I", self.block(child), 12 + 8 * i)
            key = self.block(key_id).rstrip(b"\x00").decode("utf-8", "replace")
            rows.append((key, struct.unpack_from("<H", self.block(value_id), 0)[0]))
        return rows

    def facet_names(self):
        if "FACETKEYS" not in self.vars:
            return {}
        header = self.block(self.vars["FACETKEYS"])
        child = struct.unpack_from(">I", header, 8)[0]
        n = struct.unpack_from(">H", self.block(child), 2)[0]
        out = {}
        for i in range(n):
            value_id, key_id = struct.unpack_from(">2I", self.block(child), 12 + 8 * i)
            name = self.block(key_id).rstrip(b"\x00").decode("utf-8", "replace")
            value = self.block(value_id)
            count = struct.unpack_from("<H", value, 4)[0]
            attrs = {}
            for j in range(count):
                a, x = struct.unpack_from("<2H", value, 6 + 4 * j)
                attrs[a] = x
            out[name] = attrs
        return out


def main(argv):
    if len(argv) < 2:
        print(__doc__.strip())
        return 2
    path = argv[1]
    require_dark = "--require-dark" in argv
    want_name = "AppIcon"
    if "--name" in argv:
        want_name = argv[argv.index("--name") + 1]

    bom = Bom(path)
    attrs = bom.key_format()
    print("  container: %d blocks, %d variables" % (len(bom.blocks), len(bom.vars)))
    print("  KEYFORMAT: count=%d attrs=%s" % (len(attrs), attrs))
    print("  variables: %s" % ", ".join(sorted(bom.vars)))

    if 7 not in attrs:
        print("  FAIL: no appearance slot in KEYFORMAT -- the catalog declares no")
        print("        appearances at all, so a dark icon is impossible by construction")
        return 1
    slot = attrs.index(7)

    facets = bom.facet_names()
    target_ids = set()
    for name, a in facets.items():
        if name == want_name or name.startswith(want_name + "/"):
            target_ids.add(a.get(17))
    print("  %s identifiers: %s" % (want_name, sorted(x for x in target_ids if x is not None) or "none"))

    histogram = Counter()
    parts = Counter()
    total = 0
    part_slot = attrs.index(2) if 2 in attrs else None
    for values, name in bom.renditions():
        if target_ids and values[attrs.index(17)] not in target_ids:
            continue
        histogram[values[slot]] += 1
        if part_slot is not None:
            # 220 is the classic appiconset bitmap, 245 the Icon Composer
            # iconstack (layout 1019).  Only the stack carries per-appearance
            # variants, so which of the two landed says whether the `.icon`
            # was picked up at all.
            parts[values[part_slot]] += 1
        total += 1

    rows = bom.appearance_rows()
    labels = {value: key for key, value in rows}
    print("  APPEARANCEKEYS: %s" % (rows or "absent"))
    print("  %s renditions: %d total, by part: %s"
          % (want_name, total, dict(sorted(parts.items())) or "n/a"))
    for value, count in sorted(histogram.items()):
        print("    appearance=%-3s (%s): %d" % (value, labels.get(value, "unmapped"), count))


    if total == 0:
        print("  FAIL: no renditions matched %s" % want_name)
        return 1
    dark = sum(c for v, c in histogram.items() if v != 0)
    if require_dark and dark == 0:
        print("  FAIL: the dark half is missing -- every rendition is appearance=0.")
        print("        actool compiles this catalog without a dark icon.")
        return 1
    if dark:
        print("  ok: %d dark rendition(s) present" % dark)
    else:
        print("  note: light only")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
