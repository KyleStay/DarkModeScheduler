#!/bin/bash
set -euo pipefail

exec "/Users/kyle/Documents/Project Publisher/scripts/verify-artifact-matrix.sh" \
    DarkModeScheduler \
    "${PROJECT_PUBLISHER_VERSION:?Project Publisher must set PROJECT_PUBLISHER_VERSION}"
