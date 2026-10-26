# HotLoad and mobile updates

The port follows the desktop HotLoad JSON format (`src/controllers/hotload.py`),
including the local desktop's `badNews` mandatory-update action. Mobile uses
its own channels so desktop app-version scopes and packages cannot accidentally
block or update the iOS app:

- Rules: `https://raw.githubusercontent.com/GoldenNugget-Team/GoldenNugget-mobile/main/hotload_rules.json`
- Releases: `https://api.github.com/repos/GoldenNugget-Team/GoldenNugget-mobile/releases/latest`

The root `hotload_rules.json` ships an empty rule list. Publishing it on `main`
makes this mobile rules endpoint available. Rules are metadata, never executable
code. `CFBundleShortVersionString` is the mobile app version used for both rule
matching and release comparison; `CFBundleVersion` remains an independent build
number and does not inherit desktop's positive-build-means-beta convention.

## Rules

`version` is a nonnegative integer and `rules` is an array. The unusual desktop
semantics are retained: a rule is active by default or with `disabled: true`;
`disabled: false` makes it inert. Optional scopes:

- `app_versions`: exact numeric mobile version matches with zero padding.
  When nonempty, this takes precedence over `min_app_version`/`max_app_version`.
- `min_app_version` / `max_app_version`: inclusive mobile version bounds.
- `min_version` / `max_version`: inclusive iOS version bounds.
- `only_models`: product identifier prefixes, for example `iPhone17`.

Device-scoped rules do not match unknown device fields. The UI reevaluates on
rules, settings and device-identity changes; operations also read the device
before capturing their policy. Disabling HotLoad skips fetches and all rules,
including the desktop's built-in Daemons restriction for iOS 26.6.1.

Actions:

| Action | Mobile behavior |
| --- | --- |
| Omitted or `flag` | Show a warning on the named tweak and in Apply confirmation. Toggle enable requires acknowledgement. Value editors show the warning; final Apply confirms it. |
| `risk` | Add the named tweak's `level` and `reason` to Apply confirmation without hiding it. |
| `hide_feature` | Hide the page/registry section, refuse hidden preset entries and suppress its compiled writes, including automatic reversible off writes. Dependencies of hidden tweaks are hidden too. |
| `disable_daemon` | Resolve `daemons` group names or raw labels through the mobile allowlist. Force those labels to true after preset/user values, even with the master daemon switch off. Fully forced groups are locked; partially forced groups show the forced-label count. |
| `kill_app` | Replace the shell with a blocking reason screen. iOS does not deliberately crash or terminate. |
| `badNews` | Replace the shell with an update-required screen, including optional release label `version`. Downloading does not dismiss the gate. Scope the rule to exclude fixed mobile builds. |

Feature names match desktop: `Liquid Glass`, `Springboard`, `Internal`,
`PosterBoard`, `Daemons`, `Status Bar`, `Templates`. Hidden features take
precedence over forced daemon writes. Ordinary tweak IDs are catalog IDs;
non-registry IDs include `Daemons`, `PosterBoard`, `StatusBar`, `Templates`.
Unknown actions/features/daemon labels cannot activate arbitrary writes.
Community writes targeting known hidden preference files are refused rather
than silently restoring hidden settings. Shared files are handled conservatively.

Example (inert until intentionally enabled):

```json
{
  "version": 2,
  "rules": [{
    "action": "badNews",
    "max_app_version": "9.7.0",
    "version": "9.7.1",
    "reason": "Install the mobile release containing the fix.",
    "disabled": false
  }]
}
```

## Startup, persistence and installation

HotLoad loads its last validated JSON synchronously from Application Support
before showing the shell, including offline mandatory-update rules. Automatic
checks run on foreground entry, at most once per hour; Settings can force either
check. Concurrent requests coalesce. Rules and release checks are independent,
use system TLS, have a 15-second request timeout and accept at most 2 MiB.
Malformed/oversized responses, HTTP errors and connection failures preserve the
last valid rules file. Replacements are atomic. Settings displays refresh errors
and last successful check times. A new install with no cache starts with no
remote rules; the built-in daemon restriction still applies when enabled.

Update detection compares numeric release components and SemVer prerelease
identifiers. Only stable, non-draft releases qualify. The app displays release
notes and offers the official mobile release page and IPA asset, with GitHub
links restricted to this repository. A failed check is distinct from being up
to date, and a missing release (404) has its own message. Installation uses the
user's existing sideloading tool; the app cannot replace its own signed binary.
Update results stay in memory for the session; HotLoad rules persist across runs.

The gate applies to the app shell and new engine/AirLift operations. It does not
forcibly kill a device restore already in progress when a network refresh lands.

## Validation

```sh
python3 scripts/check-hotload.py
python3 scripts/check-desktop-sync.py
scripts/typecheck.sh
scripts/build-ipa.sh Release
```

The dedicated harness compiles production Swift services with an isolated HTTP
protocol and temporary cache/preferences. It exercises matching, mandatory gates,
hidden/reversible writes and presets, dependencies, forced daemons overriding
presets and master-off state, risk warnings, version ordering, trusted release
links, offline/cache replacement failures, oversized responses, throttling and
concurrent checks. No real device or GitHub account is used by the harness.

Validated on 2026-10-26 with Swift 6.3.3, Xcode 26.6 and iOS 26.5 SDK:
56 isolated HotLoad/update checks, 124 existing community/preset/reset checks,
and 3204 desktop compiler differential cases passed. The device Release build
produces `build/GoldenNuggetMobile.ipa` (unsigned). Physical-device installation
and the remote mobile rules endpoint require publishing the rules file and
installing the IPA through a sideloading tool.
