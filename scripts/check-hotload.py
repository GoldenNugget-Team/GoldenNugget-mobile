#!/usr/bin/env python3
"""Compile production HotLoad/update services and exercise isolated HTTP/cache fixtures."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
SOURCES = ["TweakModel", "TweakCatalog", "TweakCatalogDaemons", "TweakDomainMap", "TweakCompiler",
           "GoldenNuggetPreset", "HotLoadRules", "AppRelease", "StartupServices"]

with tempfile.TemporaryDirectory(prefix="goldennugget-hotload-") as temporary:
    binary = Path(temporary) / "check"
    subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-parse-as-library",
                    *[str(ROOT / "Nugget/Core" / f"{name}.swift") for name in SOURCES],
                    str(ROOT / "scripts/hotload-check.swift"), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
