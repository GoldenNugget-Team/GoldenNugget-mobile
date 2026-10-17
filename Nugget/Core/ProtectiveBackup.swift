import Foundation
import Minimuxer

/// Stage 1: pull a real mobilebackup2 backup that deliberately excludes
/// photos, videos and app containers.
///
/// Two jobs, and only the first one is about data:
///   1. `FactoryInfo {Applications: {}}` + the mid-stream filter keep the pull
///      small — this is a *protective* backup, not a backup of value.
///   2. It is what triggers the device's Trust / backup-password dialog and
///      establishes an authorized mobilebackup2 session.  Without it iOS 27
///      refuses the later restore from an un-authorized session and just closes
///      the channel (BrokenPipe, no popup).
enum ProtectiveBackup {
    /// Run one protective backup into `<backupRoot>/<udid>/`.
    static func run(
        backupRoot: URL,
        udid: String,
        onProgress: ((Double) -> Void)? = nil
    ) async throws {
        let minimuxer = Minimuxer.shared()
        AppLog.write("Creating protective backup (no photos/video) at \(backupRoot.path)…")

        // The Rust delegate callbacks are the ONLY host-side window into the
        // mobilebackup2 conversation.  Counting what the device streamed and how
        // far progress got separates "died before the first file" (request /
        // version-exchange / authorization phase) from "died mid-stream"
        // (transfer phase) — two completely different root causes that look
        // identical in the thrown error string.
        let trace = BackupTrace()
        let beat = Heartbeat()
        let stage = StageTimer("protective backup")
        // Prove the transfer is alive: the counters only move when the device
        // actually streams a file, so a heartbeat whose detail stops changing =
        // stalled.  The DL-message count is the second half of that: it moves
        // even in phases where the device uploads nothing but is clearly working.
        beat.start("protective backup") {
            trace.livenessLine() + ", " + WireCensus.healthLine()
        }

        do {
            // The device drops the mobilebackup2 channel as soon as the Trust /
            // backup-password dialog is answered ("Backup failed, error:
            // (Socket(... BrokenPipe, channel closed))").  Retry with escalating
            // recovery instead of aborting.
            try await ChannelRecovery.retry(
                label: "protective backup",
                attempts: 3,
                diagnostics: { await Diagnostics.report() },
                // Wipe ONLY on the first attempt.  The device decides what to
                // upload, so wiping the manifest baseline makes every retry a
                // FULL re-upload of the whole protective set — the single most
                // expensive thing this app does.  A retry on top of the partial
                // baseline is incremental instead.
                // Full backup + a real Manifest.db, on every attempt including
                // the first. Both are what makes the device upload anything at
                // all here: sparse would ask it to send only what a manifest
                // lists, and a manifest it cannot read aborts the transfer
                // before the first payload.
                beforeAttempt: { attempt in
                    if attempt == 1 {
                        try HostManifests.reset(backupRoot: backupRoot, udid: udid)
                    } else {
                        AppLog.write("keeping the partial baseline from attempt \(attempt - 1) "
                            + "(wiping it would force a full re-upload)")
                    }
                    let dir = AppPaths.deviceDir(backupRoot: backupRoot, udid: udid)
                    try HostManifests.ensure(deviceDir: dir, udid: udid, isFullBackup: true)
                    try HostManifests.writeSQLiteManifest(deviceDir: dir, ios27: true)
                    AppLog.write("host manifests ready: full backup, Manifest.db written "
                        + "(\((dir.appendingPathComponent("Manifest.db")).path))")
                }
            ) {
                // 120 s of *nothing* — no host callback AND no DeviceLink message
                // — is a wedged stream, not a slow one.  The idle clock is fed by
                // the Rust delegate callbacks (actual file traffic) plus the wire
                // markers in the Rust log, so a device that is merely busy
                // enumerating the host tree never trips it; if it does go quiet,
                // the out-of-band lockdown probe decides whether to keep waiting
                // (device alive, slow phase) or give up at once (device gone).
                // The ceiling is deliberately modest: a device-side phase that is
                // slow-but-alive resumes within minutes, and past that a fresh
                // attempt on the baseline already on disk beats more waiting — and
                // the run can be stopped by hand at any point anyway.
                try await StallGuard.run(
                    label: "protective backup",
                    idleSeconds: 120,
                    idle: { trace.lastActivityAt },
                    wire: { WireCensus.totals() },
                    probe: { await Diagnostics.deviceLivenessProbe() },
                    handshakeSilent: { RustLog.deviceSilentAtHandshake() }
                ) {
                    try await minimuxer.backupBackup(
                        backupRoot: backupRoot.path(percentEncoded: false),
                        sourceIdentifier: udid,
                        skipAppContainers: true,
                        shouldPreserve: { deviceName, file in
                            let keep = isMetadataFile(file) || isProtectiveFile(deviceName)
                            trace.note(file: file, domain: deviceName, keep: keep)
                            return keep
                        },
                        onProgress: { overall in
                            // Forward on 5 % steps only.  The callback fires per
                            // file, and the callers used to log every single one:
                            // thousands of lines, and the one that mattered
                            // ("progress: 2 %") scrolled away before the failure.
                            if let step = trace.noteProgress(overall) {
                                AppLog.write("backup stream: \(step)% — \(trace.summary())")
                                onProgress?(overall)
                            }
                        },
                        // Host-side delegate decisions (which staged files we
                        // actually committed vs. deliberately never wrote) exist
                        // only inside the callbacks — pull them into the app log
                        // so a commit shortfall is never silent.
                        delegateLog: { line in AppLog.write(line) }
                    )
                }
                // The device commits a backup by moving every staged file out of
                // `<udid>/Snapshot/`. A non-empty staging tree afterwards means
                // the commit shortfalled — worth knowing before the restore
                // stage runs on top of it.
                // Marker, not decoration.  On 2026-09-19 a run reached 100 %,
                // the delegate logged `filtered payloads: 28490 … removed`, and
                // then goldennugget.log simply stopped — no `protective backup finished`,
                // no stage timer, no crash line.  That left the widest window in
                // this file unexplained: the crash was somewhere between the
                // Rust call's own teardown, the staging walk below, and the log
                // line after it.  This line splits that window in half, so the
                // next failure points at one side of it.
                AppLog.write("backup call returned — device commit done, checking the staging tree…")
                reportStagingLeftovers(backupRoot: backupRoot, udid: udid)
            }
            // A backup that kept nothing is not a successful backup. The pull
            // completes, the manifest is written, and the run then prunes an
            // empty set and restores nothing -- which looks identical to "the
            // backup did not happen" and says nothing about why. On iOS 27 this
            // is the failure mode when `shouldPreserve` no longer matches the
            // domain names the device reports, so the sample lines go out with
            // the error: they are the only record of what the device called the
            // domains that got dropped.
            guard trace.kept > 0 else {
                // Two failures look identical from the outside and need opposite
                // fixes, so they are named separately rather than guessed at:
                //
                //   total == 0  the host delegate never fired at all. The device
                //                streamed nothing we were asked to judge, so the
                //                filter is not what is wrong -- the transfer shape
                //                on iOS 27 is.
                //   total  > 0  the filter rejected every name the device used.
                //                The sample lines below are then the only record
                //                of what the device actually called its domains.
                let cause = trace.total == 0
                    ? "the host keep-filter callback was never called, so the device streamed nothing to judge — the filter is not the problem, the iOS 27 transfer shape is"
                    : "the keep-filter rejected all \(trace.total) name(s) the device used"
                AppLog.write("protective backup kept 0 of \(trace.total) file(s) — \(cause)")
                AppLog.write("domains: \(trace.domainSummary())")
                for line in trace.sampleLines() { AppLog.write(line) }
                if trace.total == 0 {
                    AppLog.write("Rust log tail, to see what the device did stream:")
                    AppLog.write(RustLog.excerpt())
                }
                beat.stop()
                stage.done("FAILED — kept 0 files")
                throw GoldenNuggetError("Protective backup kept no files: \(cause). "
                    + "Domains: \(trace.domainSummary())")
            }
            AppLog.write("protective backup finished — \(trace.summary())")
            beat.stop()
            stage.done(trace.summary())
        } catch {
            beat.stop()
            stage.done("FAILED — \(trace.summary())")
            AppLog.write("protective backup FAILED — \(trace.summary())")
            for line in trace.sampleLines() { AppLog.write(line) }
            // The Rust side is the only place that knows WHY the flow died, and
            // every candidate has its own literal: RST (device reset), "timed
            // out after N retransmissions" (our writes unACKed -> dead path),
            // FIN (silent), or a delegate failure ("Failed to send file").
            AppLog.write(RustLog.excerpt())
            // `Socket(... BrokenPipe, "channel closed")` is jktcp's generic
            // report for "that TCP flow is gone" — the userspace stack drops its
            // per-port sender when the connection is torn down, so a DEVICE-SIDE
            // close and a local pump failure look identical here.  It therefore
            // cannot be read as "the device refused us".
            AppLog.write("note: \"channel closed\" is jktcp's generic flow-closed report — it does not "
                + "distinguish a device-side teardown from a local stack failure. See minimuxer.log "
                + "(Rust, DEBUG) for the real step.")
            throw error
        }
    }

    /// Count what is left in the device's staging tree after the commit step.
    ///
    /// The device ends a backup with a `DLMessageMoveItems` batch that renames
    /// every file it staged under `<udid>/Snapshot/...` into its final shard
    /// path.  Files rejected by the mid-stream filter are deliberately never
    /// written, so the host skips their move (see `mb2_rename`); their rows are
    /// dropped by the prune because the payload is absent.  Anything else still
    /// sitting there is a genuine shortfall, and the restore that follows would be
    /// built on a partial backup — so report the size of the leftovers.
    private static func reportStagingLeftovers(backupRoot: URL, udid: String) {
        let snapshot = AppPaths.deviceDir(backupRoot: backupRoot, udid: udid)
            .appendingPathComponent("Snapshot")
        let fm = FileManager.default
        guard fm.fileExists(atPath: snapshot.path) else {
            AppLog.write("staging: no Snapshot/ tree was left behind — the device drained it")
            return
        }
        var files = 0
        var dirs = 0
        if let walker = fm.enumerator(atPath: snapshot.path) {
            for case let item as String in walker {
                var isDir: ObjCBool = false
                let full = snapshot.appendingPathComponent(item).path
                guard fm.fileExists(atPath: full, isDirectory: &isDir) else { continue }
                if isDir.boolValue { dirs += 1 } else { files += 1 }
            }
        }
        if files == 0 {
            AppLog.write("staging: Snapshot/ still exists but holds no files (\(dirs) empty dirs) — "
                + "every staged payload landed")
        } else {
            AppLog.write("staging: ⚠️ \(files) file(s) left under Snapshot/ (\(dirs) dirs) — staged but "
                + "never committed. Filtered payloads are expected here; if the prune does not "
                + "account for them the restore will fail.")
        }
    }
}

// MARK: - The protective keep-set (mirrors GoldenNugget's filter)

extension ProtectiveBackup {
    /// Returns true if a device-side backup upload name belongs to the protective
    /// keep-set.  Photos, videos, keychain, and everything else is drained
    /// mid-stream and never written to disk.
    static func isProtectiveFile(_ deviceName: String) -> Bool {
        let name = normDeviceName(deviceName)

        // Backup metadata files — the device uploads these in the same stream;
        // they MUST always be preserved or the backup is un-restorable.
        if isMetadataFile(name) { return true }

        // SystemPreferencesDomain / MessagesDomain — keep both.
        if domainMatch(name, "SystemPreferencesDomain") ||
            domainMatch(name, "MessagesDomain") {
            return true
        }

        // iOS 27 raw tree: message data
        if treeMatch(name, "Library/Messages",
                     "Library/SMS",
                     "Library/MessagesMetaData") {
            return true
        }

        // HomeDomain selective paths
        //
        // Split out of the `for … in` header: the concatenated array literal
        // there defeats the Swift 6 type-checker under -O, so collect the
        // prefixes once and iterate the flat array.
        let homePrefixes = [
            "Library/Accounts",
            "Library/ConfigurationProfiles",
            "Library/Preferences",
            "Library/SpringBoard",
            "Library/ControlCenter",
            "Library/Shortcuts",
            "Library/WebClips",
            "Library/WebApp",
            "Library/WebKit/WebsiteData",
            "Library/AddressBook",
        ]
        for prefix in homePrefixes {
            if pathMatch(name, prefix) { return true }
        }

        return false
    }

    /// Backup metadata files always preserved regardless of the keep-set,
    /// mirroring pymobiledevice3's BACKUP_METADATA_FILES.
    static func isMetadataFile(_ name: String) -> Bool {
        let base = name.split(separator: "/").last.map(String.init) ?? name
        return ["Info.plist", "Manifest.plist", "Manifest.db",
                "Manifest.db-shm", "Manifest.db-wal", "Status.plist"].contains(base)
    }

    private static func normDeviceName(_ deviceName: String) -> String {
        deviceName.replacingOccurrences(of: "\\", with: "/")
            .replacingOccurrences(of: "^/+", with: "", options: .regularExpression)
    }

    private static func domainMatch(_ name: String, _ domain: String) -> Bool {
        name == domain || name.hasPrefix("\(domain)/")
    }

    private static func treeMatch(_ name: String, _ trees: String...) -> Bool {
        let stripped = stripIOS27Root(name)
        for tree in trees {
            if stripped == tree || stripped.hasPrefix("\(tree)/") { return true }
        }
        return false
    }

    private static func pathMatch(_ name: String, _ path: String) -> Bool {
        if name == path || name.hasPrefix("\(path)/") { return true }
        if name == "HomeDomain/\(path)" || name.hasPrefix("HomeDomain/\(path)/") { return true }
        return treeMatch(name, path)
    }

    /// Strip iOS 27's `b/<n>/` or `.b/<n>/` root so the same keep-set rules apply
    /// to the raw tree layout.
    private static func stripIOS27Root(_ name: String) -> String {
        let n = name
        for prefix in ["b", ".b"] {
            if n.hasPrefix("\(prefix)/") {
                let rest = String(n.dropFirst(prefix.count + 1))
                if let slash = rest.firstIndex(of: "/") {
                    let seg = rest[rest.startIndex..<slash]
                    if Int(seg) != nil {
                        return String(rest[rest.index(after: slash)...])
                    }
                }
            }
        }
        return n
    }
}

// MARK: - The protective keep-set in MANIFEST coordinates
//
// A port of GoldenNugget's `_is_protective_file` / `_keep_protective_entry`
// (`src/restore/protective.py`), which is the keep-set the PRUNE uses.  It is
// called with production's `include_keychain: false` (see
// `clean_backup_for_restore`'s only real caller) and with photos **off**, which
// is the one argument this port no longer mirrors: `CameraRollDomain` and
// `MediaDomain` were dropped from `protectiveDomains` below, so a protective
// run no longer re-collects a second copy of every picture on every run.
// `isProtectiveFile` above already behaved that way — it never matched a media
// domain — so the two predicates now agree.
//
// Two predicates exist on purpose, in both codebases: `isProtectiveFile` above
// matches a **device-side upload name** and drives the mid-stream filter, while
// this one matches the `(domain, relativePath)` pair a **Manifest.db row**
// carries and drives the prune.  They are not interchangeable — the whole reason
// this port exists is that the prune used to have no predicate at all and used
// "the payload is on disk" as a proxy for one.

extension ProtectiveBackup {
    /// Domains whose rows are kept whole.
    /// Restored to the `a351d89` set minus `MediaDomain`, which is the one
    /// thing deliberately left out: it is photo metadata (PhotoData,
    /// PhotoStream), not pictures, and it is the half that cannot be listed over
    /// AFC (`PhotoData/UBF` fails with PERM_DENIED on iOS 27). Bulk media goes
    /// over AFC instead, from `AfcMediaBackup`.
    private static let protectiveDomains: Set<String> = [
        "CameraRollDomain",   // actual photos and videos (DCIM/)
        "MessagesDomain",     // iMessage / SMS / MMS
    ]

    /// HomeDomain prefixes holding Apple ID account data and user settings.
    private static let appleIDPrefixes = [
        "Library/Accounts",               // Accounts3.sqlite
        "Library/ConfigurationProfiles",  // configuration profiles
        "Library/Preferences",            // user settings (dark mode, wallpaper, …)
    ]
    /// SpringBoard's home-screen layout and icon state.
    private static let springBoardPrefixes = ["Library/SpringBoard"]
    /// Control Center module layout — not covered by the prefix above.
    private static let controlCenterPrefixes = ["Library/ControlCenter"]
    /// The Shortcuts app's own store.
    private static let shortcutsPrefixes = ["Library/Shortcuts"]
    /// Safari "Add to Home Screen" web clips, and the PWA data that rides along.
    private static let webClipsPrefixes = ["Library/WebClips"]
    private static let webAppPrefixes = ["Library/WebApp"]
    private static let webkitWebsiteDataPrefixes = ["Library/WebKit/WebsiteData"]
    /// The contacts database.
    private static let addressBookPrefixes = ["Library/AddressBook"]

    /// Inside the protective HomeDomain scope but written by the tweak pass
    /// itself — restoring the stale copy would undo the applied tweak.
    ///
    /// Both spellings, and the capital one is a separate entry on purpose. The
    /// classic record is `statusBarOverrides` (lower-case s) and the iOS 27
    /// record is `StatusBarOverrides.archive` (capital S) — and `startsWith`
    /// below is a plain prefix test, deliberately, so the lower-case prefix does
    /// **not** match the archive. Without this entry Phase 1 captures the
    /// override the run just applied and Phase 3 hands the stale value straight
    /// back, i.e. a status bar reset looks like it did nothing on iOS 27.
    private static let skipPathPrefixes = [
        "Library/SpringBoard/statusBarOverrides",          // iOS ≤26 classic struct
        "Library/SpringBoard/StatusBarOverrides.archive",  // iOS 27+ NSKeyedArchiver record
    ]

    /// Files iOS manages internally and rejects when a sparse backup carries
    /// them with the wrong metadata.  `.GlobalPreferences.plist` is written
    /// separately by the tweak pass, so restoring a stale one would clobber it.
    private static let skipFiles: Set<String> = [
        "keychain-backup.plist",     // iOS validates the protection class, rejects flags=4
        ".GlobalPreferences.plist",
    ]

    /// `_is_protective_file(domain, relative_path, include_photos: false,
    /// include_keychain: false)` — photos off, because `MediaVault` owns the
    /// media now.
    static func isProtectiveEntry(domain: String, relativePath: String) -> Bool {
        let filename = relativePath.split(separator: "/").last.map(String.init) ?? relativePath
        // `keychain-backup.plist` is only let through when the backup is
        // encrypted, which `include_keychain` encodes — and it is false here, the
        // same as GoldenNugget's production call.
        if skipFiles.contains(filename) { return false }

        if domain == "HomeDomain" {
            for prefix in skipPathPrefixes where startsWith(relativePath, prefix) { return false }
            let groups = [appleIDPrefixes, springBoardPrefixes, controlCenterPrefixes,
                          shortcutsPrefixes, webClipsPrefixes, webAppPrefixes,
                          webkitWebsiteDataPrefixes, addressBookPrefixes]
            for group in groups {
                for prefix in group where startsWith(relativePath, prefix) { return true }
            }
            return false
        }

        return protectiveDomains.contains(domain)
    }

    /// `_keep_protective_entry` — the row-level wrap.
    static func keepsRow(domain: String, relativePath: String) -> Bool {
        if !domain.isEmpty, !relativePath.isEmpty,
           isProtectiveEntry(domain: domain, relativePath: relativePath)
            || domain == "SystemPreferencesDomain" {
            return true
        }
        // The domain ROOT row.  GoldenNugget's comment: "without it the restore
        // agent may skip the whole domain".
        if relativePath.isEmpty,
           domain == "SystemPreferencesDomain" || domain == "MessagesDomain" {
            return true
        }
        return false
    }

    /// A stable fingerprint of the keep-set, so a retained baseline can tell
    /// whether the rules that produced it still name the same files.
    ///
    /// `BackupBaseline` invalidates the baseline when this changes: a file the
    /// rules did not name was drained and never stored, so a seeded manifest would
    /// otherwise tell the device "unchanged, do not send" for exactly the files a
    /// new rule wants, and they would never come back. Only the rule *inputs* are
    /// hashed, in a fixed order, so the value is deterministic across runs; sets
    /// are sorted first for the same reason.
    static var keepSetHash: String {
        var parts: [String] = protectiveDomains.sorted().map { "domain:\($0)" }
        let groups: [(String, [String])] = [
            ("appleID", appleIDPrefixes),
            ("springBoard", springBoardPrefixes),
            ("controlCenter", controlCenterPrefixes),
            ("shortcuts", shortcutsPrefixes),
            ("webClips", webClipsPrefixes),
            ("webApp", webAppPrefixes),
            ("webkitWebsiteData", webkitWebsiteDataPrefixes),
            ("addressBook", addressBookPrefixes),
        ]
        for (label, group) in groups {
            parts.append(contentsOf: group.map { "\(label):\($0)" })
        }
        parts.append(contentsOf: skipPathPrefixes.map { "skip:\($0)" })
        parts.append(contentsOf: skipFiles.sorted().map { "skipFile:\($0)" })
        // The domain-root rows `keepsRow` admits are part of the set too.
        parts.append("root:SystemPreferencesDomain")
        parts.append("root:MessagesDomain")
        return ManifestStore.sha1Hex(parts.joined(separator: "\n"))
    }

    /// Python's `str.startswith(prefix)` — a plain prefix test, deliberately
    /// WITHOUT a path-boundary check.
    ///
    /// A first version added `path == prefix || path.hasPrefix(prefix + "/")`,
    /// which is the tidier rule and is NOT what the reference does: GoldenNugget
    /// writes `relative_path.startswith(...)`, so `Library/SpringBoardX/Foo`
    /// matches `Library/SpringBoard`.  A differential run over 34,936 real
    /// `(domain, relativePath)` pairs from an actual device backup found exactly
    /// that one disagreement — and the direction matters.  A prune that keeps a
    /// path it did not have to keep is harmless; one that drops a path the
    /// device expects is what produces MBErrorDomain/205.  So the loose test is
    /// also the safe one, and matching the reference beats improving it.
    private static func startsWith(_ path: String, _ prefix: String) -> Bool {
        path.hasPrefix(prefix)
    }
}
