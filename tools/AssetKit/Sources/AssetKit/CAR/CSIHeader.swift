import Foundation

/// The fixed 184-byte CSI ("CTSI") rendition header. Layout verified against
/// the reference Assets.car produced by actool (Xcode 26 / CoreUI 970): on
/// disk the tag reads "ISTC" (CTSI as an LE multi-char constant).
enum CSIHeader {
    /// Byte length of the encoded header. Preserved-source and bitmap
    /// renditions both share this length; the body starts at this offset.
    static let length = 184

    /// 'CTSI' as an LE multi-char constant. Produces file bytes I,S,T,C.
    static let tag: UInt32 = 0x43545349

    /// `pixelFormat` = 'ARGB' as an LE multi-char constant. Produces file
    /// bytes B,G,R,A. The pixel encoding is in BGRA byte order in memory.
    static let pixelFormatARGB: UInt32 = 0x41524742

    /// `pixelFormat` = 'JPEG' as an LE multi-char constant. Produces file
    /// bytes G,E,P,J. Reused for preserved-source JPG renditions; CoreUI
    /// dispatches on this constant to invoke its JPEG decoder on the
    /// DWAR-wrapped body.
    static let pixelFormatJPEG: UInt32 = 0x4A504547

    /// `pixelFormat` = 'SVG ' (trailing space) as an LE multi-char constant.
    /// Produces file bytes space,G,V,S. Used for preserved-source SVG
    /// renditions; CoreUI dispatches on this constant to invoke its SVG
    /// renderer on the DWAR-wrapped body.
    static let pixelFormatSVG: UInt32 = 0x53564720

    /// Layout types observed in the reference. The names are derived from
    /// CoreUI symbol names where known.
    enum Layout: UInt16 {
        /// Per the reference: every raw bitmap icon emitted by actool uses 12.
        /// Preserved-source JPG renditions reuse this same layout value (the
        /// pixelFormat selects the decoder, not the layout).
        case bitmapIcon = 12
        case namedColor = 1009
        /// Used by preserved-source SVG renditions in CoreUI 970. JPG keeps
        /// `bitmapIcon` because JPEG sits inside CoreUI's bitmap-asset
        /// category; SVG promotes to its own layout because vector
        /// renditions surface a different AssetType to `assetutil`.
        case vector = 9
    }

    // swiftlint:disable:next function_parameter_count
    static func encode(
        renditionFlags: UInt32,
        width: UInt32,
        height: UInt32,
        scaleFactor: UInt32,
        pixelFormat: UInt32,
        colorSpace: UInt32,
        layout: Layout,
        name: String,
        tvlLength: UInt32,
        bitmapCount: UInt32,
        renditionLength: UInt32
    ) -> Data {
        var w = ByteWriter()
        w.writeLE(tag)
        w.writeLE(UInt32(1))                    // version
        w.writeLE(renditionFlags)
        w.writeLE(width)
        w.writeLE(height)
        w.writeLE(scaleFactor)
        w.writeLE(pixelFormat)
        w.writeLE(colorSpace)
        w.writeLE(UInt32(0))                    // modtime (matches reference; was wall-clock)
        w.writeLE(layout.rawValue)
        w.writeLE(UInt16(0))                    // zero
        w.writePadded(name, length: 128)
        w.writeLE(tvlLength)
        w.writeLE(bitmapCount)
        w.writeLE(UInt32(0))                    // reserved
        w.writeLE(renditionLength)
        precondition(w.offset == length, "CSI header must be \(length) bytes; got \(w.offset)")
        return w.data
    }
}
