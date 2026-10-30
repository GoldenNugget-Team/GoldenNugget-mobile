#!/usr/bin/env python3
"""Keep the launch-time log privacy pass bounded.

`GoldenNuggetEngine.enableRustFileLogging()` runs `PairingLogPrivacy` over
`minimuxer.log` before the Rust sink is installed, and it runs from the first
view body — i.e. on the main thread, inside launch. A Rust generation is capped
at 64 MB, so the pass has to read up to 128 MB of protocol log at launch.

On 2026-10-29 the app was killed by the scene-create watchdog on every launch:

    __chkstk_darwin
    ClosedRange<>.Index.== infix
    IndexingIterator.next()
    Array<A>.contains(sequence:)
    PairingLogPrivacy.scan(_:)
    PairingLogPrivacy.removeLegacyDumps(at:limit:)
    GoldenNuggetEngine.enableRustFileLogging()
    GoldenNuggetView.body.getter

19.96 s of wall clock for a 54 MB `minimuxer.log`, so the shell never appeared.
The scan is bounded in memory but not in time, and a Debug build (which is what
runs from Xcode) multiplies the constant.

This harness compiles the production type out of `Logging.swift` and asserts the
pass stays fast at the sizes the Rust cap permits, while still finding a secret
that sits at the very end of the file or across a 1 MB read boundary.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
source = (ROOT / "Nugget/Core/Logging.swift").read_text().splitlines()

# The declaration that makes up the pass, taken verbatim. (The byte-array
# substring helper it used to carry is gone; the search is Foundation's now.)
def block(start_marker, required=True):
    for i, line in enumerate(source):
        if line.startswith(start_marker):
            out = [line]
            for line in source[i + 1:]:
                out.append(line)
                if line == "}":
                    return "\n".join(out)
    if required:
        raise SystemExit(f"declaration not found: {start_marker}")
    return ""

privacy = block("enum PairingLogPrivacy {")
extension = block("private extension Array where Element == UInt8 {", required=False)

harness = r'''
import Foundation

''' + privacy + "\n\n" + extension + r'''

let fm = FileManager.default
let work = URL(fileURLWithPath: CommandLine.arguments[1])

/// A record shaped like the Rust log: timestamps, hex payloads and quoted keys.
func record(_ n: Int) -> String {
    let line = "2026-10-29T20:14:14.042 [D]: [IdeviceGateway] step \(n) — "
        + "device=/.b/6/Containers/Data/App/EFA677D9 file=00008120-0006155436F0E01E"
        + " keys: alt_irk, identifier, public_key\n"
    return line
}

func makeLog(at url: URL, megabytes: Int, secretAtTail: Bool) throws {
    var data = Data()
    data.reserveCapacity(megabytes << 20)
    var n = 0
    while data.count < (megabytes << 20) - 4096 {
        data.append(contentsOf: record(n).utf8)
        n += 1
    }
    let padding = (megabytes << 20) - data.count
    data.append(contentsOf: String(repeating: "x", count: max(0, padding - 40)).utf8)
    if secretAtTail {
        // Straddles nothing: the caller places it flush against the end so the
        // match ends on the final byte of the file.
        data.append(contentsOf: "{\"private_key\"}".utf8)
    } else {
        data.append(contentsOf: "\n".utf8)
    }
    try data.write(to: url)
}

func time(_ body: () -> Void) -> Double {
    let start = Date()
    body()
    return Date().timeIntervalSince(start)
}

var failures = 0
func check(_ ok: Bool, _ message: String) {
    if ok { print("PASS: \(message)") } else { failures += 1; print("FAIL: \(message)") }
}

// 1. The size the Rust cap actually permits, with nothing to find: this is the
//    launch that used to run out its 20 s scene-create allowance.
for megabytes in [54, 128] {
    let url = work.appendingPathComponent("clean-\(megabytes).log")
    try makeLog(at: url, megabytes: megabytes, secretAtTail: false)
    var reclaim: PairingLogPrivacy.Reclaim?
    let seconds = time { reclaim = PairingLogPrivacy.removeLegacyDumps(at: [url]) }
    check(reclaim?.isEmpty == true, "\(megabytes) MB clean log is left alone")
    check(seconds < 2.0, "\(megabytes) MB clean log scanned in \(String(format: "%.2f", seconds))s (< 2s)")
}

// 2. The pass must still do its job: a dump at the very end of a big file, and
//    one that begins in the last bytes of a 1 MB chunk so the carry is load
//    bearing.
for (label, tail) in [("end of file", "{\"private_key\"}"),
                      ("chunk boundary", String(repeating: "y", count: (1 << 20) - 6) + "{\"alt_irk\"}" + String(repeating: "z", count: 8))] {
    let url = work.appendingPathComponent("secret-\(label.replacingOccurrences(of: " ", with: "-")).log")
    try makeLog(at: url, megabytes: 3, secretAtTail: false)
    let handle = try FileHandle(forUpdating: url)
    try handle.seek(toOffset: handle.seekToEnd())
    try handle.write(contentsOf: Data(tail.utf8))
    try handle.close()
    var reclaim: PairingLogPrivacy.Reclaim?
    let seconds = time { reclaim = PairingLogPrivacy.removeLegacyDumps(at: [url]) }
    check(reclaim?.files == [url.lastPathComponent], "secret at \(label) is found")
    check(seconds < 2.0, "secret at \(label) found in \(String(format: "%.2f", seconds))s")
    let after = (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    check(after.contains("removed because it contained pairing secrets"),
          "the file is replaced with the notice at \(label)")
}

// 3. The key *names* a healthy build logs must not wipe the log.
let benign = work.appendingPathComponent("benign.log")
try Data("pairing record: Documents/pairingfile.mobiledevicepairing (keys: alt_irk, identifier, private_key, public_key)\n".utf8)
    .write(to: benign)
let reclaim = PairingLogPrivacy.removeLegacyDumps(at: [benign])
check(reclaim.isEmpty, "the current build's bare key list is not a secret dump")
check(fm.fileExists(atPath: benign.path), "benign log survives")

exit(failures == 0 ? 0 : 1)
'''

with tempfile.TemporaryDirectory(prefix="log-privacy-") as work:
    harness_path = Path(work) / "check.swift"
    harness_path.write_text(harness)
    binary = Path(work) / "check"
    build = subprocess.run(["swiftc", "-O", str(harness_path), "-o", str(binary)],
                           capture_output=True, text=True)
    if build.returncode != 0:
        print(build.stderr)
        raise SystemExit("harness did not compile")

    # Debug, exactly like the build that was killed by the watchdog: the harness
    # above is optimised so the threshold measures the algorithm, and the run
    # below is the same code at -Onone where the user's launch died.
    debug_binary = Path(work) / "check-debug"
    debug_build = subprocess.run(["swiftc", str(harness_path), "-o", str(debug_binary)],
                                 capture_output=True, text=True)
    if debug_build.returncode != 0:
        print(debug_build.stderr)
        raise SystemExit("debug harness did not compile")

    print("— optimised build")
    run = subprocess.run([str(binary), work], capture_output=True, text=True)
    print(run.stdout, end="")
    if run.returncode != 0:
        raise SystemExit("optimised scan failed")

    print("— debug build (the one that was killed at launch)")
    run = subprocess.run([str(debug_binary), work], capture_output=True, text=True, timeout=600)
    print(run.stdout, end="")
    if run.returncode != 0:
        raise SystemExit("debug scan failed")
