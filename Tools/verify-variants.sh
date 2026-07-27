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
BUILD_ARCH="$native_arch" \
CODESIGN_ENTITLEMENTS="DarkModeScheduler.entitlements" \
    ./build.sh

if ! strings "$full_binary" | grep -q 'CoreBrightness.framework'; then
    echo "✗ Full binary unexpectedly omits Night Shift support." >&2
    exit 1
fi

BUILD_ARCH="$native_arch" Tools/build-app-store.sh

echo "✅ Full and App Store channel contracts both pass."
