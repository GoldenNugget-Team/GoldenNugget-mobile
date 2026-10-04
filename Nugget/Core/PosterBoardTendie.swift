import Foundation
import ZIPFoundation

/// An imported `.tendies` wallpaper pack, as the reference reads it.
///
/// A port of `src/tweaks/posterboard/tendie_file.py`. The file is a ZIP whose
/// entries decide three things the UI and the apply both need:
///
///   * how many descriptors it carries — the reference caps a selection at 10
///     (`PosterboardTweak.verify_tendie`), because PosterBoard's picker gets
///     unusable past that;
///   * whether it carries a `container/` — a full data-store snapshot rather
///     than a descriptor, which is a different delivery path (`recursive_add`'s
///     `container` branch);
///   * whether that container carries the PosterBoard **database** itself, in
///     which case the reference calls it `unsafe_container` and tells the user
///     they may need a full wallpaper reset first.  That is not a scare: a
///     database stitched from a stale snapshot lands on the device with row
///     sets the live store does not have.
///
/// The counting rules are the reference's, including the two case-sensitivity
/// quirks in it — `__MACOSX` is matched on the lowercased name, the database
/// file name on the raw one.  Both are reproduced rather than tidied, because
/// either could be load-bearing for a pack in the wild.
/// Which PosterBoard extension a descriptor pack belongs to.
///
/// A pack that ships a bare `descriptors/<UUID>` tree does not say which
/// extension owns it — the path on the device does, and the pack has no copy of
/// that path. The reference asks the user at import time and remembers the
/// answer (`TendieItem.posterType`, `TendiesModel.swift`), because the injection
/// target is built from it:
/// `…/PRBPosterExtensionDataStore/<version>/Extensions/<extensionBundleId>/descriptors`.
///
/// Getting this wrong does not fail loudly. A descriptor injected under the
/// wrong extension id lands in a folder PosterBoard's provider never reads, so
/// the wallpaper simply does not appear.
enum PosterBoardPosterType: String, CaseIterable, Identifiable, Codable {
    case collections
    case suggestedPhotos
    case mercury
    case container

    var id: String { rawValue }

    /// The reference's `TendiePosterType.extensionBundleId`.
    var extensionBundleID: String {
        switch self {
        case .collections: return "com.apple.WallpaperKit.CollectionsPoster"
        case .suggestedPhotos: return "com.apple.PhotosUIPrivate.PhotosPosterProvider"
        case .mercury: return "com.apple.MercuryPoster"
        case .container: return "com.apple.PosterBoard"
        }
    }

    var label: String {
        switch self {
        case .collections: return "Collections"
        case .suggestedPhotos: return "Suggested Photos"
        case .mercury: return "Mercury"
        case .container: return "App Container"
        }
    }

    var systemImage: String {
        switch self {
        case .collections: return "paintpalette.fill"
        case .suggestedPhotos: return "photo.fill"
        case .mercury: return "sparkles"
        case .container: return "shippingbox.fill"
        }
    }

    /// A `container/` snapshot is its own kind of pack, so it defaults to the
    /// type named after it rather than to Collections.
    static func defaultForContainer(_ isContainer: Bool) -> PosterBoardPosterType {
        isContainer ? .container : .collections
    }
}

struct PosterBoardTendie: Identifiable, Hashable {
    let id = UUID()
    /// Where the pack lives in this app's container, so it survives a launch.
    let url: URL
    /// The file name the reference would show (`os.path.basename`).
    let name: String
    let descriptorCount: Int
    let isContainer: Bool
    let isUnsafeContainer: Bool
    /// Which extension this pack's descriptors are injected under. User-chosen,
    /// because the pack does not carry it; see `PosterBoardPosterType`.
    var posterType: PosterBoardPosterType
    /// The user's answer to the legacy-format prompt: `true` convert, `false`
    /// install as is, `nil` never asked.
    ///
    /// Upstream keeps this on the tendie object (`TendieFile.auto_convert`) and
    /// honours it per extracted pack in `apply_tweak`, which is why each pack is
    /// extracted into its own folder. Here the pack is a file on disk that is
    /// re-read from its archive on every launch, so the answer is kept in
    /// `PosterBoardPreferences.autoConvertAnswers` by file name and read back
    /// here.
    var autoConvert: Bool?

    /// The exact name `TendieFile` looks for inside a `container/` pack.
    static let databaseEntryName = "PBFPosterExtensionDataStoreSQLiteDatabase.sqlite3"

    init(url: URL) throws {
        self.url = url
        self.name = url.lastPathComponent

        let archive: Archive
        do {
            archive = try Archive(url: url, accessMode: .read)
        } catch {
            throw GoldenNuggetError("\(url.lastPathComponent) is not a readable .tendies "
                + "archive: \(error.localizedDescription)")
        }

        var descriptors = 0
        var container = false
        var unsafeContainer = false
        // The provider this pack is *for*, read off its own paths, and nil when
        // nothing said. The reference does this in the same walk
        // (`TendiesEngine.swift`: a `/container/` path sets `.container`, then a
        // descriptor path overrides it with mercury or photos). Order matters
        // there and it is preserved here: the container rule runs on the way down
        // and the descriptor rule on the way into the payload, so a snapshot
        // ends up as the provider it snapshots rather than as `.container`.
        var detected: PosterBoardPosterType?
        for entry in archive {
            let path = entry.path
            let lower = path.lowercased()
            if lower.contains("__macosx/") { continue }
            if lower.contains("container") {
                container = true
                // Raw case, as in the reference: the entry it is looking for is
                // spelled exactly this way inside a container dump.
                if path.contains(Self.databaseEntryName) { unsafeContainer = true }
            }
            if lower.contains("/container/") || lower.hasSuffix("/container") {
                detected = .container
            }
            // `descriptor/` and `descriptors/` are mutually exclusive as
            // substrings (`"descriptor/"` is not in `"descriptors/…"`), and the
            // reference tests them in that order — so the second is only reached
            // by the plural spelling.
            let marker = lower.contains("descriptor/") ? "descriptor/"
                : (lower.contains("descriptors/") ? "descriptors/" : nil)
            guard let marker else { continue }
            if lower.contains("video") || lower.contains("photos") {
                detected = .suggestedPhotos
            } else if lower.contains("mercury") {
                detected = .mercury
            } else if detected != .container {
                detected = .collections
            }
            if let tail = lower.components(separatedBy: marker).dropFirst().first {
                // One level under the marker, and a directory: `UUID/`.
                if tail.filter({ $0 == "/" }).count == 1 && tail.hasSuffix("/") {
                    descriptors += 1
                }
            }
        }

        if descriptors == 0 && !container {
            throw GoldenNuggetError("\(url.lastPathComponent) holds no descriptor and no "
                + "container — it does not look like a .tendies pack.")
        }
        self.descriptorCount = descriptors
        self.isContainer = container
        self.isUnsafeContainer = unsafeContainer
        self.posterType = PosterBoardPreferences.posterTypes[url.lastPathComponent]
            ?? detected ?? .defaultForContainer(container)
        self.autoConvert = PosterBoardPreferences.autoConvertAnswers[url.lastPathComponent]
    }

    /// Remember the legacy-format answer for this pack, and return it with the
    /// answer set. Written immediately, like `settingPosterType`.
    func settingAutoConvert(_ convert: Bool) -> PosterBoardTendie {
        var copy = self
        copy.autoConvert = convert
        var answers = PosterBoardPreferences.autoConvertAnswers
        answers[url.lastPathComponent] = convert
        PosterBoardPreferences.autoConvertAnswers = answers
        return copy
    }

    /// The families of the pre-iOS 27 packages inside this pack, read straight out
    /// of the archive.
    ///
    /// Empty means nothing legacy is in there, or the pack cannot be opened.  The
    /// pack was already opened successfully in `init`, so a throw here is a real
    /// I/O failure — which is why `legacyConvertPrompt` swallows it and asks
    /// nothing: an archive that cannot be read cannot be converted either, so
    /// there is no question worth putting to the user, and the apply then fails on
    /// the same read and says so.
    func legacyFamilies() throws -> [String] {
        try PosterBoardConverter.legacyFamilies(ofPack: url)
    }

    /// What to ask the user about this pack, or nil when there is nothing to ask.
    ///
    /// `PosterboardTweak._ask_legacy_convert`'s gates in its own order: the
    /// setting, the device (iOS 27 is where the format changed), then whether the
    /// archive holds a pre-27 package at all. The one addition is
    /// `autoConvert != nil`, which is what "already answered" means — upstream
    /// gets that for free because the flag only exists while the object that was
    /// asked about is still in memory.
    func legacyConvertPrompt(deviceVersion: String) -> LegacyConvertPrompt? {
        guard PosterBoardPreferences.autoConvertLegacy, autoConvert == nil else { return nil }
        guard let atLeast27 = PosterBoard.compareVersion(deviceVersion, "27"), atLeast27 >= 0
        else { return nil }
        guard let families = try? legacyFamilies(), !families.isEmpty else { return nil }
        return LegacyConvertPrompt(pack: self, families: families)
    }

    /// Remember a poster type for this pack, and return the pack with it set.
    ///
    /// The pack is re-read from its archive on every launch, so the answer cannot
    /// live in the pack — it goes to the one store that outlives a launch, keyed
    /// by file name. Losing it is not catastrophic: the type falls back to
    /// Collections. A wallpaper that silently stops appearing is, so it is written
    /// the moment it changes rather than at Apply time.
    func settingPosterType(_ type: PosterBoardPosterType) -> PosterBoardTendie {
        var copy = self
        copy.posterType = type
        var types = PosterBoardPreferences.posterTypes
        types[url.lastPathComponent] = type
        PosterBoardPreferences.posterTypes = types
        return copy
    }

    /// A one-line description for the row, including the reference's warning.
    var summary: String {
        if isContainer {
            return isUnsafeContainer
                ? "container, carries the database — upstream says reset all wallpapers first"
                : "container snapshot"
        }
        return descriptorCount == 1 ? "1 descriptor" : "\(descriptorCount) descriptors"
    }

    /// Unpack into `destination`, exactly as `TendieFile.extract` does.
    ///
    /// Every entry is written under `destination` and a path that would escape
    /// it is refused: the reference hands the archive straight to
    /// `zipfile.extractall`, which is safe only because CPython sanitises entry
    /// names — reproducing that with `URL(fileURLWithPath:)` needs the check
    /// spelled out.
    func extract(to destination: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let root = destination.standardizedFileURL.path

        let archive = try Archive(url: url, accessMode: .read)
        for entry in archive {
            let relative = entry.path
            guard !relative.hasPrefix("/"),
                  !relative.split(separator: "/").contains("..") else {
                throw GoldenNuggetError("\(name): the archive holds an entry that escapes the "
                    + "extraction directory (\(relative)).")
            }
            let target = URL(fileURLWithPath: root + "/" + relative)
            guard target.standardizedFileURL.path.hasPrefix(root) else {
                throw GoldenNuggetError("\(name): refusing to write \(relative) outside the "
                    + "extraction directory.")
            }
            // A directory entry can legitimately be repeated or already exist
            // (some zips carry both `a/` and `a/b`), and the reference's
            // `extractall` merges them.
            if entry.type == .directory, fm.fileExists(atPath: target.path) { continue }
            _ = try archive.extract(entry, to: target)
        }
    }
}

/// A pack waiting on the Convert / Install-as-is answer.
///
/// The reference's `prompt_legacy_convert` returns a `bool` straight into
/// `TendieFile.auto_convert`; there is nothing to keep on screen afterwards.  A
/// SwiftUI alert is presented from the view, so the pending question is a value
/// the view holds, and the pack it is about travels with it.
struct LegacyConvertPrompt: Identifiable {
    let pack: PosterBoardTendie
    /// The pre-iOS 27 families found inside, as the dialog spells them:
    /// `", ".join(sorted(set(families)))`. Normalised here rather than in the
    /// views, because the run log prints the same list.
    let families: [String]

    /// Two packages of the same family produce one entry, the way the reference's
    /// `set()` does.
    init(pack: PosterBoardTendie, families: [String]) {
        self.pack = pack
        self.families = Array(Set(families)).sorted()
    }

    var id: String { pack.url.lastPathComponent }

    /// The dialog's `setText`: "<b>pack</b> uses the legacy A, B format."
    var title: String {
        "\(pack.name) uses the legacy \(families.joined(separator: ", ")) format."
    }

    /// The dialog's `setInformativeText`, verbatim.
    static let message = "iOS 27 only applies the depth effect to wallpapers in the modern "
        + "format, so a legacy wallpaper is rewritten on import. Pick “Install as is” to push "
        + "the original files untouched instead."

    /// `Convert (may break the wallpaper)` — the reference's accepted-role button,
    /// and its default.
    static let convertTitle = "Convert (may break the wallpaper)"
    /// `Install as is` — the reference's rejected-role button.
    static let asIsTitle = "Install as is"
}

/// The imported packs, as files in this app's container.
///
/// The reference keeps its tendie list in memory (`tweaks[TweakID.PosterBoard]`)
/// and loses it on exit.  A pack is tens of megabytes that the user picked by
/// hand through the document picker, so here the **directory is the list**: a
/// pack is imported once, stays on disk, and the page shows what it finds.  That
/// is a deliberate divergence, and the only one in this area — nothing about
/// what reaches the device changes.
enum PosterBoardImports {
    static var directory: URL {
        URL.documents.appendingPathComponent("PosterBoard/Imports", conformingTo: .data)
    }

    /// A name that is not taken yet, so a second import of the same pack does
    /// not overwrite the first.
    static func uniqueDestination(for name: String) -> URL {
        let existing = Set((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
        return directory.appendingPathComponent(AfcFileExplorer.uniqueName(name, against: existing),
                                                conformingTo: .data)
    }

    /// Copy a picked file into the container and describe it.
    ///
    /// Copies rather than references: the picker's URL is security-scoped and
    /// its access ends with the callback, so a pack kept by reference would be
    /// unreadable on the next apply.
    static func `import`(from source: URL) throws -> PosterBoardTendie {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = uniqueDestination(for: source.lastPathComponent)
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            throw GoldenNuggetError("Could not copy \(source.lastPathComponent) into the app: "
                + error.localizedDescription)
        }
        do {
            return try PosterBoardTendie(url: destination)
        } catch {
            // Not a pack: leave nothing behind for the next launch to trip over.
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    /// Every imported pack, newest last, in file-name order.
    static func load() -> [PosterBoardTendie] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.sorted().compactMap { try? PosterBoardTendie(url: directory.appendingPathComponent($0)) }
    }

    static func remove(_ tendie: PosterBoardTendie) {
        try? FileManager.default.removeItem(at: tendie.url)
    }

    static func removeAll() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// The reference's cap (`PosterboardTweak.verify_tendie`).
    static let descriptorLimit = 10
}
