import Foundation
import ZIPFoundation

/// PosterBoard over an AirTraffic tunnel instead of a protective backup.
///
/// The reference for this is AirCard's `TendiesEngine`, and the difference from
/// `PosterBoard.compile` is the whole point of it: nothing is backed up and
/// nothing is restored. A descriptor folder is staged here, and
/// `al_exploit_inject_folder` moves it into PosterBoard's own data container, so
/// there is no manifest domain, no store database, and no reboot.
///
/// What that buys and what it costs, because both matter to the user:
///
///  * **Buys** — no full protective backup (the expensive part of the other mode),
///    and a respring is enough to make the wallpapers appear.
///  * **Costs** — iOS 26.2+, an unlocked device, and a store reset cannot be
///    expressed: this path can add a descriptor, not remove one.
///
/// The two modes are therefore not a preference to be optimised. `backup` stays
/// the default, and this is the opt-in.
enum PosterBoardAirlift {
    /// The bundle whose container holds the store.
    static let bundleID = "com.apple.PosterBoard"

    /// Cached container path.
    ///
    /// The UUID changes on every reinstall and on some OS updates, so a stored
    /// path can be a path to nothing. It is therefore a *cache*, refreshed
    /// whenever an inject fails, and never trusted past a failure.
    private static let containerKey = "PosterBoardAirliftContainer"

    static var cachedContainer: String {
        get { UserDefaults.standard.string(forKey: containerKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: containerKey) }
    }

    /// PosterBoard's data container, looked up over the tunnel.
    @discardableResult
    static func resolveContainer(pairingPath: String) async throws -> String {
        let container = try await Airlift.appContainer(pairingPath: pairingPath, bundleID: bundleID)
        cachedContainer = container
        return container
    }

    /// Inject the selected packs, and respring so they show up.
    ///
    /// - Parameters:
    ///   - selection: the same selection the backup mode takes. Only the packs are
    ///     honoured here; the video stage is a backup-mode concern and is rejected
    ///     by the caller, because its frames are computed and staged locally and
    ///     this path does not carry them.
    ///   - structureVersion: the store directory version. 61 for everything this
    ///     supports, matching `PosterBoard.fallbackStructureVersion`.
    ///   - deviceVersion: the device's iOS version, for the legacy-conversion gate
    ///     only. Same number, same gate and same conversion as the backup path —
    ///     see the note at the conversion itself.
    static func apply(
        selection: PosterBoardSelection,
        structureVersion: Int,
        deviceVersion: String,
        pairingPath: String,
        log: @escaping @Sendable (String) -> Void,
        progress: @escaping (Double) -> Void
    ) async throws {
        let packs = selection.tendies
        guard !packs.isEmpty else { throw GoldenNuggetError("No PosterBoard packs to inject.") }

        var container = cachedContainer
        if container.isEmpty {
            log("Locating \(bundleID) over the tunnel…")
            container = try await resolveContainer(pairingPath: pairingPath)
        }
        if !container.hasSuffix("/") { container += "/" }
        log("PosterBoard container: \(container)")
        // The version directory is not read back from the device — the FFI has no
        // readdir — so it is the one this port knows, and saying so in the log is
        // what makes a descriptor that does not show up diagnosable afterwards.
        log("Store version directory: \(structureVersion)")

        var injected = 0

        // Progress is counted per descriptor, not per pack. A pack is a loop over
        // its descriptors, and each of those opens its own tunnel and syncs its
        // own files, so the time is in the inner loop: reporting once per pack
        // left the bar sitting still for the entire run and jumping at the end.
        //
        // The denominator is counted from the archives' own listings rather than
        // after extraction, because the extraction happens one pack at a time and
        // each stage is deleted as soon as that pack is done — by the time the
        // last descriptor is injected, the earlier counts are gone. Reading the
        // zip directory is cheap and needs no unpack.
        let planned = packs.reduce(0) { $0 + countDescriptors(inArchiveAt: $1.url) }
        var done = 0
        let overall = { (completed: Int) -> Double in
            guard planned > 0 else { return 0 }
            return min(100, Double(completed) / Double(planned) * 100)
        }
        progress(overall(done))

        for (index, pack) in packs.enumerated() {
            log("[\(index + 1)/\(packs.count)] \(pack.name)")
            // The `do` block is what scopes the `defer`. A `defer` written directly
            // in the loop body belongs to the *function*, so every stage would stay
            // on disk until the whole run finished — and a pack that `continue`s
            // would leave its unpack behind for the next launch. A `do` block is a
            // scope, so each pack is cleaned when that pack is done with.
            do {
                let stage = PosterBoard.workDirectory
                    .appendingPathComponent("airlift-\(UUID().uuidString)", isDirectory: true)
                try? FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: stage) }

                do {
                    try await Airlift.extractZip(archivePath: pack.url.path, destDir: stage.path)
                } catch {
                    log("  ⚠️ could not unpack: \(error.localizedDescription)")
                    continue
                }

                // The legacy conversion, on this path too, and for the same reason
                // the backup path runs it: both paths hand PosterBoard the *same*
                // descriptor tree, so a pack converted in one and not the other
                // installs differently depending only on which button was pressed.
                // A pre-27 package injected unconverted is not a cosmetic
                // difference — iOS 27 reads the converted (Clownfish) shape, so the
                // wallpaper lands without the depth effect it was sold with.
                //
                // It has to sit here, before `findDescriptors`: `convertTree` stamps
                // the family into the bundle's own descriptor and
                // `renameDescriptorsToSkeleton` renames the bundles to the stock
                // layout, and both change what the walk below sees.
                if PosterBoard.shouldConvertLegacy(pack: pack, deviceVersion: deviceVersion,
                                                  log: log) {
                    PosterBoard.convertLegacyPack(pack.name, at: stage, log: log)
                }

                let descriptors = findDescriptors(in: stage,
                                                defaultExtension: pack.posterType.extensionBundleID,
                                                log: log)
                guard !descriptors.isEmpty else {
                    log("  ⚠️ no descriptor folders found in this pack")
                    continue
                }
                log("  \(descriptors.count) descriptor(s)")

                for (position, descriptor) in descriptors.enumerated() {
                    let target = UUID().uuidString.uppercased()
                    let numericID = Int.random(in: 10000...99999)
                    // A descriptor that keeps the pack's own identifier collides with
                    // every other copy of that pack on the device, so the id is
                    // randomized on the way in — the directory name and the plist
                    // values have to be rewritten together or PosterBoard indexes a
                    // wallpaper it cannot find.
                    randomizeIdentifiers(in: descriptor.url, numericID: numericID)

                    let parent = container + "Library/Application Support/"
                        + PosterBoard.storeDirectoryName + "/\(structureVersion)/Extensions/"
                        + descriptor.extensionID + "/descriptors"
                    do {
                        try await Airlift.injectFolder(
                            pairingPath: pairingPath,
                            folderPath: descriptor.url.path,
                            targetParentDir: parent,
                            destName: target
                        )
                        injected += 1
                        done += 1
                        log("  ✅ \(position + 1)/\(descriptors.count) → \(descriptor.extensionID)")
                        progress(overall(done))

                        // iOS 18+ moved the collections provider, so the reference
                        // writes the same descriptor to both ids and treats the
                        // second as best-effort (`try?`). Not a duplicate on the
                        // device: the old id is no longer read, the new one is.
                        if descriptor.extensionID == PosterBoardPosterType.collections.extensionBundleID {
                            let modern = container + "Library/Application Support/"
                                + PosterBoard.storeDirectoryName + "/\(structureVersion)"
                                + "/Extensions/com.apple.Posters.CollectionsPosterApp/descriptors"
                            try? await Airlift.injectFolder(
                                pairingPath: pairingPath,
                                folderPath: descriptor.url.path,
                                targetParentDir: modern,
                                destName: target
                            )
                        }
                    } catch {
                        // A stale cached container is the likeliest cause and the one
                        // worth fixing in place rather than making the user retry.
                        cachedContainer = ""
                        // Counted as attempted, not as injected: the bar is about
                        // how much of the queue is behind us, and a failed
                        // descriptor is not going to be retried in this run.
                        done += 1
                        progress(overall(done))
                        log("  ❌ \(descriptor.extensionID): \(error.localizedDescription)")
                    }
                }
            }
        }

        guard injected > 0 else {
            throw GoldenNuggetError("No PosterBoard descriptor was injected. The device has to be "
                + "unlocked with LocalDevVPN up; if it was, the cached container was stale and has "
                + "been cleared for the next attempt.")
        }

        log("Respring so PosterBoard re-reads the store…")
        // The injections are the queue, so the bar is full before the respring;
        // the line below is what the operator is actually waiting on, and a bar
        // that sits at 100% through it reads as finished. This is a userspace
        // restart, not a reboot — the device does not go down.
        progress(99)
        try await Airlift.respring()
        progress(100)
        log("Injected \(injected) descriptor(s).")
    }

    // MARK: - Descriptor discovery

    /// How many descriptors a pack will yield, counted from the archive listing.
    ///
    /// The same rule as `findDescriptors`, applied to entry paths instead of to an
    /// extracted tree, so the number the progress bar divides by is the number of
    /// injections that will actually be attempted. Nothing is unpacked: a child
    /// counts only if something lives *under* it, which is what makes it a
    /// directory once extracted.
    ///
    /// An unreadable archive counts as zero rather than throwing: the count is
    /// only a progress denominator, and a wrong one is recoverable in a way a
    /// failed apply is not — the pack still gets unpacked and injected below.
    private static func countDescriptors(inArchiveAt url: URL) -> Int {
        let archive: Archive
        do {
            archive = try Archive(url: url, accessMode: .read)
        } catch {
            return 0
        }

        // The marker folders `findDescriptors` looks for, in the order it looks
        // for them, paired with whether the extension id comes from the path.
        let markers: [(name: String, fromPath: Bool)] = [
            ("descriptors", true), ("descriptor", true),
            ("ordered-descriptors", true), ("ordered-descriptor", true),
            ("video-descriptors", false), ("video-descriptor", false),
        ]

        var paths: [String] = []
        for entry in archive {
            let parts = entry.path.split(separator: "/").map(String.init)
            guard !parts.contains("__MACOSX") else { continue }
            guard let marker = markers.first(where: { parts.contains($0.name) }),
                  let index = parts.firstIndex(of: marker.name),
                  index + 2 < parts.count,
                  !parts[index + 1].hasPrefix(".")
            else { continue }
            // A store snapshot carries the extension id above the marker; a bare
            // pack does not, and the marker sits at the root instead of nested.
            // Either way one descriptor is the *immediate child* of the marker,
            // so the child name is the whole key — keying on the rest of the path
            // would count every file in the subtree instead.
            paths.append(parts[index + 1])
        }
        return Set(paths).count
    }

    private struct Descriptor {
        let extensionID: String
        let url: URL
    }

    /// The visible, non-hidden subdirectories of `url`, or nothing if it cannot
    /// be read.
    ///
    /// A file-scope helper rather than a nested one, because the store walk and
    /// the finder both need it and a nested function is only in scope inside the
    /// declaration it is written in.
    private static func directories(_ url: URL) -> [URL] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? []
        return entries.filter { entry in
            (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                && !entry.lastPathComponent.hasPrefix(".")
                && entry.lastPathComponent != "__MACOSX"
        }
    }

    /// Every store directory in an unpacked pack, in walk order.
    ///
    /// Found by walking rather than by guessing the layout, because the
    /// reference's guess — `root/container`, then `root` — is wrong twice over
    /// for a real snapshot, and both misses are silent. It has been seen spelled
    /// `container/`, `Container/`, and wrapped in a folder named after the pack,
    /// so `iPhone 18 Pro - All Colors.tendies` unpacks to
    /// `<pack>/Container/Library/Application Support/PRBPosterExtensionDataStore/61/…`
    /// and neither of the two guessed paths exists. A fixed path also cannot see
    /// a store two levels down, so a fix that only tried `root/Container` would
    /// pass the next pack and fail the one after it.
    ///
    /// Bounded and pruned, so this stays cheap: the walk stops descending at a
    /// descriptor tree — nothing inside `descriptors/` is a store, and that is
    /// where a snapshot keeps its hundreds of folders — and at the store itself.
    private static func storeDirectories(in root: URL) -> [URL] {
        let payloadTrees: Set<String> = [
            "descriptors", "descriptor", "ordered-descriptors", "ordered-descriptor",
            "video-descriptors", "video-descriptor",
        ]
        var found: [URL] = []
        // 6 covers the deepest layout seen (pack folder, `Container`, `Library`,
        // `Application Support`) with room to spare, and the pruning is what
        // makes the depth safe rather than the walk itself.
        func walk(_ directory: URL, depth: Int) {
            guard depth > 0 else { return }
            for child in directories(directory) {
                let name = child.lastPathComponent
                if name == PosterBoard.storeDirectoryName {
                    found.append(child)
                    continue
                }
                guard !payloadTrees.contains(name) else { continue }
                walk(child, depth: depth - 1)
            }
        }
        walk(root, depth: 6)
        return found
    }

    /// Every descriptor folder in an unpacked pack, with the extension that owns it.
    ///
    /// A port of the reference's `findDescriptorsWithExtensions`
    /// (`ios-app/TendiesEngine.swift:570`), and the cascade order is load-bearing:
    /// each step returns as soon as it found anything, so a `container/` snapshot
    /// is read through the store's own layout first and a bare pack falls through
    /// to the shapes below.
    ///
    /// This was previously a single rule — a directory named `descriptors`
    /// anywhere under `Extensions/` — which is only step 1 of the reference, and
    /// which matched *nothing* in practice: every pack in the wild is a bare
    /// `descriptors/<UUID>` tree with no `Extensions/` component anywhere in it.
    /// The result was "no descriptor folders found in this pack" for all of them.
    private static func findDescriptors(in root: URL,
                                        defaultExtension: String,
                                        log: (String) -> Void) -> [Descriptor] {
        let manager = FileManager.default

        // 1. A full store snapshot: the extension id is in the path. Every version
        //    directory is read, not just the one we would write to — a snapshot
        //    carries the version it was taken from, which is not necessarily
        //    `fallbackStructureVersion`.
        var found: [Descriptor] = []
        for store in storeDirectories(in: root) {
            let listed = directories(store)
            // A store with no version directory at all cannot be read this way;
            // the write path still has a version, so look there instead.
            let versionFolders = listed.isEmpty
                ? [store.appendingPathComponent(String(PosterBoard.fallbackStructureVersion))]
                : listed
            for versionFolder in versionFolders {
                for extFolder in directories(versionFolder.appendingPathComponent("Extensions")) {
                    let descDir = extFolder.appendingPathComponent("descriptors")
                    guard manager.fileExists(atPath: descDir.path) else { continue }
                    found += directories(descDir).map {
                        Descriptor(extensionID: extFolder.lastPathComponent, url: $0)
                    }
                }
            }
            if !found.isEmpty { break }
        }
        if !found.isEmpty {
            log("  found \(found.count) descriptor folder(s) in the store snapshot")
            return found
        }

        // 2. A bare pack: the descriptor tree is the root's, and the extension is
        //    whatever the user said the pack is for.
        for folderName in ["descriptors", "descriptor", "ordered-descriptors", "ordered-descriptor"] {
            let descDir = root.appendingPathComponent(folderName)
            guard manager.fileExists(atPath: descDir.path) else { continue }
            let entries = directories(descDir)
            guard !entries.isEmpty else { continue }
            log("  found \(entries.count) descriptor folder(s) under \(folderName)/")
            return entries.map { Descriptor(extensionID: defaultExtension, url: $0) }
        }

        // 3. Video descriptors, which only ever belong to the photos provider.
        for folderName in ["video-descriptors", "video-descriptor"] {
            let descDir = root.appendingPathComponent(folderName)
            guard manager.fileExists(atPath: descDir.path) else { continue }
            let entries = directories(descDir)
            guard !entries.isEmpty else { continue }
            log("  found \(entries.count) video descriptor folder(s) under \(folderName)/")
            return entries.map {
                Descriptor(extensionID: "com.apple.PhotosUIPrivate.PhotosPosterProvider", url: $0)
            }
        }

        // 4. The root *is* the descriptor.
        if manager.fileExists(atPath: root.appendingPathComponent("versions").path)
            || manager.fileExists(atPath: root.appendingPathComponent("Wallpaper.plist").path)
            || manager.fileExists(atPath: root.appendingPathComponent(
                "com.apple.posterkit.provider.descriptor.identifier").path) {
            log("  the pack root is the descriptor")
            return [Descriptor(extensionID: defaultExtension, url: root)]
        }

        // 5. Last resort: any immediate subfolder that is a UUID or has a
        //    `versions/` of its own.
        for sub in directories(root) {
            let hasVersions = manager.fileExists(atPath: sub.appendingPathComponent("versions").path)
            guard hasVersions || UUID(uuidString: sub.lastPathComponent) != nil else { continue }
            found.append(Descriptor(extensionID: defaultExtension, url: sub))
        }
        if !found.isEmpty {
            log("  found \(found.count) descriptor folder(s) by shape")
        }
        return found
    }

    /// Rewrite the identifier files so a copy of a pack can be indexed twice.
    ///
    /// The names are PosterBoard's, not ours: a provider descriptor carries its id
    /// in a bare file, and the wallpaper's own plist points at the row it belongs
    /// to. All three have to change together.
    ///
    /// Each is rewritten **only if the shape is there to rewrite**, which the
    /// reference's version is not. It writes the number unconditionally, and that
    /// is right for the shape almost every pack has — 53 of the 62 packs in
    /// `downloaded_wallpapers` carry a bare numeric id and a userInfo that already
    /// has `wallpaperRepresentingIdentifier` — and wrong for the rest:
    ///
    ///  * a provider's own id can be a *string*. `com.apple.MercuryPoster` ships
    ///    `com.apple.posterkit.provider.descriptor.identifier` as `v6x.colorB`, a
    ///    key into the provider's built-in catalogue of looks. Overwriting it with
    ///    a number points the descriptor at a look that does not exist, and
    ///    PosterBoard indexes nothing — a successful injection that installs a
    ///    wallpaper nobody can select. It is left alone instead: the user asked
    ///    for this wallpaper, and the same id in a second, freshly named folder is
    ///    the same wallpaper installed twice, which is the point of the rename.
    ///  * `wallpaperRepresentingIdentifier` is only set where the key already
    ///    exists. Adding it to a userInfo that has never heard of it (one of the
    ///    62, and every Mercury one) writes a field the provider does not read.
    ///
    /// The folder is renamed either way, so a second copy is a second directory.
    private static func randomizeIdentifiers(in folder: URL, numericID: Int) {
        guard let walker = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        while let url = walker.nextObject() as? URL {
            switch url.lastPathComponent {
            case "com.apple.posterkit.provider.descriptor.identifier":
                // Only a bare number is ours to replace; see above for why a
                // provider's string id has to survive.
                if let existing = try? Data(contentsOf: url),
                   let text = String(data: existing, encoding: .utf8),
                   Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) != nil {
                    try? Data(String(numericID).utf8).write(to: url)
                }
            case "com.apple.posterkit.provider.contents.userInfo":
                rewritePlist(url) { plist in
                    guard plist["wallpaperRepresentingIdentifier"] != nil else { return }
                    plist["wallpaperRepresentingIdentifier"] = numericID
                }
            default:
                if url.lastPathComponent.hasSuffix("Wallpaper.plist") {
                    rewritePlist(url) { $0["identifier"] = numericID }
                }
            }
        }
    }

    private static func rewritePlist(_ url: URL, _ mutate: (inout [String: Any]) -> Void) {
        guard let data = try? Data(contentsOf: url),
              var plist = (try? PropertyListSerialization.propertyList(
                  from: data, options: .mutableContainers, format: nil)) as? [String: Any]
        else { return }
        mutate(&plist)
        guard let updated = try? PropertyListSerialization.data(
            fromPropertyList: plist, format: .binary, options: 0) else { return }
        try? updated.write(to: url)
    }
}
