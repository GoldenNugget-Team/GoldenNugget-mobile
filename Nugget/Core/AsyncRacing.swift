import Foundation

// Continuation racers.
//
// `withThrowingTaskGroup` cannot express any of the three shapes below: leaving
// the group's scope awaits every child, and the racing body sits in a
// non-cancellable FFI call (or in a socket read with no deadline), so the group
// would block exactly where we are trying to escape.  Each racer therefore
// resumes a checked continuation at most once and lets the loser become a no-op.

/// Resumes a continuation at most once, so whichever of the two racers finishes
/// first wins and the loser is a no-op.
final class OnceResumer<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var settled = false

    var isSettled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return settled
    }

    func attach(_ c: CheckedContinuation<T, Error>) {
        lock.lock()
        defer { lock.unlock() }
        continuation = c
    }

    func resume(_ result: Result<T, Error>) {
        lock.lock()
        guard !settled, let c = continuation else {
            lock.unlock()
            return
        }
        settled = true
        continuation = nil
        lock.unlock()
        c.resume(with: result)
    }
}

/// Settles a `Never`-error continuation at most once — the timeout racer's twin
/// of `OnceResumer`.
final class OnceSettler<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?
    private var settled = false

    func attach(_ c: CheckedContinuation<T, Never>) {
        lock.lock()
        continuation = c
        lock.unlock()
    }

    func settle(_ value: T) {
        lock.lock()
        guard !settled, let c = continuation else {
            lock.unlock()
            return
        }
        settled = true
        continuation = nil
        lock.unlock()
        c.resume(returning: value)
    }
}

/// Run `op`, but give up on it after `seconds` and return `fallback()`.
///
/// The liveness probe must never become the thing that hangs the stall guard: an
/// RSD round trip on a wedged tunnel can block for as long as it is allowed to.
/// The abandoned operation is left running, the same trade-off the stall guard
/// makes (it holds no lock the guard needs).
enum AsyncRacing {
    static func withDeadline<T: Sendable>(
        seconds: Double,
        fallback: @escaping @Sendable () -> T,
        _ op: @escaping @Sendable () async -> T
    ) async -> T {
        let racer = OnceSettler<T>()
        return await withCheckedContinuation { (cont: CheckedContinuation<T, Never>) in
            racer.attach(cont)
            Task { racer.settle(await op()) }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                racer.settle(fallback())
            }
        }
    }
}
