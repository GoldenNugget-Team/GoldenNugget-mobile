#!/usr/bin/env python3
"""Compile shipping Swift into an iOS Simulator regression app and run it.

Usage: scripts/test-audit-regressions.py [--device <booted simulator UDID>]
Device-only imports are removed in the generated build directory. The source
bodies themselves are unchanged; only AFC/Airlift backends are doubled. This
never substitutes a successful fake pairing/restore for a hardware test.
"""
from __future__ import annotations
import argparse
import json
import platform
import plistlib
import subprocess
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "build" / "regression-simulator"
BUNDLE = "org.goldennugget.RegressionTests"
SOURCES = [
    "scripts/regression-simulator-support.swift",
    "Nugget/Views/Extensions/Extensions.swift",
    "Nugget/Core/Logging.swift", "Nugget/Core/InFlightCall.swift",
    "Nugget/Core/TweakModel.swift", "Nugget/Core/TweakCatalog.swift",
    "Nugget/Core/TweakCatalogDaemons.swift",
    "Nugget/Core/StatusBarModel.swift", "Nugget/Core/StatusBarArchive.swift",
    "Nugget/Core/AfcMediaBackup.swift", "Nugget/Core/WirelessPairing.swift",
    "Nugget/Core/PasscodeTheme.swift", "scripts/regression-simulator-check.swift",
]
DEVICE_IMPORTS = {"import Minimuxer", "import DeviceGatewayAPI", "import IdeviceGateway", "import IDevice"}


def command(args: list[str], **kwargs):
    return subprocess.run(args, check=True, text=True, **kwargs)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device")
    args = parser.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    if args.device:
        device = args.device
    else:
        raw = subprocess.check_output(["xcrun", "simctl", "list", "devices", "booted", "-j"], text=True)
        devices = json.loads(raw[raw.index("{"):])["devices"]
        booted = [d for group in devices.values() for d in group if d["state"] == "Booted"]
        if not booted:
            parser.error("Boot an iOS Simulator first, or pass --device after booting it")
        device = booted[0]["udid"]
    generated = []
    for name in SOURCES:
        generated.append("\n// SOURCE: " + name + "\n")
        generated.extend(line + "\n" for line in (ROOT / name).read_text().splitlines()
                         if line.strip() not in DEVICE_IMPORTS)
    source = OUT / "main.swift"
    source.write_text("".join(generated))
    sdk = subprocess.check_output(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"], text=True).strip()
    arch = "arm64" if platform.machine() == "arm64" else "x86_64"
    app = OUT / "RegressionHarness.app"
    app.mkdir(exist_ok=True)
    compile_args = ["xcrun", "swiftc", "-swift-version", "5", "-parse-as-library", "-sdk", sdk,
                    "-target", f"{arch}-apple-ios26.0-simulator", str(source), "-o", str(app / "RegressionHarness")]
    with (OUT / "compile.log").open("w") as log:
        command(compile_args, stdout=log, stderr=subprocess.STDOUT)
    info = {"CFBundleIdentifier": BUNDLE, "CFBundleName": "GoldenNugget Tests",
            "CFBundleExecutable": "RegressionHarness", "CFBundlePackageType": "APPL",
            "CFBundleVersion": "1", "CFBundleShortVersionString": "1.0",
            "MinimumOSVersion": "26.0", "LSRequiresIPhoneOS": True,
            "UIDeviceFamily": [1, 2], "UILaunchScreen": {}}
    (app / "Info.plist").write_bytes(plistlib.dumps(info))
    command(["codesign", "--force", "--sign", "-", str(app)])
    command(["xcrun", "simctl", "install", device, str(app)])
    raw = subprocess.check_output(["xcrun", "simctl", "get_app_container", device, BUNDLE, "data"], text=True)
    container = Path(next(line for line in raw.splitlines() if line.startswith("/")))
    result = container / "Documents" / "regression-results.json"
    result.unlink(missing_ok=True)
    command(["xcrun", "simctl", "launch", "--terminate-running-process", device, BUNDLE])
    deadline = time.monotonic() + 90
    while not result.exists() and time.monotonic() < deadline:
        time.sleep(0.5)
    if not result.exists():
        raise RuntimeError(f"Simulator did not produce a result; inspect {OUT / 'compile.log'} and simulator crash logs")
    report = json.loads(result.read_text())
    (OUT / "results.json").write_text(json.dumps(report, indent=2, ensure_ascii=False))
    print(json.dumps(report, indent=2, ensure_ascii=False))
    command(["xcrun", "simctl", "io", device, "screenshot", str(OUT / "screenshot.png")])
    return 1 if report["failures"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
