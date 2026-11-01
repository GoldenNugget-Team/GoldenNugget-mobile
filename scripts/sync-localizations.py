#!/usr/bin/env python3
"""Keep Localizable.xcstrings in step with the strings the app can display.

Xcode extracts `Text("…")`, `Label("…")`, `String(localized:)` and the rest of
SwiftUI's localization-aware API into `.stringsdata` files during a build.  That
is the authoritative list — it knows whether an interpolation became `%lld` or
`%@` — and this script merges those files into the catalog with
`xcstringstool sync`.

Two kinds of key the compiler cannot see are added by hand here:

  * the custom view components in `Nugget/Views/NativeUI.swift` and the small
    row/card helpers the views declare — they take a `String` or a
    `LocalizedStringKey` (so the call sites stay readable) and localize it
    inside their body, which is invisible to the extractor,
  * the More page's section titles, which live in a plain `[(String, […])]`
    table, and
  * `InfoPlist.xcstrings`, whose keys are plist keys rather than source text.

With `--check` nothing is written: the catalog is synced into a temporary copy
and compared with the committed file.  That is the CI guard — a new literal that
nobody extracted, or a key that was deleted from the code but left behind, fails
the build instead of shipping an untranslatable string.

Usage:
    scripts/sync-localizations.py            # update the catalogs
    scripts/sync-localizations.py --check    # report drift, exit 1, no write

Run a build first (or let the script fall back to xcstringstool's own parser) so
interpolated keys get their real format specifiers.  On a host without Xcode the
fallback still finds the keys, but records `%arg` for an interpolation — fine
for translation, not fine to commit: run the script on macOS once.
"""

from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
APP_DIR = ROOT / "layout" / "Applications" / "GoldenNuggetMobile.app"
CATALOG = APP_DIR / "Localizable.xcstrings"
SOURCES = sorted((ROOT / "Nugget").rglob("*.swift"))

# The component initializers whose literal argument never reaches a SwiftUI
# initializer the compiler recognizes.  Keep in sync with NativeUI.swift and the
# small row/card helpers the views declare (they take a `LocalizedStringKey` and
# hand it to a `Text`/`Toggle` inside, which is invisible to the extractor too).
COMPONENT_KEYS = [
    re.compile(r"\bNativeNote\s*\(\s*"),
    re.compile(r"\bNativeSafetyNote\s*\(\s*"),
    re.compile(r"\bNativePrimaryButton\s*\(\s*title\s*:\s*"),
    re.compile(r"\bNativeDangerButton\s*\(\s*title\s*:\s*"),
    re.compile(r"\bNativeCollapsibleHeader\s*\(\s*title\s*:\s*"),
    re.compile(r"\bLocalizedStringKey\s*\(\s*"),
    # SettingsView: the row title; the note is a NativeNote already.
    re.compile(r"\bswitchRow\s*\(\s*"),
    # SettingsView: the role, i.e. the second positional argument.  The first is
    # a proper name, which is data and stays untranslated.
    re.compile(r"\bcreditRow\s*\(\s*\"[^\"]*\"\s*,\s*"),
    re.compile(r"\bcontributorRow\s*\(\s*\"[^\"]*\"\s*,\s*"),
    # FirstRunView: the step and action cards.
    re.compile(r"\bstepCard\s*\(\s*number\s*:\s*[^,]+,\s*title\s*:\s*"),
    re.compile(r"\bactionCard\s*\(\s*icon\s*:\s*\"[^\"]*\"\s*,\s*title\s*:\s*"),
    re.compile(r"\bactionCard\s*\(\s*icon\s*:\s*\"[^\"]*\"\s*,\s*title\s*:\s*\"[^\"]*\"\s*,\s*subtitle\s*:\s*"),
    # WalletView's numbered instruction row.
    re.compile(r"\bstep\s*\(\s*\"[^\"]*\"\s*,\s*"),
    # StatusBarView's row helpers: the key enum, then the title.
    re.compile(r"\btoggleRow\s*\(\s*"),
    re.compile(r"\btextFieldRow\s*\(\s*\.[A-Za-z]+\s*,\s*"),
    re.compile(r"\blevelRow\s*\(\s*\.[A-Za-z]+\s*,\s*"),
    re.compile(r"\bnetworkRow\s*\(\s*\.[A-Za-z]+\s*,\s*"),
    # PasscodeThemeView's picker row.
    re.compile(r"\boptionRow\s*\(\s*title\s*:\s*"),
]

# The More page's section titles, which live in a `[(String, [AppDestination])]`
# table rather than in a SwiftUI initializer.
SECTION_KEYS = re.compile(r"\(\s*\"([^\"]+)\"\s*,\s*\[\s*\.")


def die(message: str) -> None:
    sys.exit(f"sync-localizations: {message}")


def run(command: list[str], **kwargs) -> subprocess.CompletedProcess:
    try:
        return subprocess.run(command, cwd=ROOT, check=True,
                              capture_output=True, text=True, **kwargs)
    except FileNotFoundError:
        die(f"{command[0]} not found; run this on a host with Xcode")
    except subprocess.CalledProcessError as error:
        die(f"{' '.join(command)} failed:\n{error.stderr.strip()}")


# --------------------------------------------------------------- string literals


def read_literal(text: str, start: int) -> tuple[str, int] | None:
    """Read one Swift string literal beginning at `start`.

    Returns its contents and the index just past the closing quote.  An
    interpolated literal is rejected (`None`): its runtime key depends on the
    values, and those call sites are expected to use `String(localized:)`, which
    the compiler extracts properly.
    """
    if start >= len(text) or text[start] != '"':
        return None
    index = start + 1
    value: list[str] = []
    while index < len(text):
        character = text[index]
        if character == "\\":
            if index + 1 >= len(text):
                return None
            escape = text[index + 1]
            if escape == "(":
                return None  # interpolation
            value.append({"n": "\n", "t": "\t", "r": "\r", '"': '"', "\\": "\\"}.get(escape, escape))
            index += 2
            continue
        if character == '"':
            return "".join(value), index + 1
        value.append(character)
        index += 1
    return None


def literal_chain(text: str, start: int) -> tuple[str, int] | None:
    """A literal, or a `+`-joined chain of literals, at `start`."""
    first = read_literal(text, start)
    if first is None:
        return None
    value, index = first
    while True:
        probe = index
        while probe < len(text) and text[probe] in " \t\r\n":
            probe += 1
        if probe < len(text) and text[probe] == "+":
            probe += 1
            while probe < len(text) and text[probe] in " \t\r\n":
                probe += 1
            following = read_literal(text, probe)
            if following is None:
                break
            chunk, index = following
            value += chunk
        else:
            break
    return value, index


def component_keys() -> set[str]:
    keys: set[str] = set()
    for path in SOURCES:
        text = path.read_text(encoding="utf-8")
        for pattern in COMPONENT_KEYS:
            for match in pattern.finditer(text):
                parsed = literal_chain(text, match.end())
                if parsed is not None:
                    key, _ = parsed
                    if key:
                        keys.add(key)
        for match in SECTION_KEYS.finditer(text):
            keys.add(match.group(1))
    return keys


def component_stringsdata(keys: set[str]) -> dict:
    """A `.stringsdata` document the same shape Xcode writes."""
    return {
        "source": str(ROOT / "Nugget" / "Views" / "NativeUI.swift"),
        "tables": {
            "Localizable": [
                {"comment": "", "key": key, "location": {"startingColumn": 1, "startingLine": 1}}
                for key in sorted(keys)
            ]
        },
    }


# ------------------------------------------------------------------ stringsdata


def build_stringsdata() -> list[Path]:
    """Find (or make) the `.stringsdata` files the catalog is synced from."""
    directories = sorted(
        (ROOT / "build" / "xderived").glob(
            "Build/Intermediates.noindex/GoldenNuggetMobile.build/*/GoldenNuggetMobile.build/Objects-normal/*"),
        key=lambda path: path.stat().st_mtime,
        reverse=True,
    )
    files = [p for directory in directories for p in directory.glob("*.stringsdata")]
    if files:
        return files  # type: ignore[return-value]

    # No build yet: ask xcstringstool's lightweight parser instead.  It is
    # allowed to record "%arg" for interpolations; that is called out in the
    # module docstring so a catalog generated this way is never committed.
    print("sync-localizations: no build found; using xcstringstool's parser "
          "(interpolated keys may say %arg)", file=sys.stderr)
    output = Path(tempfile.mkdtemp(prefix="gn-l10n-"))
    run(["xcrun", "xcstringstool", "extract",
         "--SwiftUI", "--modern-localizable-strings", "--legacy-localizable-strings",
         "--output-format", "stringsdata", "-o", str(output), *map(str, SOURCES)])
    return sorted(output.glob("*.stringsdata"))


def drop_empty_keys(files: list[Path]) -> list[Path]:
    """Strip empty keys from the `.stringsdata` copies handed to `xcstringstool`.

    `Toggle("", …)` and `Picker("", …)` are the idiomatic "no visible label"
    forms (the row draws its own), and the compiler records the empty literal as
    a localizable key.  An empty string cannot be translated, so it is dropped
    here rather than committed as a catalog entry nobody can fill in.
    """
    cleaned: list[Path] = []
    temporary = Path(tempfile.mkdtemp(prefix="gn-l10n-clean-"))
    for path in files:
        document = json.loads(path.read_text(encoding="utf-8"))
        changed = False
        for table in (document.get("tables") or {}).values():
            kept = [entry for entry in table if (entry.get("key") or "").strip()]
            if len(kept) != len(table):
                changed = True
                table[:] = kept
        if not changed:
            cleaned.append(path)
            continue
        copy = temporary / path.name
        copy.write_text(json.dumps(document), encoding="utf-8")
        cleaned.append(copy)
    return cleaned


def prune_empty_entries(catalog: Path) -> None:
    """Drop catalog entries that carry neither localizations nor a state.

    `xcstringstool sync` leaves a key it no longer sees in the source as `{}` in
    some cases (a literal that became `Text(verbatim:)`), and an empty object is
    not a translatable string.  Removing it here keeps the committed catalog a
    list of keys the app can actually display.
    """
    document = json.loads(catalog.read_text(encoding="utf-8"))
    strings = document.get("strings") or {}
    empty = [key for key, entry in strings.items() if not entry]
    if not empty:
        return
    for key in empty:
        del strings[key]
    catalog.write_text(json.dumps(document, ensure_ascii=False, indent=2,
                                  sort_keys=True) + "\n", encoding="utf-8")


def sync(catalog: Path, stringsdata: list[Path], *, check: bool) -> None:
    files = [str(path) for path in stringsdata]
    if check:
        with tempfile.TemporaryDirectory() as temporary:
            copy = Path(temporary) / catalog.name
            shutil.copy2(catalog, copy)
            prune_empty_entries(copy)
            run(["xcrun", "xcstringstool", "sync", str(copy), "--stringsdata", *files])
            before = json.loads(catalog.read_text(encoding="utf-8"))
            after = json.loads(copy.read_text(encoding="utf-8"))
            report_drift(before, after)
        return

    prune_empty_entries(catalog)
    run(["xcrun", "xcstringstool", "sync", str(catalog), "--stringsdata", *files])


def report_drift(before: dict, after: dict) -> None:
    old = before.get("strings") or {}
    new = after.get("strings") or {}

    added = sorted(set(new) - set(old))
    removed = sorted(set(old) - set(new))
    stale = sorted(key for key in old if (new.get(key) or {}).get("extractionState") == "stale"
                   and (old.get(key) or {}).get("extractionState") != "stale")
    revived = sorted(key for key in old if (old.get(key) or {}).get("extractionState") == "stale"
                     and (new.get(key) or {}).get("extractionState") != "stale")

    problems = False
    for label, keys in (("missing from the catalog", added),
                        ("no longer in the source", removed),
                        ("now stale", stale),
                        ("stale but found again", revived)):
        if keys:
            problems = True
            print(f"sync-localizations: {len(keys)} key(s) {label}:", file=sys.stderr)
            for key in keys[:20]:
                print(f"  {key!r}", file=sys.stderr)
            if len(keys) > 20:
                print(f"  … and {len(keys) - 20} more", file=sys.stderr)

    if problems:
        print("sync-localizations: run scripts/sync-localizations.py and commit "
              "Localizable.xcstrings", file=sys.stderr)
        sys.exit(1)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true",
                        help="report drift and exit 1 instead of writing")
    args = parser.parse_args()

    if not CATALOG.is_file():
        die(f"no catalog at {CATALOG}")

    stringsdata = build_stringsdata()
    extra = Path(tempfile.mkdtemp(prefix="gn-l10n-components-")) / "NativeUI.stringsdata"
    extra.write_text(json.dumps(component_stringsdata(component_keys())), encoding="utf-8")
    stringsdata = drop_empty_keys([*stringsdata, extra])

    sync(CATALOG, stringsdata, check=args.check)

    keys = len((json.loads(CATALOG.read_text(encoding="utf-8")).get("strings") or {}))
    print(f"sync-localizations: {keys} keys in {CATALOG.relative_to(ROOT)}"
          + (" (check only)" if args.check else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
