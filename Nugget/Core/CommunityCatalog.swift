import CryptoKit
import Foundation

/// Read-only desktop Community Catalog protocol. Imports are stored locally;
/// only the existing home Apply action can send their payloads to the device.
enum CommunityCatalog {
    static let indexURL = URL(string: "https://goldennugget-team.github.io/GoldenNugget-Presets/index.json")!
    static let repositoryURL = URL(string: "https://github.com/GoldenNugget-Team/GoldenNugget-Presets")!
    static let directory = URL.documents.appendingPathComponent("Community", isDirectory: true)
    static let cacheURL = directory.appendingPathComponent("preset_catalog.json")

    struct Entry: Identifiable {
        let id: String
        let name: String
        let author: String
        let detail: String
        let tags: [String]
        let minimum: String
        let maximum: String
        let code: String?
        let size: Int
        let digest: String
        let writes: [String]
        var isTemplate: Bool { code == nil }
        var key: String { (isTemplate ? "template:" : "preset:") + id }
        var fingerprint: String { code.map { CommunityCatalog.hash(Data($0.utf8)) } ?? digest }
        var installedURL: URL { CommunityCatalog.directory.appendingPathComponent(id + ".batter") }
        var rangeLabel: String {
            if !minimum.isEmpty && !maximum.isEmpty { return "iOS \(minimum)–\(maximum)" }
            if !minimum.isEmpty { return "iOS \(minimum)+" }
            return maximum.isEmpty ? "All iOS versions" : "iOS ≤ \(maximum)"
        }
        func supports(_ version: String) -> Bool {
            guard !version.isEmpty else { return true }
            if !minimum.isEmpty, TweakVersion.compare(version, minimum) == -1 { return false }
            if !maximum.isEmpty {
                let depth = maximum.split(separator: ".").count
                let prefix = version.split(separator: ".").prefix(depth).joined(separator: ".")
                if TweakVersion.compare(prefix, maximum) == 1 { return false }
            }
            return true
        }
        func matches(_ search: String) -> Bool {
            let text = ([name, author, detail] + tags).joined(separator: " ").lowercased()
            return search.lowercased().split(whereSeparator: \.isWhitespace).allSatisfy { text.contains($0) }
        }
    }
    struct Index {
        let entries: [Entry]
        let rejected: Int
        var cached = false
    }

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    static func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }
    static func parse(_ data: Data) throws -> Index {
        guard data.count <= 4 * 1024 * 1024,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["format"] as? Int == 1, let presets = root["presets"] as? [Any] else {
            throw CommunityError("Unsupported or oversized community catalog.")
        }
        var result: [Entry] = []
        var rejected = 0
        for (isTemplate, rows) in [(false, presets), (true, root["templates"] as? [Any] ?? [])] {
            var seen = Set<String>()
            for raw in rows.prefix(2000) {
                do {
                    let entry = try parseEntry(raw, template: isTemplate)
                    guard seen.insert(entry.id).inserted else { throw CommunityError("Duplicate catalog entry.") }
                    result.append(entry)
                } catch { rejected += 1 }
            }
        }
        return Index(entries: result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending },
                     rejected: rejected)
    }
    private static func parseEntry(_ raw: Any, template: Bool) throws -> Entry {
        guard let row = raw as? [String: Any], let id = row["id"] as? String,
              matches(id, "^[a-z0-9][a-z0-9-]{1,47}$") else { throw CommunityError("Invalid catalog ID.") }
        func text(_ key: String, limit: Int, required: Bool = false) throws -> String {
            guard let value = (row[key] ?? "") as? String, value.count <= limit,
                  !required || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CommunityError("Invalid catalog text.")
            }
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let name = try text("name", limit: 60, required: true)
        let author = try text("author", limit: 40, required: true)
        let detail = try text("description", limit: 500)
        let minimum = try text("ios_min", limit: 8), maximum = try text("ios_max", limit: 8)
        for version in [minimum, maximum] where !version.isEmpty {
            guard matches(version, "^[0-9]{1,2}(\\.[0-9]{1,2}){0,2}$") else { throw CommunityError("Invalid iOS range.") }
        }
        if !minimum.isEmpty && !maximum.isEmpty && TweakVersion.compare(minimum, maximum) == 1 {
            throw CommunityError("Invalid iOS range.")
        }
        guard let tags = (row["tags"] ?? []) as? [String], tags.count <= 8,
              tags.allSatisfy({ !$0.isEmpty && $0.count <= 24 }) else { throw CommunityError("Invalid catalog tags.") }
        var code: String?, size = 0, digest = "", writes: [String] = []
        if template {
            guard let bytes = row["size"] as? NSNumber, CFGetTypeID(bytes) != CFBooleanGetTypeID(),
                  bytes.doubleValue.rounded() == bytes.doubleValue, bytes.intValue > 0,
                  bytes.intValue <= 25 * 1024 * 1024, let sha = row["sha256"] as? String,
                  matches(sha, "^[0-9a-f]{64}$"), let tweaks = (row["tweaks"] ?? []) as? [[String: Any]] else {
                throw CommunityError("Invalid template metadata.")
            }
            size = bytes.intValue; digest = sha
            for tweak in tweaks {
                guard let label = tweak["label"] as? String, let paths = tweak["writes"] as? [String],
                      paths.allSatisfy({ $0.count <= 1024 }) else { throw CommunityError("Invalid template paths.") }
                writes += paths.map { "\(label.prefix(80)): \($0)" }
            }
            guard writes.count <= 64 else { throw CommunityError("Too many template writes.") }
        } else {
            guard let value = row["code"] as? String, value.hasPrefix("GN1."), value.count <= 6000 else {
                throw CommunityError("Invalid preset code.")
            }
            let document = try PresetShareCode.decode(value)
            guard (document["tweaks"] as? [String: [String: Any]] ?? [:]).values.contains(where: { $0["enabled"] as? Bool == true }) else {
                throw CommunityError("Preset contains no enabled tweaks.")
            }
            code = value
        }
        return Entry(id: id, name: name, author: author, detail: detail, tags: tags,
                     minimum: minimum, maximum: maximum, code: code, size: size, digest: digest, writes: writes)
    }

    /// Streaming limit applies before allocation, including responses without Content-Length.
    static func download(_ url: URL, limit: Int) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              response.expectedContentLength <= Int64(limit) else { throw CommunityError("Catalog download failed.") }
        var data = Data()
        for try await byte in bytes {
            guard data.count < limit else { throw CommunityError("Download exceeds its size limit.") }
            data.append(byte)
        }
        return data
    }
    static func fetch() async throws -> Index {
        do {
            let data = try await download(indexURL, limit: 4 * 1024 * 1024)
            let index = try parse(data)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: cacheURL, options: .atomic)
            return index
        } catch {
            if let data = try? Data(contentsOf: cacheURL), var index = try? parse(data) {
                index.cached = true
                return index
            }
            throw error
        }
    }
    static func installedPreset(_ entry: Entry) -> String? {
        GoldenNuggetPresets.list().first {
            let mark = GoldenNuggetPresets.metadata(for: $0)?["catalog"] as? [String: String]
            return mark?["id"] == entry.id
        }
    }
    static func status(_ entry: Entry) -> String? {
        let digest: String?
        if entry.isTemplate {
            digest = (try? Data(contentsOf: entry.installedURL)).map(hash)
        } else if let name = installedPreset(entry) {
            digest = (GoldenNuggetPresets.metadata(for: name)?["catalog"] as? [String: String])?["sha256"]
        } else { digest = nil }
        return digest.map { $0 == entry.fingerprint ? "Installed" : "Update available" }
    }
    static func installPreset(_ entry: Entry) throws -> String {
        guard let code = entry.code else { throw CommunityError("This entry is a template.") }
        var document = try PresetShareCode.decode(code)
        var meta = document["metadata"] as? [String: Any] ?? [:]
        meta["catalog"] = ["id": entry.id, "sha256": entry.fingerprint]
        document["metadata"] = meta
        if let existing = installedPreset(entry) {
            try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
                .write(to: GoldenNuggetPresets.fileURL(for: existing), options: .atomic)
            return existing
        }
        return try store(document, name: entry.name)
    }
    static func store(_ document: [String: Any], name: String) throws -> String {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        try JSONSerialization.data(withJSONObject: document).write(to: file)
        let result = GoldenNuggetPresets.importPreset(from: file, newName: name)
        guard result.0 else { throw CommunityError(result.1) }
        return result.1
    }
}
