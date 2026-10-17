import Foundation

/// Packed rendition key matching `v1KeyFormat` (CoreUI 970, 10 attributes).
///
/// Encoded as a sequence of little-endian `UInt16` tokens, one per attribute,
/// in the order declared by `KEYFORMAT`. The pair `(attributeID, attributeValue)`
/// is implicit: the position in the tuple selects which attribute the token
/// belongs to. Total size is 20 bytes (10 × u16).
/// Local patch: this writer packed nine slots; actool packs ten for an
/// app-icon catalog, the extra one being a localization slot (attribute 8)
/// between `dimension2` and `identifier`. See `v1KeyFormat` for the dump this
/// is based on, and for why the field *order* stayed as it was.
struct RenditionKey: Hashable, Sendable {
    /// attr 7
    var appearance: UInt16
    /// attr 13
    var localizationLegacy: UInt16
    /// attr 12
    var scale: UInt16
    /// attr 15
    var idiom: UInt16
    /// attr 16
    var subtype: UInt16
    /// attr 9
    var dimension2: UInt16
    /// attr 8
    var localization: UInt16
    /// attr 17
    var identifier: UInt16
    /// attr 1
    var element: UInt16
    /// attr 2
    var part: UInt16

    /// CoreUI element IDs that v1 emits. Values dumped from reference
    /// `Assets.car` produced by actool (Xcode 26 / CoreUI 970).
    enum Element: UInt16 {
        /// Element used by both `.image` (imageset) and `.appIcon` bitmap
        /// renditions. The category is differentiated by `Part` below.
        case bitmap = 85
    }

    /// CoreUI part IDs that v1 emits.
    enum Part: UInt16 {
        /// Used by SpringBoard's icon-render pipeline for the classic
        /// `.appiconset` bitmaps. Confirmed against actool output: the
        /// appearance-0 app-icon bitmaps of a real app carry `part = 220`
        /// with `layout = 12` and the source filename as the rendition name.
        /// (The `245` / `layout 1019` pairs seen in the same catalogs are
        /// Icon Composer *iconstacks* — `AppIcon.iconstack` — which are the
        /// modern dark/tinted mechanism and are not what a `.appiconset`
        /// compiles to.)
        case appIcon = 220
        /// Used by UIImage(named:) for generic `.imageset` assets.
        case image = 181
        /// Slot for preserved-source vector renditions (SVG). Reference
        /// `actool` output places the SVG source rendition under this part
        /// rather than `image`; bitmap variants rasterised from the SVG
        /// (which `UIImage(named:)` actually returns) live under `image`.
        case vectorSource = 42
    }

    init(rendition: Rendition) {
        self.appearance = (rendition.appearance?.darkLuminosity == true) ? 1 : 0
        self.localizationLegacy = 0
        self.scale = rendition.scale?.rawValueByte ?? 0
        self.idiom = rendition.idiom.rawValueByte
        self.subtype = 0
        self.localization = 0
        self.identifier = UInt16(FacetKeys.nameHash(rendition.name) & 0xFFFF)
        switch rendition.body {
        case .bitmap(let body):
            self.element = Element.bitmap.rawValue
            switch body.kind {
            case .appIcon:
                self.part = Part.appIcon.rawValue
                // Dimension2 is the appicon "Icon Index" slot. v1 only
                // emits one logical icon size per appiconset, so this is
                // always 1.
                self.dimension2 = 1
            case .image:
                self.part = Part.image.rawValue
                // Generic image assets don't use Dimension2 at all.
                self.dimension2 = 0
            }
        case .color:
            self.element = 0
            self.part = 0
            self.dimension2 = 0
        case .preservedSource(let body):
            self.element = Element.bitmap.rawValue
            self.dimension2 = 0
            switch body.format {
            case .svg:
                // SVG source renditions occupy the dedicated vector-source
                // part; bitmap variants rasterised from the SVG (when the
                // compiler emits them) would use Part.image instead.
                self.part = Part.vectorSource.rawValue
            case .jpeg:
                // JPEG sits in the generic-image lookup category — CoreUI
                // decodes the JPG body itself at runtime and returns the
                // resulting bitmap from UIImage(named:).
                self.part = Part.image.rawValue
            }
        }
    }

    init(
        appearance: UInt16 = 0,
        localizationLegacy: UInt16 = 0,
        scale: UInt16 = 0,
        idiom: UInt16 = 0,
        subtype: UInt16 = 0,
        dimension2: UInt16 = 0,
        localization: UInt16 = 0,
        identifier: UInt16 = 0,
        element: UInt16 = 0,
        part: UInt16 = 0
    ) {
        self.appearance = appearance
        self.localizationLegacy = localizationLegacy
        self.scale = scale
        self.idiom = idiom
        self.subtype = subtype
        self.dimension2 = dimension2
        self.localization = localization
        self.identifier = identifier
        self.element = element
        self.part = part
    }

    func encode() -> Data {
        var w = ByteWriter()
        w.writeLE(appearance)
        w.writeLE(localizationLegacy)
        w.writeLE(scale)
        w.writeLE(idiom)
        w.writeLE(subtype)
        w.writeLE(dimension2)
        w.writeLE(localization)
        w.writeLE(identifier)
        w.writeLE(element)
        w.writeLE(part)
        return w.data
    }

    static func decode(_ data: Data) -> RenditionKey? {
        guard data.count == 20 else { return nil }
        func u16(_ offset: Int) -> UInt16 {
            let lo = UInt16(data[data.index(data.startIndex, offsetBy: offset)])
            let hi = UInt16(data[data.index(data.startIndex, offsetBy: offset + 1)])
            return lo | (hi << 8)
        }
        return RenditionKey(
            appearance: u16(0),
            localizationLegacy: u16(2),
            scale: u16(4),
            idiom: u16(6),
            subtype: u16(8),
            dimension2: u16(10),
            localization: u16(12),
            identifier: u16(14),
            element: u16(16),
            part: u16(18)
        )
    }
}
