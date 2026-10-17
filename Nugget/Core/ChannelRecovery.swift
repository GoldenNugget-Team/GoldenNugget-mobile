import Foundation
import Minimuxer

/// Retry and escalating recovery for a dropped device channel.
///
/// A single `invalidateConnection()` is NOT always enough — the Swift gateway
/// caches its RSD adapter/handshake **and** the `deviceEndpointIp` the Rust
/// tunnel dials, while the em_proxy/muxer plumbing is never recreated.  So
/// recovery releases one more layer of cached state per level (see
/// `RecoveryLevel`), and every failure dumps a diagnostics block so the failing
/// layer is identifiable from the app log alone.
///
/// The retry decision comes from `TransportFailure.retryDecision`, i.e. from the
/// *kind* of failure, not from the attempt number.  The attempt number is still
/// honoured as a floor, so a failure that recurs keeps escalating even if its
/// kind alone would not ask for it.
enum ChannelRecovery {
    /// Run `body`, retrying on a dropped device channel.
    ///
    /// - Parameter beforeAttempt: receives the 1-based attempt number, so a
    ///   caller can do the expensive reset only on the first try.
    /// - Parameter diagnostics: produces the failure dump.  Injected rather than
    ///   reached for, so this file does not depend on the engine.
    @discardableResult
    static func retry<T>(
        label: String,
        attempts: Int = 3,
        delaySeconds: UInt64 = 1,
        diagnostics: (() async -> String)? = nil,
        beforeAttempt: ((Int) async throws -> Void)? = nil,
        _ body: () async throws -> T
    ) async throws -> T {
        var attempt = 0
        while true {
            attempt += 1
            do {
                if let beforeAttempt { try await beforeAttempt(attempt) }
                return try await body()
            } catch {
                let failure = TransportFailureClassifier.classify(error, label: label)

                switch failure.retryDecision {
                case .failFast(let reason):
                    // Two shapes of message, kept from the original so the log
                    // stays grep-able: the operator's own stop and the wedged
                    // handshake each have their own line, everything else shares
                    // the "not a channel drop" wording.
                    switch failure {
                    case .cancelled:
                        AppLog.write("\(label) \(reason)")
                    case .handshakeSilent:
                        AppLog.write("\(label) aborted: \(error.localizedDescription)")
                    default:
                        AppLog.write("\(label) failed (\(reason), not retrying): "
                            + "\(error.localizedDescription)")
                    }
                    if let diagnostics { AppLog.write(await diagnostics()) }
                    throw error

                case .retry(let floor, let why):
                    if attempt >= attempts {
                        AppLog.write("\(label) did not get through in \(attempt) attempts — giving up.")
                        if let diagnostics { AppLog.write(await diagnostics()) }
                        throw error
                    }
                    // Short first wait, then double.  A flat 3 s cost 12 s of
                    // pure sleep over 5 attempts for nothing: the retry either
                    // lands on a freshly authorized session immediately or not at
                    // all.
                    let delay = min(delaySeconds << UInt64(attempt - 1), 8)
                    // The failure kind sets the floor; a failure that keeps
                    // recurring still escalates on top of it.
                    let level = min(max(floor.rawValue, attempt), RecoveryLevel.restartMuxer.rawValue)
                    AppLog.write("\(label) attempt \(attempt)/\(attempts) \(why) "
                        + "(\(error.localizedDescription)); recovering and retrying in \(delay)s…")
                    await recover(level: level)
                    try await Task.sleep(nanoseconds: delay * 1_000_000_000)
                }
            }
        }
    }

    /// Escalating recovery between retry attempts.  Each level releases one more
    /// layer of cached state, because a dropped channel can be caused by any of
    /// them being stale.
    ///
    /// 1. RSD adapter + handshake         → `invalidateConnection()`
    /// 2. tunnel peer IP (route change)   → `network.refreshEndpoint()`
    /// 3. endpoint pin + muxer plumbing   → `setDeviceEndpointIp` + `core.restart()`
    static func recover(level: Int) async {
        let minimuxer = Minimuxer.shared()
        AppLog.write("recover(level \(level)): dropping cached RSD tunnel…")
        minimuxer.ideviceGateway?.invalidateConnection()
        guard level > RecoveryLevel.dropRSD.rawValue else { return }

        AppLog.write("recover(level \(level)): re-discovering tunnel endpoint…")
        await minimuxer.network.refreshEndpoint()
        guard level > RecoveryLevel.refreshEndpoint.rawValue else { return }

        // The Rust tunnel dials `deviceEndpointIp`. If a tunnel flap left that
        // cached IP stale, every attempt dies identically no matter how often
        // the adapter is dropped. Pin the LocalDevVPN peer the app probes and
        // rebuild the muxer plumbing on top of it.
        AppLog.write("recover(level \(level)): pinning endpoint to \(Tunnel.peerIP) and restarting minimuxer…")
        minimuxer.gateway.setDeviceEndpointIp(Tunnel.peerIP)
        let stage = StageTimer("recover restart")
        do {
            try await minimuxer.core.restart()
            // Bounded at ~4 s: this runs between retry attempts, so a 10 s
            // readiness poll here is dead time on top of the retry backoff.
            var ready = false
            for _ in 0..<14 {
                if case .success(true) = await minimuxer.core.isReady(withNetworkCheck: true) {
                    ready = true
                    break
                }
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            stage.done("ready=\(ready)")
            AppLog.write("recover(level \(level)): minimuxer restarted, endpoint pinned (ready=\(ready))")
        } catch {
            stage.done("restart failed")
            AppLog.write("recover(level \(level)): minimuxer restart failed "
                + "(\(error.localizedDescription)) — continuing anyway")
        }
    }
}
