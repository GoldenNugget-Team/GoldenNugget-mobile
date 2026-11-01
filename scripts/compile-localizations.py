#!/usr/bin/env python3
"""Compile the String Catalogs into `<lang>.lproj` bundles for the xtool build.

The Xcode build compiles `Localizable.xcstrings` and `InfoPlist.xcstrings` itself.
xtool does not: it copies the entries in `xtool.yml`'s `resources:` list into the
app bundle verbatim, so an `.xcstrings` shipped that way would never be read by
Foundation.  This script produces the same `<lang>.lproj/Localizable.strings` and
`<lang>.lproj/InfoPlist.strings` files Xcode would, into `build/localizations`,
and `xtool.yml` ships those directories.

It deliberately has no Xcode dependency: the shipping path is a Linux host, where
`xcstringstool` does not exist.  It implements the subset of the catalog format
this app uses — string units and plural variations — and fails loudly on a shape
it does not understand rather than silently dropping a translation.

Usage:
    scripts/compile-localizations.py [--check] [--output DIR]

`--check` writes nothing and exits 1 if any catalog needs regenerating; CI uses
it the same way `sync-pbxproj-sources.py --check` is used.
"""

from __future__ import annotations

import argparse
import json
import plistlib
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CATALOG_DIR = ROOT / "layout" / "Applications" / "GoldenNuggetMobile.app"
DEFAULT_OUTPUT = ROOT / "build" / "localizations"

# The `.xcstrings` name maps to the `.strings` table Foundation loads.
TABLES = {
    "Localizable.xcstrings": "Localizable",
    "InfoPlist.xcstrings": "InfoPlist",
}

# `%1$lld`, `%lld`, `%@`, `%%` — the first specifier that takes an argument.
FORMAT_SPEC = re.compile(
    r"%(?:\d+\$)?[-+ 0#']*\d*(?:\.\d+)?(?P<length>hh|h|ll|l|q|z|t|j)?(?P<conversion>[@dDiuUxXoOfFeEgGcCsSpaA])"
)
PLURAL_PLACEHOLDER = "%#@value@"


def die(message: str) -> None:
    sys.exit(f"compile-localizations: {message}")


def unescape_key(key: str) -> str:
    return key


def escape_string(value: str) -> str:
    return (value.replace("\\", "\\\\")
                 .replace('"', '\\"')
                 .replace("\r", "\\r")
                 .replace("\t", "\\t")
                 .replace("\n", "\\n"))


def source_value(key: str) -> str:
    """The English text a key stands for.

    Localizable's keys *are* the source strings, so the key is the value.  The
    same is true of a key that has positional placeholders — Foundation accepts
    `%1$@` in the value as well as in the key.
    """
    return key


def translated_value(entry: dict, language: str, default: str | None) -> tuple[str | None, dict | None]:
    """Return (value, variations) for one language.

    `variations` is returned separately because a plural entry cannot live in a
    `.strings` file; the caller writes a `.stringsdict` for it.
    """
    localizations = entry.get("localizations") or {}
    localization = localizations.get(language) or {}

    variations = localization.get("variations")
    if variations:
        plural = (variations.get("plural") or {})
        if not plural:
            die(f"unsupported variation in {language!r}: {variations!r}")
        return None, plural

    unit = localization.get("stringUnit") or {}
    if "value" in unit:
        return unit["value"], None

    if default is not None:
        return default, None

    return None, None


def plural_value_type(key: str) -> str:
    match = FORMAT_SPEC.search(key)
    if not match:
        # A plural with no visible placeholder is still valid; lld is what an
        # Int interpolation produces and is the common case here.
        return "lld"
    return (match.group("length") or "") + match.group("conversion")


def plural_format_key(key: str) -> str:
    match = FORMAT_SPEC.search(key)
    if not match:
        return PLURAL_PLACEHOLDER
    return key[:match.start()] + PLURAL_PLACEHOLDER + key[match.end():]


def compile_catalog(catalog_path: Path, output: Path) -> set[str]:
    """Write one catalog's languages, returning the languages that got a file."""
    table = TABLES.get(catalog_path.name)
    if table is None:
        die(f"no table mapping for {catalog_path.name}")

    try:
        catalog = json.loads(catalog_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        die(f"cannot read {catalog_path}: {error}")

    source_language = catalog.get("sourceLanguage") or "en"
    strings = catalog.get("strings") or {}

    languages = {source_language}
    for entry in strings.values():
        languages.update((entry.get("localizations") or {}).keys())

    written: set[str] = set()
    for language in sorted(languages):
        units: dict[str, str] = {}
        plurals: dict[str, dict] = {}

        for key, entry in strings.items():
            if not key:
                continue
            if entry.get("shouldTranslate") is False:
                continue

            default = source_value(key) if language == source_language else None
            value, variations = translated_value(entry, language, default)
            if variations is not None:
                plurals[key] = variations
            elif value is not None:
                units[key] = value

        if not units and not plurals:
            continue

        directory = output / f"{language}.lproj"
        directory.mkdir(parents=True, exist_ok=True)

        header = (f"/* {table}.strings, {language}. Generated by "
                  f"scripts/compile-localizations.py from {catalog_path.name}. "
                  "Do not edit. */\n\n")
        body = "".join(f'"{escape_string(key)}" = "{escape_string(value)}";\n'
                       for key, value in sorted(units.items()))
        (directory / f"{table}.strings").write_text(header + body, encoding="utf-8")

        if plurals:
            dictionary: dict[str, object] = {}
            for key, variations in sorted(plurals.items()):
                rules: dict[str, object] = {
                    "NSStringLocalizedFormatKey": plural_format_key(key),
                    "value": {
                        "NSStringFormatSpecTypeKey": "NSStringPluralRuleType",
                        "NSStringFormatValueTypeKey": plural_value_type(key),
                        **{rule: (entry.get("stringUnit") or {}).get("value", "")
                           for rule, entry in variations.items()},
                    },
                }
                dictionary[key] = rules
            with open(directory / f"{table}.stringsdict", "wb") as handle:
                plistlib.dump(dictionary, handle)

        written.add(language)

    return written


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT,
                        help=f"destination directory (default: {DEFAULT_OUTPUT.relative_to(ROOT)})")
    parser.add_argument("--catalog-dir", type=Path, default=CATALOG_DIR,
                        help="directory holding the .xcstrings files (default: the app bundle layout)")
    parser.add_argument("--check", action="store_true",
                        help="write nothing; exit 1 if the output is stale")
    args = parser.parse_args()

    catalogs = sorted(p for p in args.catalog_dir.glob("*.xcstrings") if p.name in TABLES)
    if not catalogs:
        die(f"no String Catalogs in {args.catalog_dir}")

    if args.check:
        import tempfile
        with tempfile.TemporaryDirectory() as temporary:
            expected = Path(temporary)
            for catalog in catalogs:
                compile_catalog(catalog, expected)
            stale = not directories_equal(expected, args.output)
        if stale:
            print("compile-localizations: build/localizations is stale; "
                  "run scripts/compile-localizations.py", file=sys.stderr)
            return 1
        return 0

    args.output.mkdir(parents=True, exist_ok=True)
    languages: set[str] = set()
    for catalog in catalogs:
        languages |= compile_catalog(catalog, args.output)
    print(f"compile-localizations: wrote {len(languages)} language(s) to "
          f"{args.output}: {', '.join(sorted(languages))}")
    return 0


def directories_equal(left: Path, right: Path) -> bool:
    if not right.is_dir():
        return False
    left_files = {p.relative_to(left): p.read_bytes() for p in left.rglob("*") if p.is_file()}
    right_files = {p.relative_to(right): p.read_bytes() for p in right.rglob("*") if p.is_file()}
    return left_files == right_files


if __name__ == "__main__":
    sys.exit(main())
