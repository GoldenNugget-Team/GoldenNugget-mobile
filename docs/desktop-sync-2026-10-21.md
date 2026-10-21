# Desktop synchronization — 2026-10-21

Reference: adjacent `GoldenNugget` checkout, `0f93fa26524d8bc483019fa9ea6f93117ab66dd7` (also `origin/main` at synchronization time).

## Ported

- Regenerated all 254 registry tweaks, their labels, descriptions, version bounds, and hardware requirements. Camera Control, Action Button, physical Home button and Always-On checks come from the desktop capability predicates.
- Added experimental boolean semantics: untouched controls write nothing; explicit off writes the documented rollback value, including inverted preferences. Presets retain the difference between untouched (`null`) and explicitly switched off.
- Ported resettable numeric preferences (`-1` removes the key), optional app identifiers (empty removes the key), and integer-valued reversible booleans.
- Added experimental warnings to controls, conflicting-switch exclusion, and pre-apply dependency / app identifier validation. Controls whose desktop values remain unverified are excluded from compatibility.
- Regenerated 58 daemon groups and the interface whitelist. Removed groups excluded upstream cannot enter the launchd payload through presets.
- iOS 27 status-bar archives support fixed network badges for both SIMs. Unset signal bars omit `displayValue`; explicit zero remains an override. Network type remains zero unless selected; a carrier name is required for an entry.
- Checked Skip Setup, PosterBoard embedded assets and CAML templates against the reference; no regeneration was needed.

The SwiftUI layout remains native. Desktop-only Qt navigation and desktop device transport are not copied. Mobile AirLift remains hidden from iOS 27.2 beta 3 onward as previously requested. Existing Protective / PosterBoard preservation and DVD role fixes remain included; DVD visibility still needs device confirmation.

## Validation

- All five generators pass `--check` against the reference.
- Type-sensitive compile differential: 1841 cases (263 selections across seven device profiles).
- 58 desktop preset/community regression checks include untouched and explicit-off experimental preferences, rollback roundtrip, hardware restrictions, and dependency validation.
- Status-bar regression harness checks actual archive roundtrips, fixed network types, absent bars and explicit zero.
- 31 template safety, 12 PosterBoard template backup and 14 snapshot preservation checks passed.
- Release IPA built with `scripts/build-ipa.sh Release`; source lists checked with `scripts/sync-pbxproj-sources.py --check`.

## Follow-up synchronization to 9.7.1

- Added the persistent iOS 26 incompatible-tweaks opt-in and first-visit offer.
  It bypasses version bounds consistently through the shared compatibility gate;
  hardware restrictions and unavailable registry entries remain enforced.
- First enabling status-bar modifications asks for cellular bars (0–5).
  Cancel leaves modifications disabled; confirmation persists the override and
  the completed choice.
- Empty PosterBoard databases use AUTOINCREMENT's SQLite-managed sequence table
  and must pass schema validation before reset can continue.
- Desktop Python certificate setup and Qt device-monitor signal fixes do not
  apply to native URLSession and the mobile device monitor. Passcode Themes
  remain an unported desktop feature. Existing mobile AirLift gates are retained.

- Reset-plan comparison also found missing OTA managed-preference cleanup in the
  Daemons page. It now clears MobileAsset preferences after the stock launchd
  payload, matching desktop file order and contents.

Follow-up checks: all five generators, 1841 differential compile cases,
62 community/preset checks including iOS 26 opt-in and hardware restrictions,
14 snapshot preservation checks, 12 backup checks, and reset-plan comparison.
