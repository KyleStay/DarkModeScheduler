#!/usr/bin/env bash
#
# Build the signed app, then run its nonactivating offscreen fixture. This lane
# never opens the app, creates a menu-bar item, requests permissions, or changes
# system/user state.
set -euo pipefail

cd "$(dirname "$0")/.."

Tools/check-background-test-safety.sh

architecture="${BUILD_ARCH:-$(uname -m)}"
app_output=".build/background-fixture-product"
output=".build/background-verification"
app="$app_output/DarkModeScheduler.app"
binary="$app/Contents/MacOS/DarkModeScheduler"

APP_OUTPUT_DIR="$app_output" \
BUILD_INTERMEDIATES_DIR=".build/background-fixture-intermediates" \
BUILD_ARCH="$architecture" ./build.sh

"$binary" --background-fixture --output "$output"

test -s "$output/report.json"
rg -q '"verification"[[:space:]]*:[[:space:]]*"background-safe"' "$output/report.json"
for fixture in active-night paused-day; do
    rg -q '"name"[[:space:]]*:[[:space:]]*"'"$fixture"'"' "$output/report.json"
    rg -q '"nonBackgroundSampleCount"[[:space:]]*:[[:space:]]*[1-9][0-9][0-9]' "$output/report.json"
    rg -q '"distinctSampleCount"[[:space:]]*:[[:space:]]*[2-9][0-9]*' "$output/report.json"
done
for image in active-night paused-day; do
    test -s "$output/$image.png"
    file "$output/$image.png" | grep 'PNG image' >/dev/null
done

echo "✅ Background-safe verification passed."
echo "   Report: $(pwd)/$output/report.json"
echo "   PNGs:   $(pwd)/$output/active-night.png $(pwd)/$output/paused-day.png"
