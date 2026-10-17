#!/usr/bin/env python3
"""Differential check of `ProtectiveBackup`'s HomeDomain keep/skip predicates.

Ported from GoldenNugget's `tools/test_protective_filters.py`, extended with the
two rows the reference added in a2d5373 and with the shape cases this port's
`startsWith` deliberately differs on (see `ProtectiveBackup.startsWith`).

The contract under test is a *device* one in both directions:

  * a row the rules **drop** but the device expects produces MBErrorDomain/205
    ("Unknown domain name in file record"), so a missing skip is a restore
    failure;
  * a row the rules **keep** that the reference drops is a stale copy handed
    back — harmless to the restore, but it silently undoes the tweak, which is
    the bug a2d5373 was filed for.

Both spellings of the status-bar override have to be skipped: the classic record
is `statusBarOverrides` (lower-case s) and the iOS 27 record is
`StatusBarOverrides.archive` (capital S). `startsWith` is a plain prefix test —
deliberately, to match Python's `str.startswith` — so the lower-case prefix does
NOT match the archive, and the archive needs its own entry.

Usage:
    scripts/check-protective-filters.py
    scripts/check-protective-filters.py --swift-source Nugget/Core/ProtectiveBackup.swift
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_SOURCE = ROOT / "Nugget" / "Core" / "ProtectiveBackup.swift"

PASS = 0
FAIL = 0


def check(label: str, condition: bool, detail: str = "") -> None:
    global PASS, FAIL
    if condition:
        PASS += 1
        print(f"  ok   {label}")
    else:
        FAIL += 1
        print(f"  FAIL {label}{(': ' + detail) if detail else ''}")


def swift_string_array(source: str, name: str) -> list[str]:
    """The entries of a `let <name> = [ … ]` Swift array.

    The type annotation (`Set<String>`, `[String]`) sits between the name and the
    `=`, so the pattern allows an optional `: [ … ]` before it.
    """
    match = re.search(
        rf"let {re.escape(name)}\s*(?::[^=\n]*)?=\s*\[(.*?)\]", source, re.S)
    if match is None:
        sys.exit(f"check-protective-filters: no `let {name} = [ … ]` in the Swift source")
    body = match.group(1)
    body = re.sub(r"//[^\n]*", "", body)          # drop line comments
    body = re.sub(r"/\*.*?\*/", "", body, flags=re.S)
    return re.findall(r'"([^"]*)"', body)


class Model:
    """`ProtectiveBackup.isProtectiveEntry`, reimplemented from the parsed rules.

    Deliberately a transcription of the Swift rather than a copy of it: the
    point is to test the *rules* the Swift declares, and re-deriving them from
    the parsed arrays means a rule edited in Swift is what gets tested here.
    """

    def __init__(self, source: str) -> None:
        self.skip = swift_string_array(source, "skipPathPrefixes")
        self.skip_files = set(swift_string_array(source, "skipFiles"))
        self.domains = set(swift_string_array(source, "protectiveDomains"))
        groups = {}
        for key in ("appleIDPrefixes", "springBoardPrefixes", "controlCenterPrefixes",
                    "shortcutsPrefixes", "webClipsPrefixes", "webAppPrefixes",
                    "webkitWebsiteDataPrefixes", "addressBookPrefixes"):
            groups[key] = swift_string_array(source, key)
        self.groups = groups

    @staticmethod
    def starts_with(path: str, prefix: str) -> bool:
        # Python's str.startswith — a plain prefix test, no path boundary.
        return path.startswith(prefix)

    def entry(self, domain: str, relative_path: str) -> bool:
        filename = relative_path.rsplit("/", 1)[-1]
        if filename in self.skip_files:
            return False
        if domain == "HomeDomain":
            for prefix in self.skip:
                if self.starts_with(relative_path, prefix):
                    return False
            for group in self.groups.values():
                for prefix in group:
                    if self.starts_with(relative_path, prefix):
                        return True
            return False
        return domain in self.domains

    def keeps_row(self, domain: str, relative_path: str) -> bool:
        if domain and relative_path and (
            self.entry(domain, relative_path) or domain == "SystemPreferencesDomain"
        ):
            return True
        if not relative_path and domain in ("SystemPreferencesDomain", "MessagesDomain"):
            return True
        return False


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--swift-source", default=str(DEFAULT_SOURCE),
                    help="path to ProtectiveBackup.swift (default: the app source)")
    args = ap.parse_args()

    source_path = Path(args.swift_source)
    if not source_path.is_file():
        sys.exit(f"check-protective-filters: no {source_path}")
    model = Model(source_path.read_text(encoding="utf-8"))

    print("== status bar override files stay out of the backup (both spellings) ==")
    # Phase 3 restores Library/SpringBoard AFTER the tweak pass rewrote the
    # override, so a captured stale copy is handed straight back — the reset
    # looks like it did nothing. This is the a2d5373 row: the classic struct
    # (lower-case "s") and the iOS 27 archive (capital "S") are both skipped,
    # while the rest of SpringBoard's state is still kept.
    check("classic statusBarOverrides dropped",
          not model.entry("HomeDomain", "Library/SpringBoard/statusBarOverrides"))
    check("iOS 27 StatusBarOverrides.archive dropped",
          not model.entry("HomeDomain", "Library/SpringBoard/StatusBarOverrides.archive"))
    check("neighbouring SpringBoard state kept",
          model.entry("HomeDomain", "Library/SpringBoard/IconState.plist"))
    check("SpringBoardPreferences.plist kept",
          model.entry("HomeDomain", "Library/SpringBoard/SpringBoardPreferences.plist"))

    print("\n== how far the loose prefix test reaches ==")
    # `startsWith` is a plain prefix test on purpose (see the Swift's own
    # comment): GoldenNugget writes `relative_path.startswith(...)`, so
    # `Library/SpringBoard/statusBarOverridesExtra` matches
    # `Library/SpringBoard/statusBarOverrides`. Pinned here so the looseness is
    # a recorded fact rather than a surprise: the direction that matters is
    # safe, because a prune that keeps a row it did not have to keep is
    # harmless, while one that drops a row the device expects is the 205.
    for prefix in model.skip:
        leaf = prefix.rsplit("/", 1)[-1]
        parent = prefix.rsplit("/", 1)[0]
        check(f"{prefix} does match a longer sibling sharing its prefix "
              "(the reference's loose test, kept deliberately)",
              model.starts_with(f"{parent}/{leaf}Extra", prefix))
        check(f"{prefix} leaves an unrelated sibling in {parent} kept",
              model.entry("HomeDomain", f"{parent}/IconState.plist"))
        check(f"{prefix} leaves SpringBoardPreferences.plist kept",
              model.entry("HomeDomain", f"{parent}/SpringBoardPreferences.plist"))

    print("\n== the kept set is unchanged by the new skip ==")
    for path in ("Library/Preferences/com.apple.Preferences.plist",
                 "Library/Preferences/com.apple.mobilenotes.plist",
                 "Library/Accounts/Accounts3.sqlite",
                 "Library/ConfigurationProfiles/foo.mobileconfig",
                 "Library/ControlCenter/ModuleConfig.plist",
                 "Library/Shortcuts/shortcuts.db",
                 "Library/WebClips/bookmark.plist",
                 "Library/WebApp/Manifest.json",
                 "Library/WebKit/WebsiteData/History.db",
                 "Library/AddressBook/AddressBookImages.ab"):
        check(f"{path} kept", model.entry("HomeDomain", path))
    check("CameraRollDomain kept", model.entry("CameraRollDomain", "DCIM/100APPLE/IMG_1.HEIC"))
    check("MessagesDomain kept", model.entry("MessagesDomain", "4/abcdef/Message/1.db"))
    # SystemPreferencesDomain is kept by `keepsRow`, NOT by `isProtectiveEntry`:
    # the entry test has no branch for it and falls through to the domain set,
    # which does not list it. Asserted here because that asymmetry is easy to
    # "fix" by accident and would then be redundant rather than wrong.
    check("SystemPreferencesDomain is not an entry-level keep (keepsRow owns it)",
          not model.entry("SystemPreferencesDomain", "Library/Preferences/com.apple.mobiletimer.plist"))
    check("SystemPreferencesDomain kept at the row level",
          model.keeps_row("SystemPreferencesDomain", "Library/Preferences/com.apple.mobiletimer.plist"))

    print("\n== rows dropped for their own reasons are still dropped ==")
    check("keychain-backup.plist dropped",
          not model.entry("HomeDomain", "Library/Keychain/keychain-backup.plist"))
    check(".GlobalPreferences.plist dropped",
          not model.entry("HomeDomain", "Library/Preferences/.GlobalPreferences.plist"))
    check("an unrelated HomeDomain path dropped",
          not model.entry("HomeDomain", "Library/Caches/something.bin"))

    print("\n== the domain ROOT rows GoldenNugget keeps ==")
    check("SystemPreferencesDomain root kept",
          model.keeps_row("SystemPreferencesDomain", ""))
    check("MessagesDomain root kept", model.keeps_row("MessagesDomain", ""))
    check("HomeDomain root dropped", not model.keeps_row("HomeDomain", ""))
    check("CameraRollDomain root dropped", not model.keeps_row("CameraRollDomain", ""))

    print(f"\n{PASS} passed, {FAIL} failed")
    return 1 if FAIL else 0


if __name__ == "__main__":
    raise SystemExit(main())