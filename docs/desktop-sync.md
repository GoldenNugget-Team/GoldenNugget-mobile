# Desktop synchronization — 2026-10-18

Reference: `GoldenNugget-Team/GoldenNugget`, main commit
`b4b8c65` (GoldenNugget 9.7 beta 1). The adjacent checkout was fetched and
matched `origin/main` at synchronization time. Desktop sources were not modified.

## Catalog and behavior

- The generated registry contains all 134 desktop plist tweaks, including
  experimental RSSI and the reversible Dynamic Island switch. Applying the
  latter while disabled writes `false`, matching `ReversibleBooleanPlistTweak`.
- Dynamic Island hardware requirements are used by the list, preset import,
  preview, conflict check and compiler. Known models are generated from the
  desktop capability module rather than maintained independently.
- All 59 daemon groups and their labels/whitelist/recommended set are generated
  from desktop. Switch ordering and titles now come directly from the two GUI
  row tables; the generator fails if it cannot recognize those tables.
- Preset exports aggregate daemon groups into desktop's single `Daemons` entry.
  Existing mobile group-shaped documents remain readable. A disabled imported
  daemon entry clears the prior group selection.
- Carrier archive entries use neutral network type and signal defaults (zero),
  matching the desktop fix. Explicit badge and bar overrides still work.
- PosterBoard resources, CAML templates, Skip Setup panes, protective filters
  and page-reset plans were checked against desktop.

## Community Catalog

The sidebar has a dedicated Community Catalog page. It reads the same Pages
index, validates rows independently, supports search/iOS filtering/favorites,
marks installed entries and available updates, and falls back to a validated
offline cache. Template downloads use the fixed catalog URL, a 25 MiB cap and
the index's byte count/SHA-256 before loading.

GN1 share codes use the desktop's base64url/zlib/JSON format. Decoding has
compressed/expanded limits and fills disabled registry entries. The page can
create/share a QR code and read one from an imported image. Import saves a
preset; the user loads it in Presets and confirms the ordinary home Apply.

Format-3 `.batter` community packages support switches, sliders, text, choices,
recursive `$value` substitution, `writes_off`, version bounds, plist merges,
binary resource files, valid empty plists and file ownership. The library
persists activation/state separately from downloads. Preview and apply use the
same merged payloads; built-in plist keys take precedence. Conflicting whole
community writes fail before restore.

Successful community writes are recorded per UDID. Reset empties only recorded
Managed Preferences, using valid plists; other replaced files are listed for
manual recovery, as in desktop's `reset_plan`. Removing a template from the
library does not claim to restore the device's original files.

The preset manager imports/exports `.gnpreset` with manifest limits, exact asset
membership, safe archive paths, SHA-256 checks and isolated import directories.
Template assets activate only on explicit preset load. Saves, partial exports
and successful-apply rollback snapshots preserve template state.

## Platform boundaries

This sync carries the existing mobile restore and sandbox mechanisms forward.
It does not add a Qt runtime. Legacy wallpaper `.batter` packages with container
editing/options use the separate Templates page merged from mobile main. The
Community Catalog loader accepts community-only format-3 packages and directs
other packages to that editor rather than ignoring their options. The existing Icon Themes preset payload
and classic status-bar preset-byte limitations remain reported on import. Asset
transport in a portable preset does not imply those editors are implemented.

Encrypted backup handling and desktop-only device management retain the mobile
limitations described in the existing port documents. Real restore, pairing and
SpringBoard rendering still require device verification.

## Reproducible checks

```sh
python3 scripts/gen-tweaks-from-goldennugget.py --goldennugget ../GoldenNugget --check
python3 scripts/gen-daemons-from-goldennugget.py --goldennugget ../GoldenNugget --check
python3 scripts/gen-pb-resources-from-goldennugget.py --goldennugget ../GoldenNugget --check
python3 scripts/gen-pb-templates-from-goldennugget.py --goldennugget ../GoldenNugget --check
python3 scripts/gen-skipsetup-from-goldennugget.py --goldennugget ../GoldenNugget --check
python3 scripts/tweak-port-diff.py --goldennugget ../GoldenNugget
python3 scripts/reset-port-diff.py --goldennugget ../GoldenNugget
python3 scripts/check-desktop-sync.py
python3 scripts/check-protective-filters.py
python3 scripts/check-tunnel-endpoint.py
scripts/build-ipa.sh Release
```

The community/preset harness compiles production Swift and the actual vendored
ZIPFoundation on macOS with isolated persistence. It covers Python/Swift GN1
interoperability, decompression limits, catalog rejection, compatibility,
reversibility, daemon exports, template controls/sources, traversal/symlink
rejection, malformed inputs, ownership, write precedence, portable roundtrips,
checksums, activation and device-scoped reset history. `--live-index PATH` also
checks a downloaded catalog without making the offline test depend on network.

Validated: 715 differential compile cases (143 selections × five device
profiles); 44 community/preset checks including the live index, plus Python
decoding Swift's GN1 output; 31 protective-filter cases; nine tunnel endpoint
cases. The existing daemon merge, status-bar layout, conflict and apply-preview
harnesses pass. Release device IPA builds with Xcode 26.6/iOS 26.5 SDK.
