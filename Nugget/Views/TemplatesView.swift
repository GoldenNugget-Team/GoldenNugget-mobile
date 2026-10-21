import SwiftUI
import UniformTypeIdentifiers

/// The Templates page: imported `.batter` files and the options they expose.
///
/// A port of the reference's **Templates** tab (`posterboard.py`'s
/// `_create_templates_tab`), which lives inside its PosterBoard page.  It is a
/// page of its own here, and the reason is semantic rather than cosmetic: a
/// template is not a wallpaper.  Only templates whose `domain` is PosterBoard's
/// ride along with the wallpapers; the rest restore into any other app's
/// container, and putting those under a page called PosterBoard would say
/// something false about them.
///
/// The page edits `TemplateSelection`, which `RootView` owns — the **Apply** on
/// the home page delivers it, and a `NavigationSplitView` destroys the detail
/// view on every sidebar selection, so as page state the options would be gone
/// by the time the user reached the button.
///
/// Three things this page says that the reference's does not, all of them
/// because this port cannot do what the reference can:
///
///   * a `Sparserestore-` template is **refused with its reason** rather than
///     quietly skipped — see `TemplateFile.requiresSparserestore`;
///   * a `replace` option's chosen file does **not** survive a relaunch, and
///     the row says so, because the reference keeps the whole template in
///     memory and never has to re-ask;
///   * a template's `min_version` / `max_version` are re-checked against the
///     device on every appearance, because the device can change under a
///     selection that lives on disk.
struct TemplatesView: View {
    @Binding var selection: TemplateSelection

    @State private var identity: DeviceIdentity = .unknown
    @State private var status: String?
    @State private var statusTone: GoldenTone = .secondary
    @State private var showImporter = false
    @State private var pickError: String?

    /// The file picker for a `replace` option, and which option asked for it.
    ///
    /// One picker for the whole page rather than one per option, because two
    /// `fileImporter` modifiers on the same view shadow each other on iOS 26 —
    /// the same reason `PosterBoardView` keeps each picker attached to the
    /// control that presents it.
    @State private var replaceTarget: (template: Int, option: Int)?
    @State private var showReplaceImporter = false

    var body: some View {
        List {
            introSection
            if !selection.templates.isEmpty { templateList }
            importSection
            if let status {
                Section {
                    Text(status)
                        .foregroundStyle(statusTone.nativeColor)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if let pickError { errorSection(pickError) }
            RunLogCard()
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Templates")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            identity = await DeviceIdentity.read()
            // Reloaded with the device version so a template's own version
            // gates are re-checked: the page is the only place that knows both.
            selection.loadFromDisk(deviceVersion: identity.version)
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.data]) { result in
            importTemplate(result)
        }
        .fileImporter(isPresented: $showReplaceImporter,
                      allowedContentTypes: replaceContentTypes) { result in
            chooseReplacement(result)
        }
    }

    // MARK: - Sections

    private var introSection: some View {
        Section {
            NativeNote("A `.batter` file is a ZIP holding a `config.json`: it names the domain "
                + "to restore into and lists what you may change — an image to swap in, a colour, "
                + "a number, which of three variants to install. Import one, fill in its options "
                + "here, then press Apply on the home page. Nothing is written to the device until "
                + "then.")
        }
    }

    private var importSection: some View {
        Section {
            Button {
                showImporter = true
            } label: {
                Label("Import .batter template", systemImage: "plus.circle")
            }
            if selection.templates.isEmpty {
                NativeNote("No templates imported yet.")
            } else {
                Button(role: .destructive) {
                    selection.templates.forEach(TemplateImports.remove)
                    selection.loadFromDisk(deviceVersion: identity.version)
                } label: {
                    Label("Remove all templates", systemImage: "trash")
                }
                NativeNote("Each template is copied into this app, so removing one here removes "
                    + "the copy — the file you imported is untouched.")
            }
        }
    }

    private var templateList: some View {
        Section("Imported (\(selection.templates.count))") {
            ForEach(Array(selection.templates.enumerated()), id: \.element.id) { pair in
                templateCard(pair.offset, pair.element)
            }
        }
    }

    // MARK: - One template

    private func templateCard(_ index: Int, _ template: TemplateFile) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(template.title).font(.body).lineLimit(2)
                    Text(template.summary)
                        .font(.caption)
                        .foregroundStyle(template.requiresSparserestore ? Color.orange : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .layoutPriority(1)
                Spacer(minLength: 8)
                Button(role: .destructive) {
                    TemplateImports.remove(template)
                    selection.loadFromDisk(deviceVersion: identity.version)
                } label: {
                    Image(systemName: "trash").font(.system(size: 14))
                }
                .buttonStyle(.plain)
            }

            if template.requiresSparserestore {
                NativeSafetyNote("This template cannot be delivered by this app: it asks for "
                    + "sparserestore, which this app does not implement. Importing it is "
                    + "harmless — it is simply left out of the apply, and the run log says so "
                    + "rather than reporting success.")
            }

            // The preview images the config names.  Horizontal or stacked, per
            // `preview_layout` — the reference's own switch.
            if !template.previews.isEmpty {
                previews(template)
                    .frame(height: template.previewLayout == .stacked ? 250 : 180)
            }
            if let banner = template.bannerText {
                Text(banner)
                    .font(.footnote)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(8)
                    .background(Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
            }
            if let description = template.description {
                NativeNote(description)
            }

            // The bundle-id text box, the one option that is a field rather than
            // an object.
            if template.canChangeBundleID {
                VStack(alignment: .leading, spacing: 4) {
                    Text("App bundle id").font(.subheadline)
                    TextField("Bundle id", text: Binding(
                        get: { selection.templates[safe: index]?.bundleID ?? template.bundleID },
                        set: { newValue in
                            guard var updated = selection.templates[safe: index] else { return }
                            updated.bundleID = newValue
                            selection.update(updated)
                        }))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.callout)
                    NativeNote("The template's files are restored into this bundle's container. "
                        + "Its own note: this also changes files whose names start the same way.")
                }
            }

            ForEach(Array(template.options.enumerated()), id: \.offset) { optionPair in
                optionRow(templateIndex: index, optionIndex: optionPair.offset,
                          option: optionPair.element)
            }
        }
        .padding(.vertical, 4)
    }

    private func previews(_ template: TemplateFile) -> some View {
        let images = template.previews.sorted { $0.key < $1.key }
        return Group {
            if template.previewLayout == .stacked {
                // The reference stacks them with `StackAll`, i.e. one on top of
                // another at the same position.  Reproduced as a ZStack.
                ZStack {
                    ForEach(Array(images.enumerated()), id: \.offset) { pair in
                        if let image = UIImage(contentsOfFile: pair.element.value.path) {
                            Image(uiImage: image).resizable().scaledToFit()
                        }
                    }
                }
            } else {
                HStack(spacing: 8) {
                    ForEach(Array(images.enumerated()), id: \.offset) { pair in
                        if let image = UIImage(contentsOfFile: pair.element.value.path) {
                            Image(uiImage: image).resizable().scaledToFit()
                        }
                    }
                }
            }
        }
    }

    // MARK: - One option

    @ViewBuilder
    private func optionRow(templateIndex: Int, optionIndex: Int,
                           option: TemplateOption) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            switch option {
            case let value as ReplaceOption:
                optionControl(title: value.label + (value.required ? " *" : "")) {
                    HStack {
                        Button {
                            replaceTarget = (templateIndex, optionIndex)
                            showReplaceImporter = true
                        } label: {
                            Label(value.value == nil ? value.buttonLabel : "Replace chosen file",
                                  systemImage: value.value == nil ? "square.and.arrow.down" : "arrow.triangle.2.circlepath")
                        }
                        .buttonStyle(.bordered)
                        if let picked = value.value {
                            Text(picked.lastPathComponent)
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            Button {
                                mutate(templateIndex, optionIndex, as: ReplaceOption.self) { opt in
                                opt.value = nil
                            }
                            } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if value.required && value.value == nil {
                    NativeNote("This one is required: the template cannot be applied until a file "
                        + "is chosen.")
                }
                NativeNote("Allowed: \(value.allowedFiles). Applies the same file to every path the "
                    + "template lists.")
                NativeNote("The chosen file is not kept between launches — re-pick it after "
                    + "reopening the app. Everything else you set here is.")

            case let value as RemoveOption:
                optionControl(title: value.label) {
                    Toggle("", isOn: Binding(
                        get: { (current(templateIndex, optionIndex) as? RemoveOption)?.value
                            ?? false },
                        set: { newValue in
                            mutate(templateIndex, optionIndex, as: RemoveOption.self) { opt in
                                opt.value = newValue
                            }
                        }))
                    .labelsHidden()
                }
                if let identifier = value.identifier {
                    NativeNote("Removes the element \"\(identifier)\""
                        + (value.useCAID ? " (by its CoreAnimation id)" : "")
                        + " from: \(value.files.joined(separator: ", ")).")
                } else {
                    NativeNote("Deletes: \(value.files.joined(separator: ", ")).")
                }
                if value.inverted {
                    NativeNote("Inverted: the targets are deleted while this is **off**.")
                }

            case let value as SetOption:
                setOptionControl(templateIndex, optionIndex, value)

            case let value as PickerOption:
                optionControl(title: value.label) {
                    if value.allowMultipleSelection {
                        // A multi-selection picker is a set of toggles; the
                        // reference's `MultiComboBox` is one control, but on a
                        // phone-width column a list of switches is the readable
                        // equivalent and does the same thing.
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(value.choices.enumerated()), id: \.offset) { pair in
                                Toggle(pair.element.label, isOn: Binding(
                                    get: { (current(templateIndex, optionIndex) as? PickerOption)?
                                        .selection.contains(pair.offset) ?? false },
                                    set: { on in
                                        mutate(templateIndex, optionIndex, as: PickerOption.self) { opt in
                                                if on { opt.selection.insert(pair.offset) }
                                                else { opt.selection.remove(pair.offset) }
                                            }
                                    }))
                                .font(.callout)
                            }
                        }
                    } else {
                        Picker("", selection: Binding(
                            get: { (current(templateIndex, optionIndex) as? PickerOption)?
                                .selection.sorted().first ?? 0 },
                            set: { newValue in
                                mutate(templateIndex, optionIndex, as: PickerOption.self) { opt in
                                opt.selection = [newValue]
                            }
                            })) {
                            ForEach(Array(value.choices.enumerated()), id: \.offset) { pair in
                                Text(pair.element.label).tag(pair.offset)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                }
                NativeNote(pickerNote(value))

            default:
                EmptyView()
            }
        }
    }

    private func setOptionControl(_ templateIndex: Int, _ optionIndex: Int,
                                  _ value: SetOption) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            optionControl(title: value.label) {
                switch value.setter {
                case .toggle:
                    Toggle("", isOn: Binding(
                        get: { (current(templateIndex, optionIndex) as? SetOption)?
                            .value.first ?? 0 != 0 },
                        set: { on in
                            mutate(templateIndex, optionIndex, as: SetOption.self) { opt in
                            opt.value = [on ? 1 : 0]
                        }
                        }))
                    .labelsHidden()

                case .textbox:
                    TextField("Value", text: Binding(
                        get: { (current(templateIndex, optionIndex) as? SetOption)?.text ?? "" },
                        set: { newValue in
                            mutate(templateIndex, optionIndex, as: SetOption.self) { opt in
                            opt.text = newValue
                            let parts = newValue.split(separator: " ")
                                .map { Double($0) ?? 0 }
                            if !parts.isEmpty { opt.value = parts }
                        }
                        }))
                    .font(.callout)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)

                case .slider:
                    ForEach(Array(value.value.indices), id: \.self) { component in
                        VStack(alignment: .leading, spacing: 2) {
                            let lower = value.minValue.map {
                                $0.count > 1 ? $0[component] : $0[0] } ?? 0
                            let upper = value.maxValue.map {
                                $0.count > 1 ? $0[component] : $0[0] } ?? 1
                            let stepValue = value.step.count > 1 ? value.step[component]
                                : value.step[0]
                            HStack {
                                Text(lower.description).font(.caption2).foregroundStyle(.secondary)
                                Slider(
                                    value: Binding(
                                        get: { value.scaled(
                                            (current(templateIndex, optionIndex) as? SetOption)?
                                                .value[safe: component] ?? lower) },
                                        set: { newValue in
                                            mutate(templateIndex, optionIndex, as: SetOption.self) { opt in
                                                opt.setSliderValue(newValue, index: component)
                                            }
                                        }),
                                    in: value.scaled(lower)...value.scaled(upper),
                                    step: value.scaled(stepValue))
                                Text(upper.description).font(.caption2).foregroundStyle(.secondary)
                            }
                            Text((current(templateIndex, optionIndex) as? SetOption)?
                                .value[safe: component].map { $0.description } ?? "")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }

                case .colorPicker:
                    ColorPicker("", selection: Binding(
                        get: {
                            let current = (current(templateIndex, optionIndex) as? SetOption)?.color
                                ?? (r: 0, g: 0, b: 0, a: 1)
                            return Color(.sRGB, red: current.r, green: current.g, blue: current.b,
                                         opacity: current.a)
                        },
                        set: { newValue in
                            mutate(templateIndex, optionIndex, as: SetOption.self) { opt in
                            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1
                            UIColor(newValue).getRed(&r, green: &g, blue: &b, alpha: &a)
                            opt.color = (Double(r), Double(g), Double(b), Double(a))
                        }
                        }), supportsOpacity: value.usesOpacity)
                    .labelsHidden()
                }
            }
            NativeNote(setNote(value))
        }
    }

    private func optionControl<Content: View>(title: String,
                                              @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline)
            content()
        }
    }

    private func setNote(_ value: SetOption) -> String {
        var parts = ["Sets \(value.key) on element \"\(value.identifier)\""
            + (value.useCAID ? " (by its CoreAnimation id)" : "") + "."]
        parts.append("Applies to: \(value.files.joined(separator: ", ")).")
        if value.valueType == "float" {
            parts.append("Declared as a float, so the slider works in thousandths.")
        }
        if let valueTag = value.valueTag {
            parts.append("Keeps the \(valueTag)(…) wrapper it shipped with.")
        }
        if let min = value.minValue, let max = value.maxValue, !min.isEmpty, !max.isEmpty {
            parts.append("Range \(min[0].description)–\(max[0].description).")
        }
        if value.inverted {
            parts.append("Inverted: the value written is the opposite of the switch.")
        }
        if value.toggleOnValue != nil || value.toggleOffValue != nil {
            parts.append("This toggle writes a value other than on/off.")
        }
        return parts.joined(separator: " ")
    }

    private func pickerNote(_ value: PickerOption) -> String {
        var parts = [value.allowMultipleSelection
            ? "Every choice you do not pick is deleted before the files are delivered."
            : "The choices you do not pick are deleted before the files are delivered."]
        if value.renames {
            parts.append("The chosen files are renamed to: \(value.names.joined(separator: ", ")).")
        }
        return parts.joined(separator: " ")
    }

    private func errorSection(_ message: String) -> some View {
        Section {
            NativeSafetyNote(message)
        }
    }

    // MARK: - Selection plumbing

    /// The option currently held by the selection, read fresh each time.
    ///
    /// A binding getter rather than a captured value: the option is a `struct`
    /// inside an array inside another `struct`, so a captured copy would write
    /// into a copy and the control would not move.
    private func current(_ templateIndex: Int, _ optionIndex: Int) -> TemplateOption? {
        guard let template = selection.templates[safe: templateIndex],
              template.options.indices.contains(optionIndex) else { return nil }
        return template.options[optionIndex]
    }

    /// Change one option and persist the template.
    ///
    /// Generic over the option's concrete type rather than taking a closure over
    /// `Any`: an option is a `struct` inside an array inside another `struct`,
    /// so the change has to be made on a mutable copy and written back by name.
    /// A `(Any) -> Void` closure cannot do that — it would mutate its own copy
    /// and the control would not move.
    private func mutate<T: TemplateOption>(_ templateIndex: Int, _ optionIndex: Int,
                                           as type: T.Type,
                                           _ change: (inout T) -> Void) {
        guard var template = selection.templates[safe: templateIndex],
              template.options.indices.contains(optionIndex),
              var typed = template.options[optionIndex] as? T else { return }
        change(&typed)
        template.options[optionIndex] = typed
        selection.update(template)
    }

    // MARK: - Import

    private var replaceContentTypes: [UTType] {
        guard let target = replaceTarget,
              let option = current(target.template, target.option) as? ReplaceOption
        else { return [.data] }
        let extensions = option.allowedExtensions
        guard !extensions.isEmpty else { return [.data] }
        let types = extensions.compactMap { UTType(filenameExtension: $0) }
        return types.isEmpty ? [.data] : types
    }

    private func importTemplate(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let template = try TemplateImports.import(from: url, deviceVersion: identity.version)
            selection.loadFromDisk(deviceVersion: identity.version)
            status = "Imported \(template.title)."
            statusTone = .secondary
            RunLog.shared.append("Templates: imported \(url.lastPathComponent) as "
                + "\"\(template.title)\" (\(template.domain), \(template.options.count) option(s)).")
        } catch {
            pickError = error.localizedDescription
            RunLog.shared.append("Templates: import failed — \(error.localizedDescription)")
        }
    }

    private func chooseReplacement(_ result: Result<URL, Error>) {
        guard let target = replaceTarget else { return }
        defer { replaceTarget = nil }
        do {
            let url = try result.get()
            // Copied into the app's container, for the same reason a `.tendies`
            // pack is: the picker's URL is security-scoped and its access ends
            // with the callback, while the file is not read until Apply.
            let stored = try TemplateChoices.store(url, in: AppPaths.templateChoices)
            mutate(target.template, target.option, as: ReplaceOption.self) { opt in
                opt.value = stored
            }
        } catch {
            pickError = error.localizedDescription
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
