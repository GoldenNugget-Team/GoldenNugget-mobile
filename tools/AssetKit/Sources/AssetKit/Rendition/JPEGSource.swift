import Foundation

/// JPEG source handler: preserved verbatim inside a DWAR envelope, handed
/// to CoreUI's JPEG decoder at draw time. CoreUI 970 still expects decoded
/// width/height in the CSI TVL section, so we sniff the SOF marker without
/// touching pixel data.
enum JPEGSource {
    struct Context {
        var assetName: String
        var idiom: Idiom
        var scale: Scale?
        var appearance: Appearance?
        var filename: String
    }

    static func renditions(bytes: Data, context: Context) throws -> [Rendition] {
        let dims = try Dimensions.read(bytes)
        return [Rendition(
            name: context.assetName,
            idiom: context.idiom,
            scale: context.scale,
            appearance: context.appearance,
            gamut: nil,
            body: .preservedSource(PreservedSourceBody(
                format: .jpeg(width: dims.width, height: dims.height),
                sourceData: bytes,
                renditionName: context.filename
            ))
        )]
    }

    /// Walks the segment chain to a Start-Of-Frame marker. Only inspects
    /// markers, never pixel data.
    ///
    /// JPEG markers covered: SOF0 (baseline), SOF1 (extended sequential),
    /// SOF2 (progressive). Other SOFn markers exist in the spec but are
    /// not produced by mainstream encoders; treating an unrecognised SOF
    /// as malformed catches genuinely odd input rather than silently
    /// emitting zero dimensions.
    enum Dimensions {
        static func read(_ data: Data) throws -> (width: UInt32, height: UInt32) {
            let bytes = [UInt8](data)
            guard bytes.count >= 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else {
                throw XCAssetCompilerError.malformedJPEG(reason: "missing SOI marker")
            }
            var i = 2
            while i < bytes.count {
                // Skip any fill bytes between segments (legal per spec).
                while i < bytes.count && bytes[i] != 0xFF { i += 1 }
                while i < bytes.count && bytes[i] == 0xFF { i += 1 }
                guard i < bytes.count else { break }
                let marker = bytes[i]
                i += 1
                // Standalone markers carry no length and no payload.
                if marker == 0xD8 || marker == 0xD9 || (marker >= 0xD0 && marker <= 0xD7) {
                    continue
                }
                guard i + 2 <= bytes.count else {
                    throw XCAssetCompilerError.malformedJPEG(reason: "truncated segment length")
                }
                let segLen = Int(bytes[i]) << 8 | Int(bytes[i + 1])
                guard segLen >= 2, i + segLen <= bytes.count else {
                    throw XCAssetCompilerError.malformedJPEG(reason: "segment overruns file")
                }
                if marker == 0xC0 || marker == 0xC1 || marker == 0xC2 {
                    // SOFn payload: precision u8, height u16 BE, width u16 BE, ...
                    guard segLen >= 7 else {
                        throw XCAssetCompilerError.malformedJPEG(reason: "SOF segment too short")
                    }
                    let h = UInt32(bytes[i + 3]) << 8 | UInt32(bytes[i + 4])
                    let w = UInt32(bytes[i + 5]) << 8 | UInt32(bytes[i + 6])
                    return (w, h)
                }
                i += segLen
            }
            throw XCAssetCompilerError.malformedJPEG(reason: "no SOF marker found")
        }
    }
}
