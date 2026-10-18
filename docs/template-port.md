# `.batter` templates: port scope, limits, verification

> **Status: landed (2026-10-18).** `scripts/typecheck.sh` reports **0 errors, 0
> warnings** in `Nugget/` (the one remaining diagnostic is the documented
> `AirliftFFI` phantom). The compile and apply stages were **differentially
> tested against the reference**: 46 XML/globby cases and 38 end-to-end cases,
> every field and every resulting file byte-identical or semantically identical
> as noted below.
>
> **Not verified on a device.** Nothing here has been through a restore. The
> delivery channel is the existing `TweakPayload → TweakInjector` one, whose row
> shapes and evidence are in `docs/tweak-port.md` §2; a template into
> `AppDomain-com.example.thing` uses `TweakRowProfile.appContainer`, which is a
> class with production evidence. What is *new* is what files go in, not how.

Ported from: `~/GoldenNugget/src/tweaks/posterboard/template_file.py`,
`tendie_file.py`, `template_options/` (five modules), `templates_tweak.py`, and
`src/controllers/xml_handler.py`.
Ported into: `Nugget/Core/Template*.swift`, `Nugget/Core/XMLScanner.swift`,
`Nugget/Views/TemplatesView.swift`, and the engine / PosterBoard compile stages.

---

## 1. What a `.batter` is

A ZIP carrying a `config.json` that names a **domain** and lists **options** —
the things the user may change. GoldenNugget unpacks it, rewrites the extracted
files according to the options, then delivers the result.

Two delivery routes, and which one a template takes is decided by its own
`domain` — the reference's split, in `TemplatesTweak.apply_tweak` and
`PosterboardTweak.apply_tweak`:

| `domain` | route | here |
|---|---|---|
| `AppDomain-com.apple.PosterBoard` (or the bare `com.apple.PosterBoard`) | unpacked **with the wallpapers**, picked up by the same descriptor walk | `PosterBoard.compile(templates:)` |
| any other `AppDomain-*` | the `container/` tree is walked and each file becomes a payload | `TemplateDelivery.payloads` |
| `Sparserestore-<abs path>` | the sparse-restore protocol | **refused**, see §3 |

## 2. The five option types

| type | what it does | reference |
|---|---|---|
| `replace` | the user's file, written over every path in `files` | `replace_option.py` |
| `remove` | delete files/directories, or delete an XML element by identifier | `remove_option.py` |
| `set` | textbox / slider / toggle / color_picker → `.caml` attribute, plist key, or text substitution | `set_option.py` |
| `picker` | choose one of several file sets; the others are deleted; optional rename | `picker_option.py` |
| `bundle_id` | not an option object — a flag that makes the domain's bundle id editable | `template_file.py` |

## 3. Deliberate divergences

**`Sparserestore-` templates are refused, with the reason on screen and in the
run log.** This project deleted its whole `Nugget/Sparserestore/` tree on
2026-09-19 (`d1830d9`, "some other big things") in favour of the protective
backup route; that commit records no reason, so re-introducing the protocol is
not something this port does quietly. The template is therefore left out of the
apply and *says so* — a silent skip looks exactly like success, which is the
worst available outcome. `TemplateFile.requiresSparserestore` holds the reason.

**A `replace` option's chosen file does not survive a relaunch.** The reference
holds its templates in memory, so the value is simply still there. Here the
template is a file on disk re-read at launch, and the picked file is staged in
`Documents/TemplateChoices/`, which is emptied at the start of every apply.
Every *other* option value is persisted (`TemplateOptionStore`, keyed by file
name + option index). The page says this on the row.

**Option values are keyed by index, not by label.** Two options in one config
may share a label; the config's own order does not change under the user.

**Resources are staged next to the template** (`Documents/Templates/Resources/<name>/`)
rather than in a `TemporaryDirectory` removed by `clean_files`, so re-entering
the page does not re-extract and deleting the template deletes them.

**The templates list survives a launch; the reference's does not** — for the
same reason the `.tendies` list does here (`PosterBoardImports`).

**`format_version` above 2 is refused**, not attempted: a newer config's options
may mean things this port does not implement.

**A version gate is skipped when no device version is known.** The reference
guards with `if device_version and …`, so a falsy version short-circuits and the
template loads. That is reproduced rather than "fixed" into a refusal, because
this app loads its template list at launch — before the tunnel is up — and a
refusal there would make every version-gated template look broken until the
Templates page happened to be opened. The page passes the real version, so the
gate is enforced where it can be.

**`bundleID` is empty unless a `bundle_id` option exists.** The reference
declares `bundle_id: str = None` and assigns it only in the `bundle_id` branch,
so the text box starts empty and the domain's id is the *placeholder*.

## 4. The XML engine, and why it is hand-written

`xml_handler.py` is `ElementTree` over a CoreAnimation document: find elements
by `nuggetId` (or the CoreAnimation `id`, plus a second `targetId` pass), set
attributes, honour a `nuggetOffset` equation, and remove elements.

iOS has no `XMLDocument`, only the SAX `XMLParser`, whose `attributeDict` is
unordered — a document written back through it comes out with every attribute of
every touched element moved. So `TemplateXML.swift` + `XMLScanner.swift` are a
small DOM for the XML a `.caml` actually contains. It keeps attribute order, text
nodes (and therefore indentation), and the `<x/>` vs `<x />` spelling, so **a
document nothing matched comes back byte for byte**. `ElementTree` reformats
every document it writes; that is why the harness compares *semantically* for
edited documents and byte-for-byte only for the untouched one.

Two behaviours were measured against the reference rather than assumed, and both
are pinned by `scripts/template-xml-check.swift`:

- **a removed element takes its tail with it** — the whitespace between its
  closing tag and the next sibling goes too, because `ElementTree` keeps `tail`
  on the element;
- **a bare `**` in a `files` glob is the whole subtree**, and it does **not**
  match the starting directory itself (`glob("**")` returns its contents).

`nuggetOffset` is evaluated by a recursive-descent parser over `+ - * / % **`,
parentheses and `x`/`y`/`z`/`a` — **not** Python's `eval`, and anything else is
refused by name. A template author who needs more than arithmetic in an offset
has a different tool, and an `eval` here would be arbitrary code driven by the
contents of a file the user chose to import.

`glob.glob(..., recursive=True)` is reproduced in `TemplateGlob`, including `*`
and `?` not crossing `/`, `**/` matching zero components, and `fnmatch`'s
character classes.

## 5. Delivery

`TemplateSelection` is owned by `RootView` (the `Apply` is on the home page and
a `NavigationSplitView` destroys the detail view). The engine's
`applyTweaksRun` gained a template stage:

- a non-PosterBoard template → `TemplateDelivery.payloads`, one `TweakPayload`
  per file under `container/`, into its `AppDomain-*`;
- a PosterBoard template → extracted into `PosterBoard.workDirectory` and found
  by the same walk the packs use, because that walk is what turns a descriptor
  into a wallpaper.

A template with descriptors needs the store database; one with none does not, so
`PosterBoard.compile` requires a database only when it staged config items. The
reference's early return covers tendies, templates and the video together, which
is why `templates` is a term in the guard and not only in the walk.

The Apply button names what it carries (`Apply Tweaks & Wallpapers`, `… &
Templates`), and a run is not started for a template that cannot be delivered.

## 6. Verification

```bash
# XML engine + globs, against the reference's own functions
mkdir -p /tmp/tmpl-xml && for f in Nugget/Core/TemplateXML.swift \
    Nugget/Core/XMLScanner.swift scripts/template-xml-check.swift; do
  cat "$f"; printf '\n'; done > /tmp/tmpl-xml/main.swift
xcrun swiftc -O -swift-version 5 -target arm64-apple-macosx26.0 \
    /tmp/tmpl-xml/main.swift -o /tmp/tmpl-xml/check && /tmp/tmpl-xml/check

# End to end: header, options, gates — the reference's own TemplateFile.extract
# run in a subprocess as the oracle.  Four source files, no PosterBoard.swift:
# that file pulls the device stack and an unconditional `import ZIPFoundation`,
# so the two symbols the template path borrows (`compareVersion`,
# `PosterBoardPlist.set`) are stubbed **verbatim** inside the harness script.
# `-target` must be ≥ 26 — `conformingTo:` is a UTType overload, and the spliced
# file needs `import UniformTypeIdentifiers` (which the harness file declares)
# for `.directory`/`.data` to resolve on the host.
mkdir -p /tmp/tmpl-e2e && cat Nugget/Core/TemplateXML.swift \
    Nugget/Core/XMLScanner.swift Nugget/Core/TemplateFile.swift \
    Nugget/Core/TemplateOptions.swift scripts/template-e2e-check.swift \
    > /tmp/tmpl-e2e/main.swift
xcrun swiftc -O -swift-version 5 -target arm64-apple-macosx26.0 \
    /tmp/tmpl-e2e/main.swift -o /tmp/tmpl-e2e/check && /tmp/tmpl-e2e/check
```

Both harnesses were **reverse-verified**: every ported behaviour was mutated back
to a naive version and the gate confirmed red — 7/7 for the XML harness, 7/7 for
the end-to-end one. That step is what caught the four real bugs listed in §8.

The reference side needs an interpreter with `packaging` (it imports
`src/devicemanagement/constants.py`); `GOLDENNUGGET_PYTHON` overrides the one
the harness picks.

### Not covered

The manifest/blob layer, the prune set, the backup pull and the restore — all
shared with the tweak path and documented in `docs/tweak-port.md`. Also: the
`replace` option's picker UI, and any iOS-only file access.

## 7. Usage

Sidebar → **Templates**. Import a `.batter`, fill in its options, press Apply on
the home page. Options render as: a switch (remove/toggle), a text field
(textbox), a slider per component, a colour well, a menu or a list of switches
(picker), and a file button (replace).

## 8. Bugs these harnesses caught

Recorded because they are the argument for having them.

1. **`hidden=True`** — the reference's `set_xml_values` opens with
   `int()` on bools, so a toggle writes `1`, never `True`.
2. **alpha inlined into the colour attribute** — `convert_back` returns RGB only;
   alpha leaves as the second key of the same call (`opacity`), so `colorspace`
   must have three numbers, not four.
3. **`195.0 365.0` instead of `195 365`** — the reference's `convert_str` parses
   an integer-typed value as `int`, and `str(195)` is `195`. Colour components
   are the opposite case (`str(1.0)` is `1.0`), so there are two float
   spellings, not one.
4. **Python's `round()` is banker's rounding** — it decides which 8-bit channel a
   colour lands on, and Swift's `.rounded()` is half-away-from-zero.