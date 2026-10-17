// Regression harness for the "Skip Setup" payloads — the two files upstream's
// `add_skip_setup` adds to every apply.
//
// What it checks, none of which needs a device:
//
//   1  CONTENT  the built `CloudConfigurationDetails.plist` and
//               `com.apple.purplebuddy.plist`, parsed, are equal to the pair the
//               reference produced for this device (the files passed on the
//               command line).  Comparing *parsed* plists on purpose: plist dict
//               order is not part of the format, and Swift's `[String: Any]`
//               writes keys in hash order, so a byte comparison would fail on a
//               file that is the same file.
//   2  SHAPE    both payloads carry the domains and paths `add_skip_setup`
//               appends, in its order (cloud configuration first), because the
//               directory rows are derived from those paths and the order is
//               what the caller asked for.
//   3  SUPERVISED  the supervised variant sets `IsSupervised` and the
//               organization keys, lowercases the magic like `str(uuid4())`
//               does, and — the part this port cannot do — writes no
//               `SupervisorHostCertificates` *and says so* in its warnings.
//
// Run:
//   mkdir -p /tmp/skipsetup \
//     && cat Nugget/Core/SkipSetupCatalog.swift Nugget/Core/SkipSetup.swift \
//            Nugget/Core/TweakModel.swift Nugget/Core/TweakCatalog.swift \
//            Nugget/Core/TweakCatalogDaemons.swift Nugget/Core/TweakDomainMap.swift \
//            Nugget/Core/TweakCompiler.swift scripts/skipsetup-check.swift \
//            > /tmp/skipsetup/main.swift \
//     && xcrun swiftc -O /tmp/skipsetup/main.swift -o /tmp/skipsetup/check \
//     && /tmp/skipsetup/check [CloudConfigurationDetails.plist] [com.apple.purplebuddy.plist]
//
// With no arguments it uses the pair this port was written against and skips the
// CONTENT step if they are not on this machine.
//
// This file is NOT part of the app target; keep it out of Package.swift.

import Foundation

let defaultCloud = "/Users/jason/Omega27/files/CloudConfigurationDetails.plist"
let defaultPurple = "/Users/jason/Omega27/files/com.apple.purplebuddy.plist"
let cloudPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : defaultCloud
let purplePath = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : defaultPurple

func load(_ path: String) -> [String: Any]? {
    guard let data = FileManager.default.contents(atPath: path) else { return nil }
    return (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil))
        as? [String: Any]
}

func differingKeys(_ lhs: [String: Any], _ rhs: [String: Any]) -> [String] {
    var out: [String] = []
    for key in Set(lhs.keys).union(rhs.keys) {
        let a = lhs[key].map { String(describing: $0) } ?? "<absent>"
        let b = rhs[key].map { String(describing: $0) } ?? "<absent>"
        if a != b { out.append(key) }
    }
    return out.sorted()
}

let build = SkipSetup.build(supervised: false, organizationName: "")

// MARK: - 1. content

print("--- 1. built plists vs the reference's own output ---")
var contentFailures = 0
for (payload, path, label) in [
    (build.payloads[0], cloudPath, "CloudConfigurationDetails.plist"),
    (build.payloads[1], purplePath, "com.apple.purplebuddy.plist"),
] {
    guard let ours = (try? PropertyListSerialization.propertyList(
        from: payload.contents, options: [], format: nil)) as? [String: Any] else {
        print("CONTENT  \(label): ours is not a plist — FAIL")
        contentFailures += 1
        continue
    }
    guard let theirs = load(path) else {
        print("CONTENT  \(label): skipped (no reference file at \(path)); ours has "
            + "\(ours.count) key(s)")
        continue
    }
    let diff = differingKeys(ours, theirs)
    if diff.isEmpty {
        print("CONTENT  \(label): \(ours.count) key(s), identical to \(path)")
    } else {
        print("CONTENT  \(label): DIFFERS on \(diff.joined(separator: ", "))")
        for key in diff {
            print("           ours: \(String(describing: ours[key]).prefix(120))")
            print("           ref : \(String(describing: theirs[key]).prefix(120))")
        }
        contentFailures += 1
    }
}

// MARK: - 2. shape

print("\n--- 2. domains, paths and order (`add_skip_setup`) ---")
let expected: [(String, String)] = [
    ("SysSharedContainerDomain-systemgroup.com.apple.configurationprofiles",
     "Library/ConfigurationProfiles/CloudConfigurationDetails.plist"),
    ("ManagedPreferencesDomain", "mobile/com.apple.purplebuddy.plist"),
]
var shapeFailures = 0
if build.payloads.count != expected.count {
    print("SHAPE    expected \(expected.count) payload(s), got \(build.payloads.count) — FAIL")
    shapeFailures += 1
} else {
    for (index, want) in expected.enumerated() {
        let got = build.payloads[index]
        let ok = got.domain == want.0 && got.relativePath == want.1
        print("SHAPE    [\(index)] \(ok ? "ok  " : "FAIL") \(got.domain)/\(got.relativePath)")
        if !ok {
            print("                expected \(want.0)/\(want.1)")
            shapeFailures += 1
        }
    }
}
print("SHAPE    directory rows the injector derives: "
    + build.payloads.map { payload in
        let parents = (payload.relativePath as NSString).deletingLastPathComponent
            .split(separator: "/").count
        return "\(payload.domain) → root + \(parents) dir row(s) + file"
      }.joined(separator: " | "))

// MARK: - 3. the supervised variant

print("\n--- 3. supervised variant ---")
var supervisedFailures = 0
let supervised = SkipSetup.cloudConfiguration(supervised: true, organizationName: "  Acme Ltd  ")
guard let magic = supervised.plist["OrganizationMagic"] as? String else {
    print("SUPERVISED  OrganizationMagic missing — FAIL")
    supervisedFailures += 1
    exit(1)
}
let checks: [(String, Bool)] = [
    ("IsSupervised", (supervised.plist["IsSupervised"] as? Bool) == true),
    ("OrganizationName trimmed", (supervised.plist["OrganizationName"] as? String) == "Acme Ltd"),
    ("IsMDMUnremovable false", (supervised.plist["IsMDMUnremovable"] as? Bool) == false),
    ("OrganizationMagic is lowercase (str(uuid4()) does)",
     magic == magic.lowercased() && magic.count == 36),
    ("no SupervisorHostCertificates in the file",
     supervised.plist["SupervisorHostCertificates"] == nil),
    ("the missing certificate is warned about, not silent",
     supervised.warnings.contains { $0.contains("SupervisorHostCertificates") }),
    ("the un-merged `existing` is warned about too",
     supervised.warnings.contains { $0.contains("MobileConfigService") }),
    ("SkipSetup panes are in both variants", supervised.plist["SkipSetup"] as? [String] != nil
        && (supervised.plist["SkipSetup"] as? [String])?.count == SkipSetup.panes.count),
]
for (label, ok) in checks {
    print("SUPERVISED  \(ok ? "ok  " : "FAIL") \(label)")
    if !ok { supervisedFailures += 1 }
}

let failures = contentFailures + shapeFailures + supervisedFailures
print("\n" + (failures == 0
    ? "OK — content, shape and the supervised variant all as the reference writes them"
    : "FAIL — \(failures) check(s) failed"))
exit(failures == 0 ? 0 : 1)
