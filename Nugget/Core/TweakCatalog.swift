// GENERATED FILE — do not edit by hand.
//
// Source of truth: GoldenNugget's `src/tweaks/registry.py` (the tweak
// spec table) and `src/tweaks/basic_plist_locations.py` (the
// `FileLocation` enum).  Regenerate with:
//
//     scripts/gen-tweaks-from-goldennugget.py [--goldennugget <path>]
//
// The port is a generation, not a retype: the table is emitted from
// the reference module itself, so a tweak added upstream appears here
// without a hand edit and a spec cannot silently drift from the source.
// The rows themselves live in the `TweakCatalog+RegistryN.swift` chunks;
// this file carries the enums and the assembly.

import Foundation

/// An absolute device path a tweak writes to.
///
/// Ported from GoldenNugget's `FileLocation` enum; the raw value is the
/// absolute path, and `TweakDomainMap` turns it into the
/// `(backup domain, relative path)` pair a restorable row needs.
enum TweakFileLocation: String, CaseIterable, Sendable {
    case featureflags = "/var/preferences/FeatureFlags/Global.plist"
    case ota = "/var/Managed Preferences/mobile/com.apple.MobileAsset.plist"
    case springboard = "/var/Managed Preferences/mobile/com.apple.springboard.plist"
    case springboardPreferencesHomeDomain = "/var/mobile/Library/Preferences/com.apple.springboard.plist"
    case footnote = "/var/containers/Shared/SystemGroup/systemgroup.com.apple.configurationprofiles/Library/ConfigurationProfiles/SharedDeviceConfiguration.plist"
    case airdrop = "/var/Managed Preferences/mobile/com.apple.sharingd.plist"
    case nanoregistry = "/var/mobile/Library/Preferences/com.apple.NanoRegistry.plist"
    case chronod = "/var/Managed Preferences/mobile/com.apple.chronod.plist"
    case ambient = "/var/Managed Preferences/mobile/com.apple.ambient.plist"
    case statusBarOverridesArchive = "/var/mobile/Library/SpringBoard/StatusBarOverrides.archive"
    case accessibility = "/var/Managed Preferences/mobile/com.apple.Accessibility.plist"
    case siriAIOverrides = "/var/containers/Data/SystemGroup/com.apple.eligibilityd/Library/Caches/NeverRestore/eligibility_overrides.data"
    case globalPreferences = "/var/Managed Preferences/mobile/.GlobalPreferences.plist"
    case globalPreferencesHomeDomain = "/var/mobile/Library/Preferences/.GlobalPreferences.plist"
    case appStore = "/var/Managed Preferences/mobile/com.apple.AppStore.plist"
    case backboardd = "/var/Managed Preferences/mobile/com.apple.backboardd.plist"
    case coreMotion = "/var/Managed Preferences/mobile/com.apple.CoreMotion.plist"
    case pasteboard = "/var/Managed Preferences/mobile/com.apple.Pasteboard.plist"
    case notes = "/var/Managed Preferences/mobile/com.apple.mobilenotes.plist"
    case keyboardPreferences = "/var/Managed Preferences/mobile/com.apple.keyboard.preferences.plist"
    case uikit = "/var/Managed Preferences/mobile/com.apple.UIKit.plist"
    case swiftui = "/var/Managed Preferences/mobile/com.apple.SwiftUI.plist"
    case disabledDaemons = "/var/db/com.apple.xpc.launchd/disabled.plist"
    case screentime = "/var/mobile/Library/Preferences/com.apple.ScreenTimeAgent.plist"
    case chronodPreferencesHomeDomain = "/var/mobile/Library/Preferences/com.apple.chronod.plist"
    case prototypeToolsPreferencesHomeDomain = "/var/mobile/Library/Preferences/com.apple.PrototypeTools.plist"
    case uikitPreferencesHomeDomain = "/var/mobile/Library/Preferences/com.apple.UIKit.plist"
    case carrierBundleOverlay = "/var/mobile/Library/Carrier Bundles/Overlay"
    case keyboardPreferencesHomeDomain = "/var/mobile/Library/Preferences/com.apple.keyboard.preferences.plist"
    case keyboardContinuousPath = "/var/mobile/Library/Preferences/com.apple.keyboard.ContinuousPath.plist"
    case locationPreferencesHomeDomain = "/var/mobile/Library/Preferences/com.apple.locationd.plist"
    case swiftuiPreferencesHomeDomain = "/var/mobile/Library/Preferences/com.apple.SwiftUI.plist"
    case accessibilityPreferencesHomeDomain = "/var/mobile/Library/Preferences/com.apple.Accessibility.plist"
    case applicationAccess = "/var/Managed Preferences/mobile/com.apple.applicationaccess.plist"
    case celestialPreferencesHomeDomain = "/var/mobile/Library/Preferences/com.apple.celestial.plist"
    case mobilecalPreferencesHomeDomain = "/var/mobile/Library/Preferences/com.apple.mobilecal.plist"
    case apsPreferencesHomeDomain = "/var/mobile/Library/Preferences/com.apple.apsd.plist"
    case avatarPreferencesHomeDomain = "/var/mobile/Library/Preferences/com.apple.AvatarUI.Staryu.plist"
    case suggestionsPreferencesHomeDomain = "/var/mobile/Library/Preferences/com.apple.suggestions.plist"
    case locationStatusBarPreferencesHomeDomain = "/var/mobile/Library/Preferences/com.apple.locationd.StatusBarIconManager.plist"
    case preferencesHomeDomain = "/var/mobile/Library/Preferences/com.apple.Preferences.plist"
    case imdPersistencePreferencesHomeDomain = "/var/mobile/Library/Preferences/com.apple.imdpersistence.IMDPersistenceAgent.plist"
    case diagnosticExtensionTracker = "/var/mobile/Library/Preferences/com.apple.DiagnosticExtensions.extensionTracker.plist"
    case spotlightUIPreferencesHomeDomain = "/var/mobile/Library/Preferences/com.apple.spotlightui.plist"
    case adPlatformsPreferencesHomeDomain = "/var/mobile/Library/Preferences/com.apple.AdPlatforms.plist"
    case itunesstoredPreferencesHomeDomain = "/var/mobile/Library/Preferences/com.apple.itunesstored.plist"
    case coreSpotlightUIPreferencesHomeDomain = "/var/mobile/Library/Preferences/com.apple.corespotlightui.plist"
    case backgroundSystemTaskPreferencesHomeDomain = "/var/mobile/Library/Preferences/com.apple.bg.system.task.plist"
    case none = ""
}

/// A tweaks-page section.  Raw values match GoldenNugget's `Section` enum.
enum TweakSection: String, CaseIterable, Identifiable, Sendable {
    case posterBoard = "PosterBoard"
    case liquidGlass = "Liquid Glass"
    case springboard = "SpringBoard"
    case internalOptions = "Internal Options"
    case daemons = "Daemons to Disable"
    var id: String { rawValue }
}

/// The UI editor a spec wants.  Matches GoldenNugget's `Kind` enum.
enum TweakKind: Sendable {
    case toggle
    case text
    case number
    /// Edits fields inside the wallpaper archives a restore already
    /// carries (`PosterKitOverrides`).  Staged by the engine, not here.
    case posterArchive
    /// Writes a wallpaper dictionary into SpringBoard preferences.
    case wallpaper
    /// A single wallpaper feature flag.  No registry spec uses this yet;
    /// the case keeps the port's enum in lockstep with the reference's.
    case posterFlag
}

/// Every registry-defined tweak, in the reference's own order.
///
/// Iteration order is load-bearing: the compiler merges several tweaks into
/// one plist, and GoldenNugget iterates `tweaks` in this same order, so a
/// later key wins exactly as it does upstream.  Do not sort this array.
enum TweakCatalog {
    static let all: [TweakSpec] = registry0 + registry1 + registry2 + registry3 + registry4 + registry5 + registry6 + registry7 + registry8 + registry9

    /// The daemon groups, appended after the registry rows.  They are not in
    /// `registry.py` upstream -- `gen-daemons-from-goldennugget.py` emits them
    /// from `daemons_tweak.py` -- and they are last so every registry key still
    /// merges into a shared plist before any daemon label does.
    static let allWithDaemons: [TweakSpec] = all + daemonSpecs + [screenTimeSpec]

    static let byID: [String: TweakSpec] =
        Dictionary(uniqueKeysWithValues: allWithDaemons.map { ($0.id, $0) })

    static func inSection(_ section: TweakSection) -> [TweakSpec] {
        all.filter { $0.section == section }
    }
}


extension TweakCatalog {
    static let siriAIArchives: [String: Data] = [
        "SiriAI": Data(base64Encoded: "YnBsaXN0MDDUAQIDBAUGBwpYJHZlcnNpb25ZJGFyY2hpdmVyVCR0b3BYJG9iamVjdHMSAAGGoF8QD05TS2V5ZWRBcmNoaXZlctEICVRyb290gAGvEBALDBEdHh8gJCUsLzQ6Ozw/VSRudWxs0g0ODxBbb3ZlcnJpZGVNYXBWJGNsYXNzgAKAD9MSEw4UGBxXTlMua2V5c1pOUy5vYmplY3RzoxUWF4ADgASABaMZGhuABoAJgAqADhB6EJsQYNIhDiIjVmFuc3dlcoAHgAgQBNImJygpWiRjbGFzc25hbWVYJGNsYXNzZXNfEBdFbGlnaWJpbGl0eU92ZXJyaWRlRGF0YaIqK18QF0VsaWdpYmlsaXR5T3ZlcnJpZGVEYXRhWE5TT2JqZWN00iEOIiOAB4AI0yEwDiIyI1djb250ZXh0gAeAC4AI0xITDjU3HKE2gAyhOIANgA5fECtPU19FTElHSUJJTElUWV9DT05URVhUX0xJTldPT0RfQVZBSUxBQklMSVRZEALSJic9PlxOU0RpY3Rpb25hcnmiPSvSJidAQV8QE0VsaWdpYmlsaXR5T3ZlcnJpZGWiQitfEBNFbGlnaWJpbGl0eU92ZXJyaWRlAAgAEQAaACQAKQAyADcASQBMAFEAUwBmAGwAcQB9AIQAhgCIAI8AlwCiAKYAqACqAKwAsACyALQAtgC4ALoAvAC+AMMAygDMAM4A0ADVAOAA6QEDAQYBIAEpAS4BMAEyATkBQQFDAUUBRwFOAVABUgFUAVYBWAGGAYgBjQGaAZ0BogG4AbsAAAAAAAACAQAAAAAAAABDAAAAAAAAAAAAAAAAAAAB0Q==")!,
        "ResetSiriAIOverrides": Data(base64Encoded: "YnBsaXN0MDDUAQIDBAUGBwpYJHZlcnNpb25ZJGFyY2hpdmVyVCR0b3BYJG9iamVjdHMSAAGGoF8QD05TS2V5ZWRBcmNoaXZlctEICVRyb290gAGlCwwRFx1VJG51bGzSDQ4PEFtvdmVycmlkZU1hcFYkY2xhc3OAAoAE0xITDhQVFldOUy5rZXlzWk5TLm9iamVjdHOgoIAD0hgZGhtaJGNsYXNzbmFtZVgkY2xhc3Nlc1xOU0RpY3Rpb25hcnmiGhxYTlNPYmplY3TSGBkeH18QE0VsaWdpYmlsaXR5T3ZlcnJpZGWiIBxfEBNFbGlnaWJpbGl0eU92ZXJyaWRlCBEaJCkyN0lMUVNZX2Rwd3l7goqVlpeZnqmyv8LL0ObpAAAAAAAAAQEAAAAAAAAAIQAAAAAAAAAAAAAAAAAAAP8=")!,
    ]

    /// `siri_ai.HASHES` — sha256 of each embedded archive, verbatim.
    static let siriAIHashes: [String: String] = [
        "SiriAI": "4290e93faf86fd4f0d38364d2bb67398d9acb77f637555790c3339ad44f64d17",
        "ResetSiriAIOverrides": "f9b394804d478874f40eedcade937ab1d4a73773b4c8ed018ce51fb407a00818",
    ]
}

/// Device capabilities generated from desktop device_capabilities.py.
enum TweakDeviceCapabilities {
    static func hasDynamicIsland(_ model: String) -> Bool {
        let models: Set<String> = [
            "iPhone15,2",
            "iPhone15,3",
            "iPhone15,4",
            "iPhone15,5",
            "iPhone16,1",
            "iPhone16,2",
            "iPhone17,1",
            "iPhone17,2",
            "iPhone17,3",
            "iPhone17,4",
            "iPhone18,1",
            "iPhone18,2",
            "iPhone18,3",
            "iPhone18,4",
        ]
        return models.contains(model.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    static func hasCameraControl(_ model: String) -> Bool {
        let models: Set<String> = [
            "iPhone17,1",
            "iPhone17,2",
            "iPhone17,3",
            "iPhone17,4",
            "iPhone18,1",
            "iPhone18,2",
            "iPhone18,3",
            "iPhone18,4",
            "iPhone19,2",
            "iPhone19,3",
            "iPhone19,7",
        ]
        return models.contains(model.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    static func hasActionButton(_ model: String) -> Bool {
        let models: Set<String> = [
            "iPhone16,1",
            "iPhone16,2",
            "iPhone17,1",
            "iPhone17,2",
            "iPhone17,3",
            "iPhone17,4",
            "iPhone17,5",
            "iPhone18,1",
            "iPhone18,2",
            "iPhone18,3",
            "iPhone18,4",
            "iPhone18,5",
            "iPhone19,2",
            "iPhone19,3",
            "iPhone19,7",
        ]
        return models.contains(model.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    static func hasHomeButton(_ model: String) -> Bool {
        let models: Set<String> = [
            "iPad11,1",
            "iPad11,2",
            "iPad11,3",
            "iPad11,4",
            "iPad11,6",
            "iPad11,7",
            "iPad12,1",
            "iPad12,2",
            "iPad5,1",
            "iPad5,2",
            "iPad5,3",
            "iPad5,4",
            "iPad6,11",
            "iPad6,12",
            "iPad6,3",
            "iPad6,4",
            "iPad6,7",
            "iPad6,8",
            "iPad7,1",
            "iPad7,11",
            "iPad7,12",
            "iPad7,2",
            "iPad7,3",
            "iPad7,4",
            "iPad7,5",
            "iPad7,6",
            "iPhone10,1",
            "iPhone10,2",
            "iPhone10,4",
            "iPhone10,5",
            "iPhone12,8",
            "iPhone14,6",
            "iPhone8,1",
            "iPhone8,2",
            "iPhone8,4",
            "iPhone9,1",
            "iPhone9,2",
            "iPhone9,3",
            "iPhone9,4",
        ]
        return models.contains(model.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    static func hasAlwaysOn(_ model: String) -> Bool {
        let models: Set<String> = [
            "iPhone15,2",
            "iPhone15,3",
            "iPhone16,1",
            "iPhone16,2",
            "iPhone17,1",
            "iPhone17,2",
            "iPhone18,1",
            "iPhone18,2",
            "iPhone18,3",
            "iPhone18,4",
            "iPhone19,2",
            "iPhone19,3",
            "iPhone19,7",
        ]
        return models.contains(model.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
