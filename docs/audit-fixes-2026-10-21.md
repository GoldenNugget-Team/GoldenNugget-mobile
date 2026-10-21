# Code audit fixes — 2026-10-21

This change addresses the 13 findings from the audit of `43eb25a`.

- **1, 5 — daemon presets:** legacy group imports filter their keys; the compiler independently restricts writes to catalog labels. Canonical imports retain the actual enabled values instead of falling back to false defaults.
- **6, 7 — daemon controls:** the master gate belongs to `TweakSelection` and survives preset/autosave roundtrips separately from group choices. Turning it off suppresses both launchd and Screen Time payloads. With the master on, turning the last group off writes explicit false values so an earlier disabled override can be removed.
- **2, 3, 12 — template paths:** archives reject escaping paths and symlinks before reading resources. Option paths and picker rename destinations are checked too. Resolved paths must remain within their staging root; recursive globs skip symlinks. Reversed character ranges match nothing instead of trapping.
- **4, 8, 13 — template inputs:** replacement files remain available during compilation and retries. Each picked file gets its own staging path, so choosing a second replacement cannot delete another option's input. Restored value-type options are assigned back to the template, including explicit empty multi-selections. File filters use extensions without a leading dot.
- **9 — domain delivery:** only files inside a template's `container` tree become restore payloads. Config files and preview resources remain local.
- **10, 11 — PosterBoard:** AirLift configures and delivers descriptor templates, including template-only and mixed selections. Container templates are rejected before device preparation with a direction to use Protective backup. An undeliverable source cannot silently count as a successful mixed apply. The backup path fetches the device database for template-only wallpaper additions as well as ordinary packs.

## Regression checks

```sh
python3 scripts/check-template-safety.py
python3 scripts/check-desktop-sync.py
python3 scripts/check-posterboard-airlift.py
python3 scripts/check-posterboard-backup.py
scripts/build-ipa.sh Release
```

`check-template-safety.py` compiles the production iOS template code with the
vendored ZIPFoundation sources. It also tests template-only PosterBoard backup
compilation with the real SQLite store implementation. Only device/video
operations use test doubles. Inputs, extracted files and generated binaries live
in temporary directories.

The existing XML and template end-to-end differential harnesses also pass against
the adjacent desktop checkout. The end-to-end harness imports the desktop's real
pure path-mapping module without initializing its hardware transport package.

These checks do not install or apply anything on a physical phone. Device-side
rendering, service restoration and reboot behavior still need hardware validation.
