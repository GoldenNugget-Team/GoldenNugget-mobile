// Joined with the shipping PosterBoardStore and backup consolidation methods by
// check-posterboard-backup.py. SQLite fixtures need no device or network.
import Foundation
import SQLite3
import UniformTypeIdentifiers

struct GoldenNuggetError: Error, CustomStringConvertible {
    let description: String
    init(_ value: String) { description = value }
}
enum PosterBoard {
    static let databaseFileName = "PBFPosterExtensionDataStoreSQLiteDatabase.sqlite3"
}
struct PosterBoardConfigItem {
    let uuid: String
    let extensionID: String
    let setSelected: Bool
}
extension PosterBoardBackup {
    static func checkSnapshot(main: URL, wal: URL?, destination: URL) throws -> URL {
        try consolidate(main: main, wal: wal, destination: destination, log: { print($0) })
    }
}
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("pb-backup-check-\(UUID().uuidString)")
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
var failures = 0
func check(_ condition: Bool, _ label: String) {
    print("\(condition ? "PASS" : "FAIL"): \(label)")
    if !condition { failures += 1 }
}
func execute(_ db: OpaquePointer?, _ sql: String) throws {
    guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
        throw GoldenNuggetError(String(cString: sqlite3_errmsg(db)))
    }
}
/// Mirrors `PosterBoardStore.open`: a read-only handle only reads a WAL-mode
/// database when its `-wal`/`-shm` companions already exist, and the handle is
/// lazy, so the failure appears at the first statement rather than at open.
func openAny(_ url: URL) -> OpaquePointer? {
    for flags in [SQLITE_OPEN_READONLY, SQLITE_OPEN_READWRITE] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, flags, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            continue
        }
        var statement: OpaquePointer?
        let status = sqlite3_prepare_v2(db, "SELECT 1 FROM sqlite_master LIMIT 1",
                                       -1, &statement, nil)
        sqlite3_finalize(statement)
        if status == SQLITE_OK { return db }
        sqlite3_close(db)
    }
    return nil
}
func count(_ url: URL) -> Int {
    guard let db = openAny(url) else { return -1 }
    defer { sqlite3_close(db) }
    var statement: OpaquePointer?
    defer { sqlite3_finalize(statement) }
    guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM poster", -1, &statement, nil) == SQLITE_OK,
          sqlite3_step(statement) == SQLITE_ROW else { return -1 }
    return Int(sqlite3_column_int(statement, 0))
}
// Header bytes 18/19 are the file's read/write format versions: 1 = rollback
// journal, 2 = WAL. PosterBoard's own store says WAL, and it opens ours
// read-only and immediately runs `PRAGMA journal_mode=WAL` — on a rollback-mode
// file that pragma is a write, fails with "attempt to write a readonly
// database", and PosterBoard responds by rebuilding the store (losing every
// custom wallpaper). Shipping rollback mode is therefore a hard failure.
func journalMode(_ url: URL) throws -> String {
    let bytes = try Data(contentsOf: url)
    guard bytes.count > 19 else { return "truncated" }
    if bytes[18] == 2 && bytes[19] == 2 { return "wal" }
    if bytes[18] == 1 && bytes[19] == 1 { return "delete" }
    return "\(bytes[18])/\(bytes[19])"
}
/// A shipped payload must be self-contained: every committed page lives in the
/// main file, so no non-empty `-wal` may be left beside it.
func selfContained(_ url: URL) -> Bool {
    let fm = FileManager.default
    let wal = url.path + "-wal"
    guard let attributes = try? fm.attributesOfItem(atPath: wal) else { return true }
    return (attributes[.size] as? Int ?? 0) == 0
}
let source = root.appendingPathComponent("device.sqlite3")
try PosterBoardStore.createEmptyDatabase(at: source)
// A full reset ships this file too, so it needs the same declared mode.
check(try journalMode(source) == "wal" && selfContained(source),
      "the full-reset store declares WAL with its schema in the main file")
var db: OpaquePointer?
guard sqlite3_open(source.path, &db) == SQLITE_OK else { fatalError("fixture open failed") }
try execute(db, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0;")
try execute(db, "INSERT INTO poster (UUID, providerId) VALUES ('existing', 'provider');")
try execute(db, "PRAGMA wal_checkpoint(TRUNCATE)")
// Capture a WAL-mode main file with no WAL sibling, as in diagnostics.txt.
let mainOnly = root.appendingPathComponent("main-only.sqlite3")
try fm.copyItem(at: source, to: mainOnly)
try fm.setAttributes([.posixPermissions: 0o400], ofItemAtPath: mainOnly.path)
let sourceBytes = try Data(contentsOf: mainOnly)
let destination = root.appendingPathComponent("cached.sqlite3")
try Data("old cache".utf8).write(to: destination)
// Stale/unusable sidecars make the old copy-only path fail at sqlite_master.
for suffix in ["-wal", "-shm"] {
    try fm.createDirectory(atPath: destination.path + suffix, withIntermediateDirectories: true)
}
let standalone = try PosterBoardBackup.checkSnapshot(main: mainOnly, wal: nil, destination: destination)
check(PosterBoardStore.diagnose(standalone, strict: false) == nil,
      "fetched WAL-mode main without companion passes validation despite stale cache sidecars")
check(try journalMode(standalone) == "wal",
      "cache declares WAL — a DELETE-mode store is what made PosterBoard rebuild itself")
check(selfContained(standalone), "consolidated cache carries every page in the main file")
check(count(standalone) == 1, "existing device wallpaper survives consolidation")
check(try Data(contentsOf: mainOnly) == sourceBytes, "downloaded source is unchanged")
func isDirectory(_ path: String) -> Bool {
    (try? fm.attributesOfItem(atPath: path))?[.type] as? FileAttributeType == .typeDirectory
}
check(!isDirectory(destination.path + "-wal") && !isDirectory(destination.path + "-shm"),
      "stale sidecar directories are cleared from beside the cache")
check(selfContained(destination), "no payload is left in a sidecar beside the cache")
let staged = try PosterBoardStore.stitch(database: standalone, items: [PosterBoardConfigItem(
    uuid: "new-wallpaper", extensionID: "com.apple.WallpaperKit.CollectionsPoster", setSelected: true)],
    workingDirectory: root.appendingPathComponent("compile"))
check(count(staged) == 2 && count(standalone) == 1,
      "Protective compilation adds a wallpaper to the staged database and preserves the fetched cache")
check(try journalMode(staged) == "wal" && selfContained(staged),
      "staged restore payload declares WAL and carries the inserted rows in the main file")
check(try journalMode(standalone) == "wal",
      "staging does not rewrite the fetched cache's journal mode")
func selectedCount(_ url: URL) -> Int {
    guard let db = openAny(url) else { return -1 }
    defer { sqlite3_close(db) }
    var stmt: OpaquePointer?
    defer { sqlite3_finalize(stmt) }
    guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM posterAttributes WHERE attributeIdentifier = 'SELECTED'", -1, &stmt, nil) == SQLITE_OK,
          sqlite3_step(stmt) == SQLITE_ROW else { return -1 }
    return Int(sqlite3_column_int(stmt, 0))
}
let multiple = try PosterBoardStore.stitch(database: staged, items: [
    PosterBoardConfigItem(uuid: "second", extensionID: "provider", setSelected: true),
    PosterBoardConfigItem(uuid: "third", extensionID: "provider", setSelected: true),
], workingDirectory: root.appendingPathComponent("multiple"))
check(count(multiple) == 4 && selectedCount(multiple) == 1, "multiple additions leave exactly one selected wallpaper")
let unchanged = try PosterBoardStore.stitch(database: multiple, items: [], workingDirectory: root.appendingPathComponent("unchanged"))
check(selectedCount(unchanged) == 1, "container-only apply preserves current wallpaper selection")
let unselected = try PosterBoardStore.stitch(database: multiple,
    items: [PosterBoardConfigItem(uuid: "unselected", extensionID: "provider", setSelected: false)],
    workingDirectory: root.appendingPathComponent("unselected"))
check(selectedCount(unselected) == 1 && count(unselected) == 5, "unselected addition preserves existing selection")
// This second committed row exists only in WAL, not in the main file.
try execute(db, "INSERT INTO poster (UUID, providerId) VALUES ('wal-only', 'provider');")
let walDestination = root.appendingPathComponent("wal-cache.sqlite3")
let merged = try PosterBoardBackup.checkSnapshot(main: source,
    wal: URL(fileURLWithPath: source.path + "-wal"), destination: walDestination)
check(try count(merged) == 2 && journalMode(merged) == "wal" && selfContained(merged),
      "committed WAL-only wallpaper is merged into a self-contained WAL snapshot")
sqlite3_close(db)
let validCacheBytes = try Data(contentsOf: destination)
let corrupt = root.appendingPathComponent("corrupt.sqlite3")
try Data(repeating: 0x42, count: 512).write(to: corrupt)
do {
    _ = try PosterBoardBackup.checkSnapshot(main: corrupt, wal: nil, destination: destination)
    check(false, "corrupt download must fail")
} catch { check(true, "corrupt download fails before application") }
check(try Data(contentsOf: destination) == validCacheBytes, "failed consolidation preserves the last valid cache")
exit(failures == 0 ? 0 : 1)
