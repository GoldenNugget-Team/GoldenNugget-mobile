import Foundation
import Combine

/// Bounded metadata requests using the system TLS trust store. Cache is handled
/// by each service, so HTTP errors cannot overwrite the last valid rules/release.
enum RemoteMetadataError: LocalizedError {
    case httpStatus(Int)
    var errorDescription: String? {
        switch self { case .httpStatus(let code): return "The server returned HTTP \(code)." }
    }
}

enum RemoteMetadata {
    static func fetch(_ url: URL, session: URLSession = .shared) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("GoldenNugget-Mobile", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard http.statusCode == 200 else { throw RemoteMetadataError.httpStatus(http.statusCode) }
        let limit = 2 * 1024 * 1024
        guard response.expectedContentLength <= Int64(limit) else { throw URLError(.dataLengthExceedsMaximum) }
        var data = Data()
        for try await byte in bytes {
            if data.count >= limit { throw URLError(.dataLengthExceedsMaximum) }
            data.append(byte)
        }
        return data
    }
}

/// Loaded synchronously from disk before the shell appears. Publication and
/// preferences live on the main actor; engine calls capture an immutable policy.
@MainActor
final class HotLoadService: ObservableObject {
    static let shared = HotLoadService()
    static let enabledKey = "hotload_enabled"
    static let rulesURL = URL(string: "https://raw.githubusercontent.com/GoldenNugget-Team/GoldenNugget-mobile/main/hotload_rules.json")!
    nonisolated static var appVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }

    @Published private(set) var rules: HotLoadRules
    @Published private(set) var checking = false
    @Published private(set) var error: String?
    @Published private(set) var checkedAt: Date?
    @Published var enabled: Bool {
        didSet { defaults.set(enabled, forKey: Self.enabledKey) }
    }
    private let defaults: UserDefaults
    private let cacheURL: URL
    private let session: URLSession

    init(defaults: UserDefaults = .standard, cacheURL: URL? = nil, session: URLSession = .shared) {
        self.defaults = defaults
        self.cacheURL = cacheURL ?? Self.defaultCacheURL
        self.session = session
        enabled = defaults.object(forKey: Self.enabledKey) == nil || defaults.bool(forKey: Self.enabledKey)
        rules = (try? Data(contentsOf: self.cacheURL)).flatMap { try? HotLoadRules.parse($0) } ?? .empty
        checkedAt = (try? self.cacheURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    private static var defaultCacheURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GoldenNugget/hotload_rules.json")
    }

    func policy(deviceVersion: String, model: String) -> HotLoadPolicy {
        rules.policy(appVersion: Self.appVersion, deviceVersion: deviceVersion, model: model, enabled: enabled)
    }

    var currentPolicy: HotLoadPolicy {
        let device = DeviceIdentityMonitor.shared.current
        return policy(deviceVersion: device.version, model: device.productType)
    }

    private var lastAttempt: Date?

    func refresh(force: Bool = true) async {
        guard enabled, !checking, force || lastAttempt.map({ Date().timeIntervalSince($0) >= 3600 }) ?? true else { return }
        lastAttempt = Date()
        checking = true
        defer { checking = false }
        do {
            let data = try await RemoteMetadata.fetch(Self.rulesURL, session: session)
            let parsed = try HotLoadRules.parse(data)
            guard enabled, !Task.isCancelled else { return }
            try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: cacheURL, options: .atomic)
            rules = parsed
            checkedAt = Date()
            error = nil
        } catch is CancellationError { } catch {
            guard !Task.isCancelled else { return }
            self.error = "Could not refresh HotLoad. Keeping cached rules. \(error.localizedDescription)"
        }
    }

    static func requireAllowed(features: Set<String> = []) async throws {
        let identity = await DeviceIdentity.read()
        let policy = await MainActor.run {
            let cached = DeviceIdentityMonitor.shared.current
            return shared.policy(deviceVersion: identity.version.isEmpty ? cached.version : identity.version,
                                 model: identity.productType.isEmpty ? cached.productType : identity.productType)
        }
        try policy.requireAllowed(features: features)
    }
}

/// One coalesced check per foreground session, plus an explicit Settings check.
/// Failure retains the last release and its original check time and is shown as
/// a failure, never as "up to date". No release (404) is a separate state.
@MainActor
final class AppUpdateService: ObservableObject {
    static let shared = AppUpdateService()
    @Published private(set) var release: AppRelease?
    @Published private(set) var noReleases = false
    @Published private(set) var checking = false
    @Published private(set) var checkedAt: Date?
    @Published private(set) var error: String?
    private var lastAttempt: Date?
    private let session: URLSession
    private let installedVersion: String

    init(session: URLSession = .shared, installedVersion: String = HotLoadService.appVersion) {
        self.session = session
        self.installedVersion = installedVersion
    }

    var available: AppRelease? { release.flatMap { $0.isNewer(than: installedVersion) ? $0 : nil } }
    var releaseURL: URL { release?.pageURL ?? AppRelease.latestURL }

    func refresh(force: Bool = false) async {
        guard !checking, force || lastAttempt.map({ Date().timeIntervalSince($0) >= 3600 }) ?? true else { return }
        checking = true
        lastAttempt = Date()
        defer { checking = false }
        do {
            let data = try await RemoteMetadata.fetch(AppRelease.apiURL, session: session)
            let parsed = try AppRelease.parse(data)
            guard !Task.isCancelled else { return }
            release = parsed
            noReleases = false
            checkedAt = Date()
            error = nil
        } catch RemoteMetadataError.httpStatus(404) {
            release = nil
            noReleases = true
            checkedAt = Date()
            error = nil
        } catch is CancellationError { } catch {
            guard !Task.isCancelled else { return }
            self.error = "Could not check for updates. \(error.localizedDescription)"
        }
    }
}
