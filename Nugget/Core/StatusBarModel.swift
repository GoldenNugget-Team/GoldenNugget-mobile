import Foundation

/// The classic `StatusBarOverrideData` binary layout, as one flat buffer.
///
/// This is the port of `src/tweaks/status_bar/status_setter.py`: the reference
/// cannot serialise the struct on Windows through cffi (MSVC lays bitfields out
/// differently), so it hardcodes the clang/gcc layout as a table and writes the
/// bytes by hand.  The table is copied here field for field, with the same
/// meaning, and the same two buffers come out.
///
/// Layout, for the record:
///
///     StatusBarOverrideData                  3944 bytes
///       u8   overrideItemIsEnabled[46]
///       u32  overrideLock                    @52 (a plain u32, not a bitfield)
///       u8   bitfields                       @44, @48, @56  (see `bitfield`)
///       StatusBarRawData values              @64, 3880 bytes
///
///     StatusBarRawData                       3880 bytes
///       u8   itemIsEnabled[46]               @0
///       ...strings, ints, doubles, bits...   see `rawLayout`
///
/// Every field is addressed by an explicit byte offset or bit position, because
/// that *is* the device's ABI. There is no struct in Swift that lays itself out
/// this way, and one that claimed to would break silently on any compiler
/// change; the offsets are the contract and they are checked by
/// `scripts/statusbar-check.swift`.
enum StatusBarLayout {
    /// The whole override struct. The reference's `_serialize_override` allocates
    /// exactly this many bytes and SpringBoard reads exactly this many.
    static let overrideSize = 3944
    /// The nested raw struct, which starts at 64 inside the override struct.
    static let rawSize = 3880
    /// Where the nested raw struct begins.
    static let rawOffset = 64
    /// `overrideItemIsEnabled` is a `_Bool[46]`, one byte per element, at 0.
    static let itemCount = 46

    // MARK: - Field descriptors

    /// A `char[N]` inside the raw struct.
    struct StringField {
        let offset: Int
        let length: Int
    }

    /// An `int` / `unsigned int` at an offset.
    struct IntField {
        let offset: Int
        let isUnsigned: Bool
    }

    /// A `double` at an offset.
    struct DoubleField {
        let offset: Int
    }

    /// A `_Bool` bit packed into a byte: `offset * 8 + bit`.
    struct BitField {
        let offset: Int
        let bit: Int
        /// Widths above 1 — `voiceControlIconType` is two bits.
        let width: Int
    }

    /// A `_Bool[46]` array: one **byte** per element, at `offset + index`.
    ///
    /// Its own case because it is not a bitfield at all. The reference's table
    /// gives `itemIsEnabled` the pseudo-kind `bool46` for exactly this reason —
    /// packing 46 booleans into bits would be a different struct.
    struct BoolArray {
        let offset: Int
        let count: Int
        subscript(index: Int) -> Int { offset + index }
    }

    /// Everything `StatusBarRawData` holds, in the reference's `_RAW_LAYOUT` order.
    ///
    /// Only the fields this port can actually set are named; the rest exist in
    /// the layout because `values` is one contiguous 3880-byte struct whose
    /// *offsets after* a written field must not shift.
    enum Raw {
        static let itemIsEnabled = BoolArray(offset: 0, count: itemCount)

        static let timeString = StringField(offset: 46, length: 64)
        static let shortTimeString = StringField(offset: 110, length: 64)
        static let dateString = StringField(offset: 174, length: 256)
        static let GSMSignalStrengthRaw = IntField(offset: 432, isUnsigned: false)
        static let secondaryGSMSignalStrengthRaw = IntField(offset: 436, isUnsigned: false)
        static let GSMSignalStrengthBars = IntField(offset: 440, isUnsigned: false)
        static let secondaryGSMSignalStrengthBars = IntField(offset: 444, isUnsigned: false)
        static let serviceString = StringField(offset: 448, length: 100)
        static let secondaryServiceString = StringField(offset: 548, length: 100)
        static let serviceCrossfadeString = StringField(offset: 648, length: 100)
        static let secondaryServiceCrossfadeString = StringField(offset: 748, length: 100)
        static let serviceImages = StringField(offset: 848, length: 200)
        static let operatorDirectory = StringField(offset: 1048, length: 1024)
        static let serviceContentType = IntField(offset: 2072, isUnsigned: true)
        static let secondaryServiceContentType = IntField(offset: 2076, isUnsigned: true)
        static let cellLowDataModeActive = BitField(offset: 2080, bit: 0, width: 1)
        static let secondaryCellLowDataModeActive = BitField(offset: 2080, bit: 1, width: 1)
        static let wifiSignalStrengthRaw = IntField(offset: 2084, isUnsigned: false)
        static let wifiSignalStrengthBars = IntField(offset: 2088, isUnsigned: false)
        static let wifiLowDataModeActive = BitField(offset: 2092, bit: 0, width: 1)
        static let dataNetworkType = IntField(offset: 2096, isUnsigned: true)
        static let secondaryDataNetworkType = IntField(offset: 2100, isUnsigned: true)
        static let batteryCapacity = IntField(offset: 2104, isUnsigned: false)
        static let batteryState = IntField(offset: 2108, isUnsigned: true)
        static let batteryDetailString = StringField(offset: 2112, length: 150)
        static let bluetoothBatteryCapacity = IntField(offset: 2264, isUnsigned: false)
        static let thermalColor = IntField(offset: 2268, isUnsigned: false)
        static let thermalSunlightMode = BitField(offset: 2272, bit: 0, width: 1)
        static let slowActivity = BitField(offset: 2272, bit: 1, width: 1)
        static let syncActivity = BitField(offset: 2272, bit: 2, width: 1)
        static let activityDisplayId = StringField(offset: 2273, length: 256)
        static let bluetoothConnected = BitField(offset: 2528, bit: 8, width: 1)
        static let displayRawGSMSignal = BitField(offset: 2528, bit: 9, width: 1)
        static let displayRawWifiSignal = BitField(offset: 2528, bit: 10, width: 1)
        static let locationIconType = BitField(offset: 2528, bit: 11, width: 1)
        static let voiceControlIconType = BitField(offset: 2528, bit: 12, width: 2)
        static let quietModeInactive = BitField(offset: 2528, bit: 14, width: 1)
        static let tetheringConnectionCount = IntField(offset: 2532, isUnsigned: true)
        static let batterySaverModeActive = BitField(offset: 2536, bit: 0, width: 1)
        static let deviceIsRTL = BitField(offset: 2536, bit: 1, width: 1)
        static let lock = BitField(offset: 2536, bit: 2, width: 1)
        static let breadcrumbTitle = StringField(offset: 2537, length: 256)
        static let breadcrumbSecondaryTitle = StringField(offset: 2793, length: 256)
        static let personName = StringField(offset: 3049, length: 100)
        static let electronicTollCollectionAvailable = BitField(offset: 3148, bit: 8, width: 1)
        static let radarAvailable = BitField(offset: 3148, bit: 9, width: 1)
        static let wifiLinkWarning = BitField(offset: 3148, bit: 10, width: 1)
        static let wifiSearching = BitField(offset: 3148, bit: 11, width: 1)
        static let backgroundActivityDisplayStartDate = DoubleField(offset: 3152)
        static let shouldShowEmergencyOnlyStatus = BitField(offset: 3160, bit: 0, width: 1)
        static let secondaryCellularConfigured = BitField(offset: 3160, bit: 1, width: 1)
        static let primaryServiceBadgeString = StringField(offset: 3161, length: 100)
        static let secondaryServiceBadgeString = StringField(offset: 3261, length: 100)
        static let quietModeImage = StringField(offset: 3361, length: 256)
        static let quietModeName = StringField(offset: 3617, length: 256)
        static let extra1 = BitField(offset: 3872, bit: 8, width: 1)
    }

    /// The override struct's own packed bits, from `_OVERRIDE_BITFIELDS`.
    ///
    /// Note the three distinct byte offsets that all describe *bitfields* and not
    /// three separate fields: 44 holds bits 16-31, 48 holds bits 0-10, 56 holds
    /// bits 0-9. The reference writes each one as `off * 8 + bit`, which is what
    /// `bitfield` below reproduces.
    struct Override {
        static let overrideTimeString = BitField(offset: 44, bit: 16, width: 1)
        static let overrideDateString = BitField(offset: 44, bit: 17, width: 1)
        static let overrideGSMSignalStrengthRaw = BitField(offset: 44, bit: 18, width: 1)
        static let overrideSecondaryGSMSignalStrengthRaw = BitField(offset: 44, bit: 19, width: 1)
        static let overrideGSMSignalStrengthBars = BitField(offset: 44, bit: 20, width: 1)
        static let overrideSecondaryGSMSignalStrengthBars = BitField(offset: 44, bit: 21, width: 1)
        static let overrideServiceString = BitField(offset: 44, bit: 22, width: 1)
        static let overrideSecondaryServiceString = BitField(offset: 44, bit: 23, width: 1)
        static let overrideServiceImages = BitField(offset: 44, bit: 24, width: 1)
        static let overrideOperatorDirectory = BitField(offset: 44, bit: 26, width: 1)
        static let overrideServiceContentType = BitField(offset: 44, bit: 27, width: 1)
        static let overrideSecondaryServiceContentType = BitField(offset: 44, bit: 28, width: 1)
        static let overrideWifiSignalStrengthRaw = BitField(offset: 44, bit: 29, width: 1)
        static let overrideWifiSignalStrengthBars = BitField(offset: 44, bit: 30, width: 1)
        static let overrideDataNetworkType = BitField(offset: 44, bit: 31, width: 1)
        static let overrideSecondaryDataNetworkType = BitField(offset: 48, bit: 0, width: 1)
        static let disallowsCellularDataNetworkTypes = BitField(offset: 48, bit: 1, width: 1)
        static let overrideBatteryCapacity = BitField(offset: 48, bit: 2, width: 1)
        static let overrideBatteryState = BitField(offset: 48, bit: 3, width: 1)
        static let overrideBatteryDetailString = BitField(offset: 48, bit: 4, width: 1)
        static let overrideBluetoothBatteryCapacity = BitField(offset: 48, bit: 5, width: 1)
        static let overrideThermalColor = BitField(offset: 48, bit: 6, width: 1)
        static let overrideSlowActivity = BitField(offset: 48, bit: 7, width: 1)
        static let overrideActivityDisplayId = BitField(offset: 48, bit: 8, width: 1)
        static let overrideBluetoothConnected = BitField(offset: 48, bit: 9, width: 1)
        static let overrideBreadcrumb = BitField(offset: 48, bit: 10, width: 1)
        static let overrideDisplayRawGSMSignal = BitField(offset: 56, bit: 0, width: 1)
        static let overrideDisplayRawWifiSignal = BitField(offset: 56, bit: 1, width: 1)
        static let overridePersonName = BitField(offset: 56, bit: 2, width: 1)
        static let overrideWifiLinkWarning = BitField(offset: 56, bit: 3, width: 1)
        static let overrideSecondaryCellularConfigured = BitField(offset: 56, bit: 4, width: 1)
        static let overridePrimaryServiceBadgeString = BitField(offset: 56, bit: 5, width: 1)
        static let overrideSecondaryServiceBadgeString = BitField(offset: 56, bit: 6, width: 1)
        static let overrideQuietModeImage = BitField(offset: 56, bit: 7, width: 1)
        static let overrideQuietModeName = BitField(offset: 56, bit: 8, width: 1)
        static let overrideExtra1 = BitField(offset: 56, bit: 9, width: 1)
        /// `overrideLock` is a `uint32_t` of its own, not part of the packed row:
        /// the reference writes it with `struct.pack_into("<I", buf, 52, ...)`
        /// while the bitfields around it are OR-ed in byte by byte.
        static let overrideLock = IntField(offset: 52, isUnsigned: true)
    }
}

/// Writes the packed bits of one byte-or-multi-bit field.
///
/// `off * 8 + bit` is the reference's own formula (`divmod(off * 8 + bit, 8)`),
/// Set a bitfield's bits, matching `status_setter.py`'s `("bit", off, bit, w)` row.
///
///     bpos, sh = divmod(off * 8 + bit, 8)
///     buf[bpos] |= (val << sh) & 0xFF
///
/// The `& 0xFF` keeps the *shifted* result's low byte — masking to the field's
/// width instead (the obvious reading) would throw away exactly the bits that
/// belong to the field once it starts above bit 0, which is why a bit 16 in
/// byte 44 has to be written as `1 << 0` after the `divmod`, not masked
/// afterwards.
///
/// A zero value is not cleared: the reference ORs into a zeroed buffer and never
/// clears a bit, so the port does the same and the caller only ever sets.
private func setBit(_ buffer: inout [UInt8], _ field: StatusBarLayout.BitField, _ value: Int) {
    guard value != 0 else { return }
    let absolute = field.offset * 8 + field.bit
    let byte = absolute / 8
    let shift = absolute % 8
    guard byte < buffer.count else { return }
    buffer[byte] |= UInt8((value << shift) & 0xFF)
}

/// Write a `char[N]` at `offset`, NUL-padded and truncated to fit.
///
/// The reference assigns a Python `bytes` into the C array and then copies the
/// whole array with `ffi.buffer(...)`, so a short value is NUL-padded by cffi and
/// a long one is cut by the reference's own `value[:max_len]` slice *before* it is
/// assigned. The port fills all `length` bytes for the same reason: the struct is
/// a fixed 3880 bytes and the field after this one must start at its own offset
/// whatever the text was.
///
/// The one deliberate difference is multi-byte text. The reference slices
/// `max_len` *characters* and then encodes, so 100 non-ASCII characters overflow a
/// 100-byte array and cffi raises; here the cut is on the UTF-8 byte budget, on a
/// character boundary, so it can never split a scalar or overrun the field.
private func writeString(_ buffer: inout [UInt8], _ field: StatusBarLayout.StringField, _ text: String) {
    let room = field.length
    guard field.offset + room <= buffer.count else { return }
    var bytes = Array(text.utf8.prefix(room))
    // Never leave half a scalar at the end of the field.
    while let last = bytes.last, last & 0xC0 == 0x80, !text.isEmpty {
        // A continuation byte can only be last if the scalar it belongs to was cut.
        let whole = Array(text.utf8)
        if whole.count <= bytes.count { break }
        bytes = Array(whole.prefix(bytes.count - 1))
    }
    for index in 0..<room { buffer[field.offset + index] = 0 }
    for (index, byte) in bytes.enumerated() { buffer[field.offset + index] = byte }
}

private func writeInt(_ buffer: inout [UInt8], _ field: StatusBarLayout.IntField, _ value: Int) {
    // Both halves are the same two's-complement bytes; only the sign extension
    // differs, and `truncatingIfNeeded` already produces it.
    let wide: UInt64 = field.isUnsigned
        ? UInt64(UInt32(truncatingIfNeeded: value))
        : UInt64(UInt32(bitPattern: Int32(truncatingIfNeeded: value)))
    let big = UInt32(truncatingIfNeeded: wide)
    // Little-endian, matching `struct.pack_into("<i"/"<I")`.
    for index in 0..<4 where field.offset + index < buffer.count {
        buffer[field.offset + index] = UInt8((big >> (8 * UInt32(index))) & 0xFF)
    }
}

/// The user's status-bar overrides, as a set of typed fields.
///
/// The port of the reference's `StatusBarTweak` *state*: every `override*` flag
/// and the value it governs. The reference keeps this as a C struct mutated in
/// place; here it is a value type with named accessors, and the binary is
/// produced on demand by `serialiseClassic()`.
///
/// A field is "set" when its `override*` flag is 1 — that pairing is the whole
/// contract, and the struct the device reads carries both halves, so this type
/// never lets them drift apart.
struct StatusBarOverrides: Equatable {
    /// One `override*` flag plus the value it governs.
    ///
    /// `set` is the flag; `value` only means anything when `set` is true. Both
    /// halves are written together because SpringBoard reads a field whose flag
    /// is 0 as stock, whatever the value says.
    struct Field: Equatable {
        var set: Bool = false
        var value: Int = 0
        var text: String = ""

        /// An int-valued override.
        static func integer(_ defaultValue: Int = 0) -> Field {
            Field(set: false, value: defaultValue, text: "")
        }
        /// A string-valued override.
        static func string(_ defaultValue: String = "") -> Field {
            Field(set: false, value: 0, text: defaultValue)
        }

        var isEmpty: Bool { !set && value == 0 && text.isEmpty }
    }

    // MARK: Primary carrier
    var carrierName = Field.string()
    var cellularServiceShown = Field.integer()
    var serviceBadge = Field.string()
    var dataNetworkType = Field.integer()
    var signalBars = Field.integer(4)
    /// The raw-value toggles (`overrideDisplayRawGSMSignal` /
    /// `overrideDisplayRawWifiSignal`) — separate from the bar counts because
    /// they have no `value` of their own, only a flag.
    ///
    /// Two of them, because the reference has two: "Show Numeric Cellular
    /// Strength" and "Show Numeric Wi-Fi Strength" are separate rows on the
    /// reference's page, backed by bits 9 and 10 of the same byte.  Collapsing
    /// them into one would have meant dropping a row the reference shows.
    var rawSignalShown = false
    var rawWifiSignalShown = false

    // MARK: Secondary carrier
    var secondaryCarrierName = Field.string()
    var secondaryServiceBadge = Field.string()
    var secondaryDataNetworkType = Field.integer()
    var secondarySignalBars = Field.integer(4)
    var secondaryCellularConfigured = Field.integer()

    // MARK: Misc text
    var timeText = Field.string()
    var dateText = Field.string()
    var breadcrumb = Field.string()
    var batteryDetail = Field.string()

    // MARK: Misc values
    var batteryCapacity = Field.integer(100)
    var wifiBars = Field.integer(3)

    // MARK: Per-item show/hide
    /// `overrideItemIsEnabled` / `values.itemIsEnabled` for all 46 items.
    ///
    /// Nil means "no override for this item", which is not the same as
    /// "overridden to hidden": the flag being 0 is what leaves the item stock.
    var itemShown: [StatusBarItem: Bool] = [:]

    /// Every item on, whatever the user set — the reference's "silly mode"
    /// (`Setter.get_overrides_with_silly_mode`).
    ///
    /// Kept as a flag on the type rather than applied on write, so turning it
    /// off restores exactly what the user had.
    var sillyMode = false

    /// Every field, in a fixed order, for the two loops that walk them.
    private var allFields: [Field] {
        [carrierName, cellularServiceShown, serviceBadge, dataNetworkType,
         signalBars, secondaryCarrierName, secondaryServiceBadge,
         secondaryDataNetworkType, secondarySignalBars,
         secondaryCellularConfigured, timeText, dateText, breadcrumb,
         batteryDetail, batteryCapacity, wifiBars]
    }

    /// How many overrides are live, for the apply summary.
    ///
    /// The reference's `count_overrides` walks the struct with `dir()` and counts
    /// every int `override*` field that is non-zero, plus every enabled item.
    /// Counting the named fields is the same number: the struct's other
    /// `override*` fields (`overrideGSMSignalStrengthRaw`,
    /// `overrideServiceImages`, `overrideOperatorDirectory`, …) are ones this
    /// port does not expose, and the reference does not expose them either.
    ///
    /// Only `set` counts. A field's `value` and `text` are the *default* the user
    /// would see in the editor — `signalBars` starts at 4 and `batteryCapacity` at
    /// 100 — so a value-only test would report a fresh, untouched selection as
    /// two live overrides and never let the page read as empty.
    var activeCount: Int {
        var count = allFields.count { $0.set }
        if rawSignalShown { count += 1 }
        if rawWifiSignalShown { count += 1 }
        count += itemShown.count
        return count
    }

    var isEmpty: Bool { activeCount == 0 }

    /// The classic binary `StatusBarOverrideData`, ready to hand to the injector.
    ///
    /// `serialiseClassic()` in the reference: `overrideItemIsEnabled[46]`, the
    /// packed flag bytes at 44/48/56, `overrideLock` as a u32 at 52, and the
    /// 3880-byte `values` struct at 64.
    func serialiseClassic() -> Data {
        var buffer = [UInt8](repeating: 0, count: StatusBarLayout.overrideSize)
        // `overrideItemIsEnabled[46]` at 0. Built up rather than written straight
        // into `buffer`, because silly mode has to be able to see which slots a
        // setter already claimed — it leaves those alone and only fills the rest.
        var overrideItems = [UInt8](repeating: 0, count: StatusBarLayout.itemCount)
        var raw = [UInt8](repeating: 0, count: StatusBarLayout.rawSize)

        /// One `set_item_override(item, shown)` call, plus the two setters that
        /// reach for an item of their own (`set_gsm_signal_strength_bars` and
        /// friends). The flag goes on either way: a hidden item is still
        /// *overridden to hidden*, which is what `is_item_overridden` reports.
        func overrideItem(_ item: StatusBarItem, shown: Bool) {
            overrideItems[item.index] = 1
            raw[StatusBarLayout.Raw.itemIsEnabled[item.index]] = shown ? 1 : 0
        }

        for (item, shown) in itemShown {
            overrideItem(item, shown: shown)
        }

        // MARK: primary
        if carrierName.set {
            setBit(&buffer, StatusBarLayout.Override.overrideServiceString, 1)
            writeString(&raw, StatusBarLayout.Raw.serviceString, carrierName.text)
            // Both strings get the same bytes: the reference assigns
            // `serviceCrossfadeString = serviceString` in `set_carrier_override`.
            writeString(&raw, StatusBarLayout.Raw.serviceCrossfadeString, carrierName.text)
        }
        if cellularServiceShown.set {
            // `set_cellular_service` is a plain `set_item_override` on item 6, so
            // it has no `override*` bit of its own.
            overrideItem(.cellularService, shown: cellularServiceShown.value != 0)
        }
        if serviceBadge.set {
            setBit(&buffer, StatusBarLayout.Override.overridePrimaryServiceBadgeString, 1)
            writeString(&raw, StatusBarLayout.Raw.primaryServiceBadgeString, serviceBadge.text)
        }
        if dataNetworkType.set {
            setBit(&buffer, StatusBarLayout.Override.overrideDataNetworkType, 1)
            writeInt(&raw, StatusBarLayout.Raw.dataNetworkType, dataNetworkType.value)
        }
        if signalBars.set {
            setBit(&buffer, StatusBarLayout.Override.overrideGSMSignalStrengthBars, 1)
            // The reference also enables the signal-strength *item*, which is
            // what makes the bar count visible at all.
            overrideItem(.cellularSignalStrength, shown: true)
            writeInt(&raw, StatusBarLayout.Raw.GSMSignalStrengthBars, signalBars.value)
        }
        if rawSignalShown {
            setBit(&buffer, StatusBarLayout.Override.overrideDisplayRawGSMSignal, 1)
            setBit(&raw, StatusBarLayout.Raw.displayRawGSMSignal, 1)
        }
        if rawWifiSignalShown {
            setBit(&buffer, StatusBarLayout.Override.overrideDisplayRawWifiSignal, 1)
            setBit(&raw, StatusBarLayout.Raw.displayRawWifiSignal, 1)
        }

        // MARK: secondary
        if secondaryCarrierName.set {
            setBit(&buffer, StatusBarLayout.Override.overrideSecondaryServiceString, 1)
            writeString(&raw, StatusBarLayout.Raw.secondaryServiceString, secondaryCarrierName.text)
            writeString(&raw, StatusBarLayout.Raw.secondaryServiceCrossfadeString,
                        secondaryCarrierName.text)
        }
        if secondaryServiceBadge.set {
            setBit(&buffer, StatusBarLayout.Override.overrideSecondaryServiceBadgeString, 1)
            writeString(&raw, StatusBarLayout.Raw.secondaryServiceBadgeString,
                        secondaryServiceBadge.text)
        }
        if secondaryDataNetworkType.set {
            setBit(&buffer, StatusBarLayout.Override.overrideSecondaryDataNetworkType, 1)
            writeInt(&raw, StatusBarLayout.Raw.secondaryDataNetworkType, secondaryDataNetworkType.value)
        }
        if secondarySignalBars.set {
            setBit(&buffer, StatusBarLayout.Override.overrideSecondaryGSMSignalStrengthBars, 1)
            overrideItem(.secondaryCellularSignalStrength, shown: true)
            writeInt(&raw, StatusBarLayout.Raw.secondaryGSMSignalStrengthBars, secondarySignalBars.value)
        }
        if secondaryCellularConfigured.set {
            setBit(&buffer, StatusBarLayout.Override.overrideSecondaryCellularConfigured, 1)
            setBit(&raw, StatusBarLayout.Raw.secondaryCellularConfigured, secondaryCellularConfigured.value)
            // `set_secondary_cellular_service` sets item 7 *and* the configured bit.
            overrideItem(.secondaryCellularService, shown: secondaryCellularConfigured.value != 0)
        }

        // MARK: misc text
        if timeText.set {
            setBit(&buffer, StatusBarLayout.Override.overrideTimeString, 1)
            writeString(&raw, StatusBarLayout.Raw.timeString, timeText.text)
        }
        if dateText.set {
            setBit(&buffer, StatusBarLayout.Override.overrideDateString, 1)
            writeString(&raw, StatusBarLayout.Raw.dateString, dateText.text)
        }
        if breadcrumb.set {
            setBit(&buffer, StatusBarLayout.Override.overrideBreadcrumb, 1)
            // The reference appends the disclosure glyph: `text[:254] + " ▶"`.
            // SpringBoard renders it as the "Return to <App>" breadcrumb, and the
            // trailing triangle is part of that rendering, not part of the text.
            let crumb = breadcrumb.text.isEmpty
                ? ""
                : String(breadcrumb.text.prefix(254)) + " \u{25B6}"
            writeString(&raw, StatusBarLayout.Raw.breadcrumbTitle, crumb)
        }
        if batteryDetail.set {
            setBit(&buffer, StatusBarLayout.Override.overrideBatteryDetailString, 1)
            writeString(&raw, StatusBarLayout.Raw.batteryDetailString, batteryDetail.text)
        }

        // MARK: misc values
        if batteryCapacity.set {
            setBit(&buffer, StatusBarLayout.Override.overrideBatteryCapacity, 1)
            writeInt(&raw, StatusBarLayout.Raw.batteryCapacity, batteryCapacity.value)
        }
        if wifiBars.set {
            setBit(&buffer, StatusBarLayout.Override.overrideWifiSignalStrengthBars, 1)
            writeInt(&raw, StatusBarLayout.Raw.wifiSignalStrengthBars, wifiBars.value)
        }

        // `get_overrides_with_silly_mode`: after everything else, because the
        // reference's setters have already run by the time it is called and it
        // deliberately preserves what they wrote. Every slot it turns on goes to
        // 1 in *both* arrays — the value is forced on, not just the flag.
        if sillyMode {
            for index in 0..<StatusBarLayout.itemCount where overrideItems[index] == 0 {
                overrideItems[index] = 1
                raw[StatusBarLayout.Raw.itemIsEnabled[index]] = 1
            }
        }

        for index in 0..<StatusBarLayout.itemCount { buffer[index] = overrideItems[index] }
        // The nested struct goes in whole, at 64.
        buffer.replaceSubrange(StatusBarLayout.rawOffset..<(StatusBarLayout.rawOffset + StatusBarLayout.rawSize),
                               with: raw)
        return Data(buffer)
    }
}

/// The 46 status-bar items, with the indices the device's struct uses.
///
/// From `status_setter.py: StatusBarItem`, which is a straight transcription of
/// the private `SBStatusBarItem` enum. **The gaps are load-bearing**: 8, 11, 14,
/// 15, 19, 20, 30, 32-39 and 42-43 and 45 are unused slots in Apple's enum, so
/// their absence here is not an oversight. Renumbering would write every
/// subsequent item's flag one byte off.
enum StatusBarItem: Int, CaseIterable, Hashable {
    case time = 0
    case date = 1
    case quietMode = 2
    case airplaneMode = 3
    case cellularSignalStrength = 4
    case secondaryCellularSignalStrength = 5
    case cellularService = 6
    case secondaryCellularService = 7
    // 8 unused
    case cellularDataNetwork = 9
    case secondaryCellularDataNetwork = 10
    // 11 unused
    case mainBattery = 12
    case prominentlyShowBatteryDetail = 13
    // 14, 15 unused
    case bluetooth = 16
    case tty = 17
    case alarm = 18
    // 19, 20 unused
    case location = 21
    case rotationLock = 22
    case cameraUse = 23
    case airPlay = 24
    case assistant = 25
    case carPlay = 26
    case student = 27
    case microphoneUse = 28
    case vpn = 29
    // 30 unused
    case phonePickup = 31
    // 32-39 unused
    case liquidDetection = 40
    case voiceControl = 41
    // 42, 43 unused
    case extra1 = 44
    // 45 unused

    /// The struct offset of this item's flag / value slot.
    ///
    /// Named `index` rather than used as `rawValue` at the call sites because
    /// the two are not the same thing: `rawValue` is the enum ordinal (with
    /// Apple's gaps), and `index` is what indexes the `_Bool[46]` arrays.
    var index: Int { rawValue }

    init?(index: Int) {
        guard let known = Self(rawValue: index) else { return nil }
        self = known
    }

    /// What the status page shows. Grouped by what the user is actually changing,
    /// not by index order.
    var title: String {
        switch self {
        case .time: return "Time"
        case .date: return "Date"
        case .quietMode: return "Quiet Mode"
        case .airplaneMode: return "Airplane Mode"
        case .cellularSignalStrength: return "Cellular Signal Strength"
        case .secondaryCellularSignalStrength: return "Secondary Signal Strength"
        case .cellularService: return "Cellular Service"
        case .secondaryCellularService: return "Secondary Cellular Service"
        case .cellularDataNetwork: return "Data Network Type"
        case .secondaryCellularDataNetwork: return "Secondary Data Network"
        case .mainBattery: return "Battery"
        case .prominentlyShowBatteryDetail: return "Battery Detail"
        case .bluetooth: return "Bluetooth"
        case .tty: return "TTY"
        case .alarm: return "Alarm"
        case .location: return "Location"
        case .rotationLock: return "Rotation Lock"
        case .cameraUse: return "Camera"
        case .airPlay: return "AirPlay"
        case .assistant: return "Assistant"
        case .carPlay: return "CarPlay"
        case .student: return "Student Status"
        case .microphoneUse: return "Microphone"
        case .vpn: return "VPN"
        case .phonePickup: return "Phone Pickup"
        case .liquidDetection: return "Liquid Detection"
        case .voiceControl: return "Voice Control"
        case .extra1: return "Extra 1"
        }
    }
}

// `Field` is declared above, and its `Codable` conformance has to be in the
// **same file** as that declaration for the compiler to synthesise
// `init(from:)` / `encode(to:)`.  An extension in `StatusBarSelection.swift`,
// where the stored-selection type that needs it lives, is rejected with
// "extension outside of file declaring struct 'Field' prevents automatic
// synthesis of 'init(from:)'".  It therefore sits here, at file scope (an
// extension cannot be nested inside the struct that declares `Field`).
extension StatusBarOverrides.Field: Codable {
    private enum CodingKeys: String, CodingKey {
        case set, value, text
    }
}
