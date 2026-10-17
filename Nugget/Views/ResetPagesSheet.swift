import SwiftUI

/// The page picker behind the home page's "Reset Tweaks" button.
///
/// A port of `src/gui/dialogs/reset_dialog.py` — the reference's `ResetDialog`:
/// a title, "Select the pages you would like to reset.", one switch per
/// resettable page, and OK/Cancel. Its `accept` runs the reset **only** when at
/// least one page is checked (`if len(self.selected_pages) > 0`), which is why
/// the button here is disabled rather than a no-op on tap.
///
/// Two departures from the desktop dialog, both forced by the platform:
///
/// * a checkbox row is a `Toggle` here, since a desktop checkbox is a tap target
///   the size of a word and a phone row is a switch;
/// * the file list is on screen before the reset runs. The reference's dialog
///   says nothing about what a page reset *writes*, and on a phone the decision
///   and the consequence land in the same place — the user can scroll the note
///   before the button, but not after the restore.
///
/// The page list is `ResetPage.allCases` — the reference's `get_resettable_pages`
/// plus `StatusBar` on iOS 27, which the reference's dialog hides but this port
/// can still reset through `StatusBarArchive` (see `ResetPage`).
struct ResetPagesSheet: View {
    /// The device's iOS version, for the note that says which procedure runs.
    let deviceVersion: String
    let isRunning: Bool
    let onReset: (Set<ResetPage>) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selection: Set<ResetPage> = []

    /// The plan for what is ticked *so far*, so the file list updates as the
    /// switches move. `ios27` is the same predicate `procedureSection` uses, and
    /// it changes the bytes a nulled file is written as — so the list under the
    /// switches has to be built with the same branch the run will take.
    private var plan: TweakReset.Plan { TweakReset.plan(pages: selection, ios27: isIOS27) }

    var body: some View {
        NavigationStack {
            List {
                pageSection
                whatItTouches
                procedureSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Reset Page Tweaks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        selection.removeAll()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Reset", role: .destructive) {
                        let pages = selection
                        // Dismiss first: the run reports into the home page's
                        // status line, and a sheet over it would hide the
                        // progress the user is waiting on.
                        dismiss()
                        onReset(pages)
                    }
                    // The reference's `if len(selected_pages) > 0`, made a
                    // property of the button instead of a branch after the tap.
                    .disabled(selection.isEmpty || isRunning)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// One switch row per page, with the count of files behind it, right-aligned
    /// in the row.
    private var pageSection: some View {
        Section("Select the pages you would like to reset.") {
            ForEach(ResetPage.allCases) { page in
                Toggle(isOn: binding(for: page)) {
                    HStack {
                        Text(page.title)
                        Spacer()
                        Text(fileCount(page)).foregroundStyle(.secondary)
                    }
                }
                .tint(.green)
            }
        }
    }

    /// The paths the reset would write, named before it runs.
    ///
    /// Last path components rather than the absolute paths: the directories are
    /// the same handful for every file here (`/var/Managed Preferences/mobile/`,
    /// `/var/mobile/Library/Preferences/`, `/var/mobile/Library/SpringBoard/`,
    /// `/var/db/com.apple.xpc.launchd/`) and printing them nine times says less
    /// than the file names do. The directory *is* in the run log, which is where
    /// a full path belongs.
    @ViewBuilder
    private var whatItTouches: some View {
        if plan.targets.isEmpty {
            Section { NativeNote("Nothing selected yet.") }
        } else {
            Section("Writes \(plan.targets.count) file(s) to the device:") {
                ForEach(plan.targets) { target in
                    Text("\(shortPath(target.path)) · \(target.kind.rawValue)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Which of the two nulls this device gets, and what the reset does *not*
    /// do.
    ///
    /// The iOS 27 wording is a safety note, not decoration: the difference
    /// between the branches is whether a nulled file is 0 bytes or a valid empty
    /// plist, and the reason is that a 0-byte plist is a *truncated* plist on the
    /// newer releases, which is a SpringBoard boot loop. The user has to be able
    /// to read that before the button, not in a failure afterwards.
    private var procedureSection: some View {
        Section {
            if isIOS27 {
                NativeSafetyNote("iOS \(deviceVersion): each nulled file is written as a "
                    + "valid empty plist, not 0 bytes. A 0-byte plist is a truncated plist on "
                    + "this release and crashes SpringBoard at boot. An empty plist parses, and the "
                    + "system falls back to its own defaults.")
            } else {
                NativeNote("Each nulled file is written as 0 bytes, which makes the "
                    + "daemon that reads it fall back to its defaults.")
            }
            NativeNote("Nothing is read back from the device first: no original values "
                + "are captured, so a file that was already custom before an apply is put back to "
                + "its default rather than to what it held. The daemon list is the exception — it "
                + "is written with the six entries a stock device ships. The selections in this app "
                + "are left alone; applying again writes the tweaks back.")
            NativeNote("The Status Bar reset is the one file here that is written whole, not "
                + "nulled: a fresh, all-default "
                + (isIOS27 ? "StatusBarOverrides.archive with no cellular entries, which "
                    + "SpringBoard decodes as \"no overrides\"."
                    : "statusBarOverrides struct, so every override reads as off.")
                + " It goes through the same mechanism the Status Bar page applies with.")
        }
    }

    private var isIOS27: Bool {
        let major = Int(deviceVersion.split(separator: ".").first ?? "0") ?? 0
        return major >= 27 && !DevSettings.effective.forcePartialRestore
    }

    private func fileCount(_ page: ResetPage) -> String {
        let count = page.locations.count
        return count == 1 ? "1 file" : "\(count) files"
    }

    /// The file name, not the path. Every location here sits in one of a few
    /// directories and the same prefix nine times says less than the name does;
    /// the full path is one tap away in the run log.
    private func shortPath(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    private func binding(for page: ResetPage) -> Binding<Bool> {
        Binding(
            get: { selection.contains(page) },
            set: { on in
                if on { selection.insert(page) } else { selection.remove(page) }
            })
    }
}
