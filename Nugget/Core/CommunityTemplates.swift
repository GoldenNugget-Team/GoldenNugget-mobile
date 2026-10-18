import Foundation
import SwiftUI
import ZIPFoundation

/// Format-3 .batter community switches, matching community_tweaks.py.
/// Archive members are read in memory with explicit expansion limits; paths
/// are never extracted or used as host filesystem destinations.
struct CommunityTemplate: Identifiable {
    struct Write {
        let kind: String
        let path: String
        let values: [String: Any]
        let data: Data
        let owner: Int
    }
    struct Control {
        let kind: String
        let minimum: Double
        let maximum: Double
        let step: Double
        let integral: Bool
        let maxLength: Int
        let choices: [(String, Any)]
        let initial: Any
        func clamp(_ value: Any) -> Any {
            switch kind {
            case "slider":
                guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                      number.doubleValue.isFinite else { return initial }
                let n = min(maximum, max(minimum, number.doubleValue))
                return integral ? NSNumber(value: Int(n)) : NSNumber(value: n)
            case "text": return String(((value as? String) ?? (initial as? String ?? "")).prefix(maxLength))
            default:
                return choices.contains { NSDictionary(dictionary: ["v": $0.1]).isEqual(to: ["v": value]) } ? value : initial
            }
        }
    }
    struct Tweak: Identifiable {
        let id: String
        let label: String
        let detail: String
        let minimum: String
        let maximum: String
        let control: Control?
        let writes: [Write]
        let writesOff: [Write]
        var enabled: Bool
        var value: Any
        func supports(_ version: String) -> Bool {
            (minimum.isEmpty || TweakVersion.compare(version, minimum) != -1)
                && (maximum.isEmpty || TweakVersion.compare(version, maximum) != 1)
        }
    }
    let id: String
    let title: String
    let author: String
    let detail: String
    let minimum: String
    let maximum: String
    let url: URL
    var tweaks: [Tweak]
    var active = true

    static func relativePath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.contains("\\") && !path.contains("\0")
            && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
    static func destination(_ path: String) throws -> TweakDomainMap.Destination {
        let blocked = ["/var/root/Library/Lockdown/", "/var/mobile/Library/Preferences/com.apple.purplebuddy.plist",
                       "/var/Managed Preferences/mobile/com.apple.purplebuddy.plist", "/var/mobile/Library/Backup/"]
        guard path.hasPrefix("/var/"), relativePath(String(path.dropFirst())),
              !blocked.contains(where: path.hasPrefix), let target = TweakDomainMap.split(path: path),
              !target.relativePath.isEmpty else { throw CommunityError("Protected or unsupported template path: \(path)") }
        return target
    }
    static func validateValue(_ value: Any, depth: Int = 0) throws {
        guard depth <= 16 else { throw CommunityError("Template values are nested too deeply.") }
        if let dict = value as? [String: Any] {
            for value in dict.values { try validateValue(value, depth: depth + 1) }
        } else if let array = value as? [Any] {
            for value in array { try validateValue(value, depth: depth + 1) }
        } else if let number = value as? NSNumber {
            guard number.doubleValue.isFinite else { throw CommunityError("Nonfinite template value.") }
        } else if !(value is String) { throw CommunityError("Invalid template plist value.") }
    }
    static func load(_ url: URL, id: String? = nil) throws -> CommunityTemplate {
        let archive = try Archive(url: url, accessMode: .read)
        var entries: [String: Entry] = [:]
        var total: UInt64 = 0
        for entry in archive {
            let path = entry.path.hasSuffix("/") ? String(entry.path.dropLast()) : entry.path
            guard relativePath(path), entry.type != .symlink, entries[entry.path] == nil,
                  entries.count < 4096 else { throw CommunityError("Unsafe template archive.") }
            total += UInt64(entry.uncompressedSize)
            guard total <= 64 * 1024 * 1024 else { throw CommunityError("Template expands beyond 64 MB.") }
            entries[entry.path] = entry
        }
        func read(_ path: String, limit: Int) throws -> Data {
            guard let entry = entries[path], entry.type == .file, entry.uncompressedSize <= limit else {
                throw CommunityError("Missing or oversized template resource: \(path)")
            }
            var data = Data()
            let checksum = try archive.extract(entry) { chunk in
                guard data.count + chunk.count <= limit else { throw CommunityError("Template resource is too large.") }
                data.append(chunk)
            }
            guard checksum == entry.checksum, data.count == Int(entry.uncompressedSize) else {
                throw CommunityError("Corrupt template resource: \(path)")
            }
            return data
        }
        let configs = entries.keys.filter { $0.lowercased().hasSuffix("config.json") && !$0.lowercased().contains("descriptor") && !$0.lowercased().contains("container") }
        guard configs.count == 1, let configPath = configs.first,
              let raw = try JSONSerialization.jsonObject(with: read(configPath, limit: 1024 * 1024)) as? [String: Any],
              String(describing: raw["format_version"] ?? "") == "3",
              let rows = raw["tweaks"] as? [[String: Any]], rows.count <= 64,
              (raw["options"] as? [Any] ?? []).isEmpty,
              !entries.keys.contains(where: { $0.split(separator: "/").contains("container") }) else {
            throw CommunityError("Open this package on the Templates page to edit wallpaper options. The Community Catalog library accepts format-3 community-tweak packages.")
        }
        let base = configPath.contains("/") ? String(configPath.prefix(through: configPath.lastIndex(of: "/")!)) : ""
        func text(_ raw: [String: Any], _ key: String, limit: Int, required: Bool = false) throws -> String {
            guard let string = (raw[key] ?? "") as? String, string.count <= limit,
                  !required || !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CommunityError("Invalid template text: \(key)")
            }
            return string
        }
        func version(_ row: [String: Any], _ key: String) throws -> String {
            let value = try text(row, key, limit: 8)
            guard value.isEmpty || CommunityCatalog.matches(value, "^[0-9]{1,2}(\\.[0-9]{1,2}){0,2}$") else {
                throw CommunityError("Invalid template iOS version.")
            }
            return value
        }
        var sourceBytes = 0
        func writes(_ raw: Any?) throws -> [Write] {
            guard let rows = (raw ?? []) as? [[String: Any]] else { throw CommunityError("Invalid template writes.") }
            return try rows.map { row in
                guard let kind = row["type"] as? String, ["plist", "file", "empty"].contains(kind),
                      let path = row["path"] as? String else { throw CommunityError("Unknown template write.") }
                _ = try destination(path)
                guard let owner = (row["owner"] ?? 501) as? NSNumber else { throw CommunityError("Invalid template file owner.") }
                guard CFGetTypeID(owner) != CFBooleanGetTypeID(), [0, 501].contains(owner.intValue),
                      owner.doubleValue == Double(owner.intValue) else { throw CommunityError("Invalid template file owner.") }
                var values: [String: Any] = [:], data = Data()
                if kind == "plist" {
                    guard let dict = row["values"] as? [String: Any], !dict.isEmpty else { throw CommunityError("Missing plist values.") }
                    try validateValue(dict); values = dict
                } else if kind == "file" {
                    guard let source = row["source"] as? String, relativePath(source) else { throw CommunityError("Unsafe source path.") }
                    data = try read(base + source, limit: 4 * 1024 * 1024)
                    sourceBytes += data.count
                    guard sourceBytes <= 16 * 1024 * 1024 else { throw CommunityError("Template source data exceeds 16 MB.") }
                } else if path.hasSuffix(".plist") {
                    data = try PropertyListSerialization.data(fromPropertyList: [:], format: .xml, options: 0)
                }
                return Write(kind: kind, path: path, values: values, data: data, owner: owner.intValue)
            }
        }
        var seen = Set<String>()
        let tweaks: [Tweak] = try rows.map { row in
            let id = try text(row, "id", limit: 64, required: true)
            guard CommunityCatalog.matches(id, "^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$"), seen.insert(id).inserted else {
                throw CommunityError("Duplicate or invalid template tweak ID.")
            }
            let on = try writes(row["writes"]), off = try writes(row["writes_off"])
            guard !(on + off).isEmpty, on.count + off.count <= 32 else { throw CommunityError("Invalid number of writes.") }
            var control: Control?
            if let value = row["control"], !(value is NSNull) {
                guard let c = value as? [String: Any], let kind = c["type"] as? String else { throw CommunityError("Invalid control.") }
                switch kind {
                case "slider":
                    func number(_ key: String, _ fallback: Double) throws -> NSNumber {
                        let fallbackNumber = fallback.rounded() == fallback ? NSNumber(value: Int(fallback)) : NSNumber(value: fallback)
                        guard let value = (c[key] ?? fallbackNumber) as? NSNumber,
                              CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite,
                              abs(value.doubleValue) < 1e15 else { throw CommunityError("Invalid slider value.") }
                        return value
                    }
                    let low = try number("min", 0), high = try number("max", 1), step = try number("step", 1)
                    guard low.doubleValue < high.doubleValue, step.doubleValue > 0 else { throw CommunityError("Invalid slider range.") }
                    let integral = [low, high, step].allSatisfy { !CFNumberIsFloatType(unsafeBitCast($0, to: CFNumber.self)) }
                    let initial = min(high.doubleValue, max(low.doubleValue, try number("default", low.doubleValue).doubleValue))
                    control = Control(kind: kind, minimum: low.doubleValue, maximum: high.doubleValue, step: step.doubleValue,
                                      integral: integral, maxLength: 0, choices: [], initial: integral ? NSNumber(value: Int(initial)) : NSNumber(value: initial))
                case "text":
                    guard let number = (c["max_length"] ?? 200) as? NSNumber,
                          CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue == Double(number.intValue) else { throw CommunityError("Invalid text length.") }
                    let maxLength = number.intValue
                    guard (1...1000).contains(maxLength), let initial = (c["default"] ?? "") as? String else { throw CommunityError("Invalid text control.") }
                    control = Control(kind: kind, minimum: 0, maximum: 0, step: 1, integral: false,
                                      maxLength: maxLength, choices: [], initial: String(initial.prefix(maxLength)))
                case "choice":
                    guard let choices = c["choices"] as? [[String: Any]], (1...50).contains(choices.count) else { throw CommunityError("Invalid choices.") }
                    let parsed = try choices.map { choice -> (String, Any) in
                        let label = try text(choice, "label", limit: 80, required: true)
                        guard let value = choice["value"] else { throw CommunityError("Missing choice value.") }
                        try validateValue(value); return (label, value)
                    }
                    guard let number = (c["default"] ?? 0) as? NSNumber,
                          CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue == Double(number.intValue) else { throw CommunityError("Invalid choice index.") }
                    let index = number.intValue
                    guard parsed.indices.contains(index) else { throw CommunityError("Invalid default choice.") }
                    control = Control(kind: kind, minimum: 0, maximum: 0, step: 1, integral: false,
                                      maxLength: 0, choices: parsed, initial: parsed[index].1)
                default: throw CommunityError("Unknown template control.")
                }
            }
            guard let flag = (row["default"] ?? false) as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID() else {
                throw CommunityError("A template switch default must be boolean.")
            }
            let enabled = flag.boolValue
            return Tweak(id: id, label: try text(row, "label", limit: 80, required: true),
                         detail: try text(row, "description", limit: 500), minimum: try version(row, "min_version"),
                         maximum: try version(row, "max_version"), control: control, writes: on, writesOff: off,
                         enabled: enabled, value: control?.initial ?? false)
        }
        return CommunityTemplate(id: id ?? url.deletingPathExtension().lastPathComponent,
                                 title: try text(raw, "title", limit: 200, required: true), author: try text(raw, "author", limit: 200),
                                 detail: try text(raw, "description", limit: 2000), minimum: try version(raw, "min_version"),
                                 maximum: try version(raw, "max_version"), url: url, tweaks: tweaks)
    }
}

/// One persistent library for catalog downloads and locally imported .batter files.
/// Selection changes persist locally; compile returns a snapshot for preview/apply.
@MainActor final class CommunityTemplateStore: ObservableObject {
    static let shared = CommunityTemplateStore()
    @Published private(set) var templates: [CommunityTemplate] = []
    @Published private(set) var loadErrors: [String] = []
    private let stateURL = CommunityCatalog.directory.appendingPathComponent("state.json")
    init() { reload() }
    func reload() {
        let state = (try? Data(contentsOf: stateURL)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: [String: [String: Any]]] } ?? [:]
        templates = []; loadErrors = []
        for url in (try? FileManager.default.contentsOfDirectory(at: CommunityCatalog.directory, includingPropertiesForKeys: nil)) ?? []
            where url.pathExtension == "batter" {
            do {
                var template = try CommunityTemplate.load(url)
                template.active = state[template.id]?["$active"]?["enabled"] as? Bool ?? true
                for index in template.tweaks.indices {
                    let old = state[template.id]?[template.tweaks[index].id] ?? [:]
                    if let enabled = old["enabled"] as? Bool { template.tweaks[index].enabled = enabled }
                    if let value = old["value"], let control = template.tweaks[index].control {
                        template.tweaks[index].value = control.clamp(value)
                    }
                }
                templates.append(template)
            } catch { loadErrors.append("\(url.lastPathComponent): \(error.localizedDescription)") }
        }
        templates.sort { $0.title.localizedCompare($1.title) == .orderedAscending }
    }
    func edit(template: String, tweak: String, enabled: Bool? = nil, value: Any? = nil) {
        guard let i = templates.firstIndex(where: { $0.id == template }),
              let j = templates[i].tweaks.firstIndex(where: { $0.id == tweak }) else { return }
        if let enabled { templates[i].tweaks[j].enabled = enabled }
        if let value, let control = templates[i].tweaks[j].control { templates[i].tweaks[j].value = control.clamp(value) }
        persist()
    }
    private func persist() {
        var state: [String: [String: [String: Any]]] = [:]
        for template in templates {
            state[template.id] = Dictionary(uniqueKeysWithValues: template.tweaks.map {
                ($0.id, ["enabled": $0.enabled, "value": $0.value])
            })
            state[template.id]?["$active"] = ["enabled": template.active]
        }
        do {
            try FileManager.default.createDirectory(at: CommunityCatalog.directory, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: state).write(to: stateURL, options: .atomic)
        } catch { loadErrors = [error.localizedDescription] }
    }
    func install(_ data: Data, id: String) throws {
        guard CommunityCatalog.matches(id, "^[a-z0-9][a-z0-9-]{1,47}$"), data.count <= 25 * 1024 * 1024 else {
            throw CommunityError("Invalid template identifier or size.")
        }
        try FileManager.default.createDirectory(at: CommunityCatalog.directory, withIntermediateDirectories: true)
        let temporary = CommunityCatalog.directory.appendingPathComponent(UUID().uuidString + ".part")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(to: temporary)
        _ = try CommunityTemplate.load(temporary, id: id)
        let target = CommunityCatalog.directory.appendingPathComponent(id + ".batter")
        try data.write(to: target, options: .atomic)
        reload()
    }
    func remove(_ template: CommunityTemplate) throws {
        try FileManager.default.removeItem(at: template.url)
        templates.removeAll { $0.id == template.id }; persist()
    }
    var presetEntry: [String: Any] {
        ["type": "TemplatesTweak", "enabled": templates.contains(where: \.active),
         "templates": templates.filter(\.active).map { $0.url.path },
         "tweak_states": templates.filter(\.active).map { template in
             Dictionary(uniqueKeysWithValues: template.tweaks.map { ($0.id, ["enabled": $0.enabled, "value": $0.value]) })
         }]
    }
    /// Explicit preset load is the activation boundary, separate from import.
    func loadPreset(_ preset: GoldenNuggetPreset) throws {
        guard let entry = preset.entries.first(where: { $0.id == "Templates" }) else { return }
        var loaded: [CommunityTemplate] = []
        if entry.enabled {
            for (index, path) in entry.templatePaths.enumerated() {
                let source = URL(fileURLWithPath: path).standardizedFileURL
                let root = CommunityCatalog.directory.standardizedFileURL.path + "/"
                guard source.path.hasPrefix(root), !source.path.contains("/../") else {
                    throw CommunityError("Template assets must be imported in a portable preset first.")
                }
                let bytes = try Data(contentsOf: source)
                let id = "preset-" + String(CommunityCatalog.hash(bytes).prefix(32))
                var template = try CommunityTemplate.load(source, id: id)
                if index < entry.templateStates.count {
                    for i in template.tweaks.indices {
                        let state = entry.templateStates[index][template.tweaks[i].id] ?? [:]
                        if let enabled = state["enabled"] as? Bool { template.tweaks[i].enabled = enabled }
                        if let value = state["value"], let control = template.tweaks[i].control { template.tweaks[i].value = control.clamp(value) }
                    }
                }
                let target = CommunityCatalog.directory.appendingPathComponent(id + ".batter")
                try bytes.write(to: target, options: .atomic)
                template = CommunityTemplate(id: id, title: template.title, author: template.author, detail: template.detail,
                                             minimum: template.minimum, maximum: template.maximum, url: target, tweaks: template.tweaks)
                loaded.append(template)
            }
        }
        // Keep installed packages in the library, but turn their switches off
        // when a loaded preset does not include them.
        let selected = Set(loaded.map(\.id))
        for i in templates.indices where !selected.contains(templates[i].id) {
            templates[i].active = false
        }
        for template in loaded {
            templates.removeAll { $0.id == template.id }; templates.append(template)
        }
        persist()
    }
    func setActive(_ active: Bool, template: String) {
        guard let index = templates.firstIndex(where: { $0.id == template }) else { return }
        templates[index].active = active; persist()
    }
    func saveSelection(in name: String) throws {
        try GoldenNuggetPresets.attachTemplates(presetEntry, to: name)
    }
    func compile(version: String) throws -> [TweakPayload] {
        var plists: [String: [String: Any]] = [:], files: [String: Data] = [:], owners: [String: Int] = [:]
        func replace(_ value: Any, with replacement: Any) -> Any {
            if let dict = value as? [String: Any] { return dict.mapValues { replace($0, with: replacement) } }
            if let list = value as? [Any] { return list.map { replace($0, with: replacement) } }
            if let text = value as? String, text == "$value" { return replacement }
            return value
        }
        for template in templates where template.active {
            if !template.minimum.isEmpty && TweakVersion.compare(version, template.minimum) == -1 { continue }
            if !template.maximum.isEmpty && TweakVersion.compare(version, template.maximum) == 1 { continue }
            for tweak in template.tweaks where tweak.supports(version) {
                for write in tweak.enabled ? tweak.writes : tweak.writesOff {
                    if write.kind == "plist" {
                        guard files[write.path] == nil else { throw CommunityError("Templates conflict at \(write.path).") }
                        let value = tweak.control?.clamp(tweak.value) ?? tweak.value
                        let values = write.values.mapValues { tweak.control == nil ? $0 : replace($0, with: value) }
                        plists[write.path, default: [:]].merge(values) { _, new in new }
                    } else {
                        guard plists[write.path] == nil, files[write.path] == nil || files[write.path] == write.data else {
                            throw CommunityError("Templates conflict at \(write.path).")
                        }
                        files[write.path] = write.data
                    }
                    owners[write.path] = write.owner
                }
            }
        }
        for (path, values) in plists { files[path] = try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0) }
        return try files.keys.sorted().map { path in
            let target = try CommunityTemplate.destination(path)
            return TweakPayload(domain: target.domain, relativePath: target.relativePath, contents: files[path]!, owner: owners[path])
        }
    }
}
