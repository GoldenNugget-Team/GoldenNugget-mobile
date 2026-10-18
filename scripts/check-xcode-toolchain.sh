#!/usr/bin/env bash
# Shared by the IPA and asset workflows: require the project's supported tools.
set -euo pipefail
xcodebuild -version
swift --version
SDK_VERSION="$(xcrun --sdk iphoneos --show-sdk-version)"
XCODE_VERSION="$(xcodebuild -version | awk '/^Xcode / {print $2}')"
SWIFT_VERSION="$(swift --version | sed -nE 's/.*Swift version ([0-9]+)\..*/\1/p')"
echo "iPhoneOS SDK: $SDK_VERSION"
if [[ "${XCODE_VERSION%%.*}" -lt 26 || "${SDK_VERSION%%.*}" -lt 26 || "$SWIFT_VERSION" -lt 6 ]]; then
  echo "error: GoldenNugget requires Xcode 26+, iOS SDK 26+, and Swift 6+." >&2
  exit 1
fi
