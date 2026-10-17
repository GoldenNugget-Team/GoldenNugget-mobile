import SwiftUI
import UIKit

/// The pre-apply confirmation the desktop shows before a device is touched:
/// the summary, the storage and battery warnings, the conflict list and the
/// file preview, with the reference's "Apply" / "Cancel" pair.
///
/// The reference builds this in `main_window_mixins.py` (`_build_summary` and
/// its `_storage_warning_line` / `_battery_warning_line` / `_storage_estimate_line`
/// / `_time_estimate_line` helpers) and reaches the file list through
/// `details_callback=self._show_apply_preview`; the details are inlined here
/// because the sheet is small enough to hold them without a second screen.
struct ApplyConfirmSheet: View {
    let preview: ApplyPreview
    let onApply: () -> Void
    let onCancel: () -> Void

    /// The desktop's battery warning (`main_window_mixins.py:921`): warn below
    /// 21% unless the device is charging.  Read here rather than passed in,
    /// because the battery state is a value only this sheet's moment matters for.
    private var batteryLine: String? {
        Self.batteryWarningLine()
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Summary") {
                    LabeledContent("Tweaks selected", value: "\(preview.selectedCount)")
                    LabeledContent("Files to write", value: "\(preview.rows.count)")
                    LabeledContent("Total size", value: Self.size(preview.totalBytes))
                    LabeledContent("Estimated time",
                                   value: ApplyPreview.timeEstimate(total: preview.selectedCount))
                }

                if let line = ApplyPreview.estimatedWorkingSpaceLine() {
                    Section("Working space") {
                        NativeNote(line)
                    }
                }

                // Warnings are gathered so the section is absent when there is
                // nothing to warn about — the reference prints these lines only
                // when each is non-nil.
                let warnings = [ApplyPreview.storageWarningLine(), batteryLine].compactMap { $0 }
                if !warnings.isEmpty {
                    Section("Warnings") {
                        ForEach(Array(warnings.enumerated()), id: \.offset) { _, warning in
                            NativeSafetyNote(warning)
                        }
                    }
                }

                if !preview.conflicts.isEmpty {
                    Section("Conflicts") {
                        ForEach(preview.conflicts) { conflict in
                            Label(conflict.description, systemImage: "exclamationmark.triangle.fill")
                                .font(.subheadline)
                                .foregroundStyle(.red)
                        }
                        NativeSafetyNote("These settings contradict each other. The later "
                            + "tweak wins on the device, so the result may not be what "
                            + "the list suggests.")
                    }
                }

                if !preview.notes.isEmpty {
                    Section("Notes") {
                        ForEach(Array(preview.notes.enumerated()), id: \.offset) { _, note in
                            Text(note)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                if !preview.rows.isEmpty {
                    Section("Files") {
                        ForEach(preview.rows) { row in
                            HStack {
                                Text(row.label)
                                    .font(.subheadline)
                                    .textSelection(.enabled)
                                Spacer(minLength: 8)
                                Text(Self.size(row.byteCount))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Apply")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onCancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") { onApply() }
                        .font(.headline)
                }
            }
        }
    }

    private static func size(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    /// `_battery_warning_line`: `percent > 20` or charging means no warning;
    /// an unknown level (`batteryLevel < 0`) means none either.
    private static func batteryWarningLine() -> String? {
        let device = UIDevice.current
        device.isBatteryMonitoringEnabled = true
        let level = device.batteryLevel
        guard level >= 0 else { return nil }
        let charging = device.batteryState == .charging || device.batteryState == .full
        let percent = Int((level * 100).rounded())
        if charging || percent > 20 { return nil }
        return "⚠ Low battery: \(percent)%. Connect the charger before restoring."
    }
}
