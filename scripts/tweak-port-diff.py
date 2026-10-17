#!/usr/bin/env python3
"""Differential test for the tweak port's *compile* step.

The port's risky half is the injector (row shapes, which only a device can
confirm).  The other half — turning a tweak selection into a set of plists and
domains — is pure data, and "looks right" is not evidence for pure data.  So this
compares it against the reference itself:

    Swift side   `Nugget/Core/TweakCompiler.swift` (+ TweakModel/TweakCatalog/
                 TweakDomainMap, compiled by `xcrun swiftc` for the host)
    Python side  GoldenNugget's own `SPECS` + `BasicPlistTweak.apply_tweak` /
                 `AdvancedPlistTweak.apply_tweak` + `split_path_into_domain`

The Python side deliberately reproduces the **two documented divergences** so
that everything else must match exactly:

  1. an enabled-but-incompatible tweak is dropped (the reference's UI hides it,
     but its apply pass would still write it);
  2. the HomeDomain `.GlobalPreferences.plist` mirror is written only when there
     is something to mirror (the reference writes `{}` unconditionally and would
     overwrite the device's real file with an empty dict on a run that touches
     no GP key).

Any difference beyond those two is a bug in the port.

Usage:
    scripts/tweak-port-diff.py [--goldennugget ~/GoldenNugget] [-v]
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import tempfile
import types
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CORE = ROOT / "Nugget" / "Core"
HARNESS = ROOT / "scripts" / "tweak-port-harness" / "main.swift"
DEFAULT_SOURCE = os.path.expanduser("~/GoldenNugget")

# The compiler's own closure — and nothing else, so the harness needs no device
# stack (no UIKit, no Minimuxer, no SQLite).
HARNESS_SOURCES = ["TweakModel.swift", "TweakCatalog.swift",
                   "TweakCatalogDaemons.swift",
                   "TweakDomainMap.swift", "TweakCompiler.swift"]


def die(message: str):
    sys.exit(f"tweak-port-diff: {message}")


def load_reference(source: Path):
    pyside = types.ModuleType("PySide6")
    qtcore = types.ModuleType("PySide6.QtCore")
    qtcore.QT_TRANSLATE_NOOP = lambda context, text: text
    pyside.QtCore = qtcore
    sys.modules["PySide6"] = pyside
    sys.modules["PySide6.QtCore"] = qtcore
    sys.path.insert(0, str(source))

    import importlib.util

    # `src/restore/__init__.py` pulls in pymobiledevice3 — the reference's own
    # `src/utils/file_to_restore.py` documents exactly this and works around it
    # for the same reason ("Importing anything under the src.restore package
    # executes its __init__.py").  path_mapping.py is stdlib-only with no
    # relative imports, so loading it from its file is faithful and cheap.
    mapping_path = source / "src" / "restore" / "path_mapping.py"
    if not mapping_path.is_file():
        die(f"{mapping_path} not found")
    module_spec = importlib.util.spec_from_file_location("gn_path_mapping", mapping_path)
    mapping = importlib.util.module_from_spec(module_spec)
    module_spec.loader.exec_module(mapping)

    from src.tweaks.basic_plist_locations import FileLocation
    from src.tweaks.registry import SPECS
    from src.tweaks.tweak_classes import AdvancedPlistTweak, BasicPlistTweak
    return (SPECS, FileLocation, BasicPlistTweak, AdvancedPlistTweak,
            mapping.split_path_into_domain)


def build_harness(verbose: bool) -> Path:
    binary = Path(tempfile.mkdtemp(prefix="tweak-harness-")) / "harness"
    command = ["xcrun", "swiftc", "-swift-version", "5", "-o", str(binary)]
    command += [str(CORE / name) for name in HARNESS_SOURCES]
    command.append(str(HARNESS))
    if verbose:
        print("$ " + " ".join(command))
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode != 0:
        die(f"harness did not build:\n{result.stdout}\n{result.stderr}")
    return binary


# --------------------------------------------------------------- reference side


def make_reference_compiler(SPECS, FileLocation, BasicPlistTweak, AdvancedPlistTweak,
                            split_path_into_domain):
    """The reference's `_apply_tweak_pass` compile step, with the two documented
    divergences applied so everything else must match the port exactly."""
    by_id = {spec.id.name: spec for spec in SPECS if not spec.disabled}

    def compatible(spec, device_version, is_iphone):
        # The reference's own gate, `src/gui/ios/compat.py:is_tweak_compatible`.
        if device_version and spec.min_version:
            from packaging.version import Version
            if Version(device_version) < Version(spec.min_version):
                return False
        if device_version and spec.max_version:
            from packaging.version import Version
            if Version(device_version) > Version(spec.max_version):
                return False
        if spec.ipad_only and is_iphone:
            return False
        if spec.iphone_only and not is_iphone:
            return False
        return True

    def compile_case(tweaks: dict, device_version: str, is_iphone: bool) -> dict:
        other_tweaks: dict = {}
        for spec in SPECS:
            if spec.disabled:
                continue
            name = spec.id.name
            if name not in tweaks:
                continue
            if not compatible(spec, device_version, is_iphone):   # divergence 1
                continue
            tweak = spec.factory() if spec.factory is not None \
                else BasicPlistTweak(spec.location, spec.key, value=spec.value)
            tweak.enabled = True
            supplied = tweaks[name]
            if supplied is not None:
                tweak.value = supplied
            other_tweaks = tweak.apply_tweak(other_tweaks)

        out = {}
        for location, plist in other_tweaks.items():
            domain, relative_path = split_path_into_domain(location.value)
            out[f"{domain}/{relative_path}"] = plist

        gp = other_tweaks.get(FileLocation.globalPreferences)
        if gp:                                                     # divergence 2
            domain, relative_path = split_path_into_domain(
                FileLocation.globalPreferencesHomeDomain.value)
            out[f"{domain}/{relative_path}"] = gp
        return out

    return compile_case, by_id


# --------------------------------------------------------------------- test data


def build_cases(by_id) -> dict:
    """One case per spec (its own default), plus the cross-cutting shapes."""
    cases: dict[str, dict] = {}
    for name in sorted(by_id):
        cases[f"only::{name}"] = {name: None}

    # Values that exercise each Kind and each gate.
    cases["values::text"] = {"LockScreenFootnote": "hello world"}
    cases["values::number-int"] = {"SBMinimumLockscreenIdleTime": 12}
    cases["values::number-decimal"] = {"SolariumHighlightWhite": 0.25}
    cases["values::false-default"] = {"DisableSolariumHDR": True}
    cases["values::multi-dict"] = {"WatchOSCompatibility": {
        "IOS_PAIRING_EOL_MIN_PAIRING_COMPATIBILITY_VERSION_CHIPIDS": "",
        "maxPairingCompatibilityVersion": 37,
        "lastRestoreIdentifier": "CD97EEB8-BCD2-486B-BC13-C384E6B916C4",
        "minPairingCompatibilityVersionWithChipID": 1,
        "lastRestoreIdentifier_state": 0,
        "AdvertisingIdentifierSeed": "85E70251-1960-4DA0-A321-B68AC118FAB5",
        "minPairingCompatibilityVersion": 1,
    }}

    # Shared-plist merging: all 98 Liquid Glass tweaks land in one
    # .GlobalPreferences.plist, which exercises the merge and the GP mirror.
    sections = {}
    from src.tweaks.registry import SPECS
    for spec in SPECS:
        sections.setdefault(spec.section.name, []).append(spec.id.name)
    for section, names in sections.items():
        cases[f"section::{section}"] = {name: None for name in names}
    cases["all::every-tweak"] = {name: None for name in by_id}
    return cases


def tagged(value) -> str:
    """The same type-tagged rendering the Swift harness prints.

    `True` and `1` must not compare equal, and neither must `1` and `1.0`:
    `registry.py` writes both numeric forms and the resulting plist type
    differs, so a comparison that flattens them would pass on a real bug.
    """
    if isinstance(value, bool):
        return f"bool:{'true' if value else 'false'}"
    if isinstance(value, int):
        return f"int:{value}"
    if isinstance(value, float):
        return f"real:{value!r}"
    if isinstance(value, str):
        return f"str:{value}"
    if isinstance(value, bytes):
        return f"data:{len(value)}"
    if isinstance(value, dict):
        return "dict{" + ",".join(f"{k}={tagged(value[k])}" for k in sorted(value)) + "}"
    if isinstance(value, (list, tuple)):
        return "array[" + ",".join(tagged(v) for v in value) + "]"
    return f"other:{value!r}"


def tag_plists(payloads: dict) -> dict:
    """`{label: {key: tag}}` — the shape the harness emits."""
    return {label: {key: tagged(v) for key, v in plist.items()}
            for label, plist in payloads.items()}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--goldennugget", default=DEFAULT_SOURCE)
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args()

    SPECS, FileLocation, BasicPlistTweak, AdvancedPlistTweak, split = load_reference(
        Path(args.goldennugget))
    compile_case, by_id = make_reference_compiler(
        SPECS, FileLocation, BasicPlistTweak, AdvancedPlistTweak, split)
    cases = build_cases(by_id)

    binary = build_harness(args.verbose)

    # Three device profiles so the version/device gates are exercised, not just
    # the happy path.
    profiles = [("27.0", "iphone", True), ("26.5", "ipad", False), ("27.0", "ipad", False)]

    failures = 0
    total = 0
    for version, model, is_iphone in profiles:
        payload = json.dumps(cases)
        result = subprocess.run([str(binary), payload, version, model],
                                capture_output=True, text=True)
        if result.returncode != 0:
            die(f"harness failed on {version}/{model}:\n{result.stderr}")
        swift_output = json.loads(result.stdout)

        for name, tweaks in cases.items():
            total += 1
            expected = tag_plists(compile_case(tweaks, version, is_iphone))
            actual = swift_output.get(name, {})
            if expected != actual:
                failures += 1
                print(f"MISMATCH [{version}/{model}] {name}", file=sys.stderr)
                for key in sorted(set(expected) | set(actual)):
                    if expected.get(key) != actual.get(key):
                        print(f"    {key}", file=sys.stderr)
                        print(f"      reference: {expected.get(key)}", file=sys.stderr)
                        print(f"      port:      {actual.get(key)}", file=sys.stderr)
                if failures > 8:
                    die("too many mismatches — stopping")

    if failures:
        print(f"\n{failures} of {total} case(s) differ", file=sys.stderr)
        return 1
    print(f"tweak compiler matches the reference on {total} case(s) "
          f"({len(cases)} selections × {len(profiles)} device profiles)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
