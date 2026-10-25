import Foundation

/// One file to deliver into the backup: the payload and where it belongs.
///
/// The Swift counterpart of the reference's `FileToRestore`.  That type carries
/// `contents` **or** `contents_path` — a `FileToRestore` is either bytes in
/// memory or a path to read — and the plist tweaks this port started with only
/// ever used the first half.  The second half is not optional any more:
/// GoldenNugget also builds `FileToRestore` for posterboard assets, where one
/// video wallpaper is a few hundred extracted JPEG frames plus the video
/// itself, and a container pack is a whole data-store snapshot.  Holding that
/// as `Data` would put all of it on the app heap, and the injector reads a
/// payload three times (write, size, digest).
///
/// So a payload is **either** in memory **or** on disk, never both, and every
/// consumer goes through `bytes()`/`byteCount` rather than touching `contents`
/// directly.
///
/// Owner/group are deliberately **not** carried here.  The reference stamps
/// every plist tweak with `Tweak.__init__`'s default `owner=501, group=501`,
/// but the device's own rows disagree per domain — the footnote row is `-2/-2`
/// while a `ManagedPreferencesDomain` row is `501/501`.  The row shape is the
/// device's contract, so it lives in `TweakRowProfile` (one place, measured)
/// and the compiler only says *what* to write.
struct TweakPayload: Equatable {
    let domain: String
    let relativePath: String
    /// The bytes, for a payload that fits in memory.  Empty when `source` is set.
    let contents: Data
    /// A file whose bytes are the payload, for one that does not.  Nil when
    /// `contents` is set.  The file has to still exist when the injector runs —
    /// the caller owns it, and this type never deletes it.
    let source: URL?
    let owner: Int?

    init(domain: String, relativePath: String, contents: Data, owner: Int? = nil) {
        self.domain = domain
        self.relativePath = TweakPayload.manifestPath(relativePath)
        self.contents = contents
        self.source = nil
        self.owner = owner
    }

    init(domain: String, relativePath: String, source: URL) {
        self.domain = domain
        self.relativePath = TweakPayload.manifestPath(relativePath)
        self.contents = Data()
        self.source = source
        self.owner = nil
    }

    /// A manifest row's `relativePath`, with no leading slash.
    ///
    /// Most producers get the shape for free: `TweakDomainMap.split` drops the
    /// `/var/mobile/` prefix and leaves `Library/SpringBoard/…`, which is what the
    /// device's own rows use (`ProtectiveBackup`'s prefixes are written the same
    /// way).  Two producers instead hand over a path that is *already*
    /// domain-relative and still carries the slash — the reference's
    /// `FileToRestore.restore_path` (`/Library/SpringBoard/StatusBarOverrides.archive`,
    /// from `status_bar_tweak.py`) reaches this port as
    /// `StatusBarMechanism.restorePath`, and PosterBoard's container walk starts
    /// from `restorePath: "/"`.
    ///
    /// The reference strips it at the boundary — `restore.py`:
    /// `rel = f.restore_path.lstrip("/")` — and a row that keeps the slash is what
    /// the device rejects with `MBErrorDomain/205 — File path is invalid:
    /// HomeDomain:/Library/SpringBoard/StatusBarOverrides.archive`.  The
    /// directory rows either producer builds are unaffected (splitting on "/"
    /// drops the empty leading component), so only the file row carried the bug.
    ///
    /// Normalised here, in the one type every payload is built through, so no
    /// producer can put the slash into a row.
    static func manifestPath(_ relativePath: String) -> String {
        var path = Substring(relativePath)
        while path.first == "/" { path = path.dropFirst() }
        return String(path)
    }

    var label: String { "\(domain)/\(relativePath)" }

    /// Where the bytes come from, for a log line.
    var origin: String { source?.lastPathComponent ?? "\(contents.count) B in memory" }

    /// The bytes, mapped rather than copied when they are on disk.
    ///
    /// `.mappedIfSafe` and not a plain read: the frames of a video wallpaper are
    /// written straight back out, and mapping lets the kernel hand the same
    /// pages over instead of the app holding a second copy of every one.
    func bytes() throws -> Data {
        guard let source else { return contents }
        do {
            return try Data(contentsOf: source, options: .mappedIfSafe)
        } catch {
            throw TweakPayloadUnavailable(payload: label,
                                          file: source.lastPathComponent,
                                          reason: error.localizedDescription)
        }
    }

    /// The payload's size without reading it.
    var byteCount: Int {
        guard let source else { return contents.count }
        let size = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return size
    }
}

/// A payload whose bytes are on disk and are no longer there.
///
/// Its own type rather than `GoldenNuggetError`, which lives in the engine: this
/// file is one of the five `scripts/tweak-port-diff.py` compiles for the host,
/// and the engine pulls in Minimuxer and SwiftUI, which that harness has no use
/// for.  The message is spelled the way the app's status line reads.
struct TweakPayloadUnavailable: Error, LocalizedError {
    let payload: String
    let file: String
    let reason: String

    var errorDescription: String? {
        "The payload for \(payload) is gone from disk (\(file)): \(reason)"
    }
}

/// Turns a tweak selection into the files a restore should carry.
///
/// A port of the *compile* half of `device_manager._apply_tweak_pass`
/// (`src/devicemanagement/device_manager.py:900-1024`): start with an empty
/// `FileLocation → plist` table, let every enabled tweak merge its key in, then
/// serialise each location once and map it to a backup domain.
///
/// The merge is the whole point, not an optimisation: all 98 Liquid Glass
/// tweaks write into the same `.GlobalPreferences.plist`, so emitting one file
/// per tweak would leave only the last one standing.
enum TweakCompiler {
    /// Desktop applies community plists first, then merges built-in keys over
    /// them. Whole-file collisions are rejected rather than sent twice.
    static func merging(community: [TweakPayload], builtIn: [TweakPayload], deviceVersion: String = "") throws -> [TweakPayload] {
        var result = community
        for payload in builtIn {
            if let index = result.firstIndex(where: { $0.domain == payload.domain && $0.relativePath == payload.relativePath }) {
                guard var values = try PropertyListSerialization.propertyList(from: result[index].bytes(), options: [], format: nil) as? [String: Any],
                      let overlay = try PropertyListSerialization.propertyList(from: payload.bytes(), options: [], format: nil) as? [String: Any] else {
                    throw TweakPayloadUnavailable(payload: payload.label, file: payload.relativePath, reason: "Conflicting community file write")
                }
                values.merge(overlay) { _, builtIn in builtIn }
                let data = try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)
                result[index] = TweakPayload(domain: payload.domain, relativePath: payload.relativePath, contents: data, owner: payload.owner)
            } else { result.append(payload) }
        }
        if (TweakVersion.compare(deviceVersion, "27") ?? -1) >= 0 {
            for payload in result where payload.domain == "ManagedPreferencesDomain" {
                guard let mirror = TweakDomainMap.managedPreferenceMirror("/var/Managed Preferences/" + payload.relativePath) else { continue }
                let hasExplicitMirror = community.contains { $0.domain == "HomeDomain" && $0.relativePath == mirror }
                let hasBuiltIn = builtIn.contains { $0.domain == payload.domain && $0.relativePath == payload.relativePath }
                if hasExplicitMirror && !hasBuiltIn { continue }
                let mirrored = TweakPayload(domain: "HomeDomain", relativePath: mirror, contents: try payload.bytes(), owner: 501)
                if let index = result.firstIndex(where: { $0.domain == "HomeDomain" && $0.relativePath == mirror }) {
                    result[index] = mirrored
                } else { result.append(mirrored) }
            }
        }
        return result
    }
    struct Result {
        let payloads: [TweakPayload]
        /// Locations that produced a file, in write order — for the log.
        let locations: [TweakFileLocation]
        /// Things that were switched on but delivered nothing, and why.
        let skipped: [(label: String, reason: String)]
    }

    /// - Parameters:
    ///   - deviceVersion: the device's `ProductVersion`, for the registry's
    ///     `min_version` / `max_version` bounds.  Empty skips those checks, the
    ///     way the reference's `if device_version and spec.min_version` does.
    ///   - isIPhone: `ProductType.hasPrefix("iPhone")`, for `iphone_only` /
    ///     `ipad_only`.
    static func compile(
        selection: TweakSelection,
        deviceVersion: String,
        isIPhone: Bool,
        deviceModel: String = ""
    ) -> Result {
        // Insertion-ordered, like Python's dict: the reference iterates
        // `basic_plists.items()` in first-write order and that is the order the
        // files reach the backup.
        var order: [TweakFileLocation] = []
        var plists: [TweakFileLocation: [String: Any]] = [:]
        // Locations to overwrite with a 0-byte file rather than a serialised
        // plist. Upstream's `NullifyFileTweak` does exactly that, and the
        // injector writes `contents` verbatim, so an empty payload is it.
        var nullified: [TweakFileLocation] = []
        var skipped: [(label: String, reason: String)] = []
        var archives: [TweakPayload] = []

        // Write explicit false values too: omitting the last switched-off group
        // would leave the previous disabled override on the device. Only catalog
        // labels can reach launchd, even if selection came from a legacy preset.
        if selection.daemonModificationsEnabled {
            var disabled: [String: Any] = Dictionary(uniqueKeysWithValues:
                DaemonGroups.allowedKeys.map { ($0, false) })
            for group in DaemonGroups.all {
                guard let spec = TweakCatalog.byID["Daemon.\(group.name)"], selection.isOn(spec) else { continue }
                let values = selection.multiOverrides[spec.id]
                for label in group.labels where DaemonGroups.allowedKeys.contains(label) {
                    disabled[label] = values?[label]?.coerced(to: spec).plistObject ?? true
                }
            }
            order.append(.disabledDaemons)
            plists[.disabledDaemons] = disabled
        }

        // `allWithDaemons`, not `all`: the daemon group specs are not registry
        // rows, and compiling only the registry would drop the launchd
        // `disabled.plist` entirely.
        for spec in TweakCatalog.allWithDaemons where !spec.disabled {
            if spec.location == .disabledDaemons { continue }
            if spec.section == .daemons && !selection.daemonModificationsEnabled { continue }
            guard selection.isOn(spec) || spec.reversibleBoolean || (spec.offValue != nil && selection.values[spec.id] != nil) else { continue }
            guard spec.isCompatible(deviceVersion: deviceVersion, isIPhone: isIPhone, deviceModel: deviceModel) else {
                if selection.isOn(spec) {
                    skipped.append((spec.id, "not compatible with this device / iOS version"))
                }
                continue
            }

            // Eligibility overrides are NSKeyedArchives, never preference dictionaries.
            if spec.factory == "SiriAITweak" {
                if selection.isOn(spec),
                   !selection.enabled.contains(spec.exclusiveWith ?? ""),
                   let data = TweakCatalog.siriAIArchives[spec.id],
                   let dest = TweakDomainMap.split(path: spec.location.rawValue) {
                    archives.append(TweakPayload(domain: dest.domain, relativePath: dest.relativePath,
                                                 contents: data, owner: 0))
                }
                continue
            }

            // An `AdvancedPlistTweak` (a spec with a factory) contributes the
            // whole location's dict; the single-key merge below is the other half
            // of the reference's two `apply_tweak` shapes.  The dict comes from
            // the selection so an imported preset's own dict wins over the
            // registry's, exactly as `_apply_tweak` overwrites `tweak.value`.
            //
            // Merged, not assigned. Upstream registers daemons as *one*
            // `AdvancedPlistTweak` whose value holds every label, so a second
            // spec writing the same location has never come up -- until the port
            // modelled one spec per daemon group, all writing
            // `/var/db/com.apple.xpc.launchd/disabled.plist`. Assigning here
            // would leave exactly one group's labels in the file. Key-level
            // precedence is unchanged: a later spec still wins a shared key.
            if spec.writesWholeDict, let multiValues = selection.multiValues(for: spec) {
                if plists[spec.location] == nil { order.append(spec.location) }
                var dict = plists[spec.location] ?? [:]
                for (key, value) in multiValues { dict[key] = value.plistObject }
                plists[spec.location] = dict
                continue
            }

            // `ClearScreenTimeAgentPlist` is a `NullifyFileTweak`: it writes a
            // 0-byte file over the ScreenTime plist instead of serialising one,
            // so it must not fall into the "no plist key" skip below.
            if spec.id == TweakCatalog.screenTimeSpec.id {
                if !nullified.contains(spec.location) { nullified.append(spec.location) }
                if !order.contains(spec.location) { order.append(spec.location) }
                continue
            }

            guard !spec.key.isEmpty else {
                skipped.append((spec.id, "registry entry has no plist key"))
                continue
            }
            if plists[spec.location] == nil { order.append(spec.location) }
            var dict = plists[spec.location] ?? [:]
            if let offValue = spec.offValue {
                dict[spec.key] = (selection.isOn(spec) ? spec.value : offValue).plistObject
            } else if spec.reversibleBoolean {
                dict[spec.key] = spec.integerBoolean ? (selection.isOn(spec) ? 1 : 0) as Any : selection.isOn(spec) as Any
            } else if spec.factory == "ResettableNumericPreferenceTweak" && selection.value(for: spec).display == "-1.0" {
                dict.removeValue(forKey: spec.key)
            } else if spec.factory == "OptionalBundlePreferenceTweak" && selection.value(for: spec).display.isEmpty {
                dict.removeValue(forKey: spec.key)
            } else {
                dict[spec.key] = selection.value(for: spec).plistObject
            }
            plists[spec.location] = dict
        }

        var payloads: [TweakPayload] = archives
        var emitted: [TweakFileLocation] = []

        for location in order {
            if nullified.contains(location) {
                guard let dest = TweakDomainMap.split(path: location.rawValue) else {
                    skipped.append((location.rawValue, "no backup-domain prefix matches this location"))
                    continue
                }
                payloads.append(TweakPayload(domain: dest.domain,
                                             relativePath: dest.relativePath,
                                             contents: Data()))
                emitted.append(location)
                continue
            }
            guard let plist = plists[location] else { continue }
            // Every `FileLocation` has a prefix rule in `TweakDomainMap`, so
            // this cannot fail for the ported catalog — but the reference
            // answers an unmapped path with `(path, "")` (a domain equal to the
            // absolute path), which would inject a row no device ever produced.
            // Refusing instead of reproducing that is deliberate.
            guard let dest = TweakDomainMap.split(path: location.rawValue) else {
                skipped.append((location.rawValue, "no backup-domain prefix matches this location"))
                continue
            }
            payloads.append(TweakPayload(domain: dest.domain,
                                         relativePath: dest.relativePath,
                                         contents: serialisePlist(plist)))
            if (TweakVersion.compare(deviceVersion, "27") ?? -1) >= 0,
               location != .globalPreferences,
               let mirror = TweakDomainMap.managedPreferenceMirror(location.rawValue) {
                payloads.append(TweakPayload(domain: "HomeDomain", relativePath: mirror,
                                             contents: serialisePlist(plist), owner: 501))
            }
            emitted.append(location)
        }

        // The reference mirrors `.GlobalPreferences.plist` into HomeDomain so a
        // tweak that reads it through the NSGlobalDomain search chain still sees
        // the values after the Phase 3 protective restore
        // (`device_manager.py:1005-1016`).
        //
        // **Deliberate divergence**: the reference writes that mirror
        // *unconditionally*, so a run that touches no GP key would write
        // `plistlib.dumps({})` over the device's real HomeDomain
        // `.GlobalPreferences.plist`.  This port writes the mirror only when
        // there is something to mirror — the stated intent ("also write it to
        // HomeDomain so tweaks that depend on it survive") is preserved, and an
        // empty dict is never used to overwrite a live file.
        if let gp = plists[.globalPreferences], !gp.isEmpty,
           let dest = TweakDomainMap.split(path: TweakFileLocation.globalPreferencesHomeDomain.rawValue) {
            payloads.append(TweakPayload(domain: dest.domain,
                                         relativePath: dest.relativePath,
                                         contents: serialisePlist(gp)))
            emitted.append(.globalPreferencesHomeDomain)
        }

        return Result(payloads: payloads, locations: emitted, skipped: skipped)
    }

    /// `plistlib.dumps(plist)` — XML, the reference's default format.
    ///
    /// Not private: the page reset writes plists too (`TweakReset`), and one
    /// writer for the port is the point of `docs/tweak-port.md` — two of these
    /// drifting apart is how a reset would start writing a format the apply
    /// path never produces.
    static func serialisePlist(_ plist: [String: Any]) -> Data {
        (try? PropertyListSerialization.data(fromPropertyList: plist,
                                             format: .xml, options: 0)) ?? Data()
    }
}
