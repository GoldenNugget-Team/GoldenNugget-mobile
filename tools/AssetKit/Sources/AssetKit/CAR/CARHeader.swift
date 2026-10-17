import Foundation

/// CARHEADER block: 436-byte fixed-size header.
///
/// Field layout, byte offsets, and constants verified by hex-dumping the
/// reference Assets.car produced by actool (Xcode 26.0 (17A324), CoreUI 970,
/// StorageVersion 17). The magic word is stored as an LE multi-char constant
/// so it reads "RATC" forward on disk (CTAR -> 0x43544152 -> bytes R,A,T,C).
enum CARHeaderBlock {
    /// 'CTAR' as an LE multi-char constant. Produces file bytes R,A,T,C
    /// (matching the reference) when emitted via `writeLE`.
    static let magic: UInt32 = 0x43544152

    /// CoreUI metadata strings written for actool-compatible Assets.car.
    /// Both fields are opaque to CoreUI's binary parser (it walks them as
    /// fixed-size buffers), but staying close to the reference format means
    /// `assetutil --info` and Xcode-side tooling display them without
    /// surprises.
    ///
    /// Local patch: these were `CoreUI-970.1` and a self-describing writer
    /// string. Every actool-produced `Assets.car` in the Xcode 27 SDK carries
    /// `CoreUI-1007 [LAR]` and an `Xcode … via AssetCatalogAgent-AssetRuntime`
    /// string instead, so the numbers and text now match that. 52 of the 74
    /// non-empty catalogs in the SDK report `1007`; the outliers are older
    /// resources shipped inside the SDK's own frameworks.
    static let defaultMainVersionString = "@(#)PROGRAM:CoreUI  PROJECT:CoreUI-1007 [LAR]"
    static let defaultVersionString = "Xcode 27.0 (27A259) via AssetCatalogAgent-AssetRuntime"

    static func data(
        coreuiVersion: UInt32 = 1007,
        storageVersion: UInt32 = 17,
        timestamp: UInt32 = 0,
        renditionCount: UInt32,
        mainVersionString: String = defaultMainVersionString,
        versionString: String = defaultVersionString,
        uuid: UUID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)),
        colorSpaceID: UInt32 = 1,
        schemaVersion: UInt32 = 2,
        keySemantics: UInt32 = 1
    ) -> Data {
        var w = ByteWriter()
        w.writeLE(magic)
        w.writeLE(coreuiVersion)
        w.writeLE(storageVersion)
        w.writeLE(timestamp)
        w.writeLE(renditionCount)
        w.writePadded(mainVersionString, length: 128)
        w.writePadded(versionString, length: 256)
        let bytes = uuid.uuid
        w.write([
            bytes.0, bytes.1, bytes.2, bytes.3,
            bytes.4, bytes.5, bytes.6, bytes.7,
            bytes.8, bytes.9, bytes.10, bytes.11,
            bytes.12, bytes.13, bytes.14, bytes.15,
        ])
        w.writeLE(UInt32(0))             // associatedChecksum
        w.writeLE(schemaVersion)
        w.writeLE(colorSpaceID)
        w.writeLE(keySemantics)
        precondition(w.offset == 436, "CARHEADER must be 436 bytes; got \(w.offset)")
        return w.data
    }
}
