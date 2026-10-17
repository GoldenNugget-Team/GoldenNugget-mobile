import SwiftUI
import Foundation
import DeviceGatewayAPI
import QuickLook

/// A file browser for whatever the device's AFC service publishes.
///
/// The tree it walks is the device's, not a whitelist: the root is asked for
/// rather than assumed, and every listing is whatever `afcList` returns. That
/// matters because the service publishes different roots on different devices,
/// and a browser that hardcoded `/var/mobile/Media` would look broken on one
/// that publishes containers instead.
///
/// It is built as a `List` because that is what a file browser is on this
/// platform, and the resemblance is not decoration — it is what carries the
/// behaviours. The previous shape (a stack of `GoldenCard`s, a pencil and a bin
/// on every row, a card of "actions" above the listing) had to hand-write the
/// things a `List` already does: swipe-to-delete, a context menu, pull to
/// refresh, a disclosure chevron, a content-unavailable state. What a user
/// reaches for in a browser is learned from Files, not from this app's other
/// pages, so this page follows Files.
///
/// Three things worth reading before using it: this deletes, with no trash and
/// no undo; a write is a single-call AFC write capped at 64 MiB; and a preview
/// pulls the whole file to this device first, because AFC has no read the
/// previewer can seek in. All three are stated at the point of action rather
/// than discovered.
struct FilesView: View {
    @State private var path: [String] = []
    @State private var entries: [AfcFsEntry] = []
    @State private var volume: AfcFsVolumeInfo?
    @State private var loading = false
    @State private var busy = false
    @State private var error: String?
    @State private var status: String?
    @State private var pullProgress: Double?

    /// Persisted rather than `@State`, because a sort the user has to set again
    /// after every visit is not a preference.
    @AppStorage(Self.sortKey) private var sortRaw = SortOrder.name.rawValue

    @State private var showImporter = false
    @State private var showNewFolder = false
    @State private var newFolderName = ""
    @State private var renaming: AfcFsEntry?
    @State private var renameText = ""
    @State private var deleting: AfcFsEntry?
    @State private var preview: Preview?

    /// Quick Look over a file that has been pulled to the temporary directory.
    /// `URL` is not `Identifiable` and the sheet needs an identity to present
    /// from, so the URL is carried rather than passed.
    private struct Preview: Identifiable {
        let id = UUID()
        let url: URL
    }

    /// What the listing is ordered by. Folders stay above files under every
    /// option: a browser that interleaves them buries the next directory under
    /// whatever files happen to sort first, which is the one thing a user
    /// navigating a tree cannot afford.
    private enum SortOrder: String, CaseIterable, Identifiable {
        case name, size, date

        var id: String { rawValue }

        var title: String {
            switch self {
            case .name: "Name"
            case .size: "Size"
            case .date: "Date"
            }
        }

        var systemImage: String {
            switch self {
            case .name: "textformat.abc"
            case .size: "arrow.up.arrow.down"
            case .date: "clock"
            }
        }
    }

    private static let sortKey = "FilesSortOrder"

    private var sort: SortOrder { SortOrder(rawValue: sortRaw) ?? .name }

    var body: some View {
        List {
            if entries.isEmpty, !loading, error == nil {
                // The system's own empty state, so an empty directory looks like
                // an empty directory in every other app on the phone.
                ContentUnavailableView {
                    Label("Folder is Empty", systemImage: "folder")
                } description: {
                    Text(path.isEmpty
                         ? "The device's AFC service published nothing here."
                         : "\(path[path.count - 1]) has nothing in it.")
                } actions: {
                    Button("New Folder") { newFolderName = ""; showNewFolder = true }
                        .buttonStyle(.borderedProminent)
                }
                .listRowSeparator(.hidden)
            }

            ForEach(entries) { entry in
                row(entry)
            }

            if let pullProgress {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: pullProgress)
                    Text("Pulling \(Int(pullProgress * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(Color.clear)
            }

            if let volume {
                volumeRow(volume)
            }

            // The write cap, where a reader of the listing will find it rather
            // than where a failed upload finds them. It is the one limit on this
            // page that is not the device's, so it is stated as this app's.
            Text("Uploads are capped at \(AfcFileExplorer.format(AfcFileExplorer.pushSizeLimit)) "
                 + "— an AFC write is a single call with no streaming form, so a larger file "
                 + "is refused rather than truncated.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
        .listStyle(.insetGrouped)
        // A path bar between the navigation bar and the list, the way Finder
        // and Files both put it. A `safeAreaInset` rather than a list row: as a
        // row it scrolls away, and a browser that cannot say where it is has
        // lost the one thing it exists to answer.
        .safeAreaInset(edge: .top, spacing: 0) { pathBar }
        // What a run of the page says back. It was a line under the breadcrumb
        // card; with the cards gone there is nothing to hang it under, and an
        // alert per rename would be the platform's way of saying something that
        // is not a question. A banner that clears itself is what a phone does.
        .overlay(alignment: .bottom) { bannerView }
        .animation(.easeInOut(duration: 0.18), value: banner)
        .refreshable { await load() }
        .navigationTitle("Files")
        // Compact widths only -- on a tablet the split view draws its own sidebar
        // toggle, and a second button beside it is the duplicate-controls mess.
        .goldenSidebarButton()
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                // The three things that act on the listing, in the platform's own
                // idiom: a sort menu, and a plus that opens a new-folder action.
                // They were a card of three rows above the listing, which is a
                // toolbar written out longhand.
                Menu {
                    Picker("Sort by", selection: $sortRaw) {
                        ForEach(SortOrder.allCases) { order in
                            Label(order.title, systemImage: order.systemImage).tag(order.rawValue)
                        }
                    }
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }

                Menu {
                    Button {
                        newFolderName = ""
                        showNewFolder = true
                    } label: {
                        Label("New Folder", systemImage: "folder.badge.plus")
                    }
                    Button {
                        showImporter = true
                    } label: {
                        Label("Upload", systemImage: "square.and.arrow.up")
                    }
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .disabled(busy)
            }
        }
        .task { await load() }
        .sheet(item: $preview) { preview in
            QuickLookPreview(url: preview.url)
                .ignoresSafeArea()
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.data]) { result in
            switch result {
            case .success(let url): Task { await push(url) }
            case .failure(let error): self.error = error.localizedDescription
            }
        }
        .alert("New folder", isPresented: $showNewFolder) {
            TextField("Name", text: $newFolderName)
            Button("Create") { Task { await createFolder() } }
            Button("Cancel", role: .cancel) { newFolderName = "" }
        }
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Rename") { Task { await performRename() } }
            Button("Cancel", role: .cancel) { renaming = nil; renameText = "" }
        }
        .confirmationDialog(
            deleting.map { "Delete \($0.name)?" } ?? "Delete?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { Task { await performDelete() } }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: {
            if let deleting {
                Text(deleting.isDirectory
                     ? "A folder. Nothing goes through a trash here — this is the device's own delete."
                     : "\(AfcFileExplorer.format(deleting.size)) on the device, removed with no trash "
                        + "and no undo.")
            }
        }
    }

    // MARK: - Banner

    /// The one line of feedback the page has, and what it is for.
    ///
    /// An error outranks a status: both cannot be true at once, and the one that
    /// needs the user to do something must not be the one that was overwritten.
    ///
    /// A type rather than a tuple because the banner is animated on change and
    /// keys a self-clearing task, and both of those want `Equatable`.
    private struct Banner: Equatable {
        let text: String
        let isError: Bool
    }

    private var banner: Banner? {
        if let error { return Banner(text: error, isError: true) }
        if let status { return Banner(text: status, isError: false) }
        return nil
    }

    @ViewBuilder
    private var bannerView: some View {
        if let banner {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: banner.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(banner.isError ? Color.orange : Color.green)
                Text(banner.text)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    error = nil
                    status = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(12)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color(.separator), lineWidth: 1)
            )
            .padding(.horizontal)
            .padding(.bottom, 8)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            // Self-clearing, but only a success. An error waits for the user to
            // acknowledge it or for the next thing they do to replace it.
            .task(id: banner) {
                guard !banner.isError else { return }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if status == banner.text { status = nil }
            }
        }
    }

    // MARK: - Path bar

    private var pathBar: some View {
        HStack(spacing: 0) {
            // The way out of a directory. It lives here rather than in the
            // navigation bar because the navigation bar's back button is not this
            // page's to take: it pops Files and lands on the home page, which is a
            // different "back" from the one a person one level down is asking for.
            // Overriding it with `.navigationBarBackButtonHidden` would also take
            // the edge-swipe with it, so instead the control sits where Finder
            // puts one — beside the path, outside the scroll, always in the same
            // place however deep the tree is.
            if !path.isEmpty {
                Button(action: goUp) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.tint)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Up one level")
                .padding(.leading)
            }

            breadcrumb
        }
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    /// Horizontal instead of wrapping.  A device path is deeper than any window
    /// this app can be given — `/var/mobile/Containers/Data/Application/<UUID>/…`
    /// alone is over 300 pt — and letting it wrap made the bar grow a line per
    /// component while each separator drifted away from the name it separates.
    /// One line each at natural width, scrolled: a short path looks exactly as
    /// before, a long one is reachable without the bar changing height.
    private var breadcrumb: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                if path.isEmpty {
                    // The service's own root, which has no name of its own. A
                    // leading "afc://" says where the tree comes from, which the
                    // empty breadcrumb otherwise does not.
                    Image(systemName: "internaldrive")
                        .foregroundStyle(.secondary)
                    Text("afc://")
                        .font(.body)
                        .fontWeight(.medium)
                }
                ForEach(Array(path.enumerated()), id: \.offset) { index, component in
                    if index > 0 {
                        // A chevron, which is what makes a stack of tappable
                        // words read as a path rather than as a sentence.
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    Button {
                        path = Array(path.prefix(index + 1))
                        Task { await load() }
                    } label: {
                        Text(component)
                            .font(.body)
                            .fontWeight(.medium)
                            .foregroundStyle(index == path.count - 1
                                             ? Color.primary
                                             : Color.accentColor)
                            // Natural width, never compressed: the scroll view is
                            // what absorbs the overflow.
                            .fixedSize()
                    }
                    .buttonStyle(.plain)
                }
                if loading { ProgressView() }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }

    private func goUp() {
        guard !path.isEmpty else { return }
        path.removeLast()
        Task { await load() }
    }

    // MARK: - Rows

    /// One row, laid out the way a `List` lays out a row: a leading icon, the
    /// name over a secondary line, a chevron for a directory.
    ///
    /// The header and the rows used to be siblings inside a `GoldenSection`, which
    /// wraps content in a `VStack` that the page's lazy stack treats as one child —
    /// so every entry was built on the first pass, however long the directory is.
    /// A `List` is lazy per row for free, which is the other half of why this page
    /// stopped being a card stack.
    private func row(_ entry: AfcFsEntry) -> some View {
        Button {
            // Tapping a row does what tapping a row does in Files: a directory
            // opens, a file is looked at. The visible pencil and bin this replaced
            // are a context menu and a swipe away, which is where a phone puts
            // them.
            if entry.isDirectory { open(entry) } else { Task { await preview(entry) } }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: entry.isDirectory
                      ? "folder.fill"
                      : (entry.linkTarget != nil ? "link" : "doc"))
                    .foregroundStyle(entry.isDirectory ? Color.accentColor : Color.secondary)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 2) {
                    // One line, truncated in the middle.  A device filename is
                    // routinely 40+ characters, which in a 288 pt window wrapped
                    // to two or three lines and made every long entry a block —
                    // the list stopped scanning as a list.  Middle truncation
                    // keeps the extension, which is the part a browser is usually
                    // read for.
                    Text(entry.name)
                        .font(.body)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(subtitle(for: entry))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                if entry.isDirectory {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            // No full swipe: `afcDelete` is a real unlink with no trash, and a
            // gesture that destroys without a confirmation is exactly the thing
            // the delete dialog is here to prevent.
            Button(role: .destructive) { deleting = entry } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            if entry.isDirectory {
                Button { renaming = entry; renameText = entry.name } label: {
                    Label("Rename", systemImage: "pencil")
                }
                .tint(.gray)
            } else {
                Button { Task { await pull(entry) } } label: {
                    Label("Pull", systemImage: "arrow.down.to.line")
                }
                .tint(.gray)
            }
        }
        .contextMenu {
            if !entry.isDirectory {
                Button { Task { await preview(entry) } } label: {
                    Label("Quick Look", systemImage: "eye")
                }
                Button { Task { await pull(entry) } } label: {
                    Label("Pull to This Device", systemImage: "arrow.down.to.line")
                }
                Divider()
            }
            Button { renaming = entry; renameText = entry.name } label: {
                Label("Rename", systemImage: "pencil")
            }
            Button(role: .destructive) { deleting = entry } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    /// The grey line under a name.  A directory says what it is; a file says how
    /// big and how old, because that is the pair a person is looking for when
    /// they are trying to tell two similarly named files apart — and the
    /// modification date was being read off the entry and thrown away.
    private func subtitle(for entry: AfcFsEntry) -> String {
        if let link = entry.linkTarget { return "Symlink → \(link)" }
        guard !entry.isDirectory else { return "Folder" }
        let size = AfcFileExplorer.format(entry.size)
        guard let modified = entry.modified else { return size }
        return "\(size) · \(Self.dateText(modified))"
    }

    /// Finder's date vocabulary rather than a locale dump: today and yesterday are
    /// named, and anything older is a plain date.  The formatter is built once —
    /// `DateFormatter` construction is expensive enough to show up in a list that
    /// draws a row per file.
    private static let dateText: (Date) -> String = {
        let calendar = Calendar.current
        let time: DateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "HH:mm"
            return f
        }()
        let day: DateFormatter = {
            let f = DateFormatter()
            f.dateStyle = .medium
            f.timeStyle = .none
            return f
        }()
        return { date in
            if calendar.isDateInToday(date) { return "Today, \(time.string(from: date))" }
            if calendar.isDateInYesterday(date) { return "Yesterday, \(time.string(from: date))" }
            return day.string(from: date)
        }
    }()

    private func volumeRow(_ volume: AfcFsVolumeInfo) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "internaldrive")
                .foregroundStyle(.secondary)
            Text("\(AfcFileExplorer.format(volume.freeBytes)) free of "
                 + "\(AfcFileExplorer.format(volume.totalBytes))")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    // MARK: - Actions

    private func open(_ entry: AfcFsEntry) {
        guard entry.isDirectory else { return }
        path.append(entry.name)
        Task { await load() }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            entries = ordered(try await AfcFileExplorer.children(of: AfcFileExplorer.join(path)))
            volume = try? await AfcFileExplorer.volume()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Folders first under every order, then the order itself.  Done here rather
    /// than in `AfcFileExplorer` because it is a view preference — the sort is
    /// remembered per install, not per device.
    private func ordered(_ listed: [AfcFsEntry]) -> [AfcFsEntry] {
        let folders = listed.filter(\.isDirectory)
        let files = listed.filter { !$0.isDirectory }
        func byName(_ a: AfcFsEntry, _ b: AfcFsEntry) -> Bool {
            a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        switch sort {
        case .name:
            return folders.sorted(by: byName) + files.sorted(by: byName)
        case .size:
            return folders.sorted(by: byName) + files.sorted {
                $0.size == $1.size ? byName($0, $1) : $0.size > $1.size
            }
        case .date:
            return folders.sorted(by: byName) + files.sorted {
                // Undated entries sort last rather than first: `nil` compares as
                // "no opinion", and a file the device did not timestamp is the one
                // a date sort should not be leading with.
                switch ($0.modified, $1.modified) {
                case let (a?, b?): return a == b ? byName($0, $1) : a > b
                case (nil, _?): return false
                case (_?, nil): return true
                case (nil, nil): return byName($0, $1)
                }
            }
        }
    }

    private func preview(_ entry: AfcFsEntry) async {
        busy = true
        pullProgress = 0
        defer { busy = false; pullProgress = nil }
        do {
            // A preview is a pull, so it says so before it starts: AFC exposes no
            // read the previewer can seek in, which means a 40 MB video is 40 MB
            // over the wire and 40 MB in the temp directory before the first
            // frame. Hiding that behind a tap would be the surprise.
            status = "Fetching \(entry.name) · \(AfcFileExplorer.format(entry.size)) to preview"
            let local = try await AfcFileExplorer.pullToTemporaryFile(entry) { fraction in
                Task { @MainActor in pullProgress = fraction }
            }
            error = nil
            preview = Preview(url: local)
            status = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func pull(_ entry: AfcFsEntry) async {
        busy = true
        pullProgress = 0
        defer { busy = false; pullProgress = nil }
        do {
            let local = try await AfcFileExplorer.pull(entry) { fraction in
                Task { @MainActor in pullProgress = fraction }
            }
            status = "Pulled \(entry.name) → \(local.lastPathComponent)"
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func push(_ url: URL) async {
        busy = true
        defer { busy = false }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let entry = try await AfcFileExplorer.push(url, to: AfcFileExplorer.join(path))
            status = "Uploaded \(entry.name)"
            error = nil
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func createFolder() async {
        busy = true
        defer { busy = false }
        let name = newFolderName
        newFolderName = ""
        do {
            try await AfcFileExplorer.makeDirectory(named: name, in: AfcFileExplorer.join(path))
            error = nil
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func performRename() async {
        guard let entry = renaming else { return }
        let text = renameText
        renaming = nil
        renameText = ""
        busy = true
        defer { busy = false }
        do {
            try await AfcFileExplorer.rename(entry, to: text)
            error = nil
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func performDelete() async {
        guard let entry = deleting else { return }
        deleting = nil
        busy = true
        defer { busy = false }
        do {
            try await AfcFileExplorer.delete(entry)
            status = "Deleted \(entry.name)"
            error = nil
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Quick Look, hosted.
///
/// The system previewer is the whole point: a plist previews as a plist, a
/// video plays with a scrubber, an image opens in the real Photos viewer, and
/// none of that is ours to write. `QLPreviewController` is a `UIViewController`,
/// so it needs a `UIViewControllerRepresentable` to sit in a sheet — the one
/// piece of UIKit this page is written in.
private struct QuickLookPreview: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {}

    /// `QLPreviewControllerDataSource` and not `QLPreviewDataSource`: the latter is
    /// the macOS spelling of the same protocol, and QuickLook on iOS only has the
    /// first one.
    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL

        init(url: URL) { self.url = url }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(_ controller: QLPreviewController,
                               previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}
