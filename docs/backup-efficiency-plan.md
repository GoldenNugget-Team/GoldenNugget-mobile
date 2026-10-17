# Backup Efficiency Plan: fewer bytes, fewer walks

> **Status: P0 / P1a / P1b / P2 landed (2026-10-01); P3 / P4 not started.** Every claim
> about the current behaviour is cited to a file:line in this repo; every claim about the
> *device* is labelled as a hypothesis with the evidence that supports it and the
> experiment that would settle it.
>
> Scope: the on-device (mobile) apply path — `ProtectiveBackup` → prune → inject →
> restore, plus the two other transfers that ride an apply (the PosterBoard fetch
> and the AFC media pull). Out of scope: restore correctness work already landed
> (`docs/restore-path-audit.md`) and anything that requires changing the vendored
> Rust (costed separately in §7).

---

## 0.5 What actually shipped (2026-10-01)

The plan below was written first and implemented second; this table is the diff between
the two. Two phases that change what crosses the link (P1a, P2) are **gated off by
default** — they are wired end to end and reachable from Settings → Developer, but a
run only takes them if a switch says so.

| Phase | State | What shipped | Default | Notes vs. the proposal |
|---|---|---|---|---|
| P0 | landed | Wire-byte accounting on `MobileBackup2BackupContext` (`Vendor/…/MobileBackup2Delegate.swift:153-205`), fed from `mb2_on_progress` (`:813`), `mb2_should_preserve` (`:827`), `mb2_write_chunk` (`:626`); emitted as `byteSummary()` after both exchange summaries (`IdeviceGateway.swift`) | always on | measurement only, changes no behaviour. The summary ends in a machine-readable `[bytes=N total=N offered=N kept=N drained=N stored=N]` tail because `ByteCountFormatter` output is locale-dependent |
| P0 | landed | `scripts/backup-cost-report.py` | n/a | per-run budget table, drain share, first-vs-last comparison |
| P1b | landed | Manifest-keyed skip in `AfcMediaBackup.pull` (`AfcMediaBackup.swift:150-192`), reported as `"AFC media: N file(s) already stored, N byte(s) not transferred"` (`:260-262`) | always on | a cold store behaves exactly as before; only the repeat path short-circuits |
| P1a | landed, **gated** | `MergedContainer` (`GoldenNuggetEngine.swift:480-486`) + `deliver(… merged:)` post-pull hook (`:572-573`); filter split into `namesStore` / `keepsMergedFile` / `MergedFilter` (`PosterBoardBackup.swift:203-266`); `extractFromPull` (`:230`) | `Dev.MergePulls` = **off** | the four ordering constraints in §2.1 are encoded as the container's four fields, not as prose |
| P2 | landed, **gated** | `Nugget/Core/BackupBaseline.swift` (`plan` / `seedManifest` / `snapshot` / `commit` / `clear`); `ManifestStore.rowCount` (`:49`) + `dropRows` (`:137`); retained tree under `AppPaths.baselineDir` (`:60`) | `Dev.IncrementalPull` = **off** | `dropDomain` was added to `seedManifest` — see "self-caught bugs" below |
| P3 / P4 | not started | — | — | §4 is research; §5 needs a number from P0 first |

**Incidental fix.** `HostManifests.writeSQLiteManifest` now takes `keepingExisting:`
(`HostManifests.swift:177-192`). Before this, `ProtectiveBackup` logged *"keeping the
partial baseline … (wiping it would force a full re-upload)"* and then called a function
that deleted exactly that file — the retry-incrementality the comment promised did not
exist on attempt ≥ 2. §0(b) read that comment as evidence the mechanism works; it now
actually does.

**Still unrun:** the P2 promotion gate in §3 (two devices × three runs, content-identical
restore, measured byte drop, plus the new zero-offer assertion). Until it passes, the
default stays a full pull.

**Self-caught bugs, fixed before landing** (all three would have been silent):

- *Baseline × merged pull.* A container fetched through P1a has its rows pruned and its
  payloads swept as orphans every run, while the retained manifest still lists them — so
  a seeded manifest would tell the device "unchanged, don't send" for exactly the files
  the next run needs. Fixed by giving `seedManifest` a `dropDomain`, wired to
  `PosterBoard.domain` via `MergedContainer.dropDomain`.
- *The `deleted` flag on a skipped media entry.* The skip copied the prior entry
  verbatim, including `deleted: true`; but the file is in the survey, so the original must
  exist. The copied entry now forces `deleted: false`.
- *The seeded path tripped the pre-existing `kept > 0` guard — with the wrong diagnosis.*
  A seeded run whose delta is empty (`total == 0`) hit the guard at
  `ProtectiveBackup.swift:212` and was reported as *"the iOS 27 transfer shape is"*
  (wrong: the baseline is the thing that produced the empty stream). Worse, it was
  **permanent**: `commit` only writes a record after a successful restore, so a baseline
  that cannot produce a delta was re-validated by `plan` and re-failed identically on
  every future apply. The guard now has a third branch that names the seeded case,
  admits the two readings it cannot separate from counters alone (baseline honoured vs.
  manifest unreadable — the `4d40fbb` silent failure) and points at the Rust tail, and it
  calls `BackupBaseline.clear` so a poisoned record costs one full pull instead of every
  pull. This is §3's gate item 4, implemented rather than deferred.

---

## 0. The cost model, as the code stands today

One Apply on iOS 27 with a wallpaper selected runs **three transfers and one
restore**, and it opens **two mobilebackup2 sessions**:

| # | Stage | Code | What crosses the link | Evidence |
|---|---|---|---|---|
| 1 | PosterBoard fetch | `PosterBoardBackup.fetch` | A backup session whose filter keeps only the store | `PosterBoardBackup.swift:68-163` |
| 2 | Protective pull | `ProtectiveBackup.run` | A backup session: the whole device minus app containers | `ProtectiveBackup.swift:85-118` |
| 3 | AFC media | `AfcMediaBackup.pull` | **Every file in the Media trees, every run** | `GoldenNuggetEngine.swift:484-488`, `AfcMediaBackup.swift:128-219` |
| 4 | Restore | `RestoreRunner.run` | Only the pruned keep-set (~hundreds of rows) | `RestoreRunner.swift:49-74` |

Three facts in that table are the whole problem:

**(a) The keep-filter runs at store time, so a drained payload has already crossed
the link.** Rust decides to drain *after* the payload arrives and the host's
`should_preserve` says no; what it saves is flash writes, not bandwidth
(`MobileBackup2Delegate.swift:727-744`; `Vendor/patches/README.md:77-110` — "Without
it a *protective* backup writes every photo and video to flash"). So the number
that costs us is the **offered** set, not the **kept** set:

- PosterBoard fetch: `6 kept of 29078 offered` (`PosterBoardBackup.swift:140-141`).
- Protective pull: `filtered payloads: 28490 … removed` (`ProtectiveBackup.swift:123-131`).

**(b) The device's `Manifest.db` baseline is the only lever that shrinks the offered
set — and this app wipes it on every run.** Three separate places delete it:
`resetDirectory(backupRoot)` (`GoldenNuggetEngine.swift:774-777`), `HostManifests.reset`
on attempt 1 (`ProtectiveBackup.swift:60-62`), and `writeSQLiteManifest`, which removes
and recreates the file empty (`HostManifests.swift:177-181`). The code already knows
what that costs — the retry comment says wiping the baseline "makes every retry a FULL
re-upload of the whole protective set — the single most expensive thing this app does"
and that a retry *on top of the partial baseline is incremental instead*
(`ProtectiveBackup.swift:49-59`). **Incremental backup already works here. It is only
used inside one run, and only by accident.**

**(c) The AFC media stage is a full re-copy of the photo library on every apply.**
`pull()` loops over every surveyed file and streams it, with no "we already have this"
check — the manifest it writes already records `source`/`size`/`modified` per entry
(`AfcMediaBackup.swift:204-206`) and is persisted (`AppPaths.swift:26-32`), but the pull
loop never consults it. Since `deletingOriginals` is `false` on the apply path
(`GoldenNuggetEngine.swift:487`), the device ends up holding **two copies of every
photo**: the originals, and the app container's `Media/` store. On a device with a
large library this is both the biggest transfer and the biggest storage consumer the
app has.

### The three levers, in order of yield

1. **Don't let the device offer it** — delta against a retained baseline (§4).
2. **Don't walk the same tree twice in one run** — one session for both pulls, and
   don't re-copy media that has not changed (§3).
3. **Don't pay twice for the same failure** — retries, handshakes, tunnel-level
   retransmissions (§6).

---

## 1. P0 — Yardstick first: you cannot tune what you do not count  *(landed)*

Today the run counts *messages*, not *bytes*: `WireCensus` tracks DL messages and
jktcp reorder events (`WireCensus.swift:11-48`), and no stage anywhere reports a byte
total. Everything below is a claim about bytes, so this comes first.

Add five monotonic counters and log them once per stage:

| Counter | Where it is fed | Why it matters |
|---|---|---|
| `offeredBytes` / `offeredFiles` | the `shouldPreserve` closure (`ProtectiveBackup.swift:97-101`), summed from the delegate's per-file size | the number the device actually spent |
| `keptBytes` / `keptFiles` | same closure, `keep == true` branch | what we paid for something we use |
| `restoredRows` / `restoredBytes` | `ManifestStore.auditAgainstDisk()` (`ManifestStore.swift:418`) + the restore delegate | what the restore costs |
| `retries` | `ChannelRecovery` (`ProtectiveBackup.swift:46`, `GoldenNuggetEngine.swift:808`) | a retry *is* a second walk |
| `stageSeconds` | `StageTimer` already prints this | wall clock per stage |

Acceptance: three consecutive applies produce a stable budget table. That table is the
regression gate for every change below — no change ships on a "feels faster".

Deliverable: `scripts/backup-cost-report.py`, parsing `goldennugget.log` for the new
lines plus the existing `StageTimer` / `Pruned Manifest.db:` / `AFC media:` lines, and
printing the table. Keeping it a log parser (not an in-app screen) means it works on a
log pulled off the device with the pasteboard route that is already in use.

---

## 2. P1 — Stop paying for the same work twice (low risk, no behaviour change)

### 2.1 One session, not two — merge the PosterBoard fetch into the protective pull  *(landed; `Dev.MergePulls`, default off)*

`backupBackup` already takes an `applications` dictionary, and it **takes precedence
over `skipAppContainers`** when non-empty (`IdeviceGateway.swift:3634-3663`). So the
protective pull can carry `[PosterBoard.bundleID: entry]` and deliver both sets in one
exchange: one Trust/session authorization, one device walk.

This is *parity*, not a new mechanism. The reference builds one file list from every
feature and lets `needs_posterboard` decide only whether the store must be fetched
first — "There is no separate apply for wallpapers"
(`GoldenNuggetEngine.swift:180-190`). This port kept a second exchange
(`AppPaths.swift:38-46` exists precisely to stop the two roots from wiping each other).

Work items, and the ordering constraint that makes them non-trivial:

1. Build the application entry (`appFactoryEntry(bundleId:)`) before the pull, and pass
   it to `ProtectiveBackup.run` (`ProtectiveBackup.swift:93-101`).
2. Extend the keep-filter to keep the store's own files as well as the protective set
   (the two predicates are separate today: `isProtectiveFile` vs the `PosterBoard`
   counter's `mentionsStore`).
3. Extract the store to `Documents/PosterBoard/<udid>.sqlite3` **between the pull and
   the prune** — the prune would otherwise drop rows outside the protective keep-set,
   and the WAL merge has to happen while the payloads are still on disk.
4. Move `PosterBoard.compile` into `deliver`'s post-pull phase
   (`GoldenNuggetEngine.swift:276-298` runs it before the pull today, which is why the
   database is fetched early).

Cost: the pattern is proven (the fetch filters on the device path and refuses a run
that kept nothing — `PosterBoardBackup.swift:123-186`), and the refactor is confined to
`GoldenNuggetEngine.applyTweaks` + `ProtectiveBackup`. Payoff: one full device walk
removed from every wallpaper apply.

### 2.2 AFC media: skip what is already stored  *(landed; always on)*

The manifest already carries what a skip needs (`AfcMediaBackup.swift:204-206`). Change
`pull` to: look the entry up by `source`, and if a stored file exists with the same
`size` and the manifest's `modified` matches, **verify by size and continue** instead of
streaming it. The verification order the file's own doc comment insists on
(`AfcMediaBackup.swift:128-133`) is preserved — write, verify, then delete — only the
"we already have an identical copy" fast path is new.

Two follow-ups worth deciding explicitly (they are product calls, not engineering ones):

- The apply path pulls media on **every** iOS 27 apply (`GoldenNuggetEngine.swift:484-488`),
  with `skipAfcMedia` as the only escape. With 2.2 the repeat cost collapses, but the
  survey (an AFC directory walk) still runs. Consider making the apply-time pull
  conditional on the survey reporting files the manifest does not already cover.
- `deletingOriginals: false` means permanent 2× storage. The flag exists and the code
  already handles the destructive half safely (`AfcMediaBackup.swift:192-202`). This is
  a user-visible choice, not a default to flip silently.

---

## 3. P2 — Cross-run baseline: let the device send only the delta (gated)  *(landed; `Dev.IncrementalPull`, default off; promotion gate unrun)*

**Hypothesis.** The `Manifest.db` sitting in `<udid>/` at the start of the pull *is* the
delta baseline: seed it with the device's own previous manifest and the device offers
only what changed. Seed it empty (today) and it offers everything.

**Evidence for it:**
- The retry comment: keeping the partial baseline makes attempt 2 incremental; wiping it
  forces a full re-upload (`ProtectiveBackup.swift:49-59`). That is the mechanism working,
  observed in this app.
- The commit that introduced the empty seed explains the opposite case: with no manifest
  to serve, the device `Failed to send file …/Manifest.db: not found (-6)` and abandoned
  the transfer in three seconds, and a *synthesised sparse* manifest "asks the device to
  send only what a manifest lists, and no manifest exists yet" (commit `4d40fbb`). So the
  baseline must be **device-produced rows**, not host-shaped ones.

**What is NOT proven:** that the delta is stable across process restarts and across
sessions, and what the device does with a row whose payload we deliberately never stored
(the drained ones — they become 0-byte placeholders, `MobileBackup2Delegate.swift:736-742`).
Both need an experiment before this is a default.

### Design

```
Documents/
  <udid>/                      # working backup, wiped per run (as today)
  Baseline/<udid>/
    Manifest.db                # device-produced, taken BEFORE the prune
    <shard payloads>           # the keep-set payloads from the last successful run
    baseline.json              # udid, ProductVersion, BuildVersion, keepSetHash, date, restoreAck
```

1. **Seed.** If `baseline.json` validates (§ invalidation), copy `Baseline/<udid>/Manifest.db`
   into `<udid>/Manifest.db` instead of `HostManifests.writeSQLiteManifest`'s empty file
   (`HostManifests.swift:177-181`), and carry the keep-set payload shards into the working
   tree (APFS `clonefile`, so the carry is metadata-only, not a byte copy).
2. **Snapshot.** After `backupBackup` returns and **before** `pruneToDiskState()` mutates
   the manifest in place (`BackupInjector.swift:224-228`), copy `Manifest.db` →
   `Baseline/<udid>/Manifest.db`. The pristine copy is what the device needs; the pruned
   one is what the restore needs. Today they are the same file, which is exactly why the
   choice is wipe-or-nothing.
3. **Commit.** Write `baseline.json` only after the restore reaches its postcondition and
   `auditAgainstDisk()` is clean (`ManifestStore.swift:418-460`). A baseline written by a
   failed run is worse than none.
4. **Invalidate** (fall back to the full pull, log the reason): UDID change; device
   `ProductVersion`/`Build Version` change; `keepSetHash` change — **any edit to
   `ProtectiveBackup`'s prefix tables must invalidate**, because a file outside the old
   keep-set was never stored and would never be re-offered; a run that did not reach the
   restore postcondition; a TTL (suggest 7 days); or `Dev.FullPull`.

### Why the "stale content" worry does not apply, and where it does

The device computes the delta by comparing its *current* files against the seeded rows, so
"the device did not send it" means "the device said it is unchanged since we last saw it" —
the payload on disk is fresh by construction, not stale. The stale case is the reverse one:
rows kept in the baseline whose payload we dropped (the drained files). Those are pruned
before the restore, so they are harmless **as long as the keep-set never grows** — hence
`keepSetHash` in the invalidation list, and hence the requirement that the snapshot is
taken before the prune (a pruned baseline would tell the device that 28k files are "new",
which is the failure mode we are trying to avoid).

### Gate (per your own rule: a half-working toggle is worse than a narrow proven one)

- Default stays **full pull**. The delta path lives behind `Dev.IncrementalPull`, in the
  same shape as `Dev.SkipAfcMedia` (`GoldenNuggetEngine.swift:484`).
- It is promoted to default only when, on two devices × three consecutive runs:
  1. the restore's keep-set content is identical to a full-pull run of the same selection,
  2. every kept file is non-empty and byte-identical for unchanged paths,
  3. `offeredBytes` drops by the expected order of magnitude (measure first, then set the
     number — do not pre-commit to a percentage),
  4. the existing `kept > 0` assertion still fires when it should
     (`ProtectiveBackup.swift:212-266`) and a seeded run that offers *nothing* is named as
     such rather than misdiagnosed (the silent "transfer completed, moved nothing" failure
     of `4d40fbb`) — **implemented** in the guard's third branch, which also retires the
     poisoned record.

---

## 4. P3 — Narrowing the offered set further (research only; do not schedule yet)

- **Negative delta.** Seed the baseline with plausible rows for the domains we never keep,
  so the device treats them as unchanged. This is the only way to shrink the offered set
  without Rust changes, and it is *unsafe*: a row the device considers mismatched is a
  re-send at best, and a row whose shape it rejects is `MBErrorDomain/205` at restore time.
  Keep it as an experiment behind the same dev switch; do not ship it on top of §3.
- **Per-domain request options.** `should_preserve` is a post-transfer filter and the
  vendored FFI exposes no domain-scoped request (`IdeviceGateway.swift:3646-3663`;
  `Vendor/patches/`). Adding one means patching the vendored Rust on two files plus the C
  header, i.e. permanent upstream cost — justified only if §3 lands and still leaves a
  number worth attacking.

---

## 5. P4 — Transport and session (measure first, then tune)

- **Retries are double-spend.** `ChannelRecovery.retry(attempts: 3)` wraps both the pull
  and the restore (`ProtectiveBackup.swift:46`, `GoldenNuggetEngine.swift:808-812`). The P0
  counter will say how often it fires; every firing repeats a handshake and a partial walk.
- **jktcp-level bytes.** `WireCensus` already detects the two transports states that mean
  re-sent bytes — `held=false` (reorder window full, `WireCensus.swift:38-41`) and an
  unfilled gap with no retransmissions (`WireCensus.swift:27-36`). If P0 shows those are
  common, the reorder window/MTU are the knobs; they live in vendored Rust, so this is an
  upstream-cost change with a measurable payoff, not a free one.
- **Two tunnels, one link.** `Airlift` deliberately holds its own RSD tunnel
  (`Airlift.swift:18-26`). An Airlift write (or a background `streamSyslog`,
  `Airlift.swift:289-313`) running during a backup competes for the same path. Serialize
  them: stop any stream and refuse to start an Airlift write while a backup/restore is in
  flight.

---

## 6. Storage budget (a mobile constraint, not just a speed one)

The app owns, simultaneously: the working backup, the AFC media store (a second copy of
every photo), `PosterBoardFetch/`, `PosterBoard/<udid>.sqlite3`, two logs, and — with §3 —
the baseline. On a phone, the media store and the baseline are the ones that matter.

- `clonefile` for the baseline carry and for any "keep the previous run's payloads" step:
  same volume, so the copy is free (no bytes, no flash).
- Prune the working tree after each run instead of leaving the drained set's placeholders
  (the delegate already removes them, `MobileBackup2Delegate.swift:744`), and keep only
  the last successful run.
- Surface the total in the UI next to free space before an apply, the way the media page
  already does (`AfcMediaBackup.containerFreeBytes()`, `AfcMediaBackup.swift:115-124`).

---

## 7. Rollout

| Phase | Change | Files | Expected effect | Risk | Verification | State |
|---|---|---|---|---|---|---|
| P0 | Cost counters + log parser | `WireCensus.swift`, `ProtectiveBackup.swift`, `RestoreRunner.swift`, `AfcMediaBackup.swift`, `scripts/backup-cost-report.py` | none (measurement) | none | 3 runs produce a stable table | **landed** |
| P1a | Merge the two pulls | `GoldenNuggetEngine.swift`, `ProtectiveBackup.swift`, `PosterBoardBackup.swift` | one device walk removed per wallpaper apply | medium (ordering: pull → extract → compile → prune → inject) | same restore content; one fewer backup session in the log | **landed, `Dev.MergePulls` off** |
| P1b | AFC incremental skip | `AfcMediaBackup.swift` | media re-copy → near zero on repeat applies | low | stored file count and bytes on run 2 | **landed** |
| P2 | Baseline reuse (gated) | new `BackupBaseline.swift`, `HostManifests`, `GoldenNuggetEngine`, `ProtectiveBackup`, `ManifestStore`, `AppPaths` | offered bytes on repeat applies, order-of-magnitude | high (device semantics) | §3 gate | **landed, `Dev.IncrementalPull` off; gate unrun** |
| P4 | Retry/jktcp/serialization | `ChannelRecovery.swift`, `Airlift` call sites | removes double-spend | low-medium | retry counter + wire counters | not started |

**Do not redo** (already landed, see `docs/restore-path-audit.md:34-44`): the prune's single
transaction and `_keep` primary key, the one-walk orphan sweep, log batching, the
`setvbuf` on the host file writers, the incremental `WireCensus` tailer. Re-raising any of
those as an "optimization" would be a regression dressed as progress.

**Do not reintroduce sparse without the reason on record.** It was removed in `4d40fbb`
for a silent failure: a manifest that does not exist, or one the device cannot read, makes
the transfer complete *having moved nothing*. §3 is deliberately built so that its failure
mode is loud: the seeded manifest is device-produced, the first-run snapshot is taken
before any mutation, and a zero-offer run aborts.

---

## 8. What to do next, in one sentence

The plan asked to land P0's counters first and let the numbers choose between P1 and P2;
P0–P2 were implemented together instead, so that ability is gone **by construction** — the
first measured apply will not separate P1a from P2 on its own. What restores it is the two
switches: run three applies with `Dev.MergePulls` and `Dev.IncrementalPull` both off (the
baseline), then turn on **one** at a time, and read `scripts/backup-cost-report.py`'s
first-vs-last comparison after each — the counters are in place, so the ordering the plan
wanted can still be recovered, just from four measurement rounds instead of three.
