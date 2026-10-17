import Foundation

/// The row shape the device writes for one backup domain.
///
/// Filled in from the device's own rows in
/// `MobileSync/Backup/00008130-001431082E40001C` (iPad16,2 / iOS 27.0
/// 24A5424a) — the same ground truth `MBFileBlob`'s constants come from, and
/// the same rule applies: the device's record is the contract.  Where
/// GoldenNugget stamps every plist tweak with `Tweak.__init__`'s default
/// `owner=501, group=501`, the device disagrees per domain (the footnote's row
/// is `-2/-2`, a `DatabaseDomain` row is `0/0`), and the device wins.
///
/// `verified` records whether this app has ever *shipped* a restore against
/// that shape.  The two set to `true` are the classes this app already delivers
/// (`AppDomain-*` and the footnote's `SysSharedContainerDomain`); the others are
/// measured off the backup but have not been through a run, so they are warned
/// about in the log rather than quietly presented as proven.
struct TweakRowProfile {
    let fileOwner: Int
    let fileGroup: Int
    let fileProtectionClass: Int
    /// The data-protection exception publisher for file rows; nil where the
    /// device's file rows carry no exception at all (measured:
    /// `SystemPreferencesDomain`).
    let fileExceptionPublisher: String?
    let dirOwner: Int
    let dirGroup: Int
    let dirProtectionClass: Int
    let rootOwner: Int
    let rootGroup: Int
    let rootProtectionClass: Int
    /// Whether this domain's **file** rows carry a `Digest` (SHA-1 of the
    /// payload).  Not a style choice: the device writes one on every file row of
    /// some domains and on none of others, and a file record it cannot match to
    /// the payload it received is answered with `MBErrorDomain/205 — "Manifest
    /// references files not in backup"`.
    ///
    /// Measured over the device's own backup, the split is clean — 110 domains
    /// with file rows, none mixing the two shapes:
    ///
    ///   * **carries one** (11): `ManagedPreferencesDomain`, `HomeDomain`,
    ///     `SystemPreferencesDomain`, `DatabaseDomain`, `RootDomain`,
    ///     `MobileDeviceDomain`, `WirelessDomain`, `NetworkDomain`,
    ///     `KeychainDomain`, `ProtectedDomain`, `InstallDomain`
    ///     (`ManagedPreferencesDomain` 4/4, `HomeDomain` 708/708,
    ///     `SystemPreferencesDomain` 9/9, `DatabaseDomain` 3/3);
    ///   * **never carries one** (99): the `AppDomain*` family,
    ///     `SysSharedContainerDomain-*`, `SysContainerDomain-*`, `CameraRollDomain`.
    ///
    /// Directory rows and symlink rows never carry one, so this only ever applies
    /// to the file row.
    ///
    /// The two `false` values are the two classes this app had shipped a restore
    /// with — AppDomain (the app-container flow) and SysSharedContainer (the Lock
    /// Screen footnote) — which is exactly why an injector that never wrote a
    /// digest passed for both and could not pass for the four below.
    let carriesDigest: Bool
    let verified: Bool
    /// Where the numbers came from, for the warning line.
    let note: String

    /// Pick the profile for a domain.
    static func forDomain(_ domain: String) -> TweakRowProfile {
        if domain.hasPrefix("AppDomain") { return .appContainer }
        if domain.hasPrefix("SysSharedContainerDomain") || domain.hasPrefix("SysContainerDomain") {
            return .systemContainer
        }
        switch domain {
        case "ManagedPreferencesDomain": return .managedPreferences
        case "HomeDomain": return .homeDomain
        case "SystemPreferencesDomain": return .systemPreferences
        case "DatabaseDomain": return .database
        default: return .unmeasured
        }
    }
}

extension TweakRowProfile {
    /// `AppDomain-*`: the class `BackupInjector.inject` already delivers, with
    /// production evidence (this app's own app-container restores).
    static let appContainer = TweakRowProfile(
        fileOwner: 501, fileGroup: 501, fileProtectionClass: PROTECTION_CLASS_FILE,
        fileExceptionPublisher: "com.apple.containermanagerd_system",
        dirOwner: 501, dirGroup: 501, dirProtectionClass: PROTECTION_CLASS_DIR,
        rootOwner: 501, rootGroup: 501, rootProtectionClass: PROTECTION_CLASS_DIR,
        carriesDigest: false,
        verified: true,
        note: "AppDomain-* rows, as delivered by BackupInjector.inject")

    /// `SysSharedContainerDomain-*`: the class `BackupInjector.injectSystemPlist`
    /// already delivers (the Lock Screen footnote), with production evidence.
    static let systemContainer = TweakRowProfile(
        fileOwner: -2, fileGroup: -2, fileProtectionClass: PROTECTION_CLASS_SYSTEM_FILE,
        fileExceptionPublisher: "com.apple.containermanagerd_system",
        dirOwner: -2, dirGroup: -2, dirProtectionClass: PROTECTION_CLASS_SYSTEM_FILE,
        rootOwner: 0, rootGroup: 0, rootProtectionClass: PROTECTION_CLASS_DIR,
        carriesDigest: false,
        verified: true,
        note: "SysSharedContainerDomain rows, as delivered by BackupInjector.injectSystemPlist")

    /// Measured: `mobile/com.apple.springboard.plist`, `mobile/.GlobalPreferences.plist`
    /// and `mobile/com.apple.sharingd.plist` are all mode 0o100755, `501/501`,
    /// class 4, EA `com.apple.BackupAgent2`; the `mobile` dir row is `501/501`
    /// class 4 and the domain root is `0/0` class 4.
    static let managedPreferences = TweakRowProfile(
        fileOwner: 501, fileGroup: 501, fileProtectionClass: PROTECTION_CLASS_SYSTEM_FILE,
        fileExceptionPublisher: "com.apple.BackupAgent2",
        dirOwner: 501, dirGroup: 501, dirProtectionClass: PROTECTION_CLASS_SYSTEM_FILE,
        rootOwner: 0, rootGroup: 0, rootProtectionClass: PROTECTION_CLASS_SYSTEM_FILE,
        carriesDigest: true,
        verified: false,
        note: "ManagedPreferencesDomain rows")

    /// Measured: `Library/Preferences/.GlobalPreferences.plist` is mode
    /// 0o100600 `501/501` class 4 (EA `com.apple.cfprefsd`) and
    /// `com.apple.ScreenTimeAgent.plist` class 4 `501/501` (EA
    /// `com.apple.BackupAgent2`); the dir rows are class 0 `501/501`, root
    /// included.  One publisher is used for the file row rather than a
    /// per-file table — `BackupAgent2` is what the HomeDomain preference files
    /// this port writes are measured to carry.
    static let homeDomain = TweakRowProfile(
        fileOwner: 501, fileGroup: 501, fileProtectionClass: PROTECTION_CLASS_SYSTEM_FILE,
        fileExceptionPublisher: "com.apple.BackupAgent2",
        dirOwner: 501, dirGroup: 501, dirProtectionClass: PROTECTION_CLASS_DIR,
        rootOwner: 501, rootGroup: 501, rootProtectionClass: PROTECTION_CLASS_DIR,
        carriesDigest: true,
        verified: false,
        note: "HomeDomain rows")

    /// Measured: `SystemConfiguration/*.plist` are mode 0o100644, `0/0`,
    /// class 4, with **no** extended attribute; dir rows and the root are
    /// `0/0` class 4.
    static let systemPreferences = TweakRowProfile(
        fileOwner: 0, fileGroup: 0, fileProtectionClass: PROTECTION_CLASS_SYSTEM_FILE,
        fileExceptionPublisher: nil,
        dirOwner: 0, dirGroup: 0, dirProtectionClass: PROTECTION_CLASS_SYSTEM_FILE,
        rootOwner: 0, rootGroup: 0, rootProtectionClass: PROTECTION_CLASS_SYSTEM_FILE,
        carriesDigest: true,
        verified: false,
        note: "SystemPreferencesDomain rows")

    /// Measured: `com.apple.xpc.launchd/disabled.plist` is `0/0` class 4, EA
    /// `com.apple.BackupAgent2`; its dir rows are `0/0` class 4.
    static let database = TweakRowProfile(
        fileOwner: 0, fileGroup: 0, fileProtectionClass: PROTECTION_CLASS_SYSTEM_FILE,
        fileExceptionPublisher: "com.apple.BackupAgent2",
        dirOwner: 0, dirGroup: 0, dirProtectionClass: PROTECTION_CLASS_SYSTEM_FILE,
        rootOwner: 0, rootGroup: 0, rootProtectionClass: PROTECTION_CLASS_SYSTEM_FILE,
        carriesDigest: true,
        verified: false,
        note: "DatabaseDomain rows")

    /// A domain this port has no measurement for.  Falls back to the most
    /// common shape the backup shows for a system-owned preference file, and is
    /// reported as unmeasured on every run that uses it.
    static let unmeasured = TweakRowProfile(
        fileOwner: 501, fileGroup: 501, fileProtectionClass: PROTECTION_CLASS_SYSTEM_FILE,
        fileExceptionPublisher: "com.apple.BackupAgent2",
        dirOwner: 501, dirGroup: 501, dirProtectionClass: PROTECTION_CLASS_SYSTEM_FILE,
        rootOwner: 0, rootGroup: 0, rootProtectionClass: PROTECTION_CLASS_SYSTEM_FILE,
        // Follows the four measured domains above rather than the two `false`
        // ones: every domain this fallback can be reached for (`RootDomain`,
        // `MobileDeviceDomain`) is a system domain, and every system domain the
        // backup shows stamps a digest (RootDomain 36/36).
        carriesDigest: true,
        verified: false,
        note: "no measurement for this domain — using the common system-preference shape")
}

/// Writes compiled tweak payloads into a backup as restorable rows.
///
/// The row set per file is the one `BackupInjector.injectSystemPlist` already
/// uses and the one GoldenNugget's `_ensure_directory_rows` builds: a domain
/// root row, one `flags == 2` row per parent component, then the `flags == 1`
/// file row — "the iOS 27 restore agent skips a file whose parent directories
/// have no manifest rows" (`src/restore/inject.py:211-219`).
///
/// Inodes count up from the manifest's current maximum, matching
/// `inject_file_into_backup`, because the agent deduplicates by inode and
/// reusing one restores the wrong bytes.
enum TweakInjector {
    struct Report {
        let files: Int
        let dirRows: Int
        /// Domains whose row shape is measured but not yet proven by a run.
        let unverifiedDomains: [String]

        var summary: String {
            "\(files) tweak file(s) in \(dirRows) directory row(s)"
        }
    }

    /// Inject every payload.  Rows are upserted, so re-running is idempotent.
    static func inject(into deviceDir: URL, payloads: [TweakPayload]) throws -> Report {
        let store = ManifestStore(deviceDir: deviceDir)
        let fm = FileManager.default
        let now = Int(Date().timeIntervalSince1970)
        var nextInode = store.maxInode()
        var fileRows = 0
        var dirRows = 0
        var unverified: Set<String> = []

        for payload in payloads {
            let profile = TweakRowProfile.forDomain(payload.domain)
            if !profile.verified { unverified.insert(payload.domain) }
            let fileException = profile.fileExceptionPublisher
                .map { buildDataprotectionExtendedAttributes(publisher: $0) }
            // Read once. A payload on disk is a mapped file, so the write, the
            // size and the digest all have to share one read — three reads of a
            // video wallpaper is three passes over hundreds of megabytes.
            let bytes = try payload.bytes()

            var rows: [(path: String, flags: Int32)] = [("", 2)]
            var accumulated = ""
            for component in payload.relativePath.split(separator: "/").dropLast() {
                accumulated = accumulated.isEmpty ? String(component) : "\(accumulated)/\(component)"
                rows.append((accumulated, 2))
            }
            rows.append((payload.relativePath, 1))

            for row in rows {
                let isFile = row.flags == 1
                let isRoot = row.path.isEmpty
                let rowID = ManifestStore.fileID(domain: payload.domain, relativePath: row.path)
                if isFile {
                    let payloadURL = store.payloadURL(forFileID: rowID)
                    try fm.createDirectory(at: payloadURL.deletingLastPathComponent(),
                                           withIntermediateDirectories: true)
                    try bytes.write(to: payloadURL)
                    fileRows += 1
                } else {
                    dirRows += 1
                }

                nextInode += 1
                let blob = buildMBFileBlob(
                    relativePath: row.path,
                    mode: isFile
                        ? (Int(MODE_FILE_DEFAULT) | Int(S_IFREG))
                        : (Int(MODE_DIR_DEFAULT) | Int(S_IFDIR)),
                    size: isFile ? bytes.count : 0,
                    userID: isFile ? profile.fileOwner : (isRoot ? profile.rootOwner : profile.dirOwner),
                    groupID: isFile ? profile.fileGroup : (isRoot ? profile.rootGroup : profile.dirGroup),
                    protectionClass: isFile
                        ? profile.fileProtectionClass
                        : (isRoot ? profile.rootProtectionClass : profile.dirProtectionClass),
                    inodeNumber: nextInode,
                    timestamp: now,
                    // File rows of these domains are the class that carries one,
                    // and it is the SHA-1 of the bytes written just above — see
                    // `MBFileArchiver.digest` / `TweakRowProfile.carriesDigest`.
                    // Directory rows never carry a digest on the device.
                    digest: isFile && profile.carriesDigest ? payloadDigest(bytes) : nil,
                    // Only file rows carry the exception, per the measurements
                    // behind `TweakRowProfile` (and the same rule the injector
                    // for the shipping classes already follows).
                    extendedAttributes: isFile ? fileException : nil)
                try store.upsert(fileID: rowID, domain: payload.domain,
                                 relativePath: row.path, flags: row.flags, blob: blob)
            }
        }

        return Report(files: fileRows, dirRows: dirRows,
                      unverifiedDomains: unverified.sorted())
    }
}
