#!/usr/bin/env python3
"""Run the shipping AirLift finder, identity rewriting and apply against fixtures.

Optional arguments are .tendies archives to check in addition to synthetic cases.
No device or network is needed.
"""
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
source = (ROOT / "Nugget/Core/PosterBoardAirlift.swift").read_text()
source = source.replace("import ZIPFoundation\n", "")
source = source.replace('"PosterBoardAirliftContainer"', '"PosterBoardAirliftHarnessContainer"')
shared = (ROOT / "Nugget/Core/PosterBoard.swift").read_text().split("enum PosterBoardPlist {", 1)[1]
harness = (ROOT / "scripts/descriptor-finder-check.swift").read_text()
harness = harness.replace('"PosterBoardAirliftContainer"', '"PosterBoardAirliftHarnessContainer"')
with tempfile.TemporaryDirectory(prefix="posterboard-airlift-") as work:
    main = Path(work) / "main.swift"
    binary = Path(work) / "check"
    main.write_text(source + "\nenum PosterBoardPlist {" + shared + "\n" + harness)
    subprocess.run(["xcrun", "swiftc", "-swift-version", "5", str(main), "-o", str(binary)], check=True)
    subprocess.run([str(binary), *sys.argv[1:]], check=True)
