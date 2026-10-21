# GoldenNugget Mobile — Desktop 9.7.1 Sync

## General

- Add experimental Siri AI eligibility overrides for unsupported regions, plus a dedicated reset. Currently limited to iPhone 16 Pro on iOS 27.0; only build 24A437 is verified upstream. Requires Siri language English (US), an unencrypted protective backup, and a reboot.
- Expand the preference catalog to 256 tweaks, including split keyboard controls and additional hardware-specific options.
- Add an option to enable untested preference tweaks on iOS 26. Hardware restrictions and the stricter Siri AI requirements remain enforced.
- Improve iOS 27 network badges and cellular signal controls, including separate SIM settings and explicit zero-bar overrides.

## PosterBoard

- Fix Full Reset failing with a `sqlite_sequence` error on empty databases.
- Preserve native PosterBoard snapshots and manifest metadata when applying wallpaper changes.
- Improve handling of damaged or invalid `.tendies` ZIP archives with readable import errors.

## UI

- Browse tweaks and daemon groups in collapsible categories using the native SwiftUI interface.
- Show experimental warnings, hardware requirements, and conflicting-tweak restrictions before applying changes.
- Ask for a cellular signal override when status-bar modifications are first enabled.

## Fixes

- Preserve loaded preset selections after restart when autosave is enabled, including explicit experimental rollback values.
- Apply iOS 26 compatibility preferences consistently when browsing, importing presets, previewing, and compiling tweaks.
- Improve daemon configuration, reject unknown daemon labels, and match desktop OTA preference cleanup during reset.
- Refuse Siri AI delivery through forced Partial Restore or an encrypted protective backup.
- Retain the mobile AirLift availability restriction from iOS 27.2 beta 3 onward.

Siri AI activation and restore have not yet been verified on a physical device with the mobile app. Reset Siri AI Overrides clears all eligibility overrides, including those installed by other tools; turning the enable switch off does not undo an applied override.
