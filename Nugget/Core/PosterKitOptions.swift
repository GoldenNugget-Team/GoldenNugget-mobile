// GENERATED FILE — do not edit by hand.
//
// Source of truth: GoldenNugget's `src/tweaks/posterboard/device_overrides.py`
// (the `OPTIONS` field list and the `FILES` archive-name map),
// `src/tweaks/posterboard/preference_controls.py` (clock fonts, numeric
// limits, presets) and `src/tweaks/posterboard/archive_editor.py` (the
// `FIELDS` scalar allowlist).  Regenerate with:
//
//     scripts/gen-posterkits-from-goldennugget.py [--goldennugget <path>]

import Foundation

/// Editor metadata for the PosterKit wallpaper-archive fields, ported from
/// the reference's own tables.  Defaults only seed the controls; a field is
/// written only when its Use switch is on (`device_overrides.OPTIONS`).
enum PosterKitOptions {
    struct Field: Sendable {
        /// The `"Group:path"` key the selection stores (`option_key`).
        let key: String
        /// The archive group the field belongs to (`FILES`).
        let group: String
        /// The field path inside the archive's object graph.
        let path: String
        let title: String
        let defaultValue: TweakValue
        /// The editor's numeric bounds, when the field is numeric.
        let limits: (lower: Double, upper: Double, step: Double)?
    }

    /// `device_overrides.FILES`: which archive each group edits inside a
    /// wallpaper version directory.
    static let files: [String: String] = [
        "Rendering": "versions/0/com.apple.posterkit.provider.instance.renderingConfiguration.plist",
        "Clock": "versions/0/com.apple.posterkit.provider.instance.titleStyleConfiguration.plist",
        "Home Screen": "versions/0/supplements/0/com.apple.posterkit.provider.supplementURL.homescreenConfiguration.plist",
    ]

    static let all: [Field] = [
        Field(key: "Clock:clockOpacity", group: "Clock", path: "clockOpacity",
              title: "Clock Opacity (Experimental)", defaultValue: .double(1.0),
              limits: (0, 1, 0.01)),
        Field(key: "Clock:titleContentStyle.frostLevel", group: "Clock", path: "titleContentStyle.frostLevel",
              title: "Clock Frost Level (Experimental)", defaultValue: .double(0.75),
              limits: (0, 1, 0.01)),
        Field(key: "Clock:titleContentStyle.preferredMaterialType", group: "Clock", path: "titleContentStyle.preferredMaterialType",
              title: "Clock Material Type (Experimental)", defaultValue: .int(0),
              limits: (0, 100000, 1)),
        Field(key: "Clock:adaptiveTimeConfigurations.DISPLAY_TYPE_EMBEDDED.adaptiveTimeHeightUserConfigured", group: "Clock", path: "adaptiveTimeConfigurations.DISPLAY_TYPE_EMBEDDED.adaptiveTimeHeightUserConfigured",
              title: "Embedded Display Custom Clock Height", defaultValue: .bool(false),
              limits: nil),
        Field(key: "Clock:adaptiveTimeConfigurations.DISPLAY_TYPE_EMBEDDED.preferredTimeMaxYPortrait", group: "Clock", path: "adaptiveTimeConfigurations.DISPLAY_TYPE_EMBEDDED.preferredTimeMaxYPortrait",
              title: "Adaptive Clock Maximum Y (Portrait)", defaultValue: .double(0.0),
              limits: (-100000, 100000, 0.001)),
        Field(key: "Clock:adaptiveTimeConfigurations.DISPLAY_TYPE_EMBEDDED.preferredTimeMaxYLandscape", group: "Clock", path: "adaptiveTimeConfigurations.DISPLAY_TYPE_EMBEDDED.preferredTimeMaxYLandscape",
              title: "Adaptive Clock Maximum Y (Landscape)", defaultValue: .double(0.0),
              limits: (-100000, 100000, 0.001)),
        Field(key: "Rendering:depthEffectDisabled", group: "Rendering", path: "depthEffectDisabled",
              title: "Disable Depth Effect", defaultValue: .bool(false),
              limits: nil),
        Field(key: "Rendering:motionEffectsDisabled", group: "Rendering", path: "motionEffectsDisabled",
              title: "Disable Wallpaper Motion", defaultValue: .bool(false),
              limits: nil),
        Field(key: "Clock:permanentCompactTimeEnabled", group: "Clock", path: "permanentCompactTimeEnabled",
              title: "Compact Clock", defaultValue: .bool(false),
              limits: nil),
        Field(key: "Clock:alternateDateEnabled", group: "Clock", path: "alternateDateEnabled",
              title: "Alternate Date", defaultValue: .bool(true),
              limits: nil),
        Field(key: "Clock:timeNumberingSystem", group: "Clock", path: "timeNumberingSystem",
              title: "Clock Numbering System (Experimental)", defaultValue: .string(""),
              limits: nil),
        Field(key: "Clock:contentsLuminence", group: "Clock", path: "contentsLuminence",
              title: "Clock Content Luminance", defaultValue: .double(0.5),
              limits: (0, 1, 0.01)),
        Field(key: "Clock:isAdaptiveTimeHeightUserConfigured", group: "Clock", path: "isAdaptiveTimeHeightUserConfigured",
              title: "Custom Adaptive Clock Height", defaultValue: .bool(false),
              limits: nil),
        Field(key: "Clock:preferredTimeMaxY", group: "Clock", path: "preferredTimeMaxY",
              title: "Clock Maximum Y (Portrait)", defaultValue: .double(0.0),
              limits: (-100000, 100000, 0.001)),
        Field(key: "Clock:preferredTimeMaxYLandscape", group: "Clock", path: "preferredTimeMaxYLandscape",
              title: "Clock Maximum Y (Landscape)", defaultValue: .double(0.0),
              limits: (-100000, 100000, 0.001)),
        Field(key: "Clock:preferredTitleAlignment", group: "Clock", path: "preferredTitleAlignment",
              title: "Clock Alignment", defaultValue: .int(0),
              limits: (0, 100000, 1)),
        Field(key: "Clock:preferredTitleLayout", group: "Clock", path: "preferredTitleLayout",
              title: "Clock Layout", defaultValue: .int(0),
              limits: (0, 100000, 1)),
        Field(key: "Clock:userConfigured", group: "Clock", path: "userConfigured",
              title: "Clock User Configured", defaultValue: .bool(false),
              limits: nil),
        Field(key: "Clock:timeFontConfiguration.isSystemItem", group: "Clock", path: "timeFontConfiguration.isSystemItem",
              title: "Clock System Font Item", defaultValue: .bool(false),
              limits: nil),
        Field(key: "Clock:timeFontConfiguration.timeFontIdentifier", group: "Clock", path: "timeFontConfiguration.timeFontIdentifier",
              title: "Clock Font Identifier", defaultValue: .string("PRTimeFontIdentifierSoft"),
              limits: nil),
        Field(key: "Clock:timeFontConfiguration.weight", group: "Clock", path: "timeFontConfiguration.weight",
              title: "Clock Font Weight", defaultValue: .double(640.0),
              limits: (0, 1000, 1)),
        Field(key: "Clock:titleColor.identifier", group: "Clock", path: "titleColor.identifier",
              title: "Clock Color Identifier", defaultValue: .string("vibrantMaterialColor"),
              limits: nil),
        Field(key: "Clock:titleColor.preferredStyle", group: "Clock", path: "titleColor.preferredStyle",
              title: "Clock Color Style", defaultValue: .int(2),
              limits: (0, 100000, 1)),
        Field(key: "Clock:titleColor.suggested", group: "Clock", path: "titleColor.suggested",
              title: "Clock Suggested Color", defaultValue: .bool(false),
              limits: nil),
        Field(key: "Home Screen:lockPosterAppearance.legibilityBlurEnabled", group: "Home Screen", path: "lockPosterAppearance.legibilityBlurEnabled",
              title: "Lock Poster Blur", defaultValue: .bool(false),
              limits: nil),
        Field(key: "Home Screen:homePosterAppearance.legibilityBlurEnabled", group: "Home Screen", path: "homePosterAppearance.legibilityBlurEnabled",
              title: "Home Poster Blur", defaultValue: .bool(false),
              limits: nil),
        Field(key: "Home Screen:lockPosterAppearance.allowsModifyingLegibilityBlur", group: "Home Screen", path: "lockPosterAppearance.allowsModifyingLegibilityBlur",
              title: "Allow Lock Poster Blur Changes", defaultValue: .bool(true),
              limits: nil),
        Field(key: "Home Screen:homePosterAppearance.allowsModifyingLegibilityBlur", group: "Home Screen", path: "homePosterAppearance.allowsModifyingLegibilityBlur",
              title: "Allow Home Poster Blur Changes", defaultValue: .bool(true),
              limits: nil),
        Field(key: "Home Screen:selectedAppearanceType", group: "Home Screen", path: "selectedAppearanceType",
              title: "Home Appearance Type", defaultValue: .int(0),
              limits: (0, 100000, 1)),
        Field(key: "Home Screen:customizationConfiguration._dimmed", group: "Home Screen", path: "customizationConfiguration._dimmed",
              title: "Dim Home Wallpaper", defaultValue: .bool(false),
              limits: nil),
        Field(key: "Home Screen:customizationConfiguration._iconTintSource", group: "Home Screen", path: "customizationConfiguration._iconTintSource",
              title: "Icon Tint Source", defaultValue: .string("wallpaperSuggestion"),
              limits: nil),
        Field(key: "Home Screen:customizationConfiguration._iconUserInterfaceSize", group: "Home Screen", path: "customizationConfiguration._iconUserInterfaceSize",
              title: "Icon Size", defaultValue: .string("SMALL"),
              limits: nil),
        Field(key: "Home Screen:customizationConfiguration._iconUserInterfaceStyleType", group: "Home Screen", path: "customizationConfiguration._iconUserInterfaceStyleType",
              title: "Icon Style", defaultValue: .string("color"),
              limits: nil),
        Field(key: "Home Screen:customizationConfiguration._iconUserInterfaceStyleVariant", group: "Home Screen", path: "customizationConfiguration._iconUserInterfaceStyleVariant",
              title: "Icon Style Variant", defaultValue: .string("light"),
              limits: nil),
        Field(key: "Home Screen:customizationConfiguration._tintColorStyle._alpha", group: "Home Screen", path: "customizationConfiguration._tintColorStyle._alpha",
              title: "Icon Tint Alpha", defaultValue: .double(1.0),
              limits: (0, 1, 0.01)),
        Field(key: "Home Screen:customizationConfiguration._tintColorStyle._hue", group: "Home Screen", path: "customizationConfiguration._tintColorStyle._hue",
              title: "Icon Tint Hue", defaultValue: .double(0.5063131313131314),
              limits: (0, 1, 0.01)),
        Field(key: "Home Screen:customizationConfiguration._tintColorStyle._luminance", group: "Home Screen", path: "customizationConfiguration._tintColorStyle._luminance",
              title: "Icon Tint Luminance", defaultValue: .double(0.5),
              limits: (0, 1, 0.01)),
        Field(key: "Home Screen:customizationConfiguration._tintColorStyle._luminanceValue", group: "Home Screen", path: "customizationConfiguration._tintColorStyle._luminanceValue",
              title: "Icon Tint Luminance Value", defaultValue: .double(0.375),
              limits: (0, 1, 0.01)),
        Field(key: "Home Screen:customizationConfiguration._tintColorStyle._saturation", group: "Home Screen", path: "customizationConfiguration._tintColorStyle._saturation",
              title: "Icon Tint Saturation", defaultValue: .double(1.0),
              limits: (0, 1, 0.01)),
    ]

    /// `preference_controls.POSTER_PRESETS`: named bundles of fields.
    static let presets: [String: [String: TweakValue]] = [
        "Still wallpaper": ["Rendering:depthEffectDisabled": .bool(true), "Rendering:motionEffectsDisabled": .bool(true)],
        "Compact clock": ["Clock:permanentCompactTimeEnabled": .bool(true)],
        "Non-compact clock": ["Clock:permanentCompactTimeEnabled": .bool(false)],
    ]

    /// `preference_controls.CLOCK_FONT_IDENTIFIERS`, verbatim.
    static let clockFontIdentifiers: [String] = [
        "PRTimeFontIdentifierNewYork",
        "PRTimeFontIdentifierNewYorkAlpha",
        "PRTimeFontIdentifierNewYorkHeavy",
        "PRTimeFontIdentifierNovember",
        "PRTimeFontIdentifierNovemberCondensed",
        "PRTimeFontIdentifierOctober",
        "PRTimeFontIdentifierPrivateSystemRoundedHeavy",
        "PRTimeFontIdentifierPrivateSystemSoftHeavy",
        "PRTimeFontIdentifierPrivateSystemStencilHeavy",
        "PRTimeFontIdentifierRail",
        "PRTimeFontIdentifierRounded",
        "PRTimeFontIdentifierSFArabic",
        "PRTimeFontIdentifierSFArabicRounded",
        "PRTimeFontIdentifierSFCondensed",
        "PRTimeFontIdentifierSFHebrew",
        "PRTimeFontIdentifierSFHebrewRounded",
        "PRTimeFontIdentifierSFPro",
        "PRTimeFontIdentifierSFRounded",
        "PRTimeFontIdentifierSlab",
        "PRTimeFontIdentifierSoft",
        "PRTimeFontIdentifierSoftLight",
        "PRTimeFontIdentifierStencil",
    ]

    /// The icon-tint field keys, in the order the color editor writes them
    /// (`poster_preferences.py`'s `tint_keys`).
    static let tintKeys: [String] = [
        "Home Screen:customizationConfiguration._tintColorStyle._hue",
        "Home Screen:customizationConfiguration._tintColorStyle._saturation",
        "Home Screen:customizationConfiguration._tintColorStyle._alpha",
    ]

    /// `archive_editor.FIELDS`: the only scalar field names the archive
    /// editor recognises inside a wallpaper's object graph.  Class metadata
    /// and binary blobs stay untouched.
    static let archiveFields: Set<String> = [
        "UIAlpha",
        "UIWhite",
        "_alpha",
        "_dimmed",
        "_hue",
        "_iconTintSource",
        "_iconUserInterfaceSize",
        "_iconUserInterfaceStyleType",
        "_iconUserInterfaceStyleVariant",
        "_luminance",
        "_luminanceValue",
        "_saturation",
        "adaptiveTimeHeightUserConfigured",
        "allowsModifyingLegibilityBlur",
        "alternateDateEnabled",
        "contentsLuminence",
        "depthEffectDisabled",
        "identifier",
        "isAdaptiveTimeHeightUserConfigured",
        "isSystemItem",
        "legibilityBlurEnabled",
        "motionEffectsDisabled",
        "permanentCompactTimeEnabled",
        "preferredStyle",
        "preferredTimeMaxY",
        "preferredTimeMaxYLandscape",
        "preferredTimeMaxYPortrait",
        "preferredTitleAlignment",
        "preferredTitleLayout",
        "selectedAppearanceType",
        "suggested",
        "timeFontIdentifier",
        "timeNumberingSystem",
        "userConfigured",
        "weight",
    ]
}
