import Foundation

/// Desktop HotLoad wire format, scoped to the mobile release channel. This is
/// data only: rules cannot download or execute code. Cached and fresh rules use
/// the same matcher; missing device identity never matches device-scoped rules.
struct HotLoadRules: Codable {
    let version: Int
    let rules: [Rule]

    struct Rule: Codable {
        var action: String?
        var tweak: String?
        var feature: String?
        var reason: String?
        var level: String?
        var version: String?
        var disabled: Bool?
        var app_versions: [String]?
        var min_app_version: String?
        var max_app_version: String?
        var min_version: String?
        var max_version: String?
        var only_models: [String]?
        var daemons: [String]?

        func matches(appVersion: String, deviceVersion: String, model: String) -> Bool {
            guard disabled != false else { return false }
            if let exact = app_versions, !exact.isEmpty {
                guard exact.contains(where: { TweakVersion.compare(appVersion, $0) == 0 }) else { return false }
            } else if !Self.inRange(appVersion, min_app_version, max_app_version) { return false }
            guard Self.inRange(deviceVersion, min_version, max_version) else { return false }
            if let prefixes = only_models, !prefixes.isEmpty {
                guard !model.isEmpty, prefixes.contains(where: { model.hasPrefix($0) }) else { return false }
            }
            return true
        }

        private static func inRange(_ value: String, _ minimum: String?, _ maximum: String?) -> Bool {
            if let minimum {
                guard let order = TweakVersion.compare(value, minimum), order >= 0 else { return false }
            }
            if let maximum {
                guard let order = TweakVersion.compare(value, maximum), order <= 0 else { return false }
            }
            return true
        }

        var explanation: String { reason.flatMap { $0.isEmpty ? nil : $0 } ?? "This feature is currently flagged as dangerous or broken." }
    }

    static let empty = HotLoadRules(version: 0, rules: [])

    static func parse(_ data: Data) throws -> HotLoadRules {
        let result = try JSONDecoder().decode(Self.self, from: data)
        guard result.version >= 0, result.rules.count <= 4096 else {
            throw CocoaError(.coderReadCorrupt)
        }
        return result
    }

    func policy(appVersion: String, deviceVersion: String, model: String, enabled: Bool = true) -> HotLoadPolicy {
        guard enabled else { return HotLoadPolicy() }
        var policy = HotLoadPolicy()
        // Desktop's built-in safety rule also applies before the first fetch.
        if TweakVersion.compare(deviceVersion, "26.6.1") == 0 {
            policy.hiddenFeatures["Daemons"] = "Daemon changes are blocked on iOS 26.6.1 because a reported configuration caused the device to freeze at the passcode screen."
        }
        for rule in rules where rule.matches(appVersion: appVersion, deviceVersion: deviceVersion, model: model) {
            switch rule.action ?? "" {
            case "kill_app":
                if policy.blockingReason == nil { policy.blockingReason = rule.explanation }
            case "badNews":
                if policy.requiredUpdateReason == nil {
                    policy.requiredUpdateReason = rule.explanation
                    policy.requiredVersion = rule.version
                }
            case "hide_feature":
                if let feature = rule.feature, HotLoadPolicy.features.contains(feature), policy.hiddenFeatures[feature] == nil {
                    policy.hiddenFeatures[feature] = rule.explanation
                }
            case "disable_daemon":
                for rawName in rule.daemons ?? [] {
                    let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
                    let labels = DaemonGroups.byName[name]?.labels ?? (DaemonGroups.allowedKeys.contains(name) ? [name] : [])
                    for label in labels where DaemonGroups.allowedKeys.contains(label) && policy.forcedDaemons[label] == nil {
                        policy.forcedDaemons[label] = rule.explanation
                    }
                }
            case "risk":
                if let tweak = rule.tweak {
                    policy.risks.append((tweak, "\(rule.level ?? "medium"): \(rule.explanation)"))
                }
            case "", "flag":
                if let tweak = rule.tweak, policy.flaggedTweaks[tweak] == nil {
                    policy.flaggedTweaks[tweak] = rule.explanation
                }
            default: break // Future actions must never turn into accidental tweak flags.
            }
        }
        return policy
    }
}

/// Immutable policy captured before preview/apply. Hidden tweaks are excluded
/// from compilation even when a preset selected them before a rules refresh.
struct HotLoadPolicy {
    static let features: Set<String> = ["Liquid Glass", "Springboard", "Internal", "PosterBoard", "Daemons", "Status Bar", "Templates"]
    var hiddenFeatures: [String: String] = [:]
    var flaggedTweaks: [String: String] = [:]
    var forcedDaemons: [String: String] = [:]
    var risks: [(tweak: String, message: String)] = []
    var blockingReason: String?
    var requiredUpdateReason: String?
    var requiredVersion: String?

    var forcedDaemonKeys: Set<String> { hiddenFeatures["Daemons"] == nil ? Set(forcedDaemons.keys) : [] }

    var gateReason: String? { blockingReason ?? requiredUpdateReason }

    static func feature(for spec: TweakSpec) -> String {
        switch spec.section {
        case .liquidGlass: return "Liquid Glass"
        case .springboard: return "Springboard"
        case .internalOptions: return "Internal"
        case .daemons: return "Daemons"
        }
    }

    var hiddenTweakIDs: Set<String> {
        var ids = Set(TweakCatalog.allWithDaemons.filter { hiddenFeatures[Self.feature(for: $0)] != nil }.map(\.id))
        for feature in hiddenFeatures.keys {
            switch feature {
            case "Daemons": ids.formUnion(["Daemons", "ClearScreenTimeAgentPlist"])
            case "PosterBoard": ids.insert("PosterBoard")
            case "Status Bar": ids.insert("StatusBar")
            case "Templates": ids.insert("Templates")
            default: break
            }
        }
        // A dependent control must not survive when its prerequisite is hidden.
        var previous: Set<String>
        repeat {
            previous = ids
            for spec in TweakCatalog.allWithDaemons where !Set(spec.requires).isDisjoint(with: ids) { ids.insert(spec.id) }
        } while ids != previous
        return ids
    }

    func flag(for spec: TweakSpec) -> String? {
        flaggedTweaks[spec.id] ?? (spec.section == .daemons ? flaggedTweaks["Daemons"] : nil)
    }

    func warnings(for selection: TweakSelection) -> [String] {
        var lines = Set<String>()
        for spec in TweakCatalog.allWithDaemons where selection.isOn(spec) {
            if let reason = flag(for: spec) { lines.insert("HotLoad — \(spec.title): \(reason)") }
        }
        for risk in risks where selection.enabled.contains(risk.tweak) || (risk.tweak == "Daemons" && selection.daemonModificationsEnabled) {
            lines.insert("HotLoad — \(risk.tweak): \(risk.message)")
        }
        if !forcedDaemonKeys.isEmpty {
            let reasons = Set(forcedDaemonKeys.compactMap { forcedDaemons[$0] }).sorted().joined(separator: " ")
            lines.insert("HotLoad — forces \(forcedDaemonKeys.count) daemon label(s) disabled: \(reasons)")
        }
        return lines.sorted()
    }

    func warnings(forFeatures features: Set<String>) -> [String] {
        let names = features.map { $0 == "Status Bar" ? "StatusBar" : $0 }
        var lines = names.compactMap { name in flaggedTweaks[name].map { "HotLoad — \(name): \($0)" } }
        lines += risks.filter { names.contains($0.tweak) }.map { "HotLoad — \($0.tweak): \($0.message)" }
        return lines.sorted()
    }

    func validateCommunity(_ payloads: [TweakPayload]) throws {
        let hidden = hiddenTweakIDs
        let hiddenLocations = Set(TweakCatalog.allWithDaemons.filter { hidden.contains($0.id) }.map { $0.location.rawValue })
        let blockedDestinations = Set(hiddenLocations.compactMap { TweakDomainMap.split(path: $0) }.map { "\($0.domain)/\(TweakPayload.manifestPath($0.relativePath))" })
        if payloads.contains(where: { blockedDestinations.contains($0.label) }) {
            throw HotLoadBlocked(reason: "A community write targets a feature hidden by safety rules.")
        }
    }

    func requireAllowed(features: Set<String> = []) throws {
        if let reason = gateReason { throw HotLoadBlocked(reason: reason) }
        for feature in features.sorted() {
            if let reason = hiddenFeatures[feature] { throw HotLoadBlocked(reason: "\(feature): \(reason)") }
        }
    }
}

struct HotLoadBlocked: LocalizedError {
    let reason: String
    var errorDescription: String? { "HotLoad: \(reason)" }
}
