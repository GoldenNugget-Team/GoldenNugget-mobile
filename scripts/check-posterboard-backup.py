#!/usr/bin/env python3
"""Exercise Protective PosterBoard consolidation and stitching with real SQLite."""
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
backup = (ROOT / "Nugget/Core/PosterBoardBackup.swift").read_text()
# Compile the actual consolidation methods; the mobilebackup2 fetch needs iOS.
consolidation = backup.split("    // MARK: - Consolidation\n", 1)[1]
consolidation = consolidation.split("/// What the targeted backup offered", 1)[0]
source = (ROOT / "Nugget/Core/PosterBoardStore.swift").read_text()
source += "\nenum PosterBoardBackup {\n" + consolidation
source += (ROOT / "scripts/posterboard-backup-check.swift").read_text()
with tempfile.TemporaryDirectory(prefix="posterboard-backup-") as work:
    main = Path(work) / "main.swift"
    binary = Path(work) / "check"
    main.write_text(source)
    subprocess.run(["xcrun", "swiftc", "-swift-version", "5", str(main), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
