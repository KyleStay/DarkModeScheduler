#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

version="${PROJECT_PUBLISHER_VERSION:?Project Publisher must set PROJECT_PUBLISHER_VERSION}"
identity="${PROJECT_PUBLISHER_APP_IDENTITY:?Project Publisher must set PROJECT_PUBLISHER_APP_IDENTITY}"
packager="/Users/kyle/Documents/Project Publisher/scripts/package-app.sh"

for architecture in x86_64 arm64 universal; do
    BUILD_ARCH="$architecture" \
    CODESIGN_IDENTITY="$identity" \
    CODESIGN_ENTITLEMENTS="DarkModeScheduler.entitlements" \
    CODESIGN_RUNTIME=1 \
        ./build.sh
    "$packager" DarkModeScheduler.app DarkModeScheduler "$version" "$architecture" "Dark Mode Scheduler" verify
done
