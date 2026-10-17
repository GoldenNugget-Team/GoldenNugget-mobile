import Foundation

/// GoldenNugget's preset document — the file a user means by "autosave.json".
///
/// The reference saves the *AutoSave* preset (`src/cli/common.py:142`
/// `autosave_preset`) through the same path as any other preset, so the format
/// is GoldenNugget's preset v2 JSON, exactly:
///
///   * `src/controllers/preset_manager.py:313` `_serialize()` builds
///     `{"tweaks": {<TweakID name>: entry}}`;
///   * `:329` `_serialize_tweak()` gives each entry a `type` (the Python class
///     name) plus `enabled` and, per class, `value` / `templates` / `themes` /
///     `silly_mode` + `override_data`;
///   * `:129` `save_preset()` adds `metadata` with `version` 2 (and
///     `description` / `device_model` / `ios_version` / timestamps / `tags`);
///   * `:185` `export_preset()` / `:213` `build_export_data()` add `exported` +
///     `exported_at`, and a partial export adds `metadata.partial` +
///     `metadata.included`.
///
/// `PosterBoard` is already absent from a saved preset — the reference drops it
/// on the way out (`_serialize`: "wallpapers are device-specific and heavy, so
/// they must not travel with a preset") and ignores it on the way in.
struct GoldenNuggetPreset {
    struct Entry {
        let id: String
        /// The reference's Python class name for this tweak.
        let type: String
        let enabled: Bool
        /// A single plist value (`BasicPlistTweak`) or a nested dict
        /// (`AdvancedPlistTweak`).  nil when the entry carries neither.
        let value: TweakValue?
        let multiValues: [String: TweakValue]?
        /// Entry fields this port has no home for (a posterboard `templates`
        /// list, a status bar `override_data`, …).  Reported, never guessed at.
        let ignoredPayloadKeys: [String]
    }

    struct Metadata {
        let version: Int?
        let description: String
        let deviceModel: String
        let iosVersion: String
        let exported: Bool
        let partial: Bool
        let included: [String]
        let tags: [String]

        /// One line for the log, in the reference's own vocabulary.
        var summary: String {
            var parts = ["preset v\(version.map(String.init) ?? "?")"]
            if !description.isEmpty { parts.append("\"\(description)\"") }
            if !iosVersion.isEmpty && iosVersion != "Unknown" { parts.append("iOS \(iosVersion)") }
            if !deviceModel.isEmpty && deviceModel != "Unknown" { parts.append(deviceModel) }
            if exported { parts.append("exported") }
            if partial { parts.append("partial (\(included.count) tweaks)") }
            if !tags.isEmpty { parts.append("tags: \(tags.joined(separator: ","))") }
            return parts.joined(separator: ", ")
        }
    }

    let metadata: Metadata
    let entries: [Entry]

    /// Parse a preset document.  Throws `GoldenNuggetError` when the JSON is not a
    /// preset at all — the same "Invalid preset format" gate the reference's
    /// `import_preset` applies (a document with neither `tweaks` nor `metadata`
    /// is not one).
    static func parse(_ data: Data) throws -> GoldenNuggetPreset {
        let root: Any
        do {
            root = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw GoldenNuggetError("autosave.json: not valid JSON (\(error.localizedDescription))")
        }
        guard let object = root as? [String: Any] else {
            throw GoldenNuggetError("autosave.json: top level is not a JSON object")
        }
        guard object["tweaks"] != nil || object["metadata"] != nil else {
            throw GoldenNuggetError("autosave.json: no \"tweaks\" or \"metadata\" — not a GoldenNugget preset")
        }

        return GoldenNuggetPreset(metadata: parseMetadata(object["metadata"]),
                                  entries: parseEntries(object["tweaks"]))
    }

    private static func parseMetadata(_ raw: Any?) -> Metadata {
        let dict = raw as? [String: Any] ?? [:]
        return Metadata(version: (dict["version"] as? NSNumber)?.intValue,
                        description: dict["description"] as? String ?? "",
                        deviceModel: dict["device_model"] as? String ?? "",
                        iosVersion: dict["ios_version"] as? String ?? "",
                        exported: boolValue(dict["exported"]) ?? false,
                        partial: boolValue(dict["partial"]) ?? false,
                        included: dict["included"] as? [String] ?? [],
                        tags: dict["tags"] as? [String] ?? [])
    }

    private static func parseEntries(_ raw: Any?) -> [Entry] {
        guard let dict = raw as? [String: Any] else { return [] }
        // Sorted for a stable report; `_apply` iterates a dict but the order has
        // no effect — every entry lands in its own spec slot.
        return dict.keys.sorted().compactMap { key in
            let entry = dict[key] as? [String: Any] ?? [:]
            let value = entry["value"]
            var multi: [String: TweakValue]?
            if let nested = value as? [String: Any] {
                multi = nested.compactMapValues(tweakValue)
            }
            let consumed: Set<String> = ["type", "enabled", "value"]
            return Entry(id: key,
                         type: entry["type"] as? String ?? "?",
                         enabled: boolValue(entry["enabled"]) ?? false,
                         value: value.flatMap(tweakValue),
                         multiValues: multi,
                         ignoredPayloadKeys: entry.keys.filter { !consumed.contains($0) }.sorted())
        }
    }

    /// A JSON scalar as a `TweakValue`.
    ///
    /// `NSNumber(1) as? Bool` succeeds in Swift, so the boolean case cannot be
    /// decided by casting — the JSON parser's own type has to be asked for.
    private static func tweakValue(_ any: Any) -> TweakValue? {
        if let string = any as? String { return .string(string) }
        if let number = any as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
            let double = number.doubleValue
            if double == double.rounded(), abs(double) < 1e15 { return .int(number.intValue) }
            return .double(double)
        }
        return nil
    }

    private static func boolValue(_ any: Any?) -> Bool? {
        guard let number = any as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }
}

/// What one import did, entry by entry.
struct TweakImportReport {
    var applied: [String] = []
    var skippedUnported: [(id: String, reason: String)] = []
    var skippedIncompatible: [String] = []
    var skippedUnknown: [String] = []
    var ignoredPayload: [(id: String, keys: [String])] = []
    var metadataLine: String = ""

    /// The block written into the run log.
    var logLines: [String] {
        var out: [String] = []
        out.append("autosave.json import: \(metadataLine)")
        out.append("  applied \(applied.count) tweak(s): \(applied.isEmpty ? "(none)" : applied.joined(separator: ", "))")
        let unsupported = skippedUnported.map { "\($0.id) — \($0.reason)" }
        if !unsupported.isEmpty {
            out.append("  not part of this port (\(unsupported.count)): \(unsupported.joined(separator: "; "))")
        }
        if !skippedIncompatible.isEmpty {
            out.append("  switched off — not compatible with this device/OS: "
                + skippedIncompatible.joined(separator: ", "))
        }
        if !skippedUnknown.isEmpty {
            out.append("  unknown tweak ids (ignored, like the reference): "
                + skippedUnknown.joined(separator: ", "))
        }
        for item in ignoredPayload {
            out.append("  note: \(item.id) carries \(item.keys.joined(separator: ", ")) — "
                + "not representable here, ignored")
        }
        return out
    }
}

/// Applies a parsed preset to a selection.
///
/// The port of `PresetManager._apply` (`src/controllers/preset_manager.py:354`)
/// for the tweak classes this port covers: resolve the entry by `TweakID` name,
/// skip what the reference skips, and take `enabled` + `value` as stated.
///
/// **Documented divergence**: the reference does not re-check the registry's
/// compatibility bounds on load — its *apply* pass would carry an incompatible
/// tweak if a preset switched it on, even though the UI hides it.  This port
/// declines to enable an incompatible tweak and says so in the report, so a
/// shared preset cannot turn on something the UI would never show.
enum GoldenNuggetPresetImport {
    /// The reference tweaks whose feature a preset cannot carry, with the reason,
    /// so an import says *why* rather than just dropping them.
    ///
    /// `PosterBoard` is on this list for a reason that has nothing to do with
    /// this port: the reference itself refuses to serialise wallpapers
    /// ("device-specific and heavy, so they must not travel with a preset"), so
    /// there is nothing in a preset to carry.  The feature *is* ported — it lives
    /// on the PosterBoard page, and the page is where a wallpaper is chosen.
    static let unported: [String: String] = [
        "PosterBoard": "wallpapers — the reference excludes them from presets; "
            + "use the PosterBoard page instead",
        "Templates": "PosterBoard templates — needs the template asset store",
        "StatusBar": "Status Bar — needs the StatusBarOverrideData struct over CFFI",
        "IconThemes": "Icon Themes — needs the icon asset store",
        "ClearScreenTimeAgentPlist": "daemons page — a NullifyFileTweak writing a 0-byte plist",
    ]

    /// Desktop presets carry daemons as one entry: `Daemons` with a `value` dict
    /// mapping every launchd label to whether it is disabled. The port models one
    /// spec per group instead, so the labels are folded back up into groups --
    /// a group is on when the reference would have written all of its labels.
    ///
    /// Labels outside `INTERFACE_KEYS` are dropped, which is the whitelist
    /// upstream enforces before a preset or the apply pass ever sees them.
    private static func applyDaemons(_ entry: GoldenNuggetPreset.Entry,
                                     to selection: inout TweakSelection) {
        guard let values = entry.multiValues ?? entry.value.map({ [$0.display: $0] }) else {
            return
        }
        for group in DaemonGroups.all {
            let wanted = group.labels.filter { label in
                guard DaemonGroups.allowedKeys.contains(label) else { return false }
                return values[label]?.display == "true"
            }
            // A group whose labels are all disabled is on. A group with none is
            // left off rather than forced off, so a partial preset does not
            // clear a choice the user made by hand.
            if wanted.count == group.labels.count, let spec = TweakCatalog.byID["Daemon.\(group.name)"] {
                selection.restore(enabled: true, value: nil, multiValues: nil, for: spec)
            }
        }
    }

    @discardableResult
    static func apply(_ preset: GoldenNuggetPreset,
                      to selection: inout TweakSelection,
                      deviceVersion: String,
                      isIPhone: Bool) -> TweakImportReport {
        var report = TweakImportReport()
        report.metadataLine = preset.metadata.summary

        for entry in preset.entries {
            // Daemons is not a registry spec: it is one upstream entry covering
            // every label, and the port carries a spec per group.
            if entry.id == "Daemons" {
                applyDaemons(entry, to: &selection)
                report.applied.append(entry.id)
                continue
            }
            guard let spec = TweakCatalog.byID[entry.id] else {
                if let reason = unported[entry.id] {
                    report.skippedUnported.append((entry.id, reason))
                } else {
                    report.skippedUnknown.append(entry.id)
                }
                continue
            }
            guard spec.isCompatible(deviceVersion: deviceVersion, isIPhone: isIPhone) else {
                report.skippedIncompatible.append(entry.id)
                continue
            }
            if !entry.ignoredPayloadKeys.isEmpty {
                report.ignoredPayload.append((entry.id, entry.ignoredPayloadKeys))
            }

            let value = entry.value.map { $0.coerced(to: spec) }
            let multi = spec.writesWholeDict ? entry.multiValues : nil
            selection.restore(enabled: entry.enabled, value: value,
                              multiValues: multi, for: spec)
            report.applied.append(entry.id)
        }
        return report
    }
}
