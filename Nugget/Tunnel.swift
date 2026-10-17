import Darwin
import Foundation

// LocalDevVPN compatibility: detect whether a point-to-point tunnel with the
// minimuxer/LocalDevVPN addressing (iface 10.7.1.1, peer 10.7.0.1) is up.
// The tunnel transports lockdown traffic to the emulated network device, so
// the app must NOT start its own em_proxy WireGuard server when a native
// LocalDevVPN (NEPacketTunnelProvider-based) tunnel already provides the
// same loopback plumbing.
//
// The three addresses below are settings, not constants: a LocalDevVPN on a
// different subnet is a normal configuration, and before this was configurable
// the only way to use one was to rebuild the app with the constants edited.
enum Tunnel {
    /// UserDefaults keys, shared with the UI's `@AppStorage` bindings so the text
    /// fields and every reader below cannot disagree about the current values.
    enum Key {
        static let ifaceIP = "TunnelIfaceIP"
        static let peerIP = "TunnelPeerIP"
        static let port = "TunnelServicePort"
        static let prefixLength = "TunnelIfacePrefixLength"
    }

    static let defaultIfaceIP = "10.7.1.1"
    static let defaultPeerIP = "10.7.0.1"
    static let defaultServicePort: UInt16 = 62078
    /// Prefix length for the interface address.
    ///
    /// LocalDevVPN's "tunnel IP" field is a CIDR, and it rejects anything whose
    /// suffix is not 0...32 — so the peer/port pair does not belong there.  The
    /// app waits for the tunnel IP on an interface, and a VPN configured with
    /// anything else never produces it.
    static let defaultPrefixLength = 24

    private static var defaults: UserDefaults { .standard }

    // Every reader below goes through a validator and falls back to the default.
    // A half-typed value in a text field ("10.7.1." while the user is still
    // editing) must not become a 60 s wait for an interface that can never
    // appear — falling back keeps the probe honest, and the UI marks the field
    // red so the fallback is never silent for long.
    static var ifaceIP: String {
        isValidIPv4(defaults.string(forKey: Key.ifaceIP)) ?? defaultIfaceIP
    }

    static var peerIP: String {
        isValidIPv4(defaults.string(forKey: Key.peerIP)) ?? defaultPeerIP
    }

    static var servicePort: UInt16 {
        defaults.string(forKey: Key.port).flatMap(validPort) ?? defaultServicePort
    }

    /// Only used to render the copy-pasteable "what LocalDevVPN must be set to"
    /// line — the app never masks anything itself.
    static var ifacePrefixLength: Int {
        defaults.string(forKey: Key.prefixLength).flatMap(validPrefixLength)
            ?? defaultPrefixLength
    }

    /// True when any of the three differs from the shipped default, so the
    /// diagnostics block can say the addressing was overridden.
    static var isCustomised: Bool {
        ifaceIP != defaultIfaceIP || peerIP != defaultPeerIP
            || servicePort != defaultServicePort
    }

    static func resetToDefaults() {
        for key in [Key.ifaceIP, Key.peerIP, Key.port, Key.prefixLength] {
            defaults.removeObject(forKey: key)
        }
    }

    // MARK: - What the library says it resolved

    /// Addresses the Rust connection manager pushed into
    /// `ConnectionConfigBinding`.
    ///
    /// Those `setTunnel*IfaceIp` / `*PeerIp` / `*SubnetMask` closures are the
    /// library reporting which addresses it resolved out of the route table, and
    /// this app answered every one of them with `{ _ in }` — the answer was
    /// thrown away.  That is why "my VPN uses a different subnet" could not be
    /// settled from a dump: the app's own probe and the library's idea of the
    /// tunnel were both invisible, so there was nothing to compare.  Keeping them
    /// costs nothing and settles it.
    struct Reported: Equatable {
        var ifaceIP: String?
        var peerIP: String?
        var ifaceSubnetMask: String?
        var peerSubnetMask: String?
        var peerReachable: Bool?

        var isEmpty: Bool { self == Reported() }

        /// One line for the diagnostics block, or nil when the library never
        /// reported anything.
        var line: String? {
            guard !isEmpty else { return nil }
            var parts: [String] = []
            if let ifaceIP { parts.append("iface \(ifaceIP)\(ifaceSubnetMask.map { "/\($0)" } ?? "")") }
            if let peerIP { parts.append("peer \(peerIP)\(peerSubnetMask.map { "/\($0)" } ?? "")") }
            if let peerReachable { parts.append("peer reachable=\(peerReachable)") }
            return "tunnel as resolved by the connection manager: " + parts.joined(separator: ", ")
        }
    }

    private static let reportLock = NSLock()
    private static var storedReport = Reported()

    static var reported: Reported {
        reportLock.lock()
        defer { reportLock.unlock() }
        return storedReport
    }

    static func noteReported(_ update: (inout Reported) -> Void) {
        reportLock.lock()
        update(&storedReport)
        reportLock.unlock()
    }

    /// Called when a start attempt begins: the previous attempt's answers
    /// describe a tunnel that may not exist any more.
    static func resetReported() {
        reportLock.lock()
        storedReport = Reported()
        reportLock.unlock()
    }

    // MARK: - Validation

    /// `inet_pton` is the authority on what a probe can match: anything it
    /// rejects can never be an interface address, so it is not stored as one.
    static func isValidIPv4(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        var addr = sockaddr_in()
        return inet_pton(AF_INET, trimmed, &addr.sin_addr) == 1 ? trimmed : nil
    }

    static func validPort(_ value: String) -> UInt16? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        // UInt16's own init rejects anything that is not a number in range;
        // port 0 is rejected on top because connect() to it is never a tunnel.
        guard let port = UInt16(trimmed), port > 0 else { return nil }
        return port
    }

    static func validPrefixLength(_ value: String) -> Int? {
        guard let length = Int(value.trimmingCharacters(in: .whitespacesAndNewlines)),
              (0...32).contains(length) else { return nil }
        return length
    }

    /// The one line that says what a working tunnel is configured like.  Shown in
    /// the diagnostics block, under the tunnel fields and in the tunnel-failure
    /// alert, because the field LocalDevVPN gets wrong is the tunnel IP and the
    /// error it produces ("only allows a prefix length from 0 to 32") does not
    /// name the field.
    static var requirements: String {
        var line = "LocalDevVPN: tunnel IP \(ifaceIP)/\(ifacePrefixLength), "
            + "peer \(peerIP), port \(servicePort)"
        if isCustomised { line += " (custom)" }
        return line
    }

    // Enumerate interface addresses via getifaddrs and report whether the
    // LocalDevVPN interface IP is configured on any interface.
    static func isInterfaceUp(_ address: String = ifaceIP) -> Bool {
        configure().addresses.contains(address)
    }

    // Mirror SideStore's minimuxer pre-start bootstrap (NetworkObserverService
    // + probeVPNHandshake): the tunnel must be present AND actually route to
    // the emulated peer before core.start() is allowed to run. Our old Rust
    // lib hardcodes 10.7.0.1:62078 and never re-probes, so if start() runs
    // before the VPN routes, it fails (MinimuxerError.CreateDebug = error 3).
    // - Phase 1: wait until the LocalDevVPN iface IP is configured.
    // - Phase 2: TCP-probe the peer service port until it accepts a connect
    //            (this is exactly what minimuxer's test_device_connection and
    //            the em_proxy debug-client path do when start() runs).
    //
    // Each phase gets its own deadline.  They used to share one `start`, so a
    // tunnel whose interface appeared at 59 s had 1 s left to answer on the peer
    // port and failed the run it had actually passed.
    static func waitForTunnel(
        timeout: TimeInterval = 60,
        log: @escaping (String) -> Void = { _ in }
    ) -> Bool {
        // The loop polls every 500 ms, so an unthrottled wait wrote up to 120
        // identical lines per call — and with several waits in flight (every
        // pairing-file load spawns one) that buried the one line that says the
        // interface never appeared.  First poll, then every 5 s, then a summary.
        let logEvery: TimeInterval = 5
        var polls = 0
        var nextLogAt: TimeInterval = 0

        func waiting(_ what: String, _ elapsed: TimeInterval) {
            polls += 1
            guard elapsed >= nextLogAt else { return }
            nextLogAt = elapsed + logEvery
            log("tunnel: waiting for \(what)… (\(polls) poll(s), \(Int(elapsed))s of \(Int(timeout))s)")
        }

        let phase1Start = Date()
        while Date().timeIntervalSince(phase1Start) < timeout {
            if isInterfaceUp() { break }
            waiting("iface \(ifaceIP) to come up", Date().timeIntervalSince(phase1Start))
            usleep(500_000)
        }
        guard isInterfaceUp() else {
            log("tunnel: FAILED — iface \(ifaceIP) never appeared within \(Int(timeout))s "
                + "after \(polls) poll(s). \(requirements).")
            return false
        }
        log("tunnel: iface \(ifaceIP) up, probing \(peerIP):\(servicePort)…")

        polls = 0
        nextLogAt = 0
        let phase2Start = Date()
        while Date().timeIntervalSince(phase2Start) < timeout {
            if probePeer(timeout: 2.0) { return true }
            waiting("\(peerIP):\(servicePort) to accept a connection", Date().timeIntervalSince(phase2Start))
            usleep(500_000)
        }
        log("tunnel: FAILED — \(peerIP):\(servicePort) did not answer within \(Int(timeout))s "
            + "after \(polls) poll(s). The interface is up, so the VPN is connected but nothing "
            + "is serving lockdown on the peer port.")
        return false
    }

    // Non-blocking TCP connect to the minimuxer lockdown service port on the
    // tunnel peer. Returns true only when the connect completes successfully.
    static func probePeer(ip: String = peerIP, port: UInt16 = servicePort, timeout: TimeInterval = 2.0) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = UInt8(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, ip, &addr.sin_addr) == 1 else { return false }

        var flags = fcntl(fd, F_GETFL, 0)
        fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        let rc = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if rc == 0 { return true }
        if errno != EINPROGRESS { return false }

        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&pfd, 1, Int32(timeout * 1000)) == 1 else { return false }
        var soerr: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        _ = getsockopt(fd, SOL_SOCKET, SO_ERROR, &soerr, &len)
        return soerr == 0
    }

    // Compose a human-readable status line for the UI when a tunnel is active.
    static func describe() -> String {
        let info = configure()
        var found: [String] = []
        for a in [ifaceIP, peerIP] where info.addresses.contains(a) {
            found.append(a)
        }
        return found.isEmpty ? "tunnel not detected" : "tunnel detected (\(found.joined(separator: ", ")))"
    }

    private struct IfaceInfo {
        var addresses: Set<String> = []
    }

    private static func configure() -> IfaceInfo {
        var info = IfaceInfo()
        var ifaddr: UnsafeMutablePointer<ifaddrs>? = nil
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else {
            return info
        }
        defer { freeifaddrs(first) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = cursor {
            if let addr = cur.pointee.ifa_addr,
               addr.pointee.sa_family == UInt8(AF_INET) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                               &host, socklen_t(host.count), nil, 0,
                               NI_NUMERICHOST) == 0 {
                    info.addresses.insert(String(cString: host))
                }
            }
            cursor = cur.pointee.ifa_next
        }
        return info
    }
}