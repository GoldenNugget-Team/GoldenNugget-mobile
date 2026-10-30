import Foundation
import Minimuxer
import DeviceGatewayAPI
import IdeviceGateway
import IDevice

/// AFC-backed media transfer, moving the bulk photo/video trees out of
/// `/var/mobile/Media` and into this app's own container.
///
/// Why AFC and not `mobilebackup2`: the bulk media would otherwise ride the
/// protective backup, which is slow and — before the prune — transfers the whole
/// photo library only to throw it away. AFC reads the device's Media root
/// directly, streamed, one connection per file, so a 2 GB video never has to
/// exist in memory.
///
/// Why not the Photos framework: this needs no `PHPhotoLibrary` authorization
/// and no `NSPhotoLibraryUsageDescription`. AFC reaches the same files the
/// library shows, so a permission prompt would buy nothing.
///
/// Why the trees are narrow (`AFC_MEDIA_TREES` in the reference): only the
/// actual photo/video files move. `PhotoData` — the library database and its
/// protected metadata — is deliberately left alone; `PhotoData/UBF` is not even
/// listable over the media AFC service on iOS 27 (AFC error 10,
/// `PERM_DENIED`). Touching it would fail the whole run.
///
/// The reference's rules are kept verbatim because they are load-bearing:
///   * progress is **strings only** — the mobilebackup2 phase owns the numeric
///     progress bar, and a second numeric feed corrupts it;
///   * pull failures are **fatal** — once the originals are deleted this
///     directory is the only copy of the user's photos, so a silently skipped
///     file is data loss;
///   * symlinks are **skipped**, never followed: following one could escape the
///     Media tree and duplicate content.
enum AfcMediaBackup {
    // The Media page and an apply can both call this store. Reserve the whole
    // transfer so journal appends/compaction and Clear cannot race each other.
    private static let transferLock = NSLock()
    private static var transferActive = false

    private static func beginTransfer() throws {
        transferLock.lock()
        defer { transferLock.unlock() }
        guard !transferActive else {
            throw GoldenNuggetError("A media transfer is still running. Wait for it to finish before changing the media store.")
        }
        transferActive = true
    }

    private static func endTransfer() {
        transferLock.lock()
        transferActive = false
        transferLock.unlock()
    }
    /// The bulk media trees, matching the reference's `AFC_MEDIA_TREES`.
    static let trees = ["DCIM", "PhotoStreamsData"]

    /// 4 MB: the reference's `MAXIMUM_READ_SIZE` neighbourhood. The connection
    /// is held open for the whole file, so this trades memory against syscall
    /// count, not against a per-file connection.
    private static let chunkSize = 4 << 20

    // MARK: - Store

    /// The media store, inside the app container.
    ///
    /// Its own storage and its own manifest, deliberately not the
    /// `MediaDomain` / `CameraRollDomain` rows the protective backup would use:
    /// the restore's prune keeps only rows whose payload it pulled itself, so
    /// media sitting here would be dropped on the next apply unless it were
    /// threaded through the backup manifest as well.
    static var storeRoot: URL {
        AppPaths.mediaStore
    }

    static var manifestURL: URL {
        storeRoot.appendingPathComponent("afc-media.json", conformingTo: .data)
    }

    /// One file's record. `deleted` is whether the original was removed from
    /// the Media tree, which is the only irreversible part of the operation and
    /// therefore is tracked per file rather than per run.
    struct Entry: Codable, Hashable {
        var source: String
        var storedAs: String
        var size: Int64
        var modified: Date?
        var deleted: Bool
    }

    struct Manifest: Codable {
        var version: Int = 1
        var entries: [Entry] = []
    }

    // MARK: - Survey

    struct Survey {
        var files: [AfcFsEntry]
        var bytes: Int64
        var skippedSymlinks: Int
    }

    /// Everything a confirmation dialog needs, without transferring anything:
    /// the file list, the total size, and the free space on the volume the
    /// container actually lives on.
    static func survey() async throws -> Survey {
        let gateway = try await gateway()
        var files: [AfcFsEntry] = []
        var bytes: Int64 = 0
        var symlinks = 0

        for tree in trees {
            guard let root = try? await gateway.afcEntryInfo(path: "/" + tree) else {
                AppLog.write("AFC media: /\(tree) is not listed — skipped")
                continue
            }
            // Was `guard !root.isDirectory else { continue }`, which skipped every
            // tree exactly when it was a directory -- i.e. always. The survey
            // came back empty for every device, which is why AFC "saw no photos".
            guard root.isDirectory else {
                AppLog.write("AFC media: /\(tree) is not a directory — skipped")
                continue
            }
            for entry in try await walk(gateway, path: "/" + tree) {
                if entry.linkTarget != nil { symlinks += 1; continue }
                files.append(entry)
                bytes += entry.size
            }
        }
        return Survey(files: files, bytes: bytes, skippedSymlinks: symlinks)
    }

    /// Free space for the *container's* volume.
    ///
    /// `afcVolumeInfo()` is deliberately not used: it reports the Media volume,
    /// which is a different filesystem from the one the app container lives on.
    /// Comparing media bytes against Media's free space would be measuring the
    /// wrong disk.
    static func containerFreeBytes() -> Int64 {
        let values = try? storeRoot.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }

    /// Whether a transfer owns the store right now. A read-only view of the lock
    /// `beginTransfer` takes, for callers that would otherwise collide with it:
    /// an apply's media stage and the home page's Restore button.
    static var isTransferActive: Bool {
        transferLock.lock()
        defer { transferLock.unlock() }
        return transferActive
    }

    /// What the store holds, for the UI — `nil` when its manifest cannot be read.
    ///
    /// `read()` is memoised on the manifest's own size and date, so this is a
    /// `stat` per call and a decode only when the store actually changed.
    static func storeTotals() -> (files: Int, bytes: Int64)? {
        guard let manifest = try? read() else { return nil }
        return (manifest.entries.count, manifest.entries.reduce(0) { $0 + $1.size })
    }

    // MARK: - Transfer

    /// Pull every media file into the store, then — only if `deletingOriginals`
    /// is set — remove each one after its size has been verified.
    ///
    /// Ordering is the whole point: write, close, verify against what the device
    /// reported for that path, and only then delete. A file whose copy does not
    /// match keeps its original, always.
    static func pull(
        deletingOriginals: Bool,
        onProgress: ((String) -> Void)? = nil
    ) async throws -> Manifest {
        try beginTransfer()
        defer { endTransfer() }
        let gateway = try await gateway()
        try FileManager.default.createDirectory(at: storeRoot, withIntermediateDirectories: true)

        let survey = try await survey()
        onProgress?("AFC media: \(survey.files.count) file(s), "
            + "\(ByteCountFormatter.string(fromByteCount: survey.bytes, countStyle: .file))")

        // The store outlives one pull. In particular, deleted originals will
        // never appear in another survey, so their existing rows must survive.
        var manifest = try read()
        var indices: [String: Int] = [:]
        for (index, row) in manifest.entries.enumerated() { indices[row.source] = index }
        var done: Int64 = 0
        var alreadyStored = 0
        var alreadyStoredBytes: Int64 = 0

        for entry in survey.files {
            let relative = String(entry.path.dropFirst())          // drop the leading "/"
            let destination = try localMediaPath(relative)

            // Already held, at the size and modification date the device reports
            // now: streaming it again would rewrite an identical file. This is
            // what makes the automatic top-up (setup finish, then every launch)
            // a directory walk instead of a second full copy of the library.
            //
            // The modification date is the tie-breaker, not the size: a photo
            // edited in place keeps its path and can keep its size, and the same
            // date on both sides is the device saying "unchanged since the pull
            // that stored this".
            if let index = indices[entry.path] {
                let row = manifest.entries[index]
                let attributes = try? FileManager.default.attributesOfItem(atPath: destination.path)
                if row.size == entry.size, row.modified == entry.modified,
                   attributes?[.type] as? FileAttributeType == .typeRegular,
                   (attributes?[.size] as? NSNumber)?.int64Value == entry.size {
                    done += entry.size
                    alreadyStored += 1
                    alreadyStoredBytes += entry.size
                    // The copy is already good, but the destructive half still
                    // has to happen when it was asked for: the automatic top-up
                    // fills this store, so the Media page's switch would
                    // otherwise find every file already stored and delete
                    // nothing.
                    if deletingOriginals,
                       let marked = try await deleteOriginal(afterStored: entry,
                                                             storedAs: row.storedAs,
                                                             onProgress: onProgress) {
                        manifest.entries[index] = marked
                        try appendJournal(marked)
                    }
                    continue
                }
            }

            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

            // Write to a sidecar first: a cancelled or failed transfer must not
            // leave a short file that a later run would treat as complete.
            let partial = destination.appendingPathExtension("afcpartial")
            try? FileManager.default.removeItem(at: partial)
            FileManager.default.createFile(atPath: partial.path, contents: nil)
            let handle = try FileHandle(forWritingTo: partial)

            let written: Int64
            do {
                written = try await gateway.afcStreamFile(path: entry.path, chunkSize: chunkSize) {
                    chunk in
                    try handle.write(contentsOf: chunk)
                }
                try handle.synchronize()
                try handle.close()
            } catch {
                // The callback runs on the gateway's worker. Read the file's
                // offset after it finishes instead of mutating a captured counter.
                let partialWritten = (try? handle.offset()) ?? 0
                try? handle.close()
                try? FileManager.default.removeItem(at: partial)
                // Fatal: the store is the only copy once originals are deleted.
                throw GoldenNuggetError(
                    "AFC media: \(entry.path) failed after \(partialWritten) byte(s) — "
                    + "no original was removed.")
            }

            // Verify before the irreversible half. The device's own size is the
            // reference; the byte count we wrote is only a cross-check.
            let copied = (try? FileManager.default
                .attributesOfItem(atPath: partial.path)[.size] as? NSNumber)??.int64Value ?? -1
            guard copied == entry.size, written == entry.size else {
                try? FileManager.default.removeItem(at: partial)
                throw GoldenNuggetError(
                    "AFC media: \(entry.path) size mismatch — device reports "
                    + "\(entry.size), wrote \(copied) / \(written). Original kept.")
            }

            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: partial)
            } else {
                try FileManager.default.moveItem(at: partial, to: destination)
            }

            // Commit the verified copy BEFORE removing its original. Even if
            // deletion succeeds and the process dies immediately afterwards,
            // push() can still find and restore the copy (regardless of deleted).
            let saved = Entry(source: entry.path, storedAs: relative, size: entry.size,
                              modified: entry.modified, deleted: false)
            let savedIndex: Int
            if let index = indices[entry.path] {
                savedIndex = index
                manifest.entries[index] = saved
            } else {
                savedIndex = manifest.entries.count
                manifest.entries.append(saved)
                indices[entry.path] = savedIndex
            }
            try appendJournal(saved)

            var deleted = false
            if deletingOriginals && entry.size <= inlineWriteLimit {
                let current = try await gateway.afcEntryInfo(path: entry.path)
                guard !current.isDirectory, current.linkTarget == nil,
                      current.size == entry.size, current.modified == entry.modified else {
                    throw GoldenNuggetError("AFC media: \(entry.path) changed during transfer. Original kept.")
                }
                do {
                    try await gateway.afcDelete(path: entry.path)
                    deleted = true
                } catch {
                    // The copy is already verified, so a failed delete is a
                    // lesser problem than the reverse and is reported, not fatal.
                    onProgress?("AFC media: could not remove \(entry.path) — copy is intact")
                }
            }

            if deletingOriginals && entry.size > inlineWriteLimit {
                onProgress?("AFC media: original kept for \(relative) — exceeds the 64 MiB restore limit")
            }
            manifest.entries[savedIndex].deleted = deleted
            if deleted { try appendJournal(manifest.entries[savedIndex]) }

            done += entry.size
            onProgress?("AFC media: \(relative) — "
                + "\(ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file)), "
                + "total \(ByteCountFormatter.string(fromByteCount: done, countStyle: .file))")
        }

        if alreadyStored > 0 {
            onProgress?("AFC media: \(alreadyStored) file(s) already stored, "
                + "\(ByteCountFormatter.string(fromByteCount: alreadyStoredBytes, countStyle: .file)) "
                + "not transferred")
        }
        if survey.skippedSymlinks > 0 {
            onProgress?("AFC media: skipped \(survey.skippedSymlinks) symlink(s)")
        }
        try write(manifest)
        return manifest
    }

    /// The destructive half for a file whose copy is already in the store.
    ///
    /// Same rules as the streamed path: the original is removed only after the
    /// device itself still reports the size and date the stored copy was
    /// verified against, and a file above the AFC write limit keeps its original
    /// because `push` could not put it back.
    ///
    /// Returns the row to journal as `deleted`, or `nil` when the original was
    /// kept — a kept original is logged, never fatal: the copy is intact either
    /// way, and the pull's own job is already done.
    private static func deleteOriginal(
        afterStored entry: AfcFsEntry,
        storedAs: String,
        onProgress: ((String) -> Void)?
    ) async throws -> Entry? {
        guard entry.size <= inlineWriteLimit else {
            onProgress?("AFC media: original kept for \(storedAs) — exceeds the 64 MiB restore limit")
            return nil
        }
        let gateway = try await gateway()
        guard let current = try? await gateway.afcEntryInfo(path: entry.path) else {
            onProgress?("AFC media: could not re-check \(entry.path) — original kept, copy is intact")
            return nil
        }
        guard !current.isDirectory, current.linkTarget == nil,
              current.size == entry.size, current.modified == entry.modified else {
            onProgress?("AFC media: \(entry.path) changed during transfer — original kept")
            return nil
        }
        do {
            try await gateway.afcDelete(path: entry.path)
        } catch {
            onProgress?("AFC media: could not remove \(entry.path) — copy is intact")
            return nil
        }
        return Entry(source: entry.path, storedAs: storedAs, size: entry.size,
                     modified: entry.modified, deleted: true)
    }

    /// Put everything back after checking the complete local inventory.
    /// Local copies remain available until the user explicitly clears the store.
    static func push(onProgress: ((String) -> Void)? = nil) async throws {
        try beginTransfer()
        defer { endTransfer() }
        let manifest = try read()
        // Fail before writing any device file if a recorded copy is missing,
        // truncated or linked. A partially valid store is not a successful restore.
        for entry in manifest.entries {
            let local = try localMediaPath(entry.storedAs)
            let attributes = try FileManager.default.attributesOfItem(atPath: local.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  (attributes[.size] as? NSNumber)?.int64Value == entry.size else {
                throw GoldenNuggetError("AFC media store is incomplete: \(entry.storedAs). Restore stopped; local copies kept.")
            }
        }
        let gateway = try await gateway()
        var restored = 0
        var skipped = 0

        for entry in manifest.entries {
            let local = try localMediaPath(entry.storedAs)
            // Every level has to exist before the leaf. One afcMakeDirectory call
            // for "/DCIM/100APPLE" fails when /DCIM is absent, and `try?` used to
            // swallow exactly that, so the write then failed with a message that
            // pointed nowhere near the real cause.
            for directory in ancestors(of: entry.source) {
                try? await gateway.afcMakeDirectory(path: directory)
            }

            // `afcWrite` takes the whole file as one `Data`, and there is no
            // streaming write in the gateway API — so unlike the pull there is
            // no way to avoid holding it in memory. A file that does not fit is
            // reported and skipped rather than risking a jetsam kill that takes
            // the run down with it; the local copy is left untouched either way.
            let size = (try? FileManager.default
                .attributesOfItem(atPath: local.path)[.size] as? NSNumber)??.int64Value ?? 0
            guard size <= Self.inlineWriteLimit else {
                onProgress?("AFC push: \(entry.storedAs) is \(size) byte(s) — too large "
                    + "to write over AFC (limit \(Self.inlineWriteLimit)); local copy kept")
                skipped += 1
                continue
            }

            let data = try Data(contentsOf: local)
            guard data.count == entry.size else {
                throw GoldenNuggetError("AFC media store changed while reading \(entry.storedAs). Restore stopped.")
            }
            try await gateway.afcWrite(path: entry.source, data: data)

            // The pull verifies before deleting, so the push verifies before
            // reporting: a short write is caught here rather than discovered
            // later as a truncated photo.
            let written = (try? await gateway.afcEntryInfo(path: entry.source))?.size ?? -1
            guard written == size else {
                onProgress?("AFC push: \(entry.source) size mismatch — device reports "
                    + "\(written), expected \(size)")
                skipped += 1
                continue
            }
            restored += 1
            onProgress?("AFC push: \(entry.source)")
        }
        onProgress?("AFC push: \(restored) restored, \(skipped) skipped")
        if skipped > 0 {
            throw GoldenNuggetError("AFC media restore incomplete: \(skipped) file(s) could not be restored. Local copies kept.")
        }
    }

    /// `/DCIM/100APPLE/IMG_0001.JPG` -> `["/DCIM", "/DCIM/100APPLE"]`, outermost
    /// first, which is the order AFC needs them created in.
    private static func ancestors(of path: String) -> [String] {
        var out: [String] = []
        var parts = path.split(separator: "/").map(String.init)
        guard parts.count > 1 else { return [] }
        parts.removeLast()
        var prefix = ""
        for part in parts {
            prefix += "/" + part
            out.append(prefix)
        }
        return out
    }

    /// The largest file `afcWrite` will take. Chosen to stay clear of the memory
    /// a jetsam kill would cost, not to match anything the device reports.
    static let inlineWriteLimit: Int64 = 64 << 20

    /// Empty the store, once the originals are back and verified on the device.
    static func clear() throws {
        try beginTransfer()
        defer { endTransfer() }
        let fm = FileManager.default
        if fm.fileExists(atPath: storeRoot.path) { try fm.removeItem(at: storeRoot) }
        // The manifest lives inside the store, so the line above normally takes
        // it. Kept for the case where only the file is there.
        if fm.fileExists(atPath: manifestURL.path) { try fm.removeItem(at: manifestURL) }
        invalidateCache()
    }

    // MARK: - Internals

    /// Keep recovery journal paths inside the two media trees, without links.
    private static func localMediaPath(_ relative: String) throws -> URL {
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 2, trees.contains(String(parts[0])),
              !relative.contains("\\"), !relative.contains("\0"),
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw GoldenNuggetError("Unsafe AFC media path: \(relative)")
        }
        var target = storeRoot
        for part in [""] + parts.map(String.init) {
            if !part.isEmpty { target.appendPathComponent(part) }
            if let attributes = try? FileManager.default.attributesOfItem(atPath: target.path),
               attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                throw GoldenNuggetError("Linked AFC media path: \(relative)")
            }
        }
        return target
    }

    /// Depth-first listing, `afcList` per directory, symlinks reported rather
    /// than followed. A directory that cannot be listed throws: silently
    /// skipping it would drop photos without a trace.
    private static func walk(_ gateway: IdeviceGateway, path: String) async throws -> [AfcFsEntry] {
        var out: [AfcFsEntry] = []
        for entry in try await gateway.afcList(path: path) {
            if entry.linkTarget != nil { continue }
            if entry.isDirectory {
                out += try await walk(gateway, path: entry.path)
            } else {
                out.append(entry)
            }
        }
        return out
    }

    private static func gateway() async throws -> IdeviceGateway {
        guard let gateway = Minimuxer.shared().ideviceGateway else {
            throw GoldenNuggetError("AFC media: no idevice gateway — is the tunnel up?")
        }
        return gateway
    }

    /// Small append-only records avoid rewriting a whole photo-library index
    /// twice per file. Each verified copy is fsynced here before its deletion.
    static var journalURL: URL { storeRoot.appendingPathComponent("afc-media.journal") }

    private static func appendJournal(_ entry: Entry) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: journalURL.path) {
            guard fm.createFile(atPath: journalURL.path, contents: nil) else {
                throw GoldenNuggetError("AFC media: could not create the recovery journal. Originals kept.")
            }
        }
        let handle = try FileHandle(forUpdating: journalURL)
        defer { try? handle.close() }
        let end = try handle.seekToEnd()
        if end > 0 {
            try handle.seek(toOffset: end - 1)
            if try handle.read(upToCount: 1)?.first != 0x0a {
                // Discard a killed append before adding another record; without
                // this, its partial JSON would swallow the next complete row.
                var cursor = end
                var boundary: UInt64 = 0
                while cursor > 0 {
                    let start = cursor > 4096 ? cursor - 4096 : 0
                    try handle.seek(toOffset: start)
                    let chunk = try handle.read(upToCount: Int(cursor - start)) ?? Data()
                    if let index = chunk.lastIndex(of: 0x0a) {
                        boundary = start + UInt64(chunk.distance(from: chunk.startIndex, to: index)) + 1
                        break
                    }
                    cursor = start
                }
                try handle.truncate(atOffset: boundary)
            }
        }
        try handle.seekToEnd()
        var data = try JSONEncoder().encode(entry)
        data.append(0x0a)
        try handle.write(contentsOf: data)
        try handle.synchronize()
        invalidateCache()
    }

    private static func write(_ manifest: Manifest) throws {
        let data = try JSONEncoder().encode(manifest)
        try FileManager.default.createDirectory(at: storeRoot, withIntermediateDirectories: true)
        try data.write(to: manifestURL, options: .atomic)
        let handle = try FileHandle(forWritingTo: manifestURL)
        defer { try? handle.close() }
        try handle.synchronize()
        // The complete index is durable first. Replaying a surviving journal
        // after a crash is idempotent because its records replace by source.
        if FileManager.default.fileExists(atPath: journalURL.path) {
            try FileManager.default.removeItem(at: journalURL)
        }
        invalidateCache()
    }

    private static func invalidateCache() {
        cacheLock.lock()
        cachedKey = ""
        cachedManifest = nil
        cacheLock.unlock()
    }

    /// The decoded store manifest, memoised on the file's own identity.
    ///
    /// This used to read and JSON-decode the whole document on every call, and one
    /// of its callers runs inside a SwiftUI `body`: `GoldenNuggetView`'s Media card
    /// badge calls it on **every** body pass — i.e. once per log line during a run
    /// (see `RunLog`), on the main thread.  The store can hold thousands of entries,
    /// so that decode is milliseconds where a `stat` is microseconds.
    ///
    /// The cache key is the file's size + modification date, which is enough
    /// because `write` replaces the file atomically: any save changes at least one
    /// of the two, and the next read decodes again.  A missing file is cached as
    /// `Manifest()` under a key no real file can produce.
    private static let cacheLock = NSLock()
    private static var cachedKey = ""
    private static var cachedManifest: Manifest?

    static func read() throws -> Manifest {
        let key = manifestCacheKey()
        cacheLock.lock()
        if let cachedManifest, cachedKey == key {
            cacheLock.unlock()
            return cachedManifest
        }
        cacheLock.unlock()

        var manifest: Manifest
        if FileManager.default.fileExists(atPath: manifestURL.path) {
            // A damaged journal must never be mistaken for an empty store and
            // overwritten by a new destructive pull.
            manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
        } else {
            manifest = Manifest()
        }
        if FileManager.default.fileExists(atPath: journalURL.path) {
            let journal = try Data(contentsOf: journalURL)
            var indices: [String: Int] = [:]
            for (index, row) in manifest.entries.enumerated() { indices[row.source] = index }
            let lines = journal.split(separator: 0x0a, omittingEmptySubsequences: true)
            for (index, line) in lines.enumerated() {
                // A killed append's final unterminated row never authorized
                // deletion. The next append repairs it before writing again.
                if index == lines.count - 1 && journal.last != 0x0a { break }
                let entry = try JSONDecoder().decode(Entry.self, from: Data(line))
                if let existing = indices[entry.source] { manifest.entries[existing] = entry }
                else {
                    indices[entry.source] = manifest.entries.count
                    manifest.entries.append(entry)
                }
            }
        }
        guard manifest.version == 1 else { throw GoldenNuggetError("Unsupported AFC media journal version.") }
        var sources = Set<String>()
        for entry in manifest.entries {
            guard entry.size >= 0, entry.source == "/" + entry.storedAs,
                  sources.insert(entry.source).inserted else {
                throw GoldenNuggetError("Invalid AFC media journal entry: \(entry.source)")
            }
            _ = try localMediaPath(entry.storedAs)
        }
        cacheLock.lock()
        cachedKey = key
        cachedManifest = manifest
        cacheLock.unlock()
        return manifest
    }

    /// `"<size>:<mtime>"`, or `"<absent>"` when there is no manifest yet.
    private static func manifestCacheKey() -> String {
        [manifestURL, journalURL].map { url in
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = attrs[.size] as? Int,
                  let modified = attrs[.modificationDate] as? Date else {
                return "\(url.path):<absent>"
            }
            return "\(url.path):\(size):\(modified.timeIntervalSince1970)"
        }.joined(separator: "|")
    }
}
