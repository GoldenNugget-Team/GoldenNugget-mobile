import SwiftUI
import Minimuxer

/// Settings: what this build is, and the switches that change what a run does.
///
/// A plain `Form` in the system's grouped style.  The platform draws the
/// surface, the section headers, the row insets, the disclosure chrome and the
/// Liquid Glass; every colour and font here is semantic, so light and dark and
/// the user's text size all work without a palette of our own.
///
/// The About half is what a bug report actually needs — version, build, and the
/// two log files with their sizes.  The Apply half is the one switch that is not
/// a development switch: Skip Setup.  The Development half sits behind a master
/// switch because every row on it changes a real device.
struct SettingsView: View {
    // Reactive mirrors of `DevSettings.Key`, so a toggle redraws the page. The
    // engine reads the same strings through `DevSettings.effective`.
    @AppStorage(DevSettings.Key.enabled) private var devModeOn = false
    @AppStorage(DevSettings.Key.forcePartialRestore) private var forcePartialRestore = false
    @AppStorage(DevSettings.Key.verboseLog) private var verboseLog = true
    @AppStorage(DevSettings.Key.skipAfcMedia) private var skipAfcMedia = false

    /// Skip Setup's switch. Observed rather than mirrored with a second
    /// `@AppStorage` on the same key: the store is what the engine reads.
    @ObservedObject private var skipSetup = SkipSetupSettings.shared

    /// Read through `engine` rather than recomputed in the body, because a log is
    /// written by another thread while this page is open.
    @State private var logs = LogSizes()

    /// The setup guide, as a full-screen cover.
    ///
    /// It is the same view the app opens with on a first launch, on purpose: a
    /// second "getting started" page would be a second set of instructions to fall
    /// out of step with the first, and the whole reason this row exists is that a
    /// user who skipped the gate still needs it. A `NavigationLink` would have no
    /// place to return to after "Finish setup", which on an already-set-up app
    /// changes nothing the user can see.
    @State private var showSetupGuide = false

    /// Sizes and existence of the two files a report is built from.
    private struct LogSizes: Equatable {
        var appBytes: UInt64 = 0
        var rustBytes: UInt64 = 0
        var rustStatus: String = ""

        var appKB: UInt64 { appBytes / 1024 }
        var rustKB: UInt64 { rustBytes / 1024 }
        var hasApp: Bool { appBytes > 0 }
        var hasRust: Bool { rustBytes > 0 }
    }

    var body: some View {
        Form {
            aboutSection
            creditsSection
            setupSection
            logsSection
            applySection
            developmentSection
        }
        .navigationTitle("Settings")
        // Compact widths only -- on a tablet the split view draws its own sidebar
        // toggle, and a second button beside it is the duplicate-controls mess.
        .goldenSidebarButton()
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $showSetupGuide) {
            NavigationStack {
                FirstRunView { showSetupGuide = false }
            }
        }
        .task {
            refreshLogs()
        }
        .onChange(of: devModeOn) { _, _ in DevSettings.applyLoggingPreference() }
        .onChange(of: verboseLog) { _, _ in DevSettings.applyLoggingPreference() }
    }

    // MARK: - About

    private var aboutSection: some View {
        Section("About") {
            VStack(spacing: 12) {
                NativeLogo(size: 88)
                Text("GoldenNugget")
                    .font(.title2.bold())
                Text(Self.versionText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .listRowBackground(Color.clear)

            // A credit, not a setting: centred and on its own, so it does not
            // read as a row.
            Text("Made with ❤️ by\nGoldenNugget Development Team")
                .font(.callout)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)

            NativeNote("GoldenNugget for desktop is the original this app is "
                + "a port of. It runs the same protocols over its own Rust and Swift "
                + "stack instead of driving pymobiledevice3, and speaks to iOS 26 and "
                + "27 rather than only to tethered devices.")
        }
    }

    // MARK: - Credits

    /// What the app is built on, and by whom. Every row is a component that is
    /// really in the binary — the two static Rust/C archives are linked into the
    /// executable rather than embedded as frameworks (only `EMProxy.framework`
    /// ships as a dynamic framework in the IPA).
    private var creditsSection: some View {
        Section("Credits") {
            creditRow("GoldenNugget", "Desktop app · this is a port of it",
                      systemImage: "desktopcomputer")
            creditRow("idevice", "Rust device and backup stack",
                      systemImage: "shippingbox")
            creditRow("libimobiledevice", "C protocol core",
                      systemImage: "chevron.left.forwardslash.chevron.right")
            creditRow("Minimuxer", "SideStore · tunnel and usbmux",
                      systemImage: "network")
            creditRow("ZIPFoundation", "Archive handling",
                      systemImage: "archivebox")
            NativeNote("The vendored copies carry local patches, listed with "
                + "the reason for each in Vendor/patches/README.md. SideStore's minimuxer "
                + "is © 2026 SideStore.")
        }
    }

    private func creditRow(_ title: String, _ role: String, systemImage: String) -> some View {
        HStack(spacing: 12) {
            Label(title, systemImage: systemImage)
            Spacer(minLength: 12)
            Text(role)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }

    // MARK: - Setup

    /// The guide, reachable after the fact.
    ///
    /// Its own section rather than a row under Apply: those rows are switches a run
    /// reads, and this one changes nothing about a run — it opens a screen. It
    /// also sits above them, because it is the answer to "why is nothing
    /// connecting", which is the question a user opens Settings with.
    private var setupSection: some View {
        Section("Setup") {
            Button {
                showSetupGuide = true
            } label: {
                Label("Setup guide", systemImage: "list.number")
            }
            NativeNote("Checks the two things this app needs before it can reach the "
                + "device — the LocalDevVPN tunnel and a pairing record — and walks "
                + "through both. This is the guide a first launch opens.")
        }
    }

    // MARK: - Logs

    private var logsSection: some View {
        Section("Logs") {
            // The two halves of a report's evidence: this one is what the host
            // decided, the other is what the protocol did.
            shareRow(title: "goldennugget.log",
                     size: logs.appKB,
                     systemImage: "doc.plaintext",
                     url: GoldenNuggetEngine.appLogURL,
                     available: logs.hasApp)
            shareRow(title: "minimuxer.log",
                     size: logs.rustKB,
                     systemImage: "doc.text.magnifyingglass",
                     url: GoldenNuggetEngine.rustLogURL,
                     available: logs.hasRust)
            if !logs.hasRust, !logs.rustStatus.isEmpty {
                NativeNote(logs.rustStatus)
            }
            NativeNote(logs.hasApp
                ? "A report wants both files: the app log says what was decided, "
                  + "minimuxer.log says what the device answered."
                : "No app log yet — it is written from the first run in this session.")
        }
    }

    private func shareRow(title: String, size: UInt64, systemImage: String,
                          url: URL, available: Bool) -> some View {
        ShareLink(item: url) {
            HStack(spacing: 12) {
                Label("\(title) (\(size) KB)", systemImage: systemImage)
                Spacer(minLength: 0)
            }
        }
        .foregroundStyle(available ? Color.primary : Color.secondary)
    }

    // MARK: - Apply

    /// Skip Setup, on its own page rather than behind the Development master: it is
    /// not a switch for working around a bug, it is part of what a run writes.
    private var applySection: some View {
        Section("Apply") {
            switchRow("Skip Setup",
                      note: skipSetupNote,
                      isOn: Binding(
                          get: { skipSetup.skipSetupEnabled },
                          set: { skipSetup.setSkipSetup($0) }))
        }
    }

    /// What the switch does, in the order the two files are written.
    private var skipSetupNote: String {
        [
            "On by default, as upstream does. Off: an apply carries only the tweaks.",
            "On: an apply adds two files ahead of the tweaks, in this order —",
            "1. SysSharedContainerDomain-systemgroup.com.apple.configurationprofiles/"
                + "Library/ConfigurationProfiles/CloudConfigurationDetails.plist, "
                + "\(SkipSetup.panes.count) setup panes marked skipped;",
            "2. ManagedPreferencesDomain/mobile/com.apple.purplebuddy.plist, setup marked done.",
            "The device's existing cloud configuration is not merged in (reading it needs "
                + "a lockdown service this port has no path for), and no keybag certificate "
                + "is generated.",
        ].joined(separator: "\n")
    }

    // MARK: - Development

    private var developmentSection: some View {
        Section("Development") {
            Toggle(isOn: $devModeOn) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Development mode")
                    NativeNote(devModeOn
                        ? "The switches below are live for the next run."
                        : "Off: runs take the normal path. Stored switches are ignored.")
                }
            }

            if devModeOn {
                switchRow("Force Partial Restore",
                          note: "Takes the iOS 26 branch — a Partial Restore built "
                              + "from nothing — even on a device that reports iOS 27+, "
                              + "and skips the protective backup entirely.",
                          isOn: $forcePartialRestore)

                switchRow("Verbose log",
                          note: verboseLog
                            ? "Recording the protocol detail into minimuxer.log. "
                              + "Off keeps the app log and the run itself, and drops "
                              + "the per-frame lines."
                            : "Protocol detail is not being recorded. The app log still is.",
                          isOn: $verboseLog)

                switchRow("Skip AFC media",
                          note: "A run normally copies camera-roll media between the "
                              + "backup and the prune. This leaves it out, which on a full "
                              + "camera roll is the difference between minutes and seconds.",
                          isOn: $skipAfcMedia)

                Button("Reset switches", systemImage: "arrow.counterclockwise") {
                    DevSettings.resetSwitches()
                    DevSettings.applyLoggingPreference()
                }

                NativeSafetyNote("These are switches, not fixes. Force Partial Restore "
                    + "against a real iOS 27 device is expected to fail at the restore step, "
                    + "because a synthesised manifest carries no domain registration.")
            }
        }
    }

    // MARK: - Rows

    /// A labelled switch with the explanation underneath it.
    private func switchRow(_ title: String, note: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                NativeNote(note)
            }
        }
    }

    private func refreshLogs() {
        logs = LogSizes(appBytes: GoldenNuggetEngine.appLogSize(),
                        rustBytes: GoldenNuggetEngine.rustLogSize(),
                        rustStatus: GoldenNuggetEngine.rustLogStatus())
    }

    // MARK: - Bundle facts

    private static func info(_ key: String) -> String {
        Bundle.main.object(forInfoDictionaryKey: key) as? String ?? "unknown"
    }

    private static var versionText: String {
        "\(info("CFBundleShortVersionString")) (\(info("CFBundleVersion")))"
    }
}
