import Foundation

/// The iOS 27+ `StatusBarOverrides.archive` writer.
///
/// The port of `src/tweaks/status_bar/statusbar_archive.py`. From iOS 27
/// SpringBoard no longer reads the classic binary struct, and the
/// `SpeakeasyNewStatusBar` feature flag cannot be written by a restore at all,
/// so the overrides go in as an `NSKeyedArchiver` binary plist that SpringBoard
/// unarchives itself:
///
///     _SBSystemStatusStatusBarOverridesArchiveRecord
///       +-- statusBarData : STStatusBarData
///       |     +-- cellularEntry          : STStatusBarDataCellularEntry
///       |     +-- secondaryCellularEntry : STStatusBarDataCellularEntry
///       +-- suppressedBackgroundActivityIdentifiers : NSSet (empty)
///
/// It lives in **HomeDomain** — the same domain the classic path writes — so it
/// rides the ordinary backup restore and needs no exploit.
///
/// ## Why `NSKeyedArchiver` and not a hand-built `$objects`
///
/// The reference builds the `UID` graph by hand and hands it to `plistlib`, whose
/// `FMT_BINARY` writer knows the keyed-archiver UID encoding. `plistlib` is a
/// Python C extension with no Swift counterpart, and
/// `PropertyListSerialization` **cannot** write one either: it reads keyed UIDs
/// but writes them as plain integers, which is exactly the corruption the `$null`
/// sentinel exists to prevent — an unarchiver would take the index as the value.
///
/// So the graph is produced by the real archiver, through three private classes
/// whose *archived* names are the ones SpringBoard looks up (registered through
/// `NSKeyedArchiver.setClassName(_:for:)`), and `NSKeyedUnarchiver` reads it
/// back. The bytes are a genuine Apple keyed archive, and the round-trip check in
/// `scripts/statusbar-check.swift` proves the field names, the graph and the
/// class names all survive.
///
/// ## Scope, and why it is narrow
///
/// Only the carrier **name**, its **service badge** and its **signal-bar count**
/// survive. That is the entire surface the upstream reverse-engineering work
/// exposes as supported; everything else in the cellular entry is written with
/// fixed values that were verified to deserialize and render. Exposing more
/// without hardware verification would risk shipping a status bar that fails to
/// draw at all, so the time/date/battery/wifi overrides and the 46 per-item
/// toggles are **not** offered on iOS 27+. The page hides them, exactly as
/// `src/gui/ios/statusbar.py` does.
///
/// ## Failure mode is safe
///
/// When the record decodes empty, SpringBoard removes the file itself and the
/// stock carrier names come back. A rejected archive degrades to "no override"
/// rather than to a broken status bar.
/// One `STStatusBarDataCellularEntry`.
///
/// Declared at plain top-level scope rather than nested in `StatusBarArchive` on
/// purpose: a keyed archiver resolves `$classname` through `NSStringFromClass`,
/// which traps on a class that is nested *or* file-private — the latter adds a
/// synthetic "(unknown context at …)" component that Foundation rejects. The
/// *archived* name is registered explicitly in `StatusBarArchive.build`, so
/// nothing about the device-visible name comes from these Swift types.
///
/// `NSCoding` rather than `NSSecureCoding` on purpose: the device's own archive
/// carries no class-version set, and a secure-coding reader would reject it.
/// `requiresSecureCoding` is left false on both sides.
final class StatusBarArchiveCellularEntry: NSObject, NSCoding {
    var string: String?
    var crossfadeString: String?
    var badgeString: String?
    var displayValue: Int

    init(string: String?, badge: String?, displayValue: Int) {
        self.string = string
        // The reference points both at one shared string object
        // (`entry["crossfadeString"] = text`, the same `add()` result).
        self.crossfadeString = string
        self.badgeString = badge
        self.displayValue = displayValue
    }

    /// `decodeObject(forKey:)` **raises** when the key is absent rather than
    /// returning nil, which the archive's own shape requires: a reset record
    /// encodes no `cellularEntry` at all, and the entry defaults encode
    /// `badgeString` as null. So every optional field is gated on
    /// `containsValue(forKey:)` first, which is the only safe way to ask "absent"
    /// rather than "nil".
    convenience init(coder: NSCoder) {
        self.init(string: nil, badge: nil, displayValue: 4)
        if coder.containsValue(forKey: "string") {
            string = coder.decodeObject(forKey: "string") as? String
        }
        if coder.containsValue(forKey: "crossfadeString") {
            crossfadeString = coder.decodeObject(forKey: "crossfadeString") as? String
        }
        if coder.containsValue(forKey: "badgeString") {
            badgeString = coder.decodeObject(forKey: "badgeString") as? String
        }
        if coder.containsValue(forKey: "displayValue") {
            displayValue = coder.decodeInteger(forKey: "displayValue")
        }
    }

    /// The keys this entry sets itself; the rest come from `entryDefaults`.
    ///
    /// A key encoded twice makes `NSKeyedArchiver` warn and keep the *first*
    /// value, so the defaults loop has to skip these rather than write them again.
    private static let ownKeys: Set<String> = [
        "string", "crossfadeString", "badgeString", "displayValue",
    ]

    func encode(with coder: NSCoder) {
        // Every entry default first, so an unset field lands as the verified
        // constant rather than as a gap in the object.
        for (key, entry) in StatusBarArchive.entryDefaults where !Self.ownKeys.contains(key) {
            switch entry {
            case .null: coder.encode(nil, forKey: key)
            case .value(let wrapped): coder.encode(wrapped, forKey: key)
            }
        }
        if let string { coder.encode(string, forKey: "string") }
        if let string { coder.encode(string, forKey: "crossfadeString") }
        if let badgeString { coder.encode(badgeString, forKey: "badgeString") }
        coder.encode(displayValue, forKey: "displayValue")
    }
}

/// `STStatusBarData` — the two carrier entries, either of them optional.
final class StatusBarArchiveData: NSObject, NSCoding {
    var cellularEntry: StatusBarArchiveCellularEntry?
    var secondaryCellularEntry: StatusBarArchiveCellularEntry?

    init(cellularEntry: StatusBarArchiveCellularEntry?,
         secondaryCellularEntry: StatusBarArchiveCellularEntry?) {
        self.cellularEntry = cellularEntry
        self.secondaryCellularEntry = secondaryCellularEntry
    }

    /// Either entry may be absent, so both reads are gated on
    /// `containsValue(forKey:)` — see `StatusBarArchiveCellularEntry.init(coder:)`.
    convenience init(coder: NSCoder) {
        self.init(cellularEntry: nil, secondaryCellularEntry: nil)
        if coder.containsValue(forKey: "cellularEntry") {
            cellularEntry = coder.decodeObject(
                of: StatusBarArchiveCellularEntry.self,
                forKey: "cellularEntry")
        }
        if coder.containsValue(forKey: "secondaryCellularEntry") {
            secondaryCellularEntry = coder.decodeObject(
                of: StatusBarArchiveCellularEntry.self,
                forKey: "secondaryCellularEntry")
        }
    }

    func encode(with coder: NSCoder) {
        if let cellularEntry { coder.encode(cellularEntry, forKey: "cellularEntry") }
        if let secondaryCellularEntry {
            coder.encode(secondaryCellularEntry, forKey: "secondaryCellularEntry")
        }
    }
}

/// The root record.
final class StatusBarArchiveRecord: NSObject, NSCoding {
    let data: StatusBarArchiveData

    init(data: StatusBarArchiveData) { self.data = data }

    convenience init(coder: NSCoder) {
        // `data` has to be pulled in here rather than read off the unarchiver
        // afterwards: `statusBarData` is a key *inside* this object, and the
        // unarchiver's key space is the object it is currently decoding, not the
        // archive root. Asking the unarchiver for it finds nothing.
        self.init(data: coder.decodeObject(
            of: StatusBarArchiveData.self,
            forKey: "statusBarData")
            ?? StatusBarArchiveData(cellularEntry: nil, secondaryCellularEntry: nil))
    }

    func encode(with coder: NSCoder) {
        coder.encode(data, forKey: "statusBarData")
        // The reference's empty NSSet: present, so the record decodes as a
        // complete record rather than as a partial one.
        coder.encode(NSSet(), forKey: "suppressedBackgroundActivityIdentifiers")
    }
}

/// A throwaway object for `honoursArchivedClassNames`; encodes nothing, so the
/// only thing in its archive is the `$classname` the archiver chose.
final class StatusBarArchiveClassNameProbe: NSObject, NSCoding {
    convenience init(coder: NSCoder) { self.init() }
    func encode(with coder: NSCoder) {}
}

enum StatusBarArchive {
    /// HomeDomain path, relative to `/var/mobile`.
    static let relativePath = "/Library/SpringBoard/StatusBarOverrides.archive"
    static let domain = "HomeDomain"

    /// The record refuses to render anything longer.
    static let maxCarrierLength = 64
    /// The badge is a SIM slot glyph ("P", "1", "2"), not free text.
    static let maxBadgeLength = 8
    /// The classic tweak let the UI reach 5; iOS itself draws 0-4, so 5 clamps.
    static let maxBars = 5

    static let recordClassName = "_SBSystemStatusStatusBarOverridesArchiveRecord"
    static let dataClassName = "STStatusBarData"
    static let cellularClassName = "STStatusBarDataCellularEntry"

    /// One entry field, distinguishing "archiver null" from a real value.
    ///
    /// The reference's `_ENTRY_DEFAULTS` maps `None` to `plistlib.UID(0)`, the
    /// `$null` sentinel — a *present key holding null*, not an absent key. A
    /// missing key would leave the entry without the field at all, which is a
    /// different object.
    enum EntryValue {
        case null
        case value(Any)
    }

    /// Fixed cellular-entry values, verbatim from `_ENTRY_DEFAULTS`.
    ///
    /// `status` 5 is "connected" and `enabled` true is what makes the entry
    /// render at all; `displayValue` is the bar count (the user's value wins) and
    /// `type` 10 is 5G. `badgeString` and `suffixString` stay null unless the
    /// user sets a badge.
    static let entryDefaults: [String: EntryValue] = [
        "badgeString": .null,
        "callForwardingEnabled": .value(false),
        "displayRawValue": .value(0),
        "displayValue": .value(4),
        "enabled": .value(true),
        "isBootstrapCellular": .value(false),
        "lowDataModeActive": .value(false),
        "numberSharingState": .value(0),
        "rawValue": .value(0),
        "showsSOSWhenDisabled": .value(false),
        "sosAvailable": .value(false),
        "status": .value(5),
        "suffixString": .null,
        "type": .value(10),
        "wifiCallingEnabled": .value(false),
    ]

    // MARK: - Writing

    /// Build the archive payload.
    ///
    /// With no carrier names this returns the **reset** record: a structurally
    /// valid archive whose status-bar data carries no cellular entries, which
    /// SpringBoard decodes as "no overrides" and then unlinks.
    static func build(_ overrides: StatusBarOverrides) throws -> Data {
        let primary = truncate(overrides.carrierName.text, max: maxCarrierLength)
        let secondary = truncate(overrides.secondaryCarrierName.text, max: maxCarrierLength)

        var primaryEntry: StatusBarArchiveCellularEntry?
        if let primary {
            primaryEntry = StatusBarArchiveCellularEntry(
                string: primary,
                badge: truncateBadge(overrides.serviceBadge.text),
                displayValue: clampBars(overrides.signalBars.set
                                        ? overrides.signalBars.value : nil))
        }
        var secondaryEntry: StatusBarArchiveCellularEntry?
        if let secondary {
            secondaryEntry = StatusBarArchiveCellularEntry(
                string: secondary,
                badge: truncateBadge(overrides.secondaryServiceBadge.text),
                displayValue: clampBars(overrides.secondarySignalBars.set
                                        ? overrides.secondarySignalBars.value : nil))
        }

        let record = StatusBarArchiveRecord(
            data: StatusBarArchiveData(cellularEntry: primaryEntry,
                                       secondaryCellularEntry: secondaryEntry))
        let archiver = NSKeyedArchiver(requiringSecureCoding: false)
        // SpringBoard resolves these names itself, so they have to be what lands
        // in `$classname` — not this app's Swift type names. One registration
        // each: `setClassName(_:for:)` replaces the mapping, so naming the Swift
        // class first and the device name second would only ever keep the last.
        archiver.setClassName(recordClassName, for: StatusBarArchiveRecord.self)
        archiver.setClassName(dataClassName, for: StatusBarArchiveData.self)
        archiver.setClassName(cellularClassName, for: StatusBarArchiveCellularEntry.self)
        archiver.encode(record, forKey: NSKeyedArchiveRootObjectKey)
        archiver.finishEncoding()
        return archiver.encodedData
    }

    private static func truncate(_ text: String, max: Int) -> String? {
        guard !text.isEmpty else { return nil }
        let cut = String(text.prefix(max))
        return cut.isEmpty ? nil : cut
    }

    /// Trim a service badge to the glyph length iOS will draw.
    ///
    /// Whitespace is not a glyph, so " 5 " is the badge `5` — the reference's
    /// `_truncate_badge` does `.strip()` before the cut, and the two differ.
    private static func truncateBadge(_ text: String) -> String? {
        guard !text.isEmpty else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let cut = String(trimmed.prefix(maxBadgeLength))
        return cut.isEmpty ? nil : cut
    }

    /// Clamp a bar count into the drawable range, or the verified default.
    private static func clampBars(_ value: Int?) -> Int {
        guard let value else { return 4 }
        return max(0, min(maxBars, value))
    }

    // MARK: - Reading back

    /// The `$classname`s down the path `root → statusBarData → cellularEntry`,
    /// read straight out of the plist.
    ///
    /// The check that matters, and the reason a decoded object cannot stand in
    /// for it: a Swift unarchiver substitutes this app's own classes for the
    /// names it was given, so "it decoded" says nothing about what was written.
    /// These are the names SpringBoard will look up.
    /// Read one keyed-archiver UID out of a decoded plist.
    ///
    /// A plist UID is not a plain integer. `PropertyListSerialization` reads one as
    /// a `CFKeyedArchiverUID`, which bridges to `NSNumber` on Darwin. On Linux it
    /// comes back as swift-corelibs' own `_NSKeyedArchiverUID`, which bridges to
    /// neither `NSNumber` nor `Int` — it is an opaque class wrapping a single
    /// `value` field, reachable only by reflection. Darwin never takes that branch.
    private static func uid(_ value: Any?) -> Int? {
        guard let value else { return nil }
        // `dict[key]` hands back `Any?`, so the UID arrives wrapped in an extra
        // layer of Optional that has to come off before it is anything at all.
        var unwrapped = value
        while Mirror(reflecting: unwrapped).displayStyle == .optional,
              let some = Mirror(reflecting: unwrapped).children.first {
            unwrapped = some.value
        }
        if let number = unwrapped as? NSNumber { return number.intValue }
        if let int = unwrapped as? Int { return int }
        for child in Mirror(reflecting: unwrapped).children where child.label == "value" {
            if let number = child.value as? NSNumber { return number.intValue }
            if let int = child.value as? Int { return int }
            if let uint = child.value as? UInt32 { return Int(uint) }
        }
        return nil
    }

    static func archivedClassNames(of payload: Data) -> [String?] {
        func className(_ keyPath: [String]) -> String? {
            guard let plist = try? PropertyListSerialization.propertyList(from: payload, format: nil),
                  let archive = plist as? [String: Any],
                  archive["$archiver"] as? String == "NSKeyedArchiver",
                  let objects = archive["$objects"] as? [Any],
                  let top = archive["$top"] as? [String: Any],
                  let rootKey = uid(top[NSKeyedArchiveRootObjectKey]),
                  rootKey < objects.count
            else { return nil }
            var current = objects[rootKey]
            for key in keyPath {
                guard let dict = current as? [String: Any],
                      let next = uid(dict[key]),
                      next < objects.count else { return nil }
                current = objects[next]
            }
            guard let dict = current as? [String: Any],
                  let classKey = uid(dict["$class"]),
                  classKey < objects.count,
                  let classDef = objects[classKey] as? [String: Any]
            else { return nil }
            return classDef["$classname"] as? String
        }
        return [className([]),
                className(["statusBarData"]),
                className(["statusBarData", "cellularEntry"])]
    }

    /// Whether this platform's `NSKeyedArchiver` actually honours
    /// `setClassName(_:for:)`.
    ///
    /// Darwin does; swift-corelibs-foundation accepts the call and then writes the
    /// Swift type name regardless, so off-device the class names cannot be checked
    /// and the check would be asserting something the platform cannot express.
    /// Probed with a throwaway object so the gate reports "skipped" rather than a
    /// failure that means nothing, and so it starts failing the moment a platform
    /// regresses.
    static var honoursArchivedClassNames: Bool {
        let archiver = NSKeyedArchiver(requiringSecureCoding: false)
        archiver.setClassName("StatusBarArchiveProbe",
                           for: StatusBarArchiveClassNameProbe.self)
        archiver.encode(StatusBarArchiveClassNameProbe(),
                        forKey: NSKeyedArchiveRootObjectKey)
        archiver.finishEncoding()
        let payload = archiver.encodedData
        // `[String?].first` is a double optional, so it has to be flattened before
        // the comparison rather than unwrapped inline.
        return archivedClassNames(of: payload).first.flatMap { $0 } == "StatusBarArchiveProbe"
    }

    /// Follow `$top.root` → `statusBarData` the way SpringBoard's unarchiver
    /// does, checking the class names on the way.
    private static func decode(_ payload: Data) throws -> StatusBarArchiveData {
        // Only on a platform whose archiver can write the names at all — see
        // `honoursArchivedClassNames`. The device's own Foundation can.
        if honoursArchivedClassNames {
            let names = archivedClassNames(of: payload)
            guard names[0] == recordClassName, names[1] == dataClassName
            else {
                throw StatusBarArchiveError.notAnArchive
            }
        }
        guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: payload) else {
            throw StatusBarArchiveError.notAnArchive
        }
        unarchiver.requiresSecureCoding = false
        unarchiver.setClass(StatusBarArchiveRecord.self, forClassName: recordClassName)
        unarchiver.setClass(StatusBarArchiveData.self, forClassName: dataClassName)
        unarchiver.setClass(StatusBarArchiveCellularEntry.self,
                            forClassName: cellularClassName)
        defer { unarchiver.finishDecoding() }
        guard let record = unarchiver.decodeObject(
            of: StatusBarArchiveRecord.self,
            forKey: NSKeyedArchiveRootObjectKey)
        else {
            throw StatusBarArchiveError.notAnArchive
        }
        return record.data
    }

    /// The `(primary, secondary)` carrier names an archive holds.
    ///
    /// The round-trip half of `carrier_overrides` in the reference, used by
    /// `scripts/statusbar-check.swift` so the writer is proven to put the fields
    /// where an unarchiver will look for them rather than merely produce bytes.
    static func carrierNames(of payload: Data) throws -> (primary: String?, secondary: String?) {
        let data = try decode(payload)
        return (data.cellularEntry?.string, data.secondaryCellularEntry?.string)
    }

    /// The full override set an archive holds, for the round-trip check.
    ///
    /// `(name, badge, bars)` per carrier. Every value is read back out of the
    /// encoded plist.
    static func carrierOverrides(of payload: Data) throws
        -> (primary: (name: String?, badge: String?, bars: Int?),
            secondary: (name: String?, badge: String?, bars: Int?)) {
        let data = try decode(payload)
        func read(_ entry: StatusBarArchiveCellularEntry?)
            -> (name: String?, badge: String?, bars: Int?) {
            guard let entry else { return (nil, nil, nil) }
            // The archiver's `$null` decodes back to a nil object, so a badge
            // that was never set reads as nil rather than as the string "$null".
            return (entry.string, entry.badgeString, entry.displayValue)
        }
        return (read(data.cellularEntry), read(data.secondaryCellularEntry))
    }

    /// True when the payload carries no cellular entries — the reset record.
    static func isReset(_ payload: Data) -> Bool {
        guard let data = try? decode(payload) else { return false }
        return data.cellularEntry == nil && data.secondaryCellularEntry == nil
    }

    /// Which of the user's settings the archive cannot carry.
    ///
    /// Reported, not hidden: the reference's page simply does not offer the
    /// controls on iOS 27+ (`src/gui/ios/statusbar.py`), but a preset imported
    /// from a 26 device carries them, and applying one should say what was
    /// dropped rather than report success as though everything landed.
    static func droppedFields(_ overrides: StatusBarOverrides) -> [String] {
        var dropped: [String] = []
        if overrides.timeText.set { dropped.append("time") }
        if overrides.dateText.set { dropped.append("date") }
        if overrides.breadcrumb.set { dropped.append("breadcrumb") }
        if overrides.batteryDetail.set { dropped.append("battery detail") }
        if overrides.batteryCapacity.set { dropped.append("battery capacity") }
        if overrides.wifiBars.set { dropped.append("wifi bars") }
        if overrides.rawSignalShown { dropped.append("raw signal") }
        if overrides.dataNetworkType.set { dropped.append("data network type") }
        if overrides.secondaryDataNetworkType.set { dropped.append("secondary data network type") }
        if overrides.cellularServiceShown.set { dropped.append("cellular service") }
        if overrides.secondaryCellularConfigured.set { dropped.append("secondary cellular") }
        if !overrides.itemShown.isEmpty { dropped.append("item toggles") }
        return dropped
    }
}

enum StatusBarArchiveError: LocalizedError {
    case notAnArchive

    var errorDescription: String? {
        switch self {
        case .notAnArchive:
            return "That payload is not a usable status bar override archive."
        }
    }
}
