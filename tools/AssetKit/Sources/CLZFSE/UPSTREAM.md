# CLZFSE

Vendored from https://github.com/lzfse/lzfse @ `e634ca58b4821d9f3d560cdc6df5dec02ffc93fd`
(2017-05-22, master tip; upstream has had no commits since).

Licensed under BSD 3-Clause; see `LICENSE` in this directory.

## Files

Verbatim copies of upstream `src/*` minus `lzfse_main.c` (the CLI driver):

- `include/lzfse.h` (the public header; moved into `include/` so SwiftPM treats
  it as the public umbrella header for the `CLZFSE` module)
- `include/module.modulemap` (locally authored; declares `CLZFSE` umbrella for `lzfse.h`)
- `lzfse_decode.c`, `lzfse_decode_base.c`
- `lzfse_encode.c`, `lzfse_encode_base.c`, `lzfse_encode_tables.h`
- `lzfse_fse.c`, `lzfse_fse.h`
- `lzfse_internal.h`, `lzfse_tunables.h`
- `lzvn_decode_base.c`, `lzvn_decode_base.h`
- `lzvn_encode_base.c`, `lzvn_encode_base.h`

## Why vendored

The LZFSE encoder is needed to produce real (not passthrough) compressed
bitmap payloads inside the `Assets.car` files this package writes. Apple's
`Compression` framework provides LZFSE on Darwin only; using a single vendored
encoder on every platform makes CAR output byte-deterministic across Linux and
macOS and lets the macOS-only `AssetutilParseTests` gate verify the exact
encoder path Linux ships.

## Syncing with upstream

Upstream is effectively frozen; a sync is unlikely to ever be needed. If it
becomes necessary:

```sh
gh api repos/lzfse/lzfse/tarball/<commit-sha> > /tmp/lzfse.tar.gz
tar -xzf /tmp/lzfse.tar.gz -C /tmp
cp /tmp/lzfse-lzfse-<short-sha>/src/lzfse.h         Sources/CLZFSE/include/
cp /tmp/lzfse-lzfse-<short-sha>/src/{lzfse,lzvn}_*  Sources/CLZFSE/
cp /tmp/lzfse-lzfse-<short-sha>/LICENSE             Sources/CLZFSE/
# (do NOT copy lzfse_main.c)
```

Then update the pinned commit in this file and run `swift test`.
