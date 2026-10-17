// Regression harness for the status-bar binary layout.
//
// What it checks, none of which needs a device:
//
//   1  SIZES     the three buffers are what the device reads: a 3944-byte
//                `StatusBarOverrideData`, a 3880-byte `StatusBarRawData` nested
//                at offset 64, and 46 `_Bool` item slots.
//   2  OVERLAP   no two fields in either struct claim the same byte. This is the
//                check a compiler cannot do for a hand-written offset table: a
//                typo that moves `dateString` onto `GSMSignalStrengthRaw` types
//                cleanly and ships a status bar with a date where the signal
//                bars should be.
//   3  ROUNDTRIP each field, written at its documented offset, reads back from
//                the serialised buffer at the same offset with the same value —
//                including the strings' NUL termination and the multi-bit
//                `voiceControlIconType`.
//   4  SPAN      no field runs past the end of its buffer, and no two bitfields
//                land in the same byte-and-mask.
//   5  ARCHIVE   the iOS 27 `StatusBarOverrides.archive` round-trips through
//                `NSKeyedArchiver` → `NSKeyedUnarchiver`, the written class names
//                are the device's three, the carrier fields come back, and the
//                reset record is the "no entries" one.
//
// Run:
//   mkdir -p /tmp/sbcheck && cat Nugget/Core/TweakModel.swift \
//       Nugget/Core/TweakCatalog.swift Nugget/Core/TweakCatalogDaemons.swift \
//       Nugget/Core/TweakDomainMap.swift Nugget/Core/TweakCompiler.swift \
//       Nugget/Core/StatusBarModel.swift Nugget/Core/StatusBarArchive.swift \
//       Nugget/Core/StatusBarSelection.swift Nugget/Views/Extensions/Extensions.swift \
//       scripts/statusbar-check.swift > /tmp/sbcheck/main.swift \
//     && xcrun swiftc -O /tmp/sbcheck/main.swift -o /tmp/sbcheck/check \
//     && /tmp/sbcheck/check
//
// This file is NOT part of the app target; keep it out of Package.swift.

import Foundation

var failures: [String] = []

func check(_ condition: Bool, _ label: String) {
    if condition {
        print("  ok  \(label)")
    } else {
        print("  FAIL \(label)")
        failures.append(label)
    }
}

func section(_ name: String) {
    print("\n\(name)")
}

/// The field table, rebuilt from the same constants the writer uses.
///
/// A second, independent reading of the same numbers, so a wrong offset cannot be
/// "confirmed" by reading it back out of the writer that was given the wrong one.
/// Each entry is the extent the field claims *in bits*, because the reference packs
/// booleans into shared bytes: byte-granular comparison would call the five bits at
/// 2528 five overlapping fields.
struct Claim {
    let name: String
    let bits: Range<Int>

    /// A field that owns whole bytes: a `char[N]`, an `int`, a `double`, a `_Bool[N]`.
    init(_ name: String, bytes: Range<Int>) {
        self.name = name
        self.bits = (bytes.lowerBound * 8)..<(bytes.upperBound * 8)
    }

    /// A bitfield: one bit, or `width` bits for the two-bit `voiceControlIconType`.
    init(_ name: String, field: StatusBarLayout.BitField) {
        self.name = name
        let low = field.offset * 8 + field.bit
        self.bits = low..<(low + field.width)
    }
}

func spanClaims() -> [Claim] {
    let r = StatusBarLayout.Raw.self
    var claims: [Claim] = []
    claims.append(Claim("itemIsEnabled", bytes: r.itemIsEnabled.offset..<(r.itemIsEnabled.offset + r.itemIsEnabled.count)))
    claims.append(Claim("timeString", bytes: r.timeString.offset..<(r.timeString.offset + r.timeString.length)))
    claims.append(Claim("shortTimeString", bytes: r.shortTimeString.offset..<(r.shortTimeString.offset + r.shortTimeString.length)))
    claims.append(Claim("dateString", bytes: r.dateString.offset..<(r.dateString.offset + r.dateString.length)))
    claims.append(Claim("GSMSignalStrengthRaw", bytes: r.GSMSignalStrengthRaw.offset..<(r.GSMSignalStrengthRaw.offset + 4)))
    claims.append(Claim("secondaryGSMSignalStrengthRaw", bytes: r.secondaryGSMSignalStrengthRaw.offset..<(r.secondaryGSMSignalStrengthRaw.offset + 4)))
    claims.append(Claim("GSMSignalStrengthBars", bytes: r.GSMSignalStrengthBars.offset..<(r.GSMSignalStrengthBars.offset + 4)))
    claims.append(Claim("secondaryGSMSignalStrengthBars", bytes: r.secondaryGSMSignalStrengthBars.offset..<(r.secondaryGSMSignalStrengthBars.offset + 4)))
    claims.append(Claim("serviceString", bytes: r.serviceString.offset..<(r.serviceString.offset + r.serviceString.length)))
    claims.append(Claim("secondaryServiceString", bytes: r.secondaryServiceString.offset..<(r.secondaryServiceString.offset + r.secondaryServiceString.length)))
    claims.append(Claim("serviceCrossfadeString", bytes: r.serviceCrossfadeString.offset..<(r.serviceCrossfadeString.offset + r.serviceCrossfadeString.length)))
    claims.append(Claim("secondaryServiceCrossfadeString", bytes: r.secondaryServiceCrossfadeString.offset..<(r.secondaryServiceCrossfadeString.offset + r.secondaryServiceCrossfadeString.length)))
    claims.append(Claim("serviceImages", bytes: r.serviceImages.offset..<(r.serviceImages.offset + r.serviceImages.length)))
    claims.append(Claim("operatorDirectory", bytes: r.operatorDirectory.offset..<(r.operatorDirectory.offset + r.operatorDirectory.length)))
    claims.append(Claim("serviceContentType", bytes: r.serviceContentType.offset..<(r.serviceContentType.offset + 4)))
    claims.append(Claim("secondaryServiceContentType", bytes: r.secondaryServiceContentType.offset..<(r.secondaryServiceContentType.offset + 4)))
    claims.append(Claim("wifiSignalStrengthRaw", bytes: r.wifiSignalStrengthRaw.offset..<(r.wifiSignalStrengthRaw.offset + 4)))
    claims.append(Claim("wifiSignalStrengthBars", bytes: r.wifiSignalStrengthBars.offset..<(r.wifiSignalStrengthBars.offset + 4)))
    claims.append(Claim("dataNetworkType", bytes: r.dataNetworkType.offset..<(r.dataNetworkType.offset + 4)))
    claims.append(Claim("secondaryDataNetworkType", bytes: r.secondaryDataNetworkType.offset..<(r.secondaryDataNetworkType.offset + 4)))
    claims.append(Claim("batteryCapacity", bytes: r.batteryCapacity.offset..<(r.batteryCapacity.offset + 4)))
    claims.append(Claim("batteryState", bytes: r.batteryState.offset..<(r.batteryState.offset + 4)))
    claims.append(Claim("batteryDetailString", bytes: r.batteryDetailString.offset..<(r.batteryDetailString.offset + r.batteryDetailString.length)))
    claims.append(Claim("bluetoothBatteryCapacity", bytes: r.bluetoothBatteryCapacity.offset..<(r.bluetoothBatteryCapacity.offset + 4)))
    claims.append(Claim("thermalColor", bytes: r.thermalColor.offset..<(r.thermalColor.offset + 4)))
    claims.append(Claim("activityDisplayId", bytes: r.activityDisplayId.offset..<(r.activityDisplayId.offset + r.activityDisplayId.length)))
    claims.append(Claim("tetheringConnectionCount", bytes: r.tetheringConnectionCount.offset..<(r.tetheringConnectionCount.offset + 4)))
    claims.append(Claim("breadcrumbTitle", bytes: r.breadcrumbTitle.offset..<(r.breadcrumbTitle.offset + r.breadcrumbTitle.length)))
    claims.append(Claim("breadcrumbSecondaryTitle", bytes: r.breadcrumbSecondaryTitle.offset..<(r.breadcrumbSecondaryTitle.offset + r.breadcrumbSecondaryTitle.length)))
    claims.append(Claim("personName", bytes: r.personName.offset..<(r.personName.offset + r.personName.length)))
    claims.append(Claim("backgroundActivityDisplayStartDate", bytes: r.backgroundActivityDisplayStartDate.offset..<(r.backgroundActivityDisplayStartDate.offset + 8)))
    claims.append(Claim("primaryServiceBadgeString", bytes: r.primaryServiceBadgeString.offset..<(r.primaryServiceBadgeString.offset + r.primaryServiceBadgeString.length)))
    claims.append(Claim("secondaryServiceBadgeString", bytes: r.secondaryServiceBadgeString.offset..<(r.secondaryServiceBadgeString.offset + r.secondaryServiceBadgeString.length)))
    claims.append(Claim("quietModeImage", bytes: r.quietModeImage.offset..<(r.quietModeImage.offset + r.quietModeImage.length)))
    claims.append(Claim("quietModeName", bytes: r.quietModeName.offset..<(r.quietModeName.offset + r.quietModeName.length)))

    // Bitfields claim a single bit each, except the two-bit voiceControlIconType.
    claims.append(Claim("cellLowDataModeActive", field: r.cellLowDataModeActive))
    claims.append(Claim("secondaryCellLowDataModeActive", field: r.secondaryCellLowDataModeActive))
    claims.append(Claim("wifiLowDataModeActive", field: r.wifiLowDataModeActive))
    claims.append(Claim("thermalSunlightMode", field: r.thermalSunlightMode))
    claims.append(Claim("slowActivity", field: r.slowActivity))
    claims.append(Claim("syncActivity", field: r.syncActivity))
    claims.append(Claim("bluetoothConnected", field: r.bluetoothConnected))
    claims.append(Claim("displayRawGSMSignal", field: r.displayRawGSMSignal))
    claims.append(Claim("displayRawWifiSignal", field: r.displayRawWifiSignal))
    claims.append(Claim("locationIconType", field: r.locationIconType))
    claims.append(Claim("voiceControlIconType", field: r.voiceControlIconType))
    claims.append(Claim("quietModeInactive", field: r.quietModeInactive))
    claims.append(Claim("batterySaverModeActive", field: r.batterySaverModeActive))
    claims.append(Claim("deviceIsRTL", field: r.deviceIsRTL))
    claims.append(Claim("lock", field: r.lock))
    claims.append(Claim("electronicTollCollectionAvailable", field: r.electronicTollCollectionAvailable))
    claims.append(Claim("radarAvailable", field: r.radarAvailable))
    claims.append(Claim("wifiLinkWarning", field: r.wifiLinkWarning))
    claims.append(Claim("wifiSearching", field: r.wifiSearching))
    claims.append(Claim("shouldShowEmergencyOnlyStatus", field: r.shouldShowEmergencyOnlyStatus))
    claims.append(Claim("secondaryCellularConfigured", field: r.secondaryCellularConfigured))
    claims.append(Claim("extra1", field: r.extra1))
    return claims
}

// MARK: - 1. sizes

section("1. buffer sizes")
check(StatusBarLayout.overrideSize == 3944, "override struct is 3944 bytes")
check(StatusBarLayout.rawSize == 3880, "raw struct is 3880 bytes")
check(StatusBarLayout.rawOffset == 64, "raw struct starts at 64")
check(StatusBarLayout.overrideSize == StatusBarLayout.rawOffset + StatusBarLayout.rawSize,
      "64 + 3880 == 3944 exactly")
check(StatusBarLayout.itemCount == 46, "46 item slots")
// 46 slots, 28 of them named: the private SBStatusBarItem enum skips 8, 11, 14,
// 15, 19, 20, 30, 32-39, 42, 43 and 45.
check(StatusBarItem.allCases.count == 28, "28 named items (\(StatusBarItem.allCases.count), 18 gaps)")
check(StatusBarItem.allCases.allSatisfy { $0.index < StatusBarLayout.itemCount },
      "every item index fits in the 46-slot arrays")

// MARK: - 2. no overlap

section("2. no two raw fields share a byte")
let claims = spanClaims()
var collisions: [String] = []
for i in 0..<claims.count {
    for j in (i + 1)..<claims.count where claims[i].bits.overlaps(claims[j].bits) {
        collisions.append("\(claims[i].name)/\(claims[j].name) at bit \(claims[i].bits.lowerBound)")
    }
}
if collisions.isEmpty {
    print("  ok  \(claims.count) fields, \(claims.map { $0.bits.count }.reduce(0, +)) bits claimed, disjoint")
} else {
    for c in collisions.prefix(12) { print("  FAIL overlap: \(c)") }
    failures.append("raw field overlap (\(collisions.count))")
}

// MARK: - 4. spans stay inside

section("3. every raw field ends inside the buffer")
let overruns = claims.filter { $0.bits.upperBound > StatusBarLayout.rawSize * 8 }
if overruns.isEmpty {
    print("  ok  nothing past \(StatusBarLayout.rawSize)")
} else {
    for o in overruns { print("  FAIL \(o.name) ends at bit \(o.bits.upperBound)") }
    failures.append("raw field past end")
}

// MARK: - 3. round trip through the real writer

section("4. fields round-trip through serialiseClassic()")

/// The nested raw buffer as it appears inside a serialised override struct.
private func rawSlice(_ data: Data) -> [UInt8] {
    Array(data.dropFirst(StatusBarLayout.rawOffset).prefix(StatusBarLayout.rawSize))
}

private func readString(_ bytes: [UInt8], _ field: StatusBarLayout.StringField) -> String {
    let end = field.offset + field.length
    let slice = Array(bytes[field.offset..<end])
    let trimmed = slice.prefix { $0 != 0 }
    return String(decoding: trimmed, as: UTF8.self)
}

private func readInt(_ bytes: [UInt8], _ field: StatusBarLayout.IntField) -> Int32 {
    var value: UInt32 = 0
    for index in 0..<4 {
        value |= UInt32(bytes[field.offset + index]) << (8 * UInt32(index))
    }
    return field.isUnsigned ? Int32(bitPattern: value) : Int32(bitPattern: value)
}

var overrides = StatusBarOverrides()
overrides.carrierName = .init(set: true, value: 0, text: "MegaFon")
overrides.serviceBadge = .init(set: true, value: 0, text: "5")
overrides.signalBars = .init(set: true, value: 3, text: "")
overrides.dataNetworkType = .init(set: true, value: 10, text: "")
overrides.timeText = .init(set: true, value: 0, text: "noon")
overrides.dateText = .init(set: true, value: 0, text: "Tuesday")
overrides.breadcrumb = .init(set: true, value: 0, text: "Back to Maps")
overrides.batteryDetail = .init(set: true, value: 0, text: "78%")
overrides.batteryCapacity = .init(set: true, value: 42, text: "")
overrides.wifiBars = .init(set: true, value: 2, text: "")
overrides.secondaryCarrierName = .init(set: true, value: 0, text: "Beeline")
overrides.secondarySignalBars = .init(set: true, value: 1, text: "")
overrides.secondaryDataNetworkType = .init(set: true, value: 5, text: "")
overrides.secondaryServiceBadge = .init(set: true, value: 0, text: "2")
overrides.rawSignalShown = true
overrides.itemShown[.bluetooth] = true
overrides.itemShown[.mainBattery] = false

let payload = overrides.serialiseClassic()
check(payload.count == StatusBarLayout.overrideSize,
      "serialised payload is \(StatusBarLayout.overrideSize) bytes")

let raw = rawSlice(payload)
check(readString(raw, StatusBarLayout.Raw.serviceString) == "MegaFon",
      "serviceString at 448")
check(readString(raw, StatusBarLayout.Raw.serviceCrossfadeString) == "MegaFon",
      "serviceCrossfadeString at 648 gets the same bytes")
check(readString(raw, StatusBarLayout.Raw.secondaryServiceString) == "Beeline",
      "secondaryServiceString at 548")
check(readString(raw, StatusBarLayout.Raw.primaryServiceBadgeString) == "5",
      "primaryServiceBadgeString at 3161")
check(readString(raw, StatusBarLayout.Raw.timeString) == "noon", "timeString at 46")
check(readString(raw, StatusBarLayout.Raw.dateString) == "Tuesday", "dateString at 174")
check(readString(raw, StatusBarLayout.Raw.batteryDetailString) == "78%",
      "batteryDetailString at 2112")
check(Int(readInt(raw, StatusBarLayout.Raw.GSMSignalStrengthBars)) == 3,
      "GSMSignalStrengthBars at 440 == 3")
check(Int(readInt(raw, StatusBarLayout.Raw.dataNetworkType)) == 10,
      "dataNetworkType at 2096 == 10")
check(Int(readInt(raw, StatusBarLayout.Raw.batteryCapacity)) == 42,
      "batteryCapacity at 2104 == 42")
check(Int(readInt(raw, StatusBarLayout.Raw.wifiSignalStrengthBars)) == 2,
      "wifiSignalStrengthBars at 2088 == 2")
check(Int(readInt(raw, StatusBarLayout.Raw.secondaryGSMSignalStrengthBars)) == 1,
      "secondaryGSMSignalStrengthBars at 444 == 1")
check(Int(readInt(raw, StatusBarLayout.Raw.secondaryDataNetworkType)) == 5,
      "secondaryDataNetworkType at 2100 == 5")
check(readString(raw, StatusBarLayout.Raw.secondaryServiceBadgeString) == "2",
      "secondaryServiceBadgeString at 3261")

// The breadcrumb carries the disclosure glyph the reference appends.
let crumb = readString(raw, StatusBarLayout.Raw.breadcrumbTitle)
check(crumb == "Back to Maps \u{25B6}",
      "breadcrumbTitle at 2537 keeps the ▶ suffix (\(crumb.debugDescription))")

// The raw bits. `BitField.bit` counts from the *field's* start, so it can exceed
// 7 — displayRawGSMSignal is bit 9 of the word at 2528, which lands in byte 2529.
func rawBit(_ bytes: [UInt8], _ field: StatusBarLayout.BitField) -> Bool {
    let absolute = field.offset * 8 + field.bit
    return bytes[absolute / 8] & (1 << UInt8(absolute % 8)) != 0
}
check(rawBit(raw, StatusBarLayout.Raw.displayRawGSMSignal),
      "displayRawGSMSignal (bit 9 of the word at 2528) is set")
check(raw[StatusBarLayout.Raw.itemIsEnabled.offset + StatusBarItem.bluetooth.index] == 1,
      "itemIsEnabled[16] (bluetooth) is 1")
check(raw[StatusBarLayout.Raw.itemIsEnabled.offset + StatusBarItem.mainBattery.index] == 0,
      "itemIsEnabled[12] (battery) is 0, because it is only *overridden to hidden*")

// The override flags. `_OVERRIDE_BITFIELDS` rows are (name, byte, bit) where the
// bit counts from the start of the whole bitfield block at `byte`, not from that
// byte — hence `overrideServiceString` at (44, 22) landing in byte 46 bit 6, the
// same `divmod(off * 8 + bit, 8)` the reference serialiser does.
let bytes = [UInt8](payload)
func flag(_ field: StatusBarLayout.BitField) -> Bool {
    rawBit(bytes, field)
}
check(flag(StatusBarLayout.Override.overrideServiceString),
      "overrideServiceString set (44, bit 22)")
check(flag(StatusBarLayout.Override.overrideSecondaryServiceString),
      "overrideSecondaryServiceString set (44, bit 23)")
check(flag(StatusBarLayout.Override.overrideDataNetworkType),
      "overrideDataNetworkType set (44, bit 31)")
check(flag(StatusBarLayout.Override.overrideSecondaryDataNetworkType),
      "overrideSecondaryDataNetworkType set (48, bit 0)")
check(flag(StatusBarLayout.Override.overrideBreadcrumb),
      "overrideBreadcrumb set (48, bit 10)")
check(flag(StatusBarLayout.Override.overrideDisplayRawGSMSignal),
      "overrideDisplayRawGSMSignal set (56, bit 0)")
check(flag(StatusBarLayout.Override.overridePrimaryServiceBadgeString),
      "overridePrimaryServiceBadgeString set (56, bit 5)")
check(!flag(StatusBarLayout.Override.overrideServiceImages),
      "an untouched flag stays 0")
check(!flag(StatusBarLayout.Override.overrideOperatorDirectory),
      "overrideOperatorDirectory stays 0")

// The top-level item flags live in the *override* buffer, not the nested one.
check(bytes[StatusBarItem.bluetooth.index] == 1, "overrideItemIsEnabled[16] is 1")
check(bytes[StatusBarItem.mainBattery.index] == 1,
      "overrideItemIsEnabled[12] is 1 even though the value is hidden")
check(bytes[StatusBarItem.vpn.index] == 0, "an untouched item flag is 0")

// MARK: truncation

section("5. strings fill their char[N] and NUL-pad the rest")
var long = StatusBarOverrides()
long.carrierName = .init(set: true, value: 0, text: String(repeating: "A", count: 400))
long.dateText = .init(set: true, value: 0, text: String(repeating: "B", count: 400))
let longRaw = rawSlice(long.serialiseClassic())
let longCarrier = readString(longRaw, StatusBarLayout.Raw.serviceString)
// The reference slices `value[:100]` and hands the bytes to a `char[100]`, so a
// full-length carrier fills all 100 bytes with no terminator; the port does the
// same, because a terminator would silently shorten the string the user typed.
check(longCarrier.count == StatusBarLayout.Raw.serviceString.length,
      "carrier fills all \(StatusBarLayout.Raw.serviceString.length) bytes (\(longCarrier.count))")
let longDate = readString(longRaw, StatusBarLayout.Raw.dateString)
check(longDate.count == StatusBarLayout.Raw.dateString.length,
      "date fills all \(StatusBarLayout.Raw.dateString.length) bytes (\(longDate.count))")
// A short value is NUL-padded, so the next field still starts at its own offset.
var short = StatusBarOverrides()
short.carrierName = .init(set: true, value: 0, text: "Meg")
let shortRaw = rawSlice(short.serialiseClassic())
check(shortRaw[StatusBarLayout.Raw.serviceString.offset + 3] == 0
      && shortRaw[StatusBarLayout.Raw.serviceString.offset + 99] == 0,
      "a short carrier is NUL-padded across the whole field")
// The next field must be untouched by the overflow.
check(readString(longRaw, StatusBarLayout.Raw.batteryDetailString) == "",
      "the field after an overflowing string is untouched")

// MARK: silly mode

section("6. silly mode turns every item on")
var silly = StatusBarOverrides()
silly.itemShown[.bluetooth] = false
silly.sillyMode = true
let sillyBytes = [UInt8](silly.serialiseClassic())
var allOn = true
for index in 0..<StatusBarLayout.itemCount {
    if sillyBytes[index] == 0 { allOn = false }
}
check(allOn, "all 46 overrideItemIsEnabled bytes are 1 under silly mode")

// MARK: - 5. archive

section("7. iOS 27 archive round-trip")
do {
    var archiveOverrides = StatusBarOverrides()
    archiveOverrides.carrierName = .init(set: true, value: 0, text: "Tele2")
    archiveOverrides.serviceBadge = .init(set: true, value: 0, text: " 5 ")
    archiveOverrides.signalBars = .init(set: true, value: 9, text: "")
    archiveOverrides.timeText = .init(set: true, value: 0, text: "IGNORED")
    let archive = try StatusBarArchive.build(archiveOverrides)

    check(archive.count > 0, "archive is non-empty (\(archive.count) B)")
    check(!StatusBarArchive.isReset(archive), "not the reset record")

    // The three class names must be the device's, read out of the plist.
    let plist = try PropertyListSerialization.propertyList(from: archive, format: nil)
    let root = plist as? [String: Any]
    check(root?["$archiver"] as? String == "NSKeyedArchiver", "$archiver is NSKeyedArchiver")
    // The graph walk itself has to work everywhere, or the writer could be
    // emitting a payload whose UIDs do not resolve.
    let names = StatusBarArchive.archivedClassNames(of: archive)
    check(names.count == 3 && !names.contains(nil),
          "\(names.count) class names readable from the plist")
    if StatusBarArchive.honoursArchivedClassNames {
        check(names[0] == StatusBarArchive.recordClassName,
              "root class is \(StatusBarArchive.recordClassName) (got \(names[0] ?? "nil"))")
        check(names[1] == StatusBarArchive.dataClassName,
              "statusBarData class is \(StatusBarArchive.dataClassName) (got \(names[1] ?? "nil"))")
        check(names[2] == StatusBarArchive.cellularClassName,
              "cellularEntry class is \(StatusBarArchive.cellularClassName) (got \(names[2] ?? "nil"))")
    } else {
        // swift-corelibs-foundation's archiver writes the Swift type name whatever
        // setClassName is told, so this platform cannot express the assertion.
        // The names are still checked by StatusBarArchive.build's own probe, and
        // for real on Darwin.
        print("  skip  class names — this Foundation ignores setClassName(_:for:)")
    }

    let round = try StatusBarArchive.carrierOverrides(of: archive)
    check(round.primary.name == "Tele2", "carrier name survives: \(round.primary.name ?? "nil")")
    check(round.primary.badge == "5", "badge is trimmed to \"5\", got \(round.primary.badge ?? "nil")")
    check(round.primary.bars == 5, "bars clamped 9 → 5, got \(String(describing: round.primary.bars))")
    check(round.secondary.name == nil, "no secondary entry")

    let dropped = StatusBarArchive.droppedFields(archiveOverrides)
    check(dropped.contains("time"), "the unsupported time override is reported as dropped")

    // Long carrier truncation.
    var longName = StatusBarOverrides()
    longName.carrierName = .init(set: true, value: 0, text: String(repeating: "X", count: 200))
    let longArchive = try StatusBarArchive.build(longName)
    let longNames = try StatusBarArchive.carrierNames(of: longArchive)
    check(longNames.primary?.count == StatusBarArchive.maxCarrierLength,
          "carrier cut to \(StatusBarArchive.maxCarrierLength) (got \(longNames.primary?.count ?? 0))")

    // Reset record.
    let reset = try StatusBarArchive.build(StatusBarOverrides())
    check(StatusBarArchive.isReset(reset), "an empty selection yields the reset record")
    check(try StatusBarArchive.carrierNames(of: reset).primary == nil,
          "the reset record carries no carrier name")
} catch {
    print("  FAIL archive threw: \(error)")
    failures.append("archive round-trip")
}

// MARK: - mechanism fork

section("8. version fork")
check(StatusBarMechanism.mechanism(for: "26.6.2") == .classic, "26.6.2 → classic")
check(StatusBarMechanism.mechanism(for: "26.99") == .classic, "26.99 → classic")
check(StatusBarMechanism.mechanism(for: "27.0") == .archive, "27.0 → archive")
check(StatusBarMechanism.mechanism(for: "27.1") == .archive, "27.1 → archive")
check(StatusBarMechanism.mechanism(for: "28.0") == .archive, "28.0 → archive")
check(StatusBarMechanism.mechanism(for: "") == .classic, "an unread version refuses to guess forward")
check(StatusBarMechanism.classic.restorePath == "/Library/SpringBoard/statusBarOverrides",
      "classic path")
check(StatusBarMechanism.archive.restorePath == "/Library/SpringBoard/StatusBarOverrides.archive",
      "archive path")

// MARK: - persistence

section("9. selection round-trips through the stored shape")
do {
    // The stored shape has to survive a Codable round-trip, or a saved selection
    // comes back empty after a relaunch with no error to show for it.
    var original = StatusBarSelection()
    original.enabled = true
    original.sillyMode = true
    original.overrides.carrierName = .init(set: true, value: 0, text: "Tele2")
    original.overrides.signalBars = .init(set: true, value: 2, text: "")
    original.overrides.batteryCapacity = .init(set: true, value: 42, text: "")
    original.overrides.rawSignalShown = true
    original.overrides.rawWifiSignalShown = true
    original.overrides.itemShown[.vpn] = false
    original.overrides.itemShown[.bluetooth] = true

    let stored = original.stored
    // The keys are the reference's own method names, so a desktop preset maps
    // across without a translation table.
    check(stored.enabled, "the master switch is stored")
    check(stored.rawWifiSignalShown, "the wi-fi raw toggle is stored")
    check(stored.fields["carrier"]?.text == "Tele2", "carrier stored under \"carrier\"")
    check(stored.fields["batteryCapacity"]?.value == 42,
          "batteryCapacity stored under \"batteryCapacity\"")
    check(stored.fields["wifiSignalStrengthBars"] == nil,
          "an untouched wifiBars is not stored at all")
    check(stored.items[StatusBarItem.vpn.index] == false, "vpn toggle stored by index")
    check(stored.items[StatusBarItem.bluetooth.index] == true, "bluetooth toggle stored by index")

    let json = try JSONEncoder().encode(stored)
    let decoded = try JSONDecoder().decode(StatusBarStoredSelection.self, from: json)
    check(decoded == stored, "the stored shape survives JSON")

    var restored = StatusBarSelection()
    restored.restore(from: decoded)
    check(restored.overrides == original.overrides,
          "restore() gives back the same overrides")
    check(restored.enabled, "the master switch is restored")
    check(restored.sillyMode, "silly mode is restored")
    check(restored.overrides.rawWifiSignalShown, "the wi-fi raw toggle is restored")
    check(restored.overrides.itemShown[.vpn] == false, "a hidden item comes back hidden")

    // Untouched fields must not appear at all: a preset full of defaults would
    // read back as "the user touched all sixteen".
    let bare = StatusBarSelection()
    check(bare.stored.fields.isEmpty, "an empty selection stores no fields")
    check(bare.stored.items.isEmpty, "an empty selection stores no items")
    check(!bare.isActive, "a fresh selection is off, so the apply writes nothing")
    check(StatusBarOverrides().isEmpty,
          "a default signalBars=4 / batteryCapacity=100 is not two live overrides")

    // An unknown key is ignored rather than fatal, so a preset written by a newer
    // desktop build still loads.
    var future = decoded
    future.fields["aFieldFromTheFuture"] = .init(set: true, value: 1, text: "")
    var tolerant = StatusBarSelection()
    tolerant.restore(from: future)
    check(tolerant.overrides.carrierName.text == "Tele2",
          "an unknown key is skipped, the known ones still land")

    // The three states the master switch has to keep apart: off writes nothing,
    // on-with-nothing writes a *zeroed* struct (the only way to clear overrides
    // already on the device), and the reset record is the archive's equivalent.
    let off = StatusBarSelection()
    check(!off.isActive, "off: nothing staged")
    var reset = StatusBarSelection()
    reset.enabled = true
    check(reset.isActive, "on with nothing set: still a delivery")
    let resetData = reset.overrides.serialiseClassic()
    check(resetData.count == StatusBarLayout.overrideSize,
          "a reset is a full-size struct (\(resetData.count) B)")
    check(resetData.allSatisfy { $0 == 0 }, "and every byte of it is zero")
    check(StatusBarArchive.isReset(try StatusBarArchive.build(reset.overrides)),
          "on the archive, the same state is the reset record")
} catch {
    print("  FAIL selection threw: \(error)")
    failures.append("selection round-trip")
}

// MARK: result

print("")
if failures.isEmpty {
    print("statusbar check passed")
} else {
    print("statusbar check FAILED (\(failures.count)):")
    for f in failures { print("  - \(f)") }
    exit(1)
}