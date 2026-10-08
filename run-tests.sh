#!/usr/bin/env bash
#
# Compiles and runs the standalone SunCalculator test suite.
# Exits non-zero if compilation or any assertion fails.
#
set -euo pipefail

cd "$(dirname "$0")"

BUILD_DIR=".build"
mkdir -p "$BUILD_DIR"
TEST_BIN="$BUILD_DIR/SunCalculatorTests"

echo "==> Compiling test suite (swiftc, warnings-as-info)…"
/usr/bin/swiftc -O \
    -module-cache-path "$BUILD_DIR/module-cache" \
    -target "$(uname -m)-apple-macos13.0" \
    -o "$TEST_BIN" \
    SunCalculatorTests.swift SunCalculator.swift Scheduler.swift Support.swift

echo "==> Running tests…"
echo
"$TEST_BIN"

echo
echo "==> Verifying distribution-channel policy…"
/usr/bin/swiftc -O \
    -module-cache-path "$BUILD_DIR/module-cache" \
    -target "$(uname -m)-apple-macos13.0" \
    -o "$BUILD_DIR/FullVariantContractTests" \
    VariantContractTests.swift DistributionChannel.swift
"$BUILD_DIR/FullVariantContractTests"

/usr/bin/swiftc -O \
    -D APP_STORE \
    -module-cache-path "$BUILD_DIR/module-cache" \
    -target "$(uname -m)-apple-macos13.0" \
    -o "$BUILD_DIR/AppStoreVariantContractTests" \
    VariantContractTests.swift DistributionChannel.swift
"$BUILD_DIR/AppStoreVariantContractTests"

echo
echo "==> Verifying CoreBrightness Night Shift status mapping…"
/usr/bin/swiftc -O \
    -module-cache-path "$BUILD_DIR/module-cache" \
    -target "$(uname -m)-apple-macos13.0" \
    -o "$BUILD_DIR/NightShiftAdapterTests" \
    NightShiftAdapterTests.swift Services.swift Support.swift Scheduler.swift SunCalculator.swift
"$BUILD_DIR/NightShiftAdapterTests"

echo
echo "==> Verifying presentation host migration and sizing (offscreen)…"
/usr/bin/swiftc -O -warnings-as-errors \
    -module-cache-path "$BUILD_DIR/module-cache" \
    -target "$(uname -m)-apple-macos13.0" \
    -o "$BUILD_DIR/PresentationHostTests" \
    PresentationHostTests.swift PresentationHost.swift
"$BUILD_DIR/PresentationHostTests"
