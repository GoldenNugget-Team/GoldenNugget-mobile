import Foundation

/// Everything that reads `<Documents>/minimuxer.log` — the Rust `tracing` sink
/// installed by `GoldenNuggetEngine.enableRustFileLogging()`.
///
/// This file is the only host-side window into the protocol *and* the transport:
/// the mobilebackup2 DeviceLink conversation and jktcp's UDP retransmit logs land
/// in the same stream, which is why the readers below group lines by the layer
/// they identify instead of just tailing.
enum RustLog {
    /// Byte offset into `minimuxer.log` taken at the start of a run, so excerpts
    /// only contain this run's output.
    ///
    /// The file is append-only and shared by every run plus all RSD chatter, so
    /// a plain tail mostly shows whatever ran last — which is why the first
    /// diagnostics block came back with 25 lines of the probe itself and not one
    /// line about the backup.  Reading from a byte offset fixes that.
    private(set) static var mark: UInt64?

    static var url: URL { AppPaths.rustLog }

    static func size() -> UInt64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
    }

    /// Whether the log file exists at all.
    ///
    /// `size()` cannot answer that on its own: the Rust side creates the file
    /// with its first line, so "0 bytes" is a healthy sink that has not been
    /// written to yet — and reporting it as MISSING (as this used to) turns a
    /// quiet-but-working log into a false alarm, which is worse than silence
    /// because it sends the reader looking for a bug in the logger.
    static var fileExists: Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// Remember the log offset so the next excerpt covers only THIS run.
    @discardableResult
    static func markStart() -> UInt64 {
        let offset = size()
        mark = offset
        // Rebase the transport counters too: they are "this run" numbers, and
        // the previous run's out-of-order flood must not be counted as this
        // one's (a stale count would make the stall guard's crawl verdict look
        // satisfied before the tunnel has sent a single byte).
        WireCensus.shared.reset(from: offset)
        AppLog.write("rust log mark: byte \(offset) (excerpts from here cover only this run)")
        return offset
    }

    /// Result of the one-time Rust logger init (`idevice_init_logger`).
    /// `nil` = never attempted, 0 = file sink live, -2 = someone else won the
    /// race and the Rust log goes to console only (invisible on iOS).
    private(set) static var initResult: Int32?

    /// Record the outcome of `enableRustFileLogging()`.
    static func noteInitResult(_ rc: Int32) {
        initResult = rc
    }

    /// Status of the Rust log sink for the diagnostics block.
    ///
    /// Three states, because they mean different things to whoever reads the
    /// dump: no file at all (the sink is not coming up, and the parent directory
    /// says whether that is fixable), a 0-byte file (sink armed, the device has
    /// simply not produced a Rust line yet), and real bytes.
    static func status() -> String {
        let rc = initResult.map { String(describing: $0) } ?? "not called"
        let bytes = size()
        let state: String
        if !fileExists {
            let parent = url.deletingLastPathComponent()
            let parentExists = FileManager.default.fileExists(atPath: parent.path)
            state = "no file at \(url.path) (parent dir exists=\(parentExists))"
        } else if bytes == 0 {
            state = "0 B — sink armed, no Rust output yet"
        } else {
            state = "\(bytes) B"
        }
        return "minimuxer.log: init rc=\(rc), \(state)"
    }

    // MARK: - Keyword sets

    /// Lines worth reading in the Rust log, grouped by the layer they identify.
    ///
    /// Every entry is a literal from the actual upstream source, not a guess:
    /// `idevice/src/services/mobilebackup2.rs` (protocol layer) and
    /// `jktcp/src/{adapter,handle}.rs` (the userspace TCP stack the RSD tunnel
    /// runs on — the layer that produces "channel closed").
    static let verdictKeywords: [String] = [
        // ── mobilebackup2 protocol layer ────────────────────────────────────
        "DeviceLink version exchange",   // dl_version_exchange() entered
        "expected DLMessageVersionExchange",   // device sent something else
        "expected DLMessageDeviceReady",
        "Invalid DL message format",
        "mobilebackup2 version exchange",
        "Negotiated protocol version",
        "Version exchange failed",
        "Sending device link message",
        "Received DL message",
        "Backup start",                  // "Backup start failed with error: {error:?}"
        "Backup started successfully",
        "Restore start",                 // "Restore start failed with error: {error:?}"
        "Restore started successfully",   // the restore-side twin of the above:
                                          // without it, a restore failure shows
                                          // no phase marker at all
        "Backup info request failed",
        "Device requested file",         // device started streaming -> protocol got past auth
        "Failed to send file",           // our delegate could not serve a requested file
        "Unsupported DL message",
        "Multi status",
        "ErrorCode",
        // ── jktcp: the verdict on WHY the flow died ────────────────────────
        "RST on hp=",                    // device sent RST
        "timed out after",               // N retransmissions unACKed -> path dead
        "retransmitting",                // first sign of an unACKed write
        "channel closed",                // generic flow-gone (FIN / pump death)
        // `out-of-order seq=` is deliberately NOT in this list: an 84 s flood of
        // it is exactly what a lost-datagram stall looks like, and 3000 matching
        // lines would push the last real protocol event out of the excerpt's
        // tail slice. It is summarised in one line instead (see
        // `transportCensus`), so the excerpt keeps ending on "the last thing the
        // device actually said".
        "duplicate data seq=",           // the device retransmitted something already held
        // ── RSD / session / authorization layer ─────────────────────────────
        "StartService",
        "CreateSession",
        "EnableSession",
        "escrow",
        "InvalidHostID",
        "SessionInactive",
        "PasswordProtected",
        "PairingDialog",
        "GetProhibited",
        "Password",
    ]

    /// Log literals that only exist when a DeviceLink message actually moved.
    ///
    /// `Received DL message` is device → host, `Sending device link message` is
    /// host → device.  jktcp's `keep-alive on hp=` lines are deliberately absent:
    /// those come from a local timer and keep ticking on a dead flow, i.e. they
    /// are exactly the false "still alive" signal this must never produce.
    static let wireMarkers = ["Received DL message", "Sending device link message"]

    // MARK: - Excerpts

    /// Keyword-filtered slice of the Rust log — the evidence the app log cannot
    /// provide on its own.
    ///
    /// Shows the *head* as well as the *tail* of the matching lines: the head
    /// carries the request the device accepted (`Backup` vs `Restore`) and the
    /// handshake, the tail carries how the run died. A pure tail slice hides
    /// which of the two flows this even was.
    ///
    /// - Parameter since: byte offset to start from; defaults to the mark taken
    ///   by `markStart()` at the start of the run (nil = whole file).
    static func excerpt(
        maxLines: Int = 90,
        since: UInt64? = nil,
        keywords: [String] = RustLog.verdictKeywords
    ) -> String {
        let offset = since ?? mark
        // Read the whole file then drop the prefix: FileHandle's read-to-end API
        // was renamed in the iOS 27 SDK, and this log is a few hundred KB.
        guard let whole = try? Data(contentsOf: url) else {
            return "  (no readable minimuxer.log at \(url.path))"
        }
        let from = Int(min(offset ?? 0, UInt64(whole.count)))
        let data = whole.dropFirst(from)
        guard let text = String(data: data, encoding: .utf8) else {
            return "  (minimuxer.log unreadable from byte \(from))"
        }

        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        let lowered = keywords.map { $0.lowercased() }
        let hits = lines.filter { line in
            let low = line.lowercased()
            return lowered.contains { low.contains($0) }
        }

        var out = "  rust log excerpt"
        if offset != nil { out += " after byte \(from)" }
        out += ": \(lines.count) new lines, \(hits.count) match protocol/flow keywords"
        out += "\n" + messageHistogram(lines)
        // The DL census says whether the *protocol* moved; this says whether the
        // *tunnel* was delivering. They are different failures with the same
        // symptom ("hung at N %"): the run that motivated this census had 523 DL
        // messages and then 2954 out-of-order segments with 3 MB the tunnel could
        // not hand up, and "device→host: none" alone reads like a dead device.
        out += "\n" + WireCensus.transportLine(lines)
        guard !hits.isEmpty else {
            return out + "\n  (nothing matched — the Rust log never reached the mobilebackup2 or jktcp layer)"
        }
        if hits.count <= maxLines {
            return out + "\n" + hits.map { "  | \($0)" }.joined(separator: "\n")
        }
        // Split the budget between the two ends of the run.
        let headCount = max(20, maxLines / 3)
        let tailCount = maxLines - headCount
        let omitted = hits.count - headCount - tailCount
        let head = hits.prefix(headCount).map { "  | \($0)" }
        let tail = hits.suffix(tailCount).map { "  | \($0)" }
        return out + "\n" + (head
            + ["  | … \(omitted) matching lines omitted …"]
            + tail).joined(separator: "\n")
    }

    /// One-line census of the DeviceLink messages in the Rust log since the mark.
    ///
    /// This is what tells the two flows apart without reading anything else:
    /// `DLMessageCreateDirectory` / `DLMessageUploadFiles` / `DLMessageMoveItems`
    /// carry device → host data (backup), `DLMessageDownloadFiles` carries host →
    /// device data (restore), and `DLContentsOfDirectory` is the device scanning
    /// the host's copy (start-of-backup diffing, or the manifest-vs-tree check
    /// that raises MBErrorDomain/205).
    static func messageHistogram(_ lines: [Substring]) -> String {
        var received: [String: Int] = [:]
        var sent: [String: Int] = [:]
        for line in lines {
            if let range = line.range(of: "Received DL message: ") {
                let tag = line[range.upperBound...].prefix { !$0.isWhitespace }
                received[String(tag), default: 0] += 1
            } else if let range = line.range(of: "Sending device link message: ") {
                let tag = line[range.upperBound...].prefix { !$0.isWhitespace }
                sent[String(tag), default: 0] += 1
            }
        }
        let deviceSays = received.sorted { ($0.value, $1.key) > ($1.value, $0.key) }
            .prefix(6).map { "\($0.key)×\($0.value)" }.joined(separator: " ")
        let hostSays = sent.sorted { ($0.value, $1.key) > ($1.value, $0.key) }
            .prefix(6).map { "\($0.key)×\($0.value)" }.joined(separator: " ")
        return "  DL census — device→host: \(deviceSays.isEmpty ? "none" : deviceSays)"
            + " ; host→device: \(hostSays.isEmpty ? "none" : hostSays)"
    }

    /// Raw tail, used to prove the sink is live and to show an unclassified
    /// failure that no keyword matched.
    ///
    /// - Parameter since: byte offset to start from (a `markStart()` snapshot
    ///   confines it to the current run).  nil = whole file.
    static func tail(_ count: Int = 30, since: UInt64? = nil) -> String {
        guard let whole = try? Data(contentsOf: url) else {
            return "(no minimuxer.log at \(url.path))"
        }
        let from = Int(min(since ?? 0, UInt64(whole.count)))
        guard let text = String(data: whole.dropFirst(from), encoding: .utf8) else {
            return "(minimuxer.log unreadable from byte \(from))"
        }
        return text.split(separator: "\n").suffix(count).joined(separator: "\n")
    }

    // MARK: - Handshake silence

    /// True when the mobilebackup2 client is parked in the handshake *waiting for
    /// the device to speak first*.
    ///
    /// `dl_version_exchange()` is a pure receive: the device initiates with
    /// `["DLMessageVersionExchange", major, minor]`, our side answers
    /// `DLVersionsOK`, and only then does the device send `DLMessageDeviceReady`.
    /// So a Rust log whose last handshake line is "Starting DeviceLink version
    /// exchange" with no "Received DL message" after it means the client is
    /// blocked in `socket.read_exact` on a device that has said nothing at all.
    ///
    /// That distinction is what makes this check worth having: at this point the
    /// app has sent NOTHING on the DeviceLink channel, so no client-side change
    /// (including a patched FFI library) can be the cause — it can only be the
    /// device-side daemon.  The generic idle guard would take the full 120 s to
    /// notice the same thing, and would not say why.
    ///
    /// - Parameter offset: byte offset to read from; nil = the current run mark.
    static func deviceSilentAtHandshake(since offset: UInt64? = nil) -> Bool {
        let from = offset ?? mark
        guard let whole = try? Data(contentsOf: url) else { return false }
        let start = Int(min(from ?? 0, UInt64(whole.count)))
        guard let text = String(data: whole.dropFirst(start), encoding: .utf8) else { return false }
        guard let lastStart = text.range(of: "Starting DeviceLink version exchange",
                                         options: .backwards) else {
            return false
        }
        return !text[lastStart.upperBound...].contains("Received DL message")
    }
}
