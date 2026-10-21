// Real TemplateFile → PosterBoard.compile → SQLite stitching, without a device.
// Run through check-template-safety.py; hardware/video doubles come from the
// existing PosterBoard identity harness, while the store implementation is real.
@main struct PosterBoardTemplateCheck {
    static func main() async throws {
        let root = URL.documents
        let source = root.appendingPathComponent("device.sqlite3")
        try PosterBoardStore.createEmptyDatabase(at: source)
        let template = try TemplateFile(url: root.appendingPathComponent("posterboard.batter"), deviceVersion: "26.5")
        let payloads = try await PosterBoard.compile(selection: PosterBoardSelection(), templates: [template],
            structureVersion: 61, database: source, deviceVersion: "26.5",
            workingDirectory: root.appendingPathComponent("backup-work"), log: { _ in })
        let database = payloads.first { $0.relativePath.hasSuffix(PosterBoard.databaseFileName) }!
        precondition(payloads.contains { $0.relativePath.hasSuffix("image.bin") }, "template-only backup must carry its descriptor")
        precondition(PosterBoardStore.validate(database.source!, strict: true), "stitched database must validate")
        func rowCount(_ url: URL) -> Int {
            var db: OpaquePointer?
            defer { sqlite3_close(db) }
            precondition(sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            precondition(sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM poster", -1, &statement, nil) == SQLITE_OK)
            precondition(sqlite3_step(statement) == SQLITE_ROW)
            return Int(sqlite3_column_int(statement, 0))
        }
        precondition(rowCount(database.source!) == 1, "template descriptor must have a wallpaper row")
        precondition(rowCount(source) == 0, "stitching must preserve the fetched database")
        print("4 PosterBoard template backup checks passed")
    }
}
