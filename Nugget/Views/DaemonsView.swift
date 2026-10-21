import SwiftUI

/// The Daemons page — a port of GoldenNugget's `IOSDaemonsContent`
/// (`src/gui/ios/daemons.py`).
///
/// Everything a group switch does is a `TweakSpec` in the catalog, so Apply,
/// autosave and preset import work on it unchanged. This view is only the
/// reference's arrangement: a master switch, the one-tap Recommended set, the
/// two switch groups, and the ScreenTime nullify underneath.
///
/// The six groups upstream marks interface-visible but gives no switch
/// (`showsSwitch == false`) are deliberately not rendered — they belong to the
/// Recommended set, and the reference offers no way to toggle them alone.
struct DaemonsView: View {
    @Binding var selection: TweakSelection

    /// Matches desktop's install-level acknowledgement, outside autosave/presets.
    /// No selection is changed until both warnings have been accepted.
    @AppStorage("daemon_bootloop_warned") private var daemonWarningsAccepted = false
    @State private var pendingEnable: DaemonEnableAction?
    /// The model line at the top of the page, from the shared monitor — see
    /// `TweaksView`'s note.  A computed read, so this page cannot hold a copy that
    /// disagrees with the one the Tweaks page filtered its rows by.
    @ObservedObject private var deviceMonitor = DeviceIdentityMonitor.shared
    private var identity: DeviceIdentity { deviceMonitor.current }

    /// Same disclosure behaviour as the Tweaks page: a section the user has not
    /// touched is open when something in it is on. Forty groups of switches is a
    /// page you cannot scan, but a section that is folded hides the one group you
    /// came to change, so the fold follows the state rather than a blanket
    /// default.
    @State private var collapsedSections: Set<DaemonSection> = []
    @State private var foldedByHand: Set<DaemonSection> = []
    /// The search field's text, filtered through `visibleGroups`.
    @State private var searchText = ""

    var body: some View {
        List {
            headerSection
            coverageSection
            if searchActive && !DaemonGroups.all.contains(where: { $0.showsSwitch && matchesSearch($0) }) {
                emptySearchSection
            }
            ForEach(DaemonSection.allCases) { section in
                let groups = visibleGroups(in: section)
                if !groups.isEmpty {
                    // Same disclosure behaviour as the tweaks page: an explicit
                    // chevron in the header, rows built only while open.
                    let collapsed = collapsedBinding(for: section, groups: groups)
                    Section {
                        if !collapsed.wrappedValue {
                            ForEach(groups, id: \.name) { group in
                                groupRow(group)
                            }
                        }
                    } header: {
                        NativeCollapsibleHeader(
                            title: "\(section.rawValue) (\(onCount(in: groups))/\(groups.count))",
                            collapsed: collapsed)
                    }
                }
            }
            screenTimeSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Daemons")
        // The reference gives the daemons list the same search widget as the
        // tweaks list (`gui/ios/daemons.py`, `ListSearch`): every word of the
        // query must appear in the group's title, its name or one of its labels.
        .searchable(text: $searchText,
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Search daemons")
        // Compact widths only -- on a tablet the split view draws its own sidebar
        // toggle, and a second button beside it is the duplicate-controls mess.
        .goldenSidebarButton()
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $pendingEnable) { action in
            DaemonEnableWarningSheet {
                daemonWarningsAccepted = true
                performEnable(action)
                pendingEnable = nil
            }
        }
        .task {
            // Fresh rather than cached: the model line at the top of this page is
            // what the user came to read, and a page opened after a device swap
            // should not need a restart to say so.
            await deviceMonitor.refresh()
        }
    }

    // MARK: - Sections

    /// The device line and the count, in the Tweaks page's shape. The counts
    /// differ deliberately: this page has no "applicable" filter, so a group that
    /// is missing is missing for good, not because the device cannot run it.
    private var coverageSection: some View {
        Section {
            Text(identity.describe)
                .font(.headline)
            NativeNote("\(onCount(in: DaemonGroups.all.filter { $0.showsSwitch })) "
                + "of \(DaemonGroups.all.filter { $0.showsSwitch }.count) daemon group(s) on. "
                + "The groups upstream marks interface-visible but gives no switch are in the "
                + "Recommended set only.")
        }
    }

    private func onCount(in groups: [DaemonGroup]) -> Int {
        groups.filter(isOn).count
    }

    private func collapsedBinding(for section: DaemonSection,
                                  groups: [DaemonGroup]) -> Binding<Bool> {
        Binding(
            get: {
                if foldedByHand.contains(section) { return collapsedSections.contains(section) }
                return onCount(in: groups) == 0
            },
            set: { collapsed in
                foldedByHand.insert(section)
                if collapsed { collapsedSections.insert(section) } else { collapsedSections.remove(section) }
            })
    }

    private var headerSection: some View {
        Section {
            masterRow
            recommendedRow
            NativeNote("Writes "
                + "/var/db/com.apple.xpc.launchd/disabled.plist. Disabling a "
                + "daemon stops its service. Only the "
                + "\(DaemonGroups.allowedKeys.count) labels shown here can "
                + "ever reach the file.")
        }
    }

    private var masterRow: some View {
        Toggle("Enable Daemon Modifications", isOn: Binding(
            get: { selection.daemonModificationsEnabled },
            set: { on in
                if on {
                    requestEnable(.master)
                    return
                }
                selection.daemonModificationsEnabled = false
            }))
    }

    private var recommendedRow: some View {
        Button {
            if selection.daemonModificationsEnabled && isAllRecommendedOn {
                setAllRecommended(false)
            } else {
                requestEnable(.recommended)
            }
        } label: {
            Label("Recommended (analytics, tracking & logging)",
                  systemImage: "wand.and.stars")
        }
    }

    private var screenTimeSection: some View {
        Section("Other") {
            let spec = TweakCatalog.screenTimeSpec
            TweakRow(spec: spec, selection: $selection,
                     isOn: { isOn(spec) }, setOn: { requestSetOn($0, for: spec) })
            NativeNote("Writes a 0-byte file over "
                + "\(DaemonGroups.screenTime.path). Upstream models this as "
                + "a NullifyFileTweak: it removes a plist rather than "
                + "writing one.")
        }
    }

    // MARK: - Rows

    /// The Tweaks page's row, given the daemon meaning of "on": a group is on
    /// when every launchd label in it is written as disabled, which needs the
    /// value dict written alongside the flag, not just the flag.
    @ViewBuilder
    private func groupRow(_ group: DaemonGroup) -> some View {
        if let spec = spec(group) {
            TweakRow(spec: spec, selection: $selection,
                     isOn: { isOn(spec) }, setOn: { requestSetOn($0, for: spec) })
        } else {
            // A group with no spec would be a switch that does nothing. Say so
            // rather than rendering a row that cannot be tapped.
            Text(group.title)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Selection

    private func visibleGroups(in section: DaemonSection) -> [DaemonGroup] {
        DaemonGroups.all.filter { $0.section == section && $0.showsSwitch && matchesSearch($0) }
    }

    /// Whether the search field holds a non-empty query.
    private var searchActive: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The reference stores a card's `searchText` as the title, the daemon name
    /// and its labels joined (`gui/ios/daemons.py`), and matches the query's
    /// words against all of them.
    private func matchesSearch(_ group: DaemonGroup) -> Bool {
        searchMatches(query: searchText, group.title, group.name, group.labels.joined(separator: " "))
    }

    /// The reference's `IOSSearchEmpty`: shown only while a query is live and
    /// no switchable group survived it.
    private var emptySearchSection: some View {
        Section {
            Text("No matches found.")
                .foregroundStyle(.secondary)
        }
    }

    private func spec(_ group: DaemonGroup) -> TweakSpec? {
        TweakCatalog.byID["Daemon.\(group.name)"]
    }

    private func isOn(_ group: DaemonGroup) -> Bool {
        spec(group).map(isOn) ?? false
    }

    private func isOn(_ spec: TweakSpec) -> Bool { selection.isOn(spec) }

    private var isAllRecommendedOn: Bool {
        DaemonGroups.recommended.allSatisfy(isOn)
    }

    /// Gate every interactive enable path, including Recommended and Screen Time.
    /// Turning something off never requires acknowledgement.
    private func requestSetOn(_ on: Bool, for spec: TweakSpec) {
        if on {
            requestEnable(.tweak(spec.id))
        } else {
            setOn(false, for: spec)
        }
    }

    private func requestEnable(_ action: DaemonEnableAction) {
        if daemonWarningsAccepted {
            performEnable(action)
        } else {
            pendingEnable = action
        }
    }

    private func performEnable(_ action: DaemonEnableAction) {
        selection.daemonModificationsEnabled = true
        switch action {
        case .master: break
        case .recommended: setAllRecommended(true)
        case .tweak(let id):
            if let spec = TweakCatalog.byID[id] { setOn(true, for: spec) }
        }
    }

    /// One group on means "disable every launchd label in it", which is what
    /// upstream's `set_multiple_values(sorted(keys), value=True)` does.
    private func setGroup(_ group: DaemonGroup, on: Bool) {
        guard let spec = spec(group) else { return }
        setOn(on, for: spec)
    }

    /// A daemon group is "on" when its labels must be *disabled*, so the switch
    /// writes `true` for every label in it — the launchd plist reads
    /// `label: true` as "do not start this". The registry defaults in the spec
    /// are all-false, so setting only the on-flag would write a file that
    /// disables nothing.
    private func setOn(_ on: Bool, for spec: TweakSpec) {
        if on, let group = DaemonGroups.all.first(where: { "Daemon.\($0.name)" == spec.id }) {
            selection.restore(enabled: true, value: nil, multiValues: trueValues(for: group),
                              for: spec)
        } else {
            selection.setOn(on, for: spec)
            selection.removeValue(for: spec)
        }
    }

    private func trueValues(for group: DaemonGroup) -> [String: TweakValue] {
        Dictionary(uniqueKeysWithValues: group.labels.map { ($0, TweakValue.bool(true)) })
    }

    private func setAllRecommended(_ on: Bool) {
        for group in DaemonGroups.recommended { setGroup(group, on: on) }
    }
}

/// The pending intent stays separate from the selection so Stop or a swipe to
/// dismiss leaves both the toggles and the persisted acknowledgement unchanged.
private enum DaemonEnableAction: Identifiable {
    case master
    case recommended
    case tweak(String)

    var id: String {
        switch self {
        case .master: "master"
        case .recommended: "recommended"
        case .tweak(let id): id
        }
    }
}

/// Desktop's two consecutive confirmations, presented in one native sheet to
/// avoid presenting a second alert while the first is still being dismissed.
private struct DaemonEnableWarningSheet: View {
    let confirm: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var backupWarning = false

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text("Before you continue")
                .font(.headline)
            Text(backupWarning
                 ? "Make a full device backup before applying these changes."
                 : "Stopping system services can leave your device stuck restarting or unable to start. Recovery may require restoring the device.")
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Continue Anyway") {
                if backupWarning { confirm() } else { backupWarning = true }
            }
            .buttonStyle(.borderedProminent)
            Button("Stop", role: .cancel) { dismiss() }
        }
        .padding(24)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
