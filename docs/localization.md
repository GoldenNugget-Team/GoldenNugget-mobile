# Localization

The app ships English as its source language. Translations live in a String
Catalog; there is no `.lproj` file to edit by hand in the source tree.

## Files

| File | Purpose |
| --- | --- |
| `layout/Applications/GoldenNuggetMobile.app/Localizable.xcstrings` | Every string the app itself displays. Keys are the English source text. |
| `layout/Applications/GoldenNuggetMobile.app/InfoPlist.xcstrings` | `NSLocalNetworkUsageDescription` and `UTTypeDescription`. Keys are the plist keys. |
| `scripts/sync-localizations.py` | Merges compiler-extracted keys into `Localizable.xcstrings`; `--check` is the CI guard. |
| `scripts/compile-localizations.py` | Compiles the catalogs to `<lang>.lproj` for the xtool build (Linux-safe). |
| `docs/localization.md` | This file. |

`GoldenNuggetMobile.xcodeproj` is generated: the catalogs are listed in
`project.yml`, and Xcode compiles them itself. The xtool path cannot compile a
catalog, so `scripts/build-ipa-xtool.sh` runs `compile-localizations.py` first
and `xtool.yml` ships each generated `<lang>.lproj` directory.

## How a string gets localized

1. **Standard SwiftUI APIs take literals.** `Text("Settings")`, `Button`,
   `Label`, `Section`, `Toggle`, `TextField`, `navigationTitle`, `alert`,
   `confirmationDialog`, `accessibilityLabel` and the rest already look the
   literal up in `Localizable.strings`. Nothing else is needed.
2. **Computed display strings use `String(localized:)`.**
   ```swift
   return String(localized: "Showing \(visible) of \(total) operations")
   ```
   Interpolation is part of the key: the compiler turns the example into
   `"Showing %lld of %lld operations"`. Never build a translatable string with
   `+` inside `String(localized:)`; merge the literals.
3. **Custom components localize internally.** `NativeNote`, `NativeSafetyNote`,
   `NativePrimaryButton`, `NativeDangerButton` and `NativeCollapsibleHeader` take
   a `String` and wrap it in `LocalizedStringKey`. Literal call sites need no
   change. An *interpolated* call site must pass an already-localized value:
   ```swift
   NativeNote(String(localized: "Copying \(bytes) to the app container."))
   ```
   The small row/card helpers in the views (`switchRow`, `creditRow`,
   `contributorRow`, `stepCard`, `actionCard`, `step`, `toggleRow`,
   `textFieldRow`, `levelRow`, `networkRow`, `optionRow`) take a
   `LocalizedStringKey` for the same reason. Their literals are invisible to the
   compiler too, so `scripts/sync-localizations.py` lists them in
   `COMPONENT_KEYS`; a new helper of that shape needs one line there.
4. **Core model titles are localized where they are defined.** Enum `title`
   properties in `Nugget/Core` return `String(localized:)`, so every screen that
   displays them gets the translation.
5. **Literal text that is not prose is not a key.** A scheme shown in the file
   browser (`afc://`), a number, a path or any other verbatim value uses
   `Text(verbatim:)` or the `String` initializer, so it never reaches the
   catalog. The sync script also drops empty keys (`Toggle("", …)` is the
   idiomatic unlabelled control) and prunes catalog entries left behind with no
   localizations after a literal became verbatim.

## What stays in English

Deliberately, and permanently:

* `goldennugget.log` / `minimuxer.log` lines and everything written through
  `AppLog`.
* Error messages and diagnostics: `LocalizedError` descriptions, transport
  failures, tunnel/device status (`identity.describe`, `Tunnel.requirements`,
  `connectionState.text`), HotLoad policy reasons.
* Transient run status lines on the pages (`showStatus("Applying…")`, the
  Wallet/PosterBoard banner text, `setMessage` results) and the run log: they
  repeat a line that is already in the log, English is what a report shows.
* Imported data: tweak titles and details (`TweakCatalog`), template and
  community catalog content, wallpaper names and bylines, file names and paths,
  device identifiers, and the raw enum values that are persisted as preferences.

This keeps bug reports searchable and makes a screenshot match the log line it
came from.

## Adding a language

1. Open `Localizable.xcstrings` in Xcode (or add the language with
   `xcstringstool` / by editing the JSON) and translate the entries.
2. Add every new language to the Xcode project's known regions (Xcode does this
   when you add the language in the catalog editor).
3. Add one line to `xtool.yml` for the generated directory:
   ```yaml
   - build/localizations/ru.lproj
   ```
   `scripts/compile-localizations.py` creates it on every xtool build.
4. Run `python3 scripts/compile-localizations.py` and confirm the `.strings`
   files it writes look right.
5. Test in the simulator with **Product > Scheme > Edit Scheme > Run >
   Options > App Language**, or on device through **Settings > Apps >
   GoldenNugget > Language**. iOS exposes the per-app picker automatically
   once the bundle contains more than one localization.

Plurals are stored as `variations.plural` in the catalog. On the Xcode path
Xcode compiles them to `.stringsdict`; `compile-localizations.py` writes the
same `.stringsdict` for xtool. Use the `one` / `few` / `many` / `other` cases
that the target language needs.

## Adding or changing a string

1. Write the English text in code using one of the forms above.
2. Build once (Debug is enough): with `SWIFT_EMIT_LOC_STRINGS = YES`, Swift
   writes `.stringsdata` files into `build/xderived`.
3. Run:
   ```sh
   python3 scripts/sync-localizations.py
   ```
   This adds new keys, keeps existing translations, and marks keys that are no
   longer found as `stale` instead of deleting them. Entries that come back empty
   (the literal disappeared from the source) are pruned; empty strings are never
   recorded as keys.
4. Review the catalog diff. Delete stale keys (and their translations) if the
   text really is gone; if a key was renamed, remove the old one.

CI runs `python3 scripts/sync-localizations.py --check` after the build, so a
literal that nobody extracted fails the pull request instead of shipping as
untranslatable English.

## Layout rules that matter for translation

* Use `.leading` / `.trailing`, never `.left` / `.right`, for padding and
  alignment. SwiftUI mirrors the former in right-to-left languages.
* Do not give a label a fixed width that fits only the English string. Prefer
  `.fixedSize(horizontal: false, vertical: true)`, `lineLimit(nil)`, or let the
  row size itself.
* Prefer one text run per sentence. Concatenating translated fragments produces
  word-order bugs in German, Russian and RTL languages.
* Give custom chevrons `.flipsForRightToLeftLayoutDirection(true)`; the
  system's navigation bar does this itself, hand-drawn
  `Image(systemName: "chevron.left")` does not.
* VoiceOver labels are localized too. Use the same English text in
  `.accessibilityLabel` so translators see it in the catalog.
