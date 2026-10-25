# Desktop synchronization — 2026-10-25

Reference: adjacent `GoldenNugget` checkout at
`6f4f882a24141b4d9277cbd5b5808562cd2b32f5` (9.7.2), matching
`origin/main` after fetch. Desktop source files and its untracked `AutoSave.json`
were left intact. Existing mobile changes were retained.

## Changes

- Regenerated 258 preference tweaks and 53 daemon groups. Added the experimental
  60 FPS limit and the iOS 27.1 Home Screen search key, preserving explicit-off
  rollback semantics. The old search key is restricted to versions before 27.1.
- Removed NanoTimeKit, AppleWatchNano, Translate, DeviceCheck and Decisiond.
  Generated allowlists also exclude removed labels from imported presets.
- Siri enable/reset accept iOS 27.x, still excluding iOS 26 (including its
  incompatible-tweaks opt-in) and iOS 28. The existing mobile policy permitting
  all iPhones is retained: desktop now requires Apple Intelligence hardware for
  enable, whereas mobile deliberately does not. The mobile description states
  this difference. The original archive bytes, unencrypted protective-backup
  requirement, iPhone-only gate and reset warning remain in force.
- Applying built-in or community managed preferences on iOS 27 writes the
  corresponding HomeDomain plist too. Mirrors use the final merged dictionary
  and mobile ownership; preview and apply share the same merge path. Explicit
  community mirrors are retained for community-only writes, matching desktop.
- Page reset writes valid empty dictionaries on both iOS 26 and 27 and clears
  managed-preference mirrors, deduplicating shared targets. Stock launchd
  values and status-bar payloads retain their dedicated formats.
- AFC push checks the complete recorded inventory before any device write:
  missing, truncated, linked and invalid paths fail. Partial restore is reported
  as failure. Pull rechecks source size, timestamp and type before deletion.
  Copies remain available locally until explicitly cleared. The mobile 64 MiB
  AFC write limit remains: larger originals are retained during pull.
- Community Catalog parses strict boolean `untested` metadata for presets and
  templates and displays the device-testing warning. Omitted flags default to
  false; invalid flags reject the affected row. Truncated GN1 zlib streams are
  covered by regression checks; the existing Swift decoder already rejects them.
- Templates can import standalone format-3 community packages into the existing
  community library, with a link to its switches and to Batter Builder. Legacy
  wallpaper options continue through the existing native template editor.

## Platform boundaries

Desktop Qt layout, translation resources, Python worker/session refactors and
Python-specific I/O optimizations are not copied into the SwiftUI application.
Native PosterBoard resources, CAML templates and Skip Setup already match this
reference. Existing AirLift availability gates and mobile transport remain.
Mixed legacy-container/community packages, icon-theme and passcode-theme parity
retain their previously documented limitations. Physical-device restore and
Siri activation still require hardware verification.

## Validation

All five generated catalogs and Xcode source membership match their sources.
Compile differential: 3204 cases (267 selections across 12 profiles, including
iOS 27.1, 27.2 and 28). Reset-plan source comparison passes against the new
unconditional empty-plist behavior. Simulator regression: 41 checks across
17 scenarios, with no failures, on iOS 26.5 using production Swift and hardware
doubles. Community/preset/reset harness: 124 checks plus Python decoding Swift's
GN1 output. Protective filters: 31 checks. Template safety: 31 checks; template
backup: 16 checks; PosterBoard snapshot preservation: 14 checks. All passed.
Release device build succeeded with Xcode 26.6 / iOS 26.5 SDK and produced
`build/GoldenNuggetMobile.ipa` (unsigned), including icon-appearance and binary
freshness checks.

```sh
python3 scripts/tweak-port-diff.py --goldennugget ../GoldenNugget
python3 scripts/reset-port-diff.py --goldennugget ../GoldenNugget
python3 scripts/check-desktop-sync.py
python3 scripts/check-protective-filters.py
python3 scripts/check-template-safety.py
python3 scripts/check-posterboard-preservation.py
python3 scripts/test-audit-regressions.py --device <booted-simulator-udid>
scripts/build-ipa.sh Release
```
