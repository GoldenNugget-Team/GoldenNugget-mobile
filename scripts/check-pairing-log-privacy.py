#!/usr/bin/env python3
"""Reject credential dictionary dumps in source and the linked iOS archives."""
from pathlib import Path
import argparse

ROOT = Path(__file__).resolve().parent.parent
FORBIDDEN = b"Read dictionary for rppairingfile:"
SAFE = b"Reading RemotePairing record (secret fields omitted)"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archives", action="store_true", help="also inspect rebuilt iOS archives")
    args = parser.parse_args()
    paths = [ROOT / "Vendor/AirliftFFI/rust-core/vendor/idevice/src/remote_pairing/rp_pairing_file.rs"]
    if args.archives:
        paths += [ROOT / "Vendor/IDevice.xcframework/ios-arm64/libidevice_ffi.a",
                  ROOT / "Vendor/AirliftFFI.xcframework/ios-arm64/libairlift_ffi.a"]
    for path in paths:
        data = path.read_bytes()
        if FORBIDDEN in data or SAFE not in data:
            raise SystemExit(f"FAIL: old or unverified pairing logging in {path.relative_to(ROOT)}")
        print(f"PASS: {path.relative_to(ROOT)}")
    patch = ROOT / "Vendor/patches/idevice-ffi/redact_pairing.patch"
    if b'+        debug!("Reading RemotePairing record (secret fields omitted)");' not in patch.read_bytes():
        raise SystemExit("FAIL: reproducible IDevice redaction patch missing")
    print("PASS: IDevice redaction patch")


if __name__ == "__main__":
    main()
