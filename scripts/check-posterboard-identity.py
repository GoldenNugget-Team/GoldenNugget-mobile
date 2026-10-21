#!/usr/bin/env python3
"""Run the shipping Protective descriptor builder, optionally on an extracted pack."""
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
source = (ROOT / "Nugget/Core/PosterBoard.swift").read_text()
source += (ROOT / "scripts/posterboard-identity-check.swift").read_text()
# compile() names TemplateFile, but this harness exercises only the real disk
# walker. Actual template extraction is covered by check-template-safety.py.
source += """
struct TemplateFile {
    let url: URL
    var title: String { url.lastPathComponent }
    var summary: String { title }
    func extract(to destination: URL) throws {}
}
"""
with tempfile.TemporaryDirectory(prefix="posterboard-identity-") as work:
    main = Path(work) / "main.swift"
    binary = Path(work) / "check"
    main.write_text(source)
    subprocess.run(["xcrun", "swiftc", "-warnings-as-errors", str(main), "-o", str(binary)], check=True)
    subprocess.run([str(binary), *sys.argv[1:]], check=True)
