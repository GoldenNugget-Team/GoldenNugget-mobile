import Foundation

/// Set by the UI's stop button; polled by `StallGuard.run`.
///
/// There is no way to interrupt a Rust read that is blocked on a socket, so
/// "cancel" means abandoning the call and unwinding — the same trade-off the
/// stall guard makes, exposed to the person watching.
///
/// With the automatic timeouts gone (see `StallGuard`), this is the ONLY way a
/// long call can end early, which makes it the load-bearing control it always
/// should have been.
final class CancelFlag: @unchecked Sendable {
    static let shared = CancelFlag()

    private let lock = NSLock()
    private var flag = false

    var isRequested: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }

    func request() {
        lock.lock()
        flag = true
        lock.unlock()
        AppLog.write("⏹ stop requested — the current blocking call will be abandoned at the next check")
    }

    func clear() {
        lock.lock()
        flag = false
        lock.unlock()
    }
}

/// Watches a long device call. **It observes and reports; it does not time out.**
///
/// WHY THE TIMEOUTS WERE REMOVED (2026-09-20)
///
/// This used to abandon the call on four separate deadlines: a silent handshake
/// (45 s), a stalled stream (idle → out-of-band probe → `maxIdleSeconds`), and a
/// tunnel crawl (an out-of-order flood with a gap that would not close). Every
/// one of them ended by walking away from a call the FFI cannot interrupt, and
/// the retry ladder then rebuilt the session underneath it.
///
/// The measured cost, from the 2026-09-19/20 runs: abandoning a mid-flight
/// mobilebackup2 exchange tore the session down while the device was still in
/// the middle of it. The device-side daemon then stayed wedged across app
/// restarts — every following attempt connected to `mobilebackup2` and never
/// received a `DLMessageVersionExchange` at all — so a run that had merely
/// stalled became a run that could not proceed until the device was rebooted.
/// Rebuilding the tunnel never once recovered a transfer; it only added the
/// wedge.
///
/// The trade is therefore explicit, and the operator's:
///
///   - a stalled call keeps waiting, with a live heartbeat below;
///   - `CancelFlag` — the stop button — is the only thing that ends it early.
///
/// All of the watchdog's *measurements* are kept, because they are how this
/// stall was ever diagnosed: the handshake-silence check, the two wire clocks,
/// the delivery-rate window and the out-of-band probe still run and still
/// print. What is gone is the part that acted on them.
///
/// `mobilebackup2_backup` has no deadline of its own, so a genuinely dead run
/// now blocks until it is cancelled. That is the deliberate choice: a visible
/// hang with a stop button, instead of an automatic teardown that needed a
/// device reboot to recover from.
///
/// A second consequence, and a good one: `ChannelRecovery.recover()` calls
/// `invalidateConnection()`, which is only safe once the failing call has
/// actually returned. With the timeout paths gone, the retry ladder can only be
/// entered by an error the FFI itself threw — a cancel is `failFast` and never
/// reaches `recover()` — so the teardown can no longer race a call that is
/// still in flight. That race is exactly what `InFlightCall` exists to prevent,
/// and it is no longer reachable from here.
enum StallGuard {
    /// Runs `body`, reporting on it while it is silent.
    ///
    /// Returns when `body` returns; throws `TransportFailure.cancelled` if the
    /// operator stops it. Those are the only two ways out.
    ///
    /// "Silent" means BOTH clocks are quiet:
    ///   - `idle()` — the host delegate callbacks (a file arrived, a chunk
    ///     landed), i.e. payload actually moving;
    ///   - `wire()` — the wire counters in the Rust log (DeviceLink messages,
    ///     plus jktcp's out-of-order segments and the byte position it can
    ///     actually deliver).
    ///
    /// The second one is what keeps a healthy run from looking dead: the device
    /// spends real time enumerating the host tree and preparing batches, and for
    /// minutes of that work it fires no host callback at all.
    @discardableResult
    static func run<T>(
        label: String,
        idleSeconds: Int,
        pollSeconds: UInt64 = 5,
        silentHandshakeSeconds: Int = 45,
        crawlSeconds: Double = 15,
        crawlFloorBytesPerSecond: Double = 16 * 1024,
        crawlMinGapBytes: UInt64 = 128 * 1024,
        idle: @escaping @Sendable () -> Date,
        wire: (@Sendable () -> RustWireSample)? = nil,
        probe: (@Sendable () async -> (alive: Bool, detail: String))? = nil,
        handshakeSilent: (@Sendable () -> Bool)? = nil,
        _ body: @escaping () async throws -> T
    ) async throws -> T {
        let once = OnceResumer<T>()
        return try await withCheckedThrowingContinuation { cont in
            once.attach(cont)
            Task {
                // In-flight accounting.  Cancelling only walks away from a call
                // that keeps running, so "the block finished" and "we stopped
                // waiting for it" are two different facts — and a caller about to
                // start the next run needs to know which one it is looking at.
                InFlightCall.shared.enter()
                defer { InFlightCall.shared.leave() }
                do { once.resume(.success(try await body())) }
                catch { once.resume(.failure(error)) }
            }
            Task {
                await observe(
                    label: label,
                    once: once,
                    pollSeconds: pollSeconds,
                    idleSeconds: idleSeconds,
                    silentHandshakeSeconds: silentHandshakeSeconds,
                    crawlSeconds: crawlSeconds,
                    crawlFloorBytesPerSecond: crawlFloorBytesPerSecond,
                    crawlMinGapBytes: crawlMinGapBytes,
                    idle: idle,
                    wire: wire,
                    probe: probe,
                    handshakeSilent: handshakeSilent)
            }
        }
    }

    /// How often a repeating observation may print.  Ten minutes of stall should
    /// produce twenty lines, not one per poll.
    private static let noticeInterval: TimeInterval = 30

    /// The observer loop.  Note what it does NOT contain: any call to
    /// `once.resume` other than the operator's cancel.
    private static func observe<T>(
        label: String,
        once: OnceResumer<T>,
        pollSeconds: UInt64,
        idleSeconds: Int,
        silentHandshakeSeconds: Int,
        crawlSeconds: Double,
        crawlFloorBytesPerSecond: Double,
        crawlMinGapBytes: UInt64,
        idle: @escaping @Sendable () -> Date,
        wire: (@Sendable () -> RustWireSample)?,
        probe: (@Sendable () async -> (alive: Bool, detail: String))?,
        handshakeSilent: (@Sendable () -> Bool)?
    ) async {
        var handshakeSince: Date? = nil
        var handshakeReported = false
        var lastNotice = Date()
        var lastWire: RustWireSample?
        var lastWireAt = Date()
        var crawlReportedAt: Date? = nil
        var probeVerdict: String? = nil
        var probed = false
        var delivery: [DeliverySample] = []

        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: pollSeconds * 1_000_000_000)
            if once.isSettled { return }

            if CancelFlag.shared.isRequested {
                AppLog.write("⏹ \(label): cancelled by the user — abandoning the call "
                    + "(a blocked Rust read cannot be interrupted, only walked away from)")
                // Record the second fact: this call is still running and nobody
                // is waiting for it any more.
                InFlightCall.shared.noteAbandoned(label: label)
                once.resume(.failure(TransportFailure.cancelled(label: label)))
                return
            }

            // ── Handshake silence ────────────────────────────────────────────
            //
            // A healthy version exchange takes milliseconds, so "the device has
            // not opened the DeviceLink conversation at all" is a daemon
            // problem, not a slow transfer.  Reported once, with the action,
            // rather than acted on.
            if let handshakeSilent {
                if handshakeSilent() {
                    let from = handshakeSince ?? Date()
                    handshakeSince = from
                    let held = Int(Date().timeIntervalSince(from))
                    if held >= silentHandshakeSeconds, !handshakeReported {
                        handshakeReported = true
                        AppLog.write("⏱ \(label): the device has not sent its first DeviceLink "
                            + "message for \(held)s. The mobilebackup2 client is a pure reader at "
                            + "this point — the device initiates with DLMessageVersionExchange and "
                            + "this side only answers — so nothing the app sends can cause it. The "
                            + "device-side daemon is the one not talking, and it stays wedged across "
                            + "app restarts, so REBOOT THE DEVICE before the next attempt. "
                            + "Still waiting; press Stop to end this run.")
                    }
                } else {
                    if handshakeSince != nil {
                        AppLog.write("⏱ \(label): the device answered the handshake — that verdict "
                            + "is withdrawn")
                    }
                    handshakeSince = nil
                    handshakeReported = false
                }
            }

            let now = Date()

            // ── Wire clocks ─────────────────────────────────────────────────
            if let wire {
                let s = wire()
                if let previous = lastWire, s.dlMessages > previous.dlMessages {
                    lastWireAt = now
                    // Talking again: the earlier observations described a state
                    // that no longer holds, so they are withdrawn rather than
                    // left to be read as current.
                    if probed || crawlReportedAt != nil {
                        AppLog.write("⏱ \(label): the device is talking again "
                            + "(\(s.dlMessages) DL message(s) this run) — earlier stall verdicts "
                            + "withdrawn")
                    }
                    probed = false
                    probeVerdict = nil
                    crawlReportedAt = nil
                }
                lastWire = s

                // The delivery-rate window: it is what turns "the tunnel is
                // quiet" into "the tunnel is refusing to hand bytes up".
                if let previous = delivery.last, let previousExpected = previous.expected,
                   let expected = s.expected {
                    let dt = now.timeIntervalSince(previous.at)
                    let moved = expected > previousExpected ? expected - previousExpected : 0
                    if dt > 0, Double(moved) / dt >= crawlFloorBytesPerSecond {
                        // Bytes are demonstrably moving again, so whatever hole
                        // was open is closed and the next window starts clean.
                        delivery.removeAll()
                    }
                }
                if s.expected != nil {
                    delivery.append(DeliverySample(at: now, outOfOrder: s.outOfOrder,
                                                   expected: s.expected, gap: s.gap))
                }
                let horizon = now.addingTimeInterval(-(crawlSeconds * 3))
                while let oldest = delivery.first, oldest.at < horizon {
                    delivery.removeFirst()
                }
                if let first = delivery.first, let last = delivery.last,
                   let report = crawlObservation(
                        first: first, last: last, sample: s,
                        crawlSeconds: crawlSeconds,
                        crawlFloorBytesPerSecond: crawlFloorBytesPerSecond,
                        crawlMinGapBytes: crawlMinGapBytes) {
                    if crawlReportedAt == nil || now.timeIntervalSince(crawlReportedAt!) >= noticeInterval {
                        crawlReportedAt = now
                        lastNotice = now
                        AppLog.write("⏱ \(label): \(report)")
                    }
                }
            }

            // ── Quiet ───────────────────────────────────────────────────────
            let quiet = Int(now.timeIntervalSince(max(idle(), lastWireAt)))
            guard quiet >= idleSeconds else {
                probed = false
                probeVerdict = nil
                continue
            }

            if !probed, let probe {
                probed = true
                let result = await probe()
                probeVerdict = result.detail
                AppLog.write("⏱ \(label): nothing for \(quiet)s — out-of-band check: \(result.detail)")
            }

            if now.timeIntervalSince(lastNotice) >= noticeInterval {
                lastNotice = now
                let why = probeVerdict.map { "out-of-band check said: \($0)" }
                    ?? "no out-of-band verdict, so this is simply the quiet window"
                AppLog.write("⏱ \(label): still quiet — \(quiet)s since the last sign of life, and "
                    + "\(why). Waiting; press Stop to end this run.")
            }
        }
    }

    /// The measurement behind "the tunnel stopped delivering", or nil when the
    /// window does not support it.
    ///
    /// Kept exactly as it was when it gated an automatic teardown — the numbers
    /// are the evidence, and they are still printed. It just no longer decides
    /// anything on its own.
    private static func crawlObservation(
        first: DeliverySample,
        last: DeliverySample,
        sample: RustWireSample,
        crawlSeconds: Double,
        crawlFloorBytesPerSecond: Double,
        crawlMinGapBytes: UInt64
    ) -> String? {
        let span = last.at.timeIntervalSince(first.at)
        let segments = last.outOfOrder - first.outOfOrder
        guard span >= crawlSeconds, segments >= 8,
              let gap = sample.gap, gap >= crawlMinGapBytes,
              let startGap = first.gap else { return nil }

        // "The hole is NOT closing", not "the hole is growing": a peer that
        // retransmits one out-of-window segment on repeat leaves the gap
        // byte-for-byte constant while the counter climbs.  Any shrink at or
        // below the crawl floor is still a crawl, so the tolerance is derived
        // from the floor rather than hand-picked.
        let recoverable = UInt64(crawlFloorBytesPerSecond * crawlSeconds)
        guard startGap <= gap + recoverable else { return nil }

        // `first.expected` is present whenever `first.gap` is (the gap is
        // derived from it), so the `?? 0` below is unreachable by construction —
        // it is there to keep the arithmetic total.
        let from = first.expected ?? 0
        let to = last.expected ?? 0
        let delivered = to > from ? to - from : 0
        let rate = Double(delivered) / span
        guard rate < crawlFloorBytesPerSecond else { return nil }

        // Full phrases, not fragments: "the backlog has still growing" shipped
        // once and read as a bug in itself.
        let shape = gap > (first.gap ?? gap) ? "is still growing" : "held steady"
        // Whether the peer is even trying to fill the gap.  Measured 2026-09-19:
        // the device re-sent NOTHING for 88 s while 3.1 MB sat in the reorder
        // buffer, so patience was never going to be the remedy either.
        let retryNote = sample.retransmits > 0
            ? "the device re-sent \(sample.retransmits) range(s) meanwhile, so the gap is filling "
                + "slowly rather than never"
            : "the device has re-sent NOTHING meanwhile, so no amount of waiting will fill the gap"
                + (sample.duplicateAcks > 0
                    ? " (jktcp sent it ×\(sample.duplicateAcks) duplicate ACK(s), so the ask was made)"
                    : " (jktcp sent no duplicate ACK(s), so the hole was never announced)")
        return "the tunnel stopped delivering — jktcp is holding \(gap / 1024) KB of the device's "
            + String(format: "stream behind an unfilled gap and delivered %.1f KB/s for %.0fs",
                     rate / 1024, span)
            + " (\(segments) new out-of-order segment(s) meanwhile, the backlog \(shape) for the "
            + "whole window, and \(retryNote)). Not abandoning the call: a mid-flight teardown is "
            + "what wedges the device daemon, so this waits and reports instead."
    }
}
