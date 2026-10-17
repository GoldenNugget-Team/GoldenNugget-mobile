# Vendor/patches

Source-level patches applied when rebuilding `Vendor/IDevice.xcframework/ios-arm64/libidevice_ffi.a`.
The prebuilt archive is a binary; these are the deltas that make it reproducible.

| Path | Applied to | Why |
|---|---|---|
| `jktcp/` | crates.io `jktcp` (via `[patch.crates-io]`) | Fixes the backup stall. See `jktcp/README-PATCH.md`. |
| `idevice-ffi/take_socket.rs` | `idevice/src/lib.rs` | Non-consuming socket accessor, needed by the next row. |
| `idevice-ffi/idevice_to_stream.rs` | `ffi/src/lib.rs` | Restores `_idevice_to_stream`, which v0.1.68 does not have. |
| `idevice-ffi/factory_info.patch` | `ffi/src/mobilebackup2.rs`, `idevice/src/services/mobilebackup2.rs`, `tools/src/mobilebackup2.rs` | Restores the `factory_info` parameter of `mobilebackup2_backup`. Without it the app crashes the instant a backup starts. |
| `idevice-ffi/should_preserve.patch` | same two `mobilebackup2.rs` files | Restores the pre-store filter. Without it a *protective* backup writes every photo and video to flash. |

## idevice-ffi

The shipped `libidevice_ffi.a` exports `_idevice_to_stream` and
`Vendor/IDevice.xcframework/ios-arm64/Headers/idevice.h` declares it, but upstream
`idevice` v0.1.68 contains no such binding — the shipped binary was cut from a
newer revision than any tag we can pin. Rebuilding straight from v0.1.68 therefore
produces an archive that is missing exactly one C-ABI symbol:

```
$ nm -gj <shipped>  | grep '^_' | sort -u > old.txt
$ nm -gj <rebuilt>  | grep '^_' | sort -u > new.txt
$ diff old.txt new.txt
< _idevice_to_stream          # 4527 vs 4526 symbols
```

and Nugget fails to link:

```
Vendor/MinimuxerGateway/idevice/IdeviceGateway.swift:1379
  let streamErr = idevice_to_stream(debugDevice, &stream)   // launchAppPre17, iOS < 17
```

The header says the call *consumes* the `IdeviceHandle`, and the Swift caller
honours that (`debugDeviceNeedsFree = false` on success). Upstream's
`Idevice::get_socket(self)` consumes the receiver, so on the failure path there is
no handle left to return and the caller's deferred `idevice_free` would
double-free. Hence `take_socket`, which is the same operation without the move:

- success → handle consumed and freed here; caller must not free it
- failure  → handle handed back (`mem::forget`); caller's `idevice_free` stays valid

### factory_info.patch — the crash on "Run"

Same root cause as above — the shipped header is newer than v0.1.68 — but this one
is an **arity** mismatch, which no symbol diff can see. The header declares seven
parameters:

```c
struct IdeviceFfiError *mobilebackup2_backup(client, backup_root,
                                             source_identifier, options,
                                             plist_t factory_info,          /* <- */
                                             const struct ...FFI *delegate,
                                             plist_t *out_response);
```

v0.1.68 implements six. On arm64 Swift puts `factory_info` in `x4`, which is where
Rust expects `delegate`, so Rust reads the plist object as the delegate struct and
calls whatever bytes happen to sit at its `create_dir_all` slot. `Nugget` always
passes a non-NULL `factory_info` (`ProtectiveBackup` sets `skipAppContainers:
true`), so the very first delegate call jumps into garbage: the app dies after the
version exchange, with no Rust panic and no log line.

The patch also folds in the `TargetIdentifier` fix that
`scripts/patch-idevice-target-identifier.sh` used to do at the binary level:
`send_request` now falls back to `target_identifier.or(source_identifier)`, because
an RSD connection never learns the UDID and the device refuses a request with no
`TargetIdentifier`. That script is superseded — see its header.

Because `factory_info` cannot be restored by appending a snippet, it is kept as a
plain `git diff` against the tag. `scripts/build-idevice-ios.sh` applies it
idempotently (`git apply --reverse --check` first) and then greps the resulting
signature, so a silently-stale patch fails the build.

### should_preserve.patch — the backup that got slow

The very same drift, second instance. The header's
`Mobilebackup2BackupDelegateFFI` ends with

```c
bool (*should_preserve)(const char *device_name, const char *file_name, void *context);
```

and v0.1.68 has no such field — its FFI delegate does not implement
`on_file_received` either, so the filter `ProtectiveBackup` hands in
(`skipAppContainers` aside, the `shouldPreserve` closure) is **never called**.
Every file the device uploads is written to disk in full. On a device with a
photo library that is gigabytes of flash written and then thrown away, which is
what turned a protective backup into a slow one.

Worse, v0.1.68's `handle_upload_files` asks nothing at all before it does

```rust
let _ = delegate.remove(&dst).await;
let mut file = delegate.create_file_write(&dst).await?;
file.write_all(&data)                // ...for every chunk, before anybody is asked
```

The patch adds `BackupDelegate::should_store_file(&dir, &path) -> bool`
(default `true`, so other delegates are unaffected), calls it right after the
device names the file, and — when it answers false — skips `create_dir_all`,
`remove` and `create_file_write` entirely and drains the chunks without ever
reaching disk. The Swift side already expects this ordering: `mb2_should_preserve`
drops its 0-byte placeholder inside the callback, i.e. before anything is
written.

`should_preserve` is added **last** in the Rust struct, matching the header, so a
caller built against a header without it still lines up.

TODO verify from a run's log: `BackupTrace` prints per-domain keep/drain counts.
If everything under `HomeDomain` shows as drained, the `device_name` handed to
the callback is the bare domain and the path rules in
`ProtectiveBackup.isProtectiveFile` never fire.

## Rebuilding

```
scripts/build-idevice-ios.sh            # build; prints the artifact path
scripts/build-idevice-ios.sh --install  # swap it into Vendor (backs up first)
```

The script owns the toolchain (`.rust/`, gitignored), installs the iOS std target,
pulls cmake for `aws-lc-sys` from the managed Python venv, clones v0.1.68, applies
everything in this directory, builds `--release --target aarch64-apple-ios
--features obfuscate`, and asserts on the result (`jktcp-` object present,
`_idevice_to_stream` exported).
