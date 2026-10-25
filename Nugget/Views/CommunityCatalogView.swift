import CoreImage.CIFilterBuiltins
import SwiftUI
import UniformTypeIdentifiers

/// The desktop's dedicated Community Catalog, with a local template library.
/// Downloading stores a preset/package; the home page owns confirmation/apply.
struct CommunityCatalogView: View {
    @ObservedObject private var device = DeviceIdentityMonitor.shared
    @ObservedObject private var library = CommunityTemplateStore.shared
    @State private var entries: [CommunityCatalog.Entry] = []
    @State private var search = ""
    @State private var compatibleOnly = true
    @State private var favoritesOnly = false
    @State private var loading = false
    @State private var busy: String?
    @State private var message = ""
    @State private var code = ""
    @State private var codeName = "Shared preset"
    @State private var showImporter = false
    @State private var showCode = false
    @State private var sharedCode = ""
    @State private var epoch = 0
    @AppStorage("CommunityCatalogFavorites") private var favoriteIDs = ""

    private var favorites: Set<String> { Set(favoriteIDs.split(separator: "\n").map(String.init)) }
    private var filtered: [CommunityCatalog.Entry] {
        entries.filter { $0.matches(search) && (!compatibleOnly || $0.supports(device.current.version))
            && (!favoritesOnly || favorites.contains($0.key)) }
    }
    var body: some View {
        List {
            Section {
                Toggle("Compatible with this iOS", isOn: $compatibleOnly)
                Toggle("Favorites only", isOn: $favoritesOnly)
                if loading { ProgressView("Loading catalog…") }
                if !message.isEmpty { Text(message).font(.footnote).textSelection(.enabled) }
                Link("Community repository and submissions", destination: CommunityCatalog.repositoryURL)
            }
            Section("Community Presets") {
                ForEach(filtered.filter { !$0.isTemplate }, id: \.key) { entry in catalogRow(entry) }
            }
            Section("Community Templates") {
                ForEach(filtered.filter(\.isTemplate), id: \.key) { entry in catalogRow(entry) }
            }
            Section("Import Share Code") {
                TextField("Preset name", text: $codeName)
                TextField("GN1.…", text: $code, axis: .vertical)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Save shared preset") {
                    do {
                        let name = try CommunityCatalog.store(PresetShareCode.decode(code), name: codeName)
                        message = "Saved \(name). Load it from Presets when ready."
                        code = ""; epoch += 1
                    } catch { message = error.localizedDescription }
                }.disabled(code.isEmpty)
                Button("Import .batter or portable preset") { showImporter = true }
            }
            Section("Share a Saved Preset") {
                ForEach(GoldenNuggetPresets.list().filter { !GoldenNuggetPresets.isInternal($0) }, id: \.self) { name in
                    Button(name) { share(name) }
                }
            }
            if !library.templates.isEmpty {
                Section("Installed Template Switches") {
                    Button("Reset applied community preferences", role: .destructive) {
                        Task {
                            busy = "reset"
                            defer { busy = nil }
                            do {
                                try await GoldenNuggetEngine.shared.resetCommunityTweaks()
                                message = "Community preferences reset. Reboot the device; other replaced files are listed in the run log."
                            } catch { message = error.localizedDescription }
                        }
                    }.disabled(busy != nil)
                    ForEach(library.templates) { template in
                        DisclosureGroup {
                            Toggle("Include in Apply", isOn: Binding(get: { template.active }, set: { library.setActive($0, template: template.id) }))
                            if !template.detail.isEmpty { Text(template.detail).font(.footnote) }
                            ForEach(template.tweaks) { tweak in
                                VStack(alignment: .leading) {
                                    Toggle(tweak.label, isOn: Binding(get: { tweak.enabled }, set: {
                                        library.edit(template: template.id, tweak: tweak.id, enabled: $0)
                                    })).disabled(!tweak.supports(device.current.version))
                                    if !tweak.detail.isEmpty { Text(tweak.detail).font(.caption).foregroundStyle(.secondary) }
                                    if let control = tweak.control { controlEditor(control, tweak: tweak, template: template) }
                                    DisclosureGroup("Files changed") {
                                        ForEach(Array(Set((tweak.writes + tweak.writesOff).map(\.path))).sorted(), id: \.self) {
                                            Text($0).font(.caption.monospaced()).textSelection(.enabled)
                                        }
                                    }.font(.footnote)
                                }
                            }
                            Button("Remove template", role: .destructive) {
                                do { try library.remove(template) } catch { message = error.localizedDescription }
                            }
                        } label: { VStack(alignment: .leading) { Text(template.title); Text(template.author).font(.caption).foregroundStyle(.secondary) } }
                    }
                }
            }
            if !library.loadErrors.isEmpty {
                Section("Template Errors") { ForEach(library.loadErrors, id: \.self) { Text($0).font(.footnote) } }
            }
        }
        .navigationTitle("Community Catalog")
        .searchable(text: $search)
        .toolbar { Button { Task { await refresh() } } label: { Image(systemName: "arrow.clockwise") }.disabled(loading) }
        .task { if entries.isEmpty { await refresh() } }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.data, .zip, .json, .image]) { result in
            do { try importFile(result.get()) } catch { message = error.localizedDescription }
        }
        .sheet(isPresented: $showCode) {
            NavigationStack {
                ScrollView {
                    VStack(spacing: 20) {
                        if let image = qrImage(sharedCode) {
                            Image(uiImage: image).interpolation(.none).resizable().scaledToFit().frame(maxWidth: 320).padding(24).background(.white)
                        }
                        Text(sharedCode).font(.caption.monospaced()).textSelection(.enabled)
                        ShareLink(item: sharedCode) { Label("Share code", systemImage: "square.and.arrow.up") }
                    }.padding()
                }.navigationTitle("Share Preset").toolbar { Button("Done") { showCode = false } }
            }
        }
    }

    private func catalogRow(_ entry: CommunityCatalog.Entry) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(entry.name).font(.headline)
                Spacer()
                Button {
                    var ids = favorites
                    if !ids.insert(entry.key).inserted { ids.remove(entry.key) }
                    favoriteIDs = ids.sorted().joined(separator: "\n")
                } label: { Image(systemName: favorites.contains(entry.key) ? "star.fill" : "star") }
                    .buttonStyle(.borderless).accessibilityLabel("Favorite \(entry.name)")
            }
            Text("\(entry.author) · \(entry.rangeLabel)").font(.caption).foregroundStyle(.secondary)
            if entry.untested {
                Label("Not tested on a device", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            if !entry.detail.isEmpty { Text(entry.detail).font(.footnote) }
            if !entry.writes.isEmpty {
                DisclosureGroup("Files changed") { ForEach(entry.writes, id: \.self) { Text($0).font(.caption.monospaced()) } }
            }
            let status = CommunityCatalog.status(entry)
            Button {
                Task { await install(entry) }
            } label: {
                Label(busy == entry.key ? "Downloading…" : (status == "Update available" ? "Update" : "Import"), systemImage: "square.and.arrow.down")
            }.disabled(busy != nil || !entry.supports(device.current.version) || status == "Installed")
            if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
        }.padding(.vertical, 4)
    }
    @ViewBuilder private func controlEditor(_ control: CommunityTemplate.Control, tweak: CommunityTemplate.Tweak,
                                            template: CommunityTemplate) -> some View {
        switch control.kind {
        case "slider":
            Slider(value: Binding(get: { (tweak.value as? NSNumber)?.doubleValue ?? control.minimum }, set: {
                library.edit(template: template.id, tweak: tweak.id, value: NSNumber(value: $0))
            }), in: control.minimum...control.maximum, step: control.step)
            Text(String(describing: tweak.value)).font(.caption.monospaced())
        case "text":
            TextField(tweak.label, text: Binding(get: { tweak.value as? String ?? "" }, set: {
                library.edit(template: template.id, tweak: tweak.id, value: $0)
            }))
        default:
            Picker(tweak.label, selection: Binding(get: {
                control.choices.firstIndex { NSDictionary(dictionary: ["v": $0.1]).isEqual(to: ["v": tweak.value]) } ?? 0
            }, set: { library.edit(template: template.id, tweak: tweak.id, value: control.choices[$0].1) })) {
                ForEach(control.choices.indices, id: \.self) { Text(control.choices[$0].0).tag($0) }
            }
        }
    }
    private func refresh() async {
        loading = true
        defer { loading = false }
        do {
            let index = try await CommunityCatalog.fetch()
            entries = index.entries
            message = "\(entries.count) entries. \(index.rejected) invalid entries skipped."
                + " \(entries.filter { CommunityCatalog.status($0) == "Update available" }.count) updates available."
                + (index.cached ? " Showing the offline cache." : "")
        } catch { message = error.localizedDescription }
    }
    private func install(_ entry: CommunityCatalog.Entry) async {
        busy = entry.key
        defer { busy = nil }
        do {
            if entry.isTemplate {
                let url = CommunityCatalog.indexURL.deletingLastPathComponent().appendingPathComponent("templates/\(entry.id).batter")
                let data = try await CommunityCatalog.download(url, limit: 25 * 1024 * 1024)
                guard data.count == entry.size, CommunityCatalog.hash(data) == entry.digest else { throw CommunityError("Template checksum does not match the catalog.") }
                try library.install(data, id: entry.id)
                message = "Template installed. Review its switches before Apply."
            } else {
                let name = try CommunityCatalog.installPreset(entry)
                message = "Saved \(name). Load it from Presets when ready."
            }
            epoch += 1
        } catch { message = error.localizedDescription }
    }
    private func importFile(_ url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        if ["png", "jpg", "jpeg", "heic"].contains(url.pathExtension.lowercased()) {
            guard let image = CIImage(contentsOf: url), image.extent.width <= 16000, image.extent.height <= 16000,
                  let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]),
                  let value = detector.features(in: image).compactMap({ ($0 as? CIQRCodeFeature)?.messageString }).first(where: { $0.contains("GN1.") }) else {
                throw CommunityError("No GoldenNugget QR code found in the image.")
            }
            _ = try PresetShareCode.decode(value)
            code = value
            message = "QR code read. Choose a name and save the shared preset."
        } else if url.pathExtension.lowercased() == "batter" {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 25 * 1024 * 1024 else { throw CommunityError("Template exceeds 25 MB.") }
            try library.install(Data(contentsOf: url), id: "local-" + UUID().uuidString.lowercased())
            message = "Template imported."
        } else {
            let result = PortablePreset.importFile(url)
            guard result.0 else { throw CommunityError(result.1) }
            message = "Preset \(result.1) imported."
        }
        epoch += 1
    }
    private func share(_ name: String) {
        do {
            let raw = try Data(contentsOf: GoldenNuggetPresets.fileURL(for: name))
            guard let document = try JSONSerialization.jsonObject(with: raw) as? [String: Any] else { throw CommunityError("Invalid preset.") }
            sharedCode = try PresetShareCode.encode(document, name: name)
            showCode = true
        } catch { message = error.localizedDescription }
    }
    private func qrImage(_ code: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(code.utf8); filter.correctionLevel = "M"
        guard let image = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cg = CIContext().createCGImage(image, from: image.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
