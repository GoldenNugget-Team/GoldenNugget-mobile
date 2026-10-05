import Foundation
import Minimuxer
import SwiftUI

/// An error whose message is meant for the operator, not for a stack trace.
struct GoldenNuggetError: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// The apply pipeline, ported from GoldenNugget's own apply pass
// (`device_manager._apply_tweak_pass`) onto this app's restore machinery.
//
// Flow:
//   1. Compile the selection to plists — before the device is touched, so an
//      impossible selection costs nothing.
//   2. Real protective backup via mobilebackup2 — triggers the iOS 27
//      backup-password/trust popup and establishes an authorized session.
//      FactoryInfo {Applications: {}} skips app containers device-side.
//      shouldPreserve drains photos/movies mid-stream.
//   3. Prune Manifest.db to the protective keep-set (drained files still
//      have rows — they must be removed or restore requests them), then inject
//      the compiled tweak plists as rows + payloads.
//   4. Restore via mobilebackup2.
//
// This type is the run orchestrator and the app-facing facade.  The work itself
// lives in `Core/`: `ProtectiveBackup` (stage 2), `BackupInjector` (stage 3),
// `RestoreRunner` (stage 4), with `ChannelRecovery` / `StallGuard` /
// `TransportFailure` handling the retry and silence verdicts, `ManifestStore`
// owning the manifest, `RustLog` + `WireCensus` reading the Rust evidence, and
// `AppLog` being the process-wide log bus.  The facade is kept so the SwiftUI
// layer does not have to know any of that.
class GoldenNuggetEngine {
    static let shared = GoldenNuggetEngine()

    private init() {}

    // MARK: - Logging facade

    /// Route engine log lines into the UI list.
    var onLog: ((String) -> Void)? {
        didSet { AppLog.shared.setUIHandler(onLog) }
    }

    func log(_ msg: String) {
        AppLog.shared.log(msg)
    }

    /// Run `body` under `label`, writing a failure into the log before it escapes.
    ///
    /// Every run entry point throws to a view that turns the error into a status
    /// line, and a status line lives exactly as long as the screen: the file sink
    /// is the only record a failed run leaves once the app is closed. It has to
    /// be written here rather than at the call sites because there are four of
    /// them and a fifth would silently skip it — which is how a posterboard apply
    /// came to end with its last line still on the *fetch* and nothing saying
    /// why.
    private func loggedRun<T>(_ label: String,
                              _ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let failure as TransportFailure where failure.isCancellation {
            log("\(label) stopped: \(failure.label)")
            throw failure
        } catch {
            log("\(label) failed: \(error.localizedDescription)")
            throw error
        }
    }

    // MARK: - Cancellation facade

    func requestCancel() { CancelFlag.shared.request() }

    func clearCancel() { CancelFlag.shared.clear() }

    // MARK: - Paths facade

    static var appLogURL: URL { AppPaths.appLog }
    static var rustLogURL: URL { AppPaths.rustLog }
    static var diagnosticsURL: URL { AppPaths.diagnostics }

    static func rustLogSize() -> UInt64 { RustLog.size() }
    static func appLogSize() -> UInt64 { AppLog.shared.file.size() }
    static func rustLogStatus() -> String { RustLog.status() }

    /// Remember the log offset so the next excerpt covers only THIS run.
    @discardableResult
    func markRustLog() -> UInt64 { RustLog.markStart() }

    // MARK: - Rust logging

    /// Point the Rust logger at `<Documents>/minimuxer.log` at DEBUG level.
    ///
    /// MUST run before `setLogging(true)` / `core.start()`: the Rust side
    /// latches on the first `idevice_init_logger` call for the whole process
    /// (`Once`), and the existing call site installs console=Error / file=OFF.
    /// That is why `minimuxer.log` never existed and a failed mobilebackup2
    /// backup produced no Rust-side evidence.  Safe to call repeatedly — every
    /// call after the first returns -2 without changing anything.
    @discardableResult
    func enableRustFileLogging() -> Int32 {
        // One line per call was wrong twice over: `.onAppear` fires on every
        // navigation back and `startMinimuxer` calls this again, so a session
        // that never got a tunnel printed the same "rust log → …" line a dozen
        // times — the loudest thing in a log whose real failure was one line
        // lower. The Rust side is process-wide state; the first answer is the
        // only one that describes it.
        if let cached = RustLog.initResult {
            return cached
        }

        let path = AppPaths.rustLog.path

        let rc: Int32
        if let gateway = Minimuxer.shared().ideviceGateway {
            rc = gateway.enableRustFileLogging(to: path)
        } else {
            rc = -99
        }
        RustLog.noteInitResult(rc)

        let meaning: String
        switch rc {
        case 0:   meaning = "file sink requested (DEBUG)"
        case -1:  meaning = "file error — path rejected by Rust"
        case -2:  meaning = "already initialized — a previous idevice_init_logger call won, Rust logs stay on console(Error) and never reach the file"
        case -3:  meaning = "invalid path string"
        case -99: meaning = "no ideviceGateway available"
        default:  meaning = "unknown"
        }
        log("rust log → \(path): rc=\(rc) (\(meaning))")

        // rc=0 only means the subscriber was installed; the file itself is
        // created by the first line the Rust side writes, so it is legitimately
        // absent here. What must be true NOW is that the directory exists —
        // a missing parent is the one case where the sink can never come up, and
        // it is invisible afterwards (status reads "size=MISSING" forever).
        if rc == 0 {
            let fm = FileManager.default
            let parent = URL.documents.path
            let parentExists = fm.fileExists(atPath: parent)
            log("rust log dir: \(parent) exists=\(parentExists) "
                + "(file appears with the first Rust line)")
            if !parentExists {
                log("⚠️ the Rust log directory does not exist — no Rust evidence will be "
                    + "written this session. This app is running somewhere its Documents "
                    + "path is not writable.")
            }
        }
        return rc
    }

    // MARK: - Diagnostics

    /// The failure dump; see `Diagnostics.report()`.
    func diagnostics() async -> String {
        await Diagnostics.report()
    }

    // MARK: - Progress facade

    /// Whole-percent progress of the run in flight, or nil when nothing has
    /// reported yet.  The reference's home page prints the same number in its
    /// process-status line (`IOSApplyPage.set_status` parses `NN%` out of the
    /// status text), and a multi-minute restore with no number on it is the one
    /// screen the operator keeps re-reading to guess whether it is alive.
    private(set) var progress: Double?

    /// Route progress into the UI.  Called from the Rust progress callbacks, so
    /// the handler hops to the main actor itself.
    var onProgress: ((Double) -> Void)?

    private func reportProgress(_ percent: Double) {
        let clamped = percent < 0 ? 0 : min(percent, 100)
        progress = clamped
        onProgress?(clamped)
    }

    private func clearProgress() {
        progress = nil
        onProgress?(Double.nan)
    }

    // MARK: - Run: apply the ported GoldenNugget tweaks

    /// Apply everything this app can deliver: the compiled plist tweaks, the skip-setup
    /// files, and the PosterBoard selection — **one pass, one button**.
    ///
    /// This is GoldenNugget's `device_manager._apply_tweak_pass`, whose file list is
    /// built from every feature at once: its `needs_posterboard` flag decides whether the
    /// store's database has to be fetched first, and the wallpapers then ride the same
    /// restore as the tweaks.  There is no separate apply for wallpapers — this port had
    /// one for a while, a second button running the same four stages over a different
    /// payload set, and it is gone.  What is left of it is the flag.
    ///
    /// The compile runs *before* the device is touched, so an empty or impossible
    /// selection fails without paying for a backup first.  The PosterBoard database is
    /// the one input that has to come off the device; that stage therefore talks to it,
    /// but it is still ahead of the expensive protective pull and of the restore.
    func applyTweaks(
        selection: TweakSelection,
        posterBoard: PosterBoardSelection,
        statusBar: StatusBarSelection,
        deviceVersion: String,
        isIPhone: Bool
    ) async throws {
        try await loggedRun("apply") {
            try await applyTweaksRun(selection: selection,
                                     posterBoard: posterBoard,
                                     statusBar: statusBar,
                                     deviceVersion: deviceVersion,
                                     isIPhone: isIPhone)
        }
    }

    private func applyTweaksRun(
        selection: TweakSelection,
        posterBoard: PosterBoardSelection,
        statusBar: StatusBarSelection,
        deviceVersion: String,
        isIPhone: Bool
    ) async throws {
        AppLog.shared.memory.reset()
        warnIfPreviousCallStillRunning()
        clearCancel()
        clearProgress()
        let runStage = StageTimer("RUN apply")
        defer { runStage.done() }

        let compiled = TweakCompiler.compile(selection: selection,
                                             deviceVersion: deviceVersion,
                                             isIPhone: isIPhone)

        // The status bar is built here, on the version the page already read, and
        // for the same reason the plist compile is: a payload that cannot be built
        // has to fail before the device is touched.  The page resolves the
        // mechanism from this same number, so the two cannot disagree.
        var statusBarPayloads: [TweakPayload] = []
        if statusBar.isActive {
            let mechanism = StatusBarMechanism.mechanism(for: deviceVersion)
            let built = try statusBar.payload(for: mechanism)
            statusBarPayloads = [TweakPayload(domain: mechanism.domain,
                                              relativePath: mechanism.restorePath,
                                              contents: built.data)]
            // The count, then the parenthetical the reference's summary has: an
            // enabled-but-empty selection still writes a file, and the log has to
            // say so, or a reset reads as a no-op.
            log("Status bar: \(statusBar.overrides.activeCount) override(s)"
                + " \(statusBar.overrides.activeCount == 0 ? "(a reset)" : "") via "
                + "\(mechanism == .classic ? "the classic struct" : "the iOS 27 archive") "
                + "→ \(statusBarPayloads[0].label) (\(built.data.count) B)")
            for field in built.dropped {
                log("  ⚠️ \(field) has no counterpart in the iOS 27 archive and was not delivered")
            }
        }

        // Upstream's skip-setup block rides the same apply, **ahead of** the
        // tweaks (`device_manager.add_skip_setup`).  Its warnings are logged
        // below: the parts this port cannot reproduce must not read like parity.
        //
        // Always the un-supervised variant.  The `supervised` / `organizationName`
        // arguments used to come off the Supervision page, and the page is gone —
        // it recorded `IsSupervised` without ever writing the
        // `SupervisorHostCertificates` that make the flag mean anything, so a
        // device this app "supervised" sat in a state the reference never
        // produces on purpose.  `SkipSetup` still carries the supervised shape
        // because `scripts/skipsetup-check.swift` checks both, but nothing in the
        // app selects it any more.
        let skipSetup = SkipSetupSettings.shared.skipSetupEnabled
            ? SkipSetup.build(supervised: false, organizationName: "")
            : SkipSetup.Build(payloads: [], warnings: [])

        guard !compiled.payloads.isEmpty || !skipSetup.payloads.isEmpty || posterBoard.isActive
                || statusBar.isActive else {
            throw GoldenNuggetError("Nothing to apply: no tweak is enabled (or every enabled one "
                + "was skipped), skip setup is off, the status bar is untouched, and there is "
                + "nothing selected on the PosterBoard page.")
        }
        log("Tweaks: \(compiled.payloads.count) file(s) from \(compiled.locations.count) plist(s)")
        for location in compiled.locations { log("  → \(location.rawValue)") }
        for item in compiled.skipped { log("  ⚠️ skipped \(item.label): \(item.reason)") }
        if !skipSetup.payloads.isEmpty {
            log("Skip setup: \(skipSetup.payloads.count) file(s) ahead of the tweaks")
            for payload in skipSetup.payloads { log("  → \(payload.label)") }
            for warning in skipSetup.warnings { log("⚠️ \(warning)") }
        }

        // The apply mode picks the mechanism, and it is the user's choice: the
        // backup path below and the AirLift path install the same wallpapers two
        // different ways, and neither can stand in for the other. The mode's
        // constraints are checked *here*, before `prepareRun`, so a selection the
        // chosen mode cannot honour fails without paying for a tunnel first.
        let posterBoardMode = PosterBoardApplyModeSettings.current
        if posterBoard.isActive && posterBoardMode == .airlift {
            try checkAirliftCanApply(posterBoard: posterBoard, deviceVersion: deviceVersion)
        }

        let udid = try await prepareRun()
        // Resolved once, here, because two stages need it: the PosterBoard compile (its
        // reset preferences change at 26.4) and the manifest-format fork inside
        // `deliver`.  `resolvedDeviceVersion` carries the reasoning for refusing to
        // guess — a device whose version cannot be read must not be treated as iOS 26.
        let version = try await resolvedDeviceVersion(deviceVersion)
        let major = Int(version.split(separator: ".").first ?? "0") ?? 0
        log("device version for the manifest-format fork: \(version) (major \(major))")

        // PosterBoard, if the page has anything. Two mechanisms, chosen above:
        // the store's database first — a wallpaper exists only once it has a row in
        // it — and then the wallpapers themselves, unless AirLift is doing it, in
        // which case there is no database and no payload: the injection into the
        // container *is* the apply.
        var posterBoardPayloads: [TweakPayload] = []
        var posterBoardInjectedOverAirlift = false
        if posterBoard.isActive && posterBoardMode == .airlift {
            log("PosterBoard: \(posterBoard.describe) — over AirLift, no backup")
            try await applyPosterBoardOverAirlift(selection: posterBoard, deviceVersion: version)
            posterBoardInjectedOverAirlift = true
        } else if posterBoard.isActive {
            log("PosterBoard: \(posterBoard.describe)")
            var structureVersion = PosterBoard.fallbackStructureVersion
            var database: URL?
            if posterBoard.fullReset || !posterBoard.resetModes.isEmpty {
                // A reset needs no database, so it needs no fetch and no exchange.
                log("PosterBoard: reset only — no database is needed, and none is fetched.")
            } else {
                let fetched = try await PosterBoardBackup.fetch(
                    backupRoot: AppPaths.posterBoardFetchRoot, udid: udid,
                    // The same fork `deliver` is about to take, from the same number.
                    ios27: major >= 27 && !DevSettings.effective.forcePartialRestore,
                    onProgress: { overall in
                        self.logProgress("posterboard backup progress", overall)
                    },
                    log: { AppLog.write($0) })
                database = fetched.database
                structureVersion = fetched.structureVersion
            }
            posterBoardPayloads = try await PosterBoard.compile(
                selection: posterBoard,
                structureVersion: structureVersion,
                database: database,
                deviceVersion: version,
                workingDirectory: PosterBoard.workDirectory,
                log: { AppLog.write($0) })
            let onDisk = posterBoardPayloads.filter { $0.source != nil }.count
            let total = posterBoardPayloads.reduce(0) { $0 + $1.byteCount }
            log("PosterBoard: \(posterBoardPayloads.count) payload(s), \(onDisk) of them on disk "
                + "(\(ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file)))")
        }

        // Skip setup, then the tweaks, then the status bar, then the wallpapers: one
        // array, one pass through the injector, which derives the directory rows from
        // each payload's path.  The order is the reference's — `add_skip_setup`
        // ahead of the tweaks, and `apply_classic_tweak` / `apply_ios27_tweak`
        // before the wallpapers — and it only actually matters for the two
        // skip-setup files, which land in the order they are appended.
        let payloads = skipSetup.payloads + compiled.payloads + statusBarPayloads
            + posterBoardPayloads

        // Wallpapers-only run in AirLift mode: the injection already happened and
        // it resprings on its way out, so running the backup/restore tail here
        // would buy a full protective pull for an empty payload list.
        if payloads.isEmpty && posterBoardInjectedOverAirlift {
            log("Apply succeeded: the wallpapers are in PosterBoard's container and it has "
                + "resprung — no backup was taken.")
            return
        }

        try await deliver(payloads: payloads, udid: udid, version: version, label: "apply") {
            log("Apply succeeded: the device confirmed it finished.")
            log("Reboot the device so the injected preferences take effect.")
            if posterBoardInjectedOverAirlift {
                log("The wallpapers went in over AirLift and are already live; only the tweaks "
                    + "above needed the reboot.")
            } else if posterBoard.fullReset || !posterBoard.resetModes.isEmpty {
                log("The PosterBoard store was cleared. Reboot the device, then add wallpapers "
                    + "from a fresh database fetch — a reset makes the copy fetched before it "
                    + "stale.")
            } else if posterBoard.isActive {
                log("Reboot the device so the PosterBoard store picks the new wallpapers up.")
            }
        }
    }

    /// Refuse a selection the AirLift path cannot carry, before anything is opened.
    ///
    /// A reset is a store operation and the video stage's frames are computed for
    /// the restore, so neither can travel a container write. Saying so up front is
    /// the alternative to accepting the selection and quietly dropping half of it.
    private func checkAirliftCanApply(posterBoard: PosterBoardSelection, deviceVersion: String) throws {
        if posterBoard.fullReset || !posterBoard.resetModes.isEmpty {
            throw GoldenNuggetError("AirLift cannot reset the PosterBoard store — it only adds "
                + "wallpapers. Switch the apply mode to \"Protective backup\" for a reset.")
        }
        if posterBoard.video != nil {
            throw GoldenNuggetError("AirLift cannot apply a PosterBoard video: its frames are "
                + "staged for a restore. Switch the apply mode to \"Protective backup\".")
        }
        let reason = Airlift.unsupportedReason(deviceVersion: deviceVersion)
        guard reason.isEmpty else { throw GoldenNuggetError(reason) }
        guard FileManager.default.fileExists(atPath: AppPaths.pairingFile.path) else {
            throw GoldenNuggetError("AirLift needs a pairing record and none is stored. Import one "
                + "on the home page first.")
        }
    }

    /// Run the AirLift PosterBoard injection, reporting through the run log.
    private func applyPosterBoardOverAirlift(selection: PosterBoardSelection,
                                             deviceVersion: String) async throws {
        try await PosterBoardAirlift.apply(
            selection: selection,
            structureVersion: PosterBoard.fallbackStructureVersion,
            deviceVersion: deviceVersion,
            pairingPath: AppPaths.pairingFile.path,
            log: { AppLog.write($0) },
            progress: { overall in self.logProgress("posterboard airlift", overall) }
        )
    }

    /// Fetch only the device's PosterBoard database, without applying anything.
    ///
    /// The page's own action, and the reference has the same one (its "Fetch
    /// Database File" wizard in `pb_dialog.py`) for the same reason: the fetch is
    /// the one stage of a wallpaper apply that can fail on its own terms — the
    /// device decides whether it will upload the container — so being able to run
    /// it alone, watch it, and retry is worth a button. The result is cached at
    /// `PosterBoardBackup.cachedDatabase(udid:)`, and an apply reuses nothing:
    /// it fetches its own, because a copy fetched before a reset is stale.
    func fetchPosterBoardDatabase() async throws {
        try await loggedRun("posterboard database fetch") {
            try await fetchPosterBoardDatabaseRun()
        }
    }

    private func fetchPosterBoardDatabaseRun() async throws {
        AppLog.shared.memory.reset()
        warnIfPreviousCallStillRunning()
        clearCancel()
        clearProgress()
        let stage = StageTimer("RUN posterboard database fetch")
        defer { stage.done() }

        let udid = try await prepareRun()
        _ = try await PosterBoardBackup.fetch(
            backupRoot: AppPaths.posterBoardFetchRoot, udid: udid,
            onProgress: { overall in self.logProgress("posterboard backup progress", overall) },
            log: { AppLog.write($0) })
        log("PosterBoard database fetched and validated.")
    }

    /// Inject the PosterBoard packs over AirLift, and nothing else.
    ///
    /// The home page's Apply is one combined run — tweaks and wallpapers ride
    /// together through a single protective backup — which is right for a
    /// backup-mode selection and wrong for this one: AirLift writes the
    /// descriptors straight into the container, so a run that carries nothing
    /// but wallpapers should not buy a backup at all. That early return lives
    /// in the combined path and is reached only when no tweak is selected, so
    /// this is the same injection on its own, with no payloads to deliver and
    /// no mode switch to remember.
    ///
    /// - Parameters:
    ///   - selection: the page's selection. Only its packs are honoured, exactly
    ///     as in the combined run.
    ///   - deviceVersion: what the page already read; the constraints are checked
    ///     against it rather than resolved again over a second connection.
    func applyPosterBoardViaAirlift(_ selection: PosterBoardSelection,
                                    deviceVersion: String) async throws {
        try await loggedRun("posterboard airlift apply") {
            try await applyPosterBoardViaAirliftRun(selection, deviceVersion: deviceVersion)
        }
    }

    private func applyPosterBoardViaAirliftRun(_ selection: PosterBoardSelection,
                                               deviceVersion: String) async throws {
        AppLog.shared.memory.reset()
        warnIfPreviousCallStillRunning()
        clearCancel()
        clearProgress()
        let stage = StageTimer("RUN posterboard airlift apply")
        defer { stage.done() }

        try checkAirliftCanApply(posterBoard: selection, deviceVersion: deviceVersion)
        log("PosterBoard: \(selection.describe) — over AirLift, no backup")
        try await applyPosterBoardOverAirlift(selection: selection, deviceVersion: deviceVersion)
        log("PosterBoard: injected over AirLift and resprung. No backup was taken, and no "
            + "tweak was delivered — the home page's Apply is what delivers those.")
    }

    // MARK: - The shared delivery tail
    //
    // Both applies end in the same four stages, and the order is load-bearing:
    // the manifest-format fork decides whether there is anything to prune, the
    // pull is what authorizes the session, the prune must precede the injection,
    // and the restore is what delivers any of it.

    /// One payload set through stages 1–4.  `udid` and `version` come from the caller:
    /// the PosterBoard stage talks to the device (and needs the version) before this
    /// runs, so resolving them again here would be a second answer to a settled question.
    private func deliver(
        payloads: [TweakPayload],
        udid: String,
        version: String,
        label: String,
        onSuccess: () -> Void
    ) async throws {
        // The two versions take opposite paths, and the split is the
        // reference's one-line fork (`backup.py:113`) widened to the whole run:
        // iOS 26 speaks legacy MBDB and can have a backup built for it from
        // nothing, iOS 27+ speaks the modern sqlite Manifest.db and must keep
        // the device's own state. Comparing "26.0" against "27.0" lexically
        // would put 26.9 on the wrong side, so compare the major component.
        //
        let major = Int(version.split(separator: ".").first ?? "0") ?? 0
        // Development mode can force the iOS 26 branch, so the reported version is no
        // longer the last word on which branch runs -- only the default for it. Read
        // once, here, and both decisions below quote the same snapshot.
        let dev = DevSettings.effective
        let ios27 = major >= 27 && !dev.forcePartialRestore
        // Reported before the fork, because this number *is* the fork: the
        // branch lines below say where the run went, this says why.
        log("device version for the manifest-format fork: \(version) (major \(major))")
        if dev.forcePartialRestore {
            log("development mode: forcing the iOS 26 branch on a major \(major) device "
                + "-- no protective backup will be pulled")
        }

        // iOS 26: a Partial Restore, built rather than pulled -- an empty device
        // directory, the host-side manifests, then this run's rows. Nothing was
        // pulled, so there is no device state to reconcile against and the
        // prune would only discard what this run just wrote.
        //
        // iOS 27: the protective backup, pulled from the device, then pruned to
        // what is on disk before injection. A synthesized manifest is not enough
        // here: `restored` rejects a domain it cannot resolve ("Failed to
        // prepare INSERT for ManagedPreferencesDomain") because the real one
        // carries the device's own domain registration.
        let backupRoot: URL
        let prune: Bool
        if ios27 {
            log("Manifest format: sqlite (iOS 27+ path), protective backup pulled")
            backupRoot = try await protectiveBackup(udid: udid)
            prune = true
            // Media over AFC, after the backup and before the prune: the backup
            // filter rejects the media domains, so this is the only thing that
            // collects them, and doing it here means an apply is the one action
            // that leaves media preserved rather than only tweaks applied.
            //
            // Deletion stays off. A run is not the place to remove the user's
            // photos: it is started to apply tweaks, and the media page is where
            // that choice is made with a count and a free-space figure in front
            // of the user.
            if dev.skipAfcMedia {
                log("development mode: skipping the AFC media pull (Dev.SkipAfcMedia)")
            } else {
                await mediaBackup(deletingOriginals: false)
            }
        } else {
            log("Manifest format: legacy MBDB (iOS 26 path), built from nothing")
            backupRoot = try await partialRestore(udid: udid)
            prune = false
        }

        try await BackupInjector.pruneAndInject(
            backupRoot: backupRoot,
            udid: udid,
            tweakPayloads: payloads,
            prune: prune,
            ios27: ios27
        )

        try await runRestore(backupRoot: backupRoot, udid: udid, label: label,
                             onSuccess: onSuccess)
    }

    /// Put the named pages back to stock, on the device.
    ///
    /// A port of `device_manager.reset_tweaks` (`device_manager.py:1104`): a
    /// fixed set of files written over the device's own, with nothing read back
    /// first — no psysbackup capture, on either branch. The page set comes from
    /// the picker the reference's `ResetDialog` offers, not from this app's
    /// tweak selection; the two are unrelated, and the reference's dialog is
    /// likewise built from `get_resettable_pages`, not from what is enabled.
    ///
    /// It is the same pipeline as `applyTweaks` with a different payload list, so
    /// it reuses `protectiveBackup` / `partialRestore` / `pruneAndInject` /
    /// `runRestore` rather than growing a second restore path. The two branches
    /// differ in what a nulled file is written as (0 bytes vs. a valid empty
    /// plist — `TweakReset` has the table and the reason) and in which manifest
    /// the run needs, for the same reason the apply forks:
    ///
    /// * **iOS 27+** speaks the modern sqlite `Manifest.db` and rejects a
    ///   synthesized one ("Failed to prepare INSERT for ManagedPreferencesDomain"
    ///   — the real one carries the device's own domain registration), so the
    ///   reset pulls the protective backup and prunes it, exactly as an apply
    ///   does. It does **not** pull media: a reset is a preferences operation and
    ///   the backup filter rejects the media domains anyway.
    /// * **iOS 26** speaks legacy MBDB and can have a backup built for it from
    ///   nothing, so the reset synthesises one.
    ///
    /// What is deliberately absent is the reference's `clear_lastapply`: it drops
    /// the apply record so a later apply does not skip Phase 2 against a reset
    /// device, and there is no phase-2 skip in this port to guard. The app's own
    /// selection is left alone too, exactly as the reference leaves the tweaks
    /// page as the user had it — the reset is of the *device*, and the selection
    /// is what would put the tweaks back.
    func resetPages(pages: Set<ResetPage>) async throws {
        try await loggedRun("page reset") { try await resetPagesRun(pages: pages) }
    }

    private func resetPagesRun(pages: Set<ResetPage>) async throws {
        AppLog.shared.memory.reset()
        warnIfPreviousCallStillRunning()
        clearCancel()
        clearProgress()
        let runStage = StageTimer("RUN page reset")
        defer { runStage.done() }

        guard !pages.isEmpty else {
            throw GoldenNuggetError("No page was selected — nothing to reset.")
        }

        let udid = try await prepareRun()

        // Read the version here for the same reason the apply does: the pages
        // read it before lockdown answers, so a value of "" would put a 27
        // device on the 26 branch and hand it 0-byte plists.
        let version = try await resolvedDeviceVersion("")
        let major = Int(version.split(separator: ".").first ?? "0") ?? 0
        let dev = DevSettings.effective
        let ios27 = major >= 27 && !dev.forcePartialRestore

        let plan = TweakReset.plan(pages: pages, ios27: ios27)
        guard !plan.payloads.isEmpty else {
            throw GoldenNuggetError("Every selected page resolved to no file — nothing to reset.")
        }

        // The reference appends the skip-setup files to the *reset's* file list
        // too (`add_skip_setup(files_to_restore, uses_domains)`, called after the
        // null loop and before `start_restore`), subject to its own gate — which
        // on iOS 27 only passes when the file list already restores real domains,
        // and in the reset path that means the Daemons page was ticked. Reproduced
        // as written; see `TweakReset.skipSetupAllowed(pages:ios27:)`.
        let skipSetupOn = SkipSetupSettings.shared.skipSetupEnabled
        let skipSetup: SkipSetup.Build
        if !skipSetupOn {
            skipSetup = SkipSetup.Build(payloads: [], warnings: [])
        } else if plan.skipSetupAllowed {
            skipSetup = SkipSetup.build(supervised: false, organizationName: "")
        } else {
            skipSetup = SkipSetup.Build(payloads: [], warnings: [])
            log("Skip Setup is on, but the reference omits its two files here: on iOS 27 "
                + "the reset restores no real domain unless the Daemons page is ticked, "
                + "and that is its `add_skip_setup` condition. Tick Daemons, or reset on "
                + "iOS 26, to include them.")
        }

        log("Reset: \(pages.count) page(s) — \(plan.targets.count) file(s) on iOS \(version)")
        for target in plan.targets {
            log("  → \(target.path) [\(target.kind.rawValue), "
                + "\(target.contents.count) bytes]")
        }
        for item in plan.skipped { log("  ⚠️ skipped \(item.label): \(item.reason)") }
        for page in ResetPage.allCases where pages.contains(page) {
            log("  page \(page.title): \(page.locations.count) file(s)")
        }
        if ios27 {
            log("iOS 27 branch: a nulled file is written as a valid empty plist, not 0 bytes — "
                + "a truncated plist is a SpringBoard boot loop on this release. Nothing is read "
                + "back from the device first: this is the reference's own no-capture fallback, "
                + "not a psysbackup restore of the original values.")
        } else {
            log("iOS 26 branch: a nulled file is written as 0 bytes, over a synthesised MBDB "
                + "backup (no device content pulled).")
        }

        let backupRoot: URL
        let prune: Bool
        if ios27 {
            log("Manifest format: sqlite (iOS 27+ path), protective backup pulled, then pruned")
            backupRoot = try await protectiveBackup(udid: udid)
            prune = true
        } else {
            log("Manifest format: legacy MBDB (iOS 26 path), built from nothing")
            backupRoot = try await partialRestore(udid: udid)
            prune = false
        }

        try await BackupInjector.pruneAndInject(
            backupRoot: backupRoot,
            udid: udid,
            // Same order as the reference's file list: the daemons file first, then
            // the nulled ones, then the two skip-setup files last — the reference
            // calls `add_skip_setup` after the null loop.
            tweakPayloads: plan.payloads + skipSetup.payloads,
            prune: prune,
            ios27: ios27
        )

        try await runRestore(backupRoot: backupRoot, udid: udid, label: "page reset") {
            log("Reset succeeded: the device confirmed it finished.")
            log("The pages above are back to their defaults. The selections in this app are "
                + "untouched — applying again would write the tweaks back.")
            log("Reboot the device so the restored files take effect.")
        }
    }

    /// The AFC media stage, as a stage rather than a separate button so the run
    /// log tells the whole story in one place.
    private func mediaBackup(deletingOriginals: Bool) async {
        do {
            let survey = try await AfcMediaBackup.survey()
            guard !survey.files.isEmpty else {
                log("AFC media: nothing in \(AfcMediaBackup.trees.joined(separator: "/")) "
                    + "— skipped")
                return
            }
            log("AFC media: pulling \(survey.files.count) file(s), \(survey.bytes) byte(s)")
            let manifest = try await AfcMediaBackup.pull(deletingOriginals: deletingOriginals) {
                self.log($0)
            }
            let removed = manifest.entries.filter(\.deleted).count
            log("AFC media: stored \(manifest.entries.count) file(s), \(removed) removed "
                + "from the device")
        } catch {
            // Not fatal to the tweak apply. The store is a copy, not a
            // precondition for writing preferences, and a media failure must not
            // cost the user the tweak run they started.
            log("AFC media: FAILED — \(error.localizedDescription)")
        }
    }

    // MARK: - Protective flow stages
    //
    // The full flow, kept in one place because the order is load-bearing.

    /// Stage 1: the working backup, into `<Documents>/<udid>/`.
    ///
    /// A Partial Restore, so it is built rather than pulled: an empty device
    /// directory, then the host-side manifests, then this run's rows and
    /// payloads. There is no user content to preserve and nothing to wipe, which
    /// is why the reference's three-phase flow (and its safe-state recovery) has
    /// no part here on iOS 26 -- the restore lands on the live device.
    private func partialRestore(udid: String) async throws -> URL {
        let backupRoot = AppPaths.fullBackupRoot(udid: udid)
        try resetDirectory(backupRoot)
        log("Partial Restore: synthesising backup at \(backupRoot.lastPathComponent) "
            + "(no device content pulled)")
        return backupRoot
    }

    /// A real protective backup into `<Documents>/<udid>/`.
    private func protectiveBackup(udid: String) async throws -> URL {
        let backupRoot = AppPaths.fullBackupRoot(udid: udid)
        try resetDirectory(backupRoot)
        try await ProtectiveBackup.run(backupRoot: backupRoot, udid: udid) { overall in
            self.logProgress("backup progress", overall)
        }
        log("Protective backup complete.")
        return backupRoot
    }

    // MARK: - Shared run plumbing
    //
    // The sequence below is order-sensitive, so it lives in one place.

    /// A run must not start on top of one that was cancelled but is still
    /// running, and this makes that state visible.
    ///
    /// A blocking FFI call cannot be interrupted, so Stop only walks away from
    /// it — and `clearCancel()` at the top of a run clears the very flag that
    /// was going to make the abandoned call unwind. A second mobilebackup2
    /// exchange started in that window is two sessions on one RSD adapter, which
    /// is the hazard `InFlightCall` exists to record.
    ///
    /// This WARNS rather than blocks, deliberately. Blocking is the safer
    /// default, but an abandoned call may never drain at all, which would turn
    /// "press Stop" into "press Stop, then force-quit the app" — a worse failure
    /// than the one it prevents. The state is logged instead, so it is never
    /// invisible; adding a drain wait here is the trade to revisit if that
    /// ever looks wrong.
    ///
    /// Must run BEFORE `clearCancel()`: clearing first erases the signal the
    /// previous run is still waiting on.
    private func warnIfPreviousCallStillRunning() {
        guard InFlightCall.shared.isBusy else { return }
        log("⚠️ a previous device call is still running "
            + "(\(InFlightCall.shared.abandonedDescription)) — starting a new run on top of it. "
            + "If that call was cancelled it may still hold the session, so a failure from here that "
            + "looks like a device problem may be two sessions sharing one RSD adapter: force-quit "
            + "the app, then run again.")
    }

    /// Everything a run does before touching the device.
    ///
    /// Returns the device UDID (needed to name the backup root).  Throws
    /// `GoldenNuggetError` for the operator-facing failures.
    private func prepareRun() async throws -> String {
        let minimuxer = Minimuxer.shared()
        guard await testReady(minimuxer) else {
            throw GoldenNuggetError("minimuxer is not ready. Ensure WiFi and a working tunnel (LocalDevVPN or WireGuard + em_proxy), then select a pairing file.")
        }
        guard let udid = try await minimuxer.core.fetchUDID() else {
            throw GoldenNuggetError("Could not fetch device UDID")
        }
        log("UDID: \(udid)")
        log("Tunnel: \(Tunnel.describe())")
        try await Diagnostics.preflightBackupEncryption()
        // Everything after this byte offset is this run's Rust output.
        markRustLog()

        return udid
    }

    /// The version the manifest-format fork branches on — never a guess.
    ///
    /// An empty `fallback` means "the page never managed to read it" (it reads
    /// once, when it appears, and lockdown may not have been answering yet), and
    /// **not** "iOS 26". Parsing it as 0 used to send a 27.0 device down the
    /// legacy branch, which cannot work there: that branch synthesises a backup
    /// from nothing, and what the device answers is
    /// `MBErrorDomain/205 — No keybag in manifest` (2026-09-26).
    ///
    /// So re-read lockdown — `prepareRun()` has just shown it is ready — and
    /// refuse to continue if even that fails. Refusing beats defaulting: the two
    /// branches want different manifest formats, and a wrong pick costs the
    /// operator a whole run plus a puzzle like this one.
    private func resolvedDeviceVersion(_ fallback: String) async throws -> String {
        if !fallback.isEmpty { return fallback }
        log("device version: the caller had none (it read the identity before lockdown answered) "
            + "— re-reading before the format fork")
        let identity = await DeviceIdentity.read()
        guard !identity.version.isEmpty else {
            throw GoldenNuggetError(
                "Could not read the device's iOS version (lockdown ProductVersion), which this run "
                + "needs to choose a manifest format: iOS 27+ gets a protective backup pulled from the "
                + "device with a sqlite Manifest.db, iOS 26 a legacy MBDB backup synthesised on the "
                + "host. Unlock the device, confirm the tunnel is up, then run again.")
        }
        log("device version: lockdown answered \(identity.version)")
        return identity.version
    }

    /// Start from an empty backup root.  Both flows need this: the manifest is
    /// merged into, not replaced, so a leftover Manifest.db from a previous run
    /// would leak its rows (and its pruned keep-set) into this one.
    private func resetDirectory(_ url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// Clamp and throttle a Rust progress callback down to whole percent.
    ///
    /// The callback fires per file; logging every call appended thousands of
    /// lines and pushed the interesting ones out of the UI list.
    private func logProgress(_ prefix: String, _ overall: Double) {
        let pct = overall < 0 ? 0 : min(overall, 100)
        reportProgress(pct)
        log(String(format: "\(prefix): %.0f%%", pct))
    }

    /// Stage 4: one mobilebackup2 restore, with the iOS-27 transient-channel
    /// retry in front of it.
    ///
    /// `onSuccess` carries only the success wording — the two flows describe
    /// their outcome differently, but the failure line is the same.
    private func runRestore(
        backupRoot: URL,
        udid: String,
        label: String,
        onSuccess: () -> Void
    ) async throws {
        // Say what is being offered before offering it.  Every recorded "the
        // restore said success but only part came back" run so far has had to be
        // reconstructed from the prune / inject / placeholder lines after the
        // fact; this puts the same numbers in one place, at the moment they are
        // still actionable.
        let deviceDir = AppPaths.deviceDir(backupRoot: backupRoot, udid: udid)
        log(ManifestStore(deviceDir: deviceDir).auditAgainstDisk())

        let code = try await ChannelRecovery.retry(
            label: label,
            attempts: 3,
            diagnostics: { await Diagnostics.report() }
        ) {
            try await RestoreRunner.run(backupRoot: backupRoot, sourceIdentifier: udid)
        }

        if code == 0 {
            onSuccess()
        } else {
            // Unreachable while RestoreRunner verifies its own outcome, but kept
            // so a future path that stops doing so cannot fail silently.
            log("restore returned \(code) without confirming completion — inspect the log above.")
        }
    }

    // MARK: - Readiness

    private func testReady(_ minimuxer: Minimuxer) async -> Bool {
        if case .success(true) = await minimuxer.core.isReady() {
            return true
        }
        try? await Task.sleep(nanoseconds: 500_000_000)
        if case .success(true) = await minimuxer.core.isReady() {
            return true
        }
        return false
    }
}
