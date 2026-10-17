# jktcp, patched: reorder buffer + duplicate ACKs

Upstream: https://github.com/jkcoxson/jktcp, tag `v0.1.7`, MIT.
This directory is that tag plus the change below; nothing else was touched.

The consumer is `libidevice_ffi.a` inside `IDevice.xcframework`, built from
https://github.com/jkcoxson/idevice (checkout `v0.1.68`), which depends on
`jktcp = "0.1.7"` — the exact version string embedded in the shipped binary at
`Vendor/IDevice.xcframework/ios-arm64/libidevice_ffi.a`.

## Why

`Adapter::process_tcp_packet_from_payload` enforced strictly in-order delivery:

```rust
} else {
    // Out-of-order: drop silently.
    debug!("out-of-order seq={} expected={} hp={}", ...);
}
```

Three separate problems in that branch, all visible in one production run.

**1. The data was thrown away, not held.** On 2026-09-19 an iPad (iOS 27) went
quiet for ~11 s and then pushed 2402 segments — 2.46 MB — in 45 ms. The first
26 KB of that burst never arrived. The stack dropped the 2.46 MB sitting behind
the hole. Because it is a stream, the peer then had to re-send *all* of it:

```
26 KB lost  →  2.49 MB retransmitted
```

**2. Nothing was ACKed.** The branch left `ack_me` as `None`, so the peer got no
signal at all for out-of-order data — not even a duplicate ACK. Its only way
forward was its own retransmit timer, measured as one 1024-byte segment every
310 ms: about 13 minutes to clear a 2.5 MB backlog, while it refilled the window
with data that would be discarded too.

**3. The advertised window had no buffer behind it.** `TcpPacket::create` was
called with `u16::MAX - 1` and `OUR_WSCALE = 8`, so every ACK advertised a
16.7 MB receive window. There was no 16.7 MB of storage — in-order bytes went
straight into an unbounded `Vec` and out-of-order bytes went nowhere. Telling a
peer it may have 16.7 MB in flight while being able to hold none of it is what
turns a small loss into a large one.

## What changed

`src/adapter.rs`:

- `ConnectionState` gains `reorder: BTreeMap<u32, Arc<[u8]>>`, `reorder_bytes`,
  `reorder_base`, `reorder_window`, `dup_acks`, `last_dup_ack`.
  Out-of-order segments are **held** instead of dropped. Keys are *offsets from
  `reorder_base`*, not raw sequence numbers, so the map's ordering stays TCP's
  ordering across a 2^32 wrap.
- `deliver_buffered()` releases the segment at the gap head plus every run that
  becomes contiguous with it. A segment that starts before the gap head and
  reaches past it is trimmed, not dropped, since a peer may retransmit a range
  larger than the hole it is filling.
- `should_dup_ack()` answers out-of-order segments with duplicate ACKs, so the
  peer can fast-retransmit. A 2402-segment burst would otherwise put 2402 ACKs
  on the tunnel in the same 45 ms the receive path is trying to drain; the first
  `DUP_ACK_BURST` go immediately and the rest are paced at
  `DUP_ACK_MIN_INTERVAL`.
- `advertised_window()` / `window_field()` replace the hard-coded
  `u16::MAX - 1` at every call site, so the window field is the free reorder
  space, expressed in units of the scale announced in the SYN.
- `ConnectionState` also gains `last_ack_window` and `last_acked_seq`.
  `ack_window()` holds the advertised window steady across acknowledgements that
  do not move `ack`; it only recomputes when the gap head advances. RFC 5681
  counts an ACK as a *duplicate* only when its advertised window "equals the
  advertised window in the last incoming acknowledgment", so the shrinking
  window `window_field()` produces for held data turned every duplicate ACK into
  a window update the peer would not count — the 2026-10 stall below.
- `Adapter::set_reorder_window()` sets `DEFAULT_REORDER_WINDOW` (8 MiB) per
  construction.

No public signature changed, so `idevice` needs no source change — only the
`[patch.crates-io]` stanza in its workspace `Cargo.toml`.

## Tests

`adapter::tests` inside `src/adapter.rs`. Four new cases, driven at the real
segment size and burst length from the 2026-09-19 run:

| test | unpatched | patched |
|---|---|---|
| `burst_behind_a_hole_is_held_then_released` | delivers **26,624 B** of 2,486,272 | delivers all 2,486,272 B, in order |
| `out_of_order_segment_is_answered` | 0 ACKs | ACK pointing at the gap head |
| `out_of_order_burst_does_not_flood_acks` | 0 ACKs | ≥3, <200 for 2402 segments |
| `advertised_window_tracks_buffer_space` | (does not compile¹) | 1 MiB free → 1 MiB advertised in order |
| `duplicate_acks_repeat_the_last_window` | n/a² | every duplicate ACK repeats the in-order window |

¹ It is the only case that calls `set_reorder_window`, so it cannot compile
against the unpatched file. The others assert only on the wire and on the read
buffer, which is what lets the same suite run both ways.

² It asserts the fix for the 2026-10 stall below; it does not compile against
the unpatched file either, since `ack_window()` does not exist there.

The obsolete case `out_of_order_packet_dropped` was **removed**: it asserted
`"out-of-order data must not be buffered"` and `"out-of-order packet must not
trigger an ACK"`, i.e. exactly the behaviour being fixed.

`cargo test --lib` is 17 passed / 2 failed; the two failures
are `tests::local_tcp` and `tests::handle_speed`, which need root to create a
TUN device (`Failed to create tunnel. Are you root?`). Pre-existing, unrelated.

## Status: what this fixed, and what it did not

The three problems above were real and are fixed. Re-measured on the same iPad,
after the patch, from one production run on 2026-09-19 (23:11 local):

| claim | before | after |
|---|---|---|
| data behind a hole | dropped | **held** — 3,509 consecutive `held=true` lines; `reorder_bytes` peaked at 3,265,094 B |
| reorder window overflow | n/a | 0 `held=false`, 0 "reorder window full" |

**The run still hangs**, though, and for a reason this patch could not address:
the peer never re-sends the missing range.

```
15:11:27.874  device: DLMessageUploadFiles — the first real payload of the run
15:11:28.104  first out-of-order: seq=4262572243 expected=4262551763
              → the hole is the FIRST 20,480 bytes of that payload
15:11:28      buffered climbs 1024 → 3,265,094 B, held=true on every line
15:11:29…     DL messages = 0 for 88 s; out-of-order +6…8/s
              gap grows monotonically 2991 KB → 3361 KB
15:12:56      out-of-order stops and the gap resets — the flow ends
```

Across those 88 seconds jktcp logged **zero** `duplicate data seq` lines: not one
retransmission. So the old amplification is gone — the bytes behind the hole are
no longer thrown away — and what replaced it is a deadlock in which the data is
held correctly and never becomes deliverable.

That moves the open question off this side of the wire. The next measurement is
whether the duplicate ACKs leave and whether the peer acts on them. `ack()` wrote
only to the pcap, which this build does not capture, so that was invisible; the
`duplicate ACK for hp=…` line added to the out-of-order branch now records the
ack number, the window and the hole width for every duplicate ACK sent.

## 2026-10: the window was what made the duplicate ACKs useless

Re-measured on an iPhone (iOS 27.0.1) during a protective backup over the
`LocalDevVPN` tunnel. This time the wire census (added to the Swift side, and the
Rust log) could see both directions:

```
out-of-order ×5983   duplicate ACK for hp=… ×684   duplicate data seq=… ×298
held=false ×0
```

So the previous open question is answered: the duplicate ACKs **do** leave, and
the peer **does** retransmit. But the gap still closed at ~1024 B per ~300 ms
(~3.4 KB/s) — an RTO, not a fast retransmit — and the session eventually died
(`Socket(Kind(NotConnected))`). The cause is in `window_field()`:

```
(32764, 32760, 32756, …)   // the window on consecutive duplicate ACKs
```

Every held segment lowers `reorder_bytes`, so every duplicate ACK advertised a
smaller window than the one before. RFC 5681 §2 defines a duplicate ACK as
requiring *(e) the advertised window in the incoming acknowledgment equals the
advertised window in the last incoming acknowledgment*. None of these qualified,
so the peer never counted three of them and never fast-retransmitted.

The fix is `last_ack_window` / `last_acked_seq` / `ack_window()`: a duplicate ACK
repeats the window of the last ACK that made progress. The reorder window is
still the ceiling on what is advertised — it is recomputed the moment the gap
head moves — so this does not over-advertise; it only stops the window from
moving *between* duplicate ACKs.

## Rebuilding

See `scripts/build-idevice-ios.sh` in the repository root. It fetches
https://github.com/jkcoxson/idevice at `v0.1.68`, drops this directory in as a
`[patch.crates-io]` replacement, and builds `idevice-ffi` for
`aarch64-apple-ios` with the same flags the upstream `justfile` uses:

```
cargo build --release --target aarch64-apple-ios --features obfuscate
```

The script keeps its toolchain under `.rust/` in this repository
(`RUSTUP_HOME`/`CARGO_HOME` are pointed there) and never touches `~/.cargo` or
`~/.rustup`. It needs `cmake` on `PATH` for `aws-lc-sys`; the recipe installs it
into the managed Python venv rather than with Homebrew.
