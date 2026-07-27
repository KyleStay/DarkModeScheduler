#!/usr/bin/env bash
#
# Builds and validates the sandboxed App Store channel. This creates a local
# review candidate; App Store Connect signing/upload remains an explicit release
# action performed with the matching distribution certificate and profile.
set -euo pipefail

cd "$(dirname "$0")/.."

architecture="${BUILD_ARCH:-universal}"
app=".build/app-store-product/DarkModeScheduler.app"
binary="$app/Contents/MacOS/DarkModeScheduler"

DISTRIBUTION_CHANNEL=app-store BUILD_ARCH="$architecture" ./build.sh

codesign --verify --strict --verbose=2 "$app"

entitlements="$(codesign -d --entitlements :- "$app" 2>/dev/null)"
printf '%s' "$entitlements" | plutil -extract 'com\.apple\.security\.app-sandbox' raw - \
    | grep -qx true
printf '%s' "$entitlements" | plutil -extract 'com\.apple\.security\.network\.client' raw - \
    | grep -qx true
printf '%s' "$entitlements" \
    | plutil -extract 'com\.apple\.security\.personal-information\.location' raw - \
    | grep -qx true

if strings "$binary" | grep -Eq \
    'CoreBrightness|CBBlueLightClient|getBlueLightStatus:|setEnabled:'; then
    echo "✗ App Store binary contains a private Night Shift implementation." >&2
    exit 1
fi

echo "✅ App Store channel verified."
echo "   App bundle: $(pwd)/$app"
echo "   Channel: sandboxed; Night Shift implementation absent"
