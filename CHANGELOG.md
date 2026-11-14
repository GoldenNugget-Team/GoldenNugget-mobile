# GoldenNugget Mobile — Desktop 9.7.7 Sync

This release ports every applicable fix from desktop 9.7.7 and, for the items
that cannot exist on an on-device app, documents why. The catalog is unchanged
at 369 tweaks; the compiler, the backups and the status-bar archive carry the
fixes.

## Fixes

- The Clear ("nullify") Screen Time tweak now delivers a valid *empty*
  XML plist (`plistlib.dumps({})`) instead of a zero-byte file. A truncated
  plist is a boot-loop input on iOS 26.2+: SpringBoard reads it at boot and
  crashes. Every plist the compiler writes now goes through the same
  serialiser, so the reset paths can never drift apart.
- An enabled blank-carrier status-bar override now builds a *hiding* cellular
  entry (issue #83). The previous code collapsed an explicitly-set empty name
  into "no entry", which folded the override into the reset record and the
  real carrier name came back after a respring. The GUI keeps showing
  "Hidden" for it.
- PosterBoard wallpapers: the solid-color image is injected into the coloured
  Background layer instead of the last self-closing CALayer (issue #90), so
  WallpaperKit's depth renderer never force-unwraps a missing image.
- A 5 GB free-disk-space preflight runs before both device backups
  (`ProtectiveBackup.requireFreeSpace`), the same static minimum
  (`MIN_FREE_DISK_GB = 5.0`) desktop enforces. The check no longer demands
  the device's whole used capacity — a 256 GB phone with 200 GB of apps was
  rejected although the selective backup only needs tens of GB; real
  exhaustion stays covered by the device's own verdict
  (`DLPurgeDiskSpace` → `MBErrorDomain/105`).
- Siri AI eligibility archives are verified against the desktop's sha256
  table before they are staged. A damaged embedded archive is skipped with a
  clear reason instead of reaching the device half-blind.
- Failed update checks are shown as a failure, never as "Up to date!", and
  hotload rules/releases are written to their cache atomically
  (already the behaviour here; re-verified against the 9.7.7 fixes).

## Documented deviations (desktop fixes with no mobile counterpart)

- Data-loss guard (`_refuse_unverified_ios27_apply`): the mobile apply has no
  path that skips the protective backup on iOS 27 — the pulled backup is the
  precondition of the restore, so the desktop failure mode (applying without
  a verified backup) cannot occur.
- Re-review after a finished apply: desktop dialog mechanics. The mobile
  preview is deliberately the *pending* plan (`ApplyPreview`), documented in
  that file's header.
- Nullify payloads "delivered as-is, without a baseline merge" and issue #85
  (unreadable managed-preference baselines degrade to whole-payload
  delivery): mobile has no content-level baseline merge at all — every
  payload is delivered verbatim — so both desktop fixes describe a code path
  that does not exist here.
- Phase 3 pre-start "Find My" wait bounded to one 15-minute window: mobile
  has no swallow-and-retry loop around Find My; restore failures fail fast
  through `ChannelRecovery.retry`, which is bounded by attempts.
- Live phase-5 media push `include_historical=False`: the mobile apply never
  pushes media back (its phase 5 is a pull into the store). The manual
  Restore-media push verifies every stored copy's size before writing and is
  the only copy of files whose originals were deleted, so the whole store is
  intentionally pushed.
- Tendie-archive re-validation right before `extractall`: the mobile
  extractor validates every entry inside the same loop that writes it, so
  the TOCTOU window is structurally closed.
- Crash-handling dialog threading, the stale progress card on cache
  restore, and repository pointers: desktop GUI/repository mechanics with no
  mobile counterpart.
- Hotload safety rules remain an empty list on mobile: the desktop rules are
  inert examples scoped to desktop build numbers (9.7 exact, 9.3/9.3.1,
  badNews ≤ 9.7.1) and never fired on mobile versioning.
