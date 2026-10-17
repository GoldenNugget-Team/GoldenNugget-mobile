import Foundation

/// The *AutoSave* preset, written and read back without the user doing anything.
///
/// The reference GUI keeps one preset that always holds the current tweak
/// configuration:
///
///   * every tweak change schedules a save, debounced by 500 ms
///     (`src/gui/main_window_mixins.py:321` `_on_tweak_changed` →
///     `QTimer.singleShot(500, self._save_autosave_preset)`);
///   * startup loads it back, preferring it over any manually-loaded preset
///     (`:296` `_load_last_preset`), and then **rewrites it immediately** so an
///     entry the current registry no longer carries is purged from disk instead
///     of lingering in the file forever;
///   * the write itself is `save_preset("AutoSave", "Automatic save of last
///     tweak configuration", tags=["auto"], device_model=…, ios_version=…)`
///     (`:329`), best-effort — a failure is swallowed, because losing an
///     autosave must never interrupt tweaking.
///
/// This is that pair, and the document is the reference's preset v2 JSON
/// (`preset_manager.py:129` `save_preset` + `:313` `_serialize` +
/// `:329` `_serialize_tweak`), so a file written here is one the desktop app
/// can load and vice versa.  The on-disk layout mirrors the desktop's too:
/// `QStandardPaths.AppDataLocation/GoldenNugget/Presets/AutoSave.json`
/// (`preset_manager.py:26` `presets_dir`, `:34` `get_preset_path`) lands in
/// `Documents/GoldenNugget/Presets/AutoSave.json`, which the Files app shows
/// because the bundle sets `UIFileSharingEnabled`.
enum GoldenNuggetAutosave {
    /// The preset name the desktop uses, and therefore the file name
    /// `get_preset_path` derives from it (`_sanitize_name` keeps alphanumerics,
    /// spaces, `_` and `-`).
    static let presetName = "AutoSave"
    /// `_save_autosave_preset`'s description argument, verbatim.
    static let description = "Automatic save of last tweak configuration"
    /// `_save_autosave_preset`'s `tags` argument, verbatim.
    static let tags = ["auto"]
    /// `PRESET_VERSION` (`preset_manager.py:23`).
    static let presetVersion = 2
    /// The reference's debounce window (`QTimer.singleShot(500, …)`).
    static let debounce: Duration = .milliseconds(500)

    // MARK: - Location

    /// `…/Documents/GoldenNugget/Presets/AutoSave.json`.
    static var fileURL: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents
            .appendingPathComponent("GoldenNugget", isDirectory: true)
            .appendingPathComponent("Presets", isDirectory: true)
            .appendingPathComponent("\(presetName).json")
    }

    /// Whether an autosave exists at all — the reference's
    /// `"AutoSave" in preset_manager.list_presets()`.
    static var exists: Bool { FileManager.default.fileExists(atPath: fileURL.path) }

    // MARK: - Read

    /// The stored autosave, or nil when there is none or it is unreadable.
    ///
    /// Best-effort like the reference's `load_preset`, which returns `False`
    /// rather than raising: a corrupt autosave must not keep the page from
    /// opening with registry defaults.
    static func load() -> GoldenNuggetPreset? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? GoldenNuggetPreset.parse(data)
    }

    /// Load the autosave into `selection`, then rewrite the file — the
    /// reference's startup pair (`_load_last_preset` loads and calls
    /// `_save_autosave_preset` right after).
    ///
    /// The rewrite is what makes the file converge: a tweak id this port does
    /// not carry, or cannot run on this device, is dropped from the document
    /// instead of being re-applied on every launch.
    ///
    /// - Returns: the import report when a file was read, nil when there was
    ///   none.  A missing autosave is not a failure — it is a first run.
    @discardableResult
    static func restore(into selection: inout TweakSelection,
                        identity: DeviceIdentity) -> TweakImportReport? {
        restore(into: &selection,
                deviceVersion: identity.version,
                deviceModel: identity.productType,
                isIPhone: identity.isIPhone)
    }

    /// `restore(into:identity:)` without the device wrapper, so the load/apply/
    /// purge cycle can be exercised without a live device.
    @discardableResult
    static func restore(into selection: inout TweakSelection,
                        deviceVersion: String,
                        deviceModel: String,
                        isIPhone: Bool) -> TweakImportReport? {
        guard let preset = load() else { return nil }
        let report = GoldenNuggetPresetImport.apply(preset, to: &selection,
                                                    deviceVersion: deviceVersion,
                                                    isIPhone: isIPhone)
        // Purge, exactly as the reference does after loading.
        save(selection, deviceModel: deviceModel, iosVersion: deviceVersion)
        return report
    }

    // MARK: - Write

    /// Write the current selection as the AutoSave preset.
    ///
    /// Best-effort, like `_save_autosave_preset`: returns whether the write
    /// landed and never throws, so a full disk cannot break a tweak toggle.
    @discardableResult
    static func save(_ selection: TweakSelection, identity: DeviceIdentity) -> Bool {
        save(selection, deviceModel: identity.productType, iosVersion: identity.version)
    }

    /// `save(_:identity:)` without the device wrapper.
    @discardableResult
    static func save(_ selection: TweakSelection, deviceModel: String, iosVersion: String) -> Bool {
        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: document(for: selection,
                                                                          deviceModel: deviceModel,
                                                                          iosVersion: iosVersion),
                                                  options: [.prettyPrinted, .sortedKeys])
            try data.write(to: fileURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// Delete the autosave.  Used by "clear all tweaks" so a cleared state is
    /// not resurrected from disk on the next launch.
    @discardableResult
    static func clear() -> Bool {
        guard exists else { return true }
        do {
            try FileManager.default.removeItem(at: fileURL)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Document

    /// The preset document, in the reference's own shape.
    ///
    /// `_serialize` walks the live `tweaks` dict and writes **every** registered
    /// tweak, not just the enabled ones — that is what makes a round trip
    /// faithful, because `_apply` restores `enabled` from each entry and an
    /// omitted tweak would keep whatever the registry left behind.  `PosterBoard`
    /// is excluded, for the reason the reference gives ("wallpapers are
    /// device-specific and heavy, so they must not travel with a preset").
    ///
    /// The body is the shared preset-v2 serializer, `GoldenNuggetPresets.document`
    /// — the autosave calls it with its fixed description/tags and the original
    /// creation time (the reference's `_save_autosave_preset` arguments and its
    /// "keep `created_at`" rule), exactly as `save_preset` would.
    static func document(for selection: TweakSelection,
                         deviceModel: String,
                         iosVersion: String) -> [String: Any] {
        GoldenNuggetPresets.document(for: selection,
                                     deviceModel: deviceModel,
                                     iosVersion: iosVersion,
                                     description: description,
                                     tags: tags,
                                     createdAt: existingCreatedAt())
    }

    /// The `created_at` already on disk, if any.
    private static func existingCreatedAt() -> Int? {
        guard let data = try? Data(contentsOf: fileURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let metadata = root["metadata"] as? [String: Any]
        else { return nil }
        return (metadata["created_at"] as? NSNumber)?.intValue
    }
}
