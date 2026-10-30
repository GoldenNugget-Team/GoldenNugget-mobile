# PosterBoard restore pipeline rewrite

The mobile path previously reconstructed the existing container as regular
`TweakPayload` files. That preserved bytes but discarded native backup records,
empty directories, file modes, protection classes and other MBFile metadata.
The captured iOS 27.0.1 container contains 905 regular-file records and 1110
directory records. Its Library/store/preferences records use protection class 4,
whereas the generic mobile app-container profile used class 3 for files and 0
for directories. Those differences were absent from the old compile-only tests.

The new iOS 27 path is:

1. Fetch the complete live PosterBoard container with its native Manifest.db.
   Validate every required regular payload before proceeding. Keep the first
   complete pre-apply snapshot under `Documents/PosterBoard/Recovery/<udid>/Baseline`;
   this is independent of scratch space and is never replaced by retries.
2. Consolidate the exact database/WAL pair, then stitch the new configuration
   rows into a copy using the desktop PBConfigManager approach.
3. Compile only the wallpaper delta, and deliver each wallpaper **once** —
   under `Extensions/<provider>/configurations/<uuid>/`, the shape the device's
   own store contains and the one the reference writes.
4. Pull/prune the Protective backup. Import **only the delta's** manifest rows
   and payloads; everything else the container holds keeps its native metadata
   as a donor (protection class, inode, keyed UIDs) but is neither copied into
   the restore nor given a row.
5. Inject the new delta. Existing directory records for the delta's ancestors
   are kept verbatim. A same-path file replacement patches only the native
   archive's content size and digest, following the desktop donor-blob strategy.
   Native inode, protection, ownership, permissions, extended attributes and
   keyed UIDs remain. New PosterBoard rows use the measured class-4 profile.
6. Restore the combined backup through the existing verified transport.

Existing preferences are merged rather than replaced, and WAL/SHM companions
for the replaced SQLite store are cleared. Explicit reset paths remain separate
from additive imports; the legacy MBDB branch retains its file-based fallback.

Validation:

- `scripts/check-posterboard-restore.py <captured-udid-directory>` exercises the
  production native graph merge and production delta injector. It compares all
  2015 original records and 905 file payloads, checks empty directories/symlinks,
  excludes foreign domains, checks the retained recovery baseline and verifies
  that incomplete snapshots stop before modifying the restore backup.
- The same harness tests a database replacement against the device's real
  MBFile archive, verifying preserved metadata and native keyed-archive UIDs.
- `GN_REAL_PB_PACK=<extracted-DVD-pack> scripts/check-template-safety.py` exercises
  the actual PosterBoard compiler with DVD Screensaver, verifies one delivery per
  wallpaper and retained SQLite rows. The expanded template suite has 16 backup
  assertions plus 31 template safety checks.
- SQLite consolidation/stitching and path-preservation regressions remain covered.

These checks verify the host restore plan. Gallery visibility and persistence
after applying this build still require confirmation on the iPhone. No wallpaper
restore was run automatically during development.

The first device retry stopped before restore while opening the native manifest.
The exported manifest contained 807 PosterBoard records and a valid Files table,
but retained WAL mode without sidecars. Snapshot reads now open the local backup
with READWRITE (without CREATE), allowing SQLite to initialise WAL bookkeeping
on iOS. SQL errors include the actual extended code and message rather than
reporting every prepare failure as a missing Files table. The restore harness
also covers this WAL shape, absent-manifest handling, and all 807 records from
the failed device run. Device confirmation of the retry is still required.

The next device run passed the snapshot stage, preserved 516 native directories,
passed the pre-restore manifest audit, and served 837 files without delegate
errors. The device returned ErrorCode 0 with last progress 99. The gateway had
incorrectly required 100 even with an explicit success response. Completion now
uses the explicit device verdict first; without a verdict it still requires
100. Nonzero errors and FFI failures continue to fail. The production verdict
rule is covered by `scripts/check-restore-completion.py` (10 cases).

## 2026-10-29 — the whole container is imported, the delta is delivered

Step 4 above ("import the original PosterBoard manifest records and regular
payloads") turned out to be the one thing this port did that the reference
never does, and it is the suspect for "applying wallpapers left the store
empty": a restore that re-imports every file the container holds hands the
restore agent the live store's whole tree to recreate — 800+ files and 1000+
directory records, all of them already on the device, byte for byte — and buys
nothing for it. The reference restores only the delta (the database, the new
descriptors, the refresh preferences) and leaves the container alone.

`PosterBoardSnapshot.merge(from:into:delivering:)` now takes the run's own
paths. Records outside that set keep their native role as *metadata donors*
(`preservedDirectories` / `preservedFileMetadata`, which is what keeps a
same-path replacement stamped with the device's protection class, inode and
keyed UIDs) but are neither copied into the restore nor given file rows — a
file row without a payload is `MBErrorDomain/205`. `nil` still imports
everything, which is what `retainBaseline` needs.

The first cut of that split still kept every directory and symlink record,
arguing they carry no payload. That is wrong for the same reason a file row
without a payload is: a directory record is an instruction to **place** that
directory. A record for `Extensions/<provider>/descriptors/` whose files the
manifest does not carry makes the device create the directory and leave the
contents that were only ever there behind — and the store reconciles by
rebuilding. Only the delivered files' own ancestors (plus the domain root) are
imported now, so the delta's parents stay native and nothing else is touched.

The other mobile-only divergence is gone too: `PosterBoard.compile` used to
publish a **second copy** of every poster file under
`Extensions/com.apple.Posters.CollectionsPosterApp/descriptors/` "so it shows in
Add Wallpaper". That is a gallery *descriptor* channel, not an installed poster.
The device's iOS 27.0.1 store has no `descriptors` directory at all, no
`com.apple.Posters.CollectionsPosterApp` directory, and no stock poster carries
one; a duplicated identity under an unknown provider is one more thing the store
has to reconcile, and rebuilding is how it resolves what it cannot.

Two diagnostics were added because the failure was unreadable after the fact:
the fetched store's row counts are logged before the stitch and the staged
copy's after it (`PosterBoardStore.summary`). A schema-valid store with no
posters validates exactly like a full one, and shipping it back would erase
every wallpaper with nothing in the log to explain it; the two counts now
separate "the device handed over nothing" from "the stitch lost the rows".

`scripts/check-posterboard-restore.py` grew a `delta` mode that proves the
split: the delta's own ancestors keep their native records, a directory the
delta does not need is never placed, the delivered paths carry rows and
payloads, and an untouched container file is neither copied nor row-stamped.
`scripts/posterboard-template-check.swift` asserts one delivery per wallpaper
(no `/descriptors/` payloads, the configuration carries the assets).

Unrelated but found on the way: a PosterBoard reset and a wallpaper selection
can be armed at the same time, and a reset run returns before its packs are
read (`posterboard_tweak.py` does the same), so it empties the store and
installs none of the wallpapers the page still shows. The reset also survives
a *failed* run (it is cleared only on success), so the two can be armed
without meaning to. Apply now refuses that combination and names both halves;
the apply preview says the same before the run starts.


## 2026-10-30 — the wipe was one line of SQL: the snapshot's journal mode

Neither of the two container splits above caused the wipe. The device's own
unified log did, and the evidence is unambiguous:

```
PosterBoard: [com.apple.PosterBoard:SQLite] Database file at …-wal allowSuspend…
PosterBoard: [com.apple.PosterBoard:SQLite] [0x…] opening database at …/61/PBFPoster…
             ExtensionDataStoreSQLiteDatabase.sqlite3 w/ flags 1
PosterBoard: [com.apple.PosterBoard:SQLite] failed to run pragma 'PRAGMA journal_mode=WAL;'
PosterBoard: [com.apple.PosterBoard:SQLite] failed to init with error:
             Error Domain=com.apple.PosterBoard.PFSQLiteErrorDomain Code=8
             "attempt to write a readonly database" … {SQL=PRAGMA journal_mode=WAL;}
PosterBoard: [com.apple.PosterBoard:Migration] Pre-migration; data store never
             ever initialized; skipping migration.
```

flags 1 is `SQLITE_OPEN_READONLY`. PosterBoard opens its store read-only and
immediately asks for WAL. On a database that already declares WAL that pragma
is a no-op and succeeds — which is why healthy opens on this device (19:36:02,
flags 1) show no error at all. On the **DELETE-mode** database this app shipped
it is a write, so it fails, the store decides it was never initialised, and it
rebuilds itself from the gallery: every poster is re-registered under a new
UUID and anything whose content lives only in the store — i.e. every custom
CollectionsPoster wallpaper, the ones the store's own rows describe — is gone.
The stock posters survive because their providers regenerate them; that is why
the store afterwards still lists nine posters, none of them ours.

The mode was not chosen deliberately. `PosterBoardBackup.consolidate` copied
main + `-wal` into a scratch directory and folded them with SQLite's backup
API, then forced `PRAGMA journal_mode=DELETE` — a leftover from treating "no
sidecars at all" as the shipping requirement. The reference gets away with the
same line because iOS 26+ uploads no `-wal`, so its fetch takes the
plain-copy branch and always ships the device's own WAL header; this app's
fetch always sees a (zero-byte) `-wal` and therefore always took the branch
that rewrote the header.

The snapshot now declares WAL and stays self-contained: `fold` sets
`journal_mode=WAL`, checks that the pragma really returned `wal`, then runs
`wal_checkpoint(TRUNCATE)` and requires a zero busy count, so every page is in
the main file while the header still says WAL. `PosterBoardStore.stitch` does
the same after its own commit — a staged copy that reports anything but `wal`
is refused instead of shipped. The zero-byte `-wal`/`-shm` rows the restore
already carried are then exactly what the device's own store looks like.

One knock-on fix: a WAL-mode database with no sidecars cannot be opened
read-only (`SQLITE_CANTOPEN` at the first statement, not at open — the handle
is lazy), so `PosterBoardStore.open` probes with a statement and retries
read-write, letting SQLite create what it needs. `isEncrypted` keeps the
probe-free read-only open, because it distinguishes an encrypted payload from
a WAL-mode one by reading the failure. `scripts/posterboard-backup-check.py`
asserts the declared mode, the self-contained checkpoint and staging's mode
preservation.

The empty store a **Full Reset** installs gets the same treatment, since it is
delivered through the identical read-only open: `createEmptyDatabase` declares
WAL and checkpoints before validating, so a reset leaves the store in a shape
PosterBoard can open rather than handing it a file it responds to by rebuilding.
