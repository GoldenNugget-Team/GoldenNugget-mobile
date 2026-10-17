import Foundation

/// kThemeRenditionAttribute IDs for CoreUI 970 (StorageVersion 17, Xcode 26).
///
/// Values determined by dumping the KEYFORMAT block of an actool-produced
/// Assets.car (`xcrun assetutil --info`). Older CoreUI versions used a
/// different numbering; do not rely on writeups that predate Xcode 14.
enum AttributeID: UInt32 {
    case element = 1
    case part = 2
    case appearance = 7
    case localization = 8
    case dimension2 = 9
    case dimension1 = 10
    case scale = 12
    case localizationLegacy = 13
    case idiom = 15
    case subtype = 16
    case identifier = 17
    case attribute18 = 18
    case attribute19 = 19
    case attribute24 = 24
}

/// Attribute order CoreUI 970 emits in `KEYFORMAT` (and which the rendition key
/// tuple positions mirror exactly). Order is significant: CoreUI reads a
/// rendition key positionally, using this list to name each slot, and
/// binary-searches the packed keys by raw byte comparison.
///
/// Local patch: actool was observed emitting **ten** slots for an app-icon
/// catalog, not the nine this writer produced. Dumping `KEYFORMAT` out of an
/// actool-compiled `Assets.car` for this very catalog gives:
///
///     count = 10, attrs = [7, 13, 12, 15, 16, 9, 8, 17, 1, 2]
///
/// which is the original nine in the original order, plus a localization slot
/// (attribute 8) inserted just before `identifier`. The order was briefly
/// "corrected" to a completely different one — element/part/identifier first,
/// eleven slots — on the strength of catalogs shipped inside Xcode's own
/// frameworks. Those turn out to be a different kind of catalog (CoreUI
/// DesignLibrary and framework resources); an application icon catalog keeps
/// AssetKit's order. The original order was right; the only real defect was
/// the missing tenth slot.
let v1KeyFormat: [AttributeID] = [
    .appearance,
    .localizationLegacy,
    .scale,
    .idiom,
    .subtype,
    .dimension2,
    .localization,
    .identifier,
    .element,
    .part,
]

/// `kfmt` block payload.
enum KeyFormatBlock {
    static let magic: UInt32 = 0x6B666D74 // 'kfmt' as LE multi-char constant

    static func data(attributes: [AttributeID] = v1KeyFormat) -> Data {
        var w = ByteWriter()
        w.writeLE(magic)
        w.writeLE(UInt32(0))                            // version
        w.writeLE(UInt32(attributes.count))             // maximumRenditionKeyTokenCount
        for attr in attributes {
            w.writeLE(attr.rawValue)
        }
        return w.data
    }
}
