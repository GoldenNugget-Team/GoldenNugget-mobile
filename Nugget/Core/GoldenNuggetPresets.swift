import Foundation

/// The preset store — the port of `src/controllers/preset_manager.py`'s storage
/// half onto this app's on-device filesystem.
///
/// The desktop keeps presets under
/// `QStandardPaths.AppDataLocation/GoldenNugget/Presets/<name>.json`; this app
/// owns the same folder inside its Documents (`GoldenNugget/Presets/`), which
/// the Files app shows.  Serialisation/deserialisation of the *document* itself
/// is `GoldenNuggetAutosave`'s job (the shared `document(for:)` builder lives
/// here so both the autosave and a user-named save emit the identical preset v2
/// shape); this file is the folder's bookkeeping: names, metadata, import
/// validation, and the internal `__LastApplied`/`__Rollback` snapshots.
enum GoldenNuggetPresets {
    /// `PRESETS_DIR_NAME` (`preset_manager.py:22`).
    static let directoryName = "Presets"
    /// Internal snapshot names (`main_window_mixins.py:1090`): the last
    /// *successful* apply, and the copy of it taken before the next one starts.
    static let lastAppliedName = "__LastApplied"
    static let rollbackName = "__Rollback"

    /// `…/Documents/GoldenNugget/Presets`.
    static var presetsDirectory: URL {
        directoryOverride ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GoldenNugget", isDirectory: true)
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    /// Test seam: point the store somewhere else (the regression harness keeps
    /// the real Documents folder untouched).  Never set in the app.
    static var directoryOverride: URL?

    /// `get_preset_path` — the file a name maps to, sanitized
    /// (`preset_manager.py:34`).
    static func fileURL(for name: String) -> URL {
        presetsDirectory.appendingPathComponent("\(sanitize(name)).json")
    }

    /// `_sanitize_name` — alphanumerics plus ` `, `_`, `-`, trimmed, falling
    /// back to `"Preset"` (`preset_manager.py:38`).  Note that parentheses are
    /// *not* preserved: the desktop's `"Base (2)"` derivation still writes
    /// `Base 2.json`, because every path goes through this filter again.
    static func sanitize(_ name: String) -> String {
        let safe = name.filter { $0.isLetter || $0.isNumber || " _-".contains($0) }
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return safe.isEmpty ? "Preset" : safe
    }

    /// Whether a name is one of the internal snapshots the manager page hides.
    static func isInternal(_ name: String) -> Bool { name.hasPrefix("__") }

    /// `list_presets` — every `.json` file in the folder, sorted by name
    /// (`preset_manager.py:42`).
    static func list() -> [String] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: presetsDirectory, includingPropertiesForKeys: nil) else { return [] }
        return files
            .filter { $0.pathExtension.lowercased() == "json" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }

    /// `get_preset_metadata` (`preset_manager.py:51`): the `metadata` block of
    /// one preset, or nil when the file is missing or unreadable.
    static func metadata(for name: String) -> [String: Any]? {
        guard let data = try? Data(contentsOf: fileURL(for: name)),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return root["metadata"] as? [String: Any]
    }

    /// `list_presets_with_metadata` (`preset_manager.py:111`): the folder's
    /// presets and the metadata the manager page shows, sorted by `updated_at`
    /// descending.  Internal snapshot names are filtered out by the caller
    /// (`isInternal`), not here — the rollback flow needs them by name.
    struct PresetInfo: Identifiable {
        let name: String
        let description: String
        let deviceModel: String
        let iosVersion: String
        let createdAt: Int
        let updatedAt: Int
        let tags: [String]
        let version: Int
        var id: String { name }
    }

    static func listWithMetadata() -> [PresetInfo] {
        list().compactMap { name in
            guard let meta = metadata(for: name) else { return nil }
            return PresetInfo(name: name,
                              description: meta["description"] as? String ?? "",
                              deviceModel: meta["device_model"] as? String ?? "Unknown",
                              iosVersion: meta["ios_version"] as? String ?? "Unknown",
                              createdAt: (meta["created_at"] as? NSNumber)?.intValue ?? 0,
                              updatedAt: (meta["updated_at"] as? NSNumber)?.intValue ?? 0,
                              tags: meta["tags"] as? [String] ?? [],
                              version: (meta["version"] as? NSNumber)?.intValue ?? 1)
        }
        .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Whether a preset file exists.
    static func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(for: name).path)
    }

    /// Parse one stored preset document (no apply side effects).
    static func load(_ name: String) -> GoldenNuggetPreset? {
        guard let data = try? Data(contentsOf: fileURL(for: name)) else { return nil }
        return try? GoldenNuggetPreset.parse(data)
    }

    /// `save_preset` (`preset_manager.py:129`): serialize the selection as a
    /// preset v2 document, preserving the existing `created_at` when the preset
    /// already exists.  Best-effort like every other write here.
    @discardableResult
    static func save(_ name: String, selection: TweakSelection,
                     deviceModel: String, iosVersion: String,
                     description: String = "", tags: [String] = []) -> Bool {
        do {
            try FileManager.default.createDirectory(at: presetsDirectory,
                                                    withIntermediateDirectories: true)
            let existing = (metadata(for: name)?["created_at"] as? NSNumber)?.intValue
            let data = try JSONSerialization.data(
                withJSONObject: document(for: selection,
                                         deviceModel: deviceModel,
                                         iosVersion: iosVersion,
                                         description: description,
                                         tags: tags,
                                         createdAt: existing),
                options: [.prettyPrinted, .sortedKeys])
            try data.write(to: fileURL(for: name), options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// `delete_preset` (`preset_manager.py:174`).
    @discardableResult
    static func delete(_ name: String) -> Bool {
        guard exists(name) else { return false }
        do {
            try FileManager.default.removeItem(at: fileURL(for: name))
            return true
        } catch {
            return false
        }
    }

    /// The preset v2 serializer, shared by the autosave and the manager.
    ///
    /// `_serialize` walks the live tweak registry and writes **every** spec, not
    /// just the enabled ones — that is what makes a round trip faithful
    /// (`preset_manager.py:363`).  `PosterBoard` is excluded for the reference's
    /// own reason ("wallpapers are device-specific and heavy").  `createdAt` is
    /// the original creation time when updating an existing preset; `updated_at`
    /// is always now.
    static func document(for selection: TweakSelection,
                         deviceModel: String,
                         iosVersion: String,
                         description: String,
                         tags: [String],
                         createdAt: Int?) -> [String: Any] {
        var tweaks: [String: Any] = [:]
        // allWithDaemons, not all: the daemons live in a separate catalog
        // collection, so iterating `all` would write a preset that silently
        // omitted every daemon group.
        for spec in TweakCatalog.allWithDaemons where spec.id != "PosterBoard" {
            var entry: [String: Any] = [
                // `type(tweak).__name__`.  A spec that writes a whole dict is
                // the reference's `AdvancedPlistTweak`, everything else is a
                // `BasicPlistTweak` (`tweak_classes.py:59`, `:115`).
                "type": spec.writesWholeDict ? "AdvancedPlistTweak" : "BasicPlistTweak",
                "enabled": selection.isOn(spec),
            ]
            if spec.writesWholeDict {
                // `AdvancedPlistTweak`: the dict of keys `apply_tweak` would
                // write, which is what `_filter_keys` keeps.
                var dict: [String: Any] = [:]
                for (key, value) in selection.multiValues(for: spec) ?? [:] {
                    dict[key] = value.plistObject
                }
                entry["value"] = dict
            } else {
                entry["value"] = selection.value(for: spec).plistObject
            }
            tweaks[spec.id] = entry
        }

        let now = Int(Date().timeIntervalSince1970)
        let metadata: [String: Any] = [
            "version": GoldenNuggetAutosave.presetVersion,
            "description": description,
            "device_model": deviceModel.isEmpty ? "Unknown" : deviceModel,
            "ios_version": iosVersion.isEmpty ? "Unknown" : iosVersion,
            "created_at": createdAt ?? now,
            "updated_at": now,
            "tags": tags,
        ]
        // `data["metadata"] = meta` in the reference, so metadata comes second.
        return ["tweaks": tweaks, "metadata": metadata]
    }

    // MARK: - Export / Import

    /// `export_preset`'s serialization half (`preset_manager.py:185`): the
    /// stored document plus the `exported` / `exported_at` markers.
    ///
    /// `include`, when given, is the `_filter_export` half (`:222`): keep only
    /// those `tweaks` entries and mark the metadata as a partial export.  A
    /// `nil` or empty set is a full export, exactly like the reference.
    static func exportData(for name: String, include: Set<String>? = nil) -> Data? {
        guard var root = (try? Data(contentsOf: fileURL(for: name)))
            .flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        else { return nil }
        root["exported"] = true
        root["exported_at"] = Int(Date().timeIntervalSince1970)
        if let include, !include.isEmpty {
            let tweaks = root["tweaks"] as? [String: Any] ?? [:]
            root["tweaks"] = tweaks.filter { include.contains($0.key) }
            var meta = root["metadata"] as? [String: Any] ?? [:]
            meta["partial"] = true
            meta["included"] = include.sorted()
            root["metadata"] = meta
        }
        return try? JSONSerialization.data(withJSONObject: root,
                                           options: [.prettyPrinted, .sortedKeys])
    }

    /// The tweak ids a stored preset carries, for the partial-export picker.
    /// Read from the parsed document rather than the live registry, so the list
    /// is what the file actually holds.
    static func tweakIDs(for name: String) -> [String] {
        guard let preset = load(name) else { return [] }
        return preset.entries.map(\.id).sorted()
    }

    /// `import_preset` (`preset_manager.py:266`): validate, pick a name
    /// (the explicit one, else `metadata.description`, else the file's base
    /// name), sanitize, and make it unique with a `" (n)"` suffix.
    /// Returns `(success, actual name or error message)`.
    static func importPreset(from url: URL, newName: String?) -> (Bool, String) {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return (false, "Cannot read the file as JSON.") }
        guard isValidImport(root) else {
            return (false, "Invalid preset file. Expected a tweak dictionary and valid preset metadata.")
        }

        var base = newName
        if base == nil || base?.isEmpty == true {
            let description = (root["metadata"] as? [String: Any])?["description"] as? String ?? ""
            base = description.isEmpty ? url.deletingPathExtension().lastPathComponent : description
        }
        let baseName = sanitize(base ?? "")
        var name = baseName
        var counter = 1
        while exists(name) {
            // The reference's f"{base_name} ({counter})"; the parentheses are
            // dropped again by `sanitize` on the way to the path, exactly as
            // `get_preset_path` does upstream.
            name = "\(baseName) (\(counter))"
            counter += 1
        }

        let now = Int(Date().timeIntervalSince1970)
        var incoming = root
        var meta = incoming["metadata"] as? [String: Any] ?? [:]
        meta["imported_at"] = now
        meta["updated_at"] = now
        if meta["created_at"] == nil { meta["created_at"] = now }
        incoming["metadata"] = meta

        do {
            try FileManager.default.createDirectory(at: presetsDirectory,
                                                    withIntermediateDirectories: true)
            let out = try JSONSerialization.data(withJSONObject: incoming,
                                                 options: [.prettyPrinted, .sortedKeys])
            try out.write(to: fileURL(for: name), options: .atomic)
            return (true, name)
        } catch {
            return (false, error.localizedDescription)
        }
    }

    /// `_valid_import_structure` (`preset_manager.py:313`): reject malformed
    /// containers before they can enter the preset list.  Old files without
    /// metadata and unknown tweak names remain supported; import stores
    /// selections only.
    static func isValidImport(_ root: Any) -> Bool {
        guard let data = root as? [String: Any],
              let tweaks = data["tweaks"] as? [String: Any]
        else { return false }
        // `data.get("metadata", {})`, but a present non-dict is a failure.
        let meta: [String: Any]
        if let present = data["metadata"] {
            guard let dict = present as? [String: Any] else { return false }
            meta = dict
        } else {
            meta = [:]
        }

        for key in ["description", "device_model", "ios_version"] {
            if let value = meta[key], !(value is String) { return false }
        }
        if let tags = meta["tags"] {
            guard let list = tags as? [Any], list.allSatisfy({ $0 is String }) else { return false }
        }
        for key in ["created_at", "updated_at", "version"] {
            if let value = meta[key], !(value is Int || value is Double) { return false }
        }

        for (name, rawEntry) in tweaks {
            guard let entry = rawEntry as? [String: Any] else { return false }
            if let enabled = entry["enabled"], !(enabled is Bool) { return false }
            // Daemons / whole-dict writers carry their keys in `value`.
            if (name == "Daemons" || entry["type"] as? String == "AdvancedPlistTweak"),
               let value = entry["value"], !(value is [String: Any]) { return false }
            if let templates = entry["templates"] {
                guard let list = templates as? [Any], list.allSatisfy({ $0 is String }) else { return false }
            }
            if let themes = entry["themes"] {
                guard let list = themes as? [Any],
                      list.allSatisfy({ theme in
                          guard let dict = theme as? [String: Any] else { return false }
                          return ["bundle_id", "display_name", "icon_path"].allSatisfy { key in
                              dict[key] == nil || dict[key] is String
                          }
                      }) else { return false }
            }
            if let overrideData = entry["override_data"] {
                guard let string = overrideData as? String,
                      Data(base64Encoded: string) != nil else { return false }
            }
        }
        return true
    }

    /// `preset_has_daemon_changes` (`preset_manager.py:63`): true if the preset
    /// enables the daemon modifications or turns on any individual daemon.
    /// The desktop stores daemons as one consolidated `"Daemons"` entry; this
    /// port's presets carry one `"Daemon.<group>"` entry per group, so both
    /// shapes are recognised.
    static func presetHasDaemonChanges(_ root: [String: Any]?) -> Bool {
        guard let root, let tweaks = root["tweaks"] as? [String: Any] else { return false }
        for (name, rawEntry) in tweaks {
            guard name == "Daemons" || name.hasPrefix("Daemon.") else { continue }
            guard let entry = rawEntry as? [String: Any] else { return false }
            if (entry["enabled"] as? Bool) == true { return true }
            if let values = entry["value"] as? [String: Any],
               values.values.contains(where: { ($0 as? NSNumber)?.doubleValue != 0 }) {
                return true
            }
        }
        return false
    }

    // MARK: - Rollback snapshots

    /// `_prepare_rollback_preset` (`main_window_mixins.py:1090`): before an
    /// apply, copy the last applied snapshot aside so a failed sibling apply can
    /// be rolled back to it.  Best-effort, verbatim.
    static func prepareRollback() {
        guard exists(lastAppliedName) else { return }
        do {
            let from = fileURL(for: lastAppliedName)
            let to = fileURL(for: rollbackName)
            try? FileManager.default.removeItem(at: to)
            try FileManager.default.copyItem(at: from, to: to)
        } catch {
            // Never throw: a missing rollback snapshot must not break an apply.
        }
    }

    /// `_save_last_applied_preset` (`main_window_mixins.py:1101`): record the
    /// selection that just applied successfully as the internal snapshot.
    @discardableResult
    static func saveLastApplied(selection: TweakSelection,
                                deviceModel: String,
                                iosVersion: String) -> Bool {
        save(lastAppliedName, selection: selection,
             deviceModel: deviceModel, iosVersion: iosVersion,
             description: "Internal rollback snapshot", tags: ["internal"])
    }

    /// Whether a previous successful apply is available to roll back to.
    static var hasRollback: Bool { exists(rollbackName) }

    /// The `__Rollback` snapshot, when one exists.
    static func loadRollback() -> GoldenNuggetPreset? { load(rollbackName) }
}

