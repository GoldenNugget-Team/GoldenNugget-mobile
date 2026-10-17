import Foundation

struct LoadedCatalog: Sendable {
    var url: URL
    var imageSets: [LoadedImageSet]
    var colorSets: [LoadedColorSet]
    /// The app icon the bundle's `CFBundleIconName` resolves to. An Icon
    /// Composer `.icon` wins over a plain `.appiconset`, and a set literally
    /// named `AppIcon` wins over any other appiconset.
    var primaryAppIcon: LoadedAppIcon?
    /// Other app icons in the catalog (e.g. an alternate reached through
    /// `CFBundleAlternateIcons`). Their renditions ship in the car, but only
    /// the primary's plist additions are emitted.
    var additionalAppIcons: [LoadedAppIcon]
}

struct LoadedImageSet: Sendable {
    var name: String
    var directory: URL
    var contents: ImageSetContents
}

struct LoadedColorSet: Sendable {
    var name: String
    var directory: URL
    var contents: ColorSetContents
}

struct LoadedAppIcon: Sendable {
    var name: String
    var directory: URL
    var contents: AppIconContents
    /// Local addition. Icon Composer `.icon` bundles carry a single 1024px
    /// master per appearance, so every `.appiconset` slot has to be downscaled
    /// to its point size before it becomes a rendition. Plain `.appiconset`s
    /// ship pre-sized files and are never resampled.
    var resampleToPointSize: Bool = false
}

struct CatalogLoader: Sendable {
    init() {}

    func load(catalog url: URL) async throws -> LoadedCatalog {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            throw XCAssetCompilerError.notADirectory(path: url.path)
        }

        let decoder = JSONDecoder()

        var imageSets: [LoadedImageSet] = []
        var colorSets: [LoadedColorSet] = []
        var appIconSets: [LoadedAppIcon] = []
        var iconBundles: [LoadedAppIcon] = []

        try walk(url, fileManager: fm) { entry in
            let ext = entry.pathExtension
            let name = entry.deletingPathExtension().lastPathComponent
            switch ext {
            case "imageset":
                let contents = try decode(ImageSetContents.self, at: entry, decoder: decoder)
                imageSets.append(LoadedImageSet(name: name, directory: entry, contents: contents))
            case "colorset":
                let contents = try decode(ColorSetContents.self, at: entry, decoder: decoder)
                colorSets.append(LoadedColorSet(name: name, directory: entry, contents: contents))
            case "appiconset":
                let contents = try decode(AppIconContents.self, at: entry, decoder: decoder)
                appIconSets.append(LoadedAppIcon(name: name, directory: entry, contents: contents))
            case "icon":
                let contents = try decodeIconBundle(at: entry, decoder: decoder)
                iconBundles.append(try FlatIconSynthesis.appIcon(
                    name: name, directory: entry, contents: contents))
            default:
                if !ext.isEmpty {
                    throw XCAssetCompilerError.unsupportedAssetType("\(name).\(ext)")
                }
            }
        }

        // An Icon Composer `.icon` is always the primary when present: it is
        // what `CFBundleIconName` names. Otherwise prefer a set literally named
        // `AppIcon`, which is the conventional primary, and fall back to
        // declaration order. The remaining sets are alternates whose
        // renditions still have to be in the car for `setAlternateIconName`
        // to resolve.
        let primary = iconBundles.first
            ?? appIconSets.first { $0.name == "AppIcon" }
            ?? appIconSets.first
        var all = iconBundles + appIconSets
        if let primary, let index = all.firstIndex(where: { $0.name == primary.name }) {
            all.remove(at: index)
        }

        return LoadedCatalog(
            url: url,
            imageSets: imageSets,
            colorSets: colorSets,
            primaryAppIcon: primary,
            additionalAppIcons: all
        )
    }

    private func decodeIconBundle(
        at directory: URL, decoder: JSONDecoder
    ) throws -> IconBundleContents {
        let contentsURL = directory.appendingPathComponent("icon.json")
        guard FileManager.default.fileExists(atPath: contentsURL.path) else {
            throw XCAssetCompilerError.missingContentsJSON(path: contentsURL.path)
        }
        do {
            return try decoder.decode(IconBundleContents.self, from: Data(contentsOf: contentsURL))
        } catch let error as XCAssetCompilerError {
            throw error
        } catch {
            throw XCAssetCompilerError.malformedContentsJSON(
                path: contentsURL.path,
                underlying: String(describing: error)
            )
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, at directory: URL, decoder: JSONDecoder) throws -> T {
        let contentsURL = directory.appendingPathComponent("Contents.json")
        guard FileManager.default.fileExists(atPath: contentsURL.path) else {
            throw XCAssetCompilerError.missingContentsJSON(path: directory.path)
        }
        do {
            let data = try Data(contentsOf: contentsURL)
            return try decoder.decode(T.self, from: data)
        } catch let error as XCAssetCompilerError {
            throw error
        } catch {
            throw XCAssetCompilerError.malformedContentsJSON(
                path: contentsURL.path,
                underlying: String(describing: error)
            )
        }
    }

    private func walk(_ root: URL, fileManager fm: FileManager, visit: (URL) throws -> Void) throws {
        let children = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])
        for child in children {
            let values = try child.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true else { continue }
            let ext = child.pathExtension
            if ["imageset", "colorset", "appiconset", "icon"].contains(ext) {
                try visit(child)
            } else {
                try walk(child, fileManager: fm, visit: visit)
            }
        }
    }
}
