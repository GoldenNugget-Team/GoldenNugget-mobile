# The PosterBoard port: scope, delivery, and limits

> **Status: landed (2026-09-27), zero device runs.** With the two stale-vendored-module
> phantom error sets excluded, the **8 new source files type-check at 0 errors and 0
> warnings**; the stock gate currently reports 28 errors (the known
> `Core/AfcFileExplorer.swift` phantom set) and **0 warnings** — **the 2 errors naming the
> new `appFactoryEntry` / `applications:` disappear once you rebuild Vendor.**
>
> Every gate that needs no device passes: `tweak-port-diff.py` (426 cases, re-run after the
> `TweakPayload` change) · `blob-shape-check.swift` · `skipsetup-check.swift` ·
> `check-daemons-merge.swift` · all six `gen-*` `--check` runs ·
> `sync-pbxproj-sources.py --check`.
>
> **What has not been verified**: not one real-device restore has been run. The two riskiest
> spots are not code logic but **device contracts**: (1) whether the targeted backup
> actually makes the device upload the `com.apple.PosterBoard` container, and (2) whether
> the store accepts the database written back. Both have the reference implementation
> behind them — but that reference ran on a different host.

Ported from: `~/GoldenNugget` (Python).
Landed in: `Nugget/Core/PosterBoard*.swift`, `Nugget/Views/PosterBoardView.swift`.
Reference files: `src/tweaks/posterboard/{posterboard_tweak,tendie_file,pb_config_manager,pb_config_item}.py` ·
`src/restore/{posterboard_backup,protective}.py` · `src/controllers/{video_handler.py,aar/aar.py}` ·
`src/gui/ios/posterboard.py` · `files/posterboard/`

---

## 1. What PosterBoard is, and why it is not a tweak

A wallpaper is **two things at once**:

```
<PosterBoard container>/Library/Application Support/PRBPosterExtensionDataStore/<v>/
    Extensions/<provider extension>/configurations/<poster UUID>/…      ← the descriptor directory
PBFPosterExtensionDataStoreSQLiteDatabase.sqlite3                        ← the store's own database
```

Files without the database: the wallpaper never appears in the picker. The database without
the files: the picker holds an entry whose files it cannot find. So an apply needs **three**
steps — fetch the device's own database, add rows to a copy of it, then deliver the files
and the database together.

And the database **can only come from the device**: the `poster` / `posterAttributes` /
`posterRoleMembership` tables carry the device's own provider registrations and the usage
metadata the picker sorts by, and `posterAttributes` has a
`UNIQUE(posterUUID, roleId, attributeIdentifier)` constraint. A synthesised database is at
best a wallpaper that never shows, and at worst a corrupted store.

## 2. Delivery: no second channel

Every payload still lands in `AppDomain-com.apple.PosterBoard`, through the existing
`TweakPayload → TweakInjector`. That is not a preference but a fact about evidence:
**`AppDomain-*` is the one domain class this project had production evidence for** (the
app-container PoC and the footnote's sibling rows), and its row shape was already measured
in `TweakRowProfile`. PosterBoard introduced no new row shape.

Inside **the one apply** (the reference's `_apply_tweak_pass` shape: one pass, one button,
with `needs_posterboard` deciding whether the extra stage runs at all):

```
run: applyTweaks(selection:posterBoard:…)
  ├─ TweakCompiler.compile        the tweaks, unconditionally
  ├─ if posterBoard.isActive:     ← upstream's `needs_posterboard`
  │   ① PosterBoardBackup.fetch   a targeted backup whose FactoryInfo names only
  │                              com.apple.PosterBoard (the device's own app record,
  │                              forwarded) → the database pulled out of Manifest.db by
  │                              file name → WAL-merged → <Documents>/PosterBoard/<udid>.sqlite3
  │   ② PosterBoard.compile       unpack the .tendies → recursive_add routing + UUID/id
  │                              randomisation + the plist rewrites → PosterBoardStore.stitch
  │                              adds rows to a copy of the database → [TweakPayload]
  └─ deliver                      skip setup + tweaks + wallpapers, ONE array:
                                  protective backup (the authorising session) → prune → inject → restore
```

**There is no separate Apply for wallpapers.**  The port had one for a while — a second
button running the same four stages over a different payload set — and it was removed on
request: two runs of the same pipeline is two backups, two restores, two chances to leave
the device half-applied, and no way to tell from the log which one carried what.  The
PosterBoard page now edits a selection that `RootView` owns and the **home page's Apply**
delivers, which is also the only arrangement that works: a `NavigationSplitView` destroys the
detail view on every sidebar selection, so a selection held by the page would be gone by the
time the user reached the button.

- **Two mobilebackup2 exchanges**, deliberately not fused: the protective backup's
  `FactoryInfo` says "no app containers" (`{"Applications": {}}`), which is exactly what
  makes it fast and what the existing production evidence covers. Reshaping the one path
  known to work, to save one exchange, is not a trade worth making.
- **②'s output can be large** (a video wallpaper is hundreds of JPEG frames plus the video
  itself), so `TweakPayload` is now **either in memory or on disk** (`source:` / `contents:`,
  with every consumer going through `bytes()` / `byteCount`). The injector reads each
  payload once: the write, the length and the Digest share one read.
- The database is fetched **before** the compile (the compile needs it) but still **before**
  the expensive protective backup. A reset needs no database at all, so a reset-only apply
  is compile-first in the full sense.

## 3. The device contract: the only new interface in this port

### 3.1 Asking the device for one container

Which app containers the device uploads is decided by the factory info it is handed. This
PoC previously only ever sent `{"Applications": {}}`. Added:

| Layer | Change |
|---|---|
| `Vendor/MinimuxerGateway/idevice/IdeviceGateway.swift` | `syncAppFactoryEntry(bundleId:)` (the device's own `installation_proxy` record), `plistNode(from:)` (Foundation → `plist_t`, distinguishing Bool from NSNumber by CF type), `factoryInfo(applications:)`; a new `applications:` parameter on `backupBackup` |
| `Vendor/MinimuxerSources/MinimuxerApi.swift` | the same two layers: `appFactoryEntry(bundleId:)` + `backupBackup(…, applications:)` |
| `Nugget/Core/HostManifests.swift` | `ensure(…, applications:)` — the same dictionary has to go into both `Info.plist` (what pymobiledevice3 hands the device) and the `FactoryInfo` message (the path minimuxer takes). Both, because which one the device reads has not been distinguished on a real device |

**The record is forwarded, not composed.** The reference's `_add_posterboard_container`
hand-builds `Container` / `ApplicationSINF` / `iTunesMetadata` / `PlaceholderIcon` (the last
two are usually just defaults on a system app); here the dictionary `installation_proxy`
returned is forwarded as-is — the shape is the device's contract, and a hand-built copy
would have to be re-checked against every iOS release. `plistNode(from:)` decides Bool by
`CFGetTypeID(number) == CFBooleanGetTypeID()` rather than `as? Bool`: a plist integer is an
`NSNumber`, and `NSNumber(1) as? Bool` is `true`, so the latter would turn every 1 in the
record into a boolean.

### 3.2 Fetching and merging the database (`PosterBoardBackup`)

- **Matched by file name**, not by path. The **highest** matching path wins (the structure
  version sorts), i.e. the newest layout — the reference's own rule
  (`extract_posterboard_db` sorts its candidates by path, descending).

  The two path shapes seen so far are **not the same backup flow**, so neither can be
  assumed for the other:

  | Source | Shape |
  |---|---|
  | iTunes/MobileSync **full** backup, iPad16,2 iOS 27.0 (24A5424a) | `AppDomain-com.apple.PosterBoard` + `Library/Application Support/PRBPosterExtensionDataStore/61/<name>.sqlite3` — **no** `Containers/`, and no path in that backup starts with `/` |
  | mobilebackup2 **targeted** backup (what this app does) | `/.b/<n>/Containers/…` — the reference's `_posterboard_db_match` docstring names this as the iOS 27 upload shape, and its diagnostics count rows `LIKE '%Containers/%'` |

  What this app's targeted fetch actually produces has **not** been captured yet, which is
  why `extract` also carries a lookup that ignores the manifest entirely and identifies the
  store by content (a SQLite file with the store's `poster` table).
- **The WAL must be merged**: the store runs in WAL mode, so recent wallpaper data can live
  in the `-wal`, and copying the bare main file would lose it. SQLite's online-backup API
  does the fold (the reference's `src.backup(merged)`), and the `-shm` is deliberately
  **not** copied — a stale shared-memory file desyncs against the WAL and is a classic
  "database disk image is malformed". A failed fold, or a database that does not validate
  afterwards, falls back to the plain main file, exactly as the reference does.
- **The structure version is read out of the path** (`PRBPosterExtensionDataStore/<v>/`),
  falling back to 61 only when the path does not name the store directory — the reference's
  own fallback. The wrong version lands the injected database in a directory the device
  never reads.

Every premise the extraction depends on has been checked against **the device's own
database**, taken from that iPad's iTunes backup (`sha1("<domain>-<relativePath>")` →
`5d/5d32a1d1…`, 49152 bytes):

| Premise | Result |
|---|---|
| the fileID rule + shard layout resolve the payload | ✅ the file is at the computed path |
| the store has a `poster` table (the marker the content lookup matches on) | ✅ |
| `PRAGMA integrity_check` | ✅ `ok` |
| `requiredTables` — `poster`, `posterAttributes`, `posterRoleMembership`, `sqlite_sequence` | ✅ all present (so even `strict` validation passes) |
| structure version out of the path | ✅ `…/PRBPosterExtensionDataStore/61/` → 61 |

The manifest of that backup carries **no `-wal` sibling row** for the store, so "found the
database, no WAL companion" is the normal case rather than a symptom.

### 3.3 Stitching (`PosterBoardStore`)

A line-by-line port of `PBConfigManager.update_sqlite`, all inside one transaction, with
**update first and insert only when nothing matched** (a freshly fetched database can
already carry a row for the same UUID, and the attribute/membership tables may hold orphans
from an earlier failed apply). `posterId` counts up from `MAX(posterId)`, **not** from
`sqlite_sequence.seq + 1`: the sequence drifts in a database that has had rows deleted, and
a primary-key clash is a failed apply or a corrupted store.

The `attributePayload` JSON is written by hand in the reference's key order, and its three
timestamps are three separate clock reads (the reference makes three `time.time()` calls,
not one clock plus offsets).

## 4. The compile stage (`PosterBoard`)

The port of `apply_tweak`. Three things matter:

1. **`recursive_add`'s two modes** are the whole algorithm. Not adding: look for two kinds
   of directory — `container/` (a whole data-store snapshot, walked from the store root) and
   any directory whose name contains `descriptor` (a wallpaper, routed into
   `Extensions/<extension>/configurations`). Adding: only the **first level** under the
   `descriptors/` marker is renamed to a fresh UUID and registered as a wallpaper — the
   recursive call does **not** pass `randomizeUUID` on, so `versions/0/contents/` keeps the
   device's own naming. This was misread once: renaming every level would rewrite the store
   layout wholesale.
2. **Three plist rewrites** (`update_plist_id` + `update_for_family`):
   `provider.descriptor.identifier` written as numeric text, the
   `wallpaperRepresentingIdentifier` in `contents.userInfo`, and `*Wallpaper.plist`'s
   top-level `identifier` plus the Marble alignment (family/name forced to Lavender, the
   nested id synced with the top-level one). MercuryPoster is **skipped entirely** — its
   identifier is textual (`v6x.colorB`) and rewriting it breaks the lookup chain.
   Two details of those rewrites are load-bearing rather than cosmetic, and both were
   wrong here until the identity harness caught them (`scripts/posterboard-identity-check.swift`):

   | Detail | Upstream | What the wrong version did |
   |---|---|---|
   | `wallpaperRepresentingIdentifier` is written at the **top level** (`recursive=False`) and as a **string** | `str(randomizedID)` | `recursive: true` **only ever replaces a key that already exists**, and a third-party tendie's `userInfo` ships **without** the key — so nothing was written at all (WallpaperKit force-unwraps nil and traps, `EXC_BREAKPOINT`, in `makeViewProvider`), *and* the nested `suggestionMetadata` copy of the key was overwritten with an integer |
   | A descriptor with **no** `provider.descriptor.identifier` sidecar gets one, carrying the same id | stamped in `recursive_add`'s `randomizeUUID` branch | the sidecar was simply never created, so PosterKit invented an identifier that disagreed with the two plists |

   The walk's junk skip is Finder junk (`.DS_Store`, `._*`, `__MACOSX`), **not** "anything
   starting with a dot": `.com.apple.posterkit.provider.contents.configurableOptions.plist`
   is a legitimate descriptor plist (Apple hides it with a leading dot) and carries
   `preferredRenderingConfiguration`, which the poster editor reads for depth — skipping it
   shipped a descriptor with no depth controls. (AirLift's `randomizeIdentifiers` is a
   different path — a device-side rewrite, not an injected payload — and is unchanged.)
3. **`update_for_family` emits XML** (`plistlib.dumps`'s default) while the reset
   preferences plist is **binary** (the reference asks for `FMT_BINARY` explicitly). The
   difference is the reference's, not a transcription slip.

**Deliberate divergences** (all logged):

| Divergence | Reason |
|---|---|
| A tendie unpacks into a directory named after the **pack**, not a `uuid4()` | The reference walks `os.listdir` over UUID-named directories, i.e. in filesystem order; this port wants a run to be reproducible |
| The three configconversion plists go in **name** order | Same; `os.listdir` order is not a contract (the manifest is keyed by path) |
| A pack with neither a descriptor nor a container is **refused at import** | Otherwise it is an apply that does nothing |
| No templates parameter | Templates is not ported — see §6 |

## 5. Video (`PosterBoardVideo`)

Both of the reference's routes are ported:

- **live photo** (`Loop` off): the video goes into a Photos poster descriptor and rides
  inside a `.aar` built from `aar.py`'s two hardcoded headers (a 2-byte blob while the size
  fits in 64 KB, otherwise the subtype byte flips to `B` and the header grows by two, with
  its own length field following). A freeze frame is **required** — the reference raises
  without a thumbnail, and this does too.
- **CoreAnimation loop** (`Loop` on): every frame is decoded to a JPEG and referenced by a
  `main.caml` keyframe animation, capped at 400 frames.

Against the reference:

| | Reference | Here |
|---|---|---|
| Decoding | OpenCV (does not exist on iOS) | `AVAssetReader` + `VTCreateCGImageFromPixelBuffer`, decoded sequentially (`AVAssetImageGenerator` seeks 400 times) |
| Frame size | cv2's stored orientation, rotation **not** applied | The same, **deliberately** — the caml's `bounds` has to equal the JPEGs' real pixels. A clip carrying a rotation transform will sit sideways on the Lock Screen, and that **goes into the log** |
| MOV conversion | `ffmpeg -c:v copy -c:a copy` | `AVAssetExportPresetPassthrough` (the equivalent rewrap) |
| Memory | The whole video read into `bytes` | The `.aar` is assembled through file handles; frames are written one at a time |

`main.caml` / `index.xml` are **not transcribed**:
`scripts/gen-pb-templates-from-goldennugget.py` lifts the three string literals out of
`video_handler.py` with `ast.get_source_segment` (keeping the `{width}` placeholders as
written) and applies only mechanical substitution — and it **fails if any `{}` survives**,
so a placeholder upstream adds fails the script instead of reaching a device as a literal
`{width}`. Tabs and the trailing newline are preserved (`swift_lines` emits one literal per
line: a Swift multi-line literal strips the closing delimiter's indentation, and these lines
begin with tabs). The assets (the three configconversion plists, the live-photo skeleton,
the VideoCAML skeleton, `contents.plist`) are embedded base64 in
`Nugget/Core/PosterBoardResources.swift` by
`scripts/gen-pb-resources-from-goldennugget.py` — **not** shipped as bundle resources,
because this project is built by both Xcode and xtool from one source list, and a resource
added to only one manifest would leave two bundles quietly disagreeing.

## 6. Not ported: Templates

A `.template` is a file format of its own (`config.json` + replace / remove / set / picker /
bundle_id options + preview images / banner / stylesheet) that depends on the template asset
library, and the reference itself lists Templates and PosterBoard as two separate un-ported
features and excludes both from an exported preset. The work is `template_file.py` (313
lines) + `template_options/` (~600 lines) + a new UI, orthogonal to this port — so it **does
not appear on the page**, and a preset import reports it per
`GoldenNuggetPresetImport.unported`.

## 7. Using it

Home → **PosterBoard**:

1. **Store database** shows when the database was last fetched and how big it is; **Fetch
   database from device** runs the fetch on its own (matching the reference's "Fetch
   Database File" wizard — the fetch is the one stage of an apply that can fail by itself,
   since the device decides whether it will upload the container, so it is worth its own
   button). The switch under it is the reference's `auto_refresh_posterboard` (**on** by
   default, matching upstream): each apply then also writes a `PBF_RESET_FILE_PROTECTIONS`
   preference, which is what makes PosterBoard re-read the store at boot.
2. **Wallpaper packs**: import `.tendies` (a ZIP). Each row shows its descriptor count; a
   `container` pack says it may need a reset first — **that is upstream's own words**
   (`unsafe_container`), not a judgement made here. The cap is 10 descriptors, as
   `verify_tendie` has it.
3. **Video wallpaper**: pick a video (required), then the optional reverse /
   cover-the-clock / calculation mode when Looping is on; a `.heic` freeze frame when it is
   off. Looping decodes the video into frames — **slow, and large** — and the log reports
   the frame count, resolution, frame rate and duration.
4. **Reset**: Full Reset (zero the store's three subtrees, lay down an empty schema-only
   database, write the preferences plist) or the three selective resets (Collections /
   Suggested Photos / Gallery Cache, each a 0-byte file over its directory). **The reset
   choice is not persisted**: it is a one-shot instruction, and a "Full Reset" that survives
   a launch is a loaded gun (upstream keeps it in memory too).
5. Then press **Apply** on the home page — it carries this page's selection together with
   the tweaks, in one backup and one restore, and names itself for what it will carry
   ("Apply Tweaks & Wallpapers" / "Apply Wallpapers" / "Apply Tweaks"). **Reboot the device
   afterwards**; the store is read at boot. The full log is in the run log.

## 8. Limits (read this first)

1. **No device run.** The risk sits in §3's two device contracts; the logic itself has the
   426-case differential test and the blob-shape regression behind it. For the first run:
   **Fetch database** alone first (it can fail without damaging the store), then a small
   **descriptor** (non-container) pack, then video.
2. **A container `.tendies` is the class the reference itself marks `unsafe_container`** (the
   pack carries a `PBFPosterExtensionDataStoreSQLiteDatabase.sqlite3`). The reference's
   advice is that all wallpapers may need resetting first. That warning is reproduced
   verbatim, but a reset is **not** forced in code. The container branch's paths start with
   `/` (`recursive_add(restore_path="/")`), so its fileIDs differ from the device's own
   convention (no leading slash). That is the reference's behaviour, left alone; descriptor
   paths do not have the problem.
3. **The store is read at boot**, so an apply takes effect on the next boot.
4. **Encrypted backups are not supported**: `PosterBoardStore.isEncrypted` catches it on the
   fetched database (a plaintext payload injected into an encrypted store cannot be
   decrypted by the restore agent — `MBErrorDomain/205`), while backups as a whole are
   caught by `Diagnostics.preflightBackupEncryption()`, which is not this page's business.
5. **A reset makes the database fetched before it stale**; the next apply fetches a fresh
   one, and the page says so.
6. **There is exactly one source for `structureVersion`**: the fetched database's path. A
   reset-only apply has no database and uses the reference's fallback of 61 — so if the
   device's store directory is not 61, the reset lands in the wrong directory. The reference
   has the same problem.
7. **`plistlib`'s key order is not reproduced**: Python sorts keys on the way out of an XML
   plist, `PropertyListSerialization` writes them in dictionary order. A plist dictionary is
   unordered on read and the device compares values; the injector computes its Digest over
   these bytes itself, so nothing downstream is affected.

## 9. Gates

```bash
# Regenerate the two declarative PosterBoard artefacts (after upstream changes
#   files/posterboard/ or video_handler.py)
scripts/gen-pb-resources-from-goldennugget.py [--check]
scripts/gen-pb-templates-from-goldennugget.py [--check]

# The routine gates (sync-pbxproj-sources.py is mandatory after adding/removing files under Nugget/)
scripts/typecheck.sh "" --first PosterBoard.swift
scripts/sync-pbxproj-sources.py
scripts/check-linked-symbols.py               # see §3.3: the gateway's C calls are a link-time contract
python3 scripts/tweak-port-diff.py            # needs packaging; see docs/tweak-port.md §4.3

# The PosterBoard identity harness (see §4 item 2) — no device, no SDK:
#   cat Nugget/Core/PosterBoard.swift scripts/posterboard-identity-check.swift \
#     > /tmp/pbcheck/main.swift
#   && swiftc -swift-version 5 /tmp/pbcheck/main.swift -o /tmp/pbcheck/check
#   && /tmp/pbcheck/check
# Run it against `git show HEAD:Nugget/Core/PosterBoard.swift` too when a change here
# claims to fix something: 7 of its assertions fail against the pre-fix file, which is
# the only evidence that it can fail at all.
```

**A gate that passes is not a gate that ran.**  `check-linked-symbols.py` is the one this port
needed and did not have: `plist_new_date` is declared in the vendored `plist.h`, so it
compiled, and the device build then died at the link with `Undefined symbols …
_plist_new_date` — the archive that gets linked (`libidevice_ffi.a`) does not export it,
while the one that does (`libimobiledevice.a`) is never linked.  The first version of the
script passed anyway: its regex attached the name suffix to only the last alternative, so not
one `plist_*` call was ever matched — 43 symbols are referenced today and it reported 23.  The
fix came from running the script **the other way round** (a probe calling a symbol the archive
does not export has to make it fail), and that reversed run is now the only reason to trust its
forward "OK".

**One trap in `scripts/typecheck.sh` (measured here)**: `Core/AfcFileExplorer.swift` has a
permanent 28 phantom errors from the stale vendored module, and `swiftc` **stops reporting
after the first failing file** — so everything after it is **not checked at all**. Checking
new files therefore needs `--first`; this port was checked by excluding
`AfcFileExplorer.swift` / `AfcMediaBackup.swift` and hoisting file groups.

**Two gate defects fixed on the way** (neither introduced here, both able to read
"unchecked" as "passing"):

| File | Defect |
|---|---|
| `scripts/tweak-port-diff.py` | `HARNESS_SOURCES` was missing `TweakCatalogDaemons.swift`, while `TweakCatalog.allWithDaemons` references `daemonSpecs` / `screenTimeSpec` — so the differential test had **not compiled** since the daemons port (2026-09-26) |
| `scripts/gen-daemons-from-goldennugget.py` | `--check` called `len(DaemonGroupsCount(data))` on an int — a `TypeError`, so that gate either threw or reported drift and had never once reported a match |

## 10. Evidence

- **Differential test**: `tweak-port-diff.py` → 426 cases, every field equal (re-run after
  `TweakPayload` became "memory or disk"; the compile stage's behaviour is unchanged).
- **Descriptor identity**: `posterboard-identity-check.swift` → 19 assertions over three
  fixtures (a bare third-party Collections descriptor, a Mercury one, one that already
  ships a sidecar). Verified in both directions: all pass on the current file, **7 fail**
  on `git show HEAD:Nugget/Core/PosterBoard.swift` — the missing sidecar, the absent
  `wallpaperRepresentingIdentifier`, its nested copy being clobbered with an integer, and
  the hidden `configurableOptions.plist` being dropped.
- **Blob shape**: `blob-shape-check.swift` → 34918 device blobs, 0 unreadable `Mode`, 0
  reference-valued scalars; the per-domain Digest rule holds.
- **skip_setup / daemons**: both key-by-key harnesses pass.
- **Generators idempotent**: all six `gen-*` `--check` runs say "matches".
- **Type check**: the 8 new files at 0 errors and 0 warnings (with the stale-module phantom
  sets excluded); the stock gate's 28 errors are all the known `AfcFileExplorer.swift`
  phantoms, and 0 warnings.
