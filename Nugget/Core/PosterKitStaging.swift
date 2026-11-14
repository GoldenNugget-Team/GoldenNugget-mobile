import Foundation

/// Editing an existing PosterKit wallpaper archive without decoding away its
/// object graph (`src/tweaks/posterboard/archive_editor.py`,
/// `clock_material.py`, `clock_opacity.py`), and staging the edits as
/// `AppDomain-com.apple.PosterBoard` restore payloads
/// (`device_overrides.PosterKitOverrides.stage`).
///
/// The reference works on `plistlib`'s parse, where an NSKeyedArchiver `UID`
/// is a first-class value: edits to a field the archive stores *through* a UID
/// append a fresh object and repoint the reference, so other references to the
/// same object ("aliases") keep their old value.  CoreFoundation has no Swift
/// constructible UID — the type is opaque (`MBFileBlob.swift` reads its index
/// through reflection for the same reason) — so this port edits the referenced
/// slot in the `$objects` array instead.  An alias the archive shares with the
/// edited field is therefore changed too, where the reference would have left
/// it alone; wallpapers have not been observed to alias the scalar fields this
/// port writes, and every edit is verified by re-reading the archive after
/// serialization exactly like `PosterArchive.serialize` does.
///
/// Callers must apply PosterKit settings separately from wallpaper imports and
/// resets (`src/controllers/tweak_compiler.py:135`): the staging pulls and
/// edits the *live* container, and a reset run or a wallpaper import would
/// overwrite the very archives these edits land in.
enum PosterKitStaging {

    // MARK: - Scalar model

    /// The plist scalar kinds `plistlib` distinguishes by `type()`: a bool is
    /// not an int, an int is not a float, and the XML round-trip keeps them
    /// apart (`TweakConflicts.plistValueEquals` documents the same split for
    /// preference values).
    private enum ScalarKind: Equatable {
        case bool, int, double, string
    }

    /// One `TweakValue` flattened to the scalar the reference stores in a
    /// PosterKit archive field.
    private enum Scalar: Equatable {
        case bool(Bool)
        case int(Int)
        case double(Double)
        case string(String)

        var kind: ScalarKind {
            switch self {
            case .bool: .bool
            case .int: .int
            case .double: .double
            case .string: .string
            }
        }

        /// The plist-native representation: a `CFBoolean`-tagged NSNumber for
        /// bools (a plain `NSNumber(value:)` would serialize as an integer),
        /// and `NSString` for strings, matching what `PropertyListSerialization`
        /// reads back from an archive.
        var plistValue: Any {
            switch self {
            case .bool(let value): NSNumber(value: value)
            case .int(let value): NSNumber(value: value)
            case .double(let value): NSNumber(value: value)
            case .string(let value): value as NSString
            }
        }

        var number: NSNumber? {
            switch self {
            case .bool(let value): NSNumber(value: value)
            case .int(let value): NSNumber(value: value)
            case .double(let value): NSNumber(value: value)
            case .string: nil
            }
        }

        /// Flattens a selection value; dictionaries, dates and friends are not
        /// scalar archive fields, so they are rejected with the user-facing
        /// message the desktop editor produces for a mismatched field type.
        init?(from value: TweakValue) {
            switch value {
            case .bool(let value): self = .bool(value)
            case .int(let value): self = .int(value)
            case .double(let value): self = .double(value)
            case .string(let value): self = .string(value)
            default: return nil
            }
        }

        /// `plistlib.dumps` equality for two scalars of the same kind.
        func equals(_ other: Scalar) -> Bool {
            switch (self, other) {
            case (.bool(let a), .bool(let b)): a == b
            case (.int(let a), .int(let b)): a == b
            case (.double(let a), .double(let b)): a == b
            case (.string(let a), .string(let b)): a == b
            default: false
            }
        }
    }

    /// The kind a decoded plist value carries, mirroring `type()` in Python:
    /// `NSNumber`'s boolean/integer/real split (`TweakConflicts.numberKind`)
    /// and `NSString` for strings.
    private static func kind(_ value: Any?) -> ScalarKind? {
        guard let value else { return nil }
        guard let number = value as? NSNumber else {
            return value is NSString ? .string : nil
        }
        if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool }
        switch CFNumberGetType(number) {
        case .floatType, .doubleType, .cgFloatType: return .double
        default: return .int
        }
    }

    private static func scalar(_ value: Any?) -> Scalar? {
        switch kind(value) {
        case .bool: .bool((value! as! NSNumber).boolValue)
        case .int: .int((value! as! NSNumber).intValue)
        case .double: .double((value! as! NSNumber).doubleValue)
        case .string: .string(value! as! String)
        case nil: nil
        }
    }

    /// A native UID is opaque to Swift; its integer is exposed in reflection
    /// (`MBFileBlob.patchMBFileContents`, which established this pattern).
    private static func uidIndex(_ value: Any?) -> Int? {
        guard let value, !(value is NSNumber), !(value is NSString) else { return nil }
        let reflected = Mirror(reflecting: value).children.first(where: { $0.label == "value" })?.value
        if let number = reflected as? NSNumber { return number.intValue }
        if let unsigned = reflected as? UInt32 { return Int(unsigned) }
        return reflected as? Int
    }

    // MARK: - Archive model

    /// A parsed NSKeyedArchiver binary plist whose containers are mutable, so
    /// an edit can happen in place and be serialized back without rebuilding
    /// the graph (rebuilding would break the UID aliasing the format carries).
    private final class PosterArchive {
        enum Slot {
            /// A plain-dictionary field.  `uidIndex` is set when the entry is a
            /// UID reference, in which case the edit replaces the referenced
            /// `$objects` slot (the documented deviation above).
            case dictionary(NSMutableDictionary, String, uidIndex: Int?)
            /// A color-variant string held directly in an `NS.objects` array
            /// (`archive_editor.fields`' `("clear", "dark", …)` branch).  The
            /// reference overwrites the array slot with the raw string.
            case array(NSMutableArray, Int)
        }

        struct Field {
            let path: [String]
            let slot: Slot
            let old: Scalar
        }

        let top: NSMutableDictionary
        let objects: NSMutableArray
        let root: Any

        private init(top: NSMutableDictionary, objects: NSMutableArray, root: Any) {
            self.top = top
            self.objects = objects
            self.root = root
        }

        static func open(_ data: Data, expecting: String) throws -> PosterArchive {
            let decoded = try PropertyListSerialization.propertyList(
                from: data, options: [.mutableContainersAndLeaves], format: nil)
            guard let top = decoded as? NSMutableDictionary,
                  let archiver = top["$archiver"] as? String, archiver == "NSKeyedArchiver",
                  let objects = top["$objects"] as? NSMutableArray,
                  let root = (top["$top"] as? NSMutableDictionary)?["root"] else {
                throw GoldenNuggetError("Not an NSKeyedArchiver: \(expecting)")
            }
            return PosterArchive(top: top, objects: objects, root: root)
        }

        /// `NSMutableArray` is not a Swift collection, so index validity is a
        /// count comparison (`0 <= index < count`).
        func containsIndex(_ index: Int) -> Bool {
            index >= 0 && index < objects.count
        }

        func resolve(_ value: Any?) -> Any? {
            guard let index = uidIndex(value) else { return value ?? nil }
            guard containsIndex(index) else { return nil }
            return objects[index]
        }

        /// `archive_editor.fields`: every scalar field this port may edit,
        /// keyed by its dotted path.  Dictionary fields whose `NS.keys` entry
        /// is one of the color-variant names and whose value is a string are
        /// recorded as array slots instead — that is the title/accent color
        /// palette an archive stores as an array of color objects whose
        /// `identifier` strings live inline in `NS.objects`.
        func enumerate() throws -> [String: Field] {
            var result: [String: Field] = [:]
            func visit(_ raw: Any?, _ path: [String], _ seen: Set<Int>) throws {
                var seen = seen
                var value: Any
                if let index = uidIndex(raw) {
                    guard !seen.contains(index) else { return }
                    seen.insert(index)
                    guard containsIndex(index) else {
                        throw GoldenNuggetError("Invalid archive object reference")
                    }
                    value = objects[index] ?? NSObject()
                } else if let raw {
                    value = raw
                } else {
                    return
                }
                guard let object = value as? NSMutableDictionary else { return }
                if let keys = object["NS.keys"] as? NSArray,
                   let values = object["NS.objects"] as? NSMutableArray {
                    guard keys.count == values.count else { return }
                    for index in 0..<keys.count {
                        guard let name = resolve(keys[index]) as? String else { continue }
                        let child = values[index]
                        let childValue = resolve(child)
                        if ["clear", "dark", "default", "accent"].contains(name),
                           kind(childValue) == .string {
                            result[(path + [name]).joined(separator: ".")] = Field(
                                path: path + [name], slot: .array(values, index),
                                old: scalar(childValue)!)
                        } else {
                            try visit(child, path + [name], seen)
                        }
                    }
                    return
                }
                for (key, child) in object {
                    guard let name = key as? String, !name.hasPrefix("$") else { continue }
                    let childValue = resolve(child)
                    if PosterKitOptions.archiveFields.contains(name), let old = scalar(childValue) {
                        let uid = uidIndex(child)
                        result[(path + [name]).joined(separator: ".")] = Field(
                            path: path + [name],
                            slot: .dictionary(object, name, uidIndex: uid),
                            old: old)
                    } else if let childValue, childValue is NSMutableDictionary {
                        try visit(child, path + [name], seen)
                    }
                }
            }
            try visit(root, [], [])
            return result
        }

        /// Writes one change and enforces the type rule `serialize` applies:
        /// the new value's plist kind must equal the old one's, numbers must
        /// be finite, and a UID-referenced entry is edited in its slot.
        func set(_ field: Field, to value: Scalar) throws {
            guard field.old.kind == value.kind else {
                throw GoldenNuggetError("Incorrect value type: \(field.path.joined(separator: "."))")
            }
            if case .double(let number) = value, !number.isFinite {
                throw GoldenNuggetError("Numbers must be finite")
            }
            switch field.slot {
            case .dictionary(let object, let key, let uidIndex):
                if let uidIndex {
                    guard containsIndex(uidIndex) else {
                        throw GoldenNuggetError("Invalid archive object reference")
                    }
                    objects[uidIndex] = value.plistValue
                } else {
                    object[key] = value.plistValue
                }
            case .array(let array, let index):
                array[index] = value.plistValue
            }
        }

        /// `PosterArchive.serialize`: write the tree back as a binary plist and
        /// verify the archive the same way the reference does — re-parse the
        /// output and confirm every edited path still reads back with the
        /// written value and type.
        func serialize(_ changes: [String: Field], values: [String: Scalar]) throws -> Data {
            let output = try PropertyListSerialization.data(
                fromPropertyList: top, format: .binary, options: 0)
            let verified = try PosterArchive.open(output, expecting: "re-serialized archive")
            let fields = try verified.enumerate()
            for (path, _) in changes {
                guard let field = fields[path], let value = values[path],
                      field.old.kind == value.kind, field.old.equals(value) else {
                    throw GoldenNuggetError("Archive field verification failed: \(path)")
                }
            }
            return output
        }

        /// A nested archive (clock material/colorData bytes) stored in an
        /// `$objects` slot: the edit replaces that slot's bytes in place — the
        /// reference appends a fresh object and repoints the UID, which this
        /// port cannot construct (see the type comment).
        func storeNested(_ data: Data, replacing object: NSMutableDictionary, key: String) throws {
            guard let uid = uidIndex(object[key]) else {
                object[key] = data
                return
            }
            guard containsIndex(uid) else {
                throw GoldenNuggetError("Invalid archive object reference")
            }
            objects[uid] = data
        }

        func resolveObject(_ raw: Any, _ expecting: String) throws -> NSMutableDictionary {
            guard let object = resolve(raw) as? NSMutableDictionary else {
                throw GoldenNuggetError(expecting)
            }
            return object
        }

        func referencedBytes(in object: NSMutableDictionary, key: String) throws -> Data {
            let value = resolve(object[key])
            guard let bytes = value as? Data else {
                throw GoldenNuggetError("Unsupported \(key) representation")
            }
            return bytes
        }
    }

    // MARK: - Clock material (`clock_material.py`)

    /// Rewrites the material archive embedded in a PosterKit title style.
    /// `changes` holds `frostLevel` and/or `preferredMaterialType`.
    private static func applyClockMaterial(_ data: Data, changes: [String: Scalar]) throws -> Data {
        let archive = try PosterArchive.open(data, expecting: "keyed clock archive")
        let root = try archive.resolveObject(archive.root, "Expected a keyed clock archive")
        guard root["titleContentStyle"] != nil else {
            throw GoldenNuggetError("This wallpaper has no titleContentStyle archive")
        }
        let nestedBytes = try archive.referencedBytes(in: root, key: "titleContentStyle")
        let nested = try PosterArchive.open(nestedBytes, expecting: "keyed clock material archive")
        let style = try nested.resolveObject(nested.root, "Expected a keyed clock material archive")
        let styleClass = try nested.resolveObject(style["$class"] ?? NSObject(),
                                                   "Clock material style has no class")
        guard let classname = styleClass["$classname"] as? String,
              classname == "PRPosterContentVibrantMaterialStyle" else {
            throw GoldenNuggetError("This wallpaper does not use PRPosterContentVibrantMaterialStyle")
        }
        let fields = try nested.enumerate()
        for (key, rawValue) in changes {
            // `set_clock_material` coerces an integral frost level to the real
            // it stores (`value = float(value)`).
            var value = rawValue
            if key == "frostLevel", case .int(let level) = value {
                value = .double(Double(level))
            }
            guard key == "frostLevel" || key == "preferredMaterialType",
                  let field = fields["\(key)"] else {
                throw GoldenNuggetError("Unsupported clock material field: \(key)")
            }
            switch (key, value) {
            case ("frostLevel", .double(let level)) where level.isFinite && (0...1).contains(level):
                break
            case ("preferredMaterialType", .int(let type)) where type >= 0:
                break
            case ("frostLevel", _):
                throw GoldenNuggetError("Clock frost level must be between 0 and 1")
            default:
                throw GoldenNuggetError("Clock material type must be a nonnegative integer")
            }
            try nested.set(field, to: value)
        }
        let inner = try PropertyListSerialization.data(
            fromPropertyList: nested.top, format: .binary, options: 0)
        try archive.storeNested(inner, replacing: root, key: "titleContentStyle")
        let output = try PropertyListSerialization.data(
            fromPropertyList: archive.top, format: .binary, options: 0)
        // Verify like the reference: the outer archive must re-parse with the
        // nested style holding the written values.
        let verified = try PosterArchive.open(output, expecting: "re-serialized clock archive")
        let verifiedRoot = try verified.resolveObject(verified.root,
                                                      "Re-serialized clock archive lost its root")
        let verifiedNested = try PosterArchive.open(
            try verified.referencedBytes(in: verifiedRoot, key: "titleContentStyle"),
            expecting: "re-serialized clock material archive")
        let verifiedStyle = try verifiedNested.resolveObject(verifiedNested.root,
                                                             "Re-serialized material style")
        let verifiedFields = try verifiedNested.enumerate()
        for (key, value) in changes {
            guard let field = verifiedFields[key], field.old.equals(value) else {
                throw GoldenNuggetError("Clock material serialization failed")
            }
            _ = verifiedStyle // the style object is resolved eagerly for parity with the reference's checks
        }
        return output
    }

    // MARK: - Clock opacity (`clock_opacity.py`)

    /// Rewrites the clock color's alpha, preserving both keyed color
    /// representations: the live `titleColor` and, when present, the archived
    /// `colorData` copy.
    private static func applyClockOpacity(_ data: Data, alpha: Double) throws -> Data {
        guard alpha.isFinite, (0...1).contains(alpha) else {
            throw GoldenNuggetError("Clock opacity must be between 0 and 1.")
        }
        let archive = try PosterArchive.open(data, expecting: "keyed clock/color archive")
        let root = try archive.resolveObject(archive.root, "Expected a keyed clock/color archive")

        func editColor(_ color: NSMutableDictionary) throws {
            guard color["UIAlpha"] != nil else {
                throw GoldenNuggetError("The device clock color has no supported UIAlpha field")
            }
            let existing = archive.resolve(color["UIAlpha"] ?? NSObject())
            guard let kind = kind(existing), kind == .int || kind == .double else {
                throw GoldenNuggetError("Unsupported clock alpha representation")
            }
            if let uid = uidIndex(color["UIAlpha"] ?? NSObject()) {
                guard archive.containsIndex(uid) else {
                    throw GoldenNuggetError("Invalid archive object reference")
                }
                archive.objects[uid] = NSNumber(value: alpha)
            } else {
                color["UIAlpha"] = NSNumber(value: alpha)
            }
            if color["NSWhite"] != nil {
                let white = archive.resolve(color["NSWhite"] ?? NSObject())
                let text: String
                let stored: Any
                switch white {
                case let string as String:
                    text = string
                    stored = string as NSString
                case let bytes as Data:
                    guard let decoded = String(data: bytes, encoding: .ascii) else {
                        throw GoldenNuggetError("Unsupported NSWhite representation")
                    }
                    text = decoded
                    stored = bytes
                default:
                    throw GoldenNuggetError("Unsupported NSWhite representation")
                }
                let components = text.split(separator: " ", omittingEmptySubsequences: true)
                guard components.count == 2 else {
                    throw GoldenNuggetError("Expected white and alpha components in NSWhite")
                }
                let updated = components[0] + " " + String(format: "%.17g", alpha)
                if let uid = uidIndex(color["NSWhite"] ?? NSObject()) {
                    guard archive.containsIndex(uid) else {
                        throw GoldenNuggetError("Invalid archive object reference")
                    }
                    archive.objects[uid] = stored is Data
                        ? Data(updated.utf8)
                        : updated as NSString
                } else if stored is Data {
                    color["NSWhite"] = Data(updated.utf8)
                } else {
                    color["NSWhite"] = updated as NSString
                }
            }
        }

        let title = try archive.resolveObject(root["titleColor"] ?? NSObject(),
                                              "Clock color archive has no titleColor")
        try editColor(try archive.resolveObject(title["color"] ?? NSObject(),
                                                "Clock color has no color object"))
        var hasColorData = false
        if title["colorData"] != nil {
            let wrapper = archive.resolve(title["colorData"] ?? NSObject())
            if let null = wrapper as? NSString, null == "$null" {
                // The archive carries no archived color copy.
            } else if let wrapperObject = wrapper as? NSMutableDictionary {
                guard wrapperObject["NS.data"] != nil else {
                    throw GoldenNuggetError("Unsupported clock colorData representation")
                }
                hasColorData = true
                let nestedBytes = try archive.referencedBytes(in: wrapperObject, key: "NS.data")
                let nested = try PosterArchive.open(nestedBytes,
                                                    expecting: "keyed clock/color archive")
                try editColor(try nested.resolveObject(nested.root,
                                                       "Nested clock color has no color object"))
                let inner = try PropertyListSerialization.data(
                    fromPropertyList: nested.top, format: .binary, options: 0)
                try archive.storeNested(inner, replacing: wrapperObject, key: "NS.data")
            } else {
                throw GoldenNuggetError("Unsupported clock colorData representation")
            }
        }
        let output = try PropertyListSerialization.data(
            fromPropertyList: archive.top, format: .binary, options: 0)

        // `set_clock_opacity`'s verification: the serialized archive must read
        // back with the written alpha in both representations.
        let verified = try PosterArchive.open(output, expecting: "re-serialized clock archive")
        let verifiedRoot = try verified.resolveObject(verified.root,
                                                      "Re-serialized clock archive lost its root")
        let verifiedTitle = try verified.resolveObject(verifiedRoot["titleColor"] ?? NSObject(),
                                                       "Re-serialized clock archive lost titleColor")
        let outerColor = try verified.resolveObject(verifiedTitle["color"] ?? NSObject(),
                                                    "Re-serialized clock color")
        guard scalar(verified.resolve(outerColor["UIAlpha"] ?? NSObject())) == .double(alpha) else {
            throw GoldenNuggetError("Clock opacity archive verification failed")
        }
        if hasColorData {
            let wrapper = try verified.resolveObject(verifiedTitle["colorData"] ?? NSObject(),
                                                     "Re-serialized clock colorData")
            let nested = try PosterArchive.open(
                try verified.referencedBytes(in: wrapper, key: "NS.data"),
                expecting: "re-serialized nested clock archive")
            let innerColor = try nested.resolveObject(nested.root,
                                                      "Re-serialized nested clock color")
            guard scalar(nested.resolve(innerColor["UIAlpha"] ?? NSObject())) == .double(alpha) else {
                throw GoldenNuggetError("Nested clock opacity archive verification failed")
            }
        }
        return output
    }

    // MARK: - Staging (`PosterKitOverrides.stage`)

    /// Turns the selection's `PosterKitOverrides` dictionary into restore
    /// payloads by editing the wallpaper configuration archives the fetched
    /// PosterBoard snapshot carries.
    ///
    /// - Parameters:
    ///   - options: the selection's dictionary (`"Group:path"` → scalar).
    ///   - preservedPayloads: the snapshot's payloads (`PosterBoardBackup`'s
    ///     `Result.preservedPayloads`), each mapping a container-relative path
    ///     to the file the backup wrote.
    /// - Returns: one payload per edited archive, same domain and path, new
    ///   contents.
    static func stage(options: [String: TweakValue],
                      preservedPayloads: [TweakPayload],
                      log: @escaping (String) -> Void) throws -> [TweakPayload] {
        let fieldsByKey = Dictionary(uniqueKeysWithValues:
            PosterKitOptions.all.map { ($0.key, $0) })

        // Validation mirrors `device_overrides.PosterKitOverrides.stage`: only
        // known keys, only the field's own scalar type (an int may ride where
        // the default is a real), editor bounds, font candidates, and a
        // non-empty numbering system.
        var scalarOptions: [String: Scalar] = [:]
        for (key, raw) in options {
            guard let field = fieldsByKey[key], let value = Scalar(from: raw) else {
                throw GoldenNuggetError("Invalid PosterKit setting: \(key)")
            }
            let defaultKind = Scalar(from: field.defaultValue)!.kind
            if !(value.kind == defaultKind
                 || (defaultKind == .double && value.kind == .int)) {
                throw GoldenNuggetError("Invalid PosterKit setting: \(key)")
            }
            if key == "Clock:timeFontConfiguration.timeFontIdentifier",
               case .string(let identifier) = value,
               !PosterKitOptions.clockFontIdentifiers.contains(identifier) {
                throw GoldenNuggetError("Choose a clock font identifier from the available "
                    + "candidates, not a runtime symbol.")
            }
            if case .double(let number) = value, let limits = field.limits {
                if !number.isFinite || number < limits.lower || number > limits.upper {
                    throw GoldenNuggetError("PosterKit value outside allowed editor range: \(key)")
                }
            }
            if case .int(let number) = value, let limits = field.limits {
                if Double(number) < limits.lower || Double(number) > limits.upper {
                    throw GoldenNuggetError("PosterKit value outside allowed editor range: \(key)")
                }
            }
            if key == "Clock:timeNumberingSystem", case .string(let system) = value,
               system.trimmingCharacters(in: .whitespaces).isEmpty || system == "$null" {
                throw GoldenNuggetError("Enter a numbering-system identifier, or uncheck Use "
                    + "for Clock Numbering System.")
            }
            scalarOptions[key] = value
        }
        guard !scalarOptions.isEmpty else { return [] }

        var matched: Set<String> = []
        var payloads: [TweakPayload] = []
        for (group, _) in PosterKitOptions.files.sorted(by: { $0.key < $1.key }) {
            let requested: [(path: [String], key: String, value: Scalar)] =
                scalarOptions.compactMap { key, value in
                    guard key.hasPrefix("\(group):") else { return nil }
                    return (key.dropFirst(group.count + 1).split(separator: ".").map(String.init),
                            key, value)
                }
            if requested.isEmpty { continue }
            for payload in preservedPayloads where matches(payload.relativePath, group: group) {
                guard let source = payload.source else {
                    throw GoldenNuggetError("PosterKit snapshot payload \(payload.relativePath) "
                        + "has no file on disk.")
                }
                let data = try Data(contentsOf: source)
                let archive = try PosterArchive.open(data, expecting: payload.relativePath)
                let available = try archive.enumerate()

                var changes: [String: PosterArchive.Field] = [:]
                var values: [String: Scalar] = [:]
                var opacity: (key: String, value: Scalar)?
                var material: [String: Scalar] = [:]
                for request in requested {
                    if request.path == ["clockOpacity"] {
                        opacity = (request.key, request.value)
                        continue
                    }
                    if request.path.first == "titleContentStyle" {
                        material[request.path.dropFirst().joined(separator: ".")] = request.value
                        continue
                    }
                    let path = request.path.joined(separator: ".")
                    guard let field = available[path] else { continue }
                    // The reference coerces a numeric edit to the field's own
                    // representation: an int field takes an integral real, a
                    // real field takes an int; anything else keeps the kind.
                    var value = request.value
                    if field.old.kind == .int, case .double(let number) = value,
                       number.isFinite, number == number.rounded(.towardZero) {
                        value = .int(Int(number))
                    } else if field.old.kind == .double, case .int(let number) = value {
                        value = .double(Double(number))
                    }
                    changes[path] = field
                    values[path] = value
                    matched.insert(request.key)
                }
                if changes.isEmpty && opacity == nil && material.isEmpty { continue }
                var contents = try archive.serialize(changes, values: values)
                if !material.isEmpty {
                    contents = try applyClockMaterial(contents, changes: material)
                    for key in material.keys {
                        matched.insert("Clock:titleContentStyle.\(key)")
                    }
                    log("PosterKit clock material \(payload.relativePath): \(material.keys.sorted())")
                }
                if let opacity {
                    guard case .double(let alpha) = opacity.value else {
                        throw GoldenNuggetError("Invalid PosterKit setting: \(opacity.key)")
                    }
                    contents = try applyClockOpacity(contents, alpha: alpha)
                    matched.insert(opacity.key)
                    log("PosterKit clock opacity \(payload.relativePath) = \(alpha) "
                        + "(outer and nested color archives)")
                }
                log("PosterKit staging \(payload.relativePath): "
                    + values.keys.sorted().joined(separator: ", "))
                payloads.append(TweakPayload(domain: payload.domain,
                                             relativePath: payload.relativePath,
                                             contents: contents))
            }
        }
        let missing = Set(scalarOptions.keys).subtracting(matched).sorted()
        if !missing.isEmpty {
            throw GoldenNuggetError("Selected PosterKit fields were absent from the device "
                + "backup: " + missing.joined(separator: ", "))
        }
        log("PosterKit staged \(payloads.count) binary archive(s)")
        return payloads
    }

    /// Which snapshot payload an archive group edits.  The reference matches a
    /// regular expression over the container path
    /// (`/configurations/<store>/versions/<version>/[supplements/<n>/]<file>`);
    /// this port checks the same shape component-wise, anchored after the
    /// store-directory marker, which is the only place the device writes it.
    private static func matches(_ relativePath: String, group: String) -> Bool {
        let marker = "Library/Application Support/PRBPosterExtensionDataStore/"
        guard let markerRange = relativePath.range(of: marker) else { return false }
        guard let suffix = PosterKitOptions.files[group]?.split(separator: "/").last else {
            return false
        }
        var parts = relativePath[markerRange.upperBound...]
            .split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 4,
              parts[0] == "configurations",
              parts[2] == "versions" else { return false }
        parts.removeFirst(4)
        if group == "Home Screen" {
            guard parts.count >= 2, parts[0] == "supplements" else { return false }
            parts.removeFirst(2)
        }
        return parts.count == 1 && parts[0] == suffix
    }
}
