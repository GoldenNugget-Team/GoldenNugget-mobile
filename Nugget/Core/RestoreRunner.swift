import Foundation
import Minimuxer

/// Stage 4: hand the prepared backup back to the device.
enum RestoreRunner {
    /// Run one mobilebackup2 restore of `backupRoot`.
    ///
    /// Returns 0 only for a restore the device confirmed it finished.
    ///
    /// That confirmation is not "the FFI returned": `mobilebackup2_restore`
    /// raises nothing whenever the exchange ends at the protocol level, and a
    /// restore the device abandons part-way ends exactly as cleanly as one it
    /// completes.  `IdeviceGateway.syncRestoreBackup` therefore checks the
    /// device's own response plist AND how far its progress got, and throws
    /// `restoreIncomplete` for anything short.  Returning a constant 0 from here
    /// is safe only because of that check — the previous version returned 0
    /// unconditionally, which is how a 55 % restore was reported as a success.
    @discardableResult
    static func run(backupRoot: URL, sourceIdentifier: String) async throws -> Int32 {
        let minimuxer = Minimuxer.shared()
        AppLog.write("Restoring backup at \(backupRoot.path) (source \(sourceIdentifier)) via mobilebackup2…")

        let beat = Heartbeat()
        let stage = StageTimer("restore")
        // The restore progress callback fires per file.  Logging every callback
        // appended thousands of lines to the UI list (janky to scroll, and the
        // interesting lines get pushed out) — throttle to 5 % steps like the
        // backup path.
        let progress = PercentThrottle()
        beat.start("restore") {
            progress.livenessLine() + ", " + WireCensus.healthLine()
        }
        // Both must be deferred, not called on the way out: this function now
        // throws when the device refuses the restore (error code 205 and
        // friends), and on that path the old code never reached `beat.stop()`.
        // The Heartbeat Task is retained by its own closure, so it stayed alive
        // for the rest of the process — the 2026-09-20 21:19 log has
        // "⏱ restore: 31s elapsed" printed AFTER the run had already ended.
        defer {
            beat.stop()
            stage.done()
        }

        // Same missing-deadline problem as the backup path.  Longer idle window
        // than the backup: a restore negotiates, rewrites the manifest and
        // reboots, and several of those phases report no per-file progress.
        // Same two-part verdict as the backup: quiet with the device still
        // answering lockdown is waited out (up to 10 min), quiet and gone is not.
        try await StallGuard.run(
            label: "restore",
            idleSeconds: 180,
            idle: { progress.lastActivityAt },
            wire: { WireCensus.totals() },
            probe: { await Diagnostics.deviceLivenessProbe() },
            handshakeSilent: { RustLog.deviceSilentAtHandshake() }
        ) {
            try await minimuxer.restoreBackup(
                backupRoot: backupRoot.path(percentEncoded: false),
                sourceIdentifier: sourceIdentifier,
                shouldReboot: false,
                systemFiles: true,
                onProgress: { overall in
                    let pct = overall < 0 ? 0 : min(overall, 100)
                    if let step = progress.step(pct) {
                        AppLog.write("restore progress: \(step)%")
                    }
                },
                // Without this the host-side half of the exchange is invisible:
                // a file the device asked for and the host could not read is
                // answered with an error code the device may well sit on, and
                // nothing anywhere said so.
                delegateLog: { line in AppLog.write(line) }
            )
        }

        // Reached only for an accepted outcome: a restore that ended before the
        // device's own progress got to the end throws at the gateway.  The real
        // number goes in the log here because the heartbeat only ever printed
        // the last 5 % STEP crossed, so "≥55%" was the most precise thing the
        // operator ever saw about a run that had in fact finished.
        let reached = progress.lastPercent
        AppLog.write("restore verified: the device reported "
            + (reached < 0 ? "completion (it sent no percentage)" : "\(Int(reached))%"))
        return 0
    }
}
