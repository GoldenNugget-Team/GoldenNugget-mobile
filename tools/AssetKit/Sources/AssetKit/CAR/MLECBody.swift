import Foundation

/// MLEC wrapper for bitmap pixels, framed in one or three KCBC chunks.
///
/// Layout verified against actool's reference Assets.car:
///
///   MLEC magic        4 bytes
///   compressionType   u32  (0 = raw, 3 = LZFSE)
///   bytesPerPixel     u32  (4 for BGRA8)
///   chunkCount        u32  (1 or 3)
///   then chunkCount * KCBC chunks
///
/// Each KCBC chunk:
///
///   KCBC magic        4 bytes
///   reserved          8 zero bytes
///   chunkHeight       u32  (rows covered by this chunk)
///   payloadSize       u32  (bytes of compressed payload following)
///   payload[]         LZFSE bvx2 stream
///
/// Chunking policy mirrors actool: when height divides evenly by 3, emit 3
/// chunks of equal row height (120 -> 3x40, 180 -> 3x60); otherwise emit a
/// single chunk covering the whole image. The 3-chunk split is mimicry
/// rather than a correctness requirement: CoreUI accepts both layouts.
enum MLECBody {
    static func encode(width: UInt32, height: UInt32, pixelsBGRA: [UInt8]) -> Data {
        let bytesPerRow = Int(width) * 4
        let canChunkInThree = height % 3 == 0
        let chunkCount: UInt32 = canChunkInThree ? 3 : 1
        let rowsPerChunk = height / chunkCount

        var chunks: [(rows: UInt32, payload: [UInt8])] = []
        for i in 0..<Int(chunkCount) {
            let start = i * Int(rowsPerChunk) * bytesPerRow
            let end = start + Int(rowsPerChunk) * bytesPerRow
            let slice = Array(pixelsBGRA[start..<end])
            chunks.append((rows: rowsPerChunk, payload: LZFSE.encode(slice)))
        }

        var w = ByteWriter()
        w.writeFourCC("MLEC")
        w.writeLE(UInt32(3))                    // compressionType = 3 (LZFSE)
        w.writeLE(UInt32(4))                    // bytesPerPixel (BGRA8 = 4)
        w.writeLE(chunkCount)

        for chunk in chunks {
            w.writeFourCC("KCBC")
            w.writeZeros(8)                     // reserved
            w.writeLE(chunk.rows)               // chunkHeight (rows)
            w.writeLE(UInt32(chunk.payload.count))
            w.write(chunk.payload)
        }
        return w.data
    }
}
