import AssetKit
import Foundation

// actool-compatible front end for AssetKit.
//
// Only the arguments xtool actually passes are interpreted; everything else is
// accepted and ignored, because actool's real CLI has a large surface and the
// goal here is to be a drop-in for one specific caller, not a reimplementation.
// Every invocation appends its full argv to $ASSETKIT_SHIM_LOG so the contract
// can be read back if xtool ever grows a new flag.

enum ShimError: Error {
    case message(String)
}

extension ShimError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        }
    }
}

struct Options {
    var compileDir: URL?
    /// Print the rendition table that goes into `Assets.car` and exit. The CAR
    /// is LZFSE-compressed, so on Linux this is the only way to confirm that a
    /// `luminosity = dark` entry really became a dark appearance of the asset
    /// rather than a separate rendition. xtool never passes this flag.
    var dumpRenditions = false
    var appIconName: String?
    var minimumDeploymentTarget = "16.0"
    var platform = "iphoneos"
    var outputPartialInfoPlist: URL?
    var outputPartialInfoPlistDirectory: URL?
    var versionQuery = false
    var catalogs: [URL] = []
}

func parse(_ arguments: [String]) -> Options {
    var options = Options()
    var index = 0
    while index < arguments.count {
        let argument = arguments[index]

        func nextValue() -> String? {
            index += 1
            return index < arguments.count ? arguments[index] : nil
        }

        // Flags that take no value: actool accepts these and we ignore them.
        switch argument {
        case "--compress-pngs", "--emit-compact-header", "--filter-for-device-model",
             "--filter-for-device-os-version", "--filter-for-device-variant",
             "--filter-for-single-iphone-fallback", "--include-all-app-icons",
             "--notices", "--warnings", "--errors", "--minimum-device-version",
             "--maximum-device-version", "--separate-partial-info-plist-for-each-app-icon",
             "--app-icon", "--purge", "--target-device", "--product-type",
             "--rendition-name", "--provides-app-icon":
            // --app-icon takes a value after all; handled below by falling through.
            if argument == "--app-icon" {
                options.appIconName = nextValue()
            }
            index += 1
            continue
        default:
            break
        }

        switch argument {
        case "--version":
            options.versionQuery = true
        case "--output-format":
            _ = nextValue()
        case "--compile":
            if let value = nextValue() { options.compileDir = URL(fileURLWithPath: value) }
        case "--minimum-deployment-target":
            if let value = nextValue() { options.minimumDeploymentTarget = value }
        case "--platform":
            if let value = nextValue() { options.platform = value }
        case "--output-partial-info-plist":
            if let value = nextValue() { options.outputPartialInfoPlist = URL(fileURLWithPath: value) }
        case "--output-partial-info-plist-directory":
            if let value = nextValue() {
                options.outputPartialInfoPlistDirectory = URL(fileURLWithPath: value)
            }
        case "--actool-path", "--additional-asset-tags", "--app-icon-tag", "--compile-child":
            _ = nextValue()
        case "--dump-renditions":
            options.dumpRenditions = true
        case "-h", "--help":
            print(usage)
            exit(0)
        default:
            if argument.hasPrefix("-") {
                FileHandle.standardError.write(Data("actool: ignoring \(argument)\n".utf8))
                // Unknown flags might take a value; there is no way to know, so
                // assume they do not.  xtool only passes the flags handled above.
            } else {
                options.catalogs.append(URL(fileURLWithPath: argument))
            }
        }
        index += 1
    }
    return options
}

let usage = """
usage: actool --compile <dir> --app-icon <name> --minimum-deployment-target <v> \
               --platform <p> [--output-partial-info-plist <path>] [--compress-pngs] <catalog>...
"""

/// Deletes the temporary merged catalog, unless ASSETKIT_SHIM_KEEP_MERGED is
/// set -- a missing-file error is only diagnosable against the real tree.
func discard(_ url: URL) {
    if ProcessInfo.processInfo.environment["ASSETKIT_SHIM_KEEP_MERGED"] != nil {
        FileHandle.standardError.write(Data("kept merged catalog: \(url.path)\n".utf8))
        return
    }
    try? FileManager.default.removeItem(at: url)
}

func log(_ message: String) {
    let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
    guard let path = ProcessInfo.processInfo.environment["ASSETKIT_SHIM_LOG"] else {
        FileHandle.standardError.write(Data(line.utf8))
        return
    }
    if let handle = FileHandle(forWritingAtPath: path) {
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        try? handle.close()
    }
}

@main
struct Main {
    static func main() async {
        do {
            try await run()
        } catch {
            // A top-level Swift error here would abort with a 40-line backtrace
            // dump, and xtool parses this tool's stderr — so print one line and
            // exit non-zero like actool does.
            FileHandle.standardError.write(
                Data("error: \(Self.describe(error))\n".utf8))
            log("FAILED: \(Self.describe(error))")
            exit(1)
        }
    }

    static func describe(_ error: any Error) -> String {
        if let localized = error as? LocalizedError, let reason = localized.errorDescription {
            return reason
        }
        return String(describing: error)
    }

    static func run() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        log("argv: \(arguments.joined(separator: " "))")
        let options = parse(arguments)

        if options.versionQuery {
            // actool answers a version probe with a plist; xtool runs
            // `actool --version --output-format xml1` before anything else, so
            // this has to succeed or the build dies before it starts.
            let plist: [String: Any] = [
                "CFBundleIdentifier": "com.apple.actool",
                "CFBundleShortVersionString": "1.0",
                "CFBundleVersion": "970.0.0.16.6",
                "AssetToolBuildVersion": "970",
            ]
            let data = try PropertyListSerialization.data(
                fromPropertyList: plist, format: .xml, options: 0)
            FileHandle.standardOutput.write(data)
            log("version probe answered")
            return
        }

        guard let compileDir = options.compileDir else {
            throw ShimError.message("--compile is required\n\(usage)")
        }
        guard !options.catalogs.isEmpty else {
            throw ShimError.message("no catalog given\n\(usage)")
        }

        try FileManager.default.createDirectory(
            at: compileDir, withIntermediateDirectories: true)

        // Merge the catalogs first: actool accepts several, and a catalog split
        // across arguments has to behave like one merged catalog.
        let merged = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("assetkit-merged-\(ProcessInfo.processInfo.processIdentifier).xcassets")
        try merge(catalogs: options.catalogs, into: merged)

        let compiler = XCAssetCompiler(deploymentTarget: options.minimumDeploymentTarget)

        if options.dumpRenditions {
            for entry in try await compiler.renditionReport(catalog: merged) {
                let appearance = entry.appearance ?? "-"
                let body = entry.renditionName ?? "-"
                print("\(entry.name)\t\(entry.idiom)\t\(entry.scale ?? "-")\t\(appearance)\t\(body)")
            }
            discard(merged)
            return
        }

        let result = try await compiler.compile(catalog: merged)
        log("compiled catalog: car=\(result.carData.count) bytes, appIcon=\(result.appIconBundle != nil)")

        let carURL = compileDir.appendingPathComponent("Assets.car")
        try result.carData.write(to: carURL)
        log("wrote \(carURL.path)")

        guard let bundle = result.appIconBundle else {
            log("catalog has no .appiconset; wrote Assets.car only")
            discard(merged)
            return
        }

        // The loose PNGs are not optional: SpringBoard's icon-render path reads
        // them straight out of the bundle root when CoreUI's rendition lookup
        // misses.  actool writes them next to the .car; xtool is responsible for
        // copying them into the bundle, same as for the .car.
        for loose in bundle.looseFiles {
            let url = compileDir.appendingPathComponent(loose.name)
            try loose.data.write(to: url)
            log("wrote loose \(url.path) (\(loose.data.count) bytes)")
        }

        if let partial = options.outputPartialInfoPlist {
            try write(bundle.infoPlistAdditions, to: partial)
            log("wrote partial plist \(partial.path) with keys \(bundle.infoPlistAdditions.keys.sorted())")
        } else if let directory = options.outputPartialInfoPlistDirectory {
            let partial = directory.appendingPathComponent("actool_app_summary.plist")
            try write(bundle.infoPlistAdditions, to: partial)
            log("wrote partial plist \(partial.path)")
        }

        discard(merged)
    }

    static func write(_ additions: [String: any Sendable], to url: URL) throws {
        var plist: [String: Any] = [:]
        for (key, value) in additions { plist[key] = value }
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist, format: .binary, options: 0)
        try data.write(to: url)
    }

    /// actool compiles every input catalog together, so several `.xcassets`
    /// arguments become one catalog before rendering.
    static func merge(catalogs: [URL], into destination: URL) throws {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: destination)
        try fileManager.createDirectory(
            at: destination, withIntermediateDirectories: true)
        try PropertyListSerialization.data(
            fromPropertyList: ["info": ["author": "assetkit-cli", "version": 1]],
            format: .xml, options: 0
        ).write(to: destination.appendingPathComponent("Contents.json"))

        guard catalogs.count > 1 else {
            let only = catalogs[0]
            guard only.lastPathComponent.hasSuffix(".xcassets") else {
                // actool also accepts a directory holding several catalogs.
                let children = try fileManager.contentsOfDirectory(
                    at: only, includingPropertiesForKeys: nil)
                    .filter { $0.lastPathComponent.hasSuffix(".xcassets") }
                for child in children {
                    try fileManager.copyItem(at: child, to: destination.appendingPathComponent(child.lastPathComponent))
                }
                return
            }
            try fileManager.copyItem(at: only, to: destination.appendingPathComponent(only.lastPathComponent))
            return
        }

        for catalog in catalogs {
            let child = destination.appendingPathComponent(
                "\(catalog.deletingPathExtension().lastPathComponent)-\(catalog.lastPathComponent)")
            try fileManager.copyItem(at: catalog, to: child)
        }
    }
}
