import Foundation

/// ProductVersion alone cannot distinguish 27.2 betas. Only the two known
/// builds before beta 3 (24B5099f) remain eligible; unknown 27.2 builds fail closed.
/// Verified with `ipsw download appledb --os iOS --version "27.2 beta" --json`
/// and the beta 3 IPSW BuildManifest on Apple's CDN.
enum AirliftAvailability {
    private static let early272Builds: Set<String> = ["24B5084k", "24B5089g"]

    static func isHidden(deviceVersion: String, buildVersion: String) -> Bool {
        let parts = deviceVersion.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ".", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count),
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              let major = Int(parts[0]), let minor = Int(parts[1]) else { return true }
        if major != 27 { return major > 27 }
        if minor != 2 { return minor > 2 }
        if parts.count == 3, Int(parts[2]) != 0 { return true }
        return !early272Builds.contains(buildVersion.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
