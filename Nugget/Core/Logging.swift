import Foundation

/// A destination for one already-formatted log line.
///
/// The engine used to log through `GoldenNuggetEngine.shared.log`, which made every
/// helper that merely wanted to say something — the stage timer, the heartbeat,
/// the stall guard, the wire tailer — depend on the whole engine type.  A narrow
/// sink is what lets those helpers move out of it.
protocol LogSink: AnyObject, Sendable {
    func write(_ line: String)
}

/// `<Documents>/goldennugget.log` — append-only sink, rotated by dropping the older half.
///
/// The on-screen list alone is not enough: it only ever shows the tail and dies
/// with the process, so anything written there (the host-side delegate
/// decisions, the commit accounting, the stall verdict) would be unshareable.
/// A failed run has to be diagnosable from a file.
final class RotatingFileSink: LogSink, @unchecked Sendable {
    /// Byte cap; the sink is rotated by dropping the older half once exceeded.
    static let defaultLimit: UInt64 = 2 * 1024 * 1024

    private let url: URL
    private let limit: UInt64
    private let lock = NSLock()

    init(url: URL, limit: UInt64 = RotatingFileSink.defaultLimit) {
        self.url = url
        self.limit = limit
    }

    func write(_ line: String) {
        guard let data = (line + "\n").data(using: .utf8) else { return }
        lock.lock()
        defer { lock.unlock() }

        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try? data.write(to: url)
            return
        }
        let size = ((try? fm.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)
            .map { $0.uint64Value } ?? 0
        if size > limit, let existing = try? Data(contentsOf: url) {
            // Keep the newer half — a long run logs continuously and the tail is
            // the part that matters.
            try? existing.suffix(Int(limit / 2)).write(to: url)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }

    /// Current size on disk, for the share-sheet labels.
    func size() -> UInt64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
    }
}

/// Keeps the whole run in memory for the UI list and the diagnostics tail.
///
/// Unbounded on purpose: the engine is the producer and a run is bounded by
/// human patience, while the VIEW keeps its own 600-line window for rendering.
/// Capping here instead would silently truncate the diagnostics tail.
final class MemoryLogSink: LogSink, @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    var snapshot: [String] {
        lock.lock(); defer { lock.unlock() }
        return lines
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return lines.count
    }

    func tail(_ n: Int) -> String {
        lock.lock(); defer { lock.unlock() }
        return lines.suffix(n).joined(separator: "\n")
    }

    func reset() {
        lock.lock()
        lines.removeAll()
        lock.unlock()
    }

    func write(_ line: String) {
        lock.lock()
        lines.append(line)
        lock.unlock()
    }
}

/// Process-wide log fan-out: one `log()` call, N sinks, in order.
///
/// The sinks are installed by this type itself rather than by an owner, because
/// logging is the one dependency every other layer has — a helper that logs
/// before the engine exists must still land in `goldennugget.log`.
final class AppLog: @unchecked Sendable {
    static let shared = AppLog()

    let memory = MemoryLogSink()
    let file = RotatingFileSink(url: AppPaths.appLog)

    private let lock = NSLock()
    private var extraSinks: [LogSink] = []
    /// Only ever invoked on the main queue, which is what makes storing a
    /// non-`@Sendable` closure sound here — the class is `@unchecked Sendable`
    /// and the handler never crosses a thread boundary.
    private var uiHandler: ((String) -> Void)?

    private init() {}

    /// Route log lines to the UI list.  Set by the view; delivered on the main
    /// queue because the list is the only main-thread consumer.
    func setUIHandler(_ handler: ((String) -> Void)?) {
        lock.lock()
        uiHandler = handler
        lock.unlock()
    }

    /// Additional sinks (tests, a future in-app exporter).
    func add(_ sink: LogSink) {
        lock.lock()
        extraSinks.append(sink)
        lock.unlock()
    }

    func log(_ line: String) {
        // Console first: if a sink below throws or a lock is held by a wedged
        // thread, the line still reaches the device console.
        print(line)
        lock.lock()
        memory.write(line)
        file.write(line)
        for sink in extraSinks { sink.write(line) }
        let handler = uiHandler
        lock.unlock()
        guard let handler else { return }
        DispatchQueue.main.async { handler(line) }
    }
}

extension AppLog {
    /// Convenience for the many call sites that only want to emit a line.
    static func write(_ line: String) { shared.log(line) }
}

/// Old releases wrote complete pairing dictionaries into diagnostic files.
/// Remove only logs containing those secret field dumps before enabling the
/// append-only Rust sink, so an update cannot keep exporting previously leaked
/// credentials. Pairing records themselves are never touched.
///
/// **Nothing here throws, and nothing here may refuse.** The caller answered a
/// thrown error by leaving the Rust sink off for the rest of the session, so one
/// unreadable file was enough to silence the only protocol-level evidence this
/// app has — and it did exactly that. An 18.7 GB `minimuxer.log` could not be
/// loaded into memory, `enableRustFileLogging()` returned -1 on every launch
/// after it, and the 18.7 GB it occupied stayed on the volume the backup is
/// written to. That volume then had 74 GB free where the device wanted more, so
/// every backup returned "0 of 0 offered" with no Rust log to say why.
///
/// These files are diagnostic output the app owns and can afford to lose. When
/// one cannot be inspected, deleting it answers the secrets question *and* the
/// space question at once; keeping it does neither.
enum PairingLogPrivacy {
    /// Above this, a diagnostic file is a liability rather than evidence.
    ///
    /// The Rust sink caps itself at 64 MB per generation and keeps one
    /// generation (`minimuxer.log.1`), so a healthy pair is at most 128 MB and
    /// survives this pass untouched — the previous run's tail is still there to
    /// read after a relaunch. Anything above it came from a build without that
    /// cap; the file this exists for was 18.7 GB.
    static let maxBytes: UInt64 = 128 << 20

    /// What was removed or replaced, so the engine can say so in one line.
    struct Reclaim: Sendable, Equatable {
        var files: [String] = []
        var bytes: UInt64 = 0

        var isEmpty: Bool { files.isEmpty }

        var summary: String {
            let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
            return "\(files.joined(separator: ", ")) (\(size))"
        }
    }

    /// Field names that only ever appeared in the credential dumps of older
    /// builds. Quoted on purpose: today's builds log the same key *names* as a
    /// bare list ("keys: alt_irk, identifier, …") and that line must not wipe
    /// the log on every launch.
    private static let secretFields = ["\"private_key\"", "\"alt_irk\""]
        .map { Data($0.utf8) }

    private enum Verdict {
        case clean
        case secretDump
        case unreadable
    }

    /// Sanitise each file, deleting what cannot be inspected or is oversized.
    ///
    /// - Parameter limit: files above this are removed without being read. The
    ///   scan is the expensive part and a huge file is not evidence any more,
    ///   so the size check has to come first — that ordering is the whole fix.
    @discardableResult
    static func removeLegacyDumps(at urls: [URL], limit: UInt64 = maxBytes) -> Reclaim {
        let fm = FileManager.default
        var reclaim = Reclaim()

        for url in urls {
            guard let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? NSNumber,
                  size.uint64Value > 0 else { continue }

            if size.uint64Value > limit {
                if (try? fm.removeItem(at: url)) != nil {
                    reclaim.files.append(url.lastPathComponent)
                    reclaim.bytes += size.uint64Value
                }
                continue
            }

            switch scan(url) {
            case .clean:
                continue
            case .secretDump:
                // Replaced rather than deleted: the app log keeps appending, and
                // the notice is what a reader of that file needs to know.
                let notice = Data("Old diagnostic log removed because it contained pairing secrets.\n".utf8)
                if (try? notice.write(to: url, options: .atomic)) != nil {
                    reclaim.files.append(url.lastPathComponent)
                    reclaim.bytes += size.uint64Value - UInt64(min(notice.count, Int(size.uint64Value)))
                }
            case .unreadable:
                // Nothing here is worth keeping, and the bytes are exactly why it
                // could not be inspected — so they go, rather than disabling the
                // sink that would have explained the next failure.
                if (try? fm.removeItem(at: url)) != nil {
                    reclaim.files.append(url.lastPathComponent)
                    reclaim.bytes += size.uint64Value
                }
            }
        }
        return reclaim
    }

    /// Stream the file in 1 MB chunks, carrying the overlap a pattern could
    /// straddle. Memory stays bounded no matter how long the file is, which is
    /// the property `Data(contentsOf:)` did not have.
    ///
    /// The search is `Data.range(of:)`, not a byte-by-byte walk, and that is a
    /// launch-survival fix rather than a tidying: this pass runs from the first
    /// view body, on the main thread, before the shell is allowed to appear. A
    /// naive walk costs ~1 µs per byte in a Debug build — the 2026-10-29 build
    /// died on every launch with a scene-create watchdog kill after 19.96 s,
    /// its main thread inside `Array.contains(sequence:)` over a 54 MB
    /// `minimuxer.log` (58 s measured at -Onone by
    /// `scripts/check-log-privacy-scan.py`). The Rust sink is capped at 64 MB
    /// per generation with one generation kept, so this has to stay fast at
    /// 128 MB; Foundation's search does that in a fraction of a second.
    private static func scan(_ url: URL) -> Verdict {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .unreadable }
        defer { try? handle.close() }

        let overlap = (secretFields.map(\.count).max() ?? 1) - 1
        var carry = Data()
        while true {
            let chunk: Data
            do {
                guard let read = try handle.read(upToCount: 1 << 20), !read.isEmpty else {
                    return .clean
                }
                chunk = read
            } catch {
                return .unreadable
            }
            var buffer = carry
            buffer.append(chunk)
            if secretFields.contains(where: { buffer.range(of: $0) != nil }) {
                return .secretDump
            }
            carry = buffer.suffix(overlap)
        }
    }
}
