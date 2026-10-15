//
//  MobileBackup2Delegate.swift
//  IdeviceGateway
//
//  Swift C-compatible delegate + context for the mobilebackup2 restore FFI.
//  Membrane contract: buffers/errors returned to Rust are allocated with the
//  system allocator (malloc/free) because idevice frees both via its global
//  allocator (System == malloc on Apple platforms).
//

import Foundation
import Darwin
import IDevice

public struct InstalledAppInfo: Sendable {
    public let bundleID: String
    public let path: String
    public let version: String
    public let container: String
    public let executableName: String?

    public init(
        bundleID: String,
        path: String,
        version: String,
        container: String,
        executableName: String? = nil
    ) {
        self.bundleID = bundleID
        self.path = path
        self.version = version
        self.container = container
        self.executableName = executableName
    }
}

/// Opaque context forwarded to every mobilebackup2 delegate callback.
public final class MobileBackup2BackupContext: @unchecked Sendable {
    let onProgress: (@Sendable (Double) -> Void)?
    /// Optional mid-stream backup filter. When set, files streamed by the
    /// device during backup are stored only if this returns true; otherwise
    /// their payload is drained and never written to disk.
    ///
    /// This flag is also the *licence* to skip a missing source during the
    /// final commit (see `mb2_rename`): only a filtered run can legitimately
    /// have files that the device staged but the host never wrote.
    let shouldPreserve: (@Sendable (String, String) -> Bool)?
    /// Optional diagnostic sink, so the host-side delegate decisions land in the
    /// app's own log instead of being invisible (they are the only place where
    /// the host can disagree with the device).
    let onEvent: (@Sendable (String) -> Void)?
    /// Host-side backup root (`.../<udid>-partial`).  The device addresses every
    /// file it wants with a DL path relative to it, and Rust resolves those with
    /// `host_path(root, rel)` — the same normalising join `Self.hostPath` does.
    /// Needed to resolve a rejected payload back to the path the device will
    /// later look for.  `nil` disables placeholder materialisation.
    let backupRoot: String?
    var isCancelled = false

    private let handlesLock = NSLock()
    private var writeHandles: [String: UnsafeMutableRawPointer] = [:]

    // ── Placeholders for payloads the filter rejected ────────────────────────
    //
    // A filtered backup deliberately does not store photos/videos, but the
    // device still records them in the Manifest.db it uploads and still expects
    // to find them in the backup.  If they are simply absent, the device's own
    // consistency pass over the backup tree ends the run with
    // `MBErrorDomain/205 "Manifest references files not in backup"`.
    //
    // pymobiledevice3 solves this by touching a 0-byte placeholder for every
    // rejected payload while the exchange is live, then deleting them in
    // `cleanup_discarded_files()` once `dl_loop()` returns — i.e. *after* the
    // device has finished looking at the tree.  That is what this state does:
    // placeholder paths are recorded here, re-keyed when the device commits them
    // (Snapshot/… → shard path), and removed by `cleanupPlaceholders()`.
    private let placeholderLock = NSLock()
    private var placeholders: Set<String> = []
    private var placeholderCount = 0
    private var placeholderFailures = 0
    private var placeholderSamples: [String] = []

    // Commit (DLMessageMoveItems) accounting. The device ends every backup with
    // one move batch that renames each staged file from `Snapshot/...` to its
    // final shard path; a silent shortfall there is exactly what turns into
    // MBErrorDomain/104 on the device.
    private let commitLock = NSLock()
    private var movedCount = 0
    private var skippedCount = 0
    private var skippedSamples: [String] = []
    private var failedCount = 0
    private var failedSamples: [String] = []

    // ── Host-side failure accounting ─────────────────────────────────────────
    //
    // Every error a callback returns is a "no" handed back to the device, and
    // until now they were invisible: `mb2_write_chunk` could fail on every
    // chunk of a file and nothing anywhere recorded it. That matters because a
    // run that goes quiet right after the host refused to store something is
    // not a coincidence — the device is waiting for a file it thinks it will
    // get. Count them by kind so the app log can name them.
    private let errorLock = NSLock()
    private var delegateErrors = 0
    private var delegateErrorKinds: [String: Int] = [:]
    private var delegateErrorSamples: [String] = []
    private var reportedDiskSpace = false

    // ── Files the device actually took ───────────────────────────────────────
    //
    // A restore moves payloads host → device through `open_file_read`, and only
    // the FAILURES of that callback were ever counted.  So "how much was
    // restored" had no number behind it: the only progress the host had was the
    // device's own percentage, which is precisely the figure that cannot be
    // trusted when the device stops early (a 55 % restore and a 100 % restore
    // both end with a clean exchange and no error).  Counting the files the
    // device pulled turns that into a fact the log can state.
    private let servedLock = NSLock()
    private var servedFiles = 0
    private var servedBytes: UInt64 = 0

    func noteServedFile(bytes: Int) {
        servedLock.lock()
        servedFiles += 1
        servedBytes += UInt64(max(0, bytes))
        servedLock.unlock()
    }

    func servedFileCount() -> Int {
        servedLock.lock()
        defer { servedLock.unlock() }
        return servedFiles
    }

    func servedSummary() -> String {
        servedLock.lock()
        let files = servedFiles
        let bytes = servedBytes
        servedLock.unlock()
        return "device pulled \(files) file(s) from the host (\(bytes / 1024) KB)"
    }

    func noteDelegateError(_ kind: String, _ detail: String) {
        errorLock.lock()
        delegateErrors += 1
        delegateErrorKinds[kind, default: 0] += 1
        let firstOfKind = delegateErrorKinds[kind] == 1
        if delegateErrorSamples.count < 6 { delegateErrorSamples.append("\(kind): \(detail)") }
        errorLock.unlock()
        if firstOfKind {
            reportEvent("delegate: \(kind) FAILED — \(detail) (this is the host refusing something the "
                + "device asked for; the device may stop the stream waiting on it)")
        }
    }

    func errorSummary() -> String {
        errorLock.lock()
        let total = delegateErrors
        let kinds = delegateErrorKinds
        let samples = delegateErrorSamples
        errorLock.unlock()
        guard total > 0 else { return "delegate errors: none" }
        let parts = kinds.sorted { ($0.value, $1.key) > ($1.value, $0.key) }
            .map { "\($0.key)×\($0.value)" }.joined(separator: " ")
        var line = "delegate errors: \(total) — \(parts)"
        if !samples.isEmpty { line += " e.g. \(samples.prefix(3).joined(separator: " | "))" }
        return line
    }

    /// Log the disk-space answer once, so the value the device acted on is not a
    /// mystery when a run dies mid-transfer.
    func reportDiskSpaceOnce(_ bytes: UInt64) {
        errorLock.lock()
        let first = !reportedDiskSpace
        reportedDiskSpace = true
        errorLock.unlock()
        guard first else { return }
        reportEvent(String(format: "host free space reported to the device: %.2f GB",
                           Double(bytes) / 1_073_741_824.0))
    }

    public init(
        onProgress: (@Sendable (Double) -> Void)? = nil,
        shouldPreserve: (@Sendable (String, String) -> Bool)? = nil,
        onEvent: (@Sendable (String) -> Void)? = nil,
        backupRoot: String? = nil
    ) {
        self.onProgress = onProgress
        self.shouldPreserve = shouldPreserve
        self.onEvent = onEvent
        self.backupRoot = backupRoot
    }

    // MARK: - Rejected-payload placeholders

    /// Mirror of the Rust side's `host_path(root, rel)`: append only ordinary
    /// path components (`""`, `.` and `..` are dropped, never applied), so the
    /// result is exactly the absolute path the device's DL path maps to.
    static func hostPath(root: String, relative: String) -> String {
        var base = root
        while base.hasSuffix("/"), base.count > 1 { base.removeLast() }
        var out = base
        for component in relative.split(separator: "/") {
            if component.isEmpty || component == "." || component == ".." { continue }
            out += "/" + component
        }
        return out
    }

    /// Materialise the 0-byte placeholder for a payload the filter rejected.
    ///
    /// Never truncates: if something already lives at that path the device (or a
    /// previous attempt) put it there, and clobbering it would lose real data.
    /// Returns the absolute path when the placeholder is (now) on disk.
    @discardableResult
    func noteRejectedPayload(fileName: String) -> String? {
        guard let root = backupRoot else { return nil }
        let path = Self.hostPath(root: root, relative: fileName)
        let fm = FileManager.default
        let parent = (path as NSString).deletingLastPathComponent
        if !parent.isEmpty, !fm.fileExists(atPath: parent) {
            do {
                try fm.createDirectory(atPath: parent, withIntermediateDirectories: true)
            } catch {
                placeholderLock.lock()
                placeholderFailures += 1
                placeholderLock.unlock()
                reportEvent("placeholder: cannot create \(parent) for \(fileName) — "
                    + "\(error.localizedDescription); the device may reject the backup at the end "
                    + "(\"Manifest references files not in backup\")")
                return nil
            }
        }
        if !fm.fileExists(atPath: path), !fm.createFile(atPath: path, contents: nil) {
            placeholderLock.lock()
            placeholderFailures += 1
            placeholderLock.unlock()
            reportEvent("placeholder: cannot create \(path) for \(fileName)")
            return nil
        }

        placeholderLock.lock()
        let isNew = placeholders.insert(path).inserted
        if isNew { placeholderCount += 1 }
        let count = placeholderCount
        let firstFive = placeholderSamples.count < 5
        if firstFive {
            placeholderSamples.append((path as NSString).lastPathComponent)
        }
        placeholderLock.unlock()

        if isNew, firstFive || count % 200 == 0 {
            reportEvent("placeholder: #\(count) \((path as NSString).lastPathComponent) — 0-byte stand-in "
                + "for a payload the filter drained (removed once the device finishes its tree check)")
        }
        return path
    }

    /// The device's commit renamed a staged file; keep the placeholder's identity
    /// aligned with it (Snapshot/… → shard path), exactly like
    /// pymobiledevice3's `_move_discarded_files`.
    func renamePlaceholder(from source: String, to destination: String) {
        placeholderLock.lock()
        let matched = placeholders.remove(source) != nil
        if matched { placeholders.insert(destination) }
        placeholderLock.unlock()
    }

    func copyPlaceholder(from source: String, to destination: String) {
        placeholderLock.lock()
        if placeholders.contains(source) { placeholders.insert(destination) }
        placeholderLock.unlock()
    }

    /// The device asked for the path to be removed — it is nobody's business
    /// any more.
    func forgetPlaceholder(_ path: String) {
        placeholderLock.lock()
        placeholders.remove(path)
        placeholderLock.unlock()
    }

    /// Delete every placeholder (and the now-empty directories they left behind).
    ///
    /// MUST run only after `mobilebackup2_backup` has returned: while the exchange
    /// is live the device still validates the backup tree against the manifest it
    /// uploaded, and the placeholders are what keep that check satisfied.  Safe on
    /// the failure path too — the reference implementation cleans up in a
    /// `finally` for the same reason.
    @discardableResult
    func cleanupPlaceholders() -> Int {
        placeholderLock.lock()
        let paths = placeholders
        placeholders.removeAll()
        placeholderLock.unlock()
        guard let root = backupRoot, !paths.isEmpty else { return 0 }

        var base = root
        while base.hasSuffix("/"), base.count > 1 { base.removeLast() }
        let fm = FileManager.default
        var removed = 0
        // Deepest first: a parent can only become empty after its children went.
        for path in paths.sorted(by: { $0.split(separator: "/").count > $1.split(separator: "/").count }) {
            if fm.fileExists(atPath: path) {
                do { try fm.removeItem(atPath: path); removed += 1 } catch { /* left for the next run */ }
            }
            var parent = (path as NSString).deletingLastPathComponent
            while parent.count > base.count, parent.hasPrefix(base) {
                let contents = (try? fm.contentsOfDirectory(atPath: parent)) ?? []
                guard contents.isEmpty else { break }
                do { try fm.removeItem(atPath: parent) } catch { break }
                parent = (parent as NSString).deletingLastPathComponent
            }
        }
        return removed
    }

    /// One line for the app log: what the filter did to the device's view of the
    /// backup, and whether the stand-ins were cleaned up again.
    func placeholderSummary(removed: Int) -> String {
        placeholderLock.lock()
        let created = placeholderCount
        let failures = placeholderFailures
        let samples = placeholderSamples
        placeholderLock.unlock()
        guard created > 0 || failures > 0 else {
            return "filtered payloads: none — the device's manifest has nothing to dangle"
        }
        var line = "filtered payloads: \(created) kept visible as 0-byte placeholders, "
            + "\(removed) removed after the device finished"
        if !samples.isEmpty { line += " e.g. \(samples.joined(separator: ", "))" }
        if failures > 0 { line += ", \(failures) could NOT be materialised" }
        return line
    }

    func reportProgress(_ overall: Double) {
        onProgress?(overall)
    }

    func reportEvent(_ line: String) {
        onEvent?(line)
    }

    /// A move that succeeded (a staged file landed at its final path).
    func noteCommittedMove() {
        commitLock.lock()
        movedCount += 1
        commitLock.unlock()
    }

    /// A move the device asked for whose source does not exist because the
    /// `shouldPreserve` filter deliberately never wrote it.
    func noteSkippedMove(from source: String, to destination: String) {
        commitLock.lock()
        skippedCount += 1
        let first = skippedSamples.count < 5
        if first { skippedSamples.append("\((source as NSString).lastPathComponent) -> \((destination as NSString).lastPathComponent)") }
        let n = skippedCount
        commitLock.unlock()
        if first {
            reportEvent("commit: no payload on disk for \(destination) — rejected by the backup "
                + "filter, so the move is skipped (its Manifest.db row is pruned later)")
        } else if n % 50 == 0 {
            reportEvent("commit: \(n) filtered files skipped so far")
        }
    }

    /// A move that failed for a reason other than a filtered source.
    func noteFailedMove(from source: String, to destination: String, reason: String) {
        commitLock.lock()
        failedCount += 1
        if failedSamples.count < 5 { failedSamples.append("\(source) -> \(destination): \(reason)") }
        commitLock.unlock()
    }

    /// Emitted right after the device accepted (or rejected) the request, so the
    /// numbers are visible even when the run then fails.
    ///
    /// Carries the host-side failure count too: "the stream went quiet at 2 %"
    /// and "we refused eleven files before it went quiet" look identical from the
    /// outside, and only this line tells them apart.
    func commitSummary() -> String {
        commitLock.lock()
        let moved = movedCount, skipped = skippedCount, failed = failedCount
        let samples = skippedSamples
        let failures = failedSamples
        commitLock.unlock()
        var line = "commit: \(moved) file(s) moved into place"
        if skipped > 0 {
            line += ", \(skipped) skipped (no payload — rejected by the filter)"
            if !samples.isEmpty { line += " e.g. \(samples.joined(separator: ", "))" }
        }
        if failed > 0 {
            line += ", \(failed) FAILED"
            if !failures.isEmpty { line += " e.g. \(failures.joined(separator: " | "))" }
        }
        return line + " | " + errorSummary()
    }

    func handle(for path: String) -> UnsafeMutableRawPointer? {
        handlesLock.lock()
        defer { handlesLock.unlock() }
        return writeHandles[path]
    }

    func set(handle: UnsafeMutableRawPointer, for path: String) {
        handlesLock.lock()
        defer { handlesLock.unlock() }
        writeHandles[path] = handle
    }

    func clearHandle(for path: String) {
        handlesLock.lock()
        defer { handlesLock.unlock() }
        writeHandles.removeValue(forKey: path)
    }
}

// MARK: - Error construction (system-allocator compatible)

@inline(__always)
private func makeFFIError(_ message: String, code: Int32 = -1) -> UnsafeMutablePointer<IdeviceFfiError> {
    let size = MemoryLayout<IdeviceFfiError>.size
    let raw = malloc(size)
    memset(raw, 0, size)
    let error = raw!.assumingMemoryBound(to: IdeviceFfiError.self)
    error.pointee = IdeviceFfiError(code: code, sub_code: 0, message: strdup(message)) 
    return error
}

/// Build an error AND record that the host refused the device something.
///
/// Use this for every callback failure: the returned error tells the device,
/// the record tells the app log. Without the record a mid-stream refusal is
/// indistinguishable from a device-side stall — both surface as "the stream
/// went quiet at N %".
@inline(__always)
private func fail(
    _ c: MobileBackup2BackupContext?,
    _ kind: String,
    _ message: String,
    code: Int32 = -1
) -> UnsafeMutablePointer<IdeviceFfiError> {
    c?.noteDelegateError(kind, message)
    return makeFFIError(message, code: code)
}

@inline(__always)
private func context(_ ctx: UnsafeMutableRawPointer?) -> MobileBackup2BackupContext? {
    guard let ctx = ctx else { return nil }
    return Unmanaged<MobileBackup2BackupContext>.fromOpaque(ctx).takeUnretainedValue()
}

// MARK: - C delegate callbacks

private func mb2_get_free_disk_space(
    _ path: UnsafePointer<CChar>?,
    _ ctx: UnsafeMutableRawPointer?
) -> UInt64 {
    guard let c = context(ctx) else { return 0 }
    // The host-side backup root lives in the app's container, i.e. on the SAME
    // volume as the device's own data — so the true answer is this volume's free
    // space.  A hard-coded 1 TiB ("plenty of room") told the device there was
    // room that may not exist; when the volume filled, the writes below failed
    // and the payload silently went missing while the device kept streaming.
    let url = URL(fileURLWithPath: NSHomeDirectory())
    let capacity = (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
        .volumeAvailableCapacityForImportantUsage
    let bytes = capacity.flatMap { $0 > 0 ? UInt64($0) : nil } ?? (UInt64(1) << 40)
    c.reportDiskSpaceOnce(bytes)
    return bytes
}

private func mb2_open_file_read(
    _ path: UnsafePointer<CChar>?,
    _ outData: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?,
    _ outLen: UnsafeMutablePointer<UInt>?,
    _ ctx: UnsafeMutableRawPointer?
) -> UnsafeMutablePointer<IdeviceFfiError>? {
    guard let path = path, let outData = outData, let outLen = outLen, let c = context(ctx) else {
        return makeFFIError("invalid arguments")
    }
    let pathStr = String(cString: path)

    // Read straight into the malloc'd buffer the device will get.
    //
    // The previous version used `FileManager.contents(atPath:)` and then
    // `malloc` + `copyBytes`, so a payload was resident TWICE at peak (the
    // `Data` plus the FFI buffer) — a jetsam risk when the device asks for a
    // large video during a restore, which is exactly when this runs.  `open`/
    // `fstat`/`read` into the buffer keeps one copy and the same peak the device
    // sees, without the intermediate `Data`.
    let fd = open(pathStr, O_RDONLY)
    guard fd >= 0 else {
        return fail(c, "open_file_read", "no such file: \(pathStr) (errno \(errno))", code: -6)
    }
    defer { close(fd) }

    var st = stat()
    guard fstat(fd, &st) == 0, st.st_size >= 0 else {
        return fail(c, "open_file_read", "cannot stat \(pathStr) (errno \(errno))")
    }
    let size = Int(st.st_size)
    if size == 0 {
        c.noteServedFile(bytes: 0)
        outData.pointee = nil
        outLen.pointee = 0
        return nil
    }
    guard let buf = malloc(size) else {
        return fail(c, "open_file_read", "out of memory reading \(pathStr) (\(size) bytes)")
    }
    let dst = buf.assumingMemoryBound(to: UInt8.self)
    var filled = 0
    while filled < size {
        let n = read(fd, dst + filled, size - filled)
        if n < 0 {
            if errno == EINTR { continue }
            free(buf)
            return fail(c, "open_file_read", "read error on \(pathStr) (errno \(errno))")
        }
        if n == 0 { break }   // short file; use what we actually got
        filled += n
    }
    if filled == 0 {
        free(buf)
        c.noteServedFile(bytes: 0)
        outData.pointee = nil
        outLen.pointee = 0
        return nil
    }
    c.noteServedFile(bytes: filled)
    outData.pointee = dst
    outLen.pointee = UInt(filled)
    return nil
}

private func mb2_create_file_write(
    _ path: UnsafePointer<CChar>?,
    _ ctx: UnsafeMutableRawPointer?
) -> UnsafeMutablePointer<IdeviceFfiError>? {
    guard let path = path, let c = context(ctx) else {
        return makeFFIError("invalid arguments")
    }
    let pathStr = String(cString: path)
    // Directories are handled by create_dir_all; Rust calls this for files only,
    // but a trailing slash means "directory" and there is nothing to open.
    guard pathStr.hasSuffix("/") == false else { return nil }
    let parent = (pathStr as NSString).deletingLastPathComponent
    if !parent.isEmpty, !FileManager.default.fileExists(atPath: parent) {
        try? FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
    }
    guard let f = fopen(pathStr, "wb") else {
        // Reporting success here (the old behaviour) is a promise we cannot keep:
        // every later write_chunk for this path fails, and the device — which was
        // told the file is open — keeps streaming into a file that never lands.
        return fail(c, "create_file_write",
                    "cannot open \(pathStr) for write (errno \(errno))")
    }
    c.set(handle: f, for: pathStr)
    return nil
}

private func mb2_write_chunk(
    _ path: UnsafePointer<CChar>?,
    _ data: UnsafePointer<UInt8>?,
    _ len: UInt,
    _ ctx: UnsafeMutableRawPointer?
) -> UnsafeMutablePointer<IdeviceFfiError>? {
    guard let path = path, let data = data, let c = context(ctx) else {
        return makeFFIError("invalid arguments")
    }
    let pathStr = String(cString: path)
    guard let rawHandle = c.handle(for: pathStr) else {
        return fail(c, "write_chunk", "no open write handle: \(pathStr)")
    }
    let f = rawHandle.assumingMemoryBound(to: FILE.self)
    let want = Int(len)
    let wrote = fwrite(data, 1, want, f)
    if wrote != want {
        // A short write used to be dropped on the floor: the payload ended up
        // truncated (or empty) while the device believed it had uploaded the
        // file, and the mismatch only surfaced later as a manifest/tree error.
        return fail(c, "write_chunk",
                    "wrote \(wrote) of \(want) bytes to \(pathStr) "
                    + "(errno \(errno)); the volume may be full")
    }
    return nil
}

private func mb2_close_file(
    _ path: UnsafePointer<CChar>?,
    _ ctx: UnsafeMutableRawPointer?
) -> UnsafeMutablePointer<IdeviceFfiError>? {
    guard let path = path, let c = context(ctx) else {
        return makeFFIError("invalid arguments")
    }
    let pathStr = String(cString: path)
    guard let rawHandle = c.handle(for: pathStr) else { return nil }
    c.clearHandle(for: pathStr)
    // fclose flushes: it is the last place a full disk can turn into a
    // truncated file, so its return value is worth the branch.
    guard fclose(rawHandle.assumingMemoryBound(to: FILE.self)) == 0 else {
        return fail(c, "close_file", "cannot flush \(pathStr) (errno \(errno))")
    }
    return nil
}

private func mb2_create_dir_all(
    _ path: UnsafePointer<CChar>?,
    _ ctx: UnsafeMutableRawPointer?
) -> UnsafeMutablePointer<IdeviceFfiError>? {
    guard let path = path, let c = context(ctx) else {
        return makeFFIError("invalid arguments")
    }
    let pathStr = String(cString: path)
    // Report the real outcome. Swallowing this with `try?` tells the device a
    // directory exists when it does not, and the failure then surfaces much
    // later as an unexplained move error during the commit. `createDirectory`
    // with `withIntermediateDirectories: true` succeeds when the directory is
    // already there, so this cannot produce false alarms.
    do {
        try FileManager.default.createDirectory(atPath: pathStr, withIntermediateDirectories: true)
    } catch {
        return fail(c, "create_dir_all", "mkdir -p \(pathStr): \(error.localizedDescription)")
    }
    return nil
}

private func mb2_remove(
    _ path: UnsafePointer<CChar>?,
    _ ctx: UnsafeMutableRawPointer?
) -> UnsafeMutablePointer<IdeviceFfiError>? {
    guard let path = path, let c = context(ctx) else {
        return makeFFIError("invalid arguments")
    }
    let pathStr = String(cString: path)
    let fm = FileManager.default
    // Whatever happens, this path is no longer a placeholder the cleanup has to
    // remember (pymobiledevice3's `_forget_discarded_files`).
    c.forgetPlaceholder(pathStr)
    // "already gone" *is* the postcondition of remove, so that stays a success.
    guard fm.fileExists(atPath: pathStr) else { return nil }
    do {
        try fm.removeItem(atPath: pathStr)
    } catch {
        return fail(c, "remove", "rm \(pathStr): \(error.localizedDescription)")
    }
    return nil
}

private func mb2_rename(
    _ from: UnsafePointer<CChar>?,
    _ to: UnsafePointer<CChar>?,
    _ ctx: UnsafeMutableRawPointer?
) -> UnsafeMutablePointer<IdeviceFfiError>? {
    guard let from = from, let to = to, let c = context(ctx) else {
        return makeFFIError("invalid arguments")
    }
    let fromStr = String(cString: from)
    let toStr = String(cString: to)
    let fm = FileManager.default

    // The destination's parent has to exist before the move. Rust does call
    // create_dir_all() for it first, but discards the result (`let _ =`), so do
    // it here as well and fail loudly if it really cannot be created.
    let destParent = URL(fileURLWithPath: toStr).deletingLastPathComponent().path
    if !destParent.isEmpty, !fm.fileExists(atPath: destParent) {
        do {
            try fm.createDirectory(atPath: destParent, withIntermediateDirectories: true)
        } catch {
            return fail(c, "rename", "cannot create \(destParent) for \(toStr): \(error.localizedDescription)")
        }
    }

    guard fm.fileExists(atPath: fromStr) else {
        // A filtered run used to have files the device staged but the host never
        // wrote — `shouldPreserve` returning false drained the payload instead of
        // storing it. Since `mb2_should_preserve` now drops a 0-byte placeholder
        // at that exact path, the move normally succeeds; this branch is the
        // remaining safety net (placeholder creation failed, or the device moved
        // something it never uploaded). Reporting it as an error aborts the whole
        // backup — Rust's `move_files_from_message` returns -1 on the first
        // failure — and the device reports `MBErrorDomain/104`.
        //
        // pymobiledevice3's device_link.move_items() skips a missing source the
        // same way whenever a preserve filter is active. The dangling Manifest.db
        // rows are then dropped by PoCEngine.pruneManifestDb(), which deletes
        // every row whose payload is absent from disk.
        if c.shouldPreserve != nil {
            c.forgetPlaceholder(fromStr)
            c.noteSkippedMove(from: fromStr, to: toStr)
            return nil
        }
        return fail(c, "rename", "no such file: \(fromStr)", code: -6)
    }

    if fm.fileExists(atPath: toStr) { try? fm.removeItem(atPath: toStr) }
    do {
        try fm.moveItem(atPath: fromStr, toPath: toStr)
    } catch {
        c.noteFailedMove(from: fromStr, to: toStr, reason: error.localizedDescription)
        return fail(c, "rename", "move \(fromStr) -> \(toStr): \(error.localizedDescription)")
    }
    // A placeholder the device just committed keeps its identity, so cleanup
    // removes it from its final path instead of the (now gone) staged one.
    c.renamePlaceholder(from: fromStr, to: toStr)
    c.noteCommittedMove()
    return nil
}

private func mb2_copy(
    _ src: UnsafePointer<CChar>?,
    _ dst: UnsafePointer<CChar>?,
    _ ctx: UnsafeMutableRawPointer?
) -> UnsafeMutablePointer<IdeviceFfiError>? {
    guard let src = src, let dst = dst, let c = context(ctx) else {
        return makeFFIError("invalid arguments")
    }
    let srcStr = String(cString: src)
    let dstStr = String(cString: dst)
    let fm = FileManager.default
    if fm.fileExists(atPath: dstStr) { try? fm.removeItem(atPath: dstStr) }
    do {
        try fm.copyItem(atPath: srcStr, toPath: dstStr)
    } catch {
        return fail(c, "copy", "copy \(srcStr) -> \(dstStr): \(error.localizedDescription)")
    }
    c.copyPlaceholder(from: srcStr, to: dstStr)
    return nil
}

private func mb2_exists(
    _ path: UnsafePointer<CChar>?,
    _ ctx: UnsafeMutableRawPointer?
) -> Bool {
    guard let path = path, context(ctx) != nil else { return false }
    return FileManager.default.fileExists(atPath: String(cString: path))
}

private func mb2_is_dir(
    _ path: UnsafePointer<CChar>?,
    _ ctx: UnsafeMutableRawPointer?
) -> Bool {
    guard let path = path, context(ctx) != nil else { return false }
    var isDir: ObjCBool = false
    _ = FileManager.default.fileExists(atPath: String(cString: path), isDirectory: &isDir)
    return isDir.boolValue
}

private func mb2_is_cancelled(
    _ ctx: UnsafeMutableRawPointer?
) -> Bool {
    context(ctx)?.isCancelled ?? false
}

private func mb2_on_progress(
    _ progress: UnsafePointer<Mobilebackup2BackupProgress>?,
    _ ctx: UnsafeMutableRawPointer?
) {
    guard let progress = progress, let c = context(ctx) else { return }
    c.reportProgress(progress.pointee.overall_progress)
}

private func mb2_should_preserve(
    _ deviceName: UnsafePointer<CChar>?,
    _ fileName: UnsafePointer<CChar>?,
    _ ctx: UnsafeMutableRawPointer?
) -> Bool {
    guard let c = context(ctx), let filter = c.shouldPreserve else { return true }
    let dn = deviceName.flatMap { String(cString: $0, encoding: .utf8) } ?? ""
    let fn = fileName.flatMap { String(cString: $0, encoding: .utf8) } ?? ""
    let keep = filter(dn, fn)
    if !keep {
        // Rust has already decided to drain this payload instead of storing it.
        // Leave a 0-byte stand-in at the path the device expects so its final
        // manifest-vs-tree pass does not end the run with MBErrorDomain/205;
        // cleanupPlaceholders() removes it once the exchange is over.
        c.noteRejectedPayload(fileName: fn)
    }
    return keep
}

// MARK: - Delegate builders

public func makeRestoreDelegate(
    context: MobileBackup2BackupContext
) -> Mobilebackup2BackupDelegateFFI {
    var delegate = Mobilebackup2BackupDelegateFFI()
    delegate.context = Unmanaged.passUnretained(context).toOpaque()
    delegate.get_free_disk_space = mb2_get_free_disk_space
    delegate.open_file_read = mb2_open_file_read
    delegate.create_file_write = mb2_create_file_write
    delegate.write_chunk = mb2_write_chunk
    delegate.close_file = mb2_close_file
    delegate.create_dir_all = mb2_create_dir_all
    delegate.remove = mb2_remove
    delegate.rename = mb2_rename
    delegate.copy = mb2_copy
    delegate.exists = mb2_exists
    delegate.is_dir = mb2_is_dir
    delegate.is_cancelled = mb2_is_cancelled
    delegate.on_progress = mb2_on_progress
    delegate.should_preserve = mb2_should_preserve
    return delegate
}