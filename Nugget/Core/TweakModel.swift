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
enum TweakValue: Equatable, Sendable {
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)

    /// The object `PropertyListSerialization` should be handed for this value.
    var plistObject: Any {
        switch self {
        case .bool(let value): return value
        case .int(let value): return value
        case .double(let value): return value
        case .string(let value): return value
        }
    }

    /// A short rendering, for the log and the import report.
    var display: String {
        switch self {
        case .bool(let value): return value ? "true" : "false"
        case .int(let value): return String(value)
        case .double(let value): return String(value)
        case .string(let value): return value
        }
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
        case .toggle:
            switch self {
            case .bool(let b): return .bool(b)
            case .int(let i): return .bool(i != 0)
            case .double(let d): return .bool(d != 0)
            case .string(let s): return .bool((s as NSString).boolValue)
            }
        case .number:
            // Whichever numeric case the registry default uses is the one the
            // device was always meant to see.
            switch spec.value {
            case .double:
                switch self {
                case .int(let i): return .double(Double(i))
                case .double(let d): return .double(d)
                case .bool(let b): return .double(b ? 1 : 0)
                case .string(let s): return .double(Double(s) ?? 0)
                }
            default:
                switch self {
                case .int(let i): return .int(i)
                case .double(let d): return d == d.rounded() ? .int(Int(d)) : .double(d)
                case .bool(let b): return .int(b ? 1 : 0)
                case .string(let s):
                    if let i = Int(s) { return .int(i) }
                    if let d = Double(s) { return .double(d) }
                    return .int(0)
                }
            }
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
    func isCompatible(deviceVersion: String, isIPhone: Bool) -> Bool {
        if disabled { return false }
        if !deviceVersion.isEmpty {
            if let minVersion,
               let cmp = TweakVersion.compare(deviceVersion, minVersion), cmp < 0 { return false }
            if let maxVersion,
               let cmp = TweakVersion.compare(deviceVersion, maxVersion), cmp > 0 { return false }
        }
        if ipadOnly && isIPhone { return false }
        if iphoneOnly && !isIPhone { return false }
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
        return .int(Int(clamped.rounded()))
    }

    /// The units line under a `.number` editor.
    var numberHint: String {
        let integral = step == step.rounded() && (minValue == minValue.rounded())
        return "\(minValue)–\(maxValue), step \(step)" + (integral ? "" : " (decimal)")
    }
}

/// The live selection: which specs are on, and with what value.
///
/// Mirrors the reference's runtime `tweaks` dict of `Tweak` objects.  A spec
/// starts *off* at its registry default, exactly as `Tweak.__init__` leaves
/// `enabled = False`, and editing a value turns it on — the reference's
/// `Tweak.set_value(..., toggle_enabled: True)`.
struct TweakSelection: Equatable {
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
        if on { enabled.insert(spec.id) } else { enabled.remove(spec.id) }
    }

    /// Set a value and switch the tweak on, like `Tweak.set_value`.
    mutating func setValue(_ value: TweakValue, for spec: TweakSpec) {
        values[spec.id] = value
        enabled.insert(spec.id)
    }

    mutating func removeValue(for spec: TweakSpec) {
        values.removeValue(forKey: spec.id)
        multiOverrides.removeValue(forKey: spec.id)
    }

    mutating func removeAll() {
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
        if enabled { self.enabled.insert(spec.id) } else { self.enabled.remove(spec.id) }
        if let value { values[spec.id] = value } else { values.removeValue(forKey: spec.id) }
        if let multiValues { multiOverrides[spec.id] = multiValues }
        else { multiOverrides.removeValue(forKey: spec.id) }
    }

    var enabledCount: Int { enabled.count }
}
