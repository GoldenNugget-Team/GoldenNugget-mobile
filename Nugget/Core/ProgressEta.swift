import Foundation

/// Estimate the remaining time of a percentage-based backup/restore — the port
/// of `src/devicemanagement/eta.py`.
///
/// The device progress callbacks report a monotonically increasing percentage
/// (0..100) with no notion of time.  This watches that percentage over
/// wall-clock time and turns it into a short `"m:ss"` estimate for the UI.  It
/// is intentionally stateful and cheap: feed every numeric progress value to
/// `update` and it returns the formatted remaining time (or `""` until a stable
/// rate is known).
///
/// The rate is measured over a sliding window of recent samples so an estimate
/// stays responsive when a fresh phase runs at a different speed, but falls back
/// to the overall average while the window is still filling.  A progress value
/// that drops (a retry/restart) resets the estimator.
struct ProgressEta {
    /// `window_seconds=30.0` (`eta.py:23`): the sliding window, and the gap that
    /// counts as a phase boundary.
    let windowSeconds: TimeInterval
    /// `min_elapsed=5.0`: keep quiet until the run has been going this long.
    let minElapsed: TimeInterval
    /// `min_delta=1.0`: and until it has moved at least this far.
    let minDelta: Double

    private(set) var samples: [(time: TimeInterval, pct: Double)] = []
    private var start: TimeInterval?
    private var lastPct: Double?

    init(windowSeconds: TimeInterval = 30.0,
         minElapsed: TimeInterval = 5.0,
         minDelta: Double = 1.0) {
        self.windowSeconds = windowSeconds
        self.minElapsed = minElapsed
        self.minDelta = minDelta
    }

    /// `reset()` — forget all samples; call before a new operation
    /// (`eta.py:32`).
    mutating func reset() {
        samples = []
        start = nil
        lastPct = nil
    }

    /// `update(percent)` — feed the latest percentage; return `"m:ss"` remaining
    /// or `""` (`eta.py:38`).
    ///
    /// `time.monotonic()` is `ProcessInfo.systemUptime`, which never jumps with
    /// wall-clock changes.  The two reset paths are kept exactly: a lower value
    /// means the operation (re)started, and a gap longer than the window is a
    /// phase boundary (a reboot wait, a user unlock prompt) where no progress is
    /// measurable.
    mutating func update(_ percent: Double) -> String {
        update(percent, now: ProcessInfo.processInfo.systemUptime)
    }

    /// `update` with an explicit now — the reference feeds it
    /// `time.monotonic()`; the regression harness feeds synthetic times so the
    /// window/phase logic is testable without sleeping.
    mutating func update(_ percent: Double, now: TimeInterval) -> String {
        if percent <= 0 {
            reset()
            return ""
        }
        if percent >= 100 {
            return "0:00"
        }
        // A lower value means the operation (re)started — start over.
        if let last = lastPct, percent + 0.01 < last {
            reset()
        }
        // A gap longer than the window is a phase boundary — restart the
        // measurement rather than extrapolate across the dead time.
        if let lastTime = samples.last?.time, now - lastTime > windowSeconds {
            samples = []
            start = now
        }
        if start == nil {
            start = now
        }
        lastPct = percent
        samples.append((now, percent))
        let cutoff = now - windowSeconds
        while samples.count > 2, samples[0].time < cutoff {
            samples.removeFirst()
        }
        return Self.format(estimate(now: now, pct: percent))
    }

    /// `_estimate` (`eta.py:70`): percent-per-second over the window, falling
    /// back to the overall rate while the window has barely moved, returning the
    /// seconds left (or nil until a stable rate is known).
    private func estimate(now: TimeInterval, pct: Double) -> Double? {
        guard let start, now - start >= minElapsed else { return nil }
        let t0 = samples[0].time
        let p0 = samples[0].pct
        var dt = now - t0
        var dp = pct - p0
        if dt <= 0 || dp < minDelta {
            // The window barely moved (phase boundary) — use the overall rate.
            dt = now - start
            dp = pct
        }
        if dt <= 0 || dp <= 0 { return nil }
        let rate = dp / dt  // percent per second
        if rate <= 0 { return nil }
        return (100.0 - pct) / rate
    }

    /// `_format_duration` (`eta.py:88`): `"m:ss"`, or `"h:mm:ss"` past an hour.
    static func format(_ seconds: Double?) -> String {
        guard let seconds else { return "" }
        let total = max(0, Int(seconds.rounded()))
        if total >= 3600 {
            return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
        }
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
