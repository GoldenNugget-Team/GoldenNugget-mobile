#!/usr/bin/env python3
"""Generate Nugget/Core/TweakCatalog.swift from GoldenNugget's tweak registry.

Why generate instead of retype: the reference defines every plist tweak exactly
once, as a ``TweakSpec`` in ``src/tweaks/registry.py`` (id / section / title /
location / key / default value / kind / version + device gating / description).
That table is ~130 entries of pure data.  Retyping it into Swift would be a
transcription exercise with 130 chances to drift, and any later upstream tweak
would have to be copied by hand.  This script imports the reference module and
emits the Swift table from it, so a spec cannot disagree with the source.

The reference module imports ``PySide6.QtCore.QT_TRANSLATE_NOOP`` (a no-op marker
for lupdate).  Importing PySide6 would pull in a Qt install this script has no
business needing, so a stub module is installed first: the marker is
identity-with-strings and nothing else in the tweak-definition chain needs Qt.
``src/__init__.py`` is empty and ``src/tweaks/__init__.py`` is empty, so the
import stops at the two data modules (registry + basic_plist_locations).

Usage:
    scripts/gen-tweaks-from-goldennugget.py                 # write the catalog
    scripts/gen-tweaks-from-goldennugget.py --check          # exit 1 on drift
    scripts/gen-tweaks-from-goldennugget.py --goldennugget ~/GoldenNugget
"""

from __future__ import annotations

import argparse
import os
import sys
import types
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUTPUT = ROOT / "Nugget" / "Core" / "TweakCatalog.swift"
DEFAULT_SOURCE = os.path.expanduser("~/GoldenNugget")

# Python Section member name -> Swift case name.
DAEMONS_SECTION_TITLE = "Daemons to Disable"

SECTION_CASES = {
    "LIQUID_GLASS": "liquidGlass",
    "SPRINGBOARD": "springboard",
    "INTERNAL": "internalOptions",
}
KIND_CASES = {"SWITCH": "toggle", "TEXT": "text", "NUMBER": "number"}


def die(message: str):
    sys.exit(f"gen-tweaks: {message}")


def install_pyside_stub() -> None:
    """Make ``from PySide6.QtCore import QT_TRANSLATE_NOOP`` work without Qt."""
    pyside = types.ModuleType("PySide6")
    qtcore = types.ModuleType("PySide6.QtCore")
    qtcore.QT_TRANSLATE_NOOP = lambda context, text: text
    pyside.QtCore = qtcore
    sys.modules["PySide6"] = pyside
    sys.modules["PySide6.QtCore"] = qtcore


def load_reference(source: Path):
    if not (source / "src" / "tweaks" / "registry.py").is_file():
        die(f"{source} does not look like a GoldenNugget checkout "
            f"(no src/tweaks/registry.py)")
    install_pyside_stub()
    sys.path.insert(0, str(source))
    # Imported after the stub is installed, and only ever as the reference.
    from src.tweaks.basic_plist_locations import FileLocation  # noqa: E402
    from src.tweaks.registry import SPECS, Kind, Section  # noqa: E402
    return FileLocation, SPECS, Kind, Section


# --------------------------------------------------------------- Swift emission


def swift_string(value: str) -> str:
    escaped = (value.replace("\\", "\\\\")
                    .replace('"', '\\"')
                    .replace("\n", "\\n")
                    .replace("\r", "\\r")
                    .replace("\t", "\\t"))
    return f'"{escaped}"'


def swift_value(value) -> str:
    # bool must be tested before int: Python's bool is an int subclass, so a
    # True would otherwise be emitted as `.int(1)`.
    if isinstance(value, bool):
        return f".bool({'true' if value else 'false'})"
    if isinstance(value, int):
        return f".int({value})"
    if isinstance(value, float):
        return f".double({value!r})"
    if isinstance(value, str):
        return f".string({swift_string(value)})"
    raise SystemExit(f"gen-tweaks: unsupported plist value {value!r} "
                     f"({type(value).__name__})")


def swift_number(value: float) -> str:
    return repr(float(value))


def emit(output: list[str], FileLocation, SPECS, Kind, Section) -> None:
    w = output.append

    w("// GENERATED FILE — do not edit by hand.")
    w("//")
    w("// Source of truth: GoldenNugget's `src/tweaks/registry.py` (the tweak")
    w("// spec table) and `src/tweaks/basic_plist_locations.py` (the")
    w("// `FileLocation` enum).  Regenerate with:")
    w("//")
    w("//     scripts/gen-tweaks-from-goldennugget.py [--goldennugget <path>]")
    w("//")
    w("// The port is a generation, not a retype: the table below is emitted from")
    w("// the reference module itself, so a tweak added upstream appears here")
    w("// without a hand edit and a spec cannot silently drift from the source.")
    w("")
    w("import Foundation")
    w("")

    # --- FileLocation -------------------------------------------------------
    w("/// An absolute device path a tweak writes to.")
    w("///")
    w("/// Ported from GoldenNugget's `FileLocation` enum; the raw value is the")
    w("/// absolute path, and `TweakDomainMap` turns it into the")
    w("/// `(backup domain, relative path)` pair a restorable row needs.")
    w("enum TweakFileLocation: String, CaseIterable, Sendable {")
    for loc in FileLocation:
        w(f"    case {loc.name} = {swift_string(loc.value)}")
    w("}")
    w("")

    # --- Section ------------------------------------------------------------
    w("/// A tweaks-page section.  Raw values match GoldenNugget's `Section` enum.")
    w("enum TweakSection: String, CaseIterable, Identifiable, Sendable {")
    for member in Section:
        w(f"    case {SECTION_CASES[member.name]} = {swift_string(member.value)}")
    # Daemons is not a member of the reference's `Section`: upstream renders it
    # as its own page built in code (`load_daemons()` plus `gui/ios/daemons.py`)
    # rather than from the registry.  The port folds it into the same enum so
    # one catalog drives both pages; the raw value is the page's own header text.
    w(f"    case daemons = {swift_string(DAEMONS_SECTION_TITLE)}")
    w("    var id: String { rawValue }")
    w("}")
    w("")

    # --- Kind ---------------------------------------------------------------
    w("/// The UI editor a spec wants.  Matches GoldenNugget's `Kind` enum.")
    w("enum TweakKind: Sendable {")
    w("    case toggle")
    w("    case text")
    w("    case number")
    w("}")
    w("")

    # --- Catalog ------------------------------------------------------------
    w("/// Every registry-defined tweak, in the reference's own order.")
    w("///")
    w("/// Iteration order is load-bearing: the compiler merges several tweaks into")
    w("/// one plist, and GoldenNugget iterates `tweaks` in this same order, so a")
    w("/// later key wins exactly as it does upstream.  Do not sort this array.")
    w("enum TweakCatalog {")
    w("    static let all: [TweakSpec] = [")
    for spec in SPECS:
        w(f"        TweakSpec(")
        w(f"            id: {swift_string(spec.id.name)},")
        w(f"            section: .{SECTION_CASES[spec.section.name]},")
        w(f"            title: {swift_string(spec.title)},")
        w(f"            location: .{spec.location.name},")
        w(f"            key: {swift_string(spec.key)},")
        w(f"            value: {swift_value(spec.value)},")
        w(f"            kind: .{KIND_CASES[spec.kind.name]},")
        w(f"            minValue: {swift_number(spec.min_value)},")
        w(f"            maxValue: {swift_number(spec.max_value)},")
        w(f"            step: {swift_number(spec.step)},")
        w(f"            minVersion: {swift_string(spec.min_version) if spec.min_version else 'nil'},")
        w(f"            maxVersion: {swift_string(spec.max_version) if spec.max_version else 'nil'},")
        w(f"            iphoneOnly: {'true' if spec.iphone_only else 'false'},")
        w(f"            ipadOnly: {'true' if spec.ipad_only else 'false'},")
        w(f"            disabled: {'true' if spec.disabled else 'false'},")
        w(f"            detail: {swift_string(spec.description) if spec.description else 'nil'},")
        if spec.factory is not None:
            w("            multiValues: [")
            for key, value in spec.factory().value.items():
                w(f"                {swift_string(key)}: {swift_value(value)},")
            w("            ]")
        else:
            w("            multiValues: nil")
        w(f"        ),")
    w("    ]")
    w("")
    w("    /// The daemon groups, appended after the registry rows.  They are not in")
    w("    /// `registry.py` upstream -- `gen-daemons-from-goldennugget.py` emits them")
    w("    /// from `daemons_tweak.py` -- and they are last so every registry key still")
    w("    /// merges into a shared plist before any daemon label does.")
    w("    static let allWithDaemons: [TweakSpec] = all + daemonSpecs + [screenTimeSpec]")
    w("")
    w("    static let byID: [String: TweakSpec] =")
    w("        Dictionary(uniqueKeysWithValues: allWithDaemons.map { ($0.id, $0) })")
    w("")
    w("    static func inSection(_ section: TweakSection) -> [TweakSpec] {")
    w("        all.filter { $0.section == section }")
    w("    }")
    w("}")
    w("")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--goldennugget", default=DEFAULT_SOURCE,
                    help=f"path to the GoldenNugget checkout (default: {DEFAULT_SOURCE})")
    ap.add_argument("--check", action="store_true",
                    help="exit 1 if the catalog would change; never writes")
    args = ap.parse_args()

    FileLocation, SPECS, Kind, Section = load_reference(Path(args.goldennugget))

    lines: list[str] = []
    emit(lines, FileLocation, SPECS, Kind, Section)
    generated = "\n".join(lines)

    if args.check:
        current = OUTPUT.read_text(encoding="utf-8") if OUTPUT.is_file() else ""
        if current != generated:
            print("TweakCatalog.swift is out of date with the reference registry",
                  file=sys.stderr)
            return 1
        print(f"TweakCatalog.swift matches the reference ({len(SPECS)} tweaks)")
        return 0

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    if OUTPUT.is_file() and OUTPUT.read_text(encoding="utf-8") == generated:
        print(f"TweakCatalog.swift already up to date ({len(SPECS)} tweaks)")
        return 0
    OUTPUT.write_text(generated, encoding="utf-8")
    print(f"wrote {OUTPUT.relative_to(ROOT)}: {len(SPECS)} tweaks")
    return 0


if __name__ == "__main__":
    sys.exit(main())
