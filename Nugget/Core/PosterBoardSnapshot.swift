import Foundation
import SQLite3

/// A targeted backup can offer other apps too. Match the actual PosterBoard
/// container, never a database basename that may belong to our own cached copy.
enum PosterBoardSnapshot {
    static func relativePath(deviceName: String, container: String) -> String? {
        func normalized(_ path: String) -> String {
            var value = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if value.hasPrefix("private/") { value.removeFirst("private/".count) }
            if value.hasPrefix("var/mobile/") { value.removeFirst("var/mobile/".count) }
            for prefix in [".b/", "b/"] where value.hasPrefix(prefix) {
                let rest = value.dropFirst(prefix.count)
                if let slash = rest.firstIndex(of: "/"), Int(rest[..<slash]) != nil {
                    value = String(rest[rest.index(after: slash)...])
                }
            }
            return value
        }
        let name = normalized(deviceName)
        let domainPrefix = PosterBoard.domain + "/"
        let root = normalized(container)
        let path: String
        if name.hasPrefix(domainPrefix) {
            path = String(name.dropFirst(domainPrefix.count))
        } else if !root.isEmpty, name.hasPrefix(root + "/") {
            path = String(name.dropFirst(root.count + 1))
        } else { return nil }
        guard !path.isEmpty, !path.contains("\\"), !path.contains("\0"),
              !path.split(separator: "/", omittingEmptySubsequences: false)
                .contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return nil }
        return path
    }

    static func storeVersion(relativePath: String) -> Int? {
        let parts = relativePath.split(separator: "/")
        guard parts.count == 5, parts[0] == "Library", parts[1] == "Application Support",
              parts[2] == PosterBoard.storeDirectoryName,
              parts[4] == PosterBoard.databaseFileName, let version = Int(parts[3]), version > 0 else { return nil }
        return version
    }

    static func isStoreFile(relativePath: String) -> Bool {
        var path = relativePath
        for suffix in ["-wal", "-shm"] where path.hasSuffix(suffix) { path.removeLast(suffix.count) }
        return storeVersion(relativePath: path) != nil
    }

    /// Resolve the files the stream actually accepted, including legacy flat
    /// backups. Missing files stop the apply rather than yielding a partial store.
    static func payloads(offers: [String: String], backupRoot: URL, udid: String) throws -> [TweakPayload] {
        let deviceDir = backupRoot.appendingPathComponent(udid, isDirectory: true)
        return try offers.sorted(by: { $0.key < $1.key }).map { path, hostName in
            let fileID = URL(fileURLWithPath: hostName).lastPathComponent
            guard fileID.count == 40, fileID.allSatisfy(\.isHexDigit) else {
                throw GoldenNuggetError("PosterBoard snapshot has an invalid file ID for \(path).")
            }
            let candidates = [
                deviceDir.appendingPathComponent(String(fileID.prefix(2))).appendingPathComponent(fileID),
                deviceDir.appendingPathComponent(fileID),
                deviceDir.appendingPathComponent("Snapshot/\(fileID.prefix(2))/\(fileID)"),
            ]
            guard let source = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
                throw GoldenNuggetError("PosterBoard snapshot is missing \(path). Apply stopped to preserve existing wallpapers.")
            }
            return TweakPayload(domain: PosterBoard.domain, relativePath: path, source: source)
        }
    }
}

// A backup container is a manifest graph, not just a list of regular files.
// Keep the device's directory/symlink records and MBFile archives verbatim;
// recreating them from file paths loses empty provider directories and metadata.
extension PosterBoardSnapshot {
    struct Record {
        let fileID: String
        let path: String
        let flags: Int32
        let blob: Data
        let source: URL?
    }

    static func records(in deviceDir: URL) throws -> [Record] {
        var db: OpaquePointer?
        // The device uploads a WAL-mode manifest, even when its pages have
        // already been checkpointed. SQLite on iOS must be able to initialise
        // its WAL/SHM bookkeeping before reading it. This is our local working
        // backup, so permit that recovery, but never create a missing manifest.
        guard sqlite3_open_v2(deviceDir.appendingPathComponent("Manifest.db").path, &db,
                              SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            let detail = db.map { String(cString: sqlite3_errmsg($0)) } ?? "no SQLite handle"
            sqlite3_close(db)
            throw GoldenNuggetError("Could not open PosterBoard snapshot Manifest.db: \(detail).")
        }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT fileID, relativePath, flags, file FROM Files WHERE domain = ? ORDER BY relativePath", -1, &stmt, nil) == SQLITE_OK else {
            let detail = String(cString: sqlite3_errmsg(db))
            throw GoldenNuggetError("Could not read PosterBoard snapshot manifest (SQLite \(sqlite3_extended_errcode(db))): \(detail).")
        }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, PosterBoard.domain, -1, transient)
        var result: [Record] = []
        while true {
            let step = sqlite3_step(stmt)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW, let idText = sqlite3_column_text(stmt, 0),
                  let pathText = sqlite3_column_text(stmt, 1), let bytes = sqlite3_column_blob(stmt, 3) else {
                throw GoldenNuggetError("PosterBoard snapshot contains an unreadable file record.")
            }
            let id = String(cString: idText)
            let path = String(cString: pathText)
            let flags = sqlite3_column_int(stmt, 2)
            guard id.count == 40, id.allSatisfy(\.isHexDigit), [1, 2, 4].contains(flags),
                  path.isEmpty || relativePath(deviceName: PosterBoard.domain + "/" + path, container: "") == path else {
                throw GoldenNuggetError("PosterBoard snapshot contains an invalid path or file type.")
            }
            var source: URL?
            if flags == 1 {
                let candidates = [deviceDir.appendingPathComponent("\(id.prefix(2))/\(id)"),
                                  deviceDir.appendingPathComponent(id)]
                source = candidates.first { FileManager.default.fileExists(atPath: $0.path) }
                guard source != nil else {
                    throw GoldenNuggetError("PosterBoard snapshot is incomplete: \(path). Restore stopped before changing the device.")
                }
            }
            result.append(Record(fileID: id, path: path, flags: flags,
                                 blob: Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, 3))), source: source))
        }
        guard result.contains(where: { storeVersion(relativePath: $0.path) != nil && $0.flags == 1 }) else {
            throw GoldenNuggetError("PosterBoard snapshot does not contain its live database.")
        }
        return result
    }

    /// Keep the first complete pre-apply container independently of fetch scratch
    /// space. A subsequent retry must not erase the only recovery copy.
    static func retainBaseline(from sourceDir: URL, at destination: URL) throws {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: destination.path) else { return }
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".snapshot-" + UUID().uuidString)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        var db: OpaquePointer?
        guard sqlite3_open(staging.appendingPathComponent("Manifest.db").path, &db) == SQLITE_OK else {
            sqlite3_close(db)
            throw GoldenNuggetError("Could not prepare the PosterBoard recovery snapshot.")
        }
        let status = sqlite3_exec(db, "CREATE TABLE Files (fileID TEXT PRIMARY KEY, domain TEXT, relativePath TEXT, flags INTEGER, file BLOB)", nil, nil, nil)
        sqlite3_close(db)
        guard status == SQLITE_OK else { throw GoldenNuggetError("Could not create the PosterBoard recovery manifest.") }
        _ = try merge(from: sourceDir, into: staging)
        try fm.moveItem(at: staging, to: destination)
    }

    /// Import the complete native domain after Protective pruning, before adding
    /// the new wallpaper delta. Never reconstruct existing MBFile metadata.
    struct RestoredSnapshot {
        let directories: Set<String>
        let fileMetadata: [String: Data]
    }

    static func merge(from sourceDir: URL, into targetDir: URL) throws -> RestoredSnapshot {
        let rows = try records(in: sourceDir) // validate ALL payloads before mutation
        let fm = FileManager.default
        for row in rows {
            guard let source = row.source else { continue }
            let target = targetDir.appendingPathComponent("\(row.fileID.prefix(2))/\(row.fileID)")
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contentsOf: source, options: .mappedIfSafe).write(to: target, options: .atomic)
        }
        var db: OpaquePointer?
        guard sqlite3_open(targetDir.appendingPathComponent("Manifest.db").path, &db) == SQLITE_OK, let db else {
            sqlite3_close(db)
            throw GoldenNuggetError("Could not open the restore manifest for PosterBoard.")
        }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else {
            throw GoldenNuggetError("Could not begin the PosterBoard snapshot merge.")
        }
        var committed = false
        defer { if !committed { sqlite3_exec(db, "ROLLBACK", nil, nil, nil) } }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO Files (fileID, domain, relativePath, flags, file) VALUES (?, ?, ?, ?, ?)", -1, &stmt, nil) == SQLITE_OK else {
            throw GoldenNuggetError("Could not prepare the PosterBoard manifest merge.")
        }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for row in rows {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            sqlite3_bind_text(stmt, 1, row.fileID, -1, transient)
            sqlite3_bind_text(stmt, 2, PosterBoard.domain, -1, transient)
            sqlite3_bind_text(stmt, 3, row.path, -1, transient)
            sqlite3_bind_int(stmt, 4, row.flags)
            _ = row.blob.withUnsafeBytes { sqlite3_bind_blob(stmt, 5, $0.baseAddress, Int32($0.count), transient) }
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw GoldenNuggetError("Could not preserve PosterBoard manifest entry \(row.path).")
            }
        }
        guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else {
            throw GoldenNuggetError("Could not commit the PosterBoard snapshot merge.")
        }
        committed = true
        return RestoredSnapshot(
            directories: Set(rows.filter { $0.flags == 2 }.map { PosterBoard.domain + "/" + $0.path }),
            fileMetadata: Dictionary(uniqueKeysWithValues: rows.filter { $0.flags == 1 }
                .map { (PosterBoard.domain + "/" + $0.path, $0.blob) }))
    }
}
