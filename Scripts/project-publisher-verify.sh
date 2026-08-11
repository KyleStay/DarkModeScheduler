#!/bin/bash
set -euo pipefail

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

exec "/Users/kyle/Documents/Project Publisher/scripts/verify-artifact-matrix.sh" \
    DarkModeScheduler \
    "${PROJECT_PUBLISHER_VERSION:?Project Publisher must set PROJECT_PUBLISHER_VERSION}"
