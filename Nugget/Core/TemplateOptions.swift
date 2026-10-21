import Foundation

/// One user-configurable step of a `.batter` template.
///
/// A port of `src/tweaks/posterboard/template_options/`.  The five kinds are
/// the reference's `OptionType`: `replace`, `remove`, `set`, `picker` and
/// `bundle_id` — the last of which is not an option object at all but a flag on
/// the template, so it becomes `TemplateFile.canChangeBundleID` rather than a
/// value here.
///
/// Every option's `apply(containerPath:)` runs against the **parent of
/// `config.json`**, on the extracted tree, before anything is delivered.  That
/// ordering is the whole design: a template's files are edited in place and the
/// result is what reaches the device, so a `set` that changes a colour and a
/// `remove` that deletes a layer compose the same way they do upstream.
protocol TemplateOption {
    var kind: TemplateOptionKind { get }
    /// The text the reference puts on the control.
    var label: String { get }
    /// The paths this option acts on, relative to the config's parent.  Globs
    /// allowed — the reference runs each through `glob.glob(..., recursive=True)`
    /// at apply time, and so does `TemplateGlob.match` here.
    var files: [String] { get }
    /// The preview this option shows or hides, when the template names one.
    var associatedPreview: String? { get }
    /// Rewrite the extracted tree.
    func apply(containerPath: URL) throws
}

/// The five option types.  Raw values are the strings in `config.json`.
enum TemplateOptionKind: String {
    case replace
    case remove
    case set
    case picker
    case bundleID = "bundle_id"
}

/// The four fields every option reads from its config entry.
///
/// A base struct rather than a protocol extension assigning `let`s: each
/// concrete option has its **own** stored `label` / `files` / … properties, and
/// an extension initialiser cannot assign those — a protocol extension `init`
/// only has access to the protocol's own requirements, which is why the first
/// version of this could not compile.
struct TemplateOptionFields {
    let kind: TemplateOptionKind
    let label: String
    let files: [String]
    let associatedPreview: String?

    /// - Parameter kind: the option's type, which also decides whether `files`
    ///   is required: a `picker` has no top-level `files` (its per-choice lists
    ///   live in `options`), which is the one exception the reference carves out.
    init(_ data: [String: Any], kind: TemplateOptionKind, jsonPath: String) throws {
        guard let label = data["label"] as? String else {
            throw TemplateFile.fail("An option in \(jsonPath) has no \"label\".")
        }
        self.kind = kind
        self.label = label
        if kind == .picker {
            self.files = []
        } else {
            guard let files = data["files"] as? [String] else {
                throw TemplateFile.fail("The \(kind.rawValue) option \"\(label)\" in \(jsonPath) "
                    + "has no \"files\" list.")
            }
            guard files.allSatisfy({ TemplatePath.isSafe($0, allowLeadingSlash: true) }) else {
                throw TemplateFile.fail("An option in \(jsonPath) has an unsafe file path.")
            }
            self.files = files
        }
        self.associatedPreview = data["associated_preview"] as? String
    }
}

extension TemplateOption {
    /// The paths this option's `files` resolve to, in a stable order.
    func resolve(_ containerPath: URL) -> [URL] {
        var out: [URL] = []
        for pattern in files {
            out += TemplateGlob.match(pattern, under: containerPath)
        }
        return out
    }
}

// MARK: - replace

/// `replace_option.py`: the user picks a file, and its bytes are written over
/// every path in `files`.
///
/// The same bytes for every target, which is what makes it a "background image
/// for all three variants" control rather than a per-target one.
struct ReplaceOption: TemplateOption {
    let kind: TemplateOptionKind
    let label: String
    let files: [String]
    let associatedPreview: String?

    /// The Qt name filter from the config, shown on the button.  There is no
    /// portable equivalent to parse `"Image Files (*.png)"` into UTType, so it
    /// is **carried through verbatim** and the picker filters on
    /// `allowedContentTypes` derived from the extensions it names.
    let allowedFiles: String
    let buttonLabel: String
    /// Whether the apply fails when nothing was picked.  The reference raises
    /// `NuggetException` from `apply`, so this throws too.
    let required: Bool

    /// The file the user picked, copied into the app's container.
    var value: URL?

    init(data: [String: Any], jsonPath: String) throws {
        let base = try TemplateOptionFields(data, kind: .replace, jsonPath: jsonPath)
        self.kind = base.kind
        self.label = base.label
        self.files = base.files
        self.associatedPreview = base.associatedPreview
        guard let allowed = data["allowed_files"] as? String else {
            throw TemplateFile.fail("The replace option \"\(label)\" in \(jsonPath) has no "
                + "\"allowed_files\".")
        }
        self.allowedFiles = allowed
        // The reference's fallback button text is the filter itself; kept,
        // because it is what a user of the desktop build has read before.
        self.buttonLabel = (data["button_label"] as? String) ?? "Import \(allowed)"
        self.required = (data["required"] as? Bool) ?? false
    }

    /// The extensions the filter names, for the document picker.
    ///
    /// Parsed out of the Qt filter's `(...)` group.  An empty result means "no
    /// filter", which is also what a filter with no extension in it means — and
    /// it is the honest outcome for `"All Files (*) ()"`.
    var allowedExtensions: [String] {
        guard let open = allowedFiles.firstIndex(of: "("),
              let close = allowedFiles[allowedFiles.index(after: open)...].firstIndex(of: ")"),
              close > open else { return [] }
        let inside = allowedFiles[allowedFiles.index(after: open)..<close]
        return inside.split(separator: " ").compactMap { token -> String? in
            let text = String(token)
            guard text.hasPrefix("*."), text.count > 2 else { return nil }
            return String(text.dropFirst(2)).lowercased()
        }
    }

    func apply(containerPath: URL) throws {
        guard let value else {
            if required {
                throw TemplateFile.fail("This template cannot be applied yet: no file was chosen "
                    + "for \"\(label)\".")
            }
            // Not required and nothing chosen: the target keeps the bytes the
            // template shipped, which is the reference's early `return`.
            return
        }
        let contents: Data
        do {
            contents = try Data(contentsOf: value)
        } catch {
            throw TemplateFile.fail("The file chosen for \"\(label)\" could not be read "
                + "(\(value.lastPathComponent)): \(error.localizedDescription)")
        }
        for target in resolve(containerPath) {
            do {
                try contents.write(to: target, options: .atomic)
            } catch {
                throw TemplateFile.fail("Could not write \(target.lastPathComponent) for "
                    + "\"\(label)\": \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - remove

/// `remove_option.py`: delete files or directories, or delete an XML element by
/// identifier.
///
/// The `inverted` flag is what makes this a checkbox rather than a switch: it
/// flips the sense, so "Show Object" checked means the element **stays**.
struct RemoveOption: TemplateOption {
    let kind: TemplateOptionKind
    let label: String
    let files: [String]
    let associatedPreview: String?

    let inverted: Bool
    /// When set, the target is an XML element rather than a file.
    let identifier: String?
    let useCAID: Bool
    /// The checkbox's initial state.  `false` unless the config says otherwise.
    var value: Bool

    init(data: [String: Any], jsonPath: String) throws {
        let base = try TemplateOptionFields(data, kind: .remove, jsonPath: jsonPath)
        self.kind = base.kind
        self.label = base.label
        self.files = base.files
        self.associatedPreview = base.associatedPreview
        self.inverted = (data["inverted"] as? Bool) ?? false
        self.identifier = data["identifier"] as? String
        self.useCAID = (data["use_ca_id"] as? Bool) ?? false
        self.value = (data["default_value"] as? Bool) ?? false
    }

    /// Whether the targets are deleted, given the checkbox.
    ///
    /// `remove_option.apply`'s condition, verbatim: delete when
    /// `(inverted and not value) or (not inverted and value)`.  Both option
    /// kinds use this same pair of words — `update_preview` and `apply` — so it
    /// is stated once here and both use it.
    var deletes: Bool {
        (inverted && !value) || (!inverted && value)
    }

    func apply(containerPath: URL) throws {
        guard deletes else { return }
        let fm = FileManager.default
        for target in resolve(containerPath) {
            if let identifier {
                // The reference's own TODO — "make sure it isn't a directory" —
                // is still open there, and it is harmless here for the same
                // reason it is harmless there: an identifier only matches inside
                // a document, and a directory is not one.
                guard let data = try? Data(contentsOf: target) else { continue }
                do {
                    let edited = try TemplateXML.deleteValue(in: data, id: identifier,
                                                             useCAID: useCAID)
                    try edited.write(to: target, options: .atomic)
                } catch {
                    throw TemplateFile.fail("\(target.lastPathComponent) carries the identifier "
                        + "\"\(identifier)\" but could not be edited: \(error.localizedDescription)")
                }
                continue
            }
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: target.path, isDirectory: &isDirectory) else { continue }
            do {
                // `rmtree(..., ignore_errors=True)` for a directory and
                // `os.remove` for a file.  The directory case is the tolerant
                // one and the file case is not, and that difference is kept:
                // silently ignoring a directory that cannot go is the
                // reference's choice, while a file it cannot delete is an error
                // worth surfacing.
                if isDirectory.boolValue {
                    try fm.removeItem(at: target)
                } else {
                    try fm.removeItem(at: target)
                }
            } catch {
                throw TemplateFile.fail("Could not remove \(target.lastPathComponent) for "
                    + "\"\(label)\": \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - set

/// `set_option.py`: write a value into a `.caml` attribute, a plist key, or a
/// text file.
///
/// The most intricate of the five, because of `split_value` / `convert_float` /
/// `convert_back`.
///
/// **What the value is.**  A `set` option's default, bounds and step are written
/// the way they appear in a `.caml`: `"1.0 0.5 1"`, `"scale(0 0 0)"`,
/// `"20"`.  `split_value` pulls the tag out of `scale(…)`, splits on spaces, and
/// converts each part — and for a `color_picker` it turns the parts into a
/// colour instead, with a fourth part meaning alpha.  `convert_back` is the
/// inverse, and it is what makes the round trip lossless: a value the user did
/// not touch comes back out spelled the way it went in.
///
/// **Why floats scale by 1000.**  `convert_float` multiplies by 1000 and
/// `update_value` divides by 1000, because a `QSlider` is an integer widget: a
/// scale from 0 to 1 would have one position.  Reproduced, because the rounding
/// is observable in what lands in the file.
struct SetOption: TemplateOption {
    let kind: TemplateOptionKind
    let label: String
    let files: [String]
    let associatedPreview: String?

    /// `nuggetId` (or the CoreAnimation `id` with `useCAID`).
    let identifier: String
    /// The attribute or plist key to write.
    let key: String
    let setter: SetterType
    let useCAID: Bool

    /// `"integer"` / `"float"` / `"string"`.  The reference reads this as a bare
    /// string and its default is "integer"; `"float"` is the only value that
    /// changes behaviour (it enables the ×1000 slider scaling and the float
    /// parsing in `convert_str`).
    let valueType: String

    let minValue: [Double]?
    let maxValue: [Double]?
    let step: [Double]
    var usesOpacity: Bool

    let inverted: Bool
    let toggleOffValue: TemplateValue?
    let toggleOnValue: TemplateValue?

    /// The current value.  One element per slider component; the reference's own
    /// value is a bare number when it is single and a list when it is not, and
    /// the list-ness is decided by the *default*, not by the type.
    var value: [Double]
    /// The raw text, for a `textbox`.
    var text: String
    /// The chosen colour, 0–1 per component plus alpha 0–1.
    ///
    /// Alpha is **not** 0–255: the reference's `QColor` carries 0–255 while its
    /// `.alphaF()` — which is what `sets_opacity` writes into the caml — is
    /// 0–1, and keeping one scale here is what stops the two from disagreeing.
    var color: (r: Double, g: Double, b: Double, a: Double)

    /// The reference's tag carried out of `scale(0 0 0)`, written back in
    /// `convert_back`.
    var valueTag: String?

    enum SetterType: String {
        case textbox
        case slider
        case toggle
        case colorPicker = "color_picker"
    }

    init(data: [String: Any], jsonPath: String) throws {
        let base = try TemplateOptionFields(data, kind: .set, jsonPath: jsonPath)
        self.kind = base.kind
        self.label = base.label
        self.files = base.files
        self.associatedPreview = base.associatedPreview
        guard let identifier = data["identifier"] as? String else {
            throw TemplateFile.fail("The set option \"\(label)\" in \(jsonPath) has no "
                + "\"identifier\" — that is the nuggetId of the element to change.")
        }
        self.identifier = identifier
        guard let key = data["key"] as? String else {
            throw TemplateFile.fail("The set option \"\(label)\" in \(jsonPath) has no \"key\".")
        }
        self.key = key
        guard let setterName = data["setter_type"] as? String,
              let setter = SetterType(rawValue: setterName) else {
            throw TemplateFile.fail("The set option \"\(label)\" in \(jsonPath) needs a "
                + "\"setter_type\" of textbox, slider, toggle or color_picker.")
        }
        self.setter = setter
        self.useCAID = (data["use_ca_id"] as? Bool) ?? false
        self.valueType = (data["value_type"] as? String) ?? "integer"
        self.inverted = (data["inverted"] as? Bool) ?? false
        self.toggleOffValue = data["toggle_off_value"].map { TemplateValue(json: $0) }
        self.toggleOnValue = data["toggle_on_value"].map { TemplateValue(json: $0) }

        // Bounds. A slider requires both; the others take them if given, and the
        // reference's own fallbacks are the ones reproduced here.
        let rawMin = SetOption.numbers(data["min_value"])
        let rawMax = SetOption.numbers(data["max_value"])
        let rawStep = SetOption.numbers(data["step"]) ?? [1]
        guard setter != .slider || (rawMin != nil && rawMax != nil) else {
            throw TemplateFile.fail("The slider option \"\(label)\" in \(jsonPath) needs both a "
                + "\"min_value\" and a \"max_value\".")
        }
        self.minValue = rawMin
        self.maxValue = rawMax
        self.step = rawStep.isEmpty ? [1] : rawStep
        // A `color_picker` whose default carries four components *is* the
        // "include opacity" flag — the reference infers it in `split_value`.
        self.usesOpacity = (data["sets_opacity"] as? Bool) ?? false

        // The starting value, and how it was spelled.
        let rawDefault = data["default_value"]
        if setter == .colorPicker {
            let parts = SetOption.scalars(rawDefault).map { SetOption.color(from: $0) }
            let alpha = parts.count >= 4 ? parts[3] : 1
            self.color = (r: parts.first ?? 0, g: parts.count > 1 ? parts[1] : 0,
                          b: parts.count > 2 ? parts[2] : 0, a: alpha)
            if parts.count >= 4 { self.usesOpacity = true }
            self.value = []
            self.text = ""
        } else if setter == .toggle {
            self.value = [(rawDefault as? Bool).map { $0 ? 1 : 0 } ?? 0]
            self.text = (rawDefault as? Bool).map { $0 ? "1" : "0" } ?? "0"
            self.color = (0, 0, 0, 1)
        } else {
            let parts = SetOption.scalars(rawDefault)
            if parts.isEmpty {
                // The reference's own cascade: a toggle is false, otherwise the
                // minimum if there is one, otherwise the maximum.
                if let min = rawMin?.first ?? rawMin.map({ $0.first ?? 0 }) {
                    self.value = [min]
                } else if let max = rawMax?.first ?? rawMax.map({ $0.first ?? 0 }) {
                    self.value = [max]
                } else {
                    self.value = [0]
                }
            } else {
                self.value = parts
            }
            self.text = parts.map { TemplateValue.number($0) }.joined(separator: " ")
            self.color = (0, 0, 0, 1)
        }
        // The tag out of `scale(0 0 0)`, and the opacity inference for a colour.
        if let raw = rawDefault {
            if let text = raw as? String, text.contains("("), text.contains(")") {
                self.valueTag = String(text[text.startIndex..<text.firstIndex(of: "(")!])
            }
        }
    }

    /// `convert_str`'s number list: a string is split on spaces, a bare number is
    /// one component.
    private static func scalars(_ value: Any?) -> [Double] {
        guard let value else { return [] }
        if let number = value as? Double { return [number] }
        if let number = value as? Int { return [Double(number)] }
        if let text = value as? String {
            return text.split(separator: " ").compactMap { Double($0) }
        }
        if let list = value as? [Any] {
            return list.flatMap { scalars($0) }
        }
        return []
    }

    /// The same, keeping the array-vs-scalar distinction the bounds need.
    private static func numbers(_ value: Any?) -> [Double]? {
        guard let value else { return nil }
        if let number = value as? Double { return [number] }
        if let number = value as? Int { return [Double(number)] }
        if let text = value as? String {
            let parts = text.split(separator: " ").compactMap { Double($0) }
            return parts.isEmpty ? nil : parts
        }
        if let list = value as? [Any] {
            let flat = list.flatMap { scalars($0) }
            return flat.isEmpty ? nil : flat
        }
        return nil
    }

    /// `convert_color`: `round(min(1, value) * 255)`, scaled back to 0–1.
    ///
    /// `round` here is **Python's**, which is banker's rounding — it goes to the
    /// nearest *even* integer on a tie.  That is not pedantry: it decides the
    /// 8-bit channel a component lands on, and therefore the exact float the
    /// `.caml` ends up carrying.  `0.5 * 255 = 127.5` is a tie, and Python gives
    /// `128`; a tie like `62.5` gives `62`, where a half-away-from-zero rounding
    /// would give `63`.  Swift's `.rounded()` is half-away-from-zero, so the
    /// tie rule is spelled out here.
    private static func color(from scalar: Double) -> Double {
        let scaled = Swift.min(1, scalar) * 255
        let floor = scaled.rounded(.down)
        let fraction = scaled - floor
        let rounded: Double
        if fraction > 0.5 {
            rounded = floor + 1
        } else if fraction < 0.5 {
            rounded = floor
        } else {
            rounded = floor.truncatingRemainder(dividingBy: 2) == 0 ? floor : floor + 1
        }
        return rounded / 255
    }

    // MARK: The slider's ×1000

    /// `convert_float`, for display.
    func scaled(_ value: Double) -> Double {
        valueType == "float" ? value * 1000 : value
    }

    func unscaled(_ value: Double) -> Double {
        valueType == "float" ? value / 1000 : value
    }

    /// `correct_slider_pos`: snap to the nearest multiple of `step`, then clamp.
    ///
    /// `pos % step < step/2` goes down, else up — the reference's own rule, and
    /// it is a rounding rule rather than a "round to nearest" one at the
    /// boundary.
    func correctedSliderPosition(_ position: Double, index: Int) -> Double {
        let stepValue = step.count > 1 ? (step[index]) : step[0]
        guard stepValue > 0 else { return position }
        let remainder = position.truncatingRemainder(dividingBy: stepValue)
        var result = position
        if remainder != 0 {
            if remainder < stepValue / 2 {
                result -= remainder
            } else {
                result += (stepValue - remainder)
            }
            let lower = minValue.map { $0.count > 1 ? $0[index] : $0[0] } ?? -.infinity
            let upper = maxValue.map { $0.count > 1 ? $0[index] : $0[0] } ?? .infinity
            if result < lower { result = lower }
            if result > upper { result = upper }
        }
        return result
    }

    /// Set slider component `index`, snapping and converting like `update_value`.
    mutating func setSliderValue(_ position: Double, index: Int) {
        var corrected = correctedSliderPosition(position, index: index)
        corrected = unscaled(corrected)
        if index < value.count { value[index] = corrected } else { value.append(corrected) }
        text = value.map { TemplateValue.number($0) }.joined(separator: " ")
    }

    // MARK: The value as it is written

    /// `convert_back`, for the numeric and text paths: the components joined by
    /// spaces, with the tag re-attached.
    private var numericBack: String {
        var joined = value.map { TemplateValue.number($0) }.joined(separator: " ")
        if let valueTag { joined = "\(valueTag)(\(joined))" }
        return joined
    }

    /// The colour as three `0–1` components.
    ///
    /// **Never the alpha.**  `convert_back` returns
    /// `[redF(), greenF(), blueF()]` for a `QColor` and stops there; the alpha
    /// leaves by a different door, as the second key of the same
    /// `set_xml_values` call (`keys=[key, "opacity"]`).  Putting alpha into the
    /// colour string as a fourth component would give a `caml` a five-number
    /// attribute where the reference writes three — and a `colorspace` the
    /// device reads differently.
    private var colorBack: [String] {
        [
            TemplateValue.float(color.r), TemplateValue.float(color.g),
            TemplateValue.float(color.b),
        ]
    }

    func apply(containerPath: URL) throws {
        switch setter {
        case .toggle:
            // The reference's `apply` prologue: invert, then substitute the
            // on/off values for a non-boolean one.
            var on = value.first ?? 0 != 0
            if inverted { on.toggle() }
            let applied: TemplateValue = {
                if on, let toggleOnValue { return toggleOnValue }
                if !on, let toggleOffValue { return toggleOffValue }
                return .bool(on)
            }()
            try write(applied, containerPath: containerPath)

        case .colorPicker:
            // `sets_opacity` writes the colour **and** the alpha as a second
            // key on the same element, which is why it is the only branch that
            // passes two keys.
            try write(.string(colorBack.joined(separator: " ")), containerPath: containerPath,
                      extraKey: usesOpacity ? "opacity" : nil,
                      // `str(self.value.alphaF())` — a float, so `0.25` in the
                      // config comes out as `0.25098039215686274`, which is the
                      // 8-bit alpha the `QColor` holds divided by 255.
                      extraValue: usesOpacity ? TemplateValue.float(color.a) : nil)

        case .slider, .textbox:
            try write(.string(numericBack), containerPath: containerPath)
        }
    }

    /// The one write, shared by every setter: a `.caml`/`.xml` element by
    /// identifier, a plist key, or a plain-text substitution.
    /// - Parameter written: what lands in the file, already spelled the way the
    ///   reference spells it (`str(value)`), and carried as a `TemplateValue` so
    ///   the plist branch can keep the **type** — a toggle's `True` is a bool in
    ///   a plist and the text `True` in a caml, and the same `TemplateValue`
    ///   produces both.
    private func write(_ written: TemplateValue,
                       containerPath: URL,
                       extraKey: String? = nil,
                       extraValue: String? = nil) throws {
        for target in resolve(containerPath) {
            let name = target.lastPathComponent
            if name.hasSuffix(".caml") || name.hasSuffix(".xml") {
                let data: Data
                do {
                    data = try Data(contentsOf: target)
                } catch {
                    throw TemplateFile.fail("\(name) could not be read for \"\(label)\": "
                        + error.localizedDescription)
                }
                let keys = extraKey.map { [key, $0] } ?? [key]
                let values = extraValue.map { [written.display, $0] } ?? [written.display]
                do {
                    let edited = try TemplateXML.setValues(in: data, id: identifier,
                                                           keys: keys, values: values,
                                                           useCAID: useCAID)
                    try edited.write(to: target, options: .atomic)
                } catch {
                    throw TemplateFile.fail("\(name) carries the identifier \"\(identifier)\" "
                        + "but could not be edited: \(error.localizedDescription)")
                }
            } else if name.hasSuffix(".plist") {
                // `write_plist_value(file, key, value)`, recursive by default:
                // the key is replaced wherever it already appears, at any depth.
                do {
                    let edited = try PosterBoardPlist.set(contentsOf: target, key: key,
                                                          value: written.plistValue, recursive: true)
                    try edited.write(to: target, options: .atomic)
                } catch {
                    throw TemplateFile.fail("\(name) could not be edited for \"\(label)\": "
                        + error.localizedDescription)
                }
            } else {
                // Plain text: the reference does `contents.replace(self.key,
                // str(apply_val))` — it replaces the **key** with the value, not
                // a value of the key.  That reads like a mistake and is kept
                // verbatim: a template that ships a text file relying on it has
                // a file whose contents are the substituted token, and a port
                // that "fixed" it would deliver something else.
                guard let data = try? Data(contentsOf: target),
                      let contents = String(data: data, encoding: .utf8) else { continue }
                let replaced = contents.replacingOccurrences(of: key, with: written.display)
                try Data(replaced.utf8).write(to: target, options: .atomic)
            }
        }
    }
}

// MARK: - picker

/// `picker_option.py`: choose one of several file sets; the others are deleted.
///
/// The mechanism that makes a template ship variants: three `background.ca`
/// files under three names, and the option renames the chosen one over the
/// canonical name the template expects.  Everything not chosen is removed, so
/// only the selected variant is delivered.
struct PickerOption: TemplateOption {
    let kind: TemplateOptionKind
    let label: String
    let files: [String]
    let associatedPreview: String?

    struct Choice {
        let label: String
        let files: [String]
        let associatedPreview: String?
    }

    let choices: [Choice]
    let allowMultipleSelection: Bool
    /// Rename the chosen files to `names`.  Only meaningful single-selection —
    /// the reference says so and does not enforce it beyond ignoring `names`.
    let renames: Bool
    let names: [String]

    /// The chosen indices.  A `Set`, because multi-selection is a set; the
    /// reference's `selection` is a list of labels there and an int here.
    var selection: Set<Int>
    /// The indices the config asked to start on.
    let defaults: Set<Int>

    init(data: [String: Any], jsonPath: String) throws {
        let base = try TemplateOptionFields(data, kind: .picker, jsonPath: jsonPath)
        self.kind = base.kind
        self.label = base.label
        self.files = base.files
        self.associatedPreview = base.associatedPreview
        guard let rawChoices = data["options"] as? [[String: Any]], !rawChoices.isEmpty else {
            throw TemplateFile.fail("The picker option \"\(label)\" in \(jsonPath) needs a "
                + "non-empty \"options\" list.")
        }
        // Built in a local and assigned after, because a closure that mentions
        // `self` at all — even to read `self.label` in an error message — is a
        // capture of a half-initialised `self`, which Swift rejects.  The local
        // carries the label instead.
        let optionLabel = label
        let parsedChoices = try rawChoices.enumerated().map { index, choice in
            guard let choiceLabel = choice["label"] as? String else {
                throw TemplateFile.fail("Choice \(index) of the picker \"\(optionLabel)\" in "
                    + "\(jsonPath) has no \"label\".")
            }
            let files = (choice["files"] as? [String]) ?? []
            guard files.allSatisfy({ TemplatePath.isSafe($0, allowLeadingSlash: true) }) else {
                throw TemplateFile.fail("The picker in \(jsonPath) has an unsafe file path.")
            }
            return Choice(label: choiceLabel,
                          files: files,
                          associatedPreview: choice["associated_preview"] as? String)
        }
        self.choices = parsedChoices
        self.allowMultipleSelection = (data["allow_multiple_selection"] as? Bool) ?? false
        self.renames = (data["rename"] as? Bool) ?? false
        if renames {
            guard let names = data["names"] as? [String] else {
                throw TemplateFile.fail("The picker option \"\(label)\" in \(jsonPath) sets "
                    + "\"rename\" but has no \"names\" list to rename to.")
            }
            guard names.allSatisfy({ TemplatePath.isSafe($0) }) else {
                throw TemplateFile.fail("The picker in \(jsonPath) has an unsafe rename destination.")
            }
            self.names = names
        } else {
            self.names = []
        }

        var defaults: Set<Int> = []
        if allowMultipleSelection {
            if let list = data["default_values"] as? [Any] {
                for entry in list {
                    if let index = TemplateFile.integer(entry) { defaults.insert(index) }
                }
            }
        }
        if let single = data["default_value"], let index = TemplateFile.integer(single) {
            defaults = [index]
        }
        self.defaults = defaults
        // An empty or out-of-range default selects the first choice, which is
        // what a `QComboBox` with `setCurrentIndex(0)` shows.  A `default_value`
        // past the end is clamped rather than refused: the reference would raise
        // `IndexError` from the combo box, and a template that names a choice
        // which does not exist is not worth failing an import over.
        //
        // `self.choices` is read here on purpose — after it is assigned — so
        // the clamp is against the choices that actually parsed.
        let available = self.choices.count
        if defaults.isEmpty {
            self.selection = [0]
        } else {
            self.selection = Set(defaults.filter { $0 >= 0 && $0 < available })
            if self.selection.isEmpty { self.selection = [0] }
        }
    }

    func apply(containerPath: URL) throws {
        let fm = FileManager.default
        // Delete everything not chosen.  `remove_option`'s tolerance for a
        // directory that will not go is kept here too, since this is the same
        // delete-everything-else shape.
        for (index, choice) in choices.enumerated() where !selection.contains(index) {
            for pattern in choice.files {
                for target in TemplateGlob.match(pattern, under: containerPath) {
                    try? fm.removeItem(at: target)
                }
            }
        }
        guard renames, let chosen = selection.sorted().first, chosen < choices.count else { return }
        let chosenFiles = choices[chosen].files
        // The reference indexes `names[i]` by the chosen option's own file index,
        // with no length check — a `names` list shorter than `files` raises
        // `IndexError`.  Here it is a refusal naming both lengths, because a
        // partial rename would deliver a template with the wrong file names and
        // no error at all.
        guard names.count >= chosenFiles.count else {
            throw TemplateFile.fail("The picker \"\(label)\" renames \(chosenFiles.count) file(s) "
                + "but only names \(names.count).")
        }
        for (index, pattern) in chosenFiles.enumerated() {
            for target in TemplateGlob.match(pattern, under: containerPath) {
                guard let destination = TemplatePath.destination(names[index], under: containerPath) else {
                    throw TemplateFile.fail("Unsafe picker rename destination: \(names[index])")
                }
                if target.standardizedFileURL == destination.standardizedFileURL { continue }
                try? fm.removeItem(at: destination)
                do {
                    try fm.moveItem(at: target, to: destination)
                } catch {
                    throw TemplateFile.fail("Could not rename \(target.lastPathComponent) to "
                        + "\(names[index]) for \"\(label)\": \(error.localizedDescription)")
                }
            }
        }
    }
}

// MARK: - The value type a template writes

/// A value as `config.json` spells it.
///
/// `JSONSerialization` has already collapsed JSON's own types by the time this
/// sees them — `true` and `1` are indistinguishable — which is exactly the
/// ambiguity the reference has too, since it reads the same JSON.  What differs
/// is which plist type each is written as, so that is stated here rather than
/// inferred later.
enum TemplateValue {
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)

    init(json: Any) {
        switch json {
        case let value as Bool: self = .bool(value)
        case let value as Int: self = .int(value)
        case let value as Double:
            // `NSNumber` hands back a `Double` for `1` as well, and the
            // reference writes `1` back as `1`.  An integral double is written
            // as an integer so a plist key does not change type under the user.
            self = value == value.rounded() && abs(value) < 1e15 ? .int(Int(value)) : .double(value)
        case let value as String: self = .string(value)
        default: self = .string(String(describing: json))
        }
    }

    /// What `PropertyListSerialization` should be handed.
    var plistValue: Any {
        switch self {
        case .bool(let value): return value
        case .int(let value): return value
        case .double(let value): return value
        case .string(let value): return value
        }
    }

    /// The spelling that goes into a `.caml` attribute or a text file.
    ///
    /// **A bool is `1` / `0`, not `True` / `False`.**  That is not a choice:
    /// `xml_handler.set_xml_values` opens with
    /// `if isinstance(values[i], bool): values[i] = int(values[i])`, so every
    /// bool it writes into a `.caml` has already been turned into an integer by
    /// the time it is stringified.  `True` would be an attribute CoreAnimation
    /// cannot read as a flag.
    ///
    /// The **plist** path does not go through here — it takes `plistValue`,
    /// which keeps the type, so a toggle stays a real bool in the plist.  That
    /// split is the reference's and is reproduced rather than tidied.
    var display: String {
        switch self {
        case .bool(let value): return value ? "1" : "0"
        case .int(let value): return String(value)
        case .double(let value): return TemplateValue.number(value)
        case .string(let value): return value
        }
    }

    /// `str(float)`: the shortest spelling that reads back as the same double,
    /// which is what Python's `repr` gives and therefore what an offset or a
    /// colour component in a `.caml` was written against.
    ///
    /// **Integral values keep their integral spelling.**  The reference's
    /// `convert_str` parses `"195 365"` as two `int`s (its `value_type` defaults
    /// to integer), `convert_back` runs `str()` over them, and Python prints
    /// `str(195)` as `195`.  Printing `195.0` instead would make every template
    /// that sets a position rewrite it as a float — different bytes in the
    /// `.caml`, and a diff that shows a change the template never asked for.
    static func number(_ value: Double) -> String {
        if value == value.rounded() && abs(value) < 1e15 {
            return String(Int64(value))
        }
        return "\(value)"
    }

    /// `str()` on a genuine Python **float**, which is a different spelling from
    /// `number` for integral values: `str(1.0)` is `1.0`, not `1`.
    ///
    /// This is the one the colour components need, and it is not cosmetic.
    /// `convert_back` returns `[str(value.redF()), str(value.greenF()),
    /// str(value.blueF())]` — `redF()` and friends are always floats, so a pure
    /// red writes `1.0 0.0 0.0` and never `1 0 0`.  Printing them with `number`
    /// would give `1 0 0`, which is a different `caml` attribute from the one
    /// every existing template was authored against.
    ///
    /// The offset equation's results go through the same spelling
    /// (`OffsetEquation.format`), because `parse_equation` maps every operand
    /// through `float()` first — which is why `(2 * x + 10)` over `195` yields
    /// `400.0` and not `400`.
    static func float(_ value: Double) -> String {
        if value.isNaN { return "nan" }
        if value.isInfinite { return value < 0 ? "-inf" : "inf" }
        return "\(value)"
    }
}
