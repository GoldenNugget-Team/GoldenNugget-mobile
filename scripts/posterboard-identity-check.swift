// Regression harness for the Protective compile's **descriptor identity**
// handling — `PosterBoardBuilder.walk`'s sidecar stamping, `rewrittenContents`
// and `PosterBoardPlist.set`.  Nothing here needs a device.
//
// What it checks, and why each one is a trap rather than a detail:
//
//   1  STAMP   A descriptor that ships **no** `provider.descriptor.identifier`
//              sidecar gets one, carrying the same randomized id as the two
//              plists the walk rewrites.  This is the common case for a
//              third-party `.tendies`: PosterKit then invents an identifier that
//              disagrees with `contents.userInfo` / `Wallpaper.plist`, and
//              WallpaperKit traps in `makeViewProvider` (EXC_BREAKPOINT) — an
//              apply that reports success and a wallpaper nobody can open.
//   2  ONE ID  All three identity fields carry the *same* id, and the
//              top-level `wallpaperRepresentingIdentifier` is a **string**.  A
//              third-party userInfo ships *without* that key, and a recursive
//              set only ever replaces a key that already exists, so "replace
//              wherever present" writes nothing at all.
//   3  NESTED  The id lands at the top level and nowhere else — a nested
//              `wallpaperRepresentingIdentifier` inside `userInfo` keeps its own
//              value.  That is what upstream's `recursive=False` means, and it
//              is the reason the key cannot be written with the recursive
//              helper the other two files could get away with.
//   4  MERCURY Nothing is stamped and nothing is rewritten under MercuryPoster:
//              its identifier is a textual lookup key (`v6x.colorB`) that
//              `userInfo` and `suggestionMetadata` reference, so a randomized
//              number breaks the chain.
//   5  HIDDEN  `.com.apple.posterkit.provider.contents.configurableOptions.plist`
//              survives the walk.  Apple hides that plist behind a leading dot
//              in its own descriptors, and upstream's skip list is Finder junk
//              (`.DS_Store`, `._*`, `__MACOSX`) rather than "starts with a dot".
//
// Run:
//   cat Nugget/Core/PosterBoard.swift scripts/posterboard-identity-check.swift \
//     > /tmp/pbcheck/main.swift
//   && swiftc -swift-version 5 /tmp/pbcheck/main.swift -o /tmp/pbcheck/check
//   && /tmp/pbcheck/check
//
// The real source is concatenated, not copied, so `private` members are in
// scope and the code under test is the code that ships.  The stubs below are
// the app types `PosterBoard.swift` names and nothing else.
//
// This file is NOT part of the app target; keep it out of Package.swift.

import Foundation

// MARK: - Stubs for the app types PosterBoard.swift names

struct TweakPayload: Equatable {
    let domain: String
    let relativePath: String
    let contents: Data
    let source: URL?

    init(domain: String, relativePath: String, contents: Data) {
        self.domain = domain
        self.relativePath = TweakPayload.manifestPath(relativePath)
        self.contents = contents
        self.source = nil
    }

    init(domain: String, relativePath: String, source: URL) {
        self.domain = domain
        self.relativePath = TweakPayload.manifestPath(relativePath)
        self.contents = Data()
        self.source = source
    }

    /// Copied from `TweakCompiler.swift` rather than reimplemented: the leading
    /// slash is part of what these assertions read, so a stub that dropped it
    /// would pass on paths the manifest never sees.
    static func manifestPath(_ relativePath: String) -> String {
        var path = Substring(relativePath)
        while path.first == "/" { path = path.dropFirst() }
        return String(path)
    }

    func bytes() throws -> Data {
        guard let source else { return contents }
        return try Data(contentsOf: source)
    }
}

struct GoldenNuggetError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

enum PosterBoardPosterType: String {
    case collections
    case suggestedPhotos
    case mercury
    case container
}

enum PosterBoardCalculationMode {
    case linear
    case easeInEaseOut
    case custom
}

struct PosterBoardVideoPlan {
    let video: URL
    let thumbnail: URL?
    let loop: Bool
    let reverse: Bool
    let foreground: Bool
    let calculationMode: PosterBoardCalculationMode
}

struct PosterBoardTendie {
    let name: String
    var autoConvert: Bool?
    var summary: String { name }
    func extract(to destination: URL) throws {}
}

enum PosterBoardImports {
    static func load() -> [PosterBoardTendie] { [] }
}

struct PosterBoardConversion {
    var isDryRun = false
    var convertedLine = ""
    var renamedLine = ""
}

enum PosterBoardConverter {
    static let defaultMaxAdaptiveTimeMultiplier = 2.0
    static func convertTree(_ root: URL, screen: (width: Int, height: Int, scale: Int)? = nil,
                            maxMultiplier: Double = defaultMaxAdaptiveTimeMultiplier,
                            dryRun: Bool = false) throws -> [PosterBoardConversion] { [] }
    static func renameDescriptorsToSkeleton(_ root: URL) -> [PosterBoardConversion] { [] }
}

enum PosterBoardStore {
    static func createEmptyDatabase(at url: URL) throws {}
    static func stitch(database: URL, items: [PosterBoardConfigItem],
                       workingDirectory: URL) throws -> URL { database }
}

enum PosterBoardVideo {
    static func generate(plan: PosterBoardVideoPlan, outputDirectory: URL,
                         log: @escaping @Sendable (String) -> Void) async throws {}
}

/// The three conversion plists, by their real names — the walk writes them into
/// every version directory in `keys.sorted()` order and skips a pack's own copies,
/// so the names have to be the shipped ones for that branch to be reachable.
enum PosterBoardResources {
    static let configConversion: [String: Data] = [
        "com.apple.posterkit.provider.instance.quickActions.plist": Data("<plist/>".utf8),
        "com.apple.posterkit.provider.instance.renderingConfiguration.plist": Data("<plist/>".utf8),
        "com.apple.posterkit.provider.instance.titleStyleConfiguration.plist": Data("<plist/>".utf8),
    ]
}

extension URL {
    static var documents: URL { URL(fileURLWithPath: "/tmp/pbcheck/documents", isDirectory: true) }
}

#if !canImport(Darwin)
// Apple-only API, and never called from the code under test — declared so the
// harness builds on the machine that has no iOS SDK.
extension URL {
    enum PathAttributes { case data }
    func appendingPathComponent(_ pathComponent: String,
                                conformingTo attributes: PathAttributes) -> URL {
        appendingPathComponent(pathComponent)
    }
    func startAccessingSecurityScopedResource() -> Bool { false }
    func stopAccessingSecurityScopedResource() {}
}
#endif

// MARK: - Harness

var failures = 0

func check(_ ok: Bool, _ what: String) {
    print((ok ? "  ok    " : "  FAIL  ") + what)
    if !ok { failures += 1 }
}

let work = URL(fileURLWithPath: "/tmp/pbcheck/work", isDirectory: true)
try? FileManager.default.removeItem(at: work)
let fm = FileManager.default

/// A fresh, empty scratch directory for one case.
func fixture(_ name: String) throws -> URL {
    let url = work.appendingPathComponent(name, isDirectory: true)
    try? fm.removeItem(at: url)
    try fm.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// One file inside a fixture tree, creating the directories above it.
@discardableResult
func write(_ data: Data, under root: URL, _ components: String...) throws -> URL {
    var url = root
    for component in components.dropLast() {
        url = url.appendingPathComponent(component, isDirectory: true)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
    }
    let file = url.appendingPathComponent(components.last!, isDirectory: false)
    try data.write(to: file)
    return file
}

func plist(_ dictionary: [String: Any]) -> Data {
    try! PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)
}

/// The identity shape of one descriptor, as Apple and third-party packs write it.
func userInfo(wallpaperID: String?, nested: [String: Any] = [:]) -> Data {
    var root: [String: Any] = ["category": "Featured", "groupName": "Nugget"]
    if let wallpaperID { root["wallpaperRepresentingIdentifier"] = wallpaperID }
    if !nested.isEmpty { root["suggestionMetadata"] = nested }
    return plist(root)
}

func wallpaperPlist(identifier: Int) -> Data {
    plist([
        "identifier": identifier,
        "family": "Clownfish",
        "name": "OriginalName",
        "assets": ["lockAndHome": ["default": ["name": "OriginalName", "identifier": identifier]]],
    ])
}

func build(_ pack: URL) throws -> (payloads: [TweakPayload], configs: [PosterBoardConfigItem]) {
    var builder = PosterBoardBuilder(structureVersion: 61, log: { _ in })
    try builder.walk(currentPath: pack, restorePath: "", isAdding: false)
    return (builder.payloads, builder.configs)
}

extension Array where Element == TweakPayload {
    func with(_ suffix: String) -> [TweakPayload] {
        filter { $0.relativePath.hasSuffix(suffix) }
    }
    /// A *sub-path*, matched anywhere: the store root in front of it is the
    /// caller's business, and a prefix that omits it matches nothing.
    func under(_ subpath: String) -> [TweakPayload] {
        filter { $0.relativePath.contains(subpath) }
    }
    func one(_ suffix: String) -> TweakPayload? { with(suffix).first }
}

func text(_ suffix: String, in payloads: [TweakPayload]) -> String? {
    guard let payload = payloads.one(suffix) else { return nil }
    let data = try! payload.bytes()
    return String(data: data, encoding: .utf8)
}

func dictionary(_ suffix: String, in payloads: [TweakPayload]) -> [String: Any]? {
    guard let payload = payloads.one(suffix) else { return nil }
    let object = try! PropertyListSerialization.propertyList(from: try! payload.bytes(),
                                                             options: [], format: nil)
    return object as? [String: Any]
}

let sidecar = "com.apple.posterkit.provider.descriptor.identifier"
let userInfoFile = "com.apple.posterkit.provider.contents.userInfo"
let wallpaperPlistPath = "versions/0/contents/9183.Custom-390w-844h@3x~iphone.wallpaper/Wallpaper.plist"
let configurableOptions = ".com.apple.posterkit.provider.contents.configurableOptions.plist"
let configurations = "Extensions/com.apple.WallpaperKit.CollectionsPoster/configurations"

// MARK: 1 + 2 + 3 + 5 — a third-party Collections pack, stripped bare

print("STAMP/ONE ID/NESTED/HIDDEN — third-party Collections descriptor")
do {
    let pack = try fixture("collections")
    let suggestionMetadata: [String: Any] = ["lookIdentifier": "v6x.colorB",
                                             "wallpaperRepresentingIdentifier": "keep-me"]
    try write(userInfo(wallpaperID: nil, nested: suggestionMetadata),
              under: pack, "descriptor", "Original", userInfoFile)
    try write(plist(["_root": "objects"]), under: pack,
              "descriptor", "Original", "providerInfo.plist")
    try write(plist(["preferredRenderingConfiguration": "posterDepth"]), under: pack,
              "descriptor", "Original", "versions", "0", "contents", configurableOptions)
    try write(wallpaperPlist(identifier: 4711), under: pack,
              "descriptor", "Original", "versions", "0", "contents",
              "9183.Custom-390w-844h@3x~iphone.wallpaper", "Wallpaper.plist")

    let (payloads, configs) = try build(pack)
    check(configs.count == 1, "one wallpaper staged (got \(configs.count))")
    guard let uuid = configs.first?.uuid else {
        print("  FAIL  no config item; the rest of this case cannot run")
        exit(1)
    }
    check(uuid != "Original" && uuid.count == 36, "descriptor renamed to a UUID (\(uuid))")
    check(configs.first?.extensionID == "com.apple.WallpaperKit.CollectionsPoster",
          "routed to the Collections provider")

    // 1 STAMP
    let stamped = payloads.with("\(configurations)/\(uuid)/\(sidecar)")
    check(stamped.count == 1, "the missing sidecar is stamped (\(stamped.count) payload(s))")
    let sidecarText = text("\(configurations)/\(uuid)/\(sidecar)", in: payloads) ?? ""
    check(!sidecarText.isEmpty && Int(sidecarText) != nil,
          "the sidecar holds a bare decimal id (\"\(sidecarText)\")")

    // 2 ONE ID
    let info = dictionary("\(configurations)/\(uuid)/\(userInfoFile)", in: payloads)
    let written = info?["wallpaperRepresentingIdentifier"]
    check(written is String,
          "wallpaperRepresentingIdentifier is a string (got \(written.map { "\($0)" } ?? "absent"))")
    let wallID = dictionary("\(configurations)/\(uuid)/\(wallpaperPlistPath)", in: payloads)?["identifier"]
    check(wallID is Int, "Wallpaper.plist identifier stays an integer (got \(wallID.map { "\($0)" } ?? "absent"))")
    // Parenthesised deliberately: `x as? String == y` binds `as?` tighter than
    // `==` and parses as `x as? (String == y)`.  And the integer is rendered
    // through `map`, because `String(describing:)` on an `Any?` would say
    // "Optional(57547)" and compare unequal to the sidecar's text.
    check((written as? String) == sidecarText
            && wallID.map { "\($0)" } == sidecarText,
          "all three identity fields agree (\(sidecarText))")
    let nestedID = (info?["suggestionMetadata"] as? [String: Any])?["wallpaperRepresentingIdentifier"]
    check((nestedID as? String) == "keep-me",
          "a nested wallpaperRepresentingIdentifier is left alone (got \(nestedID.map { "\($0)" } ?? "absent"))")

    // 5 HIDDEN
    check(payloads.one("\(configurations)/\(uuid)/versions/0/contents/\(configurableOptions)") != nil,
          "Apple's hidden configurableOptions.plist survives the walk")
    let underVersion = payloads.under("\(configurations)/\(uuid)/versions/0/").count
    check(underVersion == PosterBoardResources.configConversion.count + 2,
          "the version directory holds the three conversion plists plus the two shipped files (got \(underVersion))")
}

// MARK: 4 — Mercury

print("MERCURY — textual identifiers are left alone")
do {
    let pack = try fixture("mercury")
    let suggestionMetadata: [String: Any] = ["lookIdentifier": "v6x.colorB"]
    try write(userInfo(wallpaperID: "v6x.colorB", nested: suggestionMetadata), under: pack,
              "mercury-descriptor", "v6x.colorB", userInfoFile)
    try write(Data("v6x.colorB".utf8), under: pack,
              "mercury-descriptor", "v6x.colorB", sidecar)
    try write(wallpaperPlist(identifier: 0), under: pack,
              "mercury-descriptor", "v6x.colorB", "versions", "0", "contents",
              "9183.Custom-390w-844h@3x~iphone.wallpaper", "Wallpaper.plist")

    let (payloads, configs) = try build(pack)
    check(configs.first?.extensionID == "com.apple.MercuryPoster",
          "routed to MercuryPoster (got \(configs.first?.extensionID ?? "nothing"))")
    guard let uuid = configs.first?.uuid else { exit(1) }
    let prefix = "Extensions/com.apple.MercuryPoster/configurations/\(uuid)"
    let info = payloads.one("\(prefix)/\(userInfoFile)")
    check(info?.source != nil, "userInfo rides as-is, not rewritten")
    let stamped = payloads.one("\(prefix)/\(sidecar)")
    check(stamped?.source != nil, "the sidecar rides as-is, not rewritten")
    check(text("\(prefix)/\(sidecar)", in: payloads) == "v6x.colorB",
          "Mercury's textual identifier is preserved byte for byte")
    check(payloads.one("\(prefix)/\(wallpaperPlistPath)")?.source != nil,
          "Mercury's Wallpaper.plist is not given an integer id")
}

// MARK: 1 — a pack that ships the sidecar is stamped once, not twice

print("STAMP — a pack that already ships the sidecar")
do {
    let pack = try fixture("pre-stamped")
    try write(userInfo(wallpaperID: "100"), under: pack,
              "descriptor", "Original", userInfoFile)
    try write(Data("100".utf8), under: pack,
              "descriptor", "Original", sidecar)

    let (payloads, configs) = try build(pack)
    guard let uuid = configs.first?.uuid else { exit(1) }
    let suffix = "\(configurations)/\(uuid)/\(sidecar)"
    check(payloads.with(suffix).count == 1, "exactly one sidecar payload (got \(payloads.with(suffix).count))")
    check(text(suffix, in: payloads) != "100", "the shipped sidecar is rewritten to the new id")
    check(Int(text(suffix, in: payloads) ?? "") != nil, "and it is still a bare decimal id")
}

print(failures == 0 ? "\nALL OK" : "\n\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)