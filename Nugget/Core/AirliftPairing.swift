import Foundation
import AirliftFFI

/// AirCard-iOS's self-pairing path, as a thin Swift face over `AirliftFFI`.
///
/// `al_pairing_run_host` is the proven alternative to Minimuxer's
/// `pairable_host_accept`.  Both do the same thing — the app binds a TCP
/// listener, this iPhone discovers it over `_remotepairing-pairable-host._tcp`,
/// and the two run Apple's pair-setup — but they advertise in opposite places,
/// and that is the whole difference:
///
/// * Minimuxer hands the host to Rust `mdns_sd`, which needs a multicast
///   entitlement iOS does not grant a normal app, so the service never reaches
///   the LAN.  Its Swift `NetService` fallback is fed a hand-written TXT
///   (`txtvers/id/model/name`, `IdeviceGateway.swift:2208`) that is missing the
///   `authTag`, `flags`, `ver` and `minVer` keys the RemotePairing daemon
///   matches on, so the daemon never offers it as a pairable host.
/// * This path advertises in Swift.  Rust calls back with the *full* TXT —
///   `authTag`, `flags=1`, `ver=26`, `minVer=17` — computed by
///   `PairableHostInfo::mdns_txt_records`, and it is that record the caller
///   publishes with `NetService`.  `NetService` goes through mDNSResponder, so
///   no multicast entitlement is involved.
///
/// The call blocks until the device connects and the handshake finishes, so
/// call it off the main thread.
enum AirliftPairing {
    /// What Rust reports once it has bound its listener.
    struct Ready {
        /// Bonjour instance name, and the `identifier` key in the TXT.
        let serviceID: String
        /// The TCP port Rust is listening on.
        let port: UInt16
        /// Every TXT key/value the daemon expects, already computed by Rust.
        let txt: [String: String]
    }

    /// A finished pairing.
    struct Paired {
        let deviceName: String
        let deviceModel: String
        let deviceUDID: String
        let pairingFilePath: String
        /// Hex altIRK, for the caller to persist and hand back on the next run.
        let hostAltIRKHex: String
    }

    enum Failure: Swift.Error, LocalizedError {
        case runFailed(String)

        var errorDescription: String? {
            switch self {
            case .runFailed(let message): return message
            }
        }
    }

    /// Holds the caller's closures behind the void pointer the C callbacks take.
    ///
    /// `@convention(c)` function pointers cannot capture, so the two closures
    /// ride through `ctx` instead.  Retained by `run` for the call's lifetime.
    private final class Context {
        let onReady: (Ready) -> Void
        let onPin: (String) -> Void

        init(onReady: @escaping (Ready) -> Void, onPin: @escaping (String) -> Void) {
            self.onReady = onReady
            self.onPin = onPin
        }
    }

    /// Run the host to completion.  Blocking; call off the main thread.
    ///
    /// - Parameters:
    ///   - bindAddr: local interface to bind; `0.0.0.0` is every interface.
    ///   - port: 0 lets the OS pick a free port.
    ///   - name: host display name; also seeds a fresh key pair when `outPath`
    ///     does not yet exist.
    ///   - model: host model string the daemon records.
    ///   - outPath: where the paired record is written.  An existing file is
    ///     reused for its host key pair, so a second run keeps the same identity.
    ///   - hostAltIRKHex: altIRK returned by a previous run, or `nil` first time.
    ///   - onReady: called once, with the Bonjour details, before the accept.
    ///   - onPin: called with the PIN the user confirms on the device.
    static func run(
        bindAddr: String = "0.0.0.0",
        port: UInt16 = 0,
        name: String,
        model: String,
        outPath: String,
        hostAltIRKHex: String? = nil,
        onReady: @escaping (Ready) -> Void,
        onPin: @escaping (String) -> Void
    ) throws -> Paired {
        let context = Context(onReady: onReady, onPin: onPin)
        let contextPtr = Unmanaged.passRetained(context).toOpaque()
        defer { Unmanaged<Context>.fromOpaque(contextPtr).release() }

        let readyCb: ALPairReadyCb = { ctx, serviceID, port, keys, vals, count in
            guard let ctx, let serviceID, let keys, let vals else { return }
            let context = Unmanaged<Context>.fromOpaque(ctx).takeUnretainedValue()
            var txt: [String: String] = [:]
            for i in 0..<Int(count) {
                guard let key = keys[i], let value = vals[i] else { continue }
                txt[String(cString: key)] = String(cString: value)
            }
            context.onReady(Ready(serviceID: String(cString: serviceID), port: port, txt: txt))
        }
        let pinCb: ALPairPinCb = { pin, ctx in
            guard let pin, let ctx else { return }
            let context = Unmanaged<Context>.fromOpaque(ctx).takeUnretainedValue()
            context.onPin(String(cString: pin))
        }

        var out = ALPairResult()
        let rc = al_pairing_run_host(
            bindAddr, port, name, model, outPath, hostAltIRKHex ?? "",
            readyCb, pinCb, contextPtr, &out
        )
        defer { al_pairing_result_free(&out) }

        if rc != 0 {
            let message = out.error.map { String(cString: $0) } ?? "pairing failed (code \(rc))"
            throw Failure.runFailed(message)
        }

        return Paired(
            deviceName: out.device_name.map { String(cString: $0) } ?? name,
            deviceModel: out.device_model.map { String(cString: $0) } ?? model,
            deviceUDID: out.device_udid.map { String(cString: $0) } ?? "",
            pairingFilePath: out.pairing_file_path.map { String(cString: $0) } ?? outPath,
            hostAltIRKHex: out.host_alt_irk_hex.map { String(cString: $0) } ?? ""
        )
    }
}
