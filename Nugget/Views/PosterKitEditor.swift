import SwiftUI

// The two poster-registry editors the reference renders on its tweaks page
// (`make_poster_preferences` in `src/gui/ios/tweaks.py`, backed by
// `src/gui/liquid/poster_preferences.py`):
//
//   * `PosterKitOverrides` (`Kind.POSTER_ARCHIVE`) — a set of named fields,
//     each carried in the selection under its `"Group:path"` key, applied by
//     patching the wallpaper archives the restore already carries.
//   * `SBHomeScreenWallpapers` / `SBLockScreenWallpapers` (`Kind.WALLPAPER`) —
//     one dictionary written under the tweak's key, seeded from the registry
//     default's `"none"` tree.
//
// Both are data-driven off the same shape: a master toggle, and per-field
// "use" switches whose value control the field's default decides (toggle,
// text, number, font menu).  A field only joins the selection when its use
// switch is on, and editing a value never switches the master on — that is
// `store(..., toggle_enabled=False)` in the reference.

/// The value a field's editor shows and writes.
private struct FieldEditorState {
    let field: PosterKitOptions.Field
    /// Whether the field is part of the selection (archive mode) or always
    /// written (dictionary mode).
    let used: Bool

    var isBool: Bool {
        if case .bool = field.defaultValue { return true }
        return false
    }
}

/// The `PosterKitOverrides` row: master toggle, a summary of how many fields
/// are selected, and a button into the field editor.
struct PosterKitEditorRow: View {
    let spec: TweakSpec
    @Binding var selection: TweakSelection
    let safetyWarning: String?
    @State private var showEditor = false
    @State private var showWarning = false

    private var selectedCount: Int {
        if case .dictionary(let fields) = selection.value(for: spec) { return fields.count }
        return 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: toggleBinding) {
                TweakRowLabel(title: spec.title, id: spec.id, detail: spec.detail)
            }
            if let safetyWarning { NativeSafetyNote(safetyWarning) }
            Button {
                showEditor = true
            } label: {
                Text("Edit fields… (\(selectedCount) selected)")
            }
            .disabled(!selection.isOn(spec))
            TweakRowCaption(id: spec.id, detail: spec.warning)
        }
        .sheet(isPresented: $showEditor) {
            PosterKitEditorView(spec: spec, selection: $selection)
        }
        .alert(spec.title, isPresented: $showWarning) {
            Button("Cancel", role: .cancel) {}
            Button("Continue anyway", role: .destructive) { selection.setOn(true, for: spec) }
        } message: {
            Text(spec.warning ?? "")
        }
    }

    private var toggleBinding: Binding<Bool> {
        Binding(get: { selection.isOn(spec) }, set: { on in
            if on && !(spec.warning ?? "").isEmpty {
                showWarning = true
            } else {
                selection.setOn(on, for: spec)
            }
        })
    }
}

/// The full PosterKit field editor, mirroring `poster_preferences.py`'s
/// archive branch: presets, the icon-tint color, then every field with its
/// own Use switch.
struct PosterKitEditorView: View {
    let spec: TweakSpec
    @Binding var selection: TweakSelection
    @Environment(\.dismiss) private var dismiss

    private func fields() -> [String: TweakValue] {
        if case .dictionary(let fields) = selection.value(for: spec) { return fields }
        return [:]
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle(isOn: masterBinding) {
                        Text(spec.title)
                    }
                    if let warning = spec.warning { NativeNote(warning) }
                }
                Section(String(localized: "Wallpaper presets")) {
                    ForEach(PosterKitOptions.presets.keys.sorted(), id: \.self) { name in
                        Button {
                            applyPreset(name)
                        } label: {
                            Text(name)
                        }
                    }
                }
                iconTintSection
                fieldSections
            }
            .navigationTitle(spec.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done")) { dismiss() }
                }
            }
        }
    }

    private var masterBinding: Binding<Bool> {
        Binding(get: { selection.isOn(spec) }, set: { selection.setOn($0, for: spec) })
    }

    /// `POSTER_PRESETS`: mark every preset field used and store its value.
    private func applyPreset(_ name: String) {
        guard let preset = PosterKitOptions.presets[name] else { return }
        var fields = fields()
        for (key, value) in preset { fields[key] = value }
        selection.setDictionary(fields, for: spec)
    }

    /// The icon-tint color card: the three `_tintColorStyle` fields are set
    /// together from one hue/saturation/alpha triple.
    private var iconTintSection: some View {
        Section(String(localized: "Icon tint color")) {
            ForEach(PosterKitOptions.tintKeys, id: \.self) { key in
                if let field = PosterKitOptions.all.first(where: { $0.key == key }) {
                    fieldRow(FieldEditorState(field: field, used: true))
                }
            }
            Button(String(localized: "Clear tint")) {
                var fields = fields()
                for key in PosterKitOptions.tintKeys { fields.removeValue(forKey: key) }
                selection.setDictionary(fields, for: spec)
            }
        }
    }

    /// The field cards, grouped by archive group like the reference's page.
    private var fieldSections: some View {
        ForEach(groupNames, id: \.self) { group in
            Section(group) {
                ForEach(PosterKitOptions.all.filter { $0.group == group }, id: \.key) { field in
                    fieldRow(FieldEditorState(field: field, used: fields()[field.key] != nil))
                }
            }
        }
    }

    private var groupNames: [String] {
        var seen: [String] = []
        for field in PosterKitOptions.all where !seen.contains(field.group) { seen.append(field.group) }
        return seen
    }

    @ViewBuilder
    private func fieldRow(_ state: FieldEditorState) -> some View {
        let field = state.field
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(field.title)
                Spacer()
                Toggle(String(localized: "Use"), isOn: useBinding(field))
                    .labelsHidden()
                    .fixedSize()
            }
            if state.used || alwaysShown(field) {
                valueEditor(field)
            }
            Text(field.key)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    /// Dictionary-mode fields (the wallpaper branch) always show their value;
    /// archive fields hide the value control while unused, like `entry.
    /// setEnabled(selected)` in the reference.
    private func alwaysShown(_ field: PosterKitOptions.Field) -> Bool {
        field.group != "PosterKit" && spec.kind == .wallpaper
    }

    private func useBinding(_ field: PosterKitOptions.Field) -> Binding<Bool> {
        Binding(get: { fields()[field.key] != nil }, set: { used in
            var fields = fields()
            if used {
                if fields[field.key] == nil { fields[field.key] = field.defaultValue }
            } else {
                fields.removeValue(forKey: field.key)
            }
            selection.setDictionary(fields, for: spec)
        })
    }

    @ViewBuilder
    private func valueEditor(_ field: PosterKitOptions.Field) -> some View {
        switch field.defaultValue {
        case .bool:
            Picker(selection: valueBinding(field)) {
                Text(String(localized: "Off")).tag(TweakValue.bool(false))
                Text(String(localized: "On")).tag(TweakValue.bool(true))
            } label: {
                EmptyView()
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        case .double, .int:
            TextField(field.title, text: Binding(get: {
                (fields()[field.key] ?? field.defaultValue).display
            }, set: { raw in
                var fields = fields()
                if let number = parseNumber(raw, field) { fields[field.key] = number }
                selection.setDictionary(fields, for: spec)
            }))
            .keyboardType(.decimalPad)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .textFieldStyle(.roundedBorder)
        case .string:
            if field.key == "Clock:timeFontConfiguration.timeFontIdentifier" {
                Picker(selection: valueBinding(field)) {
                    ForEach(PosterKitOptions.clockFontIdentifiers, id: \.self) { font in
                        Text(font.replacingOccurrences(of: "PRTimeFontIdentifier", with: ""))
                            .tag(TweakValue.string(font))
                    }
                } label: {
                    Text(field.title)
                }
            } else {
                TextField(field.title, text: stringBinding(field))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
            }
        case .dictionary:
            EmptyView()
        }
    }

    private func valueBinding(_ field: PosterKitOptions.Field) -> Binding<TweakValue> {
        Binding(get: {
            fields()[field.key] ?? field.defaultValue
        }, set: { newValue in
            var fields = fields()
            fields[field.key] = newValue
            selection.setDictionary(fields, for: spec)
        })
    }

    private func stringBinding(_ field: PosterKitOptions.Field) -> Binding<String> {
        Binding(get: {
            if case .string(let text) = fields()[field.key] ?? field.defaultValue { return text }
            return ""
        }, set: { selection.setDictionary(modified(fields(), field, .string($0)), for: spec) })
    }

    private func modified(_ fields: [String: TweakValue], _ field: PosterKitOptions.Field, _ value: TweakValue) -> [String: TweakValue] {
        var fields = fields
        fields[field.key] = value
        return fields
    }

    /// Parse a numeric draft the way the reference's `NumberInputDialog` does:
    /// the field's default type decides int vs double, and the generated
    /// limits clamp.
    private func parseNumber(_ raw: String, _ field: PosterKitOptions.Field) -> TweakValue? {
        guard let parsed = Double(raw.trimmingCharacters(in: .whitespaces)), parsed.isFinite else { return nil }
        var clamped = parsed
        if let (lower, upper, _) = field.limits {
            clamped = Swift.min(Swift.max(parsed, lower), upper)
        }
        if case .int = field.defaultValue {
            guard let integer = Int(exactly: clamped.rounded()) else { return nil }
            return .int(integer)
        }
        return .double(clamped)
    }
}

/// The wallpaper-dictionary editor (`Kind.WALLPAPER`): the eight SpringBoard
/// wallpaper keys the reference's `titles` map names, written as one
/// dictionary under the tweak's key.
struct WallpaperPreferencesEditorRow: View {
    let spec: TweakSpec
    @Binding var selection: TweakSelection
    let safetyWarning: String?
    @State private var showEditor = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(get: { selection.isOn(spec) },
                                 set: { selection.setOn($0, for: spec) })) {
                TweakRowLabel(title: spec.title, id: spec.id, detail: spec.detail)
            }
            if let safetyWarning { NativeSafetyNote(safetyWarning) }
            Button(String(localized: "Edit values…")) { showEditor = true }
                .disabled(!selection.isOn(spec))
            TweakRowCaption(id: spec.id, detail: spec.warning)
        }
        .sheet(isPresented: $showEditor) {
            WallpaperPreferencesEditorView(spec: spec, selection: $selection)
        }
    }
}

/// The per-field metadata for the wallpaper dictionaries, ported from
/// `poster_preferences.py`'s `titles` map and its inline `limits`.
enum WallpaperDictionaryFields {
    struct Field {
        let key: String
        let title: String
        let defaultValue: TweakValue
        let limits: (Double, Double, Double)?
    }

    static let all: [Field] = [
        Field(key: "SBWallpaperHasVideoKey", title: "Has video", defaultValue: .bool(false), limits: nil),
        Field(key: "SBWallpaperMagnifyEnabledKey", title: "Magnification", defaultValue: .bool(false), limits: nil),
        Field(key: "SBWallpaperParallaxFactorKey", title: "Parallax factor", defaultValue: .int(1), limits: (0, 100, 0.1)),
        Field(key: "SBWallpaperPortraitKey", title: "Portrait", defaultValue: .bool(true), limits: nil),
        Field(key: "SBWallpaperStillTimeInVideoKey", title: "Video still time", defaultValue: .int(0), limits: (0, 86400, 0.1)),
        Field(key: "SBWallpaperSupportsCroppingKey", title: "Cropping", defaultValue: .bool(false), limits: nil),
        Field(key: "SBWallpaperZoomScaleKey", title: "Zoom scale", defaultValue: .int(1), limits: (0.01, 100, 0.01)),
        Field(key: "kSBProceduralWallpaperHomeUserSetKey", title: "Procedural wallpaper user set", defaultValue: .bool(false), limits: nil),
    ]
}

struct WallpaperPreferencesEditorView: View {
    let spec: TweakSpec
    @Binding var selection: TweakSelection
    @Environment(\.dismiss) private var dismiss

    private func fields() -> [String: TweakValue] {
        if case .dictionary(let outer) = selection.value(for: spec),
           case .dictionary(let fields)? = outer["none"] {
            return fields
        }
        return [:]
    }

    private func store(_ fields: [String: TweakValue]) {
        selection.setDictionary(["none": .dictionary(fields)], for: spec)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle(isOn: Binding(get: { selection.isOn(spec) },
                                         set: { selection.setOn($0, for: spec) })) {
                        Text(spec.title)
                    }
                    if let warning = spec.warning { NativeNote(warning) }
                }
                Section(spec.title) {
                    ForEach(WallpaperDictionaryFields.all, id: \.key) { field in
                        wallpaperFieldRow(field)
                    }
                }
            }
            .navigationTitle(spec.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done")) { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func wallpaperFieldRow(_ field: WallpaperDictionaryFields.Field) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(field.title)
            switch field.defaultValue {
            case .bool:
                Picker(selection: fieldBinding(field)) {
                    Text(String(localized: "Off")).tag(TweakValue.bool(false))
                    Text(String(localized: "On")).tag(TweakValue.bool(true))
                } label: {
                    EmptyView()
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            case .int, .double:
                TextField(field.title, text: Binding(get: {
                    (fields()[field.key] ?? field.defaultValue).display
                }, set: { raw in
                    var fields = fields()
                    if let number = parseNumber(raw, field) { fields[field.key] = number }
                    store(fields)
                }))
                .keyboardType(.decimalPad)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
            case .string, .dictionary:
                EmptyView()
            }
            Text(field.key)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    /// Parse a numeric draft the way the reference's `NumberInputDialog` does:
    /// the field's default type decides int vs double, and the limits clamp.
    private func parseNumber(_ raw: String, _ field: WallpaperDictionaryFields.Field) -> TweakValue? {
        guard let parsed = Double(raw.trimmingCharacters(in: .whitespaces)), parsed.isFinite else { return nil }
        var clamped = parsed
        if let (lower, upper, _) = field.limits {
            clamped = Swift.min(Swift.max(parsed, lower), upper)
        }
        if case .int = field.defaultValue {
            guard let integer = Int(exactly: clamped.rounded()) else { return nil }
            return .int(integer)
        }
        return .double(clamped)
    }

    private func fieldBinding(_ field: WallpaperDictionaryFields.Field) -> Binding<TweakValue> {
        Binding(get: { fields()[field.key] ?? field.defaultValue }, set: { newValue in
            var fields = fields()
            fields[field.key] = newValue
            store(fields)
        })
    }
}
