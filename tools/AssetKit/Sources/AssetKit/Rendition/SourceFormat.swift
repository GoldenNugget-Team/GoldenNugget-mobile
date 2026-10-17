import Foundation

/// The encoding of a user-supplied file inside an asset: PNG, SVG, or JPG.
///
/// Distinct from **asset category** (an `(element, part)` pair CoreUI
/// attaches to the rendition key) and from **rendition body kind** (how
/// bytes are encoded in `Assets.car`). One source format can fan out to
/// several renditions of different bodies: an SVG source produces one
/// preserved-source rendition plus three bitmap renditions.
///
/// The set is closed because CoreUI dispatches on a fixed list of source
/// formats; adding a new one requires more than a code-side adapter (CSI
/// pixelFormat constants, TVL shape, and renditionFlags all have to be
/// reverse-engineered). Exhaustive switching catches drift at compile time.
enum SourceFormat {
    case png
    case svg
    case jpeg

    static func detect(filename: String) -> SourceFormat? {
        switch (filename as NSString).pathExtension.lowercased() {
        case "png": return .png
        case "svg": return .svg
        case "jpg", "jpeg": return .jpeg
        default: return nil
        }
    }
}
