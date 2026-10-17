import Foundation

/// 12-byte framing wrapper introduced in CoreUI 970 for preserved-source
/// renditions. `flags = 1` declares the payload is an LZFSE-framed inner
/// stream (`bvxn` / `bvx2`); `flags = 0` declares the payload is the raw
/// source bytes. The same envelope serves both SVG (compressed) and JPG
/// (raw); CoreUI uses the surrounding CSI `pixelFormat` to choose a
/// decoder for the inner content.
enum DWAREnvelope {
    static func encode(flags: UInt32, payload: [UInt8]) -> Data {
        var w = ByteWriter()
        // 'DWAR' in character order on disk (D, W, A, R). Same byte
        // convention as META / MLEC / KCBC, not LE-multi-char like CTSI.
        w.writeFourCC("DWAR")
        w.writeLE(flags)
        w.writeLE(UInt32(payload.count))
        w.write(payload)
        return w.data
    }
}
