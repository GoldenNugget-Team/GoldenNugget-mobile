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
