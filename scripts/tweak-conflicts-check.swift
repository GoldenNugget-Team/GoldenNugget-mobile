// Regression harness for conflict detection.
//
// Ports the conflict cases of GoldenNugget's `tools/test_conflicts_and_presets.py`
// onto this port's `TweakConflicts.find`, without a device and without Qt: the
// reference hands `find_conflicts` hand-built tweak objects, so this harness
// hands it hand-built `TweakSpec`s that reproduce the same pairs.
//
//   1  SAME KEY      two enabled writers of the same key with different values
//                    conflict; identical values do not.
//   2  BOOL/INT      a plist bool and the integer `1` are different plist
//                    values (`<boolean>` vs `<integer>` in plistlib), so they
//                    conflict even though `Swift ==` (bridged) would not.
//   3  RTL/LTR       both forced layout directions enabled with truthy values
//                    conflict via the independent rule; a falsy one does not.
//   4  COMPANION     a companion writer's extra key still conflicts when the
//                    later basic writer sets that key differently.
//   5  REPLACEMENT   a whole-dict writer after a basic writer replaces the
//                    basic one's settings; the reverse order does not.
//   6  CLEAR FILE    a nullified file conflicts with a writer of the same file.
//   7  GATING        disabled and incompatible specs never conflict, and an
//                    off spec contributes nothing.
//
// Run:
//   mkdir -p /tmp/conflictcheck && cat Nugget/Core/TweakModel.swift \
//       Nugget/Core/TweakCatalog.swift Nugget/Core/TweakCatalogDaemons.swift \
//       Nugget/Core/TweakConflicts.swift scripts/tweak-conflicts-check.swift \
//       > /tmp/conflictcheck/main.swift \
//     && xcrun swiftc -O /tmp/conflictcheck/main.swift -o /tmp/conflictcheck/check \
//     && /tmp/conflictcheck/check
//
// This file is NOT part of the app target; keep it out of Package.swift.

import Foundation

var failures: [String] = []
func check(_ condition: Bool, _ label: String) {
    if !condition { failures.append(label) }
}
func fail(_ label: String) { failures.append(label) }

// A bare plist-writer spec, the Swift shape of the reference's
// `BasicPlistTweak(FileLocation, key, value)` constructor call.
func basic(_ id: String,
           location: TweakFileLocation,
           key: String,
           value: TweakValue,
           multiValues: [String: TweakValue]? = nil,
           minVersion: String? = nil,
           disabled: Bool = false) -> TweakSpec {
    TweakSpec(id: id,
              section: .daemons,
              title: "Test \(id)",
              location: location,
              key: key,
              value: value,
              kind: .toggle,
              minValue: 0.0,
              maxValue: 999.0,
              step: 1.0,
              minVersion: minVersion,
              maxVersion: nil,
              iphoneOnly: false,
              ipadOnly: false,
              disabled: disabled,
              detail: nil,
              multiValues: multiValues)
}

// 1 — same key, different values.
do {
    let first = basic("A", location: .springboard, key: "Key", value: .bool(true))
    let second = basic("B", location: .springboard, key: "Key", value: .bool(false))
    var selection = TweakSelection()
    selection.setOn(true, for: first)
    selection.setOn(true, for: second)
    check(TweakConflicts.find(in: selection, specs: [first, second], deviceVersion: "27.0", isIPhone: true).count == 1,
          "same key different values conflicts")
    selection.setOn(false, for: second)
    check(TweakConflicts.find(in: selection, specs: [first, second], deviceVersion: "27.0", isIPhone: true).isEmpty,
          "disabled writer does not conflict")
}

// 2 — plist bool vs integer 1 are distinct values.
do {
    let first = basic("A", location: .springboard, key: "Key", value: .bool(true))
    let second = basic("B", location: .springboard, key: "Key", value: .int(1))
    var selection = TweakSelection()
    selection.setOn(true, for: first)
    selection.setOn(true, for: second)
    check(TweakConflicts.find(in: selection, specs: [first, second], deviceVersion: "27.0", isIPhone: true).count == 1,
          "bool and integer 1 conflict")
    let equal = basic("A", location: .springboard, key: "Key", value: .int(1))
    var same = TweakSelection()
    same.setOn(true, for: equal)
    same.setOn(true, for: second)
    check(TweakConflicts.find(in: same, specs: [equal, second], deviceVersion: "27.0", isIPhone: true).isEmpty,
          "equal int values do not conflict")
}

// 3 — the real RTL/LTR rule, on the registry specs.
do {
    let rtl = TweakCatalog.byID["RTL"]!
    let ltr = TweakCatalog.byID["LTR"]!
    var selection = TweakSelection()
    selection.setOn(true, for: rtl)
    selection.setOn(true, for: ltr)
    check(TweakConflicts.current(in: selection, deviceVersion: "27.0", isIPhone: true).count == 1,
          "RTL + LTR both truthy conflict")
    selection.setValue(.bool(false), for: ltr)
    check(TweakConflicts.current(in: selection, deviceVersion: "27.0", isIPhone: true).isEmpty,
          "RTL + falsy LTR do not conflict")
}

// 4 — companion writer vs a later basic writer of the companion key.
do {
    let first = basic("A", location: .springboard, key: "First",
                      value: .bool(true),
                      multiValues: ["First": .bool(true), "Second": .bool(true)])
    let second = basic("B", location: .springboard, key: "Second", value: .bool(false))
    var selection = TweakSelection()
    selection.setOn(true, for: first)
    selection.setOn(true, for: second)
    check(TweakConflicts.find(in: selection, specs: [first, second], deviceVersion: "27.0", isIPhone: true).count == 1,
          "companion key set differently conflicts")
}

// 5 — whole-dict replacement order.
do {
    let basicW = basic("A", location: .springboard, key: "Key", value: .bool(true))
    let whole = basic("B", location: .springboard, key: "Other",
                      value: .bool(true),
                      multiValues: ["Other": .bool(true)])
    var forward = TweakSelection()
    forward.setOn(true, for: basicW)
    forward.setOn(true, for: whole)
    check(TweakConflicts.find(in: forward, specs: [basicW, whole], deviceVersion: "27.0", isIPhone: true).count == 1,
          "whole-dict writer after a basic writer replaces its settings")
    var reverse = TweakSelection()
    reverse.setOn(true, for: whole)
    reverse.setOn(true, for: basicW)
    check(TweakConflicts.find(in: reverse, specs: [whole, basicW], deviceVersion: "27.0", isIPhone: true).isEmpty,
          "basic writer after a whole-dict writer does not replace")
}

// 6 — a nullified file vs a writer of the same file.
do {
    let writer = basic("A", location: .screentime, key: "Key", value: .bool(true))
    var selection = TweakSelection()
    selection.setOn(true, for: writer)
    selection.setOn(true, for: TweakCatalog.screenTimeSpec)
    check(TweakConflicts.find(in: selection, specs: [writer, TweakCatalog.screenTimeSpec], deviceVersion: "27.0", isIPhone: true).count == 1,
          "nullified file conflicts with a writer of the same file")
}

// 7 — gating: disabled specs and incompatible specs contribute nothing.
do {
    let disabled = basic("D", location: .springboard, key: "Key", value: .bool(true), disabled: true)
    let incompatible = basic("I", location: .springboard, key: "Key", value: .bool(false), minVersion: "28.0")
    let writer = basic("A", location: .springboard, key: "Key", value: .bool(false))
    var selection = TweakSelection()
    selection.setOn(true, for: disabled)
    selection.setOn(true, for: incompatible)
    selection.setOn(true, for: writer)
    check(TweakConflicts.find(in: selection, specs: [disabled, incompatible, writer], deviceVersion: "27.0", isIPhone: true).isEmpty,
          "disabled and incompatible specs are filtered out")
}

if failures.isEmpty {
    print("tweak-conflicts: ALL OK")
} else {
    print("tweak-conflicts: \(failures.count) FAIL")
    for item in failures { print("  - \(item)") }
    exit(1)
}
