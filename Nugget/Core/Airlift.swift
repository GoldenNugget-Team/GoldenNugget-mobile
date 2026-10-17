import Foundation
import AirliftFFI

/// AirLift's AirTraffic sandbox escape, as a thin Swift face over the vendored C FFI.
///
/// ## What this is for
///
/// Everything else in this app writes preferences through a *backup*:
/// `ProtectiveBackup` → prune → inject → restore, so the device's own files are
/// what gets replaced and iOS reads them on its terms. That cannot reach inside
/// an app's container. Apple Wallet's card artwork lives in Passbook's caches
/// under the Wallet data container, and the passcode dialer's themes live in
/// `TelephonyUI`'s — there is no manifest domain for either, so there is nothing
/// to put in a backup and no way to make `mobilebackup2` carry it. AirLift is
/// the AirTraffic sandbox escape: it opens a tunnel over a pairing record and
/// writes files straight into those containers.
///
/// ## Why it is a separate connection, not a Minimuxer gateway
///
/// `AirliftFFI` takes a *pairing file path* and opens its own RSD tunnel. This
/// app already has a tunnel (minimuxer, via LocalDevVPN) for lockdown, AFC and
/// mobilebackup2. They are deliberately not unified: minimuxer holds a long-lived
/// lockdownd session that the whole app depends on, and every `al_exploit_*` call
/// blocks for as long as the operation takes. Sharing one connection would mean a
/// Wallet write can stall the backup the rest of the app is in the middle of.
/// Two tunnels, one pairing file, no shared state.
///
/// ## Availability
///
/// iOS 26.2 and newer — the same floor the rest of the app works at, from
/// GoldenNugget's `is_supported_by_fork` (`Version(version) > Version("26.1")`,
/// src/devicemanagement/constants.py:20). It used to be 27, inherited from where
/// this library was vendored from: AirCard-iOS is an iOS 27 app, so the number
/// that came with it described *that app*, not the escape. The vendored Rust
/// carries no version check of its own — nothing in `exploit.rs` or `idevice`
/// ever looks at `ProductVersion`.
///
/// The linkage is unconditional, so a device that never opens these pages pays
/// for the code and nothing else (the linker pulls only the objects whose
/// symbols are referenced, and this file references all of them).
enum Airlift {
    // MARK: - Availability

    /// The oldest iOS the escape is attempted on, as a version string.
    ///
    /// Spelled the way the UI says it: 26.2 is the first version that clears
    /// GoldenNugget's own bound.
    static let minimumVersion = "26.2"

    /// The bound as GoldenNugget states it: `is_supported_by_fork` accepts
    /// `version > Version("26.1")` (src/devicemanagement/constants.py:20), and
    /// 26.2 is what that resolves to for the versions Apple ships.
    ///
    /// Compared rather than `minimumVersion`, because the two are not the same
    /// rule: a 26.1.1 clears `> 26.1` and Apple has shipped such point
    /// releases, so comparing against 26.2 would refuse a device the rest of
    /// this app supports. `26.2 or newer` in the message stays true regardless
    /// — it is only ever shown for a device at or below 26.1.
    private static let referenceFloor = "26.1"

    /// Whether the exploit may be attempted, for a device reporting `deviceVersion`.
    ///
    /// Not a floor the library states — see the note above. What it buys is
    /// permission to try: a device below it is refused before a call that would
    /// only fail, and an unparsable or empty version is refused with it,
    /// because "unknown" must never be read as "new enough" — the same
    /// reasoning `DeviceIdentity` records for an empty version disabling the
    /// registry's bounds in the other direction.
    ///
    /// Within the supported range the attempt can still fail, and it fails
    /// loudly: the write reports why, and an injection that wrote nothing is an
    /// error rather than a quiet no-op.
    static func isSupported(deviceVersion: String) -> Bool {
        // `nil` from the comparison is an unorderable version string, which is
        // the same "unknown" case the empty one is refused as.
        guard let cmp = TweakVersion.compare(deviceVersion, referenceFloor) else { return false }
        return cmp > 0
    }

    /// The reason to refuse, for the UI.
    static func unsupportedReason(deviceVersion: String) -> String {
        isSupported(deviceVersion: deviceVersion) ? ""
            : "AirLift needs iOS \(minimumVersion) or newer — this device reports "
            + (deviceVersion.isEmpty ? "no version" : "iOS \(deviceVersion)") + "."
    }

    /// Refuse unless the device is new enough, re-reading it first.
    ///
    /// Fresh read, not the polled value, for the reason `applyTweaks` re-reads at
    /// the start of a run rather than trusting what a page was drawn with: every
    /// call here writes into a container, and the polled copy is a UI convenience
    /// that is up to thirty seconds stale. Falls back to the polled value when
    /// lockdown does not answer, so a slow-but-alive tunnel still gets through.
    private static func requireSupported() async throws {
        var version = await DeviceIdentity.read().version
        if version.isEmpty {
            version = await MainActor.run { DeviceIdentityMonitor.shared.current.version }
        }
        guard isSupported(deviceVersion: version) else {
            throw GoldenNuggetError(unsupportedReason(deviceVersion: version))
        }
    }

    // MARK: - Logging

    /// Install the library's log sink, so its lines land in the run log.
    ///
    /// `al_log_init` returns 1 when a subscriber is already installed, which is
    /// not worth surfacing: it means the library is already logging somewhere, and
    /// the only sink we have is the one just installed.
    @discardableResult
    static func install() -> Bool {
        al_log_init(logTrampoline, nil) == 0
    }

    /// Whether this process can hand `airlift_ffi` a Grappa token.
    ///
    /// `airlift_ffi` resolves `ALGetGrappaToken` with `dlsym(RTLD_DEFAULT, …)`
    /// at write time, so a build that merely *defines* the function is not
    /// enough: the linker dead-strips any symbol nothing references, and the
    /// lookup then fails at runtime with
    /// `airlift: grappa: ALGetGrappaToken symbol not found` followed by an
    /// `ATC` `SyncFailed`. Calling it here is what pins the symbol into the
    /// export table, and running it at launch means a device that cannot produce
    /// a token says so in the log before a user presses Apply.
    @discardableResult
    static func installGrappaTokenProvider() -> Int32 {
        let status = GrappaToken.status()
        AppLog.write(status == 0
                     ? "airlift: Grappa token provider ready (\(GrappaToken.previewLength()) bytes)"
                     : "airlift: Grappa token provider unavailable (code \(status))")
        return status
    }

    /// The per-call sink, passed as `log_cb` with a `nil` context.
    ///
    /// The `ctx` slot exists in the FFI for callers that need to carry state into
    /// a C function pointer, which cannot capture. Nothing here does — the sink
    /// appends to `AppLog`'s singleton — so `nil` is passed rather than a
    /// fabricated global whose only purpose would be to be ignored.
    private static let logTrampoline: ALLogCallback = { _, msg in
        guard let msg else { return }
        AppLog.write(String(cString: msg))
    }

    /// Copy a heap string the FFI handed back, free it, and return the copy.
    ///
    /// Both `out_json` and `out_error` are malloc'd by the library and owned by
    /// the caller. The `String` is made *before* the free — reading freed memory
    /// is the bug this helper exists to make impossible to write twice.
    private static func take(_ pointer: UnsafeMutablePointer<CChar>?) -> String? {
        guard let pointer else { return nil }
        defer { al_string_free(pointer) }
        return String(cString: pointer)
    }

    // MARK: - Exploit

    /// Write every file in `sourceDir` into `targetDir` on the device.
    static func writeDir(pairingPath: String,
                         sourceDir: String,
                         targetDir: String) async throws {
        try await requireSupported()
        try await offMainActor {
            var outError: UnsafeMutablePointer<CChar>?
            let rc = al_exploit_write_dir(pairingPath, sourceDir, targetDir,
                                          logTrampoline, nil, &outError)
            guard rc == 0 else {
                throw GoldenNuggetError(take(outError) ?? "AirLift directory write returned \(rc).")
            }
        }
    }

    /// Copy a whole local directory into `targetParentDir/destName`, keeping the
    /// internal tree — one AirTraffic operation rather than a file walk.
    static func injectFolder(pairingPath: String,
                             folderPath: String,
                             targetParentDir: String,
                             destName: String) async throws {
        try await requireSupported()
        try await offMainActor {
            var outError: UnsafeMutablePointer<CChar>?
            let rc = al_exploit_inject_folder(pairingPath, folderPath, targetParentDir, destName,
                                              logTrampoline, nil, &outError)
            guard rc == 0 else {
                throw GoldenNuggetError(take(outError) ?? "AirLift folder injection returned \(rc).")
            }
        }
    }

    /// Resolve an app's Data Application Container by bundle id.
    ///
    /// This is the lookup Wallet and PosterBoard both need, and the reason it is
    /// not hardcoded anywhere: the UUID changes on every reinstall and on some
    /// OS updates, so a stored path is a path to nothing.
    static func appContainer(pairingPath: String, bundleID: String) async throws -> String {
        try await requireSupported()
        return try await offMainActor {
            var outContainer: UnsafeMutablePointer<CChar>?
            var outError: UnsafeMutablePointer<CChar>?
            let rc = al_find_app_container(pairingPath, bundleID, logTrampoline, nil,
                                           &outContainer, &outError)
            let container = take(outContainer)
            let message = take(outError)
            guard rc == 0, let container else {
                throw GoldenNuggetError(message ?? "No container for \(bundleID) (code \(rc)).")
            }
            return container
        }
    }

    /// Respring, so an injected descriptor is live without a reboot.
    ///
    /// NeoSpring — a full-screen `WKWebView` running upstream's compositor
    /// payload, attached to our own key window, which restarts the userspace
    /// under us. See `NeoSpring` for why that is here instead of a command over
    /// the tunnel.
    ///
    /// No pairing record and no tunnel: by the time this is called the writes
    /// are already in the container, and the restart is entirely on this side.
    /// That is also why it works on any supported device rather than only
    /// through AirLift's connection.
    static func respring() async throws {
        let attached = await MainActor.run { NeoSpring.trigger() }
        guard attached else {
            throw GoldenNuggetError("There is no window to respring from. Leave the app in the "
                + "foreground and run it again.")
        }
        // Give WebKit the moment it needs to load the payload. Returning
        // earlier would let the run report a respring that had not started yet.
        try? await Task.sleep(for: .milliseconds(800))
    }

    /// Reboot the device, over Diagnostics Relay.
    ///
    /// Not what a wallpaper change needs — `respring` is, and is much quicker.
    /// Kept because a failed injection can leave the store in a state only a full
    /// restart clears, and the user is the one who has to agree to that.
    ///
    /// This is Diagnostics Relay's `Restart`, and it reboots the *device*: the
    /// name is a trap when reading the FFI next to the respring beside it.
    static func reboot(pairingPath: String) async throws {
        try await requireSupported()
        try await offMainActor {
            var outError: UnsafeMutablePointer<CChar>?
            let rc = al_device_respring(pairingPath, logTrampoline, nil, &outError)
            guard rc == 0 else {
                throw GoldenNuggetError(take(outError) ?? "Reboot returned \(rc).")
            }
        }
    }

    // MARK: - Syslog

    /// Stream device syslog over the tunnel, and return the stop function.
    ///
    /// This is how an Apple Pay card is *identified*: bringing up Wallet makes
    /// Passbook log the card's identifier, and there is no other way to learn
    /// which card is in the reader. The FFI's own `al_syslog_stream_start` blocks
    /// until stopped, so it lives on its own thread and this returns immediately
    /// with the handle that stops it.
    static func streamSyslog(pairingPath: String,
                             onLine: @escaping (String) -> Void) async throws -> () -> Void {
        try await requireSupported()
        let token = UInt.random(in: UInt.min...UInt.max)
        // Registered before the thread starts, so the first line cannot arrive
        // before there is somewhere to put it.
        SyslogRegistry.shared.put(token, onLine)

        DispatchQueue.global(qos: .utility).async {
            var outError: UnsafeMutablePointer<CChar>?
            let rc = al_syslog_stream_start(pairingPath, { ctx, line in
                guard let ctx, let line else { return }
                SyslogRegistry.shared.handler(UInt(bitPattern: ctx))?(String(cString: line))
            }, UnsafeMutableRawPointer(bitPattern: token), &outError)
            if let message = take(outError) {
                AppLog.write("AirLift syslog stream ended (code \(rc)): \(message)")
            }
            SyslogRegistry.shared.remove(token)
        }

        return {
            SyslogRegistry.shared.remove(token)
            al_syslog_stream_stop()
        }
    }

    /// Handlers for `streamSyslog`, keyed by the token their callback carries.
    ///
    /// A lock rather than a `@MainActor` dictionary: the callback arrives on
    /// whatever thread the library's reader is on, while the registry is touched
    /// by the UI when a stream starts and stops.
    private final class SyslogRegistry: @unchecked Sendable {
        static let shared = SyslogRegistry()
        private let lock = NSLock()
        private var handlers: [UInt: (String) -> Void] = [:]

        func put(_ token: UInt, _ handler: @escaping (String) -> Void) {
            lock.lock(); defer { lock.unlock() }
            handlers[token] = handler
        }
        func remove(_ token: UInt) {
            lock.lock(); defer { lock.unlock() }
            handlers[token] = nil
        }
        func handler(_ token: UInt) -> ((String) -> Void)? {
            lock.lock(); defer { lock.unlock() }
            return handlers[token]
        }
    }

    // MARK: - Local archives

    /// Unpack a `.passthm` card-art archive locally — no device involved.
    ///
    /// A `.passthm` is what Passbook itself calls a card theme: a zip of scaled
    /// artwork for one card. Unpacking it on this side rather than on the device
    /// is what lets the Wallet page preview a card before anything is written.
    @discardableResult
    static func extractPassthm(archivePath: String, destDir: String) async throws -> String {
        try await offMainActor {
            let rc = al_passthm_extract(archivePath, destDir)
            guard rc == 0 else { throw GoldenNuggetError("Could not unpack \(archivePath) (code \(rc)).") }
        }
        return destDir
    }

    /// Unpack a zip locally. Thin wrapper, kept so callers do not have to know
    /// which extractor a given extension maps to.
    @discardableResult
    static func extractZip(archivePath: String, destDir: String) async throws -> String {
        try await offMainActor {
            let rc = al_zip_extract_all(archivePath, destDir)
            guard rc == 0 else { throw GoldenNuggetError("Could not unpack \(archivePath) (code \(rc)).") }
        }
        return destDir
    }

    // MARK: - Plumbing

    /// Run a blocking FFI call off the main actor and rethrow what it threw.
    ///
    /// Every `al_*` call blocks on its own RSD tunnel — a handshake, a write, a
    /// response — so none of them may run on the main thread. One helper rather
    /// than a `DispatchQueue.async` plus a continuation per call, because the
    /// continuation is what made each of them look different when they are the
    /// same shape.
    private static func offMainActor<T>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                do { cont.resume(returning: try body()) }
                catch { cont.resume(throwing: error) }
            }
        }
    }
}
