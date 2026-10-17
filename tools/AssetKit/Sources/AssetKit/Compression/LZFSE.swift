import Foundation
import CLZFSE

/// LZFSE encoder, vendored from Apple's reference implementation.
/// See `Sources/CLZFSE/UPSTREAM.md`.
enum LZFSE {
    /// Encode `input` to a self-framed LZFSE stream (`bvxn` / `bvx2`, or
    /// the `bvx-` uncompressed-block fallback for incompressible / tiny
    /// input). Used for MLEC chunk payloads and DWAR-framed SVG bodies.
    static func encode(_ input: [UInt8]) -> [UInt8] {
        // Upstream `lzfse_encode_buffer` writes the worst-case-bounded output
        // (raw passthrough is the worst case) into `dst`, returning the
        // written length or 0 on failure. Scratch=nil lets the encoder malloc
        // its own scratch per call.
        //
        // Worst case is upstream's uncompressed-block fallback (`bvx-` +
        // n_raw_bytes + payload + `bvx$`, 12 bytes of envelope). The +256
        // slack is generous insurance against any constant-size framing the
        // encoder might add ahead of choosing the fallback path.
        let bound = input.count + 256
        var output = [UInt8](repeating: 0, count: bound)
        let encoded = input.withUnsafeBufferPointer { inBuf -> Int in
            output.withUnsafeMutableBufferPointer { outBuf in
                lzfse_encode_buffer(
                    outBuf.baseAddress!, bound,
                    inBuf.baseAddress!, input.count,
                    nil
                )
            }
        }
        precondition(encoded > 0, "LZFSE encoding failed for \(input.count)-byte buffer")
        return Array(output.prefix(encoded))
    }
}
