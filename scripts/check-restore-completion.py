#!/usr/bin/env python3
"""Exercise the production restore verdict rule without a device restore."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
source = (root / 'Vendor/MinimuxerGateway/idevice/IdeviceGateway.swift').read_text()
rule = source.split('    static let restoreCompletionPercent:', 1)[1].split('    /// Last progress value', 1)[0]
rule = '    static let restoreCompletionPercent:' + rule
harness = '''
let cases: [(Int?, Double, Bool)] = [
    (0, 99, true), (0, 100, true), (0, -1, true),
    (nil, 99, false), (nil, 55, false), (nil, -1, false),
    (nil, 100, true), (205, 100, false), (-1, 100, false),
    (205, 99, false)
]
for (code, progress, expected) in cases {
    precondition(IdeviceGateway.restoreDidComplete(errorCode: code, lastPercent: progress) == expected)
}
print("PASS: 10 restore completion cases, including device success at 99% and incomplete/failed responses")
'''
with tempfile.TemporaryDirectory(prefix='gn-restore-completion-') as directory:
    directory = Path(directory)
    main = directory / 'main.swift'
    main.write_text('enum IdeviceGateway {\n' + rule + '\n}\n' + harness)
    binary = directory / 'check'
    subprocess.run(['xcrun', 'swiftc', '-warnings-as-errors', str(main), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
