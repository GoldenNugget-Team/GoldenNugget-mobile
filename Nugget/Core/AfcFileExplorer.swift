import Foundation
import Minimuxer
import DeviceGatewayAPI
import IdeviceGateway

/// A browser for the device filesystem that AFC actually exposes.
///
/// This is not a jailbreak shell and does not pretend to be. `afc://` is the
/// Media service: whatever the device chooses to publish under it, which on a
/// stock device is `/var/mobile/Media` and on this one also carries the app
/// containers the tunnel exposes. The root is asked for rather than assumed, so
/// the page shows what is really there instead of a hardcoded path that happens
/// to work today.
///
/// Every destructive call here is the device's own `afcDelete`, and that is a
/// real unlink with no undo and no trash. The UI keeps the confirmation and the
/// size in front of the user, but the reason to be careful is the reason to read
/// the path before pressing the button.
enum AfcFileExplorer {

    /// The largest file `afcWrite` will take in one call. The API has no
    /// streaming write, so a push is a single buffer, and a file bigger than
    /// this is refused before anything is sent rather than after.
    static let pushSizeLimit: Int64 = 64 * 1024 * 1024

    /// Where pulled files land. Under the container, never on the device: a
    /// browser that wrote its own downloads back into the tree it is browsing
    /// would show up in the next listing as if the device had produced them.
    static var downloadsRoot: URL {
        URL.documents.appendingPathComponent("Files", conformingTo: .data)
    }

    // MARK: - Paths

    static func children(of path: String) async throws -> [AfcFsEntry] {
        let entries = try await gateway().afcList(path: path)
        // Folders first, then by name, case-insensitively: the point of a
        // browser is to find something, and a folder buried under 400 files is
        // the same as not being there. `.` and `..` are the device's problem, not
        // ours, and nothing downstream should have to know they can appear.
        return entries
            .filter { $0.name != "." && $0.name != ".." }
            .sorted { a, b in
                if a.isDirectory != b.isDirectory { return a.isDirectory }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
    }

    /// `/DCIM` -> ["DCIM"]; an empty component list is the service's own root,
    /// which is the only path that is valid whatever the device calls it.
    ///
    /// `/DCIM` -> ["/", "DCIM"]; a relative path is treated as one component.
    static func components(of path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    static func join(_ components: [String]) -> String {
        components.isEmpty ? "/" : "/" + components.joined(separator: "/")
    }

    static func parent(of path: String) -> String {
        let parts = components(of: path)
        return join(Array(parts.dropLast()))
    }

    /// A path that does not exist yet, derived from one that does.
    ///
    /// `name (2).ext`, which is what a desktop file manager does and, more to the
    /// point, what makes a second pull of the same file not silently replace the
    /// first one.
    static func uniqueName(_ name: String, against existing: Set<String>) -> String {
        guard existing.contains(name) else { return name }
        let url = URL(fileURLWithPath: name)
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let suffix = ext.isEmpty ? "" : ".\(ext)"
        var n = 2
        while existing.contains("\(stem) (\(n))\(suffix)") { n += 1 }
        return "\(stem) (\(n))\(suffix)"
    }

    // MARK: - Reading

    /// Pull one file into the container, keeping it there.
    @discardableResult
    static func pull(_ entry: AfcFsEntry, progress: (@Sendable (Double) -> Void)? = nil) async throws -> URL {
        guard !entry.isDirectory else {
            throw GoldenNuggetError("Only files can be pulled. \(entry.name) is a folder.")
        }
        try FileManager.default.createDirectory(at: downloadsRoot, withIntermediateDirectories: true)
        let existing = Set(try FileManager.default.contentsOfDirectory(atPath: downloadsRoot.path))
        let destination = downloadsRoot.appendingPathComponent(uniqueName(entry.name, against: existing))
        try await stream(entry, into: destination, progress: progress)
        return destination
    }

    /// The same bytes, into the temporary directory, for a file that is about to be
    /// looked at rather than kept.
    ///
    /// Quick Look needs a local file, and `pull` would leave the preview in
    /// `Documents/Files` — where it is indistinguishable from a file the user chose
    /// to keep, and where the next preview of the same name lands beside it as
    /// `name (2).ext`. The temp directory is reclaimed by the system, so a preview
    /// leaves nothing behind whether or not the sheet is ever dismissed.
    @discardableResult
    static func pullToTemporaryFile(
        _ entry: AfcFsEntry,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> URL {
        guard !entry.isDirectory else {
            throw GoldenNuggetError("Only files can be previewed. \(entry.name) is a folder.")
        }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent(entry.name)
        try? FileManager.default.removeItem(at: destination.deletingLastPathComponent())
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try await stream(entry, into: destination, progress: progress)
        return destination
    }

    /// Stream one file to a local path, via a `.partial` sibling that is renamed
    /// only after the device says it sent every byte.
    ///
    /// Streamed rather than `afcRead` into a `Data` because the read has no size
    /// ceiling and a photo library entry can be larger than a phone wants to hold
    /// twice: once in the AFC buffer and once as a Swift `Data`. The `.partial`
    /// name means an interrupted pull cannot masquerade as a complete file.
    private static func stream(
        _ entry: AfcFsEntry,
        into destination: URL,
        progress: (@Sendable (Double) -> Void)?
    ) async throws {
        let gateway = try await gateway()
        let partial = destination.appendingPathExtension("afcpartial")
        try? FileManager.default.removeItem(at: partial)
        FileManager.default.createFile(atPath: partial.path, contents: nil)
        let handle = try FileHandle(forWritingTo: partial)
        defer { try? handle.close() }

        let total = max(entry.size, 0)
        do {
            let written = try await gateway.afcStreamFile(path: entry.path, chunkSize: 1 << 18) { chunk in
                try handle.write(contentsOf: chunk)
                if let progress, total > 0 {
                    progress(Double(handle.offsetInFile) / Double(total))
                }
            }
            if total > 0, written != total {
                throw GoldenNuggetError("\(entry.name): the device sent \(written) of \(total) byte(s).")
            }
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: partial, to: destination)
    }

    // MARK: - Writing

    /// Push a local file to `directory`.
    ///
    /// Refuses anything over the single-call write limit. A partial push is
    /// worse than a refused one: the device would hold a truncated file under a
    /// name that claims to be the original.
    static func push(_ local: URL, to directory: String) async throws -> AfcFsEntry {
        let size = (try? local.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        guard size <= pushSizeLimit else {
            throw GoldenNuggetError("\(local.lastPathComponent) is "
                + "\(format(size)); AFC writes are capped at \(format(pushSizeLimit)) in one call.")
        }
        let data: Data
        do {
            data = try Data(contentsOf: local, options: .mappedIfSafe)
        } catch {
            throw GoldenNuggetError("Cannot read \(local.lastPathComponent): \(error.localizedDescription)")
        }
        let remote = join(components(of: directory) + [local.lastPathComponent])
        try await gateway().afcWrite(path: remote, data: data)
        return try await gateway().afcEntryInfo(path: remote)
    }

    static func makeDirectory(named name: String, in parent: String) async throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/") else {
            throw GoldenNuggetError("A folder name cannot be empty or contain a slash.")
        }
        try await gateway().afcMakeDirectory(path: join(components(of: parent) + [trimmed]))
    }

    static func rename(_ entry: AfcFsEntry, to newName: String) async throws {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/") else {
            throw GoldenNuggetError("A name cannot be empty or contain a slash.")
        }
        guard trimmed != entry.name else { return }
        let parent = parent(of: entry.path)
        try await gateway().afcRename(path: entry.path,
                                      to: join(components(of: parent) + [trimmed]))
    }

    /// Remove a file or an emptied directory.
    ///
    /// There is no trash and no undo on the other end, so the UI confirms with
    /// the name and the size attached rather than a bare "are you sure".
    static func delete(_ entry: AfcFsEntry) async throws {
        if entry.isDirectory {
            let children = try await children(of: entry.path)
            guard children.isEmpty else {
                throw GoldenNuggetError("\(entry.name) is not empty — "
                    + "\(children.count) item(s) inside. Delete them first.")
            }
        }
        try await gateway().afcDelete(path: entry.path)
    }

    // MARK: - Volume

    static func volume() async throws -> AfcFsVolumeInfo {
        try await gateway().afcVolumeInfo()
    }

    static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private static func gateway() async throws -> IdeviceGateway {
        guard let gateway = Minimuxer.shared().ideviceGateway else {
            throw GoldenNuggetError("AFC: no idevice gateway — is the tunnel up?")
        }
        return gateway
    }
}
