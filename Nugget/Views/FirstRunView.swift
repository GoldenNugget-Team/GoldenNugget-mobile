import SwiftUI
import UIKit

/// The one-time setup guide: put a loopback VPN tunnel up, put a pairing record
/// in place, then let the user in.
///
/// A four-slide `TabView` (art in `FirstRunArt.swift`): Welcome with live step
/// cards, Tunnel with the values for LocalDevVPN, Pairing — the desktop app's
/// Mobile Helper first, then import / iOS 27 self-pairing as fallbacks — and
/// Finish. Order follows the dependency chain: the app reaches the device
/// through the tunnel, so no tunnel → nothing for a pairing record to connect
/// over → no device for minimuxer.
///
/// Both checks are ones the app can actually make: the VPN step is judged by
/// the interface and peer probe `Tunnel` performs, the pairing step by a
/// record at `AppPaths.pairingFile` passing the same `PairingRecord` rule the
/// restore path applies. There is deliberately no "install" button — this
/// target cannot install (`installation_proxy` is not bridged in), so the
/// tunnel slide says what to install and what to type into it instead.
struct FirstRunView: View {
    /// Non-nil when the guide is pushed from Settings rather than the gate:
    /// only then can the user leave without finishing setup.
    var onClose: (() -> Void)?

    @ObservedObject private var firstRun = FirstRunSettings.shared
    /// Shared: the advertisement outlives this page (Settings → Developer Mode).
    @ObservedObject private var wirelessPair = WirelessPairing.shared
    @Environment(\.scenePhase) private var scenePhase

    /// The tunnel step. A live probe rather than a stored answer — see `probe()`.
    @State private var tunnel: TunnelStep = .unchecked
    /// Whether a usable pairing record is in place.
    @State private var pairingReady = PairingRecord.onDisk() != nil
    @State private var showPairingImporter = false
    @State private var errorText: String?
    /// The slide number, swiped by the user or animated to by a step-card tap.
    @State private var page = 0
    /// The last slide's index; `Finish` and `Skip` live below it.
    private let lastPage = 3

    /// The tunnel step, as the app can actually observe it. `.peerUnreachable`
    /// is not a failure: the interface is up, the peer service is just not
    /// answering yet — `Tunnel.waitForTunnel` waits on exactly this.
    private enum TunnelStep: Equatable {
        /// Not probed yet, or the last probe was interrupted.
        case unchecked
        /// No interface carries the tunnel IP: the VPN app is not connected.
        case interfaceMissing
        /// Interface up, peer port not answering yet.
        case peerUnreachable
        /// The tunnel is carrying lockdown traffic — `startMinimuxer` will go on.
        case ready

        /// The long verdict, carrying the values it judged — for the log.
        var text: String {
            switch self {
            case .unchecked: return "Not checked yet"
            case .interfaceMissing: return "No tunnel — \(Tunnel.ifaceIP) is not on any interface"
            case .peerUnreachable: return "Tunnel interface is up, waiting for \(Tunnel.peerIP):\(Tunnel.servicePort)"
            case .ready: return "Tunnel is up — \(Tunnel.peerIP):\(Tunnel.servicePort) answered"
            }
        }

        /// The short verdict a status pill can carry.
        var shortText: String {
            switch self {
            case .unchecked: return "Not checked yet"
            case .interfaceMissing: return "Tunnel not connected"
            case .peerUnreachable: return "Waiting for the tunnel's other end"
            case .ready: return "Tunnel is up"
            }
        }

        var isReady: Bool { self == .ready }
    }

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                welcomeSlide.tag(0)
                tunnelSlide.tag(1)
                pairingSlide.tag(2)
                finishSlide.tag(3)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            footer
        }
        .background(FirstRunBackground())
        .navigationTitle("Set Up")
        .navigationBarTitleDisplayMode(.inline)
        // No menu button: there is no sidebar behind this page in either state.
        // As the gate this is the root; as a Settings page it is pushed onto a
        // stack, where the bar already carries "back".
        .toolbar {
            if let onClose {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Close") { onClose() }
                }
            }
        }
        .task {
            pairingReady = PairingRecord.onDisk() != nil
            await probe()
        }
        // Coming back from Settings is when a tunnel that was just switched on
        // becomes visible, and nothing in this process is told when an interface
        // appears — so the re-check is on foreground, not only on appear.
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await probe()
        }
        // Re-probe until it is ready: the user's half of this step happens in
        // another app, so this screen would otherwise sit on "no tunnel" for as
        // long as they took. The `id` stops the loop the moment it succeeds, so a
        // working setup costs no more probes.
        .task(id: tunnel.isReady) {
            while !tunnel.isReady, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                await probe()
            }
        }
        .fileImporter(isPresented: $showPairingImporter, allowedContentTypes: PairingRecord.types) { result in
            switch result {
            case .success(let url):
                importRecord(from: url)
            case .failure(let error):
                errorText = error.localizedDescription
            }
        }
        // A pairing file arriving as a link (AirDrop, Files "Open in"), which is
        // how it usually reaches a phone.
        .onOpenURL { url in
            guard PairingRecord.hasKnownExtension(url.pathExtension) else { return }
            importRecord(from: url)
        }
        // The wireless pairing wrote a record of its own; adopt it through the
        // same contract an import goes through.
        .onChange(of: wirelessPair.generatedRecordPath) { _, path in
            adoptGeneratedRecord(at: path)
        }
        .alert("Setup", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK") {}
        } message: {
            Text(errorText ?? "?")
        }
    }

    // MARK: - Footer

    /// The chrome under the slides: back, the dots, the forward action — and
    /// on the last slide the two ways out. `Finish` lives here so it can never
    /// be scrolled away.
    private var footer: some View {
        VStack(spacing: 12) {
            HStack {
                if page == 0 {
                    // The first slide's leading edge carries the exit instead of
                    // a back button there is nothing to go back to.
                    Button("Skip setup for now") { skip() }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Button {
                        withAnimation(.snappy) { page -= 1 }
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.body.weight(.semibold))
                            .frame(width: 44, height: 44)
                            .background(.quaternary, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Previous slide")
                }
                Spacer()
                HStack(spacing: 6) {
                    ForEach(0...lastPage, id: \.self) { index in pageDot(index) }
                }
                Spacer()
                if page < lastPage {
                    Button {
                        withAnimation(.snappy) { page += 1 }
                    } label: {
                        HStack(spacing: 6) {
                            Text(page == 0 ? "Get started" : "Continue")
                            Image(systemName: "chevron.right")
                        }
                        .font(.body.weight(.semibold))
                        .padding(.horizontal, 16)
                        .frame(height: 44)
                        .background(.quaternary, in: Capsule())
                    }
                    .buttonStyle(.plain)
                } else {
                    // Width-balances the back button so the dots stay centred on
                    // the last slide too.
                    Color.clear
                        .frame(width: 44, height: 44)
                        .accessibilityHidden(true)
                }
            }
            if page == lastPage {
                NativePrimaryButton(title: "Finish setup", systemImage: "checkmark", disabled: !canFinish) {
                    finish()
                }
                Button("Skip setup for now") { skip() }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                NativeNote("Skipping is not a dead end: this guide is in Settings afterwards.")
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    /// One of the four dots; the live one stretches into a capsule.
    private func pageDot(_ index: Int) -> some View {
        Capsule()
            .fill(index == page ? Color.accentColor : Color(.tertiaryLabel))
            .frame(width: index == page ? 20 : 7, height: 7)
            .animation(.spring(duration: 0.25), value: page)
            .accessibilityLabel("Slide \(index + 1) of \(lastPage + 1)")
            .accessibilityHidden(index != page)
    }

    // MARK: - Slides

    /// Slide 0: what the app does, plus the two steps as live cards that jump
    /// to their slide — the same probes as below, one name per state.
    private var welcomeSlide: some View {
        SlideLayout(
            art: { FirstRunWelcomeArt(active: page == 0) },
            title: "GoldenNugget",
            subtitle: "Restyle this iPhone's SpringBoard, status bar and daemons. Two steps stand in front of it.")
        {
            VStack(alignment: .leading, spacing: 12) {
                stepCard(number: 1, title: "Tunnel", done: tunnel.isReady,
                         working: tunnel == .peerUnreachable, status: tunnel.shortText,
                         destination: 1)
                stepCard(number: 2, title: "Pairing", done: pairingReady,
                         working: wirelessPair.isRunning,
                         status: pairingReady ? "Pairing record in place" : "No pairing record yet",
                         destination: 2)
                NativeNote("The PC version does step 2 for you — plug this iPhone in over USB and open GoldenNugget's “Mobile Helper”.")
                NativeNote("If the tunnel was connected after the app started, close and reopen GoldenNugget once.")
            }
        }
    }

    /// Slide 1: the tunnel. `Tunnel.requirements` is the same string the home
    /// page's diagnostics print, so the two cannot disagree.
    private var tunnelSlide: some View {
        SlideLayout(
            art: { FirstRunTunnelArt(ready: tunnel.isReady, active: page == 1) },
            title: "1 · Tunnel",
            subtitle: "Install LocalDevVPN (or any tunnel app), enter the values below, and leave it on — every connection needs it.")
        {
            VStack(alignment: .leading, spacing: 12) {
                statusPill(done: tunnel.isReady, working: tunnel == .peerUnreachable,
                           text: tunnel.shortText)
                Text(Tunnel.requirements)
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(Color(.secondarySystemBackground),
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                HStack(spacing: 10) {
                    Button {
                        UIPasteboard.general.string = Tunnel.requirements
                    } label: {
                        Text("Copy these values")
                    }
                    .buttonStyle(.bordered)
                    Button {
                        Task { await probe() }
                    } label: {
                        Label("Check again", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                }
                if tunnel == .interfaceMissing {
                    NativeNote("No interface carries \(Tunnel.ifaceIP) — the VPN app may be "
                        + "on the wrong network, or its tunnel IP left at default.")
                }
                if Tunnel.isCustomised {
                    NativeSafetyNote("Custom tunnel values are in use (Tunnel settings on the "
                        + "home page) — they must match LocalDevVPN.")
                }
            }
        }
    }

    /// Slide 2: a pairing record — the desktop app's Mobile Helper first, then
    /// the two fallbacks (import; iOS 27 self-pairing).
    private var pairingSlide: some View {
        SlideLayout(
            art: { FirstRunPairArt(linked: pairingReady, active: page == 2) },
            title: "2 · Pairing",
            subtitle: "The PC version's Mobile Helper is the easiest route. The two cards below are fallbacks.")
        {
            VStack(alignment: .leading, spacing: 12) {
                statusPill(done: pairingReady, working: wirelessPair.isRunning,
                           text: pairingReady ? "Pairing record in place" : "No pairing record yet")
                if wirelessPair.isRunning {
                    wirelessCard
                } else {
                    helperCard
                    actionCard(icon: "doc.badge.plus", title: "Import pairing file",
                               subtitle: "Made on a computer — AirDrop, Files, iCloud Drive") {
                        showPairingImporter = true
                    }
                    actionCard(icon: "wifi", title: "Pair without a computer",
                               subtitle: "iOS 27+ — on iOS 26, use a file from a computer") {
                        wirelessPair.start()
                    }
                    NativeNote("No helper? Pair on a computer (idevicepair, Sideloadly — "
                        + "tap Trust when the phone asks), send the .mobiledevicepairing file "
                        + "here, and import it above. The helper's “Save Pairing File to "
                        + "Disk” works the same way.")
                }
            }
        }
    }

    /// The desktop app's route, as an informative card — the work happens in
    /// another app on another machine, so it must not read as a button. Its
    /// file lands exactly where `PairingRecord.adoptFromDisk` reads it, and
    /// the slide's check turns green on its own after that.
    private var helperCard: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "desktopcomputer")
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 34)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text("The PC version does this for you")
                    .font(.headline)
                Text("Connect this iPhone over USB and tap Trust, then open "
                    + "GoldenNugget on the computer — iOS → “GoldenNugget Mobile "
                    + "Helper”. It installs the app and sends the pairing file itself.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                NativeNote("Send the file while the app is closed, then reopen it.")
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color(.secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    /// Slide 3: both verdicts and the buttons out; the confetti follows
    /// `canFinish`, never promising a finish the button refuses.
    private var finishSlide: some View {
        SlideLayout(
            art: { FirstRunFinishArt(ready: canFinish, active: page == lastPage) },
            title: "All set",
            subtitle: "Finishing connects to the device and opens the home page.")
        {
            VStack(alignment: .leading, spacing: 12) {
                stepCard(number: 1, title: "Tunnel", done: tunnel.isReady,
                         working: tunnel == .peerUnreachable, status: tunnel.shortText,
                         destination: 1)
                stepCard(number: 2, title: "Pairing", done: pairingReady,
                         working: wirelessPair.isRunning,
                         status: pairingReady ? "Pairing record in place" : "No pairing record yet",
                         destination: 2)
                NativeNote("Finish also starts copying this device's photos and videos in the "
                    + "background — “Restore media” on the home page puts it back after a reset.")
                if !canFinish {
                    NativeNote("Finish stays greyed out until both steps are ready.")
                }
            }
        }
    }

    // MARK: - Pieces

    /// A step card (welcome/finish slides): number, name, short verdict, and a
    /// tap that jumps to the step's slide.
    private func stepCard(number: Int, title: String, done: Bool, working: Bool,
                          status: String, destination: Int) -> some View {
        Button {
            withAnimation(.snappy) { page = destination }
        } label: {
            HStack(spacing: 12) {
                Text("\(number)")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(done ? Color.green : Color.accentColor)
                    .frame(width: 30, height: 30)
                    .background(.quaternary, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(status)
                        .font(.footnote)
                        .foregroundStyle(done ? Color.green : working ? Color.orange : Color.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
            .background(Color(.secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens this step's slide")
    }

    /// A pairing-slide action as a full-width card (two halves truncate at
    /// large Dynamic Type sizes).
    private func actionCard(icon: String, title: String, subtitle: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
            .background(Color(.secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    /// A step's verdict as a pill: done (green), working (orange), not yet.
    private func statusPill(done: Bool, working: Bool = false, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: done ? "checkmark.circle.fill" : working ? "ellipsis.circle.fill" : "circle.dashed")
                .foregroundStyle(done ? Color.green : working ? Color.orange : Color.secondary)
                .accessibilityHidden(true)
            Text(text)
                .font(.subheadline.weight(.medium))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.quinary, in: Capsule())
    }

    /// The in-flight wireless pairing: host status, PIN if asked, cancel.
    private var wirelessCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ProgressView()
                Text(wirelessPair.serviceName
                        .map { "Advertising “\($0)” — waiting for this iPhone to connect…" }
                     ?? "Starting the pairing service…")
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let pin = wirelessPair.pin {
                Text("PIN: \(pin)")
                    .font(.title3.monospaced().weight(.semibold))
                    .textSelection(.enabled)
                NativeNote("Confirm it in Settings → Privacy & Security → Developer "
                    + "Mode → “Pair with \(WirelessPairing.displayName)”.")
            } else {
                NativeNote("Leave this open, then above on this iPhone: Settings → Privacy "
                    + "& Security → Developer Mode → “Pair with "
                    + "\(WirelessPairing.displayName)”.")
            }
            Button(role: .destructive) {
                wirelessPair.cancel()
            } label: {
                Label("Cancel pairing", systemImage: "xmark.circle")
            }
        }
        .padding(12)
        .background(Color(.secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var canFinish: Bool { tunnel.isReady && pairingReady }

    // MARK: - Actions

    /// Leave the guide with both steps satisfied, and start the copy.
    private func finish() {
        firstRun.complete(reason: "tunnel and pairing record both ready")
        // Start the photo/video copy here, while the tunnel is known to
        // be up and the user is still on a screen that explains it. The
        // order matters: the record is already complete, so a pull that
        // outlives this page is not tied to it. The engine waits for
        // minimuxer before it touches AFC, which is why this call can
        // happen before the home page's `.task` starts it.
        GoldenNuggetEngine.shared.startAutomaticMediaPull(
            reason: "setup finished", force: true)
        onClose?()
    }

    /// Leave the guide without the setup; the gate's log tells the two ways out
    /// apart, and everything here stays reachable from Settings.
    private func skip() {
        firstRun.complete(reason: "skipped by the user")
        onClose?()
    }

    /// Fill the tunnel step's state, off the main actor.
    ///
    /// `Task.detached` on purpose: `probePeer` waits for the peer's lockdown port,
    /// and this runs from a view body-adjacent task that the user is scrolling —
    /// the same two-second stall the home page's `refreshTunnelStatus()` is written
    /// to avoid, in a place with nowhere to hide it.
    private func probe() async {
        let (interfaceUp, peerReachable) = await Task.detached(priority: .utility) {
            (Tunnel.isInterfaceUp(), Tunnel.probePeer(timeout: 1.0))
        }.value
        let next: TunnelStep = interfaceUp ? (peerReachable ? .ready : .peerUnreachable) : .interfaceMissing
        if next != tunnel {
            GoldenNuggetEngine.shared.log("setup guide: tunnel — \(next.text)")
        }
        tunnel = next
    }

    /// Import a record and record it the way the home page's import does.
    ///
    /// The home page adopts it on its first `.task`, reading the canonical file
    /// first — so this deliberately does **not** start anything itself: two
    /// starters would be the duplicate-start race `startMinimuxer`'s lock was added
    /// to prevent.
    private func importRecord(from url: URL) {
        do {
            let record = try PairingRecord.accept(contentsOf: url)
            PairingRecord.persist(record)
            pairingReady = true
            GoldenNuggetEngine.shared.log("setup guide: pairing file imported "
                + "(\(PairingRecord.sourceLabel(record)), \(record.count) bytes)")
        } catch {
            errorText = error.localizedDescription
            GoldenNuggetEngine.shared.log("setup guide: pairing file import failed "
                + "(\(url.lastPathComponent)): \(error.localizedDescription)")
        }
    }

    /// Take the record the wireless pairing produced.
    ///
    /// Routed through `PairingRecord` either way — the library's own file is the
    /// canonical one, so it is adopted in place rather than rewritten, and a
    /// library that wrote somewhere else is imported like any other file. Both
    /// paths apply `usable(_:)`, so a record produced inside the app gets the same
    /// rejection a picked file would.
    private func adoptGeneratedRecord(at path: String?) {
        guard let path else { return }
        defer { wirelessPair.reset() }
        do {
            let record = path == AppPaths.pairingFile.path
                ? try PairingRecord.adoptFromDisk()
                : try PairingRecord.accept(contentsOf: URL(fileURLWithPath: path))
            if path != AppPaths.pairingFile.path { PairingRecord.persist(record) }
            pairingReady = true
            GoldenNuggetEngine.shared.log("setup guide: wireless pairing record adopted "
                + "(\(PairingRecord.sourceLabel(record)))")
        } catch {
            errorText = error.localizedDescription
            GoldenNuggetEngine.shared.log("setup guide: wireless pairing record rejected — "
                + "\(error.localizedDescription)")
        }
    }
}

// MARK: - Slide scaffolding

/// One slide's frame: illustration, title, subtitle, then the content — which
/// scrolls when Dynamic Type or a small phone leaves it no room, while the
/// illustration keeps its space and stays the slide's face.
private struct SlideLayout<Art: View, Content: View>: View {
    @ViewBuilder var art: () -> Art
    var title: LocalizedStringKey
    var subtitle: LocalizedStringKey
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            art()
                .padding(.top, 16)
            VStack(spacing: 8) {
                Text(title)
                    .font(.largeTitle.weight(.bold))
                Text(subtitle)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, 24)
            .padding(.top, 4)
            .padding(.bottom, 20)
            ScrollView(.vertical) {
                content()
                    .padding(.horizontal, 24)
                    .padding(.bottom, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// The slides' backdrop: the system background with one quiet accent wash from
/// the top, behind every slide. Semantic colours only — the wash fades to
/// nothing rather than to a fixed colour, so dark mode needs no second version.
private struct FirstRunBackground: View {
    var body: some View {
        ZStack {
            Color(.systemBackground)
            LinearGradient(colors: [Color.accentColor.opacity(0.10), .clear],
                           startPoint: .top,
                           endPoint: UnitPoint(x: 0.5, y: 0.6))
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}
