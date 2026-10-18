# Audit fixes and simulator validation

The eight findings from the October 17 audit have been addressed:

- Both Rust RemotePairing readers omit the credential dictionary from logs. The IDevice change is installed by `redact_pairing.patch`. Before enabling file logging, the app removes legacy diagnostic files containing leaked pairing fields; pairing records are preserved.
- Media pulls preserve existing index entries. A verified copy is recorded in an append-only, synchronized recovery journal before its original can be deleted. Successful pulls atomically compact the journal into the existing JSON index. Interrupted final journal records are ignored and repaired before the next append.
- Media operations reserve the store for the whole transfer. Clear and a second transfer cannot race journal writes. Invalid existing index data fails the pull before deletion.
- Originals above the existing 64 MiB AFC restore limit are kept on the device, with the limit shown in the Media page.
- Engine operations reserve the run before preparation. An abandoned FFI call continues to block new runs until it actually returns, protecting the shared session and backup directory. In-flight accounting starts before either cancellation racer is scheduled.
- Pairing completion checks its generation before stopping Bonjour or ending background time. Each Rust pairing run writes its own temporary record; only the current successful run can promote it to the canonical pairing path.
- Numeric imports use the editor's finite/range/type checks and checked integer conversion.
- Keypad apply throws if every cache write fails, reports partial success, and always removes staging files.

The status-bar archive check also now reads native keyed-archive UIDs through an XML projection without depending on private Foundation object layouts. The original archive bytes are preserved.

## Simulator regression app

Run with an already booted iOS 26+ simulator:

```sh
python3 scripts/test-audit-regressions.py --device <simulator-udid>
```

The runner concatenates shipping Swift files into a temporary UIKit test app, omitting only imports of unavailable device modules. Production method bodies are compiled as written. AFC, AirLift and the RemotePairing callback backend are replaced by the adjacent hardware doubles; no physical device is contacted.

Validated on iPhone 17 Pro Simulator, iOS 26.5: **34 checks in 13 scenarios, zero failures**. Results and screenshot are written to `build/regression-simulator/`.

All seven existing Swift regression harnesses also pass, including the previously failing status-bar check. The apply-preview harness's documented command now includes its missing dependencies.

This Intel host cannot run the complete device app in Simulator: AirliftFFI and EMProxy have no simulator slices, and IDevice's existing simulator slice is ARM64-only. Real RemotePairing, AFC transport, restore and sandbox escape still require an iPhone. The simulator results cover the actual Swift state/file logic with injected transport failures, not those hardware protocols.

## Native library verification

After rebuilding and installing both device libraries:

```sh
python3 scripts/check-pairing-log-privacy.py --archives
python3 scripts/check-linked-symbols.py
scripts/build-airlift-ffi-ios.sh --check
```

These checks verify that both linked archives contain the redacted logging path, their C symbols resolve, and the installed Airlift copy matches the current build after deduplication.
