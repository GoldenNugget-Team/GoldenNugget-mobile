import CryptoKit
import Foundation

// The bytes of a backup 3.3 file record.
//
// These three symbols are the only survivors of the old `Backup.swift`: the
// rest of that file (`BackupFile` / `ConcreteFile` / `SymbolicLink` /
// `Directory` / `Backup` / `MobileBackupDatabase` / `MBDBRecord`) had zero
// references outside itself and was carried in the build for the sparserestore
// route this app no longer takes.
//
// What remains is the part the injector actually needs: the NSKeyedArchiver
// `MBFile` blob that goes in a Files row, plus the data-protection extended
// attribute the restore daemon expects on an app-container file.

/// Permission bits for a synthetic record.
///
/// Measured against a known-good device backup of the same iPad
/// (`MobileSync/Backup/00008130-001431082E40001C`), over 4000 `AppDomain-*`
/// file rows: the mode is `0o100644` for 3283 of them (`0o100700` 574,
/// `0o100600` 6, `0o100640` 4), and every directory row is `0o40755`.  A record
/// the device did not write itself is the one place a wrong value here cannot
/// be repaired by re-uploading, so it copies the common case exactly.
let MODE_FILE_DEFAULT: UInt16 = 0o644
let MODE_DIR_DEFAULT: UInt16 = 0o755

/// The data-protection class the device puts on each kind of row.
///
/// Same measurement: 3283/4000 file rows are class 3 and 133 are class 4 —
/// **not one is 0**, while every directory row is 0.  Both rows used to get 0.
let PROTECTION_CLASS_FILE: Int = 3
let PROTECTION_CLASS_DIR: Int = 0

/// The class the device puts on a **system-container** file row — 4, the
/// minority value among `AppDomain-*` rows but what the device writes for the
/// file class `injectSystemPlist` delivers.
///
/// Measured on the device's own row for the exact file that path injects
/// (`…/Manifest.db`, fileID `0affc9c4722175be11a30bb60e96880ffedf29d5` =
/// `SysSharedContainerDomain-systemgroup.com.apple.configurationprofiles/…/
/// SharedDeviceConfiguration.plist`) — which is also where the app-container
/// class-3 default comes from, so the two constants are two classes of one
/// measurement, not a smear of "3 or 4 is fine".
let PROTECTION_CLASS_SYSTEM_FILE: Int = 4

/// The `MBFile` object graph the device decodes out of a Files row's `file` blob.
///
/// The `@objc` name is load-bearing: `NSKeyedArchiver` writes the class name
/// into the archive and the device-side parser looks for `MBFile` literally.
///
/// The key set is copied from what the device itself writes, not from folklore:
/// over the same 4000 `AppDomain-*` file rows, `InodeNumber` is present in
/// **4000/4000** and `Digest` in **0/4000** (asymmetric `ExtendedAttributes` is
/// legitimate — 1808/4000 carry it).  This used to be the exact opposite: a
/// SHA1 `Digest` no iOS 27 row has, and no `InodeNumber` at all.
@objc(MBFile) private class MBFileArchiver: NSObject, NSCoding {
    var relativePath: String = ""

    /// **An `Int`, never a `UInt32`, and the difference is not cosmetic.**
    ///
    /// `NSCoder` has no `UInt32` overload for `encode(_:forKey:)`, so a `UInt32`
    /// silently takes the `Any?` overload: the number is boxed, the archiver
    /// stores it as a `$objects` entry, and the key holds a **reference**
    /// instead of an inline integer.  Every integer read path over such a blob
    /// then fails — measured against the real `NSKeyedUnarchiver` (2026-09-21):
    ///
    ///     -[NSKeyedUnarchiver decodeInt64ForKey:]: value for key (Mode) is not
    ///     an integer number        // decodeInteger / decodeInt32 / decodeInt64
    ///                              // all raise; only decodeObject survives
    ///
    /// while every scalar in the device's own blobs is inline (`Mode` encoded as
    /// a reference in **0 of 34918** rows).  A row whose `Mode` cannot be read
    /// has no file type, and that is exactly the daemon's answer:
    /// `MBErrorDomain/205 — "Invalid file type: 00"` — `00` being `%02x` of
    /// `(mode & S_IFMT) >> 12` for a mode it read as zero.
    ///
    /// The key *set* never caught this (`mbFileBlobKeys` matched the device
    /// exactly).  The *encoding* did, which is what `mbFileBlobShape` reports.
    var mode: Int = 0

    var size: Int = 0
    var userID: Int = 501
    var groupID: Int = 501
    var protectionClass: Int = 0
    var birth: Int = 0
    var lastModified: Int = 0
    var lastStatusChange: Int = 0
    var flags: Int = 0
    var inodeNumber: Int = 0
    /// The SHA-1 of the payload — on the row classes the device stamps one on.
    ///
    /// Its presence is **per domain class and absolute**, measured over the
    /// device's own backup, and it splits the 110 domains that have file rows
    /// cleanly in two — no domain mixes the two shapes
    /// (`scripts/blob-shape-check.swift` §4 re-checks exactly that):
    ///
    ///   * **carries one** (11 domains): `HomeDomain`, `SystemPreferencesDomain`,
    ///     `ManagedPreferencesDomain`, `DatabaseDomain`, `RootDomain`,
    ///     `MobileDeviceDomain`, `WirelessDomain`, `NetworkDomain`,
    ///     `KeychainDomain`, `ProtectedDomain`, `InstallDomain`
    ///     (per-domain counts are solid too: HomeDomain 708/708,
    ///     SystemPreferencesDomain 9/9, ManagedPreferencesDomain 4/4,
    ///     DatabaseDomain 3/3, RootDomain 36/36);
    ///   * **never carries one** (99 domains): the whole `AppDomain*` family
    ///     (`AppDomain-`, `AppDomainGroup-`, `AppDomainPlugin-`),
    ///     `SysSharedContainerDomain-*`, `SysContainerDomain-*`, `CameraRollDomain`
    ///     (`AppDomain-*` 0/2760, `SysSharedContainerDomain-*` 0/10).
    ///
    /// Directory rows (0/4387 across those domains) and symlink rows never carry
    /// one whatever the domain, and where it is present it equals
    /// `sha1(payload)` byte for byte (verified on one row of each of `HomeDomain`,
    /// `SystemPreferencesDomain`, `ManagedPreferencesDomain`, `DatabaseDomain`).
    ///
    /// This is the one field the AppDomain-only injector could omit for free:
    /// `AppDomain-*` is exactly the class that has none.  A row built for the
    /// tweak domains without it is therefore a divergence the app-container path
    /// can never reveal, and the device answers a file record it cannot match to
    /// the payload it received with `MBErrorDomain/205 — "Manifest references
    /// files not in backup"`.  See `TweakRowProfile.carriesDigest`.
    var digest: Data?
    var extendedAttributes: Data?

    override init() { super.init() }

    required init?(coder: NSCoder) { super.init() }

    func encode(with coder: NSCoder) {
        coder.encode(birth, forKey: "Birth")
        coder.encode(lastModified, forKey: "LastModified")
        coder.encode(lastStatusChange, forKey: "LastStatusChange")
        coder.encode(flags, forKey: "Flags")
        coder.encode(groupID, forKey: "GroupID")
        coder.encode(userID, forKey: "UserID")
        coder.encode(mode, forKey: "Mode")
        coder.encode(protectionClass, forKey: "ProtectionClass")
        coder.encode(size, forKey: "Size")
        coder.encode(relativePath, forKey: "RelativePath")
        // Unconditional, directories included: the device never omits it.
        coder.encode(inodeNumber, forKey: "InodeNumber")
        // A `Data`, so — like `RelativePath` — a real object, i.e. referenced
        // rather than inlined.  The device writes it the same way.
        if let digest { coder.encode(digest, forKey: "Digest") }
        if let ea = extendedAttributes { coder.encode(ea, forKey: "ExtendedAttributes") }
    }
}

/// Build the archived `MBFile` blob for one manifest row.
///
/// `mode` is an `Int` because the archived field has to come out as an inline
/// integer — see `MBFileArchiver.mode`.  Callers compose it as
/// `Int(MODE_FILE_DEFAULT) | Int(S_IFREG)`.
///
/// `timestamp` seeds all three time fields.  The device never writes 0 for any
/// of them (`Birth` 0/34918, `LastModified` 0/34918, `LastStatusChange` 0/34918,
/// earliest 1321453406), so neither does this.
///
/// `digest` is nil for the row classes the device writes no digest on — see
/// `MBFileArchiver.digest` for the measured split.  Callers that write into a
/// domain which carries one must pass `payloadDigest(contents)`.
func buildMBFileBlob(relativePath: String, mode: Int, size: Int,
                     userID: Int = 501, groupID: Int = 501, protectionClass: Int = 0,
                     inodeNumber: Int = 0,
                     timestamp: Int = Int(Date().timeIntervalSince1970),
                     digest: Data? = nil,
                     extendedAttributes: Data? = nil) -> Data {
    let obj = MBFileArchiver()
    obj.relativePath = relativePath
    obj.mode = mode
    obj.size = size
    obj.userID = userID
    obj.groupID = groupID
    obj.protectionClass = protectionClass
    obj.birth = timestamp
    obj.lastModified = timestamp
    obj.lastStatusChange = timestamp
    obj.inodeNumber = inodeNumber
    obj.digest = digest
    obj.extendedAttributes = extendedAttributes
    NSKeyedArchiver.setClassName("MBFile", for: MBFileArchiver.self)
    // Force-try is safe here: the class name is registered on the line above and
    // the graph is a single flat object with no nested containers, so archiving
    // cannot fail for this input.
    return try! NSKeyedArchiver.archivedData(withRootObject: obj, requiringSecureCoding: false)
}

/// The `Digest` a file row declares: SHA-1 of the payload bytes.
///
/// Defined here, next to the blob it goes into, because it is part of the same
/// contract: on every device row that carries a `Digest` it equals
/// `sha1(<payload>)` exactly (checked on `HomeDomain` /
/// `SystemPreferencesDomain` / `ManagedPreferencesDomain` / `DatabaseDomain`
/// rows of the reference backup).  GoldenNugget writes the same value
/// (`hashlib.sha1(contents).digest()` in `_build_mbfile_blob` /
/// `_patch_donor_blob`), so this is the reference's behaviour too, not an
/// inference of ours.
func payloadDigest(_ contents: Data) -> Data {
    Data(Insecure.SHA1.hash(data: contents))
}

/// The `com.apple.dataprotection.policy.exception-applied-by` attribute.
///
/// The value is the entity that applied the exception, and the device's own
/// app-container rows name `com.apple.containermanagerd_system` — 3/3 sampled,
/// on rows in the same `AppDomain-*` family this app injects into.  This used to
/// say `com.apple.springboard`, which no sampled row carries; the caller's
/// comment claimed that is what "lets SpringBoard write into the container",
/// but the device's own records disagree, and they are the contract.
///
/// `publisher` is a parameter because the device does not use one value
/// everywhere: measured off the same backup, a `ManagedPreferencesDomain` row
/// says `com.apple.BackupAgent2` and a HomeDomain `.GlobalPreferences.plist`
/// says `com.apple.cfprefsd`.  The default is the app-container value, so every
/// pre-existing call site keeps the bytes it had.
func buildDataprotectionExtendedAttributes(
    publisher: String = "com.apple.containermanagerd_system"
) -> Data {
    let ea: [String: Any] = [
        "com.apple.dataprotection.policy.exception-applied-by":
            Data(publisher.utf8)
    ]
    return (try? PropertyListSerialization.data(fromPropertyList: ea, format: .binary, options: 0)) ?? Data()
}

/// The `MBFile` keys an archived `file` blob actually carries, sorted.
///
/// This exists because the device rejected a restore with
/// `MBErrorDomain/205 — "Invalid file type: 00"` (2026-09-20) after pulling 7 of
/// the 471 payloads it was offered, and `205` is a class of error rather than a
/// cause: the description is the only discriminator.  "File type" points at the
/// metadata the device decodes out of a Files row's `file` blob, so the thing to
/// compare is the key set — ours against the device's own, which every row we
/// did not write still carries.
///
/// `NSKeyedArchiver` puts the encoded object's properties as non-`$` keys inside
/// `$objects`, so collecting those across every entry recovers the key set.
func mbFileBlobKeys(_ data: Data) -> String {
    guard let obj = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
          let dict = obj as? [String: Any] else {
        return "<not a plist>"
    }
    guard let objects = dict["$objects"] as? [Any] else {
        return dict.keys.sorted().joined(separator: ",")
    }
    var keys: Set<String> = []
    for entry in objects {
        guard let entry = entry as? [String: Any] else { continue }
        for key in entry.keys where !key.hasPrefix("$") { keys.insert(key) }
    }
    return keys.sorted().joined(separator: ",")
}

/// The `MBFile` object dict inside an archived blob, i.e. the entry that holds
/// the row's metadata (as opposed to `$null`, the strings, the class dict…).
///
/// Found by scanning rather than by following `$top` → `root`: the root index is
/// a `CFKeyedArchiverUID`, which `PropertyListSerialization` hands back as a
/// private type with no public accessor.
private func mbFileBlobObject(_ data: Data) -> [String: Any]? {
    guard let obj = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
          let dict = obj as? [String: Any],
          let objects = dict["$objects"] as? [Any] else {
        return nil
    }
    for entry in objects {
        guard let entry = entry as? [String: Any],
              entry["Birth"] != nil || entry["Mode"] != nil else { continue }
        return entry
    }
    return nil
}

/// The `Mode` the device comes away with, or nil when it cannot read one.
///
/// A nil here is the failing shape: `NSCoder` writes an inline number as an
/// inline number, but it writes anything it had to box as a `$objects`
/// reference — and the device's `decodeInteger`-family reads raise
/// "value for key (Mode) is not an integer number" on a reference.  A restore
/// agent that cannot read the type of a row answers
/// `MBErrorDomain/205 — "Invalid file type: 00"`.
func mbFileBlobMode(_ data: Data) -> Int? {
    (mbFileBlobObject(data)?["Mode"] as? NSNumber)?.intValue
}

/// The `InodeNumber` a row's blob claims, or nil when it carries none.
///
/// Needed because the restore agent deduplicates by inode: GoldenNugget's
/// injector reads the largest inode in the manifest and counts up from it, "the
/// agent deduplicates by inode — a clone sharing the donor's inode gets restored
/// with the donor's content" (`src/restore/inject.py:254-266`).  Reading it back
/// out of the archive is the only way to compute that maximum, since the field
/// lives inside the blob and not in a column.
func mbFileBlobInode(_ data: Data) -> Int? {
    (mbFileBlobObject(data)?["InodeNumber"] as? NSNumber)?.intValue
}

/// How a blob's values are *encoded*, not just which keys they are under.
///
/// `mbFileBlobKeys` compares key sets, and that is not enough on its own — which
/// is how a broken `Mode` survived a whole diagnosis round: the keys matched the
/// device exactly while the value was an object reference instead of a number,
/// so every integer read on the device raised (2026-09-21) and the restore was
/// answered with `MBErrorDomain/205 — "Invalid file type: 00"`.
///
/// So this reports the two things that separate a good blob from that one: the
/// `Mode` a reader comes away with (`UNREADABLE` when it is a reference), and
/// which keys hold references at all.  `RelativePath` / `ExtendedAttributes` /
/// `Digest` are legitimately references — they are real objects; a *scalar*
/// field appearing in this list is the bug.
func mbFileBlobShape(_ data: Data) -> String {
    guard let entry = mbFileBlobObject(data) else { return "<no object dict>" }
    var references: [String] = []
    for key in entry.keys.sorted() where !key.hasPrefix("$") {
        if entry[key] is NSNumber { continue }
        references.append(key)
    }
    let mode = (entry["Mode"] as? NSNumber)?.intValue
    return "mode=\(mode.map(String.init) ?? "UNREADABLE") "
        + "reference-valued keys=[\(references.joined(separator: ","))]"
}
