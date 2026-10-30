// Real TemplateFile → PosterBoard.compile → SQLite stitching, without a device.
// Run through check-template-safety.py; hardware/video doubles come from the
// existing PosterBoard identity harness, while the store implementation is real.
@main struct PosterBoardTemplateCheck {
    static func main() async throws {
        let savedRefresh = UserDefaults.standard.object(forKey: PosterBoardPreferences.autoRefreshKey)
        defer {
            if let savedRefresh { UserDefaults.standard.set(savedRefresh, forKey: PosterBoardPreferences.autoRefreshKey) }
            else { UserDefaults.standard.removeObject(forKey: PosterBoardPreferences.autoRefreshKey) }
        }
        PosterBoardPreferences.autoRefresh = true
        let root = URL.documents
        let source = root.appendingPathComponent("device.sqlite3")
        try PosterBoardStore.createEmptyDatabase(at: source)
        var handle: OpaquePointer?
        precondition(sqlite3_open(source.path, &handle) == SQLITE_OK)
        precondition(sqlite3_exec(handle, "INSERT INTO poster (UUID, providerId) VALUES ('existing', 'existing-provider')", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(handle)
        let preferences: [String: Any] = [
            "CustomDeviceSetting": "keep",
            "PersistedPosterContainerBundleIdentifiers": ["existing-provider", "another-provider"],
            "CompletedPosterBundleIdentifierMigrations": ["device-migration"],
        ]
        let preferencesData = try PropertyListSerialization.data(fromPropertyList: preferences, format: .binary, options: 0)
        let oldPath = PosterBoard.storePath(61) + "/Extensions/existing-provider/configurations/existing/asset.bin"
        let preserved = [
            TweakPayload(domain: PosterBoard.domain, relativePath: oldPath, contents: Data("old asset".utf8)),
            TweakPayload(domain: PosterBoard.domain, relativePath: PosterBoard.preferencesPath, contents: preferencesData),
            TweakPayload(domain: PosterBoard.domain, relativePath: PosterBoard.storePath(61) + "/" + PosterBoard.databaseFileName, source: source),
        ]
        let template = try TemplateFile(url: root.appendingPathComponent("posterboard.batter"), deviceVersion: "26.5")
        let payloads = try await PosterBoard.compile(selection: PosterBoardSelection(), templates: [template],
            structureVersion: 61, database: source, preservedPayloads: preserved, deviceVersion: "27.0.1",
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
        precondition(rowCount(database.source!) == 2, "existing and new wallpapers must both survive")
        precondition(rowCount(source) == 1, "stitching must preserve the fetched database")
        precondition(payloads.filter { $0.relativePath.hasSuffix(PosterBoard.databaseFileName) }.count == 1,
                     "live snapshot DB must be replaced by the stitched DB")
        let oldAsset = try payloads.first { $0.relativePath == TweakPayload.manifestPath(oldPath) }!.bytes()
        precondition(oldAsset == Data("old asset".utf8),
                     "existing collection descriptor assets must be restored")
        let mergedData = try payloads.first { $0.relativePath == TweakPayload.manifestPath(PosterBoard.preferencesPath) }!.bytes()
        let merged = try PropertyListSerialization.propertyList(from: mergedData, format: nil) as! [String: Any]
        precondition(merged["CustomDeviceSetting"] as? String == "keep", "custom preferences survive refresh")
        precondition(merged["PersistedPosterContainerBundleIdentifiers"] as? [String] == preferences["PersistedPosterContainerBundleIdentifiers"] as? [String], "provider list survives refresh")
        precondition(merged["CompletedPosterBundleIdentifierMigrations"] as? [String] == ["device-migration"], "migration state survives refresh")
        precondition(merged["PBF_RESET_FILE_PROTECTIONS"] as? Bool == true, "refresh flag merged")
        let delta = try await PosterBoard.compile(selection: PosterBoardSelection(), templates: [template],
            structureVersion: 61, database: source, preservedPayloads: preserved, includeSnapshotFiles: false,
            deviceVersion: "27.0.1", workingDirectory: root.appendingPathComponent("backup-delta"), log: { _ in })
        precondition(!delta.contains { $0.relativePath == TweakPayload.manifestPath(oldPath) },
                     "native snapshot files must not be re-encoded as new tweak files")
        precondition(!delta.contains { $0.relativePath.contains("/descriptors/") },
                     "an installed wallpaper is delivered once, as a configuration; the gallery-descriptor duplicate is a second identity the store has to reconcile")
        let configurationAsset = delta.first { $0.relativePath.contains("/configurations/") && $0.relativePath.hasSuffix("image.bin") }!
        let configurationBytes = try configurationAsset.bytes()
        precondition(configurationBytes == Data("wallpaper bytes".utf8),
                     "the configuration carries the wallpaper's own assets")
        PosterBoardPreferences.autoRefresh = false
        let noRefresh = try await PosterBoard.compile(selection: PosterBoardSelection(), templates: [template],
            structureVersion: 61, database: source, preservedPayloads: preserved, deviceVersion: "27.0.1",
            workingDirectory: root.appendingPathComponent("backup-no-refresh"), log: { _ in })
        let untouched = try noRefresh.first { $0.relativePath == TweakPayload.manifestPath(PosterBoard.preferencesPath) }!.bytes()
        precondition(untouched == preferencesData, "Auto refresh off preserves preferences byte for byte")
        let noRefreshDB = noRefresh.first { $0.relativePath.hasSuffix(PosterBoard.databaseFileName) }!
        precondition(rowCount(noRefreshDB.source!) == 2, "Auto refresh off still adds to existing wallpapers")
        if ProcessInfo.processInfo.environment["GN_REAL_PB_PACK"] != nil {
            var dvdSelection = PosterBoardSelection()
            dvdSelection.tendies = [PosterBoardTendie(name: "DVD Screensaver", autoConvert: false)]
            let dvd = try await PosterBoard.compile(selection: dvdSelection, structureVersion: 61,
                database: source, preservedPayloads: preserved, includeSnapshotFiles: false,
                deviceVersion: "27.0.1", workingDirectory: root.appendingPathComponent("dvd-work"), log: { _ in })
            let configs = dvd.filter { $0.relativePath.contains("/Extensions/" + PosterBoard.collectionsExtension + "/configurations/") }
            precondition(!configs.isEmpty, "DVD must publish an installed configuration")
            // One identity per wallpaper. A second copy under
            // `CollectionsPosterApp/descriptors/` (or the provider's own
            // `descriptors/`) is the gallery channel, not an installed poster;
            // the device's store holds no such directory on iOS 27, and a
            // duplicate the store cannot reconcile is what made it rebuild the
            // whole database — every wallpaper gone.
            precondition(!dvd.contains { $0.relativePath.contains("/descriptors/") },
                         "DVD must be delivered once, as a configuration")
            precondition(configs.contains { $0.relativePath.hasSuffix("/providerInfo.plist") },
                         "the configuration carries the provider metadata the store reads")
            let database = dvd.first { $0.relativePath.hasSuffix(PosterBoard.databaseFileName) }!.source!
            precondition(rowCount(database) == 2 && rowCount(source) == 1, "DVD registration retains existing wallpaper")
            print("PASS: actual DVD Screensaver publishes one configuration, with preserved database rows")
        }
        print("16 PosterBoard template backup checks passed")
    }
}
