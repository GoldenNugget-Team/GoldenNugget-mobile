import Foundation

// Progress observation: how a long operation tells the operator it is alive.
//
// These four types exist because the alternative — logging every callback — is
// unreadable, and because "it takes forever" / "it looks hung" are the two
// reports that are impossible to act on without numbers.  They log through
// `AppLog` rather than the engine so they can be used from anywhere.

/// Wall-clock cost of one stage, reported in the app log.
///
/// Added because "it takes forever" is unactionable: the run has several
/// multi-second-or-multi-minute stages (tunnel probe, minimuxer readiness, each
/// backup attempt, the restore itself) and without per-stage numbers there is no
/// way to tell a slow transfer from a stage that is merely sleeping.
///
/// `done()` is idempotent-ish by convention: call it exactly once per stage.
struct StageTimer {
    private let label: String
    private let start = Date()

    init(_ label: String) { self.label = label }

    func done(_ extra: String = "") {
        let secs = Date().timeIntervalSince(start)
        AppLog.write("⏱ \(label): \(String(format: "%.1f", secs))s"
            + (extra.isEmpty ? "" : " — \(extra)"))
    }
}

/// Logs a line every `every` seconds while a long stage runs, so the log shows
/// "still moving" instead of looking hung.
///
/// A stalled backup and a slow one look identical in the UI; the heartbeat
/// separates them (a heartbeat whose detail string never changes = stalled).
final class Heartbeat: @unchecked Sendable {
    private var task: Task<Void, Never>?
    private let start = Date()

    /// - Parameter detail: evaluated on each tick; should be cheap and ideally
    ///   show forward motion (counters, bytes, percentage).
    func start(_ label: String, every seconds: UInt64 = 10,
               detail: @escaping @Sendable () -> String) {
        stop()
        task = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
                if Task.isCancelled { break }
                let secs = Int(Date().timeIntervalSince(self.start))
                AppLog.write("⏱ \(label): \(secs)s elapsed — \(detail())")
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    deinit { task?.cancel() }
}

/// Throttles a 0–100 progress callback down to one log line per 5 % step.
///
/// Both the backup and the restore progress callbacks fire per file; the restore
/// one used to be logged verbatim, which appended thousands of lines to the UI
/// list and buried the lines that matter.
final class PercentThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var lastStep = -1
    private var lastPct: Double = -1
    private var lastActivity = Date()

    /// Timestamp of the last progress sample; see `StallGuard.run`.
    var lastActivityAt: Date {
        lock.lock(); defer { lock.unlock() }
        return lastActivity
    }

    /// The most recent value the device reported; -1 when it never reported one.
    ///
    /// Distinct from the value `livenessLine()` prints: that one is the last 5 %
    /// *step* crossed, so a run ending at 55 % and one ending at 59 % read the
    /// same ("≥55%").  The exit line needs the real number — the whole point of
    /// this type is that the log must be able to state what actually happened.
    var lastPercent: Double {
        lock.lock(); defer { lock.unlock() }
        return lastPct
    }

    /// - Returns: the new 5 % step the first time it is crossed, else nil.
    func step(_ pct: Double) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        lastActivity = Date()
        lastPct = pct
        guard pct >= 0 else { return nil }
        let step = Int(pct / 5) * 5
        guard step > lastStep else { return nil }
        lastStep = step
        return step
    }

    /// Heartbeat detail for the restore stage; see `BackupTrace.livenessLine()`.
    func livenessLine() -> String {
        lock.lock()
        let step = lastStep < 0 ? "not yet reported" : "≥\(lastStep)%"
        let idle = Int(Date().timeIntervalSince(lastActivity))
        lock.unlock()
        return "progress \(step) — host callbacks idle \(idle)s"
    }
}

/// Thread-safe tally of the Rust delegate traffic during a backup.
///
/// `shouldPreserve` and `onProgress` are invoked from the Rust streaming
/// threads, so every counter sits behind a lock and this type never touches the
/// UI — the caller logs `summary()` / `sampleLines()` from its own flow.
///
/// Diagnostic value: `total == 0` means the device never streamed a single
/// file, i.e. the channel died in the request / version-exchange / session
/// authorization phase.  A non-zero total with a stalled `lastProgress` means
/// the drop happened mid-transfer.  Those two point at different subsystems.
final class BackupTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var keptCount = 0
    private var droppedCount = 0
    private var totalCount = 0
    private var lastPct: Double = -1
    private var lastStep = -1
    private var samples: [String] = []
    private var lastActivity = Date()
    /// Every distinct `device_name` the callback was handed, with how many files
    /// it carried and how many survived the filter.
    ///
    /// This is the one thing that decides whether a zero-kept run is fixable in
    /// Swift: the keep-rules match on `device_name`, so if iOS 27 hands over a
    /// bare domain where a path prefix is expected, every rule misses and the
    /// counts here are the proof. `samples` shows twelve individual files, which
    /// is enough to guess from and not enough to rely on.
    private var byDomain: [String: (total: Int, kept: Int)] = [:]

    var kept: Int {
        lock.lock(); defer { lock.unlock() }
        return keptCount
    }

    var dropped: Int {
        lock.lock(); defer { lock.unlock() }
        return droppedCount
    }

    /// One line naming every domain the device offered and how much of it
    /// survived. Sorted so two runs diff cleanly.
    func domainSummary() -> String {
        lock.lock(); defer { lock.unlock() }
        guard !byDomain.isEmpty else { return "no domains seen" }
        return byDomain
            .sorted { $0.key < $1.key }
            .map { "\($0.key)(\($0.value.total) seen, \($0.value.kept) kept)" }
            .joined(separator: " ")
    }

    /// Every file the device offered, kept or not. `kept == 0` with a non-zero
    /// total is the "backup ran but matched nothing" case, which is
    /// indistinguishable from no backup at all without this.
    var total: Int {
        lock.lock(); defer { lock.unlock() }
        return totalCount
    }

    /// Timestamp of the last sign of life from the device.
    ///
    /// The Rust DeviceLink read has no timeout of its own, so this is the only
    /// thing that separates a slow-but-alive transfer from a wedged one; see
    /// `StallGuard.run`.
    var lastActivityAt: Date {
        lock.lock(); defer { lock.unlock() }
        return lastActivity
    }

    /// Records one keep/drop decision.  Keeps the first decisions for the log
    /// (the head of the stream is where an unexpected domain shows up first).
    func note(file: String, domain: String, keep: Bool) {
        lock.lock()
        defer { lock.unlock()
        let bucket = byDomain[domain] ?? (0, 0)
        byDomain[domain] = (bucket.total + 1, bucket.kept + (keep ? 1 : 0)) }
        totalCount += 1
        if keep { keptCount += 1 } else { droppedCount += 1 }
        lastActivity = Date()
        if samples.count < 12 {
            samples.append("  stream[\(totalCount)] \(keep ? "KEEP" : "DROP") \(domain)/\(file)")
        }
    }

    /// Records a progress sample; returns the new 5 % step the first time it is
    /// crossed, else nil (so the caller only logs once per step).
    func noteProgress(_ pct: Double) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        lastPct = pct
        guard pct >= 0 else { return nil }
        let step = Int(pct / 5) * 5
        guard step > lastStep else { return nil }
        lastStep = step
        lastActivity = Date()
        return step
    }

    func summary() -> String {
        lock.lock()
        defer { lock.unlock() }
        let progress = lastPct < 0 ? "never reported" : "\(Int(lastPct))%"
        return "streamed=\(totalCount) kept=\(keptCount) dropped=\(droppedCount) progress=\(progress)"
    }

    /// Heartbeat detail: what moved, and how long the host has been without a
    /// callback.  "3 % and nothing for 90 s" and "3 % and still receiving" are
    /// very different sentences, and only the clock separates them.
    func livenessLine() -> String {
        lock.lock()
        let progress = lastPct < 0 ? "never reported" : "\(Int(lastPct))%"
        let line = "streamed=\(totalCount) kept=\(keptCount) dropped=\(droppedCount) progress=\(progress)"
        let idle = Int(Date().timeIntervalSince(lastActivity))
        lock.unlock()
        return line + " — host callbacks idle \(idle)s"
    }

    func sampleLines() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        guard !samples.isEmpty else { return ["  (device never streamed a single file)"] }
        return samples
    }
}
