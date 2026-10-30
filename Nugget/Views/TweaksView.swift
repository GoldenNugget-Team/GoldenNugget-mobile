import SwiftUI
import UniformTypeIdentifiers

/// Which half of the device's tweaks this page is showing.
///
/// Upstream splits them into two pages — `IOSTweaksPage` over the registry and
/// `IOSDaemonsContent` over `load_daemons()` — because the desktop has a
/// sidebar to put them in.  A phone has a tab bar with five slots, and these
/// two share everything that matters: the selection, its autosave, the preset
/// import, and the one Apply on the home page.  So they are one page with a
/// switch at the top, not two pages and a fourth menu row.
enum TweaksMode: String, CaseIterable, Identifiable, Hashable {
    case tweaks
    case daemons

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tweaks: "Tweaks"
        case .daemons: "Daemons"
        }
    }
}

/// The tweaks page: GoldenNugget's three registry sections, rendered from the
/// generated catalog with the registry's own editors, defaults and gating.
///
/// The reference renders the same three sections from the same table
/// (`src/gui/ios/tweaks.py`), hides a tweak the device cannot run
/// (`gui/ios/compat.py`), and switches it on as soon as its editor is touched
/// (`Tweak.set_value(..., toggle_enabled: True)`).  All three behaviours are
/// reproduced here; what is *not* reproduced is the five un-ported features —
/// see `docs/tweak-port.md`.
///
/// The layout is the reference's `IOSTweaksPage`: a 56 pt nav bar over a scroll
/// body with 16 pt margins, an uppercase section header per registry section,
/// and **one card per tweak** — the switch rows as `IOSCard` + `IOSSwitch`, the
/// value rows as `IOSSettingsRow` with the current value echoed beside the
/// title.  The two extra lines this app renders (the tweak id and the registry's
/// description) ride inside the same card instead of moving to a tooltip, so the
/// page still shows everything it showed before.
///
/// The daemons half is `DaemonsView` itself, embedded rather than copied: it is
/// a page with its own master switch, Recommended set and confirmation sheet,
/// and a second rendering of forty-odd group switches inside this list would be
/// the same code twice with one of the two going stale.
struct TweaksView: View {
    @ObservedObject private var hotload = HotLoadService.shared
    @AppStorage(UntestedTweaks.enabledKey) private var untestedTweaks = false
    @AppStorage(UntestedTweaks.choiceKey) private var untestedChoiceDone = false
    @State private var showUntestedChoice = false
    @Binding var selection: TweakSelection

    /// The version and model this page filters the registry by, from the shared
    /// monitor.  It was `@State` read once when the page appeared, which meant the
    /// list was built against whatever the device said at that moment — an empty
    /// version disables the bounds and shows everything, so a page opened before
    /// lockdownd answered drew the unfiltered list and stayed that way until it was
    /// left and re-entered.  A computed read: the page has no copy to fall behind,
    /// and a device that changes under it re-filters these rows on the next publish.
    ///
    /// The *selection* is deliberately not re-imported when the poll publishes a new
    /// version — `restoreAutosave()` runs on appear only, because it overwrites the
    /// live selection and a device that rebooted mid-session is not a reason to
    /// discard what the user has since switched on.  The next launch re-applies the
    /// stored preset against the new bounds.
    @ObservedObject private var deviceMonitor = DeviceIdentityMonitor.shared
    private var identity: DeviceIdentity { deviceMonitor.current }
    @State private var showImporter = false
    /// Whether an autosave is on disk right now, for the note under the rows.
    @State private var autosaveSaved = false
    @State private var importReport: TweakImportReport?
    @State private var importError: String?
    /// Bumped by an import so every row is rebuilt from the imported values.
    /// A row's numeric editor seeds its draft when it is created, so without this
    /// the fields kept showing the registry defaults while the selection — the
    /// thing Apply compiles and writes — held something else entirely.
    @State private var formEpoch = 0
    @State private var running = false
    @State private var tail: [String] = []
    /// Tweak categories the user has folded away. Per session, like the rest of
    /// this page's state -- a collapse is a view preference, not a tweak.
    /// Sections the user has explicitly folded or unfolded.
    ///
    /// Empty on purpose, and paired with `foldedByHand`. Collapsing every section
    /// on launch made the page short and the page useless: there was nothing
    /// under a header to tap, not even a restored tweak, and a header that only
    /// toggles on tap reads as dead UI rather than as a disclosure. So the
    /// default for an untouched section is derived from its contents -- see
    /// `collapsedBinding(for:specs:)` -- and this set only holds the ones the
    /// user has since overridden.
    @State private var collapsedSections: Set<TweakSection> = []
    @State private var foldedByHand: Set<TweakSection> = []
    /// The search field's text. Filtering happens through `visibleSpecs`, so a
    /// section with no matches disappears and the count line tracks the query.
    @State private var searchText = ""
    /// Tweaks or daemons. Session-scoped like the rest of this page's view
    /// state: the mode is where the user is looking, not a setting.
    @State private var mode: TweaksMode = .tweaks

    var body: some View {
        Group {
            switch mode {
            case .tweaks: tweaksPage
            // Its own title, search field and confirmation sheet: the mode is
            // the page, so nothing about it is re-implemented here.
            case .daemons: DaemonsView(selection: $selection)
            }
        }
        // In the bar rather than in a band above the list: the search field
        // already takes a drawer under the title, and a third band of chrome on
        // a phone leaves the page starting a fifth of the way down. A principal
        // item also keeps the switch one tap away however far the user has
        // scrolled.
        .toolbar {
            if daemonsAllowed {
                ToolbarItem(placement: .principal) { modePicker }
            }
        }
        // HotLoad can start hiding the daemon groups mid-session (a rule
        // refresh), and a segment that leads to "Feature unavailable" is
        // worse than a segment that is not there.
        .onChange(of: daemonsAllowed) { _, allowed in
            if !allowed { mode = .tweaks }
        }
    }

    /// Whether HotLoad leaves the daemon groups visible.
    ///
    /// The same `Daemons` key that used to hide the destination: the page is
    /// gone, the rule is not.
    private var daemonsAllowed: Bool {
        hotload.currentPolicy.hiddenFeatures["Daemons"] == nil
    }

    private var modePicker: some View {
        Picker("Catalog", selection: $mode) {
            ForEach(TweaksMode.allCases) { mode in
                Text(mode.title).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .frame(width: 190)
        .accessibilityLabel("Tweaks or daemons")
    }

    private var tweaksPage: some View {
        List {
            identitySection
            importSection
            if searchActive && visibleSpecs.isEmpty { emptySearchSection }
            tweakSections
            if let importReport { reportSection(importReport) }
            if let importError { errorSection(importError) }
            if !tail.isEmpty { logSection }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Tweaks")
        // The reference's list search (`gui/ios/tweaks.py`, `ListSearch`): a
        // field that filters the cards by every whitespace-separated word of
        // the query, over the title, the description and the tweak's id.
        .searchable(text: $searchText,
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Search tweaks")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // Read before restoring, and the order is load-bearing: the stored
            // preset is applied through `TweakSpec.isCompatible`, so restoring
            // against an empty version would import tweaks this device cannot
            // take.  The monitor publishes before this returns, so the `identity`
            // `restoreAutosave()` reads is the one just fetched.
            await deviceMonitor.refresh()
            // The reference loads AutoSave at startup (`_load_last_preset`) and
            // rewrites it right after, so a stale entry cannot survive a launch.
            restoreAutosave()
            offerUntestedTweaks()
        }
        .onChange(of: identity.version) { _, _ in offerUntestedTweaks() }
        .onChange(of: untestedTweaks) { _, _ in formEpoch += 1 }
        .alert("This is not all tweaks", isPresented: $showUntestedChoice) {
            Button("Enable incompatible tweaks") { untestedTweaks = true; untestedChoiceDone = true }
            Button("No", role: .cancel) { untestedChoiceDone = true }
        } message: {
            Text("You can get more tweaks, but they are untested with your iOS version. You can change your mind in Settings.")
        }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url): importAutosave(from: url)
            case .failure(let error): importError = error.localizedDescription
            }
        }
    }

    private func offerUntestedTweaks() {
        if UntestedTweaks.isIOS26(identity.version) && !untestedTweaks && !untestedChoiceDone {
            showUntestedChoice = true
        }
    }

    /// Set membership as a `Binding`, which is what the collapsible header wants.
    /// Open a section that has something enabled in it; fold one that does not.
    ///
    /// The point is that whatever is switched on is always visible without a
    /// tap, which is the whole reason to look at this page. A section whose
    /// tweaks are all off stays folded so the page does not become 130 rows of
    /// switches, and the first tap on its header records the choice and sticks.
    private func collapsedBinding(for section: TweakSection, specs: [TweakSpec]) -> Binding<Bool> {
        Binding(
            get: {
                if foldedByHand.contains(section) { return collapsedSections.contains(section) }
                return !specs.contains { selection.isOn($0) }
            },
            set: { collapsed in
                foldedByHand.insert(section)
                if collapsed { collapsedSections.insert(section) } else { collapsedSections.remove(section) }
            })
    }

    // MARK: - Sections

    /// The device line + coverage count.
    private var identitySection: some View {
        Section {
            Text(identity.describe)
                .font(.headline)
            NativeNote("\(selection.enabledCount) of \(visibleSpecs.count) applicable tweak(s) enabled. "
                + "Incompatible and un-ported tweaks are hidden, the same way the reference hides them.")
        }
    }

    private var importSection: some View {
        Section("Saved state") {
            Button {
                showImporter = true
            } label: {
                Label("Import autosave.json", systemImage: "square.and.arrow.down")
            }
            .disabled(running)

            Button(role: .destructive) {
                selection.removeAll()
                importReport = nil
                importError = nil
                // Delete it rather than leaving it to be re-read: an
                // all-off autosave and no autosave are the same state,
                // and the latter cannot resurrect a cleared tweak.
                GoldenNuggetAutosave.clear()
            } label: {
                Label("Clear all tweaks", systemImage: "xmark.circle")
            }
            .disabled(running || selection.enabledCount == 0)

            NativeNote(autosaveNote)
        }
    }

    @ViewBuilder
    private var tweakSections: some View {
        ForEach(TweakSection.allCases.filter { $0 != .daemons }) { section in
            let specs = visibleSpecs.filter { $0.section == section }
            if !specs.isEmpty {
                let on = specs.filter { selection.isOn($0) }.count
                let collapsed = collapsedBinding(for: section, specs: specs)
                // A section that folds away, with its own chevron in the header
                // — the platform's `Section(isExpanded:)` drew no affordance in
                // this list, so the disclosure is explicit.  The rows are only
                // built while the section is open, so a folded group costs
                // nothing.
                Section {
                    if !collapsed.wrappedValue {
                        ForEach(specs, id: \.id) { spec in
                            TweakRow(spec: spec, selection: $selection)
                                .id("\(spec.id)#\(formEpoch)")
                        }
                    }
                } header: {
                    NativeCollapsibleHeader(
                        title: "\(section.rawValue) (\(on)/\(specs.count))",
                        collapsed: collapsed)
                }
            }
        }
    }

    private func reportSection(_ report: TweakImportReport) -> some View {
        Section("Import result") {
            ForEach(Array(report.logLines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func errorSection(_ message: String) -> some View {
        Section("Import failed") {
            NativeNote(message)
        }
    }

    private var logSection: some View {
        Section("Run log (last 30 lines)") {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(tail.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(height: 260)
        }
    }

    // MARK: - Behaviour

    /// The specs this device can run, in registry order.
    ///
    /// A tweak the device cannot run is hidden, not disabled — that is what
    /// `gui/ios/tweaks.py` does with `is_tweak_compatible`, and an always-inert
    /// switch would be a worse lie than an absent one.
    /// The registry tweaks only. The `daemons` section is the page's other
    /// mode (`DaemonsView`), because upstream renders it from `load_daemons()`
    /// and a hand-built widget list rather than from the registry, and folding
    /// it into this one would show 40 rows with no master switch and no
    /// Recommended set.
    private var visibleSpecs: [TweakSpec] {
        let hidden = hotload.currentPolicy.hiddenTweakIDs
        return TweakCatalog.all.filter {
            $0.section != .daemons
                && !hidden.contains($0.id)
                && $0.isCompatible(deviceVersion: identity.version, isIPhone: identity.isIPhone, deviceModel: identity.productType)
                && matchesSearch($0)
        }
    }

    /// Whether the search field holds a non-empty query.
    private var searchActive: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The reference matches a tweak's title, its description and its id
    /// (`gui/ios/tweaks.py`: `self.search.matches(title, description, tid.name)`).
    /// The registry id is the `tid.name` here.
    private func matchesSearch(_ spec: TweakSpec) -> Bool {
        searchMatches(query: searchText, spec.title, spec.detail ?? "", spec.id)
    }

    /// The reference's `IOSSearchEmpty`: shown only while a query is live and
    /// nothing survived it.
    private var emptySearchSection: some View {
        Section {
            Text("No matches found.")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Autosave

    /// Startup load of the AutoSave preset, followed by the reference's
    /// immediate rewrite so stale entries cannot survive a launch.
    private func restoreAutosave() {
        autosaveSaved = GoldenNuggetAutosave.exists
        // Through the bootstrap, so this is a no-op when Home already applied it
        // at launch. Applying twice would be harmless but would re-log the import
        // report on every visit to the page.
        guard let report = AutoSaveBootstrap.apply(into: &selection, identity: identity)
        else { return }
        // Logged rather than shown: this runs on every launch, so a report card
        // would greet the user on a perfectly normal run.  The reference logs
        // the same way, and the run log is the durable half of the report.
        for line in report.logLines { GoldenNuggetEngine.shared.log(line) }
        formEpoch &+= 1
    }

    /// The autosave line: where the file lives and that the import row is the
    /// manual path for a preset that came from somewhere else.
    private var autosaveNote: String {
        let path = "Documents/GoldenNugget/Presets/\(GoldenNuggetAutosave.presetName).json"
        let state = autosaveSaved ? "saved" : "nothing saved yet"
        return "Your selection is saved to \(path) on every change and restored on "
            + "launch, exactly as the desktop app's AutoSave preset does (\(state)). "
            + "Import is for a preset from elsewhere; entries this port does not carry "
            + "are listed below rather than guessed at."
    }

    private func importAutosave(from url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let preset = try GoldenNuggetPreset.parse(data)
            let report = GoldenNuggetPresetImport.apply(preset, to: &selection,
                                                        deviceVersion: identity.version,
                                                        isIPhone: identity.isIPhone, deviceModel: identity.productType,
                                                        hiddenTweakIDs: HotLoadService.shared.currentPolicy.hiddenTweakIDs)
            // The log is the durable half of the report: the sheet can be
            // dismissed, the run log cannot.
            for line in report.logLines { GoldenNuggetEngine.shared.log(line) }
            formEpoch &+= 1
            importReport = report
            importError = nil
        } catch {
            importError = error.localizedDescription
            importReport = nil
        }
    }

}

/// One tweak as one card: the control band on top, then the id and the
/// registry's description — see `TweaksView`'s note on why those two stay.
///
/// The copy comes from the registry (`TweakSpec.detail`, GoldenNugget's
/// `description=`), not from a second hand-written table — one source of truth
/// for "what does this switch do".
