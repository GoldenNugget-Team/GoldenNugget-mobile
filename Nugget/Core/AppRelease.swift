import Foundation

/// Numeric release versions with an optional SemVer prerelease. CFBundleVersion
/// is an independent iOS build number; it is never treated as a desktop beta flag.
struct AppReleaseVersion: Comparable {
    let numbers: [Int]
    let prerelease: [String]

    init?(_ raw: String) {
        let tag = raw.hasPrefix("v") ? String(raw.dropFirst()) : raw
        let withoutBuild = tag.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)[0]
        let parts = withoutBuild.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let digits = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(digits.count), digits.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              digits.allSatisfy({ Int($0) != nil }) else { return nil }
        numbers = digits.map { Int($0)! }
        prerelease = parts.count == 2 ? parts[1].split(separator: ".", omittingEmptySubsequences: false).map(String.init) : []
        guard prerelease.allSatisfy({ !$0.isEmpty && $0.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) }) else { return nil }
    }

    static func == (lhs: Self, rhs: Self) -> Bool { !(lhs < rhs) && !(rhs < lhs) }
    static func < (lhs: Self, rhs: Self) -> Bool {
        for index in 0..<max(lhs.numbers.count, rhs.numbers.count) {
            let a = index < lhs.numbers.count ? lhs.numbers[index] : 0
            let b = index < rhs.numbers.count ? rhs.numbers[index] : 0
            if a != b { return a < b }
        }
        if lhs.prerelease.isEmpty || rhs.prerelease.isEmpty { return !lhs.prerelease.isEmpty && rhs.prerelease.isEmpty }
        for index in 0..<min(lhs.prerelease.count, rhs.prerelease.count) {
            let a = lhs.prerelease[index], b = rhs.prerelease[index]
            if a == b { continue }
            if let x = Int(a), let y = Int(b) { return x < y }
            if Int(a) != nil { return true }
            if Int(b) != nil { return false }
            return a < b
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }
}

/// GitHub's latest stable *mobile* release, with links restricted to this repo.
/// Opening its page/IPA leaves signing and installation to the user's sideloader.
struct AppRelease: Decodable {
    static let repository = "GoldenNugget-Team/GoldenNugget-mobile"
    static let latestURL = URL(string: "https://github.com/\(repository)/releases/latest")!
    static let apiURL = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
    let tag_name: String
    let html_url: String
    let body: String?
    let draft: Bool
    let prerelease: Bool
    let assets: [Asset]

    struct Asset: Decodable {
        let name: String
        let browser_download_url: String
    }

    static func parse(_ data: Data) throws -> AppRelease {
        let release = try JSONDecoder().decode(Self.self, from: data)
        guard !release.draft, !release.prerelease, AppReleaseVersion(release.tag_name) != nil,
              release.pageURL != nil else { throw CocoaError(.coderReadCorrupt) }
        return release
    }

    func isNewer(than current: String) -> Bool {
        guard let latest = AppReleaseVersion(tag_name), let installed = AppReleaseVersion(current) else { return false }
        return installed < latest
    }

    private static func trustedURL(_ raw: String, prefix: String) -> URL? {
        guard let url = URL(string: raw), url.scheme == "https", url.host == "github.com",
              url.user == nil, url.password == nil, url.port == nil,
              !url.pathComponents.contains(".."), !url.pathComponents.contains("."),
              url.path.hasPrefix("/\(repository)/releases/\(prefix)") else { return nil }
        return url
    }

    var pageURL: URL? { Self.trustedURL(html_url, prefix: "tag/") }
    var downloadURL: URL? {
        assets.first(where: { $0.name.lowercased().hasSuffix(".ipa") && Self.trustedURL($0.browser_download_url, prefix: "download/") != nil })
            .flatMap { Self.trustedURL($0.browser_download_url, prefix: "download/") }
    }
}
