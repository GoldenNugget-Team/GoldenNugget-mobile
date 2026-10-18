import Foundation
import zlib

/// Desktop's GN1 wire format: base64url(zlib(JSON)), bounded before decoding.
/// Decoding fills disabled registry entries so loading replaces the selection.
enum PresetShareCode {
    static let localOnly: Set<String> = ["PosterBoard", "Templates", "IconThemes"]
    static let limit = 256 * 1024

    static func decode(_ text: String) throws -> [String: Any] {
        guard let start = text.range(of: "GN1.") else { throw CommunityError("No GoldenNugget share code found.") }
        let alphabet = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        let body = text[start.upperBound...].prefix { alphabet.contains($0) || $0.isWhitespace }
            .filter { !$0.isWhitespace }
        guard body.count + 4 <= 6000 else { throw CommunityError("The share code is too long.") }
        var base64 = body.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let compressed = Data(base64Encoded: base64), !compressed.isEmpty else {
            throw CommunityError("The share code is damaged.")
        }
        var output = Data(count: limit + 1)
        var count = uLongf(output.count)
        let status = output.withUnsafeMutableBytes { target in
            compressed.withUnsafeBytes { input in
                uncompress(target.bindMemory(to: Bytef.self).baseAddress!, &count,
                           input.bindMemory(to: Bytef.self).baseAddress!, uLong(compressed.count))
            }
        }
        guard status == Z_OK, count <= limit else { throw CommunityError("Invalid or oversized share code.") }
        output.count = Int(count)
        guard let payload = try JSONSerialization.jsonObject(with: output) as? [String: Any],
              payload["v"] as? Int == 1, let shared = payload["t"] as? [String: Any] else {
            throw CommunityError("Unsupported share code version.")
        }
        let known = Set(TweakCatalog.allWithDaemons.map(\.id)).union(["Daemons", "StatusBar"])
        var tweaks = Dictionary(uniqueKeysWithValues: known.map { ($0, ["enabled": false] as [String: Any]) })
        for (id, entry) in shared where known.contains(id) && !localOnly.contains(id) {
            guard let value = entry as? [String: Any] else { throw CommunityError("Invalid tweak data.") }
            tweaks[id] = value
        }
        var metadata: [String: Any] = ["tags": ["shared"], "version": 2]
        for (source, key) in [("n", "name"), ("d", "description"), ("ios", "ios_version")] {
            if let value = payload[source] as? String { metadata[key] = String(value.prefix(200)) }
        }
        let document: [String: Any] = ["tweaks": tweaks, "metadata": metadata]
        guard GoldenNuggetPresets.isValidImport(document) else { throw CommunityError("Invalid preset data.") }
        return document
    }

    static func encode(_ document: [String: Any], name: String) throws -> String {
        var selected: [String: Any] = [:]
        var legacyDaemons: [String: Any] = [:]
        for (id, value) in document["tweaks"] as? [String: [String: Any]] ?? [:]
            where !localOnly.contains(id) && value["enabled"] as? Bool == true {
            if id.hasPrefix("Daemon.") {
                for (key, value) in value["value"] as? [String: Any] ?? [:] where DaemonGroups.allowedKeys.contains(key) {
                    legacyDaemons[key] = value
                }
                continue
            }
            selected[id] = value.filter { $0.key != "type" }
        }
        if selected["Daemons"] == nil && !legacyDaemons.isEmpty {
            selected["Daemons"] = ["enabled": true, "value": legacyDaemons]
        }
        guard !selected.isEmpty else { throw CommunityError("No enabled tweaks to share.") }
        let metadata = document["metadata"] as? [String: Any] ?? [:]
        let payload: [String: Any] = ["v": 1, "t": selected, "n": String(name.prefix(200)),
                                     "d": String((metadata["description"] as? String ?? "").prefix(200)),
                                     "ios": String((metadata["ios_version"] as? String ?? "").prefix(200))]
        let raw = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        guard raw.count <= limit else { throw CommunityError("Preset too large to share.") }
        var output = Data(count: Int(compressBound(uLong(raw.count))))
        var count = uLongf(output.count)
        let status = output.withUnsafeMutableBytes { target in
            raw.withUnsafeBytes { input in
                compress2(target.bindMemory(to: Bytef.self).baseAddress!, &count,
                          input.bindMemory(to: Bytef.self).baseAddress!, uLong(raw.count), 9)
            }
        }
        guard status == Z_OK else { throw CommunityError("Cannot encode share code.") }
        output.count = Int(count)
        let code = "GN1." + output.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        guard code.count <= 6000 else { throw CommunityError("Preset too large to share as a code.") }
        return code
    }
}

struct CommunityError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
