import Foundation
import PNG

/// In-memory adapter for swift-png's `PNG.BytestreamSource`. Lets us decode
/// PNG bytes that come from a `Data` buffer (e.g. fresh output from an SVG
/// rasteriser) without round-tripping through a temp file.
private struct MemoryBytestream: PNG.BytestreamSource {
    var bytes: [UInt8]
    var offset: Int = 0
    mutating func read(count: Int) -> [UInt8]? {
        guard offset + count <= bytes.count else { return nil }
        defer { offset += count }
        return Array(bytes[offset..<offset + count])
    }
}

/// PNG source handler: produces one bitmap rendition with BGRA-premultiplied
/// pixels. Shared by both `.imageset` (kind=.image) and `.appiconset`
/// (kind=.appIcon) paths; the caller picks the kind via the Context.
enum PNGSource {
    struct Context {
        var assetName: String
        var idiom: Idiom
        var scale: Scale?
        var appearance: Appearance?
        var gamut: Gamut
        var filename: String
        var kind: BitmapBody.Kind
        /// Local addition. When set, the decoded artwork is downscaled to this
        /// many pixels (square) before it becomes a rendition. Icon Composer
        /// `.icon` bundles carry one 1024px master per appearance, so every
        /// `.appiconset` slot they expand into needs resampling; plain
        /// imagesets and appiconsets leave it `nil` and pass bytes through.
        var resampleTarget: Int? = nil
    }

    static func renditions(bytes: Data, context: Context) throws -> [Rendition] {
        var (width, height, bgra) = try decodeBGRA(bytes)
        if let target = context.resampleTarget, target > 0, target != Int(width) {
            (width, height, bgra) = resampleBGRA(
                width: width, height: height, pixels: bgra, target: target)
        }
        return [Rendition(
            name: context.assetName,
            idiom: context.idiom,
            scale: context.scale,
            appearance: context.appearance,
            gamut: context.gamut,
            body: .bitmap(BitmapBody(
                width: width,
                height: height,
                pixelsBGRA: bgra,
                colorSpaceID: context.gamut.colorSpaceID,
                kind: context.kind,
                renditionName: context.filename
            ))
        )]
    }

    /// Decode PNG bytes to BGRA-premultiplied pixels. Shared with SVGSource's
    /// rasterised fanout, which feeds PNG bytes returned by the SVG rasteriser
    /// straight through this path.
    static func decodeBGRA(_ bytes: Data) throws -> (UInt32, UInt32, [UInt8]) {
        var blob = MemoryBytestream(bytes: [UInt8](bytes))
        let image = try PNG.Image.decompress(stream: &blob)
        let rgba: [PNG.RGBA<UInt8>] = image.unpack(as: PNG.RGBA<UInt8>.self)
        let width = UInt32(image.size.x)
        let height = UInt32(image.size.y)
        var out = [UInt8](repeating: 0, count: rgba.count * 4)
        for i in 0..<rgba.count {
            let px = rgba[i]
            let a = UInt16(px.a)
            let r = UInt8((UInt16(px.r) * a + 127) / 255)
            let g = UInt8((UInt16(px.g) * a + 127) / 255)
            let b = UInt8((UInt16(px.b) * a + 127) / 255)
            let base = i * 4
            out[base + 0] = b
            out[base + 1] = g
            out[base + 2] = r
            out[base + 3] = px.a
        }
        return (width, height, out)
    }

    /// Downscale a square, premultiplied-BGRA buffer with bilinear
    /// interpolation. Only ever shrinks: Icon Composer masters are 1024px and
    /// every app-icon slot is smaller or equal. Premultiplied channels
    /// interpolate linearly, so no alpha un/re-premultiply is required.
    static func resampleBGRA(
        width: UInt32, height: UInt32, pixels: [UInt8], target: Int
    ) -> (UInt32, UInt32, [UInt8]) {
        guard target > 0, target != Int(width) || target != Int(height) else {
            return (width, height, pixels)
        }
        let dst = target
        let srcW = Int(width)
        let srcH = Int(height)
        let scaleX = Double(srcW) / Double(dst)
        let scaleY = Double(srcH) / Double(dst)
        var out = [UInt8](repeating: 0, count: dst * dst * 4)
        for dy in 0..<dst {
            let sy = (Double(dy) + 0.5) * scaleY - 0.5
            let y0 = max(0, min(srcH - 1, Int(sy.rounded(.down))))
            let y1 = min(srcH - 1, y0 + 1)
            let fy = max(0, min(1, sy - Double(y0)))
            for dx in 0..<dst {
                let sx = (Double(dx) + 0.5) * scaleX - 0.5
                let x0 = max(0, min(srcW - 1, Int(sx.rounded(.down))))
                let x1 = min(srcW - 1, x0 + 1)
                let fx = max(0, min(1, sx - Double(x0)))
                let i00 = (y0 * srcW + x0) * 4
                let i10 = (y0 * srcW + x1) * 4
                let i01 = (y1 * srcW + x0) * 4
                let i11 = (y1 * srcW + x1) * 4
                let o = (dy * dst + dx) * 4
                for c in 0..<4 {
                    let top = Double(pixels[i00 + c]) * (1 - fx) + Double(pixels[i10 + c]) * fx
                    let bottom = Double(pixels[i01 + c]) * (1 - fx) + Double(pixels[i11 + c]) * fx
                    let value = top * (1 - fy) + bottom * fy
                    out[o + c] = UInt8(max(0, min(255, value.rounded())))
                }
            }
        }
        return (UInt32(dst), UInt32(dst), out)
    }

    /// Decode `bytes`, downscale the (straight-alpha) RGBA to `target` pixels
    /// square, and re-encode. Used for the loose PNGs in the bundle root, which
    /// SpringBoard reads directly and which must match the slot's pixel size.
    static func resizedPNG(bytes: Data, target: Int) throws -> Data {
        var blob = MemoryBytestream(bytes: [UInt8](bytes))
        let image = try PNG.Image.decompress(stream: &blob)
        let source = image.unpack(as: PNG.RGBA<UInt8>.self)
        let resized: [PNG.RGBA<UInt8>]
        if target > 0, target != image.size.x {
            resized = resampleRGBA(
                source, width: image.size.x, height: image.size.y, target: target)
        } else {
            resized = source
        }
        let layout = PNG.Layout(format: .rgba8(palette: [], fill: nil))
        let out = PNG.Image(
            packing: resized, size: (x: target, y: target), layout: layout)
        var destination = DataDestination()
        try out.compress(stream: &destination, level: 9)
        return Data(destination.data)
    }

    private static func resampleRGBA(
        _ pixels: [PNG.RGBA<UInt8>], width: Int, height: Int, target: Int
    ) -> [PNG.RGBA<UInt8>] {
        guard target > 0, target != width || target != height else { return pixels }
        var flattened = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<pixels.count {
            flattened[i * 4 + 0] = pixels[i].r
            flattened[i * 4 + 1] = pixels[i].g
            flattened[i * 4 + 2] = pixels[i].b
            flattened[i * 4 + 3] = pixels[i].a
        }
        // Straight-alpha channels still interpolate acceptably for an icon
        // fallback; the value is visual approximation, not a bit-exact match to
        // Apple's Lanczos-like resampler.
        let (_, _, rgba) = resampleBGRA(
            width: UInt32(width), height: UInt32(height), pixels: flattened, target: target)
        var out: [PNG.RGBA<UInt8>] = []
        out.reserveCapacity(target * target)
        for i in 0..<(target * target) {
            let r = rgba[i * 4 + 0]
            let g = rgba[i * 4 + 1]
            let b = rgba[i * 4 + 2]
            let a = rgba[i * 4 + 3]
            out.append(PNG.RGBA<UInt8>(r, g, b, a))
        }
        return out
    }
}

/// In-memory PNG destination, so `resizedPNG` can hand back `Data` instead of
/// round-tripping through a temporary file.
private struct DataDestination: PNG.BytestreamDestination {
    var data: [UInt8] = []

    mutating func write(_ buffer: [UInt8]) -> Void? {
        data.append(contentsOf: buffer)
        return ()
    }
}
