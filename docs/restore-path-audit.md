# Restore Path Audit: Slowdowns and Dropped Tasks

> **Status: all landed (2026-09-19).** The 6 main issues + the minor items are all
> changed; `scripts/typecheck.sh` reports **0 errors, and no new warnings**.
>
> One thing **left for you to verify locally**: three files under `Vendor/` were
> changed (`IdeviceGateway.swift`, `MinimuxerApi.swift`, `MobileBackup2Delegate.swift`),
> but `typecheck.sh` reads the already-built `.swiftmodule`, so the two call sites
> (`ProtectiveBackup.swift:115`, `RestoreRunner.swift:69`) report
> `extra argument 'cancellationRequested' in call` — this is a **phantom error**; one
> Xcode rebuild makes it disappear. I verified that **every other change is clean**
> by "temporarily commenting out those two arguments → 0 errors → restore".
> A real device build still needs you to run `scripts/build-ipa.sh` locally (SwiftPM
> manifest evaluation is blocked by the sandbox on my side).
>
> Along the way I also fixed a **toolchain bug**: `scripts/relink-core-sources.py` was
> previously **not repeatable**. On its first successful run it renamed the group from
> `Sparserestore` to `Core`, while `rewrite_group()` only recognised the old name, so
> **the second run died outright with `ValueError: substring not found`**. The
> consequences are subtle: the two build paths `Package.swift` and `project.pbxproj`
> diverge (SPM compiles, xcodebuild is missing one file). It now accepts both
> spellings, and running it twice is verified to produce identical output.

Audit scope: `Nugget/Core/*` (our own code) and `Vendor/MinimuxerGateway/idevice/*`
(a SideStore fork, so changes cost upstream merge effort). **`Vendor/MinimuxerSources/`
is a forwarding layer — changing a signature means changing both layers**
(`MinimuxerApi.swift:298/320` ↔ `IdeviceGateway.swift:2864/2896`).

Conclusion: **of the 6 issues, 3 are of the "dropped task / lost data" class, not
slowness**. Only 2 are actual slowdowns; the rest are reliability. Item by item below.

---

## Landed List

| # | Issue | Changed in |
|---|---|---|
| 1 | The cancellation flag was never wired up | New `Nugget/Core/InFlightCall.swift`; `MobileBackup2Delegate.swift` (inject `cancellationRequested`); `IdeviceGateway.swift` + `MinimuxerApi.swift` (add the parameter in both layers); `ProtectiveBackup.swift`, `RestoreRunner.swift` (pass `CancelFlag`) |
| 2 | Abandoned calls had no reaping gate | `StallGuard.swift` (enter/leave/noteAbandoned); `ChannelRecovery.swift` (bounded wait for drain before retrying); `PoCEngine.swift` (entry gate, and **before `clearCancel()`**) |
| 3 | Diagnostics tears down its own session | `Diagnostics.swift` (skip the session probes entirely when a call is in flight; a single snapshot replaces two full reads) |
| 4 | Handshake-silence detection re-read the whole log every 5 s | `WireCensus.swift` (two counters + `handshakeSilent`); `RustLog.swift` (`deviceSilentAtHandshake()` shrinks to one line, the `since:` parameter is deleted) |
| 5 | Pruning did a row-by-row `stat` + scanned into `Snapshot/` | `ManifestStore.swift` (`isShardName`, one walk of the shard tree, `removeOrphanPayloads(shards:keepIDs:)`, `PruneReport.stagingKept`) |
| 6 | `_keep` has no index | `ManifestStore.swift` (`createKeepTable` with a `PRIMARY KEY`) |
| 7 | Minor items | `RestoreRunner.swift` (defer-block timer), `MobileBackup2Delegate.swift` (`open_file_read` single copy, `setvbuf` 1 MiB), `Logging.swift` (batched async sink + `flush()` + `print` only under DEBUG), `GoldenNuggetView.swift` (stable log ids + batch trimming) |

---

## Overview

| # | Issue | Category | Severity | Location |
|---|---|---|---|---|
| 1 | The cancellation flag was never wired up, so Stop only stopped the waiting | Dropped task + concurrent write corruption | P0 | `MobileBackup2Delegate.swift:57` |
| 2 | Retrying an abandoned call with no reaping gate | Dropped task + use-after-free | P0 | `StallGuard.swift:267` → `ChannelRecovery.swift:73` |
| 3 | The diagnostics block calls a read that `invalidateConnection()`s, on the abandon path | Same (sabotaging itself) | P0 | `Diagnostics.swift:34` |
| 4 | Handshake-silence detection re-reads + decodes the whole log every 5 s | Slowdown | P1 | `RustLog.swift:248` |
| 5 | Prune does a row-by-row manifest `stat`; and it treats `Snapshot/` as a shard to scan | Slowdown + silent data deletion | P1 | `ManifestStore.swift:204/271` |
| 6 | `_keep` has no index + a `NOT IN` subquery | Slowdown | P2 | `ManifestStore.swift:222/245` |

Minor items (§7): the restore stage timer is not flushed on the throwing path,
`open_file_read` keeps the whole file resident in memory, `RotatingFileSink` does
open/stat/seek/write/close per line.

---

## 1. The cancellation flag was never wired up: `Stop` only stopped the "waiting", not the device-side operation

### Symptom

After pressing Stop: the log shows `⏹ stop requested`,
`⏹ <label>: cancelled by the user — abandoning the call`, but **the device-side
backup/restore is still running**. `GoldenNuggetView` then sets `running` back to false and the
user thinks it is over; if Run is clicked again right after, the

```swift
try? FileManager.default.removeItem(at: backupRoot)   // PoCEngine.swift:156 / 245
```

at the top of `runPoC` / `runPartialRestore` runs `rm -rf` on a directory that **Rust is
still writing to**.

### Root cause

`MobileBackup2BackupContext.isCancelled` is the only source of the value that Rust's
`is_cancelled` hook sees:

```swift
// MobileBackup2Delegate.swift:677
private func mb2_is_cancelled(_ ctx: UnsafeMutableRawPointer?) -> Bool {
    context(ctx)?.isCancelled ?? false
}
```

And a repo-wide grep shows that **`isCancelled` has exactly one declaration, one read,
and no writes at all**:

```
$ grep -rn "isCancelled" Vendor/MinimuxerGateway/ Vendor/MinimuxerSources/ Nugget/
MobileBackup2Delegate.swift:57:    var isCancelled = false          ← declaration
MobileBackup2Delegate.swift:680:    context(ctx)?.isCancelled ?? false ← read
```

`CancelFlag.shared.request()` is read only by `StallGuard`'s poll loop
(`StallGuard.swift:134`), and all it does is "give up waiting".
`MobileBackup2BackupContext` does not even know `CancelFlag` exists (the gateway does
not depend on the app layer, and that layering is right — which is why it has to be
injected at construction time rather than read from a global).

### Fix

**(a) Make cancellation an injected closure**
(`Vendor/MinimuxerGateway/idevice/MobileBackup2Delegate.swift`):

```swift
public final class MobileBackup2BackupContext: @unchecked Sendable {
    ...
    /// Polled by Rust's `is_cancelled` hook.
    ///
    /// Injected rather than read from a global: the gateway must stay
    /// independent of the app's `CancelFlag`, and a `Bool` stored here can never
    /// work — it would have to be written by whichever thread happens to hold
    /// the context, and nothing did.  That is why the Stop button only ever
    /// stopped the *waiting*: `mb2_is_cancelled` answered `false` forever and
    /// the device-side loop never learned to stop.
    private let cancellationRequested: @Sendable () -> Bool

    public init(
        onProgress: (@Sendable (Double) -> Void)? = nil,
        shouldPreserve: (@Sendable (String, String) -> Bool)? = nil,
        onEvent: (@Sendable (String) -> Void)? = nil,
        backupRoot: String? = nil,
        cancellationRequested: @escaping @Sendable () -> Bool = { false }
    ) {
        ...
        self.cancellationRequested = cancellationRequested
    }

    var isCancelled: Bool { cancellationRequested() }
}
```

All three construction sites have to pass it (`IdeviceGateway.swift:2553`, `2621`):

```swift
let ctx = MobileBackup2BackupContext(
    onProgress: onProgress,
    onEvent: delegateLog,
    backupRoot: backupRoot,
    cancellationRequested: cancellationRequested
)
```

**(b) Change both layers of the API together** (otherwise the call sites report
`extra argument 'cancellationRequested' in call`):

```swift
// IdeviceGateway.swift — restoreBackup / backupBackup / syncRestoreBackup / syncBackupBackup
public func restoreBackup(
    backupRoot: String,
    sourceIdentifier: String,
    shouldReboot: Bool = false,
    systemFiles: Bool = true,
    onProgress: (@Sendable (Double) -> Void)? = nil,
    delegateLog: (@Sendable (String) -> Void)? = nil,
    cancellationRequested: @escaping @Sendable () -> Bool = { false }
) async throws { ... }

// MinimuxerApi.swift:298 / 320 — same parameter, same forwarding
func restoreBackup(
    backupRoot: String,
    sourceIdentifier: String,
    shouldReboot: Bool = false,
    systemFiles: Bool = true,
    onProgress: ((Double) -> Void)? = nil,
    delegateLog: ((String) -> Void)? = nil,
    cancellationRequested: @escaping @Sendable () -> Bool = { false }
) async throws {
    try await gw.restoreBackup(..., cancellationRequested: cancellationRequested)
}
```

**(c) Pass the real flag at the call sites** (`RestoreRunner.swift:40`,
`ProtectiveBackup.swift:87`):

```swift
try await minimuxer.restoreBackup(
    backupRoot: ...,
    sourceIdentifier: sourceIdentifier,
    shouldReboot: false,
    systemFiles: true,
    onProgress: { ... },
    delegateLog: { line in AppLog.write(line) },
    cancellationRequested: { CancelFlag.shared.isRequested }
)
```

**(d) Do not keep running later stages after a cancel.** `GoldenNuggetView.run()` already
recognises `.cancelled`, but `PoCEngine`'s two run methods simply let the cancellation
thrown by `ChannelRecovery.retry` propagate upward — which is correct. What is missing
is an **entry gate**: `guard !CancelFlag.shared.isRequested` at the top of `runPoC` /
`runPartialRestore` (naturally satisfied after `clearCancel()`), plus not doing
`removeItem(at: backupRoot)` immediately after `clearCancel()` — see `InFlightCall` in
§2.

### Expected improvement

| Item | Before | After |
|---|---|---|
| Device-side state after Stop | keeps writing until it finishes on its own (minutes) | stops on Rust's next `is_cancelled` poll (usually <1 s) |
| The Stop → Run again window | the new run's `rm -rf` races the old run's writes → corrupted backup tree / lost payloads | cannot happen |
| Diagnostic trustworthiness | the "stopped" log does not match what the device actually did | consistent |

The main payoff here is **correctness**, not speed; it is also a prerequisite for §2
and §3 — if cancellation really takes effect, one large class of "abandoned calls"
disappears.

---

## 2. Abandoned calls had no reaping gate: a retry starts a second operation while the old call is still in flight

### Symptom

Exactly the same failure, retried 3 times (the most classic signature in
`stale-connection-retry-audit`), and the log occasionally shows **two handshakes**
(two stretches of `attemptPairVerify` / `createListener` tens of milliseconds apart).
Worse variant: the first restore actually succeeded on the device side, but the app
already declared failure and started a second one.

### Root cause

`StallGuard`'s "abandon" is **one-sided**: it only does `once.resume(.failure(...))`
to return on the Swift side, while `body()` runs inside `withFFIDispatch { ... }` — an
**uninterruptible blocking FFI call** on `DispatchQueue.global()` that keeps running to
completion (`FFIDispatch.swift:15`).

Immediately afterwards `ChannelRecovery.retry` does two dangerous things:

```swift
// ChannelRecovery.swift:60-77
case .retry(let floor, let why):
    ...
    await recover(level: level)          // ← its first statement is invalidateConnection()
    try await Task.sleep(...)            // ← then immediately reopens body() once
```

And the first statement of `recover(level:)` (`ChannelRecovery.swift:93`):

```swift
minimuxer.ideviceGateway?.invalidateConnection()
```

`invalidateConnection()` frees the **shared** adapter and handshake
(`IdeviceGateway.swift:134-144`: `rsd_handshake_free` + `adapter_free`). This repo's
own comment already spells the hazard out:

```swift
// IdeviceGateway.swift:694-703
/// Deliberately not `fetchUDID()` / `performWithService`: both call
/// `invalidateConnection()` when a connect fails, which frees the RSD
/// adapter — and clients created from that adapter keep using it
/// (`mountPersonalizedDdiRsd` hands `adapter` to a second FFI call from
/// inside a service action).  ...
/// Freeing the adapter underneath that call to answer the question
/// would defeat the purpose.
```

So `.streamStalled` / `.tunnelCrawl` / `.cancelled` — the three failure kinds that
**arise precisely only when a call is still in flight** — go through exactly this
recovery ladder: **freeing the adapter out from under an in-flight call**.

### Fix

**(a) Add an in-flight gate** (new file `Nugget/Core/InFlightCall.swift`):

```swift
import Foundation

/// Records that a Rust call is *still running*, as opposed to "we stopped
/// waiting for it".
///
/// Those are different facts and the retry ladder conflated them.  A Rust read
/// blocked on a socket cannot be interrupted, so `StallGuard` abandons the
/// *wait* — but the call keeps running on `DispatchQueue.global()` and keeps
/// using the shared RSD adapter.  Starting a second operation on top of it,
/// after `recover(level:)` has freed that adapter, is how a run gets two
/// concurrent mobilebackup2 exchanges and a use-after-free at once.
final class InFlightCall: @unchecked Sendable {
    static let shared = InFlightCall()

    private let lock = NSLock()
    private var depth = 0
    private var abandoned = false

    func enter() {
        lock.lock(); depth += 1; lock.unlock()
    }

    func leave() {
        lock.lock()
        depth -= 1
        if depth <= 0 { depth = 0; abandoned = false }   // drained: clean again
        lock.unlock()
    }

    /// The guard walked away from a call that is still running.
    func noteAbandoned() {
        lock.lock(); abandoned = true; lock.unlock()
    }

    var isBusy: Bool { lock.lock(); defer { lock.unlock() }; return depth > 0 }
    var hasAbandonedCall: Bool { lock.lock(); defer { lock.unlock() }; return abandoned }
}
```

**(b) `StallGuard.run` keeps the books** (`StallGuard.swift:102-108`): all four
`once.resume(.failure(...))` sites need `InFlightCall.shared.noteAbandoned()` before
them:

```swift
let once = OnceResumer<T>()
return try await withCheckedThrowingContinuation { cont in
    once.attach(cont)
    Task {
        InFlightCall.shared.enter()
        defer { InFlightCall.shared.leave() }      // ← only cleared when it really returns
        do { once.resume(.success(try await body())) }
        catch { once.resume(.failure(error)) }
    }
    Task {
        ...
        if CancelFlag.shared.isRequested {
            InFlightCall.shared.noteAbandoned()    // ← we walked away, but it is still running
            once.resume(.failure(TransportFailure.cancelled(label: label)))
            return
        }
        ...
    }
}
```
(Add the same line to the three resumes for `handshakeSilent` / `tunnelCrawl` /
`streamStalled`.)

**(c) `ChannelRecovery.retry` waits for it to drain before retrying, and does not retry
if it does not drain**:

```swift
case .retry(let floor, let why):
    if attempt >= attempts { ...throw }

    // The abandoned call keeps running on DispatchQueue.global() and keeps
    // using the shared adapter.  recover(level:) frees that adapter, so
    // retrying while it is in flight is worse than not retrying: a second
    // mobilebackup2 exchange starts on a session the first one still holds.
    // Wait, bounded, for it to drain; do not rush it.
    if InFlightCall.shared.isBusy {
        var waited = 0
        while InFlightCall.shared.isBusy, waited < 20 {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            waited += 1
        }
        if InFlightCall.shared.isBusy {
            AppLog.write("\(label): the abandoned call is STILL running after \(waited)s — refusing "
                + "to start a second one on the same session (the blocked Rust read cannot be "
                + "interrupted). Reopen the app to get a clean runtime.")
            if let diagnostics { AppLog.write(await diagnostics()) }
            throw error
        }
        AppLog.write("\(label): the abandoned call drained after \(waited)s — recovering and retrying.")
    }

    let delay = min(delaySeconds << UInt64(attempt - 1), 8)
    let level = min(max(floor.rawValue, attempt), RecoveryLevel.restartMuxer.rawValue)
    await recover(level: level)
    try await Task.sleep(nanoseconds: delay * 1_000_000_000)
```

**(d) Likewise, both `PoCEngine` run entry points check the gate before touching
anything**:

```swift
guard !InFlightCall.shared.isBusy else {
    throw PoCError("A previous device operation is still running after being abandoned. "
        + "Force-quit the app and reopen it before starting another run.")
}
```

### Expected improvement

| Item | Before | After |
|---|---|---|
| Concurrent operations during a retry | 2 (old + new) | 1 |
| `invalidateConnection()` vs an in-flight call | always overlaps | only freed after draining |
| Double handshake / double session | happens | does not happen |
| "the retry always fails exactly the same way" | possibly two sessions stepping on each other | no longer caused by this |
| Worst-case elapsed time | 3 × 3 s backoff + 3 useless retries | bounded 20 s wait, then **fail explicitly with an explanation** instead of pretending to retry |

This is one of the **code-level root causes** of the "retries with exactly the same
symptom" class: it is not a stale cache, it is that we freed the adapter while the old
call was still using it.

---

## 3. The diagnostics block calls a read that `invalidateConnection()`s, on the abandon path

### Symptom

After abandoning a long call, a diagnostics block follows immediately in the log, and
then **the next attempt's failure mode is byte-for-byte identical to the previous
one**; or an inexplicable session invalidation appears on the device side.

### Root cause

```swift
// Diagnostics.swift:34
let udid = try? await minimuxer.core.fetchUDID()
```

And `fetchUDID` frees the shared adapter when the connect fails
(`IdeviceGateway.swift:759-761`):

```swift
if let firstErr = connectErr {
    idevice_error_free(firstErr)
    invalidateConnection()          // ← the same hazard
```

The call sites of `Diagnostics.report()` are exactly "just abandoned a call that is
still in flight":

```swift
// ChannelRecovery.swift:57 (.failFast: cancelled, handshake silent)
if let diagnostics { AppLog.write(await diagnostics()) }
// ChannelRecovery.swift:63 (retries exhausted: stalled, tunnel crawl)
if let diagnostics { AppLog.write(await diagnostics()) }
```

In other words: **among the things §2 fixes, the diagnostics block itself was doing the
same thing** — tearing down the in-flight call's adapter with one probe. The comment on
`probeLockdownAlive()` (`IdeviceGateway.swift:696-703`) already states the correct
approach, yet `Diagnostics.report()` does not follow it (it calls `fetchUDID()`, while
the other probe in that file, `deviceLivenessProbe()`, is the read-only one).

Side problem: `report()` walks the **whole** `minimuxer.log` three times — once for
`excerpt()` (`Data(contentsOf:)` + a full UTF-8 decode + 40 keyword `contains` + a DL
histogram over all the lines), another full read for `tail()`, and then
`transportLine(lines)` scans all the lines once more.

### Fix

```swift
static func report() async -> String {
    let minimuxer = Minimuxer.shared()
    var lines: [String] = ["── diagnostics ──"]

    // Snapshot the Rust evidence FIRST — these probes write into the very same
    // log we are about to read (see the note at the top of this file).
    let logStatus = RustLog.status()
    let excerpt = RustLog.excerpt()
    let tail = RustLog.tail(30, since: RustLog.mark)

    lines.append("  tunnel: \(Tunnel.describe())")
    lines.append("  peer \(Tunnel.peerIP):\(Tunnel.servicePort) reachable: \(Tunnel.probePeer())")
    if let gw = minimuxer.ideviceGateway {
        lines.append("  gateway endpoint IP: \(gw.deviceEndpointIp ?? "nil")")
    } else {
        lines.append("  gateway: not IdeviceGateway")
    }
    lines.append("  pairing type: \(minimuxer.core.getPairingFileType())")

    // Nothing below may reach for `fetchUDID()` / `performWithService`:
    // both call `invalidateConnection()` when a connect fails, which frees the
    // RSD adapter — and the whole reason this dump exists is that a long
    // mobilebackup2 call may still be parked on it (the very hazard
    // `probeLockdownAlive`'s doc describes).  When a call IS still in flight,
    // do not touch the session at all: dump the log evidence and say so.
    if InFlightCall.shared.isBusy {
        lines.append("  session probes: SKIPPED — an abandoned device call is still in flight; "
            + "probing it would free the adapter it is still using")
    } else {
        let alive = await deviceLivenessProbe()          // read-only, no invalidate
        lines.append("  lockdown: \(alive.alive) — \(alive.detail)")
        if case .success(let ready) = await minimuxer.core.isReady(withNetworkCheck: true) {
            lines.append("  isReady: \(ready)")
        } else {
            lines.append("  isReady: FAILED")
        }
    }
    lines.append("  rust log: \(logStatus)")
    lines.append("  wire: \(WireCensus.healthLine())")
    ...
}
```

Note: `isReady(withNetworkCheck: true)` also has to be checked against the same standard
for whether it goes through `fetchUDID` internally; if it does, swap it for the
read-only probe as well.

**Drop one full read while we are at it**: `excerpt()` and `tail()` each do
`Data(contentsOf:)` + `String(data:)`. Read once and share two views:

```swift
static func evidence(maxLines: Int = 90, tailCount: Int = 30) -> (excerpt: String, tail: String) {
    guard let whole = try? Data(contentsOf: url) else { ... }
    let from = Int(min(mark ?? 0, UInt64(whole.count)))
    guard let text = String(data: whole.dropFirst(from), encoding: .utf8) else { ... }
    let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
    return (excerpt(from: lines, offset: from), tail(from: lines, count: tailCount))
}
```

### Expected improvement

| Item | Before | After |
|---|---|---|
| Can diagnostics tear down an in-flight call's adapter | yes | no (probes are skipped entirely when a call is in flight) |
| Number of reads of the log file by diagnostics | 2 full reads + 2 UTF-8 decodes | 1 |
| Total cost of the abandon path | 2 full reads + 2 RSD round trips + one `invalidateConnection()` | one full read |

---

## 4. Handshake-silence detection re-reads and decodes the **entire** `minimuxer.log` every 5 s

### Symptom

The window in which "stuck" and "just slow" cannot be told apart grows; the slower the
device / the larger the log, the slower the app itself. In runs without packet loss it
shows up as overall throughput below expectation; in lossy runs it happens to stack on
top of the other issues.

### Root cause

`StallGuard`'s poll loop calls `handshakeSilent()` on **every** round (default
`pollSeconds = 5`):

```swift
// StallGuard.swift:143-159 (runs unconditionally every 5 s)
if let handshakeSilent {
    if handshakeSilent() { ... }
}
```

```swift
// RestoreRunner.swift:38 / ProtectiveBackup.swift:85
handshakeSilent: { RustLog.deviceSilentAtHandshake() }
```

```swift
// RustLog.swift:248
static func deviceSilentAtHandshake(since offset: UInt64? = nil) -> Bool {
    let from = offset ?? mark
    guard let whole = try? Data(contentsOf: url) else { return false }   // ← whole-file read
    let start = Int(min(from ?? 0, UInt64(whole.count)))
    guard let text = String(data: whole.dropFirst(start), encoding: .utf8) else { return false } // ← whole-file decode
    guard let lastStart = text.range(of: "Starting DeviceLink version exchange",
                                     options: .backwards) else { return false }
    return !text[lastStart.upperBound...].contains("Received DL message")
}
```

There is no `maxChunk` cap (`WireCensus` has a 4 MB cap), and it does one extra full
UTF-8 decode. **This is exactly the anti-pattern `WireCensus` was already fixed for** —
the comment at `WireCensus.swift:56-67` says verbatim:

> Re-reading and re-scanning a 2 MB window per poll — millions of byte comparisons,
> on the same device that is trying to drain a UDP tunnel — is load added precisely
> when the tunnel is least able to absorb it.

The same kind of load was missed in `deviceSilentAtHandshake`, and it is heavier than
the original `WireCensus` was (whole file with no cap + a decode, not just byte
comparison). The trigger condition is **guaranteed**: it runs on every round, whether or
not anything has stalled.

### Fix

Fold the handshake verdict into the incremental tailer that already exists — **one
scan serving the heartbeat, the stall verdict and the handshake verdict at once**.

**(a) `WireCensus.swift`: add two counters to the sample**

```swift
struct RustWireSample: Sendable {
    ...
    /// `Starting DeviceLink version exchange` lines seen this run.
    var handshakeStarts = 0
    /// `Received DL message` lines since the last `handshakeStarts` line.
    ///
    /// Both literals arrive through the same scan, in log order, so one
    /// incremental pass answers the handshake question that used to cost a
    /// whole-file read plus a whole-file UTF-8 decode every 5 s.
    var dlReceivedSinceHandshakeStart = 0

    /// Parked in `dl_version_exchange()` waiting for the device's FIRST
    /// DeviceLink message: a version exchange started and nothing has arrived
    /// since.  This side has sent nothing at that point, so no client-side
    /// change can be the cause — it can only be the device daemon.
    var handshakeSilent: Bool {
        handshakeStarts > 0 && dlReceivedSinceHandshakeStart == 0
    }
}
```

**(b) Maintain them in `absorb`** (`WireCensus.swift:136`):

```swift
static func absorb(_ lines: [Substring], into sample: inout RustWireSample) {
    for line in lines {
        if line.contains("Starting DeviceLink version exchange") {
            sample.handshakeStarts += 1
            sample.dlReceivedSinceHandshakeStart = 0   // a NEW attempt started
        }
        if line.contains("Received DL message") {
            sample.dlMessages += 1
            sample.dlReceivedSinceHandshakeStart += 1
        }
        if line.contains("Sending device link message") {
            sample.dlMessages += 1
        }
        guard line.contains("out-of-order seq=") else { continue }
        ...
    }
}
```

(Note that `wireMarkers` was originally an array + `contains(where:)`; the version above
preserves the semantics, but `"Received DL message"` is pulled out on its own because it
has to feed the second counter as well.)

**(c) `RustLog.deviceSilentAtHandshake()` becomes two lines**:

```swift
/// True when the mobilebackup2 client is parked in `dl_version_exchange()`
/// waiting for the device to speak first.
///
/// This used to read and UTF-8-decode the WHOLE log on every stall-guard poll
/// (every 5 s), on the device that is simultaneously draining the tunnel — the
/// same reverse load `WireCensus` was fixed for, and heavier (no chunk cap, plus
/// a full decode).  The counters now ride the tailer that is already scanning
/// those bytes, so the check costs nothing and the guard can poll it freely.
///
/// Fail-safe direction: if more than `maxChunk` was appended between polls the
/// tailer skips ahead and may miss the handshake line, which reads as
/// "not silent" — i.e. it falls back to the long idle path and can never kill a
/// live run.
static func deviceSilentAtHandshake() -> Bool {
    WireCensus.shared.read().handshakeSilent
}
```

The `since offset:` parameter can simply be deleted — grep confirms both call sites pass
the default.

**(d) While we are at it, centralise the constant for the two `Data(contentsOf:)`
sites**: the 4 MB cap `WireCensus.maxChunk` is already this project's definition of
"how much to read at most", so make every incremental read use it.

### Expected improvement

| Item | Before | After |
|---|---|---|
| Log I/O every 5 s | whole-file read (no cap) | only the newly appended bytes, usually tens of KB |
| UTF-8 decoding | the whole file on every poll | only the new lines |
| Memory churn | allocates/frees two file-sized buffers on every poll | only the new-line buffer |
| As the log grows | degrades linearly (long runs get slower and slower) | roughly flat |
| Detection latency | 45 s (`silentHandshakeSeconds`) | unchanged (safe to lower, because the check is now free) |

This one is also a **diagnostic accuracy** win: only once polling no longer competes
with the transfer for the same device's CPU/IO does the question "who is actually
slow" have an answer.

---

## 5. Pruning the manifest: row-by-row `stat` + treating `Snapshot/` as a shard to scan (and silently deleting staged payloads)

`ManifestStore.pruneToDiskState()` has two independent problems.

### 5a. Phase 1 does one `fileExists` per Files row, and builds two fresh `URL`s each time

```swift
// ManifestStore.swift:204-218
while sqlite3_step(stmt) == SQLITE_ROW {
    ...
    } else if FileManager.default.fileExists(atPath: payloadURL(forFileID: fileID).path) {
```

`payloadURL(forFileID:)` (`:59`) is internally two `appendingPathComponent` calls, i.e.
two URL allocations. So each row = 2 allocations + 1 `stat`. By the repo's own comment
(`MobileBackup2Delegate.swift:217` mentions `filtered payloads: 28490`), a
whole-device filtered backup's manifest is on the order of **1e5** rows → a few hundred
thousand syscalls + a couple of hundred thousand allocations, all synchronous and
serial.

**Fix: invert the direction — walk the shard tree once to get "which fileIDs are on
disk", then compare against the rows.**

```swift
// Phase 1: collect the payload tree ONCE instead of stat()ing per row.
//
// This used to call fileExists once per Files row, each time building two
// fresh URLs — on a filtered whole-device backup that is ~1e5 stat() calls
// plus ~2e5 URL allocations, all synchronous.  The payload tree is a flat
// two-hex-char shard layout, so one directory walk answers the same question
// in ~256 readdir calls.  removeOrphanPayloads() needs the same set anyway.
let fm = FileManager.default
var payloadsOnDisk = Set<String>()
if let shards = try? fm.contentsOfDirectory(atPath: deviceDir.path) {
    for shard in shards where ManifestSchema.isShardName(shard) {
        if let names = try? fm.contentsOfDirectory(
            atPath: deviceDir.appendingPathComponent(shard).path) {
            payloadsOnDisk.formUnion(names)
        }
    }
}
...
while sqlite3_step(stmt) == SQLITE_ROW {
    ...
    if flags == 2 { keepIDs.append(fileID) }            // directory rows never have a payload
    else if payloadsOnDisk.contains(fileID) { keepIDs.append(fileID) }
}
```

Add an **exact** shard predicate (`ManifestSchema`, i.e. the one place schema rules
live):

```swift
/// A payload shard is exactly two lowercase hex characters — that is what
/// `fileID.prefix(2)` produces.  Everything else under the backup directory is
/// not a shard: `Manifest.db`, `Manifest.plist`, `Status.plist`, `Info.plist`,
/// and the device's `Snapshot/` staging tree.
static func isShardName(_ name: String) -> Bool {
    let utf8 = name.utf8
    guard utf8.count == 2 else { return false }
    return utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
}
```

### 5b. `removeOrphanPayloads` treats every top-level directory as a shard — including `Snapshot/`

```swift
// ManifestStore.swift:271-293
guard let shards = try? fm.contentsOfDirectory(atPath: deviceDir.path) else { return 0 }
for shard in shards {
    let shardDir = deviceDir.appendingPathComponent(shard)
    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: shardDir.path, isDirectory: &isDir), isDir.boolValue else { continue }
    if let payloads = try? fm.contentsOfDirectory(atPath: shardDir.path) {
        for payload in payloads where !keepIDs.contains(payload) {
            try? fm.removeItem(at: shardDir.appendingPathComponent(payload))   // ← recursive delete
```

`Snapshot/` sits right under `deviceDir` (`ProtectiveBackup.swift:163-164` spells out
`AppPaths.deviceDir(...).appendingPathComponent("Snapshot")`); it is a directory whose
entry names are not fileIDs, so **every uncommitted payload in the staging tree gets
silently deleted recursively**, together with the `Snapshot/` directory itself
(`if remaining.isEmpty { removeItem(at: shardDir) }`).

Consequences:

1. The "⚠️ N file(s) left under Snapshot/ — staged but never committed" that
   `reportStagingLeftovers()` (`ProtectiveBackup.swift:162`, just a few lines before the
   prune) had just printed is **deleted by the next stage** — the evidence disappears
   within the same run.
2. That comment itself says "if the prune does not account for them the restore will
   fail", yet what prune does is make them physically vanish, so the cause of the
   failure becomes even harder to trace back.

**Fix: shard predicate + only sweep shards; leave `Snapshot/` for
`reportStagingLeftovers` to speak.**

```swift
/// Phase 3: remove payload files that no keep row references.
///
/// Only real shards are swept.  The first version treated every directory under
/// the backup as one, which included the device's `Snapshot/` staging tree —
/// so payloads the device staged but never committed were recursively deleted
/// here, i.e. the shortfall `reportStagingLeftovers()` had just reported was
/// erased by the next stage of the same run.  Off-shard directories are left
/// alone on purpose: they are evidence, and the manifest check already drops
/// the rows that reference them.
private func removeOrphanPayloads(shardNames: [String], keepIDs: Set<String>) -> Int {
    let fm = FileManager.default
    var removed = 0
    for shard in shardNames where ManifestSchema.isShardName(shard) {
        let shardDir = deviceDir.appendingPathComponent(shard)
        guard let payloads = try? fm.contentsOfDirectory(atPath: shardDir.path) else { continue }
        for payload in payloads where !keepIDs.contains(payload) {
            guard ManifestSchema.isShardName(String(payload.prefix(2))) else { continue }
            try? fm.removeItem(at: shardDir.appendingPathComponent(payload))
            removed += 1
        }
        if let remaining = try? fm.contentsOfDirectory(atPath: shardDir.path), remaining.isEmpty {
            try? fm.removeItem(at: shardDir)
        }
    }
    return removed
}
```

And carry the conclusion of `reportStagingLeftovers` into the diagnostics block too
(right now it only shows up in `ProtectiveBackup`'s log):

```swift
let leftover = stagingLeftoverCount(backupRoot: backupRoot, udid: udid)
if leftover > 0 {
    AppLog.write("⚠️ \(leftover) staged payload(s) were never committed — the restore below runs "
        + "on a partial backup. They are kept under Snapshot/ for inspection (not swept).")
}
```

### Expected improvement

| Item | Before | After |
|---|---|---|
| Phase 1 syscalls | ~1e5 × `stat` + ~2e5 URL allocations | ~256 `readdir` calls |
| Phase 1 magnitude | O(manifest row count) | O(shard count + payload count) |
| Staged uncommitted payloads | silently deleted recursively | kept, and reported with an explicit count |
| Duplicate cost on close | one orphan walk + one empty-directory sweep | shares the single walk already done in Phase 1 |

(This stage is a step on the **default path** in `runPartialRestore`, so the time it
saves is paid on every run. On a manifest of the 1e5-row magnitude, going from "a few
hundred thousand syscalls" to "a few hundred" is the most direct pure time reduction in
this whole path.)

---

## 6. The `_keep` temp table has no index, and the `NOT IN` subquery is not guaranteed

```swift
// ManifestStore.swift:221-250
sqlite3_exec(db, "CREATE TEMP TABLE IF NOT EXISTS _keep (fileID TEXT)", nil, nil, nil)
...
guard sqlite3_exec(db, "DELETE FROM Files WHERE fileID NOT IN (SELECT fileID FROM _keep)", ...)
```

`_keep` is declared as an ordinary table, and `Files.fileID` is a `PRIMARY KEY` (so it
has an implicit index), but the membership test in the other direction has no index to
use. SQLite normally materialises a temporary index for an `IN` subquery, so this is
**not necessarily** O(N·M) — but that is relying on the planner's behaviour, not on a
schema guarantee; once it degenerates into a nested loop, 1e5 × 1e5 is the single
largest item in the whole flow.

**Fix: declare the primary key (which incidentally removes the need for a separate
`DROP` guard before the `DELETE`)**

```swift
static let createKeepTable =
    "CREATE TEMP TABLE IF NOT EXISTS _keep (fileID TEXT PRIMARY KEY)"
```

That makes the membership test go through a B-tree, turning the cost from "depends on
the planner" into a certain O(N log M); the `INSERT INTO _keep` loop (already inside the
outer transaction, statement already prepared once) is unaffected.

### Expected improvement

| Item | Before | After |
|---|---|---|
| `DELETE ... NOT IN` complexity | planner-dependent, worst case O(N·M) | certain O(N log M) |
| Worst case | unpredictable single-step time on a large manifest | near-linear in manifest size |

---

## 7. Minor items (low risk, fixed while we were at it)

| Item | Location | Problem | Fix |
|---|---|---|---|
| The restore stage timer is not flushed on the failure path | `RestoreRunner.swift:59-60` | `beat.stop()` / `stage.done()` come after `try await`, so a throw skips them. This repo said it explicitly at `ProtectiveBackup.swift:117-124`: "a missing stage line makes the widest window unexplainable" | Wrap it in `defer { beat.stop(); stage.done(failure ? "FAILED" : "") }`, or use do/catch (`ProtectiveBackup` is already this shape, copy it) |
| `open_file_read` keeps the whole file resident in memory and copies it twice | `MobileBackup2Delegate.swift:448-461` | `FileManager.contents(atPath:)` first allocs + reads, then `malloc` + `copyBytes` → peak memory = file size, plus one extra full memcpy per file. When restoring large payloads (video / large containers) that is a jetsam risk, not a throughput problem | Read straight into the `malloc`ed buffer with `open`/`fstat`/`read`: one copy, same peak but one fewer intermediate `Data` (avoids 2× transient residency) |
| `RotatingFileSink` does open+stat+seek+write+close per line, and holds a global lock | `Logging.swift:32-53` | ~6 syscalls per line, inside `AppLog`'s process-wide lock. The current call sites are already rate-limited (the delegate's `reportEvent` fires every 50/200 entries, the heartbeat every 10 s), so it is not a hotspot; but the rotation past 2 MB does a full `Data(contentsOf:)` read + writes half back, inside the lock | Hold a long-open `FileHandle` + keep the size in memory; make the rotation a segmented truncation; wrap `print` in `#if DEBUG` (on device the console is unreachable, so it is equivalent to dropping it) |
| UI log row identity is unstable | `GoldenNuggetView.swift:176-181` / `344-352` | `ForEach(Array(logs.enumerated()), id: \.offset)`: after `logs.removeFirst(...)` every row's identity shifts, so SwiftUI rebuilds every row | A monotonically increasing id (`struct LogLine: Identifiable { let id: Int; let text: String }`), and trim in batches (100 rows at a time) instead of 1 row per time |

---

## 8. Suggested order of implementation

1. **§1 + §2 + §3 together** (three faces of the same thing: make cancellation actually
   take effect, make the retry not stack on top of an in-flight call, make diagnostics
   stop tearing down its own session). Without these three, every later "retry strategy"
   adjustment is built on sand.
2. **§4** (pure win, lowest risk: drop one whole-file read + decode, and the verdict
   reads an already-existing counter).
3. **§5a + §6** (a one-off time reduction in the prune stage).
4. **§5b** (preserve the staging evidence; it shares the single walk with §5a, so
   changing them together is cheapest).
5. §7 as needed.

## 9. Verification

- `scripts/typecheck.sh` — **it only passes with 0 errors**. Note that it picks the
  newest `Products/{Debug,Release}-iphoneos` by mtime, so after changing `Vendor/` you
  must rebuild, otherwise it reports a false positive; it needs
  `-disable-dependency-sandbox`, and **do not read the log through `| head`**
  (SIGPIPE truncation = a false green light).
- Acceptance for §5a: on a real manifest, compare the number of `fileExists` calls —
  before the fix it should be roughly equal to the row count, after the fix roughly
  equal to the payload count, and the `kept` number on the `Pruned Manifest.db: …` line
  must stay the same (unchanged behaviour is a hard requirement).
- Acceptance for §4: within the same run, compare the number of bytes of `minimuxer.log`
  read before/after `handshakeSilent()` (you can use `fs_usage` or a temporary counter);
  it should go from "≈ the file size each time" to "≈ the new bytes each time".
- Acceptance for §2: deliberately trigger a stall/cancel; the log should show
  `the abandoned call drained after Ns` or
  `refusing to start a second one on the same session`, and **should not** show a
  paired handshake of two `Starting DeviceLink version exchange` tens of milliseconds
  apart.
- Acceptance for §1: press Stop, then observe on the device side whether the backup
  daemon stops making progress within the next poll (the DL message count in
  `minimuxer.log` should stop growing within 1 s) instead of running to completion.
