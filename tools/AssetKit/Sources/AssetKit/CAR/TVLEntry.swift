import Foundation

/// One entry in a CSI rendition's TVL (type-length-value) metadata section.
///
/// CoreUI consumes a small fixed set of TVL types between the 184-byte CSI
/// header and the rendition body. Closed enum + exhaustive switch keeps the
/// type IDs and value layouts in one place; the alignment rule for
/// `.bytesPerRow` lives inside the enum (callers pass width, encoding
/// computes the 16-byte-aligned stride).
///
/// Type IDs and value layouts derived from actool's reference Assets.car
/// (Xcode 26 / CoreUI 970). Without these entries, CoreUI can parse the
/// rendition's key but cannot materialise the body -- `assetutil --info`
/// reports AssetType "Unknown" and omits PixelWidth/PixelHeight/Encoding.
enum TVLEntry {
    /// Type 1001 (20-byte value): bitmap descriptor. Encoded fields are
    /// `(1, 0, 0, width, height)`. The leading 1 is presumed a
    /// bitmap-type/flags field; the trailing dims duplicate the CSI header
    /// dims and seem to be what CoreUI consults during materialisation.
    case bitmapDescriptor(width: UInt32, height: UInt32)

    /// Type 1003 (28-byte value): destination rect. Encoded fields are
    /// `(1, 0, 0, 0, 0, width, height)` -- `(flags, x, y, z, w, w, h)`.
    case destRect(width: UInt32, height: UInt32)

    /// Type 1004 (8-byte value): slice/scale pair. Reference is `(0, 1.0f)`.
    case sliceScale

    /// Type 1006 (4-byte value): always 1 in the reference. Likely a
    /// bitmap-count / has-mipmap-stages flag.
    case bitmapFlag

    /// Type 1007 (4-byte value): bytes per row, aligned up to 16. Caller
    /// passes the pixel width; encoding computes `width * 4` then rounds up
    /// to a 16-byte stride.
    case bytesPerRow(width: UInt32)

    func encode(into w: inout ByteWriter) {
        switch self {
        case .bitmapDescriptor(let width, let height):
            w.writeLE(UInt32(1001))
            w.writeLE(UInt32(20))
            w.writeLE(UInt32(1))
            w.writeLE(UInt32(0))
            w.writeLE(UInt32(0))
            w.writeLE(width)
            w.writeLE(height)
        case .destRect(let width, let height):
            w.writeLE(UInt32(1003))
            w.writeLE(UInt32(28))
            w.writeLE(UInt32(1))
            w.writeLE(UInt32(0))
            w.writeLE(UInt32(0))
            w.writeLE(UInt32(0))
            w.writeLE(UInt32(0))
            w.writeLE(width)
            w.writeLE(height)
        case .sliceScale:
            w.writeLE(UInt32(1004))
            w.writeLE(UInt32(8))
            w.writeLE(UInt32(0))
            w.writeLE(UInt32(Float(1).bitPattern))
        case .bitmapFlag:
            w.writeLE(UInt32(1006))
            w.writeLE(UInt32(4))
            w.writeLE(UInt32(1))
        case .bytesPerRow(let width):
            w.writeLE(UInt32(1007))
            w.writeLE(UInt32(4))
            let bytesPerRow = width * 4
            let aligned = (bytesPerRow + 15) & ~15
            w.writeLE(aligned)
        }
    }
}
