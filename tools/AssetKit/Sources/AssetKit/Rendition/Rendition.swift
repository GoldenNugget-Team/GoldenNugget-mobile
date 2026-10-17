import Foundation

struct Rendition: Sendable {
    enum Body: Sendable {
        case bitmap(BitmapBody)
        case color(ColorBody)
        case preservedSource(PreservedSourceBody)
    }

    var name: String
    var idiom: Idiom
    var scale: Scale?
    var appearance: Appearance?
    var gamut: Gamut?
    var body: Body
}

struct BitmapBody: Sendable {
    /// Which CoreUI rendition category this bitmap belongs to. Determines the
    /// `(element, part)` pair we encode in the rendition key and FACETKEYS
    /// value -- actool picks different codes for appicons vs. generic images,
    /// and UIImage(named:) only finds renditions whose part matches the
    /// expected category for the lookup path.
    enum Kind: Sendable {
        /// `element=85, part=220`. Used by SpringBoard's icon-render pipeline.
        case appIcon
        /// `element=85, part=181`. Used by UIImage(named:) for generic image
        /// assets from an `.imageset`.
        case image
    }

    var width: UInt32
    var height: UInt32
    var pixelsBGRA: [UInt8]
    var colorSpaceID: UInt8
    var kind: Kind
    /// True iff this bitmap was rasterised from a vector source (SVG, PDF)
    /// rather than supplied directly as bitmap pixels. The reference actool
    /// output tags vector-rasterised bitmaps with extra bits in the CSI
    /// header's `renditionFlags`; some CoreUI runtime paths branch on this
    /// classification (e.g. when re-rasterising via the preserved vector
    /// source at a non-intrinsic size). PNG / appicon bitmaps leave it false.
    var derivedFromVector: Bool = false
    /// The source filename (e.g. "icon@2x.png"). Stored in the CSI header's
    /// 128-char name field; actool uses the filename here, not the asset name.
    var renditionName: String
}

struct ColorBody: Sendable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double
    var colorSpaceID: UInt8
}

/// Source file kept verbatim inside a DWAR envelope rather than rasterised
/// or re-encoded. Used for `.svg` (LZFSE-compressed XML inner payload) and
/// `.jpg` (raw JPEG inner payload). The source-format distinction is carried
/// in the surrounding CSI header's `pixelFormat` and in `Format` below.
struct PreservedSourceBody: Sendable {
    /// Source format plus the per-format data CoreUI needs alongside the
    /// raw bytes. JPEG carries decoded pixel dimensions (populated by
    /// `JPEGDimensions` and emitted into TVL types 1001 / 1003); SVG carries
    /// nothing extra (vector is scale-free and the reference Assets.car
    /// leaves the dimension TVL entries out for SVG renditions). Keeping
    /// these in the enum makes it unrepresentable to construct a JPEG body
    /// without dimensions.
    enum Format: Sendable {
        case svg
        case jpeg(width: UInt32, height: UInt32)
    }

    var format: Format
    /// The user-provided source bytes, unmodified. For SVG this is the raw
    /// XML; for JPG this is the entire JPEG file including JFIF / EXIF
    /// segments.
    var sourceData: Data
    /// The source filename (e.g. "Svg.svg", "Jpg@2x.jpg"). Stored in the
    /// CSI header's 128-char name field; actool uses the filename here, not
    /// the asset name.
    var renditionName: String
}
