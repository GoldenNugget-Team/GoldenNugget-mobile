# Siri AI eligibility archives

Source: https://github.com/mattisklein/project-linwood
Pinned commit: b9438cec65b384974a9c6be6169ec9fa1e64c83a
Author: mattisklein. MIT license reproduced in LICENSE.

`enable.data` is the original 631-byte `override_enable_gm.data`.
`reset.data` is the original 320-byte `override_reset.data`.
Both were generated using Apple's NSKeyedArchiver; never reserialize these as
ordinary preference plists. The runtime verifies their SHA-256 hashes.

Enable overrides SIRI_MODE (155), AMERICIUM (96), GREYMATTER (122) to answer 4;
AMERICIUM includes OS_ELIGIBILITY_CONTEXT_LINWOOD_AVAILABILITY = 2.
Reset is a valid archive with an empty overrideMap, not an empty file.

## Use

Internal Options contains **Siri AI (Ineligible Regions)** and **Reset Siri AI
Overrides**, mutually exclusive experimental switches. Select one, apply, and
reboot. Disabling a switch only deselects the operation. To roll back an applied
override, select Reset Siri AI Overrides and apply. This clears *all* overrides;
it does not restore a previous map. The ordinary Internal Options preference
reset does not clear these archives; use the dedicated switch.

Currently gated to iPhone 16 Pro (`iPhone17,1`), iOS 27.0. Only build 24A437 was
reported verified upstream; other builds and hardware are not verified by us.
Siri language must be English (US); complete Siri AI consent in Settings after
reboot. This does not add German voice support or guarantee server availability.

Delivery requires a prepared unencrypted protective backup. Encrypted backups,
skipping protection, and forced sparse delivery are refused for this payload.
File: `SysContainerDomain-com.apple.eligibilityd` /
`Library/Caches/NeverRestore/eligibility_overrides.data`, root:root, 0644,
protection class 4; generated directories root:root, 0755, class 0.

No real-device activation has been performed as part of this integration.
