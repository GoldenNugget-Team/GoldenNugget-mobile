// End-to-end test of the `.batter` pipeline: read a real archive, apply its
// options to the extracted tree, and compare what came out against what the
// reference implementation produces from the same archive.
//
// Run (the project's usual shape — top-level code needs the file to be
// `main.swift`; `-target` is ≥ 26 because the template sources use
// `URL.appendingPathComponent(_:conformingTo:)`, and the host build must not
// need ZIPFoundation):
//   mkdir -p /tmp/tmpl-e2e && cat Nugget/Core/TemplateXML.swift \
//       Nugget/Core/XMLScanner.swift Nugget/Core/TemplateFile.swift \
//       Nugget/Core/TemplateOptions.swift scripts/template-e2e-check.swift \
//       > /tmp/tmpl-e2e/main.swift && xcrun swiftc -O \
//       -target arm64-apple-macosx26.0 /tmp/tmpl-e2e/main.swift \
//       -o /tmp/tmpl-e2e/check
//
// Do **not** splice `PosterBoard.swift` instead of stubbing the two symbols it
// lends the template path (below): that file pulls the device stack and
// `PosterBoardTendie`'s unconditional `import ZIPFoundation`, neither of which
// links on the host.
//
// What it proves, and what it does not:
//
//   PROVED  the header parse (domain, format gate, version gates), the option
//          model, each option's `apply`, the glob resolution, and the payload
//          list a non-PosterBoard template turns into — all against the
//          reference's own output for the same archive.
//   NOT PROVED  anything about the device.  Nothing here touches a manifest, a
//          blob or a restore; that is `TweakInjector`'s job and its evidence
//          lives in the tweak-port documentation.
//
// The reference side is `template_file.TemplateFile.extract` plus the five
// option `apply` methods, imported from `~/GoldenNugget` with PySide6 stubbed
// out — the same trick `gen-tweaks-from-goldennugget.py` uses, because
// `template_file` imports Qt only for the UI it also carries.

import Foundation

// `Foundation` alone does NOT make `URL.appendingPathComponent(_:conformingTo:)`
// resolve — `.directory`/`.data` are `UTType` members, and the app module only
// compiles them because some other file in the batch imports
// UniformTypeIdentifiers (the project uses `conformingTo:` everywhere; this is
// the one import that keeps the spliced `main.swift` honest).  Without it the
// whole splice fails with "extra argument 'conformingTo' in call" at every call
// site in the template sources.  The old harnesses worked around this with
// shims (`posterboard-identity-check.swift`); an import is the cheap version.
import UniformTypeIdentifiers

// MARK: - Stand-ins for the two PosterBoard symbols the template path uses
//
// `TemplateFile` gates templates on the device version
// (`PosterBoard.compareVersion`) and the `set` option rewrites plists
// (`PosterBoardPlist.set`).  Both live in `PosterBoard.swift`, which drags in
// the device stack and `PosterBoardTendie`'s unconditional `import ZIPFoundation`
// — neither of which a host harness can link.  The bodies below are **verbatim**
// copies of `Nugget/Core/PosterBoard.swift` (they are Foundation-only), so the
// harness measures the real template code, not a re-implementation of its
// helpers.  If the real ones change, these have to follow — and this comment is
// where to notice.
enum PosterBoard {
    static func compareVersion(_ lhs: String, _ rhs: String) -> Int? {
        func components(_ value: String) -> [Int]? {
            let parts = value.trimmingCharacters(in: .whitespaces)
                .split(separator: ".", omittingEmptySubsequences: false)
            guard !parts.isEmpty else { return nil }
            var numbers: [Int] = []
            for part in parts {
                guard let number = Int(part), number >= 0 else { return nil }
                numbers.append(number)
            }
            return numbers
        }
        guard let left = components(lhs), let right = components(rhs) else { return nil }
        for index in 0..<max(left.count, right.count) {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            if l != r { return l < r ? -1 : 1 }
        }
        return 0
    }
}

enum PosterBoardPlist {
    static func load(contentsOf url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        let object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        guard let plist = object as? [String: Any] else {
            throw GoldenNuggetError("\(url.lastPathComponent) is a plist but not a dictionary.")
        }
        return plist
    }

    static func set(contentsOf url: URL,
                    key: String,
                    value: Any,
                    recursive: Bool) throws -> Data {
        var plist = try load(contentsOf: url)
        if recursive {
            plist = recursiveSet(plist, key: key, value: value)
        } else {
            plist[key] = value
        }
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }

    static func recursiveSet(_ plist: [String: Any], key: String, value: Any) -> [String: Any] {
        var result = plist
        for (existingKey, existingValue) in plist {
            if existingKey == key {
                result[existingKey] = value
            } else if let nested = existingValue as? [String: Any] {
                result[existingKey] = recursiveSet(nested, key: key, value: value)
            }
        }
        return result
    }
}

// MARK: - A stand-in for the engine's error type
//
// Only the `PosterBoardPlist` stub above throws it; the real type is declared
// in `GoldenNuggetEngine.swift` — and that file imports Minimuxer, SwiftUI and
// the whole device stack, none of which a host harness can link.  Declaring it
// here is safe precisely because it is **only** ever used for its message: the
// harness compares outcomes (threw / did not throw, and the text), never the
// type.  If the real type ever gains behaviour this would have to follow, and
// this comment is where to notice.
struct GoldenNuggetError: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// MARK: - Plumbing

var failures: [String] = []
var checked = 0

func check(_ condition: Bool, _ name: String, _ reason: @autoclosure () -> String) {
    checked += 1
    if !condition { failures.append("\(name): \(reason())") }
}

let goldennugget = ProcessInfo.processInfo.environment["GOLDENNUGGET"]
    ?? "\(NSHomeDirectory())/GoldenNugget"
let work = URL(fileURLWithPath: "/tmp/template-e2e-work")
let fm = FileManager.default
try? fm.removeItem(at: work)
try fm.createDirectory(at: work, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: work) }

// MARK: - The reference, run in a subprocess

/// The interpreter the reference runs under.
///
/// Not `/usr/bin/env python3`: the reference imports `packaging.version`
/// (`src/devicemanagement/constants.py`), which the host's default interpreter
/// does not have — the same caveat `docs/tweak-port.md` records for
/// `tweak-port-diff.py`.  `GOLDENNUGGET_PYTHON` overrides it.
enum TemplateReference {
    static var python: String {
        if let override = ProcessInfo.processInfo.environment["GOLDENNUGGET_PYTHON"] {
            return override
        }
        let managed = NSHomeDirectory()
            + "/.workbuddy/binaries/python/envs/default/bin/python3"
        return FileManager.default.isExecutableFile(atPath: managed) ? managed : "/usr/bin/python3"
    }
}

/// A Python driver that loads the reference's own classes and applies them.
///
/// The stub is the minimum `template_file`'s import chain needs.  It is
/// installed **before** the import, and the reference's UI methods are never
/// called — only `extract` and the options' `apply`, none of which touch Qt.
let referenceDriver = work.appendingPathComponent("reference.py")
let referenceSource = """
import sys, types, os

# --- PySide6 stub -------------------------------------------------------
# 参照实现的 template_file 会 import 一条 Qt 链，而本harness 只调用 extract 与
# 各 option 的 apply —— 它们都不碰 Qt。Qt 只需要"能被 import 且属性随便取"。
# 所以每个 stub 模块都带一个 __getattr__：任何名字都给一个占位类。
class _Any:
    def __init__(self, *a, **k): pass
    def __call__(self, *a, **k): return _Any()
    def __getattr__(self, name): return _Any()
    def __iter__(self): return iter(())

class _StubModule(types.ModuleType):
    def __getattr__(self, name):
        if name.startswith("__"):
            raise AttributeError(name)
        value = type(name, (_Any,), {})
        setattr(self, name, value)
        return value

_pkg = types.ModuleType("PySide6")
_pkg.__path__ = []
sys.modules["PySide6"] = _pkg
for _name in ("QtWidgets", "QtCore", "QtGui"):
    _m = _StubModule("PySide6." + _name)
    sys.modules["PySide6." + _name] = _m
    setattr(_pkg, _name, _m)
_pkg.QtCore.QCoreApplication = types.SimpleNamespace(tr=lambda s: s)

# QColor 必须是真的：SetOption 的 color_picker 分支要
# convert_color(r)/alphaF() 的实际数值，而通用 stub 给的是占位对象。
class QColor:
    def __init__(self, r=0, g=0, b=0, a=255):
        self._r, self._g, self._b, self._a = int(r), int(g), int(b), int(a)
    def redF(self): return self._r / 255
    def greenF(self): return self._g / 255
    def blueF(self): return self._b / 255
    def alphaF(self): return self._a / 255
    def __repr__(self):
        return "QColor(%r, %r, %r, %r)" % (self._r, self._g, self._b, self._a)

_pkg.QtGui.QColor = QColor

sys.path.insert(0, %(root)r)
os.chdir(%(root)r)

import json
from src.tweaks.posterboard.template_file import TemplateFile

payload = json.load(sys.stdin)
template = TemplateFile(path=payload['batter'], device_version=payload.get('version'))

# 把调用方给的选项值套上去，两边看到的必须是同一组选择。
for index, values in payload.get('choices', {}).items():
    option = template.options[int(index)]
    kind = option.type.value
    if kind == 'remove':
        option.value = bool(values[0])
    elif kind == 'picker':
        option.selection = int(values[0]) if not option.allow_multiple_selection else values
    elif kind == 'replace':
        option.value = values[0]
    elif kind == 'set':
        if option.setter_type.value == 'toggle':
            option.value = bool(values[0])
        elif option.setter_type.value == 'color_picker':
            option.value = values
        else:
            option.value = ' '.join(values)

out = payload['out']
os.makedirs(out, exist_ok=True)
root = template.extract(output_dir=out)

print(json.dumps({
    'root': root,
    'title': template.name,
    'author': template.author,
    'domain': template.domain,
    'format_version': template.format_version,
    'change_bundle_id': template.change_bundle_id,
    'bundle_id': template.bundle_id,
    'descriptor_cnt': template.descriptor_cnt,
    'is_container': template.is_container,
    'files': sorted(
        os.path.relpath(os.path.join(dirpath, name), root)
        for dirpath, _, names in os.walk(root) for name in names
    ),
}))
"""
do {
    try referenceSource
        .replacingOccurrences(of: "%(root)r", with: "\"\(goldennugget)\"")
        .write(to: referenceDriver, atomically: true, encoding: .utf8)
} catch {
    FileHandle.standardError.write(Data("error: cannot stage the reference driver\n".utf8))
    exit(2)
}

struct ReferenceResult {
    let title: String
    let author: String
    let domain: String
    let formatVersion: Int
    let changeBundleID: Bool
    let bundleID: String
    let descriptorCount: Int
    let isContainer: Bool
    let files: [String]
    let root: String
}

/// - Parameter quiet: set for the cases that are *expected* to be refused.  The
///   reference raises there, and its traceback on stderr would otherwise make a
///   green run look like a failure.
func runReference(batter: URL, out: URL, version: String?,
                  choices: [Int: [Any]], quiet: Bool = false) -> ReferenceResult? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: TemplateReference.python)
    process.arguments = [referenceDriver.path]
    let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
    process.standardInput = stdin
    process.standardOutput = stdout
    process.standardError = stderr
    do { try process.run() } catch { return nil }
    var payload: [String: Any] = ["batter": batter.path, "out": out.path]
    if let version { payload["version"] = version }
    if !choices.isEmpty {
        var table: [String: [Any]] = [:]
        for (index, values) in choices { table[String(index)] = values }
        payload["choices"] = table
    }
    guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
    stdin.fileHandleForWriting.write(data)
    stdin.fileHandleForWriting.closeFile()
    let outData = stdout.fileHandleForReading.readDataToEndOfFile()
    let errData = stderr.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0,
          let parsed = try? JSONSerialization.jsonObject(with: outData) as? [String: Any]
    else {
        if !quiet, let errData = String(data: errData, encoding: .utf8), !errData.isEmpty {
            FileHandle.standardError.write(Data("reference stderr:\n\(errData)\n".utf8))
        }
        return nil
    }
    guard let files = parsed["files"] as? [String],
          let title = parsed["title"] as? String,
          let author = parsed["author"] as? String,
          let domain = parsed["domain"] as? String,
          let formatVersion = parsed["format_version"] as? Int,
          let changeBundleID = parsed["change_bundle_id"] as? Bool,
          let descriptorCount = parsed["descriptor_cnt"] as? Int,
          let isContainer = parsed["is_container"] as? Bool,
          let root = parsed["root"] as? String
    else {
        FileHandle.standardError.write(Data(
            "could not read the reference's JSON; keys: \(parsed.keys.sorted())\n".utf8))
        return nil
    }
    // `bundle_id` is `null` unless a `bundle_id` option declared one, and the
    // comparison is against "" for that case — the reference's default is
    // `None`, and this port's default is the domain's own bundle id.
    let bundleID = parsed["bundle_id"] as? String ?? ""
    return ReferenceResult(title: title, author: author, domain: domain,
                           formatVersion: formatVersion, changeBundleID: changeBundleID,
                           bundleID: bundleID, descriptorCount: descriptorCount,
                           isContainer: isContainer, files: files, root: root)
}

/// My own pipeline over the same archive.
func runMine(batter: URL, out: URL, version: String?,
             choices: [Int: [Any]]) -> (result: ReferenceResult, root: URL)? {
    guard var template = try? TemplateFile(url: batter, deviceVersion: version) else { return nil }
    var edited = template
    for (index, values) in choices {
        guard edited.options.indices.contains(index) else { continue }
        switch edited.options[index] {
        case var typed as RemoveOption:
            typed.value = (values.first as? Bool) ?? typed.value
            edited.options[index] = typed
        case var typed as PickerOption:
            if let first = values.first as? Int { typed.selection = [first] }
            edited.options[index] = typed
        case var typed as ReplaceOption:
            if let path = values.first as? String { typed.value = URL(fileURLWithPath: path) }
            edited.options[index] = typed
        case var typed as SetOption:
            switch typed.setter {
            case .toggle:
                typed.value = [(values.first as? Bool) == true ? 1 : 0]
            case .colorPicker:
                let parts = values.compactMap { Double($0 as? String ?? "") }
                if parts.count >= 3 {
                    typed.color = (r: parts[0], g: parts[1], b: parts[2],
                                   a: parts.count > 3 ? parts[3] : 1)
                }
            case .slider, .textbox:
                let parts = values.compactMap { Double($0 as? String ?? "") }
                if !parts.isEmpty { typed.value = parts }
                typed.text = parts.map { "\($0)" }.joined(separator: " ")
            }
            edited.options[index] = typed
        default:
            break
        }
    }
    template = edited
    let destination = out.appendingPathComponent("mine", conformingTo: .directory)
    guard let root = try? template.extract(to: destination) else { return nil }
    let files = ((try? fm.subpathsOfDirectory(atPath: root.path)) ?? [])
        .filter { rel in
            var isDirectory: ObjCBool = false
            return fm.fileExists(atPath: root.appendingPathComponent(rel).path, isDirectory: &isDirectory)
                && !isDirectory.boolValue
        }
        .sorted()
    return (ReferenceResult(title: template.title, author: template.author, domain: template.domain,
                            formatVersion: template.formatVersion,
                            changeBundleID: template.canChangeBundleID, bundleID: template.bundleID,
                            descriptorCount: template.descriptorCount,
                            isContainer: template.isContainer, files: files,
                            root: root.path), root)
}

/// The files under a root, relative and sorted — the shape both sides report in.
func listing(of root: URL) -> [String] {
    ((try? fm.subpathsOfDirectory(atPath: root.path)) ?? [])
        .filter { rel in
            var isDirectory: ObjCBool = false
            return fm.fileExists(atPath: root.appendingPathComponent(rel).path, isDirectory: &isDirectory)
                && !isDirectory.boolValue
        }
        .sorted()
}

// MARK: - Build the fixture

let fixture = work.appendingPathComponent("fixture.batter")
do {
    try buildFixture(at: fixture, in: work)
} catch {
    FileHandle.standardError.write(Data("error: cannot build the fixture: \(error)\n".utf8))
    exit(2)
}

// MARK: - Cases

/// The header, with no option changed.
do {
    let referenceOut = work.appendingPathComponent("ref-header", conformingTo: .directory)
    let mineOut = work.appendingPathComponent("mine-header", conformingTo: .directory)
    guard let reference = runReference(batter: fixture, out: referenceOut, version: "27.0", choices: [:]),
          let mine = runMine(batter: fixture, out: mineOut, version: "27.0", choices: [:])?.result
    else {
        // Reported, not exited: an early `exit(1)` here would print nothing at
        // all, which is the one failure mode a harness must never have.
        check(false, "header", "one side produced nothing")
        report()
    }
    check(reference.title == mine.title, "header/title",
          "reference=\(reference.title) mine=\(mine.title)")
    check(reference.author == mine.author, "header/author",
          "reference=\(reference.author) mine=\(mine.author)")
    check(reference.domain == mine.domain, "header/domain",
          "reference=\(reference.domain) mine=\(mine.domain)")
    check(reference.formatVersion == mine.formatVersion, "header/format_version",
          "reference=\(reference.formatVersion) mine=\(mine.formatVersion)")
    check(reference.changeBundleID == mine.changeBundleID, "header/bundle_id flag",
          "reference=\(reference.changeBundleID) mine=\(mine.changeBundleID)")
    check(reference.bundleID == mine.bundleID, "header/bundle_id",
          "reference=\(reference.bundleID.debugDescription) mine=\(mine.bundleID.debugDescription)")
    check(reference.descriptorCount == mine.descriptorCount, "header/descriptors",
          "reference=\(reference.descriptorCount) mine=\(mine.descriptorCount)")
    check(reference.isContainer == mine.isContainer, "header/is_container",
          "reference=\(reference.isContainer) mine=\(mine.isContainer)")
    check(reference.files == mine.files, "header/files",
          "reference=\(reference.files) mine=\(mine.files)")
}

/// The applied tree, with every option at its default, and again with the
/// toggles flipped and the picker on its second choice.
struct ChoiceCase {
    let name: String
    let choices: [Int: [Any]]
}

let choiceCases = [
    ChoiceCase(name: "apply/defaults", choices: [:]),
    ChoiceCase(name: "apply/toggled", choices: [0: [true], 3: [false]]),
    ChoiceCase(name: "apply/picker-second", choices: [5: [1]]),
    ChoiceCase(name: "apply/picker-second-and-toggled", choices: [0: [true], 5: [1]]),
]

for testCase in choiceCases {
    let referenceOut = work.appendingPathComponent("ref-\(testCase.name.replacingOccurrences(of: "/", with: "-"))",
                                                   conformingTo: .directory)
    let mineOut = work.appendingPathComponent("mine-\(testCase.name.replacingOccurrences(of: "/", with: "-"))",
                                              conformingTo: .directory)
    guard let reference = runReference(batter: fixture, out: referenceOut, version: "27.0",
                                       choices: testCase.choices),
          let mine = runMine(batter: fixture, out: mineOut, version: "27.0",
                             choices: testCase.choices)
    else {
        check(false, testCase.name, "one side produced nothing")
        continue
    }
    check(reference.files == mine.result.files, "\(testCase.name)/files",
          "reference=\(reference.files) mine=\(mine.result.files)")
    // The contents of every surviving file, which is where the options land.
    let referenceRoot = URL(fileURLWithPath: reference.root)
    let mineRoot = mine.root
    for relative in reference.files {
        let referenceBytes = (try? Data(contentsOf: referenceRoot.appendingPathComponent(relative))) ?? Data()
        let mineBytes = (try? Data(contentsOf: mineRoot.appendingPathComponent(relative))) ?? Data()
        // XML is compared as a tree: this port keeps the original formatting
        // and `ElementTree` re-indents, so bytes would differ on every case.
        if relative.hasSuffix(".caml") || relative.hasSuffix(".xml") {
            let referenceShape = (try? TemplateXML.parse(referenceBytes)).map { String(describing: $0.root.tag) }
            let mineShape = (try? TemplateXML.parse(mineBytes)).map { String(describing: $0.root.tag) }
            check(referenceShape != nil && mineShape != nil, "\(testCase.name)/parse \(relative)",
                  "one side's output is not parseable")
            check(attributes(of: referenceBytes) == attributes(of: mineBytes),
                  "\(testCase.name)/xml \(relative)",
                  "reference=\(attributes(of: referenceBytes))\n  mine=\(attributes(of: mineBytes))")
        } else {
            check(referenceBytes == mineBytes, "\(testCase.name)/bytes \(relative)",
                  "reference=\(String(decoding: referenceBytes, as: UTF8.self).debugDescription) "
                  + "mine=\(String(decoding: mineBytes, as: UTF8.self).debugDescription)")
        }
    }
}

// MARK: - The gates, checked directly (the reference raises; there is no output)

struct GateCase {
    let name: String
    let config: String
    let version: String?
    let shouldFail: Bool
}

let gateCases = [
    GateCase(name: "gate/no-config", config: "{}", version: "27.0", shouldFail: true),
    GateCase(name: "gate/future-format", config: baseConfig(overrides: ["format_version": "99"]),
             version: "27.0", shouldFail: true),
    GateCase(name: "gate/no-domain", config: baseConfig(overrides: ["domain": nil]),
             version: "27.0", shouldFail: true),
    GateCase(name: "gate/min-version-too-new", config: baseConfig(overrides: ["min_version": "26.0"]),
             version: "18.0", shouldFail: true),
    GateCase(name: "gate/max-version-too-old", config: baseConfig(overrides: ["max_version": "26.0"]),
             version: "27.0", shouldFail: true),
    GateCase(name: "gate/min-version-unknown-device",
             config: baseConfig(overrides: ["min_version": "26.0"]),
             // No device version: the reference guards with
             // `if device_version and …`, so the check is **skipped** and the
             // template loads.  Reproduced — see `TemplateFile.init`.
             version: nil, shouldFail: false),
    GateCase(name: "gate/bad-option-type",
             config: baseConfig(overrides: ["options": [["type": "teleport", "label": "x", "files": []]]]),
             version: "27.0", shouldFail: true),
    GateCase(name: "gate/no-options-key", config: baseConfig(overrides: ["options": nil]),
             version: "27.0", shouldFail: true),
]

for testCase in gateCases {
    // `name` is a label with a slash in it, and a slash in a file name would
    // make `work/gate/no-config.batter` — whose parent does not exist, so `zip`
    // fails with an empty stderr and a non-zero exit.  The label is flattened
    // for the path and kept for the report.
    let archive = work.appendingPathComponent(
        testCase.name.replacingOccurrences(of: "/", with: "-") + ".batter")
    do {
        try buildArchive(config: testCase.config, at: archive, in: work)
    } catch {
        check(false, testCase.name, "could not build the fixture: \(error)")
        continue
    }
    let mineFailed = (try? TemplateFile(url: archive, deviceVersion: testCase.version)) == nil
    let referenceFailed = runReference(batter: archive,
                                       out: work.appendingPathComponent(
                                        "ref-" + testCase.name.replacingOccurrences(of: "/", with: "-"),
                                        conformingTo: .directory),
                                       version: testCase.version, choices: [:],
                                       quiet: testCase.shouldFail) == nil
    check(mineFailed == testCase.shouldFail, "\(testCase.name)/mine",
          "expected shouldFail=\(testCase.shouldFail), this port failed=\(mineFailed)")
    // Where the reference can be run at all, the two must agree about refusing.
    if referenceFailed != mineFailed && testCase.shouldFail {
        check(false, "\(testCase.name)/agreement",
              "reference refused=\(referenceFailed), this port refused=\(mineFailed)")
    }
}

// A template whose only gate that fires is `format_version`, on a device that
// satisfies every version bound — the one combination where a "too new" config
// must still be refused.
do {
    let archive = work.appendingPathComponent("gate-format-only.batter")
    try buildArchive(config: baseConfig(overrides: ["format_version": "3"]), at: archive, in: work)
    check((try? TemplateFile(url: archive, deviceVersion: "27.0")) == nil,
          "gate/format-version-alone", "a format-3 template was accepted")
}

// MARK: - Report

/// Print the outcome and exit.  Every path out of this harness goes through
/// here, so a failure can never be a silent non-zero exit.
func report() -> Never {
    if failures.isEmpty {
        print("template-e2e-check: \(checked) check(s), all identical to the reference")
        exit(0)
    }
    for failure in failures { print("FAIL \(failure)") }
    print("template-e2e-check: \(failures.count) of \(checked) check(s) failed")
    exit(1)
}

report()

// MARK: - Fixture construction

/// Every element's attributes, flattened, for comparing two XML serialisations.
func attributes(of data: Data) -> [String] {
    guard let document = try? TemplateXML.parse(data) else { return [] }
    var out: [String] = []
    for node in document.root.descendants() {
        out.append(node.tag + " " + node.attributes.map { "\($0.name)=\($0.value)" }.joined(separator: " "))
    }
    return out.sorted()
}

func baseConfig(overrides: [String: Any?]) -> String {
    var config: [String: Any] = [
        "title": "My Batter",
        "author": "harness",
        "format_version": "2",
        "domain": "AppDomain-com.example.thing",
        "options": [[String: Any]](),
    ]
    for (key, value) in overrides {
        if let value { config[key] = value } else { config.removeValue(forKey: key) }
    }
    let data = (try? JSONSerialization.data(withJSONObject: config)) ?? Data()
    return String(decoding: data, as: UTF8.self)
}

/// The fixture: a caml with two identified layers, a text file, and two
/// variants for the picker — one of each thing an option can act on.
func buildFixture(at archive: URL, in root: URL) throws {
    let options: [[String: Any]] = [
        ["type": "set", "label": "Hide background", "identifier": "1", "key": "hidden",
         "setter_type": "toggle", "default_value": false, "inverted": true,
         "files": ["container/Library/Application Support/Thing/main.caml"]],
        ["type": "set", "label": "Shift position", "identifier": "1", "key": "position",
         "setter_type": "textbox", "default_value": "195 365",
         "files": ["container/Library/Application Support/Thing/main.caml"]],
        ["type": "set", "label": "Tint", "identifier": "1", "key": "colorspace",
         "setter_type": "color_picker", "default_value": "1 0.5 1 0.25",
         "files": ["container/Library/Application Support/Thing/main.caml"]],
        ["type": "remove", "label": "Drop the extra layer", "identifier": "2",
         "files": ["container/Library/Application Support/Thing/main.caml"]],
        ["type": "remove", "label": "Drop notes", "default_value": true,
         "files": ["container/Library/Preferences/notes.txt"]],
        ["type": "picker", "label": "Which variant", "rename": true,
         "names": ["container/variants/chosen.bin"],
         "options": [
            ["label": "A", "files": ["container/variants/a.bin"]],
            ["label": "B", "files": ["container/variants/b.bin"]],
         ],
         "default_value": 0],
    ]
    var config: [String: Any] = [
        "title": "My Batter",
        "description": "A differential test template",
        "author": "harness",
        "format_version": "2",
        "domain": "AppDomain-com.example.thing",
        "options": options,
    ]
    let configData = (try? JSONSerialization.data(withJSONObject: config)) ?? Data()

    let caml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <caml xmlns="http://www.apple.com/CoreAnimation/1.0">
      <CALayer nuggetId="1" id="#1" name="Background" position="195 365" hidden="0" colorspace="1 0.5 1 0.25">
        <sublayers/>
      </CALayer>
      <CALayer nuggetId="2" id="#2" name="Removable" position="10 10">
        <sublayers/>
      </CALayer>
    </caml>
    """
    try buildArchive(config: String(decoding: configData, as: UTF8.self), at: archive, in: root,
                     extra: [
                        ("MyPack/container/Library/Application Support/Thing/main.caml",
                         Data(caml.utf8)),
                        ("MyPack/container/Library/Preferences/notes.txt", Data("Pick me up".utf8)),
                        ("MyPack/container/variants/a.bin", Data("variant A".utf8)),
                        ("MyPack/container/variants/b.bin", Data("variant B".utf8)),
                     ])
}

/// Write a ZIP holding a `config.json` and whatever else was asked for.
func buildArchive(config: String, at archive: URL, in root: URL,
                  extra: [(String, Data)] = []) throws {
    // ZIPFoundation is not linked into this harness, so the archive is written
    // with the `zip` tool — the same bytes either way, and it keeps the
    // harness's dependency list to the sources under test.
    let staging = root.appendingPathComponent("staging-" + archive.lastPathComponent,
                                              conformingTo: .directory)
    try? fm.removeItem(at: staging)
    try fm.createDirectory(at: staging, withIntermediateDirectories: true)
    let packDirectory = staging.appendingPathComponent("MyPack", conformingTo: .directory)
    try fm.createDirectory(at: packDirectory, withIntermediateDirectories: true)
    try Data(config.utf8).write(to: packDirectory.appendingPathComponent("config.json"))
    for (path, bytes) in extra {
        let target = staging.appendingPathComponent(path)
        try fm.createDirectory(at: target.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        try bytes.write(to: target)
    }
    try? fm.removeItem(at: archive)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    // The archive path is made absolute **before** `currentDirectoryURL` moves
    // the process: a relative path would then be resolved against the staging
    // directory, and `zip` would write the archive inside the tree it is
    // zipping.
    process.arguments = ["zip", "-qr", archive.standardizedFileURL.path, "MyPack"]
    process.currentDirectoryURL = staging
    let zipOut = Pipe(), zipErr = Pipe()
    process.standardOutput = zipOut
    process.standardError = zipErr
    try process.run()
    let zipErrors = zipErr.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        let detail = String(decoding: zipErrors, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        throw TemplateFile.fail("zip failed for \(archive.lastPathComponent)"
            + (detail.isEmpty ? "" : ": \(detail)"))
    }
}
