#!/bin/bash
set -euo pipefail

sed -n 's/^VERSION="\([^"]*\)"/\1/p' "$(dirname "$0")/../build.sh"
