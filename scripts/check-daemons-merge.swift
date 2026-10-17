// Host check for the daemon compiler path: does a selection of daemon groups
// reach ONE launchd `disabled.plist` with the right labels, and does the
// ScreenTime nullify come out as a 0-byte payload?
//
// Compiled ad hoc against the same pure-Foundation sources as the tweak-port
// harness -- TweakModel / TweakCatalog / TweakCatalogDaemons / TweakDomainMap /
// TweakCompiler -- so it runs on Linux with no device and no UIKit.
//
//   swiftc -O -o /tmp/daemons-check \
//     scripts/check-daemons-merge.swift Nugget/Core/TweakModel.swift \
//     Nugget/Core/TweakCatalog.swift Nugget/Core/TweakCatalogDaemons.swift \
//     Nugget/Core/TweakDomainMap.swift Nugget/Core/TweakCompiler.swift
//   /tmp/daemons-check
//
// It exists because of the two defects this path had: the compiler assigned
// the whole plist per dict spec instead of merging (so only the last group
// survived), and a group switch set the on-flag without writing `true` into
// the labels, producing a file that disabled nothing.

import Foundation

var selection = TweakSelection()
for name in ["thermalmonitord", "OTA", "AppleAds", "VPN"] {
    guard let spec = TweakCatalog.byID["Daemon.\(name)"] else {
        print("  FAIL: нет спеки \(name)"); exit(1)
    }
    let group = DaemonGroups.byName[name]!
    let on = Dictionary(uniqueKeysWithValues: group.labels.map { ($0, TweakValue.bool(true)) })
    selection.restore(enabled: true, value: nil, multiValues: on, for: spec)
}

let result = TweakCompiler.compile(selection: selection, deviceVersion: "26.0", isIPhone: true)
var disabled: [String: String] = [:]
var labels: [String] = []
for payload in result.payloads where payload.label.contains("disabled") {
    let plist = (try? PropertyListSerialization.propertyList(from: payload.contents,
                                                             options: [], format: nil)) as? [String: Any] ?? [:]
    for (k, v) in plist { disabled[k] = "\(v)" }
    labels.append(payload.label)
}

var failures = 0
func check(_ label: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if ok { print("  ok   \(label)") }
    else { failures += 1; print("  FAIL \(label) — \(detail())") }
}

check("одна полезная нагрузка для launchd", labels.count == 1, "\(labels)")
let expected = DaemonGroups.byName["thermalmonitord"]!.labels
             + DaemonGroups.byName["OTA"]!.labels
             + DaemonGroups.byName["AppleAds"]!.labels
             + DaemonGroups.byName["VPN"]!.labels
check("все 4 группы попали в один plist (слияние, не перезапись)",
      Set(expected) == Set(disabled.keys),
      "ожидалось \(expected.count), в файле \(disabled.count); нет: \(Set(expected).subtracting(Set(disabled.keys)))")
check("все значения true", disabled.values.allSatisfy { $0 == "1" || $0 == "true" },
      "\(disabled.filter { $0.value != "1" && $0.value != "true" })")
check("метки вне INTERFACE_KEYS не появились",
      Set(disabled.keys).subtracting(expected).isEmpty)
// The ScreenTime nullify is a 0-byte payload, so it needs the row on.
var withNullify = selection
withNullify.setOn(true, for: TweakCatalog.screenTimeSpec)
let nullifyRun = TweakCompiler.compile(selection: withNullify, deviceVersion: "26.0", isIPhone: true)
let nullify = nullifyRun.payloads.first { $0.label.contains("ScreenTimeAgent") }
check("ScreenTime nullify — 0-байтовая нагрузка",
      nullify?.contents.isEmpty == true,
      "получено: \(nullify.map { "\($0.contents.count) B" } ?? "нет payload")")

var clear = TweakSelection()
let otaGroup = DaemonGroups.byName["OTA"]!
clear.restore(enabled: true, value: nil,
              multiValues: Dictionary(uniqueKeysWithValues: otaGroup.labels.map { ($0, TweakValue.bool(true)) }),
              for: TweakCatalog.byID["Daemon.OTA"]!)
let only = TweakCompiler.compile(selection: clear, deviceVersion: "26.0", isIPhone: true)
var onlyKeys = 0
for p in only.payloads where p.label.contains("disabled") {
    let plist = (try? PropertyListSerialization.propertyList(from: p.contents, options: [], format: nil)) as? [String: Any] ?? [:]
    onlyKeys = plist.count
}
check("одна группа = только её метки", onlyKeys == DaemonGroups.byName["OTA"]!.labels.count,
      "получено \(onlyKeys)")

print(failures == 0 ? "\n  все проверки прошли" : "\n  \(failures) проверок упало")
exit(failures == 0 ? 0 : 1)
