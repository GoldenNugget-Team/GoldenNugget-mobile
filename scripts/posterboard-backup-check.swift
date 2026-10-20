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
func count(_ url: URL) -> Int {
    var db: OpaquePointer?
    defer { sqlite3_close(db) }
    guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return -1 }
    var statement: OpaquePointer?
    defer { sqlite3_finalize(statement) }
    guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM poster", -1, &statement, nil) == SQLITE_OK,
          sqlite3_step(statement) == SQLITE_ROW else { return -1 }
    return Int(sqlite3_column_int(statement, 0))
}
func deleteMode(_ url: URL) throws -> Bool {
    let bytes = try Data(contentsOf: url)
    return bytes.count > 19 && bytes[18] == 1 && bytes[19] == 1
}
let source = root.appendingPathComponent("device.sqlite3")
try PosterBoardStore.createEmptyDatabase(at: source)
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
check(try deleteMode(standalone), "cache is a standalone DELETE-mode database")
check(count(standalone) == 1, "existing device wallpaper survives consolidation")
check(try Data(contentsOf: mainOnly) == sourceBytes, "downloaded source is unchanged")
check(!fm.fileExists(atPath: destination.path + "-wal") && !fm.fileExists(atPath: destination.path + "-shm"),
      "old sidecars are removed and validation creates none")
let staged = try PosterBoardStore.stitch(database: standalone, items: [PosterBoardConfigItem(
    uuid: "new-wallpaper", extensionID: "com.apple.WallpaperKit.CollectionsPoster", setSelected: true)],
    workingDirectory: root.appendingPathComponent("compile"))
check(count(staged) == 2 && count(standalone) == 1,
      "Protective compilation adds a wallpaper to the staged database and preserves the fetched cache")
check(try deleteMode(staged), "staged restore payload needs no WAL to carry inserted rows")
// This second committed row exists only in WAL, not in the main file.
try execute(db, "INSERT INTO poster (UUID, providerId) VALUES ('wal-only', 'provider');")
let walDestination = root.appendingPathComponent("wal-cache.sqlite3")
let merged = try PosterBoardBackup.checkSnapshot(main: source,
    wal: URL(fileURLWithPath: source.path + "-wal"), destination: walDestination)
check(try count(merged) == 2 && deleteMode(merged), "committed WAL-only wallpaper is merged into standalone snapshot")
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
