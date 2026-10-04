import Foundation
import SQLite3

/// The PosterBoard store's SQLite database: validating it, making an empty one,
/// and stitching new wallpapers into a copy.
///
/// A port of `src/tweaks/posterboard/pb_config_manager.py`.  Only this file
/// touches that database, for the same reason `ManifestStore` is the only thing
/// that touches `Manifest.db`: the row shapes below are a device contract, and
/// one copy of them is what makes them checkable in a single read.
///
/// Why the device's own database at all, rather than a synthesised one: a
/// wallpaper *is* three rows in this database plus its descriptor directory.
/// The rows carry the device's own provider registrations, the role memberships
/// and the usage metadata the picker sorts by, and there is no way to invent
/// those — `posterAttributes` has a `UNIQUE(posterUUID, roleId,
/// attributeIdentifier)` constraint that a guessed row set violates.  So the
/// apply reads the device's database, adds rows to a copy of it, and puts the
/// copy back.
enum PosterBoardStore {
    /// The classic pre-db5 table set.  Strict validation requires all four.
    static let requiredTables = ["poster", "posterAttributes", "posterRoleMembership",
                                 "sqlite_sequence"]

    /// `SQLITE_TRANSIENT` is a C macro the module never sees; `-1` tells sqlite
    /// to copy the bytes rather than keep the pointer, which matters because the
    /// Swift temporaries die when the bind returns.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    // MARK: - Validation

    /// `_validate_posterboard_db`.
    ///
    /// - Parameter strict: `true` requires the classic table set; `false`
    ///   accepts any healthy database carrying poster-ish tables, because the
    ///   schema moves between iOS releases (db5+).
    static func validate(_ url: URL, strict: Bool = true) -> Bool {
        diagnose(url, strict: strict) == nil
    }

    /// Which step of validation rejected the database, or `nil` when it is healthy.
    ///
    /// A bare `false` used to be all a failed fetch left behind: the run stopped,
    /// the log ended on the line before, and the only place the reason existed was
    /// a status line on the phone. `describeTables` only ever described a database
    /// that opened, which is precisely the case that needs explaining least —
    /// a store that will not open at all, or one whose `integrity_check` says
    /// something other than "ok", said nothing anywhere.
    static func diagnose(_ url: URL, strict: Bool = true) -> String? {
        let path = url.path
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        guard let size = attributes?[.size] as? Int else {
            return "there is no file at \(path)"
        }
        guard size >= 100 else { return "\(size) bytes — too small to be a database" }
        guard let db = open(path) else {
            return "SQLite will not open it: \(openComplaint(path))"
        }
        defer { sqlite3_close(db) }

        guard exec(db, "SELECT 1 FROM sqlite_master LIMIT 1") else {
            return "sqlite_master is unreadable: \(String(cString: sqlite3_errmsg(db)))"
        }
        if strict {
            let missing = requiredTables.filter { !tableExists(db, $0) }
            guard missing.isEmpty else {
                return "missing table(s): \(missing.joined(separator: ", "))"
            }
        } else {
            let tables = tableNames(db).map { $0.lowercased() }
            guard tables.contains(where: { $0.contains("poster") }) else {
                return "no table is named after PosterBoard (tables: "
                    + "\(tables.isEmpty ? "none" : tables.joined(separator: ", ")))"
            }
        }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "PRAGMA integrity_check", -1, &statement, nil) == SQLITE_OK else {
            return "integrity_check would not run: \(String(cString: sqlite3_errmsg(db)))"
        }
        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            guard let text = sqlite3_column_text(statement, 0) else {
                return "integrity_check said nothing"
            }
            let verdict = String(cString: text)
            return verdict == "ok" ? nil : "integrity_check: \(verdict)"
        case SQLITE_DONE:
            return "integrity_check returned no row"
        default:
            return "integrity_check failed: \(String(cString: sqlite3_errmsg(db)))"
        }
    }

    /// `open`'s own complaint, for the cases `open` cannot report itself: a
    /// read-only connection cannot create the `-shm` a WAL database needs, and
    /// that failure surfaces as nothing at all rather than as an error string.
    private static func openComplaint(_ path: String) -> String {
        var db: OpaquePointer?
        let rc = sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE, nil)
        defer { sqlite3_close(db) }
        guard rc != SQLITE_OK else { return "opened read-write only" }
        return String(cString: sqlite3_errmsg(db))
    }

    /// `_is_encrypted_database`: a database that will not open as plain SQLite
    /// is either encrypted or not a database, and both need the same answer.
    static func isEncrypted(_ url: URL) -> Bool {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes?[.size] as? Int, size >= 100 else { return false }
        guard let db = open(url.path) else { return false }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let status = sqlite3_prepare_v2(db, "SELECT 1 FROM sqlite_master LIMIT 1", -1, &statement, nil)
        if status == SQLITE_OK { return false }
        let message = String(cString: sqlite3_errmsg(db)).lowercased()
        return message.contains("encrypted") || message.contains("not a database")
    }

    /// The tables a rejected file does carry, for the log line that says why.
    static func describeTables(_ url: URL) -> String {
        guard let db = open(url.path) else { return "unreadable" }
        defer { sqlite3_close(db) }
        let tables = tableNames(db)
        return tables.isEmpty ? "no tables" : tables.sorted().joined(separator: ", ")
    }

    // MARK: - The empty database

    /// `create_empty_posterboard_db`: the store's schema with no data, which is
    /// what a full reset leaves behind.
    static func createEmptyDatabase(at url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else {
            throw GoldenNuggetError("Could not create the empty PosterBoard database at "
                + "\(url.lastPathComponent).")
        }
        defer { sqlite3_close(db) }
        let schema = """
            CREATE TABLE IF NOT EXISTS poster (
              posterId INTEGER PRIMARY KEY AUTOINCREMENT,
              UUID TEXT,
              providerId TEXT
            );
            CREATE TABLE IF NOT EXISTS posterAttributes (
              posterUUID TEXT,
              roleId TEXT,
              attributeIdentifier TEXT,
              attributePayload BLOB
            );
            CREATE TABLE IF NOT EXISTS posterRoleMembership (
              posterUUID TEXT,
              roleId TEXT,
              roleSortKey INTEGER
            );
            """
        guard exec(db, schema) else {
            throw GoldenNuggetError("Could not create the empty PosterBoard database schema: "
                + String(cString: sqlite3_errmsg(db)))
        }
    }

    // MARK: - Stitching

    /// `PBConfigManager.update_sqlite`, on a copy of the device's database.
    ///
    /// Returns the file to deliver.  The source is never modified: a run that
    /// fails after this point must not have changed the only copy of the store.
    static func stitch(database: URL,
                       items: [PosterBoardConfigItem],
                       workingDirectory: URL) throws -> URL {
        if isEncrypted(database) {
            throw GoldenNuggetError(
                "That PosterBoard database is encrypted. Turn off \"Encrypt local backup\" in "
                + "Finder / iTunes, take a fresh backup, and fetch it again — a plaintext "
                + "payload injected into an encrypted store cannot be decrypted by the "
                + "restore agent (MBErrorDomain/205).")
        }
        guard validate(database) || validate(database, strict: false) else {
            throw GoldenNuggetError(
                "The PosterBoard database is not usable — it does not carry the store's "
                + "tables (\(describeTables(database))). It may be a truncated or interrupted "
                + "fetch; fetch it again.")
        }

        let fm = FileManager.default
        try fm.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        let staged = workingDirectory.appendingPathComponent(
            "STAGED-" + PosterBoard.databaseFileName, conformingTo: .data)
        try? fm.removeItem(at: staged)
        try fm.copyItem(at: database, to: staged)
        guard validate(staged) else {
            throw GoldenNuggetError("The staged copy of the PosterBoard database did not "
                + "validate — the source may be corrupt. Fetch it again.")
        }

        var db: OpaquePointer?
        guard sqlite3_open(staged.path, &db) == SQLITE_OK, let db else {
            throw GoldenNuggetError("Could not open the staged PosterBoard database.")
        }
        defer { sqlite3_close(db) }
        guard exec(db, "PRAGMA busy_timeout = 10000") else {
            throw GoldenNuggetError("Could not set a busy timeout on the staged database.")
        }
        guard exec(db, "BEGIN IMMEDIATE") else {
            throw GoldenNuggetError("Could not start a transaction on the staged PosterBoard "
                + "database: " + String(cString: sqlite3_errmsg(db)))
        }
        do {
            try write(db, items: items)
            guard exec(db, "COMMIT") else {
                throw GoldenNuggetError("Could not commit the PosterBoard rows: "
                    + String(cString: sqlite3_errmsg(db)))
            }
        } catch {
            _ = exec(db, "ROLLBACK")
            throw error
        }
        return staged
    }

    /// The inserts themselves.  Every write updates first and only inserts when
    /// nothing matched, because a freshly fetched database can already carry
    /// rows this list names (a re-apply of the same pack), and the attribute and
    /// membership tables may hold orphans from an earlier failed apply.
    ///
    /// `posterId` starts **above** `MAX(posterId)` rather than at the stored
    /// `sqlite_sequence.seq + 1`: the old scheme collides with a live row whose
    /// id the sequence has drifted past (rows deleted since), and a primary-key
    /// clash is a failed apply or a corrupted on-device store.
    private static func write(_ db: OpaquePointer, items: [PosterBoardConfigItem]) throws {
        var sequence = try scalarInt(db, "SELECT MAX(posterId) FROM poster") ?? 0
        var sortKey = try scalarInt(db,
            "SELECT MAX(roleSortKey) FROM posterRoleMembership WHERE roleId = ?",
            [.text("PRPosterRoleLockScreen")]) ?? sequence

        // Drop the current selection marker: whatever is added below becomes the
        // selected wallpaper.
        try run(db,
            "DELETE FROM posterAttributes WHERE roleId = ? AND attributeIdentifier = ? "
            + "AND attributePayload = ?",
            [.text("PRPosterRoleLockScreen"), .text("SELECTED"), .integer(1)])

        for item in items {
            let payload = usageMetadataJSON()
            let existing = try scalarInt(db, "SELECT posterId FROM poster WHERE UUID = ?",
                                         [.text(item.uuid)])
            if let existing {
                try run(db, "UPDATE poster SET providerId = ? WHERE posterId = ?",
                        [.text(item.extensionID), .integer(existing)])
            } else {
                sequence += 1
                try run(db, "INSERT INTO poster (posterId, UUID, providerId) VALUES (?, ?, ?)",
                        [.integer(sequence), .text(item.uuid), .text(item.extensionID)])
            }

            try run(db,
                "UPDATE posterAttributes SET attributePayload = ? WHERE posterUUID = ? "
                + "AND roleId = ? AND attributeIdentifier = ?",
                [.text(payload), .text(item.uuid), .text("PRPosterRoleLockScreen"),
                 .text("PRPosterRoleAttributeTypeUsageMetadata")])
            if changes(db) == 0 {
                try run(db,
                    "INSERT INTO posterAttributes (posterUUID, roleId, attributeIdentifier, "
                    + "attributePayload) VALUES (?, ?, ?, ?)",
                    [.text(item.uuid), .text("PRPosterRoleLockScreen"),
                     .text("PRPosterRoleAttributeTypeUsageMetadata"), .text(payload)])
            }

            if item.setSelected {
                try run(db,
                    "DELETE FROM posterAttributes WHERE posterUUID = ? AND roleId = ? "
                    + "AND attributeIdentifier = ?",
                    [.text(item.uuid), .text("PRPosterRoleLockScreen"), .text("SELECTED")])
                try run(db,
                    "INSERT INTO posterAttributes (posterUUID, roleId, attributeIdentifier, "
                    + "attributePayload) VALUES (?, ?, ?, ?)",
                    [.text(item.uuid), .text("PRPosterRoleLockScreen"), .text("SELECTED"),
                     .integer(1)])
            }

            try run(db,
                "UPDATE posterRoleMembership SET roleSortKey = ? WHERE posterUUID = ? "
                + "AND roleId = ?",
                [.integer(sortKey + 1), .text(item.uuid), .text("PRPosterRoleLockScreen")])
            if changes(db) == 0 {
                try run(db,
                    "INSERT INTO posterRoleMembership (posterUUID, roleId, roleSortKey) "
                    + "VALUES (?, ?, ?)",
                    [.text(item.uuid), .text("PRPosterRoleLockScreen"), .integer(sortKey + 1)])
            }
            sortKey += 1
        }

        try run(db, "UPDATE sqlite_sequence SET seq = ? WHERE name = ?",
                [.integer(sequence), .text("poster")])
        if changes(db) == 0 {
            try run(db, "INSERT INTO sqlite_sequence (name, seq) VALUES (?, ?)",
                    [.text("poster"), .integer(sequence)])
        }
    }

    /// The `attributePayload` JSON the device writes for a wallpaper.
    ///
    /// Built by hand rather than through `JSONSerialization` for one reason:
    /// key order.  The reference emits it with `json.dumps(...,
    /// separators=(",", ":"))`, which preserves insertion order, and a row this
    /// port writes should be comparable with one upstream would have written.
    ///
    /// The three timestamps are three separate `time.time()` calls in the
    /// reference — not one clock read with offsets — so they are three clocks
    /// here too.
    private static func usageMetadataJSON() -> String {
        let now = Date().timeIntervalSince1970
        return "{\"creationDate\":\(now),"
            + "\"extensionAvailable\":true,"
            + "\"attributeType\":\"PRPosterRoleAttributeTypeUsageMetadata\","
            + "\"lastActivatedDate\":\(Date().timeIntervalSince1970 + 0.0001),"
            + "\"lastSelectedDate\":\(Date().timeIntervalSince1970 + 0.00001)}"
    }

    // MARK: - SQLite plumbing

    private enum Binding {
        case text(String)
        case integer(Int)
    }

    private static func open(_ path: String) -> OpaquePointer? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        return db
    }

    private static func exec(_ db: OpaquePointer, _ sql: String) -> Bool {
        sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }

    private static func tableNames(_ db: OpaquePointer) -> [String] {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "SELECT name FROM sqlite_master WHERE type='table'",
                                 -1, &statement, nil) == SQLITE_OK else { return [] }
        var names: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let text = sqlite3_column_text(statement, 0) { names.append(String(cString: text)) }
        }
        return names
    }

    private static func tableExists(_ db: OpaquePointer, _ table: String) -> Bool {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?",
                                 -1, &statement, nil) == SQLITE_OK else { return false }
        sqlite3_bind_text(statement, 1, table, -1, transient)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    /// One integer column of one row, `nil` when the row or the value is absent.
    private static func scalarInt(_ db: OpaquePointer, _ sql: String,
                                  _ bindings: [Binding] = []) throws -> Int? {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw GoldenNuggetError("PosterBoard query failed: \(sql) — "
                + String(cString: sqlite3_errmsg(db)))
        }
        bind(statement, bindings)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        if sqlite3_column_type(statement, 0) == SQLITE_NULL { return nil }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private static func run(_ db: OpaquePointer, _ sql: String,
                            _ bindings: [Binding] = []) throws {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw GoldenNuggetError("PosterBoard write failed: \(sql) — "
                + String(cString: sqlite3_errmsg(db)))
        }
        bind(statement, bindings)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw GoldenNuggetError("PosterBoard write failed: \(sql) — "
                + String(cString: sqlite3_errmsg(db)))
        }
    }

    private static func bind(_ statement: OpaquePointer?, _ bindings: [Binding]) {
        for (offset, binding) in bindings.enumerated() {
            let index = Int32(offset + 1)
            switch binding {
            case .text(let value): sqlite3_bind_text(statement, index, value, -1, transient)
            case .integer(let value): sqlite3_bind_int64(statement, index, Int64(value))
            }
        }
    }

    /// `sqlite3_changes`, for the update-then-insert pattern above.
    private static func changes(_ db: OpaquePointer) -> Int {
        Int(sqlite3_changes(db))
    }
}
