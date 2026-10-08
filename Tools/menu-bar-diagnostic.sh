#!/usr/bin/env bash
# Explicit interactive lane: one temporary real menu bar scene, synthetic data.
# No installation, activation, permissions, live settings, or system effects.
set -euo pipefail
cd "$(dirname "$0")/.."
output=".build/menu-bar-diagnostic"
app_output=".build/menu-bar-diagnostic-product"
mkdir -p "$output"
APP_OUTPUT_DIR="$app_output" \
BUILD_INTERMEDIATES_DIR=".build/menu-bar-diagnostic-intermediates" \
BUILD_ARCH="$(uname -m)" ./build.sh
binary="$app_output/DarkModeScheduler.app/Contents/MacOS/DarkModeScheduler"
echo "Synthetic sun/moon item only. Existing installed app remains running."
echo "Click the synthetic item to see its diagnostic header; its settings are disabled."
echo "Ctrl-C stops this process. JSON: $output/events.ndjson"
echo "For a sample while the icon is missing, run in another terminal:"
echo "  kill -USR1 <pid from events.ndjson>"
"$binary" --menu-bar-diagnostic --capture-directory "$output" "$@" > "$output/events.ndjson"
