import Foundation

/// BITMAPKEYS tree: per-asset bitmap descriptors that CoreUI consults during
/// UIImage(named:) resolution for `.imageset` (and analogous) assets.
///
/// Structure (verified against actool's reference Assets.car, Xcode 26 /
/// CoreUI 970):
/// - The tree is `isPathInternal = true` and uses a `blockSize` of 1024.
/// - Each leaf entry's "key" slot is an INLINE u32 NameIdentifier (not a
///   block pointer like other trees).
/// - Each value is a 52-byte descriptor block.
///
/// Without this tree present, `UIImage(named:)` returns nil on device even
/// though `assetutil --info` parses the file cleanly and FACETKEYS/RENDITIONS
/// resolve correctly. SpringBoard's appicon-render path does NOT depend on
/// BITMAPKEYS (the home icon still renders via the loose-PNG fallback).
enum BitmapKeys {
    /// The 52-byte descriptor. Layout was derived by diffing actool's outputs
    /// for `.appiconset` vs `.imageset` (bitmap) vs `.imageset` (vector)
    /// renditions. The first 7 u32s are header-like; only slot 6 varies
    /// across asset kinds. The remaining 6 vary by asset kind.
    struct Descriptor {
        var kind: Kind
        /// Number of distinct (idiom, subtype) tuples this asset is keyed on.
        var idiomSubtypeCount: UInt32

        enum Kind {
            case appIcon
            /// PNG and JPEG `.imageset` assets — bitmap source.
            case image
            /// SVG `.imageset` assets — vector source.
            case vector
        }

        /// Slot 6 of the header (the only header u32 that varies by kind).
        /// `0x04` for bitmap-source assets (PNG, JPG); `0x0e` for vector
        /// sources (SVG). AppIcon keeps `0x0e` -- we have no reference dump
        /// for appicon-only catalogs to confirm which value it expects, and
        /// the current value is verified end-to-end on device.
        private var assetKindMarker: UInt32 {
            switch kind {
            case .image: return 0x04
            case .vector, .appIcon: return 0x0e
            }
        }

        func encode() -> Data {
            var w = ByteWriter()
            w.writeLE(UInt32(1))
            w.writeLE(UInt32(0))
            w.writeLE(UInt32(0x28))
            // Local patch: this was a hardcoded 9 and tracked the rendition
            // key width. It has to follow `v1KeyFormat` — dumping an
            // actool-produced app-icon catalog shows the same number here as
            // in KEYFORMAT.
            w.writeLE(UInt32(v1KeyFormat.count))
            w.writeLE(UInt32(0xFFFFFFFF))
            w.writeLE(UInt32(1))
            w.writeLE(assetKindMarker)
            // Variable section. Values come from the actool reference.
            //   AppIcon  : [u32=2, u16=1, u16=1, u32=7]
            //   Image    : [u32=1, u16=1, u16=0, u32=1]
            //   Vector   : [u32=1, u16=1, u16=0, u32=1]   (same shape as Image)
            // The exact semantics aren't fully reverse-engineered yet, so for
            // v1 we hardcode the templates per kind and pass through the
            // discovered (idiom, subtype) count. Field 7 in particular seems
            // to track that count.
            w.writeLE(idiomSubtypeCount)
            switch kind {
            case .appIcon:
                w.writeLE(UInt16(1))            // (u16, u16) tuple
                w.writeLE(UInt16(1))
                w.writeLE(UInt32(7))
            case .image, .vector:
                w.writeLE(UInt16(1))
                w.writeLE(UInt16(0))
                w.writeLE(UInt32(1))
            }
            // Three trailing -1 sentinels.
            w.writeLE(UInt32(0xFFFFFFFF))
            w.writeLE(UInt32(0xFFFFFFFF))
            w.writeLE(UInt32(0xFFFFFFFF))
            precondition(w.offset == 52, "BITMAPKEYS descriptor must be 52 bytes; got \(w.offset)")
            return w.data
        }
    }

    /// Per-asset BITMAPKEYS entry: `(NameIdentifier, descriptor bytes)`.
    static func entries(for assets: [(name: String, descriptor: Descriptor)]) -> [BOMTree.InlineKeyEntry] {
        return assets.map { asset in
            BOMTree.InlineKeyEntry(
                key: FacetKeys.nameHash(asset.name) & 0xFFFF,
                value: asset.descriptor.encode()
            )
        }
    }

    /// Derive the BITMAPKEYS descriptor for one asset from its rendition list.
    /// Returns `nil` for color-only assets, which produce no BITMAPKEYS row.
    ///
    /// `renditions` is the per-asset slice -- only the renditions whose
    /// `name` equals this asset's name. Caller is responsible for the
    /// grouping; this function does not re-filter.
    static func descriptor(forAsset name: String, renditions: [Rendition]) -> Descriptor? {
        let hasBitmapOrPreservedSource = renditions.contains { rendition in
            switch rendition.body {
            case .bitmap, .preservedSource: return true
            case .color: return false
            }
        }
        guard hasBitmapOrPreservedSource else { return nil }

        let kind = inferKind(from: renditions)

        // (idiom << 16) | subtype packs each (idiom, subtype) pair into a
        // single UInt32 for Set uniqueness. Subtype is always 0 today; the
        // packing exists to match how CoreUI would distinguish (e.g.) iPhone
        // 60pt vs iPhone 76pt if subtype were ever non-zero.
        let idiomSubtypes = Set(renditions.map { rendition -> UInt32 in
            let idiom = UInt32(rendition.idiom.rawValueByte)
            let subtype: UInt32 = 0
            return (idiom << 16) | subtype
        })

        return Descriptor(kind: kind, idiomSubtypeCount: UInt32(idiomSubtypes.count))
    }

    /// AppIcon takes precedence over Vector takes precedence over Image:
    /// an .appiconset is a distinct CoreUI category, and a vector source
    /// outranks plain bitmap because the rasterised PNG fallbacks coexist
    /// with the preserved SVG body. Mixed PNG/JPEG imagesets fall through
    /// to `.image`.
    ///
    /// The AppIcon arm relies on `ImageRenderer.appIconRenditions` only
    /// producing `.bitmap(.appIcon)` renditions (PNG-only at that entry
    /// point). If that invariant slips, an appiconset whose source was
    /// (say) preserved JPG would be misclassified as `.image` here.
    private static func inferKind(from renditions: [Rendition]) -> Descriptor.Kind {
        for rendition in renditions {
            if case .bitmap(let body) = rendition.body, body.kind == .appIcon {
                return .appIcon
            }
        }
        for rendition in renditions {
            if case .preservedSource(let body) = rendition.body, case .svg = body.format {
                return .vector
            }
        }
        return .image
    }
}
