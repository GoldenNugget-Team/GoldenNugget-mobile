import Foundation

struct AppIconPlistResult: Sendable {
    var infoPlistAdditions: [String: any Sendable]
    var iconName: String
    var iconFiles: [IconFile]
}

struct IconFile: Sendable, Hashable {
    var idiom: Idiom
    var pointSize: Double
    var scale: Int
    var sourceURL: URL
    var outputName: String
    /// `nil` for the base (Any) appearance, set for a `luminosity = dark`
    /// entry. Local patch: upstream hardcoded `appearance: nil` for every app
    /// icon file, so a dark slot became a separate rendition instead of a
    /// second appearance of the same one.
    var appearance: Appearance?
    /// Local addition. When set, the source artwork is resampled to this many
    /// pixels before it becomes a rendition (and before it is written as a
    /// loose PNG). `nil` means "use the file as-is", which is what a plain
    /// `.appiconset` wants. Icon Composer `.icon` bundles set it because they
    /// carry one 1024px master per appearance for every slot.
    var pixelSize: Int?
}

enum AppIconPlistEmitter {
    static func emit(_ appIcon: LoadedAppIcon) throws -> AppIconPlistResult {
        var iphoneFiles: [String] = []
        var ipadFiles: [String] = []
        var allFiles: [IconFile] = []

        for image in appIcon.contents.images {
            guard let filename = image.filename, !filename.isEmpty else {
                throw XCAssetCompilerError.appIconSizeMissing(asset: appIcon.name, size: image.size)
            }
            let src = appIcon.directory.appendingPathComponent(filename)
            guard FileManager.default.fileExists(atPath: src.path) else {
                throw XCAssetCompilerError.missingReferencedFile(asset: appIcon.name, filename: filename)
            }
            guard let (w, _) = image.pointSize, let scale = image.scale?.factor else {
                throw XCAssetCompilerError.appIconSizeMissing(asset: appIcon.name, size: image.size)
            }
            let bundleName = "\(appIcon.name)\(formatSize(w))x\(formatSize(w))"
            let entry = IconFile(
                idiom: image.idiom,
                pointSize: w,
                scale: scale,
                sourceURL: src,
                outputName: bundleName,
                appearance: image.appearances?.first { $0.darkLuminosity },
                pixelSize: appIcon.resampleToPointSize
                    ? Int((w * Double(scale)).rounded())
                    : nil
            )
            allFiles.append(entry)
            // Only the base appearance goes into CFBundleIconFiles. A dark
            // entry resolves to the same bundleName, and a loose PNG slot can
            // hold exactly one image, so listing it twice would both duplicate
            // the plist entry and make the file written last (dark) win the
            // SpringBoard fallback. actool writes the base artwork there.
            guard entry.appearance == nil else { continue }
            switch image.idiom {
            case .iphone:
                if !iphoneFiles.contains(bundleName) { iphoneFiles.append(bundleName) }
            case .ipad:
                if !ipadFiles.contains(bundleName) { ipadFiles.append(bundleName) }
            default:
                break
            }
        }

        var bundleIcons: [String: any Sendable] = [
            "CFBundleIconName": appIcon.name,
        ]
        if !iphoneFiles.isEmpty {
            bundleIcons["CFBundlePrimaryIcon"] = [
                "CFBundleIconName": appIcon.name,
                "CFBundleIconFiles": iphoneFiles,
            ] as [String: any Sendable]
        }

        var additions: [String: any Sendable] = [
            "CFBundleIcons": bundleIcons,
            "CFBundleIconName": appIcon.name,
        ]

        if !ipadFiles.isEmpty {
            additions["CFBundleIcons~ipad"] = [
                "CFBundleIconName": appIcon.name,
                "CFBundlePrimaryIcon": [
                    "CFBundleIconName": appIcon.name,
                    "CFBundleIconFiles": ipadFiles,
                ] as [String: any Sendable],
            ] as [String: any Sendable]
        }

        let fallback = Array(Set(iphoneFiles + ipadFiles)).sorted()
        if !fallback.isEmpty {
            additions["CFBundleIconFiles"] = fallback
        }

        return AppIconPlistResult(
            infoPlistAdditions: additions,
            iconName: appIcon.name,
            iconFiles: allFiles
        )
    }

    private static func formatSize(_ n: Double) -> String {
        let rounded = n.rounded()
        if abs(n - rounded) < 0.001 {
            return String(format: "%.0f", n)
        }
        return String(format: "%g", n)
    }
}
