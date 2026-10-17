import Foundation

/// One contradiction between two enabled plist writers, in apply order.
///
/// The port of the reference's `TweakConflict` dataclass
/// (`src/controllers/tweak_conflicts.py:12`) minus the Qt translation layer: the
/// ids are the registry ids (the reference's `TweakID`), and the description is
/// the reference's `description()` with each title resolved from the same
/// registry the two tweaks came from.
struct TweakConflict: Equatable, Identifiable {
    let first: String
    let second: String
    let reason: String

    var id: String { "\(first)+\(second)" }

    /// `"{0} + {1}: {2}"` with the registry's titles, as `description()` builds
    /// it (`tweak_conflicts.py:18`).
    var description: String {
        func title(_ id: String) -> String {
            TweakCatalog.byID[id]?.title ?? id
        }
        return "\(title(first)) + \(title(second)): \(reason)"
    }
}

/// Offline checks for contradictory plist selections — the `find_conflicts`
/// port, and deliberately not a device safety audit
/// (`src/controllers/tweak_conflicts.py:1`: the file's own first line).
///
/// The reference compares only enabled plist writers, in apply order.  Basic
/// tweaks (and companions) merge keys into their file; `AdvancedPlistTweak`
/// subclasses `BasicPlistTweak` (`tweak_classes.py:115`) so `isinstance`
/// admits it, and its `apply_tweak({})` delivers the whole location dict —
/// which is exactly what `spec.writesWholeDict` means here.  A
/// `NullifyFileTweak` (`ClearScreenTimeAgentPlist`) contributes `None` (a
/// 0-byte file over the plist).  Wallpaper/template generators and device
/// operations are never invoked.
enum TweakConflicts {
    /// Compare only the enabled, device-compatible specs, preserving their apply
    /// order — the `find_conflicts` port (`tweak_conflicts.py:27`), with the
    /// ``device_version``/`is_iphone` compatibility filter that `current_conflicts`
    /// applies (`:67`) substituted for the HotLoad half, which this port has no
    /// counterpart for.  `specs` is the iteration set — the harness passes
    /// hand-built specs the same way the reference test hands `find_conflicts` a
    /// hand-built dict; the app passes `TweakCatalog.allWithDaemons`.
    static func find(in selection: TweakSelection,
                     specs: [TweakSpec],
                     deviceVersion: String,
                     isIPhone: Bool) -> [TweakConflict] {
        // location → [(id, payload)], in first-write order.
        var writers: [TweakFileLocation: [(id: String, payload: [String: Any]?)]] = [:]
        var conflicts: [TweakConflict] = []

        for spec in specs where !spec.disabled {
            guard selection.isOn(spec) else { continue }
            // current_conflicts drops what HotLoad hides; the reference's UI
            // hides the same set.  This port never renders an incompatible tweak,
            // so filtering them here reports what the user can actually see.
            guard spec.isCompatible(deviceVersion: deviceVersion, isIPhone: isIPhone) else { continue }

            // `isinstance(tweak, NullifyFileTweak)` → None, else
            // `apply_tweak({})[file_location]`: a whole-dict writer contributes
            // its dict, a basic writer its one key.
            let payload: [String: Any]?
            if spec.id == TweakCatalog.screenTimeSpec.id {
                payload = nil
            } else if spec.writesWholeDict {
                payload = (selection.multiValues(for: spec) ?? [:]).mapValues(\.plistObject)
            } else {
                payload = [spec.key: selection.value(for: spec).plistObject]
            }

            let location = spec.location
            for prior in writers[location] ?? [] {
                let priorPayload = prior.payload
                var reason: String?
                if payload == nil || priorPayload == nil {
                    // `payload != old` with a None on either side: a nullified
                    // file colliding with real contents.  Both None is equal.
                    if payload != nil || priorPayload != nil {
                        reason = "One tweak clears a preferences file used by the other."
                    }
                } else if let p = payload, let o = priorPayload {
                    // Shared keys written with different values win the report;
                    // otherwise a whole-dict writer dropping keys the earlier
                    // tweak set is the "replaces" case.
                    let shared = Set(o.keys).intersection(p.keys)
                    if shared.contains(where: { !plistValueEquals(o[$0]! as Any, p[$0]! as Any) }) {
                        reason = "They write different values to the same setting."
                    } else if spec.writesWholeDict, !Set(o.keys).subtracting(p.keys).isEmpty {
                        reason = "The later tweak replaces settings written by the earlier one."
                    }
                }
                if let reason { conflicts.append(TweakConflict(first: prior.id, second: spec.id, reason: reason)) }
            }
            writers[location, default: []].append((spec.id, payload))
        }

        // The reference's tail case (`tweak_conflicts.py:60`): both forced
        // layout directions at once.
        if let rtl = byID("RTL", in: specs), let ltr = byID("LTR", in: specs),
           selection.isOn(rtl), selection.isOn(ltr),
           selection.value(for: rtl).isTruthy, selection.value(for: ltr).isTruthy {
            conflicts.append(TweakConflict(
                first: rtl.id, second: ltr.id,
                reason: "Both layout directions are forced at the same time. Select only one."))
        }
        return conflicts
    }

    /// The conflicts in the user's live selection — `current_conflicts`
    /// (`tweak_conflicts.py:63`), run against the whole catalog.
    static func current(in selection: TweakSelection,
                        deviceVersion: String,
                        isIPhone: Bool) -> [TweakConflict] {
        find(in: selection, specs: TweakCatalog.allWithDaemons,
             deviceVersion: deviceVersion, isIPhone: isIPhone)
    }

    private static func byID(_ id: String, in specs: [TweakSpec]) -> TweakSpec? {
        specs.first { $0.id == id }
    }

    /// `plistlib.dumps(_, sort_keys=True)` equality for two plist values.
    ///
    /// plistlib serialises an integer and a real differently (`<integer>` vs
    /// `<real>`), so `1` and `1.0` do **not** collide — the kind has to be part
    /// of the comparison, and the kind of a bridged `NSNumber` is
    /// `CFBooleanGetTypeID` / `CFNumberGetType`, not the static Swift type.
    private static func plistValueEquals(_ a: Any, _ b: Any) -> Bool {
        if let a = a as? Bool, let b = b as? Bool { return a == b }
        if let a = a as? NSNumber, let b = b as? NSNumber {
            let ka = numberKind(a), kb = numberKind(b)
            if ka != kb { return false }
            switch ka {
            case 0: return a.boolValue == b.boolValue
            case 1: return a.int64Value == b.int64Value
            default: return a.doubleValue == b.doubleValue
            }
        }
        if let a = a as? String, let b = b as? String { return a == b }
        if let a = a as? [String: Any], let b = b as? [String: Any] {
            guard a.count == b.count else { return false }
            return a.allSatisfy { key, value in
                b[key].map { plistValueEquals(value, $0) } ?? false
            }
        }
        if let a = a as? [Any], let b = b as? [Any] {
            guard a.count == b.count else { return false }
            return zip(a, b).allSatisfy { plistValueEquals($0, $1) }
        }
        return false
    }

    /// 0 = boolean, 1 = integral, 2 = real — the three shapes plistlib XML
    /// distinguishes.
    private static func numberKind(_ number: NSNumber) -> Int {
        if CFGetTypeID(number) == CFBooleanGetTypeID() { return 0 }
        switch CFNumberGetType(number) {
        case .floatType, .doubleType, .cgFloatType: return 2
        default: return 1
        }
    }
}

extension TweakValue {
    /// Python truthiness, which is what `tweak.value` is tested with when both
    /// forced layout directions are enabled (`tweak_conflicts.py:61`).
    var isTruthy: Bool {
        switch self {
        case .bool(let value): return value
        case .int(let value): return value != 0
        case .double(let value): return value != 0
        case .string(let value): return !value.isEmpty
        }
    }
}
