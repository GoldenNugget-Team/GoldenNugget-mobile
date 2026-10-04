import SwiftUI
import UniformTypeIdentifiers
import Minimuxer
import Foundation

/// The home page, laid out the way the reference's iOS home page lays it out
/// (`src/gui/ios/home.py`): logo header carrying the device line and a refresh
/// button → the connection status line → Apply Tweaks → the danger action → the
/// centred process-status line.  What this app needs on top of that (pairing
/// file, tunnel, diagnostics, log) sits below, because the reference keeps all of
/// it on its own pages.
///
/// There is no feature-card grid here.  The reference's home page opens its
/// sections from cards, but this app has a sidebar, and the two were reaching the
/// same five destinations by different routes — the cards now that the sidebar
/// exists they are a second copy of a list the user is already looking at, and
/// the copy that goes stale is the one on the page they are reading.  The
/// sections are reachable from the sidebar and from nowhere else.
struct GoldenNuggetView: View {
    @AppStorage("PairingFile") var pairingFileRaw: String?
    // The tunnel addressing, persisted under the same keys `Tunnel` reads (see
    // `Tunnel.Key`), so the fields below and every probe are looking at one set
    // of values.  `@AppStorage` rather than `@State` because the tunnel is
    // probed from background queues and from `NuggetApp.init` — a value that
    // only lived in the view would not be there when it is read.
    @AppStorage(Tunnel.Key.ifaceIP) var tunnelIfaceIP = Tunnel.defaultIfaceIP
    @AppStorage(Tunnel.Key.peerIP) var tunnelPeerIP = Tunnel.defaultPeerIP
    @AppStorage(Tunnel.Key.port) var tunnelPort = String(Tunnel.defaultServicePort)
    @AppStorage(Tunnel.Key.prefixLength) var tunnelPrefixLength = String(Tunnel.defaultPrefixLength)
    @State private var pairingFileURL: String?
    /// Whether the sidebar is a column of its own or a stack behind the detail —
    /// see `navBarVisibility`.
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    /// Launch auto-start bookkeeping for `reimportPairingFile()`, **owned by
    /// `RootView`**: `startMinimuxer`'s lock only rejects *concurrent* attempts,
    /// so these have to outlive the view that reads them even though what they
    /// guard is process-wide.  `didAutoStart` keeps a second `.task` pass from
    /// starting the core twice.
    ///
    /// `autoImportDisabled` is the user's "Reset pairing file" saying no — and
    /// unlike `didAutoStart` it is **persisted** (`@AppStorage` in `RootView`),
    /// because an in-memory reset was undone by the very next launch.  Cleared
    /// again by a successful import; see `loadPairingFile`.
    @Binding var didAutoStart: Bool
    @Binding var autoImportDisabled: Bool
    @State private var running = false
    @State private var showPairingImporter = false
    /// The on-device wireless-pairing service.  Shared because the advertisement
    /// outlives this page (a `NavigationSplitView` replaces the detail on every
    /// selection), and the page is only its UI.
    @ObservedObject private var wirelessPair = WirelessPairing.shared
    @State private var showRebootNotice = false
    // The run log is not page state any more: `RunLog` owns it and `RunLogCard`
    // is the only observer, so a logged line no longer re-evaluates this
    // page's `body` (see `RunLog`'s note — that is where the per-line disk
    // read came from).

    @State private var errorText: String?
    @State private var runStarted: Date?
    /// The tweak selection, owned by `RootView` because a `NavigationSplitView`
    /// replaces its detail view on every sidebar selection: as page state it
    /// would have been discarded the moment another destination was picked.
    @Binding var tweakSelection: TweakSelection
    /// What the PosterBoard page has assembled, hoisted for the same reason and read
    /// here because **this is the one Apply**: the wallpapers ride the same pass as the
    /// tweaks, exactly as the reference's single `_apply_tweak_pass` carries them.
    @Binding var posterBoardSelection: PosterBoardSelection
    /// The status-bar page's selection, hoisted for the same reason: it is edited
    /// on its own page and delivered by the Apply here.
    @Binding var statusBarSelection: StatusBarSelection
    /// The pending debounced autosave, cancelled and replaced on every change.
    @State private var autosaveTask: Task<Void, Never>?
    /// The device line's data, from the shared monitor rather than as page state.
    ///
    /// It was `@State` filled once by `readDevice()`, which made it a snapshot with
    /// a short life: the header said "unknown device" until the bounded wait in
    /// `readDevice` succeeded, and nothing after that ever asked again.  Naming the
    /// observed object something other than `device` because `scheduleAutosave()`
    /// and `applyTweaks()` both take a local snapshot called `device`.
    @ObservedObject private var deviceMonitor = DeviceIdentityMonitor.shared
    /// Every use below reads this, so the page has no identity of its own to keep in
    /// step with the monitor — one source of truth, four pages, one poll.
    private var identity: DeviceIdentity { deviceMonitor.current }
    @State private var readingDevice = false
    /// `home.py: process_status_lbl` — the coloured line under the buttons, which
    /// the reference hides again six seconds after it was set.
    @State private var status = ""
    @State private var statusTone: GoldenTone = .primary
    /// Bumped by every status write so a hide scheduled for an older message
    /// cannot wipe the one that replaced it.
    @State private var statusToken = 0
    @State private var progress: Double?
    /// The pages the reset sheet has open, and whether a reset is in flight.
    ///
    /// Separate from `running`, which is the *apply* run: the two never overlap
    /// (a reset and an apply both write preferences), and a single flag would
    /// have the Apply button report a reset's progress as its own.
    @State private var showResetSheet = false
    @State private var resetting = false
    @State private var tunnelExpanded = false
    /// The tunnel status line's two halves, **cached** rather than computed in
    /// the body.
    ///
    /// `Tunnel.describe()` and — much worse — `Tunnel.probePeer()` used to be
    /// interpolated straight into the disclosure's `Text`.  `probePeer` is a
    /// non-blocking connect followed by a `poll()` that waits **up to two
    /// seconds** (`timeout: 2.0`) for the peer's lockdown port, and it ran on the
    /// main thread on **every** body pass: scrolling the page, any state change,
    /// or tapping a `NavigationLink` (the page re-renders while the destination is
    /// pushed).  A two-second stall inside body evaluation is the reported freeze.
    ///
    /// `refreshTunnelStatus()` fills both, off the main actor, and only while the
    /// disclosure is open.
    @State private var tunnelSummary = "not probed"
    @State private var peerReachable: Bool?

    /// Explicit, so `AppShell.swift` gets a signature it can depend on.
    ///
    /// The synthesized memberwise initializer covers these four (they are the
    /// only stored properties without a default), but its parameters come out in
    /// **declaration order** — `didAutoStart:autoImportDisabled:tweakSelection:`
    /// — so the call site would silently depend on where each one happens to sit
    /// among a dozen other properties, and moving one breaks a different file.
    /// Everything else keeps its default.
    ///
    /// Note this initializer is also why one was needed at all: a custom `init()`
    /// suppresses the memberwise one, and the only `init()` this struct used to
    /// have (a `UIDocumentPickerViewController` swizzle) could not initialize
    /// these — which surfaced as "return from initializer without initializing
    /// all stored properties".
    init(tweakSelection: Binding<TweakSelection>,
         posterBoardSelection: Binding<PosterBoardSelection>,
         statusBarSelection: Binding<StatusBarSelection>,
         didAutoStart: Binding<Bool>,
         autoImportDisabled: Binding<Bool>) {
        _tweakSelection = tweakSelection
        _posterBoardSelection = posterBoardSelection
        _statusBarSelection = statusBarSelection
        _didAutoStart = didAutoStart
        _autoImportDisabled = autoImportDisabled
    }

    var body: some View {
        List {
            header
            connectionLine
            applyCard
            clearCard
            if !status.isEmpty { processStatus }
            connectionSection
            diagnosticsSection
            RunLogCard()
        }
        .listStyle(.insetGrouped)
        .navigationTitle("GoldenNugget")
        // Compact widths only -- on a tablet the split view draws its own sidebar
        // toggle, and a second button beside it is the duplicate-controls mess.
        .goldenSidebarButton()
        .navigationBarTitleDisplayMode(.inline)
        // The home page carries its own logo header, so the platform bar would be
        // a second, empty one.  Hiding it *here* — not on the pushed page — keeps
        // the Tweaks page's bar, and with it the interactive swipe-back gesture,
        // exactly as the reference's `IOSNavBar` has them.
        //
        // Except when the split view is collapsed (`.compact`: Slide Over, a
        // third of the screen): there the same bar is the **only** way back to
        // the sidebar, and hiding it would strand the user on this page.
        .toolbar(navBarVisibility, for: .navigationBar)
        // Owned here, next to the selection itself, rather than inside one of the
        // pages that can change it. It was on TweaksView, which made persistence
        // depend on navigation: a daemon switched on the Daemons page changed the
        // selection while the only observer sat in a view that was not in the
        // hierarchy, so nothing was written. It looked intermittent, because
        // touching any tweak afterwards swept the daemon along with it.
        .onChange(of: tweakSelection) { _, _ in scheduleAutosave() }
        // Probe only while the tunnel details are open, and never in a body: the
        // probe can wait two seconds for the peer, and two seconds on the main
        // thread is a frozen scroll.  `.task(id:)` cancels the loop when the
        // disclosure closes.
        .task(id: tunnelExpanded) {
            guard tunnelExpanded else { return }
            while !Task.isCancelled {
                await refreshTunnelStatus()
                try? await Task.sleep(for: .seconds(5))
            }
        }
        .task {
            spawnLogPrinter()
            // The Rust progress callbacks fire on their own queues; the handler
            // hops to the main actor itself.  `NaN` is the "run finished, drop
            // the percentage" signal — see `GoldenNuggetEngine.clearProgress`.
            GoldenNuggetEngine.shared.onProgress = { value in
                Task { @MainActor in progress = value.isNaN ? nil : value }
            }
            // Claim the process-wide Rust logger before anything can call
            // setLogging()/start(): the Rust side latches the first
            // idevice_init_logger call and would otherwise keep file logging off.
            GoldenNuggetEngine.shared.enableRustFileLogging()
            // The first term is the *persisted* "the user said no to this
            // record" flag, so a reset survives the relaunch that used to undo
            // it; a successful import clears it again.
            if !autoImportDisabled, reimportPairingFile(), !didAutoStart {
                didAutoStart = true
                startMinimuxer()
            }
            await readDevice()
        }
        .onOpenURL { url in
            guard Self.isPairingFileExtension(url.pathExtension) else { return }
            importPairingFile(from: url)
        }
        // A wireless pairing that succeeded has already written the record to
        // `AppPaths.pairingFile`; adopt it through the one contract every other
        // record enters by, then drop the terminal state so the button is live.
        .onChange(of: wirelessPair.generatedRecordPath) { _, path in
            adoptGeneratedPairingFile(at: path)
        }
        .alert("Error", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK") {}
        } message: {
            Text(errorText ?? "?")
        }
        .alert("Applied", isPresented: $showRebootNotice) {
            Button("OK") {}
        } message: {
            Text("Reboot the target device so the injected preferences take effect.")
        }
        .sheet(isPresented: $showResetSheet) {
            ResetPagesSheet(deviceVersion: identity.version,
                            isRunning: resetting,
                            onReset: performReset(pages:))
        }
    }

    // MARK: - Sections

    /// `.hidden` in a regular width, where the sidebar is already on screen;
    /// `.automatic` in a compact one, where the bar carries the control that
    /// reveals it.
    private var navBarVisibility: Visibility {
        horizontalSizeClass == .compact ? .automatic : .hidden
    }


    /// `home.py`'s header row: logo, title, and the device line under it.
    ///
    /// The reference puts a device picker next to the title and a refresh button
    /// after it.  There is no picker to put here — this app drives exactly one
    /// device — so the refresh button is the whole control, and it is worth
    /// having: the device line is read from lockdown, and a page that was opened
    /// before the tunnel was up kept saying "unknown device" until it was left
    /// and re-entered.
    private var header: some View {
        Section {
            HStack(spacing: 16) {
                NativeLogo(size: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text("GoldenNugget")
                        .font(.title2.bold())
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text(identity.describe)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                Button {
                    Task {
                        await readDevice()
                        await refreshTunnelStatus()
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 18, weight: .medium))
                }
                .buttonStyle(.borderless)
                .disabled(!(paired && !readingDevice))
            }
            .padding(.vertical, 4)
        }
    }

    /// `home.py: update_status` — the same three states in the same colours:
    /// green "Supported!", amber "Partially Supported" when a pairing file is
    /// loaded but lockdown has not said what the device is, plain
    /// "Not connected" otherwise.
    private var connectionLine: some View {
        Section {
            Text(connectionState.text)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(connectionState.tone.nativeColor)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private var connectionState: (text: String, tone: GoldenTone) {
        guard paired else { return ("Not connected", .secondary) }
        guard !identity.version.isEmpty else { return ("Partially Supported", .warning) }
        return ("Supported!", .success)
    }

    /// The reference's apply card (`IOSApplyPage`: a description, the button, and
    /// a progress line) in the place its home page puts the button — directly
    /// under the status line, which is where the cards used to sit.
    private var applyCard: some View {
        Section {
            NativeNote(applyNote)
            NativePrimaryButton(title: running ? "Applying…" : applyTitle,
                                running: running,
                                disabled: !canApply) {
                applyTweaks()
            }
            if running {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    let secs = Int(ctx.date.timeIntervalSince(runStarted ?? ctx.date))
                    Text(elapsedText(secs))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                // The engine has reported whole-percent progress all along and
                // this view has been storing it in `progress` without ever
                // showing it, which left a multi-minute AirLift injection
                // looking exactly like a hung one.
                progressView
                // A stall guard that waits minutes for a device that may be
                // wedged is only safe if it can be stopped by hand. A blocked
                // Rust read cannot be interrupted, so this abandons the call
                // and unwinds: the guard notices the flag at its next poll.
                NativeDangerButton(title: "Stop run") {
                    GoldenNuggetEngine.shared.requestCancel()
                }
            }
        }
    }

    /// The run's percentage, as a bar and a number.
    ///
    /// `progress` is nil until the engine reports one, which is not the same as
    /// zero — an unknown start is shown as an indeterminate bar rather than an
    /// empty one claiming no work has been done.
    private var progressView: some View {
        VStack(alignment: .leading, spacing: 6) {
            ProgressView(value: progress ?? 0, total: 100)
                .progressViewStyle(.linear)
                .opacity(progress == nil ? 0.35 : 1)
            Text(progress == nil ? "working…" : String(format: "%.0f%%", progress ?? 0))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// The reference's home-page `reset_btn` (`home.py:178`): the same
    /// "Reset Tweaks" label, opening the same page picker
    /// (`home.reset_tweaks` → `ResetDialog`).
    ///
    /// It used to be a *local* clear — `tweakSelection.removeAll()` — and that
    /// was the wrong half of the pair. The reference splits the two: this button
    /// resets the **device**, and the Tweaks page's "Clear all tweaks" is the one
    /// that discards the app's own selection. Keeping a local clear under a
    /// device-reset name meant the one destructive button on the page did
    /// nothing to the device while reading as though it had.
    private var clearCard: some View {
        Section {
            NativeNote("Puts whole pages back to stock on the device: the files those "
                + "pages' tweaks are written to are overwritten with what a fresh device has. "
                + "Choose the pages in the next screen.")
            NativeDangerButton(title: "Reset Tweaks",
                               disabled: running || resetting) {
                showResetSheet = true
            }
        }
    }

    /// The sheet's confirm. `pages` is empty when nothing was ticked, which the
    /// sheet's own disabled button makes unreachable — the guard is here so a
    /// future caller cannot start a run that writes nothing.
    private func performReset(pages: Set<ResetPage>) {
        guard !pages.isEmpty else { return }
        resetting = true
        RunLog.shared.clear()
        showStatus("Resetting \(pages.count) page(s)…", .accent, autoHide: false)
        Task {
            var text = ""
            var tone: GoldenTone = .primary
            var succeeded = false
            do {
                try await GoldenNuggetEngine.shared.resetPages(pages: pages)
                text = "Reset done. Reboot the device."
                tone = .success
                succeeded = true
            } catch let failure as TransportFailure where failure.isCancellation {
                text = "⏹ stopped by the user (\(failure.label))"
                tone = .warning
            } catch {
                text = "❌ \(error.localizedDescription)"
                tone = .error
            }
            await MainActor.run {
                resetting = false
                showStatus(text, tone)
                showRebootNotice = succeeded
            }
        }
    }

    /// `home.py: process_status_lbl` — centred, coloured by outcome.
    @ViewBuilder
    private var processStatus: some View {
        Section {
            Text(status)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(statusTone.nativeColor)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private var connectionSection: some View {
        Section("Connection") {
            if paired {
                Button {
                    resetPairing()
                } label: {
                    Label("Reset pairing file", systemImage: "arrow.counterclockwise")
                }
            } else if wirelessPair.isRunning {
                wirelessPairProgress
            } else {
                Button {
                    showPairingImporter.toggle()
                } label: {
                    Label("Select Pairing File", systemImage: "doc.badge.plus")
                }
                // iOS 27 lets the device pair with itself: the service below is
                // discovered by this same phone's RemotePairing daemon, so no
                // computer is needed to produce a record.
                Button {
                    wirelessPair.start()
                } label: {
                    Label("Pair Wirelessly", systemImage: "wifi")
                }
                if case .failed(let message) = wirelessPair.phase {
                    NativeSafetyNote(message)
                }
            }
            tunnelDisclosure
        }
        .fileImporter(isPresented: $showPairingImporter,
                      allowedContentTypes: Self.pairingFileTypes) { result in
            switch result {
            case .success(let url):
                importPairingFile(from: url)
            case .failure(let error):
                errorText = error.localizedDescription
            }
        }
    }

    /// The in-flight wireless pairing, drawn in place of the two acquire buttons.
    ///
    /// The advertisement blocks on the library side until the device connects, so
    /// this row's only jobs are to say the host is up, show the PIN if the device
    /// asks for one, and offer a way out — a pairing that never connects would
    /// otherwise leave the Connection section looking frozen.
    @ViewBuilder
    private var wirelessPairProgress: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ProgressView()
                Text(wirelessPair.serviceName.map { "Advertising “\($0)” — waiting for this iPhone to connect…" }
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
                NativeNote("Leave this screen open. iOS 27 connects this iPhone to the advertised "
                    + "pairing service itself — no computer is involved.")
            }
            Button(role: .destructive) {
                wirelessPair.cancel()
            } label: {
                Label("Cancel pairing", systemImage: "xmark.circle")
            }
        }
    }

    /// The tunnel addressing, folded away by default.
    ///
    /// It is four fields and two paragraphs of explanation, and the reference's
    /// home page carries nothing of the kind — this app's stand-in for the
    /// device picker is the pairing file above it.  Open, it is the same editor
    /// with the same validation; closed, it states the values in use, which is
    /// the part a session that already works never needs to look at twice.
    private var tunnelDisclosure: some View {
        DisclosureGroup(isExpanded: $tunnelExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                NativeNote("How this app finds the LocalDevVPN tunnel: it waits for the "
                    + "tunnel IP on an interface, then probes the peer's lockdown port. "
                    + "\(Tunnel.isCustomised ? "Custom values in use." : "Defaults in use.") "
                    + "These steer this app only — the vendored library finds the peer from the "
                    + "route table and always dials 62078.")
                VStack(alignment: .leading, spacing: 6) {
                    Text("Tunnel IP (this device)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("Tunnel IP (this device)", text: $tunnelIfaceIP)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.numbersAndPunctuation)
                    if !tunnelIfaceIPOK {
                        NativeSafetyNote("Not an IPv4 address — \(Tunnel.defaultIfaceIP) is being probed instead.")
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Peer IP (the VPN server)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("Peer IP (the VPN server)", text: $tunnelPeerIP)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.numbersAndPunctuation)
                    if !tunnelPeerIPOK {
                        NativeSafetyNote("Not an IPv4 address — \(Tunnel.defaultPeerIP) is being probed instead.")
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Lockdown port")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField(String(Tunnel.defaultServicePort), text: $tunnelPort)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        // `.numberPad` has no Return key, so on a phone this
                        // keyboard could not be dismissed at all.
                        .keyboardType(.numberPad)
                        .nativeKeyboardDone()
                    if !tunnelPortOK {
                        NativeSafetyNote("Not a port in 1…65535 — \(Tunnel.defaultServicePort) is being probed instead.")
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Tunnel IP prefix length")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField(String(Tunnel.defaultPrefixLength), text: $tunnelPrefixLength)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        // `.numberPad` has no Return key, so on a phone this
                        // keyboard could not be dismissed at all.
                        .keyboardType(.numberPad)
                        .nativeKeyboardDone()
                    if !tunnelPrefixOK {
                        NativeSafetyNote("Not 0…32 — LocalDevVPN's tunnel-IP field takes a CIDR, and this is the part after the slash.")
                    }
                }
                NativeNote("Copy into LocalDevVPN: tunnel IP \(Tunnel.ifaceIP)/\(Tunnel.ifacePrefixLength), peer \(Tunnel.peerIP), port \(Tunnel.servicePort).")
                // Both values come from state — see `tunnelSummary`.  The probe
                // is a 2 s `poll()` and must never run in a body.
                Text("tunnel: \(tunnelSummary) · peer \(Tunnel.peerIP):\(Tunnel.servicePort) "
                    + "reachable: \(peerReachable.map(String.init) ?? "…")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    Tunnel.resetToDefaults()
                    tunnelIfaceIP = Tunnel.defaultIfaceIP
                    tunnelPeerIP = Tunnel.defaultPeerIP
                    tunnelPort = String(Tunnel.defaultServicePort)
                    tunnelPrefixLength = String(Tunnel.defaultPrefixLength)
                    GoldenNuggetEngine.shared.log("tunnel addresses reset to defaults: \(Tunnel.requirements)")
                    Task { await refreshTunnelStatus() }
                } label: {
                    Label("Reset tunnel addresses", systemImage: "arrow.counterclockwise")
                }
            }
            .padding(.top, 8)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text("Tunnel settings")
                    .font(.headline)
                Text(Tunnel.requirements)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .tint(.accentColor)
    }

    // A value is only "in use" when it survives the same validator `Tunnel`
    // applies before probing, so the field cannot claim to be set to something
    // the app is silently ignoring.
    private var tunnelIfaceIPOK: Bool { Tunnel.isValidIPv4(tunnelIfaceIP) != nil }
    private var tunnelPeerIPOK: Bool { Tunnel.isValidIPv4(tunnelPeerIP) != nil }
    private var tunnelPortOK: Bool { Tunnel.validPort(tunnelPort) != nil }
    private var tunnelPrefixOK: Bool { Tunnel.validPrefixLength(tunnelPrefixLength) != nil }

    private var diagnosticsSection: some View {
        Section("Diagnostics") {
            Button {
                Task {
                    let block = await GoldenNuggetEngine.shared.diagnostics()
                    RunLog.shared.append(block)
                }
            } label: {
                Label("Dump Diagnostics Into Log", systemImage: "doc.text.magnifyingglass")
            }
            .disabled(running)
            // Share sheets beat hand-selecting text: the diagnostics block and
            // the full Rust log are files in Documents.  AirDrop / Save to
            // Files gets them off the device intact.
            shareRow(title: "Share diagnostics.txt",
                     systemImage: "square.and.arrow.up",
                     url: GoldenNuggetEngine.diagnosticsURL,
                     available: hasDiagnostics)
            shareRow(title: "Share minimuxer.log (\(GoldenNuggetEngine.rustLogSize() / 1024) KB)",
                     systemImage: "doc.text.magnifyingglass",
                     url: GoldenNuggetEngine.rustLogURL,
                     available: GoldenNuggetEngine.rustLogSize() > 0)
            // The app-side log is a separate file because it is a separate
            // half of the evidence: the Rust log shows what the protocol did,
            // this one shows what the host decided (filter keeps, commit
            // accounting, staging leftovers).
            shareRow(title: "Share goldennugget.log (\(GoldenNuggetEngine.appLogSize() / 1024) KB)",
                     systemImage: "doc.plaintext",
                     url: GoldenNuggetEngine.appLogURL,
                     available: GoldenNuggetEngine.appLogSize() > 0)
            NativeNote("The dump carries a keyword slice of the Rust log "
                + "(mobilebackup2 protocol + jktcp flow verdict) scoped to this run, plus "
                + "the app log tail (host-side decisions).")
        }
    }

    /// One share action as a row.  Kept in one place so the three cannot drift
    /// apart — the system dims an unavailable `ShareLink` on its own.
    private func shareRow(title: String, systemImage: String, url: URL, available: Bool) -> some View {
        ShareLink(item: url) {
            HStack(spacing: 12) {
                Label(title, systemImage: systemImage)
                Spacer(minLength: 0)
            }
        }
        .foregroundStyle(available ? Color.primary : Color.secondary)
    }

    private var paired: Bool { pairingFileURL != nil }

    /// Either source of work is enough: a run is worth starting when there are tweaks,
    /// when there are wallpapers, or both.
    private var canApply: Bool {
        paired && !running && (tweakSelection.enabledCount > 0 || posterBoardSelection.isActive)
    }

    /// The button is named for what it will actually carry.  "Apply Tweaks" was the
    /// whole truth while the tweaks were the only thing an apply had; the PosterBoard
    /// selection now rides the same pass, and a button that under-reports its own
    /// payload is how a user ends up surprised by a wallpaper they forgot they picked.
    private var applyTitle: String {
        switch (tweakSelection.enabledCount > 0, posterBoardSelection.isActive) {
        case (true, true): return "Apply Tweaks & Wallpapers"
        case (false, true): return "Apply Wallpapers"
        case (true, false): return "Apply Tweaks"
        case (false, false): return "Apply"
        }
    }

    private var applyNote: String {
        var lines = ["Applies every enabled tweak to the device."
            + " Reboot it when this is done — the injected preferences are read at boot."]
        if posterBoardSelection.isActive {
            lines.append("This run also delivers the PosterBoard page's selection "
                + "(\(posterBoardSelection.describe)) — one backup, one restore, the same "
                + "channel. That stage fetches the store's database from the device first, "
                + "so it takes one extra exchange.")
        } else {
            lines.append("Nothing is selected on the PosterBoard page, so this run carries "
                + "only the tweaks.")
        }
        return lines.joined(separator: "\n\n")
    }

    private var hasDiagnostics: Bool {
        FileManager.default.fileExists(atPath: GoldenNuggetEngine.diagnosticsURL.path)
    }

    // MARK: - Behaviour

    /// Forget the pairing record — in memory, and from `UserDefaults`.
    ///
    /// **The file in Documents is deliberately left alone.**  The restore path
    /// reads it first, so a reset that only cleared the two in-memory values was
    /// undone by the next launch; the persisted `autoImportDisabled` flag is
    /// what makes it stick instead of deleting the file.  That is the right
    /// trade for a button that just says "reset": the pairing file may be the
    /// user's only copy, and re-obtaining one costs a re-pair.
    ///
    /// A later import clears the flag again, so this is "stop using it", not
    /// "never use it".
    func resetPairing() {
        pairingFileRaw = nil
        pairingFileURL = nil
        autoImportDisabled = true
        didAutoStart = false
        RunLog.shared.clear()
        // Logged *after* the clear, or this would be the line the clear removes.
        // The reset used to leave no trace anywhere, which is why "the record
        // came back after a restart" was invisible in the one place it could
        // have been seen.
        GoldenNuggetEngine.shared.log("pairing reset: record cleared from memory and UserDefaults; "
            + "\(AppPaths.pairingFile.lastPathComponent) kept on disk, automatic import "
            + "disabled until the next import")
    }

    /// Extensions accepted by the pairing-file picker and the `onOpenURL`
    /// handler.  **One list**: the picker built its array from these names and
    /// the URL handler hard-coded the same three again, so adding a fourth
    /// would have worked in one path and silently not in the other.
    static let pairingFileExtensions = ["mobiledevicepairing", "mobiledevicepair", "mobiledeviceconfig"]

    static let pairingFileTypes: [UTType] = pairingFileExtensions.compactMap {
        UTType(filenameExtension: $0, conformingTo: .data)
    }

    static func isPairingFileExtension(_ ext: String) -> Bool {
        pairingFileExtensions.contains(ext.lowercased())
    }

    /// Whether the app is willing to hand these bytes to minimuxer.
    ///
    /// Deliberately **format-agnostic**: the pairing format belongs to the
    /// library, not to this file.  A pairing record is one of two shapes —
    /// `.rppairing` (`identifier`, `private_key`, `public_key`; iOS 17+
    /// RemotePairing) or `.lockdown` (`UDID`, `SystemBUID`, `EscrowBag`, the
    /// certificates) — and **only the second carries a `UDID`**.
    ///
    /// This used to require a non-empty top-level `UDID` outright, which is a
    /// lockdown-only fact.  On an iOS 17+ device, where the pairing file is an
    /// `.rppairing` record, that check rejected **every file the user could
    /// possibly import**: the import (which checked nothing) accepted it and the
    /// device paired fine, and then the restore path refused the very same bytes
    /// on the next launch and reported "no pairing record" — the pairing file
    /// "disappearing after a restart".  Exactly backwards, and invisible.
    ///
    /// So the app asserts only what it can assert alone: non-empty, a plist, a
    /// non-empty top-level dictionary.  Whether it is a *recognised* record is
    /// `PairingFileParser`'s answer, and the library gives it — naming the
    /// missing keys — from `start()`, whose error this app already surfaces
    /// (see `startMinimuxer`).  Do not reintroduce a key list here: a second
    /// copy of the format's rules is what went wrong the first time.
    static func usablePairingRecord(_ raw: String) -> Bool {
        guard let data = raw.data(using: .utf8),
              let obj = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = obj as? [String: Any]
        else { return false }
        return !dict.isEmpty
    }

    /// What a candidate record actually contains, for the log line — a rejected
    /// record has to be diagnosable from the log alone, because the alternative
    /// on a phone is "minimuxer did not start" with nothing to go on.
    ///
    /// Keys only, no verdict: this used to append `[UDID]` / `[no UDID]`, which
    /// reads as a judgement about validity and is not one — an `.rppairing`
    /// record is valid *without* a `UDID`.
    private static func pairingSourceLabel(_ raw: String) -> String {
        guard let keys = pairingFileTopLevelKeys(raw) else { return "not a parseable plist" }
        return keys.isEmpty ? "(no keys)" : "keys: \(keys.sorted().joined(separator: ", "))"
    }

    /// Make sure a usable pairing record exists on disk, and report whether one
    /// does.  Run on every launch, before `startMinimuxer()`.
    ///
    /// This used to be an `ALTPairingFile` lookup that only fired on a *first*
    /// launch, which broke the app in three ways at once:
    ///
    ///   * `@AppStorage("PairingFile")` is set by that first launch, so on the
    ///     second and every later launch the `pairingFileRaw == nil` guard
    ///     skipped the whole branch — `pairingFileURL` was set, so the UI said
    ///     "connected" while nothing had started the core.  The app looked fine
    ///     and did nothing until the user re-imported by hand.
    ///   * The embedded record was only assigned to a variable, never written to
    ///     `Documents/pairingfile.mobiledevicepairing`, so the file the rest of
    ///     the app (and `AppPaths`) treats as canonical did not exist.
    ///   * `alt.count > 5000` was the only test applied to it.  A real pairing
    ///     record is a few KB, so the threshold silently rejected a perfectly
    ///     good one and accepted a truncated multi-KB blob.  It is replaced by
    ///     `usablePairingRecord`, which checks the shape instead of the size.
    ///
    /// And the validator it uses is **not** a format rule: see
    /// `usablePairingRecord`.  A `UDID`-must-be-present test lived here and
    /// rejected every `.rppairing` record, i.e. every pairing file an iOS 17+
    /// device can use — which is the whole of "the pairing file disappears
    /// after a restart", because the import had accepted it minutes earlier.
    ///
    /// Precedence is deliberate: a pairing file the user imported wins over the
    /// one the installer embedded, because re-pairs are per-device and an
    /// embedded record is a build-time artefact.  Each candidate is validated
    /// before use, so a corrupt file on disk falls through to the next one
    /// instead of blocking the launch.
    @discardableResult
    func reimportPairingFile() -> Bool {
        let dest = AppPaths.pairingFile
        let embedded = Bundle.main.object(forInfoDictionaryKey: "ALTPairingFile") as? String
        // On disk first, then the persisted copy, then the installer's record.
        let candidates: [(source: String, raw: String?)] = [
            ("Documents/pairingfile.mobiledevicepairing", try? String(contentsOf: dest, encoding: .utf8)),
            ("stored PairingFile", pairingFileRaw),
            ("Info.plist ALTPairingFile", embedded),
        ]

        for (source, rawOpt) in candidates {
            guard let raw = rawOpt?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { continue }
            guard Self.usablePairingRecord(raw) else {
                GoldenNuggetEngine.shared.log("pairing record rejected (\(source)): \(Self.pairingSourceLabel(raw))")
                continue
            }
            let onDisk = (try? String(contentsOf: dest, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if onDisk == raw {
                GoldenNuggetEngine.shared.log("pairing record: \(source) (\(Self.pairingSourceLabel(raw)))")
            } else {
                do {
                    try raw.write(to: dest, atomically: true, encoding: .utf8)
                    GoldenNuggetEngine.shared.log("pairing record re-imported from \(source) into \(dest.lastPathComponent) (\(Self.pairingSourceLabel(raw)))")
                } catch {
                    GoldenNuggetEngine.shared.log("pairing record found (\(source)) but could not be written to Documents: \(error.localizedDescription)")
                }
            }
            pairingFileRaw = raw
            pairingFileURL = dest.path
            return true
        }

        // Nothing usable anywhere.  Do not leave a stale path behind: it would
        // make `paired` true and the UI promise a connection that cannot exist.
        pairingFileURL = nil
        if pairingFileRaw != nil {
            pairingFileRaw = nil
            GoldenNuggetEngine.shared.log("stored pairing record was unusable — cleared, import a pairing file to connect")
        } else if embedded == nil {
            GoldenNuggetEngine.shared.log("no pairing record: none on disk, none stored, and the installer embedded no ALTPairingFile")
        }
        return false
    }

    /// Import a pairing record the user picked.
    ///
    /// The contract is **validate → write → read back → only then claim it**,
    /// and each step is here for a way the previous version failed.
    ///
    /// It read the file, wrote it out, and set `pairingFileRaw` /
    /// `pairingFileURL` from whatever it happened to hold — without looking at
    /// the content and without checking that the write landed.  Nothing threw
    /// for content the *restore* path then refused, so a record that came back
    /// empty or truncated (a document-picker URL that is an iCloud/other-app
    /// placeholder read before it was materialised is the common one) was
    /// written as a 0-byte file, reported as a success — the alert only fires on
    /// a thrown error, and `write` does not throw for empty content — and read
    /// back as "no pairing record" on the next launch.
    ///
    /// What it validates **with** matters as much as that it validates: see
    /// `usablePairingRecord`.  Checking the format's rules here is what turned
    /// a working import into a rejected one, so this defers the format verdict
    /// to minimuxer.
    func loadPairingFile(from url: URL) throws {
        // Document-picker URLs are security-scoped: reading one without
        // `startAccessingSecurityScopedResource` fails with "you don't have
        // permission to view it".
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        // Read bytes, not a string: an empty or missing file has to be
        // distinguishable from a decode failure, and both have to be reported
        // in words rather than as a bare Cocoa error.  minimuxer's parser takes
        // text, so anything that is not UTF-8 (a binary plist, say) is refused
        // here instead of being silently mangled on the way to disk.
        let data = try Data(contentsOf: url)
        guard let raw = String(data: data, encoding: .utf8) else {
            throw GoldenNuggetError("\(url.lastPathComponent) is not UTF-8 text "
                + "(\(data.count) bytes). A pairing file has to be an XML plist, which is what "
                + "minimuxer parses — a binary plist has to be converted first.")
        }

        let record = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !record.isEmpty else {
            throw GoldenNuggetError("\(url.lastPathComponent) is empty — nothing to import. "
                + "If it lives in iCloud Drive, open it in Files once so it is downloaded, "
                + "then import it again.")
        }
        guard Self.usablePairingRecord(record) else {
            throw GoldenNuggetError("\(url.lastPathComponent) is not a property list "
                + "(\(Self.pairingSourceLabel(record))). A pairing file has to be an XML plist — "
                + "minimuxer parses nothing else.")
        }

        // Store the **normalised** form: it is what `reimportPairingFile()`
        // compares against on the way back in and what minimuxer is handed, so
        // keeping the untrimmed original would only ever differ by whitespace
        // the restore path silently strips.
        let dest = AppPaths.pairingFile
        try record.write(to: dest, atomically: true, encoding: .utf8)

        // Read it back.  A write that did not land is indistinguishable from one
        // that did until the next launch reads it — which is exactly the delay
        // that made this look like data loss instead of a failed import.
        let onDisk = try String(contentsOf: dest, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard onDisk == record else {
            throw GoldenNuggetError("The pairing file did not survive being written to "
                + "\(dest.lastPathComponent): \(onDisk.count) of \(record.count) bytes came "
                + "back. Import it again.")
        }

        // A successful import is the user's answer to an earlier reset, so the
        // persisted flag goes back down.  Leaving it up would import the record
        // and work *now*, then have every later launch skip the automatic load
        // and come up "unpaired" — the failure the reset fix was about, pointing
        // the other way.
        autoImportDisabled = false
        pairingFileRaw = record
        pairingFileURL = dest.path
        GoldenNuggetEngine.shared.log("pairing file imported: \(Self.pairingSourceLabel(record)) "
            + "→ \(dest.lastPathComponent), \(record.count) bytes, read back OK")
        startMinimuxer()
    }

    /// Run an import from one of the two entry points, reporting a failure the
    /// same way from both.
    ///
    /// The two call sites had their own `do`/`catch` and differed in nothing but
    /// the file name in the alert.  The reason is **also** logged: on a phone
    /// the alert is the only surface a rejected record ever reaches, and it is
    /// gone as soon as it is dismissed.
    func importPairingFile(from url: URL) {
        do {
            try loadPairingFile(from: url)
        } catch {
            errorText = error.localizedDescription
            GoldenNuggetEngine.shared.log("pairing file import failed (\(url.lastPathComponent)): "
                + "\(error.localizedDescription)")
        }
    }

    /// Adopt the record a completed wireless pairing wrote.
    ///
    /// The library writes the paired `.mobiledevicepairing` straight to
    /// `AppPaths.pairingFile`, which is the canonical location the rest of the
    /// app already reads — so this is a hand-off, not a second import path.
    /// Routing it through `loadPairingFile` keeps the validate → write →
    /// read-back → claim contract in one place: a record the library produced but
    /// this app cannot parse is rejected with the same wording a picked file
    /// would get, instead of being trusted because it came from inside the app.
    ///
    /// The pair state is reset afterwards either way, so a failed adoption does
    /// not leave the Connection section stuck on "paired".
    private func adoptGeneratedPairingFile(at path: String?) {
        guard let path else { return }
        defer { wirelessPair.reset() }
        do {
            try loadPairingFile(from: URL(fileURLWithPath: path))
            GoldenNuggetEngine.shared.log("wireless pair: generated record adopted")
        } catch {
            errorText = error.localizedDescription
            GoldenNuggetEngine.shared.log("wireless pair: generated record rejected — "
                + "\(error.localizedDescription)")
        }
    }

    /// Re-read the device line.  Called on entry and by the header's refresh
    /// button, so a page that was opened before the tunnel came up does not sit
    /// on "unknown device" until it is navigated away from.
    /// Write the selection 500 ms after the last change -- the reference's
    /// `_on_tweak_changed` debounce (`QTimer.singleShot(500, ...)`).
    ///
    /// A pending save is replaced, not queued, so dragging a number field writes
    /// once at the end rather than once per keystroke. The document is 130+ specs
    /// of JSON written into Documents, so it goes off the main actor; the snapshot
    /// and the identity are value types, and only the resulting flag comes back.
    private func scheduleAutosave() {
        autosaveTask?.cancel()
        let snapshot = tweakSelection
        let device = identity
        autosaveTask = Task {
            try? await Task.sleep(for: GoldenNuggetAutosave.debounce)
            guard !Task.isCancelled else { return }
            await Task.detached(priority: .utility) {
                GoldenNuggetAutosave.save(snapshot, identity: device)
            }.value
        }
    }

    /// Fill the tunnel status line, off the main actor.
    ///
    /// `Task.detached` on purpose: `probePeer` waits up to two seconds for the
    /// peer's lockdown port, and both halves read process-wide state (`Tunnel`'s
    /// addresses come from `@AppStorage`), so nothing here needs the main actor
    /// until the two assignments.
    private func refreshTunnelStatus() async {
        let (summary, reachable) = await Task.detached(priority: .utility) {
            (Tunnel.describe(), Tunnel.probePeer())
        }.value
        tunnelSummary = summary
        peerReachable = reachable
    }

    private func readDevice() async {
        guard paired else { return }
        readingDevice = true
        // Wait for the device before reading it.  `.task` starts minimuxer and
        // calls this immediately after, so the first read races the gateway
        // coming up and comes back `.unknown` — which used to be logged as "the
        // device has not answered lockdown yet" and then kept for the rest of
        // the session.  An empty identity is not harmless here: it *disables*
        // the registry's version bounds (`TweakSpec.isCompatible` skips them on
        // an empty version, as the reference does) and it parses to major 0,
        // which is how a 27.0 device ended up on the engine's iOS 26 branch and
        // died with `205 — No keybag in manifest` (2026-09-26).  Same bounded
        // poll the rest of the app waits with: fast at first, then backing off.
        var read = await DeviceIdentity.read()
        if read == .unknown {
            let deadline = Date().addingTimeInterval(15)
            var attempt = 0
            var delay: UInt64 = 300_000_000              // 0.3 s -> doubles -> 2 s cap
            while read == .unknown, Date() < deadline {
                attempt += 1
                try? await Task.sleep(nanoseconds: delay)
                delay = min(delay * 2, 2_000_000_000)
                read = await DeviceIdentity.read()
            }
            if read != .unknown {
                GoldenNuggetEngine.shared.log("device identity: lockdownd answered on attempt "
                    + "\(attempt + 1), after the first read raced minimuxer's start")
            }
        }
        readingDevice = false
        // Published, not assigned: the monitor is what the other three pages read,
        // and it is also what logs the change.  Handing it a value we already have
        // avoids the second handshake a `refresh()` here would cost.
        await deviceMonitor.publish(read)
        // Load the selection here rather than when the Tweaks page is built, so
        // this page's own counts see the restored selection instead of zero.
        if let report = AutoSaveBootstrap.apply(into: &tweakSelection, identity: read) {
            for line in report.logLines { GoldenNuggetEngine.shared.log(line) }
        }
    }

    private func applyTweaks() {
        running = true
        runStarted = Date()
        RunLog.shared.clear()
        showStatus("Applying…", .accent, autoHide: false)
        let snapshot = tweakSelection
        let wallpapers = posterBoardSelection
        let statusBar = statusBarSelection
        let device = identity
        Task {
            var text = ""
            var tone: GoldenTone = .primary
            var succeeded = false
            do {
                try await GoldenNuggetEngine.shared.applyTweaks(selection: snapshot,
                                                                posterBoard: wallpapers,
                                                                statusBar: statusBar,
                                                                deviceVersion: device.version,
                                                                isIPhone: device.isIPhone)
                text = "Applied. Reboot the device."
                tone = .success
                succeeded = true
            } catch let failure as TransportFailure where failure.isCancellation {
                // Stopping on purpose is not a failure — say so, and do not let it
                // read like the device did something wrong. The engine has already
                // written both of these into the log file.
                text = "⏹ stopped by the user (\(failure.label))"
                tone = .warning
            } catch {
                text = "❌ \(error.localizedDescription)"
                tone = .error
            }
            await MainActor.run {
                running = false
                runStarted = nil
                showStatus(text, tone)
                showRebootNotice = succeeded
                // The reset is spent. It is deliberately not persisted, and it must not
                // survive its own delivery either — the next run would clear the store
                // again. (The page that used to apply it did this; the Apply lives here
                // now, so the clearing does too.)
                if succeeded {
                    posterBoardSelection.resetModes = []
                    posterBoardSelection.fullReset = false
                }
            }
        }
    }

    /// `styles.py: process_status_*` fades the status line out again
    /// (`home.py`: a 6 s single-shot timer).  The token is what keeps an older
    /// message's timer from clearing a newer one.
    private func showStatus(_ text: String, _ tone: GoldenTone, autoHide: Bool = true) {
        status = text
        statusTone = tone
        statusToken &+= 1
        let token = statusToken
        guard autoHide else { return }
        Task {
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            await MainActor.run { if statusToken == token { status = "" } }
        }
    }

    /// Elapsed time, not just a spinner: this run has stages that legitimately
    /// take minutes, and a spinner alone cannot tell "working" from "hung".
    /// The percentage is the backup stage's own, which is the only stage that
    /// reports one.
    private func elapsedText(_ seconds: Int) -> String {
        let clock = "Elapsed \(seconds / 60)m \(seconds % 60)s"
        guard let progress, !progress.isNaN else { return clock }
        return "\(clock) · backup \(Int(progress))%"
    }

    // MARK: - Connection

    /// Set while a `startMinimuxer()` is running, cleared when it finishes.
    ///
    /// `startMinimuxer` is reachable from `.onAppear`, from every pairing-file
    /// load and from a pairing reset, and each call used to dispatch its own
    /// 60 s tunnel wait onto the global queue.  Four pairing loads in one session
    /// meant four parallel probes writing "waiting for iface…" into the same log
    /// and four `tunnel probe: 60.4s — FAILED` lines — and each of them had to be
    /// picked apart by hand to see there was only ever one tunnel failure.
    private static let startLock = NSLock()
    private static var startInFlight = false

    func startMinimuxer() {
        guard let pairingFileRaw else { return }
        Self.startLock.lock()
        if Self.startInFlight {
            Self.startLock.unlock()
            GoldenNuggetEngine.shared.log("minimuxer start already in progress — ignoring this request")
            return
        }
        Self.startInFlight = true
        Self.startLock.unlock()

        let docs = URL.documents.path(percentEncoded: false)
        DispatchQueue.global(qos: .userInitiated).async { [pairingFileRaw] in
            defer {
                Self.startLock.lock()
                Self.startInFlight = false
                Self.startLock.unlock()
            }
            // SideStore-style pre-start guard: the LocalDevVPN tunnel routes to
            // the emulated peer (10.7.0.1:62078). Probe the tunnel first so the
            // RSD adapter/handshake can reach the device before we start.
            let tunnelStage = StageTimer("tunnel probe")
            guard Tunnel.waitForTunnel(log: { line in GoldenNuggetEngine.shared.log(line) }) else {
                tunnelStage.done("FAILED")
                DispatchQueue.main.async {
                    errorText = "Tunnel not ready: \(Tunnel.peerIP):\(Tunnel.servicePort) unreachable.\n\n\(Tunnel.requirements)"
                }
                return
            }
            tunnelStage.done("reachable")
            Task {
                do {
                    // FIRST, before setLogging()/start(): the Rust logger latches
                    // on the first idevice_init_logger call in the process, and
                    // setLogging(true) below installs console=Error/file=OFF.
                    GoldenNuggetEngine.shared.enableRustFileLogging()
                    let minimuxer = Minimuxer.shared()
                    minimuxer.core.setLogging(true)
                    minimuxer.core.setDeviceProbeTimeout(3000)
                    // Bind the localVPN connection mode.
                    //
                    // The setters used to be `{ _ in }`: the connection manager
                    // auto-discovers the utun peer from the route table, so
                    // whatever it resolved was dropped on the floor.  They are
                    // recorded now (see `Tunnel.reported`) — the diagnostics block
                    // prints them next to the app's own probe, which is the only
                    // way to tell "the VPN is on another subnet" from "the library
                    // looked at a different address than the app did".
                    Tunnel.resetReported()
                    await minimuxer.core.bindConnectionConfig(ConnectionConfigBinding(
                        setTunnelIfaceIp: { value in Tunnel.noteReported { $0.ifaceIP = value } },
                        setTunnelPeerIp: { value in Tunnel.noteReported { $0.peerIP = value } },
                        setTunnelPeerSubnetMask: { value in Tunnel.noteReported { $0.peerSubnetMask = value } },
                        setTunnelPeerReachable: { value in Tunnel.noteReported { $0.peerReachable = value } },
                        setTunnelIfaceSubnetMask: { value in Tunnel.noteReported { $0.ifaceSubnetMask = value } },
                        getRemoteServerIp: { "" },
                        setRemoteReachable: { _ in },
                        getOverrideTunnelPeerIp: { "" },
                        setOverrideTunnelPeerReachable: { _ in },
                        getConnectionMode: { .localVPN }
                    ))
                    // Diagnostic: show the record's real keys, so a wrong or
                    // unrecognised pairing file is obvious instead of a bare
                    // error.  **No verdict is attached.**  This used to print
                    // "[UDID OK]" / "[NO UDID — start() will fail]", which is a
                    // lockdown-only rule and reads as a failure for the
                    // perfectly valid `.rppairing` record an iOS 17+ device
                    // uses.  The authoritative verdict comes from `start()` on
                    // the next line, which names whatever keys are missing.
                    // `await` is load-bearing, not decorative: this runs on a
                    // `DispatchQueue.global` task while `View` is `@MainActor`,
                    // so it is the hop that keeps the call legal.
                    if let keys = await Self.pairingFileTopLevelKeys(pairingFileRaw) {
                        GoldenNuggetEngine.shared.log("pairing file top-level keys: \(keys.isEmpty ? "(empty)" : keys.sorted().joined(separator: ", "))")
                    } else {
                        GoldenNuggetEngine.shared.log("pairing file: NOT a parseable plist")
                    }
                    try await minimuxer.core.start(pairingFile: pairingFileRaw, mountPath: docs)
                    // Readiness wait, deadline-bounded.  This used to be
                    // 20 × 1 s of flat sleeps, so every pairing-file load (and
                    // every app launch with ALTPairingFile) paid up to 20 s
                    // before anything else could happen.  Poll fast at first,
                    // then back off, and stop at a hard deadline.
                    let readyStage = StageTimer("minimuxer readiness")
                    var isReady = false
                    let deadline = Date().addingTimeInterval(20)
                    var poll = 0
                    var delay: UInt64 = 200_000_000   // 0.2 s -> doubles -> 2 s cap
                    while Date() < deadline {
                        poll += 1
                        if case .success(true) = await minimuxer.core.isReady() {
                            isReady = true
                            break
                        }
                        try await Task.sleep(nanoseconds: delay)
                        delay = min(delay * 2, 2_000_000_000)
                    }
                    readyStage.done("ready=\(isReady) after \(poll) poll(s)")
                    GoldenNuggetEngine.shared.log("minimuxer started. ready=\(isReady)")
                    if !isReady {
                        let tail = RustLog.tail()
                        GoldenNuggetEngine.shared.log("minimuxer.log tail:\n\(tail)")
                        DispatchQueue.main.async {
                            errorText = "minimuxer started but never became ready.\n\nLast minimuxer.log lines:\n\(tail)"
                        }
                    }
                } catch {
                    let tail = RustLog.tail()
                    GoldenNuggetEngine.shared.log("minimuxer.log tail:\n\(tail)")
                    DispatchQueue.main.async {
                        errorText = "\(error.localizedDescription)\n\nLast minimuxer.log lines:\n\(tail)"
                    }
                }
            }
        }
    }

    /// The record's top-level keys, for the import and start diagnostics.
    ///
    /// Keys only — deliberately no judgement about which of them *should* be
    /// there.  The required set differs per protocol (`.rppairing` needs
    /// `identifier`/`private_key`/`public_key` and no `UDID`; `.lockdown` needs
    /// `UDID` and the certificates), that rule lives in `PairingFileParser`, and
    /// the copy of it that used to be here — "a top-level UDID string is
    /// mandatory" — is exactly what rejected every valid iOS 17+ pairing file.
    static func pairingFileTopLevelKeys(_ raw: String) -> [String]? {
        guard let data = raw.data(using: .utf8) else { return nil }
        guard let obj = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) else {
            return nil
        }
        guard let dict = obj as? [String: Any] else { return nil }
        return Array(dict.keys)
    }

    /// Route engine log lines into `RunLog`.
    ///
    /// This used to append to `@State logs` on this view, one full-page
    /// invalidation per line; the store coalesces a burst into one main-thread
    /// flush and only `RunLogCard` observes it.
    func spawnLogPrinter() {
        GoldenNuggetEngine.shared.onLog = { line in
            RunLog.shared.append(line)
        }
    }
}
