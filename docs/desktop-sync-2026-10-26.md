# Desktop synchronization — 2026-10-26

Reference: fetched desktop `origin/main` at
`747adb77db2cdfa78e0679f3048dc4b884dac1a6` (9.7.2).
The adjacent checkout also contains local commit `b3ba6e7` and uncommitted
hotload/update work. Its branch and working files were preserved.

Since the previous reference (`6f4f882`), upstream changes only README and
contributor credits. Settings now links to the authors of the port's desktop
features, including MiniVoidyy's additional daemon lists, Snoolie's AAR work,
and mattisklein / Project Linwood's Siri eligibility archives. README includes
the added attributions and Prognosticate-X's iOS 27 status bar research credit.
Desktop-only GUI libraries, fonts and media conversion dependencies are not
listed as mobile dependencies. Existing mobile component credits remain.

All five generators match the adjacent desktop checkout without regeneration:
258 preference tweaks, 53 daemon groups, Skip Setup, PosterBoard resources and
CAML templates. The desktop checkout's additional local commit changes no
inputs to these generators. Reset-plan comparison passes; compile differential
passes all 3204 cases (267 selections across 12 device profiles).
Community/preset/reset checks pass all 124 assertions, including Python
decoding of Swift GN1 output.
Release device build succeeds with `scripts/build-ipa.sh Release` using
Xcode 26.6 / iOS 26.5 SDK, producing `build/GoldenNuggetMobile.ipa` (unsigned).

Existing mobile Siri hardware policy, AirLift gates, transport and restore
behavior remain as documented in the previous synchronization.
