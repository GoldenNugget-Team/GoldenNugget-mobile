import Foundation

/// Dispatches each source file in an asset to the matching source-format
/// handler (`PNGSource`, `SVGSource`, `JPEGSource`). Owns filesystem I/O,
/// missing-file detection, and the imageset / appiconset iteration; the
/// handlers own per-format rendition construction.
enum ImageRenderer {
    static func renditions(
        for set: LoadedImageSet,
        svgRasterizer: any SVGRasterizer
    ) throws -> [Rendition] {
        var out: [Rendition] = []
        for image in set.contents.images {
            guard let filename = image.filename, !filename.isEmpty else { continue }
            let src = set.directory.appendingPathComponent(filename)
            guard FileManager.default.fileExists(atPath: src.path) else {
                throw XCAssetCompilerError.missingReferencedFile(asset: set.name, filename: filename)
            }
            guard let format = SourceFormat.detect(filename: filename) else {
                throw XCAssetCompilerError.unsupportedAssetType(filename)
            }
            let bytes = try Data(contentsOf: src)
            let appearance = image.appearances?.first { $0.darkLuminosity }
            switch format {
            case .png:
                let ctx = PNGSource.Context(
                    assetName: set.name,
                    idiom: image.idiom,
                    scale: image.scale,
                    appearance: appearance,
                    gamut: image.displayGamut ?? .sRGB,
                    filename: filename,
                    kind: .image
                )
                out.append(contentsOf: try PNGSource.renditions(bytes: bytes, context: ctx))
            case .svg:
                let ctx = SVGSource.Context(
                    assetName: set.name,
                    idiom: image.idiom,
                    appearance: appearance,
                    filename: filename
                )
                out.append(contentsOf: try SVGSource.renditions(
                    bytes: bytes,
                    context: ctx,
                    rasteriser: svgRasterizer
                ))
            case .jpeg:
                let ctx = JPEGSource.Context(
                    assetName: set.name,
                    idiom: image.idiom,
                    scale: image.scale,
                    appearance: appearance,
                    filename: filename
                )
                out.append(contentsOf: try JPEGSource.renditions(bytes: bytes, context: ctx))
            }
        }
        return out
    }

    static func appIconRenditions(for appIcon: LoadedAppIcon, files: [IconFile]) throws -> [Rendition] {
        var out: [Rendition] = []
        for file in files {
            let filename = file.sourceURL.lastPathComponent
            guard SourceFormat.detect(filename: filename) == .png else {
                throw XCAssetCompilerError.unsupportedAppIconSource(asset: appIcon.name, filename: filename)
            }
            let bytes = try Data(contentsOf: file.sourceURL)
            let scale: Scale = {
                switch file.scale {
                case 1: return .x1
                case 2: return .x2
                case 3: return .x3
                default: return .x1
                }
            }()
            // The appiconset's basename ("AppIcon") is the rendition name in
            // the CSI header for the reference; the per-file outputName
            // ("AppIcon60x60") is only used for CFBundleIconFiles in
            // Info.plist. We pass the source filename through as renditionName
            // because actool uses the filename (not the asset name) here.
            //
            // Local patch: the appearance is no longer forced to nil, so a
            // `luminosity = dark` slot is registered as a second appearance of
            // this same asset name — the same thing the imageset path above
            // does, which is what makes CoreUI pick the dark artwork on a dark
            // home screen instead of finding nothing under "AppIcon".
            let ctx = PNGSource.Context(
                assetName: appIcon.name,
                idiom: file.idiom,
                scale: scale,
                appearance: file.appearance,
                gamut: .sRGB,
                filename: filename,
                kind: .appIcon,
                resampleTarget: file.pixelSize
            )
            out.append(contentsOf: try PNGSource.renditions(bytes: bytes, context: ctx))
        }
        return out
    }
}
