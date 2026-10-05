# UI: GoldenNugget Mobile Design System Port

> **Status: landed (2026-09-25).** `scripts/typecheck.sh` **0 errors, no new warnings**
> (35 sources, 33 before the change). **Only one old-look version was ever run on a real device**; the new look has not been on a device (this machine cannot build).
>
> Features and information architecture are **completely unchanged**: all bindings, actions, strings, logs, alerts, file pickers and share items stay exactly as they were;
> only the colours, fonts, component styles, spacing and layout changed.

Receiving side: `Nugget/Views/GoldenTheme.swift` (tokens), `Nugget/Views/NativeUI.swift` (components),
`Nugget/Views/GoldenNuggetView.swift` (main page), `Nugget/Views/TweaksView.swift` (Tweaks page).
Reference: the **iOS GUI** in `~/GoldenNugget` — that is the only place the GoldenNugget Mobile look was ever written down.

> **Superseded (the design-system port itself).** This document is the record of the design-system
> port, kept because it states where every token and metric came from. The ported code was later
> deleted as dead code: the `Golden*` component library (`GoldenPage`, `GoldenCard`, `GoldenHeader`,
> `GoldenLogo`, …) in `Nugget/Views/GoldenComponents.swift`, and with it `Nugget/Views/GoldenTheme.swift`
> (palette, metrics, type scale) — the native screens never read either, they use `List`/`Form`,
> Dynamic Type text styles and semantic colours. What survives is `GoldenTone` in
> `Nugget/Views/NativeUI.swift`, the status-line tone slot, now resolved to platform colours by
> `nativeColor`. Every name in the tables below is therefore history; the tables stay because they are
> the only record of the reference values the port was built from.

---

## 1. The Three Reference Files

| Reference | What it provides |
|---|---|
| `src/gui/theme/colors.py` | **All colour slots** of the `DARK` theme (bg/text/accent/semantic/border). The iOS GUI defaults to exactly this theme |
| `src/gui/theme/styles.py` | Component styles: corner radius, padding, font size/weight, letter spacing, switch track colour, button gradient, `section_header`/`settings_row`/`primary_button`/`danger_button`/`value_label`/`safety_note`/`home_*`/`process_status_*` |
| `src/gui/ios/components.py` | The mobile component set and its fixed sizes: `IOSCard` `IOSNavBar`(56) `IOSSectionHeader` `IOSSettingsRow` `IOSPrimaryButton`(50) `IOSDangerButton`(50) `IOSSwitch`(51×31) `IOSValueLabel`, home's logo 80×80/corner radius 14 |
| `src/gui/ios/home.py` · `tweaks.py` | The **layout itself** of the two pages: page margin/spacing, the responsive reflow rule of `_CardGrid` (`MIN_CARD_WIDTH=200`, `SPACING=12`), the 56pt card header strip, the render order of the sections |

## 2. Colours (slot by slot, not approximate)

| Reference slot | Value | This project |
|---|---|---|
| `bg_primary` | `#1E1E1E` | `GoldenTheme.backgroundPrimary` (page background) |
| `bg_secondary` | `#1C1C1E` | `backgroundSecondary` (cards/rows/nav bar/text fields) |
| `bg_tertiary` | `#2C2C2E` | `backgroundTertiary` (feature card body/hover) |
| `bg_input` | `#1C1C1E` | `backgroundInput` |
| `text_primary` | `#FFFFFF` | `textPrimary` |
| `text_secondary` | `#8E8E93` | `textSecondary` (subtitles/captions/weak text other than the id) |
| `text_disabled` | `#787878` | `textDisabled` (disabled rows, tweak id) |
| `accent` / `_hover` / `_pressed` | `#007AFF` / `#0066CC` / `#0055AA` | `accent` / `accentPressed` (the two ends of the button gradient); `_hover` only serves desktop hover, iOS has no corresponding state, so it is not carried over |
| `success` | `#30D158` | `success` (switch track) |
| `error` / `_pressed` | `#FF453A` / `#C2322A` | `error` / `errorPressed` (danger button, destructive rows, failure state) |
| `warning` | `#FFD60A` | `warning` |
| `border` / `divider` | `#3A3A3C` | `border` / `divider` |
| `surface_hover` | `#2C2C2E` | `surfaceHover` (row press feedback) |

`ACCENT_PRESETS` (8 theme colour sets) are **not ported**: the reference switches them from a settings page, and this project has no settings page.

## 3. Typography

The reference pins every platform to a single **bundled `Inter Variable`**; this project's font sizes and weights are **copied entry by entry**:

| Reference slot | Size/weight | This project |
|---|---|---|
| `home_title` | 32 / 700 | `GoldenFont.homeTitle` |
| `nav_title` · `home_card_title` | 17 / 600 | `navTitle` · `cardTitle` |
| `settings_row` · switch row · input control | 15 / 400 | `rowTitle` · `field` |
| `value_label` · default `QLabel` | 14 / 400 | `value` · `body` |
| `home_subtitle` · `process_status_*` | 14 / 400 · 14 / 500 | `homeSubtitle` · `status` |
| `home_card_subtitle` · section caption | 13 / 400 | `cardSubtitle` |
| `section_header` | 13 / 600 + uppercase + 0.5 tracking | `sectionHeader` (`.tracking(0.5)` + `.textCase(.uppercase)`) |
| `safety_note` | 12 / italic / danger | `safetyNote` |

**One deliberate divergence: the type family.** The reference pins Inter because Qt's default family differs per platform; and its iOS component set is itself **an imitation of the platform look** (a 51×31 green-track switch, a 17/600 centred nav title, grouped cards). On a real iPhone/iPad the system family is the faithful choice. `GoldenFont.font(_:_:)` probes for `Inter Variable` / `InterVariable`, so **the moment you bundle the font in, everything switches over automatically**, with no call site changed. To enable it:

1. Make `~/GoldenNugget/src/qt/fonts/InterVariable.ttf` (+ Italic) a project resource;
2. Add `UIAppFonts` in `layout/Applications/PoC.app/Info.plist`.

Both steps require touching the Resources section of `.pbxproj` and can only be done in an environment where XcodeGen/a real build runs — this machine cannot, so the hook is left in place instead of hand-editing the project file.

## 4. Layout and Components

| Reference | Value | This project |
|---|---|---|
| page margin / page spacing | 16 / 16 (home) · 16,16,16,32 + 8 (tweaks) | `pageMargin` 16, `sectionSpacing` 16, `rowSpacing` 8 (each of the two pages takes its own value) |
| card radius · row radius | 12 · 10 | `cardRadius` · `rowRadius` |
| text field padding / corner radius | 12·16 / 10 | `GoldenFieldStyle` |
| nav bar | 56, `bg_secondary` + bottom divider | the platform nav bar (44) + `.toolbarBackground(backgroundSecondary, .visible)`; height is left to the platform |
| primary/danger button | height 50, corner radius 12, vertical gradient, 17/600; `:disabled` = `border`+`text_disabled` | `GoldenPrimaryButton` / `GoldenDangerButton` / `GoldenButtonLabel` |
| switch | 51×31, on=`success`, off=`border`, white knob | native `Toggle().tint(success)` (the platform control is exactly that anyway) |
| row press feedback | `:hover` → `surface_hover` | `GoldenRowButtonStyle` |
| section header | 13/600 uppercase + 4 left padding | `GoldenSectionHeader` |
| settings row | `title  (value)  ›`, corner radius 10 | `GoldenRowLabel` + `GoldenActionRow` |
| feature card | 56pt header strip (17/600) + content block (13 subtitle) | `GoldenFeatureCardLabel` (header strip `bg_secondary`, card body `bg_tertiary`) |
| responsive card grid | every card ≥200, gap 12, fill one row as far as possible | `GoldenCardGrid` (the same reflow rule) |
| home logo | 80×80, corner radius 14; when the image cannot be fetched use a `bg_secondary` square | `GoldenLogo` (reads `AppIcon60x60@2x.png`; when it cannot be fetched it draws `bg_secondary` + the icon) |
| status row | 14/500, green/red/blue by outcome | `GoldenStatusText` + `outcomeTone` (Tweaks' apply outcome; home's elapsed) |

`GoldenPage` adds one more rule the reference cannot give: **content is capped at 720 wide and centred**. The reference on the desktop always draws the iOS UI inside a phone frame (the width is inherently constrained), whereas this app runs on iPad (`TARGETED_DEVICE_FAMILY 1,2`) — not letting a single line span the full 1366pt in landscape is the equivalent way of doing the same thing.

## 5. Deliberately Preserved Differences

| Difference | Why |
|---|---|
| system font family (see §3) | the reference is imitating the platform look in the first place; the Inter hook is left in place |
| the reference has no **log screen** | the reference prints progress on the status row; this project needs a complete copyable log (diagnostics depend on it). Same card shell + 12pt monospace, 300/260 high with inner scrolling, so a single run cannot push the controls off the screen |
| switch rows **have padding** | the reference's `make_switch` uses `setContentsMargins(0,0,0,0)`, so the label hugs the card edge; here they line up with `settings_row` (14·16) from the same file |
| a tweak's **id + description stay in the card** | the reference puts them in a tooltip; this project needs them visible and copyable on the device, and that is how it already was |
| icons use SF Symbols | the reference uses Qt theme icon resources |
| the main page has **only one feature card** | this project has only one secondary page; the grid rule is copied as is, and the card count follows from it |
| desktop hover / accent colour picker / phone shell | meaningless on iOS (the first two) or not needed by this project (the third) |

## 6. What Was Not Touched (Acceptance Checklist)

- Main page: pairing select/reset, `.app/.ipa` selection and reading the bundleID, the bundle/file/contents fields,
  Run/Stop, the `ALTPairingFile` bootstrap, `onOpenURL`, the two alerts, the four diagnostics + share, the 600-line log cap,
  ~~the `UIDocumentPickerViewController` swizzle in `init()`~~ — deleted on 2026-09-26: the
  `fix_initForOpeningContentTypes:asCopy:` it looks up **is not defined anywhere in the whole repo**
  (this is the only lookup site), so `class_getInstanceMethod` always returns nil and the swap never
  happened; and as a custom `init()` it also overrides the memberwise construction, which is one of the
  two root causes of the compile errors this time.
- Tweaks page: `DeviceIdentity.read()`, compatibility filtering (incompatible ones are not shown), the
  `(on/total)` of the three sections, the switch/text/number editors (the number editor still carries
  draft + clamping + `numberHint`), the `autosave.json` import and its four kinds of report,
  Clear all, the three success/cancel/failure branches of apply, the last 30 lines of the log.
- `PoCEngine` / `BackupInjector` / `ManifestStore` and the like are **not one line changed** — this is a pure view-layer change.

## 7. Window Width (Split View / Slide Over)

The reference is a desktop GUI with the single width "drawn inside a phone frame"; this app runs in a window whose **width is decided by the system**:
Slide Over 320, Split View one-third/one-half, the freely resizable windows of iPadOS 26. So beyond the table in §4 we also have to answer
"what happens when it gets narrower".

**Conclusion first: Info.plist needs no changes.** The three conditions for entering Split View are already met one by one, and can be re-checked:

| Condition | What this project has |
|---|---|
| does not require full screen | there is no `UIRequiresFullScreen` key (absent means false) |
| iPad supports all four orientations | all four entries are present in `UISupportedInterfaceOrientations~ipad` |
| uses a launch storyboard | `UILaunchScreen` (not a launch image) |

There is also `UIDeviceFamily = 1,2` and `UIApplicationSceneManifest / UIApplicationSupportsMultipleScenes = true`
(multi-window), and both of those are right too. In other words: if Split View cannot be dragged out on iPad, the reason is in the
next section's layout, not here.

The four rules for a narrow window (the narrowest is computed from Slide Over 320: minus 2×16 page margin, content width 288):

| Where | What a narrow window does | Rule |
|---|---|---|
| `GoldenHeader` title | after the 80 logo + 16 spacing + 36 button only 156 is left; 32pt "GoldenNugget" is about 210 → a tower that folds onto three lines and pushes the whole page down | `lineLimit(1)` + `minimumScaleFactor(0.6)`: shrink, never fold (about 19pt at 0.6, still readable) |
| `GoldenRowLabel` title / value | after the 20 icon + 13 chevron + 32 padding about 170 is left, split evenly between title and value → the value wraps and the title is truncated to a stub | title `layoutPriority(1)` (squeezed last), value `lineLimit(1)` + `minimumScaleFactor(0.7)` (a wrapped number reads as two facts) |
| `FilesView` breadcrumb | a single segment of `/var/mobile/Containers/Data/Application/<UUID>/…` already exceeds 300 → one segment per line, the card height grows with directory depth, and the "/" drifts further from the name it separates | `ScrollView(.horizontal)` + `.fixedSize()` per segment: one line, natural width, horizontal scrolling; short paths look unchanged |
| `FilesView` file name | 40+ characters fold onto 2–3 lines, long entries turn into blocks, the list can no longer be scanned | `lineLimit(1)` + `truncationMode(.middle)`: the extension is preserved |

**Already adaptive, left alone**: `GoldenCardGrid` (`gridMinCardWidth` 200, at 288 wide it naturally falls to 1 column,
the rule is the same as the reference's), the 720 cap of `GoldenPage` (it only centres when the window is wider than it, so it does nothing in a narrow window),
the height of `GoldenLogView` (Slide Over is still full height).

### Shell: `NavigationSplitView` (`Nugget/Views/AppShell.swift`)

In a wide window it is the two columns "sidebar + detail"; in a narrow window the system collapses it to one column itself —
**which is exactly why it was chosen**: this app runs in a window whose width is decided by the system, and `NavigationStack`
only has the second form.

Three non-obvious constraints to check against when changing that file:

1. **The home page is the bottom of the detail column's stack, not an item in the sidebar.** A split view
   **destroys** the detail view when the selection changes, and the home page holds the run (Apply / progress / log)
   and the launch bootstrap. So a sidebar selection pushes onto `path` (`path = [dest]`); the home page is
   never removed, only covered; an empty `path` = home, and that is also the single source of truth for the
   sidebar highlight (`path.last ?? .home`).
2. **`tweakSelection` and the two bootstrap flags (`didAutoStart` / `autoImportDisabled`) are hoisted to `RootView`.**
   The home page's `@State` dies together with the detail page when it is replaced: a user who selects 40 tweaks,
   taps Daemons and comes back finds everything empty. `didAutoStart` is the same story — it guards a
   process-level singleton (the lock in `startMinimuxer` only blocks concurrency), yet the flag dies with the view.
3. **The home page's nav bar is hidden only at regular width.** The reference's home has no nav bar, but when
   collapsed into one column **that bar is the only way back to the sidebar**, and hiding it locks the user on the
   home page. So `navBarVisibility` forks on `horizontalSizeClass`: keep it in compact, hide it in regular.

The sidebar uses the design system's own row metrics (`GoldenFont.rowTitle` / 20pt icon slot) rather than the platform
row style, and `.scrollContentBackground(.hidden)` + `backgroundPrimary`, so that it and the page on the right are
one and the same background colour. The 5 entries of the home card grid were changed to `NavigationLink(value:)`,
sharing the one `navigationDestination` in `RootView` with the sidebar — otherwise a card could push a page that
`path` does not know about and the sidebar would keep highlighting "GoldenNugget".

**Not done this round**: 44pt touch targets (that is a touch-precision problem, not a window-width problem; it was
pulled out separately in the previous revert).

## 8. Phone (iPhone)

**The capability declarations likewise need no changes** (re-checkable): `UIDeviceFamily = 1,2` · all three orientations
present in `UISupportedInterfaceOrientations~iphone` · no `UIRequiresFullScreen`. So as in §7, what has to change is
the layout and interaction, not the plist.

| Item | On the phone | Handling |
|---|---|---|
| split shell | `NavigationSplitView` collapses to one column by itself on the phone | the initial `columnVisibility` forks on `userInterfaceIdiom`: `.detailOnly` on the phone (even collapsed into one column the sidebar is still reachable through the detail's back entry), `.automatic` on iPad (remembers the user's last choice). Forcing them side by side on the phone would only squeeze 393pt into 240 + 153 |
| **the keyboard cannot be dismissed** | `.numberPad` / `.decimalPad` **have no Return key**, the keyboard covers half the screen and cannot be put away | added `GoldenKeyboardDone` (a Done above the keyboard, using UIKit's `resignFirstResponder`, no need to give every field a `@FocusState`), added only on the fields that use those two keyboards: the tunnel's Port / Prefix length; the tweak number editor uses `.numbersAndPunctuation`, which already has Return, so nothing is added |
| narrowest 375 (SE) | content width 343; a 2-column card grid needs `2×200+12 = 412 > 343` ⇒ it naturally falls to 1 column | no change, `GoldenCardGrid`'s reflow rule computes it itself; the header title relies on that `minimumScaleFactor(0.6)` from §7 |
| text fields inside alerts (Files' create/rename) | the alert brings its own Cancel, nothing gets stuck | no change |

**Not done**: 44pt touch targets (`GoldenIconButton` is still the reference's 36pt) — that is a touch-precision
problem, it was already pulled out separately in the previous two rounds, and this round does not smuggle it back in.

## 9. Gate

```bash
scripts/typecheck.sh                      # 0 errors (49 sources)
scripts/typecheck.sh "" --first <file>    # move a given file to the front, to make sure it really gets checked
scripts/sync-pbxproj-sources.py --check   # the project's source list matches Package.swift
```

**The two traps in `typecheck.sh` (both have been hit)**:

1. `swiftc -typecheck` stops as soon as it has reported **the first file that errors**, and the source files
   queued after it are **not checked at all**. In this project `Nugget/Core/AfcFileExplorer.swift` always throws
   28 phantom errors because the module cache is older than Vendor, so any new error under Views/ would read
   as a "pass". After adding or heavily changing a file, use `--first` to move it to the front and run it again.
2. `-target` must match the deployment target (26.0 in this project). Written as ios16.0, iOS 17+ APIs like
   `onChange(of:initial:_:)` get reported as **false** "only available in iOS 17.0 or newer".

> `sync-pbxproj-sources.py` no longer hardcodes the project file name: the project was just renamed from
> `PoC.xcodeproj` to `GoldenNuggetMobile.xcodeproj`, and hardcoding the old name would make it die straight
> away with a `FileNotFoundError` (fixed: glob the unique `*.xcodeproj` at the repo root, and error out if
> there is more than one).
