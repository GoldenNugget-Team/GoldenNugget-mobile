import SwiftUI
import UniformTypeIdentifiers

/// The PosterBoard page: wallpaper packs, a video wallpaper, and the resets.
///
/// The reference's own page has three tabs — Tendies, Templates, Video — plus a
/// reset dialog.  Templates is not here, and its absence is deliberate: a
/// `.template` is a different file format with its own options engine
/// (`template_file.py` + `template_options/`), and upstream itself lists
/// Templates and PosterBoard as two separate un-ported features.  What *is* here
/// covers everything the other two tabs do, including the video method the reset
/// dialog exists to recover from.
///
/// Three things this page says that the reference does not, all of them because
/// this port has to be honest about what has run on a device:
///
///   * **The database card.** A wallpaper is a descriptor directory *plus* three
///     rows in the store's own sqlite, and the database cannot be synthesised —
///     it has to be fetched from the device.  The card says when that happened
///     last, and the fetch is also the first stage of an apply that needs one.
///     It is hidden on AirLift, which has no such stage: that mode writes the
///     descriptors into the container and never touches the rows.
///   * **The unsafe-container warning** is shown on the pack row rather than in
///     a modal that appears on import: it is a property of the pack, and it stays
///     true for as long as the pack is listed.
///   * **The reset section states what it does not undo.** A reset makes the
///     fetched database stale, so the next apply fetches a fresh one; saying so
///     here is cheaper than the puzzle of a store that half-works.
struct PosterBoardView: View {
    /// Everything this page edits, **owned by `RootView`**: the page picks the
    /// wallpapers and the home page's single `Apply` delivers them, so the selection has
    /// to outlive this view — which a `NavigationSplitView` destroys on every sidebar
    /// selection.  The old `@AppStorage` options moved in here for the same reason: two
    /// sources of truth for "was Loop on" is one too many when the second one is the one
    /// that applies.
    @Binding var selection: PosterBoardSelection

    @State private var identity: DeviceIdentity = .unknown
    @State private var databaseSummary = "not checked yet"
    @State private var pickError: String?
    /// Only the database fetch runs from this page — the apply is the home page's.
    @State private var status: String?
    @State private var statusTone: GoldenTone = .secondary
    @State private var running = false
    @State private var runStarted: Date?

    @State private var showPackImporter = false
    @State private var showVideoImporter = false
    @State private var showThumbnailImporter = false

    /// The apply mode, seeded from the setting and written back on change.
    ///
    /// `@AppStorage` would have been the shorter version, and the reason it is not
    /// used is that the mode has to be validated against the device on this page —
    /// AirLift needs iOS 26.2 and a pairing record, and a picker that can hold a mode
    /// the page will later refuse is a worse thing to show than one that cannot be
    /// set here.
    @State private var applyMode: PosterBoardApplyMode = .airlift

    /// The imported pack awaiting a Convert / Install-as-is answer, if any. See
    /// `LegacyConvertPromptModifier` for why the question is a value rather than
    /// an immediate call.
    @State private var legacyPrompt: LegacyConvertPrompt?

    var body: some View {
        List {
            deviceSection
            applyModeSection
            // AirLift writes the descriptors into the container and never looks
            // at the store's sqlite, so on that mode the whole card is about a
            // stage the run will not perform. Leaving it up would be offering a
            // fetch that the apply below ignores.
            if applyMode != .airlift { databaseSection }
            packsSection
            videoSection
            resetSection
            if applyMode == .airlift { airliftApplySection }
            applySection
            if let pickError { errorSection(pickError) }
            if !statusText.isEmpty {
                Section {
                    Text(statusText)
                        .foregroundStyle(statusTone.nativeColor)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            RunLogCard()
        }
        .listStyle(.insetGrouped)
        .navigationTitle("PosterBoard")
        .navigationBarTitleDisplayMode(.inline)
        // Loading the pack list and the database state is a directory walk and a
        // file stat, so it happens here and not in `body`. `loadFromDisk` is idempotent
        // and does not touch the options: `RootView` already ran it at launch, and this
        // pass is what picks up a pack imported from somewhere else meanwhile.
        .task {
            // The device line is read here and not in `body`, like every other page: it is
            // a lockdown call.  It used to be declared and never set, so the card said
            // "unknown device" for the whole life of this page.
            identity = await DeviceIdentity.read()
            selection.loadFromDisk()
            applyMode = PosterBoardApplyModeSettings.current
            refreshDatabaseSummary()
        }
        .legacyConvertPrompt($legacyPrompt, answer: answerLegacyPrompt)
    }

    // MARK: - The legacy-format answer

    /// Store the Convert / Install-as-is answer and reload the selection, which is
    /// what puts the new answer on the pack the apply reads.
    ///
    /// The reference assigns `auto_convert` on the tendie it just created; the pack
    /// list here is re-read from disk, so the answer goes to
    /// `PosterBoardPreferences.autoConvertAnswers` through
    /// `settingAutoConvert` and the list is rebuilt from it.
    private func answerLegacyPrompt(_ prompt: LegacyConvertPrompt, _ convert: Bool) {
        legacyPrompt = nil
        // `settingAutoConvert` writes the answer straight through, which is what
        // matters here: the pack in the selection is a value read from the archive,
        // and the apply re-reads it too.
        _ = prompt.pack.settingAutoConvert(convert)
        RunLog.shared.append(convert
            ? "PosterBoard: \(prompt.pack.name) will be converted to the modern format on Apply "
                + "(legacy: \(prompt.families.joined(separator: ", ")))."
            : "PosterBoard: \(prompt.pack.name) stays in its original legacy format "
                + "(\(prompt.families.joined(separator: ", "))).")
        selection.loadFromDisk()
    }

    // MARK: - Device and database

    private var deviceSection: some View {
        Section {
            Text(identity.describe)
                .font(.headline)
            NativeNote("Wallpapers are delivered as files into this app's own backup "
                + "of the device, in the \(PosterBoard.domain) domain — the same channel the "
                + "tweaks use. Nothing is written to the device until Apply.")
        }
    }

    // MARK: - Apply mode

    /// The two ways a selection can reach the device, as a segmented choice.
    ///
    /// A `Picker` rather than a switch: this is a choice between two mechanisms
    /// with different costs, and a switch cannot show what the other option is.
    /// The consequence of picking AirLift is spelled out under it, because
    /// "AirLift" alone says nothing about the version floor or the reboot it
    /// saves.
    private var applyModeSection: some View {
        Section {
            Picker("How to apply", selection: $applyMode) {
                ForEach(PosterBoardApplyMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .onChange(of: applyMode) { _, mode in
                PosterBoardApplyModeSettings.current = mode
            }
            NativeNote(applyMode.summary)
            if applyMode == .airlift, !airliftBlocker.isEmpty {
                NativeSafetyNote(airliftBlocker)
            }
            if applyMode == .airlift {
                NativeNote("The store database is not part of this mode, so its card "
                    + "is hidden: the injection writes the descriptors straight into the "
                    + "container and the rows are not touched. Automatic refresh is ignored too.")
            }
            if !selection.resetModes.isEmpty, !applyMode.supportsReset {
                NativeSafetyNote("The reset you have selected cannot be done over AirLift. "
                    + "Switch back to Protective backup to keep it.")
            }
        }
    }

    /// Why AirLift is not usable right now, in the page's own words.
    ///
    /// The same check `GoldenNuggetEngine` makes before it starts a run, stated
    /// here so the picker cannot be set to something the apply will refuse.
    private var airliftBlocker: String {
        let reason = Airlift.unsupportedReason(deviceVersion: identity.version)
        if !reason.isEmpty { return reason }
        if !FileManager.default.fileExists(atPath: AppPaths.pairingFile.path) {
            return "AirLift needs a pairing record and none is stored. Import one on the home page."
        }
        return ""
    }

    private var databaseSection: some View {
        Section("Store database") {
            Toggle("Automatic refresh", isOn: $selection.autoRefresh)
            Button {
                fetchDatabase()
            } label: {
                HStack {
                    Label("Fetch database from device", systemImage: "arrow.down.circle")
                    Spacer()
                    if running { ProgressView().controlSize(.small) }
                }
            }
            .disabled(running)
            NativeNote(databaseNote)
        }
    }

    private var databaseNote: String {
        var lines = [
            "Fetched database: \(databaseSummary)",
            "A wallpaper exists in two places at once — its descriptor files, and three rows in "
                + "the store's own sqlite. The rows carry the device's provider registrations "
                + "and the metadata the picker sorts by, so they cannot be invented: the apply "
                + "fetches the store from the device first and adds rows to a copy of it.",
        ]
        if selection.autoRefresh {
            lines.append("Automatic refresh is on (upstream's default): each apply also writes "
                + "PBF_RESET_FILE_PROTECTIONS, which is what makes PosterBoard re-read the "
                + "store at boot. Turn it off to leave the device's preferences alone.")
        }
        return lines.joined(separator: "\n\n")
    }

    // MARK: - Packs

    private var packsSection: some View {
        Section("Wallpaper packs (\(selection.tendies.count))") {
            // The desktop build opens the wallpaper downloader from right here
            // (`wallpaper_downloader.py`, reached from this page's own button),
            // so the entry point stays here too — the sidebar destination is the
            // addition, for a phone where this page is three scrolls down.
            NavigationLink(value: AppDestination.wallpaperDownloads) {
                Label("Download Wallpapers", systemImage: "square.and.arrow.down")
            }
            .disabled(running)
            Button {
                showPackImporter = true
            } label: {
                Label("Import .tendies pack", systemImage: "plus.circle")
            }
            .disabled(running)
            // Keep each document picker attached to the control that presents it.
            // Stacking three fileImporter modifiers on the parent List can cause
            // one presentation host to shadow the others on iOS 26.
            .fileImporter(isPresented: $showPackImporter, allowedContentTypes: [.data]) { result in
                importPack(result)
            }
            if selection.tendies.isEmpty {
                NativeNote("No packs imported yet. A `.tendies` file is a ZIP "
                    + "holding a wallpaper's descriptor; import one from a wallpaper "
                    + "collection (Cowabunga and CaPlayground publish them), then Apply.")
            } else {
                ForEach(selection.tendies) { pack in
                    packRow(pack)
                }
                Button(role: .destructive) {
                    selection.tendies.forEach(PosterBoardImports.remove)
                    selection.loadFromDisk()
                } label: {
                    Label("Remove all packs", systemImage: "trash")
                }
                .disabled(running)
                NativeNote("Upstream caps a selection at "
                    + "\(PosterBoardImports.descriptorLimit) descriptors. Each pack is "
                    + "copied into this app, so removing one here removes the copy — "
                    + "the file you imported is untouched.")
            }
            // Upstream's `auto_convert_legacy` checkbox, on by default. It gates
            // both the import dialog and the apply-time rewrite, so it belongs
            // here rather than in the apply card: turning it off is how a user
            // says "push what I imported, as it is" for good.
            Toggle("Convert legacy wallpapers to the modern format",
                   isOn: Binding(get: { PosterBoardPreferences.autoConvertLegacy },
                                 set: { PosterBoardPreferences.autoConvertLegacy = $0 }))
            NativeNote(legacyConvertNote)
        }
    }

    private var legacyConvertNote: String {
        var lines = [
            "iOS 27 builds the depth effect only for the modern (“Clownfish”) layout, so a pack "
                + "made before iOS 27 is rewritten when it is applied — otherwise it installs and "
                + "looks flat, with no depth. The rewrite re-stamps the family, drops external "
                + "scripts and republishes the planes, and it is best effort: it can change how a "
                + "wallpaper looks. A pack holding nothing pre-27 is left alone either way.",
        ]
        if let atLeast27 = PosterBoard.compareVersion(identity.version, "27"), atLeast27 < 0 {
            lines.append("This device is on iOS \(identity.version), which reads a legacy pack as "
                + "it is, so nothing is converted here and no pack is asked about.")
        }
        if !PosterBoardPreferences.autoConvertLegacy {
            lines.append("Conversion is off, so legacy packs are pushed with their original files.")
        }
        return lines.joined(separator: "\n\n")
    }

    private func packRow(_ pack: PosterBoardTendie) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(pack.name)
                        .font(.body)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(pack.summary)
                        .font(.caption)
                        .foregroundStyle(pack.isUnsafeContainer ? Color.orange : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .layoutPriority(1)
                Spacer(minLength: 8)
                Button(role: .destructive) {
                    PosterBoardImports.remove(pack)
                    selection.loadFromDisk()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 14))
                }
                .buttonStyle(.plain)
                .disabled(running)
            }

            // Which extension this pack is injected under. A bare pack does not
            // carry that, and picking the wrong one is silent: the descriptor
            // lands in a folder the provider never reads and the wallpaper just
            // does not appear. The reference asks at import time
            // (`TendieItem.posterType`); here it is a row control that persists
            // with the pack.
            if !pack.isContainer {
                Picker("Target extension", selection: Binding(
                    get: { pack.posterType },
                    set: { chosen in
                        guard let index = selection.tendies.firstIndex(where: { $0.id == pack.id })
                        else { return }
                        selection.tendies[index] = pack.settingPosterType(chosen)
                    }
                )) {
                    ForEach(PosterBoardPosterType.allCases) { type in
                        Text(type.label).tag(type)
                    }
                }
                .disabled(running)
            }
        }
    }

    // MARK: - Video

    private var videoSection: some View {
        Section("Video wallpaper") {
            Button {
                showVideoImporter = true
            } label: {
                HStack {
                    Label("Choose video", systemImage: "film")
                    if let video = selection.video?.lastPathComponent {
                        Spacer()
                        Text(video).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            .disabled(running)
            .fileImporter(isPresented: $showVideoImporter,
                          allowedContentTypes: [.movie, .video, .quickTimeMovie, .mpeg4Movie]) { result in
                importMedia(result, into: PosterBoard.videoDirectory) { selection.video = $0 }
            }
            Toggle("Loop (CoreAnimation frame list)", isOn: $selection.loop)
            if selection.loop {
                Toggle("Reverse on loop", isOn: $selection.reverse)
                Toggle("Cover the clock", isOn: $selection.foreground)
                calculationModeRow
            } else {
                Button {
                    showThumbnailImporter = true
                } label: {
                    HStack {
                        Label("Choose freeze frame (.heic)", systemImage: "photo")
                        if let thumbnail = selection.thumbnail?.lastPathComponent {
                            Spacer()
                            Text(thumbnail).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                .disabled(running)
                .fileImporter(isPresented: $showThumbnailImporter,
                              allowedContentTypes: [.heic, .image]) { result in
                    importMedia(result, into: PosterBoard.thumbnailDirectory) { selection.thumbnail = $0 }
                }
            }
            if selection.video != nil || selection.thumbnail != nil {
                Button(role: .destructive) {
                    PosterBoard.clearFiles(in: PosterBoard.videoDirectory)
                    PosterBoard.clearFiles(in: PosterBoard.thumbnailDirectory)
                    selection.video = nil
                    selection.thumbnail = nil
                } label: {
                    Label("Clear the video choice", systemImage: "xmark.circle")
                }
            }
            NativeNote(videoNote)
        }
    }

    /// Four options in one row is 288 pt of text at the narrowest window width,
    /// so this is a menu: it keeps its value on screen instead of wrapping.
    private var calculationModeRow: some View {
        Picker("Calculation mode", selection: $selection.calculationMode) {
            ForEach(PosterBoardCalculationMode.allCases) { mode in
                Text(mode.title).tag(mode.rawValue)
            }
        }
    }

    private var videoNote: String {
        var lines = [String]()
        if selection.loop {
            lines.append("Looping decodes the video to JPEG frames and hands PosterBoard a "
                + "CoreAnimation frame list (up to \(PosterBoardVideo.frameLimit) frames, at the "
                + "video's own resolution). It is slow, and the frames are written into the "
                + "backup, so a long clip makes a large one — trim it first.")
            lines.append("A video that carries a rotation transform is decoded in its stored "
                + "orientation, which is what the reference's decoder does; such a clip may "
                + "appear rotated on the Lock Screen.")
        } else {
            lines.append("The live-photo method writes the video into a Photos poster descriptor "
                + "and needs a freeze frame — the reference raises rather than shipping a "
                + "descriptor with no thumbnail. The video is rewrapped as .mov unless it "
                + "already is one.")
        }
        if selection.loop && selection.reverse {
            lines.append("Reverse on loop plays the clip forwards and then backwards.")
        }
        return lines.joined(separator: "\n\n")
    }

    // MARK: - Reset

    private var resetSection: some View {
        Section("Reset") {
            Toggle("Full reset — wipe everything and start empty", isOn: $selection.fullReset)
            ForEach(PosterBoardResetMode.allCases) { mode in
                Toggle(mode.rawValue, isOn: binding(for: mode))
            }
            if !resetWarning.isEmpty {
                NativeSafetyNote(resetWarning)
            }
        }
    }

    private func binding(for mode: PosterBoardResetMode) -> Binding<Bool> {
        Binding(
            get: { !selection.fullReset && selection.resetModes.contains(mode) },
            set: { isOn in
                if isOn {
                    selection.resetModes.insert(mode)
                } else {
                    selection.resetModes.remove(mode)
                }
            })
    }

    private var resetWarning: String {
        if selection.fullReset {
            return "Full reset: the store's Extensions, GalleryCache and Backups directories are "
                + "zeroed and replaced with an empty database. Every wallpaper on the device is "
                + "gone, and the database fetched before this point is stale — the next apply "
                + "fetches a fresh one."
        }
        if selection.resetModes.isEmpty { return "" }
        let names = selection.resetModes.map(\.rawValue).sorted().joined(separator: ", ")
        return "Selected: \(names). A reset is written as a 0-byte file over the folder, which is "
            + "how the reference clears them; it runs without needing the store database, so it "
            + "is the recovery path for a store that is already misbehaving. It does not undo "
            + "anything already applied."
    }

    // MARK: - What the one Apply will carry

    /// **There is no Apply button here**, and that is the point: the reference has one
    /// apply pass for everything (`_apply_tweak_pass`, with a `needs_posterboard` flag),
    /// and so does this app — the button lives on the home page, next to the tweaks, and
    /// it carries this page's selection with them in one backup and one restore.
    ///
    /// A second button would have been two runs of the same four stages over two payload
    /// sets: two backups, two restores, two chances to leave the device half-applied, and
    /// no way for the operator to know which of them carried what.  Upstream's own
    /// sidebar has a single Apply page for the same reason.
    /// The apply that needs no backup, on the page whose contents it delivers.
    ///
    /// It lives here rather than on the home page because the two applies are
    /// not the same run: the home page's Apply couples the wallpapers to the
    /// tweaks and to a protective backup, and this one is the wallpapers alone.
    /// Reached through the home page, a wallpapers-only run looks identical to
    /// one that also takes a backup — the page says otherwise, but the button
    /// to believe is the one that was pressed.
    private var airliftApplySection: some View {
        Section {
            if selection.isActive {
                Text("Ready: \(selection.describe)").foregroundStyle(.tint)
            } else {
                NativeNote("No packs imported yet — import a `.tendies` above to "
                    + "apply it this way.")
            }
            Button {
                applyViaAirlift()
            } label: {
                HStack {
                    Label("Apply via AirLift", systemImage: "bolt.horizontal.circle")
                    Spacer()
                    if running { ProgressView().controlSize(.small) }
                }
            }
            .disabled(!airliftAvailable)
            if !airliftBlocker.isEmpty {
                NativeSafetyNote(airliftBlocker)
            }
            NativeNote("Writes the descriptors into \(PosterBoard.domain) over a "
                + "tunnel and resprings, so it is live in seconds. No backup is taken, because "
                + "nothing is delivered back to the device — but for the same reason it applies "
                + "**only** the packs: tweaks need the backup, so they still go through the "
                + "**Apply** button on the home page.")
        }
    }

    /// Whether the run can start: not already running, not blocked by the device,
    /// and there is something selected to inject.
    private var airliftAvailable: Bool {
        !running && airliftBlocker.isEmpty && selection.isActive
    }

    private var applySection: some View {
        Section {
            if applyMode == .airlift {
                // The home page's Apply is still a backup-mode run even when this
                // page is set to AirLift: it delivers the tweaks, and the
                // wallpapers ride that same backup. Saying "fetches the database
                // first" here would be true of that run, but the database card
                // above is hidden, so it would read as a reference to nothing.
                NativeNote("The **Apply** button on the home page delivers the "
                    + "tweaks, and the wallpapers you picked go with them in one protective "
                    + "backup — it is a backup-mode run regardless of this page's setting. To "
                    + "apply the packs alone, with no backup, use **Apply via AirLift** above.")
            } else if selection.isActive {
                Text("Ready: \(selection.describe)").foregroundStyle(.tint)
                NativeNote("Delivered by the **Apply** button on the home page, "
                    + "together with the tweaks. It fetches the store's database from the "
                    + "device first, so that run takes one extra exchange. Reboot the device "
                    + "afterwards — the store is read at boot.")
            } else {
                NativeNote("Nothing selected yet. Whatever is picked here is "
                    + "delivered by the **Apply** button on the home page, together with the "
                    + "tweaks — one backup, one restore.")
            }
            if applyMode != .airlift {
                NativeNote("The database itself can be fetched on its own, from the "
                    + "card above — it is the one stage that can fail on its own terms (the "
                    + "device decides whether it will upload the container), so being able to "
                    + "run it, watch it and retry is worth its own button.")
            }
        }
    }

    private var statusText: String { status ?? "" }

    private func errorSection(_ message: String) -> some View {
        Section("Import failed") {
            NativeSafetyNote(message)
        }
    }

    // MARK: - Behaviour

    private func refreshDatabaseSummary() {
        // The cache is keyed by UDID (upstream does the same), but the page has
        // no UDID outside a run — so it shows the newest database in the
        // directory rather than asking the device to render a label. There is
        // one device behind this app at a time.
        let directory = URL.documents.appendingPathComponent("PosterBoard", conformingTo: .data)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let candidates = names.filter { $0.hasSuffix(".sqlite3") }.sorted()
        guard let name = candidates.last else {
            databaseSummary = "none yet — an apply that adds a wallpaper fetches one"
            return
        }
        let url = directory.appendingPathComponent(name)
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes?[.size] as? Int64,
              let date = attributes?[.modificationDate] as? Date else {
            databaseSummary = name
            return
        }
        let when = DateFormatter.localizedString(from: date, dateStyle: .short, timeStyle: .short)
        databaseSummary = "\(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)), "
            + "fetched \(when)"
    }

    private func importPack(_ result: Result<URL, Error>) {
        switch result {
        case .failure(let error): pickError = error.localizedDescription
        case .success(let url):
            do {
                let existing = selection.tendies.reduce(0) { $0 + $1.descriptorCount }
                let pack = try PosterBoardImports.import(from: url)
                // Upstream's cap (`verify_tendie`): a container pack carries no
                // descriptor and so is never counted, which is also what its
                // code does.
                guard existing + pack.descriptorCount <= PosterBoardImports.descriptorLimit else {
                    PosterBoardImports.remove(pack)
                    throw GoldenNuggetError("\(pack.name) carries \(pack.descriptorCount) "
                        + "descriptor(s), which would take the selection to "
                        + "\(existing + pack.descriptorCount). PosterBoard's picker gets "
                        + "unusable past \(PosterBoardImports.descriptorLimit) — remove a pack "
                        + "first.")
                }
                selection.loadFromDisk()
                pickError = nil
                RunLog.shared.append("PosterBoard: imported \(pack.name) (\(pack.summary))")
                // The reference asks here, once, before the pack joins the
                // selection (`add_tendie` → `_ask_legacy_convert`), so the answer
                // is in place before any apply can read it.
                if let prompt = pack.legacyConvertPrompt(deviceVersion: identity.version) {
                    legacyPrompt = prompt
                }
            } catch {
                pickError = error.localizedDescription
                selection.loadFromDisk()
            }
        }
    }

    private func importMedia(_ result: Result<URL, Error>,
                             into directory: URL,
                             assign: (URL) -> Void) {
        switch result {
        case .failure(let error): pickError = error.localizedDescription
        case .success(let url):
            do {
                assign(try PosterBoard.store(url, in: directory))
                pickError = nil
            } catch {
                pickError = error.localizedDescription
            }
        }
    }

    private func fetchDatabase() {
        guard !running else { return }
        running = true
        runStarted = Date()
        RunLog.shared.clear()
        status = "Fetching the PosterBoard database…"
        statusTone = .accent
        Task {
            var text = ""
            var tone: GoldenTone = .primary
            do {
                try await GoldenNuggetEngine.shared.fetchPosterBoardDatabase()
                text = "Database fetched."
                tone = .success
            } catch let failure as TransportFailure where failure.isCancellation {
                text = "⏹ stopped by the user (\(failure.label))"
                tone = .warning
            } catch {
                text = "❌ \(error.localizedDescription)"
                tone = .error
            }
            await MainActor.run {
                running = false
                runStarted = nil
                status = text
                statusTone = tone
                refreshDatabaseSummary()
            }
        }
    }

    /// Run the AirLift injection for the packs selected on this page.
    ///
    /// Shaped like `fetchDatabase` on purpose: the page already owns a run slot,
    /// a run log and a status line, and a second apply path that kept its own
    /// would mean the user watching one of them not move.
    private func applyViaAirlift() {
        guard airliftAvailable else { return }
        running = true
        runStarted = Date()
        RunLog.shared.clear()
        status = "Injecting the packs over AirLift…"
        statusTone = .accent
        Task {
            var text = ""
            var tone: GoldenTone = .primary
            do {
                try await GoldenNuggetEngine.shared.applyPosterBoardViaAirlift(
                    selection, deviceVersion: identity.version)
                text = "Applied over AirLift. The device resprung — no backup was taken."
                tone = .success
            } catch let failure as TransportFailure where failure.isCancellation {
                text = "⏹ stopped by the user (\(failure.label))"
                tone = .warning
            } catch {
                text = "❌ \(error.localizedDescription)"
                tone = .error
            }
            await MainActor.run {
                running = false
                runStarted = nil
                status = text
                statusTone = tone
            }
        }
    }
}
