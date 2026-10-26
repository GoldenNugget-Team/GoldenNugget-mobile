# GoldenNugget Mobile 9.7.2

## HotLoad and updates

- Ported the desktop HotLoad safety rules to Swift: remote rules are cached offline and scoped by app version, iOS version and device model. They can warn on or block flagged tweaks, hide a whole feature, force-disable specific daemons, warn about risks on the apply sheet, require an update (badNews) or act as a kill switch.
- GoldenNugget Mobile now checks its own GitHub releases automatically and from Settings, showing release notes with IPA download links. Installation stays in the existing sideloading workflow.

## General

- Preference catalog regenerated to desktop 9.7.2 parity: 258 tweaks and 53 daemon groups. Adds the experimental Limit Frame Rate to 60 FPS (ProMotion) and the replacement Hide Home Screen Search Button setting for iOS 27.1+ (the old key stays for earlier versions).
- Removed the obsolete Disable Apple Watch Face Sync, Disable Apple Watch Connection Helpers, Disable Translation Helper, Disable App Device Verification and Disable Decision Helper daemon controls; labels removed on desktop are also rejected from imported presets.
- Managed preferences applied on iOS 27 now write the HomeDomain mirror too, and page reset writes valid empty plists on every supported iOS version while clearing both copies, so a retained cfprefs mirror cannot re-apply an old tweak after restore.
- Siri AI eligibility overrides accept iOS 27.x on all iPhones. Mobile deliberately does not require Apple Intelligence hardware for enable (desktop does), and the in-app description states the difference. The unencrypted protective-backup requirement, iPhone-only gate and reset warning remain.
- Community Catalog: presets and templates carry strict `untested` metadata and show the device-testing warning; invalid flags reject the affected row.
- Templates import standalone format-3 community packages into the community library, with a link to its switches and to Batter Builder.
- Contributor credits synced with desktop 9.7.2.

## PosterBoard

- AFC push validates the complete recorded inventory before any device write: missing, truncated, linked or invalid copies fail the restore instead of reporting success.
- During pull, originals that change while copying are kept locally; the 64 MiB AFC write limit remains, so larger originals are retained until explicitly cleared.

Siri AI activation and restore have not yet been verified on a physical device with the mobile app. Reset Siri AI Overrides clears all eligibility overrides, including those installed by other tools; turning the enable switch off does not undo an applied override.

**Full Changelog**: https://github.com/GoldenNugget-Team/GoldenNugget-mobile/compare/9.7.1...9.7.2
