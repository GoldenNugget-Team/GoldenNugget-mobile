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
/// The backup names the device's own app record in FactoryInfo. A scoped
/// filter accepts only that live container, even if iOS also offers other apps.
/// Database-only fetches retain the SQLite store and companions; Protective
/// applies additionally retain all existing descriptor files and preferences.
///
/// The stream's device path maps each accepted file to its backup file ID.
/// Both AppDomain paths and iOS 27's /.b/<n>/Containers/... paths are supported.
/// Cached copies in this app's container cannot be mistaken for the live store.
/// The newest numeric store layout is selected, with its exact WAL companion,
/// and missing snapshot files abort before restore.
enum PosterBoardBackup {
    struct Result {
        /// The consolidated database, cached under `Documents/PosterBoard/`.
        let database: URL
        /// The store directory version parsed out of the database's own path.
        let structureVersion: Int
        /// How it was found — a manifest row, or a scan of the shard tree.
        let locatedBy: String
        /// Existing container files carried forward by a Protective apply.
        let preservedPayloads: [TweakPayload]
        /// Native backup graph, including empty directories and original MBFile metadata.
        let snapshotDirectory: URL?
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
                      preserveExisting: Bool = false,
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
                let path = PosterBoardSnapshot.relativePath(deviceName: deviceName, container: container)
                let isStore = path.map { PosterBoardSnapshot.isStoreFile(relativePath: $0) } ?? false
                let keepContainerFile = path != nil && (preserveExisting || isStore)
                let keep = ProtectiveBackup.isMetadataFile(fileName) || keepContainerFile
                counter.note(deviceName: deviceName, fileName: fileName,
                             keep: keep, isStore: isStore,
                             relativePath: keepContainerFile ? path : nil)
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
        let captured = try PosterBoardSnapshot.payloads(offers: counter.files, backupRoot: backupRoot, udid: udid)
        let databases = captured.filter { PosterBoardSnapshot.storeVersion(relativePath: $0.relativePath) != nil }
            .sorted { structureVersion(of: $0.relativePath) > structureVersion(of: $1.relativePath) }
        guard let main = databases.first, let mainSource = main.source else {
            throw GoldenNuggetError("The backup did not carry a database from the live PosterBoard container.")
        }
        let extracted = Extracted(main: mainSource,
            wal: captured.first { $0.relativePath == main.relativePath + "-wal" }?.source,
            locatedBy: "live container /" + main.relativePath,
            structureVersion: structureVersion(of: main.relativePath))
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
        if preserveExisting && ios27 {
            _ = try PosterBoardSnapshot.records(in: deviceDir)
            let baseline = destination.deletingLastPathComponent()
                .appendingPathComponent("Recovery/" + udid + "/Baseline", isDirectory: true)
            try PosterBoardSnapshot.retainBaseline(from: deviceDir, at: baseline)
            log("PosterBoard: original pre-apply recovery snapshot retained at " + baseline.path)
        }
        return Result(database: consolidated,
                      structureVersion: extracted.structureVersion,
                      locatedBy: extracted.locatedBy,
                      preservedPayloads: preserveExisting ? captured : [],
                      snapshotDirectory: preserveExisting && ios27 ? deviceDir : nil)
    }

    // MARK: - Extraction

    private struct Extracted {
        let main: URL
        let wal: URL?
        let locatedBy: String
        let structureVersion: Int
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

    /// Produce a standalone SQLite snapshot even when no WAL was uploaded.
    /// A main file can still carry WAL journal mode without a companion. Opening
    /// that copy read-only can require sidecar creation/recovery and fail before
    /// sqlite_master is readable. Work on a writable private copy, then publish
    /// a DELETE-mode snapshot with no dependency on sidecars from an earlier fetch.
    private static func consolidate(main: URL,
                                    wal: URL?,
                                    destination: URL,
                                    log: @escaping @Sendable (String) -> Void) throws -> URL {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("posterboard-\(UUID().uuidString)",
                                                                isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        let scratch = work.appendingPathComponent("source.sqlite3")
        let snapshot = work.appendingPathComponent("snapshot.sqlite3")
        try fm.copyItem(at: main, to: scratch)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: scratch.path)
        if let wal, fileSize(wal) > 0 {
            let scratchWAL = URL(fileURLWithPath: scratch.path + "-wal")
            try fm.copyItem(at: wal, to: scratchWAL)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: scratchWAL.path)
        }
        // Never copy -shm: SQLite must rebuild it against this exact WAL.
        try fold(source: scratch, into: snapshot)
        if let complaint = PosterBoardStore.diagnose(snapshot, strict: false) {
            throw GoldenNuggetError("The downloaded PosterBoard store could not be prepared: "
                + complaint)
        }
        try fm.createDirectory(at: destination.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        // Validation of an older WAL-mode cache may have created these. Removing
        // only its main file leaves stale journal state for the replacement.
        for suffix in ["", "-wal", "-shm", "-journal"] {
            let old = URL(fileURLWithPath: destination.path + suffix)
            if fm.fileExists(atPath: old.path) { try fm.removeItem(at: old) }
        }
        try fm.moveItem(at: snapshot, to: destination)
        log("PosterBoard: prepared standalone store snapshot ("
            + "\(fileSize(destination)) bytes, journal_mode=DELETE)")
        return destination
    }

    /// Both the backup step and finish must succeed. A failed merge must not
    /// silently fall back to a main file that omits committed wallpaper rows.
    private static func fold(source sourcePath: URL, into destination: URL) throws {
        var sourceHandle: OpaquePointer?
        var mergedHandle: OpaquePointer?
        defer {
            sqlite3_close(sourceHandle)
            sqlite3_close(mergedHandle)
        }
        func failure(_ stage: String, _ db: OpaquePointer?) -> GoldenNuggetError {
            GoldenNuggetError("PosterBoard snapshot \(stage) failed: "
                + String(cString: sqlite3_errmsg(db))
                + " (SQLite \(sqlite3_extended_errcode(db))).")
        }
        guard sqlite3_open_v2(sourcePath.path, &sourceHandle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let source = sourceHandle else {
            throw failure("opening downloaded store", sourceHandle)
        }
        guard sqlite3_open(destination.path, &mergedHandle) == SQLITE_OK,
              let merged = mergedHandle else {
            throw failure("creating snapshot", mergedHandle)
        }
        sqlite3_busy_timeout(source, 1000)
        sqlite3_busy_timeout(merged, 1000)
        guard let backup = sqlite3_backup_init(merged, "main", source, "main") else {
            throw failure("starting backup", merged)
        }
        let step = sqlite3_backup_step(backup, -1)
        let finish = sqlite3_backup_finish(backup)
        guard step == SQLITE_DONE, finish == SQLITE_OK else {
            throw failure("copying pages (step \(step), finish \(finish))", merged)
        }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(merged, "PRAGMA journal_mode=DELETE", -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW,
              let mode = sqlite3_column_text(statement, 0),
              String(cString: mode).lowercased() == "delete" else {
            throw failure("normalizing journal mode", merged)
        }
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
    private var _files: [String: String] = [:]

    func note(deviceName: String, fileName: String, keep: Bool, isStore: Bool, relativePath: String?) {
        lock.lock()
        defer { lock.unlock() }
        if let relativePath { _files[relativePath] = fileName }
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

    var files: [String: String] { lock.lock(); defer { lock.unlock() }; return _files }

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
