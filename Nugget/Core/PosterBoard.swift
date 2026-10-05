import Foundation

/// The PosterBoard feature, ported from GoldenNugget's `PosterboardTweak`
/// (`src/tweaks/posterboard/posterboard_tweak.py`) and its config database
/// (`pb_config_manager.py`).
///
/// PosterBoard is the wallpaper subsystem behind the Lock Screen and Home
/// Screen.  Wallpapers are not preferences: each one is a **descriptor
/// directory** under
///
///     <app container>/Library/Application Support/PRBPosterExtensionDataStore/<v>/
///         Extensions/<provider extension>/configurations/<poster UUID>/…
///
/// plus a row in the store's own `PBFPosterExtensionDataStoreSQLiteDatabase
/// .sqlite3`, which is what makes it appear in the picker at all.  So an apply
/// is three things at once — the descriptor's files, the store's database, and
/// (optionally) an empty preview-queue database for a reset — and the database
/// half needs the **device's own** store as its starting point.  That is what
/// `PosterBoardBackup` fetches and `PosterBoardStore` stitches.
///
/// Everything this app delivers lands in `AppDomain-com.apple.PosterBoard`,
/// the one domain class this port already had production evidence for (the
/// app-container PoC and the Lock Screen footnote's sibling rows), so the
/// delivery channel is the existing one: `TweakPayload` → `TweakInjector`.
///
/// **Deliberate divergences from the reference**, all of them logged:
///
///   * Tendies are unpacked into a scratch directory named after the pack
///     rather than after a random UUID, so a run's payload order is
///     reproducible.  Upstream walks `os.listdir` over UUID-named directories,
///     i.e. in filesystem order.
///   * The three `configconversion` plists are injected in **name** order;
///     upstream appends `os.listdir` order, which is the filesystem's.
///   * A descriptor pack with no descriptor and no container is refused at
///     import time instead of producing an apply with nothing in it.
enum PosterBoard {
    /// The bundle whose container every payload lands in.  `recursive_add`
    /// hardcodes `AppDomain-<bundle_id>` for every domain it emits.
    static let bundleID = "com.apple.PosterBoard"
    static let domain = "AppDomain-\(bundleID)"

    /// The provider extensions a descriptor can belong to.  `recursive_add`
    /// picks one from the descriptor directory's name and its parent:
    ///
    ///   * a parent starting `com.apple.` (a container dump) names the
    ///     extension itself;
    ///   * `video` or `photos` in the descriptor's own name → Photos;
    ///   * `mercury` → MercuryPoster;
    ///   * anything else → the Collections provider.
    static let mercuryExtension = "com.apple.MercuryPoster"
    static let photosExtension = "com.apple.PhotosUIPrivate.PhotosPosterProvider"
    static let collectionsExtension = "com.apple.WallpaperKit.CollectionsPoster"

    /// The store directory.  Its numeric suffix is a **structure version**
    /// (61, 62, …) that Apple bumps between releases; the reference learns it
    /// from the fetched database's own path and falls back to 61.
    static let storeDirectoryName = "PRBPosterExtensionDataStore"
    static let storeRoot = "/Library/Application Support/\(storeDirectoryName)"
    static let fallbackStructureVersion = 61

    /// The store's database, by the name the reference matches on.  The store
    /// directory is matched by **file name** rather than path because iOS 27
    /// uploads the container under the raw file tree (`/.b/<n>/Containers/…`)
    /// where the store directory's own name does not always appear.
    static let databaseFileName = "PBFPosterExtensionDataStoreSQLiteDatabase.sqlite3"

    /// Where a reset leaves the store's preferences.
    static let preferencesPath =
        "/Library/Preferences/com.apple.PosterBoard.unprotectedUserDefaults.plist"

    /// The band the reference draws random descriptor identifiers from
    /// (`randint(9999, 99999)`).
    static let identifierRange = 9_999...99_999

    /// Where a PosterBoard apply's scratch files go: extraction dirs, generated
    /// video frames, the staged database.  Wiped at the start of every apply.
    static var workDirectory: URL {
        URL.documents.appendingPathComponent("PosterBoard/Work", conformingTo: .data)
    }
}

/// One thing the reset dialog can clear.
///
/// The reference's dialog offers exactly three, and its `apply_tweak` has a
/// fourth branch — `else: file_paths.append("")`, i.e. "reset every extension"
/// — that no UI path can reach.  It is not exposed here: a branch nothing can
/// select is not a feature, and reproducing it would mean offering a mode the
/// reference's own users have never run.
enum PosterBoardResetMode: String, CaseIterable, Identifiable, Hashable {
    case collections = "Collections"
    case suggestedPhotos = "Suggested Photos"
    case galleryCache = "Gallery Cache"

    var id: String { rawValue }

    /// What the reference's dialog says this clears, in its words.
    var detail: String {
        switch self {
        case .collections:
            return "Clears the Collections and MercuryPoster descriptor folders."
        case .suggestedPhotos:
            return "Clears the Photos poster provider's descriptor folder."
        case .galleryCache:
            return "Clears the gallery cache."
        }
    }

    /// The store-relative paths this mode zeroes, from `apply_tweak`.
    func paths(structureVersion: Int) -> [String] {
        switch self {
        case .collections:
            return ["/\(structureVersion)/Extensions/\(PosterBoard.collectionsExtension)/descriptors",
                    "/\(structureVersion)/Extensions/\(PosterBoard.mercuryExtension)/descriptors"]
        case .suggestedPhotos:
            return ["/\(structureVersion)/Extensions/\(PosterBoard.photosExtension)/descriptors"]
        case .galleryCache:
            return ["/\(structureVersion)/GalleryCache"]
        }
    }
}

/// A wallpaper this run is adding: the reference's `PBConfigItem`.
///
/// `uuid` is the **randomized** descriptor directory name the builder invented,
/// and it is the same string that goes into the store's `poster` row — the two
/// have to agree or the picker shows a wallpaper whose files it cannot find.
struct PosterBoardConfigItem: Equatable {
    let uuid: String
    let extensionID: String
    /// Whether this wallpaper becomes the selected one.  The reference sets it
    /// for every staged item, so the last one added wins.
    let setSelected: Bool
}

/// What the PosterBoard page has assembled, carried by the one apply.
///
/// The video's **options live here and not inside `PosterBoardVideoPlan`** on purpose:
/// the plan only exists once a video has been picked, while the switches have to be
/// editable before that.  `plan` is then the single place the two are combined, so the
/// page that sets "Loop" and the apply that reads it cannot disagree.
///
/// Owned by `RootView`, like `TweakSelection`: the page edits it, and the plain
/// `Apply` on the home page is what delivers it — a `NavigationSplitView` destroys the
/// detail view on every sidebar selection, so as page state the wallpapers would be gone
/// by the time the user reached the button.
struct PosterBoardSelection {
    var tendies: [PosterBoardTendie] = []
    /// The picked video and its freeze frame, as files in this app's container.
    var video: URL?
    var thumbnail: URL?

    /// The four options the reference keeps on the tweak object.
    var loop = true
    var reverse = false
    var foreground = false
    var calculationMode: PosterBoardCalculationMode = .linear

    /// A reset is a one-shot instruction, so it is deliberately **not** persisted: a
    /// "Full Reset" that survived a launch would be a loaded gun. Upstream holds it in
    /// memory for the same reason.
    var resetModes: Set<PosterBoardResetMode> = []
    var fullReset = false

    /// The reference's `pref_manager.auto_refresh_posterboard` — **the one option that
    /// is a preference rather than a per-run choice**, so it is the one that persists.
    /// A computed property rather than a stored one because a struct cannot write
    /// itself back on assignment, and this is the only field that needs to.
    var autoRefresh: Bool {
        get { PosterBoardPreferences.autoRefresh }
        set { PosterBoardPreferences.autoRefresh = newValue }
    }

    /// Whether the apply has anything to do — the reference's `uses_domains`.
    var isActive: Bool {
        fullReset || !resetModes.isEmpty || !tendies.isEmpty || video != nil
    }

    /// The video stage's input, or nil when no video was picked.
    var plan: PosterBoardVideoPlan? {
        guard let video else { return nil }
        return PosterBoardVideoPlan(video: video,
                                    thumbnail: thumbnail,
                                    loop: loop,
                                    reverse: reverse,
                                    foreground: foreground,
                                    calculationMode: calculationMode)
    }

    /// The reference's own summary of what an apply will carry, for the log.
    var describe: String {
        if fullReset { return "full reset" }
        if !resetModes.isEmpty {
            return "reset: " + resetModes.map(\.rawValue).sorted().joined(separator: ", ")
        }
        var parts: [String] = []
        if !tendies.isEmpty { parts.append("\(tendies.count) pack(s)") }
        if let video { parts.append("video \(video.lastPathComponent)") }
        return parts.isEmpty ? "nothing" : parts.joined(separator: ", ")
    }

    /// Re-read the inputs that live on disk: the imported packs and the two picked
    /// files.  The options are left alone — they are the user's, not the filesystem's —
    /// which is also what makes this safe to call on every appearance.
    mutating func loadFromDisk() {
        tendies = PosterBoardImports.load()
        video = PosterBoard.storedFile(in: PosterBoard.videoDirectory)
        thumbnail = PosterBoard.storedFile(in: PosterBoard.thumbnailDirectory)
    }
}

/// The one PosterBoard setting that survives a launch.
///
/// Upstream splits the same way: every option lives on the tweak object and only
/// `auto_refresh_posterboard` in `preference_manager`.
enum PosterBoardPreferences {
    static let autoRefreshKey = "PosterBoardAutoRefresh"
    static let posterTypesKey = "PosterBoardTendiePosterTypes"
    static let autoConvertLegacyKey = "PosterBoardAutoConvertLegacy"
    static let autoConvertAnswersKey = "PosterBoardAutoConvertAnswers"

    static var autoRefresh: Bool {
        get { UserDefaults.standard.object(forKey: autoRefreshKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: autoRefreshKey) }
    }

    /// `PosterboardTweak.auto_convert_legacy`, on by default.
    ///
    /// When off, an imported pre-iOS 27 pack is pushed exactly as it shipped and
    /// the import prompt never appears — which is what an iOS 26 device wants
    /// anyway, since it reads legacy packages natively.
    static var autoConvertLegacy: Bool {
        get { UserDefaults.standard.object(forKey: autoConvertLegacyKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: autoConvertLegacyKey) }
    }

    /// The user's Convert / Install-as-is answer per pack, by file name.
    ///
    /// A pack is re-read from its archive on every launch, so the answer cannot
    /// live on the pack the way it lives on upstream's `TendieFile.auto_convert`.
    /// Missing means "never asked", which converts — the same default upstream
    /// gets from `auto_convert is not False`, and the reason a pack imported from
    /// the CLI or from a version predating the prompt still converts.
    static var autoConvertAnswers: [String: Bool] {
        get {
            let raw = UserDefaults.standard.dictionary(forKey: autoConvertAnswersKey) as? [String: Bool] ?? [:]
            return raw
        }
        set {
            UserDefaults.standard.set(newValue, forKey: autoConvertAnswersKey)
        }
    }

    /// Which PosterBoard extension each imported pack is injected under, by file
    /// name. Same reason as above: a `.tendies` pack is re-read from its archive
    /// on every launch, so a choice the user made about it has to be kept
    /// somewhere the archive cannot overwrite.
    static var posterTypes: [String: PosterBoardPosterType] {
        get {
            let raw = UserDefaults.standard.dictionary(forKey: posterTypesKey) as? [String: String] ?? [:]
            return raw.compactMapValues(PosterBoardPosterType.init(rawValue:))
        }
        set {
            UserDefaults.standard.set(newValue.mapValues(\.rawValue), forKey: posterTypesKey)
        }
    }
}

// MARK: - The compile step

extension PosterBoard {
    /// `PosterboardTweak.apply_tweak`, as payloads.
    ///
    /// Runs **before the device is touched**, like `TweakCompiler.compile`: an
    /// empty selection or a missing database fails without paying for a backup
    /// first.
    ///
    /// - Parameters:
    ///   - structureVersion: the store directory's version, from the fetched
    ///     database's own path.  The reference falls back to 61 when it has no
    ///     database — which only ever happens on the reset paths, since the
    ///     applied paths need one.
    ///   - database: the device's PosterBoard sqlite, already fetched.  Required
    ///     unless the selection is a reset.
    ///   - deviceVersion: the device's `ProductVersion`; the reset and refresh
    ///     preference plists grow two extra keys at 26.4 and the store layout
    ///     moved with them.
    ///   - workingDirectory: scratch space, wiped by the caller.  Video frames
    ///     and extracted packs are written here and referenced by path — they
    ///     are far too big to hold as `Data`.
    static func compile(
        selection: PosterBoardSelection,
        structureVersion: Int,
        database: URL?,
        deviceVersion: String,
        workingDirectory: URL,
        log: @escaping @Sendable (String) -> Void
    ) async throws -> [TweakPayload] {
        var payloads: [TweakPayload] = []

        // The reference reads the structure version off the config manager and
        // falls back to 61 only when nothing was learned.  A store directory is
        // not guessed at here: every path below either came from the database's
        // own path or from the reset default.
        let version = structureVersion > 0 ? structureVersion : fallbackStructureVersion

        // 1. Full reset: wipe the store's subtrees, lay down an empty
        //    schema-only database and ship 0-byte WAL companions.
        if selection.fullReset {
            payloads.append(contentsOf: try fullResetPayloads(structureVersion: version,
                                                              workingDirectory: workingDirectory,
                                                              deviceVersion: deviceVersion,
                                                              log: log))
            return payloads
        }

        // 2. Selective reset: 0-byte zeroing of the chosen subtrees, no database.
        if !selection.resetModes.isEmpty {
            for mode in selection.resetModes.sorted(by: { $0.rawValue < $1.rawValue }) {
                for path in mode.paths(structureVersion: version) {
                    log("  → reset \(mode.rawValue): \(storeRoot)\(path)")
                    payloads.append(TweakPayload(domain: domain,
                                                 relativePath: storeRoot + path,
                                                 contents: Data()))
                }
            }
            return payloads
        }

        // 3. Nothing but resets requested and none selected: the reference
        //    returns here too (`len(tendies) == 0 and len(templates) == 0 and
        //    videoFile == None`).
        guard !selection.tendies.isEmpty || selection.video != nil else {
            log("PosterBoard: nothing selected.")
            return []
        }

        let fm = FileManager.default
        try? fm.removeItem(at: workingDirectory)
        try fm.createDirectory(at: workingDirectory, withIntermediateDirectories: true)

        // 4. Generated video first, then the packs — the reference's order, and
        //    it matters: a live-photo pack's descriptor is written by the video
        //    step, and both are then found by the single walk below.
        if let plan = selection.plan {
            try await PosterBoardVideo.generate(plan: plan,
                                                outputDirectory: workingDirectory,
                                                log: log)
        }
        for (index, tendie) in selection.tendies.enumerated() {
            // Deterministic, not `uuid4()`: see this type's divergence note.
            let destination = workingDirectory.appendingPathComponent(
                String(format: "%03d-%@", index, sanitised(tendie.name)), conformingTo: .data)
            log("  → unpacking \(tendie.name) (\(tendie.summary))")
            try tendie.extract(to: destination)
            // Each pack is converted in its own folder so the per-pack
            // "convert / install as is" answer is honoured
            // (`PosterboardTweak.apply_tweak`'s `extracted: list[tuple[str, bool]]`).
            if shouldConvertLegacy(pack: tendie, deviceVersion: deviceVersion, log: log) {
                convertLegacyPack(tendie.name, at: destination, log: log)
            }
        }

        // 5. Walk what is on disk into payloads, staging one config item per
        //    added descriptor on the way.
        var builder = PosterBoardBuilder(structureVersion: version, log: log)
        try builder.walk(currentPath: workingDirectory, restorePath: "", isAdding: false)
        payloads.append(contentsOf: builder.payloads)

        // 6. The database.  A wallpaper that is not in it does not exist.
        guard let database else {
            throw GoldenNuggetError(
                "PosterBoard has no database to add these wallpapers to. Fetch the device's "
                + "PosterBoard database first (the page's database card) — the store's "
                + "database is what makes a wallpaper appear in the picker, and it cannot be "
                + "synthesised: it carries the device's own row set.")
        }
        let staged = try PosterBoardStore.stitch(database: database,
                                                 items: builder.configs,
                                                 workingDirectory: workingDirectory)
        payloads.append(TweakPayload(domain: domain,
                                     relativePath: storePath(version) + "/" + databaseFileName,
                                     source: staged))
        // The store runs in WAL mode. Replacing only the main file while a stale
        // -wal/-shm stays behind makes the next open replay old frames over the
        // fresh database — "database disk image is malformed", or random
        // wallpaper breakage. Ship 0-byte companions so it starts clean.
        for suffix in ["-wal", "-shm"] {
            payloads.append(TweakPayload(domain: domain,
                                         relativePath: storePath(version) + "/" + databaseFileName + suffix,
                                         contents: Data()))
        }

        // 7. Force refresh: upstream's `auto_refresh_posterboard`, on by default.
        if selection.autoRefresh {
            payloads.append(TweakPayload(domain: domain,
                                         relativePath: preferencesPath,
                                         contents: try refreshPreferences(deviceVersion: deviceVersion)))
        }

        log("PosterBoard: \(payloads.count) file(s) — \(builder.configs.count) wallpaper(s) "
            + "staged into the store database (\(builder.payloads.count) from disk)")
        return payloads
    }

    /// `/Library/Application Support/PRBPosterExtensionDataStore/<v>`.
    static func storePath(_ structureVersion: Int) -> String {
        "\(storeRoot)/\(structureVersion)"
    }

    /// A pack's name, made safe for a directory name.
    static func sanitised(_ name: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        let mapped = name.map { allowed.contains($0) ? $0 : "_" }
        let trimmed = String(mapped).prefix(60)
        return trimmed.isEmpty ? UUID().uuidString : String(trimmed)
    }

    // MARK: - The three preference writes

    /// `apply_tweak`'s full-reset branch, including the empty database.
    private static func fullResetPayloads(structureVersion: Int,
                                          workingDirectory: URL,
                                          deviceVersion: String,
                                          log: @escaping @Sendable (String) -> Void) throws -> [TweakPayload] {
        var payloads: [TweakPayload] = []
        // Zero-byte files, not deletions: the reference's own comment is the
        // reason — they keep the /<v> folder a real directory, so the database
        // injection below lands cleanly.
        for subtree in ["/Extensions", "/GalleryCache", "/Backups"] {
            log("  → full reset: zeroing \(storeRoot)/\(structureVersion)\(subtree)")
            payloads.append(TweakPayload(domain: domain,
                                         relativePath: "\(storeRoot)/\(structureVersion)\(subtree)",
                                         contents: Data()))
        }
        let empty = workingDirectory.appendingPathComponent("empty_posterboard.sqlite3")
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        try PosterBoardStore.createEmptyDatabase(at: empty)
        let databasePath = storePath(structureVersion) + "/" + databaseFileName
        payloads.append(TweakPayload(domain: domain, relativePath: databasePath, source: empty))
        for suffix in ["-wal", "-shm"] {
            payloads.append(TweakPayload(domain: domain,
                                         relativePath: databasePath + suffix,
                                         contents: Data()))
        }
        payloads.append(TweakPayload(domain: domain,
                                     relativePath: preferencesPath,
                                     contents: try refreshPreferences(deviceVersion: deviceVersion)))
        return payloads
    }

    /// `PBF_LOCALE_DID_CHANGE` / `PBF_RESET_FILE_PROTECTIONS`, plus the two
    /// migration lists 26.4 added.
    ///
    /// Binary, matching `plistlib.dumps(plist, fmt=FMT_BINARY)` — unlike the
    /// per-wallpaper plists, which the reference writes as XML.
    static func refreshPreferences(deviceVersion: String) throws -> Data {
        // Upstream compares with `packaging.version.Version`, which *raises* on
        // an empty or malformed string — so refusing here is the same verdict,
        // not a stricter one.  Guessing "not 26.4" would silently write a
        // smaller plist than a 26.4+ device needs.
        guard let atLeast264 = compareVersion(deviceVersion, "26.4") else {
            throw GoldenNuggetError("PosterBoard needs the device's iOS version to decide which "
                + "reset preferences to write (26.4 added two migration lists), and "
                + "\"\(deviceVersion)\" is not a version. Read the device identity and try again.")
        }
        var plist: [String: Any] = [
            "PBF_LOCALE_DID_CHANGE": false,
            "PBF_RESET_FILE_PROTECTIONS": true,
        ]
        if atLeast264 >= 0 {
            plist["PersistedPosterContainerBundleIdentifiers"] = [
                "com.apple.Posters.CollectionsPosterApp",
            ]
            plist["CompletedPosterBundleIdentifierMigrations"] = [
                "com.apple.Posters.UnityPosterApp.ExtragalacticPoster",
                "com.apple.Posters.WeatherPosterApp.WeatherPoster",
                "com.apple.Posters.UnityPosterApp.Unity2025Poster",
                "com.apple.Posters.UnityPosterApp.UnityPosterExtension",
                "com.apple.Posters.UnityPosterApp.RhizomePoster",
                "com.apple.Posters.KaleidoscopePosterApp.KaleidoscopePoster",
            ]
        }
        return try PropertyListSerialization.data(fromPropertyList: plist,
                                                  format: .binary, options: 0)
    }

    /// `Version(a) <=> Version(b)`, or nil when either side is not a version.
    ///
    /// Numeric components only, compared component by component with a missing
    /// component as 0 (`26` == `26.0`): that is `packaging.version.Version` for
    /// every value a `ProductVersion` or a `min_version` field carries.
    static func compareVersion(_ lhs: String, _ rhs: String) -> Int? {
        func components(_ value: String) -> [Int]? {
            let parts = value.trimmingCharacters(in: .whitespaces)
                .split(separator: ".", omittingEmptySubsequences: false)
            guard !parts.isEmpty else { return nil }
            var numbers: [Int] = []
            for part in parts {
                guard let number = Int(part), number >= 0 else { return nil }
                numbers.append(number)
            }
            return numbers
        }
        guard let left = components(lhs), let right = components(rhs) else { return nil }
        for index in 0..<max(left.count, right.count) {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            if l != r { return l < r ? -1 : 1 }
        }
        return 0
    }

    /// Whether an extracted pack gets the legacy conversion, or is pushed as-is.
    ///
    /// Three gates, in this order:
    ///
    ///   - `PosterBoardPreferences.autoConvertLegacy` — upstream's
    ///     `auto_convert_legacy` setting, on by default.
    ///   - `pack.autoConvert != false` — the per-pack "Convert / Install as is"
    ///     answer. `nil` means "never asked" and converts.
    ///   - device major version `>= 27`, the cutoff that decides whether a package
    ///     is legacy at all.
    ///
    /// The device check is the one deliberate divergence from the reference.
    /// `PosterboardTweak.apply_tweak` gates only on the two booleans and converts
    /// a never-asked pack regardless of version, while `_legacy_convert_supported`
    /// gates the prompt and its own comment says "iOS 26 reads legacy packages as
    /// they are: nothing is converted there and the prompt never appears". The
    /// code does not do what the comment says. Honouring the comment matters more
    /// than the letter here: a converted package is Clownfish-shaped, and Clownfish
    /// is what 27 reads natively — rewriting an iOS 26 device's wallpaper into it
    /// is the exact damage the gate exists to prevent. A 26 device that somehow
    /// does get a modern pack pushes it unchanged and reads it fine.
    static func shouldConvertLegacy(pack: PosterBoardTendie, deviceVersion: String,
                                    log: @escaping @Sendable (String) -> Void) -> Bool {
        guard PosterBoardPreferences.autoConvertLegacy else { return false }
        guard pack.autoConvert != false else { return false }
        guard let atLeast27 = compareVersion(deviceVersion, "27") else {
            log("  → skipping legacy conversion of \(pack.name): PosterBoard needs the device's "
                + "iOS version to tell a legacy wallpaper from a modern one (27 changed the "
                + "format), and \"\(deviceVersion)\" is not a version. Read the device identity "
                + "and try again.")
            return false
        }
        return atLeast27 >= 0
    }

    /// The apply-time conversion for one extracted pack: `convert_tree` then
    /// `rename_descriptors_to_skeleton`, with the reference's per-descriptor
    /// reporting.
    ///
    /// Not `throws`. Upstream wraps each descriptor in `except Exception` and
    /// prints the traceback, so one malformed wallpaper does not cost the user the
    /// rest of the pack — here it does not cost them the pack at all, and the pack
    /// still goes in as-is for whatever did convert. Same trade, quieter failure:
    /// the log is already on screen next to the apply button that started this.
    static func convertLegacyPack(_ name: String, at destination: URL,
                                  log: @escaping @Sendable (String) -> Void) {
        do {
            let converted = try PosterBoardConverter.convertTree(
                destination, screen: nil,
                maxMultiplier: PosterBoardConverter.defaultMaxAdaptiveTimeMultiplier, dryRun: false)
            for entry in converted where !entry.isDryRun {
                log("    ↳ \(entry.convertedLine)")
            }
            for entry in PosterBoardConverter.renameDescriptorsToSkeleton(destination) {
                log("    ↳ \(entry.renamedLine)")
            }
            if converted.isEmpty {
                log("    ↳ \(name): nothing legacy to convert")
            }
        } catch {
            log("    ↳ \(name): conversion failed, installing as-is — \(error)")
        }
    }
}

// MARK: - The walk (`recursive_add`)

/// `PosterboardTweak.recursive_add`, ported.
///
/// Two modes, and the asymmetry between them is the whole algorithm:
///
///   * **not adding** — the tree is searched for the two things that name a
///     destination: a `container/` directory (a full data-store snapshot, walked
///     from the store root) and any directory whose name contains `descriptor`
///     (a wallpaper, routed into the provider extension's `configurations`
///     directory).  Everything else is descended into unchanged.
///   * **adding** — this is *inside* a descriptor, and every directory directly
///     under the `descriptors/` marker is renamed to a fresh UUID and registered
///     as a wallpaper.  The rename is **one level deep on purpose**: the
///     recursive call below does not pass `randomizeUUID` on, so `versions/`,
///     `0/`, `contents/` keep the names the device's own store uses.  Only the
///     descriptor's own directory name and the numeric ids inside it are the
///     builder's to invent.
private struct PosterBoardBuilder {
    let structureVersion: Int
    let log: @Sendable (String) -> Void
    var payloads: [TweakPayload] = []
    var configs: [PosterBoardConfigItem] = []

    /// The three plists every descriptor version directory gets, in name order
    /// (see `PosterBoard`'s divergence note).
    static var configFileNames: [String] { PosterBoardResources.configConversion.keys.sorted() }

    /// The descriptor's identity sidecar, `provider.descriptor.identifier` —
    /// the first of the three identity fields the walk keeps in step, and the
    /// one a third-party pack most often omits.
    static let descriptorIdentifierFile = "com.apple.posterkit.provider.descriptor.identifier"

    mutating func walk(currentPath: URL,
                       restorePath: String,
                       isAdding: Bool = false,
                       randomizeUUID: Bool = false,
                       randomizedID: Int? = nil) throws {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: currentPath.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return }

        let children = (try? fm.contentsOfDirectory(atPath: currentPath.path)) ?? []
        let ordered = children.sorted()
        // Upstream sizes this list off `os.listdir`, which — unlike the loop
        // below — does not filter dotfiles.  Kept identical so the ids a pack
        // gets are the same ones upstream would hand it.
        var orderedIDs: [Int] = []
        if isAdding, randomizeUUID,
           currentPath.path.contains("ordered-descriptor") {
            // PosterBoard orders wallpapers by id in *reverse*, so an
            // ordered-descriptor pack gets descending ids to come out in its
            // own order.
            let base = Int.random(in: PosterBoard.identifierRange)
            orderedIDs = (0..<children.count).map { base + $0 }.sorted(by: >)
        }
        var counter = 0

        for child in ordered {
            // Finder/archive junk only, and **not** "anything starting with a
            // dot": `.com.apple.posterkit.provider.contents.configurableOptions.plist`
            // is a legitimate descriptor plist (Apple hides it with a leading
            // dot) that carries `preferredRenderingConfiguration` — the poster
            // editor reads it for depth. Skipping every dotfile drops it from the
            // payload, and a descriptor that arrives without it has no depth
            // controls to offer.
            if child == "__MACOSX" || child == ".DS_Store" || child.hasPrefix("._") { continue }
            let childPath = currentPath.appendingPathComponent(child)

            if isAdding {
                var folderName = child
                var currentID = randomizedID
                if randomizeUUID {
                    if currentPath.path.contains("ordered-descriptor") {
                        folderName = UUID().uuidString.uppercased()
                        currentID = orderedIDs[counter]
                        counter += 1
                    } else {
                        folderName = UUID().uuidString.uppercased()
                        currentID = Int.random(in: PosterBoard.identifierRange)
                    }
                    // The reference reads the extension back out of the path it
                    // built — index 6 of
                    // `/<store>/<v>/Extensions/<ext>/configurations`.  Only
                    // reached at this level, which is the only level whose path
                    // has that shape.
                    let components = restorePath.components(separatedBy: "/")
                    guard components.count > 6 else {
                        throw GoldenNuggetError("PosterBoard: cannot read the provider "
                            + "extension out of \(restorePath) — the descriptor was routed "
                            + "to an unexpected place.")
                    }
                    configs.append(PosterBoardConfigItem(uuid: folderName,
                                                         extensionID: components[6],
                                                         setSelected: true))
                }

                let destination = joined(restorePath, folderName)
                var childIsDirectory: ObjCBool = false
                guard fm.fileExists(atPath: childPath.path, isDirectory: &childIsDirectory) else { continue }

                // Third-party .tendies usually ship **without** the
                // `provider.descriptor.identifier` sidecar. PosterKit then invents
                // one that disagrees with `contents.userInfo` / `Wallpaper.plist`,
                // and WallpaperKit traps building the view — so stamp it here, with
                // the same randomized id the other two identity fields carry. The
                // reference does this inside the `randomizeUUID` branch, i.e. only
                // at the one level whose directories are being renamed, and never
                // for Mercury (whose identifier is its own textual lookup key).
                if randomizeUUID, let currentID, childIsDirectory.boolValue,
                   !isMercury(restorePath),
                   !fm.fileExists(atPath: childPath
                       .appendingPathComponent(Self.descriptorIdentifierFile).path) {
                    payloads.append(TweakPayload(domain: PosterBoard.domain,
                                                 relativePath: joined(destination,
                                                                      Self.descriptorIdentifierFile),
                                                 contents: Data(String(currentID).utf8)))
                }

                if !childIsDirectory.boolValue {
                    if Self.configFileNames.contains(child) {
                        // The pack carries its own copy of a conversion plist;
                        // the bundled one from `PosterBoardResources` replaces it
                        // below, at the version directory.
                        continue
                    }
                    let rewritten = rewrittenContents(directory: currentPath,
                                                      fileName: child,
                                                      identifier: currentID,
                                                      restorePath: restorePath)
                    switch rewritten {
                    case .none:
                        payloads.append(TweakPayload(domain: PosterBoard.domain,
                                                     relativePath: destination,
                                                     source: childPath))
                    case .bytes(let data):
                        payloads.append(TweakPayload(domain: PosterBoard.domain,
                                                     relativePath: destination,
                                                     contents: data))
                    case .unreadable(let error):
                        // The reference catches `IOError` and moves on. Kept,
                        // but said out loud: a silently missing descriptor file
                        // is a wallpaper that half-exists.
                        log("  ⚠️ skipping \(destination): \(error)")
                    }
                } else {
                    // Every descriptor version directory gets the three
                    // conversion plists the reference replaces them with.
                    if currentPath.lastPathComponent == "versions",
                       currentPath.path.contains("descriptor") {
                        for fileName in Self.configFileNames {
                            guard let data = PosterBoardResources.configConversion[fileName] else { continue }
                            payloads.append(TweakPayload(domain: PosterBoard.domain,
                                                         relativePath: joined(destination, fileName),
                                                         contents: data))
                        }
                    }
                    try walk(currentPath: childPath,
                             restorePath: destination,
                             isAdding: true,
                             randomizeUUID: false,
                             randomizedID: currentID)
                }
                continue
            }

            // Not adding: route, or descend.
            let lower = child.lowercased()
            if lower == "container" {
                // A container is a full data-store snapshot: walk it from the
                // store root so the descriptor folders inside get routed to
                // configurations, exactly like a custom pack, and registered.
                try walk(currentPath: childPath, restorePath: "/", isAdding: false)
                return
            }
            if lower.contains("descriptor") {
                let extensionID = try self.extensionID(descriptorDirectory: currentPath,
                                                       descriptorName: lower)
                try walk(currentPath: childPath,
                         restorePath: "\(PosterBoard.storePath(structureVersion))/Extensions/"
                             + "\(extensionID)/configurations",
                         isAdding: true,
                         randomizeUUID: true)
                continue
            }
            try walk(currentPath: childPath, restorePath: restorePath, isAdding: false)
        }
    }

    /// Which provider extension a descriptor directory belongs to — the
    /// reference's four-way branch, in its order.
    private func extensionID(descriptorDirectory: URL, descriptorName: String) throws -> String {
        let parent = descriptorDirectory.lastPathComponent
        if parent.hasPrefix("com.apple.") { return parent }
        if descriptorName.contains("video") || descriptorName.contains("photos") {
            return PosterBoard.photosExtension
        }
        if descriptorName.contains("mercury") { return PosterBoard.mercuryExtension }
        return PosterBoard.collectionsExtension
    }

    /// `f"{restore_path}/{folder_name}".replace("//", "/")`.
    ///
    /// The reference builds the path with a join and then collapses the doubled
    /// slashes a `container/` walk produces (it starts at `/`).  `Data`-level
    /// path equality is what the manifest's fileID is derived from, so the
    /// collapse has to happen exactly here.
    private func joined(_ base: String, _ component: String) -> String {
        "\(base)/\(component)".replacingOccurrences(of: "//", with: "/")
    }

    /// What `update_plist_id` + `update_for_family` do to one file's bytes.
    private enum Rewrite {
        case none
        case bytes(Data)
        case unreadable(String)
    }

    /// The reference rewrites three file names inside a descriptor so the ids in
    /// them agree with the directory name it just invented.  A wallpaper whose
    /// `identifier` disagrees with its own directory is a wallpaper the provider
    /// cannot resolve.
    private func rewrittenContents(directory: URL,
                                   fileName: String,
                                   identifier: Int?,
                                   restorePath: String) -> Rewrite {
        guard let identifier else { return .none }
        // MercuryPoster configs keep their own textual identifier ("v6x.colorB")
        // that both `userInfo.lookIdentifier` and `suggestionMetadata` reference;
        // rewriting it to a random number breaks the lookup chain, so identifiers
        // are preserved byte for byte for that extension.
        if isMercury(restorePath) { return .none }

        let fileURL = directory.appendingPathComponent(fileName)
        do {
            switch true {
            case fileName == Self.descriptorIdentifierFile:
                return .bytes(Data(String(identifier).utf8))
            case fileName == "com.apple.posterkit.provider.contents.userInfo":
                // Top level, and a **string**. `recursive: true` only ever
                // *replaces* a key that is already there, and a third-party
                // tendie's userInfo ships **without**
                // `wallpaperRepresentingIdentifier` — so the key has to be
                // added, not just overwritten, or WallpaperKit force-unwraps nil
                // and traps (EXC_BREAKPOINT) in makeViewProvider. Stock
                // descriptors hold the id as text, which is what the reference
                // writes here.
                return .bytes(try PosterBoardPlist.set(contentsOf: fileURL,
                                                       key: "wallpaperRepresentingIdentifier",
                                                       value: String(identifier),
                                                       recursive: false))
            case fileName.hasSuffix("Wallpaper.plist"):
                // Top level only (`recursive=False`), then brought in line with
                // the Configs (Marble) model iOS 26.4+ expects.
                let withIdentifier = try PosterBoardPlist.set(contentsOf: fileURL,
                                                              key: "identifier",
                                                              value: identifier,
                                                              recursive: false)
                return .bytes(try PosterBoardPlist.alignedForFamily(withIdentifier))
            default:
                return .none
            }
        } catch {
            return .unreadable(error.localizedDescription)
        }
    }

    /// `PosterboardTweak.is_mercury`: index 6 of the store-relative path.
    private func isMercury(_ restorePath: String) -> Bool {
        let parts = restorePath.components(separatedBy: "/")
        return parts.count > 6 && parts[6] == PosterBoard.mercuryExtension
    }
}

// MARK: - Files the page picked

extension PosterBoard {
    /// Where a picked video wallpaper's two files are kept.
    static var videoDirectory: URL {
        URL.documents.appendingPathComponent("PosterBoard/Video", conformingTo: .data)
    }
    static var thumbnailDirectory: URL {
        URL.documents.appendingPathComponent("PosterBoard/Thumbnails", conformingTo: .data)
    }

    /// Copy a picked file into the app's container, replacing any previous choice.
    ///
    /// The picker's URL is security-scoped and its access ends with the callback,
    /// while the video is not read until minutes later, inside the compile — so
    /// the file has to live in the container.  One file per directory on purpose:
    /// a video wallpaper is *one* video, and keeping the ones the user tried and
    /// abandoned would leave hundreds of megabytes behind with nothing pointing
    /// at them.
    static func store(_ source: URL, in directory: URL) throws -> URL {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let fm = FileManager.default
        try? fm.removeItem(at: directory)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(source.lastPathComponent)
        do {
            try fm.copyItem(at: source, to: destination)
        } catch {
            throw GoldenNuggetError("Could not copy \(source.lastPathComponent) into the app: "
                + error.localizedDescription)
        }
        return destination
    }

    /// The file a picked-media directory holds, if any.
    static func storedFile(in directory: URL) -> URL? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        guard let name = names.sorted().first else { return nil }
        return directory.appendingPathComponent(name)
    }

    static func clearFiles(in directory: URL) {
        try? FileManager.default.removeItem(at: directory)
    }
}

// MARK: - plist rewriting

/// The reference's `plist_handler`, ported.
enum PosterBoardPlist {
    static func load(contentsOf url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        let object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        guard let plist = object as? [String: Any] else {
            throw GoldenNuggetError("\(url.lastPathComponent) is a plist but not a dictionary.")
        }
        return plist
    }

    /// `set_plist_value`: read, set the key (recursively or at the top level),
    /// serialise.
    ///
    /// XML, because `plistlib.dumps` defaults to it.  **One divergence**: Python
    /// sorts keys on the way out and `PropertyListSerialization` writes them in
    /// dictionary order.  A plist dictionary is unordered on read and the device
    /// compares values, not bytes — the manifest's `Digest` is computed over
    /// these bytes by the injector itself, so nothing downstream is affected.
    static func set(contentsOf url: URL,
                    key: String,
                    value: Any,
                    recursive: Bool) throws -> Data {
        var plist = try load(contentsOf: url)
        if recursive {
            plist = recursiveSet(plist, key: key, value: value)
        } else {
            plist[key] = value
        }
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }

    /// `plist_handler.recursive_set`: set the key wherever it already appears,
    /// at any depth, descending into every dictionary.
    static func recursiveSet(_ plist: [String: Any], key: String, value: Any) -> [String: Any] {
        var result = plist
        for (existingKey, existingValue) in plist {
            if existingKey == key {
                result[existingKey] = value
            } else if let nested = existingValue as? [String: Any] {
                result[existingKey] = recursiveSet(nested, key: key, value: value)
            }
        }
        return result
    }

    /// `update_for_family`: bring a system wallpaper in line with the Marble
    /// (Configs) model — family and name forced to Lavender, and the nested
    /// `assets.lockAndHome.default.identifier` kept in step with the top-level
    /// one so the provider can resolve the `.ca` animation files by that id.
    ///
    /// System wallpapers (iOS 17 era) carry their own family/name and a distinct
    /// descriptor identifier that no longer resolves once the store moved to
    /// database-driven configs, which is why every identifier field is rewritten.
    static func alignedForFamily(_ data: Data) throws -> Data {
        let object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        guard var plist = object as? [String: Any] else {
            throw GoldenNuggetError("Wallpaper.plist is not a dictionary.")
        }
        let newIdentifier = plist["identifier"]
        if let assets = plist["assets"] as? [String: Any],
           let lockAndHome = assets["lockAndHome"] as? [String: Any],
           var fallback = lockAndHome["default"] as? [String: Any] {
            fallback["name"] = "Lavender"
            if let newIdentifier { fallback["identifier"] = newIdentifier }
            var updatedLockAndHome = lockAndHome
            updatedLockAndHome["default"] = fallback
            var updatedAssets = assets
            updatedAssets["lockAndHome"] = updatedLockAndHome
            plist["assets"] = updatedAssets
        }
        plist["family"] = "Marble"
        plist["name"] = "Lavender"
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }
}
