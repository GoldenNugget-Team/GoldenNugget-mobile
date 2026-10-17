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
//   3  IDS      `randomizeIdentifiers` replaces a bare numeric id and leaves a
//               provider's string id (`v6x.colorB`) alone, and does not add
//               `wallpaperRepresentingIdentifier` to a userInfo that has none.
//               The other way round installs a wallpaper PosterBoard cannot
//               index, silently, after a "successful" injection.
//
// Run:
//   cat Nugget/Core/PosterBoardAirlift.swift \
//       scripts/descriptor-finder-check.swift \
//     | grep -v '^import ZIPFoundation$' > /tmp/finder/main.swift
//   && swiftc -O /tmp/finder/main.swift -o /tmp/finder/check
//   && /tmp/finder/check <pack.tendies> [more.tendies ...]
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
    static func extractZip(archivePath: String, destDir: String) async throws {}
    static func injectFolder(pairingPath: String, folderPath: String,
                             targetParentDir: String, destName: String) async throws {}
    static func respring() async throws {}
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

    static func __check_randomize(in folder: URL, numericID: Int) {
        randomizeIdentifiers(in: folder, numericID: numericID)
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

    // 3  IDS. A numeric id is ours to replace; a provider's string id is not,
    //     and a userInfo without the key must not gain one. Both id carriers are
    //     checked — the video/photos shape has no bare id file and keeps its id
    //     in `Wallpaper.plist` instead, and a pack with neither is a fact about
    //     the pack, not a miss.
    for descriptor in found {
        let bareBefore = identifierText(in: descriptor.url)
        let plistBefore = wallpaperIdentifier(in: descriptor.url)
        let keysBefore = userInfoKeys(in: descriptor.url)
        PosterBoardAirlift.__check_randomize(in: descriptor.url, numericID: 47123)
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
        } else if bareAfter != nil {
            fail("a bare identifier file appeared: \(bareAfter ?? "nil")")
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
            if keysAfter?.contains("wallpaperRepresentingIdentifier") == false {
                pass("no wallpaperRepresentingIdentifier added to \(keysBefore.joined(separator: ","))")
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
        PosterBoardAirlift.__check_randomize(in: found[0].url, numericID: 47123)
        let text = (try? Data(contentsOf: idFile)).flatMap {
            String(data: $0, encoding: .utf8)
        }
        if text == "v6x.colorB" { pass("\(spelling)/ provider id intact") } else {
            fail("\(spelling)/ provider id became \(text ?? "nil")")
        }
    }
}

print(failures == 0 ? "\nall checks passed" : "\n\(failures) check(s) failed")
exit(failures == 0 ? 0 : 1)
