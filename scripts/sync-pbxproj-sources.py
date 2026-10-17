#!/usr/bin/env python3
"""Reconcile the Xcode project's project.pbxproj with Package.swift.

Package.swift is the single source of truth for which files the GoldenNuggetMobile target
compiles.  It did not use to be: the manifest carried a hand-maintained list of
50 paths that had to be kept in step with the Xcode project by hand, and that
list had already drifted — Nugget/Core/InFlightCall.swift was missing from it.

This script asks SwiftPM itself (`swift package describe --disable-sandbox`)
which files the target resolves and makes the Xcode project agree.  It never
parses Package.swift's text, so changing how sources are declared cannot
desynchronise the two.

It replaces scripts/relink-core-sources.py, which was a one-shot migration for
the Sparserestore -> Core rename and had since become a no-op that crashed: it
looked for a group comment that no longer existed.

Guarantees, in the order they matter:

  * existing object IDs are reused, never re-minted, so diffs stay small
  * an object in use before the run cannot silently disappear
  * nothing is written unless every Sources entry resolves
    buildFile -> fileRef -> owning group -> real file on disk
  * running it twice with no source change writes an identical file

Usage:
    scripts/sync-pbxproj-sources.py           # reconcile and write
    scripts/sync-pbxproj-sources.py --check   # report drift, exit 1, no write
"""

from __future__ import annotations

import argparse
import hashlib
import posixpath
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
NUGGET = "Nugget"
SWIFT_TYPE = "sourcecode.swift"

HEX24 = re.compile(r"^[0-9A-F]{24}$")


def find_pbxproj() -> Path:
    """The project file, found rather than named.

    This used to be the literal ``PoC.xcodeproj/project.pbxproj``, and the
    project was then renamed to ``GoldenNuggetMobile.xcodeproj`` — which turned
    every hardcoded spelling of the old name into a `FileNotFoundError`, this
    script included.  There is exactly one ``*.xcodeproj`` in the repo root, so
    it is discovered; a future rename then costs nothing.
    """
    candidates = sorted(p / "project.pbxproj" for p in ROOT.glob("*.xcodeproj")
                        if (p / "project.pbxproj").is_file())
    # `sys.exit` rather than `die`: this runs at import time, before `die` exists.
    if not candidates:
        sys.exit(f"sync-pbxproj-sources: no *.xcodeproj/project.pbxproj under {ROOT}")
    if len(candidates) > 1:
        sys.exit("sync-pbxproj-sources: more than one project file: "
                 + ", ".join(str(p.relative_to(ROOT)) for p in candidates))
    return candidates[0]


PBXPROJ = find_pbxproj()


def die(message: str):
    sys.exit(f"sync-pbxproj-sources: {message}")


# ----------------------------------------------------------- SwiftPM's answer


def resolved_sources() -> list[str]:
    """The target's sources as SwiftPM resolves them — never a guess.

    `xcrun` is absent on a Linux host, where SwiftPM cannot be asked anything, so
    there is a fallback: the manifest declares `sources: ["Nugget"]`, and for a
    directory entry SwiftPM's answer *is* every `.swift` file under it. The walk
    is therefore not a second source of truth — it is the same answer computed
    without the tool that normally computes it, and the manifest is still the
    thing being mirrored.
    """
    try:
        proc = subprocess.run(
            ["xcrun", "swift", "package", "describe", "--disable-sandbox"],
            cwd=ROOT, capture_output=True, text=True,
        )
    except FileNotFoundError:
        proc = None
    if proc is None:
        return walk_sources()

    if proc.returncode != 0:
        die(f"`swift package describe` failed:\n{proc.stderr.strip()}")

    lines = proc.stdout.split("\n")
    try:
        start = lines.index("    Sources:")
    except ValueError:
        die("no `Sources:` block in `swift package describe` output")

    sources = []
    for line in lines[start + 1:]:
        if line.startswith("        ") and line.strip():
            sources.append(line.strip())
        else:
            break
    if not sources:
        die("`swift package describe` resolved the target to zero sources")
    return sorted(sources)


def walk_sources() -> list[str]:
    """Every `.swift` under the manifest's source directory, package-relative."""
    manifest = (ROOT / "Package.swift").read_text(encoding="utf-8")
    found = re.search(r'sources:\s*\[(.+?)\]', manifest, re.S)
    if not found:
        die("Package.swift declares no `sources:` array to fall back on")
    entries = [unquote(entry.strip()) for entry in found.group(1).split(",")]
    entries = [entry for entry in entries if entry]
    if entries != [NUGGET]:
        die(f"the xcrun-less fallback only handles sources: [\"{NUGGET}\"], "
            f"but the manifest says {entries}")

    root = ROOT / NUGGET
    if not root.is_dir():
        die(f"Package.swift declares {NUGGET}, which is not a directory")
    # The target's own `path` is `.`, so a package-relative path is the repo
    # path — `relative_to(ROOT)`, with no prefix added.
    return sorted(
        path.relative_to(ROOT).as_posix()
        for path in root.rglob("*.swift")
        if path.is_file()
    )


# ------------------------------------------------------------- pbxproj reading


def split_sections(text: str) -> dict[str, tuple[int, int]]:
    pattern = re.compile(r"/\* Begin (\w+) section \*/\n(.*?)/\* End \1 section \*/", re.S)
    return {m.group(1): (m.start(2), m.end(2)) for m in pattern.finditer(text)}


def unquote(value: str) -> str:
    value = value.strip()
    if len(value) >= 2 and value[0] == '"' and value[-1] == '"':
        return value[1:-1]
    return value


def quote(value: str) -> str:
    """Xcode only quotes path values that are not bare identifiers."""
    return value if re.fullmatch(r"[A-Za-z0-9_.]+", value) else f'"{value}"'


class FileRef:
    __slots__ = ("id", "name", "path", "is_swift", "raw")

    def __init__(self, ref_id: str, raw: str) -> None:
        self.id = ref_id
        self.raw = raw  # verbatim, leading tabs included
        comment = re.match(r"^\t\t[0-9A-F]{24} /\* (.+?) \*/", raw)
        self.name = comment.group(1) if comment else ""
        found = re.search(r"\bpath = (.+?);", raw)
        self.path = unquote(found.group(1)) if found else None
        self.is_swift = SWIFT_TYPE in raw


class BuildFile:
    __slots__ = ("id", "name", "ref", "raw", "is_sources")

    def __init__(self, build_id: str, raw: str) -> None:
        self.id = build_id
        self.raw = raw  # verbatim, leading tabs included
        comment = re.match(r"^\t\t[0-9A-F]{24} /\* (.+?) \*/", raw)
        self.name = comment.group(1) if comment else ""
        found = re.search(r"fileRef = ([0-9A-F]{24})", raw)
        self.ref = found.group(1) if found else ""
        self.is_sources = self.name.endswith(" in Sources")


class Group:
    __slots__ = ("id", "name", "path", "children", "child_comments", "name_raw", "path_raw")

    def __init__(self, gid: str, comment: str | None, body: str) -> None:
        self.id = gid
        self.name = comment
        self.children: list[str] = []
        self.child_comments: dict[str, str] = {}
        block = re.search(r"\t\t\tchildren = \(\n(.*?)\n\t\t\t\);", body, re.S)
        if block:
            for line in block.group(1).split("\n"):
                m = re.match(r"^\t{4}([0-9A-F]{24})(?: /\* (.+?) \*/)?,?$", line)
                if m:
                    self.children.append(m.group(1))
                    if m.group(2):
                        self.child_comments[m.group(1)] = m.group(2)
        name = re.search(r"^\t\t\tname = (.+);$", body, re.M)
        path = re.search(r"^\t\t\tpath = (.+);$", body, re.M)
        self.name_raw = name.group(1) if name else None
        self.path_raw = path.group(1) if path else None
        self.path = unquote(path.group(1)) if path else None


def parse(text: str, secs: dict[str, tuple[int, int]]):
    refs: dict[str, FileRef] = {}
    for m in re.finditer(
        r"^\t\t([0-9A-F]{24}) /\* .+? \*/ = \{isa = PBXFileReference;.*?\};$",
        text[secs["PBXFileReference"][0]:secs["PBXFileReference"][1]],
        re.M,
    ):
        refs[m.group(1)] = FileRef(m.group(1), m.group(0))

    builds: dict[str, BuildFile] = {}
    for m in re.finditer(
        r"^\t\t([0-9A-F]{24}) /\* .+? \*/ = \{isa = PBXBuildFile;.*?\};$",
        text[secs["PBXBuildFile"][0]:secs["PBXBuildFile"][1]],
        re.M,
    ):
        builds[m.group(1)] = BuildFile(m.group(1), m.group(0))

    groups: dict[str, Group] = {}
    for m in re.finditer(
        r"^\t\t([0-9A-F]{24})(?: /\* (.+?) \*/)? = \{\n(.*?)\n\t\t\};$",
        text[secs["PBXGroup"][0]:secs["PBXGroup"][1]],
        re.M | re.S,
    ):
        groups[m.group(1)] = Group(m.group(1), m.group(2), m.group(3))

    root = re.search(r"^\t+mainGroup = ([0-9A-F]{24});$", text, re.M)
    if not root:
        die("project.pbxproj has no mainGroup")
    return refs, builds, groups, root.group(1)


def group_dirs(groups: dict[str, Group], root_id: str) -> dict[str, str]:
    """Package-relative directory of each group.  A group declared with `name`
    only is virtual and inherits its parent's directory."""
    dirs: dict[str, str] = {}
    stack = [(root_id, "")]
    while stack:
        gid, parent = stack.pop()
        group = groups.get(gid)
        if group is None:
            continue
        here = posixpath.join(parent, group.path) if group.path else parent
        dirs[gid] = here
        stack.extend((child, here) for child in group.children if child in groups)
    return dirs


# ----------------------------------------------------------------- authoring


def make_id(seed: str, used: set[str]) -> str:
    for salt in range(10_000):
        candidate = hashlib.md5(f"{seed}:{salt}".encode()).hexdigest().upper()[:24]
        if candidate not in used:
            used.add(candidate)
            return candidate
    raise RuntimeError(f"could not mint an id for {seed}")


def render_group(group: Group, children: list[str], labels: dict[str, str]) -> str:
    head = f"\t\t{group.id}" + (f" /* {group.name} */" if group.name else "")
    out = [head + " = {", "\t\t\tisa = PBXGroup;", "\t\t\tchildren = ("]
    for child in children:
        label = labels.get(child)
        out.append(f"\t\t\t\t{child}" + (f" /* {label} */," if label else ","))
    out.append("\t\t\t);")
    if group.name_raw:
        out.append(f"\t\t\tname = {group.name_raw};")
    if group.path_raw:
        out.append(f"\t\t\tpath = {group.path_raw};")
    out.append('\t\t\tsourceTree = "<group>";')
    out.append("\t\t};")
    return "\n".join(out)


def label_of(line: str) -> str:
    """The `/* ... */` comment of a pbxproj entry, used as the sort key."""
    found = re.search(r"/\* (.+?) \*/", line)
    return found.group(1) if found else line


def render_section(entries: list[str]) -> str:
    return "\n".join(sorted(entries, key=label_of))


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__ .split("\n")[0])
    ap.add_argument("--check", action="store_true",
                    help="exit 1 if the project would change; never writes")
    args = ap.parse_args()

    desired = resolved_sources()
    for path in desired:
        if not (ROOT / path).is_file():
            die(f"SwiftPM listed {path}, which is not a file on disk")

    original = PBXPROJ.read_text(encoding="utf-8")
    secs = split_sections(original)
    for needed in ("PBXBuildFile", "PBXFileReference", "PBXGroup", "PBXSourcesBuildPhase"):
        if needed not in secs:
            die(f"project.pbxproj has no {needed} section")

    refs, builds, groups, root_id = parse(original, secs)
    dirs = group_dirs(groups, root_id)
    parent_of = {child: gid for gid, g in groups.items()
                 for child in g.children if child in groups}

    managed_gids = {g for g, d in dirs.items() if d == NUGGET or d.startswith(NUGGET + "/")}
    if not managed_gids:
        die(f"no PBXGroup under {NUGGET}/ — refusing to guess")
    managed_root = next((g for g, d in dirs.items() if d == NUGGET), None)
    if managed_root is None:
        die(f"no PBXGroup whose path is {NUGGET}")

    # Each Swift FileReference reachable from the managed subtree, by real path.
    ref_path: dict[str, str] = {}
    for gid in managed_gids:
        for child in groups[gid].children:
            ref = refs.get(child)
            if ref and ref.is_swift and ref.path:
                ref_path[child] = posixpath.join(dirs[gid], ref.path)
    ref_for_path = {p: rid for rid, p in ref_path.items()}
    build_for_ref = {bf.ref: bid for bid, bf in builds.items()}

    used_ids = set(re.findall(r"\b[0-9A-F]{24}\b", original))

    # ---- desired source -> (fileRef id, buildFile id) -------------------------
    new_ref: dict[str, str] = {}
    for path in desired:
        if path in ref_for_path:
            new_ref[path] = ref_for_path[path]
        else:
            new_ref[path] = make_id(f"fileRef:{path}", used_ids)

    new_build: dict[str, str] = {}
    for path, rid in new_ref.items():
        if rid in build_for_ref:
            new_build[path] = build_for_ref[rid]
        else:
            new_build[path] = make_id(f"buildFile:{path}", used_ids)

    # ---- a real group for every directory that holds a source ----------------
    group_for_dir = {d: g for g, d in dirs.items() if g in managed_gids}
    for path in desired:
        directory = posixpath.dirname(path)
        if directory in group_for_dir:
            continue
        parent_dir = posixpath.dirname(directory)
        if parent_dir not in group_for_dir:
            die(f"cannot place a group for {directory}: {parent_dir} has no group")
        gid = make_id(f"group:{directory}", used_ids)
        group = Group(gid, posixpath.basename(directory), "")
        group.path_raw = group.path = quote(posixpath.basename(directory))
        groups[gid] = group
        dirs[gid] = directory
        parent_of[gid] = group_for_dir[parent_dir]
        group_for_dir[directory] = gid
        managed_gids.add(gid)

    # ---- rebuild every managed group's children -----------------------------
    # Seed the labels from the file itself first, so entries this script does
    # not manage (app icons, the product, the vendored folder, the package
    # groups) keep the comments they had.
    labels: dict[str, str] = {}
    for group in groups.values():
        labels.update(group.child_comments)

    files_by_dir: dict[str, list[str]] = {}
    for path, rid in new_ref.items():
        base = posixpath.basename(path)
        labels[rid] = base
        labels[new_build[path]] = f"{base} in Sources"
        files_by_dir.setdefault(posixpath.dirname(path), []).append(rid)

    subgroups_by_parent: dict[str, list[str]] = {}
    for gid in managed_gids:
        parent = parent_of.get(gid)
        if parent is not None:
            subgroups_by_parent.setdefault(parent, []).append(gid)
        labels.setdefault(gid, groups[gid].name or dirs[gid])

    for gid in managed_gids:
        subgroups = sorted(subgroups_by_parent.get(gid, []), key=lambda g: labels[g])
        files = sorted(files_by_dir.get(dirs[gid], []), key=lambda r: labels[r])
        groups[gid].children = subgroups + files

    # ---- prune groups that ended up empty (never the managed root) ----------
    pruned = True
    while pruned:
        pruned = False
        for gid in sorted(managed_gids - {managed_root}):
            if groups[gid].children:
                continue
            managed_gids.discard(gid)
            dirs.pop(gid, None)
            groups.pop(gid)
            parent = parent_of.pop(gid, None)
            if parent and gid in subgroups_by_parent.get(parent, []):
                subgroups_by_parent[parent].remove(gid)
            for other in groups.values():
                if gid in other.children:
                    other.children.remove(gid)
            pruned = True

    # ---- render -------------------------------------------------------------
    # Managed entries are re-emitted from the resolved maps; everything else
    # (app icons, the product, the vendored folder, libsqlite3, the package
    # products) is carried over verbatim so this script cannot damage it.
    ref_entries = [
        f"\t\t{rid} /* {posixpath.basename(path)} */ = {{isa = PBXFileReference; "
        f"lastKnownFileType = {SWIFT_TYPE}; path = {quote(posixpath.basename(path))}; "
        f'sourceTree = "<group>"; }};'
        for path, rid in new_ref.items()
    ]
    ref_entries += [r.raw for r in refs.values() if r.id not in ref_path]

    build_entries = [
        f"\t\t{bid} /* {posixpath.basename(path)} in Sources */ = {{isa = PBXBuildFile; "
        f"fileRef = {new_ref[path]} /* {posixpath.basename(path)} */; }};"
        for path, bid in new_build.items()
    ]
    build_entries += [b.raw for b in builds.values() if b.ref not in ref_path]

    group_blocks = [render_group(g, g.children, labels) for g in groups.values()]

    source_entries = [
        f"\t\t\t\t{bid} /* {labels[bid]} */,"
        for bid in sorted(new_build.values(), key=lambda b: labels[b])
    ]

    text = original
    for name, entries in (("PBXBuildFile", build_entries),
                          ("PBXFileReference", ref_entries)):
        start, end = secs[name]
        text = text[:start] + render_section(entries) + "\n" + text[end:]
        secs = split_sections(text)

    start, end = secs["PBXGroup"]
    text = text[:start] + "\n".join(group_blocks) + "\n" + text[end:]
    secs = split_sections(text)

    start, end = secs["PBXSourcesBuildPhase"]
    body = text[start:end]
    opened = body.index("\t\t\tfiles = (\n") + len("\t\t\tfiles = (\n")
    closed = body.index("\t\t\t);", opened)
    text = text[:start + opened] + "\n".join(source_entries) + "\n" + text[start + closed:]

    validate(text, desired)

    if args.check:
        if text != original:
            print(f"drift in {PBXPROJ.relative_to(ROOT)}", file=sys.stderr)
            return 1
        print("project.pbxproj matches Package.swift")
        return 0

    if text == original:
        print(f"project.pbxproj already in sync ({len(desired)} sources)")
        return 0

    PBXPROJ.write_text(text, encoding="utf-8")
    print(f"rewrote {PBXPROJ.relative_to(ROOT)}: {len(desired)} sources")
    return 0


def validate(text: str, desired: list[str]) -> None:
    """Refuse to hand Xcode a project whose source entries do not resolve."""
    secs = split_sections(text)
    refs, builds, groups, root_id = parse(text, secs)
    dirs = group_dirs(groups, root_id)
    owner_of = {child: gid for gid, g in groups.items() for child in g.children}

    body = text[secs["PBXSourcesBuildPhase"][0]:secs["PBXSourcesBuildPhase"][1]]
    entries = re.findall(r"^\t{4}([0-9A-F]{24}) /\* (.+?) in Sources \*/,?$", body, re.M)
    if len(entries) != len(desired):
        die(f"Sources phase has {len(entries)} entries but SwiftPM resolved {len(desired)}")

    resolved = set()
    for bid, name in entries:
        build = builds.get(bid) or die(f"Sources entry {name} has no PBXBuildFile object")
        ref = refs.get(build.ref) or die(f"{name} points at missing fileRef {build.ref}")
        gid = owner_of.get(ref.id) or die(f"{name} is not a child of any PBXGroup")
        path = posixpath.join(dirs[gid], ref.path or "")
        if not (ROOT / path).is_file():
            die(f"{name} resolves to {path}, which is not a file on disk")
        resolved.add(path)

    if resolved != set(desired):
        missing = sorted(set(desired) - resolved)
        extra = sorted(resolved - set(desired))
        die(f"Sources phase does not match Package.swift (missing={missing}, extra={extra})")


if __name__ == "__main__":
    sys.exit(main())
