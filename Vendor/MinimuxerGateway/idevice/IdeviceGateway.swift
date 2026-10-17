//
//  IdeviceGateway.swift
//  SideStore
//
//  Created by Magesh K on 05/07/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import Foundation
import IDevice
import DeviceGatewayAPI
internal import MinimuxerCommon

internal final class IdeviceGatewayError: DeviceGatewayError, @unchecked Sendable {
    override var errorDescription: String? {
        switch code {
        case .connectionFailed:
            return "Failed to connect to device: \(reason)"
        default:
            return super.errorDescription
        }
    }
}



extension String {
    // Un-escapes literal "\\n" and "\\\"" escape sequences into real line breaks and quotes.
    var cleanedErrorFormatting: String {
        return self
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\\"", with: "\"")
    }
}

public final class IdeviceGateway: BaseDeviceGateway, DeviceGatewayAPI {
    public static let shared = IdeviceGateway()
    var lastError: Error? = nil

    /// Serializes the body of `ensureRPConnection()`.
    ///
    /// The `adapter`/`handshake` check-then-act is not atomic and every service
    /// path funnels through here from `DispatchQueue.global()`, so two concurrent
    /// callers (e.g. the post-start readiness poll and the first user-triggered
    /// operation) both observe `nil` and both run `tunnel_create_rppairing`.
    /// The device then holds two RemotePairing sessions — visible in
    /// minimuxer.log as two `Sending attemptPairVerify`, two `createListener`
    /// responses and two CDTunnel handshakes ~60 ms apart, with the second
    /// session serving the service while the first leaks until the app exits.
    private let tunnelLock = NSLock()

    private func getRustPlistString(_ node: plist_t) -> String? {
        var valPtr: UnsafeMutablePointer<Int8>? = nil
        plist_get_string_val(node, &valPtr)
        if let ptr = valPtr {
            let val = String(cString: ptr)
            free(ptr)
            return val
        }
        return nil
    }

    private func getErrorMessage(from err: UnsafeMutablePointer<IdeviceFfiError>) -> String {
        if let msgPtr = err.pointee.message {
            return String(cString: msgPtr).cleanedErrorFormatting
        }
        return "Error code \(err.pointee.code)"
    }

    private func safeFreeError(_ err: UnsafeMutablePointer<IdeviceFfiError>?) {
        guard let err = err else { return }
        let addr = Int(bitPattern: err)
        if addr > 0xff {
            idevice_error_free(err)
        }
    }

    private func safeFreePlist(_ plist: plist_t?) {
        guard let plist = plist else { return }
        let addr = Int(bitPattern: plist)
        if addr > 0xff {
            plist_free(plist)
        }
    }

    /// The progress a restore has to reach before it counts as finished.
    ///
    /// A calibration, not a law: the device reports 0→100 over the job it plans,
    /// so anything short of 100 means the device decided it was done early.  If
    /// a genuine run is ever seen completing below 100, this is the one place to
    /// change — and the thrown message already prints the value it observed.
    static let restoreCompletionPercent: Double = 100

    /// Last progress value the device reported during a restore.
    ///
    /// `MobileBackup2BackupContext` forwards progress to the caller but keeps no
    /// copy of its own, so the completion check needs one.
    final class RestoreProgressProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var last: Double = -1

        func note(_ percent: Double) {
            lock.lock()
            last = percent
            lock.unlock()
        }

        /// -1 when the device never reported anything.
        var lastPercent: Double {
            lock.lock()
            defer { lock.unlock() }
            return last
        }
    }

    private var pairingFile: OpaquePointer? = nil
    private var adapter: OpaquePointer? = nil
    private var handshake: OpaquePointer? = nil

    private override init() {
        try! super.init()
    }

    deinit {
        cleanup()
    }

    private func cleanup() {
        debugLog("[IdeviceGateway] cleanup() called")
        setInitialized(false)
        setPairingFileData(nil)
        
        if let pairingFile = self.pairingFile {
            verboseLog("[IdeviceGateway] cleanup() freeing pairingFile")
            if pairingFileType == .rppairing {
                rp_pairing_file_free(pairingFile)
            } else {
                idevice_pairing_file_free(pairingFile)
            }
            self.pairingFile = nil
        }

        setPairingFileType(.unknown)
        lastError = nil
        if let handshake = handshake {
            verboseLog("[IdeviceGateway] cleanup() freeing handshake")
            rsd_handshake_free(handshake)
            self.handshake = nil
        }
        if let adapter = adapter {
            verboseLog("[IdeviceGateway] cleanup() freeing adapter")
            adapter_free(adapter)
            self.adapter = nil
        }
    }

    private func verifyInitialized() throws {
        guard isInitialized else {
            debugLog("[IdeviceGateway] verifyInitialized() failed: Gateway has not been initialized.")
            throw IdeviceGatewayError(.notInitialized)
        }
    }

    public override func invalidateConnection() {
        debugLog("[IdeviceGateway] invalidateConnection() called - clearing stale adapter and handshake")
        if let handshake = handshake {
            rsd_handshake_free(handshake)
            self.handshake = nil
        }
        if let adapter = adapter {
            adapter_free(adapter)
            self.adapter = nil
        }
    }

    public override func setLogging(_ enabled: Bool) {
        super.setLogging(enabled)
        idevice_init_logger(enabled ? IdeviceLogLevel(rawValue: 1) : IdeviceLogLevel(rawValue: 0), IdeviceLogLevel(rawValue: 0), nil)
        #if DEBUG
        // just comment/uncomment to override above set logging level during local debugging
//        idevice_init_logger(IdeviceLogLevel(rawValue: 4), IdeviceLogLevel(rawValue: 0), nil)
        #endif
    }

    /// Install a Rust-side log sink that writes to `path` at DEBUG level.
    ///
    /// `idevice_init_logger` is guarded by a Rust `Once`: the FIRST call in the
    /// process wins and every later call returns `AlreadyInitialized` (-2).
    /// `setLogging(true)` — which `syncStart()` runs in DEBUG builds — installs
    /// console=Error / file=OFF, so `<Documents>/minimuxer.log` is never
    /// created and a failed mobilebackup2 operation leaves NO Rust trace at all.
    /// Call this **before** `start()`/`setLogging()` to capture the whole device
    /// conversation on disk.
    ///
    /// - Returns: raw `IdeviceLoggerError` (0 OK, -1 file error, -2 already
    ///   initialized, -3 invalid path). Anything but 0 means the file sink is
    ///   not active.
    @discardableResult
    public func enableRustFileLogging(to path: String) -> Int32 {
        // Rust only borrows the C string for the duration of the call
        // (`CStr::from_ptr`, never `from_raw`), so a leaked strdup is the
        // simplest way to guarantee a valid lifetime for a once-per-process
        // init without touching Rust-owned memory.
        let cPath = strdup(path)
        // console: Error, file: Debug.
        //
        // The file level is what carries the evidence (the DeviceLink
        // conversation and jktcp's flow verdict are both DEBUG), so it stays.
        // The console level used to be Debug as well, which meant every line was
        // written twice — and jktcp logs one line per out-of-order segment from
        // the thread that has to drain the socket.  Measured on 2026-09-19: a
        // 2.46 MB burst produced 2402 lines in 45.6 ms, i.e. ~53k writes/s, while
        // the same thread also had to drain a 54 MB/s burst.  Dropping the
        // console sink removes none of the evidence and halves that write work.
        // (On iOS the console sink goes nowhere anyway — `setLogging()` would
        // have installed console=Error itself if the logger had not already been
        // latched by this call.)
        let result = idevice_init_logger(
            IdeviceLogLevel(rawValue: 1),   // console: Error (was Debug — see above)
            IdeviceLogLevel(rawValue: 4),   // file:    Debug
            cPath
        )
        return Int32(result.rawValue)
    }

    private func syncStart(pairingFileContent: String) throws {
        debugLog("[IdeviceGateway] start() called, pairingFileContent length: \(pairingFileContent.count)")
        cleanup()
        
        #if DEBUG
        setLogging(true)
        #endif

        let parsedPairingFile: any PairingFile
        do {
            parsedPairingFile = try PairingFileParser.parse(content: pairingFileContent)
            setPairingFileData(parsedPairingFile.rawData)
            setPairingFileType(parsedPairingFile.mode)
        } catch {
            debugLog("[IdeviceGateway] start() failed: \(error.localizedDescription)")
            throw error
        }

        let data = parsedPairingFile.rawData

        if pairingFileType == .rppairing {
            try data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
                if let baseAddress = buf.baseAddress?.assumingMemoryBound(to: UInt8.self) {
                    verboseLog("[IdeviceGateway] start() calling rp_pairing_file_from_bytes")
                    let err = rp_pairing_file_from_bytes(baseAddress, UInt(data.count), &pairingFile)
                    if err != nil {
                        debugLog("[IdeviceGateway] start() rp_pairing_file_from_bytes failed")
                        throw IdeviceGatewayError(.invalidPairingFile, reason: "rp_pairing_file_from_bytes failed")
                    }
                }
            }
        } else {
            // Traditional usbmuxd / lockdown connection path
            // For pre-iOS 17 devices, a default connection can be established without RPPairing tunnel
            verboseLog("[IdeviceGateway] start() mode = .lockdown")

            // Parse pairing file content XML plist to self.pairingFile IdevicePairingFile*
            try data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
                if let baseAddress = buf.baseAddress?.assumingMemoryBound(to: UInt8.self) {
                    verboseLog("[IdeviceGateway] start() loading lockdown pairing file bytes")
                    let err = idevice_pairing_file_from_bytes(baseAddress, UInt(data.count), &pairingFile)
                    if err != nil {
                        debugLog("[IdeviceGateway] start() idevice_pairing_file_from_bytes failed")
                        throw IdeviceGatewayError(.invalidPairingFile, reason: "idevice_pairing_file_from_bytes failed")
                    }
                    verboseLog("[IdeviceGateway] start() loaded lockdown pairingFile successfully")
                }
            }
        }
        isInitialized = true
    }

    private func withSockaddr<R>(ip: String, port: UInt16, _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> R) throws -> R {
        if ip.contains(":") {
            var addr6 = sockaddr_in6()
            addr6.sin6_len = __uint8_t(MemoryLayout<sockaddr_in6>.size)
            addr6.sin6_family = sa_family_t(AF_INET6)
            addr6.sin6_port = port.bigEndian
            
            var cleanIp = ip
            if let scopeRange = cleanIp.range(of: "%") {
                let ifaceName = String(cleanIp[scopeRange.upperBound...])
                cleanIp = String(cleanIp[..<scopeRange.lowerBound])
                addr6.sin6_scope_id = if_nametoindex(ifaceName)
            } else if cleanIp.lowercased().hasPrefix("fe80:") {
                let en0Idx = if_nametoindex("en0")
                if en0Idx != 0 {
                    addr6.sin6_scope_id = en0Idx
                } else {
                    let awdl0Idx = if_nametoindex("awdl0")
                    addr6.sin6_scope_id = awdl0Idx != 0 ? awdl0Idx : if_nametoindex("lo0")
                }
            }
            
            guard inet_pton(AF_INET6, cleanIp, &addr6.sin6_addr) == 1 else {
                throw IdeviceGatewayError(.invalidTargetEndpoint, reason: "Invalid IPv6 address: \(ip)")
            }
            
            return try withUnsafePointer(to: &addr6) { ptr in
                try ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    try body(sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
        } else {
            var addr = sockaddr_in()
            addr.sin_len = __uint8_t(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            
            guard inet_pton(AF_INET, ip, &addr.sin_addr) == 1 else {
                throw IdeviceGatewayError(.invalidTargetEndpoint, reason: "Invalid IPv4 address: \(ip)")
            }
            
            return try withUnsafePointer(to: &addr) { ptr in
                try ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    try body(sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    private func ensureRPConnection() throws {
        // One tunnel at a time: without this, concurrent callers each build their
        // own (see `tunnelLock`).  Held across the FFI call on purpose — the call
        // is blocking anyway, so the wait is the same wait.
        tunnelLock.lock()
        defer { tunnelLock.unlock() }

        debugLog("[IdeviceGateway] ensureRPConnection() started, adapter: \(String(describing: adapter)), handshake: \(String(describing: handshake))")
        if adapter != nil && handshake != nil {
            verboseLog("[IdeviceGateway] ensureRPConnection() using existing connection")
            return
        }

        // We only get here with a half-established pair (one handle set, the
        // other nil), which no caller can use.  Release it before the FFI call
        // overwrites the properties, or the pointer leaks.
        if adapter != nil || handshake != nil {
            verboseLog("[IdeviceGateway] ensureRPConnection() releasing half-established adapter/handshake first")
            invalidateConnection()
        }

        guard let pairingFile = pairingFile else {
            debugLog("[IdeviceGateway] ensureRPConnection() failed because pairingFile is nil")
            throw IdeviceGatewayError(.invalidPairingFile, reason: "pairingFile is nil")
        }

        guard let deviceEndpointIp = deviceEndpointIp else {
            debugLog("[IdeviceGateway] ensureRPConnection() failed because deviceEndpointIp is nil")
            throw IdeviceGatewayError(.deviceEndpointIpNotAvailable)
        }

        let hostname = MinimuxerConstants.appName
        var err: UnsafeMutablePointer<IdeviceFfiError>? = nil

        let rpPort = getPort(for: .rppairing)
        verboseLog("[IdeviceGateway] ensureRPConnection() calling tunnel_create_rppairing with deviceEndpointIp: \(deviceEndpointIp):\(rpPort)")
        try hostname.withCString { hostPtr in
            try withSockaddr(ip: deviceEndpointIp, port: rpPort) { sockaddrPtr, sockaddrLen in
                err = tunnel_create_rppairing(
                    sockaddrPtr,
                    sockaddrLen,
                    hostPtr,
                    pairingFile,
                    nil,
                    nil,
                    &adapter,
                    &handshake
                )
            }
        }

        if let err = err {
            let ffiErr = err.pointee
            let code = ffiErr.code
            let subCode = ffiErr.sub_code
            var msg = ""
            if let msgPtr = ffiErr.message {
                msg = String(cString: msgPtr)
            }
            debugLog("[IdeviceGateway] ensureRPConnection() tunnel_create_rppairing failed with code: \(code), subCode: \(subCode), message: \(msg)")
            defer { idevice_error_free(err) }
            
            if isPairingError(err) {
                let reason = "Handshake failed: \(msg.isEmpty ? "Unknown FFI error" : msg)"
                let error = IdeviceGatewayError(.invalidPairingFile, reason: reason)
                lastError = error
                throw error
            } else {
                let error = IdeviceGatewayError(.connectionFailed, reason: msg.isEmpty ? "Tunnel creation failed" : msg)
                lastError = error
                throw error
            }
        }
        debugLog("[IdeviceGateway] ensureRPConnection() tunnel_create_rppairing succeeded, adapter: \(String(describing: adapter)), handshake: \(String(describing: handshake))")
    }

    private func isPairingError(_ err: UnsafeMutablePointer<IdeviceFfiError>) -> Bool {
        let code = err.pointee.code
        // 103: RemotePairing, 18: InvalidHostID, 30: PairingDialogResponsePending, 31: UserDeniedPairing, 32: PasswordProtected
        if code == 103 || code == 18 || code == 30 || code == 31 || code == 32 {
            return true
        }
        
        if let msgPtr = err.pointee.message {
            let msg = String(cString: msgPtr).lowercased()
            if msg.contains("invalidconf") || msg.contains("pairing") || msg.contains("handshake") ||
                msg.contains("connection reset") || msg.contains("connectionreset") {
                return true
            }
        }
        return false
    }

    private func performWithService<T>(
        connect: @escaping (OpaquePointer?, OpaquePointer?, UnsafeMutablePointer<OpaquePointer?>?) -> UnsafeMutablePointer<IdeviceFfiError>?,
        cleanup: @escaping (OpaquePointer?) -> Void,
        serviceName: String,
        action: (OpaquePointer) throws -> T
    ) throws -> T {
        debugLog("[IdeviceGateway] performWithService(\(serviceName)) started")
        try ensureRPConnection()
        var client: OpaquePointer? = nil
        var err = connect(adapter, handshake, &client)
        if let firstErr = err {
            let ffiErr = firstErr.pointee
            let code = ffiErr.code
            let subCode = ffiErr.sub_code
            var msg = ""
            if let msgPtr = ffiErr.message {
                msg = String(cString: msgPtr)
            }
            debugLog("[IdeviceGateway] performWithService(\(serviceName)) connect failed with code: \(code), subCode: \(subCode), message: \(msg)")
            idevice_error_free(firstErr)
            
            invalidateConnection()
            
            // Retry once with a fresh connection tunnel
            debugLog("[IdeviceGateway] performWithService(\(serviceName)) retrying with fresh connection...")
            do {
                try ensureRPConnection()
                err = connect(adapter, handshake, &client)
            } catch {
                let reason = "Service connection retry failed: \(error.localizedDescription)"
                let errObj = IdeviceGatewayError(.serviceError, reason: reason)
                lastError = errObj
                throw errObj
            }
            
            if let secondErr = err {
                let ffiErr = secondErr.pointee
                let code = ffiErr.code
                let subCode = ffiErr.sub_code
                var retryMsg = ""
                if let msgPtr = ffiErr.message {
                    retryMsg = String(cString: msgPtr)
                }
                debugLog("[IdeviceGateway] performWithService(\(serviceName)) retry connect failed with code: \(code), subCode: \(subCode), message: \(retryMsg)")
                defer { idevice_error_free(secondErr) }
                invalidateConnection()
                
                if isPairingError(secondErr) {
                    let reason = "Service connection failed, error: (\(retryMsg.isEmpty ? "Unknown FFI error" : retryMsg))"
                    let error = IdeviceGatewayError(.invalidPairingFile, reason: reason)
                    lastError = error
                    throw error
                } else {
                    let error = IdeviceGatewayError(.serviceError, reason: "Failed to connect to \(serviceName), error: (\(retryMsg.isEmpty ? "Unknown FFI error" : retryMsg))")
                    lastError = error
                    throw error
                }
            }
        }
        guard let client = client else {
            debugLog("[IdeviceGateway] performWithService(\(serviceName)) client is nil")
            throw IdeviceGatewayError(.serviceError, reason: "Connected client for \(serviceName) was nil")
        }
        defer {
            verboseLog("[IdeviceGateway] performWithService(\(serviceName)) performing cleanup")
            cleanup(client)
        }
        verboseLog("[IdeviceGateway] performWithService(\(serviceName)) executing action")
        return try action(client)
    }

    private func performWithUsbmuxdService<T>(
        connect: @escaping (OpaquePointer?, UnsafeMutablePointer<OpaquePointer?>?) -> UnsafeMutablePointer<IdeviceFfiError>?,
        cleanup: @escaping (OpaquePointer?) -> Void,
        serviceName: String,
        action: (OpaquePointer) throws -> T
    ) throws -> T {
        verboseLog("[IdeviceGateway] performWithUsbmuxdService(\(serviceName)) started")
        
        var addr: OpaquePointer? = nil
        var err: UnsafeMutablePointer<IdeviceFfiError>? = nil

        if let envVal = getenv("USBMUXD_SOCKET_ADDRESS") {
            let envAddr = String(cString: envVal)
            verboseLog("[IdeviceGateway] performWithUsbmuxdService(\(serviceName)) using USBMUXD_SOCKET_ADDRESS: \(envAddr)")
            if envAddr.contains(":") {
                let parts = envAddr.split(separator: ":")
                if parts.count == 2, let portVal = UInt16(parts[1]) {
                    let host = String(parts[0])
                    var sockAddr = sockaddr_in()
                    sockAddr.sin_family = sa_family_t(AF_INET)
                    sockAddr.sin_port = portVal.bigEndian
                    sockAddr.sin_addr.s_addr = host.withCString { inet_addr($0) }
                    #if os(macOS) || os(iOS)
                    sockAddr.sin_len = __uint8_t(MemoryLayout<sockaddr_in>.size)
                    #endif
                    
                    err = withUnsafePointer(to: &sockAddr) { ptr in
                        ptr.withMemoryRebound(to: idevice_sockaddr.self, capacity: 1) { reboundPtr in
                            return idevice_usbmuxd_tcp_addr_new(reboundPtr, socklen_t(MemoryLayout<sockaddr_in>.size), &addr)
                        }
                    }
                } else {
                    debugLog("[IdeviceGateway] performWithUsbmuxdService(\(serviceName)) invalid USBMUXD_SOCKET_ADDRESS format: \(envAddr)")
                }
            } else {
                #if os(macOS) || os(iOS)
                err = envAddr.withCString { pathPtr in
                    return idevice_usbmuxd_unix_addr_new(pathPtr, &addr)
                }
                #else
                debugLog("[IdeviceGateway] performWithUsbmuxdService(\(serviceName)) Unix socket not supported on this platform")
                #endif
            }
        }

        if addr == nil {
            err = idevice_usbmuxd_default_addr_new(&addr)
        }

        if let err = err {
            let msg = self.getErrorMessage(from: err)
            debugLog("[IdeviceGateway] performWithUsbmuxdService(\(serviceName)) addr creation failed: code=\(err.pointee.code), message=\(msg)")
            defer { idevice_error_free(err) }
            throw IdeviceGatewayError(.connectionFailed, reason: "Failed to get usbmuxd addr: \(msg)")
        }
        guard let addr = addr else {
            debugLog("[IdeviceGateway] performWithUsbmuxdService(\(serviceName)) usbmuxd addr is nil")
            throw IdeviceGatewayError(.connectionFailed, reason: "Usbmuxd addr was nil")
        }
        
        var provider: OpaquePointer? = nil
        var provErr: UnsafeMutablePointer<IdeviceFfiError>? = nil
        
        var conn: OpaquePointer? = nil
        let connErr = idevice_usbmuxd_new_default_connection(0, &conn)
        if let connErr = connErr {
            let msg = self.getErrorMessage(from: connErr)
            debugLog("[IdeviceGateway] performWithUsbmuxdService(\(serviceName)) new_default_connection failed: code=\(connErr.pointee.code), message=\(msg)")
            defer { idevice_error_free(connErr) }
            idevice_usbmuxd_addr_free(addr)
            throw IdeviceGatewayError(.connectionFailed, reason: "Failed to connect to usbmuxd: \(msg)")
        }
        
        if let conn = conn {
            defer { idevice_usbmuxd_connection_free(conn) }
            var devices: UnsafeMutablePointer<OpaquePointer?>? = nil
            var count: Int32 = 0
            let devErr = idevice_usbmuxd_get_devices(conn, &devices, &count)
            if let devErr = devErr {
                let msg = self.getErrorMessage(from: devErr)
                debugLog("[IdeviceGateway] performWithUsbmuxdService(\(serviceName)) get_devices failed: code=\(devErr.pointee.code), message=\(msg)")
                defer { idevice_error_free(devErr) }
                idevice_usbmuxd_addr_free(addr)
                throw IdeviceGatewayError(.connectionFailed, reason: "Failed to list usbmuxd devices: \(msg)")
            }
            verboseLog("[IdeviceGateway] performWithUsbmuxdService(\(serviceName)) found \(count) devices")
            if count > 0, let devicesPtr = devices, let firstDev = devicesPtr.pointee {
                defer { idevice_usbmuxd_device_list_free(devices, count) }
                let udidPtr = idevice_usbmuxd_device_get_udid(firstDev)
                let deviceID = idevice_usbmuxd_device_get_device_id(firstDev)
                verboseLog("[IdeviceGateway] performWithUsbmuxdService(\(serviceName)) creating provider for deviceID: \(deviceID)")
                provErr = usbmuxd_provider_new(addr, 0, udidPtr, deviceID, MinimuxerConstants.appName, &provider)
                if let udidPtr = udidPtr {
                    idevice_string_free(udidPtr)
                }
            } else {
                verboseLog("[IdeviceGateway] performWithUsbmuxdService(\(serviceName)) no devices found on usbmuxd")
                idevice_usbmuxd_addr_free(addr)
                throw IdeviceGatewayError(.connectionFailed, reason: "No devices found on usbmuxd")
            }
        } else {
            debugLog("[IdeviceGateway] performWithUsbmuxdService(\(serviceName)) usbmuxd connection was nil")
            idevice_usbmuxd_addr_free(addr)
            throw IdeviceGatewayError(.connectionFailed, reason: "Usbmuxd connection was nil")
        }
        
        if let provErr = provErr {
            let msg = self.getErrorMessage(from: provErr)
            debugLog("[IdeviceGateway] performWithUsbmuxdService(\(serviceName)) provider creation failed: code=\(provErr.pointee.code), message=\(msg)")
            defer { idevice_error_free(provErr) }
            throw IdeviceGatewayError(.connectionFailed, reason: "Failed to create usbmuxd provider: \(msg)")
        }
        guard let provider = provider else {
            debugLog("[IdeviceGateway] performWithUsbmuxdService(\(serviceName)) provider is nil")
            throw IdeviceGatewayError(.connectionFailed, reason: "Usbmuxd provider was nil")
        }
        var providerToFree: OpaquePointer? = provider
        defer {
            if let ptr = providerToFree {
                idevice_provider_free(ptr)
            }
        }

        var client: OpaquePointer? = nil
        let connectErr = connect(provider, &client)
        if let connectErr = connectErr {
            providerToFree = nil
            let msg = self.getErrorMessage(from: connectErr)
            debugLog("[IdeviceGateway] performWithUsbmuxdService(\(serviceName)) connect failed: code=\(connectErr.pointee.code), message=\(msg)")
            defer { idevice_error_free(connectErr) }
            throw IdeviceGatewayError(.serviceError, reason: "Failed to connect to \(serviceName), error: (\(msg))")
        }
        guard let client = client else {
            debugLog("[IdeviceGateway] performWithUsbmuxdService(\(serviceName)) client is nil")
            throw IdeviceGatewayError(.serviceError, reason: "Connected client for \(serviceName) was nil")
        }
        defer {
            verboseLog("[IdeviceGateway] performWithUsbmuxdService(\(serviceName)) performing cleanup")
            cleanup(client)
        }
        verboseLog("[IdeviceGateway] performWithUsbmuxdService(\(serviceName)) executing action")
        return try action(client)
    }

    private func performWithTcpService<T>(
        connect: @escaping (OpaquePointer?, UnsafeMutablePointer<OpaquePointer?>?) -> UnsafeMutablePointer<IdeviceFfiError>?,
        cleanup: @escaping (OpaquePointer?) -> Void,
        serviceName: String,
        action: (OpaquePointer) throws -> T
    ) throws -> T {
        verboseLog("[IdeviceGateway] performWithTcpService(\(serviceName)) started")
        
        guard let deviceEndpointIp = deviceEndpointIp else {
            debugLog("[IdeviceGateway] performWithTcpService(\(serviceName)) failed because deviceEndpointIp is nil")
            throw IdeviceGatewayError(.deviceEndpointIpNotAvailable)
        }
        


        guard let pairingFileData = self.pairingFileData else {
            debugLog("[IdeviceGateway] error: pairingFileData is nil")
            throw IdeviceGatewayError(.connectionFailed, reason: "pairingFileData is nil")
        }

        var tempPairingFile: OpaquePointer? = nil
        let parseErr = pairingFileData.withUnsafeBytes { buf in
            return idevice_pairing_file_from_bytes(buf.baseAddress?.assumingMemoryBound(to: UInt8.self), UInt(pairingFileData.count), &tempPairingFile)
        }
        if let parseErr = parseErr {
            let msg = self.getErrorMessage(from: parseErr)
            debugLog("[IdeviceGateway] error: Failed to parse temporary pairing file: \(msg)")
            defer { safeFreeError(parseErr) }
            throw IdeviceGatewayError(.connectionFailed, reason: "Failed to parse temporary pairing file: \(msg)")
        }
        guard let tempPairingFile = tempPairingFile else {
            throw IdeviceGatewayError(.connectionFailed, reason: "Temporary pairing file was nil")
        }

        var provider: OpaquePointer? = nil
        let provErr = try withSockaddr(ip: deviceEndpointIp, port: MinimuxerConstants.lockdowndPort) { sockaddrPtr, _ in
            sockaddrPtr.withMemoryRebound(to: idevice_sockaddr.self, capacity: 1) { reboundPtr in
                return idevice_tcp_provider_new(reboundPtr, tempPairingFile, MinimuxerConstants.appName, &provider)
            }
        }
        if let provErr = provErr {
            let msg = self.getErrorMessage(from: provErr)
            debugLog("[IdeviceGateway] error: Failed to create TCP provider: \(msg)")
            defer { safeFreeError(provErr) }
            throw IdeviceGatewayError(.connectionFailed, reason: "Failed to create TCP provider: \(msg)")
        }
        guard let provider = provider else {
            debugLog("[IdeviceGateway] error: TCP Provider was nil")
            throw IdeviceGatewayError(.connectionFailed, reason: "TCP Provider was nil")
        }
        var providerToFree: OpaquePointer? = provider
        defer {
            if let ptr = providerToFree {
                idevice_provider_free(ptr)
            }
        }

        var client: OpaquePointer? = nil
        let connectErr = connect(provider, &client)
        if let connectErr = connectErr {
            providerToFree = nil
            let msg = self.getErrorMessage(from: connectErr)
            debugLog("[IdeviceGateway] error: \(serviceName) connect failed: code=\(connectErr.pointee.code), message=\(msg)")
            defer { safeFreeError(connectErr) }
            throw IdeviceGatewayError(.serviceError, reason: "Failed to connect to \(serviceName), error: (\(msg))")
        }
        guard let client = client else {
            throw IdeviceGatewayError(.noConnection)
        }
        defer { cleanup(client) }

        return try action(client)
    }

    private func performWithEitherService<T>(
        connectRP: @escaping (OpaquePointer?, OpaquePointer?, UnsafeMutablePointer<OpaquePointer?>?) -> UnsafeMutablePointer<IdeviceFfiError>?,
        connectLockdown: @escaping (OpaquePointer?, UnsafeMutablePointer<OpaquePointer?>?) -> UnsafeMutablePointer<IdeviceFfiError>?,
        cleanup: @escaping (OpaquePointer?) -> Void,
        serviceName: String,
        action: (OpaquePointer) throws -> T
    ) throws -> T {
        debugLog("[IdeviceGateway] performWithEitherService(\(serviceName)) started, mode = .\(pairingFileType)")
        if pairingFileType == .rppairing {
            return try performWithService(connect: connectRP, cleanup: cleanup, serviceName: serviceName, action: action)
        } else {
            return try performWithTcpService(connect: connectLockdown, cleanup: cleanup, serviceName: serviceName, action: action)
        }
    }

    /// Ask lockdown for the device UDID **without touching any shared state**.
    ///
    /// Deliberately not `fetchUDID()` / `performWithService`: both call
    /// `invalidateConnection()` when a connect fails, which frees the RSD
    /// adapter — and clients created from that adapter keep using it
    /// (`mountPersonalizedDdiRsd` hands `adapter` to a second FFI call from
    /// inside a service action).  This probe exists for exactly one situation:
    /// a long mobilebackup2 call is parked and the app wants to know whether the
    /// device is still there.  Freeing the adapter underneath that call to
    /// answer the question would defeat the purpose.
    ///
    /// It reuses the live adapter+handshake and opens a second lockdown service
    /// connection on the same RSD session (the same thing the diagnostics block
    /// has always done), asks one question, and closes it.  Any failure is
    /// simply "false" — nothing is invalidated, nothing is retried.
    public func probeLockdownAlive() -> Bool {
        guard pairingFileType == .rppairing else {
            // usbmuxd path: probing it would build a whole new connection, which
            // is the opposite of read-only. Report "unknown" to the caller.
            return true
        }
        guard let adapter = adapter, let handshake = handshake else {
            debugLog("[IdeviceGateway] probeLockdownAlive() no live adapter/handshake to probe")
            return false
        }
        var client: OpaquePointer? = nil
        let connectErr = lockdownd_connect_rsd(adapter, handshake, &client)
        if let connectErr = connectErr {
            safeFreeError(connectErr)
            debugLog("[IdeviceGateway] probeLockdownAlive() lockdownd_connect_rsd failed — device not answering")
            return false
        }
        guard let client = client else { return false }
        defer { lockdownd_client_free(client) }

        var value: plist_t? = nil
        let valErr = lockdownd_get_value(client, "UniqueDeviceID", nil, &value)
        if let valErr = valErr {
            safeFreeError(valErr)
            debugLog("[IdeviceGateway] probeLockdownAlive() lockdownd_get_value failed")
            return false
        }
        safeFreePlist(value)
        return true
    }

    private func syncFetchUDID() throws -> String? {
        debugLog("[IdeviceGateway] fetchUDID() started, mode = .\(pairingFileType)")
        try verifyInitialized()
        if pairingFileType == .rppairing {
            do {
                verboseLog("[IdeviceGateway] fetchUDID() calling ensureRPConnection()")
                try ensureRPConnection()
            } catch {
                debugLog("[IdeviceGateway] fetchUDID() ensureRPConnection failed with error: \(error)")
                return nil
            }
            guard let adapter = adapter, let handshake = handshake else {
                debugLog("[IdeviceGateway] fetchUDID() adapter (\(String(describing: adapter))) or handshake (\(String(describing: handshake))) is nil")
                return nil
            }
            var lockdownClient: OpaquePointer? = nil
            verboseLog("[IdeviceGateway] fetchUDID() connecting lockdownd_connect_rsd")
            var connectErr = lockdownd_connect_rsd(adapter, handshake, &lockdownClient)
            if let firstErr = connectErr {
                debugLog("[IdeviceGateway] fetchUDID() lockdownd_connect_rsd failed on existing connection, invalidating and retrying with fresh connection")
                idevice_error_free(firstErr)
                invalidateConnection()
                
                do {
                    try ensureRPConnection()
                    guard let freshAdapter = self.adapter, let freshHandshake = self.handshake else { return nil }
                    connectErr = lockdownd_connect_rsd(freshAdapter, freshHandshake, &lockdownClient)
                    if let secondErr = connectErr {
                        debugLog("[IdeviceGateway] fetchUDID() lockdownd_connect_rsd retry failed")
                        idevice_error_free(secondErr)
                        invalidateConnection()
                        return nil
                    }
                } catch {
                    debugLog("[IdeviceGateway] fetchUDID() retry ensureRPConnection failed with error: \(error)")
                    return nil
                }
            }
            guard let client = lockdownClient else {
                debugLog("[IdeviceGateway] fetchUDID() lockdownClient is nil after connect")
                return nil
            }
            defer { lockdownd_client_free(client) }
            
            var plistVal: plist_t? = nil
            verboseLog("[IdeviceGateway] fetchUDID() calling lockdownd_get_value for UniqueDeviceID")
            let valErr = lockdownd_get_value(client, "UniqueDeviceID", nil, &plistVal)
            if let valErr = valErr {
                debugLog("[IdeviceGateway] fetchUDID() lockdownd_get_value failed")
                safeFreeError(valErr)
                return nil
            }
            if let plistVal = plistVal {
                defer {
                    safeFreePlist(plistVal)
                }
                let udid = getRustPlistString(plistVal)
                verboseLog("[IdeviceGateway] fetchUDID() getRustPlistString returned UDID: \(String(describing: udid))")
                return udid
            }
            debugLog("[IdeviceGateway] fetchUDID() plistVal is nil")
            return nil
        } else {
            var conn: OpaquePointer? = nil
            let err = idevice_usbmuxd_new_default_connection(0, &conn)
            if let err = err {
                let msg = self.getErrorMessage(from: err)
                debugLog("[IdeviceGateway] fetchUDID new_default_connection failed: code=\(err.pointee.code), message=\(msg)")
                idevice_error_free(err)
                return nil
            }
            
            if let conn = conn {
                defer { idevice_usbmuxd_connection_free(conn) }
                var devices: UnsafeMutablePointer<OpaquePointer?>? = nil
                var count: Int32 = 0
                let devErr = idevice_usbmuxd_get_devices(conn, &devices, &count)
                if let devErr = devErr {
                    let msg = self.getErrorMessage(from: devErr)
                    debugLog("[IdeviceGateway] fetchUDID get_devices failed: code=\(devErr.pointee.code), message=\(msg)")
                    idevice_error_free(devErr)
                    return nil
                }
                
                var udidResult: String? = nil
                if count > 0, let devicesPtr = devices, let firstDev = devicesPtr.pointee {
                    defer { idevice_usbmuxd_device_list_free(devices, count) }
                    if let udidPtr = idevice_usbmuxd_device_get_udid(firstDev) {
                        udidResult = String(cString: udidPtr)
                        idevice_string_free(udidPtr)
                    }
                }
                verboseLog("[IdeviceGateway] fetchUDID get_devices count: \(count), udid: \(udidResult ?? "nil")")
                return udidResult
            }
            return nil
        }
    }

    private func syncGetLockdownValue(key: String) throws -> String? {
        debugLog("[IdeviceGateway] getLockdownValue(key: \(key)) started, mode = .\(pairingFileType)")
        try verifyInitialized()

        return try performWithEitherService(
            connectRP: lockdownd_connect_rsd,
            connectLockdown: lockdownd_connect,
            cleanup: lockdownd_client_free,
            serviceName: "lockdownd"
        ) { client in
            var plistVal: plist_t? = nil
            verboseLog("[IdeviceGateway] getLockdownValue calling lockdownd_get_value for \(key)")
            let valErr = lockdownd_get_value(client, key, nil, &plistVal)
            if let valErr = valErr {
                let msg = self.getErrorMessage(from: valErr)
                debugLog("[IdeviceGateway] getLockdownValue lockdownd_get_value failed for \(key): \(msg)")
                defer { safeFreeError(valErr) }
                throw IdeviceGatewayError(.serviceError, reason: "Failed to get lockdown value for key \(key), error: (\(msg))")
            }
            if let plistVal = plistVal {
                defer {
                    safeFreePlist(plistVal)
                }
                let val = getRustPlistString(plistVal)
                verboseLog("[IdeviceGateway] getLockdownValue getRustPlistString returned: \(String(describing: val))")
                return val
            }
            debugLog("[IdeviceGateway] getLockdownValue plistVal is nil for \(key)")
            return nil
        }
    }

    private func syncGetLockdownBool(key: String, domain: String) throws -> Bool? {
        debugLog("[IdeviceGateway] getLockdownBool(\(domain)/\(key)) started, mode = .\(pairingFileType)")
        try verifyInitialized()

        return try performWithEitherService(
            connectRP: lockdownd_connect_rsd,
            connectLockdown: lockdownd_connect,
            cleanup: lockdownd_client_free,
            serviceName: "lockdownd"
        ) { client in
            var node: plist_t? = nil
            let valErr = domain.withCString { domainPtr in
                lockdownd_get_value(client, key, domainPtr, &node)
            }
            if let valErr = valErr {
                let msg = self.getErrorMessage(from: valErr)
                debugLog("[IdeviceGateway] getLockdownBool lockdownd_get_value failed for \(domain)/\(key): \(msg)")
                defer { safeFreeError(valErr) }
                throw IdeviceGatewayError(.serviceError, reason: "Failed to get lockdown value \(domain)/\(key), error: (\(msg))")
            }
            guard let node = node else {
                debugLog("[IdeviceGateway] getLockdownBool plistVal is nil for \(domain)/\(key)")
                return nil
            }
            defer { safeFreePlist(node) }

            // plist_get_bool_val silently does nothing on a non-boolean node,
            // so the type check is what makes a nil answer mean "absent".
            guard plist_get_node_type(node) == PLIST_BOOLEAN else {
                verboseLog("[IdeviceGateway] getLockdownBool \(domain)/\(key) is not a boolean node")
                return nil
            }
            var out: UInt8 = 0
            plist_get_bool_val(node, &out)
            verboseLog("[IdeviceGateway] getLockdownBool \(domain)/\(key) = \(out != 0)")
            return out != 0
        }
    }

    private func syncInstallProvisioningProfile(profile: Data) throws {
        debugLog("[IdeviceGateway] installProvisioningProfile() called, profile length: \(profile.count)")
        try verifyInitialized()
        try performWithEitherService(
            connectRP: misagent_connect_rsd,
            connectLockdown: misagent_connect,
            cleanup: misagent_client_free,
            serviceName: "misagent"
        ) { client in
            try profile.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
                if let baseAddress = buf.baseAddress?.assumingMemoryBound(to: UInt8.self) {
                    verboseLog("[IdeviceGateway] installProvisioningProfile() calling misagent_install")
                    let installErr = misagent_install(client, baseAddress, profile.count)
                    if let installErr = installErr {
                        let msg = self.getErrorMessage(from: installErr)
                        debugLog("[IdeviceGateway] installProvisioningProfile() misagent_install failed: \(msg)")
                        defer { safeFreeError(installErr) }
                        throw IdeviceGatewayError(.serviceError, reason: "Failed to install profile, error: (\(msg))")
                    }
                    debugLog("[IdeviceGateway] installProvisioningProfile() misagent_install succeeded")
                }
            }
        }
    }

    private func syncRemoveProvisioningProfile(id: String) throws {
        debugLog("[IdeviceGateway] removeProvisioningProfile() called, id: \(id)")
        try verifyInitialized()
        try performWithEitherService(
            connectRP: misagent_connect_rsd,
            connectLockdown: misagent_connect,
            cleanup: misagent_client_free,
            serviceName: "misagent"
        ) { client in
            try id.withCString { idPtr in
                verboseLog("[IdeviceGateway] removeProvisioningProfile() calling misagent_remove")
                let removeErr = misagent_remove(client, idPtr)
                if let removeErr = removeErr {
                    let msg = self.getErrorMessage(from: removeErr)
                    debugLog("[IdeviceGateway] removeProvisioningProfile() misagent_remove failed: \(msg)")
                    defer { safeFreeError(removeErr) }
                    throw IdeviceGatewayError(.serviceError, reason: "Failed to remove profile, error: (\(msg))")
                }
                debugLog("[IdeviceGateway] removeProvisioningProfile() misagent_remove succeeded")
            }
        }
    }

    private func syncRemoveApp(bundleId: String) throws {
        debugLog("[IdeviceGateway] removeApp() called, bundleId: \(bundleId)")
        try verifyInitialized()
        try performWithEitherService(
            connectRP: installation_proxy_connect_rsd,
            connectLockdown: installation_proxy_connect,
            cleanup: installation_proxy_client_free,
            serviceName: "instproxy"
        ) { client in
            try bundleId.withCString { bundleIdPtr in
                verboseLog("[IdeviceGateway] removeApp() calling installation_proxy_uninstall")
                let uninstallErr = installation_proxy_uninstall(client, bundleIdPtr, nil)
                if let uninstallErr = uninstallErr {
                    let msg = self.getErrorMessage(from: uninstallErr)
                    debugLog("[IdeviceGateway] removeApp() installation_proxy_uninstall failed: \(msg)")
                    defer { idevice_error_free(uninstallErr) }
                    throw IdeviceGatewayError(.serviceError, reason: "Failed to uninstall app, error: (\(msg))")
                }
                debugLog("[IdeviceGateway] removeApp() installation_proxy_uninstall succeeded")
            }
        }
    }

    private func syncsendIpaAfc(bundleId: String, ipaBytes: Data) throws {
        debugLog("[IdeviceGateway] sendIpaAfc() called, bundleId: \(bundleId), ipaBytes size: \(ipaBytes.count)")
        try verifyInitialized()
        try performWithEitherService(
            connectRP: afc_client_connect_rsd,
            connectLockdown: afc_client_connect,
            cleanup: afc_client_free,
            serviceName: "AFC client"
        ) { client in
            // Ensure directory
            let stagingDir = MinimuxerConstants.pkgPath
            verboseLog("[IdeviceGateway] sendIpaAfc() creating directory: \(stagingDir)")
            _ = stagingDir.withCString { dirPtr in
                afc_make_directory(client, dirPtr)
            }
            let bundleDir = "\(stagingDir)/\(bundleId)"
            verboseLog("[IdeviceGateway] sendIpaAfc() creating directory: \(bundleDir)")
            _ = bundleDir.withCString { dirPtr in
                afc_make_directory(client, dirPtr)
            }
 
            let path = "\(bundleDir)/app.ipa"
            var fileHandle: OpaquePointer? = nil
            verboseLog("[IdeviceGateway] sendIpaAfc() opening remote file: \(path)")
            let openErr = path.withCString { pathPtr in
                afc_file_open(client, pathPtr, AfcFopenMode(rawValue: 4), &fileHandle) // WrOnly/Wr mode
            }
            if let openErr = openErr {
                let msg = self.getErrorMessage(from: openErr)
                debugLog("[IdeviceGateway] sendIpaAfc() afc_file_open failed: \(msg)")
                defer { idevice_error_free(openErr) }
                throw IdeviceGatewayError(.serviceError, reason: "Failed to open remote AFC file, error: (\(msg))")
            }
            defer {
                verboseLog("[IdeviceGateway] sendIpaAfc() closing remote file handle")
                afc_file_close(fileHandle)
            }
 
            try ipaBytes.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
                if let baseAddress = buf.baseAddress?.assumingMemoryBound(to: UInt8.self) {
                    verboseLog("[IdeviceGateway] sendIpaAfc() writing data to AFC file")
                    let writeErr = afc_file_write(fileHandle, baseAddress, ipaBytes.count)
                    if let writeErr = writeErr {
                        let msg = self.getErrorMessage(from: writeErr)
                        debugLog("[IdeviceGateway] sendIpaAfc() afc_file_write failed: \(msg)")
                        defer { idevice_error_free(writeErr) }
                        throw IdeviceGatewayError(.serviceError, reason: "Failed to write to AFC file, error: (\(msg))")
                    }
                    debugLog("[IdeviceGateway] sendIpaAfc() afc_file_write succeeded")
                }
            }
        }
    }

    private func syncInstallIpa(bundleId: String) throws {
        debugLog("[IdeviceGateway] installIpa() called, bundleId: \(bundleId)")
        try verifyInitialized()
        try performWithEitherService(
            connectRP: installation_proxy_connect_rsd,
            connectLockdown: installation_proxy_connect,
            cleanup: installation_proxy_client_free,
            serviceName: "instproxy"
        ) { client in
            let path = "PublicStaging/\(bundleId)/app.ipa"
            try path.withCString { pathPtr in
                verboseLog("[IdeviceGateway] installIpa() calling installation_proxy_install for path: \(path)")
                let installErr = installation_proxy_install(client, pathPtr, nil)
                if let installErr = installErr {
                    let msg = self.getErrorMessage(from: installErr)
                    debugLog("[IdeviceGateway] installIpa() installation_proxy_install failed: \(msg)")
                    defer { idevice_error_free(installErr) }
                    throw IdeviceGatewayError(.serviceError, reason: "Failed to install IPA, error: (\(msg))")
                }
                debugLog("[IdeviceGateway] installIpa() installation_proxy_install succeeded")
            }
        }
    }

    private func syncsendAppBundleAfc(bundleId: String, appURL: URL) throws {
        debugLog("[IdeviceGateway] sendAppBundleAfc() called, bundleId: \(bundleId), appURL: \(appURL.path)")
        try verifyInitialized()
        try performWithEitherService(
            connectRP: afc_client_connect_rsd,
            connectLockdown: afc_client_connect,
            cleanup: afc_client_free,
            serviceName: "AFC client"
        ) { client in
            let stagingDir = MinimuxerConstants.pkgPath
            verboseLog("[IdeviceGateway] sendAppBundleAfc() creating directory: \(stagingDir)")
            _ = stagingDir.withCString { dirPtr in
                afc_make_directory(client, dirPtr)
            }
            let bundleDir = "\(stagingDir)/\(bundleId)"
            verboseLog("[IdeviceGateway] sendAppBundleAfc() creating directory: \(bundleDir)")
            _ = bundleDir.withCString { dirPtr in
                afc_make_directory(client, dirPtr)
            }
            let remoteAppPath = "\(bundleDir)/\(appURL.lastPathComponent)"
            verboseLog("[IdeviceGateway] sendAppBundleAfc() creating directory: \(remoteAppPath)")
            _ = remoteAppPath.withCString { dirPtr in
                afc_make_directory(client, dirPtr)
            }

            let fileManager = FileManager.default
            guard let enumerator = fileManager.enumerator(
                at: appURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: []
            ) else {
                throw IdeviceGatewayError(.serviceError, reason: "Failed to enumerate \(appURL.path)")
            }

            for case let fileURL as URL in enumerator {
                let relativePath = fileURL.path.replacingOccurrences(of: appURL.path, with: "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                let remoteItemPath = "\(remoteAppPath)/\(relativePath)"

                var isDirectory: ObjCBool = false
                fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDirectory)

                if isDirectory.boolValue {
                    _ = remoteItemPath.withCString { pathPtr in
                        afc_make_directory(client, pathPtr)
                    }
                } else {
                    var fileHandle: OpaquePointer? = nil
                    let openErr = remoteItemPath.withCString { pathPtr in
                        afc_file_open(client, pathPtr, AfcFopenMode(rawValue: 4), &fileHandle)
                    }
                    if let openErr = openErr {
                        let msg = self.getErrorMessage(from: openErr)
                        defer { idevice_error_free(openErr) }
                        throw IdeviceGatewayError(.serviceError, reason: "Failed to open remote AFC file \(remoteItemPath): \(msg)")
                    }
                    defer {
                        if let fileHandle = fileHandle {
                            afc_file_close(fileHandle)
                        }
                    }

                    let fileData = try Data(contentsOf: fileURL, options: .alwaysMapped)
                    if !fileData.isEmpty {
                        try fileData.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
                            if let baseAddress = buf.baseAddress?.assumingMemoryBound(to: UInt8.self) {
                                let writeErr = afc_file_write(fileHandle, baseAddress, fileData.count)
                                if let writeErr = writeErr {
                                    let msg = self.getErrorMessage(from: writeErr)
                                    defer { idevice_error_free(writeErr) }
                                    throw IdeviceGatewayError(.serviceError, reason: "Failed to write to AFC file \(remoteItemPath): \(msg)")
                                }
                            }
                        }
                    }
                }
            }
            debugLog("[IdeviceGateway] sendAppBundleAfc() uploaded \(appURL.lastPathComponent) successfully")
        }
    }

    private func syncInstallAppBundle(bundleId: String, appName: String) throws {
        debugLog("[IdeviceGateway] installAppBundle() called, bundleId: \(bundleId), appName: \(appName)")
        try verifyInitialized()
        try performWithEitherService(
            connectRP: installation_proxy_connect_rsd,
            connectLockdown: installation_proxy_connect,
            cleanup: installation_proxy_client_free,
            serviceName: "instproxy"
        ) { client in
            let path = "\(MinimuxerConstants.pkgPath)/\(bundleId)/\(appName)"
            try path.withCString { pathPtr in
                verboseLog("[IdeviceGateway] installAppBundle() calling installation_proxy_install for path: \(path)")
                let options = plist_new_dict()
                defer { plist_free(options) }
                plist_dict_set_item(options, "PackageType", plist_new_string("Developer"))

                let installErr = installation_proxy_install(client, pathPtr, options)
                if let installErr = installErr {
                    let msg = self.getErrorMessage(from: installErr)
                    debugLog("[IdeviceGateway] installAppBundle() installation_proxy_install failed: \(msg)")
                    defer { idevice_error_free(installErr) }
                    throw IdeviceGatewayError(.serviceError, reason: "Failed to install App directory, error: (\(msg))")
                }
                debugLog("[IdeviceGateway] installAppBundle() installation_proxy_install succeeded")
            }
        }
    }

    private func getAppPaths(appId: String) throws -> (container: String, bundlePath: String, executableName: String?) {
        debugLog("[IdeviceGateway] getAppPaths() called, appId: \(appId)")
        return try performWithEitherService(
            connectRP: installation_proxy_connect_rsd,
            connectLockdown: installation_proxy_connect,
            cleanup: installation_proxy_client_free,
            serviceName: "instproxy"
        ) { client in
            var outResult: UnsafeMutableRawPointer? = nil
            var outLen: Int = 0
            
            try appId.withCString { appPtr in
                var bundleIds: [UnsafePointer<Int8>?] = [appPtr]
                verboseLog("[IdeviceGateway] getAppPaths() calling installation_proxy_get_apps")
                let err = installation_proxy_get_apps(client, nil, &bundleIds, 1, &outResult, &outLen)
                if let err = err {
                    let msg = self.getErrorMessage(from: err)
                    debugLog("[IdeviceGateway] getAppPaths() installation_proxy_get_apps failed: \(msg)")
                    defer { idevice_error_free(err) }
                    throw IdeviceGatewayError(.serviceError, reason: "Failed to lookup app paths, error: (\(msg))")
                }
            }
            
            verboseLog("[IdeviceGateway] getAppPaths() installation_proxy_get_apps returned outLen: \(outLen)")
            guard let resultPtr = outResult, outLen > 0 else {
                verboseLog("[IdeviceGateway] getAppPaths() app not found")
                throw IdeviceGatewayError(.serviceError, reason: "App not found: \(appId)")
            }
            
            let plistArray = resultPtr.assumingMemoryBound(to: plist_t?.self)
            var container = ""
            var bundlePath = ""
            var executableName: String? = nil
            
            for i in 0..<outLen {
                if let plistVal = plistArray[i] {
                    // Container
                    let containerPlist = plist_dict_get_item(plistVal, "Container")
                    if let containerPlist = containerPlist {
                        if let ptr = getRustPlistString(containerPlist) {
                            container = ptr
                            verboseLog("[IdeviceGateway] getAppPaths() found Container path: \(container)")
                        }
                    }
                    
                    // Path
                    let pathPlist = plist_dict_get_item(plistVal, "Path")
                    if let pathPlist = pathPlist {
                        if let ptr = getRustPlistString(pathPlist) {
                            bundlePath = ptr
                            verboseLog("[IdeviceGateway] getAppPaths() found Path: \(bundlePath)")
                        }
                    }

                    // CFBundleExecutable
                    let execPlist = plist_dict_get_item(plistVal, "CFBundleExecutable")
                    if let execPlist = execPlist {
                        if let ptr = getRustPlistString(execPlist) {
                            executableName = ptr
                            verboseLog("[IdeviceGateway] getAppPaths() found CFBundleExecutable: \(executableName ?? "")")
                        }
                    }
                }
            }
            free(outResult)
            
            if container.isEmpty || bundlePath.isEmpty {
                debugLog("[IdeviceGateway] getAppPaths() container or bundlePath is empty")
                throw IdeviceGatewayError(.serviceError, reason: "Failed to resolve app paths")
            }
            return (container, bundlePath, executableName)
        }
    }
    
    @discardableResult
    private func sendDebugProxyCommand(client: OpaquePointer, name: String, args: [String]) throws -> String? {
        debugLog("[IdeviceGateway] sendDebugProxyCommand() called, name: \(name), args: \(args)")
        return try name.withCString { namePtr in
            var argPtrs = args.map { UnsafePointer<Int8>(strdup($0)) }
            defer {
                for ptr in argPtrs {
                    free(UnsafeMutablePointer(mutating: ptr))
                }
            }
            
            let cmdHandle = debugserver_command_new(namePtr, &argPtrs, UInt(argPtrs.count))
            if let cmdHandle = cmdHandle {
                defer { debugserver_command_free(cmdHandle) }
                var response: UnsafeMutablePointer<Int8>? = nil
                verboseLog("[IdeviceGateway] sendDebugProxyCommand() sending command \(name)")
                let sendErr = debug_proxy_send_command(client, cmdHandle, &response)
                if let sendErr = sendErr {
                    let msg = self.getErrorMessage(from: sendErr)
                    debugLog("[IdeviceGateway] sendDebugProxyCommand() failed for command \(name): \(msg)")
                    defer { idevice_error_free(sendErr) }
                    throw IdeviceGatewayError(.serviceError, reason: "Failed to send command to debug proxy: \(name), error: (\(msg))")
                }
                if let response = response {
                    let respStr = String(cString: response)
                    verboseLog("[IdeviceGateway] sendDebugProxyCommand() got response: \(respStr)")
                    free(response)
                    return respStr
                } else {
                    debugLog("[IdeviceGateway] sendDebugProxyCommand() got empty response")
                    return nil
                }
            } else {
                debugLog("[IdeviceGateway] sendDebugProxyCommand() failed to construct command \(name)")
                throw IdeviceGatewayError(.serviceError, reason: "Failed to construct debug proxy command: \(name)")
            }
        }
    }
    
    private func launchAppPre17(appId: String) throws {
        debugLog("[IdeviceGateway] launchAppPre17() called for appId: \(appId)")
        let (container, bundlePath, _) = try getAppPaths(appId: appId)
        
        try performWithEitherService(
            connectRP: lockdownd_connect_rsd,
            connectLockdown: lockdownd_connect,
            cleanup: lockdownd_client_free,
            serviceName: "lockdownd"
        ) { lockdownClient in
            var port: UInt16 = 0
            var ssl: Bool = false
            
            verboseLog("[IdeviceGateway] launchAppPre17() starting debugserver service")
            let err = "com.apple.debugserver".withCString { serviceNamePtr in
                return lockdownd_start_service(lockdownClient, serviceNamePtr, &port, &ssl)
            }
            if let err = err {
                let msg = self.getErrorMessage(from: err)
                debugLog("[IdeviceGateway] launchAppPre17() failed to start debugserver: \(msg)")
                defer { idevice_error_free(err) }
                throw IdeviceGatewayError(.serviceError, reason: "Failed to start debugserver service, error: (\(msg))")
            }
            debugLog("[IdeviceGateway] launchAppPre17() debugserver started on port: \(port)")
            
            var addr: OpaquePointer? = nil
            var addrErr = idevice_usbmuxd_default_addr_new(&addr)
            if let addrErr = addrErr {
                debugLog("[IdeviceGateway] launchAppPre17() default_addr_new failed")
                defer { idevice_error_free(addrErr) }
                throw IdeviceGatewayError(.connectionFailed, reason: "Failed to get usbmuxd default addr")
            }
            guard let addr = addr else {
                debugLog("[IdeviceGateway] launchAppPre17() usbmuxd default addr is nil")
                throw IdeviceGatewayError(.connectionFailed, reason: "Usbmuxd default addr was nil")
            }
            defer { idevice_usbmuxd_addr_free(addr) }
            
            var conn: OpaquePointer? = nil
            verboseLog("[IdeviceGateway] launchAppPre17() creating default usbmuxd connection")
            let connErr = idevice_usbmuxd_new_default_connection(0, &conn)
            if let connErr = connErr {
                debugLog("[IdeviceGateway] launchAppPre17() new_default_connection failed")
                defer { idevice_error_free(connErr) }
                throw IdeviceGatewayError(.connectionFailed, reason: "Failed to create usbmuxd connection")
            }
            guard let conn = conn else {
                debugLog("[IdeviceGateway] launchAppPre17() usbmuxd connection is nil")
                throw IdeviceGatewayError(.connectionFailed, reason: "Usbmuxd connection was nil")
            }
            var connNeedsFree = true
            defer {
                if connNeedsFree {
                    idevice_usbmuxd_connection_free(conn)
                }
            }
            
            var devices: UnsafeMutablePointer<OpaquePointer?>? = nil
            var count: Int32 = 0
            let devErr = idevice_usbmuxd_get_devices(conn, &devices, &count)
            if let devErr = devErr {
                debugLog("[IdeviceGateway] launchAppPre17() get_devices failed")
                defer { idevice_error_free(devErr) }
                throw IdeviceGatewayError(.connectionFailed, reason: "Failed to list usbmuxd devices")
            }
            
            guard count > 0, let devicesPtr = devices, let firstDev = devicesPtr.pointee else {
                verboseLog("[IdeviceGateway] launchAppPre17() no devices found on usbmuxd")
                throw IdeviceGatewayError(.connectionFailed, reason: "No devices found on usbmuxd")
            }
            defer { idevice_usbmuxd_device_list_free(devices, count) }
            
            let deviceID = idevice_usbmuxd_device_get_device_id(firstDev)
            verboseLog("[IdeviceGateway] launchAppPre17() connecting to deviceID \(deviceID) debugserver port \(port)")
            
            var debugDevice: OpaquePointer? = nil
            let connectErr = "minimuxer-debug".withCString { labelPtr in
                return idevice_usbmuxd_connect_to_device(conn, deviceID, port, labelPtr, &debugDevice)
            }
            if let connectErr = connectErr {
                debugLog("[IdeviceGateway] launchAppPre17() connect_to_device failed")
                defer { idevice_error_free(connectErr) }
                throw IdeviceGatewayError(.connectionFailed, reason: "Failed to connect to debugserver port \(port)")
            }
            connNeedsFree = false
            
            guard let debugDevice = debugDevice else {
                debugLog("[IdeviceGateway] launchAppPre17() debug device handle is nil")
                throw IdeviceGatewayError(.connectionFailed, reason: "Debug device handle was nil")
            }
            var debugDeviceNeedsFree = true
            defer {
                if debugDeviceNeedsFree {
                    idevice_free(debugDevice)
                }
            }
            
            var stream: OpaquePointer? = nil
            verboseLog("[IdeviceGateway] launchAppPre17() converting debug device connection to stream")
           let streamErr = idevice_to_stream(debugDevice, &stream)
           if let streamErr = streamErr {
               debugLog("[IdeviceGateway] launchAppPre17() idevice_to_stream failed")
               defer { idevice_error_free(streamErr) }
               throw IdeviceGatewayError(.serviceError, reason: "Failed to convert device connection to stream")
           }
            debugDeviceNeedsFree = false
            
            guard let stream = stream else {
                debugLog("[IdeviceGateway] launchAppPre17() stream is nil")
                throw IdeviceGatewayError(.serviceError, reason: "Stream was nil")
            }
            var streamNeedsFree = true
            defer {
                if streamNeedsFree {
                    idevice_stream_free(stream)
                }
            }
            
            var debugProxyClient: OpaquePointer? = nil
            verboseLog("[IdeviceGateway] launchAppPre17() creating debug proxy client")
            let proxyErr = debug_proxy_new(stream, &debugProxyClient)
            if let proxyErr = proxyErr {
                let msg = self.getErrorMessage(from: proxyErr)
                debugLog("[IdeviceGateway] launchAppPre17() debug_proxy_new failed: \(msg)")
                defer { idevice_error_free(proxyErr) }
                throw IdeviceGatewayError(.serviceError, reason: "Failed to create debug proxy client, error: (\(msg))")
            }
            streamNeedsFree = false
            
            guard let debugProxyClient = debugProxyClient else {
                debugLog("[IdeviceGateway] launchAppPre17() debugProxyClient is nil")
                throw IdeviceGatewayError(.serviceError, reason: "Debug proxy client was nil")
            }
            defer { debug_proxy_free(debugProxyClient) }
            
            verboseLog("[IdeviceGateway] launchAppPre17() configuring debug proxy workspace")
            try self.sendDebugProxyCommand(client: debugProxyClient, name: "QSetMaxPacketSize", args: ["\(MinimuxerConstants.maxPacketSize)"])
            try self.sendDebugProxyCommand(client: debugProxyClient, name: "QSetWorkingDir", args: [container])
            
            try bundlePath.withCString { bundlePathPtr in
                var argvptrs: [UnsafePointer<Int8>?] = [bundlePathPtr, bundlePathPtr]
                var response: UnsafeMutablePointer<Int8>? = nil
                verboseLog("[IdeviceGateway] launchAppPre17() setting argv for \(bundlePath)")
                let argvErr = debug_proxy_set_argv(debugProxyClient, &argvptrs, UInt(argvptrs.count), &response)
                if let argvErr = argvErr {
                    let msg = self.getErrorMessage(from: argvErr)
                    debugLog("[IdeviceGateway] launchAppPre17() debug_proxy_set_argv failed: \(msg)")
                    defer { idevice_error_free(argvErr) }
                    throw IdeviceGatewayError(.serviceError, reason: "Failed to set debug proxy argv, error: (\(msg))")
                }
                if let response = response {
                    let respStr = String(cString: response)
                    verboseLog("[IdeviceGateway] launchAppPre17() argv response: \(respStr)")
                    free(response)
                }
            }
            
            verboseLog("[IdeviceGateway] launchAppPre17() launching application")
            try self.sendDebugProxyCommand(client: debugProxyClient, name: "qLaunchSuccess", args: [])
            try self.sendDebugProxyCommand(client: debugProxyClient, name: "D", args: [])
            debugLog("[IdeviceGateway] launchAppPre17() app launched successfully")
        }
    }

    private func getDummyffiError() -> UnsafeMutablePointer<IdeviceFfiError>? {
        debugLog("[IdeviceGateway] getDummyffiError() called")
        var client: OpaquePointer? = nil
        let err = lockdownd_connect(nil, &client)
        debugLog("[IdeviceGateway] getDummyffiError() returned: \(String(describing: err))")
        return err
    }

    private func syncDebugApp(appId: String) throws {
        debugLog("[IdeviceGateway] debugApp() called, appId: \(appId)")
        try verifyInitialized()
        guard let versionStr = try syncGetLockdownValue(key: "ProductVersion"),
              let majorStr = versionStr.split(separator: ".").first,
              let major = Int(majorStr) else {
            debugLog("[IdeviceGateway] debugApp() failed to get ProductVersion")
            throw IdeviceGatewayError(.serviceError, reason: "Failed to get product version for JIT")
        }
        
        verboseLog("[IdeviceGateway] debugApp() ProductVersion major: \(major)")
        if major < 17 {
            try launchAppPre17(appId: appId)
        } else {
            let (_, bundlePath, executableName) = try getAppPaths(appId: appId)
            try performWithEitherService(
                connectRP: debug_proxy_connect_rsd,
                connectLockdown: { [weak self] _, _ in
                    debugLog("[IdeviceGateway] debugApp() lockdown placeholder called")
                    return self?.getDummyffiError()
                },
                cleanup: debug_proxy_free,
                serviceName: "debug proxy"
            ) { client in
                guard let pid = try self.findProcessPID(
                    appId: appId,
                    bundlePath: bundlePath.isEmpty ? nil : bundlePath,
                    executableName: executableName,
                    sendCommand: { name, args in
                        try self.sendDebugProxyCommand(client: client, name: name, args: args)
                    }
                ) else {
                    let targetName = executableName ?? appId
                    throw IdeviceGatewayError(
                        .serviceError,
                        reason: "App '\(targetName)' is not running. Please open the app and keep it in the background, then enable JIT."
                    )
                }
                if pid > 0 {
                    debugLog("[IdeviceGateway] Attaching to PID \(pid) for JIT...")
                    let commands = [("vAttach;\(String(format: "%x", pid))", [String]()), ("D", [String]())]
                    for (name, args) in commands {
                        try self.sendDebugProxyCommand(client: client, name: name, args: args)
                    }
                }
                debugLog("[IdeviceGateway] debugApp() successfully attached and detached for \(executableName ?? appId) (PID: \(pid))")
            }
        }
    }

    private func syncDebugProcess(pid: UInt32) throws {
        debugLog("[IdeviceGateway] debugProcess() called, pid: \(pid)")
        try verifyInitialized()
        try performWithEitherService(
            connectRP: debug_proxy_connect_rsd,
            connectLockdown: { [weak self] _, _ in
                debugLog("[IdeviceGateway] debugProcess() lockdown placeholder called")
                return self?.getDummyffiError()
            },
            cleanup: debug_proxy_free,
            serviceName: "debug proxy"
        ) { client in
            let commands = [("vAttach;\(String(format: "%x", pid))", [String]()), ("D", [String]())]
            for (name, args) in commands {
                try self.sendDebugProxyCommand(client: client, name: name, args: args)
            }
        }
    }

    private func syncDumpProfiles(docsPath: String) throws -> String {
        debugLog("[IdeviceGateway] dumpProfiles() called, docsPath: \(docsPath)")
        try verifyInitialized()
        return try performWithEitherService(
            connectRP: misagent_connect_rsd,
            connectLockdown: misagent_connect,
            cleanup: misagent_client_free,
            serviceName: "misagent"
        ) { client in
            var outProfiles: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>? = nil
            var outProfilesLen: UnsafeMutablePointer<Int>? = nil
            var outCount: Int = 0

            verboseLog("[IdeviceGateway] dumpProfiles() calling misagent_copy_all")
            let copyErr = misagent_copy_all(client, &outProfiles, &outProfilesLen, &outCount)
            if let copyErr = copyErr {
                let msg = self.getErrorMessage(from: copyErr)
                debugLog("[IdeviceGateway] dumpProfiles() misagent_copy_all failed: \(msg)")
                defer { idevice_error_free(copyErr) }
                throw IdeviceGatewayError(.serviceError, reason: "Failed to copy profiles from misagent, error: (\(msg))")
            }

            let path = docsPath.hasPrefix("file://") ? String(docsPath.dropFirst(7)) : docsPath
            let dumpDir = "\(path)/PROVISION"
            verboseLog("[IdeviceGateway] dumpProfiles() writing profiles to: \(dumpDir), count: \(outCount)")
            try? FileManager.default.createDirectory(atPath: dumpDir, withIntermediateDirectories: true)

            if let outProfiles = outProfiles, let outProfilesLen = outProfilesLen, outCount > 0 {
                let xmlPrefix = "<?xml version=".data(using: .utf8)!
                let xmlSuffix = "</plist>".data(using: .utf8)!

                for i in 0..<outCount {
                    guard let profPtr = outProfiles[i] else { continue }
                    let len = outProfilesLen[i]
                    let profileData = Data(bytes: profPtr, count: len)

                    guard let prefixRange = profileData.range(of: xmlPrefix) else { continue }
                    guard let suffixRange = profileData.range(of: xmlSuffix, options: [], in: prefixRange.lowerBound..<profileData.count) else { continue }

                    let plistBytes = profileData.subdata(in: prefixRange.lowerBound..<suffixRange.upperBound)

                    if let innerPlist = try? PropertyListSerialization.propertyList(from: plistBytes, options: [], format: nil) as? [String: Any],
                       let uuid = innerPlist["UUID"] as? String {
                        try? profileData.write(to: URL(fileURLWithPath: "\(dumpDir)/\(uuid).mobileprovision"))
                        try? plistBytes.write(to: URL(fileURLWithPath: "\(dumpDir)/\(uuid).plist"))
                    } else {
                        try? profileData.write(to: URL(fileURLWithPath: "\(dumpDir)/unknown_\(i).mobileprovision"))
                    }
                }
                misagent_free_profiles(outProfiles, outProfilesLen, outCount)
            }
            debugLog("[IdeviceGateway] dumpProfiles() complete")
            return dumpDir
        }
    }

    private func syncPerformHeartbeat(interval: UInt64, newInterval: UnsafeMutablePointer<UInt64>) throws {
       debugLog("[IdeviceGateway] performHeartbeat() called, interval: \(interval)")
       try verifyInitialized()
       try performWithEitherService(
           connectRP: heartbeat_connect_rsd,
           connectLockdown: heartbeat_connect,
           cleanup: heartbeat_client_free,
           serviceName: "heartbeat"
       ) { client in
           verboseLog("[IdeviceGateway] performHeartbeat() calling heartbeat_get_marco")
           let getErr = heartbeat_get_marco(client, interval, newInterval)
           if let getErr = getErr {
               let msg = self.getErrorMessage(from: getErr)
               debugLog("[IdeviceGateway] performHeartbeat() heartbeat_get_marco failed: \(msg)")
               defer { idevice_error_free(getErr) }
               throw IdeviceGatewayError(.serviceError, reason: "Heartbeat receive failed, error: (\(msg))")
           }
           verboseLog("[IdeviceGateway] performHeartbeat() calling heartbeat_send_polo")
           let sendErr = heartbeat_send_polo(client)
           if let sendErr = sendErr {
               let msg = self.getErrorMessage(from: sendErr)
               debugLog("[IdeviceGateway] performHeartbeat() heartbeat_send_polo failed: \(msg)")
               defer { idevice_error_free(sendErr) }
               throw IdeviceGatewayError(.serviceError, reason: "Heartbeat send failed, error: (\(msg))")
           }
           debugLog("[IdeviceGateway] performHeartbeat() succeeded, newInterval: \(newInterval.pointee)")
       }
    }

    private func syncMountPersonalizedDdi(image: Data, trustcache: Data, manifest: Data) throws {
        debugLog("[IdeviceGateway] mountPersonalizedDdi() called, image size: \(image.count), trustcache size: \(trustcache.count), manifest size: \(manifest.count)")
        try verifyInitialized()

        if pairingFileType == .rppairing {
            try mountPersonalizedDdiRsd(image: image, trustcache: trustcache, manifest: manifest)
            return
        }

        try mountPersonalizedDdiIdevice(image: image, trustcache: trustcache, manifest: manifest)
    }

    private func mountPersonalizedDdiRsd(image: Data, trustcache: Data, manifest: Data) throws {
        var chipID: UInt64 = 0
        try performWithService(connect: lockdownd_connect_rsd, cleanup: { client in
            lockdownd_client_free(client)
        }, serviceName: "lockdownd") { lockdownClient in
            var plistVal: plist_t? = nil
            verboseLog("[IdeviceGateway] mountPersonalizedDdiRsd() getting UniqueChipID")
            let valErr = lockdownd_get_value(lockdownClient, "UniqueChipID", nil, &plistVal)
            if let valErr = valErr {
                debugLog("[IdeviceGateway] mountPersonalizedDdiRsd() lockdownd_get_value failed")
                defer { idevice_error_free(valErr) }
                throw IdeviceGatewayError(.serviceError, reason: "Failed to get UniqueChipID")
            }
            if let plistVal = plistVal {
                defer { plist_free(plistVal) }
                var val: UInt64 = 0
                plist_get_uint_val(plistVal, &val)
                chipID = val
                verboseLog("[IdeviceGateway] mountPersonalizedDdiRsd() got chipID: \(chipID)")
            }
        }

        try performWithService(connect: image_mounter_connect_rsd, cleanup: image_mounter_free, serviceName: "image mounter") { mounterClient in
//            if try isDeveloperDiskImageMounted(mounterClient: mounterClient) {
//                verboseLog("[IdeviceGateway] DeveloperDiskImage already mounted. Bypassing personalization.")
//                return
//            }
            try image.withUnsafeBytes { imgBuf in
                try trustcache.withUnsafeBytes { tcBuf in
                    try manifest.withUnsafeBytes { manBuf in
                        verboseLog("[IdeviceGateway] mountPersonalizedDdiRsd() mounting image on Remote Pairing client")
                        let mountErr = image_mounter_mount_personalized_rsd(
                            mounterClient,
                            adapter,
                            handshake,
                            imgBuf.bindMemory(to: UInt8.self).baseAddress,
                            image.count,
                            tcBuf.bindMemory(to: UInt8.self).baseAddress,
                            trustcache.count,
                            manBuf.bindMemory(to: UInt8.self).baseAddress,
                            manifest.count,
                            nil,
                            chipID
                        )
                        if let mountErr = mountErr {
                            let msg = self.getErrorMessage(from: mountErr)
                            debugLog("[IdeviceGateway] mountPersonalizedDdiRsd() mount failed: code=\(mountErr.pointee.code), message=\(msg)")
                            defer { idevice_error_free(mountErr) }
                            throw IdeviceGatewayError(.serviceError, reason: "Failed to mount personalized DDI, error: (\(msg))")
                        }
                        debugLog("[IdeviceGateway] mountPersonalizedDdiRsd() mount succeeded")
                    }
                }
            }
        }
    }

    private func mountPersonalizedDdiIdevice(image: Data, trustcache: Data, manifest: Data) throws {
        verboseLog("[IdeviceGateway] mountPersonalizedDdiIdevice() starting traditional/TCP provider mounting")

        guard let deviceEndpointIp = deviceEndpointIp else {
            debugLog("[IdeviceGateway] mountPersonalizedDdiIdevice() failed because deviceEndpointIp is nil")
            throw IdeviceGatewayError(.deviceEndpointIpNotAvailable)
        }



        guard let pairingFileData = self.pairingFileData else {
            debugLog("[IdeviceGateway] error: pairingFileData is nil")
            throw IdeviceGatewayError(.connectionFailed, reason: "pairingFileData is nil")
        }

        var tempPairingFile: OpaquePointer? = nil
        let parseErr = pairingFileData.withUnsafeBytes { buf in
            return idevice_pairing_file_from_bytes(buf.baseAddress?.assumingMemoryBound(to: UInt8.self), UInt(pairingFileData.count), &tempPairingFile)
        }
        if let parseErr = parseErr {
            let msg = self.getErrorMessage(from: parseErr)
            debugLog("[IdeviceGateway] error: Failed to parse temporary pairing file: \(msg)")
            defer { safeFreeError(parseErr) }
            throw IdeviceGatewayError(.connectionFailed, reason: "Failed to parse temporary pairing file: \(msg)")
        }
        guard let tempPairingFile = tempPairingFile else {
            throw IdeviceGatewayError(.connectionFailed, reason: "Temporary pairing file was nil")
        }

        verboseLog("[IdeviceGateway] creating TCP provider to \(deviceEndpointIp):\(MinimuxerConstants.lockdowndPort)...")
        var provider: OpaquePointer? = nil
        let provErr = try withSockaddr(ip: deviceEndpointIp, port: MinimuxerConstants.lockdowndPort) { sockaddrPtr, _ in
            sockaddrPtr.withMemoryRebound(to: idevice_sockaddr.self, capacity: 1) { reboundPtr in
                return idevice_tcp_provider_new(reboundPtr, tempPairingFile, MinimuxerConstants.appName, &provider)
            }
        }
        if let provErr = provErr {
            debugLog("[IdeviceGateway] error: Failed to create TCP provider")
            defer { safeFreeError(provErr) }
            throw IdeviceGatewayError(.connectionFailed, reason: "Failed to create TCP provider")
        }
        guard let provider = provider else {
            debugLog("[IdeviceGateway] error: TCP Provider was nil")
            throw IdeviceGatewayError(.connectionFailed, reason: "TCP Provider was nil")
        }

        var providerToFree: OpaquePointer? = provider
        defer {
            if let ptr = providerToFree {
                idevice_provider_free(ptr)
            }
        }

        var chipID: UInt64 = 0
        do {
            verboseLog("[IdeviceGateway] connecting lockdownd...")
            var lockdownClient: OpaquePointer? = nil
            let connectErr = lockdownd_connect(provider, &lockdownClient)
            if let connectErr = connectErr {
                debugLog("[IdeviceGateway] error: lockdownd_connect failed")
                providerToFree = nil
                defer { idevice_error_free(connectErr) }
                throw IdeviceGatewayError(.noConnection)
            }
            guard let lockdownClient = lockdownClient else {
                debugLog("[IdeviceGateway] error: lockdownClient was nil after connect")
                throw IdeviceGatewayError(.noConnection)
            }
            defer {
                verboseLog("[IdeviceGateway] mountPersonalizedDdiIdevice() freeing lockdown client before mounter connect")
                lockdownd_client_free(lockdownClient)
            }

            var plistVal: plist_t? = nil
            verboseLog("[IdeviceGateway] querying UniqueChipID from lockdown...")
            let valErr = lockdownd_get_value(lockdownClient, "UniqueChipID", nil, &plistVal)
            if let valErr = valErr {
                verboseLog("[IdeviceGateway] No existing lockdown session exists, starting new session...")
                idevice_error_free(valErr)
                var pf: OpaquePointer? = nil
                let getPfErr = idevice_provider_get_pairing_file(provider, &pf)
                if let getPfErr = getPfErr {
                    defer { idevice_error_free(getPfErr) }
                    throw IdeviceGatewayError(.connectionFailed, reason: "Failed to get pairing file for session retry")
                }
                guard let pf = pf else {
                    throw IdeviceGatewayError(.connectionFailed, reason: "Pairing file nil for session retry")
                }
                defer { idevice_pairing_file_free(pf) }
                let sessionErr = lockdownd_start_session(lockdownClient, pf)
                if let sessionErr = sessionErr {
                    debugLog("[IdeviceGateway] error: lockdownd_start_session failed")
                    defer { idevice_error_free(sessionErr) }
                    throw IdeviceGatewayError(.noConnection)
                }
                verboseLog("[IdeviceGateway] session started. Querying UniqueChipID again...")
                let valErr2 = lockdownd_get_value(lockdownClient, "UniqueChipID", nil, &plistVal)
                if let valErr2 = valErr2 {
                    debugLog("[IdeviceGateway] error: lockdownd_get_value failed with session too")
                    defer { idevice_error_free(valErr2) }
                    throw IdeviceGatewayError(.serviceError, reason: "Failed to get UniqueChipID")
                }
            }
            if let plistVal = plistVal {
                defer { plist_free(plistVal) }
                if plist_dict_get_item(plistVal, "Error") != nil {
                    debugLog("[IdeviceGateway] error: UniqueChipID returned error plist")
                    throw IdeviceGatewayError(.serviceError, reason: "Failed to get UniqueChipID: Prohibited")
                }
                var val: UInt64 = 0
                plist_get_uint_val(plistVal, &val)
                chipID = val
                verboseLog("[IdeviceGateway] UniqueChipID (chipID) = \(chipID)")
            }
        }

        verboseLog("[IdeviceGateway] connecting to image mounter service...")
        var mounterClient: OpaquePointer? = nil
        let mounterConnectErr = image_mounter_connect(provider, &mounterClient)
        if let mounterConnectErr = mounterConnectErr {
            debugLog("[IdeviceGateway] error: image_mounter_connect failed")
            providerToFree = nil
            defer { idevice_error_free(mounterConnectErr) }
            throw IdeviceGatewayError(.serviceError, reason: "Failed to connect to image mounter")
        }
        guard let mounterClient = mounterClient else {
            debugLog("[IdeviceGateway] error: mounterClient was nil")
            throw IdeviceGatewayError(.serviceError, reason: "Mounter client was nil")
        }
        defer { image_mounter_free(mounterClient) }

//        if try isDeveloperDiskImageMounted(mounterClient: mounterClient) {
//            verboseLog("[IdeviceGateway] DeveloperDiskImage already mounted. Bypassing personalization.")
//            return
//        }

        try image.withUnsafeBytes { imgBuf in
            try trustcache.withUnsafeBytes { tcBuf in
                try manifest.withUnsafeBytes { manBuf in
                    verboseLog("[IdeviceGateway] mountPersonalizedDdiIdevice() mounting personalized image via idevice")
                    let mountErr = image_mounter_mount_personalized(
                        mounterClient,
                        provider,
                        imgBuf.bindMemory(to: UInt8.self).baseAddress,
                        image.count,
                        tcBuf.bindMemory(to: UInt8.self).baseAddress,
                        trustcache.count,
                        manBuf.bindMemory(to: UInt8.self).baseAddress,
                        manifest.count,
                        nil,
                        chipID
                    )
                    if let mountErr = mountErr {
                        let msg = self.getErrorMessage(from: mountErr)
                        debugLog("[IdeviceGateway] mountPersonalizedDdiIdevice() mount failed: code=\(mountErr.pointee.code), message=\(msg)")
                        defer { idevice_error_free(mountErr) }
                        throw IdeviceGatewayError(.serviceError, reason: "Failed to mount personalized DDI, error: (\(msg))")
                    }
                    verboseLog("[IdeviceGateway] mountPersonalizedDdiIdevice() mount succeeded")
                }
            }
        }
    }

    private func syncIsDDIMounted() throws -> Bool {
        debugLog("[IdeviceGateway] isDDIMounted() called")
        try verifyInitialized()
        return try performWithEitherService(
            connectRP: image_mounter_connect_rsd,
            connectLockdown: image_mounter_connect,
            cleanup: image_mounter_free,
            serviceName: "image mounter"
        ) { client in
            try isDeveloperDiskImageMounted(mounterClient: client)
        }
    }

    private func isDeveloperDiskImageMounted(mounterClient: OpaquePointer) throws -> Bool {
        var devicesPtr: UnsafeMutablePointer<plist_t?>? = nil
        var devicesLen: Int = 0
        let err = image_mounter_copy_devices(mounterClient, &devicesPtr, &devicesLen)
        if let err = err {
            let ffiErr = err.pointee
            let code = ffiErr.code
            let subCode = ffiErr.sub_code
            var msg = ""
            if let msgPtr = ffiErr.message {
                msg = String(cString: msgPtr)
            }
            debugLog("[IdeviceGateway] copy_devices failed: code=\(code), subCode=\(subCode), message=\(msg)")
            defer { idevice_error_free(err) }
            return false
        }
        guard let devicesPtr = devicesPtr, devicesLen > 0 else {
            return false
        }
        defer {
            for i in 0..<devicesLen {
                if let p = devicesPtr[i] {
                    plist_free(p)
                }
            }
            free(devicesPtr)
        }
        
        for i in 0..<devicesLen {
            guard let p = devicesPtr[i],
                  let xml = plistNodeToData(p),
                  let dict = try? PropertyListSerialization.propertyList(from: xml, options: [], format: nil) as? [String: Any]
            else { continue }
            
            let mountPath = dict["MountPath"] as? String
            let imageType = dict["PersonalizedImageType"] as? String
            let diskType = dict["DiskImageType"] as? String
            
            let mountPathMatches = mountPath == "/System/Developer"
            let imageTypeMatches = imageType == "DeveloperDiskImage"
            let diskTypeMatches = (diskType == nil || diskType == "Personalized")
            
            if mountPathMatches && imageTypeMatches && diskTypeMatches {
                return true
            }
        }
        return false
    }

    private func plistNodeToData(_ node: plist_t) -> Data? {
        var xmlPtr: UnsafeMutablePointer<Int8>? = nil
        var xmlLen: UInt32 = 0
        let err = plist_to_xml(node, &xmlPtr, &xmlLen)
        guard err == PLIST_ERR_SUCCESS, let xmlPtr else {
            return nil
        }
        defer { free(xmlPtr) }
        return Data(bytes: xmlPtr, count: Int(xmlLen))
    }

    private func plistNodeToDictionary(_ node: plist_t) -> [String: Any]? {
        guard let data = plistNodeToData(node) else { return nil }
        guard let obj = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = obj as? [String: Any] else {
            return nil
        }
        return dict
    }

    /// What the device said when a mobilebackup2 exchange ended.
    ///
    /// `mobilebackup2_restore` / `_backup` hand back the device's final plist
    /// through `out_response`. Its `ErrorCode` is the device's own verdict, and
    /// it is the ONLY signal that separates "finished" from "gave up part way" —
    /// the FFI return value cannot, because it is nil for both. Non-zero means
    /// the device is telling us it did not do the work.
    struct DeviceVerdict {
        let errorCode: Int?
        let errorDescription: String?
        /// The response as the device wrote it, trimmed for the log.
        let raw: String

        var summaryLine: String {
            if let code = errorCode {
                return "device verdict: ErrorCode \(code)"
                    + (errorDescription.map { " — \($0)" } ?? "")
            }
            // Not a failure: plenty of successful exchanges answer without an
            // ErrorCode. Logged in full so the shape of a real response becomes
            // visible instead of having to be guessed at.
            return "device verdict: no ErrorCode present (response: \(raw))"
        }
    }

    /// Read that verdict out of an `out_response` plist. Never throws: a shape
    /// this code does not recognise yields an absent code, which the callers
    /// treat as "no verdict", not as "failed".
    func deviceVerdict(from response: plist_t?) -> DeviceVerdict {
        guard let response, let dict = plistNodeToDictionary(response) else {
            return DeviceVerdict(errorCode: nil, errorDescription: nil,
                                 raw: "<no response plist>")
        }
        let code = Self.intValue(dict["ErrorCode"]) ?? Self.intValue(dict["Error"])
        let description = (dict["ErrorDescription"] as? String) ?? (dict["Error"] as? String)
        let raw = String(describing: dict)
        return DeviceVerdict(errorCode: code, errorDescription: description,
                             raw: raw.count > 400 ? String(raw.prefix(400)) + "…" : raw)
    }

    /// mobilebackup2 answers sometimes carry an integer, sometimes the same
    /// number as a string, depending on which daemon is speaking.
    private static func intValue(_ any: Any?) -> Int? {
        if let number = any as? NSNumber { return number.intValue }
        if let text = any as? String { return Int(text) }
        return nil
    }

    private func syncMountDeveloperImage(image: Data, signature: Data) throws {
        debugLog("[IdeviceGateway] mountDeveloperImage() called, image size: \(image.count), signature size: \(signature.count)")
        try verifyInitialized()
        try performWithEitherService(
            connectRP: image_mounter_connect_rsd,
            connectLockdown: image_mounter_connect,
            cleanup: image_mounter_free,
            serviceName: "image mounter"
        ) { client in
            // 1. Upload
            try image.withUnsafeBytes { imgBuf in
                try signature.withUnsafeBytes { sigBuf in
                    verboseLog("[IdeviceGateway] mountDeveloperImage() uploading image")
                    let uploadErr = image_mounter_upload_image(
                        client,
                        "Developer",
                        imgBuf.bindMemory(to: UInt8.self).baseAddress,
                        image.count,
                        sigBuf.bindMemory(to: UInt8.self).baseAddress,
                        signature.count
                    )
                    if let uploadErr = uploadErr {
                        let msg = self.getErrorMessage(from: uploadErr)
                        debugLog("[IdeviceGateway] mountDeveloperImage() upload failed: \(msg)")
                        defer { idevice_error_free(uploadErr) }
                        throw IdeviceGatewayError(.serviceError, reason: "Failed to upload developer image, error: (\(msg))")
                    }
                    debugLog("[IdeviceGateway] mountDeveloperImage() upload succeeded")
                }
            }

            // 2. Mount
            try signature.withUnsafeBytes { sigBuf in
                verboseLog("[IdeviceGateway] mountDeveloperImage() mounting image")
                let mountErr = image_mounter_mount_image(
                    client,
                    "Developer",
                    sigBuf.bindMemory(to: UInt8.self).baseAddress,
                    signature.count,
                    nil,
                    0,
                    nil
                )
                if let mountErr = mountErr {
                    let msg = self.getErrorMessage(from: mountErr)
                    debugLog("[IdeviceGateway] mountDeveloperImage() mount failed: code=\(mountErr.pointee.code), message=\(msg)")
                    defer { idevice_error_free(mountErr) }
                    throw IdeviceGatewayError(.serviceError, reason: "Failed to mount developer image, error: (\(msg))")
                }
                debugLog("[IdeviceGateway] mountDeveloperImage() mount succeeded")
            }
        }
    }

    private func generatePairingFile(hostName: String) throws -> (OpaquePointer, String) {
        var rpf: OpaquePointer? = nil
        verboseLog("[IdeviceGateway] generatePairingFile() generating pairing file")
        let genErr = rp_pairing_file_generate(hostName, &rpf)
        if let genErr = genErr {
            debugLog("[IdeviceGateway] generatePairingFile() rp_pairing_file_generate failed")
            defer { idevice_error_free(genErr) }
            throw IdeviceGatewayError(.serviceError, reason: "Failed to generate pairing file")
        }
        guard let rpf = rpf else {
            throw IdeviceGatewayError(.serviceError, reason: "Generated pairing file is nil")
        }

        var dataPtr: UnsafeMutablePointer<UInt8>? = nil
        var dataLen: UInt = 0
        verboseLog("[IdeviceGateway] generatePairingFile() serializing pairing file to bytes")
        let toBytesErr = rp_pairing_file_to_bytes(rpf, &dataPtr, &dataLen)
        if let toBytesErr = toBytesErr {
            debugLog("[IdeviceGateway] generatePairingFile() rp_pairing_file_to_bytes failed")
            defer { idevice_error_free(toBytesErr) }
            rp_pairing_file_free(rpf)
            throw IdeviceGatewayError(.serviceError, reason: "Failed to serialize pairing file to bytes")
        }

        var identifier = ""
        if let dataPtr = dataPtr {
            let plistData = Data(bytes: dataPtr, count: Int(dataLen))
            idevice_data_free(dataPtr, dataLen)
            if let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any] {
                identifier = plist["identifier"] as? String ?? ""
                verboseLog("[IdeviceGateway] generatePairingFile() parsed identifier: \(identifier)")
            }
        }

        if identifier.isEmpty {
            debugLog("[IdeviceGateway] generatePairingFile() failed: parsed identifier is empty")
            rp_pairing_file_free(rpf)
            throw IdeviceGatewayError(.serviceError, reason: "Failed to parse identifier from pairing file")
        }

        return (rpf, identifier)
    }

    private func findFreePort() -> UInt16 {
        var actualPort: UInt16 = 0
        verboseLog("[IdeviceGateway] findFreePort() finding free port")
        let socketFd = socket(AF_INET, SOCK_STREAM, 0)
        if socketFd >= 0 {
            var addr = sockaddr_in()
            addr.sin_len = __uint8_t(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = 0
            addr.sin_addr.s_addr = INADDR_ANY
            let bindRes = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(socketFd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if bindRes == 0 {
                var len = socklen_t(MemoryLayout<sockaddr_in>.size)
                let nameRes = withUnsafeMutablePointer(to: &addr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        getsockname(socketFd, $0, &len)
                    }
                }
                if nameRes == 0 {
                    actualPort = UInt16(bigEndian: addr.sin_port)
                    verboseLog("[IdeviceGateway] findFreePort() bound to port: \(actualPort)")
                }
            }
            close(socketFd)
        }

        if actualPort == 0 {
            actualPort = 5555 // fallback
            verboseLog("[IdeviceGateway] findFreePort() fallback to port: \(actualPort)")
        }
        return actualPort
    }

    private func finalizeAndSavePairedDevice(
        rpf: OpaquePointer,
        hostName: String,
        hostModel: String,
        outPath: String,
        fallbackUdid: String,
        initialAltIrk: [UInt8]? = nil
    ) throws -> PairedDeviceRecord {
        verboseLog("[IdeviceGateway] finalizeAndSavePairedDevice() writing pairing file to: \(outPath)")
        let writeErr = rp_pairing_file_write(rpf, outPath)
        if let writeErr = writeErr {
            debugLog("[IdeviceGateway] finalizeAndSavePairedDevice() rp_pairing_file_write failed")
            defer { idevice_error_free(writeErr) }
            throw IdeviceGatewayError(.serviceError, reason: "Failed to write pairing file to path")
        }

        var pairedDataPtr: UnsafeMutablePointer<UInt8>? = nil
        var pairedDataLen: UInt = 0
        verboseLog("[IdeviceGateway] finalizeAndSavePairedDevice() serializing paired file to bytes")
        let serializeErr = rp_pairing_file_to_bytes(rpf, &pairedDataPtr, &pairedDataLen)
        if let serializeErr = serializeErr {
            debugLog("[IdeviceGateway] finalizeAndSavePairedDevice() rp_pairing_file_to_bytes failed")
            defer { idevice_error_free(serializeErr) }
            throw IdeviceGatewayError(.serviceError, reason: "Failed to serialize paired file")
        }

        var altIrkHex = initialAltIrk?.map { String(format: "%02x", $0) }.joined() ?? ""
        var pairedUdid = ""
        var parsedPairingFile: (any PairingFile)? = nil
        if let pairedDataPtr = pairedDataPtr {
            let plistData = Data(bytes: pairedDataPtr, count: Int(pairedDataLen))
            idevice_data_free(pairedDataPtr, pairedDataLen)
            if let content = String(data: plistData, encoding: .utf8) {
                parsedPairingFile = try? PairingFileParser.parse(content: content)
            }
            if let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any] {
                pairedUdid = plist["identifier"] as? String ?? ""
                if let altIrkData = plist["alt_irk"] as? Data {
                    altIrkHex = altIrkData.map { String(format: "%02x", $0) }.joined()
                }
                verboseLog("[IdeviceGateway] finalizeAndSavePairedDevice() parsed pairedUdid: \(pairedUdid), altIrkHex length: \(altIrkHex.count)")
            }
        }

        let resolvedPairingFile: any PairingFile
        if let parsed = parsedPairingFile {
            resolvedPairingFile = parsed
        } else {
            let diskContent = try String(contentsOfFile: outPath, encoding: .utf8)
            resolvedPairingFile = try PairingFileParser.parse(content: diskContent)
        }

        debugLog("[IdeviceGateway] finalizeAndSavePairedDevice() pairing complete")
        return PairedDeviceRecord(
            name: hostName,
            model: hostModel,
            pairingFilePath: outPath,
            pairingFile: resolvedPairingFile
        )
    }

    private func syncStartWirelessPair(
        hostName: String,
        hostModel: String,
        outPath: String,
        onReady: @escaping (String, UInt16, [String: String]) -> Void,
        onPin: @escaping (String) -> Void
    ) throws -> PairedDeviceRecord {
        debugLog("[IdeviceGateway] startWirelessPair() called, hostName: \(hostName), hostModel: \(hostModel), outPath: \(outPath)")
        
        let (rpf, identifier) = try generatePairingFile(hostName: hostName)
        defer { rp_pairing_file_free(rpf) }

        let actualPort = findFreePort()

        let txtRecords = [
            "txtvers": "1",
            "id": identifier,
            "model": hostModel,
            "name": hostName
        ]
        verboseLog("[IdeviceGateway] startWirelessPair() invoking onReady")
        onReady(identifier, actualPort, txtRecords)

        var pairedRpf: OpaquePointer? = nil
        var hostAltIrk = [UInt8](repeating: 0, count: 16)

        class PinContext {
            let callback: (String) -> Void
            init(_ callback: @escaping (String) -> Void) {
                self.callback = callback
            }
        }
        let pinContextObj = PinContext(onPin)
        let pinContextPtr = Unmanaged.passRetained(pinContextObj).toOpaque()
        defer { Unmanaged<PinContext>.fromOpaque(pinContextPtr).release() }

        verboseLog("[IdeviceGateway] startWirelessPair() waiting for connection via pairable_host_accept...")
        let acceptErr = pairable_host_accept(
            hostName,
            hostModel,
            actualPort,
            { pin, context in
                guard let pin = pin, let context = context else { return }
                let ctxObj = Unmanaged<PinContext>.fromOpaque(context).takeUnretainedValue()
                let pinStr = String(cString: pin)
                verboseLog("[IdeviceGateway] startWirelessPair() received pin: \(pinStr)")
                ctxObj.callback(pinStr)
            },
            pinContextPtr,
            nil,
            &hostAltIrk,
            nil,
            &pairedRpf
        )

        if let acceptErr = acceptErr {
            debugLog("[IdeviceGateway] startWirelessPair() pairable_host_accept failed")
            defer { idevice_error_free(acceptErr) }
            throw IdeviceGatewayError(.serviceError, reason: "Pairing failed or cancelled")
        }

        guard let pairedRpf = pairedRpf else {
            debugLog("[IdeviceGateway] startWirelessPair() pairedRpf is nil")
            throw IdeviceGatewayError(.serviceError, reason: "No pairing file returned")
        }
        defer { rp_pairing_file_free(pairedRpf) }

        return try finalizeAndSavePairedDevice(
            rpf: pairedRpf,
            hostName: hostName,
            hostModel: hostModel,
            outPath: outPath,
            fallbackUdid: identifier,
            initialAltIrk: hostAltIrk
        )
    }

    private func syncTriggerWirelessPair(
        targetIp: String,
        targetPort: UInt16,
        hostName: String,
        hostModel: String,
        outPath: String,
        onRequestPin: @escaping (@escaping (String) -> Void) -> Void
    ) throws -> PairedDeviceRecord {
        debugLog("[IdeviceGateway] triggerWirelessPair() called, targetIp: \(targetIp), targetPort: \(targetPort), hostName: \(hostName), hostModel: \(hostModel), outPath: \(outPath)")
        
        let (rpf, identifier) = try generatePairingFile(hostName: hostName)
        defer { rp_pairing_file_free(rpf) }

        guard !targetIp.isEmpty, targetPort > 0 else {
            debugLog("[IdeviceGateway] triggerWirelessPair() failed because target endpoint is invalid: \(targetIp):\(targetPort)")
            throw IdeviceGatewayError(.invalidTargetEndpoint, reason: "Target endpoint IP (\(targetIp)) or port (\(targetPort)) is invalid")
        }

        class PinContext {
            let onRequestPin: (@escaping (String) -> Void) -> Void
            init(_ onRequestPin: @escaping (@escaping (String) -> Void) -> Void) {
                self.onRequestPin = onRequestPin
            }
        }
        let pinContextObj = PinContext(onRequestPin)
        let pinContextPtr = Unmanaged.passRetained(pinContextObj).toOpaque()
        defer { Unmanaged<PinContext>.fromOpaque(pinContextPtr).release() }

        var err: UnsafeMutablePointer<IdeviceFfiError>? = nil
        var peerDevicePtr: UnsafeMutablePointer<RpPairingPeerDeviceC>? = nil

        verboseLog("[IdeviceGateway] triggerWirelessPair() pairing via rppairing_pair_network to \(targetIp):\(targetPort)...")
        try hostName.withCString { hostPtr in
            try withSockaddr(ip: targetIp, port: targetPort) { sockaddrPtr, sockaddrLen in
                err = rppairing_pair_network(
                    sockaddrPtr,
                    sockaddrLen,
                    hostPtr,
                    rpf,
                    { context in
                        guard let context = context else { return nil }
                        let ctxObj = Unmanaged<PinContext>.fromOpaque(context).takeUnretainedValue()
                        let sema = DispatchSemaphore(value: 0)
                        var enteredPin: String? = nil
                        debugLog("[IdeviceGateway] pin_callback invoked, requesting PIN from user UI...")
                        ctxObj.onRequestPin { pin in
                            debugLog("[IdeviceGateway] pin_callback received user entered PIN: '\(pin)'")
                            enteredPin = pin
                            sema.signal()
                        }
                        let waitResult = sema.wait(timeout: .now() + 60.0)
                        if waitResult == .timedOut {
                            debugLog("[IdeviceGateway] pin_callback timed out waiting for user input")
                        }
                        guard let pinStr = enteredPin, let p = strdup(pinStr) else { return nil }
                        return UnsafePointer(p)
                    },
                    pinContextPtr,
                    &peerDevicePtr
                )
            }
        }

        if let err = err {
            let msg = err.pointee.message != nil ? String(cString: err.pointee.message!) : "Pairing failed"
            debugLog("[IdeviceGateway] triggerWirelessPair() pairing failed: \(msg)")
            defer { idevice_error_free(err) }
            throw IdeviceGatewayError(.serviceError, reason: msg)
        }

        var peerName = hostName
        var peerModel = hostModel
        var peerUdid: String? = nil
        var peerAltIrk: [UInt8]? = nil

        if let peer = peerDevicePtr {
            defer { rppairing_peer_device_free(peer) }
            let p = peer.pointee
            if let namePtr = p.name {
                peerName = String(cString: namePtr)
            }
            if let modelPtr = p.model {
                peerModel = String(cString: modelPtr)
            }
            if let udidPtr = p.udid {
                peerUdid = String(cString: udidPtr)
            }
            peerAltIrk = withUnsafeBytes(of: p.alt_irk) { Array($0) }
        }

        return try finalizeAndSavePairedDevice(
            rpf: rpf,
            hostName: peerName,
            hostModel: peerModel,
            outPath: outPath,
            fallbackUdid: peerUdid ?? identifier,
            initialAltIrk: peerAltIrk
        )
    }

    private func startHouseArrestAfc(bundleId: String) throws -> OpaquePointer {
        debugLog("[IdeviceGateway] startHouseArrestAfc() called, bundleId: \(bundleId)")
        try verifyInitialized()
        
        var afcHandle: OpaquePointer? = nil
        try performWithEitherService(
            connectRP: house_arrest_client_connect_rsd,
            connectLockdown: house_arrest_client_connect,
            cleanup: { _ in }, // no need to free, house_arrest takes ownership of the pointer
            serviceName: "house_arrest"
        ) { client in
            verboseLog("[IdeviceGateway] startHouseArrestAfc() calling house_arrest_vend_container")
            let err = bundleId.withCString { bundleIdPtr in
                house_arrest_vend_container(client, bundleIdPtr, &afcHandle)
            }
            if let err = err {
                let msg = self.getErrorMessage(from: err)
                debugLog("[IdeviceGateway] startHouseArrestAfc() house_arrest_vend_container failed: \(msg)")
                defer { safeFreeError(err) }
                throw IdeviceGatewayError(.serviceError, reason: "Failed to vend container for \(bundleId), error: (\(msg))")
            }
            debugLog("[IdeviceGateway] startHouseArrestAfc() house_arrest_vend_container succeeded")
        }
        
        guard let resultHandle = afcHandle else {
            debugLog("[IdeviceGateway] startHouseArrestAfc() resulting AFC handle is nil")
            throw IdeviceGatewayError(.serviceError, reason: "AFC handle is nil after vend_container")
        }
        return resultHandle
    }

    private func afcListDirectory(client: OpaquePointer, path: String) throws -> [String] {
        verboseLog("[IdeviceGateway] afcListDirectory() called, path: \(path)")
        var entriesRaw: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>? = nil
        var count: Int = 0
        let err = path.withCString { pathPtr in
            afc_list_directory(client, pathPtr, &entriesRaw, &count)
        }
        if let err = err {
            let msg = self.getErrorMessage(from: err)
            debugLog("[IdeviceGateway] afcListDirectory() afc_list_directory failed for: \(path), error: (\(msg))")
            defer { safeFreeError(err) }
            throw IdeviceGatewayError(.serviceError, reason: "Failed to list directory: \(path), error: (\(msg))")
        }
        var items: [String] = []
        if let entries = entriesRaw {
            for i in 0..<count {
                if let cStr = entries[i] {
                    items.append(String(cString: cStr))
                    idevice_string_free(cStr)
                }
            }
            free(entries)
        }
        verboseLog("[IdeviceGateway] afcListDirectory() succeeded, count: \(items.count)")
        return items
    }

    private func afcReadFile(client: OpaquePointer, path: String) throws -> Data {
        debugLog("[IdeviceGateway] afcReadFile() called, path: \(path)")
        var fileHandle: OpaquePointer? = nil
        let openErr = path.withCString { pathPtr in
            afc_file_open(client, pathPtr, AfcFopenMode(rawValue: 1), &fileHandle) // RdOnly mode
        }
        if let openErr = openErr {
            let msg = self.getErrorMessage(from: openErr)
            debugLog("[IdeviceGateway] afcReadFile() afc_file_open failed for: \(path), error: (\(msg))")
            defer { safeFreeError(openErr) }
            throw IdeviceGatewayError(.serviceError, reason: "Failed to open file: \(path), error: (\(msg))")
        }
        defer {
            verboseLog("[IdeviceGateway] afcReadFile() closing file handle")
            _ = afc_file_close(fileHandle)
        }
        
        var dataPtr: UnsafeMutablePointer<UInt8>? = nil
        var length: Int = 0
        let readErr = afc_file_read_entire(fileHandle, &dataPtr, &length)
        if let readErr = readErr {
            let msg = self.getErrorMessage(from: readErr)
            debugLog("[IdeviceGateway] afcReadFile() afc_file_read_entire failed, error: (\(msg))")
            defer { safeFreeError(readErr) }
            throw IdeviceGatewayError(.serviceError, reason: "Failed to read file: \(path), error: (\(msg))")
        }
        
        if let ptr = dataPtr {
            let data = Data(bytes: ptr, count: length)
            afc_file_read_data_free(ptr, length)
            debugLog("[IdeviceGateway] afcReadFile() succeeded, read size: \(data.count) bytes")
            return data
        } else {
            debugLog("[IdeviceGateway] afcReadFile() read completed with empty data")
            return Data()
        }
    }

    private func afcGetFileInfo(client: OpaquePointer, path: String) throws -> (isDirectory: Bool, fileSize: Int64) {
        verboseLog("[IdeviceGateway] afcGetFileInfo() called, path: \(path)")
        var info = AfcFileInfo()
        let err = path.withCString { pathPtr in
            afc_get_file_info(client, pathPtr, &info)
        }
        if let err = err {
            debugLog("[IdeviceGateway] afcGetFileInfo() afc_get_file_info failed for: \(path)")
            defer { safeFreeError(err) }
            throw IdeviceGatewayError(.serviceError, reason: "Failed to get info for path: \(path)")
        }
        defer {
            var mutableInfo = info
            afc_file_info_free(&mutableInfo)
        }
        
        let isDirectory = info.st_ifmt != nil && String(cString: info.st_ifmt).contains("S_IFDIR")
        let size = Int64(info.size)
        verboseLog("[IdeviceGateway] afcGetFileInfo() succeeded, isDirectory: \(isDirectory), size: \(size)")
        return (isDirectory, size)
    }

    private func syncAfcListDirectory(bundleId: String, path: String) throws -> [String] {
        let client = try startHouseArrestAfc(bundleId: bundleId)
        defer { afcClientFree(client: client) }
        return try afcListDirectory(client: client, path: path)
    }

    private func syncAfcReadFile(bundleId: String, path: String) throws -> Data {
        let client = try startHouseArrestAfc(bundleId: bundleId)
        defer { afcClientFree(client: client) }
        return try afcReadFile(client: client, path: path)
    }

    private func syncAfcGetFileInfo(bundleId: String, path: String) throws -> (isDirectory: Bool, fileSize: Int64) {
        let client = try startHouseArrestAfc(bundleId: bundleId)
        defer { afcClientFree(client: client) }
        return try afcGetFileInfo(client: client, path: path)
    }

        private func afcRemovePathRecursive(client: OpaquePointer, path: String) throws {
        let (isDirectory, _) = try afcGetFileInfo(client: client, path: path)
        if isDirectory {
            let contents = try afcListDirectory(client: client, path: path)
            for item in contents {
                if item == "." || item == ".." { continue }
                let itemPath = path == "/" ? "/\(item)" : "\(path)/\(item)"
                try afcRemovePathRecursive(client: client, path: itemPath)
            }
        }
        
        let err = path.withCString { pathPtr in
            afc_remove_path(client, pathPtr)
        }
        if let err = err {
            verboseLog("[IdeviceGateway] afcRemovePathRecursive() afc_remove_path failed for: \(path)")
            defer { safeFreeError(err) }
        }
    }

    private func syncWipeContainer(identifier: String) throws {
        debugLog("[IdeviceGateway] wipeContainer() called, identifier: \(identifier)")
        let client = try startHouseArrestAfc(bundleId: identifier)
        defer { afcClientFree(client: client) }
        
        let contents = try afcListDirectory(client: client, path: "/")
        for item in contents {
            if item == "." || item == ".." { continue }
            try afcRemovePathRecursive(client: client, path: "/\(item)")
        }
        debugLog("[IdeviceGateway] wipeContainer() completed, identifier: \(identifier)")
    }

    private func afcClientFree(client: OpaquePointer) {
        debugLog("[IdeviceGateway] afcClientFree() freeing AFC client handle")
        afc_client_free(client)
    }

    // MARK: - AFC filesystem (com.apple.afc + house_arrest)
    //
    // Read *and* write access to two roots, over the same AFC client:
    //
    //   * **Media** — `/var/mobile/Media` (DCIM, Downloads, Books, Recordings).
    //     Opened by asking lockdown for `com.apple.afc` directly.
    //   * **App containers** — an app's whole data container, or just its
    //     Documents.  house_arrest vends the AFC handle; the protocol under it
    //     is identical, which is why the primitives below take a client and
    //     both roots share them.
    //
    // This is the same split the `afc://<udid>:<n>/` URLs a desktop file
    // manager opens mean: the number in the URL picks the service, and the
    // container services are the house_arrest ones.
    //
    // Every call opens its own client and closes it, because AFC handles are
    // not safe to share across threads and the app's UI hops between tasks.  One
    // connection per user action is cheap next to the round trip the user just
    // paid to trigger it.

    /// Open the plain AFC service and run `action` against it, closing the
    /// client afterwards whatever the outcome.
    private func withAfcFs<T: Sendable>(
        _ action: (OpaquePointer) throws -> T
    ) throws -> T {
        try performWithEitherService(
            connectRP: afc_client_connect_rsd,
            connectLockdown: afc_client_connect,
            cleanup: afc_client_free,
            serviceName: "AFC filesystem"
        ) { client in
            try action(client)
        }
    }

    /// The same, against one app's data container, via house_arrest.
    ///
    /// `startHouseArrestAfc` (above) already frees the house_arrest client and
    /// hands back the AFC handle it vended, so the only cleanup left here is
    /// that handle — the same pairing the house-arrest list/read helpers use.
    private func withAfcContainer<T: Sendable>(
        bundleId: String,
        _ action: (OpaquePointer) throws -> T
    ) throws -> T {
        let client = try startHouseArrestAfc(bundleId: bundleId)
        defer { afcClientFree(client: client) }
        return try action(client)
    }

    // MARK: Primitives (client in hand, root-agnostic)

    private func fsVolumeInfo(client: OpaquePointer) throws -> AfcFsVolumeInfo {
        var info = AfcDeviceInfo()
        let err = afc_get_device_info(client, &info)
        if let err = err {
            let msg = self.getErrorMessage(from: err)
            defer { safeFreeError(err) }
            throw IdeviceGatewayError(.serviceError, reason: "afc_get_device_info failed: \(msg)")
        }
        defer { afc_device_info_free(&info) }
        return AfcFsVolumeInfo(
            model: info.model.map { String(cString: $0) } ?? "",
            totalBytes: Int64(clamping: info.total_bytes),
            freeBytes: Int64(clamping: info.free_bytes),
            blockSize: Int64(clamping: info.block_size)
        )
    }

    private func fsList(client: OpaquePointer, path: String) throws -> [AfcFsEntry] {
        let names = try afcListDirectory(client: client, path: path)
        let base = path.hasSuffix("/") ? path : path + "/"
        return names
            // afc_list_directory reports "." and ".." like any other entry.
            .filter { $0 != "." && $0 != ".." }
            .map { name -> AfcFsEntry in
                let child = base + name
                var info = AfcFileInfo()
                let err = child.withCString { childPtr in
                    afc_get_file_info(client, childPtr, &info)
                }
                if let err = err {
                    // A file can vanish between the listing and the stat (the
                    // user deleting it on the device, a background cleanup).
                    // That is not a reason to fail the whole listing: report
                    // the row with the size unknown.
                    safeFreeError(err)
                    return AfcFsEntry(
                        path: child,
                        name: name,
                        isDirectory: false,
                        size: 0,
                        modified: nil,
                        linkTarget: nil
                    )
                }
                defer { var mutable = info; afc_file_info_free(&mutable) }
                return afcEntry(client: client, path: child, info: info)
            }
            .sorted { lhs, rhs in
                // Directories first, then case-insensitive by name: the order
                // every file browser uses, and the one the desktop app's own
                // dialogs use.
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    private func fsEntryInfo(client: OpaquePointer, path: String) throws -> AfcFsEntry {
        var info = AfcFileInfo()
        let err = path.withCString { pathPtr in
            afc_get_file_info(client, pathPtr, &info)
        }
        if let err = err {
            let msg = self.getErrorMessage(from: err)
            defer { safeFreeError(err) }
            throw IdeviceGatewayError(.serviceError, reason: "afc_get_file_info failed for \(path): \(msg)")
        }
        defer { var mutable = info; afc_file_info_free(&mutable) }
        return afcEntry(client: client, path: path, info: info)
    }

    private func fsRead(client: OpaquePointer, path: String) throws -> Data {
        try afcReadFile(client: client, path: path)
    }

    /// `afcStreamFile`'s body: one connection, one file handle, N chunks.
    ///
    /// The FFI's `afc_file_read` allocates its own buffer per call (unlike the C
    /// API's caller-provided one), so each chunk is copied into `Data` and the
    /// buffer handed straight back to `afc_file_read_data_free`. A short read
    /// is normal — the device answers in packets — so the loop only ends when
    /// `bytesRead` comes back 0, i.e. EOF.
    private func fsStream(
        client: OpaquePointer,
        path: String,
        chunkSize: Int,
        onChunk: @escaping @Sendable (Data) throws -> Void
    ) throws -> Int64 {
        var fileHandle: OpaquePointer? = nil
        let openErr = path.withCString { pathPtr in
            afc_file_open(client, pathPtr, AfcFopenMode(rawValue: 1), &fileHandle) // RdOnly
        }
        if let openErr = openErr {
            let msg = self.getErrorMessage(from: openErr)
            defer { safeFreeError(openErr) }
            throw IdeviceGatewayError(.serviceError, reason: "afc_file_open failed for \(path), error: (\(msg))")
        }
        guard let fileHandle else {
            throw IdeviceGatewayError(.serviceError, reason: "afc_file_open returned no handle for \(path)")
        }
        defer { _ = afc_file_close(fileHandle) }

        // A caller asking for 0 bytes, or something absurd, gets one AFC packet
        // or a hard failure respectively. 8 MiB is roughly what a single read
        // can be asked for before the device starts refusing.
        let want = UInt(max(4096, min(chunkSize, 8 * 1024 * 1024)))
        var total: Int64 = 0
        while true {
            var bufferPtr: UnsafeMutablePointer<UInt8>? = nil
            var bytesRead: size_t = 0
            let readErr = afc_file_read(fileHandle, &bufferPtr, want, &bytesRead)
            if let readErr = readErr {
                let msg = self.getErrorMessage(from: readErr)
                defer { safeFreeError(readErr) }
                throw IdeviceGatewayError(.serviceError, reason: "afc_file_read failed for \(path) at offset \(total), error: (\(msg))")
            }
            guard let bufferPtr, bytesRead > 0 else {
                if let bufferPtr { afc_file_read_data_free(bufferPtr, bytesRead) }
                return total
            }
            // Copy out, then free: the sink may keep `chunk` for as long as it
            // likes, and must not be able to reach into freed memory.
            let chunk = Data(bytes: bufferPtr, count: bytesRead)
            afc_file_read_data_free(bufferPtr, bytesRead)
            do {
                try onChunk(chunk)
            } catch {
                // BytesRead of the *next* read are the ones a reader would have
                // to skip past; nothing to do here beyond closing the handle.
                throw error
            }
            total += Int64(bytesRead)
        }
    }

    private func fsWrite(client: OpaquePointer, path: String, data: Data) throws {
        var fileHandle: OpaquePointer? = nil
        let openErr = path.withCString { pathPtr in
            // AfcWr truncates on open, which is what an overwrite has to mean:
            // writing fewer bytes than the file had must shorten it, not leave
            // a tail of the old contents behind.
            afc_file_open(client, pathPtr, AfcFopenMode(rawValue: 4), &fileHandle)
        }
        if let openErr = openErr {
            let msg = self.getErrorMessage(from: openErr)
            defer { safeFreeError(openErr) }
            throw IdeviceGatewayError(.serviceError, reason: "afc_file_open (write) failed for \(path): \(msg)")
        }
        guard let fileHandle else {
            throw IdeviceGatewayError(.serviceError, reason: "afc_file_open returned no handle for \(path)")
        }
        var closed = false
        defer {
            if !closed { _ = afc_file_close(fileHandle) }
        }
        guard !data.isEmpty else {
            // A zero-length write is just the truncate above; sending an empty
            // buffer to afc_file_write is at best a no-op and on some firmware
            // an error.
            _ = afc_file_close(fileHandle)
            closed = true
            return
        }
        let writeErr = data.withUnsafeBytes { raw -> UnsafeMutablePointer<IdeviceFfiError>? in
            afc_file_write(fileHandle, raw.bindMemory(to: UInt8.self).baseAddress, data.count)
        }
        if let writeErr = writeErr {
            let msg = self.getErrorMessage(from: writeErr)
            defer { safeFreeError(writeErr) }
            throw IdeviceGatewayError(.serviceError, reason: "afc_file_write failed for \(path): \(msg)")
        }
        _ = afc_file_close(fileHandle)
        closed = true
    }

    private func fsMakeDirectory(client: OpaquePointer, path: String) throws {
        let err = path.withCString { pathPtr in
            afc_make_directory(client, pathPtr)
        }
        guard let err = err else { return }
        // "Create New Folder" on an existing name is not a failure the caller
        // needs to hear about, and AFC's error string is not something to
        // pattern-match on.  Ask the device instead.
        var info = AfcFileInfo()
        let probe = path.withCString { pathPtr -> UnsafeMutablePointer<IdeviceFfiError>? in
            afc_get_file_info(client, pathPtr, &info)
        }
        if probe == nil {
            let isDirectory = info.st_ifmt.map { String(cString: $0).contains("S_IFDIR") } ?? false
            var mutable = info
            afc_file_info_free(&mutable)
            if isDirectory { return }
        } else {
            safeFreeError(probe)
        }
        let msg = self.getErrorMessage(from: err)
        defer { safeFreeError(err) }
        throw IdeviceGatewayError(.serviceError, reason: "afc_make_directory failed for \(path): \(msg)")
    }

    private func fsRename(client: OpaquePointer, path: String, to newPath: String) throws {
        let err = path.withCString { fromPtr in
            newPath.withCString { toPtr in
                afc_rename_path(client, fromPtr, toPtr)
            }
        }
        if let err = err {
            let msg = self.getErrorMessage(from: err)
            defer { safeFreeError(err) }
            throw IdeviceGatewayError(.serviceError, reason: "afc_rename_path failed \(path) → \(newPath): \(msg)")
        }
    }

    private func fsDelete(client: OpaquePointer, path: String) throws {
        // `afc_remove_path_and_contents` is the device-side recursive delete:
        // one round trip, and it is the call that does not need this side to
        // walk the tree (which is also what would break on a directory deep
        // enough to stall on a round trip per level).
        let err = path.withCString { pathPtr in
            afc_remove_path_and_contents(client, pathPtr)
        }
        if let err = err {
            let msg = self.getErrorMessage(from: err)
            defer { safeFreeError(err) }
            throw IdeviceGatewayError(.serviceError, reason: "afc_remove_path_and_contents failed for \(path): \(msg)")
        }
    }

    /// Build an `AfcFsEntry` out of one `afc_get_file_info` result.
    ///
    /// The date is the awkward part: AFC reports mtime as a plain integer whose
    /// epoch is Apple-specific (seconds since 2001-01-01), and not every
    /// firmware slice agrees — some send Unix seconds instead.  Rather than
    /// print confidently wrong dates, try the Apple epoch, then Unix, and
    /// report `nil` when neither lands in a range a real file could occupy.
    private func afcEntry(
        client: OpaquePointer,
        path: String,
        info: AfcFileInfo
    ) -> AfcFsEntry {
        let name = (path as NSString).lastPathComponent
        let isDirectory = info.st_ifmt.map { String(cString: $0).contains("S_IFDIR") } ?? false
        let linkTarget = info.st_link_target.map { String(cString: $0) }
        return AfcFsEntry(
            path: path,
            name: name.isEmpty ? path : name,
            isDirectory: isDirectory,
            size: Int64(clamping: info.size),
            modified: Self.afcDate(fromRaw: info.modified),
            linkTarget: linkTarget
        )
    }

    private static func afcDate(fromRaw raw: Int64) -> Date? {
        guard raw > 0 else { return nil }
        let appleEpoch = Date(timeIntervalSinceReferenceDate: TimeInterval(raw))
        if (2007...2035).contains(Calendar.current.component(.year, from: appleEpoch)) {
            return appleEpoch
        }
        let unixEpoch = Date(timeIntervalSince1970: TimeInterval(raw))
        if (2007...2035).contains(Calendar.current.component(.year, from: unixEpoch)) {
            return unixEpoch
        }
        return nil
    }

    // MARK: Media (com.apple.afc)

    public func afcVolumeInfo() async throws -> AfcFsVolumeInfo {
        try await withFFIDispatch { try self.withAfcFs { try self.fsVolumeInfo(client: $0) } }
    }

    public func afcList(path: String) async throws -> [AfcFsEntry] {
        try await withFFIDispatch { try self.withAfcFs { try self.fsList(client: $0, path: path) } }
    }

    public func afcEntryInfo(path: String) async throws -> AfcFsEntry {
        try await withFFIDispatch { try self.withAfcFs { try self.fsEntryInfo(client: $0, path: path) } }
    }

    public func afcRead(path: String) async throws -> Data {
        try await withFFIDispatch { try self.withAfcFs { try self.fsRead(client: $0, path: path) } }
    }

    public func afcStreamFile(
        path: String,
        chunkSize: Int,
        onChunk: @escaping @Sendable (Data) throws -> Void
    ) async throws -> Int64 {
        try await withFFIDispatch {
            try self.withAfcFs {
                try self.fsStream(client: $0, path: path, chunkSize: chunkSize, onChunk: onChunk)
            }
        }
    }

    public func afcWrite(path: String, data: Data) async throws {
        try await withFFIDispatch { try self.withAfcFs { try self.fsWrite(client: $0, path: path, data: data) } }
    }

    public func afcMakeDirectory(path: String) async throws {
        try await withFFIDispatch { try self.withAfcFs { try self.fsMakeDirectory(client: $0, path: path) } }
    }

    public func afcRename(path: String, to newPath: String) async throws {
        try await withFFIDispatch { try self.withAfcFs { try self.fsRename(client: $0, path: path, to: newPath) } }
    }

    public func afcDelete(path: String) async throws {
        try await withFFIDispatch { try self.withAfcFs { try self.fsDelete(client: $0, path: path) } }
    }

    // MARK: App containers (house_arrest)

    public func afcContainerList(bundleId: String, path: String) async throws -> [AfcFsEntry] {
        try await withFFIDispatch {
            try self.withAfcContainer(bundleId: bundleId) { try self.fsList(client: $0, path: path) }
        }
    }

    public func afcContainerInfo(bundleId: String, path: String) async throws -> AfcFsEntry {
        try await withFFIDispatch {
            try self.withAfcContainer(bundleId: bundleId) { try self.fsEntryInfo(client: $0, path: path) }
        }
    }

    public func afcContainerRead(bundleId: String, path: String) async throws -> Data {
        try await withFFIDispatch {
            try self.withAfcContainer(bundleId: bundleId) { try self.fsRead(client: $0, path: path) }
        }
    }

    public func afcContainerWrite(bundleId: String, path: String, data: Data) async throws {
        try await withFFIDispatch {
            try self.withAfcContainer(bundleId: bundleId) { try self.fsWrite(client: $0, path: path, data: data) }
        }
    }

    public func afcContainerMakeDirectory(bundleId: String, path: String) async throws {
        try await withFFIDispatch {
            try self.withAfcContainer(bundleId: bundleId) { try self.fsMakeDirectory(client: $0, path: path) }
        }
    }

    public func afcContainerRename(bundleId: String, path: String, to newPath: String) async throws {
        try await withFFIDispatch {
            try self.withAfcContainer(bundleId: bundleId) { try self.fsRename(client: $0, path: path, to: newPath) }
        }
    }

    public func afcContainerDelete(bundleId: String, path: String) async throws {
        try await withFFIDispatch {
            try self.withAfcContainer(bundleId: bundleId) { try self.fsDelete(client: $0, path: path) }
        }
    }

    // MARK: Installed apps (instproxy)

    public func installedApps() async throws -> [DeviceAppInfo] {
        try await withFFIDispatch { try self.syncInstalledApps() }
    }

    /// Every app the device reports, as `installation_proxy_get_apps` with a
    /// NULL bundle-id filter returns them.
    ///
    /// The existing lookups in this file pass one bundle id and read
    /// `Container`/`Path` out of the first result; this asks for all of them
    /// and reads the fields a container browser shows.  `CFBundleDisplayName`
    /// first, because that is what the device's own UI shows, then
    /// `CFBundleName`, then the bundle ID — an app that declares neither still
    /// has to be findable.
    private func syncInstalledApps() throws -> [DeviceAppInfo] {
        try performWithEitherService(
            connectRP: installation_proxy_connect_rsd,
            connectLockdown: installation_proxy_connect,
            cleanup: installation_proxy_client_free,
            serviceName: "instproxy"
        ) { client in
            var outResult: UnsafeMutableRawPointer? = nil
            var outLen: Int = 0
            let err = installation_proxy_get_apps(client, nil, nil, 0, &outResult, &outLen)
            if let err = err {
                let msg = self.getErrorMessage(from: err)
                defer { safeFreeError(err) }
                throw IdeviceGatewayError(.serviceError, reason: "Could not list installed apps: \(msg)")
            }
            defer { if let outResult { free(outResult) } }
            guard let resultPtr = outResult, outLen > 0 else { return [] }

            let plistArray = resultPtr.assumingMemoryBound(to: plist_t?.self)
            var apps: [DeviceAppInfo] = []
            apps.reserveCapacity(outLen)
            for index in 0..<outLen {
                guard let appPlist = plistArray[index] else { continue }
                func string(_ key: String) -> String? {
                    guard let item = plist_dict_get_item(appPlist, key) else { return nil }
                    return getRustPlistString(item)
                }
                guard let bundleID = string("CFBundleIdentifier"), !bundleID.isEmpty else { continue }
                let name = string("CFBundleDisplayName")
                    ?? string("CFBundleName")
                    ?? bundleID
                apps.append(DeviceAppInfo(
                    bundleID: bundleID,
                    name: name,
                    version: string("CFBundleShortVersionString") ?? "",
                    containerPath: string("Container") ?? ""
                ))
            }
            debugLog("[IdeviceGateway] syncInstalledApps() found \(apps.count) app(s)")
            return apps
        }
    }
    // MARK: - App lookup (instproxy)

    private func syncLookupApp(appId: String) throws -> InstalledAppInfo {
        debugLog("[IdeviceGateway] syncLookupApp() called, appId: \(appId)")
        return try performWithEitherService(
            connectRP: installation_proxy_connect_rsd,
            connectLockdown: installation_proxy_connect,
            cleanup: installation_proxy_client_free,
            serviceName: "instproxy"
        ) { client in
            var outResult: UnsafeMutableRawPointer? = nil
            var outLen: Int = 0

            try appId.withCString { appPtr in
                var bundleIds: [UnsafePointer<Int8>?] = [appPtr]
                verboseLog("[IdeviceGateway] syncLookupApp() calling installation_proxy_get_apps")
                let err = installation_proxy_get_apps(client, nil, &bundleIds, 1, &outResult, &outLen)
                if let err = err {
                    let msg = self.getErrorMessage(from: err)
                    debugLog("[IdeviceGateway] syncLookupApp() installation_proxy_get_apps failed: \(msg)")
                    defer { idevice_error_free(err) }
                    throw IdeviceGatewayError(.serviceError, reason: "Failed to lookup app \(appId), error: (\(msg))")
                }
            }

            guard let resultPtr = outResult, outLen > 0 else {
                verboseLog("[IdeviceGateway] syncLookupApp() app not found")
                throw IdeviceGatewayError(.serviceError, reason: "App not found: \(appId)")
            }

            let plistArray = resultPtr.assumingMemoryBound(to: plist_t?.self)
            var container = ""
            var bundlePath = ""
            var version = "1.0"
            var executableName: String? = nil

            for i in 0..<outLen {
                guard let plistVal = plistArray[i] else { continue }

                if let p = plist_dict_get_item(plistVal, "Container"), let s = self.getRustPlistString(p), !s.isEmpty {
                    container = s
                }
                if let p = plist_dict_get_item(plistVal, "Path"), let s = self.getRustPlistString(p), !s.isEmpty {
                    bundlePath = s
                }
                if let p = plist_dict_get_item(plistVal, "CFBundleExecutable"), let s = self.getRustPlistString(p) {
                    executableName = s
                }
                if let p = plist_dict_get_item(plistVal, "CFBundleVersion"), let s = self.getRustPlistString(p), !s.isEmpty {
                    version = s
                } else if let p = plist_dict_get_item(plistVal, "CFBundleShortVersionString"), let s = self.getRustPlistString(p), !s.isEmpty {
                    version = s
                }
            }
            free(outResult)

            if container.isEmpty || bundlePath.isEmpty {
                debugLog("[IdeviceGateway] syncLookupApp() container or bundlePath is empty")
                throw IdeviceGatewayError(.serviceError, reason: "Failed to resolve app info for \(appId)")
            }
            return InstalledAppInfo(bundleID: appId, path: bundlePath, version: version, container: container, executableName: executableName)
        }
    }

    /// The device's own installation-proxy record for one app, as a Swift value.
    ///
    /// A backup's `FactoryInfo` is where the host tells the device which app
    /// containers it wants uploaded, and the entry it expects under
    /// `Applications` is shaped exactly like the one the device just handed us
    /// from `installation_proxy`.  This forwards that record verbatim instead of
    /// composing one (`Container` + `ApplicationSINF` + `iTunesMetadata` +
    /// `PlaceholderIcon`): the shape is the device's contract, and a hand-built
    /// entry would have to be re-measured against every iOS release.
    private func syncAppFactoryEntry(bundleId: String) throws -> [String: Any] {
        debugLog("[IdeviceGateway] syncAppFactoryEntry() called, appId: \(bundleId)")
        return try performWithEitherService(
            connectRP: installation_proxy_connect_rsd,
            connectLockdown: installation_proxy_connect,
            cleanup: installation_proxy_client_free,
            serviceName: "instproxy"
        ) { client in
            var outResult: UnsafeMutableRawPointer? = nil
            var outLen: Int = 0
            try bundleId.withCString { appPtr in
                var bundleIds: [UnsafePointer<Int8>?] = [appPtr]
                let err = installation_proxy_get_apps(client, nil, &bundleIds, 1, &outResult, &outLen)
                if let err = err {
                    let msg = self.getErrorMessage(from: err)
                    defer { idevice_error_free(err) }
                    throw IdeviceGatewayError(.serviceError,
                                              reason: "Failed to look up \(bundleId), error: (\(msg))")
                }
            }
            guard let resultPtr = outResult, outLen > 0 else {
                throw IdeviceGatewayError(.serviceError,
                                          reason: "The device does not list \(bundleId).")
            }
            let plistArray = resultPtr.assumingMemoryBound(to: plist_t?.self)
            var fallback: [String: Any]?
            for index in 0..<outLen {
                guard let node = plistArray[index], let entry = self.plistNodeToDictionary(node) else {
                    continue
                }
                if let identifier = entry["CFBundleIdentifier"] as? String, identifier == bundleId {
                    free(outResult)
                    return entry
                }
                // `get_apps` answers with whatever it found, so a miss can come
                // back as a different app's record. Only the identifier above
                // proves the match; this is the shape for the log when it fails.
                fallback = entry
            }
            free(outResult)
            if let fallback {
                let identifier = fallback["CFBundleIdentifier"] as? String ?? "<none>"
                throw IdeviceGatewayError(.serviceError,
                                          reason: "The device answered for \(identifier), not \(bundleId).")
            }
            throw IdeviceGatewayError(.serviceError,
                                      reason: "The device returned no record for \(bundleId).")
        }
    }

    /// A `FactoryInfo` listing exactly the given app containers.
    ///
    /// Takes ownership of the result through the caller's `defer { plist_free }`,
    /// the same contract `skipAppContainers`' empty dictionary has.
    private func factoryInfo(applications: [String: [String: Any]]) -> plist_t? {
        let info = plist_new_dict()
        let apps = plist_new_dict()
        for (bundleId, entry) in applications {
            guard let node = plistNode(from: entry) else {
                debugLog("[IdeviceGateway] factoryInfo: \(bundleId) could not be converted to a plist")
                continue
            }
            plist_dict_set_item(apps, bundleId, node)
        }
        plist_dict_set_item(info, "Applications", apps)
        // The stock factory info carries this list beside the dictionary, and the
        // reference sets it too (`_add_posterboard_container`).
        let installed = plist_new_array()
        for bundleId in applications.keys {
            plist_array_append_item(installed, plist_new_string(bundleId))
        }
        plist_dict_set_item(info, "Installed Applications", installed)
        return info
    }

    /// A Foundation value as a `plist_t`, recursively.  The inverse of
    /// `plistNodeToDictionary`, for the one direction that did not exist yet.
    ///
    /// Booleans are picked out by their CoreFoundation type rather than by
    /// `as? Bool`: a plist integer is an `NSNumber`, and `NSNumber(1) as? Bool`
    /// is `true` — which would turn every 1 in a device record into a boolean.
    ///
    /// **`Date` is deliberately not handled, and the reason is the linker.**
    /// `plist_new_date` is declared in the vendored `plist.h`, but the archive
    /// this app links — `libidevice_ffi.a`, see the `-lidevice_ffi` in the link
    /// line — does not export it; only `libimobiledevice.a` does, and that one
    /// is not linked at all (`nm -gU` on both).  Calling it compiles and then
    /// fails the build with `Undefined symbols … _plist_new_date`.  So an
    /// unrepresentable value is dropped **and logged** instead of guessed at:
    /// the record being forwarded is the device's own, and a field quietly
    /// missing from a factory info is worse than a line in the log.
    private func plistNode(from value: Any) -> plist_t? {
        switch value {
        case let text as String:
            return plist_new_string(text)
        case let data as Data:
            return data.withUnsafeBytes { buffer -> plist_t? in
                guard let base = buffer.baseAddress else { return plist_new_data("", 0) }
                return plist_new_data(base.assumingMemoryBound(to: CChar.self), UInt64(data.count))
            }
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return plist_new_bool(number.boolValue ? 1 : 0)
            }
            if CFNumberIsFloatType(number) {
                return plist_new_real(number.doubleValue)
            }
            return number.int64Value < 0
                ? plist_new_int(number.int64Value)
                : plist_new_uint(number.uint64Value)
        case let dictionary as [String: Any]:
            let node = plist_new_dict()
            for (key, item) in dictionary {
                guard let child = plistNode(from: item) else { continue }
                plist_dict_set_item(node, key, child)
            }
            return node
        case let array as [Any]:
            let node = plist_new_array()
            for item in array {
                guard let child = plistNode(from: item) else { continue }
                plist_array_append_item(node, child)
            }
            return node
        default:
            debugLog("[IdeviceGateway] plistNode: dropping a \(type(of: value)) value — the "
                     + "linked libplist has no exported constructor for it (see the note above)")
            return nil
        }
    }

    // MARK: - mobilebackup2 restore
    private func syncRestoreBackup(
        backupRoot: String,
        sourceIdentifier: String,
        shouldReboot: Bool,
        systemFiles: Bool,
        onProgress: (@Sendable (Double) -> Void)?,
        delegateLog: (@Sendable (String) -> Void)? = nil
    ) throws {
        debugLog("[IdeviceGateway] syncRestoreBackup() called, backupRoot: \(backupRoot), source: \(sourceIdentifier)")
        try performWithService(
            connect: mobilebackup2_connect_rsd,
            cleanup: mobilebackup2_client_free,
            serviceName: "mobilebackup2"
        ) { client in
            // A restore asks the host for file after file. Every "no" the host
            // answers with (missing file, unreadable file, refused rename) is a
            // `noteDelegateError`, and the device answers a refusal by waiting
            // or by failing the batch — but with `onEvent` nil those refusals
            // were never reported anywhere, so a restore that silently restored
            // nothing looked exactly like a restore that was merely slow.
            //
            // The device's own progress is the other half of that evidence, and
            // it is recorded here rather than merely forwarded: the completion
            // check after the exchange needs the final value, and `ctx` does not
            // expose one.
            let progressProbe = RestoreProgressProbe()
            let ctx = MobileBackup2BackupContext(
                onProgress: { overall in
                    progressProbe.note(overall)
                    onProgress?(overall)
                },
                onEvent: delegateLog)
            var delegate = makeRestoreDelegate(context: ctx)
            defer { withExtendedLifetime(ctx) {} }

            let options = plist_new_dict()
            defer { plist_free(options) }
            plist_dict_set_item(options, "RestoreShouldReboot", plist_new_bool(shouldReboot ? 1 : 0))
            plist_dict_set_item(options, "RestoreSystemFiles", plist_new_bool(systemFiles ? 1 : 0))

            let rootC = strdup(backupRoot)
            let sourceC = strdup(sourceIdentifier)
            defer {
                free(rootC)
                free(sourceC)
            }

            var response: plist_t? = nil
            let err = mobilebackup2_restore(client, rootC, sourceC, options, &delegate, &response)
            // Same ordering as the backup path: the host-side accounting is the
            // only evidence of what the device actually asked for and what the
            // host answered, so it goes out before any error is raised.
            delegateLog?(ctx.errorSummary())
            delegateLog?(ctx.commitSummary())
            // Files the device actually took, so "how much was restored" has a
            // number behind it even when the device's own percentage is the
            // thing that stopped early.
            delegateLog?(ctx.servedSummary())
            if let err = err {
                let msg = self.getErrorMessage(from: err)
                debugLog("[IdeviceGateway] syncRestoreBackup() mobilebackup2_restore failed: \(msg)")
                defer { idevice_error_free(err) }
                throw IdeviceGatewayError(.serviceError, reason: "Restore failed, error: (\(msg))")
            }
            // The device's own verdict has to be READ before the plist is freed.
            //
            // This used to be `safeFreePlist(response)` with nothing in between,
            // and that is how "the device stopped at 55% and the app reported
            // success" becomes possible: the FFI returns no IdeviceFfiError
            // whenever the exchange terminated at the protocol level, and a
            // restore the device abandoned part-way terminates just as cleanly
            // as one it finished. The only place that difference is stated is
            // this plist. Discarding it left the caller with nothing to check,
            // so "success" degenerated into "nothing threw".
            let verdict = self.deviceVerdict(from: response)
            delegateLog?(verdict.summaryLine)
            self.safeFreePlist(response)
            if let code = verdict.errorCode, code != 0 {
                throw IdeviceGatewayError(
                    .serviceError,
                    reason: "Restore did not complete: the device answered with error code \(code)"
                        + (verdict.errorDescription.map { " — \($0)" } ?? ""))
            }
            // No error code is NOT the same as "finished".  A restore the device
            // abandoned part-way answers without one, which is why the second,
            // independent signal has to be checked: the device's own progress
            // never reached the end.  Reporting success on the strength of "the
            // FFI did not throw" is what produced a 55 % restore labelled
            // "succeeded".
            let reached = progressProbe.lastPercent
            let served = ctx.servedFileCount()
            if reached < IdeviceGateway.restoreCompletionPercent {
                let shown = reached < 0 ? "never reported" : "\(Int(reached))%"
                let expected = Int(IdeviceGateway.restoreCompletionPercent)
                let verdictText = verdict.errorCode.map { "ErrorCode \($0)" } ?? "none"
                throw IdeviceGatewayError(
                    .serviceError,
                    reason: "Restore stopped short: the device ended the exchange at \(shown) "
                        + "(a completed restore reports \(expected)%), "
                        + "after taking \(served) file(s) from the host. "
                        + "device verdict: \(verdictText). "
                        + "Nothing threw, so this is not a transport failure — the device decided it was "
                        + "done. Check what the manifest offered against what the host actually has: "
                        + "the 'commit:' and 'delegate errors:' lines above are the host-side half.")
            }
            verboseLog("[IdeviceGateway] syncRestoreBackup() mobilebackup2_restore completed")
        }
    }

    // MARK: - mobilebackup2 backup

    /// Creates a device backup via mobilebackup2.
    ///
    /// - Parameters:
    ///   - backupRoot: Root directory; the backup is written to `backupRoot/<sourceIdentifier>/`.
    ///   - sourceIdentifier: Device UDID backing up (and used as the target).
    ///   - factoryInfo: Optional plist sent as the top-level `FactoryInfo` sibling of
    ///     Options (e.g. `{"Applications": {}}` to skip app containers for a
    ///     protective backup). Pass nil for a full backup. Takes ownership.
    ///   - shouldPreserve: Optional mid-stream filter; `(device_name, file_name) -> Bool`.
    ///     Files for which it returns false are drained and never written to disk.
    ///   - onProgress: Optional progress callback (0-100).
    ///   - delegateLog: Optional diagnostic sink for the host-side delegate
    ///     decisions (commit/move accounting). Without it those decisions are
    ///     invisible in the app log.
    /// - Returns: The final device response plist (an `[String: Any]` view), as a convenience.
    @discardableResult
    private func syncBackupBackup(
        backupRoot: String,
        sourceIdentifier: String,
        factoryInfo: plist_t?,
        shouldPreserve: (@Sendable (String, String) -> Bool)? = nil,
        onProgress: (@Sendable (Double) -> Void)? = nil,
        delegateLog: (@Sendable (String) -> Void)? = nil
    ) throws -> [String: Any] {
        debugLog("[IdeviceGateway] syncBackupBackup() called, backupRoot: \(backupRoot)")
        return try performWithService(
            connect: mobilebackup2_connect_rsd,
            cleanup: mobilebackup2_client_free,
            serviceName: "mobilebackup2"
        ) { client in
            let ctx = MobileBackup2BackupContext(
                onProgress: onProgress,
                shouldPreserve: shouldPreserve,
                onEvent: delegateLog,
                backupRoot: backupRoot
            )
            var delegate = makeRestoreDelegate(context: ctx)
            defer { withExtendedLifetime(ctx) {} }

            let options = plist_new_dict()
            defer { plist_free(options) }

            let rootC = strdup(backupRoot)
            let sourceC = strdup(sourceIdentifier)
            defer {
                free(rootC)
                free(sourceC)
            }

            var response: plist_t? = nil
            let err = mobilebackup2_backup(client, rootC, sourceC, options, factoryInfo, &delegate, &response)
            // Report the commit accounting before doing anything else: the
            // device ends the run with one DLMessageMoveItems batch, and a
            // shortfall there is what it reports as MBErrorDomain/104. These
            // numbers are the only host-side evidence of what happened.
            delegateLog?(ctx.commitSummary())
            // The 0-byte stand-ins for filtered payloads must outlive the whole
            // exchange: the device validates the backup tree against the
            // Manifest.db it uploaded before it answers, and a payload that is
            // missing there ends the run with MBErrorDomain/205 "Manifest
            // references files not in backup". Only now is it safe to remove
            // them (pymobiledevice3's `cleanup_discarded_files()` runs in the
            // same place — a `finally` right after `dl_loop()`).
            let standInsRemoved = ctx.cleanupPlaceholders()
            delegateLog?(ctx.placeholderSummary(removed: standInsRemoved))
            if let err = err {
                let msg = self.getErrorMessage(from: err)
                debugLog("[IdeviceGateway] syncBackupBackup() mobilebackup2_backup failed: \(msg)")
                defer { idevice_error_free(err) }
                throw IdeviceGatewayError(.serviceError, reason: "Backup failed, error: (\(msg))")
            }
            var dict: [String: Any] = [:]
            if let response = response {
                dict = (self.plistNodeToDictionary(response) ?? [:])
                self.safeFreePlist(response)
            }
            verboseLog("[IdeviceGateway] syncBackupBackup() mobilebackup2_backup completed")
            return dict
        }
    }
}

// Async FFI Dispatcher Extensions
extension IdeviceGateway {
    public func start(pairingFileContent: String) async throws {
        try await withFFIDispatch {
            try self.syncStart(pairingFileContent: pairingFileContent)
        }
    }

    public func fetchUDID() async throws -> String? {
        try await withFFIDispatch {
            try self.syncFetchUDID()
        }
    }

    public func getLockdownValue(key: String) async throws -> String? {
        try await withFFIDispatch {
            try self.syncGetLockdownValue(key: key)
        }
    }

    /// Boolean lockdown read from an explicit domain.
    ///
    /// `getLockdownValue(key:)` cannot express this for two independent reasons:
    /// it passes a NULL domain (so domain-scoped keys such as
    /// `com.apple.mobile.backup / WillEncrypt` are not visible at all), and it
    /// reads through `plist_get_string_val`, which does nothing on a
    /// PLIST_BOOLEAN node and therefore returns nil.
    ///
    /// Use this for the backup-encryption precondition: with "Encrypted Local
    /// Backup" on, the device hands the host an ENCRYPTED Manifest.db, while
    /// the PoC rewrites it with bare sqlite3.
    public func getLockdownBool(key: String, domain: String) async throws -> Bool? {
        try await withFFIDispatch {
            try self.syncGetLockdownBool(key: key, domain: domain)
        }
    }

    public func installProvisioningProfile(profile: Data) async throws {
        try await withFFIDispatch {
            try self.syncInstallProvisioningProfile(profile: profile)
        }
    }

    public func removeProvisioningProfile(id: String) async throws {
        try await withFFIDispatch {
            try self.syncRemoveProvisioningProfile(id: id)
        }
    }

    public func removeApp(bundleId: String) async throws {
        try await withFFIDispatch {
            try self.syncRemoveApp(bundleId: bundleId)
        }
    }

    public func sendIpaAfc(bundleId: String, ipaBytes: Data) async throws {
        try await withFFIDispatch {
            try self.syncsendIpaAfc(bundleId: bundleId, ipaBytes: ipaBytes)
        }
    }

    public func sendAppBundleAfc(bundleId: String, appURL: URL) async throws {
        try await withFFIDispatch {
            try self.syncsendAppBundleAfc(bundleId: bundleId, appURL: appURL)
        }
    }

    public func installIpa(bundleId: String) async throws {
        try await withFFIDispatch {
            try self.syncInstallIpa(bundleId: bundleId)
        }
    }

    public func installAppBundle(bundleId: String, appName: String) async throws {
        try await withFFIDispatch {
            try self.syncInstallAppBundle(bundleId: bundleId, appName: appName)
        }
    }

    public func debugApp(appId: String) async throws {
        try await withFFIDispatch {
            try self.syncDebugApp(appId: appId)
        }
    }

    public func debugProcess(pid: UInt32) async throws {
        try await withFFIDispatch {
            try self.syncDebugProcess(pid: pid)
        }
    }

    public func dumpProfiles(docsPath: String) async throws -> String {
        try await withFFIDispatch {
            try self.syncDumpProfiles(docsPath: docsPath)
        }
    }

    public func performHeartbeat(interval: UInt64) async throws -> UInt64 {
        try await withFFIDispatch {
            var newInterval: UInt64 = 0
            try self.syncPerformHeartbeat(interval: interval, newInterval: &newInterval)
            return newInterval > 0 ? newInterval : 1000
        }
    }

    public func mountPersonalizedDdi(image: Data, trustcache: Data, manifest: Data) async throws {
        try await withFFIDispatch {
            try self.syncMountPersonalizedDdi(image: image, trustcache: trustcache, manifest: manifest)
        }
    }

    public func isDDIMounted() async throws -> Bool {
        try await withFFIDispatch {
            try self.syncIsDDIMounted()
        }
    }

    public func mountDeveloperImage(image: Data, signature: Data) async throws {
        try await withFFIDispatch {
            try self.syncMountDeveloperImage(image: image, signature: signature)
        }
    }

    public func startWirelessPair(
        hostName: String,
        hostModel: String,
        outPath: String,
        onReady: @escaping @Sendable (String, UInt16, [String: String]) -> Void,
        onPin: @escaping @Sendable (String) -> Void
    ) async throws -> PairedDeviceRecord {
        try await withFFIDispatch {
            try self.syncStartWirelessPair(
                hostName: hostName,
                hostModel: hostModel,
                outPath: outPath,
                onReady: onReady,
                onPin: onPin
            )
        }
    }

    public func triggerWirelessPair(
        targetIp: String,
        targetPort: UInt16,
        hostName: String,
        hostModel: String,
        outPath: String,
        onRequestPin: @escaping @Sendable (@escaping @Sendable (String) -> Void) -> Void
    ) async throws -> PairedDeviceRecord {
        try await withFFIDispatch {
            try self.syncTriggerWirelessPair(
                targetIp: targetIp,
                targetPort: targetPort,
                hostName: hostName,
                hostModel: hostModel,
                outPath: outPath,
                onRequestPin: onRequestPin
            )
        }
    }

    public func afcListDirectory(bundleId: String, path: String) async throws -> [String] {
        try await withFFIDispatch {
            try self.syncAfcListDirectory(bundleId: bundleId, path: path)
        }
    }

    public func afcReadFile(bundleId: String, path: String) async throws -> Data {
        try await withFFIDispatch {
            try self.syncAfcReadFile(bundleId: bundleId, path: path)
        }
    }

    public func afcGetFileInfo(bundleId: String, path: String) async throws -> (isDirectory: Bool, fileSize: Int64) {
        try await withFFIDispatch {
            try self.syncAfcGetFileInfo(bundleId: bundleId, path: path)
        }
    }

    public func wipeContainer(identifier: String) async throws {
        try await withFFIDispatch {
            try self.syncWipeContainer(identifier: identifier)
        }
    }

    public func lookupApp(bundleId: String) async throws -> InstalledAppInfo {
        try await withFFIDispatch {
            try self.syncLookupApp(appId: bundleId)
        }
    }

    /// The device's own `installation_proxy` record for one app.
    ///
    /// The payload a backup's `FactoryInfo` wants for each app container it is
    /// asking for; see `syncAppFactoryEntry` for why it is forwarded rather than
    /// composed.  Returned as a Swift dictionary because it crosses into app
    /// code, which has no business holding a `plist_t`.
    public func appFactoryEntry(bundleId: String) async throws -> [String: Any] {
        try await withFFIDispatch {
            try self.syncAppFactoryEntry(bundleId: bundleId)
        }
    }

    public func restoreBackup(
        backupRoot: String,
        sourceIdentifier: String,
        shouldReboot: Bool = false,
        systemFiles: Bool = true,
        onProgress: (@Sendable (Double) -> Void)? = nil,
        delegateLog: (@Sendable (String) -> Void)? = nil
    ) async throws {
        try await withFFIDispatch {
            try self.syncRestoreBackup(
                backupRoot: backupRoot,
                sourceIdentifier: sourceIdentifier,
                shouldReboot: shouldReboot,
                systemFiles: systemFiles,
                onProgress: onProgress,
                delegateLog: delegateLog
            )
        }
    }

    /// Creates a device backup via mobilebackup2 (async, off the main thread).
    ///
    /// - Parameters:
    ///   - backupRoot: Root directory; backup is written to `backupRoot/<sourceIdentifier>/`.
    ///   - sourceIdentifier: Device UDID.
    ///   - skipAppContainers: If true, sends `FactoryInfo` with an empty
    ///     `Applications` dict so the device skips app containers entirely
    ///     (protective backup).
    ///   - applications: App records to list in `FactoryInfo`'s `Applications`,
    ///     keyed by bundle id — the way to ask for a *specific* container (e.g.
    ///     PosterBoard's, whose sqlite database is otherwise never uploaded).
    ///     Each value is the device's own `appFactoryEntry(bundleId:)` record.
    ///     Takes precedence over `skipAppContainers` when non-empty.
    ///   - shouldPreserve: Optional mid-stream filter. False → payload drained, not stored.
    ///   - onProgress: Optional progress callback (0-100).
    /// - Returns: The device's final response plist as a dictionary.
    @discardableResult
    public func backupBackup(
        backupRoot: String,
        sourceIdentifier: String,
        skipAppContainers: Bool = false,
        applications: [String: [String: Any]]? = nil,
        shouldPreserve: (@Sendable (String, String) -> Bool)? = nil,
        onProgress: (@Sendable (Double) -> Void)? = nil,
        delegateLog: (@Sendable (String) -> Void)? = nil
    ) async throws -> [String: Any] {
        try await withFFIDispatch {
            var factoryInfo: plist_t? = nil
            if let applications, !applications.isEmpty {
                factoryInfo = self.factoryInfo(applications: applications)
            } else if skipAppContainers {
                factoryInfo = plist_new_dict()
                let apps = plist_new_dict()
                plist_dict_set_item(factoryInfo, "Applications", apps)
            }
            defer {
                if let factoryInfo { plist_free(factoryInfo) }
            }
            return try self.syncBackupBackup(
                backupRoot: backupRoot,
                sourceIdentifier: sourceIdentifier,
                factoryInfo: factoryInfo,
                shouldPreserve: shouldPreserve,
                onProgress: onProgress,
                delegateLog: delegateLog
            )
        }
    }
}
