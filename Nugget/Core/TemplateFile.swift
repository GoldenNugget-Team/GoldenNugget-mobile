import Foundation
#if canImport(ZIPFoundation)
import ZIPFoundation
#endif

/// Reading and unpacking a ZIP, with one implementation per platform.
///
/// The app builds against ZIPFoundation (`canImport` true); the host harnesses
/// in `scripts/` build for macOS, where `Process` exists and ZIPFoundation does
/// not — a harness could not shell out from an iOS binary, and it could not link
/// a module built for iOS either.  Rather than give the harness a stubbed-out
/// `TemplateFile`, the ZIP access is isolated here and the macOS side shells out
/// to `/usr/bin/zip`, which is what the harness's own fixtures are built with.
///
/// Both paths implement the same three operations, so the code under test —
/// the header parse, the options, the globs — is identical on both.
enum TemplateArchive {
    #if canImport(ZIPFoundation)

    /// Open a ZIP for reading.  Throws if it is not one.
    static func open(_ url: URL) throws -> Handle {
        do {
            let archive = try Archive(url: url, accessMode: .read)
            for entry in archive {
                guard TemplatePath.isSafe(entry.path), entry.type != .symlink else {
                    throw TemplateFile.fail("Unsafe template archive member: \(entry.path)")
                }
            }
            return Handle(archive: archive)
        } catch {
            throw TemplateFile.TemplateError("\(url.lastPathComponent) is not a readable .batter archive: "
                + error.localizedDescription)
        }
    }

    struct Handle {
        let archive: Archive

        /// Every entry path, in the archive's own order — which matters, because
        /// the search for `config.json` takes the first match.
        var paths: [String] { archive.map(\.path) }

        var names: [String] { paths }

        /// Whether this archive carries a directory entry (or a path) that
        /// matches `pattern`.
        func contains(matching pattern: String) -> Bool {
            paths.contains { TemplateGlob.fnmatch(pattern, $0) }
        }

        /// The entry's bytes.
        func data(at path: String) throws -> Data {
            guard let entry = archive.first(where: { $0.path == path }) else {
                throw TemplateFile.TemplateError("\(path) is not in the archive.")
            }
            let directory = try TemplateArchive.stagingDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let target = directory.appendingPathComponent("entry")
            _ = try archive.extract(entry, to: target)
            return try Data(contentsOf: target)
        }

        /// Unpack everything under `destination`.
        func extract(to destination: URL) throws {
            let fm = FileManager.default
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)
            for entry in archive {
                let relative = entry.path
                guard entry.type != .symlink,
                      let target = TemplatePath.destination(relative, under: destination) else {
                    throw TemplateFile.TemplateError("the archive holds an entry that escapes the extraction "
                        + "directory (\(relative)).")
                }
                if entry.type == .directory {
                    try? fm.createDirectory(at: target, withIntermediateDirectories: true)
                    continue
                }
                try? fm.createDirectory(at: target.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
                _ = try archive.extract(entry, to: target)
            }
        }
    }

    #else

    /// macOS: `unzip` into a scratch directory, once, and serve from the tree.
    ///
    /// The whole archive is unpacked up front because `unzip` has no
    /// single-entry-to-stdout mode worth depending on, and every use here reads
    /// either a handful of entries or all of them anyway.
    static func open(_ url: URL) throws -> Handle {
        // `FileManager.createTemporaryDirectory` is iOS 16+; this project
        // deploys to iOS 26 but the host harnesses build for macOS, where it
        // does not exist — so the directory is made the long way, which works
        // on both.
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tmpl-zip-" + UUID().uuidString, conformingTo: .directory)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-qq", "-o", url.path, "-d", scratch.path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            try? FileManager.default.removeItem(at: scratch)
            throw TemplateFile.TemplateError(
                "\(url.lastPathComponent) is not a readable .batter archive.")
        }
        return Handle(root: scratch)
    }

    struct Handle {
        let root: URL

        private var listing: [String] {
            ((try? FileManager.default.subpathsOfDirectory(atPath: root.path)) ?? []).sorted()
        }

        var names: [String] { listing }

        var paths: [String] { listing }

        func contains(matching pattern: String) -> Bool {
            listing.contains { TemplateGlob.fnmatch(pattern, $0) }
        }

        func data(at path: String) throws -> Data {
            try Data(contentsOf: root.appendingPathComponent(path))
        }

        func extract(to destination: URL) throws {
            let fm = FileManager.default
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)
            for relative in listing {
                let source = root.appendingPathComponent(relative)
                var isDirectory: ObjCBool = false
                guard fm.fileExists(atPath: source.path, isDirectory: &isDirectory) else { continue }
                let target = destination.appendingPathComponent(relative)
                guard !relative.hasPrefix("/"),
                      !relative.split(separator: "/").contains(".."),
                      target.standardizedFileURL.path
                        .hasPrefix(destination.standardizedFileURL.path) else {
                    throw TemplateFile.TemplateError("refusing to write \(relative) outside the extraction "
                        + "directory.")
                }
                if isDirectory.boolValue {
                    try? fm.createDirectory(at: target, withIntermediateDirectories: true)
                } else {
                    try? fm.createDirectory(at: target.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
                    try? fm.copyItem(at: source, to: target)
                }
            }
        }
    }

    #endif

    /// A scratch directory for one extraction.
    ///
    /// Its own directory rather than a bare temporary file name, because an
    /// extraction writes a whole *tree* and two concurrent templates must not
    /// collide.
    static func stagingDirectory() throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tmpl-" + UUID().uuidString, conformingTo: .directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

/// An imported `.batter` template.
///
/// A port of `src/tweaks/posterboard/template_file.py` (which extends
/// `tendie_file.py`, so the archive-inspection half is shared with
/// `PosterBoardTendie`).  A `.batter` is a ZIP carrying a `config.json` that
/// declares which domain the payload belongs in and **what the user may
/// change**: a wallpaper collection's author ships a template that asks for a
/// background image, a colour, and which of three variants to install.
///
/// Two things make it more than a renamed `.tendies`:
///
///   * the **options engine** (`template_options/`), which rewrites the
///     extracted files before they are delivered — see `TemplateOption`;
///   * a **domain** that is not necessarily PosterBoard's, so the payload can
///     land in any `AppDomain-*` (or, upstream, via `Sparserestore-`).
///
/// The header's gates are all reproduced, and they are gates rather than
/// warnings because a template that declares `min_version: "26.0"` on a device
/// running 18 is a template whose payload the device cannot read — installing it
/// would write files nothing will ever open.
struct TemplateFile: Identifiable {
    let id = UUID()
    /// Where the template lives in this app's container.
    let url: URL
    /// `title` from the header, which is what the reference puts on the row
    /// (not the file name — a template's file name says nothing useful).
    let title: String
    let author: String
    let description: String?
    let domain: String
    let formatVersion: Int
    let minVersion: String?
    let maxVersion: String?

    let resourcesDirectory: String
    /// Resource name → the file it was extracted to, for the ones named as
    /// previews.
    let previews: [String: URL]
    let previewLayout: PreviewLayout
    let bannerText: String?
    let bannerStylesheet: String?

    /// `var`, not `let`: an option carries the user's choices, so filling one in is
    /// a mutation of the template rather than of some side table.  The page
    /// edits through `TemplateSelection.update`, which persists the result.
    var options: [TemplateOption]
    /// Whether the config declared a `bundle_id` option.
    let canChangeBundleID: Bool
    /// The bundle id in force, defaulting to the one in the domain.  A value,
    /// because the page edits it (`update_bundle_id`).
    var bundleID: String

    /// Where `config.json` was found, relative to the archive root.  The
    /// reference's `json_path`, and it matters: every `files` entry in an
    /// option is relative to the config's **parent**, not to the archive root,
    /// so a template that ships its config in a subdirectory resolves its
    /// option paths against that subdirectory.
    let jsonPath: String

    /// The archive-inspection half of `TendieFile`, which a template inherits.
    let isContainer: Bool
    let unsafeContainer: Bool
    let descriptorCount: Int

    enum PreviewLayout: String {
        case horizontal
        case stacked
    }

    /// The format version this port understands — the reference's
    /// `CURRENT_FORMAT`.
    ///
    /// A template that declares a higher one is **refused**, not attempted:
    /// its options may mean things this port does not implement, and a
    /// half-applied template is worse than one that says so.
    static let currentFormat = 2

    /// The name of the config the reference looks for, lowercased.
    static let configName = "config.json"

    /// The store database a `container/` pack may carry, which the reference
    /// calls `unsafe_container` and warns about (`TendieFile.__init__`).
    ///
    /// The **same string** as `PosterBoardTendie.databaseEntryName`, and it has
    /// to stay that one string: a template that ships a `container/` snapshot
    /// and a `.tendies` pack that ships the same thing are the same warning,
    /// and a template copy that spelled it differently would warn about nothing.
    static let databaseEntryName = "PBFPosterExtensionDataStoreSQLiteDatabase.sqlite3"

// MARK: - Reading

/// A scratch directory for one extraction.
///
/// Its own directory rather than a bare temporary file name, because
/// `archive.extract(_:to:)` writes a *directory tree* and two concurrent
/// templates must not collide.
static func stagingDirectory() throws -> URL {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("tmpl-" + UUID().uuidString, conformingTo: .directory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

/// Read a template, or throw `TemplateError` saying which gate it failed.
    init(url: URL, deviceVersion: String?) throws {
        self.url = url

        let archive = try TemplateArchive.open(url)

        // The reference's search: the first entry whose lowercased name contains
        // `config.json`, and which is not inside a descriptor or container
        // folder.  Order matters (it is the archive's) and so does the exclusion
        // — a descriptor can carry its own `config.json`, and picking that one
        /// would read a wallpaper's config as a template header.
        var jsonPath: String?
        for candidate in archive.names {
            let lower = candidate.lowercased()
            guard lower.contains(Self.configName),
                  !lower.contains("descriptor"), !lower.contains("container") else { continue }
            jsonPath = candidate
            break
        }
        guard let jsonPath else {
            throw TemplateError("\(url.lastPathComponent) has no \(Self.configName) in it. "
                + "A .batter file is a ZIP holding a \(Self.configName).")
        }
        self.jsonPath = jsonPath

        // `extractData(for:)` is spelled `archive.extract(_:to:)` in the ZIPFoundation
        // version this project vendors — `PosterBoardTendie.extract` is the
        // existing call site — so this reads through the same helper that file
        // uses rather than a second spelling of it.
        guard let configData = try? archive.data(at: jsonPath) else {
            throw TemplateError("\(url.lastPathComponent): could not read \(jsonPath) out of it.")
        }
        guard let raw = try? JSONSerialization.jsonObject(with: configData),
              let data = raw as? [String: Any] else {
            throw TemplateError("\(jsonPath) is not a JSON object.")
        }

        // MARK: the required header

        guard let optionsData = data["options"] as? [Any] else {
            throw TemplateError("\(jsonPath) has no \"options\" list. Make sure it is in the "
                + "correct format.")
        }
        guard var domain = data["domain"] as? String else {
            throw TemplateError("\(jsonPath) has no \"domain\", so there is nowhere to restore "
                + "this template to.")
        }
        // Backwards compatibility for the reference's own v5.2-beta slip, which
        // wrote the bare bundle id here.
        if domain == "com.apple.PosterBoard" { domain = "AppDomain-\(domain)" }
        self.domain = domain

        guard let rawFormat = data["format_version"] else {
            throw TemplateError("\(jsonPath) has no \"format_version\".")
        }
        // The reference does `int(data['format_version'])`, so `"2"` and `2` are
        // both accepted and `"two"` raises `ValueError` — a refusal here too.
        guard let formatVersion = TemplateFile.integer(rawFormat) else {
            throw TemplateError("\(jsonPath)'s \"format_version\" is \(rawFormat), which is not "
                + "a whole number.")
        }
        guard formatVersion <= Self.currentFormat else {
            throw TemplateError("\(url.lastPathComponent) needs a newer version of this app "
                + "(its config is format \(formatVersion); this app reads up to "
                + "\(Self.currentFormat)).")
        }
        self.formatVersion = formatVersion

        guard let title = data["title"] as? String else {
            throw TemplateError("\(jsonPath) has no \"title\".")
        }
        self.title = title
        guard let author = data["author"] as? String else {
            throw TemplateError("\(jsonPath) has no \"author\".")
        }
        self.author = author
        self.description = data["description"] as? String

        // MARK: the version gates

        self.minVersion = data["min_version"] as? String
        self.maxVersion = data["max_version"] as? String
        // Both version gates are guarded by `if device_version and …`, which is
        // load-bearing in two directions and is reproduced exactly:
        //
        //   * with **no** device version the check is **skipped**, not failed.
        //     The reference writes `if device_version and Version(min) >
        //     Version(device_version)`, so a falsy version short-circuits and
        //     the template loads.  Refusing here instead would empty this app's
        //     template list at launch (which happens before the tunnel is up)
        //     and make every version-gated template look broken until the
        //     Templates page happened to be opened with a device.  The page
        //     passes the real version, so the gate is still enforced where it
        //     can be;
        //   * an unparseable version on either side raises `InvalidVersion` in
        //     the reference, so it is a refusal here too.
        if let deviceVersion, !deviceVersion.isEmpty {
            if let minVersion = self.minVersion {
                guard let atLeast = PosterBoard.compareVersion(deviceVersion, minVersion) else {
                    throw TemplateError("This device reports iOS \"\(deviceVersion)\", which is "
                        + "not a version, so \(url.lastPathComponent)'s iOS \(minVersion) "
                        + "requirement cannot be checked.")
                }
                guard atLeast >= 0 else {
                    throw TemplateError("\(url.lastPathComponent) requires iOS \(minVersion). "
                        + "This device is on iOS \(deviceVersion).")
                }
            }
            if let maxVersion = self.maxVersion {
                guard let atMost = PosterBoard.compareVersion(deviceVersion, maxVersion) else {
                    throw TemplateError("This device reports iOS \"\(deviceVersion)\", which is "
                        + "not a version, so \(url.lastPathComponent)'s iOS \(maxVersion) ceiling "
                        + "cannot be checked.")
                }
                guard atMost <= 0 else {
                    throw TemplateError("\(url.lastPathComponent) supports up to iOS \(maxVersion). "
                        + "This device is on iOS \(deviceVersion).")
                }
            }
        }

        // MARK: previews, banner, resources

        var previewNames: [String] = []
        if let previews = data["previews"] as? [String] {
            previewNames = previews
        }
        self.previewLayout = (data["preview_layout"] as? String).flatMap(PreviewLayout.init(rawValue:))
            ?? .horizontal
        self.bannerText = data["banner_text"] as? String
        var bannerStylesheet = data["banner_stylesheet"] as? String

        // The directory the config lives in — the base for every `files` entry
        // and for the resource patterns.
        let base = (jsonPath as NSString).deletingLastPathComponent
        self.resourcesDirectory = base

        var previews: [String: URL] = [:]
        if let resources = data["resources"] as? [String] {
            // The reference extracts resources into a temporary directory at
            // *load* time, and `clean_files` removes it when the template is
            // dropped.  Here they go next to the template, in a directory named
            // after it: the page can be re-entered any number of times without
            // re-extracting, and there is nothing to clean up on delete because
            // deleting the template deletes its directory.
            let destination = Self.resourcesDirectory(for: url)
            for resource in resources {
                // `fnmatch.filter(archive.namelist(), base + resource)` — the
                // pattern is the base joined to the resource, so a resource may
                // itself be a glob (`images/*.png`).
                let pattern = (base as NSString).appendingPathComponent(resource)
                for entryName in archive.names where TemplateGlob.fnmatch(pattern, entryName) {
                    guard let bytes = try? archive.data(at: entryName) else { continue }
                    guard let target = TemplatePath.destination(entryName, under: destination) else {
                        throw TemplateError("Unsafe template resource path: \(entryName)")
                    }
                    try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                            withIntermediateDirectories: true)
                    do {
                        try bytes.write(to: target)
                    } catch {
                        throw TemplateError("Could not stage \(entryName) out of "
                            + "\(url.lastPathComponent): \(error.localizedDescription)")
                    }
                    // `clean_path` is the entry's path with the base stripped,
                    // and that is the key `previews` is written against.
                    let cleanPath = entryName.replacingOccurrences(of: base, with: "")
                    // The reference rewrites the banner's `url(...)` to point at
                    // the extracted file, because a Qt stylesheet resolves URLs
                    // against the app bundle.
                    if let sheet = bannerStylesheet {
                        bannerStylesheet = sheet.replacingOccurrences(
                            of: "url(\(cleanPath))", with: "url(\(target.path))")
                    }
                    if previewNames.contains(cleanPath) { previews[cleanPath] = target }
                }
            }
        }
        self.previews = previews
        self.bannerStylesheet = bannerStylesheet

        // MARK: the archive's own shape (`TendieFile.__init__`)

        var descriptors = 0
        var container = false
        var unsafe = false
        for path in archive.names {
            let lower = path.lowercased()
            if lower.contains("__macosx/") { continue }
            if lower.contains("container") {
                container = true
                if path.contains(Self.databaseEntryName) { unsafe = true }
            }
            // `"descriptor/"` is not a substring of `"descriptors/…"`, so the two
            // tests are exclusive — the reference relies on that too.
            let marker = lower.contains("descriptor/") ? "descriptor/"
                : (lower.contains("descriptors/") ? "descriptors/" : nil)
            guard let marker else { continue }
            let tail = lower.components(separatedBy: marker).dropFirst().first ?? ""
            // One level under the marker, and a directory.
            if tail.filter({ $0 == "/" }).count == 1 && tail.hasSuffix("/") { descriptors += 1 }
        }
        self.descriptorCount = descriptors
        self.isContainer = container
        self.unsafeContainer = unsafe

        // MARK: the options

        var parsed: [TemplateOption] = []
        var bundleIDOption = false
        for entry in optionsData {
            guard let optionData = entry as? [String: Any] else {
                throw TemplateError("\(jsonPath)'s \"options\" contains something that is not an "
                    + "object.")
            }
            guard let typeName = optionData["type"] as? String else {
                throw TemplateError("An option in \(jsonPath) has no \"type\".")
            }
            switch TemplateOptionKind(rawValue: typeName) {
            case .replace:
                parsed.append(try ReplaceOption(data: optionData, jsonPath: jsonPath))
            case .remove:
                parsed.append(try RemoveOption(data: optionData, jsonPath: jsonPath))
            case .set:
                parsed.append(try SetOption(data: optionData, jsonPath: jsonPath))
            case .picker:
                parsed.append(try PickerOption(data: optionData, jsonPath: jsonPath))
            case .bundleID:
                // Not an option object: it is a flag on the template, and the
                // reference turns it into exactly that (`change_bundle_id`).
                bundleIDOption = true
            case .none:
                throw TemplateError("\"\(typeName)\" is not an option type this app knows. The "
                    + "types are: replace, remove, set, picker, bundle_id.")
            }
        }
        self.options = parsed
        self.canChangeBundleID = bundleIDOption
        // The bundle id in force, defaulting to **empty**.
        //
        // Not to the domain's bundle id: the reference's `TemplateFile` declares
        // `bundle_id: str = None` and assigns it in exactly one place — the
        // `bundle_id` branch of the option loop — so a template without that
        // option has `None`, and the page's text box is seeded from it and
        // therefore starts empty.  The domain's own id is the placeholder text,
        // not the value (`textbox.setPlaceholderText(...)` vs `setText(...)`).
        self.bundleID = canChangeBundleID && domain.hasPrefix("AppDomain-")
            ? String(domain.dropFirst("AppDomain-".count)) : ""
    }

    /// `int()` on the values that may be a number or a numeric string.
    static func integer(_ value: Any) -> Int? {
        switch value {
        case let number as Int: return number
        case let number as Double: return Int(exactly: number.rounded()) == nil ? nil : Int(number)
        case let text as String: return Int(text)
        default: return nil
        }
    }

    // MARK: - Derived facts

    /// Whether this template's payload belongs to PosterBoard.
    ///
    /// The reference tests the exact string in three places
    /// (`add_template`, `apply_tweak`'s template loop, `TemplatesTweak`), and
    /// the two spellings are both live: `com.apple.PosterBoard` is what a
    /// v5.2-beta template wrote, `AppDomain-…` is what everything since does.
    var isPosterBoard: Bool {
        domain == "com.apple.PosterBoard" || domain == "AppDomain-com.apple.PosterBoard"
    }

    /// Whether this template asks for a **sparserestore**, which this port
    /// cannot deliver.
    ///
    /// Upstream routes a `Sparserestore-<absolute path>` domain through the
    /// sparse-restore protocol (`templates_tweak.recursive_add` strips the
    /// prefix and sets the restore domain to `None`).  This project removed its
    /// whole `Nugget/Sparserestore/` tree on 2026-09-19 (`d1830d9`, "some other
    /// big things") in favour of the protective-backup route, and that commit
    /// records no reason.  So the template is **refused with that reason**,
    /// rather than being delivered through a channel that was never going to
    /// carry it — which would be a silent no-op on the device.
    var requiresSparserestore: Bool {
        domain.hasPrefix("Sparserestore-")
    }

    /// The domain the payload is delivered to, with a `bundle_id` option
    /// applied.  `TemplatesTweak.apply_tweak`'s own rewrite.
    var effectiveDomain: String {
        canChangeBundleID ? "AppDomain-\(bundleID)" : domain
    }

    /// A one-line description for the row.
    var summary: String {
        var parts = ["by \(author)", domain]
        if descriptorCount > 0 { parts.append("\(descriptorCount) descriptor(s)") }
        if canChangeBundleID { parts.append("bundle id editable") }
        if !options.isEmpty { parts.append("\(options.count) option(s)") }
        if minVersion != nil || maxVersion != nil {
            parts.append("iOS \(minVersion ?? "any")–\(maxVersion ?? "any")")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Extraction

    /// Unpack into `destination` and apply every option, as
    /// `TemplateFile.extract` does.
    ///
    /// The options run against the **parent of `json_path`**, which is what
    /// makes a template whose config sits in a subdirectory resolve its `files`
    /// entries correctly.
    @discardableResult
    func extract(to destination: URL) throws -> URL {
        let archive = try TemplateArchive.open(url)
        try archive.extract(to: destination)

        let parent = destination.appendingPathComponent(
            (jsonPath as NSString).deletingLastPathComponent)
        for option in options {
            try option.apply(containerPath: parent)
        }
        return destination
    }

    // MARK: - Where a template's staged files live

    enum TemplateError: Error, LocalizedError {
        /// `reason` is the whole message, because it goes on screen as-is.
        case message(String)

        /// Explicit so the case can be thrown from outside this file — the
        /// option types and the harness both construct it directly.
        init(_ reason: String) { self = .message(reason) }

        var errorDescription: String? {
            switch self {
            case .message(let reason): return reason
            }
        }

        static func == (lhs: TemplateError, rhs: TemplateError) -> Bool {
            lhs.errorDescription == rhs.errorDescription
        }
    }

    /// Throw the standard refusal.
    static func fail(_ message: String) -> TemplateError { .message(message) }

    /// Where a template's `resources` entries are staged.
    ///
    /// Next to the template, in a directory named after it: the page can be
    /// re-entered any number of times without re-extracting, and there is
    /// nothing to clean up on delete because deleting the template deletes its
    /// directory.  (The reference extracts into a `TemporaryDirectory` and
    /// removes it in `clean_files`.)
    static func resourcesDirectory(for template: URL) -> URL {
        template.deletingLastPathComponent()
            .appendingPathComponent("Resources", conformingTo: .directory)
            .appendingPathComponent(template.lastPathComponent, conformingTo: .directory)
    }
}
