#!/usr/bin/env python3
"""Check live-container scoping and preservation of streamed snapshot files."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
source = (ROOT / "Nugget/Core/PosterBoardSnapshot.swift").read_text()
support = (ROOT / "scripts/posterboard-identity-check.swift").read_text()
support = support.split("struct TweakPayload", 1)[1].split("enum PosterBoardResources", 1)[0]
# Only the common payload and error definitions are needed.
support = "struct TweakPayload" + support.split("enum PosterBoardTendie", 1)[0]
support = support[:support.index("struct PosterBoardTendie")] if "struct PosterBoardTendie" in support else support
harness = r'''
enum PosterBoard {
    static let domain = "AppDomain-com.apple.PosterBoard"
    static let storeDirectoryName = "PRBPosterExtensionDataStore"
    static let databaseFileName = "PBFPosterExtensionDataStoreSQLiteDatabase.sqlite3"
}
let container = "/private/var/mobile/Containers/Data/Application/LIVE"
let relative = "Library/Application Support/PRBPosterExtensionDataStore/61/" + PosterBoard.databaseFileName
var checks = 0
func check(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }
for prefix in ["AppDomain-com.apple.PosterBoard", container,
               "/.b/6/Containers/Data/Application/LIVE", "/b/1/Containers/Data/Application/LIVE"] {
    check(PosterBoardSnapshot.relativePath(deviceName: prefix + "/" + relative, container: container) == relative,
          "known live path: \(prefix)")
}
for path in ["AppDomain-other/" + relative,
             "/.b/6/Containers/Data/Application/OTHER/" + relative,
             "/.b/6/Containers/Data/Application/LIVE-COPY/" + relative,
             "/.b/6/Containers/Data/Application/OTHER/Documents/PosterBoard/Work/" + relative,
             container + "/../" + relative] {
    check(PosterBoardSnapshot.relativePath(deviceName: path, container: container) == nil, "reject foreign/traversal path")
}
check(PosterBoardSnapshot.storeVersion(relativePath: relative) == 61, "current store layout identified")
check(!PosterBoardSnapshot.isStoreFile(relativePath: "Backups/" + relative), "cached database not used as live store")
check(PosterBoardSnapshot.isStoreFile(relativePath: relative + "-wal"), "matching WAL kept")
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("pb-preserve-\(UUID().uuidString)")
defer { try? fm.removeItem(at: root) }
let id = String(repeating: "a", count: 40)
let file = root.appendingPathComponent("device/aa/" + id)
try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
try Data("existing collection bytes".utf8).write(to: file)
let payloads = try PosterBoardSnapshot.payloads(offers: ["Library/existing.bin": "device/Snapshot/aa/" + id], backupRoot: root, udid: "device")
let bytes = try payloads[0].bytes()
check(payloads.count == 1 && bytes == Data("existing collection bytes".utf8), "existing file bytes carried forward")
try fm.removeItem(at: file)
do {
    _ = try PosterBoardSnapshot.payloads(offers: ["Library/existing.bin": "device/Snapshot/aa/" + id], backupRoot: root, udid: "device")
    check(false, "missing snapshot must fail")
} catch { check(true, "incomplete snapshot stops restore") }
print("\(checks) PosterBoard snapshot preservation checks passed")
'''
with tempfile.TemporaryDirectory(prefix="posterboard-preservation-") as work:
    main = Path(work) / "main.swift"
    binary = Path(work) / "check"
    main.write_text(source + support + harness)
    subprocess.run(["xcrun", "swiftc", "-warnings-as-errors", str(main), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
