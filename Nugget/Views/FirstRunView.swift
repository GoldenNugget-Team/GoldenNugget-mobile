import SwiftUI
import UIKit

/// The one-time setup guide: put a loopback VPN tunnel up, put a pairing record
/// in place, then let the user in.
///
/// Two prerequisites, in this order, because they are a chain. The app reaches the
/// device through a loopback tunnel (`Tunnel`), so with no tunnel there is
/// nothing for a pairing record to connect over — and with no pairing record
/// there is no device to reach, which is why the home page's `startMinimuxer()`
/// waits for the tunnel before it hands anything to minimuxer. Guiding the steps
/// in the order they unblock each other is the difference between a guide and a
/// list.
///
/// **Every check is one the app can actually make**, and neither step guesses:
///
///   * the VPN step is judged by the interface and the peer probe `Tunnel` itself
///     probes with — a real tunnel carrying a real lockdown port, not a guess
///     made from a bundle ID the app cannot read;
///   * the pairing step is judged by a record at `AppPaths.pairingFile` that
///     passes the same `PairingRecord` rule the restore path applies.
///
/// There is no "install" button, and that is deliberate rather than unfinished.
/// The app has no installer to call: `installation_proxy` lives in the vendored
/// `IdeviceGateway` and is not bridged into this target, and the profile route
/// this app would otherwise use is not available either — `SkipSetup` documents
/// the same wall for `MobileConfigService`. A button that promises to install an
/// app it cannot install is worse than an honest set of instructions, so the step
/// says what to install and what to type into it.
struct FirstRunView: View {
    /// Present when the guide is a page pushed from Settings rather than the
    /// app's own gate. Only then is there a way out that is not "finish", and
    /// only then does the finish button have somewhere to return to.
    var onClose: (() -> Void)?

    @ObservedObject private var firstRun = FirstRunSettings.shared
    /// Shared because the advertisement outlives this page: the user leaves for
    /// Settings → Developer Mode to confirm it, and a `NavigationSplitView`
    /// replaces the detail on every selection.
    @ObservedObject private var wirelessPair = WirelessPairing.shared
    @Environment(\.scenePhase) private var scenePhase

    /// The tunnel step. A live probe rather than a stored answer — see `probe()`.
    @State private var tunnel: TunnelStep = .unchecked
    /// Whether a usable pairing record is in place.
    @State private var pairingReady = PairingRecord.onDisk() != nil
    @State private var showPairingImporter = false
    @State private var errorText: String?

    /// The tunnel step, as the app can actually observe it.
    ///
    /// `.peerUnreachable` is deliberately **not** a failure state: the interface
    /// is up, so the VPN is on and something else — LocalDevVPN's own service —
    /// has yet to answer on the peer port. `Tunnel.waitForTunnel` waits for
    /// exactly this, and reporting it as an error would tell a user whose tunnel
    /// is working that it is not.
    private enum TunnelStep: Equatable {
        /// Not probed yet, or the last probe was interrupted.
        case unchecked
        /// No interface carries the tunnel IP: the VPN app is not connected.
        case interfaceMissing
        /// Interface up, peer port not answering yet.
        case peerUnreachable
        /// The tunnel is carrying lockdown traffic — `startMinimuxer` will go on.
        case ready

        var text: String {
            switch self {
            case .unchecked: return "Not checked yet"
            case .interfaceMissing: return "No tunnel — \(Tunnel.ifaceIP) is not on any interface"
            case .peerUnreachable: return "Tunnel interface is up, waiting for \(Tunnel.peerIP):\(Tunnel.servicePort)"
            case .ready: return "Tunnel is up — \(Tunnel.peerIP):\(Tunnel.servicePort) answered"
            }
        }

        var isReady: Bool { self == .ready }
    }

    var body: some View {
        List {
            introSection
            tunnelSection
            pairingSection
            finishSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Set Up")
        .navigationBarTitleDisplayMode(.inline)
        // No `goldenSidebarButton()`: there is no sidebar behind this page in
        // either state. As the gate this is the root; as a Settings page it is
        // pushed onto the detail stack, where the bar already carries "back".
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

    // MARK: - Sections

    private var introSection: some View {
        Section {
            HStack(spacing: 16) {
                NativeLogo(size: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Set up GoldenNugget")
                        .font(.title3.bold())
                    Text("Two things before the app can reach this device.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
            NativeNote("If the tunnel was connected after the app had already started, "
                + "close and reopen GoldenNugget once — it decides whether to start its own "
                + "emulated tunnel at launch, and that decision is made once.")
        }
    }

    /// Step 1: the tunnel, with the values to type into LocalDevVPN.
    ///
    /// The configuration line is the same `Tunnel.requirements` string the home
    /// page's diagnostics and its tunnel-failure alert print, so the guide and
    /// the diagnostics cannot disagree about what a working tunnel looks like —
    /// including when the user has overridden the addressing.
    private var tunnelSection: some View {
        Section("1 · LocalDevVPN tunnel") {
            stepStatus(done: tunnel.isReady, text: tunnel.text)
            Text(Tunnel.requirements)
                .font(.footnote.monospaced())
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                UIPasteboard.general.string = Tunnel.requirements
            } label: {
                Label("Copy these values", systemImage: "doc.on.doc")
            }
            Button {
                Task { await probe() }
            } label: {
                Label("Check again", systemImage: "arrow.clockwise")
            }
            NativeNote("Install LocalDevVPN (or any equivalent tunnel app) on this iPhone, "
                + "then switch it on and enter the values above: the tunnel IP is this "
                + "device's own address in the tunnel, and the peer is the other end. "
                + "Leave the tunnel on — GoldenNugget needs it for every connection, and "
                + "this app cannot install a VPN app or a configuration profile itself.")
            if tunnel == .interfaceMissing {
                NativeNote("No interface carries \(Tunnel.ifaceIP). The most common cause "
                    + "is the VPN app being connected to the wrong network, or its tunnel "
                    + "IP left at its own default.")
            }
            if Tunnel.isCustomised {
                NativeSafetyNote("Custom tunnel values are in use (see Tunnel settings on "
                    + "the home page). These must match the ones in LocalDevVPN.")
            }
        }
    }

    /// Step 2: a pairing record, from the PC or from the phone itself.
    private var pairingSection: some View {
        Section("2 · Pairing") {
            stepStatus(done: pairingReady,
                       text: pairingReady
                        ? "A pairing record is in place"
                        : "No pairing record yet")
            if wirelessPair.isRunning {
                wirelessPairProgress
            } else {
                Button {
                    showPairingImporter = true
                } label: {
                    Label("Import pairing file", systemImage: "doc.badge.plus")
                }
                Button {
                    wirelessPair.start()
                } label: {
                    Label("Pair without a computer", systemImage: "wifi")
                }
            }
            NativeNote("To pair with a computer: connect this iPhone over USB, tap Trust when "
                + "it asks, and run the computer's pairing tool against it — for example "
                + "idevicepair from libimobiledevice, or Sideloadly. The tool writes a "
                + ".mobiledevicepairing file; send that file to this phone (AirDrop, or save it "
                + "in iCloud Drive) and import it above.")
            NativeNote("Or pair without a computer: iOS 27 lets the phone pair with itself, "
                + "which is what the second button does. That record is this app's own — a "
                + "computer still needs its own record, imported the first way.")
        }
    }

    private var finishSection: some View {
        Section {
            NativeNote(canFinish
                ? "Both are ready. Finishing connects to the device and opens the home page; "
                    + "the record here is the one it reads."
                : "The tunnel and the pairing record are both required. Finish stays greyed "
                    + "out until both are ready — a home page that cannot connect is the "
                    + "state this guide exists to prevent.")
            NativePrimaryButton(title: "Finish setup", systemImage: "checkmark", disabled: !canFinish) {
                firstRun.complete(reason: "tunnel and pairing record both ready")
                onClose?()
            }
            Button("Skip setup for now") {
                firstRun.complete(reason: "skipped by the user")
                onClose?()
            }
            .foregroundStyle(.secondary)
            NativeNote("Skipping is not a dead end: this guide is in Settings afterwards.")
        }
    }

    // MARK: - Pieces

    /// One step's verdict: a tick, a spinner-free cross, and the sentence saying
    /// which of the two it is. The wording is the step's whole value here — an
    /// icon alone would leave a user who cannot see the screen colour with no way
    /// to tell which of the two checks failed.
    private func stepStatus(done: Bool, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(done ? Color.green : Color.secondary)
                .accessibilityHidden(true)
            Text(text)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    /// The in-flight wireless pairing. Drawn in place of the two acquire buttons,
    /// because the advertisement blocks until the device connects — this row's
    /// jobs are to say the host is up, show a PIN if the device asks for one, and
    /// offer a way out so a pairing that never connects does not look frozen.
    private var wirelessPairProgress: some View {
        VStack(alignment: .leading, spacing: 8) {
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
                NativeNote("Confirm this PIN on the device to finish pairing.")
            } else {
                NativeNote("Leave this screen open. iOS 27 connects this iPhone to the "
                    + "advertised pairing service itself — no computer is involved.")
            }
            Button(role: .destructive) {
                wirelessPair.cancel()
            } label: {
                Label("Cancel pairing", systemImage: "xmark.circle")
            }
        }
    }

    private var canFinish: Bool { tunnel.isReady && pairingReady }

    // MARK: - Actions

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