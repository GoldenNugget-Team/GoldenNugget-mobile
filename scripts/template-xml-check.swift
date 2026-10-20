// Differential test of the `.batter` XML engine against the reference.
//
// Run (the project's usual shape — top-level code needs the file to be `main.swift`):
//   mkdir -p /tmp/tmpl-xml \
//     && cat Nugget/Core/TemplateXML.swift Nugget/Core/XMLScanner.swift \
//            scripts/template-xml-check.swift > /tmp/tmpl-xml/main.swift \
//     && xcrun swiftc -O /tmp/tmpl-xml/main.swift -o /tmp/tmpl-xml/check \
//     && /tmp/tmpl-xml/check
//
// Or without the copy, by naming the concatenation target `main.swift`:
//   mkdir -p /tmp/tmpl-xml && cat Nugget/Core/TemplateXML.swift \
//       Nugget/Core/XMLScanner.swift scripts/template-xml-check.swift \
//       > /tmp/tmpl-xml/main.swift && xcrun swiftc -O /tmp/tmpl-xml/main.swift \
//       -o /tmp/tmpl-xml/check && /tmp/tmpl-xml/check
//
// What it compares, case by case: the document the reference's
// `set_xml_values` / `delete_xml_value` produce, against the document this port
// produces, for the same input and the same arguments.
//
// Why a *semantic* comparison and not a byte one: `xml.etree.ElementTree`
// reformats every document it writes (attribute quoting, self-closing style, the
// namespace declaration it re-emits), and this port deliberately does not.
// Comparing bytes would report a difference on every case for a reason that has
// nothing to do with the semantics under test.  So both outputs are parsed and
// their `(tag, ordered attributes, text)` trees plus child order are compared.
// The one thing that *must* round-trip byte for byte — a document nothing
// matched — is asserted separately, because that is the property a template
// author diffing a `.caml` actually relies on.
//
// The cases are the ones the reference's own documentation describes:
// `nuggetId` / `use_ca_id` / `targetId` lookup, the `nuggetOffset` equation
// (`(2 * x + 10), (3 * y + 15)` over `195 365`), removal of nested and repeated
// matches, entity round-tripping, and the two situations the reference raises on
// (a non-numeric offset value, a mismatched closing tag).

import Foundation

// MARK: - Harness plumbing

struct Failure {
    let caseName: String
    let reason: String
}

var failures: [Failure] = []
var checked = 0

func check(_ condition: Bool, _ caseName: String, _ reason: @autoclosure () -> String) {
    checked += 1
    if !condition { failures.append(Failure(caseName: caseName, reason: reason())) }
}

// MARK: - A semantic view of a document, for comparing two serialisers

/// One attribute, as a pair — a tuple would not make the enclosing array
/// `Equatable` automatically.
struct Attribute: Equatable {
    let name: String
    let value: String
}

/// One element, flattened the way both sides have to agree on.
indirect enum Shape: Equatable {
    case element(tag: String, attributes: [Attribute], content: [Shape])
    case text(String)

    /// The subtree, ignoring whitespace-only text between child elements.
    ///
    /// That normalisation is the whole point of the comparison: `ElementTree`
    /// drops the indentation a file had and re-indents with its own, and this
    /// port keeps it.  Whitespace between elements is layout, not information;
    /// the attributes and the child order are.
    static func parse(_ data: Data) throws -> Shape {
        let document = try TemplateXML.parse(data)
        return shape(of: document.root)
    }

    private static func shape(of node: TemplateXML.Node) -> Shape {
        var out: [Shape] = []
        // A parent whose body is entirely character data keeps that data as its
        // text; a parent's body that mixes text and elements contributes its
        // element children, because the whitespace around them is layout and a
        // mixed body is not something a `caml` has.
        let hasElements = node.content.contains { if case .element = $0 { return true } else { return false } }
        if !hasElements {
            let joined = node.text
            if !joined.isEmpty { return .text(joined) }
        }
        for item in node.content {
            if case .element(let child) = item { out.append(shape(of: child)) }
        }
        return .element(tag: node.tag,
                        attributes: node.attributes.map { Attribute(name: $0.name, value: $0.value) },
                        content: out)
    }
}

// MARK: - Cases

struct Case {
    let name: String
    let document: String
    /// Arguments for `xml_handler.set_xml_values`.
    let id: String
    let keys: [String]
    let values: [String]
    let useCAID: Bool
    /// Whether to delete instead of set.
    let isDelete: Bool
}

let caml = """
<?xml version="1.0" encoding="UTF-8"?>
<caml xmlns="http://www.apple.com/CoreAnimation/1.0">
  <CALayer allowsEdgeAntialiasing="1" allowsGroupOpacity="1" bounds="0 -28 520 563" contentsFormat="RGBA8" cornerCurve="circular" hidden="0" name="Root Layer" position="195 365" transform="" zPosition="442">
    <sublayers>
      <CALayer nuggetId="1" id="#1" allowsEdgeAntialiasing="1" allowsGroupOpacity="1" bounds="0 -28 520 563" contentsFormat="RGBA8" cornerCurve="circular" hidden="0" name="Thing" position="195 365" transform="" zPosition="442">
        <sublayers/>
      </CALayer>
    </sublayers>
  </CALayer>
</caml>
"""

let offsetDoc = """
<?xml version="1.0" encoding="UTF-8"?>
<caml xmlns="http://www.apple.com/CoreAnimation/1.0">
  <CALayer nuggetId="1" nuggetOffset="(2 * x + 10), (3 * y + 15)" id="#1" position="195 365" name="Thing">
    <sublayers/>
  </CALayer>
</caml>
"""

let repeatedDoc = """
<?xml version="1.0" encoding="UTF-8"?>
<caml xmlns="http://www.apple.com/CoreAnimation/1.0">
  <CALayer id="#1">
    <sublayers>
      <CALayer nuggetId="dup" name="A"/>
      <CALayer nuggetId="other" name="B"/>
      <CALayer nuggetId="dup" name="C"/>
    </sublayers>
  </CALayer>
</caml>
"""

let targetIDDoc = """
<?xml version="1.0" encoding="UTF-8"?>
<caml xmlns="http://www.apple.com/CoreAnimation/1.0">
  <CALayer id="#1" name="Layer">
    <sublayers>
      <CALayer targetId="#1" name="Child"/>
    </sublayers>
  </CALayer>
</caml>
"""

let escapedDoc = """
<?xml version="1.0" encoding="UTF-8"?>
<caml xmlns="http://www.apple.com/CoreAnimation/1.0">
  <CALayer nuggetId="1" name="A &amp; B" position="1 &lt; 2" src="assets/a&amp;b.png"/>
</caml>
"""

let offsetSingleDoc = """
<?xml version="1.0" encoding="UTF-8"?>
<caml xmlns="http://www.apple.com/CoreAnimation/1.0">
  <CALayer nuggetId="1" nuggetOffset="2 * x + 10" id="#1" position="20" name="Thing">
    <sublayers/>
  </CALayer>
</caml>
"""

/// A single value against a two-component equation.
///
/// The reference **raises** `NameError` here — `zip(['x','y','z','a'], ['20'])`
/// binds only `x`, so the second equation's `y` is unbound — and this port
/// refuses for the same reason with the same class of error.  Pinned because
/// "helpfully" binding `y = 0.0` here would be the kind of divergence that
/// silently moves a layer instead of failing.
let offsetUnboundDoc = offsetDoc

let cases: [Case] = [
    // set: the ordinary path
    .init(name: "set/nuggetId", document: caml, id: "1", keys: ["hidden"],
          values: ["1"], useCAID: false, isDelete: false),
    .init(name: "set/multi-key", document: caml, id: "1", keys: ["hidden", "position"],
          values: ["1", "0 0"], useCAID: false, isDelete: false),
    .init(name: "set/no-match", document: caml, id: "nope", keys: ["hidden"],
          values: ["1"], useCAID: false, isDelete: false),
    // set: use_ca_id, and the targetId second pass
    .init(name: "set/ca-id", document: caml, id: "#1", keys: ["name"],
          values: ["Renamed"], useCAID: true, isDelete: false),
    .init(name: "set/targetId", document: targetIDDoc, id: "#1", keys: ["name"],
          values: ["Renamed"], useCAID: true, isDelete: false),
    // set: the nuggetOffset equation, single and multiple components
    .init(name: "set/offset-two", document: offsetDoc, id: "1", keys: ["position"],
          values: ["195 365"], useCAID: false, isDelete: false),
    .init(name: "set/offset-single", document: offsetSingleDoc, id: "1", keys: ["position"],
          values: ["20"], useCAID: false, isDelete: false),
    // set: every match, not just the first
    .init(name: "set/repeated", document: repeatedDoc, id: "dup", keys: ["name"],
          values: ["Z"], useCAID: false, isDelete: false),
    // escaping must survive a round trip
    .init(name: "set/escaped-attrs", document: escapedDoc, id: "1", keys: ["name"],
          values: ["X & Y"], useCAID: false, isDelete: false),
    // delete
    .init(name: "delete/nuggetId", document: caml, id: "1", keys: [], values: [],
          useCAID: false, isDelete: true),
    .init(name: "delete/repeated", document: repeatedDoc, id: "dup", keys: [], values: [],
          useCAID: false, isDelete: true),
    .init(name: "delete/ca-id-and-target", document: targetIDDoc, id: "#1", keys: [], values: [],
          useCAID: true, isDelete: true),
    .init(name: "delete/no-match", document: caml, id: "nope", keys: [], values: [],
          useCAID: false, isDelete: true),
]

// MARK: - Run

let goldennugget = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "\(NSHomeDirectory())/GoldenNugget"
let referenceScript = URL(fileURLWithPath: "/tmp/xml-handler-ref.py")

let pythonSource = """
import io, json, sys, xml.etree.ElementTree as tree
tree.register_namespace('', "http://www.apple.com/CoreAnimation/1.0")

def parse_equation(eq, val):
    eqns = eq.split(',')
    value = [val]
    if ' ' in val:
        value = val.split(' ')
    value = list(map(lambda x: float(x), value))
    keys = ['x', 'y', 'z', 'a']
    results = []
    mapped = dict(zip(keys, value))
    for eqn in eqns:
        results.append(str(eval(eqn, {"__builtins__": {}}, mapped)))
    return ' '.join(results)

def set_xml_values(file, id, keys, values, use_ca_id=False):
    xml = tree.parse(file)
    root = xml.getroot()
    for i in range(len(values)):
        if isinstance(values[i], bool):
            values[i] = int(values[i])
        if not isinstance(values[i], str):
            values[i] = str(values[i])
    idKey = "id" if use_ca_id else "nuggetId"
    for to_change in root.findall(f".//*[@{idKey}='{id}']"):
        eqn = to_change.get("nuggetOffset")
        for i in range(len(keys)):
            offsetVal = values[i]
            if i == 0 and eqn is not None:
                offsetVal = parse_equation(eqn, offsetVal)
            to_change.set(keys[i], offsetVal)
    if use_ca_id:
        for to_change in root.findall(f".//*[@targetId='{id}']"):
            for i in range(len(keys)):
                to_change.set(keys[i], values[i])
    xml.write(file, encoding="UTF-8", xml_declaration=True)

def remove_from_root(root, search):
    for parent in root.findall(search + "/.."):
        for prop in parent.findall(search):
            parent.remove(prop)

def delete_xml_value(file, id, use_ca_id=False):
    xml = tree.parse(file)
    root = xml.getroot()
    idKey = "id" if use_ca_id else "nuggetId"
    remove_from_root(root, search=f".//*[@{idKey}='{id}']")
    if use_ca_id:
        remove_from_root(root, search=f".//*[@targetId='{id}']")
    xml.write(file, encoding="UTF-8", xml_declaration=True)

payload = json.load(sys.stdin)
src, dst = payload['src'], payload['dst']
open(src, 'w', encoding='utf-8').write(payload['document'])
if payload['delete']:
    delete_xml_value(src, payload['id'], payload['use_ca_id'])
else:
    set_xml_values(src, payload['id'], payload['keys'], payload['values'], payload['use_ca_id'])
sys.stdout.write(open(src, encoding='utf-8').read())
"""
do {
    try Data(pythonSource.utf8).write(to: referenceScript)
} catch {
    fatal("could not write the reference script: \(error)")
}

let work = URL(fileURLWithPath: "/tmp/template-xml-check-work")
try? FileManager.default.removeItem(at: work)
do {
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
} catch {
    fatal("could not create \(work.path): \(error)")
}
defer { try? FileManager.default.removeItem(at: work) }

func reference(_ testCase: Case) -> String? {
    let input: [String: Any] = [
        "src": work.appendingPathComponent("ref.xml").path,
        "dst": work.appendingPathComponent("out.xml").path,
        "document": testCase.document,
        "id": testCase.id,
        "keys": testCase.keys,
        "values": testCase.values,
        "use_ca_id": testCase.useCAID,
        "delete": testCase.isDelete,
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: input) else { return nil }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["python3", referenceScript.path]
    let stdin = Pipe(), stdout = Pipe()
    process.standardInput = stdin
    process.standardOutput = stdout
    process.standardError = Pipe()
    do { try process.run() } catch { return nil }
    stdin.fileHandleForWriting.write(data)
    stdin.fileHandleForWriting.closeFile()
    let out = stdout.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return nil }
    return String(data: out, encoding: .utf8)
}

func mine(_ testCase: Case) -> Data? {
    guard let input = testCase.document.data(using: .utf8) else { return nil }
    do {
        if testCase.isDelete {
            return try TemplateXML.deleteValue(in: input, id: testCase.id, useCAID: testCase.useCAID)
        }
        return try TemplateXML.setValues(in: input, id: testCase.id, keys: testCase.keys,
                                         values: testCase.values, useCAID: testCase.useCAID)
    } catch {
        return nil
    }
}

for testCase in cases {
    guard let referenceOutput = reference(testCase),
          let mineOutput = mine(testCase) else {
        check(false, testCase.name, "one side produced nothing (the reference run failed, or "
            + "this port threw)")
        continue
    }
    guard let referenceShape = try? Shape.parse(Data(referenceOutput.utf8)),
          let myShape = try? Shape.parse(mineOutput) else {
        check(false, testCase.name, "one side's output is not parseable as XML")
        continue
    }
    check(referenceShape == myShape, testCase.name,
          "shapes differ\n  reference: \(referenceShape)\n  this port: \(myShape)")
}

// A document nothing matched must come back byte for byte.  `ElementTree`
// reformats it; this port must not, and that difference is the reason the rest
// of the comparison is semantic.
do {
    let untouched = Case(name: "roundtrip/no-match", document: caml, id: "nothing-matches-this",
                         keys: ["hidden"], values: ["1"], useCAID: false, isDelete: false)
    if let output = mine(untouched) {
        check(output == untouched.document.data(using: .utf8), "roundtrip/no-match",
              "a document with no match was reformatted:\n\(String(decoding: output, as: UTF8.self))")
    } else {
        check(false, "roundtrip/no-match", "this port threw on a document it should not have touched")
    }
}

// The two behaviours that must be *refusals*, checked directly because the
// reference raises and there is no output to compare.
do {
    let offsetWithText = Case(name: "refuse/offset-non-numeric", document: offsetDoc, id: "1",
                              keys: ["position"], values: ["not a number"],
                              useCAID: false, isDelete: false)
    check(mine(offsetWithText) == nil, "refuse/offset-non-numeric",
          "a nuggetOffset over a non-numeric value produced output; the reference raises "
          + "ValueError there and this port must refuse too")
}

// A two-component equation over a one-component value: `NameError` in the
// reference, a refusal here.  Both sides refusing is the pass condition.
do {
    let unbound = Case(name: "refuse/offset-unbound-variable", document: offsetUnboundDoc, id: "1",
                       keys: ["position"], values: ["20"], useCAID: false, isDelete: false)
    let mineRefused = mine(unbound) == nil
    let referenceRefused = reference(unbound) == nil
    check(mineRefused && referenceRefused, "refuse/offset-unbound-variable",
          "mine refused=\(mineRefused), reference refused=\(referenceRefused) — both must refuse, "
          + "because the reference's zip() binds no `y` for a one-component value")
}

do {
    let badXML = Case(name: "refuse/malformed", document: "<caml><CALayer></caml>",
                      id: "1", keys: ["hidden"], values: ["1"],
                      useCAID: false, isDelete: false)
    check(mine(badXML) == nil, "refuse/malformed",
          "a mismatched closing tag was accepted")
}

// fnmatch, the `files` glob behind every option.
let globCases: [(String, String, Bool)] = [
    ("*.caml", "main.caml", true),
    ("*.caml", "main.xml", false),
    ("a?c", "abc", true),
    ("a?c", "ac", false),
    ("[abc]x", "bx", true),
    ("[abc]x", "dx", false),
    ("[!abc]x", "dx", true),
    ("[!abc]x", "bx", false),
    ("[a-c]x", "bx", true),
    ("*", "anything", true),
    ("exact", "exact", true),
    ("exact", "other", false),
]
for (pattern, name, expected) in globCases {
    check(TemplateGlob.fnmatch(pattern, name) == expected, "fnmatch/\(pattern)/\(name)",
          "expected \(expected), got \(TemplateGlob.fnmatch(pattern, name))")
}

// The glob itself, over a real tree — compared against the reference's
// `glob.glob(..., recursive=True)` rather than against expectations written by
// hand.  Writing the expectations by hand is how `**/main.caml` becomes "should
// match the one at the root too", which is wrong: CPython's `**` does not match
// zero components *in front of a literal*, so a top-level `main.caml` is not a
// hit.  (It did produce 2 on both sides; the hand-written expectation of 3 was
// the error, and finding that out is why this block asks Python.)
do {
    let root = work.appendingPathComponent("glob")
    let fm = FileManager.default
    try fm.createDirectory(at: root.appendingPathComponent("descriptors/UUID/bg/assets"),
                           withIntermediateDirectories: true)
    try fm.createDirectory(at: root.appendingPathComponent("descriptors/OTHER"),
                           withIntermediateDirectories: true)
    try Data().write(to: root.appendingPathComponent("descriptors/UUID/bg/assets/a.png"))
    try Data().write(to: root.appendingPathComponent("descriptors/UUID/bg/main.caml"))
    try Data().write(to: root.appendingPathComponent("descriptors/OTHER/main.caml"))
    try Data().write(to: root.appendingPathComponent("descriptors/UUID/main.caml"))
    try Data().write(to: root.appendingPathComponent("top.caml"))

    // Do not shadow Python's standard-library glob module with the script itself.
    let globScript = work.appendingPathComponent("reference-glob.py")
    try Data("""
import glob, json, os, sys
root, pattern = json.load(sys.stdin)
os.chdir(root)
print(json.dumps(sorted(glob.glob(pattern, recursive=True))))
""".utf8).write(to: globScript)

    func pythonGlob(_ pattern: String) -> [String]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", globScript.path]
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let input = try? JSONSerialization.data(withJSONObject: [root.path, pattern])
        stdin.fileHandleForWriting.write(input ?? Data())
        stdin.fileHandleForWriting.closeFile()
        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let parsed = try? JSONSerialization.jsonObject(with: out) as? [String]
        else { return nil }
        return parsed
    }

    for pattern in ["top.caml", "missing.caml", "descriptors/*", "descriptors/*/main.caml",
                    "descriptors/*/*/main.caml", "**/main.caml", "**/*.caml",
                    "descriptors/UUID/bg/assets/*.png", "*/main.caml", "**",
                    // The three below are the `*`-does-not-cross-a-`/` rules, and
                    // they are here because a mutation that made `*` match
                    // across path components still passed every other case in
                    // this list — including `**`.  `*` matching across a `/` is
                    // the difference between "one level down" and "any depth",
                    // which is what decides whether a `set` option's `files`
                    // entry edits one descriptor or all of them.
                    "descriptors/*main.caml", "descriptors/UUID/*", "*.caml",
                    "descriptors/UUID/bg/*/main.caml", "*/*/main.caml",
                    "d*/U*/bg/assets/*.png", "descriptors/UUID/bg/asset?/*.png"] {
        // `standardizedFileURL` on both sides: macOS resolves `/tmp` to
        // `/private/tmp`, so the matches come back prefixed with the resolved
        // root while `root.path` still says `/tmp` — and a naive strip then
        // leaves "/private" glued onto every relative path.
        let prefix = root.standardizedFileURL.path + "/"
        let mineHits = TemplateGlob.match(pattern, under: root)
            .map { $0.standardizedFileURL.path.replacingOccurrences(of: prefix, with: "") }
            .sorted()
        let referenceHits = pythonGlob(pattern) ?? []
        check(mineHits == referenceHits, "glob/\(pattern)",
              "reference=\(referenceHits) mine=\(mineHits)")
    }
}

// MARK: - Report

if failures.isEmpty {
    print("template-xml-check: \(checked) check(s), all identical to the reference")
    exit(0)
}
for failure in failures {
    print("FAIL \(failure.caseName): \(failure.reason)")
}
print("template-xml-check: \(failures.count) of \(checked) check(s) failed")
exit(1)

// MARK: - Small helpers this file needs

func fatal(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("error: " + message + "\n").utf8))
    exit(2)
}
