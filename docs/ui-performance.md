# UI Performance: Audit, Fixes, and To-Do (2026-09-26)

> Goal: find the real source of the "stutter / slow response" instead of guessing. **Cannot actually run
> on this machine** (no device, no Instruments), so the conclusions come from a static audit + per-item
> cost reasoning, and every item cites a `file:line`; the three items that were changed are all
> "judgeable by construction" changes (see the effect argument in §3). The on-device quantification
> method is in §5.

> **Note on the `GoldenComponents.swift` citations below.** That file has since been deleted as dead
> code — the native screens never used the `Golden*` component library, and `RunLog`/`RunLogCard`
> (`Nugget/Views/RunLog.swift`) are what actually carry the log view the audit is about. The
> `file:line` references are therefore a snapshot of the code as it was on 2026-09-26; the findings
> and the effects they had still stand.

## 1. Findings ranked (by real cost, not by line count)

| # | Source | Mechanism | Cost | Status |
|---|---|---|---|---|
| 1 | **`mediaDetail` reads from disk + JSON-decodes inside `body`** | The Media card badge in `GoldenNuggetView` calls `AfcMediaBackup.read()` (`Data(contentsOf:)` + `JSONDecoder().decode`); it lives in `body`, so it **runs once per render**, on the main thread | The media manifest holds one record per already-pulled file; a few thousand entries is JSON on the order of a few hundred KB to MB ⇒ **milliseconds to tens of milliseconds per render** | **Fixed** (memoized at the source) |
| 2 | **One log line = a full-page re-render** | `logs: [String]` is `GoldenNuggetView`'s `@State`; `AppLog`'s UI handler appends once per line ⇒ every line triggers a whole-page `body` recomputation, and item 1 runs again along with it | One run produces on the order of 10² log lines (progress, delegate accounting, retries, diagnostic blocks) ⇒ 10² full-page recomputations, each one also carrying the disk read from item 1 | **Fixed** (logs in their own store) |
| 3 | **Long lists are not lazy** | The inner container of `GoldenPage` is a `VStack`: as soon as the page appears it builds **all** rows and keeps them resident. The Tweaks page alone has 98 sub-cards just from Liquid Glass (each = title + toggle/text field + id + description); Files has 3 rows per entry | The first draw, and any diff afterwards, pays for the off-screen rows | **Fixed** (`LazyVStack`) |
| 4 | **`MediaView.hasStoredFiles` walks the directory tree twice per render** | The predicate walks the store looking for `.afcpartial`, yet it is written into two `.disabled(...)` calls ⇒ **two** full-tree walks per re-render, on the main thread | The more files there are, the slower it gets (after one media pull there are thousands of files) | **Fixed** (computed once into state) |
| 5 | All identities shift when the log window slides | `ForEach(Array(lines.enumerated()), id: \.offset)`: after `removeFirst` every offset changes ⇒ all 600 lines are **rebuilt** | Only happens past 600 lines, which is exactly the second half of a long run | **Fixed** (stable ids) |
| 6 | `TweaksView` filters the catalog 4 times per render | `visibleSpecs` (133 × `isCompatible`, containing a version-string split) is called once by `.count` and once by each of the 3 sections | Microsecond-level, **noise** | Not fixed (see §4) |
| 7 | `DaemonsView` filters `DaemonGroups.all` per section on every render | Same order of magnitude | Noise | Not fixed |
| 8 | `MemoryLogSink` has no upper bound | By design (the diagnostic tail needs it); the view side used to have a 600-row window ✓ the window is now in `RunLog` | Only copies the whole array when dumping diagnostics | Kept as is |

Items 1 and 2 are two halves of the same root cause: **I/O is done in `body`**, while **high-frequency events (logs) land on page state**, so the disk read gets multiplied by the number of log lines.

## 1.5 Round two: the two heavier items found after the user reported "still slow" (read this first)

User retest: **opening a NavigationLink takes about 3 seconds, and scrolling the home page sometimes freezes**. The original table missed two heavier items.

| # | Source | Mechanism | Cost | Status |
|---|---|---|---|---|
| **0** | **`Tunnel.probePeer()` in `body`** (the tunnel detail row on the home page) | `Tunnel.probePeer` = a non-blocking `connect` + `poll(fd, POLLOUT, timeout*1000)`, **default `timeout: 2.0`** (`Tunnel.swift:234-260`), interpolated straight into `GoldenStatusText` (`GoldenNuggetView.swift:399`, before the fix). So **as long as that DisclosureGroup is expanded**, any body evaluation (lazy row creation triggered by scrolling, any state change, the page re-render when tapping a NavigationLink) can stall the main thread for **up to 2 seconds** | 2 seconds on the main thread = frozen scrolling; also the bulk of the "3 seconds to open the page" | **Fixed** |
| **3'** | **The previous round's `LazyVStack` actually did not fix the problem** | Each section wraps its rows in a `VStack` and then hands that to the section view as **one** `AnyView` ⇒ the lazy stack only sees "one child" and still builds **all** rows of that section. This time the user had **172 tweaks** restored (all three sections open by default) ⇒ opening the Tweaks page synchronously builds 133 cards (one control per card); the Files list is the same story (3 rows per entry) | Hundreds of milliseconds on the first frame / push, and it takes part of the 3s | **Fixed** (split the "section header" and the "rows" into **sibling** nodes) |

The fix:

- The two halves of the tunnel status (`describe()` and `probePeer()`) became **state**, filled in by
  `refreshTunnelStatus()` inside `Task.detached`; only **while the detail is expanded** does
  `.task(id: tunnelExpanded)` probe once every 5 seconds (collapsing cancels it), plus one refresh each
  after the header refresh button and after "Reset tunnel addresses". Only string interpolation is left
  in body.
- `GoldenCollapsibleSection` (header + content wrapped in a `VStack`) → **`GoldenCollapsibleHeader`**:
  the caller puts the header and `if !collapsed { ForEach(rows) { … } }` directly into the page content
  as **siblings**, so the rows become independent children of the page's `LazyVStack` and are really
  built on demand. The Tweaks and Daemons pages change at the same time; the spacing is identical
  (8 pt in both cases), so the appearance is unchanged.
- The `Contents` list in Files is likewise split into `GoldenSectionHeader` + a bare `ForEach(entries)`.

> The user log also shows **the race that was fixed in the previous round**:
> `getLockdownValue(ProductVersion) … verifyInitialized() failed: Gateway has not been initialized`
> (14:57:03) — precisely the read from the time when "the page read an empty identity first ⇒ the engine
> took the iOS 26 branch". The bounded retry in `readDevice()` and `resolvedDeviceVersion` already cover
> it; this is not a new problem.
>
> The rest of the system noise in the log (`cannot add handler to 0 from 0 - dropping`, `LaunchServices … process may not
> map database`, `personaAttributesForPersonaType failed`, `Gesture: System gesture gate timed out`)
> is launchd/LS/XPC grumbling about the sideloaded process, not this app's cost.

## 2. Evidence (item by item)

- `AfcMediaBackup.read()`: `Nugget/Core/AfcMediaBackup.swift:339` (before the fix) = `Data(contentsOf: manifestURL)` + `JSONDecoder().decode(Manifest.self, …)`; the call site is `Nugget/Views/GoldenNuggetView.swift:178-184` (`mediaDetail`), a property used as `detail:` in the Media card of `tweakCards` ⇒ inside `body`. The comment next to it reads "read from the manifest rather than a directory walk, so it costs nothing on every body pass" — **the first half is right, the second half is wrong**.
- Logs: `Logging.swift:145` dispatches the UI handler with `DispatchQueue.main.async`; `GoldenNuggetView.swift:876-884` (before the fix) does `logs.append` + `logs.count > 600 { removeFirst }` inside the handler ⇒ an `@State` write ⇒ the whole page is invalidated.
- Non-lazy lists: `GoldenComponents.swift:17-35` (`GoldenPage`, a `VStack` before the fix); the row sources are `TweaksView.swift:151-165` (`ForEach(specs)`) and `FilesView.swift:143-196`.
- The two walks in `MediaView`: `MediaView.swift:56,60,75` (`hasStoredFiles` in three `.disabled` calls).
- Sliding-window identities: `GoldenLogView` in `GoldenComponents.swift` (`id: \.offset` before the fix).

## 3. What was changed (three items + two side effects)

| Change | File | Why this change is safe |
|---|---|---|
| Add `RunLog` (`ObservableObject`, a per-thread-locked buffer + coalesced flush) and `RunLogCard` (the **only** observer) | `Nugget/Views/RunLog.swift` (new) | The page no longer reads the logs ⇒ one log line only recomputes that card; `append` can be entered from any thread (the engine callbacks are on the main queue today, and the store does not depend on that), bursts are coalesced into a single main-queue flush; no lines are dropped |
| All of the home page's `logs` now go through the store; `spawnLogPrinter`, the diagnostic dump, the two "start run" clear points; the log area unconditionally holds a `RunLogCard()` (when empty it draws nothing by itself) | `GoldenNuggetView.swift` | Behaviourally equivalent: the window is still 600 rows, and diagnostic blocks are still appended as one multi-line entry; `grep` confirms that the whole repo has only one place setting `onLog`, so they cannot overwrite each other |
| `AfcMediaBackup.read()` caches the decoded result by "file size + mtime" | `AfcMediaBackup.swift` | `write` uses `.atomic`: any save changes the size or the mtime ⇒ the next read re-decodes (it will not read a stale value); when the file does not exist it caches an empty manifest under the `<absent>` key ✓ the semantics match the original, it just no longer decodes every time |
| `MediaView.hasStoredFiles` becomes state, computed once in `loadManifest()` (also added once on the pull path) | `MediaView.swift` | The predicate itself is not changed by a single word; the trigger timing matches the original logic (entering the page / the end of each action) |
| `GoldenPage`'s inner `VStack` → `LazyVStack` | `GoldenComponents.swift` | Still constrained by `maxWidth` and centred the same way; the children's `.onAppear`/`.task` become "run only once they appear", which is the desired semantics for text field drafts and for the log card |
| `GoldenLogView` uses stable ids (new optional `firstId`) | `GoldenComponents.swift` | The static call sites (the 30 rows on the Tweaks page, the action log on the Media page) do not pass it ⇒ default 0, behaviour unchanged |

**Effect argument (verifiable, no profiler needed)**: after fixing items 1 and 2, the number of renders for one
run goes from "1 + number of log lines" to "1", and there is **no** heavy work left in `body`. Verification
command:

```bash
grep -nE "contentsOf|JSONDecoder|enumerator|attributesOfItem|AfcMediaBackup\.read" Nugget/Views/*.swift
```

After the change only four hits remain, and each one is allowed on inspection: `GoldenComponents.swift:505-507`
(`GoldenLogo`'s `static let bundledIcon`, a **one-time** load), `GoldenNuggetView.swift:183` (`mediaDetail`
⇒ now only a **`stat`** inside `AfcMediaBackup.read()`; the decoding is absorbed by the cache in §3),
`MediaView.swift:28,47` (both inside `loadManifest()` / `storeHasFiles()`, invoked by `.task` or by an
action, **not in `body`**); the remaining hits are all in **actions** such as pairing files and importing
presets. Item 3 means off-screen rows are no longer constructed, which directly reduces the first frame and
the diffs.

## 4. Looked at but deliberately not changed (with reasons)

- **`visibleSpecs` is computed 4 times per render** (`TweaksView.swift:114,151`): it could be changed to
  "compute it once in the parent and pass it down as a parameter", but one computation = 133 × version
  string comparisons, which is on the order of microseconds ⇒ it is noise. If we change it, we wait until
  on-device Instruments shows that it is a hotspot.
- **`TweakVersion.components` splits the string every time**: same thing, an even smaller order of
  magnitude; memoizing it would only add state.
- **`DaemonsView`'s per-section filtering**: same.
- **`MemoryLogSink` sets no upper bound**: a design decision (the diagnostic tail needs the full data), and
  the view side already has a window.
- **`AppLog` does one `DispatchQueue.main.async` per line**: `RunLog` already coalesces bursts; eliminating
  it entirely would mean changing `AppLog`'s dispatch policy, which would affect several call sites, and
  the benefit would not be worth it compared with what is there now.

## 5. How to quantify on a real device (next step)

1. **Instruments → SwiftUI** template (Xcode 27 ships a "View Body" track): first record the baseline
   body-evaluation count for `GoldenNuggetView` / `TweaksView`, run one apply, and compare before and
   after the change. Expected: before ≈ 1 + number of log lines, after ≈ 1.
2. **Time Profiler** on one apply: check whether `JSONDecoder.decode` / `contentsOf` / `enumerator(atPath:)`
   are still on the stack on the main thread — after the change there should be no such symbols left under
   `/Views/`.
3. **First frame**: when entering the Tweaks page (Liquid Glass expanded), use `os_signpost` or the
   "Hangs / Animation Hitches" instrument in Instruments to look at the first-frame duration; before
   `LazyVStack` it was "all 98 cards constructed".
4. The app's own channel: `Share poc.log` / `Share diagnostics.txt` (the 600-row `RunLog` window + the
   full tail of the engine's in-memory sink) is the crime scene of "what happened"; the change does not
   affect their availability.
