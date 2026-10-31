#!/usr/bin/env python3
"""Emit the daemon groups GoldenNugget's Daemons page exposes, as Swift.

Source of truth is the reference itself: `src/tweaks/daemons_tweak.py` (the
`Daemon` enum, the interface whitelist, the recommended set) and
`src/gui/ios/daemons.py` (which groups get a switch, and their titles).

Why this is separate from `gen-tweaks-from-goldennugget.py`: that one walks
`registry.py`, and daemons are deliberately *not* in the registry. Upstream
registers them at `load_daemons()` time as a single `AdvancedPlistTweak` over
`/var/db/com.apple.xpc.launchd/disabled.plist`, and the per-group switches are
built in the GUI rather than declared as tweak specs. Modelling one spec per
group is what makes them survive the port's Apply / autosave / preset paths,
which all work off the catalog.

Two facts the reference is careful about and this file has to carry:

  * `INTERFACE_KEYS` is the whitelist. Every daemon outside it must never reach
    the plist, a preset or the apply pass -- upstream says disabling those
    "broke whole apps on iOS 26.5".
  * Switch rows are read from the desktop GUI. Interface groups without a
    row remain available through presets/recommended selection and are emitted
    with `showsSwitch: false`. Rows in the GUI's third table (the "Risky"
    3-tuples with a warning line) ride the Disable section and carry the
    warning as `information`.

Usage:
    scripts/gen-daemons-from-goldennugget.py [--goldennugget <path>]
"""
from __future__ import annotations

import argparse
import ast
import json
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
OUTPUT = REPO / "Nugget/Core/TweakCatalogDaemons.swift"

# Filled from the desktop GUI's literal row tables by load_reference().
MAIN: list[tuple[str, str, str | None]] = []
ANALYTICS: list[tuple[str, str, str | None]] = []
RISKY: list[tuple[str, str, str | None]] = []
RECOMMENDED: list[str] = []
# Rows in RISKY carry a warning line (the 3rd tuple element); keyed by daemon
# name and re-emitted as `information`. Empty when the desktop has no Risky
# rows.
INFORMATION: dict[str, str] = {}

# `TweakID.ClearScreenTimeAgentPlist` is a NullifyFileTweak: it does not write
# the ScreenTime plist, it writes a 0-byte file over it. The port's registry
# has no nullify shape, so the row exists in the catalog with an empty key and
# the injector is told to truncate rather than serialise.
SCREENTIME = (
    "ClearScreenTimeAgentPlist",
    "Disable Screen Time Agent",
    "/var/mobile/Library/Preferences/com.apple.ScreenTimeAgent.plist",
)

SECTIONS = {"main": MAIN, "analytics": ANALYTICS}


def swift_string(value: str) -> str:
    return json.dumps(value, ensure_ascii=False)


def load_reference(root: Path):
    global MAIN, ANALYTICS, RISKY, RECOMMENDED, SECTIONS, INFORMATION
    # Read literal row data without importing Qt or constructing the desktop UI.
    # Three tables: two 2-tuples (`title, daemon`) for the main Disable and
    # Analytics rows, one 3-tuple (`title, daemon, information`) for the Risky
    # rows the reference shows with a warning line. Titles arrive either as
    # `QCoreApplication.translate(...)` calls or plain `self.tr`-able strings.
    tree = ast.parse((root / "src/gui/ios/daemons.py").read_text())
    tables = []

    def parsed_title(node) -> str | None:
        # Rows bind either `QCoreApplication.translate("Nugget", 'Title')`
        # (or `self.tr('Title')`): the string payload is the last positional
        # string constant, never the translate context.
        if isinstance(node, ast.Constant) and isinstance(node.value, str):
            return node.value
        if isinstance(node, ast.Call):
            candidates = [a.value for a in node.args
                          if isinstance(a, ast.Constant) and isinstance(a.value, str)]
            candidates += [kw.value.value for kw in node.keywords
                           if kw.arg == "text" and isinstance(kw.value, ast.Constant)
                           and isinstance(kw.value.value, str)]
            if candidates:
                return candidates[-1]
        return None

    for node in ast.walk(tree):
        if not isinstance(node, ast.For) or not isinstance(node.iter, (ast.List, ast.Tuple)):
            continue
        rows: list[tuple[str, str, str | None]] = []
        for item in node.iter.elts:
            if not isinstance(item, ast.Tuple) or len(item.elts) not in (2, 3):
                break
            title, daemon, *rest = item.elts
            if not (parsed_title(title) is not None
                    and isinstance(daemon, ast.Attribute) and isinstance(daemon.value, ast.Name)
                    and daemon.value.id == "Daemon"):
                break
            information = (rest[0].value if rest and isinstance(rest[0], ast.Constant)
                           and isinstance(rest[0].value, str) else None)
            rows.append((daemon.attr, parsed_title(title), information))
        else:
            if rows:
                tables.append((node.lineno, rows))
    tables.sort()
    if len(tables) != 3:
        raise ValueError("Expected three desktop daemon switch tables; update the generator")
    MAIN, ANALYTICS, RISKY = (table[1] for table in tables)
    SECTIONS = {"main": MAIN, "analytics": ANALYTICS}
    INFORMATION = {name: info for name, _, info in RISKY if info}
    sys.path.insert(0, str(root))
    from src.tweaks.daemons_tweak import (  # noqa: E402
        DANGEROUS_KEYS,
        INTERFACE_DAEMONS,
        INTERFACE_KEYS,
        Daemon,
        RECOMMENDED_ANALYTICS,
    )
    RECOMMENDED = [daemon.name for daemon in RECOMMENDED_ANALYTICS]
    return Daemon, INTERFACE_DAEMONS, INTERFACE_KEYS, DANGEROUS_KEYS


def emit(Daemon, INTERFACE_DAEMONS, INTERFACE_KEYS, DANGEROUS_KEYS) -> list[str]:
    out: list[str] = []
    w = out.append

    interface = {d.name for d in INTERFACE_DAEMONS}

    w("// GENERATED FILE — do not edit by hand.")
    w("//")
    w("// Source of truth: GoldenNugget's `src/tweaks/daemons_tweak.py` and the")
    w("// group tables in `src/gui/ios/daemons.py`.  Regenerate with:")
    w("//")
    w("//     scripts/gen-daemons-from-goldennugget.py [--goldennugget <path>]")
    w("//")
    w("// Daemons are not in `registry.py` -- upstream registers them in")
    w("// `load_daemons()` as a single `AdvancedPlistTweak` over the launchd")
    w("// `disabled.plist`, and builds the per-group switches in the GUI. One")
    w("// spec per group is what lets them ride the port's Apply, autosave and")
    w("// preset paths, all of which work off the catalog.")
    w("")
    w("import Foundation")
    w("")
    w("/// One switch on the Daemons page: a named group of launchd labels that")
    w("/// are disabled together.")
    w("///")
    w("/// `showsSwitch` is false for interface-visible groups upstream")
    w("/// gives no switch of its own (AppleAds, CrashReports, Diagnostics,")
    w("/// Feedback, SettingsStats, Shazam). They stay in the catalog -- they are")
    w("/// part of `INTERFACE_DAEMONS` and the Recommended set turns them on --")
    w("/// but the page must not offer a per-group switch for them.")
    w("struct DaemonGroup: Sendable {")
    w("    let name: String")
    w("    let title: String")
    w("    let labels: [String]")
    w("    let section: DaemonSection")
    w("    let isRecommended: Bool")
    w("    let showsSwitch: Bool")
    w("    /// The reference's row warning line (its `Risky tweaks` rows): the")
    w("    /// sentence the desktop shows under the title, e.g. what breaking")
    w("    /// thermal monitoring or ATWAKEUP costs. nil everywhere else.")
    w("    let information: String?")
    w("}")
    w("")
    w("/// The two groups of switches on the Daemons page, in the reference's order.")
    w("enum DaemonSection: String, CaseIterable, Identifiable, Sendable {")
    w("    case disable = \"Daemons to Disable\"")
    w("    case analytics = \"Analytics, Data Tracking & Logging\"")
    w("    var id: String { rawValue }")
    w("}")
    w("")
    w("enum DaemonGroups {")

    # The table, ordered the way the page shows it. The two Risky rows
    # (3-tuples with the warning line) ride the Disable section after the main
    # rows: the desktop page surfaces them under a "Risky tweaks" heading,
    # which this two-section page has no room for -- a disable-type action
    # either way.
    w("    static let all: [DaemonGroup] = [")
    for section_name, members in SECTIONS.items():
        case = "disable" if section_name == "main" else "analytics"
        if section_name == "main":
            members = members + RISKY
        for name, title, information in members:
            labels = Daemon[name].value
            w("        DaemonGroup(")
            w(f"            name: {swift_string(name)},")
            w(f"            title: {swift_string(title)},")
            w(f"            labels: [{', '.join(swift_string(x) for x in labels)}],")
            w(f"            section: .{case},")
            w(f"            isRecommended: {str(name in RECOMMENDED).lower()},")
            w("            showsSwitch: true,")
            info = INFORMATION.get(name)
            w("            information: "
              + (swift_string(info) if info is not None else "nil"))
            w("        ),")
    # Groups without a switch, appended so `all` stays complete for the
    # compiler and the Recommended set. They carry an empty section on purpose:
    # nothing renders them individually.
    for name in sorted(interface):
        if (any(name == n for n, _, _ in MAIN)
                or any(name == n for n, _, _ in ANALYTICS)
                or any(name == n for n, _, _ in RISKY)):
            continue
        labels = Daemon[name].value
        w("        DaemonGroup(")
        w(f"            name: {swift_string(name)},")
        w(f"            title: {swift_string(name)},")
        w(f"            labels: [{', '.join(swift_string(x) for x in labels)}],")
        w("            section: .analytics,")
        w(f"            isRecommended: {str(name in RECOMMENDED).lower()},")
        w("            showsSwitch: false,")
        w("            information: nil")
        w("        ),")
    w("    ]")
    w("")
    w("    /// The one-tap \"Recommended\" set: pure analytics, tracking and")
    w("    /// logging, nothing boot-critical.  Upstream's comment on")
    w("    /// `RECOMMENDED_ANALYTICS` says the same.")
    w("    static let recommended: [DaemonGroup] = all.filter(\\.isRecommended)")
    w("")
    w("    static let byName: [String: DaemonGroup] =")
    w("        Dictionary(uniqueKeysWithValues: all.map { ($0.name, $0) })")
    w("")
    w("    /// Every launchd label the reference will let a preset carry.  Mirrors")
    w("    /// `INTERFACE_KEYS`: a label outside this set must never reach the")
    w("    /// plist, because disabling those daemons broke whole apps on 26.5.")
    w("    static let allowedKeys: Set<String> = [")
    for key in sorted(INTERFACE_KEYS):
        w(f"        {swift_string(key)},")
    w("    ]")
    w("")
    w("    /// `DANGEROUS_KEYS` upstream, which is empty by design: entries are")
    w("    /// deleted from the reference rather than blocked at runtime.  Kept so a")
    w("    /// future upstream entry shows up as a diff instead of silently")
    w("    /// becoming writable.")
    w("    static let dangerousKeys: Set<String> = [")
    for key in sorted(DANGEROUS_KEYS):
        w(f"        {swift_string(key)},")
    w("    ]")
    w("")
    w("    /// `TweakID.ClearScreenTimeAgentPlist`: a `NullifyFileTweak`, i.e. a")
    w("    /// 0-byte file written over the plist rather than a serialised dict.")
    w("    static let screenTime = DaemonNullify(")
    w(f"        id: {swift_string(SCREENTIME[0])},")
    w(f"        title: {swift_string(SCREENTIME[1])},")
    w(f"        path: {swift_string(SCREENTIME[2])}")
    w("    )")
    w("}")
    w("")
    w("/// A file the port overwrites with zero bytes rather than serialising.")
    w("struct DaemonNullify: Sendable {")
    w("    let id: String")
    w("    let title: String")
    w("    let path: String")
    w("}")
    w("")
    w("extension TweakCatalog {")
    w("    /// The daemon groups as tweak specs, so Apply, autosave and preset")
    w("    /// import all work on them unchanged.")
    w("    ///")
    w("    /// `multiValues` carries the group's labels mapped to `false`: a group is")
    w("    /// \"on\" when the user wants it disabled, and the compiler writes the")
    w("    /// labels of every on-group into the launchd `disabled.plist`.")
    w("    static let daemonSpecs: [TweakSpec] = DaemonGroups.all.map { group in")
    w("        TweakSpec(")
    w("            id: \"Daemon.\\(group.name)\",")
    w("            section: .daemons,")
    w("            title: group.title,")
    w("            location: .disabledDaemons,")
    w("            key: \"\",")
    w("            value: .bool(false),")
    w("            kind: .toggle,")
    w("            minValue: 0.0,")
    w("            maxValue: 1.0,")
    w("            step: 1.0,")
    w("            minVersion: nil,")
    w("            maxVersion: nil,")
    w("            iphoneOnly: false,")
    w("            ipadOnly: false,")
    w("            disabled: false,")
    w("            detail: group.information ?? \"Disables \\(group.labels.count) launchd \"")
    w("                + \"\\(group.labels.count == 1 ? \"daemon\" : \"daemons\"): \"")
    w("                + group.labels.joined(separator: \", \") + \".\",")
    w("            multiValues: Dictionary(")
    w("                uniqueKeysWithValues: group.labels.map { ($0, TweakValue.bool(false)) }")
    w("            )")
    w("        )")
    w("    }")
    w("")
    w("    /// The ScreenTime nullify, which is not a daemon group and so has no")
    w("    /// `multiValues`: it truncates a file instead of writing a dict.")
    w("    static let screenTimeSpec = TweakSpec(")
    w("        id: \"\\(DaemonGroups.screenTime.id)\",")
    w("        section: .daemons,")
    w("        title: \"\\(DaemonGroups.screenTime.title)\",")
    w("        location: .screentime,")
    w("        key: \"\",")
    w("        value: .bool(false),")
    w("        kind: .toggle,")
    w("        minValue: 0.0,")
    w("        maxValue: 1.0,")
    w("        step: 1.0,")
    w("        minVersion: nil,")
    w("        maxVersion: nil,")
    w("        iphoneOnly: false,")
    w("        ipadOnly: false,")
    w("        disabled: false,")
    w("        detail: \"Writes a 0-byte file over \"")
    w("            + \"\\(DaemonGroups.screenTime.path).\",")
    w("        multiValues: nil")
    w("    )")
    w("}")
    return out


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--goldennugget", default=str(REPO.parent / "GoldenNugget"))
    parser.add_argument("--check", action="store_true",
                        help="verify the file on disk matches, do not write")
    args = parser.parse_args()

    root = Path(args.goldennugget)
    if not (root / "src/tweaks/daemons_tweak.py").exists():
        print(f"gen-daemons: no GoldenNugget at {root}", file=sys.stderr)
        return 1

    data = load_reference(root)
    lines = emit(*data)
    text = "\n".join(lines) + "\n"

    if args.check:
        current = OUTPUT.read_text() if OUTPUT.exists() else ""
        if current == text:
            # `DaemonGroupsCount` already returns a count — `len()` on it raised
            # `TypeError: object of type 'int' has no len()`, so this gate could
            # never report a pass (only a traceback) and read as "drift" either
            # way.
            print(f"TweakCatalogDaemons.swift matches the reference "
                  f"({DaemonGroupsCount(data)} groups)")
            return 0
        print("TweakCatalogDaemons.swift is out of date", file=sys.stderr)
        return 1

    OUTPUT.write_text(text)
    print(f"wrote {OUTPUT.relative_to(REPO)}")
    return 0


def DaemonGroupsCount(data) -> int:
    Daemon, INTERFACE_DAEMONS, _, _ = data
    return len(INTERFACE_DAEMONS)


if __name__ == "__main__":
    sys.exit(main())
