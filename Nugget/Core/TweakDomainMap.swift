import Foundation

/// Absolute device path → backup domain, ported from GoldenNugget's
/// `src/restore/path_mapping.py`.
///
/// The reference keeps this table in exactly one module because it used to live
/// in two (`DeviceManager.get_domain_for_path` and `original_plist.
/// _BACKUP_DOMAIN_MAPPINGS`) "with the risk that one drifted and a reset wrote
/// plists into the wrong domain".  It is one place here too, and the tweak
/// compiler is its only caller.
enum TweakDomainMap {
    /// One prefix rule.  `isContainer` marks the Sys(SHARED)Container domains,
    /// whose first path segment becomes part of the domain name
    /// (`/var/containers/Data/SystemGroup/<group>/…` → `SysContainerDomain-<group>`).
    private struct Rule {
        let prefix: String
        let domain: String
        let isContainer: Bool
    }

    /// Order is load-bearing: the reference tests these in sequence and takes
    /// the first match, so `/var/Managed Preferences/` must be reached before a
    /// looser prefix could shadow it.  Kept in the reference's own order.
    private static let rules: [Rule] = [
        Rule(prefix: "/var/Managed Preferences/", domain: "ManagedPreferencesDomain", isContainer: false),
        Rule(prefix: "/var/root/", domain: "RootDomain", isContainer: false),
        Rule(prefix: "/var/preferences/", domain: "SystemPreferencesDomain", isContainer: false),
        Rule(prefix: "/var/MobileDevice/", domain: "MobileDeviceDomain", isContainer: false),
        Rule(prefix: "/var/mobile/", domain: "HomeDomain", isContainer: false),
        Rule(prefix: "/var/db/", domain: "DatabaseDomain", isContainer: false),
        Rule(prefix: "/var/containers/Shared/SystemGroup/",
             domain: "SysSharedContainerDomain-", isContainer: true),
        Rule(prefix: "/var/containers/Data/SystemGroup/",
             domain: "SysContainerDomain-", isContainer: true),
    ]

    /// The `(domain, relativePath)` pair a manifest row carries.
    struct Destination: Equatable, Sendable {
        let domain: String
        let relativePath: String
    }

    /// `split_path_into_domain`.  Returns nil when no prefix matches.
    static func split(path: String) -> Destination? {
        for rule in rules where path.hasPrefix(rule.prefix) {
            let rest = String(path.dropFirst(rule.prefix.count))
            guard rule.isContainer else {
                return Destination(domain: rule.domain, relativePath: rest)
            }
            // Python's `rest.partition("/")`: no separator means the whole rest
            // is the group name and the relative path is empty.
            if let slash = rest.firstIndex(of: "/") {
                let group = String(rest[rest.startIndex..<slash])
                let remainder = String(rest[rest.index(after: slash)...])
                return Destination(domain: rule.domain + group, relativePath: remainder)
            }
            return Destination(domain: rule.domain + rest, relativePath: "")
        }
        return nil
    }
}
