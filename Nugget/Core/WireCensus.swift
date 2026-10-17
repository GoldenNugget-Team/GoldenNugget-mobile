import Foundation

// jktcp transport health — the Rust log's second clock.
//
// The mobilebackup2 protocol rides on jktcp — a userspace TCP stack over UDP —
// so "did a DeviceLink message move?" is not the only question worth asking.
// This adds the one the tunnel-level failures hinge on: is the byte stream
// actually being delivered?

/// One reading of what the Rust transport layer did with the bytes.
struct RustWireSample: Sendable {
    /// `Received DL message` / `Sending device link message` lines: DeviceLink
    /// traffic that moved, in either direction.
    var dlMessages = 0
    /// jktcp `out-of-order seq=` lines. A handful is normal UDP reordering; a
    /// flood is the signature of a segment that never arrived.
    var outOfOrder = 0
    /// `expected=` of the newest such line: the next byte jktcp can hand
    /// upstream. It only moves when the device retransmits the missing range,
    /// which is why it is the delivery clock.
    var expected: UInt64?
    /// `seq=` of the newest such line: how far ahead of `expected` the device
    /// already is.
    var seq: UInt64?

    /// jktcp `duplicate data seq=` lines: the peer re-sent a range it had
    /// already sent, i.e. a retransmission — the ONLY thing that closes a hole.
    ///
    /// This is the counter that decides whether waiting can ever help, and it
    /// had to be measured before it could be trusted.  A crawl on 2026-09-19 sat
    /// for 88 s with 3,265,094 B held in the reorder buffer and produced
    /// **zero** of these: the peer never resent the missing range, so no amount
    /// of patience was going to unblock it.  "Out-of-order + a gap" on its own
    /// cannot tell "recovering slowly" from "never recovering" — the difference
    /// between waiting and rebuilding the connection.
    var retransmits = 0

    /// jktcp `held=false` lines: segments the reorder buffer had to REFUSE
    /// because its window was full.  Any non-zero value means the hole is wider
    /// than the buffer, which waiting cannot repair either.
    var heldDropped = 0

    /// jktcp `duplicate ACK for hp=` lines: the duplicate ACKs this side put on
    /// the wire for out-of-order data.  The retransmit counter says whether the
    /// peer is filling the hole; this says whether it was ever asked to.  A
    /// logged zero here with a standing gap means the hole is not the peer
    /// refusing to retransmit — it is us never asking, or the ask never landing.
    var duplicateAcks = 0

    /// Bytes the device has sent that jktcp still cannot deliver.
    var gap: UInt64? {
        guard let expected, let seq, seq > expected else { return nil }
        return seq - expected
    }
}

/// One poll's reading of the delivery clock, for the crawl verdict in
/// `StallGuard.run`.
struct DeliverySample {
    let at: Date
    let outOfOrder: Int
    let expected: UInt64?
    let gap: UInt64?
}

/// Incremental tailer over `minimuxer.log`.
///
/// Why incremental: the stall guard and the heartbeat both ask for these
/// numbers every few seconds, and the log grows fastest exactly when the tunnel
/// is failing (each lost-datagram retransmit writes a line). Re-reading and
/// re-scanning a 2 MB window per poll — millions of byte comparisons, on the
/// same device that is trying to drain a UDP tunnel — is load added precisely
/// when the tunnel is least able to absorb it. The file is append-only, so
/// remember where the last scan stopped and look only at what is new.
///
/// One shared instance is deliberate: the counters are monotonic, so several
/// callers asking "what now?" cost one scan between them, and each still sees
/// whether the number moved.
final class WireCensus: @unchecked Sendable {
    static let shared = WireCensus()

    /// Ceiling for a single read. A run that starts without a mark would
    /// otherwise read the whole (multi-MB) log on the main thread the first time
    /// the heartbeat ticks; skipping ahead is harmless because only "is the
    /// number rising" is ever asked of these counters.
    private static let maxChunk: UInt64 = 4 * 1024 * 1024

    private let lock = NSLock()
    private var offset: UInt64 = 0
    private var carry = Data()
    private var sample = RustWireSample()

    private init() {}

    /// Restart at `mark`: everything before it belongs to an earlier run, and
    /// carrying those counts over would make the crawl verdict fire on a tunnel
    /// that has not sent a byte yet.
    func reset(from mark: UInt64?) {
        lock.lock()
        defer { lock.unlock() }
        offset = mark ?? 0
        carry.removeAll(keepingCapacity: true)
        sample = RustWireSample()
    }

    /// Counters as of now, scanning only the bytes appended since the last call.
    func read() -> RustWireSample {
        lock.lock()
        defer { lock.unlock() }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: RustLog.url.path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value else { return sample }
        if size < offset {
            // Rotated or replaced — the old offset means nothing any more.
            offset = 0
            carry.removeAll(keepingCapacity: true)
            sample = RustWireSample()
        }
        guard size > offset else { return sample }
        if size - offset > Self.maxChunk { offset = size - Self.maxChunk }
        guard let handle = try? FileHandle(forReadingFrom: RustLog.url) else { return sample }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.read(upToCount: Int(size - offset)), !data.isEmpty
        else { return sample }
        offset += UInt64(data.count)

        var buffer = carry
        buffer.append(data)
        // A log line can straddle two reads, so only whole lines are parsed and
        // the remainder is carried into the next call.
        guard let lastNewline = buffer.lastIndex(of: 0x0A) else {
            carry = buffer
            return sample
        }
        carry = Data(buffer[buffer.index(after: lastNewline)...])
        if let text = String(data: Data(buffer[...lastNewline]), encoding: .utf8) {
            Self.absorb(text.split(separator: "\n"), into: &sample)
        }
        return sample
    }

    /// Count what the given log lines mean, transport-wise.
    ///
    /// Shared with the failure dump, which parses lines it already read rather
    /// than touching the live counters above.
    static func absorb(_ lines: [Substring], into sample: inout RustWireSample) {
        for line in lines {
            // `RustLog.wireMarkers` is the one place those literals are listed
            // (with the note on why jktcp's keep-alive is not among them).
            if RustLog.wireMarkers.contains(where: { line.contains($0) }) {
                sample.dlMessages += 1
            }
            // Counted before the out-of-order guard below, because neither line
            // matches it.  Together they are the whole difference between a hole
            // that is closing and one that is permanent.
            if line.contains("duplicate data seq=") {
                sample.retransmits += 1
            } else if line.contains("held=false") {
                sample.heldDropped += 1
            }
            if line.contains("duplicate ACK for hp=") {
                sample.duplicateAcks += 1
            }
            guard line.contains("out-of-order seq=") else { continue }
            sample.outOfOrder += 1
            if let value = number(after: "expected=", in: line) { sample.expected = value }
            if let value = number(after: "seq=", in: line) { sample.seq = value }
        }
    }

    /// `expected=83126912 hp=27735` → 83126912.
    ///
    /// The digits directly after the label: jktcp's lines are ASCII, and the
    /// label is unique within them.
    private static func number(after label: String, in line: Substring) -> UInt64? {
        guard let range = line.range(of: label) else { return nil }
        let digits = line[range.upperBound...].prefix { $0.isNumber }
        return digits.isEmpty ? nil : UInt64(digits)
    }

    // MARK: - Reporting

    /// Live wire counters for this run, from the shared incremental tailer.
    ///
    /// Reads only what was appended since the previous call, so the heartbeat
    /// and the stall guard can both ask as often as they like without turning
    /// into a log-sized scan each time.
    static func totals() -> RustWireSample {
        shared.read()
    }

    /// One line of tunnel health for the heartbeat and the diagnostics block.
    ///
    /// The jktcp half is the part that used to be invisible: "out-of-order ×N,
    /// M MB stuck behind an unfilled gap" is a stopped transport, while
    /// "0 DL messages, no out-of-order" is a device that has not spoken yet.
    /// Both look like a hung progress bar.
    static func healthLine() -> String {
        let s = totals()
        var line = "\(s.dlMessages) DL message(s) this run"
        if s.outOfOrder > 0 {
            line += ", jktcp out-of-order ×\(s.outOfOrder)"
            if let gap = s.gap, gap >= 64 * 1024 {
                line += String(format: ", %.1f MB stuck behind an unfilled gap",
                               Double(gap) / 1_048_576.0)
            }
            // The half that decides whether patience is the right answer at all.
            // Zero retransmissions means the hole cannot close by waiting.
            line += s.retransmits > 0
                ? ", peer retransmitted ×\(s.retransmits)"
                : ", peer has retransmitted NOTHING"
            line += s.duplicateAcks > 0
                ? ", jktcp sent ×\(s.duplicateAcks) duplicate ACK(s)"
                : ", jktcp sent no duplicate ACK(s)"
        }
        if s.heldDropped > 0 {
            line += ", \(s.heldDropped) segment(s) refused (reorder window full)"
        }
        return line
    }

    /// One line on what jktcp did with the bytes, from a line array the caller
    /// already read (so the failure dump does not disturb the live counters).
    ///
    /// Three states, three causes, one line each:
    /// no out-of-order lines → the tunnel never lost a datagram (look at the
    /// device instead); out-of-order lines with the byte position advancing →
    /// a hole appeared and was retransmitted (the stream survived); out-of-order
    /// lines with a gap that does not close → nothing is being handed up,
    /// which is what "stuck at 1 %" looks like from the inside.
    static func transportLine(_ lines: [Substring]) -> String {
        var sample = RustWireSample()
        absorb(lines, into: &sample)
        guard sample.outOfOrder > 0 else {
            return "  jktcp: 0 out-of-order segments — the tunnel delivered everything it received"
        }
        var line = "  jktcp: \(sample.outOfOrder) out-of-order segment(s)"
        if let gap = sample.gap {
            line += ", \(gap / 1024) KB stuck behind an unfilled gap"
            if let seq = sample.seq, let expected = sample.expected {
                line += " (device at byte \(seq), tunnel can only deliver up to \(expected))"
            }
        }
        // Whether the hole can still close.  This clause is the one that
        // separates "the peer is recovering, give it time" from "the peer is not
        // coming back for that range", and those two call for opposite actions.
        line += sample.retransmits > 0
            ? "; the peer re-sent \(sample.retransmits) range(s), so the gap is being worked on"
            : "; the peer has re-sent NOTHING — this gap does not close by waiting"
        line += sample.duplicateAcks > 0
            ? " (jktcp did put ×\(sample.duplicateAcks) duplicate ACK(s) on the wire, so the ask was made)"
            : " (jktcp sent no duplicate ACK(s) at all, so the peer was never asked to retransmit)"
        if sample.heldDropped > 0 {
            line += ". \(sample.heldDropped) segment(s) were refused (reorder window full), so part "
                + "of the stream was dropped rather than held"
        }
        return line
    }
}
