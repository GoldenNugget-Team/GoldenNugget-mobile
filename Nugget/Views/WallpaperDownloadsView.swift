import SwiftUI

/// The wallpaper downloader, as its own page.
///
/// The desktop build puts this in a dialog behind a button on the PosterBoard
/// page (`gui/dialogs/wallpaper_downloader.py`): a source dropdown, a category
/// dropdown, a search box and a grid of cards, and clicking a card downloads the
/// `.tendies` and imports it into PosterBoard immediately.  Every one of those
/// steps is here; the only difference is that a phone gets a page, because a
/// dialog over a navigation stack on a 6.1" screen is a sheet with a grid in it
/// and no way to keep the search box in view while scrolling.
///
/// What it does *not* do is deliver anything to the phone.  A download lands in
/// this app's container as an imported pack and appears on the PosterBoard page;
/// the write to the device is that page's Apply, exactly as a pack imported with
/// the document picker behaves.  `selection` is the PosterBoard page's own
/// selection object, so the pack is on screen the moment the user goes back.
struct WallpaperDownloadsView: View {
    /// The PosterBoard page's selection, owned by `RootView`.
    ///
    /// Passed in rather than reached for, because the import has to land in the
    /// same list the PosterBoard page reads — a download that only refreshed a
    /// local copy would show an empty pack list until something else reloaded it.
    @Binding var selection: PosterBoardSelection

    @State private var source: WallpaperSource = .all
    @State private var category: WallpaperCategory = .custom
    @State private var search = ""

    @State private var wallpapers: [Wallpaper] = []
    @State private var status = "Loading wallpapers…"
    @State private var statusTone: GoldenTone = .secondary
    @State private var error: String?
    @State private var loading = false
    /// The download in flight, by wallpaper id. One at a time, as in the
    /// reference: it frees the previews for the transfer and a second tap while
    /// a pack is coming down has nowhere to report itself.
    @State private var importing: String?

    /// The imported pack awaiting a Convert / Install-as-is answer.
    ///
    /// A pack that arrives by download is converted exactly like one that arrives
    /// through the PosterBoard page's picker — the reference asks on the way into
    /// the tendie list, wherever the file came from — so the same question is put
    /// here, through the same modifier.
    @State private var legacyPrompt: LegacyConvertPrompt?
    /// The device's iOS version, read once on appear for the same gate. Passed in
    /// nowhere else: this page only asks, and the apply decides.
    @State private var deviceVersion = ""

    /// What the grid shows: the catalog, filtered.
    ///
    /// The reference's `_apply_search`, verbatim in behaviour — a substring match
    /// against the name **or** the author, case-insensitively, and an empty box
    /// meaning "no filter" rather than "nothing matches".
    private var visible: [Wallpaper] {
        let term = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !term.isEmpty else { return wallpapers }
        return wallpapers.filter {
            $0.name.lowercased().contains(term) || $0.author.lowercased().contains(term)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                controlsCard
                statusCard
                if error != nil { errorCard }
                if visible.isEmpty && !loading {
                    NativeNote(wallpapers.isEmpty
                        ? "No wallpapers found. The catalogs are community-run and one of them may be down — the other source is still listed above."
                        : "Nothing matches “\(search.trimmingCharacters(in: .whitespacesAndNewlines))”.")
                } else {
                    grid
                }
                notesCard
                RunLogCard()
            }
            .padding(.vertical)
            .padding(.horizontal, 16)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("Download Wallpapers")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("Reload catalog")
                .disabled(loading || importing != nil)
            }
        }
        // Reloading on the pair, not on either alone: "All" ignores the category
        // and a single Cowabunga request carries it, so `(source, category)` is
        // the smallest id that can actually change the answer.
        .task(id: LoadKey(source: source, category: category)) {
            await load()
        }
        // Read once, for the import-time question. `PosterBoardView` reads the
        // identity the same way — a lockdown call, so not in `body`.
        .task {
            deviceVersion = await DeviceIdentity.read().version
        }
        .legacyConvertPrompt($legacyPrompt, answer: answerLegacyPrompt)
    }

    // MARK: - Controls

    private var controlsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Source", selection: $source) {
                ForEach(WallpaperSource.allCases) { source in
                    Text(source.label).tag(source)
                }
            }
            .pickerStyle(.segmented)

            // Shown only for Cowabunga, which is the only source that publishes
            // per-category catalogs. The reference keeps the dropdown on screen
            // and disables it; a disabled segmented control on a phone is a row
            // of dead pixels, so it is hidden instead.
            if !source.categories.isEmpty {
                Picker("Category", selection: $category) {
                    ForEach(source.categories) { category in
                        Text(category.label).tag(category)
                    }
                }
                .pickerStyle(.segmented)
            }

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search name or author", text: $search)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .nativeKeyboardDone()
                if !search.isEmpty {
                    Button {
                        search = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(uiColor: .secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 10))

            if loading || importing != nil {
                ProgressView()
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(14)
        .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private var statusCard: some View {
        Text(status)
            .font(.footnote)
            .foregroundStyle(statusTone.nativeColor)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
    }

    private var errorCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Something went wrong", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.bold())
                .foregroundStyle(GoldenTone.error.nativeColor)
            if let error {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Grid

    private var grid: some View {
        // Three columns on a phone rather than the reference's two: with the
        // preview now the wallpaper's own shape instead of a squat 150×200 box,
        // two columns means two wallpapers per screenful and a 100-entry catalog
        // takes a very long scroll. 108 is what three columns actually fit on the
        // narrowest phone this builds for, so the grid does not collapse back to
        // two wider ones.
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 108), spacing: 12)], spacing: 16) {
            ForEach(visible) { wallpaper in
                WallpaperCard(wallpaper: wallpaper,
                              busy: importing == wallpaper.id,
                              // The reference pauses every preview while a pack
                              // downloads (`_pause_previews`) so the transfer gets
                              // the CPU. Same here, and it is the one bit of
                              // shared state between the grid and the download.
                              paused: importing != nil,
                              onTap: { download(wallpaper) })
            }
        }
    }

    private var notesCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            NativeNote("A card downloads the wallpaper's `.tendies` pack and imports it "
                + "into this app. It shows up on the PosterBoard page straight away; "
                + "nothing is written to the device until you press Apply there.")
            NativeNote("Upstream caps a selection at \(PosterBoardImports.descriptorLimit) "
                + "descriptors, so an import past the cap is refused rather than "
                + "silently dropped. Each pack is copied into this app — removing it on "
                + "the PosterBoard page removes the copy, not the original file.")
            NativeNote("Catalogs are cached for \(Int(WallpaperCatalog.catalogTTL / 60)) "
                + "minutes; the reload button throws the cache away and asks again. "
                + "Previews are cached until iOS reclaims them.")
        }
    }

    // MARK: - Work

    private func load() async {
        loading = true
        error = nil
        status = "Loading wallpapers…"
        statusTone = .secondary
        let result = await WallpaperCatalog.load(source: source, category: category)
        wallpapers = result.wallpapers
        loading = false

        if result.wallpapers.isEmpty {
            status = result.failures.isEmpty ? "No wallpapers found" : "Failed to load wallpapers"
            statusTone = result.failures.isEmpty ? .secondary : .error
        } else {
            status = "\(result.wallpapers.count) wallpapers"
                + (result.failures.isEmpty ? "" : " (\(result.failures.joined(separator: "; ")))")
            statusTone = result.failures.isEmpty ? .secondary : .warning
        }
        // A source that failed while another answered is worth a line in the log
        // as well as in the status: the status is overwritten by the next action,
        // and the log is what the user can scroll back through.
        for failure in result.failures { RunLog.shared.append("Wallpapers: \(failure)") }
        RunLog.shared.append("Wallpapers: \(result.wallpapers.count) from "
            + "\(source.label)\(result.fromCache ? " (cached)" : "")")
    }

    /// Throw the cached catalogs away and ask the network — the toolbar button.
    private func reload() {
        for (requestSource, requestCategory) in source.requests {
            let category = requestCategory ?? (source == .cowabunga ? self.category : nil)
            try? FileManager.default.removeItem(
                at: WallpaperCatalog.catalogCacheURL(source: requestSource, category: category))
        }
        Task { await load() }
    }

    /// Download a pack and import it, in the reference's order: the transfer
    /// first, then the import, then the pack list refresh.
    private func download(_ wallpaper: Wallpaper) {
        guard importing == nil else { return }
        importing = wallpaper.id
        error = nil
        status = "Downloading \(wallpaper.name)…"
        statusTone = .secondary

        Task {
            defer { importing = nil }
            let file: URL
            do {
                file = try await WallpaperCatalog.download(wallpaper)
            } catch {
                fail("\(wallpaper.name) could not be downloaded: \(error.localizedDescription)")
                return
            }
            do {
                let existing = selection.tendies.reduce(0) { $0 + $1.descriptorCount }
                let pack = try PosterBoardImports.import(from: file)
                guard existing + pack.descriptorCount <= PosterBoardImports.descriptorLimit else {
                    PosterBoardImports.remove(pack)
                    throw GoldenNuggetError("\(pack.name) carries \(pack.descriptorCount) "
                        + "descriptor(s), which would take the selection to "
                        + "\(existing + pack.descriptorCount). PosterBoard's picker gets "
                        + "unusable past \(PosterBoardImports.descriptorLimit) — remove a pack "
                        + "on the PosterBoard page first.")
                }
                selection.loadFromDisk()
                status = "Imported \(wallpaper.name)"
                statusTone = .success
                RunLog.shared.append("Wallpapers: imported \(pack.name) (\(pack.summary)) "
                    + "from \(wallpaper.sourceLabel)")
                // Same question as on the PosterBoard page: the reference asks on
                // the way into the tendie list, not per import route.
                if let prompt = pack.legacyConvertPrompt(deviceVersion: deviceVersion) {
                    legacyPrompt = prompt
                }
            } catch {
                fail("Could not import \(wallpaper.name): \(error.localizedDescription)")
            }
            // The copy in `PosterBoardImports` is the one that is kept; this is
            // the transfer's scratch file, in the temporary directory.
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func fail(_ message: String) {
        error = message
        status = "Import failed"
        statusTone = .error
        RunLog.shared.append("Wallpapers: \(message)")
    }

    /// Store the Convert / Install-as-is answer for a downloaded pack.
    ///
    /// `settingAutoConvert` persists it, so the PosterBoard page's apply reads it
    /// without this page and the selection only has to be refreshed for the pack
    /// list to show.
    private func answerLegacyPrompt(_ prompt: LegacyConvertPrompt, _ convert: Bool) {
        legacyPrompt = nil
        _ = prompt.pack.settingAutoConvert(convert)
        selection.loadFromDisk()
        RunLog.shared.append(convert
            ? "Wallpapers: \(prompt.pack.name) will be converted to the modern format on Apply "
                + "(legacy: \(prompt.families.joined(separator: ", ")))."
            : "Wallpapers: \(prompt.pack.name) stays in its original legacy format "
                + "(\(prompt.families.joined(separator: ", "))).")
    }
}

/// The pair a catalog request is keyed by.
private struct LoadKey: Hashable {
    let source: WallpaperSource
    let category: WallpaperCategory
}

/// One catalog entry: preview, name, byline. Tappable, and busy while its own
/// pack is coming down.
///
/// A `Button` with `.plain` style rather than a `NavigationLink`: the tap *is* the
/// download, and a link would push a detail page that has nothing to show.
private struct WallpaperCard: View {
    let wallpaper: Wallpaper
    let busy: Bool
    let paused: Bool
    let onTap: () -> Void

    @State private var frames: WallpaperFrames?
    @State private var failed = false
    /// The preview's own size, once it is known, so the box can be the
    /// wallpaper's shape instead of a guess.
    @State private var previewSize: CGSize?

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 6) {
                preview
                Text(wallpaper.name)
                    .font(.caption.bold())
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(height: 32, alignment: .top)
                Text(wallpaper.byline)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .task(id: wallpaper.previewURL) { await loadPreview() }
    }

    /// A phone wallpaper's shape — what almost every entry in both catalogs is,
    /// and what the box falls back to before the bytes arrive.
    private static let phonePreviewRatio: CGFloat = 844.0 / 390.0

    private var previewRatio: CGFloat {
        guard let size = previewSize, size.width > 0, size.height > 0 else {
            return Self.phonePreviewRatio
        }
        // Clamped, because one catalog entry with a panorama's proportions must not
        // make a card a thousand points tall. A landscape wallpaper then reads as a
        // short wide strip, which is what it is.
        return min(max(size.height / size.width, 0.35), 2.4)
    }

    private var preview: some View {
        ZStack {
            Color(uiColor: .secondarySystemGroupedBackground)
            if let frames {
                if frames.isAnimated, !paused {
                    TimelineView(.animation) { context in
                        image(frames.frame(at: context.date.timeIntervalSinceReferenceDate))
                    }
                } else {
                    image(frames.images.first)
                }
            } else if failed {
                Image(systemName: "photo.badge.exclamationmark")
                    .font(.title)
                    .foregroundStyle(.tertiary)
            } else {
                ProgressView().scaleEffect(0.8)
            }
            if busy {
                Color.black.opacity(0.35)
                ProgressView().tint(.white)
            }
        }
        // The reference draws the preview into a fixed 150×200 box with
        // `Qt.KeepAspectRatio`, so a wallpaper shows whole inside it with empty
        // bands above and below — a card two-thirds as wide as it is tall, holding
        // a tall wallpaper. This sizes the box to the wallpaper instead, so the
        // preview fills the card's width and shows the whole wallpaper with
        // nothing letterboxed: the interesting half of a wallpaper is its top and
        // bottom, and cropping those is what made these cards unreadable as
        // previews.
        .aspectRatio(1 / previewRatio, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func image(_ image: UIImage?) -> some View {
        if let image {
            Image(uiImage: image)
                .resizable()
                // Fit, not fill: the box is already the image's shape, so the two
                // agree — and where they do not (an animation whose frames differ
                // in size) fit keeps the difference visible instead of cropping it.
                .scaledToFit()
        }
    }

    private func loadPreview() async {
        guard frames == nil, !failed, let url = wallpaper.previewURL else { return }
        guard let data = await WallpaperCatalog.preview(for: url) else {
            failed = true
            return
        }
        frames = await WallpaperFrameDecoder.decode(data)
        if frames == nil { failed = true }
        // Read off the first frame rather than decoding twice: the frames are
        // already in memory and their size is the card's shape.
        if let first = frames?.images.first {
            previewSize = CGSize(width: first.size.width * first.scale,
                                 height: first.size.height * first.scale)
        }
    }
}
