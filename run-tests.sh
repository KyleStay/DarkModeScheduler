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
    -target "$(uname -m)-apple-macos13.0" \
    -o "$TEST_BIN" \
    SunCalculatorTests.swift SunCalculator.swift

echo "==> Running tests…"
echo
"$TEST_BIN"
