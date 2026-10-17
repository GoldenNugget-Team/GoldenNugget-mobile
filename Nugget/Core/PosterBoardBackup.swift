import Foundation
import Minimuxer
import SQLite3

/// Fetches the device's **own** PosterBoard database.
///
/// A port of `src/restore/posterboard_backup.py` (`targeted_posterboard_database_backup`)
/// plus `protective.extract_posterboard_db` and `posterboard_structure_version`.
///
/// This is the one piece of the PosterBoard feature that has no alternative.
/// The store's database is where a wallpaper *is*: its descriptor directory is
/// inert on its own, and the row set (provider registrations, role memberships,
/// usage metadata) cannot be synthesised because the device's own rows carry
/// values the host cannot invent. So the device has to hand its store over.
///
/// Two facts make that possible, and both are in the reference:
///
///   1. The device uploads an app's container only when the host names that app
///      in the backup's `FactoryInfo`. The protective backup this app already
///      runs passes an **empty** `Applications`, which is exactly why it never
///      sees PosterBoard. A targeted backup naming `com.apple.PosterBoard`
///      (with the record the device itself gave us) makes it upload the store.
///   2. A mid-stream filter drains everything else, so the run stays small: no
///      photos, no other app's data, nothing but the database is ever written.
///
/// The database is then pulled out of the backup's own `Manifest.db` — matched
/// by **file name**, not by path, which is the reference's own rule
/// (`extract_posterboard_db` sorts the matching rows by path and takes the
/// highest, i.e. the newest store layout).
///
/// Matching by name rather than by shape is not defensive padding: the path the
/// store arrives under really does vary, and the two shapes observed so far are
/// not the same backup flow, so neither can be assumed for the other:
///
///   * an **iTunes/MobileSync full backup** of this iPad (iPad16,2, iOS 27.0
///     24A5424a) carries it as `AppDomain-com.apple.PosterBoard` +
///     `Library/Application Support/PRBPosterExtensionDataStore/61/<name>.sqlite3`
///     — no `Containers/`, and not one path in that backup starts with `/`;
///   * the reference's own diagnostics count rows LIKE `'%Containers/%'`,
///     which is the shape a **mobilebackup2 targeted backup** (what this app
///     does) is written for.
///
/// What this app's targeted fetch actually produces has not been captured yet,
/// which is why `extract` also has a lookup that ignores the manifest entirely
/// and reads the payloads by content.
enum PosterBoardBackup {
    struct Result {
        /// The consolidated database, cached under `Documents/PosterBoard/`.
        let database: URL
        /// The store directory version parsed out of the database's own path.
        let structureVersion: Int
        /// How it was found — a manifest row, or a scan of the shard tree.
        let locatedBy: String
    }

    /// Where a fetched database is kept between runs.
    static func cachedDatabase(udid: String) -> URL {
        URL.documents.appendingPathComponent("PosterBoard/\(udid).sqlite3", conformingTo: .data)
    }

    /// Run the targeted backup and return the consolidated database.
    ///
    /// - Parameter ios27: the device speaks the sqlite `Manifest.db` (iOS 27+) or the
    ///   legacy MBDB format (iOS 26).  It decides what the *host* writes: a sqlite
    ///   manifest the device reads, or nothing at all.  It does **not** decide how the
    ///   store is found — that lookup goes through the payloads themselves when the
    ///   manifest cannot answer (see `extract`), so the flat MBDB layout is covered too.
    static func fetch(backupRoot: URL,
                      udid: String,
                      ios27: Bool = true,
                      onProgress: ((Double) -> Void)? = nil,
                      log: @escaping @Sendable (String) -> Void) async throws -> Result {
        let fm = FileManager.default
        try? fm.removeItem(at: backupRoot)
        try fm.createDirectory(at: backupRoot, withIntermediateDirectories: true)
        let deviceDir = AppPaths.deviceDir(backupRoot: backupRoot, udid: udid)

        // 1. The app record the device itself gave us. Forwarded, not composed:
        //    the entry's shape is the device's contract, and the reference's own
        //    fallbacks (`ApplicationSINF` → b"", `iTunesMetadata` → {}) are only
        //    correct for a record the device produced.
        log("PosterBoard: asking the device for the \(PosterBoard.bundleID) container…")
        let entry = try await Minimuxer.shared().appFactoryEntry(bundleId: PosterBoard.bundleID)
        let container = entry["Container"] as? String ?? ""
        log("PosterBoard: container \(container.isEmpty ? "<not reported>" : container) — "
            + "\(entry.keys.count) field(s) from the device's own record: "
            + "\(entry.keys.sorted().joined(separator: ", "))")
        // `Container` is the knob itself. Without it the device has nothing to
        // upload, and the only thing a backup would then produce is the host's
        // own metadata — which is exactly what a 265-second run returned once,
        // failing only at the end. Refuse here instead: the answer is known in
        // about a second, and this is the one precondition worth asserting.
        guard !container.isEmpty else {
            throw GoldenNuggetError(
                "The device's own record for \(PosterBoard.bundleID) carries no Container, so "
                + "there is nothing for a backup to upload. Fields it did return: "
                + "\(entry.keys.sorted().joined(separator: ", ")). The entry is forwarded "
                + "verbatim from installation_proxy — it is not composed here — so this is the "
                + "device declining to name the container, not a malformed request.")
        }

        // 2. Host-side metadata. `isFullBackup: true` is the same marker the
        //    protective pull uses and for the same reason: a sparse marker asks
        //    the device to send whatever the manifest lists, which is nothing.
        // `ios27` goes to both halves. It is one fork, and the two files it
        // decides are read as a pair by the device: give `ensure` the 3.3/10.0
        // metadata while the manifest is the legacy shape and the run is
        // incoherent before it starts.
        try HostManifests.ensure(deviceDir: deviceDir, udid: udid, ios27: ios27,
                                 isFullBackup: true,
                                 applications: [PosterBoard.bundleID: entry])
        try HostManifests.writeSQLiteManifest(deviceDir: deviceDir, ios27: ios27)

        // 3. The backup itself. The filter keeps the database and its WAL
        //    companions — `…sqlite3-wal` contains the name too — plus the backup
        //    metadata files, which must never be drained or the backup is
        //    un-restorable.
        let counter = Counter()
        try await Minimuxer.shared().backupBackup(
            backupRoot: backupRoot.path(percentEncoded: false),
            sourceIdentifier: udid,
            applications: [PosterBoard.bundleID: entry],
            shouldPreserve: { deviceName, fileName in
                // **The device's own name is the first argument, and matching
                // the wrong argument is what made this fetch return nothing.**
                //
                // `mb2_should_preserve(deviceName, fileName)` hands the host two
                // strings, and they are not the same kind of thing: `fileName`
                // is the *host* path the payload is being written to — its last
                // component is the 40-hex fileID, which is what the 0-byte
                // placeholder stand-ins in the log are named after — while
                // `deviceName` is the path the device knows the file by
                // (`AppDomain-com.apple.PosterBoard/Library/…`, or the raw
                // container tree). The reference filters on `device_name`
                // (`_pb_only` → `_domain_match` / `_posterboard_db_match`).
                //
                // The first version of this filter ignored the device name and
                // searched `fileName` for the database's name. A fileID never
                // contains it, so every PosterBoard file was drained: the run
                // reported "6 kept of 29078 offered", the six being exactly the
                // host-side metadata files, and failed 4.4 minutes later.
                //
                // Both strings are still checked, because which of them carries
                // the device path is not something this file can observe, and
                // being wrong costs a full device run. A false positive would
                // require a fileID to contain the database's name.
                let inDevice = deviceName.contains(PosterBoard.databaseFileName)
                let inFile = fileName.contains(PosterBoard.databaseFileName)
                let mentionsStore = inDevice || inFile
                // The metadata files are the one thing named on the host side.
                let keep = ProtectiveBackup.isMetadataFile(fileName) || mentionsStore
                counter.note(deviceName: deviceName, fileName: fileName,
                             keep: keep, isStore: mentionsStore)
                return keep
            },
            onProgress: { overall in
                if let step = counter.noteProgress(overall) {
                    log("PosterBoard backup stream: \(step)% — \(counter.summary)")
                }
                onProgress?(overall)
            },
            delegateLog: { line in AppLog.write(line) }
        )
        log("PosterBoard: backup done — \(counter.summary)")
        // Logged on every run, not only on failure: the first few offers are the
        // only record of which string this device's stream carries the path in.
        log("PosterBoard: offers — \(counter.sample())")
        // The store itself has to have come through — metadata alone is not a result.
        // The first version accepted any kept file at all, so a run that carried nothing
        // but `Status.plist` went on to fail several stages later, deep in the manifest
        // reader, with a message about a table. The device's own names are the evidence,
        // and they are right here.
        guard counter.posterBoardKept > 0 else {
            throw GoldenNuggetError(
                "The device uploaded nothing for \(PosterBoard.bundleID): \(counter.kept) of "
                + "\(counter.total) offered file(s) went through the keep-filter and not one of "
                + "them was \(PosterBoard.databaseFileName). Either the container was never "
                + "offered — the factory info it was handed did not name it, or the device "
                + "declined — or it was offered under a name the filter did not recognise; the "
                + "names below tell the two apart. Offers: \(counter.sample()). "
                + "(A kept count that is exactly the host's metadata set — Info.plist, "
                + "Manifest.plist, Status.plist, Manifest.db and its -shm/-wal — means the "
                + "filter matched nothing the device streamed, not that the device sent "
                + "nothing: check whether the names being matched are the device's or the "
                + "host's.)")
        }

        // 4. Pull it out, merge the WAL, and hand back the version it was found
        //    at so the restored copy lands in the same store directory.
        let extracted = try extract(backupRoot: backupRoot, udid: udid,
                                    deviceName: counter.posterBoardName, log: log)
        let destination = cachedDatabase(udid: udid)
        try fm.createDirectory(at: destination.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        let consolidated = try consolidate(main: extracted.main,
                                           wal: extracted.wal,
                                           destination: destination,
                                           log: log)
        // Named, not just "did not validate": the log used to stop on the line
        // above, which left the copy and the validation as the two candidates
        // and nothing to tell them apart.
        if let complaint = PosterBoardStore.diagnose(consolidated, strict: false) {
            log("PosterBoard: the fetched database was rejected — \(complaint). Tables: "
                + "\(PosterBoardStore.describeTables(consolidated)).")
            throw GoldenNuggetError("The PosterBoard database fetched from the device did not "
                + "validate (\(complaint)). Fetch it again.")
        }
        log("PosterBoard: database ready — \(extracted.locatedBy), structure version "
            + "\(extracted.structureVersion), "
            + ByteCountFormatter.string(fromByteCount: fileSize(consolidated), countStyle: .file))
        return Result(database: consolidated,
                      structureVersion: extracted.structureVersion,
                      locatedBy: extracted.locatedBy)
    }

    // MARK: - Extraction

    private struct Extracted {
        let main: URL
        let wal: URL?
        let locatedBy: String
        let structureVersion: Int
    }

    /// `extract_posterboard_db`: find the database out of the fetched backup.
    ///
    /// Two ways, in this order, and the second one exists because the first one's premise
    /// is not guaranteed:
    ///
    ///  1. **The device's own manifest row.**  This is what the reference does
    ///     (`SELECT fileID, relativePath FROM Files WHERE relativePath LIKE
    ///     '%PBFPosterExtensionDataStoreSQLiteDatabase.sqlite3%'`, highest path first, and
    ///     the `-wal` sibling for a WAL merge).  It goes through `ManifestStore` rather
    ///     than a second copy of that query, because on this engine `Manifest.db` is not
    ///     always the schema a reader expects: the host writes a libimobiledevice-shaped
    ///     placeholder (`ManifestEntry` + `Properties`) for the *device* to read, and the
    ///     device's own `Files`-shaped database replaces it only when it uploads one.
    ///
    ///  2. **A scan of the shard tree**, matching on content: a SQLite database that has
    ///     the store's `poster` table, and beside it the (single) SQLite WAL.  A filtered
    ///     backup keeps so few files that this is cheap, and it does not care what the
    ///     manifest says at all — which matters, because the first real run of this fetch
    ///     died on exactly that: the run carried metadata only, the manifest left on disk
    ///     was the host's placeholder, and the failure surfaced several steps later as
    ///     "could not query the backup's Manifest.db" with nothing about why.
    ///
    /// - Parameter deviceName: the device's own name for the store, captured by the
    ///   keep-filter.  It is the best source for the structure version: it is the path the
    ///   *device* uses, so it is right even when the manifest is unreadable.
    private static func extract(backupRoot: URL, udid: String, deviceName: String?,
                                log: @escaping @Sendable (String) -> Void) throws -> Extracted {
        let deviceDir = AppPaths.deviceDir(backupRoot: backupRoot, udid: udid)
        let store = ManifestStore(deviceDir: deviceDir)

        // ① the rule the device itself reports, via the single owner of Manifest.db
        var manifestTrouble: String?
        do {
            let rows = try store.rows(relativePathLike: "%\(PosterBoard.databaseFileName)%")
            if let candidate = rows.first(where: {
                $0.relativePath.hasSuffix(PosterBoard.databaseFileName)
            }) {
                guard let payload = candidate.payload else {
                    throw GoldenNuggetError("The manifest lists \(candidate.relativePath) but its "
                        + "payload is not on disk — the mid-stream filter dropped it.")
                }
                let wal = rows.first { $0.relativePath == candidate.relativePath + "-wal" }?.payload
                log("PosterBoard: found \(candidate.relativePath) "
                    + "(fileID \(candidate.fileID.prefix(12))…"
                    + (wal == nil ? ", no WAL companion)" : ", with a WAL companion)"))
                return Extracted(main: payload, wal: wal,
                                 locatedBy: "manifest row \(candidate.relativePath)",
                                 structureVersion: structureVersion(of: deviceName
                                                                    ?? candidate.relativePath))
            }
            manifestTrouble = rows.isEmpty
                ? "the manifest carries no row mentioning \(PosterBoard.databaseFileName)"
                : "the manifest has \(rows.count) matching row(s) but none is the store itself"
        } catch {
            manifestTrouble = error.localizedDescription
        }

        // ② the fallback: whatever is actually in the shard tree
        log("PosterBoard: the manifest did not resolve the store (\(manifestTrouble ?? "unknown") "
            + "— scanning the \(store.payloadFiles().count) payload(s) on disk by content")
        if let scanned = scanForStore(in: store) {
            log("PosterBoard: found the store by content \(scanned.locatedBy)")
            return Extracted(main: scanned.main, wal: scanned.wal,
                             locatedBy: scanned.locatedBy,
                             structureVersion: structureVersion(of: deviceName ?? scanned.locatedBy))
        }

        throw GoldenNuggetError(
            "The fetched backup does not hold the PosterBoard store. \(manifestTrouble ?? "") "
            + "Manifest.db tables: \(store.tableNames.isEmpty ? "none" : store.tableNames.joined(separator: ", ")). "
            + "Payloads on disk: \(store.payloadFiles().map(\.lastPathComponent).prefix(10).joined(separator: ", ")). "
            + (store.tableNames.contains("ManifestEntry")
               ? "Those tables are the host-written placeholder — the device never uploaded its "
                 + "own Manifest.db, which happens when it does not take the container it was "
                 + "asked for."
               : "No payload is a PosterBoard database."))
    }

    /// The store found by reading the payloads, with the WAL paired only when exactly one
    /// candidate of each kind exists: a mismatched WAL would do nothing (SQLite checks its
    /// salt against the database and discards what does not belong), but guessing pairs is
    /// still worse than saying "no WAL".
    private static func scanForStore(in store: ManifestStore)
        -> (main: URL, wal: URL?, locatedBy: String)? {
        let payloads = store.payloadFiles()
        let stores = payloads.filter(isPosterBoardDatabase)
        guard let main = stores.first else { return nil }
        let wals = payloads.filter(isSQLiteWAL)
        let wal = stores.count == 1 && wals.count == 1 ? wals[0] : nil
        return (main, wal, "shard scan (fileID \(main.lastPathComponent.prefix(12))…, "
                + "\(stores.count) store(s) and \(wals.count) WAL candidate(s) found)")
    }

    /// Whether a payload is a SQLite database carrying the store's own marker table.
    ///
    /// `poster` and not "any sqlite": the backup may hold more than one database, and the
    /// store's schema is the one thing that identifies it without consulting a manifest.
    private static func isPosterBoardDatabase(_ url: URL) -> Bool {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let db else {
            sqlite3_close(db)
            return false
        }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'poster' LIMIT 1"
        return sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK
            && sqlite3_step(stmt) == SQLITE_ROW
    }

    /// Whether a payload begins with the SQLite WAL magic.  It has no tables to query, so
    /// the header is the only thing to match on.
    private static func isSQLiteWAL(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 4), header.count == 4 else { return false }
        // 0x377f0682 / 0x377f0683, big-endian, checksum-order dependent.
        return header[0] == 0x37 && header[1] == 0x7f && header[2] == 0x06
            && (header[3] == 0x82 || header[3] == 0x83)
    }

    /// `posterboard_structure_version`: the digits right after the store
    /// directory's name, 61 when the name is absent from the path.
    ///
    /// 61 is the oldest supported layout, and it is the reference's own fallback
    /// — it is only reachable from a path that omits the store directory, which
    /// some iOS 27 upload paths do.
    static func structureVersion(of path: String) -> Int {
        let marker = "\(PosterBoard.storeDirectoryName)/"
        guard let range = path.range(of: marker) else {
            return PosterBoard.fallbackStructureVersion
        }
        let digits = path[range.upperBound...].prefix { $0.isNumber }
        return Int(digits) ?? PosterBoard.fallbackStructureVersion
    }

    // MARK: - Consolidation

    /// Fold the `-wal` companion into the main file, if there is one.
    ///
    /// The store runs in WAL mode, so recent wallpaper data can live in the WAL
    /// rather than the main file — and copying the bare main file would lose it.
    /// The `-shm` is deliberately **not** copied: a stale shared-memory file
    /// desyncs against the WAL and is a classic "database disk image is
    /// malformed".
    ///
    /// SQLite's own backup API does the fold, which is what the reference's
    /// `src.backup(merged)` is; on any failure this falls back to the plain
    /// file, exactly as the reference does.
    private static func consolidate(main: URL,
                                    wal: URL?,
                                    destination: URL,
                                    log: @escaping @Sendable (String) -> Void) throws -> URL {
        let fm = FileManager.default
        try? fm.removeItem(at: destination)
        guard let wal else {
            do {
                try fm.copyItem(at: main, to: destination)
            } catch {
                log("PosterBoard: copying the store onto the cache failed — "
                    + "\(error.localizedDescription) (from \(main.lastPathComponent), "
                    + "\(fileSize(main)) bytes, onto \(destination.path))")
                throw error
            }
            return destination
        }

        let work = fm.temporaryDirectory.appendingPathComponent("posterboard-\(UUID().uuidString)",
                                                                conformingTo: .data)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        let scratch = work.appendingPathComponent("posterboard.sqlite3")
        do {
            try fm.copyItem(at: main, to: scratch)
            try fm.copyItem(at: wal, to: URL(fileURLWithPath: scratch.path + "-wal"))
        } catch {
            log("PosterBoard: staging the store and its WAL failed — "
                + "\(error.localizedDescription) (store \(fileSize(main)) bytes, "
                + "WAL \(fileSize(wal)) bytes, in \(work.lastPathComponent))")
            throw error
        }

        let folded = fold(source: scratch, into: destination)
        if !folded || !PosterBoardStore.validate(destination, strict: false) {
            let reason = folded
                ? (PosterBoardStore.diagnose(destination, strict: false) ?? "validation failed")
                : "the backup API refused"
            log("PosterBoard: WAL consolidation did not produce a healthy database "
                + "(\(reason)) — using the plain file, which is what the reference falls "
                + "back to as well")
            try? fm.removeItem(at: destination)
            try fm.copyItem(at: main, to: destination)
        }
        return destination
    }

    /// SQLite's online-backup API, the Swift spelling of the reference's
    /// `src.backup(merged)`.
    ///
    /// Both handles are closed before this returns: the destination's connection
    /// holds the `journal_mode` pragma, and a reader opened while it is still
    /// live is not guaranteed to see the copy.
    private static func fold(source sourcePath: URL, into destination: URL) -> Bool {
        var source: OpaquePointer?
        var merged: OpaquePointer?
        defer {
            sqlite3_close(source)
            sqlite3_close(merged)
        }
        guard sqlite3_open_v2(sourcePath.path, &source, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              sqlite3_open(destination.path, &merged) == SQLITE_OK,
              let source, let merged else { return false }
        guard let backup = sqlite3_backup_init(merged, "main", source, "main") else { return false }
        sqlite3_backup_step(backup, -1)
        sqlite3_backup_finish(backup)
        sqlite3_exec(merged, "PRAGMA journal_mode=DELETE", nil, nil, nil)
        return true
    }

    private static func fileSize(_ url: URL) -> Int64 {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
    }
}

/// What the targeted backup offered and what the filter did with it.
///
/// The device decides what to upload, so a run that keeps nothing has to say
/// what it was offered — that sample is the only record of how this iOS names
/// the container's files.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var _total = 0
    private var _kept = 0
    private var _posterBoardKept = 0
    private var _posterBoardName: String?
    private var _samples: [String] = []
    private var _lastStep = -1
    private var _posterBoardOffers: [String] = []

    func note(deviceName: String, fileName: String, keep: Bool, isStore: Bool) {
        lock.lock()
        defer { lock.unlock() }
        _total += 1
        if keep { _kept += 1 }
        // The store *itself*, not its `-wal`/`-shm` siblings — those contain the
        // name too. Its device-side path is the best source for the structure
        // version, and its presence decides whether this fetch produced anything.
        if keep, isStore, !deviceName.hasSuffix("-wal"), !deviceName.hasSuffix("-shm") {
            _posterBoardKept += 1
            if _posterBoardName == nil { _posterBoardName = deviceName }
        }
        // The first few offers are printed as a PAIR, which is the only way to
        // settle, from a log alone, which of the two strings carries the device
        // path. That question cost one full device run to answer.
        if _samples.count < 5 {
            _samples.append("\(keep ? "+" : "-") device=\(deviceName) file=\(fileName)")
        } else if _samples.count < 20 {
            _samples.append("\(keep ? "+" : "-") \(deviceName)")
        }
        // Anything mentioning PosterBoard is worth seeing when nothing matched:
        // it says whether the container was uploaded under an unexpected name.
        let haystack = (deviceName + " " + fileName).lowercased()
        if _posterBoardOffers.count < 10
            && (haystack.contains("poster") || haystack.contains("prb")) {
            _posterBoardOffers.append(deviceName.isEmpty ? fileName : deviceName)
        }
    }

    func noteProgress(_ overall: Double) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        let step = Int(overall / 5) * 5
        guard step != _lastStep else { return nil }
        _lastStep = step
        return step
    }

    var total: Int { lock.lock(); defer { lock.unlock() }; return _total }
    var kept: Int { lock.lock(); defer { lock.unlock() }; return _kept }
    var posterBoardKept: Int { lock.lock(); defer { lock.unlock() }; return _posterBoardKept }
    /// The device's own name for the store file, e.g.
    /// `/.b/1/Containers/…/PRBPosterExtensionDataStore/62/…sqlite3` (iOS 27) or
    /// `AppDomain-com.apple.PosterBoard/Library/Application Support/…` (the shape
    /// this iPad's own iTunes backup uses).
    var posterBoardName: String? { lock.lock(); defer { lock.unlock() }; return _posterBoardName }

    var summary: String {
        lock.lock()
        defer { lock.unlock() }
        return "\(_kept) kept of \(_total) offered"
    }

    func sample() -> String {
        lock.lock()
        defer { lock.unlock() }
        let poster = _posterBoardOffers.isEmpty
            ? "no name mentioning PosterBoard"
            : _posterBoardOffers.joined(separator: " | ")
        return _samples.joined(separator: " | ") + " // posterboard-ish: " + poster
    }
}
