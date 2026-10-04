import Foundation
import ImageIO
import ZIPFoundation

/// What one descriptor's conversion produced, as the reference's result dicts.
///
/// The Python version returns bare dictionaries and the callers index into them
/// (`item.get('wallpaper')`, `item.get('screen')`), which is why a flattened-only
/// entry prints `to None` in its log line. A struct cannot be indexed like that,
/// so the keys became properties and the two optional ones — `screen` and
/// `changed_files` — stayed optional, `flattened` and `dry_run` became flags.
struct PosterBoardConversion: Hashable {
    /// The descriptor folder the conversion ran in.
    let descriptor: String
    /// The `.wallpaper` bundle's file name, after any rename.
    var wallpaper: String
    /// `WxH@Sx`, present only for a full conversion.
    var screen: String?
    /// The plane roles, or for a sanitize-only pass the plane folder names.
    var planes: [String]
    /// Every file rewritten, present only for a full conversion.
    var changedFiles: [String]?
    /// The package was already modern and only had its trapping planes flattened.
    var flattened = false
    /// Nothing was written.
    var isDryRun = false

    /// The reference's `f"{wallpaper} -> {screen or '?'} planes={planes}"`.
    var summary: String {
        (isDryRun ? "[dry] " : "") + "\(wallpaper) -> \(screen ?? "?") planes=\(planes)"
    }

    /// The reference's two `print()`s in `apply_tweak`.
    ///
    /// A sanitize-only entry has no screen, and upstream prints `None` there
    /// because the key is simply absent from the dict. It is a log line, so it is
    /// spelled out rather than reproduced — "to None" reads like a failure.
    var convertedLine: String {
        flattened
            ? "Sanitized \(wallpaper) (flattened \(planes.joined(separator: ", ")))"
            : "Converted legacy wallpaper \(wallpaper) to \(screen ?? "?") "
                + "(planes=\(planes.joined(separator: ", ")))"
    }

    var renamedLine: String {
        "Renamed wallpaper to \(wallpaper) (planes=\(planes.joined(separator: ", ")))"
    }
}

/// Legacy `.tendies` → modern iOS 27 ("Clownfish") shape.
///
/// A port of `src/tweaks/posterboard/posterboard_converter.py`. The reason any
/// of this exists: PosterKit only builds the Depth effect for a package in the
/// modern layout, so a pre-iOS 27 pack imports as a flat animation with no depth
/// no matter what else is configured. The modern layout means
///
///   * every plane's `index.xml` declares `publishedObjectNames`;
///   * the plane's `main.caml` root `CALayer` carries a matching `id` — iOS 27
///     resolves the floating layer from that name and collapses the view into the
///     foreground when no matching layer exists;
///   * the document is the logical screen with `scalesToFitInPlayer` and
///     `unitsInPixelsInPlayer` cleared;
///   * the version's `contents` folder carries a `configurableOptions` plist with
///     a `preferredRenderingConfiguration`, and the version folder a
///     `renderingConfiguration` plist — a third-party pack ships neither;
///   * `Wallpaper.plist` is re-stamped `family = Clownfish` and carries
///     `contentVersion` / `disableAdaptiveTime` / `maximumAdaptiveTimeMultiplier`.
///   * and the bundle and plane folders carry the stock
///     `<assetId>.<Family>-<class>.wallpaper` names, because WallpaperKit builds
///     the view from the on-disk name and traps without them.
///
/// Everything is pure file I/O on an extracted tree; the device is only touched
/// later, by the ordinary apply. The two families that must never be rewritten are
/// handled rather than trusted: a plane whose CAML uses a state op the depth
/// renderer traps on is flattened to a static image, and an external
/// `<scriptObject>` is always stripped — both of those make
/// `WKPlatformPackageView` raise `EXC_BREAKPOINT`, which trips the
/// CollectionsPoster crash cooldown and kills snapshots and Depth for *every*
/// wallpaper on the device, not just this one.
///
/// Only the import path is ported. `conversion_action` / `is_mercury` belong to
/// the "Rebuild Database" flow (`posterboard_rebuild.py`), which repacks what is
/// already on the device; they are here because they are two functions and the
/// next port needs them, and `convertTree` deliberately does *not* consult them —
/// upstream converts every legacy descriptor on import regardless of family.
enum PosterBoardConverter {
    // MARK: - Constants

    static let modernContentVersion = 1.01
    static let defaultMaxAdaptiveTimeMultiplier = 2.0

    /// The family whose renderer builds the Depth effect. A legacy
    /// Marble/Lavender descriptor stays flat even with published layers and the
    /// depth plists until it is re-stamped as Clownfish.
    static let clownfishFamily = "Clownfish"

    /// PosterKit reads these two archiver plists when it decides whether depth is
    /// allowed. A third-party wallpaper ships without either.
    static let configurableOptionsName =
        ".com.apple.posterkit.provider.contents.configurableOptions.plist"
    static let renderingConfigurationName =
        "com.apple.posterkit.provider.instance.renderingConfiguration.plist"

    /// Spatial photo posters: a different layout entirely (axonometric 3D, no
    /// floating/background planes). Never rewritten.
    static let mercuryProvider = "com.apple.MercuryPoster"
    static let mercuryFamily = "Mercury"

    /// The flat Apple families that ship without a published layer on iOS 27.
    /// Only these are repacked by the rebuild flow; the import path converts
    /// anything legacy.
    static let repackFamilies: Set<String> = ["Marble", "Lavender"]

    enum ConversionAction: String {
        case keep, repack, skip
    }

    // MARK: - Regexes

    /// `NSRegularExpression` built once. The port has no other regex-heavy core
    /// file, so there is no shared helper to reuse here.
    private static func regex(_ pattern: String) -> NSRegularExpression {
        // Force-unwrap is wrong in general and right here: every pattern in this
        // file is a literal, and a typo should be a crash at first use, not a
        // silently dead match.
        try! NSRegularExpression(pattern: pattern)
    }

    private static let logicalScreenRE = regex(#"^(\d+)w-(\d+)h@(\d+)x"#)
    /// ``^(\d+)w-(\d+)h@(\d+)x`` — note the reference's `--screen` help text says
    /// `393x852@3` while the pattern wants `393w-852h@3x`, so the documented form
    /// raises in the reference and the documented-as-working form is this one.
    private static let selfClosingLayerRE = regex(#"<CALayer\b[^>]*/>"#)
    private static let rootLayerRE = regex(#"<CALayer\b[^>]*>"#)
    private static let backgroundColorAttrRE = regex(#"backgroundColor="([^"]+)""#)
    private static let backgroundColorElementRE =
        regex(#"<backgroundColor\b[^>]*\bvalue="([^"]+)""#)

    /// State ops the depth renderer traps on. `LKStateAddElement` builds a layer
    /// tree at state-apply time and `CAMeshTransform` carries a mesh value the
    /// renderer cannot decode; neither appears in any working stock or repacked
    /// descriptor.
    private static let unsupportedCAMLRE = regex(
        #"<LKStateAddElement\b|<LKStateRemoveElement\b|\bCAMeshTransform\b|(?:^|[\s\"])meshTransform\s*="#)
    /// External JavaScript `<scriptObject src="...">` nodes, self-closing or with
    /// a body. The stock Clownfish and Odyssey descriptors carry only an empty
    /// `<scriptComponents/>`, so removing it costs nothing.
    private static let scriptObjectRE = regex(
        #"<scriptObject\b[^>]*?/>|<scriptObject\b[^>]*?>.*?</scriptObject>"#, options: [.dotMatchesLineSeparators])

    static func hasUnsupportedCAML(_ text: String) -> Bool {
        unsupportedCAMLRE.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    static func stripScripts(_ text: String) -> String {
        scriptObjectRE.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                               withTemplate: "")
    }

    static func hasExternalScript(_ text: String) -> Bool {
        scriptObjectRE.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static let imageExtensions = ["png", "jpg", "jpeg", "heic", "heif"]

    // MARK: - CAML templates

    private static let micaAssetManifest = """
        <?xml version="1.0" encoding="UTF-8"?>

        <caml xmlns="http://www.apple.com/CoreAnimation/1.0">
          <MicaAssetManifest>
            <modules type="NSArray"/>
          </MicaAssetManifest>
        </caml>

        """

    /// A flattened plane: one full-screen image layer in the document space.
    private static func flatPlaneCAML(role: String, image: String,
                                     width: Double, height: Double) -> String {
        // `%g` is Python's `{width:g}`: the shortest form that round-trips, so
        // 390 stays "390" and 852.5 stays "852.5".
        func g(_ value: Double) -> String { String(format: "%g", value) }
        return """
            <?xml version="1.0" encoding="UTF-8"?>

            <caml xmlns="http://www.apple.com/CoreAnimation/1.0">
              <CALayer id="\(role)" allowsEdgeAntialiasing="1" allowsGroupOpacity="1" bounds="0 0 \(g(width)) \(g(height))" contentsFormat="RGBA8" cornerCurve="circular" geometryFlipped="1" hidden="0" name="Root Layer" position="\(g(width / 2)) \(g(height / 2))">
                <sublayers>
                  <CALayer allowsEdgeAntialiasing="1" allowsGroupOpacity="1" bounds="0 0 \(g(width)) \(g(height))" contentsFormat="RGBA8" cornerCurve="circular" name="\(xmlAttr(image))" position="\(g(width / 2)) \(g(height / 2))">
                    <contents type="CGImage" src="assets/\(xmlAttr(image))"/>
                  </CALayer>
                </sublayers>
              </CALayer>
            </caml>

            """
    }

    /// What a plane with no usable asset becomes: a published but empty root.
    private static func emptyPlaneCAML(role: String, width: Double, height: Double) -> String {
        func g(_ value: Double) -> String { String(format: "%g", value) }
        return """
            <?xml version="1.0" encoding="UTF-8"?>

            <caml xmlns="http://www.apple.com/CoreAnimation/1.0">
              <CALayer id="\(role)" allowsEdgeAntialiasing="1" allowsGroupOpacity="1" bounds="0 0 \(g(width)) \(g(height))" contentsFormat="RGBA8" cornerCurve="circular" geometryFlipped="0" hidden="0" name="\(role)" position="\(g(width / 2)) \(g(height / 2))"/>
            </caml>

            """
    }

    // MARK: - Names and screen sizes

    /// `"390w-844h@3x~iphone"` → `(390, 844, 3)`, or nil when unparsable.
    static func parseLogicalScreenClass(_ value: String?)
        -> (width: Int, height: Int, scale: Int)? {
        guard let value, !value.isEmpty else { return nil }
        let range = NSRange(value.startIndex..., in: value)
        guard let match = logicalScreenRE.firstMatch(in: value, range: range),
              match.numberOfRanges == 4,
              let width = Int(value[Range(match.range(at: 1), in: value)!]),
              let height = Int(value[Range(match.range(at: 2), in: value)!]),
              let scale = Int(value[Range(match.range(at: 3), in: value)!]) else { return nil }
        return (width, height, scale)
    }

    /// A plane folder name → `Background` / `Floating` / `Foreground`.
    ///
    /// Split on non-letters rather than matched whole, so `BG-391x852`,
    /// `…_Background-390w-844h@3x~iphone.ca` and `fg.ca` all land. A plane whose
    /// name yields nil is skipped everywhere downstream — the reference's rule,
    /// and the reason a `video-descriptor.ca` is left alone.
    static func planeRole(_ pathName: String) -> String? {
        var name = pathName.split(separator: "/").last.map(String.init)?.lowercased() ?? ""
        if name.hasSuffix(".ca") { name = String(name.dropLast(3)) }
        let tokens = name.split(whereSeparator: { !($0 >= "a" && $0 <= "z") }).map(String.init)
        if tokens.contains("foreground") || tokens.contains("fg") { return "Foreground" }
        if tokens.contains("floating") || tokens.contains("fl") { return "Floating" }
        if tokens.contains("background") || tokens.contains("bg") { return "Background" }
        return nil
    }

    // MARK: - Tiny XML/plist helpers

    /// The reference's `_get_attr`: `\bname="([^"]*)"`.
    static func xmlAttribute(_ tag: String, _ name: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: "\\b" + NSRegularExpression.escapedPattern(for: name) + #"="([^"]*)""#) else { return nil }
        let range = NSRange(tag.startIndex..., in: tag)
        guard let match = regex.firstMatch(in: tag, range: range),
              let captured = Range(match.range(at: 1), in: tag) else { return nil }
        return String(tag[captured])
    }

    /// The reference's `_set_attr`: replace the first occurrence, else append
    /// before the tag's last `>`.
    ///
    /// The append case inherits a quirk worth naming: for a self-closing root
    /// (`<CALayer … />`) the last `>` belongs to the `/>`, so the attribute lands
    /// *after* the slash. Upstream does exactly this and the packs that hit it
    /// work, so it is reproduced rather than "fixed" — a fix would be a
    /// behavioural difference in a file this port exists to keep identical.
    static func settingXMLAttribute(_ tag: String, _ name: String, _ value: String) -> String {
        let pattern = "\\b" + NSRegularExpression.escapedPattern(for: name) + #"="[^"]*""#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)) else {
            guard let end = tag.range(of: ">", options: .backwards) else { return tag }
            let head = tag[tag.startIndex..<end.lowerBound]
            let tail = tag[end.lowerBound...]
            return head + " \(name)=\"\(value)\"" + tail
        }
        let range = Range(match.range, in: tag)!
        return tag.replacingCharacters(in: range, with: "\(name)=\"\(value)\"")
    }

    /// Escape a value for an XML attribute (`&`, `"`, `<`, `>`, in that order).
    static func xmlAttr(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func regex(_ pattern: String, options: NSRegularExpression.Options) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    /// The whole contents of one zip entry.
    ///
    /// ZIPFoundation streams through a consumer instead of returning bytes, and
    /// its read overload insists on a positive buffer size, so "the entry as
    /// `Data`" is four lines rather than one.
    static func data(of entry: Entry, in archive: Archive) throws -> Data {
        var out = Data()
        _ = try archive.extract(entry, bufferSize: defaultReadChunkSize) { out.append($0) }
        return out
    }

    /// Read a text file the reference's way: UTF-8, undecodable bytes dropped.
    ///
    /// `String(decoding:as:)` substitutes U+FFFD where CPython's
    /// `errors="ignore"` deletes the bytes. CAML and plist XML in the wild is
    /// ASCII, and a lossy read is the one that cannot abort a conversion
    /// half-way — an `ignore` read that throws would.
    static func readText(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    @discardableResult
    static func writeText(_ text: String, to url: URL) -> Bool {
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    /// `plistlib.load`, reduced to the reference's contract: a dict, or `{}`.
    static func readPlist(_ url: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: url),
              let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = object as? [String: Any] else { return [:] }
        return dict
    }

    /// `plistlib.dump(fmt=FMT_BINARY)`.
    static func writePlist(_ object: Any, to url: URL) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: object, format: .binary, options: 0)
        try data.write(to: url, options: .atomic)
    }

    /// `NSNumber`/`Bool` → `Double`, without `as? Double`'s Bool surprise.
    private static func number(_ value: Any?) -> Double? {
        guard let value, CFGetTypeID(value as CFTypeRef) != CFBooleanGetTypeID() else { return nil }
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        if let number = value as? NSNumber { return number.doubleValue }
        return nil
    }

    // MARK: - Layout discovery

    /// The descriptor's `.wallpaper` bundle, first `.wallpaper` directory in the
    /// first version folder that has one.
    static func findWallpaperDir(_ descriptorDir: URL) -> URL? {
        let versions = descriptorDir.appendingPathComponent("versions", isDirectory: true)
        guard isDirectory(versions) else { return nil }
        for version in (try? FileManager.default.contentsOfDirectory(atPath: versions.path))?.sorted() ?? [] {
            let contents = versions.appendingPathComponent(version, isDirectory: true)
                .appendingPathComponent("contents", isDirectory: true)
            guard isDirectory(contents) else { continue }
            for name in (try? FileManager.default.contentsOfDirectory(atPath: contents.path))?.sorted() ?? [] {
                guard name.hasSuffix(".wallpaper") else { continue }
                let candidate = contents.appendingPathComponent(name, isDirectory: true)
                if isDirectory(candidate) { return candidate }
            }
        }
        return nil
    }

    /// Every `.ca` directory in the bundle, in name order.
    static func planeDirs(_ wallpaperDir: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(atPath: wallpaperDir.path))?.sorted() ?? [])
            .filter { $0.hasSuffix(".ca") }
            .map { wallpaperDir.appendingPathComponent($0, isDirectory: true) }
            .filter { isDirectory($0) }
    }

    static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        return exists && isDir.boolValue
    }

    static func isModernPlane(_ planeDir: URL) -> Bool {
        readPlist(planeDir.appendingPathComponent("index.xml")).keys.contains("publishedObjectNames")
    }

    /// True when the descriptor has wallpaper planes but none is published.
    static func isLegacyDescriptor(_ descriptorDir: URL) -> Bool {
        guard let wallpaperDir = findWallpaperDir(descriptorDir) else { return false }
        let planes = planeDirs(wallpaperDir)
        guard !planes.isEmpty else { return false }
        return !planes.contains { isModernPlane($0) }
    }

    /// `Wallpaper.plist`'s `family`, if any.
    static func wallpaperFamily(_ descriptorDir: URL) -> String? {
        guard let wallpaperDir = findWallpaperDir(descriptorDir) else { return nil }
        guard let family = readPlist(wallpaperDir.appendingPathComponent("Wallpaper.plist"))["family"] else {
            return nil
        }
        return String(describing: family)
    }

    /// The pre-iOS 27 packages inside a `.tendies`, read straight out of the zip.
    ///
    /// Read from the archive rather than from an extracted tree so the import
    /// prompt can be answered before anything is staged for a restore.
    ///
    /// Note the deliberate asymmetry with `isLegacyDescriptor`: this tests the
    /// **raw text** of `index.xml` for `publishedObjectNames`, while
    /// `isModernPlane` parses the plist and looks for the key. Upstream does the
    /// same, and it means an index.xml that mentions the name in a comment counts
    /// as modern here and legacy there. Reproduced, not fixed.
    static func legacyFamilies(ofPack packURL: URL) throws -> [String] {
        let archive: Archive
        do {
            archive = try Archive(url: packURL, accessMode: .read)
        } catch {
            throw GoldenNuggetError("\(packURL.lastPathComponent) is not a readable .tendies "
                + "archive: \(error.localizedDescription)")
        }
        var bundles: Set<String> = []
        var indexes: [String: [String]] = [:]
        var plists: [String: Data] = [:]

        for entry in archive {
            let normalized = entry.path.replacingOccurrences(of: "\\", with: "/")
            let lowered = normalized.lowercased()
            if lowered.contains("__macosx/") || normalized.split(separator: "/").last.map(String.init)?
                .hasPrefix("._") == true { continue }
            let parts = normalized.split(separator: "/").map(String.init)
            guard let cut = parts.firstIndex(where: { $0.hasSuffix(".wallpaper") }) else { continue }
            let bundle = parts[0...cut].joined(separator: "/")
            bundles.insert(bundle)
            let tail = parts[(cut + 1)...].joined(separator: "/")
            if tail.hasSuffix("/index.xml") {
                let data = try data(of: entry, in: archive)
                indexes[bundle, default: []].append(String(decoding: data, as: UTF8.self))
            } else if tail == "Wallpaper.plist" {
                plists[bundle] = try data(of: entry, in: archive)
            }
        }

        var families: [String] = []
        for bundle in bundles.sorted() {
            let planes = indexes[bundle] ?? []
            if planes.isEmpty || planes.contains(where: { $0.contains("publishedObjectNames") }) { continue }
            var family = ""
            if let raw = plists[bundle],
               let object = try? PropertyListSerialization.propertyList(from: raw, options: [], format: nil),
               let dict = object as? [String: Any],
               let value = dict["family"] {
                family = String(describing: value)
            }
            families.append(family.isEmpty ? (bundle.split(separator: "/").last.map(String.init) ?? bundle) : family)
        }
        return families
    }

    /// A Mercury (spatial photo) package, by provider path or by family.
    static func isMercury(_ descriptorDir: URL) -> Bool {
        if descriptorDir.path.contains(mercuryProvider) { return true }
        guard let family = wallpaperFamily(descriptorDir) else { return false }
        return family.lowercased() == mercuryFamily.lowercased()
    }

    /// Whether a **device** descriptor should be repacked to Clownfish.
    ///
    /// Used by the rebuild flow only. The import path does not consult it:
    /// `convertTree` converts every legacy descriptor it finds, which is what
    /// upstream does on import too.
    static func conversionAction(for descriptorDir: URL,
                                 repackFamilies families: Set<String> = repackFamilies) -> ConversionAction {
        if isMercury(descriptorDir) { return .skip }
        if !isLegacyDescriptor(descriptorDir) { return .keep }
        if let family = wallpaperFamily(descriptorDir), families.contains(family) { return .repack }
        return .keep
    }

    // MARK: - Plane surgery

    /// The largest image asset in a plane, used as a flattened static frame.
    static func pickPlaneImage(_ planeDir: URL) -> String? {
        let assets = planeDir.appendingPathComponent("assets", isDirectory: true)
        guard isDirectory(assets) else { return nil }
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: assets.path) else { return nil }
        // `max(candidates)` on (size, name) tuples, so a size tie is broken by
        // the larger name — reproduced rather than left to dictionary order.
        var best: (size: Int, name: String)?
        for name in names {
            let lower = name.lowercased()
            guard imageExtensions.contains(where: { lower.hasSuffix(".\($0)") }) else { continue }
            let url = assets.appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue,
                  let attributes = try? fm.attributesOfItem(atPath: url.path),
                  let size = attributes[.size] as? Int else { continue }
            if best == nil || (size, name) > (best!.size, best!.name) { best = (size, name) }
        }
        return best?.name
    }

    /// A static single-image CAML for a plane whose states the renderer traps on.
    static func flattenPlane(role: String, planeDir: URL,
                             width: Double = 393.0, height: Double = 852.0) -> String {
        guard let image = pickPlaneImage(planeDir) else {
            return emptyPlaneCAML(role: role, width: width, height: height)
        }
        return flatPlaneCAML(role: role, image: image, width: width, height: height)
    }

    /// `"0.02684 0.1512 0.2793"` → `(7, 39, 71)`, clamped per channel.
    static func rgb(fromComponents value: String) -> (Int, Int, Int)? {
        let parts = value.split(whereSeparator: \.isWhitespace).map(String.init)
        guard parts.count >= 3 else { return nil }
        var channels: [Int] = []
        for part in parts.prefix(3) {
            guard let channel = Double(part) else { return nil }
            channels.append(Int((min(max(channel, 0), 1) * 255).rounded()))
        }
        return (channels[0], channels[1], channels[2])
    }

    /// The first opaque solid colour in a plane's CAML.
    ///
    /// A sublayer's `backgroundColor` attribute wins over the root's
    /// `<backgroundColor>` element, because the source often leaves the element at
    /// opacity 0 and the attribute is the visible fill.
    static func solidBackgroundColor(of text: String) -> (r: Int, g: Int, b: Int)? {
        let full = NSRange(text.startIndex..., in: text)
        for match in backgroundColorAttrRE.matches(in: text, range: full) {
            guard let range = Range(match.range(at: 1), in: text) else { continue }
            if let rgb = rgb(fromComponents: String(text[range])) {
                return (rgb.0, rgb.1, rgb.2)
            }
        }
        for match in backgroundColorElementRE.matches(in: text, range: full) {
            guard let range = Range(match.range(at: 1), in: text) else { continue }
            if let rgb = rgb(fromComponents: String(text[range])) {
                return (rgb.0, rgb.1, rgb.2)
            }
        }
        return nil
    }

    /// Give the last empty sublayer a real CGImage, leaving the CAML intact.
    static func injectingContents(_ text: String, image: String) -> String {
        let matches = selfClosingLayerRE.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard let last = matches.last, let matchRange = Range(last.range, in: text) else { return text }
        let tag = String(text[matchRange])
        guard tag.hasSuffix("/>") else { return text }
        let head = String(tag.dropLast(2))
        let injected = head + "><contents type=\"CGImage\" src=\"assets/\(xmlAttr(image))\"/></CALayer>"
        var out = text
        out.replaceSubrange(matchRange, with: injected)
        return out
    }

    /// Render a colour-only plane's fill to a PNG and publish it as its image.
    ///
    /// A plane that paints only a solid `backgroundColor` ships no `<contents>`
    /// image, and the depth renderer force-unwraps the published Background
    /// layer's image and traps when it is missing. Every working stock and
    /// repacked Clownfish background carries a real CGImage, so the fill is
    /// rendered at document size and injected.
    ///
    /// Returns the rewritten `main.caml`, or nil when the plane already has an
    /// image or paints no solid colour.
    @discardableResult
    static func ensureBackgroundImage(planeDir: URL, role: String,
                                      docWidth: Double, docHeight: Double) -> URL? {
        let mainCAML = planeDir.appendingPathComponent("main.caml")
        guard let text = readText(mainCAML) else { return nil }
        guard !text.contains("<contents") else { return nil }
        guard let color = solidBackgroundColor(of: text) else { return nil }

        let image = "solid_\(role.lowercased()).png"
        let assets = planeDir.appendingPathComponent("assets", isDirectory: true)
        try? FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        let width = max(1, Int(docWidth.rounded()))
        let height = max(1, Int(docHeight.rounded()))
        guard writeSolidColorPNG(to: assets.appendingPathComponent(image), rgb: color,
                                 width: width, height: height) else { return nil }

        let rewritten = injectingContents(text, image: image)
        guard rewritten != text else { return nil }
        guard writeText(rewritten, to: mainCAML) else { return nil }
        return mainCAML
    }

    /// The reference's `Image.new("RGB", size, color).save(path)`.
    ///
    /// CoreGraphics rather than `UIGraphicsImageRenderer`: this runs on whatever
    /// queue the apply is on, and the renderer is a main-actor API.
    ///
    /// `canImport` rather than an unconditional call so the converter can be
    /// compiled and exercised by a host-side test harness — the rest of the file
    /// is plain Foundation, and this is the only part of it that is not.
    #if canImport(ImageIO) && canImport(CoreGraphics)
    private static func writeSolidColorPNG(to url: URL, rgb: (Int, Int, Int),
                                           width: Int, height: Int) -> Bool {
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
        context.setFillColor(CGColor(red: CGFloat(rgb.0) / 255, green: CGFloat(rgb.1) / 255,
                                     blue: CGFloat(rgb.2) / 255, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let cgImage = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(destination, cgImage, nil)
        return CGImageDestinationFinalize(destination)
    }
    #else
    private static func writeSolidColorPNG(to url: URL, rgb: (Int, Int, Int),
                                           width: Int, height: Int) -> Bool { false }
    #endif

    /// Sanitize every plane of a descriptor, in place.
    ///
    /// Flattens any plane carrying a trapping CAML state op and strips the
    /// external `<scriptObject>` from every plane. Called for already-modern
    /// descriptors too: a third-party pack can publish its layers and still carry
    /// a script that crashes.
    @discardableResult
    static func flattenUnsupportedPlanes(_ descriptorDir: URL) -> [URL] {
        guard let wallpaperDir = findWallpaperDir(descriptorDir) else { return [] }
        let parsed = parseLogicalScreenClass(
            readPlist(wallpaperDir.appendingPathComponent("Wallpaper.plist"))["logicalScreenClass"] as? String)
        // The reference's fallback here is 393x852@3 while `convertDescriptor`'s is
        // 390x844@3. Both are reproduced: they disagree upstream, and picking one
        // would silently change the document size of a pack whose
        // `logicalScreenClass` is missing.
        let screen = parsed ?? (393, 852, 3)

        var written: [URL] = []
        for planeDir in planeDirs(wallpaperDir) {
            guard let role = planeRole(planeDir.path) else { continue }
            let mainCAML = planeDir.appendingPathComponent("main.caml")
            guard let original = readText(mainCAML) else { continue }
            let text = stripScripts(original)
            if hasUnsupportedCAML(text) {
                if writeText(flattenPlane(role: role, planeDir: planeDir,
                                          width: Double(screen.width), height: Double(screen.height)), to: mainCAML) {
                    written.append(mainCAML)
                }
            } else if text != original {
                if writeText(text, to: mainCAML) { written.append(mainCAML) }
            }
        }
        return written
    }

    // MARK: - Modernising

    /// The plane document as the reference writes it after conversion.
    private static func modernIndexXML(docWidth: Double, docHeight: Double, role: String) -> String {
        func real(_ value: Double) -> String { "\(value)" }
        return """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
            	<key>assetManifest</key>
            	<string>assetManifest.caml</string>
            	<key>documentHeight</key>
            	<real>\(real(docHeight))</real>
            	<key>documentResizesToView</key>
            	<false/>
            	<key>documentWidth</key>
            	<real>\(real(docWidth))</real>
            	<key>dynamicGuidesEnabled</key>
            	<true/>
            	<key>geometryFlipped</key>
            	<false/>
            	<key>guidesEnabled</key>
            	<true/>
            	<key>interactiveMouseEventsEnabled</key>
            	<true/>
            	<key>interactiveShowsCursor</key>
            	<true/>
            	<key>interactiveTouchEventsEnabled</key>
            	<false/>
            	<key>loopEnd</key>
            	<real>+infinity</real>
            	<key>loopStart</key>
            	<real>0.0</real>
            	<key>loopingEnabled</key>
            	<true/>
            	<key>multitouchDisablesMouse</key>
            	<false/>
            	<key>multitouchEnabled</key>
            	<false/>
            	<key>plugins</key>
            	<array/>
            	<key>presentationMouseEventsEnabled</key>
            	<true/>
            	<key>presentationShowsCursor</key>
            	<true/>
            	<key>presentationTouchEventsEnabled</key>
            	<false/>
            	<key>publishedObjectNames</key>
            	<array>
            		<string>\(role)</string>
            	</array>
            	<key>rootDocument</key>
            	<string>main.caml</string>
            	<key>savesWindowFrame</key>
            	<false/>
            	<key>scalesToFitInPlayer</key>
            	<true/>
            	<key>showsTouches</key>
            	<true/>
            	<key>snappingEnabled</key>
            	<true/>
            	<key>timelineMarkers</key>
            	<string>[(null)]</string>
            	<key>touchesColor</key>
            	<string>1 1 0 0.8</string>
            	<key>unitsInPixelsInPlayer</key>
            	<false/>
            </dict>
            </plist>

            """
    }

    /// The scale that fits the root canvas onto the document.
    ///
    /// Only a pixel canvas needs it: a points-based plane already shares the
    /// screen's coordinate space and the player's `scalesToFitInPlayer` handles
    /// the last few points, so scaling it again would drift the artwork.
    static func fitScale(tag: String, docWidth: Double, docHeight: Double,
                         unitsInPixels: Bool, pixelScale: Int) -> Double {
        guard unitsInPixels else { return 1.0 }
        var oldWidth = docWidth
        var oldHeight = docHeight
        if let bounds = xmlAttribute(tag, "bounds") {
            let parts = bounds.split(whereSeparator: \.isWhitespace).map(String.init)
            if parts.count >= 4, let width = Double(parts[2]), let height = Double(parts[3]) {
                oldWidth = width
                oldHeight = height
            }
        }
        let divisor = pixelScale == 0 ? 1.0 : Double(pixelScale)
        let pointWidth = oldWidth / divisor
        let pointHeight = oldHeight / divisor
        guard pointWidth > 0, pointHeight > 0 else { return 1.0 }
        return max(docWidth / pointWidth, docHeight / pointHeight)
    }

    static func addingScale(_ tag: String, scale: Double) -> String {
        guard abs(scale - 1.0) > 1e-6 else { return tag }
        let existing = (xmlAttribute(tag, "transform") ?? "").trimmingCharacters(in: .whitespaces)
        var transform = existing.isEmpty ? "" : existing + " "
        transform += String(format: "scale(%.6f, %.6f, 1)", scale, scale)
        return settingXMLAttribute(tag, "transform", transform)
    }

    /// Publish the plane root layer and fit its canvas to the document.
    ///
    /// The legacy root holds the whole plane content and its script, and its own
    /// `LKStateSetValue` entries point at that root's existing `id` (usually
    /// `#1`). So the root becomes the published layer: its `id` is set to the role
    /// and every internal `targetId` is repointed at it, while `name` and
    /// `position` are left alone. Only a pixel canvas gets a fit scale.
    static func modernizingMainCAML(_ text: String, role: String,
                                    docWidth: Double, docHeight: Double,
                                    unitsInPixels: Bool, pixelScale: Int) throws -> String {
        let full = NSRange(text.startIndex..., in: text)
        guard let match = rootLayerRE.firstMatch(in: text, range: full),
              let matchRange = Range(match.range, in: text) else {
            throw GoldenNuggetError("main.caml has no root CALayer")
        }
        let tag = String(text[matchRange])
        let oldID = xmlAttribute(tag, "id")
        var newTag = settingXMLAttribute(tag, "id", role)
        newTag = addingScale(newTag, scale: fitScale(tag: tag, docWidth: docWidth, docHeight: docHeight,
                                                     unitsInPixels: unitsInPixels, pixelScale: pixelScale))
        var out = text
        if let oldID, oldID != role {
            out = out.replacingOccurrences(of: "targetId=\"\(oldID)\"", with: "targetId=\"\(role)\"")
        }
        out.replaceSubrange(matchRange, with: newTag)
        return out
    }

    /// Whether the plane's document is in pixels rather than points.
    static func planeUnits(_ index: [String: Any], logicalWidth: Int) -> Bool {
        if let value = index["unitsInPixelsInPlayer"],
           CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID(),
           let flag = value as? Bool {
            return flag
        }
        if let docWidth = number(index["documentWidth"]), logicalWidth != 0 {
            return docWidth > Double(logicalWidth) + 1.0
        }
        return true
    }

    /// Modernise one plane, in place. Returns the files it wrote.
    @discardableResult
    static func modernizePlane(_ planeDir: URL, role: String,
                               docWidth: Double, docHeight: Double,
                               logicalWidth: Int, pixelScale: Int) throws -> [URL] {
        let index = readPlist(planeDir.appendingPathComponent("index.xml"))
        let unitsInPixels = planeUnits(index, logicalWidth: logicalWidth)
        let mainCAML = planeDir.appendingPathComponent("main.caml")
        guard let original = readText(mainCAML) else {
            throw GoldenNuggetError("\(planeDir.lastPathComponent) has no main.caml")
        }
        let stripped = stripScripts(original)
        let text: String
        if hasUnsupportedCAML(stripped) {
            // Publishing the root would keep the trapping state op and crash the
            // depth renderer for every wallpaper; flatten to a static frame.
            text = flattenPlane(role: role, planeDir: planeDir, width: docWidth, height: docHeight)
        } else {
            text = try modernizingMainCAML(stripped, role: role, docWidth: docWidth, docHeight: docHeight,
                                           unitsInPixels: unitsInPixels, pixelScale: pixelScale)
        }
        writeText(text, to: mainCAML)
        // A colour-only plane carries no image and traps the depth renderer.
        ensureBackgroundImage(planeDir: planeDir, role: role, docWidth: docWidth, docHeight: docHeight)

        let indexPath = planeDir.appendingPathComponent("index.xml")
        writeText(modernIndexXML(docWidth: docWidth, docHeight: docHeight, role: role), to: indexPath)

        var written = [mainCAML, indexPath]
        let manifest = planeDir.appendingPathComponent("assetManifest.caml")
        if !FileManager.default.fileExists(atPath: manifest.path), writeText(micaAssetManifest, to: manifest) {
            written.append(manifest)
        }
        return written
    }

    /// Add the modern keys and point the asset entries at the real plane folders.
    ///
    /// `family` is switched to `Clownfish` — the family whose renderer enables
    /// Depth. A legacy Marble/Lavender/WWDC22 descriptor keeps rendering flat
    /// even with published layers and the depth plists, while the same content
    /// stamped Clownfish gets Depth. The human-readable `name` is left alone.
    static func modernizeWallpaperPlist(_ wallpaperDir: URL,
                                        maxMultiplier: Double = defaultMaxAdaptiveTimeMultiplier) throws {
        let path = wallpaperDir.appendingPathComponent("Wallpaper.plist")
        var data = readPlist(path)
        guard !data.isEmpty else { throw GoldenNuggetError("\(path.lastPathComponent) is missing or unreadable") }

        data["family"] = clownfishFamily
        // `setdefault`, so a package that already carries these keeps its own
        // values — including a `contentVersion` of 2.06, which a video flow
        // descriptor sets and which must survive the repack.
        if data["contentVersion"] == nil { data["contentVersion"] = modernContentVersion }
        if data["disableAdaptiveTime"] == nil { data["disableAdaptiveTime"] = true }
        if data["maximumAdaptiveTimeMultiplier"] == nil {
            data["maximumAdaptiveTimeMultiplier"] = maxMultiplier
        }

        var assets = data["assets"] as? [String: Any] ?? [:]
        var lockAndHome = assets["lockAndHome"] as? [String: Any] ?? [:]
        var payload = lockAndHome["default"] as? [String: Any] ?? [:]
        if payload["type"] == nil { payload["type"] = "LayeredAnimation" }

        var planes: [String: String] = [:]
        for planeDir in planeDirs(wallpaperDir) {
            if let role = planeRole(planeDir.path) { planes[role] = planeDir.lastPathComponent }
        }

        // The primary/alternate pairing is the reference's and looks arbitrary:
        // Background and Foreground use the plain name as primary, Floating uses
        // the `…Key` one. Swapping them would leave a stale key behind.
        let keys: [(role: String, primary: String, alternate: String)] = [
            ("Background", "backgroundAnimationFileName", "backgroundAnimationFileNameKey"),
            ("Floating", "floatingAnimationFileNameKey", "floatingAnimationFileName"),
            ("Foreground", "foregroundAnimationFileName", "foregroundAnimationFileNameKey"),
        ]
        for (role, primary, alternate) in keys {
            if let plane = planes[role] {
                payload[primary] = plane
                let existing = payload[alternate]
                if existing == nil || (existing as? String)?.isEmpty == true {
                    payload.removeValue(forKey: alternate)
                }
            } else {
                payload.removeValue(forKey: primary)
                payload.removeValue(forKey: alternate)
            }
        }

        lockAndHome["default"] = payload
        assets["lockAndHome"] = lockAndHome
        data["assets"] = assets
        try writePlist(data, to: path)
    }

    /// Write the two PosterKit archiver plists that allow Depth.
    ///
    /// `configurableOptions` lives in the version's `contents` folder next to the
    /// bundle; `renderingConfiguration` is a sibling of `contents`. Both take
    /// `depthEffectDisabled = false`.
    @discardableResult
    static func writeDepthConfigs(_ wallpaperDir: URL) throws -> [URL] {
        let contentsDir = wallpaperDir.deletingLastPathComponent()
        let versionDir = contentsDir.deletingLastPathComponent()
        let optionsPath = contentsDir.appendingPathComponent(configurableOptionsName)
        try configurableOptionsData().write(to: optionsPath, options: .atomic)
        let renderingPath = versionDir.appendingPathComponent(renderingConfigurationName)
        try renderingConfigurationData().write(to: renderingPath, options: .atomic)
        return [optionsPath, renderingPath]
    }

    /// Publish an empty Foreground plane when the wallpaper has none.
    ///
    /// The depth renderer builds a third plane; a package stamped Clownfish that
    /// ships only Background+Floating leaves it with no foreground view provider
    /// and traps in WallpaperKit, which disables Depth and snapshots system-wide.
    /// The subject cannot be segmented out of a flat image, so the plane is
    /// generated empty — the Depth toggle becomes a no-op instead of a crash.
    @discardableResult
    static func synthesizeForegroundPlane(_ wallpaperDir: URL, docWidth: Double, docHeight: Double,
                                          pixelScale: Int, dirName: String? = nil) -> [URL] {
        let existing = Dictionary(uniqueKeysWithValues: planeDirs(wallpaperDir).compactMap { plane in
            planeRole(plane.path).map { ($0, plane) }
        })
        guard existing["Foreground"] == nil else { return [] }
        let dest = wallpaperDir.appendingPathComponent(dirName ?? "foreground.ca", isDirectory: true)
        let fm = FileManager.default
        if fm.fileExists(atPath: dest.path) { try? fm.removeItem(at: dest) }
        try? fm.createDirectory(at: dest, withIntermediateDirectories: true)

        let mainCAML = dest.appendingPathComponent("main.caml")
        writeText(emptyPlaneCAML(role: "Foreground", width: docWidth, height: docHeight), to: mainCAML)
        let indexPath = dest.appendingPathComponent("index.xml")
        writeText(modernIndexXML(docWidth: docWidth, docHeight: docHeight, role: "Foreground"), to: indexPath)
        let manifest = dest.appendingPathComponent("assetManifest.caml")
        writeText(micaAssetManifest, to: manifest)
        return [mainCAML, indexPath, manifest]
    }

    // MARK: - Stock Clownfish names

    /// `<assetId>.<Family>-<logicalScreenClass>.wallpaper` and its planes.
    ///
    /// `assetId` is `assets.lockAndHome.<variant>.identifier`, falling back to the
    /// first variant and then to the descriptor's own `identifier` — deliberately
    /// *not* the descriptor id, which the import path randomises afterwards.
    static func skeletonNames(for data: [String: Any],
                              family: String = clownfishFamily) -> (bundle: String, planes: [String: String])? {
        let assets = (data["assets"] as? [String: Any])?["lockAndHome"] as? [String: Any] ?? [:]
        let variant = (assets["default"] as? [String: Any])
            ?? assets.values.compactMap { $0 as? [String: Any] }.first
            ?? [:]
        var assetID = variant["identifier"]
        if assetID == nil { assetID = data["identifier"] }
        let logicalClass = (data["logicalScreenClass"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        guard let assetID, !logicalClass.isEmpty else { return nil }
        let id = String(describing: assetID)
        let bundle = "\(id).\(family)-\(logicalClass).wallpaper"
        var planes: [String: String] = [:]
        for role in ["Background", "Floating", "Foreground"] {
            planes[role] = "\(id).\(family)_\(role)-\(logicalClass).ca"
        }
        return (bundle, planes)
    }

    /// Rename a bundle and its plane folders to the stock Clownfish convention.
    ///
    /// WallpaperKit resolves planes through `Wallpaper.plist` but also relies on
    /// the on-disk name: every working descriptor ships
    /// `<assetId>.<Family>-<class>.wallpaper` with
    /// `<assetId>.<Family>_<Plane>-<class>.ca` planes, and the bundle name is
    /// echoed in `userInfo.wallpaperRepresentingFileName`. A converted tendie that
    /// keeps `Windows_11.wallpaper` / `background.ca` leaves
    /// `WKPlatformPackageView` unable to build the view, and it traps on the lock
    /// screen.
    @discardableResult
    static func renameToSkeletonShape(_ wallpaperDir: URL, data: [String: Any],
                                      family: String = clownfishFamily) -> (URL, [String: String]) {
        guard let names = skeletonNames(for: data, family: family) else { return (wallpaperDir, [:]) }
        let fm = FileManager.default
        let contentsDir = wallpaperDir.deletingLastPathComponent()

        for planeDir in planeDirs(wallpaperDir) {
            guard let role = planeRole(planeDir.path), let target = names.planes[role] else { continue }
            let targetURL = wallpaperDir.appendingPathComponent(target, isDirectory: true)
            guard targetURL.standardizedFileURL != planeDir.standardizedFileURL else { continue }
            if fm.fileExists(atPath: targetURL.path) { try? fm.removeItem(at: targetURL) }
            try? fm.moveItem(at: planeDir, to: targetURL)
        }

        var newDir = wallpaperDir
        let renamedBundle = contentsDir.appendingPathComponent(names.bundle, isDirectory: true)
        if renamedBundle.standardizedFileURL != wallpaperDir.standardizedFileURL {
            if fm.fileExists(atPath: renamedBundle.path) { try? fm.removeItem(at: renamedBundle) }
            if (try? fm.moveItem(at: wallpaperDir, to: renamedBundle)) != nil { newDir = renamedBundle }
        }

        // Repoint every asset entry, in every group and variant, not just
        // `lockAndHome.default` — a pack can carry a `lockScreen`-only variant.
        let planeKeys = [
            "backgroundAnimationFileName": "Background",
            "backgroundAnimationFileNameKey": "Background",
            "foregroundAnimationFileName": "Foreground",
            "foregroundAnimationFileNameKey": "Foreground",
            "floatingAnimationFileName": "Floating",
            "floatingAnimationFileNameKey": "Floating",
        ]
        let wallpaperPlist = newDir.appendingPathComponent("Wallpaper.plist")
        var wallpaperData = readPlist(wallpaperPlist)
        if !wallpaperData.isEmpty {
            var changed = false
            if var assets = wallpaperData["assets"] as? [String: Any] {
                for (groupKey, groupValue) in assets {
                    guard var group = groupValue as? [String: Any] else { continue }
                    for (variantKey, variantValue) in group {
                        guard var variant = variantValue as? [String: Any] else { continue }
                        for (key, role) in planeKeys {
                            if let current = variant[key] as? String, let name = names.planes[role],
                               current != name {
                                variant[key] = name
                                changed = true
                            }
                        }
                        group[variantKey] = variant
                    }
                    assets[groupKey] = group
                }
                if changed { wallpaperData["assets"] = assets }
            }
            if changed { try? writePlist(wallpaperData, to: wallpaperPlist) }
        }

        let userInfo = contentsDir.appendingPathComponent("com.apple.posterkit.provider.contents.userInfo")
        var info = readPlist(userInfo)
        if !info.isEmpty {
            info["wallpaperRepresentingFileName"] = names.bundle
            try? writePlist(info, to: userInfo)
        }
        return (newDir, names.planes)
    }

    /// Rename every converted Clownfish bundle under `root` to the stock shape.
    ///
    /// Must run **after** `convertTree`, which stamps `family = Clownfish` and
    /// synthesises the Foreground plane, because the skeleton name is derived from
    /// the final `Wallpaper.plist`.
    static func renameDescriptorsToSkeleton(_ root: URL) -> [PosterBoardConversion] {
        var results: [PosterBoardConversion] = []
        for descriptorDir in descriptorDirectories(under: root) {
            guard let wallpaperDir = findWallpaperDir(descriptorDir) else { continue }
            let data = readPlist(wallpaperDir.appendingPathComponent("Wallpaper.plist"))
            guard (String(describing: data["family"] ?? "")).lowercased() == clownfishFamily.lowercased() else {
                continue
            }
            let (newDir, _) = renameToSkeletonShape(wallpaperDir, data: data)
            results.append(PosterBoardConversion(
                descriptor: descriptorDir.path,
                wallpaper: newDir.lastPathComponent,
                planes: planeDirs(newDir).compactMap { planeRole($0.path) }))
        }
        return results
    }

    // MARK: - Entry points

    /// Modernise one legacy descriptor in place.
    static func convertDescriptor(_ descriptorDir: URL, screen: (width: Int, height: Int, scale: Int)? = nil,
                                  maxMultiplier: Double = defaultMaxAdaptiveTimeMultiplier) throws
        -> PosterBoardConversion {
        guard let wallpaperDir = findWallpaperDir(descriptorDir) else {
            throw GoldenNuggetError("\(descriptorDir.lastPathComponent) has no wallpaper folder")
        }
        let data = readPlist(wallpaperDir.appendingPathComponent("Wallpaper.plist"))
        // The reference's fallback is 390x844@3 here and 393x852@3 in
        // `flatten_unsupported_planes`. Kept as-is for the same reason.
        let target = screen ?? parseLogicalScreenClass(data["logicalScreenClass"] as? String)
            ?? (390, 844, 3)
        let docWidth = Double(target.width)
        let docHeight = Double(target.height)

        var convertedPlanes: [String] = []
        var changedFiles: [URL] = []
        for planeDir in planeDirs(wallpaperDir) {
            guard let role = planeRole(planeDir.path) else { continue }
            changedFiles += try modernizePlane(planeDir, role: role, docWidth: docWidth, docHeight: docHeight,
                                               logicalWidth: target.width, pixelScale: target.scale)
            convertedPlanes.append(role)
        }

        changedFiles += synthesizeForegroundPlane(wallpaperDir, docWidth: docWidth,
                                                  docHeight: docHeight, pixelScale: target.scale)
        if !convertedPlanes.contains("Foreground"),
           isDirectory(wallpaperDir.appendingPathComponent("foreground.ca", isDirectory: true)) {
            convertedPlanes.append("Foreground")
        }

        try modernizeWallpaperPlist(wallpaperDir, maxMultiplier: maxMultiplier)
        changedFiles.append(wallpaperDir.appendingPathComponent("Wallpaper.plist"))
        changedFiles += try writeDepthConfigs(wallpaperDir)

        return PosterBoardConversion(
            descriptor: descriptorDir.path,
            wallpaper: wallpaperDir.lastPathComponent,
            screen: "\(target.width)x\(target.height)@\(target.scale)x",
            planes: convertedPlanes,
            changedFiles: changedFiles.map(\.path))
    }

    /// Every folder under `root` that looks like a wallpaper descriptor.
    ///
    /// `__MACOSX` trees are pruned: a macOS-created `.tendies` mirrors every real
    /// descriptor but holds AppleDouble stubs instead of CAML files, so they would
    /// abort the conversion with a missing `main.caml`.
    static func descriptorDirectories(under root: URL) -> [URL] {
        var found: [URL] = []
        let fm = FileManager.default
        func walk(_ dir: URL) {
            if dir.lastPathComponent == "versions", isDirectory(dir),
               findWallpaperDir(dir.deletingLastPathComponent()) != nil {
                found.append(dir.deletingLastPathComponent())
                return  // upstream clears dirnames here: do not descend
            }
            let children = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
            for name in children where name.lowercased() != "__macosx" {
                let child = dir.appendingPathComponent(name, isDirectory: true)
                if isDirectory(child) { walk(child) }
            }
        }
        walk(root)
        return found
    }

    /// Convert every legacy descriptor under `root` (an extracted tendie tree).
    static func convertTree(_ root: URL, screen: (width: Int, height: Int, scale: Int)? = nil,
                            maxMultiplier: Double = defaultMaxAdaptiveTimeMultiplier,
                            dryRun: Bool = false) throws -> [PosterBoardConversion] {
        var results: [PosterBoardConversion] = []
        for descriptorDir in descriptorDirectories(under: root) {
            guard isLegacyDescriptor(descriptorDir) else {
                // An already-modern package can still carry a trapping script or
                // CAML state op, so sanitize any plane that does.
                if dryRun || !descriptorNeedsSanitize(descriptorDir) { continue }
                let written = flattenUnsupportedPlanes(descriptorDir)
                guard !written.isEmpty else { continue }
                results.append(PosterBoardConversion(
                    descriptor: descriptorDir.path,
                    wallpaper: findWallpaperDir(descriptorDir)?.lastPathComponent ?? "",
                    planes: written.map { $0.deletingLastPathComponent().lastPathComponent },
                    flattened: true))
                continue
            }
            guard let wallpaperDir = findWallpaperDir(descriptorDir) else { continue }
            if dryRun {
                results.append(PosterBoardConversion(
                    descriptor: descriptorDir.path,
                    wallpaper: wallpaperDir.lastPathComponent,
                    planes: planeDirs(wallpaperDir).compactMap { planeRole($0.path) },
                    isDryRun: true))
                continue
            }
            results.append(try convertDescriptor(descriptorDir, screen: screen, maxMultiplier: maxMultiplier))
        }
        return results
    }

    static func descriptorNeedsSanitize(_ descriptorDir: URL) -> Bool {
        guard let wallpaperDir = findWallpaperDir(descriptorDir) else { return false }
        return planeDirs(wallpaperDir).contains { plane in
            guard planeRole(plane.path) != nil else { return false }
            guard let text = readText(plane.appendingPathComponent("main.caml")) else { return false }
            return hasUnsupportedCAML(text) || hasExternalScript(text)
        }
    }
}

// MARK: - The two depth plists

extension PosterBoardConverter {
    /// The `PRPosterRenderingConfiguration` archive, depth enabled.
    ///
    /// Upstream builds this dict by hand and dumps it with `plistlib`, which means
    /// `plistlib.UID` values — a binary-plist type Foundation's serialiser cannot
    /// produce. Hand-writing a bplist00 container to fake two UIDs would be a lot
    /// of code for two small files, so this archives real objects instead:
    /// `NSKeyedArchiver` writes the same `$archiver` / `$version` / `$top` /
    /// `$objects` shape, and `@objc(...)` pins `$classname` to the exact names
    /// PosterKit expects. `NSKeyedUnarchiver` — which is what PosterKit uses —
    /// resolves by name, not by index, so the object order differs from the
    /// Python output while the graph is identical.
    static func renderingConfigurationData() throws -> Data {
        try NSKeyedArchiver.archivedData(withRootObject: RenderingConfigurationArchive(),
                                         requiringSecureCoding: true)
    }

    /// The `PRPosterConfigurableOptions` archive, depth enabled.
    ///
    /// This one is load-bearing where the bundled copy is not: upstream ships its
    /// own `configurableOptions` without a `preferredRenderingConfiguration`, so
    /// the injected one cannot stand in for this. The reference's docstring says
    /// as much.
    static func configurableOptionsData() throws -> Data {
        try NSKeyedArchiver.archivedData(withRootObject: ConfigurableOptionsArchive(),
                                         requiringSecureCoding: true)
    }

    @objc(PRPosterRenderingConfiguration)
    final class RenderingConfigurationArchive: NSObject, NSSecureCoding {
        static var supportsSecureCoding: Bool { true }
        var motionEffectsDisabled = false
        var depthEffectDisabled = false

        override init() { super.init() }

        required init?(coder: NSCoder) {
            motionEffectsDisabled = coder.containsValue(forKey: "motionEffectsDisabled")
                ? coder.decodeBool(forKey: "motionEffectsDisabled") : false
            depthEffectDisabled = coder.containsValue(forKey: "depthEffectDisabled")
                ? coder.decodeBool(forKey: "depthEffectDisabled") : false
            super.init()
        }

        func encode(with coder: NSCoder) {
            coder.encode(motionEffectsDisabled, forKey: "motionEffectsDisabled")
            coder.encode(depthEffectDisabled, forKey: "depthEffectDisabled")
        }
    }

    @objc(PRPosterDescriptorHomeScreenConfiguration)
    final class HomeScreenConfigurationArchive: NSObject, NSSecureCoding {
        static var supportsSecureCoding: Bool { true }
        /// `0` in the reference, stored as a plain number in `$objects`.
        var preferredStyle = 0
        var allowsModifyingLegibilityBlur = true

        override init() { super.init() }

        required init?(coder: NSCoder) {
            preferredStyle = coder.containsValue(forKey: "preferredStyle")
                ? coder.decodeInteger(forKey: "preferredStyle") : 0
            allowsModifyingLegibilityBlur = coder.containsValue(forKey: "allowsModifyingLegibilityBlur")
                ? coder.decodeBool(forKey: "allowsModifyingLegibilityBlur") : true
            super.init()
        }

        func encode(with coder: NSCoder) {
            coder.encode(preferredStyle, forKey: "preferredStyle")
            coder.encode(allowsModifyingLegibilityBlur, forKey: "allowsModifyingLegibilityBlur")
        }
    }

    @objc(PRPosterConfigurableOptions)
    final class ConfigurableOptionsArchive: NSObject, NSSecureCoding {
        static var supportsSecureCoding: Bool { true }
        var role = "PRPosterRoleLockScreen"
        var luminance = 0.5
        var ambientSupportedDataLayout = 0
        var preferredHomeScreenConfiguration = HomeScreenConfigurationArchive()
        var preferredRenderingConfiguration = RenderingConfigurationArchive()
        var preferredTimeFontConfigurations: NSArray = []
        var preferredTitleColors: NSArray = []

        override init() { super.init() }

        required init?(coder: NSCoder) {
            role = coder.decodeObject(of: NSString.self, forKey: "role") as String? ?? "PRPosterRoleLockScreen"
            luminance = coder.decodeDouble(forKey: "luminance")
            ambientSupportedDataLayout = coder.decodeInteger(forKey: "ambientSupportedDataLayout")
            preferredHomeScreenConfiguration =
                coder.decodeObject(of: HomeScreenConfigurationArchive.self,
                                   forKey: "preferredHomeScreenConfiguration") ?? HomeScreenConfigurationArchive()
            preferredRenderingConfiguration =
                coder.decodeObject(of: RenderingConfigurationArchive.self,
                                   forKey: "preferredRenderingConfiguration") ?? RenderingConfigurationArchive()
            preferredTimeFontConfigurations =
                coder.decodeObject(of: NSArray.self, forKey: "preferredTimeFontConfigurations") ?? []
            preferredTitleColors = coder.decodeObject(of: NSArray.self, forKey: "preferredTitleColors") ?? []
            super.init()
        }

        func encode(with coder: NSCoder) {
            coder.encode(role as NSString, forKey: "role")
            coder.encode(luminance, forKey: "luminance")
            coder.encode(ambientSupportedDataLayout, forKey: "ambientSupportedDataLayout")
            coder.encode(preferredHomeScreenConfiguration, forKey: "preferredHomeScreenConfiguration")
            coder.encode(preferredRenderingConfiguration, forKey: "preferredRenderingConfiguration")
            coder.encode(preferredTimeFontConfigurations, forKey: "preferredTimeFontConfigurations")
            coder.encode(preferredTitleColors, forKey: "preferredTitleColors")
            // `displayNameLocalizationKey` is a nil object reference (`$null`) in
            // the reference and is not encoded here: `NSKeyedArchiver` has no way
            // to write a true `$null` reference, and omitting the key decodes to
            // the same nil.
        }
    }
}
