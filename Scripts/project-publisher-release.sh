#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

version="${PROJECT_PUBLISHER_VERSION:?Project Publisher must set PROJECT_PUBLISHER_VERSION}"
identity="${PROJECT_PUBLISHER_APP_IDENTITY:?Project Publisher must set PROJECT_PUBLISHER_APP_IDENTITY}"
packager="/Users/kyle/Documents/Project Publisher/scripts/package-app.sh"

architecture_list="${PROJECT_PUBLISHER_ARCHITECTURES:?Project Publisher must set PROJECT_PUBLISHER_ARCHITECTURES}"
if [[ "$architecture_list" == ,* || "$architecture_list" == *, || "$architecture_list" == *,,* ]]; then
    echo "error: PROJECT_PUBLISHER_ARCHITECTURES contains an empty architecture" >&2
    exit 64
fi

IFS=',' read -r -a architectures <<< "$architecture_list"
seen_architectures=","
for architecture in "${architectures[@]}"; do
    case "$architecture" in
        x86_64|arm64|universal) ;;
        *) echo "error: unsupported architecture: $architecture" >&2; exit 64 ;;
    esac
    if [[ "$seen_architectures" == *",$architecture,"* ]]; then
        echo "error: duplicate architecture: $architecture" >&2
        exit 64
    fi
    seen_architectures+="$architecture,"
done

for architecture in "${architectures[@]}"; do
    BUILD_ARCH="$architecture" \
    CODESIGN_IDENTITY="$identity" \
    CODESIGN_ENTITLEMENTS="DarkModeScheduler.entitlements" \
    CODESIGN_RUNTIME=1 \
        ./build.sh
    "$packager" DarkModeScheduler.app DarkModeScheduler "$version" "$architecture" "Dark Mode Scheduler" verify
done
