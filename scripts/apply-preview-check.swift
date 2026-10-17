// Regression harness for the pre-apply write plan.
//
// `ApplyPreview` compiles the current selection exactly as the engine will and
// reports the pending writes, their sizes, and the conflict/time/storage
// estimates the desktop shows before confirming.  Without a device, this
// checks that the plan aggregates the same payloads the apply would deliver:
//
//   1  EMPTY       an untouched selection plans zero files and zero bytes.
//   2  TWEAKS      the rows are exactly the compiled payloads, with sizes that
//                  sum to `totalBytes`.
//   3  STATUS BAR  an enabled status bar adds its one payload row (the classic
//                  struct below iOS 27, the archive on 27+).
//   4  SKIP SETUP  an enabled skip setup adds its payload rows ahead of the
//                  tweaks.
//   5  CONFLICTS   RTL + LTR both on reports exactly one conflict.
//   6  ESTIMATES   the time estimate is `120 + n*8` seconds rounded up to a
//                  minute; the storage line reads the volume without crashing.
//
// Run:
//   mkdir -p /tmp/previewcheck && cat Nugget/Core/TweakModel.swift \
//       Nugget/Core/TweakCatalog.swift Nugget/Core/TweakCatalogDaemons.swift \
//       Nugget/Core/TweakDomainMap.swift Nugget/Core/TweakCompiler.swift \
//       Nugget/Core/StatusBarModel.swift Nugget/Core/StatusBarArchive.swift \
//       Nugget/Core/StatusBarSelection.swift Nugget/Core/SkipSetup.swift \
//       Nugget/Core/TweakConflicts.swift Nugget/Core/ApplyPreview.swift \
//       scripts/apply-preview-check.swift > /tmp/previewcheck/main.swift \
//     && xcrun swiftc -O /tmp/previewcheck/main.swift -o /tmp/previewcheck/check \
//     && /tmp/previewcheck/check
//
// This file is NOT part of the app target; keep it out of Package.swift.

import Foundation

var failures: [String] = []
func check(_ condition: Bool, _ label: String) {
    if !condition { failures.append(label) }
}

// 1 — an untouched selection plans nothing.
do {
    let preview = try ApplyPreview.build(selection: TweakSelection(),
                                         statusBar: StatusBarSelection(),
                                         skipSetupEnabled: false,
                                         deviceVersion: "27.0", isIPhone: true)
    check(preview.rows.isEmpty, "empty selection plans zero files")
    check(preview.totalBytes == 0, "empty selection plans zero bytes")
    check(preview.selectedCount == 0, "empty selection counts zero")
    check(preview.conflicts.isEmpty, "empty selection has no conflicts")
    check(preview.notes.isEmpty, "empty selection has no notes")
}

// 2 — the plan is the compiled payload list.
do {
    var selection = TweakSelection()
    for spec in TweakCatalog.all.prefix(3) {
        selection.setOn(true, for: spec)
    }
    let preview = try ApplyPreview.build(selection: selection,
                                         statusBar: StatusBarSelection(),
                                         skipSetupEnabled: false,
                                         deviceVersion: "27.0", isIPhone: true)
    let compiled = TweakCompiler.compile(selection: selection,
                                         deviceVersion: "27.0", isIPhone: true)
    check(!preview.rows.isEmpty, "enabled tweaks plan files")
    check(preview.rows.map(\.label) == compiled.payloads.map(\.label),
          "plan rows are exactly the compiled payloads")
    check(preview.totalBytes == compiled.payloads.reduce(0) { $0 + $1.byteCount },
          "totalBytes is the payload sum")
    check(preview.selectedCount == 3, "selectedCount matches the selection")
}

// 3 — an enabled status bar adds its payload row.
do {
    var statusBar = StatusBarSelection()
    statusBar.enabled = true
    let classic = try ApplyPreview.build(selection: TweakSelection(),
                                         statusBar: statusBar,
                                         skipSetupEnabled: false,
                                         deviceVersion: "26.0", isIPhone: true)
    check(classic.rows.contains { $0.label.hasPrefix("Status bar overrides (classic)") },
          "classic status bar row appears below iOS 27")
    check(classic.totalBytes > 0, "status bar payload counts towards the total")
    let archive = try ApplyPreview.build(selection: TweakSelection(),
                                         statusBar: statusBar,
                                         skipSetupEnabled: false,
                                         deviceVersion: "27.0", isIPhone: true)
    check(archive.rows.contains { $0.label.hasPrefix("Status bar overrides (iOS 27 archive)") },
          "archive status bar row appears on iOS 27+")
}

// 4 — an enabled skip setup adds its rows ahead of the tweaks.
do {
    var selection = TweakSelection()
    selection.setOn(true, for: TweakCatalog.all[0])
    let preview = try ApplyPreview.build(selection: selection,
                                         statusBar: StatusBarSelection(),
                                         skipSetupEnabled: true,
                                         deviceVersion: "27.0", isIPhone: true)
    check(preview.rows.contains { $0.label.hasPrefix("Skip setup:") }, "skip setup rows appear")
    check(preview.rows.first?.label.hasPrefix("Skip setup:") == true,
          "skip setup rows come ahead of the tweaks")
}

// 5 — conflicts are surfaced in the plan.
do {
    var selection = TweakSelection()
    selection.setOn(true, for: TweakCatalog.byID["RTL"]!)
    selection.setOn(true, for: TweakCatalog.byID["LTR"]!)
    let preview = try ApplyPreview.build(selection: selection,
                                         statusBar: StatusBarSelection(),
                                         skipSetupEnabled: false,
                                         deviceVersion: "27.0", isIPhone: true)
    check(preview.conflicts.count == 1, "RTL + LTR reports exactly one conflict")
    check(preview.conflicts.first?.description.contains("Both layout directions") == true,
          "conflict description names the contradiction")
}

// 6 — the desktop's estimates.
do {
    check(ApplyPreview.timeEstimate(total: 0) == "≈ 2 min", "time estimate floors at one selection")
    check(ApplyPreview.timeEstimate(total: 7) == "≈ 3 min", "time estimate rounds half up")
    check(ApplyPreview.timeEstimate(total: 10) == "≈ 3 min", "time estimate for 10 tweaks")
    check(ApplyPreview.timeEstimate(total: 12) == "≈ 4 min", "time estimate for 12 tweaks")
    check(ApplyPreview.freeBytes != nil, "the volume reports free space")
    check(ApplyPreview.estimatedWorkingSpaceLine() != nil, "the working-space line reads the volume")
    if let warning = ApplyPreview.storageWarningLine() {
        check(!warning.isEmpty, "storage warning is non-empty when present")
    }
}

if failures.isEmpty {
    print("apply-preview: ALL OK")
} else {
    print("apply-preview: \(failures.count) FAIL")
    for item in failures { print("  - \(item)") }
    exit(1)
}
