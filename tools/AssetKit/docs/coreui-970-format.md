# CoreUI 970 `.car` format reference

This document describes the CoreUI `Assets.car` (Compiled Asset Resource) binary format as emitted by `actool` in Xcode 26 (CoreUI 970, `StorageVersion = 17`, targeting iOS 16+).

It is not a replacement for reading `Sources/AssetKit/`; it is a companion that explains *why* the bytes are the way they are, with particular attention to six places where the public reverse-engineering writeups (Timac 2018, DBG.RE 2026) describe an older format and would have given wrong values if followed literally. This writer was developed against a freshly dumped `actool` reference rather than from those writeups; the divergences below cost real iteration cycles to discover.

## Container

A `.car` is a BOM ("Bill of Materials") container whose payload blocks carry CoreUI-specific data. The BOM format itself is documented elsewhere (libbom, Timac 2018); the relevant points are:

- Header at offset 0, all big-endian: `BOMStore` magic, version, block count, plus offsets to the block index and vars tables.
- Block payloads packed sequentially after the header.
- Block index table: `count u32` then `(addr u32, len u32)` pairs. Block 0 is reserved/null.
- Variables table: `count u32` then per-entry `{ blockID u32, nameLen u8, name[nameLen] }`. CoreUI looks up payloads by name.

The CoreUI-named variables this writer emits, in the canonical order `actool` produces:

| Variable | Type | Purpose |
|---|---|---|
| `CARHEADER` | block | 436-byte fixed-size header with version, storage version, schema version, etc. |
| `RENDITIONS` | tree | Packed-key tuple → CSI rendition bytes. |
| `FACETKEYS` | tree | Asset name → attribute pairs. |
| `APPEARANCEKEYS` | tree | Appearance name string → numeric ID. |
| `KEYFORMAT` | block | Declares the attribute-tuple layout used by RENDITIONS keys. |
| `EXTENDED_METADATA` | block | 1028-byte block; platform / deployment target / authoring tool. |
| `BITMAPKEYS` | tree | Per-asset bitmap descriptors; required for `UIImage(named:)` lookup of generic image assets. |

iOS's `UIImage(named:)` and SpringBoard's icon-render pipeline both walk the vars table in this order and reject catalogs whose ordering doesn't match the reference shape. Order is load-bearing.

## Seven places the public writeups are wrong for CoreUI 970

These are listed by detection mode — §§1–3 and §7 are caught by Apple's own `assetutil --info`; §§4–6 silently produce a catalog that parses cleanly but fails at runtime on a real iOS device. The runtime-only ones were the costly ones to discover, because there's no easy local signal. §7 is also notionally easy to detect, but it only fires on macOS 26.4+ — the older `/usr/bin/assetutil` silently tolerated the wrong shape.

### 1. AttributeID enum values are not stable across CoreUI versions

DBG.RE 2026 lists `appearance=6`, `scale=11`, `identifier=15`. CoreUI 970 emits `appearance=7`, `scale=12`, `identifier=17`. The full v1 schema this writer uses:

```
.element       = 1
.part          = 2
.appearance    = 7
.dimension2    = 9
.scale         = 12
.localization  = 13
.idiom         = 15
.subtype       = 16
.identifier    = 17
```

Implementation: [Sources/AssetKit/CAR/KeyFormat.swift](../Sources/AssetKit/CAR/KeyFormat.swift).

If you target a different Xcode version, re-derive these by dumping a fresh `assetutil --info` reference catalog. CoreUI itself binary-searches rendition keys by raw byte comparison, so a single wrong attribute number desyncs the entire lookup.

### 2. Magic-word byte order is inconsistent per block

CoreUI mixes endianness for its magic words. The following are little-endian multi-char constants (bytes appear reversed on disk):

- `CTAR` → on disk: `R`, `A`, `T`, `C`
- `CTSI` → on disk: `I`, `S`, `T`, `C`
- `kfmt` → on disk: `t`, `m`, `f`, `k`

These are written in character order (no reversal):

- `MLEC`, `KCBC`, `COLR`, `META`

There's no obvious pattern in the source code for which is which; it must be matched against actool's output per block. Mixing this up produces files that look superficially correct in a hex viewer but fail at runtime.

### 3. A 104-byte TVL section is required between the CSI header and the bitmap body

For raw-bitmap renditions, CoreUI 970 expects a TVL (type-length-value) metadata block of exactly 104 bytes between the 184-byte CSI header and the MLEC-framed bitmap payload. Five entries:

| Type | Length | Value |
|---|---|---|
| 1001 | 20 | bitmap descriptor: `(1, 0, 0, width, height)` |
| 1003 | 28 | destination rect: `(1, 0, 0, 0, 0, width, height)` |
| 1004 | 8 | slice/scale pair: `(0, 1.0f)` |
| 1006 | 4 | `1` — likely bitmap-count or has-mipmap-stages flag |
| 1007 | 4 | bytes per row, aligned up to 16 |

Without this section, CoreUI parses the rendition key but cannot materialise the bitmap. `assetutil --info` reports `AssetType: Unknown` and omits `PixelWidth`, `PixelHeight`, `Encoding`, and `Compression`.

Implementation: [Sources/AssetKit/CAR/CSIWriter.swift](../Sources/AssetKit/CAR/CSIWriter.swift).

### 4. iOS uses `UIAppearanceAny` / `UIAppearanceDark` in APPEARANCEKEYS — not the macOS names

The APPEARANCEKEYS tree maps appearance name strings to the numeric IDs that appear in the `appearance` slot of rendition keys. CoreUI walks this tree by exact string match.

- iOS: `UIAppearanceAny` (0), `UIAppearanceDark` (1)
- macOS: `NSAppearanceNameAqua` (0), `NSAppearanceNameDarkAqua` (1)

Registering only the macOS names produces a catalog where `UIImage(named:)` returns nil at runtime for every asset, even though `assetutil --info` parses cleanly. SpringBoard's appicon path doesn't depend on APPEARANCEKEYS (it falls back to loose PNGs we emit alongside `Assets.car`, see §"SpringBoard fallback" below), which masks the bug for icon-only catalogs.

The `UIAppearanceAny` row (id=0) is always emitted, because every rendition key packs `appearance=0` as the default-variant marker — even in catalogs with no explicit appearance entries. The `UIAppearanceDark` row (id=1) is emitted only when at least one rendition in the catalog declares the dark variant (matches actool's reference: dark-free catalogs omit the row entirely). Each appearance ID is encoded as a single `u16 LE`.

Implementation: [Sources/AssetKit/CAR/AppearanceKeys.swift](../Sources/AssetKit/CAR/AppearanceKeys.swift).

### 5. `actool` allocates value blocks before key blocks in BOM trees

For BOM trees with separate key/value blocks (most trees other than BITMAPKEYS), the convention is to allocate the value block *before* its corresponding key block — so the value block has the lower block ID.

`UIImage(named:)` returns nil if this ordering is reversed. The catalog still parses with `assetutil` because the file structure is valid; iOS's runtime walks the leaf assuming value-first IDs.

Implementation: [Sources/AssetKit/BOM/BOMTree.swift](../Sources/AssetKit/BOM/BOMTree.swift).

### 6. BITMAPKEYS is required for `UIImage(named:)` resolution

The BITMAPKEYS tree carries per-asset bitmap descriptors that CoreUI consults during `UIImage(named:)` resolution for `.imageset` (and analogous) assets. Without this tree present, image lookups return nil at runtime even though the renditions are physically present in the file and FACETKEYS / RENDITIONS resolve correctly.

Structure:

- Tree is `isPathInternal = true` and uses a `blockSize` of 1024.
- Each leaf entry's "key" slot is an inline `u32` `NameIdentifier` (not a block pointer like other trees).
- Each value is a 52-byte descriptor.

The 52-byte descriptor layout was derived by diffing `actool`'s outputs for `.appiconset` vs `.imageset` (bitmap source) vs `.imageset` (vector source) renditions. The first 7 `u32`s are header-like; the only one that varies across kinds is slot 6 (an asset-kind marker: `0x04` for PNG / JPG, `0x0e` for SVG vector sources and for appicons). The remaining 6 fields vary by asset kind:

| Field | AppIcon | Image (PNG / JPG) | Vector (SVG) |
|---|---|---|---|
| `u32` slot 6 (asset-kind marker) | `0x0e` | `0x04` | `0x0e` |
| `u32` slot 8 | (idiom×subtype count) | (idiom×subtype count) | (idiom×subtype count) |
| `(u16, u16)` slot 9 | `(1, 1)` | `(1, 0)` | `(1, 0)` |
| `u32` slot 10 | `7` | `1` | `1` |

Followed by three trailing `0xFFFFFFFF` sentinels. Total: 52 bytes. The Vector template matches the Image template after slot 6 — the marker is the only thing CoreUI uses to route the lookup differently for SVG sources.

The `renditionFlags` field in the CSI header differs correspondingly — bit 4 set for `.image` renditions, bit 2 set for vector renditions, both cleared for `.appIcon`.

Implementation: [Sources/AssetKit/CAR/BitmapKeys.swift](../Sources/AssetKit/CAR/BitmapKeys.swift).

### 7. BOM tree leaves must be padded to the declared `blockSize`

Every BOM tree header declares a `blockSize` (`u32`) — the B-tree page size, e.g. `4096` for RENDITIONS / FACETKEYS / APPEARANCEKEYS and `1024` for BITMAPKEYS. The leaf BOM block that the header points to must be at least `blockSize` bytes; pad with zeros after the entry list. `actool` always pads.

On macOS ≤ 26.0, `/usr/bin/assetutil` read only the bytes the leaf's count field said were there and silently tolerated a short underlying block. On macOS 26.4+, `assetutil` reads the full `blockSize` from the leaf stream and aborts with `assetutil: fatal error error exiting: 'BOMStreamGetDataPointer buffer overflow' invalid file` if the block is shorter. iOS's runtime walks leaves by the count field and was never affected — but a catalog that emits short leaves is now unparseable by Apple's own validator on a current macOS.

Note that `/usr/bin/assetutil` is a system binary, not bundled with Xcode — its strictness tracks the macOS version, not the selected Xcode. See also: [the AssetutilParseTests gate](../Tests/AssetKitTests/AssetutilParseTests.swift).

Implementation: [Sources/AssetKit/BOM/BOMTree.swift](../Sources/AssetKit/BOM/BOMTree.swift).

## 7. Preserved-source renditions: SVG and JPG via the DWAR envelope

CoreUI 970 (Xcode 26) introduced a new rendition shape for sources the user wants stored verbatim rather than decoded into a raw bitmap. SVG and JPG both ride this path. The envelope is reused; the surrounding CSI header's `pixelFormat` selects the decoder CoreUI invokes at draw time.

### DWAR envelope

A 12-byte framing wrapper at the start of the rendition body:

| Offset | Size | Field | Notes |
|---|---|---|---|
| 0 | 4 | magic | `'DWAR'` in character order on disk (not LE-reversed like `CTSI` / `CTAR`). Same convention as `MLEC`, `KCBC`, `META`. |
| 4 | 4 | flags `u32 LE` | `1` ⇒ payload is an LZFSE-framed inner stream (`bvxn` or `bvx2`); `0` ⇒ payload is the raw source bytes. |
| 8 | 4 | innerLen `u32 LE` | Length of the payload that follows. |
| 12 | innerLen | payload | LZFSE frame for SVG; raw JPEG bytes for JPG. |

The same envelope serves both formats; the inner compression mode is chosen per source.

### SVG renditions emitted per asset

A single `.svg` source in an imageset produces **four** renditions in the compiled CAR:

1. **One preserved-source vector rendition** (layout=9; see below)
2. **Three rasterised bitmap renditions** at 1x / 2x / 3x

iOS's `UIImage(named:)` resolves SVG-sourced assets through the rasterised bitmap fallbacks, not the vector rendition. Empirically, shipping iOS looks up by `(scale, part=181)` and ignores the vector source; the vector rendition is still emitted because other CoreUI consumers (and future iOS versions) may prefer it, and the marginal cost is small (one DWAR-wrapped LZFSE-compressed copy of the XML, typically a few hundred bytes for icon SVGs).

The three bitmap renditions are produced by an injected `SVGRasterizer` (default: `rsvg-convert` subprocess). Pixel dimensions for each scale are `intrinsicWidth * scale × intrinsicHeight * scale`, where the intrinsic dimensions come from the SVG's `width` / `height` attributes or its `viewBox`. The resulting BGRA bitmaps go through the regular bitmap CSI writer with `pixelFormat='ARGB'` and `layout=12` — identical in shape to PNG-sourced bitmaps.

### SVG vector rendition

| CSI field | Value |
|---|---|
| `layout` | `9` (new in CoreUI 970) |
| `pixelFormat` | `'SVG '` (trailing space) as an LE multi-char constant; on-disk bytes ` `, `G`, `V`, `S`. |
| `renditionFlags` | `0x4` (bit 2 set; distinguishes vector from the generic-image category) |
| `width` / `height` / `scaleFactor` / `colorSpace` | all `0` (vector is scale-free; intrinsic dimensions live in the SVG viewBox) |
| `tvlLength` | `28` |
| `bitmapCount` | `1` |
| body | `DWAR(flags=1)` followed by `bvxn(LZFSE-encoded raw SVG XML bytes)` |

The TVL section carries only two entries:

| Type | Length | Value |
|---|---|---|
| 1004 | 8 | slice/scale pair `(0, 1.0f)` |
| 1006 | 4 | `1` |

Entries `1001` (bitmap descriptor), `1003` (destination rect), and `1007` (bytes-per-row) are absent — they are pixel-specific and have no meaning for a vector source.

### JPG raw-passthrough rendition

| CSI field | Value |
|---|---|
| `layout` | `12` — **same as bitmap**; JPG sits inside CoreUI's bitmap-asset category and reuses the bitmap layout value |
| `pixelFormat` | `'JPEG'` as an LE multi-char constant; on-disk bytes `G`, `E`, `P`, `J`. |
| `renditionFlags` | `0x10` (same as generic `.image` bitmap) |
| `width` / `height` / `colorSpace` | `0` in the CSI header; decoded dimensions live in TVL `1001` and `1003` |
| `scaleFactor` | `scale*100` (respects `@Nx` filename suffix, same as PNG) |
| `tvlLength` | `92` |
| `bitmapCount` | `1` |
| body | `DWAR(flags=0)` followed by raw JPEG bytes (JFIF / EXIF / SOS markers all included verbatim) |

The TVL section is shaped like the bitmap TVL but with type `1007` (bytes-per-row) omitted — bytes-per-row is a strided-bitmap concept that has no analogue in a JPEG bitstream. The decoded width / height in `1001` and `1003` are populated by walking the JPEG segment chain to SOF0 / SOF1 / SOF2; see [Sources/AssetKit/Rendition/JPEGSource.swift](../Sources/AssetKit/Rendition/JPEGSource.swift).

| Type | Length | Value |
|---|---|---|
| 1001 | 20 | `(1, 0, 0, width, height)` |
| 1003 | 28 | `(1, 0, 0, 0, 0, width, height)` |
| 1004 | 8 | slice/scale pair `(0, 1.0f)` |
| 1006 | 4 | `1` |

### Surrounding-table treatment

JPG renditions sit in the generic-image category at every layer above the CSI body, exactly like PNG. SVG vector renditions diverge in two places because CoreUI keys the vector-source slot separately from the bitmap-source slot.

- **FACETKEYS**: `(element=85, part=181)` for all three source formats. The asset-level entry is opaque to source format; one FACETKEYS row per asset name regardless of whether the underlying renditions are PNG, JPG, or SVG.
- **BITMAPKEYS**:
  - PNG, JPG → `.image` 52-byte descriptor template (slot 6 asset-kind marker = `0x04`).
  - SVG → separate `.vector` template (same shape as `.image` after slot 6; marker = `0x0e`).
  See §6 above for the full descriptor layout.
- **RENDITIONS tree key** (per-rendition, 18-byte packed-attribute tuple):
  - PNG, JPG → `(element=85, part=181)`.
  - SVG vector → `(element=85, part=42, scale=1)`. The reference packs every SVG vector rendition into the `scale=1` slot of CoreUI's lookup tree regardless of any `@Nx` in the source filename; encoding `scale=0` here orphans the rendition from CoreUI's scale-keyed lookups even though `assetutil --info` still parses the file cleanly.
  - For all source formats, the `appearance` slot still carries dark-mode variants.
- **APPEARANCEKEYS**: rows emitted on demand — `UIAppearanceAny` always, `UIAppearanceDark` only when at least one rendition declares the dark variant. Each ID is a single `u16 LE`.
- **KEYFORMAT**, **EXTENDED_METADATA**, **CARHEADER**: unchanged.

Implementation: [Sources/AssetKit/CAR/CSIWriter.swift](../Sources/AssetKit/CAR/CSIWriter.swift), [Sources/AssetKit/Rendition/Rendition.swift](../Sources/AssetKit/Rendition/Rendition.swift), [Sources/AssetKit/Rendition/ImageRenderer.swift](../Sources/AssetKit/Rendition/ImageRenderer.swift).

### Historical note

Older Xcode releases (11 through 13 era) converted SVG to PDF internally and stored the PDF stream as a CoreUI vector rendition body. Modern actool no longer does the PDF round-trip: it stores the SVG XML directly, LZFSE-compressed inside the DWAR envelope. Anything you may have read about `preserves-vector-representation` triggering an SVG-to-PDF intermediate is the older shape.

## SpringBoard fallback (loose-PNG escape hatch)

The library emits loose PNGs into the bundle root alongside `Assets.car`, named per `CFBundleIconFiles` (e.g. `AppIcon60x60@2x.png`). These are not redundant with the CAR-embedded renditions — they exist because SpringBoard's home-screen icon-render pipeline uses the loose-PNG fallback whenever CoreUI's rendition lookup misses.

This writer's `NameIdentifier` is `CRC32-IEEE(name) & 0xFFFF`, whereas `actool`'s hash function differs. The truncated CRC32 produces a value that matches across this writer's own FACETKEYS and RENDITIONS trees (which is what CoreUI requires for lookup), but doesn't match what SpringBoard would compute for the same asset name. The loose-PNG fallback masks this for app icons.

Imagesets have no such fallback. This is why divergences #4-6 above gate `UIImage(named:)` for image assets — there's no second chance.

## Workflow: generating a fresh `actool` reference

When changing any CoreUI block-emitting code (`CAR/*.swift`, `BOM/*.swift`), the durable safety net is to generate a reference Assets.car with `actool` and compare bytes.

```sh
# Create a fixture .xcassets, then:
xcrun actool \
  --compile /tmp/actool-out \
  --platform iphoneos \
  --minimum-deployment-target 16.0 \
  --output-partial-info-plist /tmp/actool-out/partial.plist \
  Test.xcassets

# Inspect:
xcrun assetutil --info /tmp/actool-out/Assets.car

# Hex-diff against this writer's output:
xxd /tmp/actool-out/Assets.car > /tmp/ref.hex
xxd /tmp/our-output/Assets.car > /tmp/ours.hex
diff /tmp/ref.hex /tmp/ours.hex
```

The `assetutil` parse gate in [Tests/AssetKitTests/AssetutilParseTests.swift](../Tests/AssetKitTests/AssetutilParseTests.swift) automates the most important half of this for the project's CI.

Crash signals like `_swapKeyFormat` are register heuristics from the iOS crash reporter, not diagnoses; treat them as "something is wrong upstream of this point" rather than "this specific function is the bug."

## Drift across Xcode and macOS versions

CoreUI's format has changed silently in past Xcode releases without changes to the writeups people cite. Anyone targeting a newer Xcode should:

1. Dump a reference Assets.car with that Xcode's `actool`.
2. Re-derive the AttributeID enum values from the KEYFORMAT block of that reference.
3. Re-verify the magic-word endianness for each block.
4. Re-verify the BITMAPKEYS descriptor layout against `.imageset` and `.appiconset` reference outputs.
5. Run the `assetutil` parse gate against new fixture catalogs.

Two distinct sources of drift to keep separate:

- **Xcode (`actool`) drift** — the bytes Apple's compiler emits. Item §1 (AttributeIDs) is the classic example.
- **macOS (`/usr/bin/assetutil`) drift** — how strictly Apple's validator reads existing bytes. `assetutil` is a system binary, not bundled with Xcode; its parser strictness tracks the macOS version. §7 (leaf padding) was discovered exactly this way: a catalog accepted by `assetutil` on macOS 26.0 was rejected by the same code on macOS 26.4 with no change to `actool` or the writer in between. When the parse gate splits between local and CI, compare `sw_vers` first; the Xcode pin doesn't move `assetutil`.

The format is undocumented and Apple is under no obligation to keep it stable. This document and this writer reflect a snapshot of CoreUI 970; treat it as such.
