import Foundation

/// The imported templates and what the user has chosen in them.
///
/// Owned by `RootView` for the reason every other selection here is: the
/// Templates page edits it and the home page's single **Apply** delivers it, so
/// as page state it would be destroyed by walking over to press the button.
///
/// The reference keeps its templates in memory (`tweaks[TweakID.Templates]`) and
/// the option values on the live `TemplateFile` objects.  Here the **files** are
/// the list — a template is imported once, copied into this app's container and
/// re-read from there — so the option values need a home that outlives a launch
/// too.  They live in `TemplateOptionStore`, keyed by template file name and
/// option index, and are written the moment they change: an option value a user
/// spent a picker on and then lost to a relaunch is a template that has to be
/// set up again from scratch.
struct TemplateSelection {
    var templates: [TemplateFile] = []

    /// Whether the apply has anything to do.
    ///
    /// The reference's `TemplatesTweak.is_empty` is `len(self.templates) == 0`,
    /// and `uses_domains` is a **different** question — it is true when any
    /// template is not a sparserestore, because that decides whether the run
    /// needs domain delivery at all.  Both are reproduced, and the second is
    /// what decides whether a template-only selection is worth a backup.
    var isActive: Bool { !templates.isEmpty }

    /// Whether at least one template delivers through a backup domain.
    var usesDomains: Bool {
        templates.contains { !$0.requiresSparserestore }
    }

    /// Templates this port cannot deliver, with the reason.
    ///
    /// A sparserestore template is not silently dropped: the page says so, and
    /// so does the run log, because "my template did nothing" is the worst
    /// possible outcome and it looks exactly like success.
    var undeliverable: [(template: TemplateFile, reason: String)] {
        templates.compactMap { template in
            guard template.requiresSparserestore else { return nil }
            return (template, "it asks for sparserestore (\(template.domain)), which this app "
                + "does not implement — it delivers through a protective backup instead")
        }
    }

    /// The reference's own summary, for the log.
    var describe: String {
        guard !templates.isEmpty else { return "nothing" }
        let names = templates.map(\.title)
        return names.count == 1 ? names[0] : "\(names.count) template(s)"
    }

    /// Re-read the imported templates from disk.
    ///
    /// - Parameter deviceVersion: needed to re-apply a template's own
    ///   `min_version` / `max_version` gates.  With no device connected, a
    ///   template that declares a bound is dropped from the list and the page
    ///   says so, rather than being shown as ready and then refused at Apply.
    mutating func loadFromDisk(deviceVersion: String? = nil) {
        templates = TemplateImports.load(deviceVersion: deviceVersion)
    }

    /// Apply a change to one template's options and persist it.
    mutating func update(_ template: TemplateFile) {
        guard let index = templates.firstIndex(where: { $0.id == template.id }) else { return }
        templates[index] = template
        TemplateOptionStore.persist(template)
    }
}

/// The imported `.batter` files, as files in this app's container.
///
/// The same shape as `PosterBoardImports`, and for the same reason: the desktop
/// build holds its list in memory and loses it on exit, while a template is
/// something a user picked by hand and will want back after a relaunch.
enum TemplateImports {
    static var directory: URL {
        URL.documents.appendingPathComponent("Templates/Imports", conformingTo: .data)
    }

    static func uniqueDestination(for name: String) -> URL {
        let existing = Set((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
        return directory.appendingPathComponent(AfcFileExplorer.uniqueName(name, against: existing),
                                                conformingTo: .data)
    }

    /// Copy a picked file into the container and read it as a template.
    ///
    /// - Parameter deviceVersion: the device's iOS version, for the template's
    ///   own `min_version` / `max_version` gates.  Nil means "not known", and a
    ///   template that declares a bound is then **refused** rather than
    ///   installed unchecked — the reference's own `Version(min) > Version(None)`
    ///   raises in exactly that situation.
    static func `import`(from source: URL, deviceVersion: String?) throws -> TemplateFile {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = uniqueDestination(for: source.lastPathComponent)
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            throw TemplateFile.fail("Could not copy \(source.lastPathComponent) into the app: "
                + error.localizedDescription)
        }
        do {
            return try TemplateFile(url: destination, deviceVersion: deviceVersion)
        } catch {
            // Not a template (or one this device cannot use): leave nothing
            // behind for the next launch to trip over.
            try? FileManager.default.removeItem(at: destination)
            try? FileManager.default.removeItem(at: TemplateFile.resourcesDirectory(for: destination))
            throw error
        }
    }

    /// Every imported template, in file-name order.
    ///
    /// A template that no longer parses is **skipped**, not fatal: one bad file
    /// in the directory must not empty the page.  (The reference cannot hit this
    /// — its list is in memory and every entry was checked on import.)
    ///
    /// The stored option values are restored here, which is the whole reason
    /// `TemplateFile.init` takes no device version on this path: a template that
    /// declares `min_version` cannot be re-read without one, so a device-gated
    /// template would vanish from the list on the next launch.  It is therefore
    /// read **unfiltered** and the gates are re-applied by the caller, which has
    /// the device — see `TemplateSelection.loadFromDisk(deviceVersion:)`.
    static func load(deviceVersion: String?) -> [TemplateFile] {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .sorted()
        var out: [TemplateFile] = []
        for name in names {
            let url = directory.appendingPathComponent(name)
            guard var template = try? TemplateFile(url: url, deviceVersion: deviceVersion) else {
                continue
            }
            for index in template.options.indices {
                TemplateOptionStore.restore(at: index, in: template)
            }
            out.append(template)
        }
        return out
    }

    static func remove(_ template: TemplateFile) {
        try? FileManager.default.removeItem(at: template.url)
        try? FileManager.default.removeItem(at: TemplateFile.resourcesDirectory(for: template.url))
        TemplateOptionStore.forget(template)
    }

    static func removeAll() {
        try? FileManager.default.removeItem(at: directory)
        TemplateOptionStore.forgetAll()
    }
}

/// Where a template's option values live between launches.
///
/// Keyed by **file name + option index** rather than by option label: labels
/// are a template author's prose and two options in one config may well share
/// one, while the index is fixed by the config's own order.
enum TemplateOptionStore {
    private static let key = "TemplateOptionValues"

    private static var all: [String: [String]] {
        get { UserDefaults.standard.dictionary(forKey: key) as? [String: [String]] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    private static func storeKey(for template: TemplateFile) -> String {
        template.url.lastPathComponent
    }

    /// The saved value for one option, as the strings the option's control uses.
    ///
    /// Encoding per kind, so a reload restores exactly what the control showed:
    /// a toggle and a textbox are both one string, a slider and a colour are
    /// several.
    static func value(at index: Int, in template: TemplateFile) -> [String]? {
        guard index >= 0, index < template.options.count else { return nil }
        let stored = all[storeKey(for: template)]?[index] ?? ""
        guard !stored.isEmpty else { return nil }
        return stored.components(separatedBy: "\u{1}")
    }

    /// Record one option's values.
    static func setValue(_ values: [String], at index: Int, in template: TemplateFile) {
        guard index >= 0 else { return }
        var store = all
        var forTemplate = store[storeKey(for: template)] ?? []
        while forTemplate.count <= index { forTemplate.append("") }
        forTemplate[index] = values.joined(separator: "\u{1}")
        store[storeKey(for: template)] = forTemplate
        all = store
    }

    /// Write every option of a template out at once.
    static func persist(_ template: TemplateFile) {
        var store = all
        var forTemplate: [String] = []
        for option in template.options {
            forTemplate.append(encode(option).joined(separator: "\u{1}"))
        }
        store[storeKey(for: template)] = forTemplate
        all = store
    }

    /// An option's current values, in the form `setValue` stores.
    static func encode(_ option: TemplateOption) -> [String] {
        switch option {
        case let value as ReplaceOption:
            return [value.value?.lastPathComponent ?? ""]
        case let value as RemoveOption:
            return [value.value ? "1" : "0"]
        case let value as SetOption:
            switch value.setter {
            case .toggle:
                return [value.value.first.map { $0 != 0 ? "1" : "0" } ?? "0"]
            case .colorPicker:
                return [String(value.color.r), String(value.color.g), String(value.color.b),
                        String(value.color.a)]
            case .slider, .textbox:
                return value.text.split(separator: " ").map(String.init)
            }
        case let value as PickerOption:
            return [value.selection.sorted().map(String.init).joined(separator: ",")]
        default:
            return []
        }
    }

    /// Put a stored value back onto one option, by its index in the template.
    ///
    /// Best effort by design: a stored value that no longer fits the option's
    /// shape (a template was updated, or the config was edited by hand) leaves
    /// the option at its own default rather than failing.  A template that
    /// cannot be loaded at all is refused in `TemplateFile.init`; this is a
    /// narrower window and it should not throw.
    static func restore(at index: Int, in template: TemplateFile) {
        guard index >= 0, index < template.options.count else { return }
        let parts = value(at: index, in: template) ?? []
        switch template.options[index] {
        case let value as ReplaceOption:
            // The picked file is not in the store — only its name is, and the
            // file itself was never copied in.  So a replace option does not
            // survive a relaunch, and that is stated on the page: the user
            // re-picks the file, and the template is otherwise intact.
            break
        case var value as RemoveOption:
            if let first = parts.first { value.value = first == "1" }
        case var value as SetOption:
            switch value.setter {
            case .toggle:
                if let first = parts.first, let on = Double(first) { value.value = [on] }
            case .colorPicker:
                if parts.count >= 3 {
                    value.color = (r: Double(parts[0]) ?? 0, g: Double(parts[1]) ?? 0,
                                   b: Double(parts[2]) ?? 0,
                                   a: parts.count > 3 ? (Double(parts[3]) ?? 1) : 1)
                }
            case .slider, .textbox:
                if parts.count == value.value.count {
                    value.value = parts.map { Double($0) ?? 0 }
                    value.text = parts.joined(separator: " ")
                }
            }
        case var value as PickerOption:
            if let first = parts.first {
                let indices = first.split(separator: ",").compactMap { Int($0) }
                    .filter { $0 >= 0 && $0 < value.choices.count }
                if !indices.isEmpty { value.selection = Set(indices) }
            }
        default:
            break
        }
    }

    static func forget(_ template: TemplateFile) {
        var store = all
        store[storeKey(for: template)] = nil
        all = store
    }

    static func forgetAll() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

// MARK: - Delivery

/// `templates_tweak.py`: the non-PosterBoard half of a template's delivery.
///
/// A template's payload lives under a `container/` folder in the extracted
/// tree, and its files are restored into the template's **domain** — which is
/// how a template can put files into any app's container rather than only
/// PosterBoard's.
///
/// The two delivery routes, and which is which:
///
///   * a **PosterBoard** template goes in with the wallpapers: its extracted
///     tree is written into `PosterBoard.workDirectory` and picked up by the
///     same `PosterBoardBuilder.walk` that walks the tendies, because a
///     PosterBoard template ships descriptors and a `container/` snapshot like
///     any pack.  That is `posterboard_tweak.apply_tweak`'s template branch, and
///     it is `PosterBoard.compile`'s business, not this file's;
///   * **everything else** is this file: walk the extracted tree, take the files
///     under `container/`, and emit a `TweakPayload` each.
///
/// `Sparserestore-` domains are refused, and `TemplateSelection.undeliverable`
/// is what the page shows — the reason is in `TemplateFile.requiresSparserestore`.
enum TemplateDelivery {
    /// The reference's `recursive_add`, for a template that is not PosterBoard's.
    ///
    /// Two modes, and the asymmetry is the algorithm: **not adding** looks for
    /// the folder that names a destination (`container`, and the option paths),
    /// and **adding** turns every file below it into a payload.
    static func payloads(for template: TemplateFile,
                         into workDirectory: URL,
                         log: @escaping @Sendable (String) -> Void) throws -> [TweakPayload] {
        guard !template.requiresSparserestore else { return [] }

        // Upstream extracts into a fresh `uuid4()` directory under the output
        // dir; here the working directory is named, so a run's payload order is
        // reproducible (the same choice `PosterBoard.compile` makes).
        let destination = workDirectory.appendingPathComponent(
            "tmpl-" + PosterBoard.sanitised(template.url.lastPathComponent), conformingTo: .data)
        try? FileManager.default.removeItem(at: destination)
        let extracted = try template.extract(to: destination)

        let domain = template.effectiveDomain
        var payloads: [TweakPayload] = []
        try collect(from: extracted, base: extracted, domain: domain,
                    payloads: &payloads, log: log)
        if payloads.isEmpty {
            log("    ⚠️ \(template.title): nothing to deliver — its extracted tree has no "
                + "\"container\" folder, which is where a template keeps the files it restores.")
        }
        return payloads
    }

    /// The walk. `container` is the reference's `isAdding` branch's trigger and
    /// `parse_path_string`'s bundle-id rewrite is reproduced in `restorePath`.
    private static func collect(from directory: URL,
                                base: URL,
                                domain: String,
                                payloads: inout [TweakPayload],
                                log: @Sendable (String) -> Void) throws {
        let fm = FileManager.default
        let children = ((try? fm.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
        for child in children {
            // The reference skips dotfiles and `__MACOSX`.  Reproduced, and the
            // dotfile rule is not a "skip anything hidden" rule: it is
            // `folder.startswith('.')`, which does drop the legitimate
            // dot-prefixed descriptor plists — but those only exist inside a
            // descriptor tree, and a non-PosterBoard template's `container` is a
            // plain file tree.
            if child.hasPrefix(".") || child == "__MACOSX" { continue }
            let childPath = directory.appendingPathComponent(child)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: childPath.path, isDirectory: &isDirectory) else { continue }

            if child.lowercased() == "container" {
                // The reference starts the container walk at the archive root,
                // so the payload paths are relative to it.
                try collect(from: childPath, base: childPath, domain: domain,
                            payloads: &payloads, log: log)
                continue
            }
            if isDirectory.boolValue {
                try collect(from: childPath, base: base, domain: domain,
                            payloads: &payloads, log: log)
                continue
            }
            let relative = childPath.path.replacingOccurrences(of: base.path + "/", with: "")
            payloads.append(TweakPayload(domain: domain, relativePath: relative,
                                         source: childPath))
            log("    → \(domain)/\(relative)")
        }
    }
}