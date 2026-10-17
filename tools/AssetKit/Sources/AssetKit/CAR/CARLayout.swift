import Foundation

/// Per-asset facts CARWriter consults when emitting tree-shaped blocks
/// (FACETKEYS, BITMAPKEYS). Built once from the rendition list and queried
/// by both tree builders.
struct AssetFacts {
    let name: String
    let kind: FacetKeys.Kind
    let renditions: [Rendition]
}

/// One-time derivation of facts CARWriter consults across multiple BOM
/// blocks: per-asset facts in canonical (sorted-by-name) order, plus the
/// set of appearances that actually show up in the rendition list.
///
/// Single scan over the rendition list in `init`; everything downstream is
/// cached lookups. Replaces the three independent rendition scans CARWriter
/// previously did for FACETKEYS, APPEARANCEKEYS, and BITMAPKEYS.
struct CARLayout {
    /// Per-asset facts sorted by asset name. Tree-emitting blocks iterate
    /// this array directly; the sort matches BOM tree binary-search order.
    let assets: [AssetFacts]
    let usedAppearances: Set<UInt16>

    init(renditions: [Rendition]) {
        let grouped = Dictionary(grouping: renditions, by: \.name)
        self.assets = grouped.keys.sorted().map { name in
            // `grouped[name]!` is safe: we are iterating its own keys.
            let assetRenditions = grouped[name]!
            // All renditions for one asset share the same FacetKeys.Kind:
            // imageset, colorset, and appiconset producers each emit exactly
            // one kind per asset. Classifying off the first rendition is
            // therefore equivalent to classifying off any of them.
            return AssetFacts(
                name: name,
                kind: Self.facetKind(for: assetRenditions[0]),
                renditions: assetRenditions
            )
        }

        var usedAppearances: Set<UInt16> = [AppearanceKeys.any]
        for rendition in renditions where rendition.appearance?.darkLuminosity == true {
            usedAppearances.insert(AppearanceKeys.dark)
        }
        self.usedAppearances = usedAppearances
    }

    private static func facetKind(for rendition: Rendition) -> FacetKeys.Kind {
        switch rendition.body {
        case .bitmap(let body):
            switch body.kind {
            case .appIcon: return .appIcon
            case .image: return .image
            }
        case .color: return .color
        // Preserved-source renditions live in the `.image` category at every
        // layer above the CSI body: FACETKEYS, BITMAPKEYS, and the rendition
        // key all reuse the same element/part as a generic PNG imageset.
        // The source format only shows up in the CSI header's pixelFormat.
        case .preservedSource: return .image
        }
    }
}
