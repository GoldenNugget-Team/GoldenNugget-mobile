# Desktop synchronization — 2026-10-22

Reference: adjacent `GoldenNugget` checkout at
`5fd115af2aafa3a3a367de96bdbfa05f08e9a76d`, matching `origin/main` after fetch.
Desktop sources were not modified.

- Generated all 256 registry entries, including Siri AI and Reset Siri AI
  Overrides. Supported-model lists now participate in shared compatibility
  checks. Both Siri operations require exactly iPhone17,1 / iOS 27.0, including
  when the iOS 26 incompatible-tweaks opt-in is enabled.
- Siri operations emit the original Project Linwood NSKeyedArchive bytes,
  embedded by the catalog generator after desktop's SHA-256 validation. They
  never pass through the preference-dictionary writer. Turning a switch off
  only deselects the operation; the dedicated reset writes the original valid
  empty-map archive. The existing exclusivity and warning UI carries desktop's
  restrictions and consent / language / reboot instructions.
- Eligibility archive delivery requires the protective-backup branch and a
  Manifest.plist explicitly declaring an unencrypted backup. Forced partial
  restore is refused. The eligibilityd domain uses root:root ownership,
  file mode 0644 / protection class 4, and directory mode 0755 / class 0.
- Mobile already catches unreadable wallpaper ZIP imports and displays an
  import error. Desktop Qt navigation/slogans and CI workflow changes do not
  apply to the native SwiftUI interface and mobile build workflow.
- Project Linwood's MIT notice and upstream payload documentation are retained
  in `docs/licenses/siri_ai/`.

## Validation

The five generators and page-reset differential comparison pass against this
reference. The compile differential now includes exact Siri archive bytes,
conflicting actions, iOS 27.0.1 and another iPhone model. The community/preset
harness includes Siri enable/reset/off behavior, exclusivity, and the strict
model/version gate with incompatible tweaks enabled. The existing injector
harness also checks the eligibility file and every generated directory's
ownership, mode, protection class, absence of digest/extended attributes, and
payload bytes, alongside PosterBoard snapshot preservation.

Actual Siri activation and restore on a physical device remain unverified.
Upstream only reports verification on iPhone 16 Pro, iOS 27.0 build 24A437.

Completed checks: 2385 differential compile cases (265 selections across nine
profiles), 68 community/preset checks plus Python decoding Swift GN1 output,
31 protective-filter checks, 31 template-safety and 16 template-backup checks,
and the PosterBoard/eligibility injector harness. All five generators and
Xcode source-list checks pass. `scripts/build-ipa.sh Release` produced
`build/GoldenNuggetMobile.ipa` (unsigned) with Xcode 26.6 / iOS 26.5 SDK.
