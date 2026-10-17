import Foundation

/// Orchestrates the BOM container and CAR-specific blocks/trees.
///
/// Canonical vars-table order is established by call sequence: each
/// `addBlock` is immediately paired with `setVariable`, and `BOMWriter`
/// emits the vars table in insertion order. CoreUI's `UIImage(named:)`
/// lookup walks the vars table in order and rejects catalogs whose
/// ordering doesn't match the reference shape, so adding a new block out
/// of sequence here would break iOS lookups silently.
struct CARWriter: Sendable {
    var deploymentTarget: String
    var renditions: [Rendition]

    func write() throws -> Data {
        let layout = CARLayout(renditions: renditions)
        var bom = BOMWriter()

        // Canonical vars-table order, established by the call sequence
        // below: CARHEADER, RENDITIONS, FACETKEYS, APPEARANCEKEYS,
        // KEYFORMAT, EXTENDED_METADATA, BITMAPKEYS. Reordering or omitting
        // a `setVariable` here breaks iOS lookups silently.

        let headerBlockID = bom.addBlock(CARHeaderBlock.data(renditionCount: UInt32(renditions.count)))
        bom.setVariable("CARHEADER", blockID: headerBlockID)

        let renditionEntries: [BOMTree.Entry] = renditions.map { rendition in
            BOMTree.Entry(
                key: RenditionKey(rendition: rendition).encode(),
                value: csiData(for: rendition)
            )
        }
        let renditionsTreeID = BOMTree.insert(into: &bom, entries: renditionEntries)
        bom.setVariable("RENDITIONS", blockID: renditionsTreeID)

        let facetEntries = layout.assets.map { asset in
            BOMTree.Entry(
                key: Data(asset.name.utf8),
                value: FacetKeys.value(for: asset.name, kind: asset.kind)
            )
        }
        let facetTreeID = BOMTree.insert(into: &bom, entries: facetEntries)
        bom.setVariable("FACETKEYS", blockID: facetTreeID)

        let appearanceTreeID = BOMTree.insert(
            into: &bom,
            entries: AppearanceKeys.entries(used: layout.usedAppearances)
        )
        bom.setVariable("APPEARANCEKEYS", blockID: appearanceTreeID)

        let kfmtBlockID = bom.addBlock(KeyFormatBlock.data())
        bom.setVariable("KEYFORMAT", blockID: kfmtBlockID)

        let extendedMetadataBlockID = bom.addBlock(ExtendedMetadata.data(deploymentTarget: deploymentTarget))
        bom.setVariable("EXTENDED_METADATA", blockID: extendedMetadataBlockID)

        let bitmapAssets: [(name: String, descriptor: BitmapKeys.Descriptor)] =
            layout.assets.compactMap { asset in
                guard let descriptor = BitmapKeys.descriptor(
                    forAsset: asset.name,
                    renditions: asset.renditions
                ) else { return nil }
                return (asset.name, descriptor)
            }
        // Local patch: BITMAPKEYS is not emitted.
        //
        // Its per-asset descriptor is a variable-width packed structure whose
        // length depends on the asset: actool-produced catalogs in the Xcode 27
        // SDK carry 48-, 52-, 56-, 60-, 64-, 68- and 72-byte descriptors, and
        // the shape varies with the number of (size, scale, idiom) renditions
        // the asset has. This writer only had a fixed 52-byte template, which
        // matches no reference: once the rendition keys became readable,
        // CoreUI walked BITMAPKEYS and faulted on the short block — the
        // home-screen icon renderer crashed instead of falling back.
        //
        // The block is not on the app-icon path: this catalog's consumer is
        // SpringBoard's icon renderer, which resolves the icon through
        // FACETKEYS + RENDITIONS. Dropping an unreproducible block is safe
        // where a wrong one is not — a missing tree reads as "no descriptors",
        // a short one reads as corruption.
        //
        // `BitmapKeys` is left in place for callers that want to build the
        // tree by hand; it is simply not wired into `write()`.
        if false, !bitmapAssets.isEmpty {
            let bitmapKeysTreeID = BOMTree.insertInlineKey(
                into: &bom,
                entries: BitmapKeys.entries(for: bitmapAssets),
                blockSize: 1024
            )
            bom.setVariable("BITMAPKEYS", blockID: bitmapKeysTreeID)
        }

        return bom.finalize()
    }

    private func csiData(for rendition: Rendition) -> Data {
        switch rendition.body {
        case .bitmap(let body):
            let scaleFactor = UInt32(rendition.scale?.factor ?? 1) * 100
            return CSIWriter.bitmap(name: rendition.name, body: body, scaleFactor: scaleFactor)
        case .color(let body):
            return CSIWriter.color(name: rendition.name, body: body)
        case .preservedSource(let body):
            // SVG renditions are scale-free; the reference leaves
            // scaleFactor=0 for them. JPGs respect the @Nx suffix the same
            // way PNGs do.
            let scaleFactor: UInt32 = {
                switch body.format {
                case .svg: return 0
                case .jpeg: return UInt32(rendition.scale?.factor ?? 1) * 100
                }
            }()
            return CSIWriter.preservedSource(body: body, scaleFactor: scaleFactor)
        }
    }
}
