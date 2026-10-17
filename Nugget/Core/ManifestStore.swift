import CryptoKit
import Foundation
import SQLite3

/// The backup 3.3 manifest schema, in one place.
///
/// This used to be spelled out four times: `pruneManifestDb`, the (unused)
/// `createEmptyManifestDb`, `ingestFileRow`, and the dead `Backup
/// .generateManifestSQLite`.  Two of those copies also restated the fileID rule.
/// A schema drift between copies is a silent, device-side validation failure, so
/// there is now exactly one definition.
enum ManifestSchema {
    /// SQLite's destructor sentinel for "copy this buffer now".
    static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    static let insertOrReplaceRow =
        "INSERT OR REPLACE INTO Files (fileID, domain, relativePath, flags, file) VALUES (?, ?, ?, ?, ?)"
}

/// The single owner of a backup's `Manifest.db`.
///
/// Every mutation of the manifest — pruning it to what is on disk, inserting an
/// injected file row — goes through here.  Nothing else in the app opens this
/// database, which is what makes the fileID rule and the schema checkable in one
/// read.
struct ManifestStore {
    /// `<backupRoot>/<udid>/` — the directory holding Manifest.db and the shards.
    let deviceDir: URL

    init(deviceDir: URL) {
        self.deviceDir = deviceDir
    }

    var dbPath: String {
        deviceDir.appendingPathComponent("Manifest.db").path
    }

    var exists: Bool {
        FileManager.default.fileExists(atPath: dbPath)
    }

    /// The number of rows in the `Files` table.
    ///
    /// Returns 0 — rather than throwing — when the database is absent or is the
    /// host-written placeholder (which has no `Files` table). Both are the answer
    /// `BackupBaseline` needs: it is checking whether there is anything worth
    /// retaining or seeding, and "nothing" is a legitimate 0.
    func rowCount() -> Int {
        guard let db = try? open() else { return 0 }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM Files", -1, &stmt, nil) == SQLITE_OK else {
            return 0
        }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
    }

    /// Delete every `Files` row of one domain and return how many were removed.
    ///
    /// Used when seeding a retained manifest for a *merged* pull: a container
    /// fetched that way has its rows pruned and its payloads swept as orphans at
    /// the end of every run, while the retained manifest still lists them. Telling
    /// the device those files are unknown (by dropping the rows) makes it upload
    /// them again instead of answering "unchanged, do not send".
    func dropRows(domain: String) -> Int {
        guard let db = try? open() else { return 0 }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "DELETE FROM Files WHERE domain = ?", -1, &stmt, nil) == SQLITE_OK else {
            return 0
        }
        sqlite3_bind_text(stmt, 1, domain, -1, ManifestSchema.transient)
        guard sqlite3_step(stmt) == SQLITE_DONE else { return 0 }
        return Int(sqlite3_changes(db))
    }

    /// The fileID of a manifest row: `sha1("<domain>-<relativePath>")` in hex.
    ///
    /// This is the join between the database and the payload tree — the payload
    /// for a row lives at `<deviceDir>/<fileID.prefix(2)>/<fileID>` — so it must
    /// be byte-identical everywhere.  It used to exist twice (an instance method
    /// on the dead `BackupFile` class and a file-private function here).
    static func fileID(domain: String, relativePath: String) -> String {
        sha1Hex("\(domain)-\(relativePath)")
    }

    /// Payload path for a row, i.e. the shard layout the device expects.
    func payloadURL(forFileID fileID: String) -> URL {
        deviceDir.appendingPathComponent(String(fileID.prefix(2)), isDirectory: true)
            .appendingPathComponent(fileID)
    }

    /// SHA-1 in lowercase hex.
    static func sha1Hex(_ value: String) -> String {
        let digest = Insecure.SHA1.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02hhx", $0) }.joined()
    }

    // MARK: - Opening

    /// Open the manifest, or throw if the file is not there.
    private func open() throws -> OpaquePointer {
        var db: OpaquePointer?
        guard sqlite3_open(dbPath, &db) == SQLITE_OK, let db else {
            throw GoldenNuggetError("Failed to open Manifest.db at \(dbPath)")
        }
        return db
    }

    // MARK: - Writing rows

    /// Insert (or replace) one file row.
    func upsert(fileID: String, domain: String, relativePath: String,
                flags: Int32, blob: Data) throws {
        let db = try open()
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, ManifestSchema.insertOrReplaceRow, -1, &stmt, nil) == SQLITE_OK,
              let stmt else {
            throw GoldenNuggetError("Manifest.db: failed to prepare INSERT for \(domain)/\(relativePath)")
        }
        defer { sqlite3_finalize(stmt) }

        fileID.withCString { cID in
            domain.withCString { cDom in
                relativePath.withCString { cRel in
                    sqlite3_bind_text(stmt, 1, cID, -1, ManifestSchema.transient)
                    sqlite3_bind_text(stmt, 2, cDom, -1, ManifestSchema.transient)
                    sqlite3_bind_text(stmt, 3, cRel, -1, ManifestSchema.transient)
                    sqlite3_bind_int(stmt, 4, flags)
                    _ = blob.withUnsafeBytes { ptr in
                        sqlite3_bind_blob(stmt, 5, ptr.baseAddress, Int32(blob.count),
                                          ManifestSchema.transient)
                    }
                }
            }
        }
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE else {
            throw GoldenNuggetError("Manifest.db: INSERT for \(domain)/\(relativePath) failed with code \(rc)")
        }
    }

    // MARK: - Reading rows

    /// One row of the manifest, for a caller that needs to find a file in the backup.
    struct Row {
        let fileID: String
        let domain: String
        let relativePath: String
        /// Where the payload lives — nil when the file is not on disk, which is a
        /// state the device answers with `MBErrorDomain/205`.
        let payload: URL?
    }

    /// The tables this manifest actually has.
    ///
    /// Here because the file at `Manifest.db` is **not always** the schema a reader
    /// expects.  On iOS 27 the *host* writes a libimobiledevice-shaped placeholder for
    /// the device to read (`ManifestEntry` + `Properties`, see `HostManifests
    /// .writeSQLiteManifest`), and the device's own `Files`-shaped database replaces it
    /// only if the device uploads one.  A reader that fails with "no such table: Files"
    /// and nothing else leaves the operator guessing which of the two they are holding —
    /// which is exactly what happened the first time `PosterBoardBackup` ran.
    var tableNames: [String] {
        guard let db = try? open() else { return [] }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT name FROM sqlite_master WHERE type = 'table'",
                                 -1, &stmt, nil) == SQLITE_OK else { return [] }
        var names: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let text = sqlite3_column_text(stmt, 0) { names.append(String(cString: text)) }
        }
        return names.sorted()
    }

    /// Rows whose `relativePath` matches a SQL `LIKE` pattern, longest path first.
    ///
    /// Longest-first because the reference resolves the PosterBoard store by taking the
    /// highest matching path: the store directory carries a numeric structure version, so
    /// ordering by path picks the newest layout when a device somehow has more than one.
    func rows(relativePathLike pattern: String) throws -> [Row] {
        let db = try open()
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT fileID, domain, relativePath FROM Files "
                                     + "WHERE relativePath LIKE ? ORDER BY relativePath DESC",
                                 -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw GoldenNuggetError("Manifest.db has no readable Files table "
                + "(tables present: \(tableNames.isEmpty ? "none" : tableNames.joined(separator: ", "))). "
                + "That is the host-written placeholder, not the database the device uploads.")
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, pattern, -1, ManifestSchema.transient)

        var rows: [Row] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let idText = sqlite3_column_text(stmt, 0),
                  let domainText = sqlite3_column_text(stmt, 1),
                  let pathText = sqlite3_column_text(stmt, 2) else { continue }
            let fileID = String(cString: idText)
            let url = payloadURL(forFileID: fileID)
            rows.append(Row(fileID: fileID,
                            domain: String(cString: domainText),
                            relativePath: String(cString: pathText),
                            payload: FileManager.default.fileExists(atPath: url.path) ? url : nil))
        }
        return rows
    }

    /// Every payload in the backup, whatever the manifest says.
    ///
    /// Both layouts, because the two manifest formats ship payloads differently: the
    /// sqlite one (iOS 27) uses the `fileID` shard tree —
    /// `<deviceDir>/<fileID.prefix(2)>/<fileID>` — while the legacy MBDB one (iOS 26)
    /// leaves them flat in `deviceDir`.  A *filtered* backup can also hold payloads the
    /// manifest no longer accounts for, and the manifest itself can be the host's
    /// placeholder, so this is the inventory that survives all of it.
    ///
    /// The three host-written metadata files are skipped: they sit in the same directory
    /// and are not payloads.
    func payloadFiles() -> [URL] {
        let fm = FileManager.default
        let metadata = Set(["Info.plist", "Manifest.plist", "Manifest.db", "Manifest.db-shm",
                            "Manifest.db-wal", "Status.plist", "Manifest.mbdb"])
        guard let entries = try? fm.contentsOfDirectory(at: deviceDir,
                                                        includingPropertiesForKeys: [.isDirectoryKey])
        else { return [] }
        var files: [URL] = []
        for entry in entries {
            let name = entry.lastPathComponent
            if entry.hasDirectoryPath {
                if name.count == 2 {
                    let contents = (try? fm.contentsOfDirectory(
                        at: entry, includingPropertiesForKeys: nil)) ?? []
                    files.append(contentsOf: contents.filter { !$0.hasDirectoryPath })
                }
            } else if !metadata.contains(name) {
                files.append(entry)
            }
        }
        return files.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    // MARK: - Pruning
    /// What `pruneToDiskState()` did, for the log line and for callers that want
    /// to react to a shortfall.
    struct PruneReport {
        /// Every row in the table before the rewrite.
        let rows: Int
        /// Rows the keep-set named AND that have a payload (or need none).
        let kept: Int
        /// Rows the keep-set named but that have no payload on disk.  Dropped,
        /// like GoldenNugget does — a file row without a payload is exactly what
        /// the device reports as `MBErrorDomain/205`.
        let missingPayloads: Int
        let orphansRemoved: Int
        /// Flags histogram of the rows that survived, e.g. `1×471 2×16695`.
        /// `flags` is the value the device reads a "file type" out of, so what
        /// survives matters as much as what is dropped.
        let keptFlags: String

        /// Rows outside the keep-set entirely.
        var outsideKeepSet: Int { rows - kept - missingPayloads }

        var logLine: String {
            var line = "Pruned Manifest.db: \(kept) of \(rows) row(s) kept "
                + "(\(missingPayloads) named by the keep-set but payload-less, "
                + "\(outsideKeepSet) outside the keep-set), "
                + "\(orphansRemoved) orphan payload file(s) removed."
            line += " Kept rows by flags: \(keptFlags)."
            if missingPayloads > 0 {
                line += " A payload-less row is what the device reports as MBErrorDomain/205."
            }
            return line
        }
    }

    /// Prune the manifest in place: delete rows for files not present on disk,
    /// remove orphan payload files, and clean empty shard directories.
    ///
    /// This is the second half of the filtered-backup contract.  The device
    /// records every payload it uploaded in the Manifest.db it sends — including
    /// the ones the host filter drained — and the mobilebackup2 delegate keeps a
    /// 0-byte stand-in for each of those on disk only until the backup exchange
    /// is over (see `MobileBackup2BackupContext.cleanupPlaceholders`).  Once the
    /// stand-ins are gone, those rows are exactly the "payload missing on disk"
    /// set this drops, so the manifest and the tree agree again before a restore
    /// is attempted.
    ///
    /// - Returns: nil when there was no Manifest.db to prune.
    @discardableResult
    func pruneToDiskState() -> PruneReport? {
        guard exists else {
            AppLog.write("Prune Manifest.db: no Manifest.db at \(dbPath) — skipped")
            return nil
        }
        guard let db = try? open() else {
            AppLog.write("Prune Manifest.db: could not open \(dbPath) — skipped")
            return nil
        }
        defer { sqlite3_close(db) }

        // Roll the whole rewrite back if any step fails: a half-pruned manifest
        // is worse than an unpruned one, because the device then sees rows whose
        // payloads are gone (MBErrorDomain/205) with no way to tell which
        // failure produced them.
        var stmt: OpaquePointer?
        var keepIDs: [String] = []
        var rowCount = 0
        var payloadLess = 0
        var payloadLessSample: [String] = []
        var keptFlags: [Int32: Int] = [:]

        guard sqlite3_exec(db, "BEGIN", nil, nil, nil) == SQLITE_OK else {
            AppLog.write("Prune Manifest.db: could not begin a transaction — skipped")
            return nil
        }
        var committed = false
        defer {
            if !committed {
                sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
                AppLog.write("Prune Manifest.db: rolled back — the manifest is untouched")
            }
        }

        // Phase 1: apply the keep-set to every row.
        //
        // The keep-set is GoldenNugget's predicate on `(domain, relativePath)`
        // — see `ProtectiveBackup.keepsRow`.  It used to be "the payload exists
        // on disk", which answers a *different* question: it keeps a row the
        // keep-set excludes as long as something was uploaded for it, and it
        // drops a symlink row, whose payload never exists.  The reference
        // resolves both by predicate, so this does too.
        if sqlite3_prepare_v2(db, "SELECT fileID, domain, relativePath, flags FROM Files",
                              -1, &stmt, nil) == SQLITE_OK, let stmt {
            defer { sqlite3_finalize(stmt) }
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let cID = sqlite3_column_text(stmt, 0) else { continue }
                rowCount += 1
                let fileID = String(cString: cID)
                let domain = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
                let relPath = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
                let flags = sqlite3_column_int(stmt, 3)

                guard ProtectiveBackup.keepsRow(domain: domain, relativePath: relPath) else {
                    continue
                }

                // Only regular files carry a `<aa>/<fileID>` payload, so only
                // they are subject to the payload test.  GoldenNugget spells the
                // rule as `flags == 1 and not payload_exists`, and the flags it
                // does NOT name are the reason: a directory row (2) must survive
                // without a payload — "dropping them makes the restore agent fail
                // with renameatx ENOENT" — and a symlink row (4) has no payload
                // by definition and must survive all the same.
                if flags == 1,
                   !FileManager.default.fileExists(atPath: payloadURL(forFileID: fileID).path) {
                    payloadLess += 1
                    if payloadLessSample.count < 5 {
                        payloadLessSample.append("\(domain)/\(relPath)")
                    }
                    continue
                }
                keepIDs.append(fileID)
                keptFlags[flags, default: 0] += 1
            }
        }

        if payloadLess > 0 {
            AppLog.write("Prune: dropping \(payloadLess) row(s) the keep-set named but that have no "
                + "payload on disk (e.g. \(payloadLessSample.joined(separator: ", "))) — a file row "
                + "without a payload is what the device reports as MBErrorDomain/205")
        }

        // Phase 2: rewrite the table against the keep set.
        guard sqlite3_exec(db,
                           "CREATE TEMP TABLE IF NOT EXISTS _keep (fileID TEXT)",
                           nil, nil, nil) == SQLITE_OK else {
            AppLog.write("Prune Manifest.db: could not create the keep table — skipped")
            return nil
        }

        var insert: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT INTO _keep (fileID) VALUES (?)", -1, &insert, nil) == SQLITE_OK,
              let insert else {
            AppLog.write("Prune Manifest.db: could not prepare the keep insert — skipped")
            return nil
        }
        // Prepared ONCE, outside the loop: the original re-prepared the statement
        // for every kept row, which is a full compile of the INSERT per file on a
        // filtered whole-device backup (tens of thousands of rows).
        for fid in keepIDs {
            sqlite3_reset(insert)
            sqlite3_clear_bindings(insert)
            _ = fid.withCString { sqlite3_bind_text(insert, 1, $0, -1, ManifestSchema.transient) }
            sqlite3_step(insert)
        }
        sqlite3_finalize(insert)

        guard sqlite3_exec(db, "DELETE FROM Files WHERE fileID NOT IN (SELECT fileID FROM _keep)",
                           nil, nil, nil) == SQLITE_OK else {
            AppLog.write("Prune Manifest.db: the row rewrite failed — skipped")
            return nil
        }
        sqlite3_exec(db, "DROP TABLE _keep", nil, nil, nil)

        guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else {
            AppLog.write("Prune Manifest.db: commit failed — skipped")
            return nil
        }
        committed = true

        let orphansRemoved = removeOrphanPayloads(keepIDs: Set(keepIDs))

        let histogram = keptFlags.sorted { $0.key < $1.key }
            .map { "\($0.key)×\($0.value)" }
            .joined(separator: " ")
        let report = PruneReport(rows: rowCount, kept: keepIDs.count,
                                 missingPayloads: payloadLess,
                                 orphansRemoved: orphansRemoved,
                                 keptFlags: histogram.isEmpty ? "(none)" : histogram)
        AppLog.write(report.logLine)
        return report
    }

    /// One line describing exactly what the host is about to hand the device.
    ///
    /// The device restores what `Manifest.db` says and fails the run when the two
    /// disagree ("Manifest references files not in backup"), but the host never
    /// had a consolidated view of its own tree — the detail was spread across the
    /// prune, inject and placeholder lines, each counting something different.
    /// This is that view, taken immediately before the restore.
    ///
    /// `missingPayloads` is the number that matters.  Non-zero means the host is
    /// offering the device rows it cannot fulfil, which is the host-side shape of
    /// a restore that stops short: the device plans work it will never get the
    /// bytes for.  Directory rows (`flags == 2`) **and symlink rows
    /// (`flags == 4`)** have no payload by definition and are counted separately
    /// so they cannot mask a real gap — and so they do not *look* like one.
    ///
    /// The symlink half is not cosmetic: `pruneToDiskState` deliberately keeps
    /// `flags == 4` rows payload-less (GoldenNugget parity), so counting them as
    /// missing made this line report `INCONSISTENT` on a backup that was
    /// perfectly consistent.  The 2026-09-21 run said "2 missing their payload";
    /// both were the 2 surviving symlink rows (e.g. `ba6b3d08…` =
    /// `HomeDomain/Library/Shortcuts/ToolKit/Tools-active`, `flags = 4` in the
    /// device's own manifest).  A verdict that is always red carries no signal.
    func auditAgainstDisk() -> String {
        guard exists, let db = try? open() else {
            return "pre-restore audit: no readable Manifest.db at \(dbPath)"
        }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        // `file IS NULL OR length(file) = 0` is the third thing the device can
        // read a "type" out of: a row whose blob is empty has no `Mode` at all.
        guard sqlite3_prepare_v2(
            db, "SELECT fileID, flags, (file IS NULL OR length(file) = 0), file FROM Files",
            -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return "pre-restore audit: could not read Manifest.db"
        }
        defer { sqlite3_finalize(stmt) }

        var fileRows = 0
        var dirRows = 0
        var symlinkRows = 0
        var missingPayloads = 0
        var bloblessRows = 0
        var unreadableModes = 0
        var firstMissing: String?
        var firstBlobless: String?
        var firstUnreadable: String?
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let cID = sqlite3_column_text(stmt, 0) else { continue }
            let fileID = String(cString: cID)
            let flags = sqlite3_column_int(stmt, 1)
            if sqlite3_column_int(stmt, 2) != 0 {
                bloblessRows += 1
                if firstBlobless == nil { firstBlobless = fileID }
                continue
            }
            let count = sqlite3_column_bytes(stmt, 3)
            guard count > 0, let raw = sqlite3_column_blob(stmt, 3) else { continue }
            // Fourth thing the device reads a "type" out of, and the one that
            // actually bit us: a `Mode` that is an object reference rather than
            // an inline number makes `decodeIntegerForKey:` raise on the device,
            // which answers "Invalid file type: 00".  Checked here so the log
            // names it instead of leaving a 205 to be interpreted.
            if mbFileBlobMode(Data(bytes: raw, count: Int(count))) == nil {
                unreadableModes += 1
                if firstUnreadable == nil { firstUnreadable = fileID }
            }
            if flags == 2 {
                dirRows += 1
                continue
            }
            if flags == 4 {
                symlinkRows += 1
                continue
            }
            fileRows += 1
            if !FileManager.default.fileExists(atPath: payloadURL(forFileID: fileID).path) {
                missingPayloads += 1
                if firstMissing == nil { firstMissing = fileID }
            }
        }

        // Both halves are reported: a row with a payload but no blob is just as
        // unusable to the device as the reverse, and until now only the payload
        // half was ever counted.
        let verdict = (missingPayloads == 0 && bloblessRows == 0 && unreadableModes == 0)
            ? "consistent"
            : "INCONSISTENT — the device cannot restore these rows"
        var line = "pre-restore audit: \(fileRows) file row(s), \(dirRows) directory row(s), "
            + "\(symlinkRows) symlink row(s), \(missingPayloads) missing their payload, "
            + "\(bloblessRows) with an empty file blob, \(unreadableModes) with an unreadable Mode "
            + "— \(verdict)"
        if let firstMissing { line += " (first payload-less: \(firstMissing))" }
        if let firstBlobless { line += " (first blob-less: \(firstBlobless))" }
        if let firstUnreadable { line += " (first unreadable Mode: \(firstUnreadable))" }
        return line
    }

    /// Our injected row's `MBFile` shape next to the device's own.
    ///
    /// `MBErrorDomain/205 — "Invalid file type: 00"` (2026-09-20) came back after
    /// the device had pulled 7 of the 471 payloads it was offered. `205` is a
    /// class of error, not a cause, so the description is the only discriminator
    /// — and "file type" points at the metadata the device decodes out of a
    /// Files row's `file` blob. Rows this app did not write still carry the blob
    /// the device uploaded, which makes them the reference. One sample of each is
    /// enough: the comparison that matters is the key SET, and each side is
    /// produced by exactly one code path.
    ///
    /// The key set alone is not sufficient: it matched for two runs while the
    /// archived `Mode` was an object reference, which makes every
    /// `decodeInteger`-family read on the device raise "not an integer number".
    /// So the *shape* is printed beside the keys — see `mbFileBlobShape`.
    ///
    /// Returns one log line; call it once, right after injecting.
    func blobKeySample(ours: String) -> String {
        guard exists, let db = try? open() else {
            return "blob keys: no readable Manifest.db at \(dbPath)"
        }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT fileID, file FROM Files WHERE file IS NOT NULL",
                                 -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return "blob keys: could not read Manifest.db"
        }
        defer { sqlite3_finalize(stmt) }

        var oursKeys: String?
        var deviceKeys: String?
        var oursShape: String?
        var deviceShape: String?
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let cID = sqlite3_column_text(stmt, 0) else { continue }
            let fileID = String(cString: cID)
            let count = sqlite3_column_bytes(stmt, 1)
            guard count > 0, let raw = sqlite3_column_blob(stmt, 1) else { continue }
            let blob = Data(bytes: raw, count: Int(count))
            let keys = mbFileBlobKeys(blob)
            let shape = mbFileBlobShape(blob)
            if fileID == ours {
                oursKeys = keys
                oursShape = shape
            } else if deviceKeys == nil {
                deviceKeys = keys
                deviceShape = shape
            }
            if oursKeys != nil, deviceKeys != nil { break }
        }
        return "blob keys: ours=[\(oursKeys ?? "row not found")] "
            + "device=[\(deviceKeys ?? "no other row to compare against")]"
            + " | shape ours: \(oursShape ?? "-")"
            + " | shape device: \(deviceShape ?? "-")"
    }

    /// The largest `InodeNumber` any row in this manifest claims, or 0.
    ///
    /// The restore agent deduplicates by inode, so a synthetic row must not
    /// reuse one the manifest already claims — GoldenNugget's injector counts up
    /// from this value ("it deduplicates by inode — a clone sharing the donor's
    /// inode gets restored with the donor's content", `src/restore/inject.py:
    /// 254-266`).  The field lives inside each row's blob rather than in a
    /// column, so answering it means decoding every blob.
    func maxInode() -> Int {
        guard exists, let db = try? open() else { return 0 }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT file FROM Files WHERE file IS NOT NULL",
                                 -1, &stmt, nil) == SQLITE_OK, let stmt else { return 0 }
        defer { sqlite3_finalize(stmt) }
        var highest = 0
        while sqlite3_step(stmt) == SQLITE_ROW {
            let count = sqlite3_column_bytes(stmt, 0)
            guard count > 0, let raw = sqlite3_column_blob(stmt, 0) else { continue }
            if let inode = mbFileBlobInode(Data(bytes: raw, count: Int(count))) {
                highest = max(highest, inode)
            }
        }
        return highest
    }

    /// Phase 3: remove payload files that no keep row references.
    ///
    /// Membership is a Set, not an Array scan: a filtered whole-device backup
    /// leaves one entry per stored file, and the reference implementation had to
    /// fix exactly this quadratic walk
    /// (https://github.com/doronz88/pymobiledevice3/issues/1833).
    private func removeOrphanPayloads(keepIDs: Set<String>) -> Int {
        let fm = FileManager.default
        var removed = 0
        guard let shards = try? fm.contentsOfDirectory(atPath: deviceDir.path) else { return 0 }
        for shard in shards {
            let shardDir = deviceDir.appendingPathComponent(shard)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: shardDir.path, isDirectory: &isDir), isDir.boolValue else {
                continue
            }
            if let payloads = try? fm.contentsOfDirectory(atPath: shardDir.path) {
                for payload in payloads where !keepIDs.contains(payload) {
                    try? fm.removeItem(at: shardDir.appendingPathComponent(payload))
                    removed += 1
                }
            }
            // Remove shards that are now empty.
            if let remaining = try? fm.contentsOfDirectory(atPath: shardDir.path), remaining.isEmpty {
                try? fm.removeItem(at: shardDir)
            }
        }
        return removed
    }
}
