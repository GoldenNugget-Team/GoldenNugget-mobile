# GoldenNugget tweaks port: scope, compatibility limits, usage

> **Status: landed (2026-09-24).** `scripts/typecheck.sh` reports **0 errors, no new
> warnings** (33 sources, 25 before the change). The compile stage was **differentially
> tested against the reference implementation: 142 selections × 3 device profiles = 426
> cases, every field (including plist types) identical**.
>
> **One thing unverified:** the row shapes the injector synthesises for
> `ManagedPreferencesDomain` / `HomeDomain` / `SystemPreferencesDomain` /
> `DatabaseDomain` are **measured** from a real device backup, but **no real-device
> restore has been run yet**. The `AppDomain-*` and `SysSharedContainerDomain-*`
> classes reuse paths this project already has production evidence for, byte for byte.
>
> **2026-09-27:** the Supervision page and the `supervised` / `organization_name` halves of
> `SupervisionSettings` are gone — they only recorded intent, the certificate was never
> written, and no real supervision could be installed. `skip_setup` lives on its own as a
> switch in the **Apply** section of the **Settings** page (`SkipSetupSettings`), and the
> engine always writes the un-supervised form. Reasoning in §2.3.
>
> **2026-09-27:** the page-level **reset** is ported — the home page's "Reset Tweaks"
> opens a page picker and writes the device, on both the iOS 26 and the iOS 27 branch, with
> **no psysbackup capture on either**. See §2.4.
>
> **2026-09-26:** the two `skip_setup` files are in, as a switch on the Settings page
> (**off by default**, upstream defaults to on), and the panel list is generated from the
> reference; the two deliberate divergences (not merging the device's existing cloud
> config, not writing a keybag certificate) are in §2.3 / §3.3.
>
> **2026-09-25:** a real-device apply returned `205 — "Manifest references files not in
> backup"`, traced to these 4 domains' file rows missing their `Digest` (the device writes
> it in these domains consistently and never writes it in AppDomain/SysSharedContainer).
> Fixed — see §2.2.
>
> **2026-09-27:** PosterBoard is a line of its own now — see `docs/posterboard-port.md`.
> This file is about the registry's 133 plist tweaks; wallpaper packs, video wallpapers
> and the store resets go through the **same** delivery channel
> (`TweakPayload → TweakInjector`, domain `AppDomain-com.apple.PosterBoard`) but have
> their own compile stage, their own database stage and their own page. It is also why
> `TweakPayload` can now carry a payload **on disk** as well as in memory — §2 of that
> document.
>
> A real-device build still needs `scripts/build-ipa.sh` run locally.

Ported from: `~/GoldenNugget` (Python / PySide6, `src/tweaks/` and `src/controllers/`).
Ported into: `Nugget/Core/Tweak*.swift`, `Nugget/Core/GoldenNuggetPreset.swift`,
`Nugget/Views/TweaksView.swift`.

---

## 1. Scope

### 1.1 Ported: all 133 tweaks of the registry

| Section | Count | Editor |
|---|---|---|
| Liquid Glass | 98 | toggle / number |
| SpringBoard | 17 | toggle / text / number |
| Internal Options | 18 | toggle |

**Generated field by field, not retyped.** `scripts/gen-tweaks-from-goldennugget.py`
imports the reference's `src/tweaks/registry.py` through a PySide6 stub (replacing only
`QT_TRANSLATE_NOOP`) and emits the `TweakSpec` table (`id` / `section` / `title` /
`location` / `key` / default value / `Kind` / `min_version` / `max_version` /
`iphone_only` / `ipad_only` / `description` / `factory`) straight into
`Nugget/Core/TweakCatalog.swift`, with the `FileLocation` enum generated alongside.
`--check` detects drift.
→ Upstream adds a tweak, re-run the script and it appears here; **a mistyped spec is not
possible**.

Reference semantics ported alongside it (each with its source file and function name, so
they can be checked one by one):

| Reference | Here | Notes |
|---|---|---|
| `src/restore/path_mapping.py` | `TweakDomainMap.split(path:)` | absolute path → (domain, relative path); a container domain folds the first path segment into the domain name |
| the **compile stage** of `device_manager._apply_tweak_pass` | `TweakCompiler.compile` | keys for the same `FileLocation` are **merged**; `AdvancedPlistTweak` replaces the whole dict; `.GlobalPreferences.plist` is written twice, ManagedPreferences and HomeDomain |
| `src/gui/ios/compat.py:is_tweak_compatible` | `TweakSpec.isCompatible` | `min_version`/`max_version` + `iphone_only`/`ipad_only` |
| `Tweak.set_value(..., toggle_enabled: True)` | `TweakSelection.setValue` | setting a value enables the tweak |
| `src/controllers/preset_manager.py` (preset v2 JSON) | `GoldenNuggetPreset` / `GoldenNuggetPresetImport` | see §4.2 |
| `tweak_loader._build_spec` | the generator folds `factory()`'s dict into `multiValues` | `WatchOSCompatibility`'s multi-key write |

### 1.2 Not ported (three features today)

As of 2026-09-27 what is still not carried is **Templates**, **Status Bar** and
**Icon Themes**. The table is the 2026-09-24 statement, kept for the record — the two
amendments below it say what has moved since.

Absent from the UI; on preset import each one is **reported with its reason**, never
silently dropped.

| Not ported | Why |
|---|---|
| PosterBoard | wallpapers — **the reference excludes them from presets too** ("device-specific and heavy, so they must not travel with a preset") |
| Templates | depends on the PosterBoard template library |
| Status Bar | needs the `StatusBarOverrideData` struct over CFFI (`status_bar/status_bar_c/status_setter.py`) |
| Icon Themes | needs a persistent icon resource library |
| Daemons (incl. `ClearScreenTimeAgentPlist`) | force-disabling launchd daemons is the highest-risk item; and it needs a per-switch UI over 90 `INTERFACE_KEYS` |

> **Amended 2026-09-27:** Daemons has since been ported — `TweakCatalogDaemons.swift`
> (generated) plus `Nugget/Views/DaemonsView.swift`, the ScreenTime nullify included — so
> the last row records the state as of 2026-09-24, not today. It is also the page a reset
> can act on (§2.4).
>
> **Amended 2026-09-27:** so has **PosterBoard** — wallpaper packs, video wallpapers and
> the store resets, Templates still excluded; see `docs/posterboard-port.md`. Its row
> stays for the same reason, and it is still reported by a preset import: the reference
> **itself** refuses to serialise wallpapers ("device-specific and heavy, so they must
> not travel with a preset"), so there is nothing in a preset to carry. The reason text
> now points at the PosterBoard page rather than at a missing port.

---

## 2. Delivery

Reuses this project's existing chain, **without adding a second one** (the single-channel
property still holds):

```
TweakCompiler.compile (touches no device)
        ↓
ProtectiveBackup (stage 1) → prune (stage 2) → TweakInjector (stage 3) → RestoreRunner (stage 4)
```

- Compilation finishes **before the device is touched**: an empty selection, or one where
  everything was skipped, errors out immediately rather than paying for a backup first.
- `BackupInjector.pruneAndInject` gained an optional `tweakPayloads`; `bundleID` became
  optional — because the reference's tweak-only apply **does not target the app container
  at all** (the file list of `_apply_tweak_pass` is made of tweaks only).
- Each tweak file writes 3 kinds of rows: the domain root row, one row per parent
  directory (`flags=2`), and the file row (`flags=1`), with the payload stored at
  `<aa>/<fileID>`. Inodes count up from the manifest's current maximum, **guaranteed
  unique** — the reference is explicit about it ("the agent deduplicates by inode — a clone
  sharing the donor's inode gets restored with the donor's content").
- Injection always happens **after the prune**, for the same reason as the existing
  footnote injection: the prune keeps only the reference's keep-set, these rows are not in
  it, and writing them first would have them pruned away.

### 2.1 Row shapes (measured, not guessed)

Source: `~/Library/Application Support/MobileSync/Backup/00008130-001431082E40001C`
(iPad16,2 / iOS 27.0 24A5424a). **The device's own output is the only contract.**

| Domain | File Mode | User/Group | ProtectionClass | EA publisher | File-row Digest |
|---|---|---|---|---|---|
| `ManagedPreferencesDomain` | 0755(3)/0644(1) | 501/501 | 4 | `com.apple.BackupAgent2` | **yes** 4/4 |
| `HomeDomain` | 0600(526)/0644(181) | 501/501 | 4 | `com.apple.BackupAgent2` | **yes** 708/708 |
| `SystemPreferencesDomain` | 0644 | 0/0 | 4 | **none** | **yes** 9/9 |
| `DatabaseDomain` | 0644(2)/0755(1) | 0/0 | 4 | `com.apple.BackupAgent2` | **yes** 3/3 |
| `SysSharedContainerDomain-*` | 0644 | -2/-2 | 4 | `com.apple.containermanagerd_system` | **no** 0/10 |
| `AppDomain-*` | 0644 | 501/501 | 3 | `com.apple.containermanagerd_system` | **no** 0/2760 |

Directory rows: domain root `0/0` (the `SysSharedContainerDomain-*` root is class 0), the
intermediate directories follow the domain (`ManagedPreferencesDomain` is 501/501 class 4,
`HomeDomain` is 501/501 class 0). Directory rows and symlink rows carry **no Digest in any
domain**.

> The reference stamps every plist tweak with `Tweak.__init__`'s default
> `owner=501, group=501`, but **the device's own rows differ per domain** (the footnote row
> is `-2/-2`, `DatabaseDomain` is `0/0`). The device's record wins, so
> owner/group/protectionClass/EA are collected in `TweakRowProfile` and chosen per domain
> rather than copied as 501.

### 2.2 `Digest`: two classes by domain, completed 2026-09-25

`Digest` = the SHA-1 of the payload. **It is not optional metadata** — it is a field the
device writes consistently or never writes, per domain: of the 110 domains with file rows
in a real backup, not one mixes the two shapes (`scripts/blob-shape-check.swift` §4
re-checks this on every run).

- **Must be written** (11 domains): `HomeDomain` · `SystemPreferencesDomain` ·
  `ManagedPreferencesDomain` · `DatabaseDomain` · `RootDomain` · `MobileDeviceDomain` ·
  `WirelessDomain` · `NetworkDomain` · `KeychainDomain` · `ProtectedDomain` ·
  `InstallDomain`
- **Must not be written** (99 domains): the whole `AppDomain*` family (`AppDomain-` /
  `AppDomainGroup-` / `AppDomainPlugin-`) · `SysSharedContainerDomain-*` ·
  `SysContainerDomain-*` · `CameraRollDomain`

On a row that carries one, it equals `sha1(payload)` byte for byte (spot-checked on one
row in each of 4 domains); the reference writes the same value
(`inject.py:_build_mbfile_blob` / `_patch_donor_blob` use `hashlib.sha1(contents).digest()`).

**Why this used to be invisible:** an injector serving only `AppDomain-*` does not need it
— AppDomain happens to be one of the "never written" classes; the footnote's
`SysSharedContainerDomain-*` is another. So "never write a Digest" was correct on both paths
with production evidence, and wrong only for the tweaks' 4 domains. The device answers such
a row with `MBErrorDomain/205 — "Manifest references files not in backup"`.

---

### 2.3 The two `skip_setup` files (completed 2026-09-26)

The switch is in the **Apply** section of the **Settings** page. Upstream keeps
`skip_setup` / `supervised` / `organization_name` in one settings object; only the first is
ported here: `supervised` / `organization_name` need a keybag certificate to mean anything,
and that half was never implemented, so they were removed together with the Supervision page
(see §3.3). When it is on, every apply delivers these two files **before** the tweak files:

| Order | Domain | Relative path | Content source |
|---|---|---|---|
| 1 | `SysSharedContainerDomain-systemgroup.com.apple.configurationprofiles` | `Library/ConfigurationProfiles/CloudConfigurationDetails.plist` | the 7 fixed keys of `build_cloud_config` + `SkipSetupCatalog.panes` (81 items) |
| 2 | `ManagedPreferencesDomain` | `mobile/com.apple.purplebuddy.plist` | upstream's three literals (`SetupDone` / `SetupFinishedAllSteps` / `UserChoseLanguage`) |

- **Order and directory rows**: upstream's `add_skip_setup` only appends the two files, the
  directory rows are added by the injection side from the paths. Here `TweakInjector` derives
  the directory chain from the two payload paths, so the row order is exactly
  `""` → `Library` → `Library/ConfigurationProfiles` → file, then `""` → `mobile` → file.
- **Row shapes**: both go through the **same** `TweakRowProfile` —
  `SysSharedContainerDomain-*` → `.systemContainer` (`-2/-2`, class 4, EA
  `containermanagerd_system`, **no Digest**), `ManagedPreferencesDomain` →
  `.managedPreferences` (`501/501`, class 4, EA `BackupAgent2`, **Digest written**, see
  §2.2). Both are measured shapes, so these two files need no new measurement.
- **Timing**: like every other injection, **after the prune** — every domain outside
  `SystemPreferencesDomain` is not in the keep-set, so writing them first would have them
  pruned. Both branches (iOS 27 = pull + prune, iOS 26 = synthesised MBDB with no flat
  prune) share the one payload array, so both files are delivered on both paths.
- **Code**: `Nugget/Core/SkipSetup.swift` (behaviour) +
  `Nugget/Core/SkipSetupCatalog.swift` (**generated, do not hand-edit**). Verification:
  `scripts/skipsetup-check.swift` diffed against the reference's output (see §3.3).

### 2.4 Page-level reset (ported 2026-09-27, no psysbackup on either branch)

Home page **Reset Tweaks** → a sheet to pick pages → writes the device. Ported from
`device_manager.reset_tweaks` (`device_manager.py:1104`) and
`gui/dialogs/reset_dialog.py`; the entry point matches the reference
(`home.reset_tweaks` → `ResetDialog`). It runs the **same** injection chain
(`protectiveBackup`/`partialRestore` → `pruneAndInject` → `runRestore`) with a different
payload list.

| Page (`Page.getPageName`) | What is written | Files |
|---|---|---|
| Springboard | `springboard`, `uikit` → **nulled** | 2 |
| Internal | `globalPreferences`, `globalPreferencesHomeDomain`, `appStore`, `backboardd`, `coreMotion`, `pasteboard`, `notes` → **nulled** | 7 |
| Daemons | `disabled.plist` → the **stock six keys** (`magicswitchd.companion` / `otpaird` / `dhcp6d` / `bootpd` / `relevanced` = true, `ftp-proxy-embedded` = false) | 1 |

**"Nulled" is the one thing that differs between the branches**, and it is the reference's
own split, not an invention here:

| branch | nulled file written as | why |
|---|---|---|
| iOS 26 and below | **0 bytes** | the original Nugget's behaviour: the managed-preferences copy already holds the tweaked values, and a daemon reading an empty file falls back to its defaults (`NullifyFileTweak`'s trick, already shipped here for ScreenTime) |
| iOS 27+ | **`plistlib.dumps({})`** — a valid, empty XML plist, byte-identical to what the reference writes | "on iOS 26.2+ a truncated plist (e.g. an empty com.apple.springboard.plist) makes SpringBoard crash at boot, which sends the device into a boot loop. An empty dict parses fine and makes the system fall back to its default values." A 0-byte plist is a *truncated* plist there, so it is not used |

**No psysbackup anywhere.** The reference's iOS 27 branch captures the device's original
plists first and restores *those*, which is what makes its reset a true "put back what was
there" rather than "write the same values again". This port has no capture and no
materialiser, so it takes the fallback the reference itself documents for a device where the
capture is unavailable: write a valid empty plist and let the system fall back to its
defaults. That is a different guarantee and the sheet says so on screen — a file that was
custom *before* an apply comes back to its default, not to what it held. Concretely, versus
the reference on iOS 27: values that were already at their defaults come back unchanged
either way; values this app wrote are reset; values something else wrote are lost.

- **Manifest format, same fork as an apply**: iOS 27 speaks the sqlite `Manifest.db` and
  rejects a synthesised one ("Failed to prepare INSERT for ManagedPreferencesDomain" — the
  real one carries the device's own domain registration), so the reset pulls the protective
  backup and prunes it. iOS 26 speaks legacy MBDB and can have a backup built from nothing.
  The reset does **not** pull media on the iOS 27 path: it is a preferences operation, and
  the backup filter rejects the media domains anyway.
- **Not a selection clear**: the reference splits the two — this button resets the
  **device**, and **Clear all tweaks** on the Tweaks page clears this app's selection.
- **The daemons file is not an empty dict**: an empty `disabled.plist` *enables* `otpaird` /
  `bootpd` / `dhcp6d` / `magicswitchd.companion` / `relevanced`, which a stock device has
  off, so a reset would be a way to break pairing. `default_daemons` is copied verbatim; the
  `owner=0, group=0` it asks for comes for free from the `DatabaseDomain` row shape.
- **`skip_setup` rides along, but only when the reference's own gate passes**:
  `add_skip_setup` is entered on
  `pref_manager.skip_setup and (restoring_domains or version < 27.0)`, and in the reset
  path `uses_domains` is assigned in exactly one place — the Daemons branch. So:

  | reset | iOS 26 | iOS 27 |
  |---|---|---|
  | Springboard only / Internal only | the two files ride along | **no skip-setup files** |
  | anything including Daemons | the two files ride along | the two files ride along |

  The reference does not explain the iOS 27 arm, and its own comment argues the files are
  safe regardless ("they always carry real domains, so they can always ride the domain
  delivery") — which makes the flag look like a leftover from the tweak path, where it is
  set by a `/var/mobile` nullify. It is reproduced as written so the diff is empty; the
  consequence is that a Springboard-only reset on iOS 27 leaves the setup-wizard state
  alone. The run log says so when it happens.
- **The two skip-setup files are appended last**, like the reference's own file list —
  it calls `add_skip_setup` after the null loop, so the order there is
  `disabled.plist`, the nulled files, then the skip-setup pair.
- **`clear_lastapply` is not ported**: the reference drops its apply record so a later apply
  does not skip Phase 2 against a reset device. There is no phase-2 skip here to guard, so
  there is nothing to clear. **The selection is left as the user had it** — the reset is of
  the device, and the next Apply is what writes the tweaks back.

**Deliberately absent**

- **No Status Bar page.** This port has no `statusBarOverrides` writer (see the Status Bar
  row in §1.2), so the first entry of `get_resettable_pages` is not offered.
- **`Internal` also clears Liquid Glass**: those 98 tweaks are written into
  `globalPreferences`. The reference behaves the same way — its resettable-page list has no
  Liquid Glass entry either. The UI follows the reference rather than inventing a split.

Code: `Nugget/Core/TweakReset.swift` (page table + payload plan),
`GoldenNuggetEngine.resetPages` (the chain), `Nugget/Views/ResetPagesSheet.swift` (the
sheet).

**Verified mechanically**, not by hand: `scripts/reset-port-diff.py` re-derives both sides
— the reference with `ast` (no PySide6 needed) and this port from the Swift source — and
compares the per-page file lists and their order, the one non-null file, the stock dict
(keys, values *and* bool/int types), the null bytes per branch, the skip-setup gate, and
where the skip-setup files land in the payload list. It is what caught the two
skip-setup divergences above, and it fails on any of the three ways that is checked
(verified by mutating this port and confirming the non-zero exit). The null bytes were
additionally compared byte for byte against `plistlib.dumps({})` — 181 bytes, identical.
Not covered by the script: the Manifest.db/MBDB fork, the backup pull, the prune set and
the no-psysbackup decision.

## 3. Compatibility limits (read this first)

1. **The injector is unverified on a real device.** Apart from `AppDomain-*` /
   `SysSharedContainerDomain-*` (which have production evidence), the row shapes of 4
   domains are measured from a backup and are a reasonable inference, but **no restore has
   been run**. The log prints one line per unverified domain: `note: the <domain> row shape
   is measured ... but has not been confirmed by a run yet`. For the first real-device
   verification, turn on **one tweak only** (e.g. `SBBuildNumber` under Internal), confirm it
   took, then widen.
   **Added 2026-09-25:** the first real-device apply returned
   `MBErrorDomain/205 — "Manifest references files not in backup"`. One mismatch with the
   device's contract was found and fixed — these 4 domains' file rows must carry a
   `Digest` (AppDomain/SysSharedContainer happen not to, which is why the old implementation
   did not show it), see §2.2. A known deviation remains in `Mode` (the device writes 0755
   in `ManagedPreferencesDomain` and mostly 0600 in `HomeDomain`; this port writes 0644
   throughout): it is per-row rather than per-domain, so it is left alone for now.

2. **Two deliberate compiler divergences** (both explicitly modelled in the differential
   test, so they are not "undetected differences"):
   - **Incompatible tweaks are dropped at compile time.** The reference's apply stage does
     not do this check (only the GUI hides them), so a shared preset can enable a tweak that
     is inapplicable on this device without it being visible. This port would rather write
     less than write more.
   - **The HomeDomain `.GlobalPreferences.plist` mirror is written only when the GP dict
     really has keys.** The reference writes it unconditionally, so a run that touches no GP
     key writes `plistlib.dumps({})` over the device's real HomeDomain
     `.GlobalPreferences.plist`. The stated intent is preserved ("also write it to
     HomeDomain so tweaks that depend on it survive"), but an empty dict is never used to
     overwrite a live file.

3. **`skip_setup` is ported, but off by default and with two known divergences.** The
   reference's `_apply_tweak_pass` appends the two skip-setup files
   (`SysSharedContainerDomain-…/CloudConfigurationDetails.plist` and
   `ManagedPreferencesDomain/mobile/com.apple.purplebuddy.plist`), driven by
   `pref_manager.skip_setup`. Here it is a **switch in the Apply section of the Settings
   page** (`SkipSetupSettings.skipSetupEnabled` → `SkipSetup.build` → the engine splices it
   into the same array **before** the tweak payloads, see §2.3).

   - **Off by default**: upstream defaults to **on** (`preference_manager.py:19`). It is off
     here because `SkipSetup` has not had a real-device run yet — on by default would
     silently add two files to every apply. Once it works, changing that one literal to
     `true` makes the file set identical to the reference's.
   - **Divergence one: it does not merge the device's existing cloud config.** Upstream's
     `build_cloud_config(existing, …)` first calls
     `MobileConfigService.get_cloud_configuration()`; this port has no such service, so
     only the 7 fixed keys are written and the device's other existing keys are **not
     preserved** (every run logs this).
   - **Divergence two: it writes only the un-supervised form, no
     `SupervisorHostCertificates`.** Upstream generates an x509 with
     `pymobiledevice3.ca.create_keybag_file` when "supervised + has an organisation name";
     this port has no keybag generator. Rather than keep a switch that cannot install
     supervision — which is exactly what the old Supervision page was: writing
     `IsSupervised`, never writing the certificate, and leaving the device "trusting its own
     supervision with the profile uninstallable" — the `supervised` / `organization_name`
     pair was removed with the page. The supervised form of
     `SkipSetup.build(supervised:organizationName:)` is still in `SkipSetup.swift` and
     `scripts/skipsetup-check.swift` still checks both forms, but the engine always passes
     `false` / `""`.

   Verification (no device): `scripts/skipsetup-check.swift` diffs the two generated plists
   against the reference's two files for the same device **key by key** (parsed, not
   byte-compared — plist dicts are unordered), and checks that the domain/path/order match
   upstream's `add_skip_setup`; the panel list is generated by
   `scripts/gen-skipsetup-from-goldennugget.py` from the reference's `SKIP_ALL_PANES` in
   `skip_setup27.py` (with `--check`), never hand-copied.

4. **Encrypted backups are not supported.** The reference explicitly skips injection into an
   encrypted backup ("a locally-injected plaintext payload has no matching wrapped key —
   the Phase 3 restore agent fails to decrypt it (MBErrorDomain/205)"). This project's
   `Diagnostics.preflightBackupEncryption()` blocks the run beforehand; the tweak path has
   **no** extra handling.

5. **HotLoad is not ported.** The reference has a `hotload_rules.json` kill switch (hide or
   disable tweaks by app version / iOS version / model). Of the rules as read on 2026-09-24,
   the only effective one targets `Daemons` (excluded), so it has no effect on the 133
   ported tweaks today — but **the rules are updatable remotely**, and if upstream adds a
   rule for another tweak this port will not follow it.

6. **An import does not enable a tweak that is incompatible with this device.** See
   divergence two in item 2 above. (Numbering note: this is the constraint referred to as
   "§3.6" elsewhere in this document.)

7. **A number's plist type is decided by the registry default.** JSON cannot distinguish
   `1` from `1.0` (`JSONSerialization` writes `1.0` as `1`), so on import the **numeric type
   of the registry's default value** decides whether an int or a real is written — in a plist
   those are two different types and frameworks read them differently.

8. **The footnote input on the home page** serves the app-container PoC only (`runPoC`).
   `LockScreenFootnote` in the tweak list is the same tweak's official entry point; the two
   paths are never live at once (`applyTweaks` passes `footnote: nil`, `runPoC` passes
   `tweakPayloads: []`).

---

## 4. Usage

### 4.1 UI

Home page → **Tweaks** → *GoldenNugget tweaks*:

- A top line shows the model and iOS version (lockdown `ProductType` / `ProductVersion`) and
  `n of m applicable tweak(s) enabled`. **An inapplicable tweak is not shown at all** —
  matching the reference's `is_tweak_compatible`; a switch that can never be pressed is
  worse than a switch that does not exist.
- The three sections are listed in registry order, each tweak with its title, id and the
  reference's `description`. Number items show `min–max, step`, and input is **clamped** to
  the registry's bounds as you type.
- **Clear all tweaks** clears the selection (this app only, **the device is not touched**).
- **Apply N tweak(s)** — the home page's single Apply — runs the whole chain; afterwards the
  page shows the last 30 log lines at the bottom, and the home page's log area has the full
  log. It also carries whatever the PosterBoard page has selected, in the same run (see
  `docs/posterboard-port.md` §2); with no wallpapers selected it is a tweak-only run, exactly
  as before. **Reboot the device** after applying for the injected preferences to take effect.

Home page **Reset Tweaks** → a sheet to pick pages → resets the **device**
(Springboard / Internal / Daemons); semantics, the file set and the per-branch null are in
§2.4. The reference does nothing when OK is pressed with no page ticked, so this sheet's
confirm button is disabled until something is. It runs on **iOS 27 as well as iOS 26**, with
no original-value capture on either — the sheet states that on screen.

### 4.2 Importing `autosave.json`

GoldenNugget writes its current state to an **AutoSave preset** on every change
(`Presets/AutoSave.json`, `cli/common.py:autosave_preset`), which is what "autosave.json"
means here; any **exported preset** (`exported: true`; a partial export also carries
`metadata.partial` + `metadata.included`) is equally valid input. The format is preset v2
JSON:

```json
{
  "tweaks": {
    "SBBuildNumber":  { "type": "BasicPlistTweak",    "enabled": true,  "value": true },
    "LockScreenFootnote": { "type": "BasicPlistTweak", "enabled": true, "value": "hello" },
    "WatchOSCompatibility": { "type": "AdvancedPlistTweak", "enabled": true, "value": { ... } }
  },
  "metadata": { "version": 2, "description": "...", "ios_version": "27.0", "tags": ["auto"] }
}
```

Tap **Import autosave.json** and pick the file. The result is reported in four categories,
each also written to the run log:

- `applied` — the name matched a supported tweak, restored from `enabled` + `value` (**enabled
  and value are read separately**, so an entry that had a value but was `false` is not
  switched on; this differs from `Tweak.set_value`'s implicit enabling);
- `not part of this port` — the 5 unported features, each with its reason;
- `switched off — not compatible` — inapplicable on this device or iOS version, **not
  enabled** (see §3.6);
- `unknown tweak ids` — which the reference also just `continue`s past.

Entries whose role is `Daemons` show up under `not part of this port`; that is expected for
presets exported before the Daemons page existed.

### 4.3 Scripts

```bash
# Regenerate TweakCatalog.swift from the reference registry (run after upstream adds a tweak)
scripts/gen-tweaks-from-goldennugget.py [--goldennugget ~/GoldenNugget] [--check]

# Regenerate SkipSetupCatalog.swift from the reference's skip_setup27.py (after upstream adds/renames a setup panel)
scripts/gen-skipsetup-from-goldennugget.py [--goldennugget ~/GoldenNugget] [--check]

# Differential test of the compile stage against the reference (no device, runs on the host)
scripts/tweak-port-diff.py [--goldennugget ~/GoldenNugget] [-v]

# Differential test of the page-reset payload plan against the reference (no device, no PySide6)
scripts/reset-port-diff.py [--goldennugget ~/GoldenNugget] [-v]

# Regenerate the PosterBoard embedded assets / the caml templates from the reference
#   (the templates script also fails if upstream grows a placeholder it does not know)
scripts/gen-pb-resources-from-goldennugget.py [--goldennugget ~/GoldenNugget] [--check]
scripts/gen-pb-templates-from-goldennugget.py [--goldennugget ~/GoldenNugget] [--check]

# Key-by-key diff of the two skip_setup plists against the reference's output (no device;
#   with no arguments it uses the two files on this machine)
#   How to compile it: see the header comment of scripts/skipsetup-check.swift (concatenate into main.swift, then xcrun swiftc)
/local/path/to/skipsetup-check [CloudConfigurationDetails.plist] [com.apple.purplebuddy.plist]

# Routine gates
scripts/typecheck.sh                 # passes only at 0 errors
scripts/sync-pbxproj-sources.py      # must be run after adding/removing files under Nugget/
scripts/check-linked-symbols.py      # every C symbol the gateway calls must be in the archive that is linked
```

`tweak-port-diff.py` depends on `packaging` (the reference uses it for version comparison).
When the host's default interpreter lacks it, use
`~/.workbuddy/binaries/python/envs/default/bin/python3`.

`sync-pbxproj-sources.py` reconciles **sources only**. A SwiftPM *product* the app depends
on (`.product(name:package:)` in `Package.swift`) has to be mirrored by hand in
`project.yml` **and** in `project.pbxproj` (`packageProductDependencies` plus an
`XCSwiftPackageProductDependency` object) — XcodeGen is not installed here, so
`project.pbxproj` cannot be regenerated from `project.yml` and the three files have to
agree by hand. The app depends on two products of the vendored package today: `Minimuxer`
and `ZIPFoundation` (the latter for `.tendies` packs, which are ZIPs).

---

## 5. Evidence

- **Compile-stage differential test**: 142 selections (each tweak alone + each section
  wholesale + everything on + text/number/decimal/`false`-default/multi-key dicts) × 3
  device profiles (27.0 iPhone, 26.5 iPad, 27.0 iPad) = **426 cases, every field
  identical**. The diff also checks the plist **types** (`bool` / `int` / `real` / `str`) —
  that check caught a real defect: comparing through JSON first collapsed `1.0` and `1` into
  the same value, so the test would have missed a type mismatch.
- **Type check**: `scripts/typecheck.sh` → `0 errors` (8 warnings, 3 of them in `Nugget/`,
  the same as the pre-port baseline).
- **Generators are re-checkable**: `gen-tweaks-from-goldennugget.py --check` is idempotent.
- **Reset differential test**: `scripts/reset-port-diff.py` — 12 checks over the reset's
  file lists, order, stock dict, null bytes and skip-setup gate. Fails on mutation
  (checked).
