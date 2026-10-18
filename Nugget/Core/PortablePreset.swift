import Foundation
import ZIPFoundation

/// Desktop .gnpreset ZIP: a manifest plus exactly the declared, hashed assets.
/// Each import owns an isolated directory; importing never activates assets.
enum PortablePreset {
    static let format = "GoldenNugget portable preset"
    static func export(_ document: [String: Any], to destination: URL) throws {
        var document = document
        var tweaks = document["tweaks"] as? [String: [String: Any]] ?? [:]
        tweaks.removeValue(forKey: "PosterBoard")
        var assets: [String: [String: Any]] = [:], data: [String: Data] = [:]
        func capture(_ path: String) throws -> String {
            let file = URL(fileURLWithPath: path)
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= 64 * 1024 * 1024 else {
                throw CommunityError("Missing, linked or oversized preset asset.")
            }
            let bytes = try Data(contentsOf: file)
            let digest = CommunityCatalog.hash(bytes)
            let name = "assets/" + digest + "." + file.pathExtension.lowercased()
            assets[name] = ["size": bytes.count, "sha256": digest]; data[name] = bytes
            return "bundle://" + name
        }
        if var templates = tweaks["Templates"] {
            templates["templates"] = try (templates["templates"] as? [String] ?? []).map(capture)
            tweaks["Templates"] = templates
        }
        if var icons = tweaks["IconThemes"], let themes = icons["themes"] as? [[String: Any]] {
            icons["themes"] = try themes.map { raw -> [String: Any] in
                var theme = raw
                if let path = theme["icon_path"] as? String, !path.isEmpty { theme["icon_path"] = try capture(path) }
                return theme
            }
            tweaks["IconThemes"] = icons
        }
        document["tweaks"] = tweaks
        let manifest = try JSONSerialization.data(withJSONObject: ["format": format, "version": 1, "preset": document, "assets": assets], options: [.sortedKeys])
        guard manifest.count <= 4 * 1024 * 1024, data.values.reduce(0, { $0 + $1.count }) <= 256 * 1024 * 1024 else {
            throw CommunityError("Portable preset exceeds its size limit.")
        }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".zip")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let archive = try Archive(url: temporary, accessMode: .create)
        for (path, bytes) in data.merging(["manifest.json": manifest], uniquingKeysWith: { _, new in new }) {
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(bytes.count), compressionMethod: .deflate) { position, size in
                bytes.subdata(in: Int(position)..<(Int(position) + size))
            }
        }
        try Data(contentsOf: temporary).write(to: destination, options: .atomic)
    }
    static func importFile(_ url: URL) -> (Bool, String) {
        guard url.pathExtension.lowercased() == "gnpreset" else {
            return GoldenNuggetPresets.importPreset(from: url, newName: nil)
        }
        do {
            let imported = try decode(url)
            do { return (true, try CommunityCatalog.store(imported.document, name: url.deletingPathExtension().lastPathComponent)) }
            catch { try? FileManager.default.removeItem(at: imported.owned); throw error }
        } catch { return (false, error.localizedDescription) }
    }
    static func decode(_ source: URL) throws -> (document: [String: Any], owned: URL) {
        let archive = try Archive(url: source, accessMode: .read)
        var entries: [String: Entry] = [:]
        var total: UInt64 = 0
        for entry in archive {
            guard entry.type == .file, CommunityTemplate.relativePath(entry.path), entries[entry.path] == nil,
                  entries.count < 4096, entry.uncompressedSize <= 64 * 1024 * 1024 else {
                throw CommunityError("Unsafe portable preset archive.")
            }
            total += UInt64(entry.uncompressedSize)
            guard total <= 256 * 1024 * 1024 else { throw CommunityError("Portable preset expands beyond 256 MB.") }
            entries[entry.path] = entry
        }
        func read(_ path: String, limit: Int) throws -> Data {
            guard let entry = entries[path], entry.uncompressedSize <= limit else { throw CommunityError("Missing or oversized preset asset.") }
            var bytes = Data()
            let checksum = try archive.extract(entry) { chunk in
                guard bytes.count + chunk.count <= limit else { throw CommunityError("Oversized preset asset.") }
                bytes.append(chunk)
            }
            guard checksum == entry.checksum, bytes.count == Int(entry.uncompressedSize) else {
                throw CommunityError("Corrupt portable preset entry.")
            }
            return bytes
        }
        guard let manifest = try JSONSerialization.jsonObject(with: read("manifest.json", limit: 4 * 1024 * 1024)) as? [String: Any],
              manifest["format"] as? String == format, manifest["version"] as? Int == 1,
              var document = manifest["preset"] as? [String: Any], GoldenNuggetPresets.isValidImport(document),
              let assets = manifest["assets"] as? [String: [String: Any]],
              Set(entries.keys) == Set(assets.keys).union(["manifest.json"]) else {
            throw CommunityError("Invalid portable preset manifest.")
        }
        let owned = CommunityCatalog.directory.appendingPathComponent("imports/" + UUID().uuidString, isDirectory: true)
        var success = false
        defer { if !success { try? FileManager.default.removeItem(at: owned) } }
        try FileManager.default.createDirectory(at: owned, withIntermediateDirectories: true)
        var resolved: [String: String] = [:]
        for (name, asset) in assets {
            guard name.hasPrefix("assets/"), CommunityTemplate.relativePath(name),
                  let size = asset["size"] as? Int, size >= 0, size <= 64 * 1024 * 1024,
                  let sha = asset["sha256"] as? String, CommunityCatalog.matches(sha, "^[0-9a-f]{64}$") else {
                throw CommunityError("Invalid portable preset asset metadata.")
            }
            let data = try read(name, limit: 64 * 1024 * 1024)
            guard data.count == size, CommunityCatalog.hash(data) == sha else { throw CommunityError("Portable preset asset checksum mismatch.") }
            let file = owned.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
            resolved["bundle://" + name] = file.path
        }
        var used = Set<String>()
        func resolve(_ value: Any) throws -> String {
            guard let ref = value as? String, let path = resolved[ref] else { throw CommunityError("Preset references an undeclared asset.") }
            used.insert(ref)
            return path
        }
        var tweaks = document["tweaks"] as! [String: [String: Any]]
        if var template = tweaks["Templates"] {
            template["templates"] = try (template["templates"] as? [Any] ?? []).map(resolve)
            tweaks["Templates"] = template
        }
        if var icons = tweaks["IconThemes"], let themes = icons["themes"] as? [[String: Any]] {
            icons["themes"] = try themes.map { raw -> [String: Any] in
                var theme = raw
                if let path = theme["icon_path"], (path as? String)?.isEmpty == false { theme["icon_path"] = try resolve(path) }
                return theme
            }
            tweaks["IconThemes"] = icons
        }
        guard used == Set(resolved.keys) else { throw CommunityError("Preset contains unused assets.") }
        document["tweaks"] = tweaks
        success = true
        return (document, owned)
    }
}
