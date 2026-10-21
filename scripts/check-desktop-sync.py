#!/usr/bin/env python3
"""Compile shipping community/preset Swift and ZIPFoundation for macOS.

All persistent writes are redirected to a temporary Documents directory.
Fixtures cover desktop wire formats, controls, write precedence, archive/path
rejection, portable assets, and the device-scoped community reset record.
"""
import base64
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import zipfile
import zlib

ROOT = Path(__file__).resolve().parent.parent
SOURCES = ["TweakModel", "TweakCatalog", "TweakCatalogDaemons", "TweakDomainMap", "TweakCompiler",
           "GoldenNuggetPreset", "GoldenNuggetPresets", "GoldenNuggetAutosave", "PresetShareCode",
           "CommunityCatalog", "CommunityTemplates", "PortablePreset", "CommunityApplyRecord"]
SUPPORT = r'''
import Foundation
struct GoldenNuggetError: LocalizedError {
    let text: String
    init(_ text: String) { self.text = text }
    var errorDescription: String? { text }
}
struct DeviceIdentity {
    let version: String
    let productType: String
    var isIPhone: Bool { productType.hasPrefix("iPhone") }
}
extension URL {
    static var documents: URL { URL(fileURLWithPath: ProcessInfo.processInfo.environment["GN_TEST_ROOT"]!) }
}
@main struct Check {
    @MainActor static func main() throws {
        let root = URL.documents
        GoldenNuggetPresets.directoryOverride = root.appendingPathComponent("Presets", isDirectory: true)
        var checks = 0
        func check(_ test: Bool, _ name: String) {
            precondition(test, name); checks += 1; print("PASS: \(name)")
        }
        func rejects(_ name: String, _ body: () throws -> Void) {
            do { try body(); preconditionFailure(name) } catch { checks += 1; print("PASS: \(name)") }
        }
        func bytes(_ name: String) throws -> Data { try Data(contentsOf: root.appendingPathComponent(name)) }
        let code = try String(contentsOf: root.appendingPathComponent("desktop.code"), encoding: .utf8)
        let document = try PresetShareCode.decode(code)
        let entries = document["tweaks"] as! [String: [String: Any]]
        check(entries["HideDICompletely"]?["enabled"] as? Bool == true, "desktop GN1 code decodes")
        check(entries["LockScreenFootnote"]?["enabled"] as? Bool == false, "GN1 disables unspecified registry entries")
        let encoded = try PresetShareCode.encode(document, name: "Swift roundtrip")
        try encoded.write(to: root.appendingPathComponent("swift.code"), atomically: true, encoding: .utf8)
        let decoded = try PresetShareCode.decode(encoded)
        check((decoded["tweaks"] as? [String: [String: Any]])?["HideDICompletely"]?["enabled"] as? Bool == true, "GN1 Swift roundtrip")
        let dynamicIsland = TweakCatalog.byID["HideDICompletely"]!
        check(!dynamicIsland.isCompatible(deviceVersion: "27.0", isIPhone: true, deviceModel: "iPhone14,7"), "Dynamic Island tweak rejects an unsupported iPhone")
        check(dynamicIsland.isCompatible(deviceVersion: "iOS 27.0", isIPhone: true, deviceModel: "iPhone17,1"), "compatibility accepts desktop display-version strings")
        let reversed = TweakCompiler.compile(selection: TweakSelection(), deviceVersion: "27.0", isIPhone: true, deviceModel: "iPhone17,1")
        let reversePlist = try PropertyListSerialization.propertyList(from: reversed.payloads.first!.bytes(), options: [], format: nil) as! [String: Any]
        check(reversePlist["SBSuppressDynamicIslandCompletely"] as? Bool == false, "turning Dynamic Island tweak off writes false")
        var selection = TweakSelection()
        let daemon = TweakCatalog.byID["Daemon.OTA"]!
        selection.restore(enabled: true, value: nil, multiValues: daemon.multiValues?.mapValues { _ in .bool(true) }, for: daemon)
        let exported = GoldenNuggetPresets.document(for: selection, deviceModel: "iPhone17,1", iosVersion: "27.0", description: "", tags: [], createdAt: nil)
        let exportedTweaks = exported["tweaks"] as! [String: [String: Any]]
        check(exportedTweaks["Daemons"]?["enabled"] as? Bool == true && !exportedTweaks.keys.contains(where: { $0.hasPrefix("Daemon.") }), "daemon export uses desktop's single Daemons entry")
        let daemonCode = try PresetShareCode.encode(exported, name: "Daemons")
        let daemonDecoded = try PresetShareCode.decode(daemonCode)["tweaks"] as! [String: [String: Any]]
        check(daemonDecoded["Daemons"]?["enabled"] as? Bool == true, "daemon GN1 roundtrip retains unified entry")
        let disabled = try GoldenNuggetPreset.parse(JSONSerialization.data(withJSONObject: ["tweaks": ["Daemons": ["enabled": false, "value": [:]]]]))
        _ = GoldenNuggetPresetImport.apply(disabled, to: &selection, deviceVersion: "27.0", isIPhone: true, deviceModel: "iPhone17,1")
        check(!selection.isOn(daemon), "loading disabled daemon entry clears the previous selection")
        func daemonPlist(_ state: TweakSelection) throws -> [String: Any]? {
            let payloads = TweakCompiler.compile(selection: state, deviceVersion: "26.5", isIPhone: true).payloads
            guard let file = payloads.first(where: { $0.relativePath.contains("disabled.plist") }) else { return nil }
            return try PropertyListSerialization.propertyList(from: file.bytes(), options: [], format: nil) as? [String: Any]
        }
        var importedDaemons = TweakSelection()
        try importedDaemonsFromDocument(daemonDecoded, into: &importedDaemons)
        func importedDaemonsFromDocument(_ doc: [String: [String: Any]], into state: inout TweakSelection) throws {
            let preset = try GoldenNuggetPreset.parse(JSONSerialization.data(withJSONObject: ["tweaks": doc]))
            _ = GoldenNuggetPresetImport.apply(preset, to: &state, deviceVersion: "26.5", isIPhone: true)
        }
        let importedValues = try daemonPlist(importedDaemons)!
        check(DaemonGroups.byName["OTA"]!.labels.allSatisfy { importedValues[$0] as? Bool == true },
              "canonical daemon preset compiles true labels")
        importedDaemons.daemonModificationsEnabled = false
        importedDaemons.setOn(true, for: TweakCatalog.screenTimeSpec)
        importedDaemons.daemonModificationsEnabled = false
        check(try daemonPlist(importedDaemons) == nil, "master off excludes launchd payload")
        let gated = TweakCompiler.compile(selection: importedDaemons, deviceVersion: "26.5", isIPhone: true)
        check(!gated.payloads.contains(where: { $0.relativePath.contains("ScreenTimeAgent") }), "master off excludes Screen Time payload")
        let gatedDocument = GoldenNuggetPresets.document(for: importedDaemons, deviceModel: "iPhone", iosVersion: "26.5",
            description: "gated", tags: [], createdAt: nil)
        var restoredGate = TweakSelection()
        try importedDaemonsFromDocument(gatedDocument["tweaks"] as! [String: [String: Any]], into: &restoredGate)
        check(!restoredGate.daemonModificationsEnabled && restoredGate.isOn(daemon), "master gate and group choices survive preset roundtrip")
        importedDaemons.daemonModificationsEnabled = true
        importedDaemons.setOn(false, for: daemon); importedDaemons.removeValue(for: daemon)
        let resetValues = try daemonPlist(importedDaemons)!
        check(DaemonGroups.byName["OTA"]!.labels.allSatisfy { resetValues[$0] as? Bool == false },
              "last group off still writes explicit false labels")
        let forbidden = "com.apple.not-in-catalog"
        var hostile = TweakSelection()
        try importedDaemonsFromDocument(["Daemon.OTA": ["enabled": true, "value": [forbidden: true]]], into: &hostile)
        let hostileValues = try daemonPlist(hostile)
        check(hostile.multiValues(for: daemon)?[forbidden] == nil && hostileValues?[forbidden] == nil,
              "legacy preset cannot inject an unknown daemon")
        hostile.restore(enabled: true, value: nil, multiValues: [forbidden: .bool(true)], for: daemon)
        check((try daemonPlist(hostile))?[forbidden] == nil, "compiler rejects unknown labels even without the importer")
        rejects("GN1 expansion bomb rejected") { _ = try PresetShareCode.decode(String(contentsOf: root.appendingPathComponent("bomb.code"), encoding: .utf8)) }
        rejects("damaged GN1 rejected") { _ = try PresetShareCode.decode("GN1.not-valid") }
        let index = try CommunityCatalog.parse(bytes("index.json"))
        check(index.entries.count == 2 && index.rejected == 2, "catalog rejects duplicate IDs and invalid rows")
        let entry = index.entries.first { !$0.isTemplate }!
        check(entry.supports("27.9.1") && !entry.supports("28.0"), "catalog major-version upper bound covers minor releases")
        check(entry.matches("author Example"), "catalog search matches all words")
        if FileManager.default.fileExists(atPath: root.appendingPathComponent("live-index.json").path) {
            let live = try CommunityCatalog.parse(bytes("live-index.json"))
            check(!live.entries.isEmpty && live.rejected == 0, "live desktop catalog parses without rejected entries")
        }
        let template = try CommunityTemplate.load(root.appendingPathComponent("valid.batter"))
        check(template.tweaks.count == 3, "format-3 template loads all controls")
        check(template.tweaks[0].control?.clamp(100) as? Int == 10, "slider values clamp to integer bounds")
        check(template.tweaks[1].control?.clamp("abcdef") as? String == "abc", "text control length clamps")
        check(template.tweaks[2].control?.clamp("invalid") as? String == "B", "invalid choice falls back to configured index")
        for file in ["traversal.batter", "protected.batter", "duplicate.batter", "symlink.batter", "missing-source.batter", "legacy.batter", "boolean-default.batter", "bad-owner.batter", "corrupt.batter"] {
            rejects("reject \(file)") { _ = try CommunityTemplate.load(root.appendingPathComponent(file)) }
        }
        let store = CommunityTemplateStore()
        let fileTemplate = try CommunityTemplate.load(root.appendingPathComponent("files.batter"))
        check(fileTemplate.tweaks[0].writes[0].data == Data([0, 1, 2, 255]), "file write reads exact archive resource bytes")
        let empty = fileTemplate.tweaks[0].writes[1].data
        let emptyDict = try PropertyListSerialization.propertyList(from: empty, options: [], format: nil) as? [String: Any]
        check(!empty.isEmpty && emptyDict?.isEmpty == true, "empty plist write stays a valid plist")
        try store.install(bytes("valid.batter"), id: "test-package")
        let payloads = try store.compile(version: "27.0")
        let plist = try PropertyListSerialization.propertyList(from: payloads[0].bytes(), options: [], format: nil) as! [String: Any]
        check(plist["TestInteger"] as? Int == 3 && plist["OffState"] as? Bool == false, "enabled writes and writes_off compile together")
        check(payloads[0].owner == 0, "community root file owner is preserved")
        let builtIn = TweakPayload(domain: payloads[0].domain, relativePath: payloads[0].relativePath,
            contents: try PropertyListSerialization.data(fromPropertyList: ["TestInteger": 9], format: .xml, options: 0))
        let merged = try TweakCompiler.merging(community: payloads, builtIn: [builtIn])
        let mergedDict = try PropertyListSerialization.propertyList(from: merged[0].bytes(), options: [], format: nil) as! [String: Any]
        check(merged.count == 1 && mergedDict["TestInteger"] as? Int == 9 && mergedDict["OffState"] as? Bool == false,
              "built-in keys win while unrelated community keys survive")
        store.setActive(false, template: "test-package")
        check(try store.compile(version: "27.0").isEmpty, "inactive package does not emit writes_off")
        store.reload()
        check(store.templates.first?.active == false, "package activation persists")
        store.setActive(true, template: "test-package")
        let bundleURL = root.appendingPathComponent("roundtrip.gnpreset")
        let preset: [String: Any] = ["metadata": ["version": 2], "tweaks": ["Templates": store.presetEntry]]
        try PortablePreset.export(preset, to: bundleURL)
        let imported = try PortablePreset.decode(bundleURL)
        let templateEntry = (imported.document["tweaks"] as! [String: [String: Any]])["Templates"]!
        let paths = templateEntry["templates"] as! [String]
        check(paths.count == 1 && paths[0].hasPrefix(imported.owned.path), "portable assets get isolated owned paths")
        check(CommunityCatalog.hash(try Data(contentsOf: URL(fileURLWithPath: paths[0]))) == CommunityCatalog.hash(try bytes("valid.batter")), "portable asset bytes preserved")
        let parsed = try GoldenNuggetPreset.parse(JSONSerialization.data(withJSONObject: imported.document))
        try store.loadPreset(parsed)
        check(store.templates.filter(\.active).count == 1, "explicit preset load activates its templates only")
        rejects("portable checksum mismatch rejected") { _ = try PortablePreset.decode(root.appendingPathComponent("tampered.gnpreset")) }
        rejects("portable undeclared asset rejected") { _ = try PortablePreset.decode(root.appendingPathComponent("unlisted.gnpreset")) }
        try CommunityApplyRecord.record(payloads + [TweakPayload(domain: "HomeDomain", relativePath: "Library/test.bin", contents: Data([1]))], udid: "device-a")
        let plan = try CommunityApplyRecord.resetPlan("device-a")
        check(plan.payloads.count == 1 && plan.remaining.count == 1, "reset clears only managed preferences and reports other files")
        check(try CommunityApplyRecord.resetPlan("device-b").payloads.isEmpty, "community reset history is device-scoped")
        let cleared = try PropertyListSerialization.propertyList(from: plan.payloads[0].bytes(), options: [], format: nil) as! [String: Any]
        check(cleared.isEmpty && !plan.payloads[0].contents.isEmpty, "reset uses a valid empty plist")
        try CommunityApplyRecord.didReset("device-a")
        check(try CommunityApplyRecord.resetPlan("device-a").payloads.isEmpty, "successful reset clears only resettable history")
        print("\(checks) desktop-sync checks passed")
    }
}
'''


def code(payload):
    return "GN1." + base64.urlsafe_b64encode(zlib.compress(json.dumps(payload).encode())).decode().rstrip("=")


def fixtures(folder):
    share = code({"v": 1, "n": "Example", "t": {"HideDICompletely": {"enabled": True, "value": True}}})
    (folder / "desktop.code").write_text(share)
    (folder / "bomb.code").write_text(code({"v": 1, "t": {}, "n": "x" * 300000}))
    row = {"id": "test-preset", "name": "Example", "author": "author", "code": share, "ios_max": "27"}
    config = {"format_version": "3", "title": "Tests", "author": "Example", "tweaks": [
        {"id": "slider", "label": "Slider", "default": True,
         "control": {"type": "slider", "min": 0, "max": 10, "step": 1, "default": 3},
         "writes": [{"type": "plist", "path": "/var/Managed Preferences/mobile/com.example.test.plist", "owner": 0, "values": {"TestInteger": "$value"}}]},
        {"id": "text", "label": "Text", "control": {"type": "text", "max_length": 3},
         "writes_off": [{"type": "plist", "path": "/var/Managed Preferences/mobile/com.example.test.plist", "owner": 0, "values": {"OffState": False}}]},
        {"id": "choice", "label": "Choice", "control": {"type": "choice", "choices": [{"label": "A", "value": "A"}, {"label": "B", "value": "B"}], "default": 1},
         "writes": [{"type": "empty", "path": "/var/mobile/Library/Preferences/empty.plist"}]}]}

    def archive(name, config_data, extras=None):
        with zipfile.ZipFile(folder / name, "w", zipfile.ZIP_DEFLATED) as target:
            target.writestr("config.json", json.dumps(config_data))
            for path, data in (extras or {}).items():
                target.writestr(path, data)

    archive("valid.batter", config)
    with zipfile.ZipFile(folder / "corrupt.batter", "w", zipfile.ZIP_STORED) as target:
        target.writestr("config.json", json.dumps(config))
    corrupt = (folder / "corrupt.batter").read_bytes().replace(b'"title": "Tests"', b'"title": "Tosts"', 1)
    (folder / "corrupt.batter").write_bytes(corrupt)
    for name, field, value in [("boolean-default.batter", "default", 1), ("bad-owner.batter", "owner", "root")]:
        modified = json.loads(json.dumps(config))
        if field == "default":
            modified["tweaks"][0][field] = value
        else:
            modified["tweaks"][0]["writes"][0][field] = value
        archive(name, modified)
    files = {"format_version": "3", "title": "Files", "author": "Test", "tweaks": [
        {"id": "files", "label": "Files", "default": True, "writes": [
            {"type": "file", "path": "/var/mobile/Library/test.bin", "source": "resource.bin"},
            {"type": "empty", "path": "/var/mobile/Library/Preferences/test.plist"}]}]}
    archive("files.batter", files, {"resource.bin": bytes([0, 1, 2, 255])})
    archive("traversal.batter", config, {"../outside": "x"})
    protected = json.loads(json.dumps(config))
    protected["tweaks"][0]["writes"][0]["path"] = "/var/root/Library/Lockdown/pairing.plist"
    archive("protected.batter", protected)
    duplicate = json.loads(json.dumps(config))
    duplicate["tweaks"][1]["id"] = "slider"
    archive("duplicate.batter", duplicate)
    archive("legacy.batter", {"format_version": "2", "options": [], "domain": "AppDomain-com.apple.PosterBoard"})
    missing = json.loads(json.dumps(config))
    missing["tweaks"][0]["writes"] = [{"type": "file", "path": "/var/mobile/Library/test.bin", "source": "missing.bin"}]
    archive("missing-source.batter", missing)
    archive("symlink.batter", config)
    with zipfile.ZipFile(folder / "symlink.batter", "a") as target:
        info = zipfile.ZipInfo("link")
        info.create_system = 3
        info.external_attr = 0o120777 << 16
        target.writestr(info, "/tmp")
    data = (folder / "valid.batter").read_bytes()
    template = {"id": "test-template", "name": "Template", "author": "author", "size": len(data), "sha256": hashlib.sha256(data).hexdigest()}
    (folder / "index.json").write_text(json.dumps({"format": 1, "presets": [row, row, {"id": "../bad"}], "templates": [template]}))
    manifest = {"format": "GoldenNugget portable preset", "version": 1,
                "preset": {"tweaks": {"Templates": {"templates": ["bundle://assets/template.batter"]}}},
                "assets": {"assets/template.batter": {"size": len(data), "sha256": hashlib.sha256(data).hexdigest()}}}
    for name, tamper in [("tampered.gnpreset", True), ("unlisted.gnpreset", False)]:
        with zipfile.ZipFile(folder / name, "w") as archive_file:
            archive_file.writestr("manifest.json", json.dumps(manifest))
            archive_file.writestr("assets/template.batter", b"bad" if tamper else data)
            if not tamper:
                archive_file.writestr("unlisted", b"x")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--live-index", type=Path)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="goldennugget-desktop-sync-") as temporary:
        folder = Path(temporary)
        fixtures(folder)
        if args.live_index:
            (folder / "live-index.json").write_bytes(args.live_index.read_bytes())
        paths = []
        for name in SOURCES:
            path = folder / f"{name}.swift"
            path.write_text((ROOT / "Nugget/Core" / f"{name}.swift").read_text().replace("import ZIPFoundation", ""))
            paths.append(path)
        harness = folder / "Check.swift"
        harness.write_text(SUPPORT)
        binary = folder / "check"
        vendor = sorted((ROOT / "Vendor/ZIPFoundation/Sources").glob("*.swift"))
        subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-parse-as-library", *map(str, vendor + paths), str(harness), "-o", str(binary)], check=True)
        subprocess.run([str(binary)], env={**os.environ, "GN_TEST_ROOT": str(folder)}, check=True)
        wire = (folder / "swift.code").read_text()[4:]
        decoded = json.loads(zlib.decompress(base64.urlsafe_b64decode(wire + "=" * (-len(wire) % 4))))
        assert decoded["t"]["HideDICompletely"]["enabled"] is True
        print("PASS: Python decodes Swift GN1 output")


if __name__ == "__main__":
    main()
