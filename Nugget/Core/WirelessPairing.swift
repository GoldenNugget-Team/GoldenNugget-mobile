import Foundation
import SwiftUI
import UIKit
import Minimuxer

/// On-device wireless pairing (iOS 27 RemotePairing), as an observable service
/// rather than as page state.
///
/// This app used to acquire its pairing record one way only: the user had to
/// bring a `.mobiledevicepairing` file from a computer (or the installer).  With
/// iOS 27 the device can pair **with itself**: an app publishes the
/// `_remotepairing-pairable-host._tcp` service, the device's RemotePairing daemon
/// discovers it, and the two complete a host/device pairing on the phone.
///
/// ## Why this drives AirliftFFI, not Minimuxer's `wirelessPair`
///
/// The vendored Minimuxer carries a whole `WirelessPairAPI` for this, but its
/// two halves never met: the Rust side (`pairable_host_accept`) self-advertises
/// through `mdns_sd`, which iOS blocks for a normal app because it needs a
/// multicast entitlement; and the Swift side publishes a `NetService` whose TXT
/// is hand-written as `txtvers/id/model/name` (`IdeviceGateway.swift:2208`),
/// missing the `authTag`, `flags`, `ver` and `minVer` keys the daemon matches
/// on.  A service the daemon cannot recognise never becomes a "pair" row, which
/// is exactly what the device showed.
///
/// `AirliftFFI`'s `al_pairing_run_host` is AirCard-iOS's proven fix for the same
/// problem: Rust binds the listener and hands back the **full** TXT records
/// (`PairableHostInfo::mdns_txt_records`), and the app publishes *that* with
/// `NetService` — which goes through mDNSResponder and needs no entitlement.
/// See `AirliftPairing` for the binding.
///
/// The object owns the two callbacks — the service becoming ready and the PIN —
/// and the completion, and publishes them for the home page's Connection
/// section.  It deliberately does **not** import or adopt the generated record
/// itself: the file lands at `AppPaths.pairingFile` through the library, and the
/// page hands it to `loadPairingFile`, so the ordinary validate → write →
/// read-back → claim contract stays the one path a record enters the app by.
final class WirelessPairing: NSObject, ObservableObject, NetServiceDelegate {
    static let shared = WirelessPairing()

    enum Phase: Equatable {
        case idle
        /// Publishing the Bonjour service and waiting for the device to connect.
        case advertising
        /// The library returned a fresh record; the page adopts it.
        case paired
        case failed(String)
    }

    /// What the Connection section draws.  Main thread only.
    @Published private(set) var phase: Phase = .idle
    /// The advertised service's Bonjour name, once the ready callback has fired.
    @Published private(set) var serviceName: String?
    /// The local port the pairable host bound, once the ready callback has fired.
    @Published private(set) var port: Int?
    /// The PIN the library generated for the guest to confirm, if one was needed.
    @Published private(set) var pin: String?
    /// Where the library wrote the paired record, for the page to adopt.
    @Published private(set) var generatedRecordPath: String?

    /// The host display name.  Named for the app rather than SideStore so the
    /// identity this advertises is clearly this app's own; the identifier is a
    /// v3 UUID of the string, so a fresh name is also a fresh identity and the
    /// device does not confuse it with a stale "Pair with SideStore" row.
    private static let hostName = "GoldenNugget"

    /// The name the device lists in Settings → Privacy & Security → Developer
    /// Mode, where the user taps the pairable host to pair.  Exposed so the
    /// pairing UI can name that exact row instead of repeating the literal.
    static var displayName: String { hostName }

    /// Where the altIRK from the last successful run is kept.  `al_pairing_run_host`
    /// accepts it back so the host keeps the same trusted identity across runs;
    /// without it every run is a brand-new host to the device.
    private static let hostAltIRKKey = "com.awesomenull.goldennugget.wirelessPair.hostAltIRK"

    /// The Bonjour advertiser.  Held for as long as the run is advertising; the
    /// page only ever talks to this object.
    private var netService: NetService?

    /// Bumped on every start/cancel.  The Rust accept call has no cancellation
    /// (see `cancel`), so a callback from a superseded run is dropped by
    /// comparing against this rather than by trying to stop it.
    private var generation = 0

    /// Keeps the process alive while the user leaves the app for Settings →
    /// Privacy & Security → Developer Mode to tap the pairable host.  The
    /// device-initiated handshake cannot start while the process is suspended,
    /// and the app is suspended a few seconds after it goes to the background
    /// unless it holds one of these.  UIKit grants roughly 30 seconds.
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    private override init() {}

    // MARK: - Background task

    private func beginBackgroundTask() {
        endBackgroundTask()
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "GoldenNugget.WirelessPairing") { [weak self] in
            Task { @MainActor in
                GoldenNuggetEngine.shared.log("wireless pair: background time expired before the device connected")
                self?.endBackgroundTask()
            }
        }
        if backgroundTask == .invalid {
            GoldenNuggetEngine.shared.log("wireless pair: could not start a background task — the device can only pair while the app is on screen")
        } else {
            GoldenNuggetEngine.shared.log("wireless pair: holding background task \(backgroundTask.rawValue) so the device can pair while Settings is open")
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    /// Whether an advertisement is in flight.  The page uses this to swap the
    /// button for the progress row, so it has to answer `false` for the terminal
    /// phases (paired/failed) as well as idle.
    var isRunning: Bool { phase == .advertising }

    // MARK: - Run

    /// Advertise this device as a pairable host and wait for the device to pair
    /// with itself.
    ///
    /// Re-entrant calls are ignored while a run is advertising.
    func start() {
        guard !isRunning else { return }
        phase = .advertising
        serviceName = nil
        port = nil
        pin = nil
        generatedRecordPath = nil

        generation += 1
        let runGeneration = generation
        let savedAltIRK = UserDefaults.standard.string(forKey: Self.hostAltIRKKey)
        let outPath = AppPaths.pairingFile.path(percentEncoded: false)

        GoldenNuggetEngine.shared.log("wireless pair: advertising as \(Self.hostName)/\(MinimuxerConstants.defaultHostModel), "
            + "record → \(AppPaths.pairingFile.lastPathComponent)")
        beginBackgroundTask()

        // DispatchQueue, not Task.detached: `al_pairing_run_host` blocks a whole
        // thread until the device connects, and parking a cooperative-pool
        // thread would starve Swift concurrency for as long as that takes.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result: Result<AirliftPairing.Paired, Swift.Error>
            do {
                result = .success(try AirliftPairing.run(
                    name: Self.hostName,
                    model: MinimuxerConstants.defaultHostModel,
                    outPath: outPath,
                    hostAltIRKHex: savedAltIRK,
                    onReady: { [weak self] ready in
                        DispatchQueue.main.async {
                            self?.advertise(ready, generation: runGeneration)
                        }
                    },
                    onPin: { [weak self] pin in
                        DispatchQueue.main.async {
                            self?.show(pin: pin, generation: runGeneration)
                        }
                    }
                ))
            } catch {
                result = .failure(error)
            }
            DispatchQueue.main.async {
                self?.finish(result, generation: runGeneration)
            }
        }
    }

    /// Publish the Bonjour record Rust computed.  Main thread.
    private func advertise(_ ready: AirliftPairing.Ready, generation runGeneration: Int) {
        guard runGeneration == generation else { return }
        serviceName = ready.serviceID
        port = Int(ready.port)
        stopAdvertising()

        let service = NetService(
            domain: MinimuxerConstants.defaultAdDomain,
            type: MinimuxerConstants.remotePairingPairableHostServiceType,
            name: ready.serviceID,
            port: Int32(ready.port)
        )
        var txt: [String: Data] = [:]
        for (key, value) in ready.txt {
            txt[key] = Data(value.utf8)
        }
        service.setTXTRecord(NetService.data(fromTXTRecord: txt))
        service.delegate = self
        service.publish()
        netService = service

        GoldenNuggetEngine.shared.log("wireless pair: published \(ready.serviceID) on port \(ready.port) "
            + "with TXT keys [\(ready.txt.keys.sorted().joined(separator: ", "))] — waiting for the device to connect")
    }

    /// Show the PIN the guest must confirm.  Main thread.
    private func show(pin receivedPin: String, generation runGeneration: Int) {
        guard runGeneration == generation else { return }
        pin = receivedPin
        GoldenNuggetEngine.shared.log("wireless pair: PIN \(receivedPin) — confirm it in Settings → Developer Mode")
    }

    /// Handle the run's terminal result.  Main thread.
    private func finish(_ result: Result<AirliftPairing.Paired, Swift.Error>, generation runGeneration: Int) {
        stopAdvertising()
        endBackgroundTask()
        guard runGeneration == generation else { return }

        switch result {
        case .success(let paired):
            if !paired.hostAltIRKHex.isEmpty {
                UserDefaults.standard.set(paired.hostAltIRKHex, forKey: Self.hostAltIRKKey)
            }
            phase = .paired
            generatedRecordPath = paired.pairingFilePath
            GoldenNuggetEngine.shared.log("wireless pair: completed — \(paired.deviceName) "
                + "(\(paired.deviceModel)) → \(paired.pairingFilePath)")
        case .failure(let error):
            phase = .failed(error.localizedDescription)
            GoldenNuggetEngine.shared.log("wireless pair failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Teardown

    /// Stop an in-flight advertisement and drop back to idle.
    ///
    /// `al_pairing_run_host` has no cancel token, so the blocked Rust thread
    /// stays parked until a device connects; this stops the advertisement (so it
    /// cannot be discovered) and bumps `generation` so any late callback or
    /// completion from that run is ignored.
    func cancel() {
        generation += 1
        stopAdvertising()
        endBackgroundTask()
        phase = .idle
        serviceName = nil
        port = nil
        pin = nil
        generatedRecordPath = nil
        GoldenNuggetEngine.shared.log("wireless pair: cancelled")
    }

    /// Forget a terminal state so the button is live again.  Called by the page
    /// after it has adopted (or rejected) a generated record.
    func reset() {
        stopAdvertising()
        endBackgroundTask()
        phase = .idle
        serviceName = nil
        port = nil
        pin = nil
        generatedRecordPath = nil
    }

    private func stopAdvertising() {
        if let service = netService {
            GoldenNuggetEngine.shared.log("wireless pair: stopped advertising \(service.name)")
            service.stop()
            netService = nil
        }
    }

    // MARK: - NetServiceDelegate

    func netServiceDidPublish(_ sender: NetService) {
        GoldenNuggetEngine.shared.log("wireless pair: Bonjour accepted \(sender.name) on port \(sender.port)")
    }

    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        GoldenNuggetEngine.shared.log("wireless pair: Bonjour refused \(sender.name) — \(errorDict)")
    }
}
