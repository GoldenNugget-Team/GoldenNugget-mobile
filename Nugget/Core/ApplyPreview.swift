import Foundation

/// What a confirmed apply would write, computed before the device is touched —
/// the mobile counterpart of the reference's pre-apply summary/preview
/// (`apply_preview.py`, and the summary dialog in `main_window_mixins.py`).
///
/// The reference previews a *previous* apply from `lastapply.json.preview`
/// history; on a device there is no separate host to preview on, so the honest
/// shape is the *pending* one: the files the current selection compiles to, with
/// their sizes, the conflicts in it, and the storage/time estimates the desktop
/// shows before confirming (`_storage_estimate_line`, `_time_estimate_line`).
///
/// Building the plan runs the same compile the engine will run for the tweaks,
/// status bar and skip-setup payloads — the compile is cheap and the device is
/// never touched, so the plan cannot diverge from the apply.  PosterBoard is
/// deliberately not staged here: its database has to come off the device, and
/// the apply itself fetches it; the view adds a descriptive "is active" line
/// instead.
struct ApplyPreview {
    /// One file the apply would deliver, with its size.
    struct Row: Identifiable {
        let label: String
        let byteCount: Int
        var id: String { label }
    }

    let rows: [Row]
    let totalBytes: Int
    let selectedCount: Int
    let conflicts: [TweakConflict]
    let notes: [String]

    /// The desktop's `is_low_storage`-style line, but for the app's own volume:
    /// how much room the restore has to work with.  Warning when free space
    /// falls below the estimated need.
    static var freeBytes: Int64? {
        let url = URL(fileURLWithPath: "/")
        return (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))
            .flatMap { $0.volumeAvailableCapacityForImportantUsage }
    }

    /// The desktop's `_storage_estimate_line` (`main_window_mixins.py:894`):
    /// the recommended working room, always shown when the volume is readable.
    /// The threshold is `max(5 GiB, 10% of total)`.
    static func estimatedWorkingSpaceLine() -> String? {
        guard let total = totalBytesOnVolume, total > 0 else { return nil }
        let recommended = max(5 * 1024 * 1024 * 1024, Int64(Double(total) * 0.10))
        return String(format: "Estimated working space: keep at least %.1f GB free"
                      + " for the backup and restore.",
                      Double(recommended) / (1024.0 * 1024 * 1024))
    }

    /// The desktop's `_storage_warning_line` (`main_window_mixins.py:872`):
    /// a warning only when free space is below the same threshold.  On-device
    /// the phone *is* the device, so the root volume's numbers replace the
    /// reference's UDID-scoped query.
    static func storageWarningLine() -> String? {
        guard let total = totalBytesOnVolume, total > 0,
              let free = freeBytes, free >= 0 else { return nil }
        let threshold = max(5 * 1024 * 1024 * 1024, Int64(Double(total) * 0.10))
        if free >= threshold { return nil }
        return String(format: "⚠ Low storage: %.1f GB free. Restoring tweaks may"
                      + " require at least %.1f GB free and could fail if the"
                      + " device runs out of space.",
                      Double(free) / (1024.0 * 1024 * 1024),
                      Double(threshold) / (1024.0 * 1024 * 1024))
    }

    /// The desktop's `_time_estimate_line` (`main_window_mixins.py:909`):
    /// `120 + count*8` seconds, rounded *half* up to a whole minute, and never
    /// below one selected item.  `total` is the number of selected tweaks.
    static func timeEstimate(total: Int) -> String {
        let count = max(1, total)
        let seconds = 120 + count * 8
        let (minutes, remainder) = seconds.quotientAndRemainder(dividingBy: 60)
        let rounded = remainder >= 30 ? minutes + 1 : minutes
        return "≈ \(rounded) min"
    }

    /// The volume's total capacity, for the storage lines.
    private static var totalBytesOnVolume: Int64? {
        let url = URL(fileURLWithPath: "/")
        // `volumeTotalCapacity` is an `Int`; widen for the threshold math above.
        return (try? url.resourceValues(forKeys: [.volumeTotalCapacityKey]))
            .flatMap { $0.volumeTotalCapacity.map(Int64.init) }
    }

    /// Compile the current selection exactly as the engine will — tweaks, status
    /// bar and skip setup — and report the plan.  Throws when the status bar
    /// payload cannot be built, which is also what the apply itself would do.
    static func build(selection: TweakSelection,
                      statusBar: StatusBarSelection,
                      skipSetupEnabled: Bool,
                      deviceVersion: String,
                      isIPhone: Bool) throws -> ApplyPreview {
        let compiled = TweakCompiler.compile(selection: selection,
                                             deviceVersion: deviceVersion,
                                             isIPhone: isIPhone)
        var rows: [Row] = []
        var notes: [String] = []
        for payload in compiled.payloads {
            rows.append(Row(label: payload.label, byteCount: payload.byteCount))
        }
        for skipped in compiled.skipped {
            notes.append("Skipped \(skipped.label): \(skipped.reason)")
        }

        if statusBar.isActive {
            let mechanism = StatusBarMechanism.mechanism(for: deviceVersion)
            let built = try statusBar.payload(for: mechanism)
            rows.append(Row(label: "Status bar "
                + (mechanism == .classic ? "overrides (classic)" : "overrides (iOS 27 archive)"),
                            byteCount: built.data.count))
        }

        let skipSetup = skipSetupEnabled
            ? SkipSetup.build(supervised: false, organizationName: "")
            : SkipSetup.Build(payloads: [], warnings: [])
        for payload in skipSetup.payloads {
            rows.append(Row(label: "Skip setup: \(payload.label)", byteCount: payload.byteCount))
        }
        for warning in skipSetup.warnings { notes.append(warning) }

        let conflicts = TweakConflicts.current(in: selection,
                                               deviceVersion: deviceVersion,
                                               isIPhone: isIPhone)
        return ApplyPreview(rows: rows,
                            totalBytes: rows.reduce(0) { $0 + $1.byteCount },
                            selectedCount: selection.enabledCount,
                            conflicts: conflicts,
                            notes: notes)
    }
}
