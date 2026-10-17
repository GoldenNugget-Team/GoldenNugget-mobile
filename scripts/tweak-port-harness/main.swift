// Differential harness: run this port's tweak compiler and print what it would
// write, so `scripts/tweak-port-diff.py` can compare it against GoldenNugget's
// own `apply_tweak` + `split_path_into_domain`.
//
// Deliberately depends on nothing but the compiler's own four files
// (`TweakModel` / `TweakCatalog` / `TweakDomainMap` / `TweakCompiler`), all of
// which are pure Foundation — no UIKit, no Minimuxer, no SQLite.  That is what
// lets it build and run on the host for a check the device is not needed for.
//
// It lives under `scripts/` (excluded from the app target by `Package.swift`)
// and is compiled ad hoc by the driver, never by the app build.
//
// Usage:
//     tweak-port-harness '<cases json>' <deviceVersion> <iphone|ipad>
//
// `cases json` is `{"<case name>": {"<TweakID>": <value or null>, ...}, ...}`.

import Foundation

func tweakValue(_ any: Any?) -> TweakValue? {
    guard let any else { return nil }
    if let string = any as? String { return .string(string) }
    if let number = any as? NSNumber {
        if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
        let double = number.doubleValue
        if double == double.rounded(), abs(double) < 1e15 { return .int(number.intValue) }
        return .double(double)
    }
    if let dict = any as? [String: Any] {
        return nil // handled as a multi-value dict by the caller
    }
    return nil
}

let arguments = CommandLine.arguments
guard arguments.count >= 4 else {
    FileHandle.standardError.write(Data("usage: harness <cases json> <version> <iphone|ipad>\n".utf8))
    exit(2)
}
let deviceVersion = arguments[2]
let isIPhone = arguments[3] == "iphone"

guard let casesData = arguments[1].data(using: .utf8),
      let cases = try? JSONSerialization.jsonObject(with: casesData) as? [String: [String: Any]] else {
    FileHandle.standardError.write(Data("harness: cases argument is not a JSON object\n".utf8))
    exit(2)
}

/// A type-tagged rendering of one plist value.
///
/// `JSONSerialization` writes `Double(1.0)` as `1`, so a JSON round trip cannot
/// tell an integer from a real — and that distinction is the *point* of this
/// test: the reference writes `1` and `1.0` as different plist types
/// (`value=1` vs `value=1.0` in `registry.py`), and the framework reading the
/// key sees the difference.  So the tag is carried in the string instead.
///
/// `CFNumberIsFloatType` is the only reliable discriminator here: `NSNumber(1)
/// as? Bool` succeeds in Swift, so a plain cast cannot tell `true` from `1`
/// either.
func tagged(_ value: Any) -> String {
    if let number = value as? NSNumber {
        if CFGetTypeID(number) == CFBooleanGetTypeID() { return "bool:\(number.boolValue)" }
        if !CFNumberIsFloatType(number) { return "int:\(number.intValue)" }
        return "real:\(number.doubleValue)"
    }
    if let string = value as? String { return "str:\(string)" }
    if let data = value as? Data { return "data:\(data.count)" }
    if let dict = value as? [String: Any] {
        return "dict{" + dict.keys.sorted()
            .map { "\($0)=\(tagged(dict[$0]!))" }
            .joined(separator: ",") + "}"
    }
    if let array = value as? [Any] { return "array[" + array.map(tagged).joined(separator: ",") + "]" }
    return "other:\(value)"
}

/// One case's compiled output: `"<domain>/<relativePath>" -> { key: tag }`.
func compileCase(_ tweaks: [String: Any]) -> [String: [String: String]] {
    var selection = TweakSelection()
    for (id, raw) in tweaks {
        guard let spec = TweakCatalog.byID[id] else { continue }
        var multi: [String: TweakValue]?
        if let dict = raw as? [String: Any] {
            multi = dict.compactMapValues { tweakValue($0) }
        }
        selection.restore(enabled: true,
                          value: raw is NSNull ? nil : tweakValue(raw),
                          multiValues: multi,
                          for: spec)
    }
    let result = TweakCompiler.compile(selection: selection,
                                       deviceVersion: deviceVersion,
                                       isIPhone: isIPhone)
    var out: [String: [String: String]] = [:]
    for payload in result.payloads {
        let plist = (try? PropertyListSerialization.propertyList(from: payload.contents,
                                                                 options: [],
                                                                 format: nil)) as? [String: Any]
        out[payload.label] = (plist ?? [:]).mapValues(tagged)
    }
    return out
}

var output: [String: [String: [String: String]]] = [:]
for (name, tweaks) in cases {
    output[name] = compileCase(tweaks)
}

let encoded = try! JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
FileHandle.standardOutput.write(encoded)
