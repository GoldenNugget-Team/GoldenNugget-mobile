import SwiftUI
import UIKit

/// Apple Wallet card skins.
///
/// A card's artwork is not a preference — it lives inside the pass, and Passbook
/// caches the rendered layers next to it, so writing a skin is two operations and
/// both have to happen. That, and the fact that neither can be carried by a
/// backup, is why this page exists next to the other AirLift pages rather than
/// inside the tweaks list.
///
/// The layout follows AirCard's card tab: a live scanner banner, then one
/// realistic Wallet card mockup (1.586:1) per card with its controls underneath,
/// and the flash action in the toolbar. The page is deliberately explicit about
/// the one thing it cannot do for the user: a card identifier has to come from
/// somewhere, and the only source is Passbook's own log while a card is held to
/// the reader. There is no "read my cards" button, because there is no API for
/// it.
struct WalletView: View {
    @State private var identity: DeviceIdentity = .unknown
    @State private var cards: [WalletCard] = []
    @State private var log: [String] = []
    @State private var status: String?
    @State private var tone: GoldenTone = .secondary
    @State private var running = false
    @State private var scanning = false
    @State private var stopScan: (() -> Void)?
    /// The picker's delegate, held here.
    ///
    /// `UIImagePickerController.delegate` is a weak reference, and the controller
    /// does not retain it either — a delegate created inline is deallocated
    /// before the picker ever appears, which is why the compiler points at
    /// `[weak self]` and says the capture is always nil. Holding it in `@State`
    /// is what makes the callback reachable; it is released when the pick
    /// finishes.
    @State private var pickerDelegate: ImagePickerDelegate?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                scannerBanner
                blockerBanner

                if cards.isEmpty && !scanning {
                    emptyState
                } else {
                    cardsList
                    if !log.isEmpty { logCard }
                }
            }
            .padding(.vertical)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(cards.isEmpty ? "Wallet" : "Wallet Cards (\(cards.count))")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    toggleScan()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: scanning ? "stop.circle.fill" : "wave.3.left.circle")
                        Text(scanning ? "Stop Scan" : "Scan Cards")
                    }
                    .font(.subheadline.bold())
                    .foregroundStyle(scanning ? .red : .blue)
                }
                .disabled(!canScan && !scanning)
            }

            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        applyToAll()
                    } label: {
                        Label("Set Skin for All Cards", systemImage: "photo.on.rectangle.angled")
                    }
                    .disabled(selectedCount == 0)

                    Button {
                        setAllSelected(true)
                    } label: {
                        Label("Select All", systemImage: "checkmark.circle")
                    }
                    Button {
                        setAllSelected(false)
                    } label: {
                        Label("Deselect All", systemImage: "circle")
                    }

                    Divider()

                    Button(role: .destructive) {
                        clearAll()
                    } label: {
                        Label("Clear All Cards", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.title3)
                }
                .disabled(cards.isEmpty)
            }

            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    apply()
                } label: {
                    HStack(spacing: 6) {
                        if running {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                .scaleEffect(0.75)
                            Text("Flashing…")
                        } else {
                            Image(systemName: "bolt.fill")
                            Text("Flash")
                        }
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 4)
                    .frame(minHeight: 28)
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .disabled(running || selectedCount == 0)
            }
        }
        .task {
            identity = await DeviceIdentity.read()
            // The identifiers are worth keeping across launches; see
            // `WalletCardStore`. A card that is found twice is not added twice,
            // and a stored skin is kept for a card that is found again.
            cards = WalletCardStore.load()
        }
        .onDisappear { stopScan?(); stopScan = nil; scanning = false }
    }

    private var blocker: String {
        let reason = Airlift.unsupportedReason(deviceVersion: identity.version)
        if !reason.isEmpty { return reason }
        if !FileManager.default.fileExists(atPath: AppPaths.pairingFile.path) {
            return "AirLift needs a pairing record and none is stored. Import one on the home page."
        }
        return ""
    }

    private var selectedCount: Int {
        cards.filter { $0.isSelected && $0.hasImage }.count
    }

    private var canScan: Bool {
        blocker.isEmpty && !running
    }

    // MARK: - Banners

    @ViewBuilder
    private var scannerBanner: some View {
        if scanning || status != nil {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    if scanning {
                        ProgressView().scaleEffect(0.85)
                        Text("Live Scanner Active")
                            .font(.subheadline.bold())
                            .foregroundStyle(.blue)
                    } else {
                        Image(systemName: "wave.3.left.circle")
                            .foregroundStyle(.secondary)
                        Text("Status")
                            .font(.subheadline.bold())
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if scanning {
                        Button("Stop") { toggleScan() }
                            .font(.caption.bold())
                            .buttonStyle(.borderedProminent)
                            .tint(.red)
                            .controlSize(.small)
                    }
                }
                if let status {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(tone.nativeColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
            .background(scanning ? Color.blue.opacity(0.12)
                                 : Color(uiColor: .secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal)
        }
    }

    @ViewBuilder
    private var blockerBanner: some View {
        if !blocker.isEmpty {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                NativeSafetyNote(blocker)
                Spacer(minLength: 0)
            }
            .padding(14)
            .background(Color(uiColor: .secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal)
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 18) {
            Image(systemName: "creditcard.viewfinder")
                .font(.system(size: 56))
                .foregroundStyle(.blue.opacity(0.8))

            Text("No Cards Detected Yet")
                .font(.title3.bold())

            VStack(alignment: .leading, spacing: 10) {
                step("1.", "Tap **Scan Cards** in the toolbar above.")
                step("2.", "Hold a card against the reader while it listens.")
                step("3.", "The card appears here — tap it to assign a skin.")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding(16)
            .background(Color(uiColor: .secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal, 24)

            Button {
                toggleScan()
            } label: {
                HStack(spacing: 6) {
                    Spacer()
                    Image(systemName: scanning ? "stop.circle.fill" : "wave.3.left.circle")
                    Text(scanning ? "Stop Scan" : "Scan Cards")
                    Spacer()
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
            }
            .buttonStyle(.borderedProminent)
            .tint(scanning ? .red : .blue)
            .disabled(!canScan && !scanning)
            .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    private func step(_ number: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(number).bold().foregroundStyle(.blue)
            Text(LocalizedStringKey(text))
        }
    }

    // MARK: - Cards

    private var cardsList: some View {
        VStack(spacing: 16) {
            ForEach(cards) { card in
                WalletCardRow(
                    card: card,
                    index: cards.firstIndex(where: { $0.id == card.id }) ?? 0,
                    onToggleSelected: { toggleSelected(card.id, $0) },
                    onPickImage: { pickImage(for: card.id) },
                    onClearImage: { clearImage(card.id) },
                    onDelete: { delete(card.id) })
            }
        }
        .padding(.horizontal)
    }

    private var logCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Flash Log (\(log.count) lines)").font(.subheadline.bold())
                Spacer()
                Button("Clear") { log.removeAll() }.font(.caption)
            }
            ForEach(Array(log.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Mutations

    private func toggleSelected(_ id: String, _ isOn: Bool) {
        guard let index = cards.firstIndex(where: { $0.id == id }) else { return }
        cards[index].isSelected = isOn
        WalletCardStore.save(cards)
    }

    private func setAllSelected(_ isOn: Bool) {
        for index in cards.indices { cards[index].isSelected = isOn }
        WalletCardStore.save(cards)
    }

    private func clearImage(_ id: String) {
        guard let index = cards.firstIndex(where: { $0.id == id }) else { return }
        cards[index].imageData = nil
        WalletCardStore.save(cards)
    }

    private func delete(_ id: String) {
        cards.removeAll { $0.id == id }
        WalletCardStore.save(cards)
    }

    private func clearAll() {
        cards.removeAll()
        WalletCardStore.save(cards)
    }

    private func applyToAll() {
        let image = cards.first(where: { $0.hasImage })?.imageData
        guard let image else { return }
        for index in cards.indices { cards[index].imageData = image }
        WalletCardStore.save(cards)
    }

    // MARK: - Scanning

    private func toggleScan() {
        if scanning {
            stopScan?()
            stopScan = nil
            scanning = false
            return
        }
        scanning = true
        log = []
        status = "Listening. Hold a card against the reader."
        tone = .secondary
        Task { @MainActor in
            do {
                // The syslog callback is not on the main actor, so the hop is where
                // the card is recorded rather than in the delegate: `add` writes
                // `@State`, and `@State` is main-actor state.
                let stop = try await WalletEngine.scanCards(
                    pairingPath: AppPaths.pairingFile.path
                ) { identifier in
                    Task { @MainActor in self.add(identifier) }
                }
                stopScan = stop
            } catch {
                scanning = false
                status = error.localizedDescription
                tone = .error
            }
        }
    }

    private func add(_ identifier: String) {
        guard !cards.contains(where: { $0.id == identifier }) else { return }
        cards.append(WalletCard(id: identifier))
        WalletCardStore.save(cards)
        status = "Found \(identifier.prefix(10))…"
        tone = .primary
    }

    // MARK: - Apply

    private func apply() {
        running = true
        log = []
        Task { @MainActor in
            defer { running = false }
            do {
                try await WalletEngine.apply(
                    cards: cards,
                    pairingPath: AppPaths.pairingFile.path,
                    log: { line in Task { @MainActor in log.append(line) } },
                    progress: { _ in }
                )
                status = "Card skins applied."
                tone = .primary
            } catch {
                status = error.localizedDescription
                tone = .error
            }
        }
    }

    // MARK: - Image picking

    private func pickImage(for identifier: String) {
        let picker = UIImagePickerController()
        picker.sourceType = .photoLibrary
        picker.allowsEditing = false
        let delegate = ImagePickerDelegate { image in
            pickerDelegate = nil
            guard let image,
                  let data = WalletSkinEngine.prepareForStorage(image),
                  let index = cards.firstIndex(where: { $0.id == identifier }) else { return }
            cards[index].imageData = data
            WalletCardStore.save(cards)
        }
        picker.delegate = delegate
        pickerDelegate = delegate
        PickerHost.present(picker)
    }
}

/// One card as AirCard draws it: the artwork mockup, then the control bar.
///
/// Adapted from AirCard's `WalletCardView`. The card is a 1.586:1 Wallet-shaped
/// tile — the real skin when one is assigned, a dashed "assign a skin" placeholder
/// otherwise — with the selection switch, the identifier pill (tap to copy) and
/// the delete button underneath.
private struct WalletCardRow: View {
    let card: WalletCard
    let index: Int
    let onToggleSelected: (Bool) -> Void
    let onPickImage: () -> Void
    let onClearImage: () -> Void
    let onDelete: () -> Void

    @State private var copied = false

    private var image: UIImage? { card.imageData.flatMap { UIImage(data: $0) } }

    var body: some View {
        VStack(spacing: 12) {
            artwork
                .aspectRatio(1.586, contentMode: .fit)
            controlBar
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(card.isSelected ? Color.blue.opacity(0.35) : Color.clear, lineWidth: 1.5)
        )
    }

    private var artwork: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = width / 1.586

            ZStack {
                if let image {
                    ZStack(alignment: .topTrailing) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: width, height: height)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                        LinearGradient(
                            colors: [.white.opacity(0.18), .clear, .black.opacity(0.12)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                        Button(action: onClearImage) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 24))
                                .foregroundStyle(.white.opacity(0.95))
                                .background(Circle().fill(Color.black.opacity(0.55)))
                        }
                        .buttonStyle(.plain)
                        .padding(10)
                    }
                } else {
                    placeholder
                }
            }
            .frame(width: width, height: height)
            .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
            .contentShape(Rectangle())
            .onTapGesture { onPickImage() }
        }
    }

    private var placeholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(uiColor: .secondarySystemBackground),
                            Color(uiColor: .tertiarySystemBackground)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(
                    Color.secondary.opacity(0.25),
                    style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
                )

            VStack(alignment: .leading) {
                HStack {
                    Image(systemName: "wave.3.right")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary.opacity(0.6))
                    Spacer()
                    Image(systemName: "creditcard")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary.opacity(0.5))
                }
                .padding(14)
                Spacer()
            }

            VStack(spacing: 8) {
                Image(systemName: "photo.badge.plus")
                    .font(.system(size: 32))
                    .foregroundStyle(.blue)
                Text("Assign Card Skin")
                    .font(.subheadline.bold())
                    .foregroundStyle(.primary)
                Text("Tap to choose photo")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var controlBar: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(get: { card.isSelected }, set: onToggleSelected))
                .labelsHidden()

            Text("Card #\(index + 1)")
                .font(.system(size: 13, weight: .semibold))

            HStack(spacing: 4) {
                Text(card.id.prefix(8) + "…" + card.id.suffix(6))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)

                Button {
                    UIPasteboard.general.string = card.id
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                } label: {
                    Image(systemName: copied ? "checkmark.circle.fill" : "doc.on.doc")
                        .font(.system(size: 10))
                        .foregroundStyle(copied ? .green : .secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(uiColor: .systemFill))
            .clipShape(Capsule())

            Spacer()

            if card.hasImage {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.system(size: 14))
            }

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 4)
    }
}

/// Bridges a `UIImagePickerController` into the SwiftUI tree.
///
/// The page cannot hold the controller itself — a `UIViewControllerRepresentable`
/// has to own it, and the picker must be presented from the key window's top
/// view controller, which a SwiftUI page does not have a handle on.
private final class ImagePickerDelegate: NSObject, UIImagePickerControllerDelegate,
                                      UINavigationControllerDelegate {
    private let onPick: (UIImage?) -> Void
    init(onPick: @escaping (UIImage?) -> Void) { self.onPick = onPick }

    func imagePickerController(_ picker: UIImagePickerController,
                               didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
        onPick(info[.originalImage] as? UIImage)
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        onPick(nil)
    }
}

enum PickerHost {
    static func present(_ controller: UIViewController) {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        guard let root = scene?.windows.first(where: \.isKeyWindow)?.rootViewController
                ?? scene?.windows.first?.rootViewController else { return }
        var top = root
        while let presented = top.presentedViewController { top = presented }
        top.present(controller, animated: true)
    }
}
