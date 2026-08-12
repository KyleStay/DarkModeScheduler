#!/usr/bin/env bash
#
# Regression gate for the shared-source two-channel product.
set -euo pipefail

cd "$(dirname "$0")/.."

native_arch="$(uname -m)"
full_output=".build/full-variant-product"
full_app="$full_output/DarkModeScheduler.app"
full_binary="$full_app/Contents/MacOS/DarkModeScheduler"

APP_OUTPUT_DIR="$full_output" \
BUILD_INTERMEDIATES_DIR=".build/full-variant-intermediates" \
BUILD_ARCH="$native_arch" \
CODESIGN_ENTITLEMENTS="DarkModeScheduler.entitlements" \
    ./build.sh

# Do not use grep -q here: with pipefail, an early grep exit can turn strings'
# SIGPIPE into a false contract failure.
if ! strings "$full_binary" | grep -F 'CoreBrightness.framework' >/dev/null; then
    echo "✗ Full binary unexpectedly omits Night Shift support." >&2
    exit 1
fi

BUILD_ARCH="$native_arch" Tools/build-app-store.sh

echo "✅ Full and App Store channel contracts both pass."
