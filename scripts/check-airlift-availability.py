#!/usr/bin/env python3
"""Exercise the shipping AirLift version/build gate and saved mode fallback."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
availability = (ROOT / "Nugget/Core/AirliftAvailability.swift").read_text()
modes = (ROOT / "Nugget/Core/PosterBoardApplyMode.swift").read_text().replace(
    '"PosterBoardApplyMode"', '"AirliftAvailabilityHarnessMode"')
airlift = (ROOT / "Nugget/Core/Airlift.swift").read_text()
gate = airlift.split("    // MARK: - Availability", 1)[1].split(
    "    /// Refuse unless", 1)[0]
model = (ROOT / "Nugget/Core/TweakModel.swift").read_text()
version = "enum TweakVersion {" + model.split("enum TweakVersion {", 1)[1].split(
    "\nextension TweakSpec", 1)[0]
harness = r'''
var checks = 0
func check(_ value: Bool, _ label: String) {
    precondition(value, label)
    checks += 1
}
for (version, build, supported) in [
    ("26.1", "", false), ("26.1.1", "", true), ("26.2", "", true),
    ("27.0", "", true), ("27.1", "", true),
    ("27.2", "24B5084k", true), ("27.2", "24B5089g", true),
    ("27.2.0", "24B5089g", true), ("27.2", "24B5099f", false),
    ("27.2", "24B5110a", false), ("27.2", "24B100", false),
    ("27.2", "", false), ("27.2", "unknown", false),
    ("27.2.1", "24B5089g", false), ("27.3", "24B5089g", false),
    ("28.0", "", false), ("", "", false), ("invalid", "", false)
] {
    check(Airlift.isSupported(deviceVersion: version, buildVersion: build) == supported,
          "support: \(version) \(build)")
    check(Airlift.unsupportedReason(deviceVersion: version, buildVersion: build).isEmpty == supported,
          "reason: \(version) \(build)")
}
let saved = UserDefaults.standard.object(forKey: PosterBoardApplyModeSettings.key)
defer {
    if let saved { UserDefaults.standard.set(saved, forKey: PosterBoardApplyModeSettings.key) }
    else { UserDefaults.standard.removeObject(forKey: PosterBoardApplyModeSettings.key) }
}
PosterBoardApplyModeSettings.current = .airlift
check(PosterBoardApplyModeSettings.resolved(deviceVersion: "27.2", buildVersion: "24B5099f") == .backup,
      "saved AirLift falls back on beta 3")
check(PosterBoardApplyModeSettings.current == .airlift, "fallback preserves original preference")
check(PosterBoardApplyModeSettings.resolved(deviceVersion: "27.2", buildVersion: "24B5089g") == .airlift,
      "beta 2 retains AirLift")
PosterBoardApplyModeSettings.current = .backup
check(PosterBoardApplyModeSettings.resolved(deviceVersion: "27.1", buildVersion: "") == .backup,
      "explicit backup preserved")
print("\(checks) AirLift availability checks passed")
'''
with tempfile.TemporaryDirectory(prefix="airlift-availability-") as work:
    main = Path(work) / "main.swift"
    binary = Path(work) / "check"
    main.write_text(availability + modes + version + "\nenum Airlift {\n" + gate + "\n}\n" + harness)
    subprocess.run(["xcrun", "swiftc", "-warnings-as-errors", str(main), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
