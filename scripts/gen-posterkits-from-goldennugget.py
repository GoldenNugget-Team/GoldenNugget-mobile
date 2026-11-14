#!/usr/bin/env python3
"""Generate Nugget/Core/PosterKitOptions.swift from GoldenNugget's PosterKit
override metadata.

The reference defines the PosterKit editor's data exactly once, in
``src/tweaks/posterboard/device_overrides.py`` (the ``OPTIONS`` field list and
the ``FILES`` archive-name map) and ``src/tweaks/posterboard/preference_controls.py``
(``CLOCK_FONT_IDENTIFIERS``, ``number_limits``, ``POSTER_PRESETS``).  The port
edits the same fields, so the table is generated rather than retyped — a field
added upstream then appears here without a hand edit.

Usage:
    scripts/gen-posterkits-from-goldennugget.py                 # write
    scripts/gen-posterkits-from-goldennugget.py --check         # exit 1 on drift
    scripts/gen-posterkits-from-goldennugget.py --goldennugget <path>
"""

from __future__ import annotations

import argparse
import math
import os
import re
import sys
import types
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUTPUT = ROOT / "Nugget" / "Core" / "PosterKitOptions.swift"
DEFAULT_SOURCE = os.path.expanduser("~/GoldenNugget")


def install_pyside_stub() -> None:
    pyside = types.ModuleType("PySide6")
    qtcore = types.ModuleType("PySide6.QtCore")
    qtcore.QT_TRANSLATE_NOOP = lambda context, text: text
    pyside.QtCore = qtcore
    sys.modules["PySide6"] = pyside
    sys.modules["PySide6.QtCore"] = qtcore


def load_reference(source: Path):
    if not (source / "src" / "tweaks" / "posterboard" / "device_overrides.py").is_file():
        raise SystemExit(f"gen-posterkits: {source} does not look like a GoldenNugget checkout")
    install_pyside_stub()
    sys.path.insert(0, str(source))
    from src.tweaks.posterboard.device_overrides import FILES, OPTIONS, option_key  # noqa: E402
    from src.tweaks.posterboard.preference_controls import (  # noqa: E402
        CLOCK_FONT_IDENTIFIERS, POSTER_PRESETS, number_limits)
    return FILES, OPTIONS, CLOCK_FONT_IDENTIFIERS, POSTER_PRESETS, number_limits, option_key


def load_archive_fields(source: Path) -> frozenset[str]:
    """Parse the scalar-field allowlist out of ``archive_editor.py``.

    The set is a module-level literal of plain quoted names; the module imports
    PySide-adjacent machinery nowhere, so a targeted regex read avoids importing
    it (and keeps the stub shim above unnecessary for this file).
    """
    text = (source / "src" / "tweaks" / "posterboard" / "archive_editor.py").read_text(
        encoding="utf-8")
    match = re.search(r"^FIELDS = \{(.*?)\}", text, re.MULTILINE | re.DOTALL)
    if not match:
        raise SystemExit("gen-posterkits: FIELDS not found in archive_editor.py")
    names = re.findall(r'"([^"]+)"', match.group(1))
    return frozenset(names)


def swift_string(value: str) -> str:
    escaped = (value.replace("\\", "\\\\")
                    .replace('"', '\\"')
                    .replace("\n", "\\n")
                    .replace("\r", "\\r")
                    .replace("\t", "\\t"))
    return f'"{escaped}"'


def swift_value(value) -> str:
    if isinstance(value, bool):
        return f".bool({'true' if value else 'false'})"
    if isinstance(value, int):
        return f".int({value})"
    if isinstance(value, float):
        return f".double({value!r})"
    if isinstance(value, str):
        return f".string({swift_string(value)})"
    raise SystemExit(f"gen-posterkits: unsupported default {value!r}")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--goldennugget", default=DEFAULT_SOURCE,
                    help=f"path to the GoldenNugget checkout (default: {DEFAULT_SOURCE})")
    ap.add_argument("--check", action="store_true",
                    help="exit 1 if the file would change; never writes")
    args = ap.parse_args()

    FILES, OPTIONS, CLOCK_FONT_IDENTIFIERS, POSTER_PRESETS, number_limits, option_key = load_reference(Path(args.goldennugget))
    archive_fields = load_archive_fields(Path(args.goldennugget))

    lines: list[str] = []
    w = lines.append
    w("// GENERATED FILE — do not edit by hand.")
    w("//")
    w("// Source of truth: GoldenNugget's `src/tweaks/posterboard/device_overrides.py`")
    w("// (the `OPTIONS` field list and the `FILES` archive-name map),")
    w("// `src/tweaks/posterboard/preference_controls.py` (clock fonts, numeric")
    w("// limits, presets) and `src/tweaks/posterboard/archive_editor.py` (the")
    w("// `FIELDS` scalar allowlist).  Regenerate with:")
    w("//")
    w("//     scripts/gen-posterkits-from-goldennugget.py [--goldennugget <path>]")
    w("")
    w("import Foundation")
    w("")
    w("/// Editor metadata for the PosterKit wallpaper-archive fields, ported from")
    w("/// the reference's own tables.  Defaults only seed the controls; a field is")
    w("/// written only when its Use switch is on (`device_overrides.OPTIONS`).")
    w("enum PosterKitOptions {")
    w("    struct Field: Sendable {")
    w("        /// The `\"Group:path\"` key the selection stores (`option_key`).")
    w("        let key: String")
    w("        /// The archive group the field belongs to (`FILES`).")
    w("        let group: String")
    w("        /// The field path inside the archive's object graph.")
    w("        let path: String")
    w("        let title: String")
    w("        let defaultValue: TweakValue")
    w("        /// The editor's numeric bounds, when the field is numeric.")
    w("        let limits: (lower: Double, upper: Double, step: Double)?")
    w("    }")
    w("")
    w("    /// `device_overrides.FILES`: which archive each group edits inside a")
    w("    /// wallpaper version directory.")
    w("    static let files: [String: String] = [")
    for group, suffix in FILES.items():
        w(f"        {swift_string(group)}: {swift_string(suffix)},")
    w("    ]")
    w("")
    w("    static let all: [Field] = [")
    for group, path, title, default in OPTIONS:
        key = option_key(group, path)
        lower, upper, step = number_limits(path, default)
        finite_ok = math.isfinite(default) if isinstance(default, (int, float)) else True
        if not finite_ok:
            raise SystemExit(f"gen-posterkits: non-finite default for {key}")
        # `preference_controls.number_limits` returns a step of 0 for the tint
        # fields it range-limits without a stepper; emit nil limits there and
        # let the editor use the whole-range free form, exactly like desktop's
        # `NumberInputDialog` does for its own defaults.
        is_numeric = isinstance(default, (int, float)) and not isinstance(default, bool)
        limits = (f"({lower!r}, {upper!r}, {step!r})" if is_numeric else "nil")
        w(f"        Field(key: {swift_string(key)}, group: {swift_string(group)}, path: {swift_string(path)},")
        w(f"              title: {swift_string(title)}, defaultValue: {swift_value(default)},")
        w(f"              limits: {limits}),")
    w("    ]")
    w("")
    w("    /// `preference_controls.POSTER_PRESETS`: named bundles of fields.")
    w("    static let presets: [String: [String: TweakValue]] = [")
    for name, fields in POSTER_PRESETS.items():
        entries = ", ".join(f"{swift_string(k)}: {swift_value(v)}" for k, v in fields.items())
        w(f"        {swift_string(name)}: [{entries}],")
    w("    ]")
    w("")
    w("    /// `preference_controls.CLOCK_FONT_IDENTIFIERS`, verbatim.")
    w("    static let clockFontIdentifiers: [String] = [")
    for font in CLOCK_FONT_IDENTIFIERS:
        w(f"        {swift_string(font)},")
    w("    ]")
    w("")
    w("    /// The icon-tint field keys, in the order the color editor writes them")
    w("    /// (`poster_preferences.py`'s `tint_keys`).")
    w("    static let tintKeys: [String] = [")
    for field in ("_hue", "_saturation", "_alpha"):
        w(f"        {swift_string('Home Screen:customizationConfiguration._tintColorStyle.' + field)},")
    w("    ]")
    w("")
    w("    /// `archive_editor.FIELDS`: the only scalar field names the archive")
    w("    /// editor recognises inside a wallpaper's object graph.  Class metadata")
    w("    /// and binary blobs stay untouched.")
    w("    static let archiveFields: Set<String> = [")
    for name in sorted(archive_fields):
        w(f"        {swift_string(name)},")
    w("    ]")
    w("}")
    w("")

    generated = "\n".join(lines)
    if args.check:
        current = OUTPUT.read_text(encoding="utf-8") if OUTPUT.is_file() else ""
        if current != generated:
            print("PosterKitOptions.swift is out of date with the reference", file=sys.stderr)
            return 1
        print(f"PosterKitOptions.swift matches the reference ({len(OPTIONS)} fields)")
        return 0
    OUTPUT.write_text(generated, encoding="utf-8")
    print(f"wrote {OUTPUT.relative_to(ROOT)}: {len(OPTIONS)} fields")
    return 0


if __name__ == "__main__":
    sys.exit(main())
