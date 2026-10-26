import Foundation

/// Production services run against an in-process HTTP stub. No GitHub request,
/// device connection, persistent preference or real app cache is used here.
struct GoldenNuggetError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct DeviceIdentity {
    var version = ""
    var productType = ""
    static func read() async -> DeviceIdentity { DeviceIdentity() }
}
@MainActor final class DeviceIdentityMonitor {
    static let shared = DeviceIdentityMonitor()
    var current = DeviceIdentity()
}

final class MetadataProtocol: URLProtocol {
    static var status = 200
    static var body = Data()
    static var failure = false
    static var requests = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests += 1
        if Self.failure {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": "\(Self.body.count)"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main struct HotLoadCheck {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ condition: Bool, _ name: String) {
            precondition(condition, name)
            checks += 1
            print("PASS: \(name)")
        }
        func document(_ rules: String) throws -> HotLoadRules {
            try HotLoadRules.parse(Data("{\"version\":1,\"rules\":[\(rules)]}".utf8))
        }
        func policy(_ rules: String, ios: String = "27.0", model: String = "iPhone17,1", app: String = "9.7.0") throws -> HotLoadPolicy {
            try document(rules).policy(appVersion: app, deviceVersion: ios, model: model)
        }
        let flag = #"{"tweak":"HideDICompletely","reason":"Reported failure","app_versions":["9.7"],"min_version":"27","max_version":"27.1","only_models":["iPhone17"]}"#
        check(try policy(flag).flaggedTweaks["HideDICompletely"] == "Reported failure", "desktop padded exact version and device prefix match")
        check(try policy(flag, app: "9.7.1").flaggedTweaks.isEmpty, "fixed app excluded")
        check(try policy(flag, ios: "26.5").flaggedTweaks.isEmpty, "lower iOS excluded")
        check(try policy(flag, ios: "27.2").flaggedTweaks.isEmpty, "upper iOS excluded")
        check(try policy(flag, ios: "").flaggedTweaks.isEmpty, "unknown iOS never matches scoped rule")
        check(try policy(flag, model: "").flaggedTweaks.isEmpty, "unknown model never matches prefix")
        check(try policy(#"{"tweak":"X","disabled":false}"#).flaggedTweaks.isEmpty, "disabled false is inert")
        check(try policy(#"{"tweak":"X","disabled":true}"#).flaggedTweaks["X"] != nil, "disabled true means active as on desktop")
        check(try policy(#"{"tweak":"X","action":"future"}"#).flaggedTweaks.isEmpty, "unknown action does not become a tweak flag")
        let range = #"{"action":"badNews","min_app_version":"9.6","max_app_version":"9.7.1","version":"9.7.2","reason":"Update required"}"#
        let required = try policy(range)
        check(required.requiredUpdateReason == "Update required" && required.requiredVersion == "9.7.2", "mandatory update retains reason and release label")
        check(try policy(range, app: "9.7.2").gateReason == nil, "updated build unblocked")
        do { try required.requireAllowed(); preconditionFailure("required update bypass") } catch { checks += 1 }
        check(try policy(#"{"action":"kill_app","reason":"Blocked"}"#).blockingReason == "Blocked", "kill rule blocks without crashing")
        check(HotLoadRules.empty.policy(appVersion: "9.7", deviceVersion: "26.6.1", model: "iPhone17,1").hiddenFeatures["Daemons"] != nil, "desktop built-in daemon safety rule works offline")
        check(HotLoadRules.empty.policy(appVersion: "9.7", deviceVersion: "26.6.1", model: "iPhone17,1", enabled: false).hiddenFeatures.isEmpty, "master switch disables all rules")
        let hidden = try policy(#"{"action":"hide_feature","feature":"Springboard","reason":"Broken"}"#)
        check(hidden.hiddenTweakIDs.contains("HideDICompletely"), "hidden feature resolves registry IDs")
        let compiled = TweakCompiler.compile(selection: TweakSelection(), deviceVersion: "27", isIPhone: true, deviceModel: "iPhone17,1", hiddenTweakIDs: hidden.hiddenTweakIDs)
        check(!compiled.payloads.contains { $0.relativePath.hasSuffix("com.apple.springboard.plist") }, "hidden reversible preferences do not emit off writes")
        let preset = try GoldenNuggetPreset.parse(Data(#"{"tweaks":{"HideDICompletely":{"enabled":true,"value":true}}}"#.utf8))
        var imported = TweakSelection()
        let report = GoldenNuggetPresetImport.apply(preset, to: &imported, deviceVersion: "27", isIPhone: true, deviceModel: "iPhone17,1", hiddenTweakIDs: hidden.hiddenTweakIDs)
        check(!imported.enabled.contains("HideDICompletely") && report.skippedIncompatible.contains("HideDICompletely"), "hidden tweaks refused by preset import")
        let dependent = TweakCatalog.all.first { !$0.requires.isEmpty }!
        let prerequisite = TweakCatalog.byID[dependent.requires.first!]!
        let dependencyPolicy = try policy("{\"action\":\"hide_feature\",\"feature\":\"\(HotLoadPolicy.feature(for: prerequisite))\"}")
        check(dependencyPolicy.hiddenTweakIDs.contains(dependent.id), "hidden prerequisites also hide dependent controls")
        let featureFlag = try policy(#"{"tweak":"PosterBoard","reason":"Unsafe wallpaper"}"#)
        check(featureFlag.warnings(forFeatures: ["PosterBoard"]).contains { $0.contains("Unsafe wallpaper") }, "non-registry feature flags reach apply confirmation")
        let forced = try policy(#"{"action":"disable_daemon","daemons":["OTA","not.a.catalog.label"],"reason":"Safety"}"#)
        check(Set(forced.forcedDaemons.keys) == Set(DaemonGroups.byName["OTA"]!.labels), "forced daemon groups resolve only allowlisted labels")
        check(forced.warnings(for: TweakSelection()).contains { $0.contains("forces") && $0.contains("Safety") }, "forced-only apply includes reason in confirmation")
        let forcedCompile = TweakCompiler.compile(selection: TweakSelection(), deviceVersion: "27", isIPhone: true, forcedDaemonKeys: Set(forced.forcedDaemons.keys))
        let disabled = forcedCompile.payloads.first { $0.relativePath.hasSuffix("disabled.plist") }!
        let plist = try PropertyListSerialization.propertyList(from: disabled.contents, format: nil) as! [String: Any]
        check(forced.forcedDaemons.keys.allSatisfy { plist[$0] as? Bool == true }, "forced labels apply with master off")
        var falseSelection = TweakSelection()
        let ota = TweakCatalog.byID["Daemon.OTA"]!
        falseSelection.restore(enabled: true, value: nil, multiValues: Dictionary(uniqueKeysWithValues: DaemonGroups.byName["OTA"]!.labels.map { ($0, TweakValue.bool(false)) }), for: ota)
        let forcedOverride = TweakCompiler.compile(selection: falseSelection, deviceVersion: "27", isIPhone: true, forcedDaemonKeys: Set(forced.forcedDaemons.keys)).payloads.first { $0.relativePath.hasSuffix("disabled.plist") }!
        let forcedPlist = try PropertyListSerialization.propertyList(from: forcedOverride.contents, format: nil) as! [String: Any]
        check(forced.forcedDaemons.keys.allSatisfy { forcedPlist[$0] as? Bool == true }, "forced daemon labels override imported false values")
        let daemonHidden = try policy(#"{"action":"hide_feature","feature":"Daemons"},{"action":"disable_daemon","daemons":["OTA"]}"#)
        check(!TweakCompiler.compile(selection: TweakSelection(), deviceVersion: "27", isIPhone: true, hiddenTweakIDs: daemonHidden.hiddenTweakIDs, forcedDaemonKeys: Set(daemonHidden.forcedDaemons.keys)).payloads.contains { $0.relativePath.hasSuffix("disabled.plist") }, "hidden feature wins over forced daemon writes")
        do { try daemonHidden.validateCommunity([disabled]); preconditionFailure("community bypass") } catch { checks += 1 }
        var selected = TweakSelection()
        selected.setOn(true, for: TweakCatalog.byID["HideDICompletely"]!)
        check(try policy(flag).warnings(for: selected).count == 1, "preset-selected flagged tweak reaches apply warning")
        let risk = try policy(#"{"action":"risk","tweak":"HideDICompletely","level":"high","reason":"Loop"}"#)
        check(risk.flaggedTweaks.isEmpty && risk.warnings(for: selected).contains { $0.contains("high: Loop") }, "risk rules warn without blocking")
        for invalid in [#"{"rules":[]}"#, #"{"version":1,"rules":[{"disabled":1}]}"#, #"{"version":1,"rules":{}}"#] {
            do { _ = try HotLoadRules.parse(Data(invalid.utf8)); preconditionFailure("malformed rules accepted") } catch { checks += 1 }
        }
        check(AppReleaseVersion("v9.7.1")! > AppReleaseVersion("9.7.0")!, "mobile release tags compare numerically")
        check(AppReleaseVersion("9.7")! == AppReleaseVersion("9.7.0")!, "zero padding does not create update")
        check(AppReleaseVersion("9.7.1-beta.2")! < AppReleaseVersion("9.7.1")!, "stable supersedes prerelease")
        check(AppReleaseVersion("9.7.1-beta.10")! > AppReleaseVersion("9.7.1-beta.2")!, "numeric prerelease identifiers compare numerically")
        check(AppReleaseVersion("garbage") == nil && AppReleaseVersion("9..7") == nil, "invalid release versions rejected")
        let releaseData = Data(#"{"tag_name":"9.7.1","html_url":"https://github.com/GoldenNugget-Team/GoldenNugget-mobile/releases/tag/9.7.1","body":"Notes","draft":false,"prerelease":false,"assets":[{"name":"app.ipa","browser_download_url":"https://github.com/GoldenNugget-Team/GoldenNugget-mobile/releases/download/9.7.1/app.ipa"}]}"#.utf8)
        let release = try AppRelease.parse(releaseData)
        check(release.isNewer(than: "9.7.0") && !release.isNewer(than: "9.7.1"), "update detection compares installed mobile version")
        check(release.downloadURL?.path.hasSuffix("app.ipa") == true, "official IPA selected")
        let malicious = Data(String(data: releaseData, encoding: .utf8)!.replacingOccurrences(of: "https://github.com/", with: "https://example.com/").utf8)
        do { _ = try AppRelease.parse(malicious); preconditionFailure("untrusted release") } catch { checks += 1 }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "HotLoadTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MetadataProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let cache = root.appendingPathComponent("rules.json")
        let cachedData = Data(#"{"version":7,"rules":[{"action":"badNews","max_app_version":"9.7.1","reason":"Cached required update"}]}"#.utf8)
        try cachedData.write(to: cache)
        let service = HotLoadService(defaults: defaults, cacheURL: cache, session: session)
        check(service.rules.version == 7, "cached rules available synchronously before network")
        check(service.policy(deviceVersion: "27", model: "iPhone17,1").requiredUpdateReason == "Cached required update", "cached mandatory update gates before first network response")
        MetadataProtocol.failure = true
        await service.refresh()
        check(service.rules.version == 7 && service.error != nil, "offline failure preserves rules and reports failure")
        check(try Data(contentsOf: cache) == cachedData, "offline failure preserves cache bytes")
        service.enabled = false
        let count = MetadataProtocol.requests
        await service.refresh()
        check(MetadataProtocol.requests == count, "disabled HotLoad makes no request")
        check(service.policy(deviceVersion: "27", model: "iPhone17,1").gateReason == nil, "disabled cached mandatory rule does not gate")
        service.enabled = true
        MetadataProtocol.failure = false
        MetadataProtocol.body = Data("bad json".utf8)
        await service.refresh()
        check(try service.rules.version == 7 && Data(contentsOf: cache) == cachedData, "malformed response cannot erase cache")
        MetadataProtocol.body = Data(#"{"version":8,"rules":[]}"#.utf8)
        await service.refresh()
        check(service.rules.version == 8 && service.error == nil, "valid refresh publishes new rules")
        check(try HotLoadRules.parse(Data(contentsOf: cache)).version == 8, "valid refresh persists atomically")
        let reloaded = HotLoadService(defaults: defaults, cacheURL: cache, session: session)
        check(reloaded.rules.version == 8, "new session restores updated cache")
        let requestsBeforeThrottle = MetadataProtocol.requests
        await service.refresh(force: false)
        check(MetadataProtocol.requests == requestsBeforeThrottle, "automatic HotLoad refreshes are throttled")
        MetadataProtocol.body = Data(repeating: 32, count: 2 * 1024 * 1024 + 1)
        await service.refresh()
        check(service.rules.version == 8 && service.error != nil, "oversized metadata rejected without cache loss")
        let updates = AppUpdateService(session: session, installedVersion: "9.7.0")
        MetadataProtocol.body = releaseData
        await updates.refresh(force: true)
        check(updates.available?.tag_name == "9.7.1", "release service publishes available mobile update")
        let requestsBeforeCoalesce = MetadataProtocol.requests
        async let first: Void = updates.refresh(force: true)
        async let second: Void = updates.refresh(force: true)
        _ = await (first, second)
        check(MetadataProtocol.requests == requestsBeforeCoalesce + 1, "concurrent update checks coalesce")
        let checked = updates.checkedAt
        MetadataProtocol.failure = true
        await updates.refresh(force: true)
        check(updates.available != nil && updates.error != nil && updates.checkedAt == checked, "failed update request preserves prior result and check date")
        MetadataProtocol.failure = false
        MetadataProtocol.status = 404
        await updates.refresh(force: true)
        check(updates.noReleases && updates.available == nil && updates.error == nil, "no releases is distinct from network failure and up to date")
        MetadataProtocol.status = 200
        MetadataProtocol.body = releaseData
        let previous = MetadataProtocol.requests
        await updates.refresh()
        check(MetadataProtocol.requests == previous, "foreground checks are throttled")
        print("\(checks) HotLoad/update checks passed")
    }
}
