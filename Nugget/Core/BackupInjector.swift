import CryptoKit
import Foundation
import Minimuxer

/// The Lock Screen Footnote tweak, ported from GoldenNugget's
/// "Lock Screen Footnote Text" (`src/tweaks/`).
///
/// Reference chain: `registry.py` defines it as a `BasicPlistTweak` against
/// `FileLocation.footnote`, whose only consumer is the key `LockScreenFootnote`
/// in `SharedDeviceConfiguration.plist`; the file is emitted as
/// `plistlib.dumps({"LockScreenFootnote": text})` — a WHOLE-file replacement —
/// and mapped to a backup domain by `path_mapping.py`:
///
///     /var/containers/Shared/SystemGroup/systemgroup.com.apple.configurationprofiles/...
///       → SysSharedContainerDomain-systemgroup.com.apple.configurationprofiles
///       +  Library/ConfigurationProfiles/SharedDeviceConfiguration.plist
///
/// The text shows at the bottom of the Lock Screen under the clock. Long text
/// is cut off — keep it short. An empty value clears an existing footnote,
/// which is also how GoldenNugget's "leave empty to remove" works.
///
/// `BackupInjector.injectSystemPlist` is the only delivery channel: it injects
/// these bytes into the pulled protective backup's manifest. The domain, the
/// path and the plist encoding are stated once, here.
enum LockScreenFootnoteTweak {
    static let domain = "SysSharedContainerDomain-systemgroup.com.apple.configurationprofiles"
    static let relativePath = "Library/ConfigurationProfiles/SharedDeviceConfiguration.plist"

    /// The whole-file plist for one footnote text. `text` may be empty (explicit
    /// reset) — the caller decides whether to send the file at all.
    static func contents(text: String) throws -> Data {
        let plist: [String: Any] = ["LockScreenFootnote": text]
        return try PropertyListSerialization.data(fromPropertyList: plist,
                                                  format: .xml, options: 0)
    }
}

/// Turns the backup the device just gave us into one the restore daemon will
/// accept: prune `Manifest.db` down to what is actually on disk, then write the
/// rows and payloads for the files this run is delivering.
///
/// The delivered files are system-container plists, and the row shape for one of
/// those is *not* the shape an app container takes — no `Applications`
/// registration, `nobody` as owner, protection class 4.  The shape comes from
/// the device's own row for the same path, which is the only version of it that
/// cannot be wrong.
enum BackupInjector {
    /// Inject one file that is NOT an app container — currently only the Lock
    /// Screen footnote, a `SysSharedContainerDomain` plist.
    ///
    /// `inject` above cannot carry this one, for two independent reasons:
    ///
    ///   1. It registers an app bundle.  Registration exists for exactly one
    ///      reason — the restore daemon answers `MBErrorDomain/205 "Unknown domain
    ///      name in file record"` for an `AppDomain-*` payload whose bundle is
    ///      missing from `Manifest.plist`'s `Applications` dict.  A
    ///      `SysSharedContainerDomain` is not in that family and has no bundle to
    ///      register, which is also why the reference delivers its
    ///      `BasicPlistTweak` files with no registration at all.
    ///   2. It writes the app-container row shape.  The device writes a different
    ///      one for a system-container plist, and a row it did not write itself is
    ///      the one place a wrong value cannot be repaired by re-uploading.
    ///
    /// Measured off the device's own record for the exact file this delivers
    /// (`MobileSync/Backup/00008130-001431082E40001C`, fileID
    /// `0affc9c4722175be11a30bb60e96880ffedf29d5` =
    /// `SysSharedContainerDomain-systemgroup.com.apple.configurationprofiles` /
    /// `Library/ConfigurationProfiles/SharedDeviceConfiguration.plist`):
    ///
    ///     file row    Mode 0o100644  UserID -2  GroupID -2  ProtectionClass 4  EA ✓
    ///     inner dirs  Mode 0o40755   UserID -2  GroupID -2  ProtectionClass 4  EA ✗
    ///     domain root Mode 0o40755   UserID  0  GroupID  0  ProtectionClass 0  EA ✗
    ///
    /// `-2` is Darwin's `nobody`, and it is what the device records for this path
    /// (sibling rows in the same domain mix `501` and `-2`, so the value is
    /// per-row, not per-domain — this copies the row for *this* file).  The
    /// extended attribute is the same `com.apple.dataprotection.policy
    /// .exception-applied-by` an app-container row carries, so the "only app
    /// containers get one" rule does not hold for this class either.
    ///
    /// The owner is a deliberate divergence from the Python: GoldenNugget's
    /// `Tweak.__init__` defaults to `owner=501, group=501`, so its synthesized
    /// footnote row says `501` where the device's own row for the same path says
    /// `-2`.  The device's record wins here (nothing else in this repo copies a
    /// Python default against a measurement), and what IS copied from the
    /// reference is the part it does get right: no `Applications` registration
    /// for a non-`AppDomain-*` domain.
    ///
    /// Only regular files carry a payload; the directory rows are the path
    /// scaffolding the restore agent renames into place (dropping them makes it
    /// fail with `renameatx ENOENT` — see the prune's `flags == 2` rule).
    static func injectSystemPlist(
        into deviceDir: URL,
        domain: String,
        relativePath: String,
        contents: Data
    ) throws {
        let fileID = ManifestStore.fileID(domain: domain, relativePath: relativePath)
        let store = ManifestStore(deviceDir: deviceDir)
        let fm = FileManager.default

        // 1. Payload where the fileID says it lives.  Same shard layout as every
        //    other row: this is the join between the database and the tree.
        let payloadDir = store.payloadURL(forFileID: fileID).deletingLastPathComponent()
        try fm.createDirectory(at: payloadDir, withIntermediateDirectories: true)
        try contents.write(to: store.payloadURL(forFileID: fileID))

        // 2. Rows: domain root, one per parent component, then the file itself.
        //    Same ordering rule as `inject` — dirs first, so a PRIMARY KEY
        //    collision with the file row is impossible on a fresh Manifest.db.
        var rows: [(path: String, flags: Int32)] = [("", 2)]
        var accumulated = ""
        for component in relativePath.split(separator: "/").dropLast() {
            accumulated = accumulated.isEmpty ? String(component) : "\(accumulated)/\(component)"
            rows.append((accumulated, 2))
        }
        rows.append((relativePath, 1))

        let dataprotection = buildDataprotectionExtendedAttributes()
        let now = Int(Date().timeIntervalSince1970)
        // Darwin's `nobody`, i.e. the -2 the device stores for a system-container
        // file.  A negative id is legitimate here: it is what `uid_t` 4294967294
        // round-trips to in the archive, and the device produced that value
        // itself.
        let systemOwner = -2

        for row in rows {
            let isFile = row.flags == 1
            // The domain root row is the single exception in the measurement
            // above: the device writes 0/0 at protection class 0 there, while
            // every row below it is `nobody` at class 4.
            let isRoot = row.path.isEmpty
            let owner = isRoot ? 0 : systemOwner
            let rowID = ManifestStore.fileID(domain: domain, relativePath: row.path)
            let blob = buildMBFileBlob(
                relativePath: row.path,
                mode: isFile
                    ? (Int(MODE_FILE_DEFAULT) | Int(S_IFREG))
                    : (Int(MODE_DIR_DEFAULT) | Int(S_IFDIR)),
                size: isFile ? contents.count : 0,
                userID: owner,
                groupID: owner,
                protectionClass: isRoot ? PROTECTION_CLASS_DIR : PROTECTION_CLASS_SYSTEM_FILE,
                inodeNumber: inode(for: rowID),
                timestamp: now,
                // Only the file row carries one, per the measurement above.
                extendedAttributes: isFile ? dataprotection : nil)
            try store.upsert(fileID: rowID, domain: domain,
                             relativePath: row.path, flags: row.flags, blob: blob)
        }

        AppLog.write("Injected system plist \(domain)/\(relativePath) "
            + "(fileID=\(fileID), \(contents.count) bytes, owner \(systemOwner), class "
            + "\(PROTECTION_CLASS_SYSTEM_FILE))")
        AppLog.write(store.blobKeySample(ours: fileID))
    }

    /// A stable, plausible inode for one manifest row.
    ///
    /// The device writes an `InodeNumber` on every row it creates (4000/4000
    /// sampled `AppDomain-*` file rows) and never 0, and two rows sharing an
    /// inode would be a lie about the tree.  Derived from the `fileID`, so a
    /// re-run reproduces the same numbers, and mapped into the band the device's
    /// own inodes occupy (87278…1306390 in that backup) rather than an obviously
    /// synthetic value.
    static func inode(for fileID: String) -> Int {
        let head = Insecure.SHA1.hash(data: Data(fileID.utf8))
            .prefix(4)
            .reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        return 100_000 + Int(head % 900_000)
    }

    /// Stage 2+3 of the full flow: ensure the host-side metadata, prune the
    /// device's manifest down to what is on disk, then inject what the run is
    /// delivering.
    ///
    /// The injection rides *after* the prune for one reason: the prune keeps only
    /// the reference's keep-set, and no tweak row is in it — a row written before
    /// the prune would be deleted on the way past.
    /// - Parameter prune: pass `false` to build the backup rather than trim one.
    ///   A Partial Restore has no device content to protect: the backup is
    ///   synthesised from the host-side manifests plus this run's rows and
    ///   payloads, so there is nothing to reconcile against the filesystem and
    ///   `pruneToDiskState` would only walk an empty payload store.
    static func pruneAndInject(
        backupRoot: URL,
        udid: String,
        tweakPayloads: [TweakPayload],
        prune: Bool = true,
        ios27: Bool = true
    ) async throws {
        let deviceDir = AppPaths.deviceDir(backupRoot: backupRoot, udid: udid)
        let store = ManifestStore(deviceDir: deviceDir)

        // Fallback: if the device did not upload the host-side backup metadata
        // (Info.plist / Status.plist / Manifest.plist), write minimal valid ones
        // — restore refuses a backup without them.
        let manifestStage = StageTimer("ensure host-side manifests")

        // AppDomain-* file rows are not self-describing.  mobilebackup2 resolves
        // the suffix as an installed application and refuses the restore with
        // MBErrorDomain/205 ("Unknown domain name in file record") unless that
        // application is registered in Manifest.plist.  PosterBoard is the first
        // production payload in this port that uses AppDomain-*.
        let appDomainPrefix = "AppDomain-"
        let appBundleIDs = Set(tweakPayloads.compactMap { payload -> String? in
            guard payload.domain.hasPrefix(appDomainPrefix) else { return nil }
            let bundleID = String(payload.domain.dropFirst(appDomainPrefix.count))
            return bundleID.isEmpty ? nil : bundleID
        }).sorted()

        var applications: [String: [String: Any]]?
        if !appBundleIDs.isEmpty {
            var records: [String: [String: Any]] = [:]
            for bundleID in appBundleIDs {
                let entry = try await Minimuxer.shared().appFactoryEntry(bundleId: bundleID)
                records[bundleID] = entry
                AppLog.write("Registered restore AppDomain for \(bundleID) "
                    + "(\(entry.keys.count) installation_proxy field(s))")
            }
            applications = records
        }

        try HostManifests.ensure(deviceDir: deviceDir, udid: udid, ios27: ios27,
                                 applications: applications)
        manifestStage.done()

        if !ios27 {
            // iOS 26: the legacy MBDB manifest, payloads flat in the root.
            // Nothing to prune -- this backup is what the run built -- and no
            // sqlite Manifest.db at all: the device reads Manifest.mbdb and
            // asks for each payload by its fileID.
            let mbdbStage = StageTimer("write Manifest.mbdb")
            let rows = try MBDBManifest.rows(for: tweakPayloads)
            try MBDBManifest.encode(rows).write(to: deviceDir.appendingPathComponent("Manifest.mbdb"),
                                                options: .atomic)
            for payload in tweakPayloads {
                let name = MBDBManifest.fileID(domain: payload.domain,
                                               relativePath: payload.relativePath)
                try payload.bytes().write(to: deviceDir.appendingPathComponent(name),
                                          options: .atomic)
            }
            mbdbStage.done()
            try? FileManager.default.removeItem(at: deviceDir.appendingPathComponent("Manifest.db"))
            AppLog.write("Partial Restore: \(rows.count) MBDB row(s), "
                         + "\(tweakPayloads.count) payload(s) flat")
            return
        }

        if prune {
            AppLog.write("Pruning Manifest.db…")
            let pruneStage = StageTimer("prune Manifest.db")
            store.pruneToDiskState()
            pruneStage.done()
        } else {
            AppLog.write("Partial Restore: synthesising the backup, nothing to prune.")
        }

        let tweakStage = StageTimer("inject tweaks")
        AppLog.write("Injecting \(tweakPayloads.count) tweak file(s)…")
        let report = try TweakInjector.inject(into: deviceDir, payloads: tweakPayloads)
        tweakStage.done(report.summary)
        AppLog.write("Tweaks injected: \(report.summary)")
        for domain in report.unverifiedDomains {
            AppLog.write("note: the \(domain) row shape is measured from the device's own "
                + "backup but has not been confirmed by a run yet")
        }
    }
}
