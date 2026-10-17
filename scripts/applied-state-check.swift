// Regression harness for the applied-state bookkeeping: the preset store, the
// apply/reset history, the progress ETA, and the shared preset-v2 serializer.
//
// Ports the storage half of GoldenNugget's `test_conflicts_and_presets.py` and
// `tools/test_apply_history.py` onto this port's on-device stores, without a
// device and without Qt.  The stores default to the app's Documents folder, so
// the harness points them at a temp directory first and the serialiser is
// exercised through `GoldenNuggetPreset.parse` (a full file round trip).
//
//   1  SANITIZE    `_sanitize_name` keeps alphanumerics/space/_/-, trims, and
//                  falls back to "Preset".
//   2  ROUNDTRIP   save → load parses back with the same enabled set, and the
//                  serializer's document survives `GoldenNuggetPreset.parse`
//                  with every catalog spec (minus PosterBoard) present.
//   3  METADATA    re-saving an existing preset keeps `created_at` and moves
//                  `updated_at`; list/metadata read back what was written.
//   4  HISTORY     record → load order, the 30-entry bound, and clear.
//   5  IMPORT      validation rejects malformed containers; a duplicate name
//                  gets a " (n)" suffix; a description-less file falls back to
//                  its base name.
//   6  DAEMONS     `preset_has_daemon_changes` recognises both the desktop's
//                  consolidated "Daemons" entry and this port's "Daemon.*" rows.
//   7  ROLLBACK    `saveLastApplied` → `prepareRollback` leaves a loadable
//                  `__Rollback` snapshot; none exists before any apply.
//   8  ETA         format edge cases and the window/phase/drop logic, with
//                  synthetic times so nothing sleeps.
//
// Run:
//   mkdir -p /tmp/appliedstate && cat Nugget/Core/TweakModel.swift \
//       Nugget/Core/TweakCatalog.swift Nugget/Core/TweakCatalogDaemons.swift \
//       Nugget/Core/GoldenNuggetPreset.swift Nugget/Core/GoldenNuggetAutosave.swift \
//       Nugget/Core/GoldenNuggetPresets.swift Nugget/Core/ApplyHistory.swift \
//       Nugget/Core/ProgressEta.swift scripts/applied-state-check.swift \
//       > /tmp/appliedstate/main.swift \
//     && xcrun swiftc -O /tmp/appliedstate/main.swift -o /tmp/appliedstate/check \
//     && /tmp/appliedstate/check
//
// This file is NOT part of the app target; keep it out of Package.swift.

import Foundation

// `GoldenNuggetAutosave.restore(into:identity:)` names `DeviceIdentity`; the
// app's real one imports Minimuxer and is not host-compilable, so the harness
// carries the minimal shape the autosave touches.
struct DeviceIdentity {
    var productType: String
    var version: String
    var isIPhone: Bool
}

// `GoldenNuggetPreset.parse` throws `GoldenNuggetError`, which lives in the
// engine file (Minimuxer-heavy); the harness carries its shape.
struct GoldenNuggetError: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

var failures: [String] = []
func check(_ condition: Bool, _ label: String) {
    if !condition { failures.append(label) }
}

let temp = FileManager.default.temporaryDirectory
    .appendingPathComponent("appliedstate-\(UUID().uuidString)", isDirectory: true)
try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
ApplyHistory.fileURLOverride = temp.appendingPathComponent("History/operations.json")
GoldenNuggetPresets.directoryOverride = temp.appendingPathComponent("Presets")

// A selection with one basic tweak, one whole-dict tweak and one daemon group on.
func sampleSelection() -> TweakSelection {
    var selection = TweakSelection()
    selection.setOn(true, for: TweakCatalog.byID["SolariumIgnoreSystemPrefersReduceTransparency"]
        ?? TweakCatalog.all[0])
    selection.setOn(true, for: TweakCatalog.allWithDaemons.first { $0.writesWholeDict && $0.id != "PosterBoard" }!)
    selection.setOn(true, for: TweakCatalog.allWithDaemons.first { $0.id.hasPrefix("Daemon.") }!)
    return selection
}

let docSelection: TweakSelection = {
    var s = TweakSelection()
    s.setOn(true, for: TweakCatalog.all[0])
    return s
}()

// 1 — sanitize.
check(GoldenNuggetPresets.sanitize("My Preset!") == "My Preset", "sanitize drops punctuation")
check(GoldenNuggetPresets.sanitize("   ") == "Preset", "sanitize falls back to Preset")
check(GoldenNuggetPresets.sanitize("A-B_c 123") == "A-B_c 123", "sanitize keeps - _ and digits")
check(GoldenNuggetPresets.sanitize("Base (2)") == "Base 2", "sanitize drops parentheses")

// 2/3 — save/load roundtrip, metadata and updated_at/created_at behaviour.
do {
    let selection = sampleSelection()
    check(GoldenNuggetPresets.save("Shared", selection: selection,
                                   deviceModel: "iPhone16,1", iosVersion: "27.0",
                                   description: "Shared test", tags: ["test"]),
          "save preset succeeds")
    check(GoldenNuggetPresets.list() == ["Shared"], "list finds the saved preset")
    let meta = GoldenNuggetPresets.metadata(for: "Shared")
    check(meta?["description"] as? String == "Shared test", "metadata description round-trips")
    check(meta?["device_model"] as? String == "iPhone16,1", "metadata device_model round-trips")
    check(meta?["ios_version"] as? String == "27.0", "metadata ios_version round-trips")
    check((meta?["tags"] as? [String]) == ["test"], "metadata tags round-trip")
    let created = (meta?["created_at"] as? NSNumber)?.intValue ?? 0
    check(created > 0, "created_at is set")
    Thread.sleep(forTimeInterval: 1.1)
    _ = GoldenNuggetPresets.save("Shared", selection: selection,
                                 deviceModel: "iPhone16,1", iosVersion: "27.0",
                                 description: "Shared test", tags: ["test"])
    if let meta2 = GoldenNuggetPresets.metadata(for: "Shared") {
        check((meta2["created_at"] as? NSNumber)?.intValue == created, "re-save keeps created_at")
        check((meta2["updated_at"] as? NSNumber)?.intValue ?? 0 > created, "re-save moves updated_at")
    } else {
        check(false, "metadata reads after re-save")
    }

    if let preset = GoldenNuggetPresets.load("Shared") {
        check(preset.metadata.description == "Shared test", "parsed preset description")
        check(preset.entries.count > 0, "parsed preset has entries")
        for entry in preset.entries where entry.enabled {
            check(selection.isOn(TweakCatalog.byID[entry.id]!),
                  "round-trip enabled set matches (\(entry.id))")
        }
    } else {
        check(false, "preset loads and parses")
    }
}

// The shared serializer round-trips through `GoldenNuggetPreset.parse`.
do {
    let doc = GoldenNuggetPresets.document(for: docSelection,
                                           deviceModel: "iPhone", iosVersion: "26.0",
                                           description: "D", tags: [], createdAt: nil)
    let data = try JSONSerialization.data(withJSONObject: doc)
    let parsed = try GoldenNuggetPreset.parse(data)
    check(parsed.entries.count == TweakCatalog.allWithDaemons.count,
          "serializer emits every catalog spec (no PosterBoard spec exists to drop)")
    check(parsed.entries.first { $0.id == TweakCatalog.all[0].id }?.enabled == true,
          "enabled flag round-trips")
    check(parsed.entries.contains { $0.value != nil || !($0.multiValues ?? [:]).isEmpty },
          "values round-trip")
    check(doc["metadata"] != nil && doc["tweaks"] != nil, "document has tweaks and metadata")
} catch {
    check(false, "serializer round-trip throws: \(error.localizedDescription)")
}

// 4 — history.
do {
    for _ in 0..<5 {
        ApplyHistory.record(mode: "apply", success: true, device: "iPhone16,1", model: "iPhone", ios: "27.0")
    }
    let records = ApplyHistory.load()
    check(records.count == 5, "history keeps recorded entries")
    check(records.allSatisfy { $0.mode == "apply" && $0.success && $0.device == "iPhone16,1" },
          "history fields round-trip")
    for _ in 0..<30 { ApplyHistory.record(mode: "reset", success: false, error: "boom") }
    check(ApplyHistory.load().count == 30, "history is bounded to 30")
    check(ApplyHistory.load().first?.mode == "reset", "history keeps the newest first")
    ApplyHistory.clear()
    check(ApplyHistory.load().isEmpty, "clear removes history")
}

// 5 — import validation and unique naming.
do {
    let doc = GoldenNuggetPresets.document(for: docSelection, deviceModel: "D", iosVersion: "I",
                                           description: "Imported preset", tags: [], createdAt: nil)
    check(GoldenNuggetPresets.isValidImport(doc), "own document is a valid import")

    var badMeta = doc
    var meta = badMeta["metadata"] as! [String: Any]
    meta["description"] = 42
    badMeta["metadata"] = meta
    check(!GoldenNuggetPresets.isValidImport(badMeta), "non-string description rejected")

    var badTweaks = doc
    var tweaks = badTweaks["tweaks"] as! [String: Any]
    var entry = tweaks[TweakCatalog.all[0].id] as! [String: Any]
    entry["enabled"] = "yes"
    tweaks[TweakCatalog.all[0].id] = entry
    badTweaks["tweaks"] = tweaks
    check(!GoldenNuggetPresets.isValidImport(badTweaks), "non-bool enabled rejected")

    let emptyRoot: [String: Any] = ["tweaks": []]
    check(!GoldenNuggetPresets.isValidImport(emptyRoot), "non-dict tweaks rejected")

    var oldFile = doc
    oldFile.removeValue(forKey: "metadata")
    check(GoldenNuggetPresets.isValidImport(oldFile), "old file without metadata imports")

    let importFile = temp.appendingPathComponent("import.json")
    try? JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted])
        .write(to: importFile)
    let (ok1, name1) = GoldenNuggetPresets.importPreset(from: importFile, newName: nil)
    check(ok1 && name1 == "Imported preset", "import names itself from metadata.description")
    let (ok2, name2) = GoldenNuggetPresets.importPreset(from: importFile, newName: nil)
    check(ok2 && name2 == "Imported preset (1)", "duplicate import gets a unique name")
    check(GoldenNuggetPresets.list().contains("Imported preset 1"),
          "the duplicate lands under its sanitized file name")
    let (ok3, name3) = GoldenNuggetPresets.importPreset(from: importFile, newName: "  My new  ")
    check(ok3 && name3 == "My new", "explicit name is sanitized")
    check(GoldenNuggetPresets.exists("My new"), "imported preset exists on disk")
    let (ok4, err4) = GoldenNuggetPresets.importPreset(from: temp.appendingPathComponent("missing.json"),
                                                       newName: nil)
    check(!ok4 && !err4.isEmpty, "missing import file fails with a message")
}

// 6 — daemon-change detection, both preset shapes.
do {
    let doc = GoldenNuggetPresets.document(for: docSelection, deviceModel: "D", iosVersion: "I",
                                           description: "", tags: [], createdAt: nil)
    var desktop = doc
    var desktopTweaks = desktop["tweaks"] as! [String: Any]
    desktopTweaks["Daemons"] = ["type": "AdvancedPlistTweak", "enabled": true,
                                "value": ["com.apple.thermalmonitord": false]]
    desktop["tweaks"] = desktopTweaks
    check(GoldenNuggetPresets.presetHasDaemonChanges(desktop), "Daemons enabled is a daemon change")

    var groupOff = doc
    var groupTweaks = groupOff["tweaks"] as! [String: Any]
    groupTweaks["Daemon.Thermal"] = ["type": "AdvancedPlistTweak", "enabled": false,
                                     "value": ["com.apple.thermalmonitord": false]]
    groupOff["tweaks"] = groupTweaks
    check(!GoldenNuggetPresets.presetHasDaemonChanges(groupOff), "disabled daemon group is not a change")

    var groupOn = doc
    var onTweaks = groupOn["tweaks"] as! [String: Any]
    onTweaks["Daemon.Thermal"] = ["type": "AdvancedPlistTweak", "enabled": true,
                                  "value": ["com.apple.thermalmonitord": false]]
    groupOn["tweaks"] = onTweaks
    check(GoldenNuggetPresets.presetHasDaemonChanges(groupOn), "enabled daemon group is a change")

    var labelOn = doc
    var labelTweaks = labelOn["tweaks"] as! [String: Any]
    labelTweaks["Daemons"] = ["type": "AdvancedPlistTweak", "enabled": false,
                              "value": ["com.apple.thermalmonitord": true]]
    labelOn["tweaks"] = labelTweaks
    check(GoldenNuggetPresets.presetHasDaemonChanges(labelOn), "a truthy label is a daemon change")

    check(!GoldenNuggetPresets.presetHasDaemonChanges(doc), "plain tweaks are not a daemon change")
}

// 7 — rollback snapshot lifecycle.
do {
    check(!GoldenNuggetPresets.hasRollback, "no rollback before any apply")
    check(GoldenNuggetPresets.saveLastApplied(selection: sampleSelection(),
                                              deviceModel: "iPhone16,1", iosVersion: "27.0"),
          "saveLastApplied succeeds")
    GoldenNuggetPresets.prepareRollback()
    check(GoldenNuggetPresets.hasRollback, "prepareRollback leaves a snapshot")
    if let rolled = GoldenNuggetPresets.loadRollback(),
       let applied = GoldenNuggetPresets.load(GoldenNuggetPresets.lastAppliedName) {
        check(rolled.entries.count == applied.entries.count,
              "rollback mirrors the last applied snapshot")
    } else {
        check(false, "rollback snapshot loads")
    }
    check(GoldenNuggetPresets.isInternal(GoldenNuggetPresets.rollbackName), "rollback name is internal")
    check(!GoldenNuggetPresets.isInternal("Shared"), "user preset name is not internal")
}

// 8 — progress ETA, with synthetic time.
do {
    var eta = ProgressEta()
    check(eta.update(0, now: 100) == "", "zero progress never estimates")
    check(eta.update(100, now: 101) == "0:00", "completed progress is zero time")
    check(eta.update(50, now: 110) == "", "estimator stays quiet until minElapsed")
    // from t=110 (50%) to t=116 (60%): 10% over 6 s → remaining 40/1.667 = 24 s
    let a = eta.update(60, now: 116)
    check(a == "0:24", "window rate estimates remaining seconds (got \(a))")
    let b = eta.update(70, now: 126)
    check(b == "0:24", "sliding window follows the rate (got \(b))")
    // A drop restarts the measurement: nothing left to estimate.
    check(eta.update(65, now: 127) == "", "a dropped value resets the estimator")
    // format() edge cases.
    check(ProgressEta.format(nil) == "", "nil formats empty")
    check(ProgressEta.format(0) == "0:00", "zero formats zero")
    check(ProgressEta.format(59) == "0:59", "seconds format m:ss")
    check(ProgressEta.format(600) == "10:00", "minutes format m:ss")
    check(ProgressEta.format(3661) == "1:01:01", "hours format h:mm:ss")
}

try? FileManager.default.removeItem(at: temp)

if failures.isEmpty {
    print("applied-state: ALL OK")
} else {
    print("applied-state: \(failures.count) FAIL")
    for item in failures { print("  - \(item)") }
    exit(1)
}

