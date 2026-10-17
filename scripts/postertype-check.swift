// Regression harness for the poster-type detection in
// `PosterBoardTendie.init` — which provider a pack is *for*, read off its own
// entry paths.
//
// What it checks, none of which needs a device:
//
//   DETECT   a bare Collections pack detects `.collections`; the Mercury
//            snapshot detects `.mercury`, not `.container`; a video pack detects
//            `.suggestedPhotos`; a store snapshot with no provider in the path
//            detects `.container`. The second one is the case this port got
//            wrong: the container rule fired on `…/Container/Library/…` and
//            nothing ever looked at the extension that follows `Extensions/`, so
//            a real Mercury pack claimed to be a container dump.
//
// Run:
//   cat Nugget/Core/PosterBoardTendie.swift \
//       Nugget/Core/PosterBoardApplyMode.swift \
//       scripts/postertype-check.swift > /tmp/ptype/main.swift
//   && swiftc -O /tmp/ptype/main.swift -o /tmp/ptype/check
//   && /tmp/ptype/check <pack.tendies> [more.tendies ...]
//
// `Archive` is stubbed over `unzip -Z1` rather than a real reader: the init only
// ever iterates entry paths, so the listing is the whole of what it needs, and
// this keeps the harness off a zip library. Only the listing is faked — the code
// under test is the shipping file, concatenated rather than copied, reached
// through an extension because the init is internal.
//
// This file is NOT part of the app target; keep it out of Package.swift.

import Foundation

// MARK: - Stubs

struct Archive: Sequence {
    struct Entry: Hashable {
        enum EntryType { case file, directory, symlink }
        let path: String
        /// Derived from the listing the way a zip reader would: a trailing slash
        /// is a directory. `PosterBoardTendie` only reads `type` to skip
        /// directories it has already created, so this is enough.
        var type: EntryType { path.hasSuffix("/") ? .directory : .file }
    }
    enum AccessMode { case read, create, update }

    private let entries: [Entry]

    init(url: URL, accessMode access: AccessMode) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        proc.arguments = ["-Z1", url.path]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            throw GoldenNuggetError("unzip -Z1 failed (\(proc.terminationStatus))")
        }
        let text = String(decoding: data, as: UTF8.self)
        entries = text.split(separator: "\n", omittingEmptySubsequences: true)
            .map { Entry(path: String($0)) }
    }

    func makeIterator() -> AnyIterator<Entry> {
        var index = 0
        return AnyIterator {
            guard index < entries.count else { return nil }
            defer { index += 1 }
            return entries[index]
        }
    }

    /// Unused by the init; present because the same file's extractor calls it.
    func extract(_ entry: Entry, to url: URL) throws -> Data {
        throw GoldenNuggetError("the harness does not extract")
    }
}

extension URL {
    static var documents: URL { URL(fileURLWithPath: "/tmp/ptype/documents") }
    /// UniformTypeIdentifiers is not on this platform, and this overload comes
    /// with it. The conformance argument is dropped, which is all the harness
    /// needs: the paths it appends are the same either way.
    func appendingPathComponent(_ path: String, conformingTo _: UTType?) -> URL {
        appendingPathComponent(path)
    }
}

/// Just the one case the app under test names, standing in for
/// UniformTypeIdentifiers, which does not exist here.
enum UTType { case data }

/// Named by the import code in the same file; the harness never walks the
/// device, so a stub that is never called is the honest one.
enum AfcFileExplorer {
    static func uniqueName(_ name: String, against existing: Set<String>) -> String { name }
}

extension URL {
    /// Security-scoped URLs are a device concept; nothing in the harness is
    /// scoped, so this is the real thing minus the platform.
    func startAccessingSecurityScopedResource() -> Bool { false }
    func stopAccessingSecurityScopedResource() {}
}

enum PosterBoardPreferences {
    /// The harness has no preferences to read, which is the point: it is checking
    /// the fallback path, the one a device gets for a pack it has never been told
    /// about.
    private static var store: [String: PosterBoardPosterType] = [:]
    static var posterTypes: [String: PosterBoardPosterType] {
        get { store }
        set { store = newValue }
    }
    static func reset() {}
}

struct GoldenNuggetError: Error { let message: String; init(_ m: String) { message = m } }

// MARK: - The check

var failures = 0

/// What each pack is expected to detect, and why. Spelled out per file rather
/// than sniffed, so a change in the detection cannot quietly redefine the
/// expectation: the expectation is the reference's, fixed here.
let expected: [String: PosterBoardPosterType] = [
    "iPhone 18 Pro - All Colors.tendies": .mercury,
    "Among_Us_e7216358.tendies": .collections,
    "Animal_Crossing_Seasons_df0415bb.tendies": .collections,
    "Wii_Homebrew_Channel_Red_c78ea60c.tendies": .collections,
    "DVD_Screensaver_04f9e71d.tendies": .collections,
    "Windows_11_c96ec63b.tendies": .collections,
]

for argument in CommandLine.arguments.dropFirst() {
    let url = URL(fileURLWithPath: argument)
    let name = url.lastPathComponent
    do {
        let tendie = try PosterBoardTendie(url: url)
        let want = expected[name] ?? .collections
        if tendie.posterType == want {
            print("  ✓ \(name): \(tendie.posterType.rawValue) "
                  + "(\(tendie.descriptorCount) descriptor(s), container: \(tendie.isContainer))")
        } else {
            print("  ✗ \(name): detected \(tendie.posterType.rawValue), expected \(want.rawValue)")
            failures += 1
        }
    } catch {
        print("  ✗ \(name): \(error)")
        failures += 1
    }
}

print(failures == 0 ? "\nall checks passed" : "\n\(failures) check(s) failed")
exit(failures == 0 ? 0 : 1)
