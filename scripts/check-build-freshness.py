#!/usr/bin/env python3
"""A failed build must not publish a previous IPA as the current result.

Run the shipping script in an isolated temporary project, with xcodebuild
replaced by a controlled failure. No real build product is moved or deleted.
"""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent

with tempfile.TemporaryDirectory(prefix="goldennugget-freshness-") as folder:
    root = Path(folder)
    (root / "scripts").mkdir()
    (root / "bin").mkdir()
    (root / "build").mkdir()
    script = root / "scripts/build-ipa.sh"
    shutil.copy2(ROOT / "scripts/build-ipa.sh", script)
    fake = root / "bin/xcodebuild"
    fake.write_text("#!/bin/sh\nexit 42\n")
    fake.chmod(0o755)
    ipa = root / "build/GoldenNuggetMobile.ipa"
    ipa.write_bytes(b"previous successful IPA")
    env = {**os.environ, "PATH": str(root / "bin") + ":" + os.environ["PATH"]}
    result = subprocess.run(["/bin/zsh", str(script), "Release"], env=env, capture_output=True, text=True)
    assert result.returncode == 42, result.stdout + result.stderr
    assert not ipa.exists(), "Failed build still advertises the old IPA"
    historical = list((root / "build/previous").glob("*.ipa"))
    assert len(historical) == 1 and historical[0].read_bytes() == b"previous successful IPA"
    print("PASS: failed build has no current IPA; previous success is preserved separately")
