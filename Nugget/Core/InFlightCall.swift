import Foundation

// "We stopped waiting for it" and "it stopped running" are two different facts.
//
// The retry ladder used to treat them as one, and that is the root of the worst
// class of failure this app has: a Rust read blocked on a socket cannot be
// interrupted, so `StallGuard` can only abandon the *wait* — the call keeps
// running on `DispatchQueue.global()` (see `withFFIDispatch`) and keeps using
// the shared RSD adapter.  `ChannelRecovery` then immediately called
// `recover(level:)`, whose first statement is `invalidateConnection()`, i.e.
// freeing that adapter out from under a call that is still using it — and then
// started a second mobilebackup2 operation on the same session.
//
// This type records the second fact so the ladder can act on it.
//
// CURRENT WIRING (2026-09-20)
//
//   * `StallGuard.run` calls `enter()` / `defer leave()` around the guarded call,
//     and `noteAbandoned(label:)` on the one path that abandons it (the operator's
//     cancel).  So `isBusy` is now truthful.
//   * `GoldenNuggetEngine.warnIfPreviousCallStillRunning()` reads it at the start of a
//     run and logs the state — it does NOT block, and nothing waits for a drain.
//
// The absence of a drain wait is deliberate rather than forgotten.  With the
// automatic timeouts gone (see `StallGuard`), a cancel is the only way a call is
// abandoned, and an abandoned FFI read may never drain at all — so gating the next
// run on it would turn "press Stop" into "press Stop, then force-quit the app".
// Warning keeps the dangerous window visible without adding that failure.  The
// other half of the original hazard — `recover()` invalidating the adapter
// underneath a call still in flight — is closed by the same change that removed
// the timeouts: the retry ladder can now only be entered by an error the FFI
// actually threw, and a cancel is `failFast`.

/// Tracks whether a device call is still in flight after having been abandoned.
///
/// `depth` is normally 0 or 1 (one long operation at a time), but it is a
/// counter rather than a flag so that a retry which somehow overlaps a
/// not-yet-drained attempt can never clear the gate early.
final class InFlightCall: @unchecked Sendable {
    static let shared = InFlightCall()

    private let lock = NSLock()
    private var depth = 0
    private var abandoned = false
    private var abandonedLabel: String?

    private init() {}

    /// A call is about to start running.
    func enter() {
        lock.lock()
        depth += 1
        lock.unlock()
    }

    /// The call really returned (success or failure).  Only this clears the gate.
    func leave() {
        lock.lock()
        depth = max(0, depth - 1)
        if depth == 0 {
            // Fully drained — the runtime is clean again and a retry is safe.
            abandoned = false
            abandonedLabel = nil
        }
        lock.unlock()
    }

    /// The guard walked away from a call that is still running.
    func noteAbandoned(label: String) {
        lock.lock()
        abandoned = true
        abandonedLabel = label
        lock.unlock()
    }

    /// True while a Rust call is still executing, abandoned or not.
    var isBusy: Bool {
        lock.lock()
        defer { lock.unlock() }
        return depth > 0
    }

    var abandonedDescription: String {
        lock.lock()
        defer { lock.unlock() }
        return abandonedLabel ?? "the device operation"
    }

}
