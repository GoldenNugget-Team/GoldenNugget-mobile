import CryptoKit
import Foundation

/// Device-scoped history of successful community writes. Like desktop's
/// reset_plan, only Managed Preferences can be emptied without an original
/// backup; replaced files in other domains are reported for manual recovery.
enum CommunityApplyRecord {
    static func url(_ udid: String) -> URL {
        let name = SHA256.hash(data: Data(udid.utf8)).map { String(format: "%02x", $0) }.joined()
        return URL.documents.appendingPathComponent("Community/applied-\(name).json")
    }
    static func payloads(_ udid: String) -> [(String, String)] {
        guard let data = try? Data(contentsOf: url(udid)),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] else { return [] }
        return rows.compactMap { row in
            guard let domain = row["domain"], let path = row["path"],
                  CommunityTemplate.relativePath(path), !domain.contains("/") else { return nil }
            return (domain, path)
        }
    }
    static func record(_ payloads: [TweakPayload], udid: String) throws {
        guard !payloads.isEmpty else { return }
        var rows = Dictionary(uniqueKeysWithValues: Self.payloads(udid).map { ("\($0.0)/\($0.1)", ["domain": $0.0, "path": $0.1]) })
        for payload in payloads { rows[payload.label] = ["domain": payload.domain, "path": payload.relativePath] }
        try FileManager.default.createDirectory(at: url(udid).deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: Array(rows.values)).write(to: url(udid), options: .atomic)
    }
    static func resetPlan(_ udid: String) throws -> (payloads: [TweakPayload], remaining: [String]) {
        var result: [TweakPayload] = [], remaining: [String] = []
        let empty = try PropertyListSerialization.data(fromPropertyList: [:], format: .xml, options: 0)
        for (domain, path) in payloads(udid) {
            if domain == "ManagedPreferencesDomain" {
                result.append(TweakPayload(domain: domain, relativePath: path, contents: empty))
            } else { remaining.append("\(domain)/\(path)") }
        }
        return (result, remaining.sorted())
    }
    static func didReset(_ udid: String) throws {
        let rows = payloads(udid).filter { $0.0 != "ManagedPreferencesDomain" }.map { ["domain": $0.0, "path": $0.1] }
        try JSONSerialization.data(withJSONObject: rows).write(to: url(udid), options: .atomic)
    }
}
