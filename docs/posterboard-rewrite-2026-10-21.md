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
3. Compile only the wallpaper delta. Publish new configurations and gallery
   descriptors separately; Collections gallery descriptors use the current
   `com.apple.Posters.CollectionsPosterApp` mapping shared with AirLift.
4. Pull/prune the Protective backup. Import the original PosterBoard manifest
   records and regular payloads without reconstructing them. Directory and
   symlink records survive even when no regular file needs them.
5. Inject the new delta. Existing directory records are kept verbatim. A
   same-path file replacement patches only the native archive's content size
   and digest, following the desktop donor-blob strategy. Native inode,
   protection, ownership, permissions, extended attributes and keyed UIDs remain.
   New PosterBoard rows use the measured class-4 profile.
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
  the actual PosterBoard compiler with DVD Screensaver, verifies matching
  gallery/configuration assets and retained SQLite rows. The expanded template
  suite has 16 backup assertions plus 31 template safety checks.
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
