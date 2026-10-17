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

    /// The master switch, upstream's `daemons_tweak.enabled`. Kept out of the
    /// selection on purpose: it gates every group rather than being one, and
    /// turning it off is the same observable state as having no group on.
    @State private var masterEnabled = true
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
        .task {
            // Upstream's master switch reads the stored `enabled` flag. There is
            // no separate flag here, so the page reports the state that actually
            // reaches the device: master is on exactly when a group is on.
            masterEnabled = DaemonGroups.all.contains { isOn($0) }
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
            get: { masterEnabled },
            set: { on in
                masterEnabled = on
                // The reference's master switch is a gate, not a group: flipping
                // it off leaves the per-group choices alone and only stops the
                // write.
                if !on { setAllRecommended(false) }
            }))
    }

    private var recommendedRow: some View {
        Button {
            let turnOn = !isAllRecommendedOn
            for group in DaemonGroups.recommended {
                setGroup(group, on: turnOn)
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
                     isOn: { isOn(spec) }, setOn: { setOn($0, for: spec) })
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
                     isOn: { isOn(spec) }, setOn: { setOn($0, for: spec) })
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
