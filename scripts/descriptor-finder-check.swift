// Regression harness for the descriptor finder — `findDescriptors`,
// `storeDirectories`, `countDescriptors` and `randomizeIdentifiers`.
//
// What it checks, none of which needs a device:
//
//   1  FIND     every pack on the command line yields at least one descriptor,
//               and the extension id is the one the path says for a store
//               snapshot and the pack's own type for a bare tree. The two cases
//               are the whole point: a finder that only handles the bare shape
//               reports "no descriptor folders found in this pack" for a
//               snapshot, which is what this port did to a real Mercury pack.
//   2  STORE    a snapshot's store directory is found wherever the pack put it —
//               under `container/`, under `Container/`, or wrapped in a folder
//               named after the pack. Three spellings, one walk.
//   3  IDS      sidecar, string userInfo identity, nested wallpaper assets,
//               Mercury preservation and malformed plist rejection.
//   4  APPLY    current Collections provider delivery and failure propagation.
//
// Run: python3 scripts/check-posterboard-airlift.py [pack.tendies ...]
//
// The real source is concatenated, not copied, so `private` members are in
// scope and the code under test is the code that ships. The stubs below are the
// app types `PosterBoardAirlift.swift` names and nothing else.
//
// This file is NOT part of the app target; keep it out of Package.swift.

import Foundation

// MARK: - Stubs for the app types PosterBoardAirlift names

enum PosterBoard {
    static let storeDirectoryName = "PRBPosterExtensionDataStore"
    static let fallbackStructureVersion = 61
    static func shouldConvertLegacy(pack: PosterBoardPack, deviceVersion: String,
                                    log: (String) -> Void) -> Bool { false }
    static func convertLegacyPack(_ name: String, at root: URL, log: (String) -> Void) {}
    static let workDirectory = URL(fileURLWithPath: "/tmp/finder/work")
}

enum PosterBoardPosterType {
    case collections
    case mercury
    case suggestedPhotos
    case container
    var extensionBundleID: String {
        switch self {
        case .collections: return "com.apple.WallpaperKit.CollectionsPoster"
        case .mercury: return "com.apple.MercuryPoster"
        case .suggestedPhotos: return "com.apple.PhotosUIPrivate.PhotosPosterProvider"
        case .container: return "com.apple.PosterBoard"
        }
    }
}

struct PosterBoardPack {
    let url: URL
    let posterType: PosterBoardPosterType
    var name: String { url.lastPathComponent }
}

struct PosterBoardSelection {
    var tendies: [PosterBoardPack] = []
    var isActive: Bool { !tendies.isEmpty }
    var describe: String { "harness" }
}

struct GoldenNuggetError: Error { let message: String; init(_ m: String) { message = m } }

enum Airlift {
    static func appContainer(pairingPath: String, bundleID: String) async throws -> String { "" }
    static var targets: [String] = []
    static var failInjection = false
    static var resprings = 0
    static func extractZip(archivePath: String, destDir: String) async throws {
        for child in try FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: archivePath), includingPropertiesForKeys: nil) {
            try FileManager.default.copyItem(at: child, to: URL(fileURLWithPath: destDir)
                .appendingPathComponent(child.lastPathComponent))
        }
    }
    static func injectFolder(pairingPath: String, folderPath: String,
                             targetParentDir: String, destName: String) async throws {
        targets.append(targetParentDir)
        if failInjection { throw GoldenNuggetError("fixture injection failed") }
    }
    static func respring() async throws { resprings += 1 }
}

// `countDescriptors` reads a zip listing; the harness only ever calls the
// extracted-tree functions, so a stub that fails loudly is better than a zip
// reader that silently disagrees with the shipping one. The one line this
// harness cannot provide is `import ZIPFoundation`, which the run command
// filters out of the concatenation — nothing else is touched.
struct Archive: Sequence {
    enum AccessMode { case read, create, update }
    struct Entry { let path: String }
    init(url: URL, accessMode access: AccessMode) throws { throw GoldenNuggetError("no zip in harness") }
    func makeIterator() -> AnyIterator<Entry> { AnyIterator { nil } }
}

// The functions under test are `private`, and top-level code in the same file
// cannot see a type's private members — only an extension of that type in the
// same file can. So the harness calls them through this, which is also why the
// nested `Descriptor` never has to be named outside the type.
extension PosterBoardAirlift {
    static func __check_find(in root: URL,
                             defaultExtension: String,
                             log: @escaping (String) -> Void) -> [(ext: String, url: URL)] {
        findDescriptors(in: root, defaultExtension: defaultExtension, log: log)
            .map { (ext: $0.extensionID, url: $0.url) }
    }

    static func __check_randomize(in folder: URL, numericID: Int,
                                   extensionID: String) throws {
        try randomizeIdentifiers(in: folder, numericID: numericID, extensionID: extensionID)
    }
}

// MARK: - The checks

var failures = 0

func fail(_ message: String) {
    print("  ✗ \(message)")
    failures += 1
}

func pass(_ message: String) { print("  ✓ \(message)") }

func extract(_ archive: URL, to stage: URL) throws {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
    proc.arguments = ["-q", "-o", archive.path, "-d", stage.path]
    try proc.run()
    proc.waitUntilExit()
    guard proc.terminationStatus == 0 else {
        throw GoldenNuggetError("unzip failed (\(proc.terminationStatus))")
    }
}

func identifierText(in descriptor: URL) -> String? {
    let file = descriptor.appendingPathComponent(
        "com.apple.posterkit.provider.descriptor.identifier")
    guard let data = try? Data(contentsOf: file) else { return nil }
    return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
}

func wallpaperIdentifier(in descriptor: URL) -> Any? {
    guard let walker = FileManager.default.enumerator(
        at: descriptor, includingPropertiesForKeys: nil) else { return nil }
    for case let url as URL in walker where url.lastPathComponent.hasSuffix("Wallpaper.plist") {
        if let data = try? Data(contentsOf: url),
           let plist = try? PropertyListSerialization.propertyList(
               from: data, options: [], format: nil) as? [String: Any],
           let value = plist["identifier"] {
            return value
        }
    }
    return nil
}

func userInfoKeys(in descriptor: URL) -> [String]? {
    guard let walker = FileManager.default.enumerator(
        at: descriptor, includingPropertiesForKeys: nil) else { return nil }
    for case let url as URL in walker
    where url.lastPathComponent == "com.apple.posterkit.provider.contents.userInfo" {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil) as? [String: Any]
        else { return nil }
        return plist.keys.sorted()
    }
    return nil
}

for argument in CommandLine.arguments.dropFirst() {
    let archive = URL(fileURLWithPath: argument)
    let name = archive.lastPathComponent
    print("▸ \(name)")

    let stage = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("finder-check-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: stage) }
    do {
        try extract(archive, to: stage)
    } catch {
        fail("could not unpack: \(error)")
        continue
    }

    // The finder takes the pack's own type as the default extension, and the
    // type is the one thing a real user sets — a Mercury pack is not a
    // Collections pack whatever the folder is called.
    let isSnapshot = name.contains("Mercury") || name.contains("All Colors")
    let type: PosterBoardPosterType = isSnapshot ? .mercury : .collections
    let log: (String) -> Void = { print("    · \($0)") }
    let found = PosterBoardAirlift.__check_find(
        in: stage, defaultExtension: type.extensionBundleID, log: log)

    if found.isEmpty {
        fail("found no descriptor folders — the apply would stop here")
        continue
    }
    pass("found \(found.count) descriptor folder(s)")

    if isSnapshot {
        let wrong = found.filter { $0.ext != type.extensionBundleID }
        if wrong.isEmpty {
            pass("extension id came from the path (\(found[0].ext))")
        } else {
            fail("expected \(type.extensionBundleID) from the snapshot path, got "
                 + wrong.map { $0.ext }.joined(separator: ", "))
        }
    }

    // Identity fields agree for Collections/Photos; Mercury retains its lookup keys.
    for descriptor in found {
        let bareBefore = identifierText(in: descriptor.url)
        let plistBefore = wallpaperIdentifier(in: descriptor.url)
        let keysBefore = userInfoKeys(in: descriptor.url)
        try PosterBoardAirlift.__check_randomize(in: descriptor.url, numericID: 47123,
                                                   extensionID: descriptor.ext)
        let bareAfter = identifierText(in: descriptor.url)
        let plistAfter = wallpaperIdentifier(in: descriptor.url)
        let keysAfter = userInfoKeys(in: descriptor.url)

        if let bareBefore {
            if Int(bareBefore) != nil {
                if bareAfter == "47123" {
                    pass("bare numeric id \(bareBefore) -> \(bareAfter ?? "nil")")
                } else {
                    fail("bare numeric id \(bareBefore) became \(bareAfter ?? "nil"), expected 47123")
                }
            } else if bareAfter == bareBefore {
                pass("provider id \(bareBefore) left alone")
            } else {
                fail("provider id \(bareBefore) was rewritten to \(bareAfter ?? "nil") — "
                     + "that points the descriptor at a look the provider does not have")
            }
        } else if descriptor.ext != "com.apple.MercuryPoster", bareAfter == "47123" {
            pass("missing sidecar stamped")
        } else if let plistBefore {
            if "\(plistAfter ?? "nil")" == "47123" {
                pass("Wallpaper.plist identifier \(plistBefore) -> \(plistAfter ?? "nil")")
            } else {
                fail("Wallpaper.plist identifier \(plistBefore) became "
                     + "\(plistAfter.map { "\($0)" } ?? "nil")")
            }
        } else {
            pass("no id to rewrite in this shape")
        }

        if let keysBefore, !keysBefore.contains("wallpaperRepresentingIdentifier") {
            if keysAfter?.contains("wallpaperRepresentingIdentifier") == (descriptor.ext != "com.apple.MercuryPoster") {
                pass("userInfo identity matches provider requirements")
            } else {
                fail("added wallpaperRepresentingIdentifier to a userInfo that had "
                     + "\(keysBefore.joined(separator: ","))")
            }
        }
    }
}

// 2  STORE. The walk has to find the store wherever the pack put it. Built
//     directly as trees, because the finder takes an extracted root — no zip
//     needed — and the three spellings are the whole claim: a fixed path
//     handles the first and fails the next two, and the second is the one a real
//     pack shipped today used.
print("▸ store spellings")
func descriptorFixture(extensionID: String, identifier: String) throws -> String {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("fixture-\(UUID().uuidString)")
    let descriptor = root.appendingPathComponent(
        "Library/Application Support/PRBPosterExtensionDataStore/61/Extensions/"
            + "\(extensionID)/descriptors/AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
    try FileManager.default.createDirectory(
        at: descriptor.appendingPathComponent("versions/0"), withIntermediateDirectories: true)
    try Data(identifier.utf8).write(to: descriptor.appendingPathComponent(
        "com.apple.posterkit.provider.descriptor.identifier"))
    return root.path
}

for spelling in ["container", "Container", "Some Pack Name/Container", "Some Pack Name/container"] {
    let fixture = try descriptorFixture(extensionID: "com.apple.MercuryPoster",
                                        identifier: "v6x.colorB")
    defer { try? FileManager.default.removeItem(atPath: fixture) }
    let moved = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("fixture-\(UUID().uuidString)")
        .appendingPathComponent(spelling)
    // `spelling` can be nested ("Some Pack Name/Container"), and `moveItem` will
    // not create the way down for us.
    try FileManager.default.createDirectory(
        at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.moveItem(atPath: fixture, toPath: moved.path)
    let found = PosterBoardAirlift.__check_find(
        in: moved.deletingLastPathComponent(),
        defaultExtension: "com.apple.MercuryPoster", log: { _ in })
    if found.count == 1, found[0].ext == "com.apple.MercuryPoster" {
        pass("\(spelling)/ → 1 descriptor, com.apple.MercuryPoster")
    } else {
        fail("\(spelling)/ → \(found.count) descriptor(s): "
             + found.map { "\($0.ext)" }.joined(separator: ", "))
    }
    // And the id survives the rewrite, for the same reason as above.
    let idFile = found.first.map {
        $0.url.appendingPathComponent("com.apple.posterkit.provider.descriptor.identifier")
    }
    if let idFile {
        try PosterBoardAirlift.__check_randomize(in: found[0].url, numericID: 47123,
                                                   extensionID: found[0].ext)
        let text = (try? Data(contentsOf: idFile)).flatMap {
            String(data: $0, encoding: .utf8)
        }
        if text == "v6x.colorB" { pass("\(spelling)/ provider id intact") } else {
            fail("\(spelling)/ provider id became \(text ?? "nil")")
        }
    }
}

print("▸ AirLift descriptor identity and delivery")
let identityRoot = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("airlift-identity-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: identityRoot) }
let descriptor = identityRoot.appendingPathComponent("descriptors/Test")
let contents = descriptor.appendingPathComponent("versions/0/contents")
try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
let userInfo = contents.appendingPathComponent("com.apple.posterkit.provider.contents.userInfo")
let wallpaper = contents.appendingPathComponent("ExampleWallpaper.plist")
let hidden = contents.appendingPathComponent(".com.apple.posterkit.provider.contents.configurableOptions.plist")
func writePlist(_ value: [String: Any], to url: URL) throws {
    try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
        .write(to: url)
}
func readPlist(_ url: URL) throws -> [String: Any] {
    try PropertyListSerialization.propertyList(from: Data(contentsOf: url), options: [], format: nil)
        as! [String: Any]
}
try writePlist(["suggestionMetadata": ["wallpaperRepresentingIdentifier": "keep"]], to: userInfo)
try writePlist(["identifier": 1, "assets": ["lockAndHome": ["default": ["identifier": 2]]]], to: wallpaper)
try Data("depth options".utf8).write(to: hidden)
try PosterBoardAirlift.__check_randomize(in: descriptor, numericID: 47123,
    extensionID: PosterBoardPosterType.collections.extensionBundleID)
let info = try readPlist(userInfo)
if identifierText(in: descriptor) == "47123",
   info["wallpaperRepresentingIdentifier"] as? String == "47123",
   (info["suggestionMetadata"] as? [String: Any])?["wallpaperRepresentingIdentifier"] as? String == "keep" {
    pass("missing sidecar and top-level string identity agree; nested identity preserved")
} else { fail("descriptor identity fields disagree") }
let aligned = try readPlist(wallpaper)
let assets = aligned["assets"] as? [String: Any]
let lockAndHome = assets?["lockAndHome"] as? [String: Any]
let fallback = lockAndHome?["default"] as? [String: Any]
if aligned["identifier"] as? Int == 47123, fallback?["identifier"] as? Int == 47123,
   aligned["family"] as? String == "Marble", aligned["name"] as? String == "Lavender",
   try Data(contentsOf: hidden) == Data("depth options".utf8) {
    pass("wallpaper assets aligned and hidden depth options preserved")
} else { fail("wallpaper assets disagree with descriptor identity") }
let mercuryBefore = try Data(contentsOf: userInfo)
try PosterBoardAirlift.__check_randomize(in: descriptor, numericID: 99999,
    extensionID: PosterBoardPosterType.mercury.extensionBundleID)
if try Data(contentsOf: userInfo) == mercuryBefore, identifierText(in: descriptor) == "47123" {
    pass("Mercury descriptor preserved byte for byte")
} else { fail("Mercury descriptor was changed") }
try Data("invalid plist".utf8).write(to: userInfo)
do {
    try PosterBoardAirlift.__check_randomize(in: descriptor, numericID: 47123,
        extensionID: PosterBoardPosterType.collections.extensionBundleID)
    fail("malformed identity plist silently accepted")
} catch { pass("malformed identity plist rejected before injection") }
try writePlist([:], to: userInfo)
let fixtureSelection = PosterBoardSelection(tendies: [PosterBoardPack(
    url: identityRoot, posterType: .collections)])
PosterBoardAirlift.cachedContainer = "/fixture/PosterBoard"
try await PosterBoardAirlift.apply(selection: fixtureSelection, structureVersion: 61,
    deviceVersion: "26.5", pairingPath: "fixture", log: { _ in }, progress: { _ in })
if Airlift.targets.count == 1,
   Airlift.targets[0].hasSuffix("Extensions/com.apple.Posters.CollectionsPosterApp/descriptors"),
   Airlift.resprings == 1 {
    pass("Collections delivered to current provider before respring")
} else { fail("Collections delivery used wrong provider") }
Airlift.failInjection = true
let previousResprings = Airlift.resprings
do {
    try await PosterBoardAirlift.apply(selection: fixtureSelection, structureVersion: 61,
        deviceVersion: "26.5", pairingPath: "fixture", log: { _ in }, progress: { _ in })
    fail("failed delivery reported success")
} catch {
    if Airlift.resprings == previousResprings { pass("failed delivery reports failure without respring") }
    else { fail("resprung after failed delivery") }
}
UserDefaults.standard.removeObject(forKey: "PosterBoardAirliftContainer")

print(failures == 0 ? "\nall checks passed" : "\n\(failures) check(s) failed")
exit(failures == 0 ? 0 : 1)
