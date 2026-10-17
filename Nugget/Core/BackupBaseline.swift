import Foundation

/// The retained mobilebackup2 pull that the next run diffs against.
///
/// ## Why this exists
///
/// The device decides what to upload by comparing its files against the
/// `Manifest.db` the host serves it at the start of the exchange. Serve an empty
/// one and it uploads the world: the protective pull then has to *drain* ~28 000
/// offered files mid-stream (`ProtectiveBackup`'s own log line), and because the
/// keep filter runs before the write rather than before the wire, every one of
/// those drained files has already been transferred. Serve the manifest from the
/// last run and the same exchange carries only what changed.
///
/// This is not a new mechanism being invented here — it is the one the retry path
/// already relies on: `ProtectiveBackup`'s attempt loop keeps a partial baseline
/// on purpose because wiping it "makes every retry a FULL re-upload of the whole
/// protective set — the single most expensive thing this app does". The only
/// thing this file adds is using that baseline *across runs* instead of only
/// within one.
///
/// ## The shape
///
/// ```
/// Documents/Baseline/<udid>/
///   Manifest.db      pristine, device-produced, taken BEFORE the prune mutates
///                    the working copy in place
///   baseline.json    the record — written only after a restore reached its
///                    postcondition, and the only thing that authorises a seed
/// ```
///
/// The split matters: the *pruned* manifest is what a restore needs, the
/// *pristine* one is what the device needs, and today they are the same file
/// inside the working tree. Keeping the pristine copy aside is what makes
/// "reuse" possible without weakening the prune.
///
/// ## The invariant
///
/// **A record exists if and only if a tree matching it exists.** That is
/// enforced by construction: the only way to lose the tree is the full path,
/// which wipes the working directory, and the full path deletes the record in
/// the same breath (`clear(udid:)`). A seed therefore never has to trust a
/// record over the tree — the two are created and destroyed together.
///
/// ## What invalidates it
///
/// Device (UDID), OS version, the protective keep-set, and age. Each has its own
/// reason and its own log line, because a silent fall-back to the full pull is
/// indistinguishable from the feature not working:
///
/// * **UDID** — a baseline is one device's manifest; its rows mean nothing on
///   another.
/// * **version / productType** — a layout change between releases moves files
///   the manifest names.
/// * **keep-set hash** — see `ProtectiveBackup.keepSetHash`. A file the rules
///   did not name was drained and never stored; if the rules later gain a
///   prefix, a seeded manifest would tell the device "unchanged, do not send"
///   for exactly the files the new rule wants, and they would never come back.
///   This is the one invalidation that protects correctness rather than hygiene.
/// * **age** — the backstop for everything not enumerated. It is also what
///   covers a beta → release swap that keeps the same `ProductVersion` (the
///   build number is not part of the key; `DeviceIdentity` carries version and
///   product type only, and adding a lockdown read for a field whose changes
///   already imply an OS update is not worth a second round trip).
enum BackupBaseline {
    /// How long a baseline may be reused without a fresh full pull.
    static let maxAgeDays = 7

    /// The record next to the retained manifest. Its presence *is* the
    /// authorisation — there is no separate "valid" flag to fall out of sync.
    struct Record: Codable, Equatable {
        var udid: String
        var productVersion: String
        var keepSetHash: String
        /// When the run that produced this baseline confirmed its restore.
        var committedAt: Date

        var describe: String {
            let age = Int(Date().timeIntervalSince(committedAt) / 86_400)
            return "iOS \(productVersion), keep-set \(keepSetHash), \(age) day(s) old"
        }
    }

    /// What a run should do about the pull, and why.
    enum Plan {
        /// Wipe the working tree and pull everything — today's behaviour.
        case full(reason: String)
        /// Keep the tree and serve the retained manifest.
        case seeded(Record)

        var isSeeded: Bool {
            if case .seeded = self { return true }
            return false
        }

        var reason: String {
            switch self {
            case .full(let reason): return reason
            case .seeded(let record): return "seeded from the retained pull (\(record.describe))"
            }
        }
    }

    // MARK: - Deciding

    /// Whether the retained baseline may be used, and if not, why not.
    ///
    /// - Parameter enabled: the development switch. Off means full, always —
    ///   this path changes what the device is asked for, and a half-proven one
    ///   must not be the default.
    static func plan(udid: String,
                     productVersion: String,
                     enabled: Bool) -> Plan {
        guard enabled else {
            return .full(reason: "the incremental pull switch is off (Dev.IncrementalPull)")
        }
        guard let record = record(udid: udid) else {
            return .full(reason: "no baseline recorded yet — the first run after switching this "
                + "on is a full pull, and the next one can be incremental")
        }
        guard let retained = manifestURL(udid: udid), FileManager.default.fileExists(atPath: retained.path)
        else {
            return .full(reason: "the record survived but its Manifest.db did not")
        }
        guard record.udid == udid else {
            return .full(reason: "the baseline belongs to \(record.udid), not \(udid)")
        }
        guard record.productVersion == productVersion else {
            return .full(reason: "the device changed since the baseline was taken "
                + "(was iOS \(record.productVersion), now iOS \(productVersion))")
        }
        let hash = ProtectiveBackup.keepSetHash
        guard record.keepSetHash == hash else {
            return .full(reason: "the protective keep-set changed (\(record.keepSetHash) → \(hash)): "
                + "a file it now names was drained and never stored, so a seeded manifest would "
                + "tell the device not to send it")
        }
        let age = Date().timeIntervalSince(record.committedAt)
        guard age < Double(maxAgeDays) * 86_400 else {
            return .full(reason: "the baseline is \(Int(age / 86_400)) day(s) old "
                + "(limit \(maxAgeDays))")
        }
        return .seeded(record)
    }

    // MARK: - Seeding

    /// Put the retained manifest where the device expects the host's manifest.
    ///
    /// MUST run after `HostManifests.ensure` and INSTEAD OF
    /// `HostManifests.writeSQLiteManifest` — the latter deletes and recreates the
    /// file empty, which is precisely the "nothing backed up previously" answer
    /// that makes the device offer everything.
    ///
    /// - Returns: true when the working manifest is the retained one. False
    ///   means the caller must fall back to the empty manifest: a seed that
    ///   silently left a missing or half-copied database would abort the
    ///   transfer with no payload offered at all.
    /// - Parameter dropDomain: a domain to strip from the seeded manifest, so the
    ///   device treats its files as unknown and uploads them again.
    ///
    ///   Load-bearing for the *merged* pull. A container fetched that way (the
    ///   PosterBoard store) has its rows pruned and its payloads swept as orphans
    ///   at the end of every run — they are not in the protective keep-set — while
    ///   the retained manifest still lists them. Seeding that manifest unchanged
    ///   would tell the device "unchanged, do not send" for exactly the files the
    ///   next run needs to read, and the failure would surface in the database
    ///   reader as "the manifest lists X but its payload is not on disk".
    @discardableResult
    static func seedManifest(deviceDir: URL, udid: String, dropDomain: String? = nil) -> Bool {
        let fm = FileManager.default
        guard let retained = manifestURL(udid: udid), fm.fileExists(atPath: retained.path) else {
            return false
        }
        let working = ManifestStore(deviceDir: deviceDir).dbPath
        do {
            if fm.fileExists(atPath: working) { try fm.removeItem(atPath: working) }
            // Copied, not moved: the retained copy is the baseline for the run
            // after this one too.
            try fm.copyItem(atPath: retained.path, toPath: working)
            if let dropDomain {
                let dropped = ManifestStore(deviceDir: deviceDir).dropRows(domain: dropDomain)
                AppLog.write("baseline: dropped \(dropped) row(s) of \(dropDomain) from the seeded "
                    + "manifest, so the device uploads that container again")
            }
            // A seeded database that cannot be read is worse than none: the
            // device would abandon the exchange ("Failed to send file
            // Manifest.db: not found (-6)" is what a missing one produced).
            guard ManifestStore(deviceDir: deviceDir).rowCount() > 0 else {
                AppLog.write("baseline: the retained Manifest.db has no rows — falling back to "
                    + "the empty manifest, which means a full pull")
                try? fm.removeItem(atPath: working)
                return false
            }
            return true
        } catch {
            AppLog.write("baseline: could not seed \(working) "
                + "(\(error.localizedDescription)) — falling back to the empty manifest")
            return false
        }
    }

    // MARK: - Retaining

    /// Keep the manifest the device just uploaded, BEFORE the prune rewrites the
    /// working copy in place.
    ///
    /// - Returns: a line for the run log either way; "not saved" carries the
    ///   reason, because a baseline that is silently never written looks exactly
    ///   like one that is written and never used.
    @discardableResult
    static func snapshot(deviceDir: URL, udid: String) -> String {
        let store = ManifestStore(deviceDir: deviceDir)
        guard store.exists else {
            return "not saved — the exchange left no Manifest.db to retain"
        }
        let rows = store.rowCount()
        guard rows > 0 else {
            return "not saved — the device did not upload its own Manifest.db (0 rows), so there "
                + "is nothing to diff against next time"
        }
        let fm = FileManager.default
        let target = AppPaths.baselineDir(udid: udid).appendingPathComponent("Manifest.db")
        let staging = target.appendingPathExtension("new")
        do {
            try fm.createDirectory(at: target.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            if fm.fileExists(atPath: staging.path) { try fm.removeItem(at: staging) }
            // Copy then swap, so a crash mid-copy cannot leave a truncated
            // database behind. The `.new` suffix marks an unfinished copy, and
            // the record (written only by `commit`) is what decides whether this
            // file is ever read.
            try fm.copyItem(atPath: store.dbPath, toPath: staging.path)
            if fm.fileExists(atPath: target.path) { try fm.removeItem(atPath: target.path) }
            try fm.moveItem(atPath: staging.path, toPath: target.path)
            let bytes = (try? fm.attributesOfItem(atPath: target.path)[.size] as? NSNumber)??.int64Value
            return "saved \(rows) row(s), "
                + ByteCountFormatter.string(fromByteCount: bytes ?? 0, countStyle: .file)
                + " — the next run can be a delta if this one reaches its restore"
        } catch {
            return "not saved — \(error.localizedDescription)"
        }
    }

    /// Declare the retained manifest usable. Called only after the restore
    /// confirmed its own completion, so a baseline never describes a tree that a
    /// failed run left half-written.
    static func commit(udid: String, productVersion: String) {
        let fm = FileManager.default
        guard let manifest = manifestURL(udid: udid), fm.fileExists(atPath: manifest.path) else {
            // Silent on purpose: the iOS 26 branch never pulls a Manifest.db, and
            // `snapshot` has already said so in the log for the runs where it was
            // expected. A line here would fire on every iOS 26 apply and say
            // nothing.
            return
        }
        let record = Record(udid: udid,
                            productVersion: productVersion,
                            keepSetHash: ProtectiveBackup.keepSetHash,
                            committedAt: Date())
        do {
            let data = try JSONEncoder().encode(record)
            let url = AppPaths.baselineDir(udid: udid).appendingPathComponent("baseline.json")
            try data.write(to: url, options: .atomic)
            AppLog.write("baseline: committed — \(record.describe). The next iOS 27 apply on this "
                + "device will ask for a delta instead of the whole device walk.")
        } catch {
            AppLog.write("baseline: could not write the record "
                + "(\(error.localizedDescription)) — the retained manifest stays unused")
        }
    }

    /// Throw the baseline away. MUST be called whenever the working tree is
    /// wiped: the record's whole meaning is "a tree matching this exists".
    static func clear(udid: String, reason: String) {
        let dir = AppPaths.baselineDir(udid: udid)
        guard FileManager.default.fileExists(atPath: dir.path) else { return }
        try? FileManager.default.removeItem(at: dir)
        AppLog.write("baseline: cleared (\(reason))")
    }

    /// `Manifest.db` should not be half a directory away from its record.
    static func record(udid: String) -> Record? {
        let url = AppPaths.baselineDir(udid: udid).appendingPathComponent("baseline.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Record.self, from: data)
    }

    private static func manifestURL(udid: String) -> URL? {
        AppPaths.baselineDir(udid: udid).appendingPathComponent("Manifest.db")
    }
}
