import Foundation

// The runtime half of the tweak port.
//
// `TweakCatalog.swift` (generated) carries the *data* — one `TweakSpec` per
// record in GoldenNugget's `src/tweaks/registry.py`.  This file carries the
// *meaning*: the plist value type those specs use, the compatibility verdict
// the reference's `src/gui/ios/compat.py` gives a spec, and the live selection
// that mirrors GoldenNugget's `tweaks: dict[TweakID, Tweak]` runtime state.
//
// Everything here is a port of a named reference function; the file names and
// line references are in the doc comments so a divergence can be checked
// against the source rather than guessed at.

/// A plist scalar a tweak can carry.
///
/// The reference stores a plain Python value (`True`, `5`, `1.0`, `"text"`) and
/// hands it to `plistlib`.  This is that value with the case split made
/// explicit, because the *kind* decides the wire encoding: an `Int` must reach
/// `PropertyListSerialization` as an integer, not as a `Double` that happens to
/// have no fraction — the same distinction that made a `UInt32` `Mode` decode as
/// a number reference and cost a whole diagnosis round (see `MBFileBlob`).
enum TweakValue: Hashable, Sendable {
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    /// A nested mapping (`PosterKitOverrides`'s selected fields,
    /// `WallpaperPreferencesTweak`'s `{"none": …}` tree, `_clock_animation`'s
    /// flag dict).  `plistObject` hands it to `PropertyListSerialization`
    /// unchanged, so the nesting the reference's Python dict had is preserved.
    indirect case dictionary([String: TweakValue])

    /// The object `PropertyListSerialization` should be handed for this value.
    var plistObject: Any {
        switch self {
        case .bool(let value): return value
        case .int(let value): return value
        case .double(let value): return value
        case .string(let value): return value
        case .dictionary(let values):
            return Dictionary(uniqueKeysWithValues: values.map { ($0.key, $0.value.plistObject) })
        }
    }

    /// A short rendering, for the log and the import report.
    var display: String {
        switch self {
        case .bool(let value): return value ? "true" : "false"
        case .int(let value): return String(value)
        case .double(let value): return String(value)
        case .string(let value): return value
        case .dictionary(let values): return "\(values.count) field(s)"
        }
    }

    /// A member of a `.dictionary` value, for the dict-shaped selections.
    func dictionaryValue(_ key: String) -> TweakValue? {
        guard case .dictionary(let values) = self else { return nil }
        return values[key]
    }

    /// Re-shape a value that came from outside (a preset) into what `spec`
    /// expects.
    ///
    /// The spec is the authority, not the stored value, for two reasons:
    ///
    ///   * a switch and a `0/1` number are indistinguishable once JSON has been
    ///     through `JSONSerialization` (`NSNumber(1) as? Bool` succeeds), so the
    ///     editor the spec asks for decides the case;
    ///   * a `.number` spec's default decides `int` vs `double`, and that is not
    ///     cosmetic — the reference writes `1` and `1.0` as different plist
    ///     types (`value=1` vs `value=1.0` in `registry.py`), and the framework
    ///     reading the key sees a different type.  JSON prints both as `1.0`,
    ///     so the default is the only place the intent survives.
    func coerced(to spec: TweakSpec) -> TweakValue {
        switch spec.kind {
        case .posterArchive, .wallpaper, .posterFlag:
            // The dict-shaped kinds take a dictionary as-is; the import
            // validation (`validationIssue`) checks the fields, the way the
            // reference's `PosterKitOverrides.stage` /
            // `WallpaperPreferencesTweak.apply_tweak` raise on bad fields.
            if case .dictionary = self { return self }
            return spec.value
        case .toggle:
            switch self {
            case .bool(let b): return .bool(b)
            case .int(let i): return .bool(i != 0)
            case .double(let d): return .bool(d != 0)
            case .string(let s): return .bool((s as NSString).boolValue)
            case .dictionary: return spec.value
            }
        case .number:
            // Imports obey the same finite/range/type rules as the editor.
            // Int(Double) traps for large JSON numbers before any later clamp.
            let raw: String
            if case .bool(let b) = self { raw = b ? "1" : "0" }
            else { raw = display }
            return spec.numberValue(from: raw) ?? spec.value
        case .text:
            return .string(display)
        }
    }
}

/// One registry-defined tweak, field for field with the reference `TweakSpec`.
///
/// `multiValues` is the one field with no counterpart in the reference's
/// `TweakSpec`: it is non-nil exactly when that spec's `factory` builds an
/// `AdvancedPlistTweak`, whose `apply_tweak` replaces the whole location dict
/// with a set of keys instead of writing one key/value pair.  The generator
/// folds that dict in here so one Swift type covers both shapes.
struct TweakSpec: Sendable {
    let id: String
    let section: TweakSection
    let title: String
    let location: TweakFileLocation
    let key: String
    let value: TweakValue
    let kind: TweakKind
    let minValue: Double
    let maxValue: Double
    let step: Double
    let minVersion: String?
    let maxVersion: String?
    let iphoneOnly: Bool
    let ipadOnly: Bool
    let disabled: Bool
    let detail: String?
    let multiValues: [String: TweakValue]?
    /// ReversibleBooleanPlistTweak writes false on a subsequent disabled apply.
    var reversibleBoolean: Bool = false
    var requiresDynamicIsland: Bool = false
    /// A `TriStateBooleanPlistTweak` selection: "used on" / "used off" /
    /// "not used".  Master-off discards the stored state (nothing is written),
    /// unlike an `ExperimentalBooleanPlistTweak`, whose off selection persists
    /// `offValue` for rollback.
    var triState: Bool = false
    /// The value a tri-state row writes in its "used on" state; "used off"
    /// writes the negation, like the reference's `off_value`.
    var onValue: TweakValue? = nil
    /// `FeatureFlagTweak` / `GlassFeatureFlagTweak`: the flags write into
    /// `flagCategory` inside the FeatureFlags plist, one entry per name.
    var flagCategory: String? = nil
    var flagNames: [String] = []
    /// `NestedNumericPreference`: the number lands inside `key`'s dictionary
    /// under this child key.
    var childKey: String? = nil
    /// Research-only rows carry an `unavailable_reason` and are shown greyed
    /// out instead of hidden (`show_when_unavailable`).
    var showWhenUnavailable: Bool = false

    var factory: String = "BasicPlistTweak"
    var offValue: TweakValue? = nil
    var integerBoolean: Bool = false
    var requiresCameraControl: Bool = false
    var requiresActionButton: Bool = false
    var requiresHomeButton: Bool = false
    var requiresAlwaysOn: Bool = false
    var warning: String? = nil
    var requires: [String] = []
    var exclusiveWith: String? = nil
    var unavailableReason: String? = nil
    var supportedModels: [String] = []

    /// Whether this tweak writes a whole dict rather than a single key.
    var writesWholeDict: Bool { multiValues != nil }
}

/// The subset of `packaging.version.Version` the registry's bounds need.
///
/// GoldenNugget compares with `packaging.version.Version`
/// (`src/devicemanagement/constants.py:1`).  Every bound in the registry is a
/// plain dotted release — `17.4`, `26.0`, `26.99`, `27.0` — and PEP 440 orders
/// those as zero-padded integer tuples, which is what this reproduces.
///
/// A version whose *first* component is not an integer is deliberately treated
/// as unorderable rather than guessed at: the reference wraps each comparison in
/// `try/except: pass`, which leaves the tweak visible when a parse fails, and a
/// silent "not compatible" verdict on unparseable input would be a different
/// (and worse) outcome than the reference's.
enum TweakVersion {
    private static func components(_ version: String) -> [Int]? {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        var out: [Int] = []
        for part in parts {
            // A trailing non-numeric component (e.g. `27.0b1`) is dropped, the
            // same way the reference's own `HotLoad._compare` filters parts with
            // `isdigit()`.
            guard let n = Int(part) else { break }
            out.append(n)
        }
        return out.isEmpty ? nil : out
    }

    /// -1 / 0 / 1, or nil when either side has no orderable leading component.
    static func compare(_ lhs: String, _ rhs: String) -> Int? {
        guard var a = components(lhs), var b = components(rhs) else { return nil }
        let count = max(a.count, b.count)
        a += Array(repeating: 0, count: count - a.count)
        b += Array(repeating: 0, count: count - b.count)
        for (x, y) in zip(a, b) where x != y { return x < y ? -1 : 1 }
        return 0
    }
}

/// Desktop's opt-in bypasses version bounds only on iOS 26; hardware gates stay active.
enum UntestedTweaks {
    static let enabledKey = "enable_incompatible_tweaks"
    static let choiceKey = "incompatible_tweaks_choice_done"
    static func isIOS26(_ version: String) -> Bool {
        guard let range = version.range(of: "[0-9]+(\\.[0-9]+){0,3}", options: .regularExpression) else { return false }
        let version = String(version[range])
        return (TweakVersion.compare(version, "26") ?? -1) >= 0
            && TweakVersion.compare(version, "27") == -1
    }
}

extension TweakSpec {
    /// The verdict of the reference's `is_tweak_compatible`
    /// (`src/gui/ios/compat.py:11`), plus the registry's own `disabled` flag.
    ///
    /// `disabled` is checked first because the reference cuts such a spec off at
    /// load time (`tweak_loader.load_plist_tweaks`: "never registered, so they
    /// neither render nor apply"), which is a stronger statement than
    /// incompatible — it simply does not exist.
    ///
    /// `deviceVersion` is the device's `ProductVersion` (`27.0`), read from
    /// lockdown; `isIPhone` is `ProductType.hasPrefix("iPhone")`, which is how
    /// the reference derives it (`src/gui/ios/tweaks.py:107`).
    func isCompatible(deviceVersion: String, isIPhone: Bool, deviceModel: String = "") -> Bool {
        if disabled || unavailableReason != nil { return false }
        if !supportedModels.isEmpty && !supportedModels.contains(deviceModel) { return false }
        // Opaque Siri archives have a stricter delivery gate than ordinary preferences.
        if factory == "SiriAITweak" {
            guard let minimum = TweakVersion.compare(deviceVersion, "27"), minimum >= 0,
                  TweakVersion.compare(deviceVersion, "28") == -1 else { return false }
        }
        if deviceVersion.isEmpty && deviceModel.isEmpty { return true }
        if !deviceVersion.isEmpty {
            guard let range = deviceVersion.range(of: "[0-9]+(\\.[0-9]+){0,3}", options: .regularExpression) else { return false }
            let deviceVersion = String(deviceVersion[range])
            let allowUntested = UntestedTweaks.isIOS26(deviceVersion) && UserDefaults.standard.bool(forKey: UntestedTweaks.enabledKey)
            if !allowUntested, let minVersion,
               let cmp = TweakVersion.compare(deviceVersion, minVersion), cmp < 0 { return false }
            if !allowUntested, let maxVersion,
               let cmp = TweakVersion.compare(deviceVersion, maxVersion), cmp > 0 { return false }
        }
        if ipadOnly && isIPhone { return false }
        if iphoneOnly && !isIPhone { return false }
        if requiresDynamicIsland && !TweakDeviceCapabilities.hasDynamicIsland(deviceModel) { return false }
        if requiresCameraControl && !TweakDeviceCapabilities.hasCameraControl(deviceModel) { return false }
        if requiresActionButton && !TweakDeviceCapabilities.hasActionButton(deviceModel) { return false }
        if requiresHomeButton && !TweakDeviceCapabilities.hasHomeButton(deviceModel) { return false }
        if requiresAlwaysOn && !TweakDeviceCapabilities.hasAlwaysOn(deviceModel) { return false }
        return true
    }

    /// Parse a `.number` edit: clamped to the registry's own bounds and carrying
    /// the registry's numeric type.
    ///
    /// The bounds are the spec's (`min_value` / `max_value` in `registry.py`),
    /// so the UI cannot write a value the reference's own spin box would not
    /// have allowed.  Integer specs round; a `.double` default keeps its
    /// fraction, because `1.0` and `1` are different plist types.
    func numberValue(from raw: String) -> TweakValue? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let parsed = Double(trimmed), parsed.isFinite else { return nil }
        let clamped = Swift.min(Swift.max(parsed, minValue), maxValue)
        if case .double = value { return .double(clamped) }
        guard let integer = Int(exactly: clamped.rounded()) else { return nil }
        return .int(integer)
    }

    /// The units line under a `.number` editor.
    var numberHint: String {
        let integral = step == step.rounded() && (minValue == minValue.rounded())
        return "\(minValue)–\(maxValue), step \(step)" + (integral ? "" : " (decimal)")
    }

    /// The apply-time value checks the reference runs inside the factory
    /// classes (`PosterKitOverrides.stage`,
    /// `WallpaperPreferencesTweak.apply_tweak`, `GlassLegibilityTweak`,
    /// `UIKitAnimationScaleTweak`, `UIKitInternalScrollDurationTweak`).
    ///
    /// They live here rather than in the compiler because a preset import can
    /// produce a selection no editor would: the reference raises from
    /// `apply_tweak` and aborts the apply, and this port answers with the
    /// same refusal through `TweakSelection.validationIssue`, before any
    /// device work starts.
    func selectionValueIssue(_ value: TweakValue) -> String? {
        switch factory {
        case "PosterKitOverrides":
            guard case .dictionary(let fields) = value else { return nil }
            let allowed = Dictionary(uniqueKeysWithValues: PosterKitOptions.all.map { ($0.key, $0) })
            for (key, item) in fields.sorted(by: { $0.key < $1.key }) {
                guard let field = allowed[key] else {
                    return "Invalid PosterKit setting: \(key)"
                }
                switch (field.defaultValue, item) {
                case (.bool, .bool), (.double, .double), (.int, .int), (.string, .string):
                    break
                // A whole-number default accepts a fractional input the same
                // way Python's `int`/`float` duality does: the field decides
                // the plist type at write time.
                case (.double, .int), (.int, .double):
                    break
                default:
                    return "Invalid PosterKit setting: \(key)"
                }
                if key == "Clock:timeFontConfiguration.timeFontIdentifier" {
                    if case .string(let font) = item, PosterKitOptions.clockFontIdentifiers.contains(font) {} else {
                        return "Choose a clock font identifier from the available candidates, not a runtime symbol."
                    }
                }
                if key == "Clock:timeNumberingSystem", case .string(let text) = item,
                   text.trimmingCharacters(in: .whitespaces).isEmpty || text == "$null" {
                    return "Enter a numbering-system identifier, or uncheck Use for Clock Numbering System."
                }
                if case .double(let number) = item {
                    if let (lower, upper, _) = field.limits, !number.isFinite || number < lower || number > upper {
                        return "PosterKit value outside allowed editor range: \(key)"
                    }
                }
                if case .int(let number) = item {
                    if let (lower, upper, _) = field.limits, Double(number) < lower || Double(number) > upper {
                        return "PosterKit value outside allowed editor range: \(key)"
                    }
                }
            }
            return nil
        case "WallpaperPreferencesTweak":
            guard case .dictionary(let outer) = value,
                  case .dictionary(let fields)? = outer["none"] else { return nil }
            for key in ["SBWallpaperHasVideoKey", "SBWallpaperMagnifyEnabledKey",
                        "SBWallpaperPortraitKey", "SBWallpaperSupportsCroppingKey",
                        "kSBProceduralWallpaperHomeUserSetKey"] {
                // `WallpaperPreferencesTweak` accepts a bool or a 0/1 int and
                // normalizes both to a bool.
                switch fields[key] {
                case .bool: break
                case .int(let flag) where flag == 0 || flag == 1: break
                default: return "Expected a boolean wallpaper field: \(key)"
                }
            }
            for (key, lower, upper) in [("SBWallpaperParallaxFactorKey", 0.0, 100.0),
                                        ("SBWallpaperStillTimeInVideoKey", 0.0, 86400.0),
                                        ("SBWallpaperZoomScaleKey", 0.01, 100.0)] {
                guard case .double(let number)? = fields[key] else {
                    if case .int(let integer)? = fields[key] {
                        let number = Double(integer)
                        if !(lower...upper).contains(number) { return "Invalid numeric wallpaper field: \(key)" }
                        continue
                    }
                    return "Invalid numeric wallpaper field: \(key)"
                }
                if !number.isFinite || !(lower...upper).contains(number) {
                    return "Invalid numeric wallpaper field: \(key)"
                }
            }
            return nil
        case "GlassLegibilityTweak":
            switch value {
            case .int(let number) where number == 0 || number == 1: return nil
            case .double(let number) where number == 0 || number == 1: return nil
            default: return "Glass legibility appearance must be 0 or 1."
            }
        case "UIKitAnimationScaleTweak":
            let number: Double?
            if case .double(let d) = value { number = d } else if case .int(let i) = value { number = Double(i) } else { number = nil }
            guard let number, number.isFinite, (0.1...3.0).contains(number) else {
                return "Animation duration scale must be between 0.1 and 3."
            }
            return nil
        case "DiscreteScrollDurationTweak", "DirectionalScrollDurationTweak":
            let number: Double?
            if case .double(let d) = value { number = d } else if case .int(let i) = value { number = Double(i) } else { number = nil }
            guard let number, number.isFinite, (0.0...1.0).contains(number) else {
                return "Scrolling duration must be between 0 and 1 second."
            }
            return nil
        default:
            return nil
        }
    }
}

/// The live selection: which specs are on, and with what value.
///
/// Mirrors the reference's runtime `tweaks` dict of `Tweak` objects.  A spec
/// starts *off* at its registry default, exactly as `Tweak.__init__` leaves
/// `enabled = False`, and editing a value turns it on — the reference's
/// `Tweak.set_value(..., toggle_enabled: True)`.
struct TweakSelection: Equatable {
    /// A real apply gate, independent of the retained per-group choices.
    var daemonModificationsEnabled = false
    private(set) var enabled: Set<String> = []
    private(set) var values: [String: TweakValue] = [:]
    /// Imported overrides for the specs whose reference definition writes a
    /// whole dict (`AdvancedPlistTweak`).  A preset round-trips that dict, so it
    /// has to be storable — but it is a different shape from `values`, hence a
    /// separate table rather than a wider `TweakValue`.
    private(set) var multiOverrides: [String: [String: TweakValue]] = [:]

    func isOn(_ spec: TweakSpec) -> Bool { enabled.contains(spec.id) }

    /// The value to write: the user's, else the registry default.
    func value(for spec: TweakSpec) -> TweakValue { values[spec.id] ?? spec.value }

    /// The dict to write for a dict-shaped spec: an imported override, else the
    /// registry's own.
    func multiValues(for spec: TweakSpec) -> [String: TweakValue]? {
        multiOverrides[spec.id] ?? spec.multiValues
    }

    mutating func setOn(_ on: Bool, for spec: TweakSpec) {
        if on && spec.section == .daemons { daemonModificationsEnabled = true }
        if on { enabled.insert(spec.id) } else { enabled.remove(spec.id) }
        if spec.triState {
            // `TriStateBooleanPlistTweak.set_enabled`: on seeds the "used on"
            // state, off returns to "not used" and discards whatever the
            // editor last chose.
            if on { values[spec.id] = spec.onValue ?? spec.value }
            else { values.removeValue(forKey: spec.id) }
        } else if spec.offValue != nil {
            values[spec.id] = on ? spec.value : spec.offValue
        }
        if on {
            if let id = spec.exclusiveWith, let other = TweakCatalog.byID[id], isOn(other) { setOn(false, for: other) }
        }
    }

    /// Set a value and switch the tweak on, like `Tweak.set_value`.
    mutating func setValue(_ value: TweakValue, for spec: TweakSpec) {
        values[spec.id] = value
        enabled.insert(spec.id)
    }

    /// `TriStateBooleanPlistTweak.set_state`: choose the written state while
    /// the master toggle stays on.  The choice, not the written value, is
    /// stored — the compiler maps it through the spec's `onValue`.
    mutating func setTriState(_ state: Bool, for spec: TweakSpec) {
        values[spec.id] = .bool(state)
    }

    /// Store a dictionary-shaped selection (`PosterKitOverrides`'s fields,
    /// `WallpaperPreferencesTweak`'s `{"none": …}` tree) without the enable
    /// side effect: the desktop editor's `store` keeps `toggle_enabled=False`,
    /// so editing a field never switches the master toggle on.
    mutating func setDictionary(_ dictionary: [String: TweakValue], for spec: TweakSpec) {
        values[spec.id] = .dictionary(dictionary)
    }

    mutating func removeValue(for spec: TweakSpec) {
        values.removeValue(forKey: spec.id)
        multiOverrides.removeValue(forKey: spec.id)
    }

    mutating func removeAll() {
        daemonModificationsEnabled = false
        enabled.removeAll()
        values.removeAll()
        multiOverrides.removeAll()
    }

    /// Seed straight from an imported preset, without the "enabling" side effect
    /// `setValue` has: a preset states `enabled` and `value` separately, and a
    /// stored `false` must not switch the tweak on.
    mutating func restore(enabled: Bool,
                          value: TweakValue?,
                          multiValues: [String: TweakValue]?,
                          for spec: TweakSpec) {
        if enabled && spec.section == .daemons { daemonModificationsEnabled = true }
        if enabled { self.enabled.insert(spec.id) } else { self.enabled.remove(spec.id) }
        if let value { values[spec.id] = value } else { values.removeValue(forKey: spec.id) }
        if let multiValues { multiOverrides[spec.id] = multiValues }
        else { multiOverrides.removeValue(forKey: spec.id) }
    }

    /// Validate dependencies before staging files, including presets that bypass editors.
    func validationIssue() -> String? {
        for spec in TweakCatalog.all where isOn(spec) {
            if let reason = spec.unavailableReason { return "\(spec.title): \(reason)" }
            if let peer = spec.exclusiveWith, enabled.contains(peer) {
                return "\(spec.title) cannot be combined with \(TweakCatalog.byID[peer]?.title ?? peer)."
            }
            if spec.kind != .number || value(for: spec) != spec.value {
                for id in spec.requires where !enabled.contains(id) {
                    return "Enable \(TweakCatalog.byID[id]?.title ?? id) before applying \(spec.title)."
                }
            }
            if spec.factory == "OptionalBundlePreferenceTweak" {
                let text = value(for: spec).display
                if text.count > 255 || text.range(of: "^(?:[A-Za-z0-9-]+(?:\\.[A-Za-z0-9-]+)+)?$", options: .regularExpression) == nil {
                    return "Enter a valid app bundle identifier for \(spec.title), or clear the field."
                }
            }
            if let issue = spec.selectionValueIssue(value(for: spec)) {
                return "\(spec.title): \(issue)"
            }
        }
        return nil
    }

    var enabledCount: Int { enabled.count }
    var hasPendingWrites: Bool {
        !enabled.isEmpty || TweakCatalog.all.contains { $0.offValue != nil && values[$0.id] != nil }
    }
}
