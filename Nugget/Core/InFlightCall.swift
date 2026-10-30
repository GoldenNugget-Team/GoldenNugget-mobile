import Foundation

/// Separates a user-visible run from its blocking device calls. Cancelling a
/// wait cannot stop Rust; a new run must not reuse its session or backup tree
/// until the last abandoned call has actually returned.
final class InFlightCall: @unchecked Sendable {
    static let shared = InFlightCall()

    private let lock = NSLock()
    private var depth = 0
    private var runActive = false

    enum Failure: Error, LocalizedError {
        case busy
        var errorDescription: String? {
            "A previous device operation is still running. Wait for it to finish; if a cancelled operation remains blocked, restart the app before trying again."
        }
    }

    /// Reserve the entire run, including preparation before its first FFI call.
    func beginRun() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !runActive && depth == 0 else { throw Failure.busy }
        runActive = true
    }

    func endRun() {
        lock.lock()
        runActive = false
        lock.unlock()
    }

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

    /// Whether a user-visible run owns the device right now — the flag
    /// `beginRun` sets. Work that must not start mid-run (the background media
    /// copy) reads this instead of trying to begin a run of its own.
    var isRunActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return runActive
    }

    var abandonedDescription: String {
        lock.lock()
        defer { lock.unlock() }
        return abandonedLabel ?? "the device operation"
    }

}
