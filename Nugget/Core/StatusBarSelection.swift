import Foundation

/// Which status-bar mechanism a given device reads.
///
/// The reference forks on the product version in `StatusBarTweak` itself:
/// `apply_classic_tweak` for iOS 26.x and `apply_ios27_tweak` for 27+, chosen by
/// the caller (`device_manager.py`). The two write **different files in the same
/// HomeDomain path family** and nothing else distinguishes them, so getting the
/// fork wrong writes a file the device never reads — and the failure is silent,
/// because the restore succeeds and the status bar simply does not change.
enum StatusBarMechanism: Equatable {
    /// iOS 26 and below: the classic binary `statusBarOverrides` struct, with the
    /// full surface (46 item toggles, time/date/battery/wifi).
    case classic
    /// iOS 27+: `StatusBarOverrides.archive`, carrier name + badge + bars only.
    case archive

    /// The version fork: `>= 27.0` takes the archive path.
    ///
    /// The same predicate as the reference's `StatusBarTweak` dispatch
    /// (`Version(device) >= Version("27.0")`, and `Version.parse(version) >=
    /// Version.parse("27.0")` in `status_bar_tweak.py`'s caller).
    static func mechanism(for deviceVersion: String) -> StatusBarMechanism {
        guard let compare = TweakVersion.compare(deviceVersion, "27.0") else { return .classic }
        return compare >= 0 ? .archive : .classic
    }

    /// Where the payload lands, as an injector-ready pair.
    var restorePath: String {
        switch self {
        case .classic: return "/Library/SpringBoard/statusBarOverrides"
        case .archive: return StatusBarArchive.relativePath
        }
    }

    var domain: String {
        switch self {
        case .classic: return "HomeDomain"
        case .archive: return StatusBarArchive.domain
        }
    }

    /// The payload for these overrides under this mechanism.
    ///
    /// On iOS 27+ the archive carries only the carrier name, badge and bar count,
    /// so anything else the user set is **not** delivered — the page hides those
    /// controls, and this returns a note for the log rather than silently
    /// pretending the whole struct went out.
    func payload(for overrides: StatusBarOverrides) throws -> (data: Data, dropped: [String]) {
        switch self {
        case .classic:
            return (overrides.serialiseClassic(), [])
        case .archive:
            let dropped = StatusBarArchive.droppedFields(overrides)
            return (try StatusBarArchive.build(overrides), dropped)
        }
    }
}

/// The status-bar page's live state, and the one place a payload is produced.
///
/// Owns the overrides and hands them to `StatusBarMechanism` for delivery; the
/// page never touches bytes itself.
struct StatusBarSelection {
    /// The page's master switch: "Enable Status Bar Modifications".
    ///
    /// Not a display preference — it decides whether the apply writes the file
    /// **at all**.  The reference's `Tweak.enabled` starts false, both
    /// `apply_classic_tweak` and `apply_ios27_tweak` return before staging
    /// anything while it is false, and editing any value sets it.  So the
    /// reference has three states, not two, and the middle one is this port's
    /// reason for keeping a separate flag instead of inferring "off" from
    /// `isEmpty`:
    ///
    ///   * off, and the page untouched — no file is written;
    ///   * on, and nothing overridden — a **zeroed** struct is written, which is
    ///     the only way to clear overrides already on the device;
    ///   * on, with overrides — the overrides.
    ///
    /// Defaulting to off rather than to "on but empty" is the same default the
    /// reference has, and it is the safer one: a page that has been opened and
    /// closed does not silently reset a status bar the user set on the desktop.
    var enabled = false

    var overrides = StatusBarOverrides()

    /// The reference's "silly mode": every status-bar item on regardless of what
    /// is set. It only affects the classic struct — the archive has no item
    /// toggles at all — so it is not offered on iOS 27+.
    var sillyMode: Bool {
        get { overrides.sillyMode }
        set { overrides.sillyMode = newValue }
    }

    /// Whether the apply has anything to do here.
    ///
    /// The switch, not the override count: an enabled-but-empty selection still
    /// writes the zeroed struct, which is a reset, and a reset is a delivery.
    var isActive: Bool { enabled }

    /// The payload, plus anything the chosen mechanism cannot carry.
    func payload(for mechanism: StatusBarMechanism) throws -> (data: Data, dropped: [String]) {
        try mechanism.payload(for: overrides)
    }

    /// Restore a stored selection.
    ///
    /// `silly_mode` is a *view* option rather than a device setting — the
    /// reference keeps it on the setter and it is not part of any preset — so it
    /// is not restored here either.
    mutating func restore(from stored: StatusBarStoredSelection) {
        enabled = stored.enabled
        overrides = StatusBarOverrides()
        overrides.sillyMode = stored.sillyMode
        for (referenceName, field) in stored.fields {
            overrides.set(field: field, for: referenceName)
        }
        for (index, shown) in stored.items {
            guard let item = StatusBarItem(index: index) else { continue }
            overrides.itemShown[item] = shown
        }
        overrides.rawSignalShown = stored.rawSignalShown
        overrides.rawWifiSignalShown = stored.rawWifiSignalShown
    }

    /// The stored shape: what a preset holds.
    ///
    /// Flat `[String: StatusBarOverrides.Field]` rather than a codable mirror of
    /// the struct, so the file format is a plain key/value map that survives the
    /// layout being refactored — the offsets move, the keys do not.
    var stored: StatusBarStoredSelection {
        var items: [Int: Bool] = [:]
        for (item, shown) in overrides.itemShown {
            items[item.index] = shown
        }
        return StatusBarStoredSelection(
            enabled: enabled,
            sillyMode: overrides.sillyMode,
            rawSignalShown: overrides.rawSignalShown,
            rawWifiSignalShown: overrides.rawWifiSignalShown,
            fields: overrides.storedFields(),
            items: items)
    }

    /// Read the page back at launch, so a selection survives a relaunch.
    ///
    /// The same reason the PosterBoard selection is hoisted out of its view: the
    /// status bar is edited on one page and delivered by the Apply on the home
    /// page, so as page state it would be destroyed by walking over to press it.
    mutating func loadFromDisk() {
        guard let stored = StatusBarPreferences.storedSelection() else { return }
        restore(from: stored)
    }

    /// Write the current selection out for next launch.
    ///
    /// Called by the page as fields are edited rather than on every keystroke:
    /// `applyTweaks` takes a snapshot of the in-memory copy, so the file only has
    /// to be right by the time the app is next opened.
    func saveToDisk() {
        StatusBarPreferences.save(stored)
    }
}

/// Where the status-bar selection lives between launches.
///
/// Upstream keeps the whole status-bar state on the tweak object and persists
/// only through `pref_manager`, so the file is a port decision. It is a plain
/// `Codable` of `stored` rather than the overrides struct, which keeps the
/// on-disk format keyed by the reference's own field names — the same shape a
/// desktop preset uses, so the two read each other's files.
enum StatusBarPreferences {
    private static let defaultsKey = "StatusBarSelection"

    /// The selection file, next to the other per-feature state in Documents.
    ///
    /// Plain `appendingPathComponent` rather than the `conformingTo:` overload the
    /// PosterBoard paths use: that one is a recent Foundation addition, and this
    /// file is read by the Linux regression harness, which compiles the selection
    /// without it.
    static var file: URL {
        URL.documents.appendingPathComponent("StatusBar")
            .appendingPathComponent("selection.json")
    }

    /// The stored selection, or nil when there is none or it cannot be read.
    ///
    /// A corrupt file reads as no selection rather than as an error: the page then
    /// shows an empty status bar the user can type into, instead of refusing to
    /// open at all.
    static func load() -> StatusBarStoredSelection? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(StatusBarStoredSelection.self, from: data)
    }

    /// The last saved selection, from whichever copy survived.
    ///
    /// `UserDefaults` is read first because it is the copy the app itself wrote
    /// most recently, and it survives the documents copy being deleted by a
    /// restore or by the user clearing the container.
    static func storedSelection() -> StatusBarStoredSelection? {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode(StatusBarStoredSelection.self, from: data) {
            return decoded
        }
        return load()
    }

    /// Both copies, with the documents file best-effort.
    ///
    /// `UserDefaults` is the one that matters: it always exists, and it is read
    /// first.  The file is the copy a user or a restore can delete out from under
    /// the app, so losing the write costs nothing — hence `try?` rather than an
    /// error the page would have to surface.  The directory is created here
    /// because `Documents/StatusBar/` is not shipped with the container, and
    /// `Data.write` does not create intermediate directories: without this the
    /// write fails silently every single time and only the defaults copy exists.
    static func save(_ stored: StatusBarStoredSelection) {
        guard let data = try? JSONEncoder().encode(stored) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}

/// The preset shape for status-bar overrides.
///
/// Keys are the reference's `StatusBarTweak` property names, so a preset written
/// by the desktop app maps across without a translation table.
struct StatusBarStoredSelection: Codable, Equatable {
    /// Absent in a file written before the master switch existed, which decodes
    /// as this default rather than failing: a saved selection has to survive the
    /// port adding a control to the page.
    var enabled = false
    var sillyMode = false
    var rawSignalShown = false
    var rawWifiSignalShown = false
    var fields: [String: StatusBarOverrides.Field] = [:]
    var items: [Int: Bool] = [:]
}

extension StatusBarOverrides {
    /// Every named field, keyed the way the reference names them.
    ///
    /// The reference's method names are the natural key and they are what
    /// `preset_manager._apply_status_bar` round-trips, so a preset moves between
    /// the two apps unchanged.
    enum FieldKey: String, CaseIterable {
        case carrierName, cellularServiceShown, serviceBadge, dataNetworkType, signalBars
        case secondaryCarrierName, secondaryServiceBadge, secondaryDataNetworkType
        case secondarySignalBars, secondaryCellularConfigured
        case timeText, dateText, breadcrumb, batteryDetail
        case batteryCapacity, wifiBars

        var referenceName: String {
            switch self {
            case .carrierName: return "carrier"
            case .cellularServiceShown: return "cellularService"
            case .serviceBadge: return "serviceBadge"
            case .dataNetworkType: return "dataNetworkType"
            case .signalBars: return "signalBars"
            case .secondaryCarrierName: return "secondaryCarrier"
            case .secondaryServiceBadge: return "secondaryServiceBadge"
            case .secondaryDataNetworkType: return "secondaryDataNetworkType"
            case .secondarySignalBars: return "secondarySignalBars"
            case .secondaryCellularConfigured: return "secondaryCellularService"
            case .timeText: return "time"
            case .dateText: return "date"
            case .breadcrumb: return "crumb"
            case .batteryDetail: return "batteryDetail"
            case .batteryCapacity: return "batteryCapacity"
            case .wifiBars: return "wifiSignalStrengthBars"
            }
        }
    }

    func field(for key: FieldKey) -> StatusBarOverrides.Field {
        switch key {
        case .carrierName: return carrierName
        case .cellularServiceShown: return cellularServiceShown
        case .serviceBadge: return serviceBadge
        case .dataNetworkType: return dataNetworkType
        case .signalBars: return signalBars
        case .secondaryCarrierName: return secondaryCarrierName
        case .secondaryServiceBadge: return secondaryServiceBadge
        case .secondaryDataNetworkType: return secondaryDataNetworkType
        case .secondarySignalBars: return secondarySignalBars
        case .secondaryCellularConfigured: return secondaryCellularConfigured
        case .timeText: return timeText
        case .dateText: return dateText
        case .breadcrumb: return breadcrumb
        case .batteryDetail: return batteryDetail
        case .batteryCapacity: return batteryCapacity
        case .wifiBars: return wifiBars
        }
    }

    mutating func set(_ field: StatusBarOverrides.Field, for key: FieldKey) {
        switch key {
        case .carrierName: carrierName = field
        case .cellularServiceShown: cellularServiceShown = field
        case .serviceBadge: serviceBadge = field
        case .dataNetworkType: dataNetworkType = field
        case .signalBars: signalBars = field
        case .secondaryCarrierName: secondaryCarrierName = field
        case .secondaryServiceBadge: secondaryServiceBadge = field
        case .secondaryDataNetworkType: secondaryDataNetworkType = field
        case .secondarySignalBars: secondarySignalBars = field
        case .secondaryCellularConfigured: secondaryCellularConfigured = field
        case .timeText: timeText = field
        case .dateText: dateText = field
        case .breadcrumb: breadcrumb = field
        case .batteryDetail: batteryDetail = field
        case .batteryCapacity: batteryCapacity = field
        case .wifiBars: wifiBars = field
        }
    }

    /// The fields as a dictionary, keyed by the reference's own names.
    ///
    /// Only fields that are actually set are stored: a preset full of default
    /// `Field`s would carry sixteen entries that mean nothing and would have to
    /// be re-read as "user touched this".
    func storedFields() -> [String: StatusBarOverrides.Field] {
        var out: [String: StatusBarOverrides.Field] = [:]
        for key in StatusBarOverrides.FieldKey.allCases {
            let field = field(for: key)
            guard field.set else { continue }
            out[key.referenceName] = field
        }
        return out
    }

    /// Restore by the reference's names, the inverse of `storedFields()`.
    mutating func set(field: StatusBarOverrides.Field, for referenceName: String) {
        guard let key = StatusBarOverrides.FieldKey.allCases
            .first(where: { $0.referenceName == referenceName }) else { return }
        set(field, for: key)
    }
}
